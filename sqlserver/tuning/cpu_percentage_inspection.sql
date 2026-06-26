    DECLARE @start_time datetimeoffset = '2026-06-25 20:00:00 +03:00';
DECLARE @end_time   datetimeoffset = '2026-06-26 07:00:00 +03:00';
DECLARE @vcores int = 4;

SELECT TOP (50)
    CAST(SWITCHOFFSET(rsi.start_time, '+03:00') AS datetime2(0)) AS interval_start_tr,
    q.query_id,
    p.plan_id,

    SUM(rs.count_executions) AS executions,

    SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms,

    CAST(
        100.0 * (SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0)
        / NULLIF(@vcores * 3600.0 * 1000.0, 0)
        AS decimal(10,2)
    ) AS approx_cpu_percent_of_instance,

    SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,

    CAST(
        (SUM(rs.avg_duration * rs.count_executions) / 1000.0)
        / NULLIF(3600.0 * 1000.0, 0)
        AS decimal(10,2)
    ) AS approx_avg_concurrent_running,

    SUM(rs.avg_logical_io_reads * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,

    LEFT(qt.query_sql_text, 800) AS query_text
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan p
    ON rs.plan_id = p.plan_id
JOIN sys.query_store_query q
    ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
WHERE rsi.start_time >= @start_time
  AND rsi.start_time <  @end_time
GROUP BY
    CAST(SWITCHOFFSET(rsi.start_time, '+03:00') AS datetime2(0)),
    q.query_id,
    p.plan_id,
    qt.query_sql_text
ORDER BY
    interval_start_tr,
    approx_cpu_percent_of_instance DESC;
