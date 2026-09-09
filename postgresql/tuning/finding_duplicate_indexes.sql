WITH index_info AS (
  SELECT n.nspname AS schema_name,
         t.relname AS table_name,
         ix.indexrelid,
         ic.relname AS index_name,
         am.amname  AS index_method,
         ix.indisprimary,
         ix.indisunique,
         ix.indkey::text        AS indkey,
         ix.indclass::text      AS indclass,
         ix.indcollation::text  AS indcollation,
         ix.indoption::text     AS indoption,
         ix.indnkeyatts,
         ix.indnatts,
         pg_get_expr(ix.indexprs, ix.indrelid) AS index_exprs,
         pg_get_expr(ix.indpred,  ix.indrelid) AS index_predicate,
         pg_get_indexdef(ix.indexrelid)        AS indexdef,
         pg_relation_size(ix.indexrelid)       AS index_size_bytes,
         COALESCE(s.idx_scan, 0)               AS idx_scan
  FROM pg_index ix
  JOIN pg_class     t  ON t.oid  = ix.indrelid
  JOIN pg_namespace n  ON n.oid  = t.relnamespace
  JOIN pg_class     ic ON ic.oid = ix.indexrelid
  JOIN pg_am        am ON am.oid = ic.relam
  LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = ix.indexrelid
  WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
    AND ix.indisvalid
    AND ix.indisready
),
ranked AS (
  SELECT i.*,
         row_number() OVER (
           PARTITION BY schema_name, table_name, index_method, indkey, indclass,
                        indcollation, indoption, indnkeyatts, indnatts,
                        index_exprs, index_predicate
           -- Keeper sirasi: PK > UNIQUE > cok kullanilan > buyuk > eski
           ORDER BY indisprimary DESC, indisunique DESC,
                    idx_scan DESC, index_size_bytes DESC, indexrelid
         ) AS rn,
         count(*) OVER (
           PARTITION BY schema_name, table_name, index_method, indkey, indclass,
                        indcollation, indoption, indnkeyatts, indnatts,
                        index_exprs, index_predicate
         ) AS grup_adedi
  FROM index_info i
)
SELECT d.schema_name,
       d.table_name,
       k.index_name AS korunacak,
       CASE WHEN k.indisprimary THEN 'PRIMARY KEY'
            WHEN k.indisunique  THEN 'UNIQUE'
            ELSE 'NORMAL' END AS korunacak_tip,
       k.idx_scan   AS korunacak_kullanim,
       d.index_name AS mukerrer,
       d.idx_scan   AS mukerrer_kullanim,
       pg_size_pretty(d.index_size_bytes) AS mukerrer_boyut,
       k.indexdef   AS korunacak_def,
       d.indexdef   AS mukerrer_def,
       'DROP INDEX CONCURRENTLY IF EXISTS '
         || quote_ident(d.schema_name) || '.' || quote_ident(d.index_name)
         || ';' AS onerilen_drop
FROM ranked d
JOIN ranked k
  ON  k.schema_name = d.schema_name
  AND k.table_name  = d.table_name
  AND k.index_method = d.index_method
  AND k.indkey = d.indkey
  AND k.indclass = d.indclass
  AND k.indcollation = d.indcollation
  AND k.indoption = d.indoption
  AND k.indnkeyatts = d.indnkeyatts
  AND k.indnatts = d.indnatts
  AND k.index_exprs IS NOT DISTINCT FROM d.index_exprs
  AND k.index_predicate IS NOT DISTINCT FROM d.index_predicate
  AND k.rn = 1
WHERE d.grup_adedi > 1
  AND d.rn > 1
  AND NOT d.indisprimary          -- PK asla drop onerilmesin
ORDER BY d.table_name, d.index_size_bytes DESC;
