# Data Guard Broker + Fast-Start Failover + Observer — Phase 1: Pre-Checks

This is **Phase 1** of a step-by-step guide to adding Data Guard Broker, Fast-Start Failover (FSFO) and an Observer to an **existing, manually managed** physical standby configuration, **online** (the primary stays open throughout).

Every check in this phase is **read-only**. The goal is to prove that the current Data Guard setup is healthy before the broker takes control of it. Never build a broker configuration on top of a broken standby.

| Phase | Content |
|---|---|
| 0 | Planning: protection mode, FSFO threshold, observer location, rollback plan |
| **1** | **Pre-checks (this document)** |
| 2 | Static `_DGMGRL` listener entries, `dg_broker_start` |
| 3 | Clear manual destinations, create and enable the broker configuration |
| 4 | Protection mode and broker properties, switchover test |
| 5 | Observer host: client, wallet, systemd service |
| 6 | FSFO properties, enable FSFO, start the observer |
| 7 | Testing, monitoring, handover |

---

## Example environment

All commands and expected outputs below use this environment. Replace the names with your own.

| Role | Host | DB_UNIQUE_NAME | Notes |
|---|---|---|---|
| Primary | `ol9dg1` | `ORCL_DG1` | Oracle 19c (19.31), CDB with one PDB |
| Physical standby | `ol9dg2` | `ORCL_DG2` | Real-time apply, standby redo logs |
| Observer (later) | `ol9obs` | — | Oracle software only, no database |

- `DB_NAME = ORCL`, `ORACLE_SID = ORCL` on both database hosts
- Transport: **ASYNC**, protection mode: **Maximum Performance**
- TNS aliases `ORCL_DG1` and `ORCL_DG2` exist on all three hosts
- No broker yet: `dg_broker_start = FALSE`, destinations set manually with `ALTER SYSTEM`

## How to run the checks

- Log in to each host as the **`oracle`** OS user with the Oracle environment loaded (`ORACLE_HOME`, `ORACLE_SID`, `PATH`).
- **"SQL"** means: `sqlplus / as sysdba` on that host. Start each session with:
  ```sql
  set lines 200 pages 100
  col name for a25
  col value for a60
  ```
- **"Shell"** means: the Linux shell, outside SQL*Plus.
- Record the results in the [summary checklist](#summary-checklist) at the end.

---

## Step 1 — Database roles and core settings

**Where:** primary **and** standby · **Tool:** SQL

```sql
select db_unique_name, database_role, open_mode, protection_mode,
       log_mode, force_logging, flashback_on
from v$database;
```

**Expected:**

| Column | Primary | Standby |
|---|---|---|
| `DATABASE_ROLE` | `PRIMARY` | `PHYSICAL STANDBY` |
| `OPEN_MODE` | `READ WRITE` | `MOUNTED` or `READ ONLY WITH APPLY` (Active Data Guard) |
| `PROTECTION_MODE` | as designed (here `MAXIMUM PERFORMANCE`) | same as primary |
| `LOG_MODE` | `ARCHIVELOG` | `ARCHIVELOG` |
| `FORCE_LOGGING` | `YES` | `YES` |
| `FLASHBACK_ON` | `YES` | `YES` |

**Red flags:**
- `FLASHBACK_ON = NO` on **either** side: FSFO still fails over, but the old primary cannot be **automatically reinstated**; you would have to rebuild it.
- `FORCE_LOGGING = NO`: `NOLOGGING` operations on the primary leave unrecoverable blocks on the standby.

---

## Step 2 — Redo transport health

**Where:** primary · **Tool:** SQL

```sql
col error for a40
select dest_id, status, error from v$archive_dest_status where dest_id = 2;
select dest_id, transmit_mode, affirm from v$archive_dest where dest_id = 2;
```

**Expected:** `STATUS = VALID`, `ERROR` empty, `TRANSMIT_MODE = ASYNCHRONOUS`, `AFFIRM = NO`.
(For SYNC: `PARALLELSYNC`/`SYNCHRONOUS` and `AFFIRM = YES`.)

**Red flags:** any value in `ERROR` (for example `ORA-12541`, `ORA-16191`) means redo is not being shipped. Fix it before continuing.

---

## Step 3 — Lag and gaps on the standby

**Where:** standby · **Tool:** SQL

```sql
col value for a20
col time_computed for a20
col datum_time for a20
select name, value, time_computed, datum_time
from v$dataguard_stats
where name in ('transport lag', 'apply lag');

select * from v$archive_gap;
```

**Expected:**
- Both lags `+00 00:00:00` or a few seconds.
- `DATUM_TIME` close to `TIME_COMPUTED`: the standby is actively receiving redo.
- `v$archive_gap`: **no rows selected**.

**Red flags:** lag in minutes, a gap, or `DATUM_TIME` far behind `TIME_COMPUTED`. In the last case the standby has stopped hearing from the primary, and the lag values are not trustworthy even if they show zero.

---

## Step 4 — Redo apply is running

**Where:** standby · **Tool:** SQL

```sql
col role for a26
col action for a14
select name, role, action, thread#, sequence#
from v$dataguard_process
where name like 'MRP%' or name like 'PR0%' or lower(name) like 'rfs%'
order by name;
```

**Expected:**
- `PR00` with `ACTION = APPLYING_LOG` and the primary's current sequence number.
- `MRP0` is present. In `v$dataguard_process` it is the coordinator and often shows `IDLE`; the work is done by the `PR0x` recovery slaves.
- `RFS` rows: the processes receiving redo from the primary.

**Red flags:** no `MRP0` row means redo apply is not running. In a configuration without the broker, apply does **not** restart by itself after a standby restart:
```sql
alter database recover managed standby database disconnect;
```

---

## Step 5 — Archived vs. applied sequence

**Where:** primary first, then standby · **Tool:** SQL

> **Real-time apply caveat:** the standby applies redo as it arrives, before the log is archived. The most recently archived log is shown as `APPLIED = 'IN-MEMORY'` (applied, not yet checkpointed), not `YES`. A query filtering only on `APPLIED = 'YES'` will always look **one sequence behind** even when the standby is fully in sync.
>
> **Incarnation caveat:** after a failover, flashback or `RESETLOGS`, sequence numbers restart in a new incarnation. Always filter on the current incarnation, or `max(sequence#)` may come from an old one.

**Primary:**
```sql
alter system archive log current;

select max(sequence#) as last_archived
from v$archived_log
where dest_id = 1
  and resetlogs_change# = (select resetlogs_change# from v$database_incarnation where status = 'CURRENT');
```
`ALTER SYSTEM ARCHIVE LOG CURRENT` forces a log switch so the comparison is up to date. It is harmless, even in production.

**Standby** (wait about 10 seconds):
```sql
select max(sequence#) as last_applied
from v$archived_log
where applied in ('YES', 'IN-MEMORY')
  and resetlogs_change# = (select resetlogs_change# from v$database_incarnation where status = 'CURRENT');
```

**Expected:** both numbers are **equal**.

**Optional, more precise check:** the log being applied right now should be the primary's current log.
```sql
-- primary
select sequence# from v$log where status = 'CURRENT';
-- standby
select name, action, sequence#, block# from v$dataguard_process where name like 'PR0%';
```

---

## Step 6 — Standby redo logs

**Where:** primary **and** standby · **Tool:** SQL

```sql
select thread#, count(*) as online_groups, max(bytes)/1024/1024 as mb from v$log group by thread#;
select thread#, count(*) as srl_groups,    max(bytes)/1024/1024 as mb from v$standby_log group by thread#;
```

**Expected:** per thread, **standby redo log groups = online redo log groups + 1**, all the **same size** as the online logs. Example: 3 online groups × 200 MB → 4 SRL groups × 200 MB.

**Why on the primary too?** After a role change the primary becomes the standby and needs them. FSFO and real-time apply depend on standby redo logs.

---

## Step 7 — Fast recovery area and flashback retention

**Where:** primary **and** standby · **Tool:** SQL

```sql
select name,
       space_limit/1024/1024/1024 as limit_gb,
       round(space_used/1024/1024/1024, 2) as used_gb,
       round(space_reclaimable/1024/1024/1024, 2) as reclaimable_gb
from v$recovery_file_dest;

show parameter db_flashback_retention_target
```

**Expected:** usage comfortably below the limit, and `db_flashback_retention_target` matching your design (for example `1440` minutes = 24 hours).

**Red flags:** a full FRA stops archiving and **hangs the primary**. Flashback logs live in the FRA too.

---

## Step 8 — Password files are compatible

**Where:** primary **and** standby · **Tool:** SQL + Shell

> **Don't use `md5sum`.** Byte-identical password files are not required, and they are often not identical: `RMAN DUPLICATE ... FOR STANDBY` copies the password file and rewrites its header, so the checksums differ even though the credentials are the same. What matters is that both sides can authenticate to each other as `SYS`.

**a) Same users and privileges on both sides** (SQL, primary and standby):
```sql
col username for a12
select username, sysdba, sysoper, sysdg, sysbackup, account_status from v$pwfile_users;
```

**b) Real login in both directions** (Shell): on the primary connect to the standby, and on the standby connect to the primary.
```bash
# on ol9dg1
echo "select db_unique_name from v\$database;" | sqlplus -s -L sys/<password>@ORCL_DG2 as sysdba
# on ol9dg2
echo "select db_unique_name from v\$database;" | sqlplus -s -L sys/<password>@ORCL_DG1 as sysdba
```

**c) Transport authenticates too:** Step 2 shows `STATUS = VALID` with no error. A password file mismatch would show up there as `ORA-16191`.

**Expected:** identical rows in (a), both logins succeed in (b), no error in (c).

**Note:** since 12.2, changing the SYS password on the primary with `ALTER USER SYS IDENTIFIED BY ...` is propagated to the standby's password file through redo. If you recreate the file with `orapwd`, copy it to the standby manually.

---

## Step 9 — Network: every direction, including the observer host

**Where:** primary, standby **and** observer host · **Tool:** Shell

On each of the three hosts:
```bash
tnsping ORCL_DG1 | tail -1
tnsping ORCL_DG2 | tail -1
echo "select db_unique_name, database_role from v\$database;" | sqlplus -s -L sys/<password>@ORCL_DG1 as sysdba
echo "select db_unique_name, database_role from v\$database;" | sqlplus -s -L sys/<password>@ORCL_DG2 as sysdba
```

**Expected:** `OK (n msec)` for both pings, and both queries return a row (`ORCL_DG1 PRIMARY`, `ORCL_DG2 PHYSICAL STANDBY`).

**Why test from the observer host?** The observer must connect to **both** databases as SYS (or SYSDG). `tnsping` only proves the listener is reachable; the SQL*Plus login proves name resolution, listener, service and authentication end to end.

---

## Step 10 — Listener services

**Where:** primary **and** standby · **Tool:** Shell

```bash
lsnrctl status | grep Service
```

**Expected (before Phase 2):** the database service (`ORCL_DG1` / `ORCL_DG2`) is registered.

**Finding to record:** look for `ORCL_DG1_DGMGRL` / `ORCL_DG2_DGMGRL`. Without Oracle Clusterware, the broker needs these **static** entries to restart instances during switchover and reinstatement. If they are missing, they are added in Phase 2.

---

## Step 11 — Current Data Guard parameters (rollback reference)

**Where:** primary **and** standby · **Tool:** SQL + Shell

```sql
show parameter dg_broker_start
show parameter dg_broker_config_file
show parameter log_archive_config
show parameter log_archive_dest_2
show parameter log_archive_dest_state_2
show parameter fal_server
show parameter standby_file_management
```
```bash
ls -l $ORACLE_HOME/dbs/dr*
```

**Expected (manual configuration):**
- `dg_broker_start = FALSE`
- `log_archive_dest_2` set manually on both sides (here `ASYNC NOAFFIRM ... valid_for=(online_logfiles,primary_role)`)
- No `dr1*.dat` / `dr2*.dat` files (`No such file or directory`)

**Action:** **save these values.** They are your rollback reference if the broker is removed again (`REMOVE CONFIGURATION PRESERVE DESTINATIONS`, then restore). The manually set `log_archive_dest_2` is also what will cause `ORA-16698` in Phase 3 if it is not cleared before `ADD DATABASE`.

---

## Step 12 — RMAN archived log deletion policy

**Where:** primary **and** standby · **Tool:** RMAN

```bash
rman target /
```
```
show archivelog deletion policy;
exit
```

**Typical result:** `CONFIGURE ARCHIVELOG DELETION POLICY TO NONE; # default`

**Recommendation:** `CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;` so RMAN never deletes archived logs the standby still needs. This matters in Phase 3, when redo shipping pauses briefly and archived logs accumulate.
**In Phase 1, record it only; don't change it.**

---

## Step 13 — Time synchronization

**Where:** primary, standby **and** observer host · **Tool:** Shell

```bash
date; chronyc tracking | grep -E "System time|Leap"
```

**Expected:** the same time on all hosts, `Leap status : Normal`, offset in milliseconds.

**Why:** FSFO decisions are based on seconds (`FastStartFailoverThreshold`), and correlating the observer log with the alert logs during an incident is impossible if the clocks drift.

---

## Step 14 — Recent errors in the alert log

**Where:** primary **and** standby · **Tool:** SQL + Shell

Find the trace directory:
```sql
select value from v$diag_info where name = 'Diag Trace';
```
Then, in the shell (replace the path with the value above):
```bash
grep -nE "ORA-|TNS-" /u01/app/oracle/diag/rdbms/orcl_dg1/ORCL/trace/alert_ORCL.log | tail -20
```

**Expected:** no **recurring or recent** errors. Old entries from planned maintenance (restarts, earlier role changes) are fine; what matters is that nothing is still happening.

---

## Summary checklist

| # | Check | Pass criteria | Result |
|---|---|---|---|
| 1 | Roles and core settings | Correct roles, `ARCHIVELOG`, force logging and flashback `YES` on both | ☐ |
| 2 | Redo transport | `dest_2 VALID`, no error, expected transmit mode | ☐ |
| 3 | Lag and gaps | Lag ≈ 0, `DATUM_TIME` current, no gap | ☐ |
| 4 | Redo apply | `PR00 APPLYING_LOG`, `MRP0` present | ☐ |
| 5 | Sequences | Archived = applied (current incarnation, `YES` + `IN-MEMORY`) | ☐ |
| 6 | Standby redo logs | Online + 1 per thread, same size, on both sides | ☐ |
| 7 | FRA / flashback | Enough free space, retention as designed | ☐ |
| 8 | Password files | Same `v$pwfile_users`, SYS login both ways | ☐ |
| 9 | Network | All three hosts reach both databases as SYS | ☐ |
| 10 | Listener | DB service registered; `_DGMGRL` status recorded | ☐ |
| 11 | Parameters | Current values saved for rollback | ☐ |
| 12 | RMAN policy | Recorded (recommended: `APPLIED ON ALL STANDBY`) | ☐ |
| 13 | Time sync | Clocks in sync on all three hosts | ☐ |
| 14 | Alert logs | No recurring errors | ☐ |

**Go / No-Go:** proceed to Phase 2 only if checks 1–9 pass. Items 10–12 are findings that later phases address; items 13–14 must not show active problems.

---

*Next: [Phases 2–6 — Setup](broker_fsfo_02_setup.md)*
