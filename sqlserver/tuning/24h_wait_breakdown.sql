DECLARE @query_id bigint = ???;
DECLARE @since datetimeoffset = DATEADD(hour, -24, SYSUTCDATETIME());

SELECT
    p.query_id,
    p.plan_id,
    ws.wait_category_desc,
    SUM(ws.total_query_wait_time_ms) AS total_wait_ms
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_runtime_stats_interval rsi
    ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan p
    ON ws.plan_id = p.plan_id
WHERE
    p.query_id = @query_id
    AND rsi.start_time >= @since
GROUP BY
    p.query_id,
    p.plan_id,
    ws.wait_category_desc
ORDER BY
    p.plan_id,
    total_wait_ms DESC;
