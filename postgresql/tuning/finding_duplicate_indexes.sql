WITH index_info AS (
  SELECT n.nspname AS schema_name,
         t.relname AS table_name,
         ix.indrelid,
         ix.indexrelid,
         ic.relname AS index_name,
         ic.relkind AS index_relkind,
         am.amname  AS index_method,
         ix.indisprimary,
         ix.indisunique,
         ix.indimmediate,
         ix.indnullsnotdistinct,             -- PG15+; eski sürümde bu satırı ve WHERE'deki kullanımını silin
         ix.indisreplident,
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
         COALESCE(s.idx_scan, 0)               AS idx_scan,
         -- Kendi constraint'i (UNIQUE/EXCLUDE) veya ona referans veren FK var mi
         EXISTS (SELECT 1 FROM pg_constraint c
                 WHERE c.conindid = ix.indexrelid)   AS constraint_bagli,
         -- Partitioned parent indekse attach edilmis child indeks mi
         EXISTS (SELECT 1 FROM pg_inherits inh
                 WHERE inh.inhrelid = ix.indexrelid) AS parent_e_bagli
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
         first_value(indexrelid) OVER w AS keeper_oid,
         row_number()            OVER w AS rn
  FROM index_info i
  WINDOW w AS (
    PARTITION BY indrelid, index_method, indkey, indclass, indcollation,
                 indoption, indnkeyatts, indnatts, index_exprs, index_predicate
    -- Keeper sirasi: PK > constraint'li > parent'a bagli > replica identity
    --                > UNIQUE > cok kullanilan > buyuk > eski
    ORDER BY indisprimary DESC, constraint_bagli DESC, parent_e_bagli DESC,
             indisreplident DESC, indisunique DESC,
             idx_scan DESC, index_size_bytes DESC, indexrelid
  )
)
SELECT d.schema_name,
       d.table_name,
       k.index_name AS korunacak,
       CASE WHEN k.indisprimary     THEN 'PRIMARY KEY'
            WHEN k.constraint_bagli THEN 'CONSTRAINT'
            WHEN k.indisunique      THEN 'UNIQUE'
            ELSE 'NORMAL' END AS korunacak_tip,
       k.idx_scan   AS korunacak_kullanim,
       d.index_name AS mukerrer,
       d.idx_scan   AS mukerrer_kullanim,
       pg_size_pretty(d.index_size_bytes) AS mukerrer_boyut,
       k.indexdef   AS korunacak_def,
       d.indexdef   AS mukerrer_def,
       CASE
         WHEN d.constraint_bagli THEN
           '-- MANUEL: constraint/FK bu indekse bagli, ALTER TABLE ... DROP CONSTRAINT gerekebilir'
         WHEN d.index_relkind = 'I' THEN
           'DROP INDEX IF EXISTS ' || quote_ident(d.schema_name) || '.' || quote_ident(d.index_name)
           || ';  -- partitioned indeks: CONCURRENTLY desteklenmez, kilit alir'
         ELSE
           'DROP INDEX CONCURRENTLY IF EXISTS ' || quote_ident(d.schema_name) || '.' || quote_ident(d.index_name) || ';'
       END AS onerilen_drop
FROM ranked d
JOIN ranked k ON k.indexrelid = d.keeper_oid
WHERE d.rn > 1
  AND NOT d.indisprimary
  AND NOT d.indisreplident
  AND NOT d.parent_e_bagli
  -- Unique mukerrer ancak keeper ayni unique semantigini sagliyorsa silinsin
  AND (NOT d.indisunique
       OR (k.indisunique
           AND k.indimmediate        = d.indimmediate
           AND k.indnullsnotdistinct = d.indnullsnotdistinct))
ORDER BY d.schema_name, d.table_name, d.index_size_bytes DESC;
