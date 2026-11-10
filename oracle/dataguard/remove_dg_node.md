# Removing a Standby from an Oracle 19c Data Guard Configuration

A runbook for decommissioning one physical standby from a multi-standby Data Guard
configuration **without client-side changes and without downtime**.

Tested on Oracle 19.29 Enterprise Edition, single instance (no RAC, no Grid
Infrastructure), Data Guard Broker disabled (manual configuration).

---

## Scope

| | |
|---|---|
| **Goal** | Remove one physical standby from a 1 primary + 2 standby configuration |
| **Downtime** | None. Primary and the remaining standby are never restarted |
| **Client impact** | None. `tnsnames.ora` is not modified |
| **Reversible** | Yes, up to Phase 5 — see [Rollback](#rollback) |

### Reference topology

| Role | Host | `db_unique_name` | Notes |
|---|---|---|---|
| Primary | `db01.example.com` | `PRODDB` | |
| Standby 1 | `db02.example.com` | `PRODDB_S1` | Same subnet, low latency |
| Standby 2 | `db03.example.com` | `PRODDB_S2` | **To be removed.** Remote site |

Both standbys run Active Data Guard (`READ ONLY WITH APPLY`).

Role-based services are managed by `db_role_change` and `after startup` database
triggers:

- `PRODDB_RW` — started only when `database_role = 'PRIMARY'`
- `PRODDB_RO` — started on any node open in `READ ONLY` or `READ WRITE` mode

Replace all names above with your own throughout.

---

## Why no TNS change is required

Clients reach the database through a single descriptor listing all three hosts, with
`LOAD_BALANCE=OFF` and `FAILOVER=ON` (connect-time failover). When the removed node
stops answering, one of three things happens, and all of them are handled by the
client automatically:

| Node state | Client receives | Cost |
|---|---|---|
| Listener down / host refuses | `ORA-12541` or TCP RST | Milliseconds — next address tried immediately |
| Host up, service not registered | `ORA-12514` | Milliseconds |
| Host completely unreachable (VM deleted, network cut) | timeout | `TRANSPORT_CONNECT_TIMEOUT` seconds |

Only the third case costs anything. Whether it matters depends on where the removed
node sits in the address list:

- If it is **last** (typical for the read-write descriptor), it is never reached in
  normal operation — cost is zero.
- If it is **in the middle** (typical for a read-only descriptor), the cost is paid
  only when the address before it is also unavailable.

Removing the address from `tnsnames.ora` is therefore **optional cleanup**, not part
of the decommission. Schedule it for a later maintenance window.

> **DNS:** if the VM is deleted, either remove its DNS record or leave it in place —
> but never let the record point at a different machine. An unresolvable name yields
> `ORA-12545`, which also fails over cleanly. A name pointing at the wrong host does not.

---

## Prerequisites

Run these before starting and keep the output. They establish the baseline you will
compare against afterwards.

```sql
-- On every node
select name, db_unique_name, database_role, open_mode, flashback_on from v$database;

select name, value from v$parameter
where name like 'log_archive_dest%' and value is not null
order by name;

select name, value from v$parameter
where name in ('log_archive_config','fal_server','service_names');

select dest_id, destination, status, valid_role, error
from v$archive_dest where destination is not null order by dest_id;
```

```sql
-- On the primary
select dest_id, dest_name, status, database_mode, recovery_mode, error
from v$archive_dest_status where status != 'INACTIVE' order by dest_id;
```

Also take a parameter-file backup on all three nodes:

```sql
create pfile='/tmp/pfile_before_removal.ora' from spfile;
```

### Check the archive deletion policy

```
RMAN> show archivelog deletion policy;
```

- `APPLIED ON STANDBY` (singular) — safe. Archives become reclaimable once *any*
  standby has applied them.
- `APPLIED ON ALL STANDBY` — **fix this first.** Once the removed node stops applying,
  the condition can never be satisfied, archives are never reclaimed, the FRA fills
  and redo apply stops.

---

## Phase 1 — Drain client traffic

This phase is what makes the operation non-disruptive. Do it first.

On the node being removed, see who is connected:

```sql
select service_name, machine, program, username, count(*)
from v$session where type = 'USER'
group by service_name, machine, program, username
order by 5 desc;
```

Stop the read-only service. New connections fail over to the remaining nodes through
the existing TNS descriptor; **existing sessions are not killed**:

```sql
exec dbms_service.stop_service('PRODDB_RO');
alter system register;
```

Wait for existing sessions to drain naturally — connection pools will replace them on
their own recycle. Re-run the `v$session` query until it returns nothing.

> Do not proceed while user sessions remain unless you accept killing them.

---

## Phase 2 — Stop redo apply

On the node being removed:

```sql
alter database recover managed standby database cancel;
```

---

## Phase 3 — Defer the destination on the primary

**Order matters.** Deferring before shutdown prevents the primary from logging
transport failures.

```sql
-- On the primary
alter system set log_archive_dest_state_3 = 'DEFER' scope = both sid = '*';
```

Confirm the primary is no longer shipping to it:

```sql
select dest_id, dest_name, status, error
from v$archive_dest_status where status != 'INACTIVE';
```

In `MAXIMUM PERFORMANCE` with `OPTIONAL` binding, skipping this step is harmless but
noisy. Under `MAXIMUM AVAILABILITY` with `SYNC` transport it is **not** optional —
shutting down an enabled `SYNC` destination stalls the primary.

---

## Phase 4 — Shut down and soak

```sql
-- On the node being removed
shutdown immediate;
```

**Stop here for a defined soak period** — one to two weeks is typical. Everything up
to this point is fully reversible with no data movement.

### The rollback window is finite

While the node is down, the primary keeps reclaiming archived logs under its deletion
policy. With `APPLIED ON STANDBY`, an archive becomes reclaimable as soon as the
*remaining* standby applies it, and is deleted under FRA pressure.

Once the archives needed to close the gap are gone, the only way back is an RMAN
duplicate. Track this explicitly:

```sql
-- On the primary
select file_type, percent_space_used, percent_space_reclaimable, number_of_files
from v$flash_recovery_area_usage where number_of_files > 0;
```

To widen the window, back up the archived logs to a separate location before shutdown.

---

## Phase 5 — Remove from the configuration

Only after the soak period. **This is the point of no return for a simple rollback.**

```sql
-- On EVERY remaining node
alter system set log_archive_config = 'DG_CONFIG=(PRODDB,PRODDB_S1)'
  scope = both sid = '*';
```

```sql
-- On the primary
alter system set log_archive_dest_3 = '' scope = both sid = '*';
alter system set log_archive_dest_state_3 = 'DEFER' scope = both sid = '*';
alter system set fal_server = 'PRODDB_S1' scope = both sid = '*';
```

```sql
-- On the remaining standby
alter system set log_archive_dest_3 = '' scope = both sid = '*';
alter system set log_archive_dest_state_3 = 'DEFER' scope = both sid = '*';
alter system set fal_server = 'PRODDB' scope = both sid = '*';
```

### Why the remaining standby also needs this

Its `log_archive_dest_3` is marked `VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE)`, so it
is dormant while the node is a standby — no errors are produced today. But after a
switchover it becomes the primary and will try to ship redo to a node that no longer
exists. Clean it now, not during a role transition.

`log_archive_dest_state_n` has no effect once the destination is empty. Setting it to
`DEFER` on every node simply keeps the configuration symmetric and avoids the
confusing "enabled state pointing at nothing" artifact.

---

## Phase 6 — Decommission the host

1. Archive the alert log and trace files for the record
2. Remove the node from monitoring and alerting
3. Remove backup jobs and cron entries referencing it
4. Clear the data and FRA filesystems
5. Update or remove the DNS record (see the DNS note above)
6. Release the VM
7. *(Optional, later)* Remove the address from `tnsnames.ora` in a maintenance window

---

## Verification

Run after Phase 5. All output should be clean.

```sql
-- Primary: destination is gone, only local + remaining standby survive
select name, value from v$parameter
where name like 'log_archive_dest_%' and name not like '%state%'
  and value is not null order by name;

select dest_id, destination, status, valid_role, error
from v$archive_dest where destination is not null order by dest_id;

select dest_id, dest_name, status, database_mode, recovery_mode, error
from v$archive_dest_status where status != 'INACTIVE' order by dest_id;
```

Expected on the primary: `dest_1` local `VALID`, `dest_2` `VALID` with the remaining
standby reported as `OPEN_READ-ONLY` / `MANAGED REAL TIME APPLY WITH QUERY`.

```sql
-- Both nodes: configuration is symmetric
select name, value from v$parameter
where name in ('log_archive_config','fal_server');
```

| Node | `log_archive_config` | `fal_server` |
|---|---|---|
| Primary | `DG_CONFIG=(PRODDB,PRODDB_S1)` | `PRODDB_S1` |
| Standby | `DG_CONFIG=(PRODDB,PRODDB_S1)` | `PRODDB` |

```sql
-- Remaining standby: apply is healthy
select name, value, datum_time from v$dataguard_stats
where name in ('transport lag','apply lag');

select process, status, thread#, sequence#
from v$managed_standby where process in ('MRP0','RFS');
```

Both lags should be `+00 00:00:00` with a recent `datum_time`, and `MRP0` should be
`APPLYING_LOG`.

### The decisive test

Static parameter checks are not enough. Force real redo transport and confirm no
errors are produced:

```sql
-- On the primary
alter system switch logfile;
alter system switch logfile;
```

Wait a few minutes, then:

```sql
select to_char(timestamp,'YYYY-MM-DD HH24:MI:SS') ts, severity, message
from v$dataguard_status
where severity in ('Error','Fatal','Warning')
  and timestamp > sysdate - 1/24
order by timestamp desc fetch first 20 rows only;
```

Only `Control` and `Informational` messages should appear during archiving. Any
mention of the removed `db_unique_name` means the destination is still live somewhere.

---

## Rollback

Possible through Phase 4 without restrictions, and through Phase 5 **provided the
archived logs needed to close the gap still exist**.

```sql
-- 1. Restore the configuration on every remaining node
alter system set log_archive_config = 'DG_CONFIG=(PRODDB,PRODDB_S1,PRODDB_S2)'
  scope = both sid = '*';
```

```sql
-- 2. Primary
alter system set log_archive_dest_3 =
  'SERVICE=PRODDB_S2 LGWR ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=PRODDB_S2'
  scope = both sid = '*';
alter system set log_archive_dest_state_3 = 'ENABLE' scope = both sid = '*';
alter system set fal_server = 'PRODDB_S1','PRODDB_S2' scope = both sid = '*';
```

```sql
-- 3. Remaining standby
alter system set log_archive_dest_3 =
  'SERVICE=PRODDB_S2 LGWR ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=PRODDB_S2'
  scope = both sid = '*';
alter system set log_archive_dest_state_3 = 'ENABLE' scope = both sid = '*';
alter system set fal_server = 'PRODDB','PRODDB_S1' scope = both sid = '*';
```

```sql
-- 4. Restarted node
startup mount;
alter database open read only;
alter database recover managed standby database using current logfile disconnect from session;
```

Then watch the gap close:

```sql
select * from v$archive_gap;
select process, status, sequence# from v$managed_standby where process = 'MRP0';
select name, value from v$dataguard_stats where name in ('transport lag','apply lag');
```

The role-based trigger restarts `PRODDB_RO` automatically once the database is open
read-only. Confirm with:

```sql
select name, network_name from v$active_services order by name;
```

If the archives are gone, recreate the standby with RMAN duplicate instead.

---

## With Data Guard Broker

If the configuration is broker-managed, Phases 3 and 5 collapse into two commands:

```
DGMGRL> disable database 'PRODDB_S2';
DGMGRL> remove database 'PRODDB_S2';
```

The broker updates `log_archive_dest_n`, `log_archive_config` and `fal_server` on
every remaining member itself, which eliminates the asymmetry risk described below.
Phases 1, 2, 4 and 6 still apply.

---

## Pitfalls

**Shutting down before deferring the destination.** Produces
`DB_UNIQUE_NAME ... is not in the Data Guard configuration` and `FAL: Error 12154`
entries on the primary. Harmless under `MAXIMUM PERFORMANCE`, disruptive under
`SYNC`. Order: drain → cancel apply → defer → shutdown.

**Forgetting the remaining standby.** The most common asymmetry bug. Its dormant
`PRIMARY_ROLE` destination produces no errors today and fails the day it is promoted.
Every member must be cleaned, not just the primary.

**`APPLIED ON ALL STANDBY` deletion policy.** Silently prevents archive reclamation
once one standby leaves the configuration, filling the FRA and stalling apply.

**Assuming the rollback window is open indefinitely.** It closes when the primary
reclaims the archived logs needed to close the gap.

**Verifying parameters only.** A destination can be absent from `v$parameter` and
still produce errors if a change was applied with `scope=memory` or if another member
still references the node. Force a log switch and read the Data Guard status view.

**Mixed `scope`.** Always use `scope=both`. `scope=memory` reverts on restart;
`scope=spfile` has no effect until restart, which is exactly the kind of surprise
that surfaces during a role transition months later.

---

## Post-removal checklist

- [ ] Both remaining nodes report identical `log_archive_config`
- [ ] `fal_server` points to the correct peer on each node
- [ ] No destination references the removed `db_unique_name` on any node
- [ ] Transport and apply lag are zero on the remaining standby
- [ ] Two forced log switches produce no `Error` or `Warning` entries
- [ ] Archived logs are being reclaimed (`percent_space_reclaimable` tracks usage)
- [ ] Role-based services are active on the correct nodes
- [ ] Monitoring, backup jobs and DNS updated
- [ ] Parameter-file backups taken after the change
