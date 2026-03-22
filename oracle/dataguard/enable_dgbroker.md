# Oracle Data Guard Broker — Activation Guide

> **Environment:** Oracle Database 19c EE (19.28) on Oracle Enterprise Linux 8  
> **Tested on:** 19.28.0.0.0

## Environment Reference

| Role | Hostname | SID |
|---|---|---|
| Primary | oracle1 | PRIDB |
| Standby | oracle2 | PRIDBSTBY |

---

## Phase 1 — Prerequisites

### Step 1 — Configure Static Listener Entries (Both Nodes)

The broker requires a static listener entry on each node. Edit `$ORACLE_HOME/network/admin/listener.ora` on both nodes.

**oracle1 — `listener.ora`:**

```
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = PRIDB_DGMGRL)
      (ORACLE_HOME   = /u01/app/oracle/product/19.0.0/dbhome_1)
      (SID_NAME      = PRIDB)
    )
  )

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle1)(PORT = 1521))
    )
  )
```

**oracle2 — `listener.ora`:**

```
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = PRIDBSTBY_DGMGRL)
      (ORACLE_HOME   = /u01/app/oracle/product/19.0.0/dbhome_1)
      (SID_NAME      = PRIDBSTBY)
    )
  )

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2)(PORT = 1521))
    )
  )
```

> **Note:** The `_DGMGRL` suffix on `GLOBAL_DBNAME` is mandatory — this is how the broker locates the static service.

### Step 2 — Configure TNS Entries (Both Nodes)

Add both databases to `$ORACLE_HOME/network/admin/tnsnames.ora` on **both** nodes:

```
PRIDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle1)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = PRIDB)
    )
  )

PRIDBSTBY =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = PRIDBSTBY)
    )
  )
```

### Step 3 — Reload Listeners (Both Nodes)

```bash
lsnrctl reload
lsnrctl status
```

Static entries will appear with `UNKNOWN` status — this is expected and correct.

---

## Phase 2 — Enable Broker on Primary (oracle1)

```bash
sqlplus / as sysdba
```

```sql
-- Verify current value
SHOW PARAMETER dg_broker_start;

-- Enable the broker
ALTER SYSTEM SET dg_broker_start = TRUE SCOPE=BOTH SID='*';

-- Confirm DMON and NSA background processes started
SELECT name, description FROM v$bgprocess WHERE name LIKE 'DMON%' OR name LIKE 'NSA%';

-- Check broker config file locations
SHOW PARAMETER dg_broker_config_file;
```

Default config file paths will be:
```
dg_broker_config_file1 = $ORACLE_BASE/dbs/dr1PRIDB.dat
dg_broker_config_file2 = $ORACLE_BASE/dbs/dr2PRIDB.dat
```

---

## Phase 3 — Enable Broker on Standby (oracle2)

```bash
sqlplus / as sysdba
```

```sql
ALTER SYSTEM SET dg_broker_start = TRUE SCOPE=BOTH SID='*';

-- Verify DMON started
SELECT name FROM v$bgprocess WHERE name = 'DMON';

-- Check broker config file locations
SHOW PARAMETER dg_broker_config_file;
```

---

## Phase 4 — Pre-Check: Clear Conflicting Archive Destinations

Before creating the broker configuration, ensure no `LOG_ARCHIVE_DEST_n` parameter on **either node** contains a `SERVICE=` attribute. The broker manages redo transport itself and will refuse to add a standby if a conflicting manual dest exists.

**Check on both nodes:**

```sql
SHOW PARAMETER log_archive_dest;
```

If any dest contains `SERVICE=`, clear it:

```sql
-- Replace 2 with whichever dest number contains SERVICE=
ALTER SYSTEM SET log_archive_dest_2 = '' SCOPE=BOTH;
```

> **Important:** This must be checked on **both** oracle1 and oracle2 — the error `ORA-16698` can be triggered by a conflicting dest on either node.

---

## Phase 5 — Create the Broker Configuration

Always run from the **primary node**.

```bash
dgmgrl sys@PRIDB
```

```sql
-- Create the configuration
CREATE CONFIGURATION dg_PRIDB
    AS PRIMARY DATABASE IS PRIDB
    CONNECT IDENTIFIER IS PRIDB;

-- Add the standby
ADD DATABASE PRIDBSTBY
    AS CONNECT IDENTIFIER IS PRIDBSTBY
    MAINTAINED AS PHYSICAL;

-- Enable the configuration (broker takes over management)
ENABLE CONFIGURATION;
```

---

## Phase 6 — Verify the Configuration

```sql
SHOW CONFIGURATION;
```

Expected output:
```
Configuration - dg_pridb

  Protection Mode: MaxPerformance
  Members:
  pridb     - Primary database
    pridbstby - Physical standby database

Fast-Start Failover:  Disabled

Configuration Status:
SUCCESS   (status updated X seconds ago)
```

```sql
SHOW DATABASE VERBOSE PRIDB;
SHOW DATABASE VERBOSE PRIDBSTBY;
```

Both should report `Database Status: SUCCESS`. On the standby, confirm:
```
Transport Lag:  0 seconds
Apply Lag:      0 seconds
```

---

## Phase 7 — Validate the Configuration

> **Important:** Always connect DGMGRL with a password — not OS auth (`dgmgrl /`) — when running VALIDATE. OS auth causes `ORA-01017` during static identifier validation and can produce misleading warnings.

```bash
dgmgrl sys@PRIDB
```

```sql
VALIDATE DATABASE PRIDB;
VALIDATE DATABASE PRIDBSTBY;
```

Expected output for each:
```
Ready for Switchover:  Yes
Ready for Failover:    Yes (Primary Running)
The static connect identifier allows for a connection to database "..."
```

### Note on SRL Warning

You may see:
```
Warning: standby redo logs not configured for thread 1 on pridb
```

This is a **cosmetic warning** caused by the fact that primary SRLs sit `UNASSIGNED` with `THREAD#=0` until the database actually transitions to standby role. It does not block switchover or failover. If `Ready for Switchover: Yes` is confirmed, the environment is healthy.

Verify SRLs exist on both nodes with:

```sql
SELECT GROUP#, BYTES/1024/1024 AS SIZE_MB, THREAD#, SEQUENCE#, STATUS
FROM V$STANDBY_LOG
ORDER BY GROUP#;
```

Minimum required: **online redo log groups + 1** (e.g. 3 online groups → 4 SRLs minimum).

---

## Phase 8 — Switchover (Planned Role Reversal)

```sql
SWITCHOVER TO PRIDBSTBY;
```

The broker will:
1. Flush all redo from the primary
2. Switch the primary to standby role
3. Open the new primary
4. Automatically restart the old primary as a standby

After switchover verify:

```sql
SHOW CONFIGURATION;
```

Expected — roles are now flipped:
```
Members:
pridbstby - Primary database
  pridb     - Physical standby database
```

> A `WARNING` status with `ORA-16854: apply lag could not be determined` immediately after switchover is normal. Wait 30–60 seconds and re-run `SHOW CONFIGURATION` — it will settle to `SUCCESS`.

---

## Troubleshooting Reference

| Error | Cause | Fix |
|---|---|---|
| `ORA-16698: member has a LOG_ARCHIVE_DEST_n parameter with SERVICE attribute set` | Manual `LOG_ARCHIVE_DEST_n` with `SERVICE=` exists on primary or standby | Clear the conflicting dest on **both** nodes before running `ADD DATABASE` |
| `ORA-01017` during VALIDATE | Connected to DGMGRL via OS auth (`dgmgrl /`) | Always use `dgmgrl sys@PRIDB` with password |
| `ORA-16525: broker not yet available` | DMON not started | Verify `dg_broker_start=TRUE` and static listener entry |
| `ORA-16047: DGID mismatch` | `DB_UNIQUE_NAME` mismatch | Run `SHOW PARAMETER db_unique_name` on both nodes and verify |
| `WARNING` after switchover with ORA-16854 | Broker lag monitoring hasn't initialised yet | Wait 60 seconds and re-check |

---

## Day-to-Day DGMGRL Reference

```sql
-- Health check
SHOW CONFIGURATION;
SHOW DATABASE VERBOSE PRIDB;
SHOW DATABASE VERBOSE PRIDBSTBY;

-- Deep validation
VALIDATE DATABASE PRIDB;
VALIDATE DATABASE PRIDBSTBY;

-- Planned switchover (no data loss)
SWITCHOVER TO PRIDBSTBY;

-- Emergency failover (potential data loss)
FAILOVER TO PRIDBSTBY;

-- Reinstate old primary after failover
REINSTATE DATABASE PRIDB;

-- Disable broker (if ever needed)
DISABLE CONFIGURATION;
```

---

## Key Rules — Once Broker Is Active

- Always use `DGMGRL` for Data Guard operations — do not mix with manual `ALTER SYSTEM` commands for transport/apply settings
- Always connect DGMGRL with `sys@<db>` and password, not OS auth
- Do not manually set `LOG_ARCHIVE_DEST_n` with `SERVICE=` — the broker owns redo transport
- Protection mode and log transport mode changes must go through the broker:

```sql
EDIT DATABASE PRIDBSTBY SET PROPERTY LogXptMode='SYNC';
EDIT DATABASE PRIDB      SET PROPERTY LogXptMode='SYNC';
EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability;
```
