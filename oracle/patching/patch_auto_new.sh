#!/usr/bin/env bash
# Re-run under bash if started with sh
if [ -z "$BASH_VERSION" ]; then
  echo "Re-running under bash..."
  exec /bin/bash "$0" "$@"
fi

set -euo pipefail

# ——— 0. Auto-detect DB instances & homes ———

# 0.1: Detect running SIDs
mapfile -t DETECTED_SIDS < <(
  ps -ef \
    | awk '/[o]ra_pmon_/ { for(i=1;i<=NF;i++) if($i~/^ora_pmon_/) print substr($i,10) }' \
    | sort -u
)

if [[ ${#DETECTED_SIDS[@]} -eq 0 ]]; then
  echo "ERROR: No running Oracle instances detected (no ora_pmon_* processes found)."
  echo "       All databases may already be down, or this host has no Oracle instances."
  exit 1
fi

# 0.2: Read /etc/oratab for SID→ORACLE_HOME mapping
declare -A SID_ORACLE_HOME
if [[ ! -f /etc/oratab ]]; then
  echo "ERROR: /etc/oratab not found."
  exit 1
fi
while IFS=: read -r sid home _; do
  [[ -z "$sid" || "$sid" == "#"* ]] && continue
  SID_ORACLE_HOME["$sid"]="$home"
done < /etc/oratab

# 0.3: Present and confirm/override
echo "Detected Oracle instances and homes:"
for sid in "${DETECTED_SIDS[@]}"; do
  echo "  • SID=$sid, HOME=${SID_ORACLE_HOME[$sid]:-<not found in oratab>}"
done
read -r -p "Accept all? [Y/n]: " yn
if [[ "$yn" =~ ^[Nn]$ ]]; then
  read -r -p "Enter a global ORACLE_HOME (leave blank to keep per-SID values): " GLOBAL_HOME
  read -r -p "Enter SIDs (space-separated): " -a DETECTED_SIDS
  for sid in "${DETECTED_SIDS[@]}"; do
    if [[ -n "$GLOBAL_HOME" ]]; then
      SID_ORACLE_HOME["$sid"]="$GLOBAL_HOME"
    else
      read -r -p "Home for SID $sid [${SID_ORACLE_HOME[$sid]:-}]: " h
      [[ -n "$h" ]] && SID_ORACLE_HOME["$sid"]="$h"
    fi
  done
fi

# 0.4: Validate that every SID has a home assigned
for sid in "${DETECTED_SIDS[@]}"; do
  if [[ -z "${SID_ORACLE_HOME[$sid]:-}" ]]; then
    echo "ERROR: No ORACLE_HOME found for SID '$sid'. Add it to /etc/oratab or enter it manually."
    exit 1
  fi
done

# 0.5: Collect unique ORACLE_HOMEs (patching is per-home, not per-SID)
declare -A UNIQUE_HOMES
for sid in "${DETECTED_SIDS[@]}"; do
  UNIQUE_HOMES["${SID_ORACLE_HOME[$sid]}"]=1
done

# 0.6: Determine the listener's ORACLE_HOME.
#      Standalone environments run exactly one listener. Detect it from the
#      running process; fall back to the first SID's home.
LISTENER_HOME=""
LISTENER_HOME=$(
  ps -ef \
    | awk '/[t]nslsnr/ { for(i=1;i<=NF;i++) if($i~/tnslsnr/) { split($i,a,"/bin/"); print a[1]; exit } }'
)
if [[ -z "$LISTENER_HOME" ]]; then
  LISTENER_HOME="${SID_ORACLE_HOME[${DETECTED_SIDS[0]}]}"
  echo "WARNING: Could not detect listener ORACLE_HOME from process list."
  echo "         Defaulting to first SID home: $LISTENER_HOME"
fi
echo "Listener ORACLE_HOME: $LISTENER_HOME"

# ——— 1. Choose patching mode ———
echo
echo "Patching mode:"
echo "  1) Primary/standalone  – run datapatch & utlrp, start databases"
echo "  2) Data Guard standby-first – skip datapatch & utlrp, leave databases shut down"
read -r -p "Choice [1/2]: " PATCH_MODE
RUN_DATAPATCH=1
START_DATABASES=1
if [[ "$PATCH_MODE" == "2" ]]; then
  RUN_DATAPATCH=0
  START_DATABASES=0
  echo "Data Guard standby-first: datapatch/utlrp skipped; databases will NOT be started."
fi

# ——— 2. Patch files (hardcoded – update these for each RU cycle) ———
OPATCH_ZIP_PATTERN="p6880880_*.zip"
DB_RU_ZIP="p38291812_190000_Linux-x86-64.zip"
JVM_RU_ZIP="p38194382_190000_Linux-x86-64.zip"

# ——— 3. Logging ———
LOG_FILE="patching_log_$(date +%Y%m%d_%H%M%S).log"
# Ensure log dir is writable
if ! touch "$LOG_FILE" 2>/dev/null; then
  echo "ERROR: Cannot write log file '$LOG_FILE' in $(pwd). Aborting."
  exit 1
fi
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# ——— 4. Pre-flight checks ———
preflight_check() {
  local home=$1
  log "Pre-flight checks for ORACLE_HOME=$home"

  for bin in "$home/bin/sqlplus" "$home/bin/lsnrctl" "$home/OPatch/opatch" "$home/OPatch/datapatch"; do
    if [[ ! -x "$bin" ]]; then
      log "ERROR: Required binary not found or not executable: $bin"
      exit 1
    fi
  done

  # Rough free-space check: require at least 5 GB under ORACLE_HOME filesystem
  local required_kb=$((10 * 1024 * 1024))
  local free_kb
  free_kb=$(df -Pk "$home" | awk 'NR==2 {print $4}')
  if (( free_kb < required_kb )); then
    log "ERROR: Insufficient disk space under $home — ${free_kb}KB free, ${required_kb}KB required."
    exit 1
  fi
  log "Pre-flight OK for $home (free: ${free_kb}KB)"
}

# ——— 5. Helpers ———

backup_opatch() {
  local home=$1
  local opatch_dir="$home/OPatch"
  local backup_dir="${home}/OPatch_$(date +%Y%m%d_%H%M%S)"

  log "Removing older OPatch backups under $home..."
  find "$home" -maxdepth 1 -name "OPatch_[0-9]*" -type d -exec rm -rf {} + 2>/dev/null || true
  log "Older OPatch backups removed."

  if [[ -d "$opatch_dir" ]]; then
    log "Backing up OPatch to $backup_dir..."
    cp -r "$opatch_dir" "$backup_dir" \
      || { log "ERROR: OPatch backup failed for $home."; exit 1; }
    log "OPatch backup done: $backup_dir"
  else
    log "No existing OPatch directory found at $opatch_dir. Skipping backup."
  fi
}

stop_listener() {
  log "Stopping listener (home: $LISTENER_HOME)..."
  "$LISTENER_HOME/bin/lsnrctl" stop 2>&1 | tee -a "$LOG_FILE" || {
    log "WARNING: lsnrctl stop returned non-zero (listener may already be down). Continuing."
  }
  log "Listener stop sequence complete."
}

start_listener() {
  log "Starting listener (home: $LISTENER_HOME)..."
  "$LISTENER_HOME/bin/lsnrctl" start 2>&1 | tee -a "$LOG_FILE" \
    || { log "ERROR: Listener start failed."; exit 1; }
  log "Listener started."
}

update_opatch() {
  # Resolve the glob once so we handle filenames with spaces or multiple matches cleanly
  local opatch_zips
  mapfile -t opatch_zips < <(compgen -G "$OPATCH_ZIP_PATTERN" 2>/dev/null || true)

  if [[ ${#opatch_zips[@]} -eq 0 ]]; then
    log "Skipping OPatch update: no file matching '$OPATCH_ZIP_PATTERN' found."
    return
  fi
  if [[ ${#opatch_zips[@]} -gt 1 ]]; then
    log "WARNING: Multiple OPatch zips found (${opatch_zips[*]}). Using the first: ${opatch_zips[0]}"
  fi
  local opatch_zip="${opatch_zips[0]}"

  local home=$1
  backup_opatch "$home"
  log "Unzipping OPatch '$opatch_zip' into $home..."
  unzip -o "$opatch_zip" -d "$home" 2>&1 | tee -a "$LOG_FILE" \
    || { log "ERROR: OPatch unzip failed for $home."; exit 1; }
  log "OPatch updated for $home."
}

apply_patch() {
  local home=$1
  local patch_zip=$2
  local patch_name=$3

  if [[ -z "$patch_zip" ]]; then
    log "Skipping $patch_name: no zip specified."
    return
  fi
  if [[ ! -f "$patch_zip" ]]; then
    log "Skipping $patch_name: file '$patch_zip' not found."
    return
  fi

  # Extract numeric patch ID from filename (e.g. p38291812_… → 38291812)
  local patch_dir
  patch_dir=$(basename "$patch_zip" | sed -n 's/^p\([0-9]*\)_.*$/\1/p')
  if [[ -z "$patch_dir" ]]; then
    log "ERROR: Could not parse patch ID from filename '$patch_zip'."
    exit 1
  fi

  log "Unzipping $patch_name ($patch_zip)..."
  unzip -o "$patch_zip" 2>&1 | tee -a "$LOG_FILE" \
    || { log "ERROR: Unzip failed for $patch_name."; exit 1; }

  log "Applying $patch_name with OPatch (patch dir: $patch_dir, home: $home)..."
  ORACLE_HOME="$home" "$home/OPatch/opatch" apply -silent "$patch_dir" 2>&1 | tee -a "$LOG_FILE" \
    || { log "ERROR: OPatch apply failed for $patch_name on $home."; rm -rf "$patch_dir"; exit 1; }

  log "$patch_name applied to $home."
  log "Cleaning up unzipped patch directory: $patch_dir"
  rm -rf "$patch_dir"
}

shutdown_database() {
  local sid=$1
  local home="${SID_ORACLE_HOME[$sid]}"
  log "Shutting down $sid..."
  ORACLE_SID="$sid" ORACLE_HOME="$home" "$home/bin/sqlplus" -S / as sysdba <<-SQL
    WHENEVER SQLERROR EXIT FAILURE
    SHUTDOWN IMMEDIATE;
    EXIT;
SQL
  log "$sid is down."
}

start_database() {
  local sid=$1
  local home="${SID_ORACLE_HOME[$sid]}"
  log "Starting $sid..."
  ORACLE_SID="$sid" ORACLE_HOME="$home" "$home/bin/sqlplus" -S / as sysdba <<-SQL
    WHENEVER SQLERROR EXIT FAILURE
    STARTUP;
    EXIT;
SQL
  log "$sid is up."
}

run_datapatch() {
  local sid=$1
  local home="${SID_ORACLE_HOME[$sid]}"
  log "Running datapatch on $sid..."
  ORACLE_SID="$sid" ORACLE_HOME="$home" "$home/OPatch/datapatch" -verbose 2>&1 | tee -a "$LOG_FILE" \
    || { log "ERROR: datapatch failed for $sid."; exit 1; }
  log "datapatch completed for $sid."
}

run_utlrp() {
  local sid=$1
  local home="${SID_ORACLE_HOME[$sid]}"
  log "Recompiling invalid objects on $sid (utlrp)..."
  # utlrp can exit non-zero for pre-existing invalids unrelated to the patch.
  # We log the outcome but do NOT abort the script on failure.
  ORACLE_SID="$sid" ORACLE_HOME="$home" "$home/bin/sqlplus" -S / as sysdba <<-SQL 2>&1 | tee -a "$LOG_FILE" \
    || log "WARNING: utlrp exited non-zero on $sid — review the log for pre-existing invalids."
    @?/rdbms/admin/utlrp.sql
    EXIT;
SQL
  log "utlrp sequence complete on $sid."
}

# ——— 6. Main ———
log "========== Oracle Patching Script Started =========="
log "SIDs      : ${DETECTED_SIDS[*]}"
log "Homes     : ${!UNIQUE_HOMES[*]}"
log "Listener  : $LISTENER_HOME"
log "Mode      : $([ "$RUN_DATAPATCH" -eq 1 ] && echo 'Primary/standalone' || echo 'Data Guard standby-first')"

# Final safety confirmation
read -r -p "Proceed with patching? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  log "Aborted by user."
  exit 0
fi

# ——— Pre-flight for all unique homes ———
for home in "${!UNIQUE_HOMES[@]}"; do
  preflight_check "$home"
done

# ——— Stop listener ONCE (single listener assumption) ———
stop_listener

# ——— Shut down all databases ———
for sid in "${DETECTED_SIDS[@]}"; do
  shutdown_database "$sid"
done

# ——— Update OPatch and apply patches per unique ORACLE_HOME ———
for home in "${!UNIQUE_HOMES[@]}"; do
  log "---------- Patching ORACLE_HOME: $home ----------"
  update_opatch  "$home"
  apply_patch    "$home" "$DB_RU_ZIP"  "Database RU"
  apply_patch    "$home" "$JVM_RU_ZIP" "JVM RU"
done

# ——— Start databases and run post-patch steps per SID ———
for sid in "${DETECTED_SIDS[@]}"; do
  if [[ "$START_DATABASES" -eq 1 ]]; then
    start_database "$sid"
  else
    log "Skipping STARTUP for $sid (Data Guard standby-first mode)."
  fi

  if [[ "$RUN_DATAPATCH" -eq 1 ]]; then
    run_datapatch "$sid"
    run_utlrp     "$sid"
  else
    log "Skipping datapatch/utlrp for $sid (Data Guard standby-first mode)."
  fi
done

# ——— Start listener ONCE ———
start_listener

# ——— Reminders ———
if [[ "$RUN_DATAPATCH" -eq 0 ]]; then
  log ""
  log "REMINDER – Data Guard standby-first next steps:"
  log "  After both sites are on the patched home and roles are stable, run on the PRIMARY:"
  log "    \$ORACLE_HOME/OPatch/datapatch -verbose"
  log "  Verify with:"
  log "    SELECT status, action, description FROM dba_registry_sqlpatch ORDER BY action_time;"
fi

log "========== Patching Process Completed Successfully =========="
