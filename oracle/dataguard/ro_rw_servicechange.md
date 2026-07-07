# Oracle 19c Data Guard - Role-Based TNS and Service Configuration

## Purpose

This document describes a simple role-based Oracle Net service model for a non-RAC Oracle 19c Data Guard environment.

The goal is to separate application traffic into two logical connection types:

```text
TESTDB_RW → Read/write application traffic, active only on PRIMARY
TESTDB_RO → Read-only application traffic, active only on PHYSICAL STANDBY opened READ ONLY
```

This avoids hard-coding application connections to a specific database host. After a switchover or failover, applications can reconnect through the same TNS alias and reach the correct database role.

---

## Environment

Example test environment:

```text
oracle1.localdomain → PRIDB
oracle2.localdomain → PRIDBSTBY
oracle3.localdomain → PRIDBSTBY2
```

Architecture:

```text
Oracle version : 19c
Data Guard     : Physical standby
RAC            : No
Broker         : Not required for this service model
```

---

## Existing Data Guard TNS Aliases

These aliases are used for Data Guard transport, FAL, and administrative connections.

They are node-specific and should remain as-is.

```ini
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

PRIDBSTBY2 =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle3.localdomain)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = PRIDBSTBY2)
    )
  )
```

These aliases are **not** intended to be used by applications for automatic role-based failover.

For example:

```text
PRIDB always points to oracle1.localdomain
PRIDBSTBY always points to oracle2.localdomain
PRIDBSTBY2 always points to oracle3.localdomain
```

After a switchover, the host names remain the same, but the database roles change. Therefore application traffic should use role-based aliases instead.

---

## Application TNS Aliases

Add the following aliases to `tnsnames.ora` on all application servers and Oracle client hosts.

### Read/write application alias

```ini
TESTDB_RW =
  (DESCRIPTION =
    (CONNECT_TIMEOUT=5)
    (TRANSPORT_CONNECT_TIMEOUT=3)
    (RETRY_COUNT=3)
    (ADDRESS_LIST =
      (LOAD_BALANCE=OFF)
      (FAILOVER=ON)
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle1.localdomain)(PORT = 1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2.localdomain)(PORT = 1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle3.localdomain)(PORT = 1521))
    )
    (CONNECT_DATA =
      (SERVICE_NAME = TESTDB_RW.localdomain)
      (SERVER = DEDICATED)
    )
  )
```

### Read-only application alias

```ini
TESTDB_RO =
  (DESCRIPTION =
    (CONNECT_TIMEOUT=5)
    (TRANSPORT_CONNECT_TIMEOUT=3)
    (RETRY_COUNT=3)
    (ADDRESS_LIST =
      (LOAD_BALANCE=ON)
      (FAILOVER=ON)
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle1.localdomain)(PORT = 1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle2.localdomain)(PORT = 1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = oracle3.localdomain)(PORT = 1521))
    )
    (CONNECT_DATA =
      (SERVICE_NAME = TESTDB_RO.localdomain)
      (SERVER = DEDICATED)
    )
  )
```

---

## Expected Service Behavior

Before switchover:

```text
oracle1 / PRIDB      → PRIMARY          → TESTDB_RW active
oracle2 / PRIDBSTBY  → PHYSICAL STANDBY → TESTDB_RO active
oracle3 / PRIDBSTBY2 → PHYSICAL STANDBY → TESTDB_RO active
```

After switchover to `oracle3 / PRIDBSTBY2`:

```text
oracle1 / PRIDB      → PHYSICAL STANDBY → TESTDB_RO active
oracle2 / PRIDBSTBY  → PHYSICAL STANDBY → TESTDB_RO active
oracle3 / PRIDBSTBY2 → PRIMARY          → TESTDB_RW active
```

Rules:

```text
TESTDB_RW must be active only on PRIMARY.
TESTDB_RO must be active only on PHYSICAL STANDBY when OPEN_MODE is READ ONLY or READ ONLY WITH APPLY.
TESTDB_RO should not be active when the standby database is only MOUNTED.
```

---

## Create Role-Based Services

Run this on the current primary database as `SYSDBA`.

```sql
set serveroutput on

BEGIN
    DBMS_SERVICE.CREATE_SERVICE(
        service_name  => 'TESTDB_RW',
        network_name => 'TESTDB_RW.localdomain'
    );

    DBMS_OUTPUT.PUT_LINE('Created service TESTDB_RW');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -44303 THEN
            DBMS_OUTPUT.PUT_LINE('Service TESTDB_RW already exists');
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    DBMS_SERVICE.CREATE_SERVICE(
        service_name  => 'TESTDB_RO',
        network_name => 'TESTDB_RO.localdomain'
    );

    DBMS_OUTPUT.PUT_LINE('Created service TESTDB_RO');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -44303 THEN
            DBMS_OUTPUT.PUT_LINE('Service TESTDB_RO already exists');
        ELSE
            RAISE;
        END IF;
END;
/
```

Validate:

```sql
set lines 200
col name format a30
col network_name format a40

select name, network_name
from dba_services
where name in ('TESTDB_RW', 'TESTDB_RO')
order by name;
```

Expected:

```text
TESTDB_RO  TESTDB_RO.localdomain
TESTDB_RW  TESTDB_RW.localdomain
```

---

## Service Management Procedure

This procedure starts or stops the services based on the current database role and open mode.

Run on the current primary as `SYSDBA`.

```sql
CREATE OR REPLACE PROCEDURE sys.manage_testdb_services
AUTHID DEFINER
AS
    v_role       v$database.database_role%TYPE;
    v_open_mode  v$database.open_mode%TYPE;
    v_count      number;

    PROCEDURE start_service_if_needed(p_service_name varchar2) IS
    BEGIN
        SELECT count(*)
        INTO v_count
        FROM v$active_services
        WHERE upper(name) = upper(p_service_name);

        IF v_count = 0 THEN
            DBMS_SERVICE.START_SERVICE(p_service_name);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    PROCEDURE stop_service_if_needed(p_service_name varchar2) IS
    BEGIN
        SELECT count(*)
        INTO v_count
        FROM v$active_services
        WHERE upper(name) = upper(p_service_name);

        IF v_count > 0 THEN
            DBMS_SERVICE.STOP_SERVICE(p_service_name);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

BEGIN
    SELECT database_role, open_mode
    INTO v_role, v_open_mode
    FROM v$database;

    IF v_role = 'PRIMARY' THEN
        start_service_if_needed('TESTDB_RW');
        stop_service_if_needed('TESTDB_RO');

    ELSIF v_role = 'PHYSICAL STANDBY' THEN
        stop_service_if_needed('TESTDB_RW');

        IF v_open_mode LIKE 'READ ONLY%' THEN
            start_service_if_needed('TESTDB_RO');
        ELSE
            stop_service_if_needed('TESTDB_RO');
        END IF;

    ELSE
        stop_service_if_needed('TESTDB_RW');
        stop_service_if_needed('TESTDB_RO');
    END IF;

    EXECUTE IMMEDIATE 'ALTER SYSTEM REGISTER';
END;
/
```

---

## Database Triggers

Two database-level triggers are used:

```text
AFTER STARTUP        → aligns services after database startup
AFTER DB_ROLE_CHANGE → aligns services after switchover/failover role change
```

Run on the current primary as `SYSDBA`.

```sql
CREATE OR REPLACE TRIGGER sys.trg_testdb_services_startup
AFTER STARTUP ON DATABASE
BEGIN
    sys.manage_testdb_services;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/
```

```sql
CREATE OR REPLACE TRIGGER sys.trg_testdb_services_rolechange
AFTER DB_ROLE_CHANGE ON DATABASE
BEGIN
    sys.manage_testdb_services;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/
```

Validate:

```sql
set lines 200
col trigger_name format a40
col status format a10
col triggering_event format a40

select trigger_name, status, triggering_event
from dba_triggers
where trigger_name in (
    'TRG_TESTDB_SERVICES_STARTUP',
    'TRG_TESTDB_SERVICES_ROLECHANGE'
)
order by trigger_name;
```

Expected:

```text
TRG_TESTDB_SERVICES_ROLECHANGE  ENABLED
TRG_TESTDB_SERVICES_STARTUP     ENABLED
```

---

## Optional: Stop Old Generic Service

If an old generic service such as `TESTDB` exists and is no longer used, stop it to avoid confusion.

```sql
BEGIN
    DBMS_SERVICE.STOP_SERVICE('TESTDB');
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/

ALTER SYSTEM REGISTER;
```

Do not drop the old service until all applications are confirmed to use either:

```text
TESTDB_RW
TESTDB_RO
```

---

## Manual Service Alignment

Normally this is not required because the triggers handle startup and role changes automatically.

For manual correction or troubleshooting, run:

```sql
exec sys.manage_testdb_services;
alter system register;
```

---

## Validation Queries

Run on each database node.

```sql
set lines 200
col db_unique_name format a20
col database_role format a20
col open_mode format a25
col host_name format a30
col name format a30
col network_name format a40

select
    d.db_unique_name,
    d.database_role,
    d.open_mode,
    i.host_name
from v$database d
cross join v$instance i;

select
    name,
    network_name
from v$active_services
where name in ('TESTDB', 'TESTDB_RW', 'TESTDB_RO')
order by name;
```

Expected example after switchover to `PRIDBSTBY2`:

```text
oracle1 / PRIDB      → PHYSICAL STANDBY → TESTDB_RO
oracle2 / PRIDBSTBY  → PHYSICAL STANDBY → TESTDB_RO
oracle3 / PRIDBSTBY2 → PRIMARY          → TESTDB_RW
```

The old `TESTDB` service should not be active unless intentionally still used.

---

## Listener Validation

Run on each Linux VM:

```bash
lsnrctl status | egrep "TESTDB|Service"
```

Expected:

```text
Current PRIMARY listener:
  TESTDB_RW

Current READ ONLY standby listeners:
  TESTDB_RO
```

---

## TNS Validation

From an application host or Oracle client host:

```bash
tnsping TESTDB_RW
tnsping TESTDB_RO
```

Application connection examples:

```bash
export ORACLE_DSN=TESTDB_RW
```

Expected result:

```text
Connects to the current PRIMARY database.
```

```bash
export ORACLE_DSN=TESTDB_RO
```

Expected result:

```text
Connects to a READ ONLY standby database.
```

---

## Important Notes

This setup validates **new connection routing** after a role change.

It does not guarantee that an already-open database session survives a switchover or failover without an application-side reconnect. Applications and connection pools should still handle transient connection errors and retry.

Recommended application behavior:

```text
Use TESTDB_RW for read/write workloads.
Use TESTDB_RO for read-only/reporting workloads.
Do not use PRIDB / PRIDBSTBY / PRIDBSTBY2 for role-based application connectivity.
Do not use the old generic TESTDB service unless it is intentionally maintained.
```

---

## Final Model

```text
Application RW traffic
        ↓
TNS alias: TESTDB_RW
        ↓
Service: TESTDB_RW.localdomain
        ↓
Current PRIMARY only


Application RO traffic
        ↓
TNS alias: TESTDB_RO
        ↓
Service: TESTDB_RO.localdomain
        ↓
Current READ ONLY standby databases only
```
