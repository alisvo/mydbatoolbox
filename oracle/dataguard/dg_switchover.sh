#!/bin/sh
# Interactive Oracle Data Guard switchover helper.
# Run on the current primary as the oracle OS user.

set -u

SQLPLUS_BIN=${SQLPLUS:-sqlplus}
LOG_FILE=${DG_SWITCHOVER_LOG:-"./dg_switchover_$(date +%Y%m%d_%H%M%S).log"}
DG_RW_SERVICE=${DG_RW_SERVICE:-LSYBO19_RW}
DG_RO_SERVICE=${DG_RO_SERVICE:-LSYBO19_RO}
DG_RW_DSN=${DG_RW_DSN:-$DG_RW_SERVICE}
RUN_SQL_OUTPUT=
PRECHECK_FAILURES=0
PRECHECK_WARNINGS=0

usage() {
  cat <<'EOF'
Usage:
  ./dg_switchover.sh

Run this on the current primary as the oracle OS user. The script:
  1. Confirms the local database is the current primary and open READ WRITE.
  2. Runs Data Guard switchover pre-checks.
  3. Asks whether to continue.
  4. Lists standby DB_UNIQUE_NAME targets and asks you to choose one.
  5. Runs ALTER DATABASE SWITCHOVER TO <target> VERIFY.
  6. Asks for final confirmation before executing the switchover.
  7. Prints post-switchover verification commands.

Environment:
  SQLPLUS            sqlplus executable path. Defaults to sqlplus.
  DG_SWITCHOVER_LOG  log file path. Defaults to ./dg_switchover_YYYYMMDD_HHMMSS.log.
  DG_RW_SERVICE      Primary-role database service. Defaults to LSYBO19_RW.
  DG_RO_SERVICE      Standby read-only service. Defaults to LSYBO19_RO.
  DG_RW_DSN          Client TNS alias for the primary service. Defaults to DG_RW_SERVICE.
EOF
}

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

pass_check() {
  log "PASS: $*"
}

warn_check() {
  PRECHECK_WARNINGS=$((PRECHECK_WARNINGS + 1))
  log "WARN: $*"
}

fail_check() {
  PRECHECK_FAILURES=$((PRECHECK_FAILURES + 1))
  log "FAIL: $*"
}

run_sql() {
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/dg_sql.XXXXXX") || exit 1
  "$SQLPLUS_BIN" -L -s / as sysdba >"$tmp_file" 2>&1
  rc=$?
  RUN_SQL_OUTPUT=$(cat "$tmp_file")
  printf '%s\n' "$RUN_SQL_OUTPUT" | tee -a "$LOG_FILE"
  rm -f "$tmp_file"
  return "$rc"
}

query_sql() {
  "$SQLPLUS_BIN" -L -s / as sysdba
}

clean_value() {
  sed '/^$/d' | tail -1 | tr -d '\r' | sed 's/^ *//;s/ *$//'
}

validate_db_unique_name() {
  value=$1
  if ! printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_#$]+$'; then
    log "ERROR: invalid DB_UNIQUE_NAME '$value'. Choose a DB_UNIQUE_NAME, not a host name."
    exit 2
  fi
}

validate_service_name() {
  service_label=$1
  service_value=$2
  if ! printf '%s\n' "$service_value" | grep -Eq '^[A-Za-z0-9_.#$-]+$'; then
    log "ERROR: invalid $service_label value '$service_value'."
    exit 2
  fi
}

get_database_state() {
  query_sql <<'SQL' | clean_value
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT database_role || '|' || open_mode || '|' || db_unique_name || '|' || switchover_status
FROM v$database;
EXIT
SQL
}

check_local_primary() {
  log "Checking local database state at $(date)"
  log "Log file: $LOG_FILE"
  log ""

  state=$(get_database_state)
  role=$(printf '%s' "$state" | awk -F'|' '{print $1}' | sed 's/^ *//;s/ *$//')
  open_mode=$(printf '%s' "$state" | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//')
  db_unique_name=$(printf '%s' "$state" | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//')
  switchover_status=$(printf '%s' "$state" | awk -F'|' '{print $4}' | sed 's/^ *//;s/ *$//')

  if [ -z "$role" ] || [ -z "$open_mode" ]; then
    log "ERROR: could not query v\$database. Check ORACLE_HOME, ORACLE_SID, and sqlplus / as sysdba."
    exit 1
  fi

  log "Local database: db_unique_name=$db_unique_name role=$role open_mode=$open_mode switchover_status=$switchover_status"

  if [ "$role" != "PRIMARY" ]; then
    log "ERROR: this script must run from the current primary. Local role is '$role'."
    exit 1
  fi

  if [ "$open_mode" != "READ WRITE" ]; then
    log "ERROR: local primary is not open READ WRITE. Current open_mode='$open_mode'."
    exit 1
  fi
}

get_precheck_metrics() {
  query_sql <<SQL | clean_value
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT switchover_status || '|' ||
       force_logging || '|' ||
       flashback_on || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*)
                     FROM v\$archive_dest_status
                     WHERE type = 'PHYSICAL'
                       AND (status <> 'VALID' OR error IS NOT NULL)))) || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*)
                     FROM v\$dataguard_status
                     WHERE severity IN ('Error', 'Fatal')
                       AND timestamp > SYSDATE - 1))) || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*)
                     FROM v\$datafile
                     WHERE unrecoverable_time > SYSDATE - 1))) || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*) FROM v\$transaction))) || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*)
                     FROM v\$session
                     WHERE type = 'USER'
                       AND username IS NOT NULL
                       AND username NOT IN ('SYS', 'SYSTEM')
                       AND sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))))) || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*)
                     FROM v\$active_services
                     WHERE UPPER(name) = UPPER('$DG_RW_SERVICE')))) || '|' ||
       TRIM(TO_CHAR((SELECT COUNT(*)
                     FROM v\$active_services
                     WHERE UPPER(name) = UPPER('$DG_RO_SERVICE'))))
FROM v\$database;
EXIT
SQL
}

evaluate_precheck_results() {
  metrics=$(get_precheck_metrics)
  if [ -z "$metrics" ]; then
    fail_check "could not calculate pre-check metrics."
    return 1
  fi

  old_ifs=$IFS
  IFS='|' read -r metric_switchover_status metric_force_logging metric_flashback_on \
    metric_dest_problems metric_dg_errors metric_unrecoverable metric_transactions \
    metric_user_sessions metric_rw_services metric_ro_services <<EOF
$metrics
EOF
  IFS=$old_ifs

  log ""
  log "== Enforced pre-check result =="

  if [ "$metric_switchover_status" = "TO STANDBY" ]; then
    pass_check "primary SWITCHOVER_STATUS is TO STANDBY."
  else
    fail_check "primary SWITCHOVER_STATUS is '$metric_switchover_status'; required value is TO STANDBY."
  fi

  if [ "$metric_force_logging" = "YES" ]; then
    pass_check "FORCE_LOGGING is enabled."
  else
    warn_check "FORCE_LOGGING is '$metric_force_logging'. Standby consistency can be exposed to NOLOGGING operations."
  fi

  if [ "$metric_flashback_on" = "YES" ]; then
    pass_check "Flashback Database is enabled on the primary."
  else
    warn_check "Flashback Database is '$metric_flashback_on'. It is not required for switchover, but reduces recovery options after a failed role transition or failover."
  fi

  if [ "$metric_dest_problems" -eq 0 ]; then
    pass_check "all physical standby destinations currently have VALID status and no current error."
  else
    warn_check "$metric_dest_problems physical standby destination(s) currently have a non-VALID status or error. Only eligible targets will be listed."
  fi

  if [ "$metric_dg_errors" -eq 0 ]; then
    pass_check "no Error/Fatal Data Guard events were recorded in the last 24 hours."
  else
    warn_check "$metric_dg_errors Error/Fatal Data Guard event(s) were recorded in the last 24 hours; review the detailed output and alert logs."
  fi

  if [ "$metric_unrecoverable" -eq 0 ]; then
    pass_check "no datafiles report unrecoverable/NOLOGGING changes in the last 24 hours."
  else
    warn_check "$metric_unrecoverable datafile(s) report unrecoverable/NOLOGGING changes in the last 24 hours."
  fi

  if [ "$metric_transactions" -eq 0 ]; then
    pass_check "no active transactions were found."
  else
    warn_check "$metric_transactions active transaction(s) were found; drain application writes before switchover."
  fi

  if [ "$metric_user_sessions" -eq 0 ]; then
    pass_check "no non-SYS user sessions were found."
  else
    warn_check "$metric_user_sessions non-SYS user session(s) remain connected."
  fi

  if [ "$metric_rw_services" -eq 1 ]; then
    pass_check "$DG_RW_SERVICE is active on the primary."
  else
    warn_check "expected exactly one active $DG_RW_SERVICE service on the primary; found $metric_rw_services."
  fi

  if [ "$metric_ro_services" -eq 0 ]; then
    pass_check "$DG_RO_SERVICE is not active on the primary."
  else
    warn_check "$DG_RO_SERVICE is active on the primary ($metric_ro_services record(s)); verify your role-based service policy."
  fi

  log "Pre-check summary: failures=$PRECHECK_FAILURES warnings=$PRECHECK_WARNINGS"
  if [ "$PRECHECK_FAILURES" -ne 0 ]; then
    log "ERROR: enforced pre-checks failed. No switchover can be attempted."
    return 1
  fi

  return 0
}

run_prechecks() {
  log ""
  log "Running Data Guard switchover pre-checks..."

  run_sql <<'SQL'
SET LINESIZE 240 PAGESIZE 200 TRIMSPOOL ON VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE

PROMPT == Local database identity ==
COLUMN name FORMAT A12
COLUMN db_unique_name FORMAT A20
COLUMN database_role FORMAT A18
COLUMN open_mode FORMAT A22
COLUMN switchover_status FORMAT A22
COLUMN protection_mode FORMAT A24
COLUMN protection_level FORMAT A24
COLUMN force_logging FORMAT A14
COLUMN flashback_on FORMAT A14
SELECT name,
       db_unique_name,
       database_role,
       open_mode,
       switchover_status,
       protection_mode,
       protection_level,
       force_logging,
       flashback_on
FROM v$database;

PROMPT
PROMPT == Local instance ==
COLUMN instance_name FORMAT A18
COLUMN host_name FORMAT A35
COLUMN status FORMAT A12
COLUMN database_status FORMAT A18
SELECT instance_name, host_name, status, database_status
FROM v$instance;

PROMPT
PROMPT == Data Guard destinations ==
COLUMN dest_id FORMAT 999
COLUMN status FORMAT A12
COLUMN type FORMAT A12
COLUMN database_mode FORMAT A18
COLUMN recovery_mode FORMAT A28
COLUMN synchronization_status FORMAT A24
COLUMN synchronized FORMAT A12
COLUMN gap_status FORMAT A18
COLUMN db_unique_name FORMAT A22
COLUMN error FORMAT A80
SELECT dest_id,
       status,
       type,
       database_mode,
       recovery_mode,
       synchronization_status,
       synchronized,
       gap_status,
       db_unique_name,
       error
FROM v$archive_dest_status
WHERE type = 'PHYSICAL'
   OR (
        db_unique_name IS NOT NULL
    AND db_unique_name <> 'NONE'
    AND db_unique_name <> (SELECT db_unique_name FROM v$database)
      )
ORDER BY dest_id;

PROMPT
PROMPT == Standby lag check ==
PROMPT V$DATAGUARD_STATS lag is a standby-side metric and is not queried locally on this primary.
PROMPT Target synchronization, Redo Apply, and MRP are checked by ALTER DATABASE ... VERIFY.

PROMPT
PROMPT == Archive destination errors ==
COLUMN dest_id FORMAT 999
COLUMN status FORMAT A14
COLUMN error FORMAT A100
SELECT dest_id, status, error
FROM v$archive_dest
WHERE status <> 'INACTIVE'
  AND error IS NOT NULL
ORDER BY dest_id;

PROMPT
PROMPT == Error/Fatal Data Guard events in the last 24 hours ==
COLUMN severity FORMAT A12
COLUMN event_time FORMAT A20
COLUMN message FORMAT A120
SELECT severity,
       TO_CHAR(timestamp, 'YYYY-MM-DD HH24:MI:SS') AS event_time,
       message
FROM v$dataguard_status
WHERE severity IN ('Error', 'Fatal')
  AND timestamp > SYSDATE - 1
ORDER BY timestamp;

PROMPT
PROMPT == Unrecoverable/NOLOGGING datafile changes in the last 24 hours ==
COLUMN file_name FORMAT A100
COLUMN unrecoverable_time FORMAT A20
SELECT file#,
       name AS file_name,
       unrecoverable_change#,
       TO_CHAR(unrecoverable_time, 'YYYY-MM-DD HH24:MI:SS') AS unrecoverable_time
FROM v$datafile
WHERE unrecoverable_time > SYSDATE - 1
ORDER BY file#;

PROMPT
PROMPT == Connected application work ==
SELECT (SELECT COUNT(*) FROM v$transaction) AS active_transactions,
       (SELECT COUNT(*)
        FROM v$session
        WHERE type = 'USER'
          AND username IS NOT NULL
          AND username NOT IN ('SYS', 'SYSTEM')
          AND sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))) AS non_sys_user_sessions
FROM dual;

PROMPT
PROMPT == Active services ==
COLUMN name FORMAT A45
SELECT name
FROM v$active_services
ORDER BY name;

EXIT
SQL
}

known_standbys() {
  query_sql <<'SQL' | sed '/^$/d;s/^ *//;s/ *$//'
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT DISTINCT db_unique_name
FROM v$archive_dest_status
WHERE type = 'PHYSICAL'
  AND status = 'VALID'
  AND error IS NULL
  AND gap_status = 'NO GAP'
  AND recovery_mode LIKE 'MANAGED%'
  AND database_mode IN ('OPEN_READ-ONLY', 'MOUNTED-STANDBY')
  AND db_unique_name IS NOT NULL
  AND db_unique_name <> 'NONE'
  AND db_unique_name <> (SELECT db_unique_name FROM v$database)
ORDER BY db_unique_name;
EXIT
SQL
}

choose_target() {
  targets_file=$(mktemp "${TMPDIR:-/tmp}/dg_targets.XXXXXX") || exit 1
  if ! known_standbys >"$targets_file"; then
    rm -f "$targets_file"
    printf '%s\n' "ERROR: failed to query eligible standby targets." | tee -a "$LOG_FILE" >&2
    return 1
  fi

  if [ ! -s "$targets_file" ]; then
    rm -f "$targets_file"
    printf '%s\n' "ERROR: no eligible physical standby target is currently VALID, gap-free, and running managed recovery." | tee -a "$LOG_FILE" >&2
    return 1
  fi

  printf '\n' | tee -a "$LOG_FILE" >&2
  printf '%s\n' "Eligible standby DB_UNIQUE_NAME values:" | tee -a "$LOG_FILE" >&2
  nl -ba "$targets_file" | tee -a "$LOG_FILE" >&2
  printf 'Choose target number, or type one of the listed DB_UNIQUE_NAME values: ' >&2
  read -r selection

  case "$selection" in
    '' )
      rm -f "$targets_file"
      printf '\n'
      return
      ;;
    *[!0-9]* )
      chosen=$(awk -v requested="$selection" 'toupper($0) == toupper(requested) { print; exit }' "$targets_file")
      ;;
    * )
      chosen=$(sed -n "${selection}p" "$targets_file" | sed 's/^ *//;s/ *$//')
      ;;
  esac

  rm -f "$targets_file"
  if [ -z "$chosen" ]; then
    printf '%s\n' "ERROR: selection is not one of the eligible standby targets." | tee -a "$LOG_FILE" >&2
    return 2
  fi

  printf '%s\n' "$chosen"
  return 0
}

get_target_state() {
  target_name=$1
  query_sql <<SQL | clean_value
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT status || '|' ||
       database_mode || '|' ||
       recovery_mode || '|' ||
       gap_status || '|' ||
       NVL(error, 'NONE')
FROM v\$archive_dest_status
WHERE type = 'PHYSICAL'
  AND db_unique_name = UPPER('$target_name')
  AND ROWNUM = 1;
EXIT
SQL
}

check_target_eligibility() {
  target_name=$1
  target_state=$(get_target_state "$target_name")
  if [ -z "$target_state" ]; then
    log "FAIL: target $target_name is not visible as a physical standby destination from the primary."
    return 1
  fi

  old_ifs=$IFS
  IFS='|' read -r target_status target_database_mode target_recovery_mode target_gap_status target_error <<EOF
$target_state
EOF
  IFS=$old_ifs

  target_failed=0
  if [ "$target_status" != "VALID" ]; then
    log "FAIL: target $target_name destination status is '$target_status', not VALID."
    target_failed=1
  fi
  case "$target_database_mode" in
    OPEN_READ-ONLY|MOUNTED-STANDBY) ;;
    *)
      log "FAIL: target $target_name database mode is '$target_database_mode'."
      target_failed=1
      ;;
  esac
  case "$target_recovery_mode" in
    MANAGED*) ;;
    *)
      log "FAIL: target $target_name is not running managed recovery; recovery mode is '$target_recovery_mode'."
      target_failed=1
      ;;
  esac
  if [ "$target_gap_status" != "NO GAP" ]; then
    log "FAIL: target $target_name gap status is '$target_gap_status'."
    target_failed=1
  fi
  if [ "$target_error" != "NONE" ]; then
    log "FAIL: target $target_name reports destination error: $target_error"
    target_failed=1
  fi

  if [ "$target_failed" -ne 0 ]; then
    return 1
  fi

  log "PASS: target $target_name is VALID, $target_database_mode, $target_recovery_mode, and $target_gap_status."
  return 0
}

run_verify() {
  target=$1
  verify_phase=${2:-"dry-run"}
  log ""
  log "Running $verify_phase verify:"
  log "ALTER DATABASE SWITCHOVER TO $target VERIFY;"

  run_sql <<SQL
SET ECHO ON TIMING ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER DATABASE SWITCHOVER TO $target VERIFY;
EXIT
SQL
  verify_sql_rc=$?

  if printf '%s\n' "$RUN_SQL_OUTPUT" | grep -q 'ORA-16475'; then
    log "WARN: VERIFY succeeded with ORA-16475 warnings. Review the primary and target alert logs, correct or explicitly assess the warnings, then rerun this script."
    return 75
  fi

  return "$verify_sql_rc"
}

require_clean_verify() {
  verify_target=$1
  verify_phase=$2
  run_verify "$verify_target" "$verify_phase"
  verify_rc=$?

  if [ "$verify_rc" -eq 75 ]; then
    log "ERROR: switchover is blocked because VERIFY returned warnings for target $verify_target."
    return 1
  fi
  if [ "$verify_rc" -ne 0 ]; then
    log "ERROR: switchover VERIFY failed for target $verify_target. Actual switchover was not executed."
    return "$verify_rc"
  fi

  return 0
}

run_switchover() {
  target=$1
  log ""
  log "Executing switchover:"
  log "ALTER DATABASE SWITCHOVER TO $target;"

  run_sql <<SQL
SET ECHO ON TIMING ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER DATABASE SWITCHOVER TO $target;
EXIT
SQL
}

print_post_switchover_notes() {
  new_primary_name=$1
  new_standby_name=$2

  log ""
  log "Switchover command completed."
  log "Important: this script was running on the old primary. After switchover, Oracle may shut down or make this local instance unavailable."
  log "So the script intentionally does not query local v\$database after the switchover command."
  log "Database names below are dynamic DB_UNIQUE_NAME values; no host name or ORACLE_SID is hard-coded."
  log "New primary DB_UNIQUE_NAME: $new_primary_name"
  log "New standby DB_UNIQUE_NAME: $new_standby_name"
  log "Configured services: RW=$DG_RW_SERVICE RO=$DG_RO_SERVICE client_DSN=$DG_RW_DSN"
  log ""
  log "Post-switchover procedure:"
  log ""
  log "1. On the database host for the new primary ($new_primary_name):"
  log "   Connect with sqlplus / as sysdba."
  log "   If the instance is down and reports ORA-01034, start it mounted:"
  log "     STARTUP MOUNT;"
  log "   Check its role and open state:"
  log "   SELECT name, db_unique_name, database_role, open_mode, switchover_status FROM v\$database;"
  log "   It must report DATABASE_ROLE=PRIMARY. If it is MOUNTED, open it:"
  log "     ALTER DATABASE OPEN;"
  log "   Query v\$database again and require PRIMARY / READ WRITE before allowing application writes."
  log "   If the role is not PRIMARY, stop here and inspect both databases' alert logs; do not activate it manually."
  log ""
  log "   Verify role-based services and listener registration:"
  log "     SELECT name FROM v\$active_services"
  log "     WHERE UPPER(name) IN (UPPER('$DG_RW_SERVICE'), UPPER('$DG_RO_SERVICE')) ORDER BY name;"
  log "   Expected on the new primary: $DG_RW_SERVICE active and $DG_RO_SERVICE inactive."
  log "   If service automation has not reached that state, correct it using your production service procedure."
  log "     ALTER SYSTEM REGISTER;"
  log ""
  log "2. On the database host for the new standby / old primary ($new_standby_name):"
  log "   Connect with sqlplus / as sysdba. If the instance is down, start it mounted:"
  log "     STARTUP MOUNT;"
  log "   Confirm that the role changed before starting apply:"
  log "   SELECT name, db_unique_name, database_role, open_mode, switchover_status FROM v\$database;"
  log "   Require DATABASE_ROLE=PHYSICAL STANDBY. If it is not, stop and inspect the alert logs."
  log ""
  log "   For a mounted standby, leave it mounted. For licensed Active Data Guard read-only access, open it:"
  log "     ALTER DATABASE OPEN READ ONLY;"
  log "   Start Redo Apply:"
  log "     ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;"
  log "   Verify MOUNTED with apply, or READ ONLY WITH APPLY for Active Data Guard:"
  log "     SELECT database_role, open_mode FROM v\$database;"
  log "     SELECT role, thread#, sequence#, action FROM v\$dataguard_process ORDER BY role, thread#;"
  log "     SELECT name, value, time_computed, datum_time FROM v\$dataguard_stats"
  log "     WHERE name IN ('transport lag', 'apply lag', 'apply finish time') ORDER BY name;"
  log ""
  log "   Verify role-based services and register with the listener:"
  log "     SELECT name FROM v\$active_services"
  log "     WHERE UPPER(name) IN (UPPER('$DG_RW_SERVICE'), UPPER('$DG_RO_SERVICE')) ORDER BY name;"
  log "   Expected on a read-only standby: $DG_RO_SERVICE active and $DG_RW_SERVICE inactive."
  log "     ALTER SYSTEM REGISTER;"
  log ""
  log "3. Validate all standby destinations from the new primary:"
  log "     SELECT dest_id, status, database_mode, recovery_mode, gap_status, db_unique_name, error"
  log "     FROM v\$archive_dest_status WHERE type='PHYSICAL' ORDER BY dest_id;"
  log "   Require VALID status, managed recovery, NO GAP, and no current error for every required standby."
  log "   Generate a fresh archive and confirm it reaches/applies on the standbys:"
  log "     ALTER SYSTEM ARCHIVE LOG CURRENT;"
  log ""
  log "4. From the client side, rerun the Python TNS test with ORACLE_DSN=$DG_RW_DSN."
  log "   Confirm it reconnects to DB_UNIQUE_NAME=$new_primary_name with role=PRIMARY and open_mode=READ WRITE."
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage
    exit 2
    ;;
esac

if ! command -v "$SQLPLUS_BIN" >/dev/null 2>&1; then
  log "ERROR: sqlplus not found. Set ORACLE_HOME/PATH or export SQLPLUS=/path/to/sqlplus."
  exit 1
fi

validate_service_name "DG_RW_SERVICE" "$DG_RW_SERVICE"
validate_service_name "DG_RO_SERVICE" "$DG_RO_SERVICE"

check_local_primary
run_prechecks
precheck_rc=$?
if [ "$precheck_rc" -ne 0 ]; then
  log "ERROR: pre-check SQL failed. No switchover attempted."
  exit "$precheck_rc"
fi

if ! evaluate_precheck_results; then
  exit 1
fi

printf '\nContinue to choose a switchover target? Type YES to continue: '
read -r continue_choice
if [ "$continue_choice" != "YES" ]; then
  log "Stopped after pre-checks. No switchover attempted."
  exit 0
fi

TARGET_DB_UNIQUE_NAME=$(choose_target)
choose_rc=$?
if [ "$choose_rc" -ne 0 ]; then
  log "No target selected. No switchover attempted."
  exit "$choose_rc"
fi
validate_db_unique_name "$TARGET_DB_UNIQUE_NAME"
TARGET_DB_UNIQUE_NAME=$(printf '%s' "$TARGET_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')

if ! check_target_eligibility "$TARGET_DB_UNIQUE_NAME"; then
  log "ERROR: selected target is not eligible. No switchover attempted."
  exit 1
fi

if ! require_clean_verify "$TARGET_DB_UNIQUE_NAME" "dry-run"; then
  exit 1
fi

log ""
log "VERIFY passed for target $TARGET_DB_UNIQUE_NAME."
printf 'Execute actual switchover now? Type YES to continue: '
read -r final_choice
if [ "$final_choice" != "YES" ]; then
  log "Switchover cancelled after VERIFY. No actual switchover executed."
  exit 0
fi

log ""
log "Final target recheck after confirmation..."
if ! check_target_eligibility "$TARGET_DB_UNIQUE_NAME"; then
  log "ERROR: target eligibility changed after the first VERIFY. No switchover attempted."
  exit 1
fi

if ! require_clean_verify "$TARGET_DB_UNIQUE_NAME" "final immediate"; then
  exit 1
fi
log "Final VERIFY passed. Executing switchover without another pause."

run_switchover "$TARGET_DB_UNIQUE_NAME"
switch_rc=$?
if [ "$switch_rc" -ne 0 ]; then
  log "ERROR: switchover command failed. Review $LOG_FILE and Oracle alert logs."
  exit "$switch_rc"
fi

print_post_switchover_notes "$TARGET_DB_UNIQUE_NAME" "$db_unique_name"
log "Finished at $(date)."
