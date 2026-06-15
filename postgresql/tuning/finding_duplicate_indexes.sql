WITH index_info AS (
  SELECT
    n.nspname AS schema_name,
    t.relname AS table_name,
    ix.indexrelid,
    ic.relname AS index_name,
    am.amname AS index_method,
    ix.indisprimary,
    ix.indisunique,
    ix.indisvalid,
    ix.indisready,
    ix.indkey::text AS indkey,
    ix.indclass::text AS indclass,
    ix.indcollation::text AS indcollation,
    ix.indoption::text AS indoption,
    ix.indnkeyatts,
    ix.indnatts,
    pg_get_expr(ix.indexprs, ix.indrelid) AS index_exprs,
    pg_get_expr(ix.indpred, ix.indrelid) AS index_predicate,
    pg_get_indexdef(ix.indexrelid) AS indexdef,
    pg_relation_size(ix.indexrelid) AS index_size_bytes
  FROM pg_index ix
  JOIN pg_class t ON t.oid = ix.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  JOIN pg_class ic ON ic.oid = ix.indexrelid
  JOIN pg_am am ON am.oid = ic.relam
  WHERE n.nspname = 'public'
    AND ix.indisvalid = true
    AND ix.indisready = true
),
duplicates AS (
  SELECT
    candidate.schema_name,
    candidate.table_name,

    keeper.index_name AS covering_index_name,
    CASE
      WHEN keeper.indisprimary THEN 'PRIMARY KEY'
      WHEN keeper.indisunique THEN 'UNIQUE'
    END AS covering_index_type,
    keeper.indexdef AS covering_indexdef,

    candidate.index_name AS duplicate_index_name,
    candidate.indexdef AS duplicate_indexdef,
    pg_size_pretty(candidate.index_size_bytes) AS duplicate_index_size,

    'DROP INDEX CONCURRENTLY IF EXISTS '
      || quote_ident(candidate.schema_name)
      || '.'
      || quote_ident(candidate.index_name)
      || ';' AS suggested_drop_sql
  FROM index_info candidate
  JOIN index_info keeper
    ON keeper.schema_name = candidate.schema_name
   AND keeper.table_name = candidate.table_name
   AND keeper.indexrelid <> candidate.indexrelid

   -- Aynı index method
   AND keeper.index_method = candidate.index_method

   -- Aynı key kolonları / operator class / collation / sort option
   AND keeper.indkey = candidate.indkey
   AND keeper.indclass = candidate.indclass
   AND keeper.indcollation = candidate.indcollation
   AND keeper.indoption = candidate.indoption

   -- INCLUDE kolon farkı varsa duplicate sayma
   AND keeper.indnkeyatts = candidate.indnkeyatts
   AND keeper.indnatts = candidate.indnatts

   -- Expression / partial index farkı varsa duplicate sayma
   AND keeper.index_exprs IS NOT DISTINCT FROM candidate.index_exprs
   AND keeper.index_predicate IS NOT DISTINCT FROM candidate.index_predicate

  WHERE candidate.indisprimary = false
    AND candidate.indisunique = false
    AND (
      keeper.indisprimary = true
      OR keeper.indisunique = true
    )
)
SELECT
  schema_name,
  table_name,
  covering_index_name,
  covering_index_type,
  duplicate_index_name,
  duplicate_index_size,
  covering_indexdef,
  duplicate_indexdef,
  suggested_drop_sql
FROM duplicates
ORDER BY
  table_name,
  duplicate_index_name;
