IF OBJECT_ID('tempdb..#space') IS NOT NULL DROP TABLE #space;
CREATE TABLE #space
(
    database_name sysname PRIMARY KEY,
    data_used_mb  decimal(18,1),
    log_used_mb   decimal(18,1)
);

DECLARE @space_sql nvarchar(max);

SELECT @space_sql = STRING_AGG(CAST(
        'USE ' + QUOTENAME(name) + '; INSERT #space SELECT DB_NAME(), '
      + 'CAST(SUM(CASE WHEN type_desc = ''ROWS'' THEN CAST(FILEPROPERTY(name, ''SpaceUsed'') AS bigint) END) * 8 / 1024.0 AS decimal(18,1)), '
      + 'CAST(SUM(CASE WHEN type_desc = ''LOG''  THEN CAST(FILEPROPERTY(name, ''SpaceUsed'') AS bigint) END) * 8 / 1024.0 AS decimal(18,1)) '
      + 'FROM sys.database_files;' AS nvarchar(max)), CHAR(13) + CHAR(10))
FROM   sys.databases
WHERE  database_id > 4 AND state_desc = 'ONLINE';

IF @space_sql IS NOT NULL EXEC sys.sp_executesql @space_sql;

WITH files AS
(
    SELECT  database_id,
            CAST(SUM(CASE WHEN type_desc = 'ROWS' THEN CAST(size AS bigint) END) * 8 / 1024.0 AS decimal(18,1)) AS data_mb,
            CAST(SUM(CASE WHEN type_desc = 'LOG'  THEN CAST(size AS bigint) END) * 8 / 1024.0 AS decimal(18,1)) AS log_mb
    FROM    sys.master_files
    GROUP BY database_id
),
usage_by_db AS
(
    SELECT  d.database_id,
            d.name                               AS database_name,
            d.state_desc,
            d.recovery_model_desc,
            d.create_date,
            d.is_read_only,
            d.is_auto_close_on,
            ISNULL(SUM(ius.user_seeks + ius.user_scans + ius.user_lookups), 0) AS user_reads,
            ISNULL(SUM(ius.user_updates), 0)                                   AS user_writes,
            GREATEST(MAX(ius.last_user_seek),
                     MAX(ius.last_user_scan),
                     MAX(ius.last_user_lookup))  AS last_user_read,
            MAX(ius.last_user_update)            AS last_user_write
    FROM    sys.databases AS d
    LEFT JOIN sys.dm_db_index_usage_stats AS ius
           ON ius.database_id = d.database_id
    WHERE   d.database_id > 4
    GROUP BY d.database_id, d.name, d.state_desc, d.recovery_model_desc,
             d.create_date, d.is_read_only, d.is_auto_close_on
)
SELECT  u.database_name,
        u.state_desc,
        u.recovery_model_desc                    AS recovery,
        u.create_date,
        u.user_reads,
        u.user_writes,
        u.user_reads + u.user_writes             AS total_activity,
        u.last_user_read,
        u.last_user_write,
        f.data_mb,
        s.data_used_mb,
        CAST(f.data_mb - s.data_used_mb AS decimal(18,1))     AS data_free_mb,
        f.log_mb,
        s.log_used_mb,
        CAST((f.data_mb + f.log_mb) / 1024.0 AS decimal(18,2)) AS total_gb,
        CASE WHEN s.data_used_mb > 0
             THEN CAST(100.0 * s.data_used_mb / NULLIF(f.data_mb, 0) AS decimal(5,1)) END AS data_pct_used
FROM    usage_by_db AS u
LEFT JOIN files   AS f ON f.database_id   = u.database_id
LEFT JOIN #space  AS s ON s.database_name = u.database_name
ORDER BY total_activity, f.data_mb, u.database_name;
