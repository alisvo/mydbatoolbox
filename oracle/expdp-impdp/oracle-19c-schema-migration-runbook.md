# Oracle 19c Schema Migration Runbook (Data Pump)

Cross-platform schema migration between two Oracle 19c databases using
`expdp` / `impdp` over a shared filesystem.

**Validated on:** source OEL 8 / 19.31 → target RHEL 9 / 19.31, non-CDB, filesystem storage.

Data Pump dump files are platform-independent — endianness and OS differences are
handled internally, so no conversion step is required. Matching RU levels on both
sides means the `VERSION` parameter can be omitted entirely.

---

## Conventions used in this document

Replace these placeholders throughout:

| Placeholder | Meaning | Example |
|---|---|---|
| `<SHARED_DIR>` | OS path visible to **both** hosts | `/backup_nfs2/export` |
| `DP_DIR` | Oracle directory object name | `DP_NFS` |
| `<SCHEMA_LIST>` | Comma-separated schemas to migrate | `APP_CORE,APP_SVC_A,U_USER_01` |
| `<DATA_DIR>` | Target datafile location | `/data` |
| `<SOURCE_DB>` / `<TARGET_DB>` | TNS aliases or connect strings | — |

Example schema set used below (9 schemas):

```
APP_CORE, APP_SVC_AUTH, APP_SVC_IDM,
U_USER_01, U_USER_02, U_USER_03,
U_USER_04, U_USER_05, U_USER_06
```

Example role set (16 custom roles):

```
APP_ROLE_READONLY, APP_ROLE_ADMIN, APP_ROLE_MANAGER_A, APP_ROLE_ANALYST_B,
APP_ROLE_REP_C, APP_ROLE_AGENT_D, APP_ROLE_AUDITOR, APP_ROLE_SEC_ADMIN,
GEN_READ_ALL_DATA, GEN_METADATA_VIEWER, GEN_DML_ALL_DATA,
GEN_DDL_OBJ_CREATOR, GEN_DDL_OBJ_MAINTAINER, GEN_DDL_OBJ_DROPPER,
GEN_CODE_DEPLOYER, GEN_SEC_ROLE_MANAGER
```

---

## A note on connecting as SYSDBA

Oracle documentation recommends **against** `expdp \"/ as sysdba\"` for routine
Data Pump work. SYSDBA triggers specialized internal behaviour intended for
Oracle-internal use, and is officially supported only when Oracle Support
directs it or for specific migration scenarios.

Preferred connection identity:

```sql
-- one-time setup on both databases
CREATE USER dpadmin IDENTIFIED BY "<password>"
  DEFAULT TABLESPACE users TEMPORARY TABLESPACE temp;
GRANT CREATE SESSION TO dpadmin;
GRANT DATAPUMP_EXP_FULL_DATABASE TO dpadmin;   -- source
GRANT DATAPUMP_IMP_FULL_DATABASE TO dpadmin;   -- target
GRANT READ, WRITE ON DIRECTORY DP_DIR TO dpadmin;
```

`SYSTEM` also works and already holds both roles. Every command below shows the
`dpadmin` form; substitute `\"/ as sysdba\"` only if your environment requires it.

---

## Execution order (read this first)

The sequence is not arbitrary — steps 5 and 9 straddle the import for a reason.

```
SOURCE                               TARGET
------                               ------
1. Directory object
2. Pre-flight inventory queries
3. Extract roles/profiles/synonym DDL
4. expdp
                                     5. Directory object
                                     6. Tablespaces
                                     7. Profiles
                                     8. CREATE ROLE + role system/role grants
                                     9. impdp
                                    10. Object grants to roles
                                    11. utlrp + gather stats
                                    12. Reconciliation
```

**Why roles come before impdp:** the dump contains
`GRANT APP_ROLE_READONLY TO U_USER_01` statements. If the role does not exist,
every one of those fails with ORA-01919 and the users arrive without privileges.

**Why object grants come after impdp:** `GRANT SELECT ON APP_CORE.ORDERS TO
APP_ROLE_READONLY` requires the table to exist. Run these before the import and
they all fail with ORA-00942.

---

## 1. Directory object — source

```sql
CREATE OR REPLACE DIRECTORY DP_DIR AS '<SHARED_DIR>';
GRANT READ, WRITE ON DIRECTORY DP_DIR TO dpadmin;

SELECT directory_name, directory_path FROM dba_directories
WHERE  directory_name = 'DP_DIR';
```

Verify at OS level as the `oracle` user on the source host:

```bash
ls -ld <SHARED_DIR>                                    # expect oracle:oinstall
touch <SHARED_DIR>/.wtest && rm <SHARED_DIR>/.wtest && echo WRITABLE
df -h <SHARED_DIR>                                     # confirm free space
```

### NFS mount options

If `<SHARED_DIR>` is NFS, mount it on **both** hosts with:

```
rw,bg,hard,nointr,rsize=32768,wsize=32768,tcp,vers=3,timeo=600,actimeo=0
```

`actimeo=0` disables attribute caching. Without it, the target host can read
stale metadata for a dumpfile the source just finished writing, producing
ORA-39000 / ORA-31640 on import.

---

## 2. Pre-flight inventory — source

These queries determine what must be pre-created on the target. Run all of them
and keep the output.

```sql
-- 2a. Tablespaces referenced by the migrating schemas
SELECT DISTINCT tablespace_name
FROM   dba_segments
WHERE  owner IN (<SCHEMA_LIST>)
ORDER BY 1;

-- 2b. Per-user attributes (default TS, temp TS, profile)
SELECT username, default_tablespace, temporary_tablespace, profile, account_status
FROM   dba_users
WHERE  oracle_maintained = 'N'
ORDER BY username;

-- 2c. Custom roles — NOT carried by schema-mode export
SELECT role, authentication_type, password_required, common
FROM   dba_roles
WHERE  oracle_maintained = 'N'
ORDER BY role;

-- 2d. Custom profiles — also NOT carried
SELECT DISTINCT profile
FROM   dba_users
WHERE  oracle_maintained = 'N' AND profile <> 'DEFAULT';

-- 2e. Size estimate for the dump
SELECT ROUND(SUM(bytes)/1024/1024/1024, 1) AS total_gb
FROM   dba_segments
WHERE  owner IN (<SCHEMA_LIST>);

-- 2f. Baseline object counts for later reconciliation
SELECT owner, object_type, COUNT(*)
FROM   dba_objects
WHERE  owner IN (<SCHEMA_LIST>)
GROUP  BY owner, object_type
ORDER  BY owner, object_type;

-- 2g. Pre-existing invalid objects (so you don't blame the migration)
SELECT owner, object_name, object_type
FROM   dba_objects
WHERE  owner IN (<SCHEMA_LIST>) AND status = 'INVALID';
```

### Check for password-protected roles

```sql
SELECT role, authentication_type FROM dba_roles
WHERE  oracle_maintained = 'N' AND authentication_type <> 'NONE';
```

Any row here needs its password set **manually** on the target.
`DBMS_METADATA.GET_DDL` does not reliably reproduce role passwords — for
`authentication_type = 'PASSWORD'` it emits `IDENTIFIED BY VALUES '...'` only in
some versions, and for `EXTERNAL` / `GLOBAL` / `APPLICATION` it emits nothing
usable. Record these and handle them by hand.

### Confirm role names are not display-truncated

```sql
SELECT role, LENGTH(role) FROM dba_roles WHERE oracle_maintained = 'N';
```

Long names can be clipped by `LINESIZE` in spooled output. Since 12.2 the
identifier limit is 128 bytes (30 before), so verify actual lengths rather than
trusting the visual output.

---

## 3. Extract what Data Pump will not carry

Schema-mode export includes the users, their objects, data, and grants **made
by** those users. It excludes several things that live outside the schemas.

```sql
SET LONG 1000000 LONGCHUNKSIZE 1000000 PAGESIZE 0 LINESIZE 32767
SET TRIMSPOOL ON TRIMOUT ON FEEDBACK OFF ECHO OFF VERIFY OFF HEADING OFF
EXEC DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM,'SQLTERMINATOR',TRUE);
EXEC DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM,'PRETTY',TRUE);
```

### 3a. Roles — CREATE, system privs, nested role grants

```sql
SPOOL <SHARED_DIR>/01_roles.sql

PROMPT -- ===== CREATE ROLE =====
SELECT DBMS_METADATA.GET_DDL('ROLE', role)
FROM   dba_roles WHERE oracle_maintained = 'N' ORDER BY role;

PROMPT -- ===== SYSTEM PRIVILEGES GRANTED TO ROLES =====
SELECT DBMS_METADATA.GET_GRANTED_DDL('SYSTEM_GRANT', r.role)
FROM   dba_roles r
WHERE  r.oracle_maintained = 'N'
AND    EXISTS (SELECT 1 FROM dba_sys_privs p WHERE p.grantee = r.role);

PROMPT -- ===== ROLES GRANTED TO ROLES (nesting) =====
SELECT DBMS_METADATA.GET_GRANTED_DDL('ROLE_GRANT', r.role)
FROM   dba_roles r
WHERE  r.oracle_maintained = 'N'
AND    EXISTS (SELECT 1 FROM dba_role_privs p WHERE p.grantee = r.role);

SPOOL OFF
```

`GET_DDL('ROLE', ...)` returns only the bare `CREATE ROLE` statement — it does
**not** include anything granted to the role. `GET_GRANTED_DDL` is required for
that, which is why there are three separate queries here.

### 3b. Profiles

```sql
SPOOL <SHARED_DIR>/02_profiles.sql

SELECT DBMS_METADATA.GET_DDL('PROFILE', profile)
FROM   (SELECT DISTINCT profile FROM dba_users
        WHERE oracle_maintained = 'N' AND profile <> 'DEFAULT');

SPOOL OFF
```

### 3c. Object grants to roles — applied AFTER impdp

```sql
SPOOL <SHARED_DIR>/03_role_object_grants.sql

SELECT DBMS_METADATA.GET_GRANTED_DDL('OBJECT_GRANT', r.role)
FROM   dba_roles r
WHERE  r.oracle_maintained = 'N'
AND    EXISTS (SELECT 1 FROM dba_tab_privs p WHERE p.grantee = r.role);

SPOOL OFF
```

### 3d. Public synonyms pointing at migrating schemas

```sql
SPOOL <SHARED_DIR>/04_public_synonyms.sql

SELECT 'CREATE OR REPLACE PUBLIC SYNONYM "' || synonym_name ||
       '" FOR "' || table_owner || '"."' || table_name || '";'
FROM   dba_synonyms
WHERE  owner = 'PUBLIC' AND table_owner IN (<SCHEMA_LIST>);

SPOOL OFF
```

### 3e. Users — reference copy only

The dump creates these users itself; this file is for comparison if something
looks wrong afterwards.

```sql
SPOOL <SHARED_DIR>/05_users_reference.sql

SELECT DBMS_METADATA.GET_DDL('USER', username)
FROM   dba_users WHERE oracle_maintained = 'N' ORDER BY username;

SELECT DBMS_METADATA.GET_GRANTED_DDL('ROLE_GRANT', u.username)
FROM   dba_users u
WHERE  u.oracle_maintained = 'N'
AND    EXISTS (SELECT 1 FROM dba_role_privs p WHERE p.grantee = u.username);

SELECT DBMS_METADATA.GET_GRANTED_DDL('SYSTEM_GRANT', u.username)
FROM   dba_users u
WHERE  u.oracle_maintained = 'N'
AND    EXISTS (SELECT 1 FROM dba_sys_privs p WHERE p.grantee = u.username);

SPOOL OFF
```

### 3f. Review the spooled files before use

```bash
cd <SHARED_DIR>
sed -i '/^SQL>/d; /^Elapsed:/d' 0*.sql   # strip stray prompts if ECHO was on
grep -c 'CREATE ROLE' 01_roles.sql       # should match your role count
less 01_roles.sql
```

`DBMS_METADATA` output can wrap or pick up blank lines depending on session
settings. Always eyeball these files rather than piping them straight into the
target.

---

## 4. Export

Use a parameter file. `FLASHBACK_TIME` contains commas, quotes and parentheses
that are painful to escape correctly on a shell command line.

```bash
cat > <SHARED_DIR>/exp_schemas.par <<'EOF'
DIRECTORY=DP_DIR
DUMPFILE=schemas_%U.dmp
LOGFILE=exp_schemas.log
FILESIZE=8G
PARALLEL=4
SCHEMAS=APP_CORE,APP_SVC_AUTH,APP_SVC_IDM,U_USER_01,U_USER_02,U_USER_03,U_USER_04,U_USER_05,U_USER_06
FLASHBACK_TIME="TO_TIMESTAMP(TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS'),'YYYY-MM-DD HH24:MI:SS')"
EXCLUDE=STATISTICS
COMPRESSION=METADATA_ONLY
LOGTIME=ALL
METRICS=YES
JOB_NAME=EXP_SCHEMAS_01
EOF

nohup expdp dpadmin/'<password>'@<SOURCE_DB> \
      parfile=<SHARED_DIR>/exp_schemas.par \
      > <SHARED_DIR>/exp_nohup.out 2>&1 &
echo "PID=$!"

tail -f <SHARED_DIR>/exp_nohup.out
```

### Parameter rationale

| Parameter | Why |
|---|---|
| `DUMPFILE=..._%U.dmp` | `%U` expands to 01, 02, … — required for `PARALLEL > 1` |
| `FILESIZE=8G` | Keeps individual files manageable; avoids 2 GB limits on older filesystems |
| `PARALLEL=4` | Start at CPU count; needs at least as many dumpfiles as workers |
| `FLASHBACK_TIME` | **Transactionally consistent** snapshot across all schemas at one SCN |
| `EXCLUDE=STATISTICS` | Significantly faster export and import; regather on target instead |
| `COMPRESSION=METADATA_ONLY` | No license required. `COMPRESSION=ALL` needs Advanced Compression |
| `LOGTIME=ALL` + `METRICS=YES` | Timestamps and row counts per object — essential for diagnosing slow runs |
| `JOB_NAME` | Predictable name for `ATTACH` and for `dba_datapump_jobs` |

Without `FLASHBACK_TIME` (or `FLASHBACK_SCN`), each schema is read at whatever
time the worker reaches it — nine independent snapshots rather than one
consistent set. For related schemas this can produce referential inconsistency.

Requires sufficient UNDO retention for the duration of the export, otherwise
ORA-01555.

### Monitoring a running job

```sql
SELECT job_name, operation, job_mode, state, degree, attached_sessions
FROM   dba_datapump_jobs WHERE state <> 'NOT RUNNING';

SELECT sid, serial#, opname, target_desc, sofar, totalwork,
       ROUND(sofar/NULLIF(totalwork,0)*100,1) AS pct
FROM   v$session_longops
WHERE  opname LIKE 'SYS_EXPORT%' AND sofar <> totalwork;
```

Interactive control:

```bash
expdp dpadmin/'<password>'@<SOURCE_DB> attach=EXP_SCHEMAS_01
# then: STATUS / STOP_JOB=IMMEDIATE / START_JOB / KILL_JOB / PARALLEL=n
```

### Verify the dump before moving on

```bash
ls -lh <SHARED_DIR>/schemas_*.dmp
grep -iE "ORA-|error" <SHARED_DIR>/exp_schemas.log
tail -5 <SHARED_DIR>/exp_schemas.log      # expect "successfully completed"
```

---

## 5–7. Target preparation

### 5. Directory object

```sql
CREATE OR REPLACE DIRECTORY DP_DIR AS '<SHARED_DIR>';
GRANT READ, WRITE ON DIRECTORY DP_DIR TO dpadmin;
```

Confirm OS visibility from the target host too — the mount existing is not the
same as the `oracle` user being able to read it.

```bash
ls -l <SHARED_DIR>/schemas_01.dmp
```

### 6. Tablespaces

Create every tablespace returned by query 2a:

```sql
CREATE TABLESPACE <TS_NAME>
  DATAFILE '<DATA_DIR>/<TS_NAME>01.dbf'
  SIZE 1G AUTOEXTEND ON NEXT 128M MAXSIZE 32G
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE
  SEGMENT SPACE MANAGEMENT AUTO;
```

Alternatively remap during import (see step 9) — but pre-creating with matching
names is simpler and avoids surprises with partitioned objects and LOB segments
that carry their own tablespace clauses.

### 7. Profiles and roles

```sql
@<SHARED_DIR>/02_profiles.sql
@<SHARED_DIR>/01_roles.sql
```

Then verify before importing:

```sql
SELECT COUNT(*) FROM dba_roles WHERE oracle_maintained = 'N';   -- expect 16
SELECT role FROM dba_roles WHERE oracle_maintained = 'N' ORDER BY role;
```

Set passwords for any role identified in step 2 as password-protected:

```sql
ALTER ROLE <ROLE_NAME> IDENTIFIED BY "<password>";
```

---

## 9. Import

```bash
cat > <SHARED_DIR>/imp_schemas.par <<'EOF'
DIRECTORY=DP_DIR
DUMPFILE=schemas_%U.dmp
LOGFILE=imp_schemas.log
PARALLEL=4
SCHEMAS=APP_CORE,APP_SVC_AUTH,APP_SVC_IDM,U_USER_01,U_USER_02,U_USER_03,U_USER_04,U_USER_05,U_USER_06
TABLE_EXISTS_ACTION=SKIP
EXCLUDE=STATISTICS
LOGTIME=ALL
METRICS=YES
JOB_NAME=IMP_SCHEMAS_01
EOF

nohup impdp dpadmin/'<password>'@<TARGET_DB> \
      parfile=<SHARED_DIR>/imp_schemas.par \
      > <SHARED_DIR>/imp_nohup.out 2>&1 &
echo "PID=$!"

tail -f <SHARED_DIR>/imp_nohup.out
```

### Optional import parameters

```
# Different tablespace names on target (repeatable)
REMAP_TABLESPACE=OLD_TS_A:NEW_TS_A
REMAP_TABLESPACE=OLD_TS_B:NEW_TS_B

# Collapse everything into one tablespace: pair remap with this transform,
# which strips per-object storage clauses that would otherwise override it
TRANSFORM=SEGMENT_ATTRIBUTES:N

# Rename a schema during import
REMAP_SCHEMA=OLD_OWNER:NEW_OWNER

# Metadata-only dry run — validates DDL and dependencies without loading data
CONTENT=METADATA_ONLY

# Generate the DDL to a file instead of executing it (excellent dry run)
SQLFILE=imp_preview.sql
```

`SQLFILE` is the safest way to preview a risky import: `impdp` writes every DDL
statement it would run to that file and executes nothing.

### `TABLE_EXISTS_ACTION` values

| Value | Behaviour |
|---|---|
| `SKIP` | Leave existing table untouched (default when `CONTENT` is not `DATA_ONLY`) |
| `APPEND` | Insert rows into existing table |
| `TRUNCATE` | Empty then load — respects existing structure |
| `REPLACE` | Drop and recreate from dump |

For a clean target, `SKIP` is correct and safe.

---

## 10. Object grants to roles

Now that the tables exist:

```sql
@<SHARED_DIR>/03_role_object_grants.sql
@<SHARED_DIR>/04_public_synonyms.sql
```

---

## 11. Recompile and gather statistics

```sql
@?/rdbms/admin/utlrp.sql

SELECT owner, object_type, COUNT(*)
FROM   dba_objects WHERE status = 'INVALID'
GROUP  BY owner, object_type ORDER BY owner;
```

Compare against the step 2g baseline — objects invalid on the source will still
be invalid here and are not a migration failure.

```sql
BEGIN
  FOR r IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N') LOOP
    DBMS_STATS.GATHER_SCHEMA_STATS(
      ownname          => r.username,
      estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
      degree           => 4,
      cascade          => TRUE);
  END LOOP;
END;
/
```

---

## 12. Reconciliation

Run each query on **both** databases and diff the output.

```sql
-- object counts by owner and type
SELECT owner, object_type, COUNT(*) FROM dba_objects
WHERE  owner IN (<SCHEMA_LIST>)
GROUP  BY owner, object_type ORDER BY owner, object_type;

-- role assignments to users
SELECT grantee, granted_role, admin_option, default_role
FROM   dba_role_privs
WHERE  grantee IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
ORDER  BY grantee, granted_role;

-- object privileges held by each custom role
SELECT grantee, COUNT(*) FROM dba_tab_privs
WHERE  grantee IN (SELECT role FROM dba_roles WHERE oracle_maintained='N')
GROUP  BY grantee ORDER BY grantee;

-- system privileges by role
SELECT grantee, privilege FROM dba_sys_privs
WHERE  grantee IN (SELECT role FROM dba_roles WHERE oracle_maintained='N')
ORDER  BY grantee, privilege;

-- row counts on the largest tables (spot check)
SELECT owner, table_name, num_rows FROM dba_tables
WHERE  owner IN (<SCHEMA_LIST>) AND num_rows > 100000
ORDER  BY num_rows DESC FETCH FIRST 25 ROWS ONLY;

-- constraint and index integrity
SELECT owner, constraint_type, status, COUNT(*) FROM dba_constraints
WHERE  owner IN (<SCHEMA_LIST>) GROUP BY owner, constraint_type, status;

SELECT owner, status, COUNT(*) FROM dba_indexes
WHERE  owner IN (<SCHEMA_LIST>) GROUP BY owner, status;
```

Any `UNUSABLE` index or `DISABLED` constraint needs attention:

```sql
SELECT 'ALTER INDEX '||owner||'.'||index_name||' REBUILD ONLINE;'
FROM   dba_indexes WHERE status = 'UNUSABLE' AND owner IN (<SCHEMA_LIST>);
```

---

## What schema-mode export does NOT include

Each of these is a real gap that typically surfaces only when an application
breaks. Check every one against the source.

| Item | Detection query | Handling |
|---|---|---|
| **Custom roles** | `dba_roles WHERE oracle_maintained='N'` | Step 3a — **mandatory** |
| **Custom profiles** | `dba_profiles` | Step 3b |
| **Public synonyms** | `dba_synonyms WHERE owner='PUBLIC'` | Step 3d |
| **Directory objects** | `dba_directories` | SYS-owned; recreate manually |
| **Grants TO Oracle-maintained users** | `dba_tab_privs` where grantee is maintained | Extract with `DBMS_METADATA` |
| **Grants FROM other schemas** on objects the migrating schemas need | `dba_tab_privs WHERE grantee IN (<SCHEMA_LIST>)` | Extract separately |
| **Database links** | `dba_db_links` | User-owned links export, but connect strings need target `tnsnames.ora` entries |
| **Scheduler jobs / credentials / chains** | `dba_scheduler_jobs`, `dba_scheduler_credentials` | Jobs export; verify `enabled` state and recreate credentials (passwords not carried) |
| **Application contexts** | `dba_context` | SYS-owned; recreate |
| **Profiles' password verify functions** | `dba_profiles WHERE resource_name='PASSWORD_VERIFY_FUNCTION'` | Function usually lives in SYS |
| **Wallet / TDE keys** | — | Separate export; encrypted columns need the key on target |
| **AWR / SQL plan baselines** | `dba_sql_plan_baselines` | `DBMS_SPM.PACK_STGTAB_BASELINE` |
| **External table OS files** | `dba_external_locations` | Copy the underlying files |
| **BFILE contents** | `dba_directories` + BFILE columns | Copy the OS files |

Post-migration check for cross-schema dependencies you might have missed:

```sql
SELECT DISTINCT referenced_owner
FROM   dba_dependencies
WHERE  owner IN (<SCHEMA_LIST>)
AND    referenced_owner NOT IN (<SCHEMA_LIST>)
AND    referenced_owner NOT IN ('SYS','SYSTEM','PUBLIC')
ORDER  BY 1;
```

Anything returned is a schema you did not migrate but the migrated code depends on.

---

## Common errors

| Error | Cause | Fix |
|---|---|---|
| **ORA-39002 / ORA-39070** | Directory object missing, or OS path not writable by `oracle` | Verify `dba_directories` and OS permissions on both hosts |
| **ORA-01919: role does not exist** | Roles not created before impdp | Step 8 before step 9 |
| **ORA-00942 on grant statements** | Object grants run before the tables exist | Move to step 10 |
| **ORA-01950: no privileges on tablespace** | Target tablespace missing or no quota | Pre-create tablespaces; grant quota or `UNLIMITED TABLESPACE` |
| **ORA-39082: object created with compilation errors** | Dependency not yet loaded | Usually resolved by `utlrp.sql`; investigate if it persists |
| **ORA-31693 + ORA-01555** | UNDO retention too short for `FLASHBACK_TIME` | Increase `undo_retention` / UNDO tablespace size; retry |
| **ORA-39000 / ORA-31640: unable to open dumpfile** | NFS attribute caching, or file not visible from target | Mount with `actimeo=0`; verify with `ls` as `oracle` |
| **ORA-29913 / ORA-29400** | External table definition, path missing on target | Create the OS directory and copy files |
| **PRVG-1901 / permission denied in /tmp** | `/tmp` mounted `noexec` (see appendix) | `export CV_DESTLOC=/u01/tmp/cvu` |
| **ORA-02380: profile does not exist** | Custom profile not created | Step 7 |
| **Import hangs at "Startup took N seconds"** | Master table contention or insufficient `PARALLEL` streams | Check `dba_datapump_jobs`; ensure dumpfile count ≥ `PARALLEL` |

---

## Appendix A: environment for RHEL 9 hosts

Any Oracle utility that invokes CVU (`dbca`, `runInstaller`, `srvctl`) needs
these when running 19.x on RHEL 9.

```bash
export ORACLE_HOME=/u01/app/oracle/product/19/dbhome_1
export ORACLE_BASE=/u01/app/oracle
export ORACLE_SID=<sid>
export PATH=$ORACLE_HOME/bin:$PATH
export CV_ASSUME_DISTID=OL8       # 19.x does not recognise RHEL 9 release string
export CV_DESTLOC=/u01/tmp/cvu    # required if /tmp is mounted noexec
export TMP=/u01/tmp TMPDIR=/u01/tmp
umask 0022
```

`CV_DESTLOC` matters because CVU writes `exectask.sh` into its work area and
then executes it. A hardened `/tmp` (`noexec,nosuid,nodev`) causes
`PRVG-1901 ... Permission denied` even though the file was created
successfully. `TMP`/`TMPDIR` alone do **not** relocate the CVU work area.

```bash
mkdir -p /u01/tmp/cvu && chmod 700 /u01/tmp/cvu
mount | grep -w /tmp                    # check for noexec
rm -rf /tmp/CVU_19.0.0.0.0_oracle       # clear any half-written work area
```

`umask` must be `0022`. A hardened default of `0027` creates files the
installer and Oracle processes cannot read via group, which surfaces later as
obscure permission failures.

---

## Appendix B: wrapper script template

Keeps the invocation reproducible and survives SSH disconnection.

```bash
#!/bin/bash
# <SHARED_DIR>/run_datapump.sh   — chmod 700, contains a password
set -o pipefail

export ORACLE_HOME=/u01/app/oracle/product/19/dbhome_1
export ORACLE_BASE=/u01/app/oracle
export ORACLE_SID=<sid>
export PATH=$ORACLE_HOME/bin:$PATH
export CV_ASSUME_DISTID=OL8
export CV_DESTLOC=/u01/tmp/cvu
export TMP=/u01/tmp TMPDIR=/u01/tmp
umask 0022

STAMP=$(date +%Y%m%d_%H%M%S)
LOG=<SHARED_DIR>/datapump_${STAMP}.out

{
  echo "=== started $(date) ==="
  impdp dpadmin/'<password>'@<TARGET_DB> parfile=<SHARED_DIR>/imp_schemas.par
  echo "=== IMPDP_EXIT=$? ==="
  echo "=== finished $(date) ==="
} 2>&1 | tee "$LOG"
```

```bash
chmod 700 <SHARED_DIR>/run_datapump.sh
nohup <SHARED_DIR>/run_datapump.sh > /dev/null 2>&1 &
echo "PID=$!"
```

Remove the script when finished, since it contains a credential:

```bash
shred -u <SHARED_DIR>/run_datapump.sh
```

Better still, use a wallet and avoid the embedded password entirely:

```bash
mkstore -wrl $ORACLE_HOME/network/admin/wallet -create
mkstore -wrl $ORACLE_HOME/network/admin/wallet \
        -createCredential <TARGET_DB> dpadmin '<password>'
# then connect with:  impdp /@<TARGET_DB> parfile=...
```

---

## Appendix C: alternative — NETWORK_LINK (no dumpfile)

When shared storage is unavailable, import directly over a database link.

```sql
-- on target
CREATE DATABASE LINK src_link
  CONNECT TO dpadmin IDENTIFIED BY "<password>"
  USING '<SOURCE_DB>';

SELECT * FROM dual@src_link;   -- verify
```

```bash
impdp dpadmin/'<password>'@<TARGET_DB> \
  NETWORK_LINK=src_link \
  SCHEMAS=<SCHEMA_LIST> \
  LOGFILE=DP_DIR:imp_netlink.log \
  PARALLEL=4 \
  EXCLUDE=STATISTICS \
  FLASHBACK_TIME="TO_TIMESTAMP(TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS'),'YYYY-MM-DD HH24:MI:SS')"
```

Trade-offs: no intermediate disk space needed and no file transfer, but it is
generally slower for large volumes, holds a long-running distributed
transaction, cannot use `COMPRESSION`, and LONG / LONG RAW columns are not
supported over a network link. The pre- and post-import role steps are
identical.

---

## Quick reference checklist

```
SOURCE
[ ] Directory object created, OS path writable by oracle
[ ] Inventory queries 2a–2g captured and saved
[ ] Password-protected roles identified
[ ] 01_roles.sql extracted and reviewed
[ ] 02_profiles.sql extracted
[ ] 03_role_object_grants.sql extracted
[ ] 04_public_synonyms.sql extracted
[ ] 05_users_reference.sql extracted
[ ] UNDO retention adequate for export duration
[ ] expdp completed — log shows "successfully completed", no ORA- errors

TARGET
[ ] Directory object created, dumpfiles visible as oracle
[ ] Tablespaces pre-created (or REMAP_TABLESPACE planned)
[ ] Profiles created
[ ] Roles created — count verified
[ ] Role passwords set where required
[ ] impdp completed — log reviewed
[ ] Object grants to roles applied
[ ] Public synonyms applied
[ ] utlrp.sql run, invalid objects compared to source baseline
[ ] Statistics gathered
[ ] Reconciliation queries diffed against source
[ ] Gap list (db links, scheduler jobs, contexts, directories) worked through
[ ] Application connectivity smoke-tested
[ ] Credential-bearing scripts shredded
```
