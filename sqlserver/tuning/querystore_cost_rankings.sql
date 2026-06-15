
DECLARE @since datetimeoffset = DATEADD(hour, -24, SYSUTCDATETIME());

SELECT TOP (50)
    q.query_id,
    p.plan_id,

    SUM(rs.count_executions) AS executions,

    SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,
    SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms,

    SUM(rs.avg_logical_io_reads * rs.count_executions) AS total_logical_reads,
    SUM(rs.avg_physical_io_reads * rs.count_executions) AS total_physical_reads,

    SUM(rs.avg_duration * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,

    SUM(rs.avg_cpu_time * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,

    SUM(rs.avg_logical_io_reads * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,

    LEFT(qt.query_sql_text, 3000) AS query_text
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan p
    ON rs.plan_id = p.plan_id
JOIN sys.query_store_query q
    ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
WHERE rsi.start_time >= @since
GROUP BY
    q.query_id,
    p.plan_id,
    qt.query_sql_text
ORDER BY total_duration_ms   DESC;
