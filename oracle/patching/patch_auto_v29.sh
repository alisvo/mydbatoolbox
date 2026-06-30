#!/usr/bin/env bash

# =============================================================================
# oracle_patch.sh
# =============================================================================
# Description : Automated Oracle Database patching script for RHEL-based Linux
#               Supports combo patches (DBRU + OJVM)
# Execution   : Direct (nohup) or via Ansible
# Patch dir   : Derived from ORACLE_HOME root -> /setup/
#               e.g. ORACLE_HOME=/u01/app/oracle/... -> /u01/setup/
# Patch order : 1) OPatch Update 2) DBRU 3) OJVM 4) Cleanup 5) utlrp
# =============================================================================
set -euo pipefail

# =============================================================================
# USER CONFIGURATION - Edit these values before running
# =============================================================================
ORACLE_USER="oracle"                      # OS user that owns Oracle installations
ORATAB="/etc/oratab"                      # Path to oratab file

# Patch Number (Recommended to set manually if multiple patches exist in setup dir)
# This targets the main combo patch zip file (e.g., 35643107 for p35643107_190000_Linux-x86-64.zip)
MANUAL_COMBO_PATCH_NUM=""                 # e.g., "35643107" (Leave empty to auto-detect any p*.zip)

# Sub-Patch Configuration (Set manually if auto-detection fails to distinguish DBRU vs OJVM)
MANUAL_DBRU_PATCH_NUM=""                  # e.g., "38523462" (The DBRU sub-directory inside the combo)
MANUAL_OJVM_PATCH_NUM=""                  # e.g., "38523609" (The OJVM sub-directory inside the combo)

# =============================================================================
# INTERNAL - Do not edit below this line
# =============================================================================
SCRIPT_VERSION="2.9.0"
START_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

# Helper function for logging
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Ensure script is run as the oracle user
if [[ "$(whoami)" != "${ORACLE_USER}" ]]; then
    echo "ERROR: This script must be run as the '${ORACLE_USER}' user. Current user is $(whoami)."
    exit 1
fi

# =============================================================================
# FUNCTIONS FOR LISTENER AND DATABASE STATE MANAGEMENT
# =============================================================================

setup_env() {
    local sid=$1
    local oh=$2
    
    export ORACLE_HOME=$oh
    export PATH=$ORACLE_HOME/bin:/usr/local/bin:/usr/bin:/bin:$PATH
    
    # Dynamically set ORACLE_BASE to prevent OCI-21500 environment errors
    if [[ -x "$ORACLE_HOME/bin/orabase" ]]; then
        export ORACLE_BASE=$($ORACLE_HOME/bin/orabase)
    fi
    export LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib

    # Only export ORACLE_SID if a value was provided
    if [[ -n "$sid" ]]; then
        export ORACLE_SID=$sid
    fi
}

manage_listener() {
    local action=$1 # "stop" or "start"
    local oh=$2
    setup_env "" "$oh"

    if [[ "$action" == "stop" ]]; then
        log "Checking listener status..."
        # Disable exit on error temporarily for status check
        set +e
        lsnrctl status >/dev/null 2>&1
        local lsnr_status=$?
        set -e
        
        if [[ $lsnr_status -eq 0 ]]; then
            log "Listener is running. Stopping listener..."
            lsnrctl stop
        else
            log "Listener is already down or not configured in this home."
        fi
    elif [[ "$action" == "start" ]]; then
        log "Starting listener..."
        lsnrctl start || log "WARNING: Listener failed to start. Please check listener.ora."
    fi
}

get_db_status() {
    local sid=$1
    local oh=$2
    setup_env "$sid" "$oh"

    local status
    # Temporarily disable set -e to safely capture sqlplus crashes
    set +e
    status=$(sqlplus -S -L / as sysdba 2>&1 <<EOF
set heading off feedback off pagesize 0 linesize 100
select status from v\$instance;
exit;
EOF
)
    set -e

    # Trim whitespace and handle ORA errors
    status=$(echo "$status" | xargs)
    
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
    set +e
    role=$(sqlplus -S -L / as sysdba 2>&1 <<EOF
set heading off feedback off pagesize 0 linesize 100
select database_role from v\$database;
exit;
EOF
)
    set -e
    # Trim whitespace
    echo "$role" | xargs
}

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

    echo "$summary" | xargs
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

find_manual_subpatch_dir() {
    local combo_dir=$1
    local patch_num=$2
    local patch_dir="$combo_dir/$patch_num"

    if [[ -d "$patch_dir" ]]; then
        echo "$patch_dir"
    else
        return 1
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
        if [[ -n "$exclude_name" && "$zip_name" == $exclude_name ]]; then
            continue
        fi

        echo "$zip"
        return 0
    done < <(find "$search_dir" -maxdepth 1 -type f -name "$include_name" -print | sort)

    return 1
}

stop_database() {
    local sid=$1
    local oh=$2
    local status
    status=$(get_db_status "$sid" "$oh")

    if [[ "$status" == ERROR:* ]]; then
        log "CRITICAL: Unable to verify status for $sid due to an environment or SQL*Plus error."
        log "Detailed Error: ${status#ERROR: }"
        log "Aborting patch process for safety to prevent corrupting a running database!"
        exit 1
    fi

    if [[ "$status" == "DOWN" ]]; then
        log "Database $sid is already DOWN."
    else
        log "Database $sid status is $status. Initiating shutdown immediate..."
        setup_env "$sid" "$oh"
        sqlplus -S -L / as sysdba <<EOF
shutdown immediate;
exit;
EOF
        log "Database $sid shut down successfully."
    fi
}

start_database() {
    local sid=$1
    local oh=$2
    local status
    status=$(get_db_status "$sid" "$oh")

    if [[ "$status" == ERROR:* ]]; then
        log "CRITICAL: Unable to verify status for $sid due to an environment or SQL*Plus error."
        log "Detailed Error: ${status#ERROR: }"
        exit 1
    fi

    setup_env "$sid" "$oh"

    if [[ "$status" == "DOWN" ]]; then
        log "Database $sid is DOWN. Starting up in MOUNT mode to check role..."
        sqlplus -S -L / as sysdba <<EOF
startup mount;
exit;
EOF
        status="MOUNTED"
    fi

    # Now that it's at least mounted, check the role
    local role
    role=$(get_db_role "$sid" "$oh")
    log "Database role for $sid is: $role"

    if [[ "$status" == "OPEN" ]]; then
        log "Database $sid is already OPEN."
    elif [[ "$status" == "MOUNTED" ]]; then
        if [[ "$role" == "PRIMARY" ]]; then
            log "Database $sid is PRIMARY. Opening database..."
            sqlplus -S -L / as sysdba <<EOF
alter database open;
exit;
EOF
        else
            log "Database $sid is a STANDBY. Opening database for Active Data Guard (READ ONLY)..."
            sqlplus -S -L / as sysdba <<EOF
alter database open read only;
exit;
EOF
        fi
    fi
}

# =============================================================================
# MAIN EXECUTION BLOCK
# =============================================================================
log "Starting Oracle Patching Script v${SCRIPT_VERSION}"

# Identify unique ORACLE_HOMEs from oratab
UNIQUE_HOMES=$(grep -E -v '^\s*#|^\s*$' "$ORATAB" | grep -i ':Y' | awk -F: '{print $2}' | sort -u)

for ORATAB_OH in $UNIQUE_HOMES; do
    log "========================================================"
    log "Processing ORACLE_HOME: $ORATAB_OH"
    log "========================================================"

    # Find all SIDs associated with this HOME
    SIDS=$(grep -E -v '^\s*#|^\s*$' "$ORATAB" | grep -i ':Y' | awk -F: -v oh="$ORATAB_OH" '$2 == oh {print $1}')
    
    # Convert multiline SIDS to single line for logging
    SID_LIST=$(echo $SIDS | tr '\n' ' ')
    log "Databases attached to this home: $SID_LIST"

    # 1. Stop Listener
    manage_listener "stop" "$ORATAB_OH"

    # 2. Stop ALL databases in this home gracefully
    for ORATAB_SID in $SIDS; do
        stop_database "$ORATAB_SID" "$ORATAB_OH"
    done

    # Wait a few seconds for background processes to release binary file locks
    sleep 5

    # ========================================================
    # PATCH APPLICATION LOGIC (OPATCH + DBRU + OJVM)
    # ========================================================
    
    # Setup dizinini belirle (ORACLE_HOME root dizininden türetilir)
    # Örn: /u01/app/oracle/product/19/dbhome_1 -> /u01/setup
    SETUP_BASE=$(echo "$ORATAB_OH" | awk -F'/' '{print "/"$2"/setup"}')
    log "Derived setup directory: $SETUP_BASE"

    if [[ ! -d "$SETUP_BASE" ]]; then
        log "ERROR: Setup directory $SETUP_BASE does not exist!"
        exit 1
    fi

    # --------------------------------------------------------
    # OPATCH UPDATE LOGIC (Patch 6880880)
    # --------------------------------------------------------
    OPATCH_ZIP=""
    
    if OPATCH_ZIP=$(find_first_zip "$SETUP_BASE" "p6880880_*.zip"); then
        log "Found OPatch update zip: $OPATCH_ZIP"
        if [[ -d "$ORATAB_OH/OPatch" ]]; then
            BACKUP_DIR="OPatch_bak_$(date +%Y%m%d_%H%M%S)"
            log "Backing up existing OPatch to $BACKUP_DIR..."
            mv "$ORATAB_OH/OPatch" "$ORATAB_OH/$BACKUP_DIR"
        fi
        log "Extracting new OPatch to $ORATAB_OH..."
        unzip -o -q "$OPATCH_ZIP" -d "$ORATAB_OH"
    else
        log "No OPatch update zip (p6880880_*.zip) found in $SETUP_BASE. Skipping OPatch update."
    fi

    export PATH=$ORATAB_OH/OPatch:$PATH
    log "Verifying OPatch version..."
    opatch version || { log "ERROR: opatch not found in $ORATAB_OH/OPatch"; exit 1; }

    cd "$SETUP_BASE"

    # --------------------------------------------------------
    # COMBO PATCH LOGIC
    # --------------------------------------------------------
    # Combo patch numarasını bul (Eğer manuel verilmemişse ilk zip dosyasını bul)
    COMBO_ZIP=""
    if [[ -n "$MANUAL_COMBO_PATCH_NUM" ]]; then
        COMBO_ZIP=$(find_first_zip "$SETUP_BASE" "p${MANUAL_COMBO_PATCH_NUM}_*.zip" "p6880880*") || true
    else
        COMBO_ZIP=$(find_first_zip "$SETUP_BASE" "p*.zip" "p6880880*") || true
    fi

    if [[ -z "$COMBO_ZIP" ]]; then
        log "ERROR: No combo patch zip file found in $SETUP_BASE"
        exit 1
    fi

    # Patch klasör adını zip adından türet (p35643107_190000_Linux-x86-64.zip -> 35643107)
    COMBO_ZIP_NAME=$(basename "$COMBO_ZIP")
    PATCH_NUM=$(echo "$COMBO_ZIP_NAME" | cut -d'_' -f1 | tr -d 'p')
    log "Detected Combo Patch Number: $PATCH_NUM"

    # Zip dosyasını çıkar (Eğer klasör yoksa)
    if [[ ! -d "$PATCH_NUM" ]]; then
        log "Unzipping combo patch $COMBO_ZIP..."
        # Added -o flag to forcefully overwrite existing files (like PatchSearch.xml) without prompting
        unzip -o -q "$COMBO_ZIP" -d .
    fi

    COMBO_DIR="$SETUP_BASE/$PATCH_NUM"

    # DBRU/OJVM sub-patch dizinlerini inventory.xml metadata'sına göre bul.
    # Fallback sadece metadata eksik olduğunda ve güvenli dar koşullarda kullanılır.
    DBRU_DIR=""
    OJVM_DIR=""
    declare -a ALL_SUBPATCH_DIRS=()
    declare -a UNKNOWN_SUBPATCH_DIRS=()

    while IFS= read -r -d '' PATCH_DIR; do
        PATCH_BASENAME=$(basename "$PATCH_DIR")
        [[ "$PATCH_BASENAME" =~ ^[0-9]{8}$ ]] || continue

        ALL_SUBPATCH_DIRS+=("$PATCH_DIR")
        PATCH_KIND=$(classify_patch_dir "$PATCH_DIR")
        PATCH_SUMMARY=$(get_patch_summary "$PATCH_DIR")

        if [[ -n "$PATCH_SUMMARY" ]]; then
            log "Detected sub-patch candidate $PATCH_BASENAME: $PATCH_KIND - $PATCH_SUMMARY"
        else
            log "Detected sub-patch candidate $PATCH_BASENAME: $PATCH_KIND - no inventory.xml summary found"
        fi

        case "$PATCH_KIND" in
            DBRU)
                if [[ -z "$DBRU_DIR" ]]; then
                    DBRU_DIR="$PATCH_DIR"
                else
                    log "WARNING: Multiple DBRU candidates found. Keeping $DBRU_DIR and ignoring $PATCH_DIR"
                fi
                ;;
            OJVM)
                if [[ -z "$OJVM_DIR" ]]; then
                    OJVM_DIR="$PATCH_DIR"
                else
                    log "WARNING: Multiple OJVM candidates found. Keeping $OJVM_DIR and ignoring $PATCH_DIR"
                fi
                ;;
            UNKNOWN)
                UNKNOWN_SUBPATCH_DIRS+=("$PATCH_DIR")
                ;;
        esac
    done < <(find "$COMBO_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

    if [[ ${#ALL_SUBPATCH_DIRS[@]} -eq 0 ]]; then
        log "ERROR: No numeric sub-patch directories found inside $COMBO_DIR"
        exit 1
    fi

    if [[ -n "$MANUAL_DBRU_PATCH_NUM" ]]; then
        if DBRU_DIR=$(find_manual_subpatch_dir "$COMBO_DIR" "$MANUAL_DBRU_PATCH_NUM"); then
            log "Using manually configured DBRU patch directory: $DBRU_DIR"
        else
            log "ERROR: Manual DBRU patch directory was not found: $COMBO_DIR/$MANUAL_DBRU_PATCH_NUM"
            exit 1
        fi
    fi

    if [[ -n "$MANUAL_OJVM_PATCH_NUM" ]]; then
        if OJVM_DIR=$(find_manual_subpatch_dir "$COMBO_DIR" "$MANUAL_OJVM_PATCH_NUM"); then
            log "Using manually configured OJVM patch directory: $OJVM_DIR"
        else
            log "ERROR: Manual OJVM patch directory was not found: $COMBO_DIR/$MANUAL_OJVM_PATCH_NUM"
            exit 1
        fi
    fi

    if [[ -z "$DBRU_DIR" && ${#UNKNOWN_SUBPATCH_DIRS[@]} -gt 0 ]]; then
        DBRU_DIR="${UNKNOWN_SUBPATCH_DIRS[0]}"
        log "WARNING: DBRU metadata was not found. Falling back to first unknown numeric sub-patch as DBRU: $DBRU_DIR"
    fi

    if [[ -z "$OJVM_DIR" && ${#ALL_SUBPATCH_DIRS[@]} -eq 2 && -n "$DBRU_DIR" ]]; then
        for PATCH_DIR in "${ALL_SUBPATCH_DIRS[@]}"; do
            if [[ "$PATCH_DIR" != "$DBRU_DIR" ]]; then
                OJVM_DIR="$PATCH_DIR"
                log "WARNING: OJVM metadata was not found. Falling back to the remaining sub-patch as OJVM: $OJVM_DIR"
                break
            fi
        done
    fi

    if [[ -n "$DBRU_DIR" && -n "$OJVM_DIR" && "$DBRU_DIR" == "$OJVM_DIR" ]]; then
        log "ERROR: DBRU and OJVM resolved to the same directory: $DBRU_DIR"
        log "Set MANUAL_DBRU_PATCH_NUM and MANUAL_OJVM_PATCH_NUM explicitly, then retry."
        exit 1
    fi

    if [[ -n "$DBRU_DIR" ]]; then
        log "--> Executing DBRU Patch from: $DBRU_DIR"
        cd "$DBRU_DIR"
        opatch apply -silent -local
    else
        log "ERROR: Could not identify DBRU patch directory inside $PATCH_NUM"
        log "Set MANUAL_DBRU_PATCH_NUM explicitly, then retry."
        exit 1
    fi

    if [[ -n "$OJVM_DIR" ]]; then
        log "--> Executing OJVM Patch from: $OJVM_DIR"
        cd "$OJVM_DIR"
        opatch apply -silent -local
    else
        log "WARNING: Could not identify OJVM patch directory inside $PATCH_NUM"
    fi

    log "OPatch binary updates completed."
    
    # --------------------------------------------------------
    # DISK CLEANUP (Remove extracted combo patch directory)
    # --------------------------------------------------------
    if [[ -n "$PATCH_NUM" && -d "$SETUP_BASE/$PATCH_NUM" ]]; then
        log "Cleaning up extracted patch directory to save disk space: $SETUP_BASE/$PATCH_NUM"
        rm -rf "$SETUP_BASE/$PATCH_NUM"
    fi
    # ========================================================

    # 3. Start ALL databases in this home (Required to OPEN for datapatch)
    for ORATAB_SID in $SIDS; do
        start_database "$ORATAB_SID" "$ORATAB_OH"
    done

    # 4. Run Datapatch and UTLRP (Post-patch SQL actions)
    # We do this BEFORE starting the listener so users cannot connect during dictionary updates
    cd "$ORATAB_OH/OPatch"
    for ORATAB_SID in $SIDS; do
        DB_ROLE=$(get_db_role "$ORATAB_SID" "$ORATAB_OH")
        
        if [[ "$DB_ROLE" == "PRIMARY" ]]; then
            log "Running datapatch for $ORATAB_SID to apply SQL changes (Role: PRIMARY)..."
            setup_env "$ORATAB_SID" "$ORATAB_OH"
            ./datapatch -verbose
            
            log "Running utlrp.sql for $ORATAB_SID to recompile any invalid objects..."
            sqlplus -S -L / as sysdba <<EOF
@?/rdbms/admin/utlrp.sql
exit;
EOF
            log "Object recompilation finished for $ORATAB_SID."
        else
            log "Skipping datapatch and utlrp for $ORATAB_SID. Database role is $DB_ROLE."
        fi
    done

    # 5. Start Listener (Safe to allow user connections now)
    manage_listener "start" "$ORATAB_OH"

    log "Patching completed for ORACLE_HOME: $ORATAB_OH"
done

log "All ORACLE_HOMEs processed. Patching script finished at $(date '+%Y-%m-%d %H:%M:%S')"
