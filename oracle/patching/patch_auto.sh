#!/usr/bin/env bash
# Re-run under bash if started with sh
if [ -z "$BASH_VERSION" ]; then
  echo "Re-running under bash..."
  exec /bin/bash "$0" "$@"
fi

# ——— 0. Auto-detect DB instances & homes ———

# 0.1: detect running SIDs (your requested form, no process substitution)
IFS=$'\n' read -r -d '' DETECTED_SIDS_JOINED <<< "$(ps -ef | awk '/[p]mon_/ { for(i=1;i<=NF;i++) if($i~/^ora_pmon_/) print substr($i,10) }' | sort -u; printf '\0')"
IFS=$'\n' DETECTED_SIDS=($DETECTED_SIDS_JOINED)
unset IFS

# 0.2: read /etc/oratab for SID→ORACLE_HOME mapping
declare -A SID_ORACLE_HOME
while IFS=: read -r sid home _; do
  [[ -z "$sid" || "$sid" == "#"* ]] && continue
  SID_ORACLE_HOME["$sid"]="$home"
done < /etc/oratab

# 0.3: present and confirm/override
echo "Detected Oracle instances and homes:"
for sid in "${DETECTED_SIDS[@]}"; do
  echo "  • SID=$sid, HOME=${SID_ORACLE_HOME[$sid]:-<not found>}"
done
read -p "Accept all? [Y/n]: " yn
if [[ "$yn" =~ ^[Nn]$ ]]; then
  read -p "Enter ORACLE_HOME (or leave blank to keep per-SID): " GLOBAL_HOME
  read -p "Enter SIDs (space-separated): " -a DETECTED_SIDS
  for sid in "${DETECTED_SIDS[@]}"; do
    if [[ -n "$GLOBAL_HOME" ]]; then
      SID_ORACLE_HOME["$sid"]="$GLOBAL_HOME"
    else
      read -p "Home for SID $sid [${SID_ORACLE_HOME[$sid]}]: " h
      [[ -n "$h" ]] && SID_ORACLE_HOME["$sid"]="$h"
    fi
  done
fi

# ——— 1. Choose patching mode ———
echo
echo "Patching mode:"
echo "  1) Primary/standalone (RUN datapatch/sqlpatch, START databases)"
echo "  2) Data Guard standby-first (SKIP datapatch/utlrp, DO NOT start databases)"
read -p "Choice [1/2]: " PATCH_MODE
RUN_DATAPATCH=1
START_DATABASES=1
if [[ "$PATCH_MODE" == "2" ]]; then
  RUN_DATAPATCH=0
  START_DATABASES=0
  echo "Data Guard standby-first: will SKIP datapatch/utlrp and will NOT start databases."
fi

# ——— 2. Patch files ———
OPATCH_ZIP="p6880880_*.zip"
DB_RU_ZIP="p38291812_190000_Linux-x86-64.zip"
JVM_RU_ZIP="p38194382_190000_Linux-x86-64.zip"

# ——— 3. Logging ———
LOG_FILE="patching_log_$(date +%Y%m%d_%H%M%S).log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# ——— 4. Helpers ———
backup_opatch() {
  local OPATCH_DIR="$ORACLE_HOME/OPatch"
  local BACKUP_DATE
  BACKUP_DATE=$(date +%Y%m%d)
  local BACKUP_DIR="$ORACLE_HOME/OPatch_$BACKUP_DATE"

  log "Removing older OPatch backups..."
  find "$ORACLE_HOME" -maxdepth 1 -name "OPatch_[0-9]*" -type d -exec rm -rf {} + 2>/dev/null
  log "Older OPatch backups removed."

  if [ -d "$OPATCH_DIR" ]; then
    log "Backing up OPatch to $BACKUP_DIR..."
    cp -r "$OPATCH_DIR" "$BACKUP_DIR" || { log "ERROR: OPatch backup failed."; exit 1; }
    log "OPatch backup done."
  else
    log "No existing OPatch dir. Skipping backup."
  fi
}

stop_listener() {
  log "Stopping listener..."
  "$ORACLE_HOME/bin/lsnrctl" stop | tee -a "$LOG_FILE" || { log "ERROR: Listener stop failed."; exit 1; }
  log "Listener stopped."
}

start_listener() {
  log "Starting listener..."
  "$ORACLE_HOME/bin/lsnrctl" start | tee -a "$LOG_FILE" || { log "ERROR: Listener start failed."; exit 1; }
  log "Listener started."
}

apply_patch() {
  local PATCH_ZIP=$1
  local PATCH_NAME=$2

  if [ -z "$PATCH_ZIP" ]; then
    log "Skipping $PATCH_NAME: no zip specified."
    return
  fi

  if ls $PATCH_ZIP &>/dev/null; then
    local PATCH_DIR
    PATCH_DIR=$(basename "$PATCH_ZIP" | sed -n 's/^p\([0-9]*\)_.*$/\1/p')
    [ -z "$PATCH_DIR" ] && { log "ERROR: Could not parse patch dir from $PATCH_ZIP."; exit 1; }

    log "Unzipping $PATCH_NAME..."
    unzip -o "$PATCH_ZIP" | tee -a "$LOG_FILE" || { log "ERROR: Unzip failed for $PATCH_NAME."; exit 1; }

    log "Applying $PATCH_NAME with OPatch ($PATCH_DIR)..."
    "$ORACLE_HOME/OPatch/opatch" apply -silent "$PATCH_DIR" | tee -a "$LOG_FILE" || { log "ERROR: OPatch apply failed for $PATCH_NAME."; exit 1; }
    log "$PATCH_NAME applied."

    log "Cleaning up: $PATCH_DIR"
    rm -rf "$PATCH_DIR"
  else
    log "Skipping $PATCH_NAME: zip not found."
  fi
}

shutdown_database() {
  local SID=$1
  log "Shutting down $SID..."
  export ORACLE_SID=$SID
  "$ORACLE_HOME/bin/sqlplus" / as sysdba <<-EOF
    SHUTDOWN IMMEDIATE;
    EXIT;
EOF
  [[ $? -ne 0 ]] && { log "ERROR: Shutdown failed for $SID."; exit 1; }
  log "$SID down."
}

start_database() {
  local SID=$1
  log "Starting $SID..."
  export ORACLE_SID=$SID
  "$ORACLE_HOME/bin/sqlplus" / as sysdba <<-EOF
    STARTUP;
    EXIT;
EOF
  [[ $? -ne 0 ]] && { log "ERROR: Startup failed for $SID."; exit 1; }
  log "$SID up."
}

run_datapatch() {
  local SID=$1
  log "Running datapatch on $SID..."
  export ORACLE_SID=$SID
  "$ORACLE_HOME/OPatch/datapatch" -verbose | tee -a "$LOG_FILE" || { log "ERROR: datapatch failed for $SID."; exit 1; }
  log "datapatch completed for $SID."
}

run_utlrp() {
  local SID=$1
  log "Recompiling invalids on $SID..."
  export ORACLE_SID=$SID
  "$ORACLE_HOME/bin/sqlplus" / as sysdba <<-EOF
    @?/rdbms/admin/utlrp.sql;
    EXIT;
EOF
  [[ $? -ne 0 ]] && { log "ERROR: utlrp failed for $SID."; exit 1; }
  log "utlrp completed on $SID."
}

# ——— 5. Main ———
log "Starting database patching process…"

# Safety confirmation
read -r -p "Are you sure start patching? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
  log "Aborted by user."
  exit 0
fi

# Stop listener & shutdown per SID
for SID in "${DETECTED_SIDS[@]}"; do
  export ORACLE_HOME="${SID_ORACLE_HOME[$SID]}"
  stop_listener
  shutdown_database "$SID"
done

# Update OPatch if zip present
if ls $OPATCH_ZIP &>/dev/null; then
  backup_opatch
  log "Unzipping OPatch into \$ORACLE_HOME..."
  unzip -o "$OPATCH_ZIP" -d "$ORACLE_HOME" | tee -a "$LOG_FILE" || { log "ERROR: OPatch unzip failed."; exit 1; }
  log "OPatch updated."
else
  log "Skipping OPatch update: zip not found."
fi

# Apply Database & JVM RUs
apply_patch "$DB_RU_ZIP"  "Database RU"
apply_patch "$JVM_RU_ZIP" "JVM RU"

# Start DBs and (optionally) run datapatch & utlrp
for SID in "${DETECTED_SIDS[@]}"; do
  export ORACLE_HOME="${SID_ORACLE_HOME[$SID]}"

  if [[ "$START_DATABASES" -eq 1 ]]; then
    start_database "$SID"
  else
    log "Skipping database STARTUP for $SID (Data Guard standby-first mode)."
  fi

  if [[ "$RUN_DATAPATCH" -eq 1 ]]; then
    run_datapatch "$SID"
    run_utlrp     "$SID"
  else
    log "Skipping datapatch/utlrp for $SID (Data Guard standby-first mode)."
  fi
done

# Start listener at the end (safe either way)
start_listener

if [[ "$RUN_DATAPATCH" -eq 0 ]]; then
  log "REMINDER: In Data Guard standby-first, run datapatch later on the PRIMARY database after both sites are on the patched home and roles are stable."
  log "Example: \$ORACLE_HOME/OPatch/datapatch -verbose"
  log "Verify: SELECT status, action, description FROM dba_registry_sqlpatch ORDER BY action_time;"
fi

log "Patching process completed."
