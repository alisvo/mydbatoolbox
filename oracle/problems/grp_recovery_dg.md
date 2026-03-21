# Oracle 19c Data Guard — Automatic Standby Flashback Scenario

> **Feature:** Oracle 19c Automatic Flashback of Standby Database  
> **Environment:** Oracle Linux 8 | Oracle 19.28.0.0.0 | Physical Standby | No Broker  
> **Primary:** oracle1 (PRIDB) | **Standby:** oracle2 (PRIDBSTBY)

---

## Overview

In Oracle 19c, when a **Guaranteed Restore Point (GRP)** is created on the primary database, it is **automatically replicated to the standby** as a *Replicated Restore Point* (suffixed with `_PRIMARY`).

When the primary is flashed back to a GRP and opened with `RESETLOGS`, the **MRP process on the standby automatically detects the new incarnation and flashes the standby back to the same point in time** — with zero manual intervention required on the standby.

This is a major improvement over pre-19c behaviour where you had to:
1. Obtain the RESETLOGS SCN from the primary
2. Manually issue `FLASHBACK DATABASE` on the standby
3. Re-enable managed recovery

---

## How It Works (Flow)

```
PRIMARY                                    STANDBY
───────                                    ───────
CREATE RESTORE POINT grp          ──▶      GRP replicated automatically
                                           (name suffixed with _PRIMARY)

[human error occurs]

SHUTDOWN IMMEDIATE
STARTUP MOUNT
FLASHBACK DATABASE TO grp
ALTER DATABASE OPEN RESETLOGS     ──▶      RFS detects new incarnation
                                           MRP detects orphaned datafiles
                                           MRP performs automatic flashback
                                           Flashback Media Recovery Complete
                                           MRP resumes Real Time Apply
```

---

## Prerequisites

### 1. Verify Archivelog Mode (Both Nodes)

```bash
sqlplus -s / as sysdba << 'EOF'
SELECT log_mode FROM v$database;
EOF
```

Expected: `ARCHIVELOG`

### 2. Verify and Configure Fast Recovery Area (Both Nodes)

FRA must be configured and sized large enough to hold flashback logs for the duration you want to flash back.

```bash
# Check current FRA config
sqlplus -s / as sysdba << 'EOF'
SHOW PARAMETER db_recovery_file_dest
EOF
```

If FRA is not configured:

```bash
# On BOTH nodes — set FRA location and size
sqlplus / as sysdba << 'EOF'
ALTER SYSTEM SET db_recovery_file_dest='/u01/app/oracle/fast_recovery_area' SCOPE=BOTH;
ALTER SYSTEM SET db_recovery_file_dest_size=30G SCOPE=BOTH;
EOF
```

> ⚠️ Always set the same FRA size on both nodes. The standby needs space for flashback logs, archive logs, and the automatic flashback operation itself.

### 3. Enable Flashback on Primary

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE FLASHBACK ON;
ALTER DATABASE OPEN;
SELECT flashback_on FROM v$database;
EOF
```

Expected: `FLASHBACK_ON = YES`

### 4. Verify Flashback Auto-Enabled on Standby

In Oracle 19c, enabling flashback on the primary automatically propagates to the standby via MRP. Verify:

```bash
# On oracle2
sqlplus -s / as sysdba << 'EOF'
SELECT flashback_on FROM v$database;
EOF
```

Expected: `FLASHBACK_ON = YES`

> ⚠️ If it shows `NO`, enable it manually on the standby as well:
> ```sql
> SHUTDOWN IMMEDIATE;
> STARTUP MOUNT;
> ALTER DATABASE FLASHBACK ON;
> ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
> ```

### 5. Drop Standby to MOUNT Mode

The automatic standby flashback feature requires the standby to be in **MOUNT mode with MRP running**. If your standby is in Active Data Guard (READ ONLY WITH APPLY), drop it to MOUNT first:

```bash
# On oracle2
sqlplus / as sysdba << 'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
SELECT open_mode, database_role FROM v$database;
SELECT process, status, sequence# FROM v$managed_standby WHERE process='MRP0';
EOF
```

Expected: `OPEN_MODE = MOUNTED`, `MRP0 STATUS = APPLYING_LOG`

### 6. Final Pre-Check (Both Nodes)

```bash
# On oracle1
sqlplus -s / as sysdba << 'EOF'
SELECT flashback_on, log_mode, open_mode, database_role FROM v$database;
EOF
```

```bash
# On oracle2
sqlplus -s / as sysdba << 'EOF'
SELECT flashback_on, log_mode, open_mode, database_role FROM v$database;
SELECT process, status, sequence# FROM v$managed_standby WHERE process='MRP0';
EOF
```

Expected state before proceeding:

| | oracle1 | oracle2 |
|---|---|---|
| FLASHBACK_ON | YES | YES |
| LOG_MODE | ARCHIVELOG | ARCHIVELOG |
| OPEN_MODE | READ WRITE | MOUNTED |
| MRP0 | — | APPLYING_LOG |

---

## Step-by-Step Scenario

### Step 1 — Create Test Objects on Primary (Clean State)

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'

-- Create test user
CREATE USER testdg IDENTIFIED BY Oracle123
  DEFAULT TABLESPACE USERS
  QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO testdg;

-- Create clean tables
CREATE TABLE testdg.employees (
  emp_id   NUMBER PRIMARY KEY,
  emp_name VARCHAR2(100),
  salary   NUMBER,
  dept     VARCHAR2(50)
);

CREATE TABLE testdg.departments (
  dept_id   NUMBER PRIMARY KEY,
  dept_name VARCHAR2(100),
  location  VARCHAR2(100)
);

-- Insert clean data
INSERT INTO testdg.departments VALUES (1, 'Engineering', 'Istanbul');
INSERT INTO testdg.departments VALUES (2, 'Finance',     'Ankara');
INSERT INTO testdg.departments VALUES (3, 'HR',          'Izmir');

INSERT INTO testdg.employees VALUES (1, 'Ahmet Yilmaz', 15000, 'Engineering');
INSERT INTO testdg.employees VALUES (2, 'Ayse Kaya',    12000, 'Finance');
INSERT INTO testdg.employees VALUES (3, 'Mehmet Demir', 11000, 'HR');
COMMIT;

-- Verify clean state
SELECT COUNT(*) AS emp_count  FROM testdg.employees;
SELECT COUNT(*) AS dept_count FROM testdg.departments;
SELECT table_name FROM dba_tables WHERE owner='TESTDG';
EOF
```

Expected: 3 rows in each table, 2 tables total.

### Step 2 — Create the Guaranteed Restore Point (Primary)

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
CREATE RESTORE POINT PRIDB_GRP GUARANTEE FLASHBACK DATABASE;

-- Verify on primary
SELECT name, guarantee_flashback_database, replicated FROM v$restore_point;
EOF
```

Expected:

| NAME | GUA | REP |
|---|---|---|
| PRIDB_GRP | YES | NO |

### Step 3 — Verify GRP Replicated to Standby

```bash
# On oracle2
sqlplus -s / as sysdba << 'EOF'
SELECT name, guarantee_flashback_database, replicated FROM v$restore_point;
EOF
```

Expected:

| NAME | GUA | REP |
|---|---|---|
| PRIDB_GRP_PRIMARY | NO | YES |

> ℹ️ The replicated restore point on the standby is NOT a Guaranteed Restore Point itself (GUA=NO) — it is a regular restore point that marks the same SCN. The guarantee is maintained by the primary's GRP.

### Step 4 — Simulate Human Error (Destructive Changes)

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'

-- Create large junk table (~few GB of redo)
CREATE TABLE testdg.big_junk AS
SELECT a.object_id, a.object_name, a.object_type,
       b.object_id AS b_id, b.object_name AS b_name,
       DBMS_RANDOM.STRING('A', 500) AS junk_data
FROM dba_objects a CROSS JOIN dba_objects b
WHERE ROWNUM <= 5000000;

SELECT COUNT(*) AS junk_rows FROM testdg.big_junk;

-- Destructive operations
DROP TABLE testdg.employees;
DROP TABLE testdg.departments;

-- Create wrong/garbage table
CREATE TABLE testdg.wrong_table AS SELECT * FROM dba_objects WHERE 1=2;
INSERT INTO testdg.wrong_table SELECT * FROM dba_objects;
COMMIT;

-- Confirm damage
SELECT table_name FROM dba_tables WHERE owner='TESTDG';
EOF
```

Expected: only `BIG_JUNK` and `WRONG_TABLE` visible — `EMPLOYEES` and `DEPARTMENTS` are gone.

### Step 5 — Check FRA Usage Before Flashback

```bash
# On oracle1
sqlplus -s / as sysdba << 'EOF'
SELECT space_used/1024/1024/1024    AS used_gb,
       space_limit/1024/1024/1024   AS limit_gb,
       space_reclaimable/1024/1024/1024 AS reclaimable_gb
FROM v$recovery_file_dest;
EOF
```

### Step 6 — Flashback Primary to GRP

Note the start time to measure how fast the operation completes.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
SELECT TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS') AS flashback_start FROM dual;

SHUTDOWN IMMEDIATE;
STARTUP MOUNT;

FLASHBACK DATABASE TO RESTORE POINT PRIDB_GRP;

ALTER DATABASE OPEN RESETLOGS;

SELECT TO_CHAR(SYSDATE,'DD-MON-YYYY HH24:MI:SS') AS flashback_end FROM dual;

-- Verify tables restored
SELECT COUNT(*) AS emp_count  FROM testdg.employees;
SELECT COUNT(*) AS dept_count FROM testdg.departments;
SELECT table_name FROM dba_tables WHERE owner='TESTDG';
EOF
```

Expected: `EMPLOYEES` and `DEPARTMENTS` back with 3 rows each. `BIG_JUNK` and `WRONG_TABLE` gone.

### Step 7 — Watch Standby Auto-Flashback

Tail the standby alert log in real time to observe the automatic flashback:

```bash
# On oracle2 — in a dedicated terminal
tail -f /u01/app/oracle/diag/rdbms/pridbstby/PRIDBSTBY/trace/alert_PRIDBSTBY.log
```

Key lines to look for in the alert log:

```
rfs: New archival redo branch                          ← detects RESETLOGS
Incarnation entry added for Branch(resetlogs_id): ... 
MRP0: Detected orphaned datafiles!                     ← expected, triggers flashback
MRP0: Recovery coordinator performing automatic flashback of database to SCN:...
Flashback Restore Start
Flashback Restore Complete
Flashback Media Recovery Start
Flashback Media Recovery Complete                      ← standby fully flashed back
PR00: Managed Standby Recovery starting Real Time Apply ← resumes apply
```

### Step 8 — Verify Standby Auto-Flashback Complete

```bash
# On oracle2
sqlplus -s / as sysdba << 'EOF'
SELECT process, status, sequence# FROM v$managed_standby WHERE process='MRP0';
SELECT open_mode, database_role FROM v$database;
EOF
```

Expected: `MRP0 = APPLYING_LOG`, `OPEN_MODE = MOUNTED`

### Step 9 — Verify Data on Standby

```bash
# On oracle2
sqlplus -s / as sysdba << 'EOF'
SELECT COUNT(*) AS emp_count  FROM testdg.employees;
SELECT COUNT(*) AS dept_count FROM testdg.departments;
SELECT table_name FROM dba_tables WHERE owner='TESTDG';
EOF
```

Expected: Same clean state as primary — 3 rows each, only `EMPLOYEES` and `DEPARTMENTS`.

### Step 10 — Re-open Standby to Active Data Guard (Optional)

If you want the standby back in READ ONLY WITH APPLY mode:

```bash
# On oracle2
sqlplus / as sysdba << 'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE OPEN READ ONLY;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
SELECT open_mode, database_role FROM v$database;
SELECT process, status, sequence# FROM v$managed_standby WHERE process='MRP0';
EOF
```

> ✅ No need to SHUTDOWN/STARTUP — the database is already mounted, so `ALTER DATABASE OPEN READ ONLY` is sufficient.

---

## Cleanup — Drop the GRP

> ⚠️ **Important:** Guaranteed Restore Points prevent flashback log space from being reclaimed. Always drop the GRP when it is no longer needed to allow the FRA to free up space.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
DROP RESTORE POINT PRIDB_GRP;

-- Verify dropped on primary
SELECT name FROM v$restore_point;
EOF
```

```bash
# On oracle2 — replicated restore point is automatically dropped
sqlplus -s / as sysdba << 'EOF'
SELECT name FROM v$restore_point;
EOF
```

Both queries should return no rows.

---

## Verification Queries Reference

### Check Restore Points

```sql
-- On primary
SELECT name, scn, time, guarantee_flashback_database, replicated
FROM v$restore_point;

-- On standby
SELECT name, scn, time, guarantee_flashback_database, replicated
FROM v$restore_point;
```

### Check Flashback Status

```sql
SELECT flashback_on, oldest_flashback_scn, oldest_flashback_time
FROM v$database;
```

### Check FRA Usage

```sql
SELECT name,
       space_limit/1024/1024/1024     AS limit_gb,
       space_used/1024/1024/1024      AS used_gb,
       space_reclaimable/1024/1024/1024 AS reclaimable_gb,
       number_of_files
FROM v$recovery_file_dest;
```

### Check FRA File Breakdown

```sql
SELECT file_type,
       percent_space_used,
       percent_space_reclaimable,
       number_of_files
FROM v$flash_recovery_area_usage;
```

### Check MRP Status

```sql
SELECT process, status, thread#, sequence#, block#
FROM v$managed_standby
WHERE process IN ('MRP0','RFS');
```

### Check Current Incarnation

```sql
SELECT incarnation#, resetlogs_time, status
FROM v$database_incarnation
ORDER BY incarnation#;
```

---

## Observed Performance

In a test environment (Oracle 19.28, ~5GB of redo generated by 5 million row table creation + DDL drops):

| Event | Time |
|---|---|
| Primary flashback + OPEN RESETLOGS | ~2 minutes |
| Standby detects new incarnation | immediate |
| MRP triggers automatic flashback | ~20 seconds after RESETLOGS |
| Standby flashback complete | ~21 seconds total |
| MRP resumes Real Time Apply | immediate after flashback |

---

## Key Notes and Gotchas

| Topic | Detail |
|---|---|
| Standby must be in MOUNT | Automatic flashback only works when standby is in MOUNT mode with MRP running. If in Active DG (READ ONLY WITH APPLY), cancel apply, shutdown, startup mount, restart MRP before doing the primary flashback |
| Replicated GRP name | The standby GRP is always named `<GRP_NAME>_PRIMARY`. It is a regular restore point (not guaranteed) on the standby |
| GRP blocks space reclaim | A GRP on the primary prevents flashback log space from being freed. Drop it as soon as it is no longer needed |
| FRA size both nodes | Always size FRA the same on both nodes. The standby needs sufficient space for its own flashback logs during the automatic flashback operation |
| No Broker required | This feature works without Data Guard Broker — MRP handles the automatic flashback natively |
| ORA-19909 / orphaned datafiles | These errors in the standby alert log during the auto-flashback are **expected and normal** — they are what triggers MRP to initiate the automatic flashback |
| OPEN RESETLOGS | After flashback, the primary must be opened with `RESETLOGS` — this creates a new incarnation which signals the standby to auto-flashback |
| Re-enabling Active DG | After the standby completes auto-flashback, if you were using Active Data Guard simply run `ALTER DATABASE OPEN READ ONLY` followed by `ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION` — no restart needed |
