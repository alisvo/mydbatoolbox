DECLARE @since datetimeoffset = DATEADD(HOUR, -2, SYSDATETIMEOFFSET());

SELECT
    rsi.start_time,
    rsi.end_time,
    qsq.query_id,
    qsp.plan_id,
    SUM(rs.count_executions) AS executions,

    SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,
    SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,
    SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,

    SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms,
    SUM(rs.avg_logical_io_reads * rs.count_executions) AS total_logical_reads
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan qsp
    ON rs.plan_id = qsp.plan_id
JOIN sys.query_store_query qsq
    ON qsp.query_id = qsq.query_id
WHERE qsq.query_id IN (12823839,10708083, 10708075,12819599)
  AND rsi.end_time >= @since
GROUP BY
    rsi.start_time,
    rsi.end_time,
    qsq.query_id,
    qsp.plan_id
ORDER BY
qsq.query_id,
    rsi.start_time DESC,  
    total_cpu_ms DESC;
