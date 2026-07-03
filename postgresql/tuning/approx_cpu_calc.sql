WITH
    params AS (
        SELECT
            LOCALTIMESTAMP - INTERVAL '3 days' AS from_ts,
            LOCALTIMESTAMP AS to_ts

            -- Örnek sabit tarih aralığı kullanmak istersen:
            -- '2026-07-02 15:00:00'::timestamp AS from_ts,
            -- '2026-07-03 00:00:00'::timestamp AS to_ts
    ),
    base AS (
        SELECT
            qv.db_id,
            qv.user_id,
            qv.query_id,

            COUNT(DISTINCT qv.plan_id) AS plan_count,
            STRING_AGG(
                DISTINCT qv.plan_id::text,
                ', '
                ORDER BY qv.plan_id::text
            ) AS plan_ids,

            MIN(qv.start_time) AS first_seen,
            MAX(qv.end_time) AS last_seen,

            SUM(qv.calls) AS calls,
            SUM(qv.total_time) AS total_exec_ms,

            SUM(qv.rows) AS total_rows,

            SUM(qv.shared_blks_hit) AS shared_blks_hit,
            SUM(qv.shared_blks_read) AS shared_blks_read,
            SUM(qv.shared_blks_dirtied) AS shared_blks_dirtied,
            SUM(qv.shared_blks_written) AS shared_blks_written,

            SUM(qv.temp_blks_read) AS temp_blks_read,
            SUM(qv.temp_blks_written) AS temp_blks_written,

            SUM(COALESCE(qv.blk_read_time, 0)) AS blk_read_time_ms,
            SUM(COALESCE(qv.blk_write_time, 0)) AS blk_write_time_ms,

            MIN(qv.min_time) AS min_exec_ms,
            MAX(qv.max_time) AS max_exec_ms,

            MAX(qv.query_type) AS query_type,
            REGEXP_REPLACE(MAX(qv.query_sql_text), '\s+', ' ', 'g') AS query_text
        FROM
            query_store.qs_view qv
            CROSS JOIN params p
        WHERE
            qv.end_time > p.from_ts
            AND qv.start_time < p.to_ts
            AND qv.is_system_query IS FALSE
        GROUP BY
            qv.db_id,
            qv.user_id,
            qv.query_id
    ),
    totals AS (
        SELECT
            SUM(total_exec_ms) AS workload_exec_ms
        FROM
            base
    )
SELECT
    COALESCE(d.datname, b.db_id::text) AS database_name,
    COALESCE(r.rolname, b.user_id::text) AS user_name,

    b.query_id,
    b.query_type,
    b.plan_count,
    b.plan_ids,

    b.first_seen,
    b.last_seen,

    b.calls,

    ROUND((b.total_exec_ms / 1000.0)::numeric, 2) AS total_exec_sec,

    ROUND(
        (
            100.0 * b.total_exec_ms / NULLIF(t.workload_exec_ms, 0)
        )::numeric,
        2
    ) AS exec_time_pct_of_workload,

    ROUND(
        (b.total_exec_ms / NULLIF(b.calls, 0))::numeric,
        2
    ) AS avg_exec_ms_per_call,

    ROUND(b.min_exec_ms::numeric, 2) AS min_exec_ms,
    ROUND(b.max_exec_ms::numeric, 2) AS max_exec_ms,

    ROUND(
        (b.total_rows::numeric / NULLIF(b.calls, 0)),
        2
    ) AS avg_rows_per_call,

    b.total_rows,

    b.shared_blks_hit,
    b.shared_blks_read,
    b.shared_blks_dirtied,
    b.shared_blks_written,

    b.temp_blks_read,
    b.temp_blks_written,

    ROUND((b.blk_read_time_ms / 1000.0)::numeric, 2) AS blk_read_time_sec,
    ROUND((b.blk_write_time_ms / 1000.0)::numeric, 2) AS blk_write_time_sec,

    LEFT(b.query_text, 3000) AS query_text
FROM
    base b
    CROSS JOIN totals t
    LEFT JOIN pg_database d ON d.oid = b.db_id
    LEFT JOIN pg_roles r ON r.oid = b.user_id
ORDER BY
    b.total_exec_ms DESC
LIMIT
    50;

