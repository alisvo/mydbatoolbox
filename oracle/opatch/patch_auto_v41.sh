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
#
# Flow        : STEP 1  Analysis, NO downtime. Per ORACLE_HOME: read the patch
#                       ids from the combo zip (metadata only, no full unzip)
#                       and compare them with "opatch lspatches".
#               STEP 2  Only if at least one home needs binary patching:
#                       systemctl stop -> OPatch apply (DBRU, OJVM) -> systemctl start
#               STEP 3  Per PRIMARY database:
#                       - home patched in this run -> datapatch + utlrp
#                       - otherwise "datapatch -prereq" decides:
#                           SQL changes pending -> datapatch + utlrp (no restart)
#                           nothing pending     -> utlrp only (optional)
#
# Scenarios   : a) binaries OK, SQL pending  -> no shutdown, datapatch + utlrp
#               b) binaries need patching    -> full flow
#               c) nothing needed            -> no shutdown, utlrp only
#
# Error policy: - Nothing to do is never an error.
#               - "opatch apply" really fails -> patching STOPS: no further home
#                 is patched and datapatch/utlrp are skipped for the failed home.
#                 Fix the cause and re-run; whatever is installed is skipped.
#               - If the service was stopped it is ALWAYS started again.
#               - All problems are listed in the final summary (exit code 1).
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

# Run utlrp.sql even when neither binary patching nor datapatch was needed
UTLRP_WHEN_NOTHING_TO_PATCH="yes"         # "yes" or "no"

# Patch Number (Recommended to set manually if multiple patches exist in setup dir)
# This targets the main combo patch zip file (e.g., 35643107 for p35643107_190000_Linux-x86-64.zip)
MANUAL_COMBO_PATCH_NUM=""                 # e.g., "35643107" (Leave empty to auto-detect any p*.zip)

# Sub-Patch Configuration (Set manually if auto-detection fails to distinguish DBRU vs OJVM)
MANUAL_DBRU_PATCH_NUM=""                  # e.g., "38523462" (The DBRU sub-directory inside the combo)
MANUAL_OJVM_PATCH_NUM=""                  # e.g., "38523609" (The OJVM sub-directory inside the combo)

# =============================================================================
# INTERNAL - Do not edit below this line
# =============================================================================
SCRIPT_VERSION="4.1.1"
BASE_PATH=$PATH
SERVICE_STOP_ATTEMPTED=0
SERVICE_START_ATTEMPTED=0
declare -a ERRORS=()
declare -a HOMES_TO_PATCH=()    # homes where at least one binary patch is missing
declare -a PATCHED_HOMES=()     # homes successfully patched in this run
declare -a FAILED_HOMES=()      # homes where "opatch apply" failed in this run
declare -A PLAN_COMBO_ZIP=()    # home -> combo zip file
declare -A PLAN_COMBO_DIR=()    # home -> directory the combo zip extracts to
declare -A PLAN_DBRU=()         # home -> DBRU patch id to apply ("" = nothing to do)
declare -A PLAN_OJVM=()         # home -> OJVM patch id to apply ("" = nothing to do)

# Helper function for logging
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Log an error and remember it for the final summary (never exits)
record_error() {
    log "ERROR: $1"
    ERRORS+=("$1")
}

# in_list <item> <list elements...>
in_list() {
    local item=$1
    local element
    shift
    for element in "$@"; do
        [[ "$element" == "$item" ]] && return 0
    done
    return 1
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
# expires (timeout 0 = check once). Prints the last status seen.
# (No logging here: stdout is the result.)
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
    local installed

    # Capture the output first: piping opatch straight into "grep -q" makes
    # opatch die with SIGPIPE on a match, which pipefail then reports as failure.
    installed=$(as_oracle "$opatch_bin" lspatches 2>/dev/null) || true
    grep -q "^${patch_id};" <<<"$installed"
}

# Prints the OPatch version (e.g. 12.2.0.1.55) of an OPatch directory or of a
# p6880880 zip. Prints nothing if it cannot be read.
opatch_version_of() {
    local source=$1
    local raw=""
    if [[ -d "$source" ]]; then
        raw=$(cat "$source/version.txt" 2>/dev/null)
    elif [[ -f "$source" ]]; then
        raw=$(unzip -p "$source" OPatch/version.txt 2>/dev/null)
    fi
    raw=$(tr -d '[:space:]' <<<"$raw")
    echo "${raw#OPATCH_VERSION:}"
}

# version_newer <a> <b> : returns 0 only if version a is strictly newer than b
version_newer() {
    local a=$1
    local b=$2
    [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
}

# Replace $ORACLE_HOME/OPatch with the p6880880 zip from the setup directory,
# but ONLY if the zip is newer than what the home has (no downgrade).
# If a version cannot be read (zip or home), the zip is assumed to be the
# newest and is extracted. Safe while the database is running.
update_opatch() {
    local oh=$1
    local setup_base=$2
    local zip zip_ver opatch_zip="" best_ver="" cur_ver backup_dir=""

    # If several p6880880 zips exist, take the one with the highest version.
    # A zip whose version cannot be read is assumed to be the newest.
    while IFS= read -r zip; do
        zip_ver=$(opatch_version_of "$zip")
        if [[ -z "$zip_ver" ]]; then
            log "WARNING: Could not read the OPatch version inside $zip. Assuming it is the newest."
            best_ver="unknown"
            opatch_zip=$zip
            break
        fi
        log "Found OPatch zip: $zip (version $zip_ver)"
        if [[ -z "$best_ver" ]] || version_newer "$zip_ver" "$best_ver"; then
            best_ver=$zip_ver
            opatch_zip=$zip
        fi
    done < <(find "$setup_base" -maxdepth 1 -type f -name "p6880880_*.zip" -print | sort)

    if [[ -z "$opatch_zip" ]]; then
        log "No OPatch update zip (p6880880_*.zip) found in $setup_base. Skipping OPatch update."
        return 0
    fi

    if [[ -d "$oh/OPatch" ]]; then
        cur_ver=$(opatch_version_of "$oh/OPatch")
        if [[ "$best_ver" == "unknown" || -z "$cur_ver" ]]; then
            log "OPatch in this home is ${cur_ver:-unknown}, zip is $best_ver: cannot compare, assuming the zip is newer. Updating."
        elif ! version_newer "$best_ver" "$cur_ver"; then
            log "OPatch in this home is $cur_ver, zip is $best_ver: not newer. Skipping OPatch update."
            return 0
        else
            log "OPatch in this home is $cur_ver, zip is $best_ver: updating."
        fi

        backup_dir="$oh/OPatch_bak_$(date +%Y%m%d_%H%M%S)"
        log "Backing up existing OPatch to $backup_dir..."
        if ! as_oracle mv "$oh/OPatch" "$backup_dir"; then
            record_error "[$oh] Could not back up the existing OPatch directory. Keeping the current OPatch."
            return 1
        fi
    else
        log "No OPatch directory in this home. Installing OPatch $best_ver."
    fi

    log "Extracting new OPatch to $oh..."
    if ! as_oracle unzip -o -q "$opatch_zip" -d "$oh"; then
        record_error "[$oh] Extracting $opatch_zip failed."
        if [[ -n "$backup_dir" ]]; then
            log "Restoring previous OPatch from $backup_dir..."
            as_oracle rm -rf "$oh/OPatch"
            as_oracle mv "$backup_dir" "$oh/OPatch"
        fi
        return 1
    fi

    return 0
}

# =============================================================================
# STEP 1 - ANALYSIS OF ONE ORACLE_HOME (no downtime)
# Finds the DBRU/OJVM patch ids inside the combo zip and checks them against
# the home's inventory. Homes that need binary patching are added to
# HOMES_TO_PATCH together with their plan. Never exits.
# =============================================================================
analyze_home() {
    local oh=$1
    local opatch_bin="$oh/OPatch/opatch"
    local setup_base combo_zip patch_num combo_dir meta_dir
    local dbru_id="" ojvm_id="" need_dbru="" need_ojvm=""
    local patch_dir patch_id patch_kind patch_summary
    local -a all_ids=()
    local -a unknown_ids=()

    setup_env "" "$oh"

    # Setup directory is derived from the root of ORACLE_HOME
    # e.g. /u01/app/oracle/product/19/dbhome_1 -> /u01/setup
    setup_base=$(echo "$oh" | awk -F'/' '{print "/"$2"/setup"}')
    log "Derived setup directory: $setup_base"

    if [[ ! -d "$setup_base" ]]; then
        record_error "[$oh] Setup directory $setup_base does not exist. Binary patch level cannot be checked."
        return 1
    fi

    combo_zip=""
    if [[ -n "$MANUAL_COMBO_PATCH_NUM" ]]; then
        combo_zip=$(find_first_zip "$setup_base" "p${MANUAL_COMBO_PATCH_NUM}_*.zip" "p6880880*") || true
    else
        combo_zip=$(find_first_zip "$setup_base" "p*.zip" "p6880880*") || true
    fi

    if [[ -z "$combo_zip" ]]; then
        record_error "[$oh] No combo patch zip file found in $setup_base. Binary patch level cannot be checked."
        return 1
    fi

    # p35643107_190000_Linux-x86-64.zip -> 35643107
    patch_num=$(basename "$combo_zip" | cut -d'_' -f1 | tr -d 'p')
    combo_dir="$setup_base/$patch_num"
    meta_dir="$setup_base/.${patch_num}_meta"
    log "Detected Combo Patch Number: $patch_num ($combo_zip)"

    # Extract ONLY the inventory.xml of each sub-patch (takes a second or two)
    as_oracle rm -rf "$meta_dir"
    if ! as_oracle mkdir -p "$meta_dir" || \
       ! as_oracle unzip -o -q "$combo_zip" "${patch_num}/*/etc/config/inventory.xml" -d "$meta_dir"; then
        as_oracle rm -rf "$meta_dir"
        record_error "[$oh] Could not read the patch metadata from $combo_zip. Binary patch level cannot be checked."
        return 1
    fi

    while IFS= read -r -d '' patch_dir; do
        patch_id=$(basename "$patch_dir")
        [[ "$patch_id" =~ ^[0-9]{8}$ ]] || continue

        all_ids+=("$patch_id")
        patch_kind=$(classify_patch_dir "$patch_dir")
        patch_summary=$(get_patch_summary "$patch_dir")
        log "Sub-patch in zip: $patch_id = $patch_kind - ${patch_summary:-no summary found}"

        case "$patch_kind" in
            DBRU)
                if [[ -z "$dbru_id" ]]; then
                    dbru_id="$patch_id"
                else
                    log "WARNING: Multiple DBRU candidates found. Keeping $dbru_id and ignoring $patch_id"
                fi
                ;;
            OJVM)
                if [[ -z "$ojvm_id" ]]; then
                    ojvm_id="$patch_id"
                else
                    log "WARNING: Multiple OJVM candidates found. Keeping $ojvm_id and ignoring $patch_id"
                fi
                ;;
            UNKNOWN)
                unknown_ids+=("$patch_id")
                ;;
        esac
    done < <(find "$meta_dir/$patch_num" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    as_oracle rm -rf "$meta_dir"

    if [[ -n "$MANUAL_DBRU_PATCH_NUM" ]]; then
        dbru_id="$MANUAL_DBRU_PATCH_NUM"
        log "Using manually configured DBRU patch number: $dbru_id"
    fi

    if [[ -n "$MANUAL_OJVM_PATCH_NUM" ]]; then
        ojvm_id="$MANUAL_OJVM_PATCH_NUM"
        log "Using manually configured OJVM patch number: $ojvm_id"
    fi

    if [[ -z "$dbru_id" && ${#unknown_ids[@]} -gt 0 ]]; then
        dbru_id="${unknown_ids[0]}"
        log "WARNING: DBRU metadata was not found. Falling back to first unknown sub-patch as DBRU: $dbru_id"
    fi

    if [[ -z "$ojvm_id" && ${#all_ids[@]} -eq 2 && -n "$dbru_id" ]]; then
        for patch_id in "${all_ids[@]}"; do
            if [[ "$patch_id" != "$dbru_id" ]]; then
                ojvm_id="$patch_id"
                log "WARNING: OJVM metadata was not found. Falling back to the remaining sub-patch as OJVM: $ojvm_id"
                break
            fi
        done
    fi

    if [[ -z "$dbru_id" ]]; then
        record_error "[$oh] Could not identify the DBRU patch inside $combo_zip. Set MANUAL_DBRU_PATCH_NUM."
        return 1
    fi

    if [[ "$dbru_id" == "$ojvm_id" ]]; then
        record_error "[$oh] DBRU and OJVM resolved to the same patch ($dbru_id). Set MANUAL_DBRU_PATCH_NUM and MANUAL_OJVM_PATCH_NUM."
        return 1
    fi

    if [[ -z "$ojvm_id" ]]; then
        log "WARNING: Could not identify an OJVM patch inside $combo_zip. Only DBRU is considered."
    fi

    # --------------------------------------------------------
    # Compare with the inventory of the home
    # --------------------------------------------------------
    if patch_is_installed "$opatch_bin" "$dbru_id"; then
        log "DBRU $dbru_id : already installed"
    else
        log "DBRU $dbru_id : NOT installed"
        need_dbru="$dbru_id"
    fi

    if [[ -n "$ojvm_id" ]]; then
        if patch_is_installed "$opatch_bin" "$ojvm_id"; then
            log "OJVM $ojvm_id : already installed"
        else
            log "OJVM $ojvm_id : NOT installed"
            need_ojvm="$ojvm_id"
        fi
    fi

    if [[ -z "$need_dbru" && -z "$need_ojvm" ]]; then
        log "==> Binary patching is NOT needed for this home."
        return 0
    fi

    # Binary patching is needed: bring OPatch up to date now (no downtime needed)
    update_opatch "$oh" "$setup_base"

    log "Verifying OPatch version..."
    if ! as_oracle "$opatch_bin" version; then
        record_error "[$oh] opatch is not usable in $oh/OPatch. Binary patching skipped."
        return 1
    fi

    # Extract the full patch now, while the database is still up, so that the
    # unzip time is not part of the downtime
    if [[ ! -d "$combo_dir" ]]; then
        log "Unzipping combo patch $combo_zip (database stays up meanwhile)..."
        if ! as_oracle unzip -o -q "$combo_zip" -d "$setup_base"; then
            as_oracle rm -rf "$combo_dir"
            record_error "[$oh] Unzipping $combo_zip failed. Binary patching skipped."
            return 1
        fi
    else
        log "Using already extracted patch directory: $combo_dir"
    fi

    PLAN_COMBO_ZIP[$oh]="$combo_zip"
    PLAN_COMBO_DIR[$oh]="$combo_dir"
    PLAN_DBRU[$oh]="$need_dbru"
    PLAN_OJVM[$oh]="$need_ojvm"
    HOMES_TO_PATCH+=("$oh")
    log "==> Binary patching IS needed for this home."
    return 0
}

# =============================================================================
# STEP 2 - BINARY PATCHING OF ONE ORACLE_HOME (service must be stopped)
# Never exits. Returns 0 = patched
#                      1 = nothing was applied (unzip problem etc.)
#                      2 = "opatch apply" failed -> caller stops patching
# =============================================================================
apply_home() {
    local oh=$1
    local opatch_bin="$oh/OPatch/opatch"
    local combo_zip=${PLAN_COMBO_ZIP[$oh]}
    local combo_dir=${PLAN_COMBO_DIR[$oh]}
    local setup_base
    local label patch_id

    setup_env "" "$oh"
    setup_base=$(dirname "$combo_dir")

    if [[ ! -d "$combo_dir" ]]; then
        log "Unzipping combo patch $combo_zip..."
        if ! as_oracle unzip -o -q "$combo_zip" -d "$setup_base"; then
            record_error "[$oh] Unzipping $combo_zip failed. Nothing was applied."
            return 1
        fi
    else
        log "Using already extracted patch directory: $combo_dir"
    fi

    # Check everything is in place before touching the home
    for patch_id in "${PLAN_DBRU[$oh]}" "${PLAN_OJVM[$oh]}"; do
        if [[ -n "$patch_id" && ! -d "$combo_dir/$patch_id" ]]; then
            record_error "[$oh] Patch directory $combo_dir/$patch_id does not exist. Nothing was applied."
            return 1
        fi
    done

    # DBRU always first, then OJVM
    for label in DBRU OJVM; do
        if [[ "$label" == "DBRU" ]]; then
            patch_id=${PLAN_DBRU[$oh]}
        else
            patch_id=${PLAN_OJVM[$oh]}
        fi

        if [[ -z "$patch_id" ]]; then
            log "--> $label: already installed, nothing to apply."
            continue
        fi

        log "--> Executing $label Patch from: $combo_dir/$patch_id"
        if ! ( cd "$combo_dir/$patch_id" && as_oracle "$opatch_bin" apply -silent -local ); then
            record_error "[$oh] opatch apply FAILED for $label ($combo_dir/$patch_id). Extracted patch kept in $combo_dir."
            return 2
        fi
    done

    log "OPatch binary updates completed."

    log "Cleaning up extracted patch directory to save disk space: $combo_dir"
    as_oracle rm -rf "$combo_dir"

    return 0
}

# =============================================================================
# STEP 3 - SQL ACTIONS FOR ONE DATABASE (datapatch + utlrp)
# =============================================================================

# Asks datapatch (without changing anything) whether SQL changes are pending.
# Returns 0 = datapatch is needed (also when the answer is not clearly "no")
#         1 = nothing to do
# Expects setup_env to be done for the SID.
datapatch_needed() {
    local oh=$1
    local output queue pending

    if ! output=$( cd "$oh/OPatch" && as_oracle ./datapatch -prereq 2>&1 ); then
        echo "$output"
        log "datapatch -prereq returned an error. Treating datapatch as needed."
        return 0
    fi
    echo "$output"

    queue=$(sed -n '/Installation queue:/,$p' <<<"$output")

    # The "nothing to do" lines must be there...
    if ! grep -q 'No release update patches need to be installed' <<<"$queue"; then
        return 0
    fi

    # ...and nothing else may be listed in the installation queue
    pending=$(grep -Ev '^[[:space:]]*$|Installation queue:|For the following PDBs|No interim patches need to be rolled back|No release update patches need to be installed|No interim patches need to be applied|SQL Patching tool complete' <<<"$queue")
    if [[ -n "$pending" ]]; then
        return 0
    fi

    return 1
}

run_datapatch() {
    local sid=$1
    local oh=$2
    log "Running datapatch for $sid to apply SQL changes..."
    if ! ( cd "$oh/OPatch" && as_oracle ./datapatch -verbose ); then
        record_error "[$sid] datapatch failed. Check the datapatch logs under \$ORACLE_BASE/cfgtoollogs/sqlpatch."
    fi
}

run_utlrp() {
    local sid=$1
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
}

# mode "force" = home was patched in this run -> always datapatch + utlrp
# mode "check" = binaries untouched           -> datapatch -prereq decides
# Never exits. Problems are recorded and the caller moves on to the next SID.
post_patch_db() {
    local sid=$1
    local oh=$2
    local mode=$3
    local timeout=0
    local status role

    # Only wait for the database if this script restarted the service
    if [[ $SERVICE_STOP_ATTEMPTED -eq 1 ]]; then
        timeout=$DB_START_TIMEOUT
        log "Waiting for database $sid (timeout ${timeout}s)..."
    fi
    status=$(wait_for_db "$sid" "$oh" "OPEN MOUNTED" "$timeout")

    if [[ "$status" != "OPEN" && "$status" != "MOUNTED" ]]; then
        record_error "[$sid] Database is not up (status: $status). datapatch/utlrp skipped."
        return 1
    fi

    role=$(get_db_role "$sid" "$oh")
    log "Database $sid status is $status, role is: $role"

    if [[ "$role" != "PRIMARY" ]]; then
        log "Skipping datapatch and utlrp for $sid. Database role is $role."
        return 0
    fi

    if [[ "$status" != "OPEN" ]]; then
        if [[ $SERVICE_STOP_ATTEMPTED -eq 0 ]]; then
            # We did not restart anything, so we do not change the database state either
            record_error "[$sid] PRIMARY database is $status, not OPEN. Left as it is; datapatch/utlrp skipped."
            return 1
        fi

        # A primary may still be on its way from MOUNT to OPEN
        status=$(wait_for_db "$sid" "$oh" "OPEN" 60)
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
    fi

    setup_env "$sid" "$oh"

    if [[ "$mode" == "check" ]]; then
        log "Checking with 'datapatch -prereq' whether SQL changes are pending for $sid..."
        if datapatch_needed "$oh"; then
            log "==> datapatch IS needed for $sid."
        else
            log "==> datapatch is NOT needed for $sid."
            if [[ "$UTLRP_WHEN_NOTHING_TO_PATCH" == "yes" ]]; then
                run_utlrp "$sid"
            else
                log "Skipping utlrp for $sid (UTLRP_WHEN_NOTHING_TO_PATCH=$UTLRP_WHEN_NOTHING_TO_PATCH)."
            fi
            return 0
        fi
    fi

    run_datapatch "$sid" "$oh"
    run_utlrp "$sid"
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

# ----------------------------------------------------------------------------
# STEP 1: Analysis (no downtime)
# ----------------------------------------------------------------------------
for ORATAB_OH in $UNIQUE_HOMES; do
    log "========================================================"
    log "STEP 1: Analysing ORACLE_HOME: $ORATAB_OH"
    log "        Databases: $(sids_for_home "$ORATAB_OH" | tr '\n' ' ')"
    log "========================================================"
    analyze_home "$ORATAB_OH"
done

# ----------------------------------------------------------------------------
# STEP 2: Binary patching - only if at least one home needs it
# ----------------------------------------------------------------------------
log "========================================================"
if [[ ${#HOMES_TO_PATCH[@]} -eq 0 ]]; then
    log "STEP 2: No home needs binary patching. $ORACLE_SERVICE is NOT restarted."
    log "========================================================"
else
    log "STEP 2: Binary patching needed for: ${HOMES_TO_PATCH[*]}"
    log "        Stopping $ORACLE_SERVICE"
    log "========================================================"
    SERVICE_STOP_ATTEMPTED=1
    service_ctl stop

    # Wait a few seconds for background processes to release binary file locks
    sleep 5

    for ORATAB_OH in "${HOMES_TO_PATCH[@]}"; do
        log "--------------------------------------------------------"
        log "Binary patching ORACLE_HOME: $ORATAB_OH"
        log "--------------------------------------------------------"

        # Never run opatch against a home that is still in use
        if home_is_running "$ORATAB_OH"; then
            record_error "[$ORATAB_OH] Home is still in use after stopping $ORACLE_SERVICE. Binary patching skipped."
            continue
        fi

        apply_home "$ORATAB_OH"
        APPLY_RC=$?

        if [[ $APPLY_RC -eq 0 ]]; then
            PATCHED_HOMES+=("$ORATAB_OH")
            log "Binary patching completed for ORACLE_HOME: $ORATAB_OH"
        elif [[ $APPLY_RC -eq 2 ]]; then
            FAILED_HOMES+=("$ORATAB_OH")
            log "STOPPING binary patching: opatch failed for $ORATAB_OH. Remaining homes (if any) are left untouched."
            break
        else
            log "Nothing was applied to ORACLE_HOME: $ORATAB_OH. Continuing."
        fi
    done

    log "========================================================"
    log "        Starting $ORACLE_SERVICE"
    log "========================================================"
    SERVICE_START_ATTEMPTED=1
    service_ctl start
fi

# ----------------------------------------------------------------------------
# STEP 3: Datapatch and UTLRP, only where needed
# ----------------------------------------------------------------------------
for ORATAB_OH in $UNIQUE_HOMES; do
    log "========================================================"
    log "STEP 3: SQL actions for ORACLE_HOME: $ORATAB_OH"
    log "========================================================"

    if in_list "$ORATAB_OH" "${FAILED_HOMES[@]}"; then
        log "Skipping datapatch/utlrp for this home because opatch failed. Fix the problem and re-run the script."
        continue
    fi

    if in_list "$ORATAB_OH" "${PATCHED_HOMES[@]}"; then
        SQL_MODE="force"
    else
        SQL_MODE="check"
    fi

    for ORATAB_SID in $(sids_for_home "$ORATAB_OH"); do
        post_patch_db "$ORATAB_SID" "$ORATAB_OH" "$SQL_MODE"
    done
done

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
log "========================================================"
log "Patching script finished at $(date '+%Y-%m-%d %H:%M:%S')"
if [[ $SERVICE_STOP_ATTEMPTED -eq 1 ]]; then
    log "Service restarted : YES (binary patching was needed)"
else
    log "Service restarted : NO"
fi
if [[ ${#ERRORS[@]} -eq 0 ]]; then
    log "RESULT: SUCCESS - no errors recorded."
    exit 0
fi

log "RESULT: COMPLETED WITH ${#ERRORS[@]} ERROR(S):"
for ERR in "${ERRORS[@]}"; do
    log "  - $ERR"
done
exit 1
