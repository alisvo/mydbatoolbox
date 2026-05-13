I am so glad to hear that fixed the issue for you! Data Guard Broker is fantastic, but it definitely demands that you play by its rules. 

Here is the fully revised, ready-to-save runbook for the **Oracle 19c Automatic Standby Flashback** scenario, specifically rewritten for an environment where **Data Guard Broker is enabled** and the standby starts in Active Data Guard mode.

---

# Oracle 19c Data Guard — Automatic Standby Flashback Scenario (Broker Enabled)

> **Feature:** Oracle 19c Automatic Flashback of Standby Database
> **Environment:** Oracle Linux 8 | Oracle 19.28.0.0.0 | Physical Standby | **DG Broker Enabled**
> **Primary:** oracle1 (PRIDB) | **Standby:** oracle2 (PRIDBSTBY)

---

## Overview

In Oracle 19c, when a **Guaranteed Restore Point (GRP)** is created on the primary database, it is automatically replicated to the standby. When the primary is flashed back to that GRP and opened with `RESETLOGS`, the standby's MRP process detects the new incarnation and automatically flashes the standby back to match.

**Crucial Broker Rule:** When Data Guard Broker is enabled, you **must not** use SQL*Plus to manage the MRP process (e.g., `ALTER DATABASE RECOVER MANAGED STANDBY...`). Doing so will confuse the Broker. You must use `dgmgrl` to manage apply states, and SQL*Plus only for database states (`SHUTDOWN`, `STARTUP`, `FLASHBACK`).

---

## Step-by-Step Scenario

### Step 1 — Create Test Objects on Primary (Clean State)
Set up your baseline data before creating the restore point.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
CREATE USER testdg IDENTIFIED BY Oracle123 DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CREATE SESSION, CREATE TABLE TO testdg;

CREATE TABLE testdg.employees (emp_id NUMBER PRIMARY KEY, emp_name VARCHAR2(100));
INSERT INTO testdg.employees VALUES (1, 'Ahmet Yilmaz');
INSERT INTO testdg.employees VALUES (2, 'Ayse Kaya');
COMMIT;

SELECT COUNT(*) AS emp_count FROM testdg.employees;
EOF
```

### Step 2 — Create the Guaranteed Restore Point (Primary)
Create the GRP on the primary. It will automatically replicate to the standby.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
CREATE RESTORE POINT PRIDB_GRP GUARANTEE FLASHBACK DATABASE;
SELECT name, guarantee_flashback_database, replicated FROM v$restore_point;
EOF
```

### Step 3 — Transition Standby from Active DG to MOUNT
**This is the critical step for Broker environments.** The database cannot be flashed back while open (even in READ ONLY). You must gracefully stop apply via the Broker, mount the database, and hand apply control back to the Broker.

```bash
# 1. Stop apply via Broker (On either node)
dgmgrl sys/Oracle123@oracle1
DGMGRL> EDIT DATABASE PRIDBSTBY SET STATE='APPLY-OFF';
EXIT;

# 2. Drop to MOUNT mode via SQL*Plus (On oracle2)
sqlplus / as sysdba
SQL> SHUTDOWN IMMEDIATE;
SQL> STARTUP MOUNT;
SQL> EXIT;

# 3. Resume apply via Broker (On either node)
dgmgrl sys/Oracle123@oracle1
DGMGRL> EDIT DATABASE PRIDBSTBY SET STATE='APPLY-ON';
EXIT;
```
*Expected State: Standby is now MOUNTED, and the Broker is actively running MRP.*

### Step 4 — Simulate Human Error (Destructive Changes)
Wipe out the data on the primary to simulate an emergency.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
DROP TABLE testdg.employees;
SELECT table_name FROM dba_tables WHERE owner='TESTDG';
EOF
```
*Expected: The `EMPLOYEES` table is gone.*

### Step 5 — Flashback Primary to GRP
Perform the flashback on the primary database using SQL*Plus.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
FLASHBACK DATABASE TO RESTORE POINT PRIDB_GRP;
ALTER DATABASE OPEN RESETLOGS;

-- Verify table is restored
SELECT COUNT(*) AS emp_count FROM testdg.employees;
EOF
```

### Step 6 — Watch Standby Auto-Flashback
Once you issue the `OPEN RESETLOGS` on the primary, the Broker takes over. You can monitor the progress on the standby in two ways:

**Via Standby Alert Log:**
```bash
# On oracle2
tail -f /u01/app/oracle/diag/rdbms/pridbstby/PRIDBSTBY/trace/alert_PRIDBSTBY.log
```
*(Look for: `MRP0: Recovery coordinator performing automatic flashback of database`)*

**Via DG Broker:**
```bash
# On either node
dgmgrl sys/Oracle123@oracle1
DGMGRL> SHOW DATABASE PRIDBSTBY;
```
*(You will see the status briefly change to flashing back, and then return to "Applying Redo".)*
*(Check the alert log and you may see something like below, this means it's synced.)*

```
2026-03-26T10:11:33.329988+03:00
PR00 (PID:6877): Media Recovery Waiting for T-1.S-2 (in transit)
2026-03-26T10:11:33.409136+03:00
Recovery of Online Redo Log: Thread 1 Group 5 Seq 2 Reading mem 0
```

### Step 7 — Re-open Standby to Active Data Guard (Optional)
Once the auto-flashback completes and apply resumes, you can return the standby to Active Data Guard (READ ONLY WITH APPLY) using the proper Broker workflow.

```bash
# 1. Stop apply via Broker (On either node)
dgmgrl sys/Oracle123@oracle1
DGMGRL> EDIT DATABASE PRIDBSTBY SET STATE='APPLY-OFF';
EXIT;

# 2. Open the database via SQL*Plus (On oracle2)
sqlplus / as sysdba
SQL> ALTER DATABASE OPEN;
SQL> EXIT;

# 3. Resume apply via Broker (On either node)
dgmgrl sys/Oracle123@oracle1
DGMGRL> EDIT DATABASE PRIDBSTBY SET STATE='APPLY-ON';
EXIT;
```

### Step 8 — Cleanup: Drop the GRP
Always drop the Guaranteed Restore Point to allow the Fast Recovery Area (FRA) to clear out old flashback logs.

```bash
# On oracle1
sqlplus / as sysdba << 'EOF'
DROP RESTORE POINT PRIDB_GRP;
EOF
```

---

