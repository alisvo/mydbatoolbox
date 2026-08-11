# Oracle 19c — Session ↔ Service Checks

Post-switchover verification queries. Oracle records the **service** a session
connected through (`v$session.SERVICE_NAME`), not which listener handed it over —
cross-check with `lsnrctl services` on the host for the listener half.

All queries use `gv$` so they work on single-instance and RAC alike.

---

## 1. Who's on which service

Summary of live user sessions grouped by service.

```sql
SELECT s.inst_id,
       s.service_name,
       s.con_id,
       COUNT(*)                  AS sessions,
       COUNT(DISTINCT s.machine) AS client_hosts,
       MIN(s.logon_time)         AS oldest_logon,
       MAX(s.logon_time)         AS newest_logon
FROM   gv$session s
WHERE  s.type = 'USER'
GROUP  BY s.inst_id, s.service_name, s.con_id
ORDER  BY sessions DESC;
```

---

## 2. Session-level detail

Find the specific client/app sitting on the wrong service.

```sql
SELECT s.inst_id, s.sid, s.serial#, s.username, s.service_name,
       s.machine, s.osuser, s.program, s.server,
       s.logon_time, s.status, s.con_id
FROM   gv$session s
WHERE  s.type = 'USER'
AND    s.username IS NOT NULL
ORDER  BY s.service_name, s.machine, s.logon_time;
```

---

## 3. Red flag — sessions on `SYS$USERS`

Anything on `SYS$USERS` connected **without** a real service name: SID-based TNS
entries, `/ as sysdba`, bequeath/local connections, or JDBC thin URLs using
`host:port:SID`. These clients do not follow a role change and will keep pointing
at whatever database answers on that host.

```sql
SELECT service_name, username, machine, osuser, program,
       COUNT(*)          AS cnt,
       MIN(logon_time)   AS first_logon
FROM   gv$session
WHERE  type = 'USER'
AND    service_name IN ('SYS$USERS')
GROUP  BY service_name, username, machine, osuser, program
ORDER  BY cnt DESC;
```

> `SYS$BACKGROUND` is normal — that's background processes, ignore it.

---

## 4. Configured vs. started vs. actually used

Catches role-based services that never started after the switchover.

```sql
SELECT d.name          AS service_name,
       d.network_name,
       CASE WHEN a.name IS NULL THEN 'NOT STARTED' ELSE 'ACTIVE' END AS state,
       NVL(c.sessions, 0) AS sessions
FROM   dba_services d
LEFT   JOIN v$active_services a
       ON a.name = d.name
LEFT   JOIN (SELECT service_name, COUNT(*) AS sessions
             FROM   v$session
             WHERE  type = 'USER'
             GROUP  BY service_name) c
       ON c.service_name = d.name
ORDER  BY sessions DESC, d.name;
```

**Reading the result**

| state | sessions | meaning |
|---|---|---|
| `ACTIVE` | > 0 | healthy — service is up and clients are using it |
| `ACTIVE` | 0 | service is up but nobody connects to it yet; check client TNS |
| `NOT STARTED` | 0 | service never came up after the switchover — start it |

> In a CDB, `dba_services` only shows services of the **current container**.
> Run it in the PDB, or query `cdb_services` from the root.

---

## Notes

- Run the whole set on **both** sides after a switchover. Lingering sessions on
  the new standby show up as connections against a mounted / read-only database.
- Listener side (from the OS, on each host):

  ```bash
  lsnrctl status LISTENER
  lsnrctl services LISTENER   # per-service handlers + established/refused counts
  ```

- Grid Infrastructure — confirm the role binding survived:

  ```bash
  srvctl status service -db <db_unique_name>
  srvctl config service -db <db_unique_name> -s <service_name> | grep -i role
  ```

  Each app-facing service should report `Service role: PRIMARY`.

---

Tested on Oracle Database 19c. Requires `SELECT` on `gv$session`,
`v$active_services`, and `dba_services` (e.g. `SELECT_CATALOG_ROLE`).
