SELECT
    q.query_id,
    p.plan_id,
    p.is_forced_plan,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    p.count_compiles,
    p.initial_compile_start_time,
    p.last_compile_start_time,
    qt.query_sql_text,
    TRY_CONVERT(xml, p.query_plan) AS query_plan_xml
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
WHERE q.query_id = ???
ORDER BY p.plan_id;

