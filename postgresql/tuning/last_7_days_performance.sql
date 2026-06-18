
WITH daily AS (
    SELECT
        date_trunc('day', q.start_time)::date AS day,

        COUNT(DISTINCT q.query_id) AS distinct_query_count,
        SUM(q.calls) AS executions,
        SUM(q.rows) AS total_rows,

        SUM(q.total_time)::numeric AS total_query_time_ms,

        SUM(q.shared_blks_hit) AS shared_blks_hit,
        SUM(q.shared_blks_read) AS shared_blks_read,
        SUM(q.temp_blks_read) AS temp_blks_read,
        SUM(q.temp_blks_written) AS temp_blks_written,

        SUM(q.blk_read_time)::numeric AS blk_read_time_ms,
        SUM(q.blk_write_time)::numeric AS blk_write_time_ms

    FROM query_store.qs_view q
    WHERE q.start_time >= now() - interval '7 days'
      AND q.is_system_query IS FALSE
    GROUP BY 1
)
SELECT
    day,

    distinct_query_count,
    executions,
    total_rows,

    -- TOTAL süreler
    ROUND(total_query_time_ms / 1000 / 60, 2) AS total_query_time_minutes,

    -- EXECUTION başına ortalamalar
    ROUND(total_query_time_ms / NULLIF(executions, 0), 2) AS avg_ms_per_execution,

    ROUND(total_rows::numeric / NULLIF(executions, 0), 2) AS avg_rows_per_execution,

    -- ROW başına normalize süre
    ROUND(
        total_query_time_ms / NULLIF(total_rows, 0),
        4
    ) AS avg_ms_per_row,

    ROUND(
        total_query_time_ms * 1000 / NULLIF(total_rows, 0),
        2
    ) AS avg_ms_per_1000_rows,

    -- Physical read: cache dışından okunan block'lar
    ROUND(
        shared_blks_read::numeric
        * current_setting('block_size')::numeric
        / 1024 / 1024 / 1024,
        2
    ) AS physical_read_gb,

    ROUND(
        shared_blks_read::numeric
        * current_setting('block_size')::numeric
        / 1024
        / NULLIF(executions, 0),
        2
    ) AS avg_physical_read_kb_per_execution,

    -- Logical-ish buffer access: hit + read
    ROUND(
        (shared_blks_hit + shared_blks_read)::numeric
        * current_setting('block_size')::numeric
        / 1024 / 1024 / 1024,
        2
    ) AS buffer_access_gb,

    ROUND(
        (shared_blks_hit + shared_blks_read)::numeric
        * current_setting('block_size')::numeric
        / 1024
        / NULLIF(executions, 0),
        2
    ) AS avg_buffer_access_kb_per_execution,

    -- Temp kullanımı
    ROUND(
        temp_blks_read::numeric
        * current_setting('block_size')::numeric
        / 1024 / 1024 / 1024,
        2
    ) AS temp_read_gb,

    ROUND(
        temp_blks_written::numeric
        * current_setting('block_size')::numeric
        / 1024 / 1024 / 1024,
        2
    ) AS temp_written_gb,

    ROUND(
        temp_blks_read::numeric
        * current_setting('block_size')::numeric
        / 1024
        / NULLIF(executions, 0),
        2
    ) AS avg_temp_read_kb_per_execution,

    ROUND(
        temp_blks_written::numeric
        * current_setting('block_size')::numeric
        / 1024
        / NULLIF(executions, 0),
        2
    ) AS avg_temp_written_kb_per_execution,

    -- Cache hit oranı
    ROUND(
        100.0 * shared_blks_hit::numeric
        / NULLIF((shared_blks_hit + shared_blks_read)::numeric, 0),
        2
    ) AS shared_cache_hit_pct,

    -- track_io_timing açıksa anlamlı
    ROUND(blk_read_time_ms / 1000, 2) AS total_blk_read_time_sec,

    ROUND(
        blk_read_time_ms / NULLIF(executions, 0),
        2
    ) AS avg_blk_read_time_ms_per_execution

FROM daily
ORDER BY day;
