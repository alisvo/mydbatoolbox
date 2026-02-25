# 🔍 Oracle DB Health Monitoring

A lightweight, automated Oracle Database health monitoring solution that runs SQL checks every 30 minutes and delivers **HTML-formatted alert emails** when issues are detected — no monitoring software required.

---

## 📋 Table of Contents

- [Overview](#overview)
- [What It Monitors](#what-it-monitors)
- [How It Works](#how-it-works)
- [Directory Structure](#directory-structure)
- [Prerequisites](#prerequisites)
- [Installation on RHEL](#installation-on-rhel)
- [Crontab Setup](#crontab-setup)
- [Configuration Reference](#configuration-reference)
- [Email Alert Logic](#email-alert-logic)
- [Log Files](#log-files)

---

## Overview

This solution consists of two files:

| File | Type | Role |
|---|---|---|
| `monitoring.sql` | SQL\*Plus Script | Runs all health checks and generates an HTML report |
| `db_monitoring.sh` | Bash Script | Orchestrates SQL execution, parses results, and sends email alerts |

The shell script is invoked by cron every **30 minutes**, passing the `ORACLE_SID` as an argument. If any check returns a warning or error, a styled HTML email is dispatched to the DBA team via SMTP using `curl`.

---

## What It Monitors

### 1. 🗄️ Tablespace Usage (> 90%)
Queries `dba_data_files` and `dba_free_space` to calculate the percentage of used space across all permanent tablespaces (excluding UNDO). Alerts when any tablespace exceeds **90% of its maximum allocated size**.

### 2. 💽 ASM Disk Group Usage (> 90%)
Checks the `DATA` and `FRA` ASM disk groups via `v$asm_diskgroup`. Alerts when usable space drops below **10% of total capacity**.

### 3. 📼 Recovery Area (FRA) Usage (> 90%)
Monitors `v$recovery_file_dest` to track Fast Recovery Area consumption. Fires when the non-reclaimable portion exceeds **90%** of the defined limit.

### 4. 🔄 RMAN Backup Issues (Last 1 Hour)
Checks `v$rman_status` for three failure conditions — all on PRIMARY databases only:

- **Failed/Aborted** backup jobs within the last hour
- **DB/Controlfile backup missing** — no successful backup in the last **28 hours**
- **Archivelog backup missing** — no successful archivelog backup in the last **5 hours**

### 5. 🧠 High PGA Usage
A PL/SQL block that evaluates PGA consumption per RAC instance using a three-tier threshold logic:

| Mode | Parameter | Threshold |
|---|---|---|
| Hard Limit | `pga_aggregate_limit` | ≥ 90% |
| AMM Mode | `memory_target` (minus SGA used) | ≥ 95% |
| Soft Target | `pga_aggregate_target` | > 100% |

When triggered, it also reports the **top PGA-consuming session** (SID, serial#, username, MB used).

### 6. 🔒 Blocking Sessions (> 300 seconds)
Detects TX lock chains via `gv$lock` where a session has been waiting more than **5 minutes**. For each blocking scenario, the report includes:

- Blocker: SID, instance, username, status, locked objects
- Waiter: SID, instance, username, wait time in seconds, SQL text (first 100 chars)
- A ready-to-use `ALTER SYSTEM KILL SESSION` command
- Scheduled jobs (`J%` program) are flagged as `DONT_MAIL` to suppress noise

### 7. ⚙️ Parameter Limit Utilization (> 90%)
Queries `gv$resource_limit` for `sessions` and `processes` to detect when the instance is approaching its configured hard limits.

---

## How It Works

```
cron (every 30 min)
    │
    └─► db_monitoring.sh <ORACLE_SID>
            │
            ├─► sqlplus -s / as sysdba @monitoring.sql
            │       └─► Generates HTML report → db_result_<SID>.html
            │
            └─► send_alert()
                    ├─► Grep for: SEND_MAIL | error | ERROR | ORA-
                    ├─► [ALERT]  Build .eml payload with MIME headers + HTML body
                    │           └─► curl → SMTP server → DBA team inbox
                    └─► [CLEAN]  No issues? Delete the log file silently.
```

---

## Directory Structure

```
/home/oracle/scripts/monitoringv2/
├── db_monitoring.sh        # Main orchestration script
├── monitoring.sql          # SQL*Plus health check queries
└── log/
    ├── db_result_<SID>.html              # Active HTML report (deleted if healthy)
    └── db_result_<SID>.html_<TIMESTAMP>  # Archived reports after alert emails
```

---

## Prerequisites

- Oracle Database 19c+ (queries use `gv$` views — RAC compatible)
- `sqlplus` available and in PATH via `ORACLE_HOME`
- `curl` installed on the OS with access to the SMTP relay
- OS user `oracle` with SYSDBA privilege (for `/ as sysdba` connection)
- RHEL 7 / 8 / 9 (or compatible: OEL, CentOS Stream, Rocky Linux)

---

## Installation on RHEL

### 1. Copy Files to the Server

```bash
mkdir -p /home/oracle/scripts/monitoringv2/log
cp monitoring.sql   /home/oracle/scripts/monitoringv2/
cp db_monitoring.sh /home/oracle/scripts/monitoringv2/
```

### 2. Set Permissions

```bash
chmod 750 /home/oracle/scripts/monitoringv2/db_monitoring.sh
chmod 640 /home/oracle/scripts/monitoringv2/monitoring.sql
chown -R oracle:oinstall /home/oracle/scripts/monitoringv2/
```

### 3. Verify curl and SMTP Connectivity

```bash
# Check curl is available
curl --version

# Test SMTP reachability (replace with your mail server)
curl --url "smtp://mycompmailserver.mycompmail.com:25" \
     --mail-from "test@mycompmail.com" \
     --mail-rcpt "dbateam@mycompmail.com" \
     -T /dev/null
```

### 4. Update Configuration in `db_monitoring.sh`

Edit the configuration section at the top of the script:

```bash
ORACLE_HOME="/u01/app/oracle/product/19/dbhome_1"  # Path to your Oracle Home
EMAIL_TO="dbateam@mycompmail.com"                   # Alert recipients
EMAIL_FROM="oracle_alerts@mycompmail.com"           # Sender address
SMTP_URL="smtp://mycompmailserver.mycompmail.com:25" # Your SMTP relay
```

### 5. Test Manually

```bash
su - oracle
cd /home/oracle/scripts/monitoringv2
./db_monitoring.sh ORCL    # Replace ORCL with your actual SID
```

Check the log directory for the generated HTML file or confirm email delivery.

---

## Crontab Setup

Switch to the `oracle` OS user and edit the crontab:

```bash
su - oracle
crontab -e
```

Add the following entry to run every 30 minutes:

```cron
# Oracle DB Health Monitoring - every 30 minutes
*/30 * * * * /home/oracle/scripts/monitoringv2/db_monitoring.sh ORCL >> /home/oracle/scripts/monitoringv2/log/cron_ORCL.log 2>&1
```

> **Multiple Instances (RAC or multiple DBs):** Add one line per SID:
> ```cron
> */30 * * * * /home/oracle/scripts/monitoringv2/db_monitoring.sh ORCL1 >> /home/oracle/scripts/monitoringv2/log/cron_ORCL1.log 2>&1
> */30 * * * * /home/oracle/scripts/monitoringv2/db_monitoring.sh ORCL2 >> /home/oracle/scripts/monitoringv2/log/cron_ORCL2.log 2>&1
> ```

Verify the crontab is registered:

```bash
crontab -l
```

---

## Configuration Reference

| Variable | Default | Description |
|---|---|---|
| `ORACLE_SID` | `$1` (argument) | Target database SID |
| `ORACLE_BASE` | `/home/oracle/scripts/monitoringv2` | Script working directory |
| `ORACLE_HOME` | `/u01/app/oracle/product/19/dbhome_1` | Oracle binaries path |
| `LOG_DIR` | `${ORACLE_BASE}/log` | Directory for HTML output and archives |
| `EMAIL_TO` | `dbateam@mycompmail.com` | Alert recipient(s) |
| `EMAIL_FROM` | `oracle_alerts@mycompmail.com` | Sender address |
| `SMTP_URL` | `smtp://mycompmailserver...:25` | SMTP relay URL |

---

## Email Alert Logic

An alert email is sent **only when** the generated HTML report contains at least one of:

| Keyword | Triggered By |
|---|---|
| `SEND_MAIL` | Any monitoring check that found an issue |
| `ORA-` | Oracle errors from SQL*Plus execution |
| `ERROR` / `error` | Generic error strings in output |

If none of these are found, the log file is silently deleted and **no email is sent** — keeping the DBA inbox clean on healthy days.

> **Scheduler Jobs:** Blocking sessions caused by Oracle Scheduler jobs (program name matching `J%`) are labeled `DONT_MAIL` in the report body to provide visibility without noise.

---

## Log Files

| File Pattern | Description |
|---|---|
| `db_result_<SID>.html` | Latest HTML report; deleted automatically if no issues |
| `db_result_<SID>.html_<TIMESTAMP>` | Archived copy retained after each alert email sent |
| `cron_<SID>.log` | Stdout/stderr from cron execution (if redirected) |

---

> **Note:** All queries use `gv$` global views, making this solution **RAC-aware** out of the box. Single-instance databases are also fully supported.
