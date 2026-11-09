# Oracle Data Guard Monitoring Queries

A collection of clean, reliable SQL queries for monitoring the synchronization and health of an Oracle Data Guard environment. These scripts eliminate the need for overly complex, legacy queries by utilizing modern Oracle Data Guard dynamic performance views.

> **Tested on:** Oracle Database 19c (19.31), single-instance physical standby, real-time apply, ASYNC and SYNC transport.

> **Read this first: real-time apply and sequence math**
> With standby redo logs and real-time apply (the default in modern setups), the standby applies redo **as it arrives**, before the log is archived. As a result:
> * The log being applied right now is the primary's **CURRENT** log, which is not archived yet.
> * The most recently archived log is usually shown as `APPLIED = 'IN-MEMORY'` (applied, but not yet checkpointed to the datafiles), not `YES`.
> * `V$ARCHIVE_DEST_STATUS.APPLIED_SEQ#` lags one sequence behind `ARCHIVED_SEQ#` even when the standby is fully in sync.
>
> Sequence numbers are therefore good for **detecting gaps**, but for **"how far behind am I?"**, trust the time-based metrics in Query 2 (`V$DATAGUARD_STATS`).

## 1. Primary Node: The Sync Check

Run this query directly from your **Primary node**. It targets `v$archive_dest_status`, filtering out local destinations and inactive configurations to give you a clear, side-by-side view of what has been shipped versus what has been applied on your standbys.

```sql
SET LINESIZE 250
SET PAGESIZE 100
COL standby_db FORMAT A15
COL status FORMAT A10
COL database_mode FORMAT A15
COL recovery_mode FORMAT A35
COL gap_status FORMAT A25
COL error FORMAT A40

SELECT
    dest_id,
    db_unique_name AS standby_db,
    status,
    database_mode,
    recovery_mode,
    archived_thread# AS thread,
    archived_seq# AS last_archived,
    applied_seq# AS last_applied,
    (archived_seq# - applied_seq#) AS seq_diff,
    gap_status,
    error
FROM
    v$archive_dest_status
WHERE
    status <> 'INACTIVE'
    AND type <> 'LOCAL'
ORDER BY
    dest_id;
```

### How to interpret the results:
* **`seq_diff`:** With real-time apply, **`1` is the normal, fully in-sync value** (see the note at the top). It is only a concern if it **keeps growing** over several log switches.
* **`status`:** Should be **VALID**. `ERROR` means log transport is failing (the reason is in the **`error`** column); `DEFERRED` means the destination was manually disabled.
* **`gap_status`:**
  * `NO GAP`: healthy.
  * `LOG SWITCH GAP`: a log switch just happened and the archive is still being shipped. Usually transient.
  * `RESOLVABLE GAP`: logs are missing on the standby, but FAL (Fetch Archive Log) can fetch them from the primary.
  * `UNRESOLVABLE GAP` / `LOCALLY UNRESOLVABLE GAP`: **critical**. The missing logs are no longer available on the primary. Restore them from backup or roll the standby forward with an incremental backup.
* **`recovery_mode`:**
  * `MANAGED REAL TIME APPLY`: healthy (real-time apply).
  * `MANAGED REAL TIME APPLY WITH QUERY`: healthy, and the standby is open read-only (Active Data Guard).
  * `MANAGED`: redo apply is running, but only after logs are archived (no real-time apply, so expect more lag).
  * `IDLE`: the MRP (Managed Recovery Process) is **not running**, so no redo is being applied.
* **RAC primaries:** this view shows one thread per destination. Use Query 4 for a per-thread breakdown.

---

## 2. Standby Node: Lag & State Check

Run this on your **Standby node**. It combines `V$DATABASE` and `V$DATAGUARD_STATS` into a single, instant health check that gives you exact time metrics instead of sequence math.

```sql
SET LINESIZE 200
SET PAGESIZE 100
COL db_unique_name FORMAT A15
COL database_role FORMAT A16
COL open_mode FORMAT A20
COL transport_lag FORMAT A15
COL apply_lag FORMAT A15
COL time_computed FORMAT A20
COL datum_time FORMAT A20

SELECT
    d.db_unique_name,
    d.database_role,
    d.open_mode,
    MAX(CASE WHEN s.name = 'transport lag' THEN s.value END)         AS transport_lag,
    MAX(CASE WHEN s.name = 'apply lag'     THEN s.value END)         AS apply_lag,
    MAX(CASE WHEN s.name = 'apply lag'     THEN s.time_computed END) AS time_computed,
    MAX(CASE WHEN s.name = 'apply lag'     THEN s.datum_time END)    AS datum_time
FROM
    v$database d
    CROSS JOIN v$dataguard_stats s
WHERE
    s.name IN ('transport lag', 'apply lag')
GROUP BY
    d.db_unique_name,
    d.database_role,
    d.open_mode;
```

### How to interpret the results:
* **`open_mode`:** `MOUNTED` is a standard physical standby; `READ ONLY WITH APPLY` is Active Data Guard (separately licensed). `READ ONLY` **without** "WITH APPLY" means the standby is open but redo apply is **not** running.
* **`transport_lag` & `apply_lag`:** The exact time difference (for example `+00 00:00:00`). If both are near zero, you are in sync.
* **`time_computed` vs. `datum_time`:** `time_computed` is when the standby calculated the metric; `datum_time` is when it last received data from the primary. **If `datum_time` falls far behind `time_computed`, the standby has stopped hearing from the primary** (network, transport, or primary problem), and the lag values above are not trustworthy, even if they show zero. An empty lag value means the metric cannot be computed (for example, after a restart or with transport stopped).

---

## 3. Standby Node: MRP Process Check

If your standby apply lag is growing, you need to know what the recovery process is doing. Run this on the **Standby node** to check the status of MRP0 and RFS processes.

```sql
SET LINESIZE 150
COL process FORMAT A10
COL status FORMAT A15
COL group# FORMAT A6
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
* **`MRP0` (Managed Recovery Process):**
  * `APPLYING_LOG`: healthy, redo is being applied.
  * `WAIT_FOR_LOG`: waiting for the next redo to arrive (normal when the primary is quiet).
  * `WAIT_FOR_GAP`: **apply is blocked by a missing archive log**. Check `gap_status` in Query 1 and `V$ARCHIVE_GAP`.
  * Missing entirely: the apply process has crashed or was never started (for example after a standby restart without the broker). Start it with `ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT;`.
* **`group#`** is a character column (`N/A` for processes not tied to a log group).

### Modern alternative (12.2+): `V$DATAGUARD_PROCESS`
`V$MANAGED_STANDBY` still works in 19c but has been deprecated since 12.2. Its replacement shows the apply slaves too:

```sql
SET LINESIZE 150
COL name FORMAT A8
COL role FORMAT A26
COL action FORMAT A14

SELECT name, role, action, thread#, sequence#, block#
FROM   v$dataguard_process
WHERE  name LIKE 'MRP%' OR name LIKE 'PR0%' OR LOWER(name) LIKE 'rfs%'
ORDER  BY name;
```
Note: here `MRP0` is the coordinator and often shows `IDLE`. The rows that do the work are the recovery slaves (`PR00`, `PR01`, …): `PR00` with `ACTION = APPLYING_LOG` and the primary's current sequence is the healthy state.

---

## 4. Primary Node: Shipped vs. Applied per Destination and Thread

Run this on the **Primary node**. It reads the primary's archive log history for each remote destination in the current incarnation, so it works per thread (RAC) and per standby. On a standby, it returns no rows on purpose: the standby's `V$ARCHIVED_LOG` can contain stale `STANDBY_DEST` rows from a period when it was itself the primary (after a failover or switchover), which would produce misleading numbers.

```sql
SET LINESIZE 200
SET PAGESIZE 100
COL standby_db FORMAT A15
COL last_applied_redo_time FORMAT A22

SELECT d.dest_id,
       d.db_unique_name                       AS standby_db,
       a.thread#,
       t.sequence#                            AS current_seq,    -- being written now (not archived yet)
       a.last_sent,
       a.last_applied,
       a.last_sent - NVL(a.last_applied, 0)   AS archived_not_applied,
       TO_CHAR(a.last_applied_redo_time, 'YYYY-MM-DD HH24:MI:SS') AS last_applied_redo_time
  FROM (SELECT dest_id,
               thread#,
               MAX(sequence#) AS last_sent,
               MAX(CASE WHEN applied IN ('YES', 'IN-MEMORY') THEN sequence# END) AS last_applied,
               MAX(CASE WHEN applied IN ('YES', 'IN-MEMORY') THEN next_time END) AS last_applied_redo_time
          FROM v$archived_log
         WHERE standby_dest = 'YES'
           AND resetlogs_id = (SELECT resetlogs_id FROM v$database_incarnation WHERE status = 'CURRENT')
         GROUP BY dest_id, thread#) a
  JOIN v$archive_dest d ON d.dest_id = a.dest_id
  JOIN v$thread t       ON t.thread# = a.thread#
 WHERE (SELECT database_role FROM v$database) = 'PRIMARY'
 ORDER BY d.dest_id, a.thread#;
```

### How to interpret the results:
* **`archived_not_applied`:** Archived logs that were shipped but are not applied yet. **`0` means in sync.** If it keeps growing, apply is falling behind.
* **`current_seq`:** The online log the primary is writing right now. With real-time apply it is normal for this to be `last_sent + 1`: that log is being shipped and applied live, it simply isn't archived yet. Do **not** use `current_seq - last_applied` as a lag metric, because it is always at least `1` when fully in sync.
* **`last_applied_redo_time`:** The timestamp of the **redo** contained in the last applied log (`NEXT_TIME`), not the wall-clock time when it was applied. For precise time lag, use Query 2.
* **`resetlogs_id` filter:** After a failover, flashback or `RESETLOGS`, sequence numbers restart in a new incarnation. Without this filter, old incarnations would produce misleading maximums.
