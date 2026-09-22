IF OBJECT_ID('tempdb..#shrink') IS NOT NULL DROP TABLE #shrink;
CREATE TABLE #shrink
(
    database_id   int,
    database_name sysname,
    logical_name  sysname,
    file_type     nvarchar(10),
    current_mb    decimal(18,1),
    used_mb       decimal(18,1)
);

DECLARE @sql nvarchar(max);

SELECT @sql = STRING_AGG(CAST(
        'USE ' + QUOTENAME(name) + '; INSERT #shrink SELECT DB_ID(), DB_NAME(), name, type_desc, '
      + 'CAST(size * 8 / 1024.0 AS decimal(18,1)), '
      + 'CAST(CAST(FILEPROPERTY(name, ''SpaceUsed'') AS bigint) * 8 / 1024.0 AS decimal(18,1)) '
      + 'FROM sys.database_files;' AS nvarchar(max)), CHAR(13) + CHAR(10))
FROM   sys.databases
WHERE  database_id > 4 AND state_desc = 'ONLINE';

IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

WITH activity AS        -- kullanici sorgu aktivitesi (restart'tan beri)
(
    SELECT  database_id,
            SUM(user_seeks + user_scans + user_lookups) AS user_reads,
            SUM(user_updates)                           AS user_writes,
            GREATEST(MAX(last_user_seek), MAX(last_user_scan),
                     MAX(last_user_lookup), MAX(last_user_update)) AS last_touch
    FROM    sys.dm_db_index_usage_stats
    GROUP BY database_id
),
io AS                   -- fiziksel disk aktivitesi (restart'tan beri)
(
    SELECT  mf.database_id,
            mf.file_id,
            vfs.num_of_reads,
            vfs.num_of_writes,
            CAST((vfs.num_of_bytes_read + vfs.num_of_bytes_written) / 1048576.0 AS decimal(18,1)) AS io_mb
    FROM    sys.master_files AS mf
    CROSS APPLY sys.dm_io_virtual_file_stats(mf.database_id, mf.file_id) AS vfs
),
calc AS
(
    SELECT  s.*,
            CAST(CEILING((s.used_mb * 1.3 + 64) / 64.0) * 64 AS int) AS target_mb
    FROM    #shrink AS s
)
SELECT  c.database_name,
        c.logical_name,
        c.file_type,
        c.current_mb,
        c.used_mb,
        c.target_mb,
        c.current_mb - c.target_mb                                      AS gain_mb,
        CAST((c.current_mb - c.target_mb) / 1024.0 AS decimal(10,2))    AS gain_gb,
        ISNULL(a.user_reads, 0)                                         AS user_reads,
        ISNULL(a.user_writes, 0)                                        AS user_writes,
        a.last_touch,
        DATEDIFF(day, a.last_touch, SYSDATETIME())                      AS days_since_touch,
        i.num_of_writes                                                 AS file_writes,
        i.io_mb                                                         AS file_io_mb,
        CASE WHEN a.last_touch IS NULL AND ISNULL(i.num_of_writes, 0) < 1000
                  THEN 'OLU - istedigin zaman'
             WHEN a.last_touch IS NULL
                  THEN 'SORGU YOK - ama disk yazmis'
             WHEN DATEDIFF(day, a.last_touch, SYSDATETIME()) > 7
                  THEN 'SAKIN - 7+ gundur bos'
             ELSE 'AKTIF - mesai disi yap' END                          AS risk,
        CASE WHEN c.used_mb < 250  THEN 'KOLAY - saniyeler'
             WHEN c.used_mb < 2000 THEN 'ORTA - dakikalar'
             ELSE 'AGIR - rebuild gerekir' END                          AS effort,
        'USE ' + QUOTENAME(c.database_name) + '; DBCC SHRINKFILE ('
          + QUOTENAME(c.logical_name) + ', ' + CAST(c.target_mb AS varchar(10))
          + ') WITH WAIT_AT_LOW_PRIORITY (ABORT_AFTER_WAIT = SELF);'    AS shrink_cmd
FROM    calc AS c
LEFT JOIN activity AS a ON a.database_id = c.database_id
LEFT JOIN io       AS i ON i.database_id = c.database_id
                       AND i.file_id = (SELECT file_id FROM sys.master_files
                                        WHERE database_id = c.database_id
                                          AND name = c.logical_name)
WHERE   c.current_mb - c.target_mb >= 500
ORDER BY CASE WHEN a.last_touch IS NULL THEN 0 ELSE 1 END,   -- olu olanlar once
         gain_gb DESC;
