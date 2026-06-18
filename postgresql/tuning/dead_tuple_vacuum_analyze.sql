WITH table_options AS (
    SELECT
        c.oid AS relid,

        COALESCE(
            (MAX(opt.option_value) FILTER (WHERE opt.option_name = 'autovacuum_enabled'))::boolean,
            true
        ) AS autovacuum_enabled,

        COALESCE(
            (MAX(opt.option_value) FILTER (WHERE opt.option_name = 'autovacuum_vacuum_threshold'))::numeric,
            current_setting('autovacuum_vacuum_threshold')::numeric
        ) AS autovacuum_vacuum_threshold,

        COALESCE(
            (MAX(opt.option_value) FILTER (WHERE opt.option_name = 'autovacuum_vacuum_scale_factor'))::numeric,
            current_setting('autovacuum_vacuum_scale_factor')::numeric
        ) AS autovacuum_vacuum_scale_factor,

        COALESCE(
            (MAX(opt.option_value) FILTER (WHERE opt.option_name = 'autovacuum_analyze_threshold'))::numeric,
            current_setting('autovacuum_analyze_threshold')::numeric
        ) AS autovacuum_analyze_threshold,

        COALESCE(
            (MAX(opt.option_value) FILTER (WHERE opt.option_name = 'autovacuum_analyze_scale_factor'))::numeric,
            current_setting('autovacuum_analyze_scale_factor')::numeric
        ) AS autovacuum_analyze_scale_factor

    FROM pg_class c
    LEFT JOIN LATERAL pg_options_to_table(c.reloptions) opt ON true
    GROUP BY c.oid
),
base AS (
    SELECT
        s.relid,
        s.schemaname AS schema_name,
        s.relname AS table_name,

        pg_relation_size(s.relid) AS table_bytes,
        pg_total_relation_size(s.relid) AS total_bytes,

        s.n_live_tup::numeric AS n_live_tup,
        s.n_dead_tup::numeric AS n_dead_tup,
        s.n_mod_since_analyze::numeric AS n_mod_since_analyze,

        s.last_vacuum,
        s.last_autovacuum,
        s.last_analyze,
        s.last_autoanalyze,

        s.vacuum_count,
        s.autovacuum_count,
        s.analyze_count,
        s.autoanalyze_count,

        o.autovacuum_enabled,

        (
            o.autovacuum_vacuum_threshold
            + o.autovacuum_vacuum_scale_factor * GREATEST(s.n_live_tup::numeric, 0)
        ) AS vacuum_threshold_tuples,

        (
            o.autovacuum_analyze_threshold
            + o.autovacuum_analyze_scale_factor * GREATEST(s.n_live_tup::numeric, 0)
        ) AS analyze_threshold_tuples

    FROM pg_stat_user_tables s
    JOIN pg_class c ON c.oid = s.relid
    JOIN table_options o ON o.relid = s.relid
    WHERE c.relkind IN ('r', 'm')
),
scored AS (
    SELECT
        *,

        ROUND(
            100.0 * n_dead_tup
            / NULLIF(n_live_tup + n_dead_tup, 0),
            2
        ) AS dead_tuple_pct,

        ROUND(
            100.0 * n_mod_since_analyze
            / NULLIF(n_live_tup, 0),
            2
        ) AS mod_since_analyze_pct,

        (
            n_dead_tup >= 10000
            AND
            100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0) >= 10
        ) AS high_dead_tuple_ratio,

        (
            n_dead_tup >= vacuum_threshold_tuples
        ) AS over_vacuum_threshold,

        (
            last_analyze IS NULL
            AND last_autoanalyze IS NULL
            AND n_live_tup > 0
        ) AS never_analyzed,

        (
            n_mod_since_analyze >= analyze_threshold_tuples
        ) AS over_analyze_threshold,

        (
            n_mod_since_analyze >= 10000
            AND
            100.0 * n_mod_since_analyze / NULLIF(n_live_tup, 0) >= 10
        ) AS high_mod_since_analyze_ratio

    FROM base
)
SELECT
    current_database() AS database_name,
    schema_name,
    table_name,

    pg_size_pretty(table_bytes) AS table_size,
    pg_size_pretty(total_bytes) AS total_size_with_indexes,

    n_live_tup::bigint AS estimated_live_tuples,
    n_dead_tup::bigint AS estimated_dead_tuples,
    dead_tuple_pct,

    n_mod_since_analyze::bigint AS rows_changed_since_analyze,
    mod_since_analyze_pct,

    vacuum_threshold_tuples::bigint AS estimated_vacuum_threshold,
    analyze_threshold_tuples::bigint AS estimated_analyze_threshold,

    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,

    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count,

    autovacuum_enabled,

    CASE
        WHEN autovacuum_enabled IS FALSE THEN 'CHECK_AUTOVACUUM_DISABLED'
        WHEN (high_dead_tuple_ratio OR over_vacuum_threshold)
             AND (never_analyzed OR over_analyze_threshold OR high_mod_since_analyze_ratio)
            THEN 'VACUUM_ANALYZE_CANDIDATE'
        WHEN high_dead_tuple_ratio OR over_vacuum_threshold
            THEN 'VACUUM_CANDIDATE'
        WHEN never_analyzed OR over_analyze_threshold OR high_mod_since_analyze_ratio
            THEN 'ANALYZE_CANDIDATE'
        ELSE 'REVIEW'
    END AS maintenance_suggestion,

    concat_ws(
        ', ',
        CASE WHEN autovacuum_enabled IS FALSE THEN 'autovacuum disabled on table' END,
        CASE WHEN high_dead_tuple_ratio THEN 'dead tuple ratio >= 10% and dead tuples >= 10000' END,
        CASE WHEN over_vacuum_threshold THEN 'estimated autovacuum vacuum threshold exceeded' END,
        CASE WHEN never_analyzed THEN 'table has never been analyzed' END,
        CASE WHEN over_analyze_threshold THEN 'estimated autovacuum analyze threshold exceeded' END,
        CASE WHEN high_mod_since_analyze_ratio THEN 'changed rows since analyze >= 10% and >= 10000 rows' END
    ) AS reason,

    CASE
        WHEN (high_dead_tuple_ratio OR over_vacuum_threshold)
             AND (never_analyzed OR over_analyze_threshold OR high_mod_since_analyze_ratio)
            THEN format('VACUUM (ANALYZE, VERBOSE) %I.%I;', schema_name, table_name)

        WHEN high_dead_tuple_ratio OR over_vacuum_threshold
            THEN format('VACUUM (VERBOSE) %I.%I;', schema_name, table_name)

        WHEN never_analyzed OR over_analyze_threshold OR high_mod_since_analyze_ratio
            THEN format('ANALYZE VERBOSE %I.%I;', schema_name, table_name)

        ELSE NULL
    END AS suggested_command

FROM scored
WHERE
       autovacuum_enabled IS FALSE
    OR high_dead_tuple_ratio
    OR over_vacuum_threshold
    OR never_analyzed
    OR over_analyze_threshold
    OR high_mod_since_analyze_ratio
ORDER BY
    CASE
        WHEN autovacuum_enabled IS FALSE THEN 1
        WHEN (high_dead_tuple_ratio OR over_vacuum_threshold)
             AND (never_analyzed OR over_analyze_threshold OR high_mod_since_analyze_ratio)
            THEN 2
        WHEN high_dead_tuple_ratio OR over_vacuum_threshold
            THEN 3
        WHEN never_analyzed OR over_analyze_threshold OR high_mod_since_analyze_ratio
            THEN 4
        ELSE 5
    END,
    total_bytes DESC,
    dead_tuple_pct DESC NULLS LAST,
    n_dead_tup DESC;
