DECLARE @query_id bigint = ???;
DECLARE @since datetimeoffset = DATEADD(hour, -24, SYSUTCDATETIME());

SELECT
    p.query_id,
    p.plan_id,
    SUM(rs.count_executions) AS executions,

    SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,
    SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,
    SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,
    SUM(rs.avg_physical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_physical_reads,

    SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,
    SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms,
    SUM(rs.avg_logical_io_reads * rs.count_executions) AS total_logical_reads,
    SUM(rs.avg_physical_io_reads * rs.count_executions) AS total_physical_reads,

    MIN(rsi.start_time) AS first_interval_start,
    MAX(rsi.end_time) AS last_interval_end
FROM sys.query_store_plan p
JOIN sys.query_store_runtime_stats rs
    ON p.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE
    p.query_id = @query_id
    AND rsi.start_time >= @since
GROUP BY
    p.query_id,
    p.plan_id
ORDER BY
    total_logical_reads DESC;
