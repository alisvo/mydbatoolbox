--Server Level check

SELECT
    datname,
    age(datfrozenxid) AS database_xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint AS autovacuum_freeze_max_age,
    ROUND(
        100.0 * age(datfrozenxid)::numeric
        / current_setting('autovacuum_freeze_max_age')::numeric,
        2
    ) AS database_freeze_age_pct
FROM pg_database
WHERE datallowconn
ORDER BY age(datfrozenxid) DESC;


-- DB Object Level Check
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relkind,
    age(c.relfrozenxid) AS xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint AS autovacuum_freeze_max_age,
    ROUND(
        100.0 * age(c.relfrozenxid)::numeric
        / current_setting('autovacuum_freeze_max_age')::numeric,
        2
    ) AS freeze_age_pct,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 50;


-- TOAST Level Check: en yasli toast tablolari ve ait olduklari ana tablolar
SELECT
    pn.nspname AS parent_schema,
    pc.relname AS parent_table,
    tn.nspname AS toast_schema,
    tc.relname AS toast_table,
    age(pc.relfrozenxid) AS parent_xid_age,
    age(tc.relfrozenxid) AS toast_xid_age,
    ROUND(
        100.0 * age(tc.relfrozenxid)::numeric
        / current_setting('autovacuum_freeze_max_age')::numeric,
        2
    ) AS toast_freeze_age_pct,
    pg_size_pretty(pg_total_relation_size(pc.oid)) AS parent_total_size,
    pg_size_pretty(pg_total_relation_size(tc.oid)) AS toast_total_size
FROM pg_class pc
JOIN pg_namespace pn ON pn.oid = pc.relnamespace
JOIN pg_class tc ON tc.oid = pc.reltoastrelid
JOIN pg_namespace tn ON tn.oid = tc.relnamespace
WHERE pc.relkind IN ('r', 'm')
  AND pn.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(tc.relfrozenxid) DESC
LIMIT 20;


