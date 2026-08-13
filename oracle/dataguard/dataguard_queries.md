# Oracle Data Guard Monitoring Queries

A collection of clean, reliable SQL queries for monitoring the synchronization and health of an Oracle Data Guard environment. These scripts eliminate the need for overly complex, legacy queries by utilizing modern Oracle Data Guard dynamic performance views.

## 1. Primary Node: The Sync Check

Run this query directly from your **Primary node**. It targets `v$archive_dest_status`, filtering out local destinations and inactive configurations to give you a clear, side-by-side view of what has been shipped versus what has been applied on your standbys.

```sql
SET LINESIZE 200
SET PAGESIZE 100
COL standby_host FORMAT A20
COL status FORMAT A10
COL database_mode FORMAT A15
COL recovery_mode FORMAT A25
COL gap_status FORMAT A15

SELECT 
    dest_id,
    destination AS standby_host,
    status,
    database_mode,
    recovery_mode,
    archived_thread# AS thread,
    archived_seq# AS last_shipped,
    applied_seq# AS last_applied,
    (archived_seq# - applied_seq#) AS sequence_lag,
    gap_status
FROM 
    v$archive_dest_status
WHERE 
    status <> 'INACTIVE' 
    AND type <> 'LOCAL'
ORDER BY 
    dest_id;
```

### How to interpret the results:
* **`last_shipped` vs. `last_applied`:** Your core metric. If these match, your standby is perfectly in sync.
* **`sequence_lag`:** Calculated difference between shipped and applied sequences. You want this at `0` (or `1` during an active log switch). If it steadily climbs, the standby is falling behind.
* **`status`:** Should be **VALID**. `ERROR` or `DEFERRED` indicates log transport has failed or been manually paused.
* **`gap_status`:** Should be **NO GAP**. `LOG SWITCH GAP` or `RESOLVABLE GAP` means logs are missing and FAL (Fetch Archive Log) is resolving it.
* **`recovery_mode`:** Look for **MANAGED RECOVERY**. `IDLE` means the standby is mounted but MRP (Managed Recovery Process) is not running.

---

## 2. Standby Node: Lag & State Check

Run this on your **Standby Node**. It combines `V$DATABASE` and `V$DATAGUARD_STATS` into a single, instant health check that gives you exact time metrics instead of sequence math.

```sql
SET LINESIZE 200
SET PAGESIZE 100
COL db_name FORMAT A10
COL database_role FORMAT A15
COL open_mode FORMAT A20
COL transport_lag FORMAT A20
COL apply_lag FORMAT A20
COL last_updated FORMAT A20

SELECT 
    d.name AS db_name,
    d.database_role,
    d.open_mode,
    MAX(CASE WHEN s.name = 'transport lag' THEN s.value END) AS transport_lag,
    MAX(CASE WHEN s.name = 'apply lag' THEN s.value END) AS apply_lag,
    MAX(CASE WHEN s.name = 'apply lag' THEN s.time_computed END) AS last_updated
FROM 
    v$database d,
    v$dataguard_stats s
GROUP BY 
    d.name, 
    d.database_role, 
    d.open_mode;
```

### How to interpret the results:
* **`open_mode`:** Confirms if you are in `MOUNTED` state (standard physical standby) or `READ ONLY WITH APPLY` (Active Data Guard).
* **`transport_lag` & `apply_lag`:** Provides the exact time difference (e.g., `+00 00:00:00`). If these are zero, you are perfectly synced.

---

## 3. Standby Node: MRP Process Check

If your standby apply lag is growing, you need to know what the recovery process is doing. Run this on the **Standby node** to check the status of MRP0 and RFS processes.

```sql
SET LINESIZE 150
COL process FORMAT A10
COL status FORMAT A15
COL group# FORMAT 999
COL thread# FORMAT 999
COL sequence# FORMAT 999999

SELECT 
    process, 
    status, 
    group#, 
    thread#, 
    sequence#, 
    block#, 
    blocks
FROM 
    v$managed_standby
WHERE 
    process IN ('MRP0', 'RFS')
ORDER BY 
    process;
```

### How to interpret the results:
* **`RFS` (Remote File Server):** Should show as `RECEIVING` or `IDLE`.
* **`MRP0` (Managed Recovery Process):** Should show as `APPLYING_LOG` or `WAIT_FOR_LOG`. If MRP is missing entirely, the apply process has crashed or been stopped.

---

## 4. Applied/Sent/General Controls



```sql
SELECT t.thread#,
       t.sequence#                      AS current_seq,      -- being written now
       s.last_sent,
       s.last_applied,
       t.sequence# - NVL(s.last_applied,0) AS logs_behind,
       TO_CHAR(s.last_apply_time,'dd/mm/yyyy hh24:mi:ss') AS son_uygulama_zamani
  FROM v$thread t
  LEFT JOIN (SELECT thread#,
                    MAX(sequence#) last_sent,
                    MAX(CASE WHEN applied IN ('YES','IN-MEMORY') THEN sequence# END) last_applied,
                    MAX(CASE WHEN applied IN ('YES','IN-MEMORY') THEN next_time END) last_apply_time
               FROM v$archived_log
              WHERE standby_dest = 'YES'
                AND resetlogs_id = (SELECT resetlogs_id FROM v$database_incarnation WHERE status='CURRENT')
              GROUP BY thread#) s
    ON s.thread# = t.thread#
 WHERE t.status = 'OPEN';
```
