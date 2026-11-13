#!/usr/bin/env bash

# =============================================================================
# oracle_patch.sh
# =============================================================================
# Description : Automated Oracle Database patching script for RHEL-based Linux
#               Supports combo patches (DBRU + OJVM)
# Execution   : As ROOT - direct (nohup) or via Ansible (become: true)
#               systemctl runs as root; every Oracle command (sqlplus, opatch,
#               datapatch, unzip into ORACLE_HOME) is run as ORACLE_USER via runuser.
# Patch dir   : Derived from ORACLE_HOME root -> /setup/
#               e.g. ORACLE_HOME=/u01/app/oracle/... -> /u01/setup/
# Flow        : 1) systemctl stop  (listener + databases)
#               2) per ORACLE_HOME: OPatch update -> DBRU -> OJVM -> cleanup
#               3) systemctl start (listener + databases)  -- ALWAYS runs
#               4) per PRIMARY database: datapatch -> utlrp
# Error policy: - Patch already in the inventory  -> skipped, NOT an error.
#               - Nothing to patch (no zip etc.)  -> logged, run continues.
#               - "opatch apply" really fails     -> patching STOPS: no further
#                 home is patched and datapatch/utlrp are skipped for the failed
#                 home. Fix the cause and re-run; applied patches are skipped.
#               In every case the service is started again and all problems
#               are listed in the final summary (exit code 1).
# =============================================================================
set -uo pipefail   # no "-e" on purpose: errors are handled explicitly

# =============================================================================
# USER CONFIGURATION - Edit these values before running
# =============================================================================
ORACLE_USER="oracle"                      # OS user that owns Oracle installations
ORATAB="/etc/oratab"                      # Path to oratab file

# systemd unit that stops/starts the listener AND the databases
ORACLE_SERVICE="oracle-db.service"
# How systemctl is called (the script itself runs as root)
SYSTEMCTL_CMD="systemctl"

# Seconds to wait for a database to come up after the service is started
DB_START_TIMEOUT=300

# Patch Number (Recommended to set manually if multiple patches exist in setup dir)
# This targets the main combo patch zip file (e.g., 35643107 for p35643107_190000_Linux-x86-64.zip)
MANUAL_COMBO_PATCH_NUM=""                 # e.g., "35643107" (Leave empty to auto-detect any p*.zip)

# Sub-Patch Configuration (Set manually if auto-detection fails to distinguish DBRU vs OJVM)
MANUAL_DBRU_PATCH_NUM=""                  # e.g., "38523462" (The DBRU sub-directory inside the combo)
MANUAL_OJVM_PATCH_NUM=""                  # e.g., "38523609" (The OJVM sub-directory inside the combo)

# =============================================================================
# INTERNAL - Do not edit below this line
# =============================================================================
SCRIPT_VERSION="3.2.0"
BASE_PATH=$PATH
SERVICE_STOP_ATTEMPTED=0
SERVICE_START_ATTEMPTED=0
declare -a ERRORS=()
declare -a FAILED_HOMES=()

# Helper function for logging
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Log an error and remember it for the final summary (never exits)
record_error() {
    log "ERROR: $1"
    ERRORS+=("$1")
}

# Ensure script is run as root and that the Oracle OS user exists
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Current user is $(whoami)."
    exit 1
fi
if ! id "${ORACLE_USER}" >/dev/null 2>&1; then
    echo "ERROR: OS user '${ORACLE_USER}' does not exist."
    exit 1
fi

# Run a command as the Oracle software owner, keeping the current environment
# (ORACLE_HOME, ORACLE_SID, ...), working directory and stdin.
# opatch/datapatch/sqlplus must NEVER run as root.
as_oracle() {
    runuser -u "$ORACLE_USER" -- env "PATH=$PATH" "$@"
}

# =============================================================================
# ENVIRONMENT / SERVICE / STATUS FUNCTIONS
# =============================================================================

setup_env() {
    local sid=$1
    local oh=$2

    export ORACLE_HOME=$oh
    export PATH=$ORACLE_HOME/bin:/usr/local/bin:/usr/bin:/bin:$BASE_PATH

    # Dynamically set ORACLE_BASE to prevent OCI-21500 environment errors
    if [[ -x "$ORACLE_HOME/bin/orabase" ]]; then
        ORACLE_BASE=$(as_oracle "$ORACLE_HOME/bin/orabase")
        export ORACLE_BASE
    fi
    export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib

    # Only export ORACLE_SID if a value was provided
    if [[ -n "$sid" ]]; then
        export ORACLE_SID=$sid
    fi
}

service_ctl() {
    local action=$1 # "stop" or "start"
    log "Running: $SYSTEMCTL_CMD $action $ORACLE_SERVICE"
    # shellcheck disable=SC2086
    if $SYSTEMCTL_CMD "$action" "$ORACLE_SERVICE"; then
        log "$ORACLE_SERVICE $action completed."
        return 0
    fi
    record_error "'$SYSTEMCTL_CMD $action $ORACLE_SERVICE' failed"
    return 1
}

# Safety net: if the script dies for any reason after the service was stopped,
# still try to bring the listener and the databases back.
on_exit() {
    if [[ $SERVICE_STOP_ATTEMPTED -eq 1 && $SERVICE_START_ATTEMPTED -eq 0 ]]; then
        log "Script is ending unexpectedly. Starting $ORACLE_SERVICE before exit..."
        SERVICE_START_ATTEMPTED=1
        service_ctl start
    fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

sids_for_home() {
    local oh=$1
    grep -E -v '^\s*#|^\s*$' "$ORATAB" | grep -i ':Y' | awk -F: -v oh="$oh" '$2 == oh {print $1}'
}

# Returns 0 if anything of this home is still running (instance or listener)
home_is_running() {
    local oh=$1
    local sid
    local running=1

    for sid in $(sids_for_home "$oh"); do
        if pgrep -f "^ora_pmon_${sid}\$" >/dev/null 2>&1; then
            log "Instance $sid is still running (ora_pmon_${sid})."
            running=0
        fi
    done

    if pgrep -f "^${oh}/bin/tnslsnr" >/dev/null 2>&1; then
        log "A listener is still running from $oh."
        running=0
    fi

    return $running
}

get_db_status() {
    local sid=$1
    local oh=$2
    setup_env "$sid" "$oh"

    local status
    status=$(as_oracle sqlplus -S -L / as sysdba 2>&1 <<EOF
set heading off feedback off pagesize 0 linesize 100
select status from v\$instance;
exit;
EOF
)

    # Trim whitespace and handle ORA errors
    status=$(echo "$status" | xargs 2>/dev/null)

    if [[ "$status" == *"Connected to an idle instance"* || "$status" == *"ORA-01034"* || "$status" == *"ORA-01081"* || -z "$status" ]]; then
        echo "DOWN"
    elif [[ "$status" == "OPEN" || "$status" == "MOUNTED" || "$status" == "STARTED" ]]; then
        echo "$status"
    else
        # Output unexpected errors (like OCI-21500) so caller can catch them
        echo "ERROR: $status"
    fi
}

get_db_role() {
    local sid=$1
    local oh=$2
    setup_env "$sid" "$oh"

    local role
    role=$(as_oracle sqlplus -S -L / as sysdba 2>&1 <<EOF
set heading off feedback off pagesize 0 linesize 100
select database_role from v\$database;
exit;
EOF
)
    # Trim whitespace
    echo "$role" | xargs 2>/dev/null
}

# Poll the instance until it reaches one of the wanted states or the timeout
# expires. Prints the last status seen. (No logging here: stdout is the result.)
wait_for_db() {
    local sid=$1
    local oh=$2
    local wanted=$3   # e.g. "OPEN MOUNTED"
    local timeout=$4
    local waited=0
    local status

    while true; do
        status=$(get_db_status "$sid" "$oh")
        if [[ " $wanted " == *" $status "* ]] || (( waited >= timeout )); then
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done

    echo "$status"
}

# =============================================================================
# PATCH DETECTION FUNCTIONS
# =============================================================================

get_patch_metadata() {
    local patch_dir=$1
    local inventory_xml="$patch_dir/etc/config/inventory.xml"

    if [[ -f "$inventory_xml" ]]; then
        grep -Eih '<patch_description>|<abstract>|<patch_type>|<product_family>' "$inventory_xml" 2>/dev/null || true
    fi
}

get_patch_summary() {
    local patch_dir=$1
    local summary

    summary=$(get_patch_metadata "$patch_dir" | sed -n 's/.*<patch_description>\(.*\)<\/patch_description>.*/\1/ip' | head -1)
    if [[ -z "$summary" ]]; then
        summary=$(get_patch_metadata "$patch_dir" | sed -n 's/.*<abstract>\(.*\)<\/abstract>.*/\1/ip' | head -1)
    fi

    echo "$summary" | xargs 2>/dev/null
}

classify_patch_dir() {
    local patch_dir=$1
    local metadata

    metadata=$(get_patch_metadata "$patch_dir" | tr '[:lower:]' '[:upper:]')

    if echo "$metadata" | grep -Eq 'OJVM|ORACLE JAVAVM|DATABASE JAVA VM|JAVA VM COMPONENT'; then
        echo "OJVM"
    elif echo "$metadata" | grep -Eq 'DATABASE RELEASE UPDATE|DATABASE RU|DBRU|DB RELEASE UPDATE|DB RU|DATABASE PROACTIVE BUNDLE'; then
        echo "DBRU"
    elif echo "$metadata" | grep -Eq 'OCW|CLUSTERWARE|ACFS|WLM|TOMCAT|JDK|GSM'; then
        echo "OTHER"
    else
        echo "UNKNOWN"
    fi
}

find_first_zip() {
    local search_dir=$1
    local include_name=$2
    local exclude_name=${3:-}
    local zip
    local zip_name

    while IFS= read -r zip; do
        zip_name=$(basename "$zip")
        # shellcheck disable=SC2053
        if [[ -n "$exclude_name" && "$zip_name" == $exclude_name ]]; then
            continue
        fi

        echo "$zip"
        return 0
    done < <(find "$search_dir" -maxdepth 1 -type f -name "$include_name" -print | sort)

    return 1
}

# Returns 0 if the given patch id is already registered in the home's inventory
patch_is_installed() {
    local opatch_bin=$1
    local patch_id=$2
    as_oracle "$opatch_bin" lspatches 2>/dev/null | grep -q "^${patch_id};"
}

# Apply one sub-patch. Returns 0 if applied or already installed, 1 on failure.
apply_subpatch() {
    local opatch_bin=$1
    local label=$2
    local patch_dir=$3
    local patch_id
    patch_id=$(basename "$patch_dir")

    if patch_is_installed "$opatch_bin" "$patch_id"; then
        log "--> $label patch $patch_id is already installed in this home. Skipping (not an error)."
        return 0
    fi

    log "--> Executing $label Patch from: $patch_dir"
    ( cd "$patch_dir" && as_oracle "$opatch_bin" apply -silent -local )
}

# =============================================================================
# BINARY PATCHING OF ONE ORACLE_HOME (OPATCH + DBRU + OJVM)
# Never exits. Returns 0 = patched or already patched
#                      1 = nothing was applied (no zip, no setup dir, ...)
#                      2 = "opatch apply" failed -> caller stops patching
# =============================================================================
patch_home() {
    local oh=$1
    local opatch_bin="$oh/OPatch/opatch"
    local setup_base opatch_zip backup_dir
    local combo_zip combo_zip_name patch_num combo_dir
    local dbru_dir="" ojvm_dir=""
    local patch_dir patch_basename patch_kind patch_summary
    local -a all_subpatch_dirs=()
    local -a unknown_subpatch_dirs=()

    setup_env "" "$oh"

    # Setup dizinini belirle (ORACLE_HOME root dizininden türetilir)
    # Örn: /u01/app/oracle/product/19/dbhome_1 -> /u01/setup
    setup_base=$(echo "$oh" | awk -F'/' '{print "/"$2"/setup"}')
    log "Derived setup directory: $setup_base"

    if [[ ! -d "$setup_base" ]]; then
        record_error "[$oh] Setup directory $setup_base does not exist. Binary patching skipped."
        return 1
    fi

    # --------------------------------------------------------
    # OPATCH UPDATE LOGIC (Patch 6880880)
    # --------------------------------------------------------
    if opatch_zip=$(find_first_zip "$setup_base" "p6880880_*.zip"); then
        log "Found OPatch update zip: $opatch_zip"
        backup_dir=""
        if [[ -d "$oh/OPatch" ]]; then
            backup_dir="$oh/OPatch_bak_$(date +%Y%m%d_%H%M%S)"
            log "Backing up existing OPatch to $backup_dir..."
            if ! as_oracle mv "$oh/OPatch" "$backup_dir"; then
                record_error "[$oh] Could not back up the existing OPatch directory. Keeping the current OPatch."
                backup_dir=""
                opatch_zip=""
            fi
        fi
        if [[ -n "$opatch_zip" ]]; then
            log "Extracting new OPatch to $oh..."
            if ! as_oracle unzip -o -q "$opatch_zip" -d "$oh"; then
                record_error "[$oh] Extracting $opatch_zip failed."
                if [[ -n "$backup_dir" ]]; then
                    log "Restoring previous OPatch from $backup_dir..."
                    as_oracle rm -rf "$oh/OPatch"
                    as_oracle mv "$backup_dir" "$oh/OPatch"
                fi
            fi
        fi
    else
        log "No OPatch update zip (p6880880_*.zip) found in $setup_base. Skipping OPatch update."
    fi

    log "Verifying OPatch version..."
    if ! as_oracle "$opatch_bin" version; then
        record_error "[$oh] opatch is not usable in $oh/OPatch. Binary patching skipped."
        return 1
    fi

    # --------------------------------------------------------
    # COMBO PATCH LOGIC
    # --------------------------------------------------------
    # Combo patch numarasını bul (Eğer manuel verilmemişse ilk zip dosyasını bul)
    combo_zip=""
    if [[ -n "$MANUAL_COMBO_PATCH_NUM" ]]; then
        combo_zip=$(find_first_zip "$setup_base" "p${MANUAL_COMBO_PATCH_NUM}_*.zip" "p6880880*") || true
    else
        combo_zip=$(find_first_zip "$setup_base" "p*.zip" "p6880880*") || true
    fi

    if [[ -z "$combo_zip" ]]; then
        record_error "[$oh] No combo patch zip file found in $setup_base. Binary patching skipped."
        return 1
    fi

    # Patch klasör adını zip adından türet (p35643107_190000_Linux-x86-64.zip -> 35643107)
    combo_zip_name=$(basename "$combo_zip")
    patch_num=$(echo "$combo_zip_name" | cut -d'_' -f1 | tr -d 'p')
    combo_dir="$setup_base/$patch_num"
    log "Detected Combo Patch Number: $patch_num"

    # Zip dosyasını çıkar (Eğer klasör yoksa)
    if [[ ! -d "$combo_dir" ]]; then
        log "Unzipping combo patch $combo_zip..."
        if ! as_oracle unzip -o -q "$combo_zip" -d "$setup_base"; then
            record_error "[$oh] Unzipping $combo_zip failed. Binary patching skipped."
            return 1
        fi
    fi

    if [[ ! -d "$combo_dir" ]]; then
        record_error "[$oh] Expected directory $combo_dir does not exist after unzip. Binary patching skipped."
        return 1
    fi

    # DBRU/OJVM sub-patch dizinlerini inventory.xml metadata'sına göre bul.
    # Fallback sadece metadata eksik olduğunda ve güvenli dar koşullarda kullanılır.
    while IFS= read -r -d '' patch_dir; do
        patch_basename=$(basename "$patch_dir")
        [[ "$patch_basename" =~ ^[0-9]{8}$ ]] || continue

        all_subpatch_dirs+=("$patch_dir")
        patch_kind=$(classify_patch_dir "$patch_dir")
        patch_summary=$(get_patch_summary "$patch_dir")

        if [[ -n "$patch_summary" ]]; then
            log "Detected sub-patch candidate $patch_basename: $patch_kind - $patch_summary"
        else
            log "Detected sub-patch candidate $patch_basename: $patch_kind - no inventory.xml summary found"
        fi

        case "$patch_kind" in
            DBRU)
                if [[ -z "$dbru_dir" ]]; then
                    dbru_dir="$patch_dir"
                else
                    log "WARNING: Multiple DBRU candidates found. Keeping $dbru_dir and ignoring $patch_dir"
                fi
                ;;
            OJVM)
                if [[ -z "$ojvm_dir" ]]; then
                    ojvm_dir="$patch_dir"
                else
                    log "WARNING: Multiple OJVM candidates found. Keeping $ojvm_dir and ignoring $patch_dir"
                fi
                ;;
            UNKNOWN)
                unknown_subpatch_dirs+=("$patch_dir")
                ;;
        esac
    done < <(find "$combo_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    if [[ ${#all_subpatch_dirs[@]} -eq 0 ]]; then
        record_error "[$oh] No numeric sub-patch directories found inside $combo_dir. Binary patching skipped."
        return 1
    fi

    if [[ -n "$MANUAL_DBRU_PATCH_NUM" ]]; then
        if [[ -d "$combo_dir/$MANUAL_DBRU_PATCH_NUM" ]]; then
            dbru_dir="$combo_dir/$MANUAL_DBRU_PATCH_NUM"
            log "Using manually configured DBRU patch directory: $dbru_dir"
        else
            record_error "[$oh] Manual DBRU patch directory was not found: $combo_dir/$MANUAL_DBRU_PATCH_NUM. Binary patching skipped."
            return 1
        fi
    fi

    if [[ -n "$MANUAL_OJVM_PATCH_NUM" ]]; then
        if [[ -d "$combo_dir/$MANUAL_OJVM_PATCH_NUM" ]]; then
            ojvm_dir="$combo_dir/$MANUAL_OJVM_PATCH_NUM"
            log "Using manually configured OJVM patch directory: $ojvm_dir"
        else
            record_error "[$oh] Manual OJVM patch directory was not found: $combo_dir/$MANUAL_OJVM_PATCH_NUM. Binary patching skipped."
            return 1
        fi
    fi

    if [[ -z "$dbru_dir" && ${#unknown_subpatch_dirs[@]} -gt 0 ]]; then
        dbru_dir="${unknown_subpatch_dirs[0]}"
        log "WARNING: DBRU metadata was not found. Falling back to first unknown numeric sub-patch as DBRU: $dbru_dir"
    fi

    if [[ -z "$ojvm_dir" && ${#all_subpatch_dirs[@]} -eq 2 && -n "$dbru_dir" ]]; then
        for patch_dir in "${all_subpatch_dirs[@]}"; do
            if [[ "$patch_dir" != "$dbru_dir" ]]; then
                ojvm_dir="$patch_dir"
                log "WARNING: OJVM metadata was not found. Falling back to the remaining sub-patch as OJVM: $ojvm_dir"
                break
            fi
        done
    fi

    if [[ -z "$dbru_dir" ]]; then
        record_error "[$oh] Could not identify the DBRU patch directory inside $patch_num. Set MANUAL_DBRU_PATCH_NUM. Binary patching skipped."
        return 1
    fi

    if [[ -n "$ojvm_dir" && "$dbru_dir" == "$ojvm_dir" ]]; then
        record_error "[$oh] DBRU and OJVM resolved to the same directory ($dbru_dir). Set MANUAL_DBRU_PATCH_NUM and MANUAL_OJVM_PATCH_NUM. Binary patching skipped."
        return 1
    fi

    # --------------------------------------------------------
    # APPLY
    # --------------------------------------------------------
    if ! apply_subpatch "$opatch_bin" "DBRU" "$dbru_dir"; then
        record_error "[$oh] opatch apply FAILED for DBRU ($dbru_dir). OJVM skipped; extracted patch kept in $combo_dir."
        return 2
    fi

    if [[ -n "$ojvm_dir" ]]; then
        if ! apply_subpatch "$opatch_bin" "OJVM" "$ojvm_dir"; then
            record_error "[$oh] opatch apply FAILED for OJVM ($ojvm_dir). Extracted patch kept in $combo_dir."
            return 2
        fi
    else
        log "WARNING: Could not identify OJVM patch directory inside $patch_num. Only DBRU was applied."
    fi

    log "OPatch binary updates completed."

    # --------------------------------------------------------
    # DISK CLEANUP (only after a clean apply)
    # --------------------------------------------------------
    if [[ -n "$patch_num" && -d "$combo_dir" ]]; then
        log "Cleaning up extracted patch directory to save disk space: $combo_dir"
        as_oracle rm -rf "$combo_dir"
    fi

    return 0
}

# =============================================================================
# POST-PATCH SQL ACTIONS FOR ONE DATABASE (datapatch + utlrp)
# Never exits. Problems are recorded and the caller moves on to the next SID.
# =============================================================================
post_patch_db() {
    local sid=$1
    local oh=$2
    local status role

    log "Waiting for database $sid (timeout ${DB_START_TIMEOUT}s)..."
    status=$(wait_for_db "$sid" "$oh" "OPEN MOUNTED" "$DB_START_TIMEOUT")

    if [[ "$status" != "OPEN" && "$status" != "MOUNTED" ]]; then
        record_error "[$sid] Database did not come up after starting $ORACLE_SERVICE (status: $status). datapatch/utlrp skipped."
        return 1
    fi

    role=$(get_db_role "$sid" "$oh")
    log "Database $sid status is $status, role is: $role"

    if [[ "$role" != "PRIMARY" ]]; then
        log "Skipping datapatch and utlrp for $sid. Database role is $role."
        return 0
    fi

    # A primary may still be on its way from MOUNT to OPEN
    if [[ "$status" != "OPEN" ]]; then
        status=$(wait_for_db "$sid" "$oh" "OPEN" 60)
    fi

    if [[ "$status" != "OPEN" ]]; then
        log "Database $sid is PRIMARY but $status. Trying to open it..."
        setup_env "$sid" "$oh"
        as_oracle sqlplus -S -L / as sysdba <<EOF
alter database open;
exit;
EOF
        status=$(get_db_status "$sid" "$oh")
        if [[ "$status" != "OPEN" ]]; then
            record_error "[$sid] PRIMARY database could not be opened (status: $status). datapatch/utlrp skipped."
            return 1
        fi
    fi

    setup_env "$sid" "$oh"

    log "Running datapatch for $sid to apply SQL changes (Role: PRIMARY)..."
    if ! ( cd "$oh/OPatch" && as_oracle ./datapatch -verbose ); then
        record_error "[$sid] datapatch failed. Check the datapatch logs under \$ORACLE_BASE/cfgtoollogs/sqlpatch."
    fi

    log "Running utlrp.sql for $sid to recompile any invalid objects..."
    if ! as_oracle sqlplus -S -L / as sysdba <<EOF
@?/rdbms/admin/utlrp.sql
exit;
EOF
    then
        record_error "[$sid] utlrp.sql could not be run."
    else
        log "Object recompilation finished for $sid."
    fi

    return 0
}

# =============================================================================
# MAIN EXECUTION BLOCK
# =============================================================================
log "Starting Oracle Patching Script v${SCRIPT_VERSION}"

# Start from a directory the Oracle user can read (not /root)
cd /tmp || exit 1

# Identify unique ORACLE_HOMEs from oratab
UNIQUE_HOMES=$(grep -E -v '^\s*#|^\s*$' "$ORATAB" | grep -i ':Y' | awk -F: '{print $2}' | sort -u)

if [[ -z "$UNIQUE_HOMES" ]]; then
    log "No ORACLE_HOME with ':Y' found in $ORATAB. Nothing to do."
    exit 0
fi

for ORATAB_OH in $UNIQUE_HOMES; do
    log "ORACLE_HOME: $ORATAB_OH  ->  databases: $(sids_for_home "$ORATAB_OH" | tr '\n' ' ')"
done

# ----------------------------------------------------------------------------
# 1. Stop listener + databases through systemd
# ----------------------------------------------------------------------------
log "========================================================"
log "STEP 1: Stopping $ORACLE_SERVICE"
log "========================================================"
SERVICE_STOP_ATTEMPTED=1
service_ctl stop

# Wait a few seconds for background processes to release binary file locks
sleep 5

# ----------------------------------------------------------------------------
# 2. Binary patching, home by home
# ----------------------------------------------------------------------------
for ORATAB_OH in $UNIQUE_HOMES; do
    log "========================================================"
    log "STEP 2: Binary patching ORACLE_HOME: $ORATAB_OH"
    log "========================================================"

    # Never run opatch against a home that is still in use
    if home_is_running "$ORATAB_OH"; then
        record_error "[$ORATAB_OH] Home is still in use after stopping $ORACLE_SERVICE. Binary patching skipped."
        continue
    fi

    patch_home "$ORATAB_OH"
    PATCH_RC=$?

    if [[ $PATCH_RC -eq 0 ]]; then
        log "Binary patching completed for ORACLE_HOME: $ORATAB_OH"
    elif [[ $PATCH_RC -eq 2 ]]; then
        FAILED_HOMES+=("$ORATAB_OH")
        log "STOPPING binary patching: opatch failed for $ORATAB_OH. Remaining homes (if any) are left untouched."
        break
    else
        log "Nothing was applied to ORACLE_HOME: $ORATAB_OH. Continuing."
    fi
done

# ----------------------------------------------------------------------------
# 3. Start listener + databases through systemd (always)
# ----------------------------------------------------------------------------
log "========================================================"
log "STEP 3: Starting $ORACLE_SERVICE"
log "========================================================"
SERVICE_START_ATTEMPTED=1
service_ctl start

# ----------------------------------------------------------------------------
# 4. Datapatch and UTLRP. Runs even if nothing was applied in this run, so a
#    datapatch that failed in an earlier run gets another chance. Skipped only
#    for a home where opatch failed in this run.
# ----------------------------------------------------------------------------
for ORATAB_OH in $UNIQUE_HOMES; do
    log "========================================================"
    log "STEP 4: Post-patch SQL actions for ORACLE_HOME: $ORATAB_OH"
    log "========================================================"

    if [[ " ${FAILED_HOMES[*]:-} " == *" $ORATAB_OH "* ]]; then
        log "Skipping datapatch/utlrp for this home because opatch failed. Fix the problem and re-run the script."
        continue
    fi

    for ORATAB_SID in $(sids_for_home "$ORATAB_OH"); do
        post_patch_db "$ORATAB_SID" "$ORATAB_OH"
    done
done

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
log "========================================================"
log "Patching script finished at $(date '+%Y-%m-%d %H:%M:%S')"
if [[ ${#ERRORS[@]} -eq 0 ]]; then
    log "RESULT: SUCCESS - no errors recorded."
    exit 0
fi

log "RESULT: COMPLETED WITH ${#ERRORS[@]} ERROR(S):"
for ERR in "${ERRORS[@]}"; do
    log "  - $ERR"
done
exit 1
