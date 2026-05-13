# Oracle Database: Fast Schema Statistics Guide

Gathering database statistics is crucial for the Oracle Optimizer to choose the most efficient execution plans for your queries. However, running statistics on large schemas (e.g., 40GB+) can take a long time if not done correctly.

This guide covers how to gather statistics **fast**, monitor progress, and manage the process safely without locking tables.

## 🚀 The "Fast" Method: Gathering Stats Efficiently

If you just run a basic gather stats command, Oracle scans every table using a single CPU thread. To make it much faster, use the following PL/SQL block:

```sql
BEGIN
    DBMS_STATS.GATHER_SCHEMA_STATS (
        ownname          => 'YOUR_SCHEMA_NAME',           -- Replace with your schema
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,  -- Fast NDV highly accurate sampling
        options          => 'GATHER AUTO',                -- ONLY processes tables with stale data
        degree           => 4,                            -- Parallel processing (uses 4 CPU threads)
        cascade          => DBMS_STATS.AUTO_CASCADE       -- Auto-gathers index stats if needed
    );
END;
/
```

### Why these parameters matter:

* **`options => 'GATHER AUTO'`**: This is the biggest time saver. It skips tables that haven't had significant data changes (usually < 10% change) and only analyzes "stale" tables.
* **`degree => 4`**: Enables parallel processing. Instead of 1 CPU thread, it splits the workload across multiple threads (set this based on your server's available cores).
* **`estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE`**: Uses an optimized Oracle algorithm to achieve near 100% accuracy in a fraction of the time of a full table scan.

## 📊 Checking Schema Size

Before running statistics, it is helpful to know exactly how large your schema is. This query groups all physical objects (tables, indexes, LOBs) by owner and displays the size in MB and GB.

*Requires `DBA` privileges:*

```sql
SELECT owner AS schema_name,
       ROUND(SUM(bytes) / 1024 / 1024, 2) AS size_in_mb,
       ROUND(SUM(bytes) / 1024 / 1024 / 1024, 2) AS size_in_gb
FROM dba_segments
WHERE owner NOT IN ('SYS', 'SYSTEM', 'SYSAUX', 'XDB', 'CTXSYS') -- Filters out standard system schemas
GROUP BY owner
ORDER BY size_in_gb DESC;
```

## ⏱️ Monitoring Statistics Progress

If a statistics job is taking a long time, you can check exactly which table or index it is currently scanning and how much time is left.

```sql
SELECT sid, 
       serial#, 
       opname, 
       target, 
       sofar, 
       totalwork, 
       ROUND((sofar/totalwork)*100, 2) AS percent_done,
       time_remaining AS seconds_left
FROM v$session_longops
WHERE time_remaining > 0
  AND opname LIKE '%Gather%';
```

## 🗂️ Running on Multiple Specific Schemas

If you need to run this on a specific list of schemas, you can use a PL/SQL loop.

```sql
BEGIN
   FOR s IN (SELECT column_value AS schema_name 
             FROM TABLE(sys.odcivarchar2list('HR', 'FINANCE', 'SALES'))) 
   LOOP
      DBMS_OUTPUT.PUT_LINE('Gathering stats for: ' || s.schema_name);
      
      DBMS_STATS.GATHER_SCHEMA_STATS (
         ownname          => s.schema_name,
         estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
         options          => 'GATHER AUTO',
         degree           => 4,
         cascade          => DBMS_STATS.AUTO_CASCADE
      );
   END LOOP;
END;
/
```

## 🛡️ Safety & FAQ

**Q: Does gathering statistics lock my tables?**  
**No.** Gathering statistics does not place exclusive locks on your data. Users and applications can continue to `SELECT`, `INSERT`, `UPDATE`, and `DELETE` normally. The only restriction is that you cannot perform structural changes (DDL like `ALTER TABLE` or `DROP TABLE`) on the specific table currently being analyzed.

**Q: Is it safe to cancel a running statistics job?**  
**Yes.** If it is taking too long or draining server CPU during peak hours, you can safely cancel or kill the job.
* It **will not** corrupt your data.
* Tables that finished will keep their new statistics.
* The table currently processing will safely roll back to its old statistics.
* You will just have a mix of fresh and stale statistics in your schema until you run it again.
