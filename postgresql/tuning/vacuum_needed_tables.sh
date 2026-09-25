WITH cfg AS (
    SELECT current_setting('autovacuum_vacuum_threshold')::float8           AS vac_base,
           current_setting('autovacuum_vacuum_scale_factor')::float8        AS vac_scale,
           current_setting('autovacuum_vacuum_insert_threshold')::float8    AS ins_base,
           current_setting('autovacuum_vacuum_insert_scale_factor')::float8 AS ins_scale,
           current_setting('autovacuum_analyze_threshold')::float8          AS ana_base,
           current_setting('autovacuum_analyze_scale_factor')::float8       AS ana_scale,
           current_setting('autovacuum_freeze_max_age')::float8             AS freeze_max
),
t AS (
    SELECT c.oid,
           n.nspname  AS schema_name,
           c.relname  AS table_name,
           c.relkind,
           c.reltuples,
           c.relpages,
           c.relallvisible,
           CASE WHEN c.relkind IN ('r', 'm') THEN age(c.relfrozenxid) END AS xid_age,
           s.n_live_tup,
           s.n_dead_tup,
           s.n_mod_since_analyze,
           s.n_ins_since_vacuum,
           greatest(s.last_vacuum,  s.last_autovacuum)  AS last_any_vacuum,
           greatest(s.last_analyze, s.last_autoanalyze) AS last_any_analyze,
           (SELECT count(DISTINCT ps.attname) FROM pg_stats ps
             WHERE ps.schemaname = n.nspname AND ps.tablename = c.relname)      AS stats_cols,
           (SELECT count(*) FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)  AS total_cols,
           EXISTS (SELECT 1 FROM pg_stat_progress_vacuum p WHERE p.relid = c.oid) AS vacuum_running,
           opt.*
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    LEFT JOIN LATERAL (
        SELECT  max(option_value) FILTER (WHERE option_name = 'autovacuum_enabled')                          AS o_av_enabled,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_vacuum_threshold'))::float8        AS o_vac_base,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_vacuum_scale_factor'))::float8     AS o_vac_scale,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_vacuum_insert_threshold'))::float8 AS o_ins_base,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_vacuum_insert_scale_factor'))::float8 AS o_ins_scale,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_analyze_threshold'))::float8       AS o_ana_base,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_analyze_scale_factor'))::float8    AS o_ana_scale,
               (max(option_value) FILTER (WHERE option_name = 'autovacuum_freeze_max_age'))::float8          AS o_freeze_max
        FROM pg_options_to_table(c.reloptions)
    ) opt ON true
    WHERE c.relkind IN ('r', 'p', 'm')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg\_%'
),
d AS (
    SELECT t.*,
           coalesce(o_vac_base, vac_base) + coalesce(o_vac_scale, vac_scale) * greatest(reltuples, 0) AS vac_thresh,
           coalesce(o_ins_base, ins_base)                                                             AS ins_base_eff,
           coalesce(o_ins_base, ins_base) + coalesce(o_ins_scale, ins_scale) * greatest(reltuples, 0) AS ins_thresh,
           coalesce(o_ana_base, ana_base) + coalesce(o_ana_scale, ana_scale) * greatest(reltuples, 0) AS ana_thresh,
           coalesce(o_freeze_max, freeze_max)                                                         AS freeze_max_eff
    FROM t CROSS JOIN cfg
),
e AS (
    SELECT d.*,
           coalesce(n_dead_tup > vac_thresh, false)                                  AS need_vac_dead,
           coalesce(ins_base_eff >= 0 AND n_ins_since_vacuum > ins_thresh, false)    AS need_vac_ins,
           coalesce(xid_age > 0.8 * freeze_max_eff, false)                           AS need_vac_freeze,
           (relkind = 'p' AND stats_cols = 0)                                        AS miss_part,
           ((relkind <> 'p' AND reltuples > 0 AND stats_cols = 0)
             OR (reltuples = -1 AND coalesce(n_live_tup, 0) > 0))                    AS miss_stats,
           (reltuples > 0 AND stats_cols > 0 AND stats_cols < total_cols)            AS partial_stats,
           coalesce(n_mod_since_analyze > ana_thresh, false)                         AS stale_stats
    FROM d
),
f AS (
    SELECT e.*,
           (need_vac_dead OR need_vac_ins OR need_vac_freeze)             AS need_vac,
           (miss_part OR miss_stats OR partial_stats OR stale_stats)      AS need_analyze,
           concat_ws(', ',
               CASE WHEN need_vac_freeze        THEN 'ACİL: wraparound yaklaşıyor' END,
               CASE WHEN o_av_enabled = 'false' THEN 'autovacuum bu tabloda kapalı' END,
               CASE WHEN need_vac_dead          THEN 'dead tuple eşiği aşıldı' END,
               CASE WHEN need_vac_ins           THEN 'insert eşiği aşıldı' END,
               CASE WHEN miss_part              THEN 'partitioned: elle ANALYZE gerekir' END,
               CASE WHEN miss_stats             THEN 'istatistik yok' END,
               CASE WHEN partial_stats          THEN 'bazı kolon istatistikleri eksik' END,
               CASE WHEN stale_stats            THEN 'istatistik eskimiş' END
           ) AS reasons
    FROM e
)
SELECT reasons,
       schema_name,
       table_name,
       pg_size_pretty(pg_relation_size(oid))                                       AS table_size,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2)           AS dead_pct,
       round((n_dead_tup / nullif(vac_thresh, 0))::numeric, 2)                     AS dead_vs_thresh,
       n_ins_since_vacuum,
       n_mod_since_analyze,
       xid_age,
       round((100.0 * xid_age / freeze_max_eff)::numeric, 1)                       AS xid_pct,
       round((100.0 * relallvisible / nullif(relpages, 0))::numeric, 1)            AS vm_pct,
       last_any_vacuum,
       last_any_analyze,
       vacuum_running,
       CASE
         WHEN vacuum_running            THEN '-- şu an vacuum çalışıyor, bitmesini bekleyin'
         WHEN need_vac AND need_analyze THEN format('VACUUM (ANALYZE) %I.%I;', schema_name, table_name)
         WHEN need_vac                  THEN format('VACUUM %I.%I;',           schema_name, table_name)
         WHEN need_analyze              THEN format('ANALYZE %I.%I;',          schema_name, table_name)
       END AS command
FROM f
WHERE reasons <> ''
ORDER BY need_vac_freeze DESC, need_vac DESC, need_analyze DESC, pg_relation_size(oid) DESC;
