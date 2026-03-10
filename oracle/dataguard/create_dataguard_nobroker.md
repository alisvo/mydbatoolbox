# Oracle 19c Data Guard Setup Guide (Physical Standby, No Broker)

> **Environment:** Oracle Linux 8 | Oracle Database 19.28.0.0.0 | Non-CDB | Filesystem Storage

---

## Environment Overview

| Parameter | Primary (oracle1) | Standby (oracle2) |
|---|---|---|
| Hostname | oracle1.localdomain | oracle2.localdomain |
| IP Address | 192.168.0.191 | 192.168.0.192 |
| DB_NAME | PRIDB | PRIDB |
| DB_UNIQUE_NAME | PRIDB | PRIDBSTBY |
| ORACLE_BASE | /u01/app/oracle | /u01/app/oracle |
| ORACLE_HOME | /u01/app/oracle/product/19.0.0/dbhome_1 | /u01/app/oracle/product/19.0.0/dbhome_1 |
| Data files | /u01/app/oracle/oradata/PRIDB | /u01/app/oracle/oradata/PRIDB |
| Archive logs | /u01/app/oracle/oradata/PRIDB/archive | /u01/app/oracle/oradata/PRIDB/archive |
| Fast Recovery Area | /u01/app/oracle/fast_recovery_area | /u01/app/oracle/fast_recovery_area |
| Role | PRIMARY | PHYSICAL STANDBY |
| Protection Mode | MAXIMUM PERFORMANCE | — |
| DG Broker | Disabled | — |

---

## Phase 1 — Prerequisites

### 1.1 Verify Oracle Environment (Both Nodes)

```bash
hostname
echo $ORACLE_HOME
echo $ORACLE_BASE
echo $ORACLE_SID
$ORACLE_HOME/bin/sqlplus -V
ls $ORACLE_HOME/bin/dbca
```

### 1.2 Setup Passwordless SSH (Both Directions)

```bash
# On oracle1
su - oracle
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa   # skip if key already exists
ssh-copy-id oracle@oracle2

# On oracle2
su - oracle
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa   # skip if key already exists
ssh-copy-id oracle@oracle1

# Test both directions
ssh oracle@oracle2 "hostname"   # from oracle1 — must return oracle2.localdomain
ssh oracle@oracle1 "hostname"   # from oracle2 — must return oracle1.localdomain
```

### 1.3 Firewall — Open Required Ports (Both Nodes)

```bash
sudo firewall-cmd --permanent --add-port=1521/tcp
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --reload
```

### 1.4 Start Listeners (Both Nodes)

```bash
lsnrctl start
lsnrctl status
```

### 1.5 Clean Up Stale Configuration (Both Nodes)

If any previous Oracle databases existed on these servers, clean them up:

```bash
# Remove stale admin directories
rm -rf $ORACLE_BASE/admin/*

# Check for and remove leftover dbs files (spfile, orapw, init)
ls -la $ORACLE_HOME/dbs/

# Clean oratab — will be re-populated automatically
# On oracle1 (as root):
sudo bash -c "cat > /etc/oratab << 'EOF'
#
EOF"

# On oracle2 (as root):
sudo bash -c "cat > /etc/oratab << 'EOF'
#
EOF"
```

> ⚠️ **Fix:** If oracle2's `listener.ora` contains a static `SID_LIST_LISTENER` entry from a previous database, remove it. Replace with a clean listener.ora:
>
> ```bash
> cat > $ORACLE_HOME/network/admin/listener.ora << 'EOF'
> LISTENER =
>   (DESCRIPTION_LIST =
>     (DESCRIPTION =
>       (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2.localdomain)(PORT = 1521))
>     )
>   )
>
> ADR_BASE_LISTENER = /u01/app/oracle
> EOF
> lsnrctl reload
> ```

---

## Phase 2 — Create Primary Database on oracle1

> Run on **oracle1 only** as the `oracle` user.

> ⚠️ **Fix:** Before running DBCA, ensure `/etc/oratab` does NOT already contain a `PRIDB` entry — DBCA checks oratab to detect existing SIDs. If it does, blank the file first (DBCA will re-add it automatically).

```bash
dbca -silent \
  -createDatabase \
  -templateName General_Purpose.dbc \
  -gdbName PRIDB \
  -sid PRIDB \
  -createAsContainerDatabase false \
  -datafileDestination /u01/app/oracle/oradata \
  -recoveryAreaDestination /u01/app/oracle/fast_recovery_area \
  -recoveryAreaSize 10240 \
  -characterSet AL32UTF8 \
  -nationalCharacterSet AL16UTF16 \
  -totalMemory 4096 \
  -databaseType OLTP \
  -enableArchive true \
  -archiveLogDest /u01/app/oracle/oradata/PRIDB/archive \
  -redoLogFileSize 200 \
  -sysPassword Oracle123 \
  -systemPassword Oracle123 \
  -emConfiguration NONE
```

> Adjust `-totalMemory` to ~60–70% of available RAM (`free -g` to check).

### Verify Primary DB

```bash
sqlplus -s / as sysdba << 'EOF'
SELECT instance_name, host_name, status, database_status FROM v$instance;
SELECT name, db_unique_name, log_mode, open_mode FROM v$database;
SELECT group#, members, bytes/1024/1024 AS size_mb, status FROM v$log;
ARCHIVE LOG LIST;
EOF
```

Expected: status `OPEN`, log mode `ARCHIVELOG`, open mode `READ WRITE`.

---

## Phase 3 — Configure Primary for Data Guard

> Run on **oracle1 only**.

### 3.1 Set Data Guard Parameters

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER SYSTEM SET DB_UNIQUE_NAME='PRIDB' SCOPE=SPFILE;
ALTER DATABASE FORCE LOGGING;
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(PRIDB,PRIDBSTBY)' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=/u01/app/oracle/oradata/PRIDB/archive VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=PRIDB' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_2='SERVICE=PRIDBSTBY ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=PRIDBSTBY' SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_1=ENABLE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=ENABLE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_MAX_PROCESSES=4 SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;
ALTER SYSTEM SET FAL_SERVER='PRIDBSTBY' SCOPE=BOTH;
ALTER SYSTEM SET FAL_CLIENT='PRIDB' SCOPE=BOTH;
ALTER SYSTEM SET REMOTE_LOGIN_PASSWORDFILE=EXCLUSIVE SCOPE=SPFILE;
EOF
```

### 3.2 Add Standby Redo Logs

Rule: SRL size must match online redo log size. Number of SRL groups = online redo log groups + 1 per thread.
We have 3 online redo log groups (200MB each), so we need 4 SRL groups.

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE ADD STANDBY LOGFILE GROUP 4 '/u01/app/oracle/oradata/PRIDB/srl_redo04.log' SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 5 '/u01/app/oracle/oradata/PRIDB/srl_redo05.log' SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 6 '/u01/app/oracle/oradata/PRIDB/srl_redo06.log' SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 7 '/u01/app/oracle/oradata/PRIDB/srl_redo07.log' SIZE 200M;

SELECT group#, bytes/1024/1024 AS size_mb, status FROM v$standby_log;
EOF
```

Expected: 4 rows with status `UNASSIGNED`.

### 3.3 Restart to Apply SPFILE Changes

```bash
sqlplus -s / as sysdba << 'EOF'
SHUTDOWN IMMEDIATE;
STARTUP;
SHOW PARAMETER log_archive_config
SHOW PARAMETER remote_login_passwordfile
EOF
```

---

## Phase 4 — TNS and Password File

### 4.1 Configure tnsnames.ora (Both Nodes — Identical)

```bash
cat > $ORACLE_HOME/network/admin/tnsnames.ora << 'EOF'
PRIDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle1.localdomain)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = PRIDB)
    )
  )

PRIDBSTBY =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2.localdomain)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = PRIDBSTBY)
    )
  )
EOF
```

Run this on **both oracle1 and oracle2**.

### 4.2 Test TNS Resolution (Both Nodes)

```bash
tnsping PRIDB
tnsping PRIDBSTBY
```

Both must return `OK`.

### 4.3 Copy Password File to oracle2

```bash
# On oracle1
scp $ORACLE_HOME/dbs/orapwPRIDB oracle@oracle2:$ORACLE_HOME/dbs/orapwPRIDBSTBY
```

### 4.4 Verify

```bash
# On oracle1
ls -la $ORACLE_HOME/dbs/orapw*    # should show orapwPRIDB

# On oracle2
ls -la $ORACLE_HOME/dbs/orapw*    # should show orapwPRIDBSTBY
```

---

## Phase 5 — Build Standby via RMAN Active Duplicate

### 5.1 Create Directories on oracle2

> ⚠️ **Fix:** RMAN copies the primary's spfile first, then restarts the auxiliary instance using it. The spfile references several directories that must exist on oracle2 **before** the duplicate starts. Missing directories cause RMAN to fail at the startup step with `ORA-01261`, `ORA-09925`, etc.

```bash
# On oracle2 — create ALL required directories upfront
mkdir -p /u01/app/oracle/admin/PRIDB/adump
mkdir -p /u01/app/oracle/admin/PRIDBSTBY/adump
mkdir -p /u01/app/oracle/admin/PRIDBSTBY/bdump
mkdir -p /u01/app/oracle/admin/PRIDBSTBY/cdump
mkdir -p /u01/app/oracle/admin/PRIDBSTBY/udump
mkdir -p /u01/app/oracle/oradata/PRIDB
mkdir -p /u01/app/oracle/oradata/PRIDB/archive
mkdir -p /u01/app/oracle/fast_recovery_area
```

> ⚠️ **Note:** The `PRIDB/adump` directory (using the primary's name, not PRIDBSTBY) is also required because the spfile copied from primary still has `audit_file_dest` pointing to that path. It gets overridden in the RMAN SPFILE SET clause but the directory must exist for the intermediate restart.

### 5.2 Create Minimal pfile and Start Standby in NOMOUNT

```bash
# On oracle2
cat > $ORACLE_HOME/dbs/initPRIDBSTBY.ora << 'EOF'
DB_NAME=PRIDB
DB_UNIQUE_NAME=PRIDBSTBY
EOF

export ORACLE_SID=PRIDBSTBY
sqlplus -s / as sysdba << 'EOF'
STARTUP NOMOUNT PFILE='/u01/app/oracle/product/19.0.0/dbhome_1/dbs/initPRIDBSTBY.ora';
EOF
```

### 5.3 Add Static Listener Entry on oracle2

A physical standby in NOMOUNT/MOUNT state does not register dynamically with the listener. A static entry is required so RMAN can connect to the auxiliary instance.

```bash
# On oracle2
cat > $ORACLE_HOME/network/admin/listener.ora << 'EOF'
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2.localdomain)(PORT = 1521))
    )
  )

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = PRIDBSTBY)
      (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)
      (SID_NAME = PRIDBSTBY)
    )
  )

ADR_BASE_LISTENER = /u01/app/oracle
EOF

lsnrctl reload
lsnrctl status
```

### 5.4 Test Connectivity from oracle1 to Standby

```bash
# On oracle1
sqlplus sys/Oracle123@PRIDBSTBY as sysdba << 'EOF'
SELECT instance_name, status FROM v$instance;
EOF
```

Expected: `PRIDBSTBY` / `STARTED`

### 5.5 Run RMAN Active Duplicate

> Run on **oracle1 only**. This copies all datafiles live over the network — takes 10–30 minutes depending on DB size.

> ⚠️ **Note on RMAN SPFILE SET parameters:** In Oracle 19c, the RMAN `SPFILE SET` clause only accepts a limited set of recognised parameter names. Parameters like `LOG_ARCHIVE_DEST_STATE_1`, `FAL_SERVER`, `FAL_CLIENT`, `STANDBY_FILE_MANAGEMENT`, and `LOG_ARCHIVE_MAX_PROCESSES` are **not** accepted by the SPFILE SET clause and will cause a syntax error. Set these via `ALTER SYSTEM` after the duplicate completes instead.

```bash
# On oracle1
rman TARGET sys/Oracle123@PRIDB AUXILIARY sys/Oracle123@PRIDBSTBY << 'EOF'

RUN {
  DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='PRIDBSTBY'
    SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(PRIDB,PRIDBSTBY)'
    SET LOG_ARCHIVE_DEST_1='LOCATION=/u01/app/oracle/oradata/PRIDB/archive VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=PRIDBSTBY'
    SET LOG_ARCHIVE_DEST_2='SERVICE=PRIDB ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=PRIDB'
    SET FAL_SERVER='PRIDB'
    SET FAL_CLIENT='PRIDBSTBY'
    SET AUDIT_FILE_DEST='/u01/app/oracle/admin/PRIDBSTBY/adump'
  NOFILENAMECHECK;
}
EOF
```

Expected final output: `Finished Duplicate Db at ...`

---

## Phase 6 — Start Redo Apply and Verify

### 6.1 Add Standby Redo Logs and Start MRP on oracle2

> ⚠️ **Note:** RMAN duplicates the SRLs from the primary as part of the duplicate, so the `ADD STANDBY LOGFILE` commands below will return `ORA-01184: logfile group already exists`. This is expected and harmless — the SRLs are already in place.

```bash
# On oracle2
export ORACLE_SID=PRIDBSTBY
sqlplus -s / as sysdba << 'EOF'
-- These may already exist (duplicated by RMAN) — ORA-01184 is safe to ignore
ALTER DATABASE ADD STANDBY LOGFILE GROUP 4 '/u01/app/oracle/oradata/PRIDB/srl_redo04.log' SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 5 '/u01/app/oracle/oradata/PRIDB/srl_redo05.log' SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 6 '/u01/app/oracle/oradata/PRIDB/srl_redo06.log' SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 7 '/u01/app/oracle/oradata/PRIDB/srl_redo07.log' SIZE 200M;

-- Start real-time redo apply
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EOF
```

### 6.2 Set Remaining Parameters on Standby

```bash
# On oracle2
sqlplus -s / as sysdba << 'EOF'
ALTER SYSTEM SET REMOTE_LOGIN_PASSWORDFILE=EXCLUSIVE SCOPE=SPFILE;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_MAX_PROCESSES=4 SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_1=ENABLE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=ENABLE SCOPE=BOTH;
EOF
```

### 6.3 Verify Data Guard Status

```bash
# On oracle1 — verify redo transport
sqlplus -s / as sysdba << 'EOF'
ALTER SYSTEM SWITCH LOGFILE;

SELECT dest_id, status, target, archiver, destination
FROM v$archive_dest WHERE dest_id IN (1,2);

SELECT thread#, MAX(sequence#) AS max_seq,
       SUM(CASE WHEN applied='YES' THEN 1 ELSE 0 END) AS applied_count
FROM v$archived_log GROUP BY thread#;
EOF
```

```bash
# On oracle2 — verify apply
sqlplus -s / as sysdba << 'EOF'
SELECT process, status, thread#, sequence#
FROM v$managed_standby WHERE process IN ('MRP0','RFS');

SELECT name, db_unique_name, open_mode, database_role, protection_mode
FROM v$database;

SELECT name, value, datum_time FROM v$dataguard_stats
WHERE name IN ('transport lag','apply lag','apply finish time');
EOF
```

**Expected results:**

| Check | Expected Value |
|---|---|
| DATABASE_ROLE | PHYSICAL STANDBY |
| MRP0 STATUS | APPLYING_LOG |
| transport lag | +00 00:00:00 |
| apply lag | +00 00:00:00 |
| Recent sequences | YES or IN-MEMORY |

> `IN-MEMORY` status means redo is being applied directly from Standby Redo Logs in real time — this is better than `YES` (which means applied from archived logs on disk).

---

## Day-to-Day Operations

### Check Data Guard Lag (on Standby)

```bash
sqlplus -s / as sysdba << 'EOF'
SELECT name, value, datum_time FROM v$dataguard_stats
WHERE name IN ('transport lag','apply lag','apply finish time');
EOF
```

### Check MRP Apply Status (on Standby)

```bash
sqlplus -s / as sysdba << 'EOF'
SELECT process, status, thread#, sequence# FROM v$managed_standby;
EOF
```

### Stop Redo Apply (on Standby)

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
EOF
```

### Restart Redo Apply (on Standby)

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EOF
```

### Check Archive Dest Status (on Primary)

```bash
sqlplus -s / as sysdba << 'EOF'
SELECT dest_id, dest_name, status, target, archiver, schedule, destination
FROM v$archive_dest WHERE dest_id IN (1,2);
EOF
```

### Open Standby Read-Only (Active Data Guard — requires license)

```bash
# On oracle2 — stop apply first
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE OPEN READ ONLY;
-- To resume real-time apply in read-only mode:
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EOF
```

---

## Switchover Procedure (Planned Role Reversal)

### Step 1 — Verify Standby is Ready (on Primary)

```bash
sqlplus -s / as sysdba << 'EOF'
SELECT switchover_status FROM v$database;
EOF
```

Expected: `TO STANDBY` or `SESSIONS ACTIVE`

### Step 2 — Switch Primary to Standby Role (on oracle1)

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE COMMIT TO SWITCHOVER TO PHYSICAL STANDBY WITH SESSION SHUTDOWN;
SHUTDOWN ABORT;
STARTUP MOUNT;
EOF
```

### Step 3 — Switch Standby to Primary Role (on oracle2)

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE COMMIT TO SWITCHOVER TO PRIMARY WITH SESSION SHUTDOWN;
ALTER DATABASE OPEN;
EOF
```

### Step 4 — Start Apply on New Standby (on oracle1)

```bash
sqlplus -s / as sysdba << 'EOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EOF
```

---

## Known Issues and Fixes

| Error | Cause | Fix |
|---|---|---|
| `[FATAL] DBT-10317 Specified SID Name already exists` | `/etc/oratab` contains a pre-existing entry for the SID | Blank `/etc/oratab` before running DBCA; it will re-add the entry automatically |
| `RMAN-01009: syntax error: found "identifier" ENABLE` | `LOG_ARCHIVE_DEST_STATE_*`, `FAL_SERVER`, `FAL_CLIENT` etc. are not valid in RMAN SPFILE SET clause | Remove unsupported parameters from RMAN command; set them via `ALTER SYSTEM` after duplicate |
| `ORA-01261: db_recovery_file_dest destination string cannot be translated` | `/u01/app/oracle/fast_recovery_area` does not exist on oracle2 | `mkdir -p /u01/app/oracle/fast_recovery_area` on oracle2 before RMAN duplicate |
| `ORA-09925: Unable to create audit trail file` | `audit_file_dest` directory does not exist on oracle2 | `mkdir -p /u01/app/oracle/admin/PRIDB/adump` AND `mkdir -p /u01/app/oracle/admin/PRIDBSTBY/adump` on oracle2; also add `SET AUDIT_FILE_DEST='/u01/app/oracle/admin/PRIDBSTBY/adump'` to RMAN SPFILE SET clause |
| `ORA-01184: logfile group already exists` during SRL creation on standby | RMAN Active Duplicate already duplicated the SRLs from the primary | Safe to ignore — SRLs are already present |
| Listener shows `The listener supports no services` on oracle2 | Physical standby in MOUNTED state does not dynamically register | Add static `SID_LIST_LISTENER` entry to oracle2's `listener.ora` permanently |
| `lsnrctl status` or `ssh` hangs indefinitely | Firewall blocking port 1521 or 22 | Open ports via `firewall-cmd` and verify connectivity with `nc -zv` |

---

## File Locations Reference

| File | Location |
|---|---|
| Primary spfile | `/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRIDB.ora` |
| Standby spfile | `/u01/app/oracle/product/19.0.0/dbhome_1/dbs/spfilePRIDBSTBY.ora` |
| Primary password file | `/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRIDB` |
| Standby password file | `/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPRIDBSTBY` |
| tnsnames.ora (both) | `/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/tnsnames.ora` |
| listener.ora (both) | `/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/listener.ora` |
| Primary alert log | `/u01/app/oracle/diag/rdbms/pridb/PRIDB/trace/alert_PRIDB.log` |
| Standby alert log | `/u01/app/oracle/diag/rdbms/pridbstby/PRIDBSTBY/trace/alert_PRIDBSTBY.log` |
| Primary archive logs | `/u01/app/oracle/oradata/PRIDB/archive/` |
| Standby archive logs | `/u01/app/oracle/oradata/PRIDB/archive/` |
