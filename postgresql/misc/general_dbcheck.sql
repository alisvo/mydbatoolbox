WITH db_size AS (
    -- 1. Get total database size
    SELECT 
        '1. Database Overview'::text AS category,
        'Total Database Size (' || current_database() || ')'::text AS metric,
        pg_size_pretty(pg_database_size(current_database()))::text AS value,
        1 AS cat_order,
        1 AS sub_order
),
connections AS (
    -- 2. Get connection counts grouped by state
    SELECT 
        '2. Connections'::text AS category,
        COALESCE(state, 'backend process') AS metric,
        count(*)::text AS value,
        2 AS cat_order,
        row_number() OVER (ORDER BY count(*) DESC) AS sub_order
    FROM pg_stat_activity
    WHERE datname = current_database()
    GROUP BY state
),
top_objects AS (
    -- 3. Get the top 5 largest objects (Tables, Indexes, TOAST, Mat Views)
    SELECT 
        '3. Top Largest Objects'::text AS category,
        (n.nspname || '.' || c.relname || ' [' || 
            CASE c.relkind WHEN 'r' THEN 'Table' WHEN 'i' THEN 'Index' WHEN 't' THEN 'TOAST' WHEN 'm' THEN 'Mat View' WHEN 'p' THEN 'Partition' ELSE 'Other' END || ']')::text AS metric,
        pg_size_pretty(pg_relation_size(c.oid))::text AS value,
        3 AS cat_order,
        row_number() OVER (ORDER BY pg_relation_size(c.oid) DESC) AS sub_order
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'i', 't', 'm', 'p') AND n.nspname NOT IN ('information_schema', 'pg_catalog')
),
cache_hit AS (
    -- 4. Cache hit ratio
    SELECT 
        '4. Performance Metrics'::text AS category,
        'Overall Cache Hit Ratio'::text AS metric,
        COALESCE(round(sum(blks_hit)*100.0 / NULLIF(sum(blks_hit+blks_read), 0), 2)::text || '%', 'N/A') AS value,
        4 AS cat_order,
        1 AS sub_order
    FROM pg_stat_database 
    WHERE datname = current_database()
),
long_queries_raw AS (
    -- 5a. Identify queries running longer than 5 minutes
    SELECT 
        substring(query FROM 1 FOR 50) || '...' AS metric,
        date_trunc('second', now() - query_start)::text AS value
    FROM pg_stat_activity
    WHERE state IN ('active', 'idle in transaction')
      AND now() - query_start > interval '5 minutes'
      AND datname = current_database()
      AND pid <> pg_backend_pid()
),
long_queries AS (
    -- 5b. Format long queries or return "None"
    SELECT 
        '5. Long Running Queries (>5m)'::text AS category,
        COALESCE(metric, 'No long-running queries') AS metric,
        COALESCE(value, 'N/A') AS value,
        5 AS cat_order,
        row_number() OVER () AS sub_order
    FROM (
        SELECT metric, value FROM long_queries_raw
        UNION ALL
        SELECT NULL, NULL WHERE NOT EXISTS (SELECT 1 FROM long_queries_raw)
    ) x
),
dead_tuples_raw AS (
    -- 6a. Get tables with the highest dead tuple counts (Bloat)
    SELECT relname::text AS metric, n_dead_tup::text || ' dead rows' AS value
    FROM pg_stat_user_tables 
    WHERE n_dead_tup > 0
    ORDER BY n_dead_tup DESC LIMIT 5
),
dead_tuples AS (
    -- 6b. Format dead tuples or return "None"
    SELECT 
        '6. Bloat/Dead Tuples (Top 5)'::text AS category,
        COALESCE(metric, 'No dead tuples found') AS metric,
        COALESCE(value, 'N/A') AS value,
        6 AS cat_order,
        row_number() OVER () AS sub_order
    FROM (
        SELECT metric, value FROM dead_tuples_raw
        UNION ALL
        SELECT NULL, NULL WHERE NOT EXISTS (SELECT 1 FROM dead_tuples_raw)
    ) x
),
tx_wraparound AS (
    -- 7. Check database age (Transaction ID Wraparound risk)
    SELECT 
        '7. TX Wraparound Risk'::text AS category,
        'Database Age (datfrozenxid)'::text AS metric,
        age(datfrozenxid)::text || ' txns' AS value,
        7 AS cat_order,
        1 AS sub_order
    FROM pg_database
    WHERE datname = current_database()
),
rep_stat_raw AS (
    -- 8a. Raw replication data
    SELECT 
        client_addr::text || ' (' || state || ')' AS metric,
        'Lag: ' || pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS value
    FROM pg_stat_replication
),
replication_status AS (
    -- 8b. Format replication data or return "No replicas"
    SELECT 
        '8. Replication Status'::text AS category,
        COALESCE(metric, 'No active read replicas detected') AS metric,
        COALESCE(value, 'N/A') AS value,
        8 AS cat_order,
        row_number() OVER () AS sub_order
    FROM (
        SELECT metric, value FROM rep_stat_raw
        UNION ALL
        SELECT NULL, NULL WHERE NOT EXISTS (SELECT 1 FROM rep_stat_raw)
    ) x
)
-- Combine everything and sort
SELECT category, metric, value 
FROM (
    SELECT * FROM db_size UNION ALL
    SELECT * FROM connections UNION ALL
    SELECT * FROM top_objects WHERE sub_order <= 5 UNION ALL
    SELECT * FROM cache_hit UNION ALL
    SELECT * FROM long_queries WHERE sub_order <= 5 UNION ALL
    SELECT * FROM dead_tuples UNION ALL
    SELECT * FROM tx_wraparound UNION ALL
    SELECT * FROM replication_status
) combined_results
ORDER BY cat_order, sub_order;
