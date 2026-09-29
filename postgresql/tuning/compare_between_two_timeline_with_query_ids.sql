6768945005058160394

-- =====================================================================
-- Azure PostgreSQL Flexible Server - Query Store
-- Impact of specific query_id(s) vs. the rest of the workload
-- P1 = [earliest .. Fri 25 Sep 2026 10:15 TRT]   P2 = [Fri 10:15 TRT .. now]
--
-- RUN WHILE CONNECTED TO THE  azure_sys  DATABASE.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1: Find the query_id(s) of your query.
--   If you REWROTE the SQL, it gets a NEW query_id, so include both the
--   old and the new id in step 2. If you only added an index or changed
--   settings, the query_id stays the same and you may see a new plan_id.
-- ---------------------------------------------------------------------
SELECT
    query_id,
    plan_id,
    min(start_time) AT TIME ZONE 'Europe/Istanbul'                  AS first_seen_trt,
    max(end_time)   AT TIME ZONE 'Europe/Istanbul'                  AS last_seen_trt,
    sum(calls)                                                      AS calls,
    round((sum(total_time) / NULLIF(sum(calls), 0))::numeric, 2)    AS avg_ms,
    left(max(query_sql_text), 150)                                  AS query_text
FROM query_store.qs_view
WHERE query_sql_text ILIKE '%your_table_or_keyword%'     -- <== change this
GROUP BY query_id, plan_id
ORDER BY query_id, first_seen_trt;


-- ---------------------------------------------------------------------
-- STEP 2: Target query(ies) vs. rest of workload, per period.
--   "rate" metrics  -> per hour (the windows have different lengths)
--                      plus the target's share of the server total
--   "per call"      -> cost of ONE execution; independent of traffic volume,
--                      so this is the cleanest evidence of the optimization
-- ---------------------------------------------------------------------
WITH params AS (
    SELECT timestamptz '2026-09-25 10:15:00+03'           AS cutoff,      -- Fri 10:15 TRT = 07:15 UTC
           ARRAY[6768945005058160394]::bigint[] AS target_ids   -- <== your query_id(s)
),
bounds AS (
    SELECT (extract(epoch FROM p.cutoff - min(qs.start_time)) / 3600)::numeric AS h1,
           (extract(epoch FROM max(qs.end_time) - p.cutoff)   / 3600)::numeric AS h2
    FROM query_store.qs_view qs
    CROSS JOIN params p
    GROUP BY p.cutoff
),
agg AS (
    SELECT
        CASE WHEN qs.start_time < p.cutoff THEN 1 ELSE 2 END      AS period,
        qs.query_id = ANY (p.target_ids)                           AS tgt,
        sum(qs.calls)::numeric                                     AS calls,
        sum(qs.total_time)::numeric                                AS total_ms,
        sum(qs.blk_read_time + qs.blk_write_time)::numeric         AS io_ms,
        sum(qs.rows)::numeric                                      AS rows_,
        sum(qs.shared_blks_hit)::numeric                           AS hit,
        sum(qs.shared_blks_read)::numeric                          AS rd,
        sum(qs.shared_blks_dirtied)::numeric                       AS dirtied,
        sum(qs.temp_blks_read + qs.temp_blks_written)::numeric     AS temp
    FROM query_store.qs_view qs
    CROSS JOIN params p
    -- WHERE qs.is_system_query = false     -- uncomment to exclude background/system queries
    GROUP BY 1, 2
),
m AS (   -- guarantee all 4 combinations exist, even if a query_id only ran in one period
    SELECT g.period, g.tgt,
           CASE g.period WHEN 1 THEN b.h1 ELSE b.h2 END AS hrs,
           coalesce(a.calls, 0)    AS calls,
           coalesce(a.total_ms, 0) AS total_ms,
           coalesce(a.io_ms, 0)    AS io_ms,
           coalesce(a.rows_, 0)    AS rows_,
           coalesce(a.hit, 0)      AS hit,
           coalesce(a.rd, 0)       AS rd,
           coalesce(a.dirtied, 0)  AS dirtied,
           coalesce(a.temp, 0)     AS temp
    FROM (VALUES (1, true), (1, false), (2, true), (2, false)) AS g(period, tgt)
    LEFT JOIN agg a ON a.period = g.period AND a.tgt = g.tgt
    CROSS JOIN bounds b
)
SELECT
    v.metric,
    round(x.tp1, 2)                                        AS "Target P1",
    round(x.tp2, 2)                                        AS "Target P2",
    round(100 * (x.tp2 - x.tp1) / NULLIF(x.tp1, 0), 1)     AS "Target change %",
    round(x.sh1, 1)                                        AS "Target share P1 %",
    round(x.sh2, 1)                                        AS "Target share P2 %",
    round(x.op1, 2)                                        AS "Rest P1",
    round(x.op2, 2)                                        AS "Rest P2",
    round(100 * (x.op2 - x.op1) / NULLIF(x.op1, 0), 1)     AS "Rest change %"
FROM m t1
JOIN m o1 ON o1.period = 1 AND NOT o1.tgt
JOIN m t2 ON t2.period = 2 AND t2.tgt
JOIN m o2 ON o2.period = 2 AND NOT o2.tgt
CROSS JOIN LATERAL (VALUES
    -- ord, kind,      metric,                          target P1,              rest P1,                target P2,              rest P2
    ( 1, 'rate',     'Executions / hour',               t1.calls,               o1.calls,               t2.calls,               o2.calls),
    ( 2, 'rate',     'DB time (sec / hour)',            t1.total_ms / 1000,     o1.total_ms / 1000,     t2.total_ms / 1000,     o2.total_ms / 1000),
    ( 3, 'rate',     'Est. CPU time (sec / hour)',      (t1.total_ms - t1.io_ms) / 1000, (o1.total_ms - o1.io_ms) / 1000,
                                                        (t2.total_ms - t2.io_ms) / 1000, (o2.total_ms - o2.io_ms) / 1000),
    ( 4, 'rate',     'I/O wait time (sec / hour)',      t1.io_ms / 1000,        o1.io_ms / 1000,        t2.io_ms / 1000,        o2.io_ms / 1000),
    ( 5, 'rate',     'Disk reads (MB / hour)',          t1.rd * 8 / 1024,       o1.rd * 8 / 1024,       t2.rd * 8 / 1024,       o2.rd * 8 / 1024),
    ( 6, 'rate',     'Buffer hits (MB / hour)',         t1.hit * 8 / 1024,      o1.hit * 8 / 1024,      t2.hit * 8 / 1024,      o2.hit * 8 / 1024),
    ( 7, 'rate',     'Pages dirtied (MB / hour)',       t1.dirtied * 8 / 1024,  o1.dirtied * 8 / 1024,  t2.dirtied * 8 / 1024,  o2.dirtied * 8 / 1024),
    ( 8, 'rate',     'Temp spill (MB / hour)',          t1.temp * 8 / 1024,     o1.temp * 8 / 1024,     t2.temp * 8 / 1024,     o2.temp * 8 / 1024),
    ( 9, 'rate',     'Rows / hour',                     t1.rows_,               o1.rows_,               t2.rows_,               o2.rows_),
    (10, 'per_call', 'Avg exec time (ms / call)',       t1.total_ms,            o1.total_ms,            t2.total_ms,            o2.total_ms),
    (11, 'per_call', 'Est. CPU (ms / call)',            t1.total_ms - t1.io_ms, o1.total_ms - o1.io_ms, t2.total_ms - t2.io_ms, o2.total_ms - o2.io_ms),
    (12, 'per_call', 'Disk blocks read / call',         t1.rd,                  o1.rd,                  t2.rd,                  o2.rd),
    (13, 'per_call', 'Buffer hits / call',              t1.hit,                 o1.hit,                 t2.hit,                 o2.hit),
    (14, 'per_call', 'Rows / call',                     t1.rows_,               o1.rows_,               t2.rows_,               o2.rows_)
) AS v(ord, kind, metric, t1v, o1v, t2v, o2v)
CROSS JOIN LATERAL (
    SELECT
        CASE v.kind WHEN 'rate' THEN v.t1v / NULLIF(t1.hrs, 0) ELSE v.t1v / NULLIF(t1.calls, 0) END AS tp1,
        CASE v.kind WHEN 'rate' THEN v.t2v / NULLIF(t2.hrs, 0) ELSE v.t2v / NULLIF(t2.calls, 0) END AS tp2,
        CASE v.kind WHEN 'rate' THEN v.o1v / NULLIF(o1.hrs, 0) ELSE v.o1v / NULLIF(o1.calls, 0) END AS op1,
        CASE v.kind WHEN 'rate' THEN v.o2v / NULLIF(o2.hrs, 0) ELSE v.o2v / NULLIF(o2.calls, 0) END AS op2,
        CASE WHEN v.kind = 'rate' THEN 100 * v.t1v / NULLIF(v.t1v + v.o1v, 0) END AS sh1,
        CASE WHEN v.kind = 'rate' THEN 100 * v.t2v / NULLIF(v.t2v + v.o2v, 0) END AS sh2
) AS x
WHERE t1.period = 1 AND t1.tgt
ORDER BY v.ord;
