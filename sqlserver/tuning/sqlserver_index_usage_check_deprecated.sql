
SELECT
    SYSDATETIME() AS captured_at,
    osi.sqlserver_start_time,
    i.name,
    COALESCE(us.user_seeks, 0) AS user_seeks,
    COALESCE(us.user_scans, 0) AS user_scans,
    COALESCE(us.user_lookups, 0) AS user_lookups,
    COALESCE(us.user_updates, 0) AS user_updates,
    us.last_user_seek,
    us.last_user_scan,
    us.last_user_update
FROM sys.indexes AS i
CROSS JOIN sys.dm_os_sys_info AS osi
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = DB_ID()
   AND us.object_id = i.object_id
   AND us.index_id = i.index_id
WHERE i.object_id = OBJECT_ID(N'dbo.SHIFTMEMBERS')
ORDER BY i.index_id;
