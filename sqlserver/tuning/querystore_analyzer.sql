/* ============================================================================
   QUERY STORE ANALYZER — SQL Server 2017+
   ----------------------------------------------------------------------------

   RESULT SETS:
     1. Query ranking (query level, Top N or selected query_ids)
     2. Plan breakdown for those queries
     3. Per-interval trend for those queries (approx. CPU % and concurrency)
     4. Top consumers per interval ("who used the CPU in which hour")
     5. Wait category breakdown
     6. Plan details (forcing status, compile info, plan XML)

   USAGE:
     - Run in the target database (Query Store is per database).
     - Set the time window, @top_n and @order_by below.
     - To analyze specific queries, add query_ids to @query_ids; leave it empty
       to pick the Top N by @order_by.
     - Turn result sets on/off with the @show_* parameters.

   NOTES:
     - Query Store times are UTC; displayed in @display_offset.
     - CPU % = total_cpu / (vcores * interval length). It is approximate, and
       only counts work recorded in Query Store.
     - Waits (result 5) require WAIT_STATS_CAPTURE_MODE = ON (2017+).
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @start_time     datetimeoffset = DATEADD(HOUR, -24, SYSDATETIMEOFFSET());
DECLARE @end_time       datetimeoffset = SYSDATETIMEOFFSET();
DECLARE @display_offset nvarchar(6)    = N'+03:00';

DECLARE @top_n            int = 50;
DECLARE @top_per_interval int = 5;
-- duration | cpu | logical_reads | physical_reads | executions
DECLARE @order_by         varchar(20) = 'duration';

-- NULL = sys.dm_os_sys_info.cpu_count
DECLARE @vcores int = NULL;

-- Specific queries (leave empty for Top N):
DECLARE @query_ids TABLE (query_id bigint PRIMARY KEY);
-- INSERT @query_ids (query_id) VALUES (12823839), (10708083);

DECLARE @show_plans_summary bit = 1;
DECLARE @show_trend         bit = 1;
DECLARE @show_per_interval  bit = 1;
DECLARE @show_waits         bit = 1;
DECLARE @show_plan_xml      bit = 1;

/* ------------------------------------------------------------------------- */

IF @vcores IS NULL
    SELECT @vcores = cpu_count FROM sys.dm_os_sys_info;

IF @order_by NOT IN ('duration', 'cpu', 'logical_reads', 'physical_reads', 'executions')
BEGIN
    RAISERROR('@order_by must be one of: duration, cpu, logical_reads, physical_reads, executions', 16, 1);
    RETURN;
END;

IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc <> 'READ_WRITE')
    SELECT actual_state_desc, readonly_reason, desired_state_desc,
           current_storage_size_mb, max_storage_size_mb,
           'WARNING: Query Store is not READ_WRITE, data may be missing' AS note
    FROM sys.database_query_store_options;

/* Runtime stats aggregated per plan per interval, within the window */
DROP TABLE IF EXISTS #rs;

SELECT
    p.query_id,
    rs.plan_id,
    rsi.runtime_stats_interval_id,
    rsi.start_time,
    rsi.end_time,
    SUM(rs.count_executions)                            AS executions,
    SUM(rs.avg_duration          * rs.count_executions) AS duration_us,
    SUM(rs.avg_cpu_time          * rs.count_executions) AS cpu_us,
    SUM(rs.avg_logical_io_reads  * rs.count_executions) AS logical_reads,
    SUM(rs.avg_physical_io_reads * rs.count_executions) AS physical_reads
INTO #rs
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan p
    ON rs.plan_id = p.plan_id
WHERE rsi.start_time >= @start_time
  AND rsi.start_time <  @end_time
GROUP BY p.query_id, rs.plan_id, rsi.runtime_stats_interval_id, rsi.start_time, rsi.end_time;

/* Target queries: given list, or Top N by @order_by */
DROP TABLE IF EXISTS #target;

WITH q AS (
    SELECT
        query_id,
        SUM(executions)     AS executions,
        SUM(duration_us)    AS duration_us,
        SUM(cpu_us)         AS cpu_us,
        SUM(logical_reads)  AS logical_reads,
        SUM(physical_reads) AS physical_reads
    FROM #rs
    WHERE NOT EXISTS (SELECT 1 FROM @query_ids)
       OR query_id IN (SELECT query_id FROM @query_ids)
    GROUP BY query_id
)
SELECT
    q.*,
    ROW_NUMBER() OVER (ORDER BY
        CASE @order_by
            WHEN 'duration'       THEN q.duration_us
            WHEN 'cpu'            THEN q.cpu_us
            WHEN 'logical_reads'  THEN q.logical_reads
            WHEN 'physical_reads' THEN q.physical_reads
            WHEN 'executions'     THEN q.executions
        END DESC) AS rank_no
INTO #target
FROM q;

DELETE FROM #target WHERE rank_no > @top_n AND NOT EXISTS (SELECT 1 FROM @query_ids);

DECLARE @total_cpu_us float = (SELECT SUM(cpu_us) FROM #rs);
DECLARE @total_duration_us float = (SELECT SUM(duration_us) FROM #rs);

/* 1. Query ranking */
SELECT
    t.rank_no,
    t.query_id,
    (SELECT COUNT(DISTINCT plan_id) FROM #rs r WHERE r.query_id = t.query_id) AS plan_count,
    t.executions,
    t.duration_us / 1000.0 AS total_duration_ms,
    t.cpu_us      / 1000.0 AS total_cpu_ms,
    t.logical_reads        AS total_logical_reads,
    t.physical_reads       AS total_physical_reads,
    t.duration_us   / NULLIF(t.executions, 0) / 1000.0 AS avg_duration_ms,
    t.cpu_us        / NULLIF(t.executions, 0) / 1000.0 AS avg_cpu_ms,
    t.logical_reads / NULLIF(t.executions, 0)          AS avg_logical_reads,
    t.physical_reads / NULLIF(t.executions, 0)         AS avg_physical_reads,
    CAST(100.0 * t.cpu_us      / NULLIF(@total_cpu_us, 0)      AS decimal(5,2)) AS pct_of_total_cpu,
    CAST(100.0 * t.duration_us / NULLIF(@total_duration_us, 0) AS decimal(5,2)) AS pct_of_total_duration,
    OBJECT_NAME(q.object_id) AS object_name,
    LEFT(qt.query_sql_text, 3000) AS query_text
FROM #target t
JOIN sys.query_store_query q       ON q.query_id = t.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
ORDER BY t.rank_no;

/* 2. Plan breakdown */
IF @show_plans_summary = 1
SELECT
    r.query_id,
    r.plan_id,
    p.is_forced_plan,
    SUM(r.executions) AS executions,
    SUM(r.duration_us)    / NULLIF(SUM(r.executions), 0) / 1000.0 AS avg_duration_ms,
    SUM(r.cpu_us)         / NULLIF(SUM(r.executions), 0) / 1000.0 AS avg_cpu_ms,
    SUM(r.logical_reads)  / NULLIF(SUM(r.executions), 0)          AS avg_logical_reads,
    SUM(r.physical_reads) / NULLIF(SUM(r.executions), 0)          AS avg_physical_reads,
    SUM(r.duration_us) / 1000.0 AS total_duration_ms,
    SUM(r.cpu_us)      / 1000.0 AS total_cpu_ms,
    SUM(r.logical_reads)        AS total_logical_reads,
    SUM(r.physical_reads)       AS total_physical_reads,
    CAST(SWITCHOFFSET(MIN(r.start_time), @display_offset) AS datetime2(0)) AS first_interval_start,
    CAST(SWITCHOFFSET(MAX(r.end_time),   @display_offset) AS datetime2(0)) AS last_interval_end
FROM #rs r
JOIN #target t ON t.query_id = r.query_id
JOIN sys.query_store_plan p ON p.plan_id = r.plan_id
GROUP BY t.rank_no, r.query_id, r.plan_id, p.is_forced_plan
ORDER BY t.rank_no, total_logical_reads DESC;

/* 3. Per-interval trend */
IF @show_trend = 1
SELECT
    CAST(SWITCHOFFSET(r.start_time, @display_offset) AS datetime2(0)) AS interval_start,
    r.query_id,
    r.plan_id,
    r.executions,
    r.duration_us   / NULLIF(r.executions, 0) / 1000.0 AS avg_duration_ms,
    r.cpu_us        / NULLIF(r.executions, 0) / 1000.0 AS avg_cpu_ms,
    r.logical_reads / NULLIF(r.executions, 0)          AS avg_logical_reads,
    r.cpu_us / 1000.0 AS total_cpu_ms,
    r.logical_reads   AS total_logical_reads,
    CAST(100.0 * r.cpu_us / NULLIF(@vcores * DATEDIFF(SECOND, r.start_time, r.end_time) * 1e6, 0)
         AS decimal(10,2)) AS approx_cpu_pct_of_instance,
    CAST(r.duration_us / NULLIF(DATEDIFF(SECOND, r.start_time, r.end_time) * 1e6, 0)
         AS decimal(10,2)) AS approx_avg_concurrent_running
FROM #rs r
JOIN #target t ON t.query_id = r.query_id
ORDER BY t.rank_no, r.start_time DESC, total_cpu_ms DESC;

/* 4. Top consumers per interval (all queries, not only targets) */
IF @show_per_interval = 1
BEGIN;
WITH x AS (
    SELECT
        r.*,
        CAST(100.0 * r.cpu_us / NULLIF(@vcores * DATEDIFF(SECOND, r.start_time, r.end_time) * 1e6, 0)
             AS decimal(10,2)) AS approx_cpu_pct_of_instance,
        CAST(r.duration_us / NULLIF(DATEDIFF(SECOND, r.start_time, r.end_time) * 1e6, 0)
             AS decimal(10,2)) AS approx_avg_concurrent_running,
        ROW_NUMBER() OVER (PARTITION BY r.runtime_stats_interval_id ORDER BY r.cpu_us DESC) AS rn
    FROM #rs r
)
SELECT
    CAST(SWITCHOFFSET(x.start_time, @display_offset) AS datetime2(0)) AS interval_start,
    x.rn AS rank_in_interval,
    x.query_id,
    x.plan_id,
    x.executions,
    x.cpu_us      / 1000.0 AS total_cpu_ms,
    x.approx_cpu_pct_of_instance,
    x.duration_us / 1000.0 AS total_duration_ms,
    x.approx_avg_concurrent_running,
    x.logical_reads / NULLIF(x.executions, 0) AS avg_logical_reads,
    LEFT(qt.query_sql_text, 800) AS query_text
FROM x
JOIN sys.query_store_query q       ON q.query_id = x.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE x.rn <= @top_per_interval
ORDER BY x.start_time, x.rn;
END;

/* 5. Wait category breakdown */
IF @show_waits = 1
BEGIN;
WITH w AS (
    SELECT
        p.query_id,
        ws.plan_id,
        ws.wait_category_desc,
        SUM(ws.total_query_wait_time_ms) AS total_wait_ms
    FROM sys.query_store_wait_stats ws
    JOIN sys.query_store_runtime_stats_interval rsi
        ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan p
        ON ws.plan_id = p.plan_id
    JOIN #target t
        ON t.query_id = p.query_id
    WHERE rsi.start_time >= @start_time
      AND rsi.start_time <  @end_time
    GROUP BY p.query_id, ws.plan_id, ws.wait_category_desc
)
SELECT
    w.query_id,
    w.plan_id,
    w.wait_category_desc,
    w.total_wait_ms,
    CAST(100.0 * w.total_wait_ms / NULLIF(SUM(w.total_wait_ms) OVER (PARTITION BY w.plan_id), 0)
         AS decimal(5,2)) AS pct_of_plan_waits
FROM w
JOIN #target t ON t.query_id = w.query_id
ORDER BY t.rank_no, w.plan_id, w.total_wait_ms DESC;
END;

/* 6. Plan details */
IF @show_plan_xml = 1
SELECT
    q.query_id,
    p.plan_id,
    p.is_forced_plan,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    p.count_compiles,
    CAST(SWITCHOFFSET(p.initial_compile_start_time, @display_offset) AS datetime2(0)) AS initial_compile_start_time,
    CAST(SWITCHOFFSET(p.last_compile_start_time,    @display_offset) AS datetime2(0)) AS last_compile_start_time,
    CAST(SWITCHOFFSET(p.last_execution_time,        @display_offset) AS datetime2(0)) AS last_execution_time,
    qt.query_sql_text,
    TRY_CONVERT(xml, p.query_plan) AS query_plan_xml
FROM #target t
JOIN sys.query_store_query q       ON q.query_id = t.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p        ON p.query_id = q.query_id
ORDER BY t.rank_no, p.plan_id;

DROP TABLE IF EXISTS #rs;
DROP TABLE IF EXISTS #target;
