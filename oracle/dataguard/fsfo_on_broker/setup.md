# Data Guard Broker + Fast-Start Failover + Observer — Phases 2–6: Setup

This document adds Data Guard Broker, Fast-Start Failover (FSFO) and an Observer to an **existing, manually managed** physical standby configuration, **online**: the primary stays open and applications keep working throughout.

Complete [Phase 1 — Pre-Checks](broker_fsfo_01_prechecks.md) first.

| Phase | Content | Impact |
|---|---|---|
| [2](#phase-2--static-listener-entries-and-broker-start) | Static `_DGMGRL` listener entries, `dg_broker_start` | None |
| [3](#phase-3--create-the-broker-configuration) | Clear manual destinations, create and enable the configuration | Redo shipping pauses for a few minutes; primary keeps running |
| [4](#phase-4--broker-properties-and-switchover-test) | Broker properties, switchover test | Planned role change (sessions reconnect) |
| [5](#phase-5--observer-host-wallet-and-service) | Observer host: wallet, start script, systemd service | None |
| [6](#phase-6--enable-fsfo-and-start-the-observer) | FSFO properties, enable FSFO, start the observer | None |

## Example environment

| Role | Host | DB_UNIQUE_NAME |
|---|---|---|
| Primary | `ol9dg1` | `ORCL_DG1` |
| Physical standby | `ol9dg2` | `ORCL_DG2` |
| Observer | `ol9obs` | — (Oracle software only, no database) |

- Oracle Database 19c (19.31), single instance, no Oracle Clusterware, CDB with one PDB
- `ORACLE_SID = ORCL` on both database hosts, `ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1`
- Transport **ASYNC**, protection mode **Maximum Performance** (notes for SYNC are included where it differs)
- TNS aliases `ORCL_DG1` and `ORCL_DG2` resolve on all three hosts
- Starting point: no broker (`dg_broker_start = FALSE`), `log_archive_dest_2` and `fal_server` set manually with `ALTER SYSTEM`

Unless stated otherwise, run everything as the **`oracle`** OS user. "SQL" means `sqlplus / as sysdba` on that host. Replace `<sys_password>` and `<wallet_password>` with your own values.

> **Without the broker, redo apply does not start by itself.** If the standby was restarted while still manually managed, start apply before you begin:
> ```sql
> alter database recover managed standby database disconnect;
> ```

---

# Phase 2 — Static listener entries and broker start

No impact on applications; redo transport is not interrupted.

## 2.1 Back up listener.ora

**Where:** primary and standby · Shell

```bash
cp -p $ORACLE_HOME/network/admin/listener.ora $ORACLE_HOME/network/admin/listener.ora.before_broker
```

## 2.2 Add the static `_DGMGRL` entry

**Where:** primary and standby · edit `$ORACLE_HOME/network/admin/listener.ora`

Add a second `SID_DESC` whose `GLOBAL_DBNAME` is `<DB_UNIQUE_NAME>_DGMGRL`.

On `ol9dg1`:
```
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = ORCL_DG1)(ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)(SID_NAME = ORCL))
    (SID_DESC = (GLOBAL_DBNAME = ORCL_DG1_DGMGRL)(ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)(SID_NAME = ORCL)))
```
On `ol9dg2`: the same, with `ORCL_DG2` and `ORCL_DG2_DGMGRL`.

**Why:** during a switchover or reinstatement the broker shuts an instance down and has to start it again. A stopped instance cannot register itself with the listener, so DGMGRL can only reach it through this static entry. With Oracle Clusterware/Restart this entry is not needed.

> **Pitfalls (both happened in this walkthrough):**
> * **Unbalanced parentheses.** One extra `)` and the listener silently ignores the new entry: no error, the service just never appears. The first `SID_DESC` line ends with `))`, the last one with `)))`.
> * **Copy-paste between nodes.** On the standby the entry must use the **standby's** `DB_UNIQUE_NAME`. A wrong name produces no listener error and only surfaces at the first switchover. Step 2.4 catches both problems.

## 2.3 Reload the listener

**Where:** primary and standby · Shell

```bash
lsnrctl reload
lsnrctl status | grep -A1 DGMGRL
```

**Expected:**
```
Service "ORCL_DG1_DGMGRL" has 1 instance(s).
  Instance "ORCL", status UNKNOWN, has 1 handler(s) for this service...
```
`status UNKNOWN` is normal for a static registration. `reload` keeps existing connections; do not use `stop`/`start`.

## 2.4 Test the static services

**Where:** primary (test both directions) · Shell

```bash
echo "select db_unique_name from v\$database;" | sqlplus -s -L "sys/<sys_password>@//ol9dg1.lab.local:1521/ORCL_DG1_DGMGRL as sysdba"
echo "select db_unique_name from v\$database;" | sqlplus -s -L "sys/<sys_password>@//ol9dg2.lab.local:1521/ORCL_DG2_DGMGRL as sysdba"
```

**Expected:** `ORCL_DG1` and `ORCL_DG2`.
`ORA-12514` means the entry is misspelled, has the wrong name, or the listener was not reloaded.

## 2.5 Check the broker configuration file locations

**Where:** primary and standby · SQL

```sql
show parameter dg_broker
```

**Expected:** `dg_broker_start = FALSE`, and
```
dg_broker_config_file1 = $ORACLE_HOME/dbs/dr1<DB_UNIQUE_NAME>.dat
dg_broker_config_file2 = $ORACLE_HOME/dbs/dr2<DB_UNIQUE_NAME>.dat
```

These defaults are derived automatically from `DB_UNIQUE_NAME`. The broker keeps two copies of its configuration for redundancy, and each database has its own pair.

* Single instance: the defaults are fine.
* RAC: all instances must see the same files, so point both parameters to shared storage (ASM).
* The parameters can only be changed while `dg_broker_start = FALSE`, which is why this check comes before 2.6.

## 2.6 Start the broker

**Where:** primary and standby · SQL

```sql
alter system set dg_broker_start=TRUE scope=both;
```
```bash
ps -ef | grep [o]ra_dmon
ls -l $ORACLE_HOME/dbs/dr*
```

**Expected:** the `ora_dmon_ORCL` process is running, and both `dr1*.dat` / `dr2*.dat` files now exist (8 KB each).

> **Note:** the files are created as empty skeletons as soon as the DMON process starts, not at `CREATE CONFIGURATION`. If you later remove the broker completely, set `dg_broker_start=FALSE` **and** delete these files.

## 2.7 Verify

**Where:** primary · Shell

```bash
dgmgrl sys/<sys_password>@ORCL_DG1 "show configuration"
```

**Expected:**
```
ORA-16532: Oracle Data Guard broker configuration does not exist
```
This is the result you want: the broker is running and has no configuration yet. (`ORA-16525` would mean the broker is not running.) At this point the broker changes nothing; redo transport continues as before.

## Phase 2 rollback

```sql
alter system set dg_broker_start=FALSE scope=both;
```
```bash
rm $ORACLE_HOME/dbs/dr1<DB_UNIQUE_NAME>.dat $ORACLE_HOME/dbs/dr2<DB_UNIQUE_NAME>.dat
cp -p $ORACLE_HOME/network/admin/listener.ora.before_broker $ORACLE_HOME/network/admin/listener.ora
lsnrctl reload
```

---

# Phase 3 — Create the broker configuration

**The critical window:** from clearing `log_archive_dest_2` on the primary (3.3) until `ENABLE CONFIGURATION` (3.5), **no redo is shipped**. The primary keeps running and the standby catches up automatically afterwards. In production, run 3.3 to 3.5 back to back.

## 3.1 Record the current values

**Where:** primary and standby · SQL

```sql
show parameter log_archive_dest_2
show parameter fal_server
```
Save the output; it is your rollback reference. On the standby, also confirm there is no lag:
```sql
col value for a20
select name, value from v$dataguard_stats where name in ('transport lag','apply lag');
```

## 3.2 Create the configuration

**Where:** primary · DGMGRL

```bash
dgmgrl sys/<sys_password>@ORCL_DG1
```
```
CREATE CONFIGURATION dgcfg AS PRIMARY DATABASE IS ORCL_DG1 CONNECT IDENTIFIER IS ORCL_DG1;
```
**Expected:** `Configuration "dgcfg" created with primary database "orcl_dg1"`

## 3.3 Clear the manually set destinations

The broker insists on managing redo transport destinations itself. If you try to add the standby while a manual destination exists, you get:

```
DGMGRL> ADD DATABASE ORCL_DG2 AS CONNECT IDENTIFIER IS ORCL_DG2 MAINTAINED AS PHYSICAL;
Error: ORA-16698: member has a LOG_ARCHIVE_DEST_n parameter with SERVICE attribute set
```

> **Observed on 19.31:** `CREATE CONFIGURATION` succeeds even with a manual destination on the primary; the check fires at `ADD DATABASE`.

Clear the destination on the **standby first, then the primary** (SQL on each host):
```sql
alter system set log_archive_dest_2='' scope=both;
```
The standby's destination is inactive anyway (`valid_for=(online_logfiles,primary_role)`), so clearing it has no effect. **Redo shipping stops when you run it on the primary.** Continue immediately.

## 3.4 Add the standby

**Where:** primary · DGMGRL

```
ADD DATABASE ORCL_DG2 AS CONNECT IDENTIFIER IS ORCL_DG2 MAINTAINED AS PHYSICAL;
SHOW CONFIGURATION;
```
**Expected:** `Database "orcl_dg2" added`, both members listed, `Configuration Status: DISABLED`.

## 3.5 Enable the configuration

```
ENABLE CONFIGURATION;
```
Wait 30–60 seconds, then:
```
SHOW CONFIGURATION;
```
**Expected:**
```
  Protection Mode: MaxPerformance
  Members:
  orcl_dg1 - Primary database
    orcl_dg2 - Physical standby database

Fast-Start Failover:  Disabled

Configuration Status:
SUCCESS
```
A `WARNING` in the first minute is normal while the standby catches up.

> **`SHOW CONFIGURATION` is not live.** It shows the result of the broker's last health check; look at `(status updated N seconds ago)`. Right after a change, a `SUCCESS` (or a missing warning) may be older than your change. Only trust a status that was updated **after** it.

## 3.6 See what the broker did

**DGMGRL:**
```
SHOW DATABASE ORCL_DG2;
SHOW DATABASE ORCL_DG1 LogXptMode;
SHOW DATABASE ORCL_DG1 StaticConnectIdentifier;
SHOW DATABASE ORCL_DG2 StaticConnectIdentifier;
```
**Expected:**
* `Intended State: APPLY-ON`, transport and apply lag `0 seconds`, `Database Status: SUCCESS`
* `LogXptMode = 'ASYNC'` (the 19c default)
* `StaticConnectIdentifier` contains `SERVICE_NAME=ORCL_DG1_DGMGRL` / `ORCL_DG2_DGMGRL` (the entries from Phase 2)

**Primary, SQL:**
```sql
show parameter log_archive_dest_2
```
**Expected:** a broker-generated value such as `service="orcl_dg2", ASYNC NOAFFIRM ... db_unique_name="orcl_dg2" ...`

## 3.7 Validate

```
VALIDATE DATABASE ORCL_DG2;
```
**Expected:**
```
  Ready for Switchover:  Yes
  Ready for Failover:    Yes (Primary Running)

  Managed by Clusterware:
    orcl_dg1:  NO
    orcl_dg2:  NO
    Validating static connect identifier for the primary database orcl_dg1...
    The static connect identifier allows for a connection to database "orcl_dg1".
```

## Rules from now on

* **Do not change Data Guard parameters with `ALTER SYSTEM`** (`log_archive_dest_n`, `log_archive_config`, `fal_server`, ...). Use `EDIT DATABASE ... SET PROPERTY` in DGMGRL; the broker overrides or flags manual changes.
* **The broker manages redo apply.** After a standby restart, apply now starts by itself.

## Phase 3 rollback

```
REMOVE CONFIGURATION PRESERVE DESTINATIONS;
```
`PRESERVE DESTINATIONS` keeps the broker-written `log_archive_dest_n` so redo keeps flowing. Then restore the values saved in 3.1 with `ALTER SYSTEM` on both sides.

---

# Phase 4 — Broker properties and switchover test

Prove that the broker can run a role change **before** you let it fail over automatically.

## 4.1 Review the properties

**Where:** primary · DGMGRL (`dgmgrl sys/<sys_password>@ORCL_DG1`)

```
SHOW CONFIGURATION;
SHOW DATABASE VERBOSE ORCL_DG1;
```

| Property | Expected | Meaning |
|---|---|---|
| Protection Mode | `MaxPerformance` | As designed |
| `LogXptMode` | `ASYNC` | Redo transport mode |
| `DelayMins` | `0` | No apply delay |
| `StandbyFileManagement` | empty or `AUTO` | Empty means the broker does not manage it and the database parameter applies (must be `AUTO` there) |
| `StaticConnectIdentifier` | contains `..._DGMGRL` | From Phase 2 |

## 4.2 Set the transport mode explicitly for both directions

```
EDIT DATABASE ORCL_DG1 SET PROPERTY LogXptMode='ASYNC';
EDIT DATABASE ORCL_DG2 SET PROPERTY LogXptMode='ASYNC';
```
For ASYNC this only documents the intent, since ASYNC is the default. `LogXptMode` describes how redo is sent **to** that database while it is a standby, so it must be set on both members to survive a role change.

> **SYNC variant:** set `LogXptMode='SYNC'` on **both** members, then
> `EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability;`
> If you set SYNC on one member only, transport silently falls back to ASYNC after a switchover.

## 4.3 Switchover to the standby

```
VALIDATE DATABASE ORCL_DG2;
SWITCHOVER TO ORCL_DG2;
```
**Expected:**
```
Performing switchover NOW, please wait...
New primary database "orcl_dg2" is opening...
Operation requires start up of instance "ORCL" on database "orcl_dg1"
Starting instance "ORCL"...
Database mounted.
Switchover succeeded, new primary is "orcl_dg2"
```
A switchover is a planned operation with no data loss, but application sessions are disconnected and must reconnect. Do it in a maintenance window.

```
SHOW CONFIGURATION;
```
**Expected:** `orcl_dg2 - Primary database`, `orcl_dg1 - Physical standby database`, `SUCCESS`.

## 4.4 Switch back

```
VALIDATE DATABASE ORCL_DG1;
SWITCHOVER TO ORCL_DG1;
SHOW CONFIGURATION;
SHOW DATABASE ORCL_DG2;
```
**Expected:** `Switchover succeeded, new primary is "orcl_dg1"`, `SUCCESS`, standby `APPLY-ON` with zero lag.

> **Pitfall: never run role changes from `dgmgrl /`.**
> `dgmgrl /` uses OS authentication, which is valid only for the **local** database. During `SWITCHOVER`, `FAILOVER`, `REINSTATE` and `VALIDATE`, DGMGRL must also connect **over the network to the other database** (to restart the old primary through its static listener entry), and it reuses the credentials you logged in with. With `/` there are none:
> ```
> Validating static connect identifier for the primary database orcl_dg2...
> ORA-01017: invalid username/password; logon denied
> Warning: Ensure primary database's StaticConnectIdentifier property is configured properly ...
> ```
> The warning text is misleading; the static identifier is fine. Always connect as `user/password@tns_alias` (or `/@tns_alias` with a wallet, see Phase 5). To avoid the password on the command line, start `dgmgrl` and use `CONNECT sys@ORCL_DG1`, which prompts for it.

---

# Phase 5 — Observer host: wallet and service

Everything in this phase happens on the **observer host**; the databases are not touched.

**Requirements:** an Oracle Database home or an Oracle Client (**Administrator** install type) of the same version as the databases. Instant Client does not include `dgmgrl`. Place the observer on a third host, ideally at a third site or next to the application tier, never on the primary or the standby host.

Steps 5.1–5.6 run as **`oracle`**, step 5.7 as **`root`**. If you create the directories as root by mistake, `mkstore` fails; fix it with `chown oracle:oinstall <dir>`. When switching users use `su - oracle` (with the dash) so the Oracle environment is loaded.

## 5.1 Directories

```bash
mkdir -p /u01/app/oracle/wallet /u01/app/oracle/observer
chmod 700 /u01/app/oracle/wallet
```
`/u01/app/oracle/observer` will hold the observer's state file (`fsfo.dat`) and log (`observer.log`).

## 5.2 Create the wallet

```bash
mkstore -wrl /u01/app/oracle/wallet -create
```
You are asked for a new **wallet password** (at least 8 characters, letters and digits). It is separate from the SYS password and is only needed to change the wallet's contents.

## 5.3 Add credentials for both databases

```bash
mkstore -wrl /u01/app/oracle/wallet -createCredential ORCL_DG1 sys
mkstore -wrl /u01/app/oracle/wallet -createCredential ORCL_DG2 sys
mkstore -wrl /u01/app/oracle/wallet -listCredential
```
Each `-createCredential` prompts for the SYS password (twice) and then the wallet password. The list shows the two entries without passwords.

The wallet maps a **TNS alias** to a user and password: "when connecting to `ORCL_DG1`, log in as `sys` with this password".

## 5.4 Point SQL*Net to the wallet

```bash
cat >> $ORACLE_HOME/network/admin/sqlnet.ora <<'EOF'
WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = /u01/app/oracle/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
EOF
```

## 5.5 Test password-less connections

```bash
dgmgrl /@ORCL_DG1 "show configuration"
dgmgrl /@ORCL_DG2 "show configuration"
dgmgrl /@orcl_dg1 "show configuration"
```
**Expected:** `Connected to "ORCL_DGx"`, `Connected as SYSDBA`, and the configuration, for all three.

`/@ORCL_DG1` means "take the user and password from the wallet". Do not confuse it with `dgmgrl /` (local OS authentication): this is a real network login as SYS, so it also works for role changes.

The third test uses the lowercase alias because the broker stores connect identifiers in lowercase and the observer uses those. It worked here without extra entries; if it fails with `ORA-01017`, add credentials for the lowercase aliases as well.

## 5.6 Observer start script

```bash
cat > /home/oracle/start_observer.sh <<'EOF'
#!/bin/bash
# Starts the FSFO observer using the wallet; connects to whichever database is reachable.
. ~/.bash_profile
cd /u01/app/oracle/observer
for db in ORCL_DG1 ORCL_DG2; do
  if dgmgrl -silent /@$db "show configuration" >/dev/null 2>&1; then
    exec dgmgrl -silent /@$db "start observer obs1 file is '/u01/app/oracle/observer/fsfo.dat' logfile is '/u01/app/oracle/observer/observer.log'"
  fi
done
echo "no database reachable"; exit 1
EOF
chmod 700 /home/oracle/start_observer.sh
```
The script tries both databases because the observer host may reboot after a failover, when the former primary is down. It contains no password.

## 5.7 systemd service (as root; do not start it yet)

```bash
cat > /etc/systemd/system/dg-observer.service <<'EOF'
[Unit]
Description=Oracle Data Guard FSFO Observer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=oracle
Group=oinstall
ExecStart=/home/oracle/start_observer.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl status dg-observer --no-pager | head -3
```
**Expected:** `Loaded: loaded (...; disabled; ...)`, `Active: inactive (dead)`.

> **Use `Restart=on-failure`, not `Restart=always`.** With `always`, a deliberate `STOP OBSERVER` in DGMGRL is undone by systemd a few seconds later; the observer re-registers, and broker commands such as `REMOVE CONFIGURATION` can hang for minutes. With `on-failure` the observer is restarted after a crash but stays down when stopped on purpose.

---

# Phase 6 — Enable FSFO and start the observer

No impact on applications. Order matters: properties, then FSFO, then the observer.

## 6.1 Define the failover targets

**Where:** primary · DGMGRL (`dgmgrl sys/<sys_password>@ORCL_DG1`)

```
EDIT DATABASE ORCL_DG1 SET PROPERTY FastStartFailoverTarget='ORCL_DG2';
EDIT DATABASE ORCL_DG2 SET PROPERTY FastStartFailoverTarget='ORCL_DG1';
```
Set it in both directions so FSFO keeps working after a role change. With more than one standby, list the candidates in order of preference, for example `'ORCL_DG2,ORCL_DG3'`.

## 6.2 Set the FSFO properties

```
EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=30;
EDIT CONFIGURATION SET PROPERTY FastStartFailoverLagLimit=30;
EDIT CONFIGURATION SET PROPERTY FastStartFailoverAutoReinstate=TRUE;
EDIT CONFIGURATION SET PROPERTY ObserverReconnect=10;
```

| Property | Value | Meaning |
|---|---|---|
| `FastStartFailoverThreshold` | 30 s | How long the primary must be unreachable (for the observer **and** the standby) before failover starts. Too low: failovers on network blips. Too high: longer outage. |
| `FastStartFailoverLagLimit` | 30 s | **ASYNC / MaxPerformance only.** If the standby is further behind than this, no automatic failover happens. It is also the upper bound of data loss when one does. Choose it from your RPO. |
| `FastStartFailoverAutoReinstate` | TRUE | The old primary is flashed back and converted to a standby automatically when it returns (requires Flashback Database on both sides). |
| `ObserverReconnect` | 10 s | The observer renews its primary connection at this interval, which detects hung connections. |

Related default worth knowing: `FastStartFailoverPmyShutdown = TRUE`. A primary that loses contact with both the observer and the standby for longer than the threshold shuts itself down, which prevents a split brain.

## 6.3 Enable FSFO

```
ENABLE FAST_START FAILOVER;
SHOW CONFIGURATION;
```
**Expected:**
```
Enabled in Potential Data Loss Mode.
...
  orcl_dg1 - Primary database
    Warning: ORA-16819: fast-start failover observer not started
    orcl_dg2 - (*) Physical standby database

Fast-Start Failover: Enabled in Potential Data Loss Mode

Configuration Status:
WARNING
```
* **Potential Data Loss Mode** is the ASYNC / MaxPerformance mode. With SYNC / MaxAvailability it reads `Enabled in Zero Data Loss Mode`.
* `(*)` marks the failover target.
* `ORA-16819` is expected until the observer runs. It may take up to a minute to appear (see the note about status age in 3.5). Until the observer is started, **no automatic failover can happen**.

## 6.4 Start the observer

**Where:** observer host · **root**

```bash
systemctl enable --now dg-observer
sleep 15
systemctl status dg-observer --no-pager | head -8
tail -10 /u01/app/oracle/observer/observer.log
```
**Expected:** `Active: active (running)` and in the log:
```
Observer 'obs1' started
... Try to connect to the primary orcl_dg1.
... The standby orcl_dg2 is ready to be a FSFO target
... Connection to the primary restored!
```
The observer registers itself with the configuration; there is no separate "add observer" command.

## 6.5 Verify

**Where:** primary · DGMGRL (wait about a minute)

```
SHOW CONFIGURATION;
SHOW FAST_START FAILOVER;
SHOW OBSERVER;
```
**Expected:**
```
Fast-Start Failover: Enabled in Potential Data Loss Mode

  Protection Mode:    MaxPerformance
  Lag Limit:          30 seconds
  Threshold:          30 seconds
  Active Target:      orcl_dg2
  Potential Targets:  "ORCL_DG2"
    orcl_dg2   valid
  Observer:           obs1
  Shutdown Primary:   TRUE
  Auto-reinstate:     TRUE
  Observer Reconnect: 10 seconds
```
```
Observer "obs1" - Master

  Host Name:                    ol9obs.lab.local
  Last Ping to Primary:         2 seconds ago
  Last Ping to Target:          2 seconds ago
```
and `SHOW CONFIGURATION` returns `SUCCESS` without warnings once its status has been refreshed.

The same output lists the **health conditions** that trigger an immediate failover even when the primary is reachable (by default: corrupted controlfile, corrupted dictionary, datafile write errors). Add more with `ENABLE FAST_START FAILOVER CONDITION "Stuck Archiver";`.

## 6.6 Confirm no password is exposed

**Where:** observer host

```bash
ps -ef | grep "[d]gmgrl"
grep -c "<sys_password>" /home/oracle/start_observer.sh
```
**Expected:** the process list shows `dgmgrl -silent ... start observer obs1 ...` with **no password**, and `grep` returns `0`.

## Stopping the observer

In DGMGRL:
```
STOP OBSERVER obs1;
```
The process exits cleanly and systemd does not restart it (`Restart=on-failure`). Add `systemctl disable dg-observer` as root if it should not start at boot.

## Phase 6 rollback

```
DISABLE FAST_START FAILOVER;
```
and on the observer host as root: `systemctl disable --now dg-observer`.

---

# When FSFO does and does not fail over

| Situation | Automatic failover? |
|---|---|
| Primary host or instance crashes (power loss, `shutdown abort`) | **Yes**, after the threshold |
| Primary is isolated from both the observer and the standby | **Yes**; the isolated primary shuts itself down |
| A configured health condition fires (for example datafile write errors) | **Yes**, immediately |
| Clean shutdown (`shutdown immediate` / `normal`) | No: a deliberate action |
| Observer is not running | No: nobody can decide |
| Only the observer loses the primary; the standby still sees it | No |
| Standby lag exceeds `FastStartFailoverLagLimit` (ASYNC) | No |
| Standby is down or not synchronized (SYNC / zero data loss mode) | No |

---

# Summary checklist

| # | Check | Result |
|---|---|---|
| 2 | `_DGMGRL` services registered and reachable in both directions | ☐ |
| 2 | `dg_broker_start = TRUE` on both, `ORA-16532` before the configuration exists | ☐ |
| 3 | Manual `log_archive_dest_2` values saved, then cleared | ☐ |
| 3 | Configuration enabled, `SUCCESS`, zero lag | ☐ |
| 3 | `VALIDATE DATABASE`: ready for switchover, static connect identifier OK | ☐ |
| 4 | Switchover and switch back succeeded | ☐ |
| 5 | Wallet logins work for both databases (`dgmgrl /@alias`) | ☐ |
| 5 | Observer service defined with `Restart=on-failure` | ☐ |
| 6 | FSFO enabled, target `valid`, observer pinging both databases | ☐ |
| 6 | No password in scripts or the process list | ☐ |

---

*Previous: [Phase 1 — Pre-Checks](broker_fsfo_01_prechecks.md) · Next: Phase 7 — Failover test and reinstatement*
