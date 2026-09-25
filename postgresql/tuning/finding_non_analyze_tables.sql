WITH t AS (
    SELECT c.oid,
           n.nspname                                   AS schema_name,
           c.relname                                   AS table_name,
           c.relkind,
           c.reltuples,
           s.n_live_tup,
           s.n_mod_since_analyze,
           s.last_analyze,
           s.last_autoanalyze,
           (SELECT count(DISTINCT ps.attname) FROM pg_stats ps
             WHERE ps.schemaname = n.nspname AND ps.tablename = c.relname)          AS stats_cols,
           (SELECT count(*) FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)      AS total_cols
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE c.relkind IN ('r', 'p', 'm')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg\_%'
),
d AS (
    SELECT *,
           round(100.0 * n_mod_since_analyze / nullif(n_live_tup, 0), 1) AS mod_pct,
           CASE
             WHEN relkind = 'p' AND stats_cols = 0
                  THEN '1-partitioned: autovacuum analiz etmez, elle ANALYZE gerekir'
             WHEN reltuples = -1 AND coalesce(n_live_tup, 0) > 0
                  THEN '2-hiç analiz edilmemiş (veri var)'
             WHEN stats_cols = 0 AND reltuples > 0
                  THEN '3-satır var ama kolon istatistiği yok'
             WHEN stats_cols < total_cols AND reltuples > 0
                  THEN '4-bazı kolonların istatistiği eksik'
             WHEN n_mod_since_analyze > 0.2 * nullif(n_live_tup, 0)
                  THEN '5-eskimiş (son analizden beri %20+ değişiklik)'
             WHEN reltuples = -1
                  THEN '6-hiç analiz edilmemiş (boş tablo, önemsiz)'
             WHEN last_analyze IS NULL AND last_autoanalyze IS NULL
                  THEN '7-zaman bilgisi yok ama istatistik mevcut (restart kaynaklı olabilir)'
           END AS durum
    FROM t
)
SELECT durum,
       schema_name,
       table_name,
       pg_size_pretty(pg_relation_size(oid))        AS table_size,
       reltuples::bigint                            AS reltuples,
       n_live_tup,
       n_mod_since_analyze,
       mod_pct,
       stats_cols || ' / ' || total_cols            AS stats_coverage,
       greatest(last_analyze, last_autoanalyze)     AS last_any_analyze,
       format('ANALYZE %I.%I;', schema_name, table_name) AS analyze_cmd
FROM d
WHERE durum IS NOT NULL
ORDER BY durum, pg_relation_size(oid) DESC;
