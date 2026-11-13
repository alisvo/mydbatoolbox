#!/usr/bin/env bash

# =============================================================================
# oracle_patch.sh  (NO-SERVICE edition)
# =============================================================================
# Description : Automated Oracle Database patching script for RHEL-based Linux
#               Supports combo patches (DBRU + OJVM)
#               This edition does NOT use a systemd unit: it stops and starts
#               the listener(s) and the databases itself (lsnrctl / sqlplus)
#               and takes care of Data Guard (with or without the broker).
# Execution   : As root OR as the Oracle OS user - direct (nohup) or via Ansible.
#               As root, every Oracle command is run as ORACLE_USER via runuser.
# Patch dir   : Derived from ORACLE_HOME root -> /setup/
#               e.g. ORACLE_HOME=/u01/app/oracle/... -> /u01/setup/
#
# Flow        : STEP 1  Analysis, NO downtime. Per ORACLE_HOME: read the patch
#                       ids from the combo zip (metadata only, no full unzip)
#                       and compare them with "opatch lspatches".
#               STEP 2  Only for homes that need binary patching, one by one:
#                       a) Data Guard preparation (see below)
#                       b) stop listener(s), shutdown immediate
#                       c) OPatch apply (DBRU, OJVM)
#                       d) start listener(s), start databases by role,
#                          Data Guard restore
#               STEP 3  Per PRIMARY database:
#                       - home patched in this run -> datapatch + utlrp
#                       - otherwise "datapatch -prereq" decides
#
# Start by role: PRIMARY          -> startup mount, alter database open
#               PHYSICAL STANDBY -> startup mount, then READ ONLY or MOUNTED
#                                   (see STANDBY_OPEN_MODE), then redo apply
#
# Data Guard  : Before shutdown                    After startup
#   PRIMARY, broker     state TRANSPORT-OFF        state TRANSPORT-ON
#   PRIMARY, no broker  archive log current,       log_archive_dest_state_n
#                       log_archive_dest_state_n   =ENABLE (scope=memory)
#                       =DEFER (scope=memory)
#   STANDBY, broker     state APPLY-OFF            state APPLY-ON
#   STANDBY, no broker  cancel managed recovery    start managed recovery
#   Only states that were ON/ENABLE before are touched and put back.
#   Nothing is written to the spfile.
#
# Error policy: - Nothing to do is never an error.
#               - "opatch apply" really fails -> patching STOPS: no further home
#                 is patched and datapatch/utlrp are skipped for the failed home.
#               - Whatever was stopped is ALWAYS started again.
#               - All problems are listed in the final summary (exit code 1).
# =============================================================================
set -uo pipefail   # no "-e" on purpose: errors are handled explicitly

# =============================================================================
# USER CONFIGURATION - Edit these values before running
# =============================================================================
ORACLE_USER="oracle"                      # OS user that owns Oracle installations
ORATAB="/etc/oratab"                      # Path to oratab file

# Listener names to stop/start per home. Empty = automatic: the listeners that
# are running from the ORACLE_HOME when the script starts.
LISTENER_NAMES=""                         # e.g. "LISTENER LISTENER_DG"

# Data Guard handling around the shutdown (defer / broker state, see header)
DG_PREPARE="yes"                          # "yes" or "no"

# How a PHYSICAL STANDBY is left after startup:
#   previous  = as it was before the shutdown (READ ONLY stays READ ONLY,
#               MOUNTED stays MOUNTED); READ ONLY if it was down at the start
#   read_only = always open READ ONLY (with redo apply = Active Data Guard,
#               which needs its own license)
#   mount     = always leave MOUNTED
STANDBY_OPEN_MODE="previous"

# Without broker: start redo apply on a standby that was DOWN when the script
# started (if it was up, apply is restarted only if it was running before)
STANDBY_START_APPLY="yes"                 # "yes" or "no"

# Seconds to wait for one dgmgrl command
DGMGRL_TIMEOUT=180

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
SCRIPT_VERSION="4.1.1-noservice"
BASE_PATH=$PATH
ORIG_TNS_ADMIN=${TNS_ADMIN:-}
STOPPED_HOME=""                 # home that is currently stopped by this script
declare -a RESTARTED_HOMES=()   # homes stopped and started in this run
declare -A HOME_LISTENERS=()    # home -> listener names to stop/start
declare -A HOME_TNS_ADMIN=()    # home -> TNS_ADMIN of its running processes
declare -A DB_WAS=()            # sid -> status before shutdown (OPEN/MOUNTED/DOWN...)
declare -A DB_ROLE=()           # sid -> database role before shutdown
declare -A DB_OPEN_MODE=()      # sid -> open mode before shutdown
declare -A DB_UNQ=()            # sid -> db_unique_name
declare -A DB_BROKER=()         # sid -> TRUE if dg_broker_start was TRUE
declare -A DB_MRP=()            # sid -> yes/no: managed recovery ran before shutdown
declare -A DG_BROKER_OFF=()     # sid -> TRANSPORT or APPLY: broker state we switched off
declare -A DG_DEFERRED=()       # sid -> archive dest ids we deferred
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

# The script may run as root or as the Oracle OS user
if ! id "${ORACLE_USER}" >/dev/null 2>&1; then
    echo "ERROR: OS user '${ORACLE_USER}' does not exist."
    exit 1
fi
if [[ "$(id -u)" -ne 0 && "$(id -un)" != "${ORACLE_USER}" ]]; then
    echo "ERROR: This script must be run as root or as '${ORACLE_USER}'. Current user is $(id -un)."
    exit 1
fi

# Run a command as the Oracle software owner, keeping the current environment
# (ORACLE_HOME, ORACLE_SID, ...), working directory and stdin.
# opatch/datapatch/sqlplus must NEVER run as root.
as_oracle() {
    if [[ "$(id -u)" -eq 0 ]]; then
        runuser -u "$ORACLE_USER" -- env "PATH=$PATH" "$@"
    else
        "$@"
    fi
}

# =============================================================================
# ENVIRONMENT / STATUS FUNCTIONS
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

    # Use the TNS_ADMIN the running processes of this home were started with
    # (listener.ora / sqlnet.ora may live outside $ORACLE_HOME/network/admin)
    if [[ -n "${HOME_TNS_ADMIN[$oh]:-}" ]]; then
        export TNS_ADMIN=${HOME_TNS_ADMIN[$oh]}
    elif [[ -n "$ORIG_TNS_ADMIN" ]]; then
        export TNS_ADMIN=$ORIG_TNS_ADMIN
    else
        unset TNS_ADMIN
    fi

    # Only export ORACLE_SID if a value was provided
    if [[ -n "$sid" ]]; then
        export ORACLE_SID=$sid
    fi
}

# Safety net: if the script dies for any reason while a home is stopped,
# still try to bring its listener(s) and databases back.
on_exit() {
    local oh=$STOPPED_HOME
    if [[ -n "$oh" ]]; then
        STOPPED_HOME=""
        log "Script is ending unexpectedly. Starting listener(s) and databases of $oh before exit..."
        start_home "$oh"
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

# =============================================================================
# SQL / DGMGRL HELPERS
# =============================================================================

# sql_value <sid> <oh> <query> : prints the result on one line.
# Returns 1 if the output contains an ORA-/SP2- error.
sql_value() {
    local sid=$1
    local oh=$2
    local query=$3
    local out

    setup_env "$sid" "$oh"
    out=$(as_oracle sqlplus -S -L / as sysdba 2>&1 <<EOF
set heading off feedback off pagesize 0 linesize 300 trimspool on
$query;
exit;
EOF
)
    out=$(tr '\n' ' ' <<<"$out" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')
    echo "$out"
    [[ "$out" != *ORA-* && "$out" != *SP2-* ]]
}

# sql_exec <sid> <oh> <statement> : runs a statement and shows its output.
# Returns 1 if the output contains an ORA-/SP2- error.
sql_exec() {
    local sid=$1
    local oh=$2
    local statement=$3
    local out

    setup_env "$sid" "$oh"
    out=$(as_oracle sqlplus -S -L / as sysdba 2>&1 <<EOF
$statement;
exit;
EOF
)
    [[ -n "$out" ]] && echo "$out"
    [[ "$out" != *ORA-* && "$out" != *SP2-* ]]
}

# dg_cmd <sid> <oh> <dgmgrl command> : prints the dgmgrl output
dg_cmd() {
    local sid=$1
    local oh=$2
    local command=$3

    setup_env "$sid" "$oh"
    as_oracle timeout "$DGMGRL_TIMEOUT" dgmgrl -silent / "$command" 2>&1
}

# Prints the broker's intended state of a database (TRANSPORT-ON, APPLY-OFF, ...)
broker_state() {
    local sid=$1
    local oh=$2
    local unq=$3

    dg_cmd "$sid" "$oh" "show database $unq" \
        | sed -n 's/^[[:space:]]*Intended State:[[:space:]]*//p' | head -1 | tr -d '[:space:]'
}

# broker_set_state <sid> <oh> <db_unique_name> <state> : returns 0 on "Succeeded"
broker_set_state() {
    local sid=$1
    local oh=$2
    local unq=$3
    local state=$4
    local out

    log "[$sid] DGMGRL: edit database $unq set state='$state'"
    out=$(dg_cmd "$sid" "$oh" "edit database $unq set state='$state'")
    [[ -n "$out" ]] && echo "$out"
    grep -q "Succeeded" <<<"$out"
}

mrp_is_running() {
    local sid=$1
    local oh=$2
    local count

    count=$(sql_value "$sid" "$oh" "select count(*) from v\$managed_standby where process like 'MRP%'") || return 1
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]
}

# =============================================================================
# STOP / START OF ONE ORACLE_HOME (listener, databases, Data Guard)
# =============================================================================

# Prints one variable from the environment of a running process
proc_env() {
    local pid=$1
    local name=$2
    tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | sed -n "s/^${name}=//p" | head -1
}

# Finds the running listeners of a home and the TNS_ADMIN its processes use
detect_home_env() {
    local oh=$1
    local pid name sid
    local tns=""
    local listeners=""

    while read -r pid _ name _; do
        [[ -n "${name:-}" && "$name" != -* ]] || continue
        listeners+="$name "
        [[ -z "$tns" ]] && tns=$(proc_env "$pid" TNS_ADMIN)
    done < <(pgrep -af "^${oh}/bin/tnslsnr " 2>/dev/null)

    for sid in $(sids_for_home "$oh"); do
        [[ -n "$tns" ]] && break
        pid=$(pgrep -f "^ora_pmon_${sid}\$" 2>/dev/null | head -1)
        [[ -n "$pid" ]] && tns=$(proc_env "$pid" TNS_ADMIN)
    done

    [[ -n "$LISTENER_NAMES" ]] && listeners="$LISTENER_NAMES"
    HOME_LISTENERS[$oh]="${listeners% }"
    HOME_TNS_ADMIN[$oh]="$tns"
}

# Remembers how a database looks before we touch it
capture_db_state() {
    local sid=$1
    local oh=$2
    local status

    status=$(get_db_status "$sid" "$oh")
    DB_WAS[$sid]="$status"

    if [[ "$status" == "OPEN" || "$status" == "MOUNTED" ]]; then
        DB_ROLE[$sid]=$(get_db_role "$sid" "$oh")
        DB_OPEN_MODE[$sid]=$(sql_value "$sid" "$oh" "select open_mode from v\$database")
        DB_UNQ[$sid]=$(sql_value "$sid" "$oh" "select db_unique_name from v\$database")
        DB_BROKER[$sid]=$(sql_value "$sid" "$oh" "select upper(value) from v\$parameter where name='dg_broker_start'")
        log "[$sid] status=$status role=${DB_ROLE[$sid]} open_mode=${DB_OPEN_MODE[$sid]} db_unique_name=${DB_UNQ[$sid]} broker=${DB_BROKER[$sid]}"
    else
        log "[$sid] status=$status"
    fi
}

# Data Guard preparation before the shutdown. The database must be up.
# Everything that is switched off here is remembered and put back by
# dg_restore_primary / dg_restore_standby.
dg_prepare() {
    local sid=$1
    local oh=$2
    local role=${DB_ROLE[$sid]:-}
    local unq=${DB_UNQ[$sid]:-}
    local state dests dest

    if [[ "$role" == "PRIMARY" ]]; then
        if [[ "${DB_BROKER[$sid]:-}" == "TRUE" ]]; then
            state=$(broker_state "$sid" "$oh" "$unq")
            log "[$sid] PRIMARY with broker. Intended state: ${state:-unknown}"
            if [[ "$state" == "TRANSPORT-ON" ]]; then
                sql_exec "$sid" "$oh" "alter system archive log current" || log "WARNING: [$sid] archive log current failed."
                if broker_set_state "$sid" "$oh" "$unq" "TRANSPORT-OFF"; then
                    DG_BROKER_OFF[$sid]="TRANSPORT"
                else
                    log "WARNING: [$sid] Could not set TRANSPORT-OFF through the broker. Continuing with the shutdown."
                fi
            fi
        else
            dests=$(sql_value "$sid" "$oh" "select d.dest_id from v\$archive_dest d, v\$parameter p where p.name='log_archive_dest_state_'||d.dest_id and upper(p.value)='ENABLE' and d.target in ('STANDBY','REMOTE') and d.status<>'INACTIVE' order by d.dest_id") || dests=""
            if [[ -z "$dests" ]]; then
                log "[$sid] PRIMARY without broker and without an enabled standby destination. No Data Guard action."
                return 0
            fi
            log "[$sid] PRIMARY without broker. Enabled standby destination(s): $dests"
            sql_exec "$sid" "$oh" "alter system archive log current" || log "WARNING: [$sid] archive log current failed."
            for dest in $dests; do
                [[ "$dest" =~ ^[0-9]+$ ]] || continue
                log "[$sid] Deferring log_archive_dest_state_$dest (scope=memory)"
                if sql_exec "$sid" "$oh" "alter system set log_archive_dest_state_$dest=defer scope=memory"; then
                    DG_DEFERRED[$sid]="${DG_DEFERRED[$sid]:-}$dest "
                else
                    log "WARNING: [$sid] Could not defer log_archive_dest_state_$dest."
                fi
            done
        fi

    elif [[ "$role" == "PHYSICAL STANDBY" ]]; then
        if mrp_is_running "$sid" "$oh"; then
            DB_MRP[$sid]="yes"
        else
            DB_MRP[$sid]="no"
        fi

        if [[ "${DB_BROKER[$sid]:-}" == "TRUE" ]]; then
            state=$(broker_state "$sid" "$oh" "$unq")
            log "[$sid] PHYSICAL STANDBY with broker. Intended state: ${state:-unknown}, redo apply running: ${DB_MRP[$sid]}"
            if [[ "$state" == "APPLY-ON" ]]; then
                if broker_set_state "$sid" "$oh" "$unq" "APPLY-OFF"; then
                    DG_BROKER_OFF[$sid]="APPLY"
                    return 0
                fi
                log "WARNING: [$sid] Could not set APPLY-OFF through the broker. Cancelling redo apply with SQL instead."
            fi
        else
            log "[$sid] PHYSICAL STANDBY without broker. Redo apply running: ${DB_MRP[$sid]}"
        fi

        if mrp_is_running "$sid" "$oh"; then
            log "[$sid] Cancelling managed recovery"
            sql_exec "$sid" "$oh" "alter database recover managed standby database cancel" \
                || log "WARNING: [$sid] Could not cancel managed recovery. Continuing with the shutdown."
        fi
    fi
}

stop_database() {
    local sid=$1
    local oh=$2
    local was=${DB_WAS[$sid]:-}
    local status

    if [[ "$was" == "DOWN" ]]; then
        log "[$sid] Database is already DOWN."
        return 0
    fi

    if [[ "$was" == ERROR:* ]]; then
        record_error "[$sid] Status could not be determined (${was#ERROR: }). Database is NOT shut down by the script."
        return 1
    fi

    log "[$sid] shutdown immediate..."
    sql_exec "$sid" "$oh" "shutdown immediate"

    status=$(get_db_status "$sid" "$oh")
    if [[ "$status" != "DOWN" ]]; then
        record_error "[$sid] Database is still $status after shutdown immediate."
        return 1
    fi
    log "[$sid] Database is down."
}

# Stops everything of one home: Data Guard preparation, listeners, databases
stop_home() {
    local oh=$1
    local sid name

    detect_home_env "$oh"

    for sid in $(sids_for_home "$oh"); do
        capture_db_state "$sid" "$oh"
        if [[ "$DG_PREPARE" == "yes" ]]; then
            dg_prepare "$sid" "$oh"
        fi
    done

    setup_env "" "$oh"
    if [[ -z "${HOME_LISTENERS[$oh]}" ]]; then
        log "No listener is running from this home."
    fi
    for name in ${HOME_LISTENERS[$oh]}; do
        log "Stopping listener $name..."
        as_oracle lsnrctl stop "$name" || log "WARNING: lsnrctl stop $name returned an error."
    done

    for sid in $(sids_for_home "$oh"); do
        stop_database "$sid" "$oh"
    done
}

# Puts back what dg_prepare switched off on a primary
dg_restore_primary() {
    local sid=$1
    local oh=$2
    local unq=${DB_UNQ[$sid]:-}
    local dest

    if [[ "${DG_BROKER_OFF[$sid]:-}" == "TRANSPORT" ]]; then
        if broker_set_state "$sid" "$oh" "$unq" "TRANSPORT-ON"; then
            DG_BROKER_OFF[$sid]=""
        else
            record_error "[$sid] Could not set TRANSPORT-ON again. Run in dgmgrl: edit database $unq set state='TRANSPORT-ON';"
        fi
    fi

    for dest in ${DG_DEFERRED[$sid]:-}; do
        log "[$sid] Enabling log_archive_dest_state_$dest (scope=memory)"
        if ! sql_exec "$sid" "$oh" "alter system set log_archive_dest_state_$dest=enable scope=memory"; then
            record_error "[$sid] Could not enable log_archive_dest_state_$dest again. Run: alter system set log_archive_dest_state_$dest=enable;"
        fi
    done
    DG_DEFERRED[$sid]=""
}

# Starts redo apply again on a standby (if it should be running)
dg_restore_standby() {
    local sid=$1
    local oh=$2
    local unq broker state waited want_apply

    unq=${DB_UNQ[$sid]:-}
    [[ -n "$unq" ]] || unq=$(sql_value "$sid" "$oh" "select db_unique_name from v\$database")
    broker=${DB_BROKER[$sid]:-}
    [[ -n "$broker" ]] || broker=$(sql_value "$sid" "$oh" "select upper(value) from v\$parameter where name='dg_broker_start'")

    if [[ "$broker" == "TRUE" ]]; then
        if [[ "${DG_BROKER_OFF[$sid]:-}" == "APPLY" ]]; then
            if broker_set_state "$sid" "$oh" "$unq" "APPLY-ON"; then
                DG_BROKER_OFF[$sid]=""
            else
                record_error "[$sid] Could not set APPLY-ON again. Run in dgmgrl: edit database $unq set state='APPLY-ON';"
            fi
        fi

        state=$(broker_state "$sid" "$oh" "$unq")
        if [[ "$state" != "APPLY-ON" ]]; then
            log "[$sid] Broker intended state is ${state:-unknown}. Redo apply is not started."
            return 0
        fi

        # The broker starts redo apply by itself; give it a moment
        waited=0
        until mrp_is_running "$sid" "$oh" || (( waited >= 30 )); do
            sleep 5
            waited=$((waited + 5))
        done
        want_apply="yes"
    else
        case "${DB_MRP[$sid]:-unknown}" in
            yes) want_apply="yes" ;;
            no)  want_apply="no" ;;
            *)   want_apply=$STANDBY_START_APPLY ;;
        esac
    fi

    if mrp_is_running "$sid" "$oh"; then
        log "[$sid] Redo apply is running."
        return 0
    fi

    if [[ "$want_apply" != "yes" ]]; then
        log "[$sid] Redo apply was not running before. It is not started."
        return 0
    fi

    log "[$sid] Starting managed recovery"
    if ! sql_exec "$sid" "$oh" "alter database recover managed standby database disconnect from session"; then
        record_error "[$sid] Could not start managed recovery on the standby."
    fi
}

# Starts one database according to its role and restores Data Guard
start_database() {
    local sid=$1
    local oh=$2
    local status role want_ro

    status=$(get_db_status "$sid" "$oh")

    if [[ "$status" == "DOWN" ]]; then
        log "[$sid] startup mount..."
        sql_exec "$sid" "$oh" "startup mount"
        status=$(get_db_status "$sid" "$oh")
    fi

    if [[ "$status" != "MOUNTED" && "$status" != "OPEN" ]]; then
        record_error "[$sid] Database could not be mounted (status: $status)."
        return 1
    fi

    role=$(get_db_role "$sid" "$oh")
    log "[$sid] status=$status role=$role"

    if [[ "$role" == "PRIMARY" ]]; then
        if [[ "$status" != "OPEN" ]]; then
            log "[$sid] PRIMARY: alter database open..."
            sql_exec "$sid" "$oh" "alter database open"
            status=$(get_db_status "$sid" "$oh")
            if [[ "$status" != "OPEN" ]]; then
                record_error "[$sid] PRIMARY database could not be opened (status: $status)."
            fi
        fi
        dg_restore_primary "$sid" "$oh"

    elif [[ "$role" == "PHYSICAL STANDBY" ]]; then
        case "$STANDBY_OPEN_MODE" in
            read_only) want_ro="yes" ;;
            mount)     want_ro="no" ;;
            *)
                # previous: unknown (database was down at the start) counts as READ ONLY
                if [[ "${DB_OPEN_MODE[$sid]:-READ ONLY}" == "MOUNTED" ]]; then
                    want_ro="no"
                else
                    want_ro="yes"
                fi
                ;;
        esac

        if [[ "$want_ro" == "yes" && "$status" == "MOUNTED" ]]; then
            # Redo apply (e.g. started by the broker at mount) blocks the open: ORA-10456
            if mrp_is_running "$sid" "$oh"; then
                log "[$sid] Redo apply is already running. Cancelling it to open the standby."
                sql_exec "$sid" "$oh" "alter database recover managed standby database cancel"
            fi
            log "[$sid] PHYSICAL STANDBY: alter database open read only..."
            sql_exec "$sid" "$oh" "alter database open read only"
            status=$(get_db_status "$sid" "$oh")
            if [[ "$status" != "OPEN" ]]; then
                record_error "[$sid] Standby could not be opened READ ONLY (status: $status)."
            fi
        elif [[ "$want_ro" != "yes" ]]; then
            log "[$sid] PHYSICAL STANDBY: left MOUNTED."
        fi
        dg_restore_standby "$sid" "$oh"

    else
        record_error "[$sid] Database role '$role' is not handled by this script. Database left $status."
        return 1
    fi
}

# Starts everything of one home: listeners first, then the databases
start_home() {
    local oh=$1
    local sid name

    setup_env "" "$oh"
    if [[ -z "${HOME_LISTENERS[$oh]:-}" ]]; then
        log "No listener was running from this home before. No listener is started."
    fi
    for name in ${HOME_LISTENERS[$oh]:-}; do
        log "Starting listener $name..."
        as_oracle lsnrctl start "$name" || record_error "[$oh] Listener $name could not be started."
    done

    for sid in $(sids_for_home "$oh"); do
        start_database "$sid" "$oh"
    done
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
# STEP 2 - BINARY PATCHING OF ONE ORACLE_HOME (home must be stopped)
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
    local status role

    status=$(get_db_status "$sid" "$oh")

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
        record_error "[$sid] PRIMARY database is $status, not OPEN. datapatch/utlrp skipped."
        return 1
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
    detect_home_env "$ORATAB_OH"
    analyze_home "$ORATAB_OH"
done

# ----------------------------------------------------------------------------
# STEP 2: Binary patching - only for homes that need it, one home at a time
# ----------------------------------------------------------------------------
log "========================================================"
if [[ ${#HOMES_TO_PATCH[@]} -eq 0 ]]; then
    log "STEP 2: No home needs binary patching. Nothing is stopped."
    log "========================================================"
else
    log "STEP 2: Binary patching needed for: ${HOMES_TO_PATCH[*]}"
    log "========================================================"

    for ORATAB_OH in "${HOMES_TO_PATCH[@]}"; do
        log "--------------------------------------------------------"
        log "Stopping listener(s) and database(s) of: $ORATAB_OH"
        log "--------------------------------------------------------"
        STOPPED_HOME=$ORATAB_OH
        stop_home "$ORATAB_OH"

        # Wait a few seconds for background processes to release binary file locks
        sleep 5

        log "--------------------------------------------------------"
        log "Binary patching ORACLE_HOME: $ORATAB_OH"
        log "--------------------------------------------------------"

        # Never run opatch against a home that is still in use
        if home_is_running "$ORATAB_OH"; then
            record_error "[$ORATAB_OH] Home is still in use after the shutdown. Binary patching skipped."
            APPLY_RC=1
        else
            apply_home "$ORATAB_OH"
            APPLY_RC=$?
        fi

        log "--------------------------------------------------------"
        log "Starting listener(s) and database(s) of: $ORATAB_OH"
        log "--------------------------------------------------------"
        STOPPED_HOME=""
        RESTARTED_HOMES+=("$ORATAB_OH")
        start_home "$ORATAB_OH"

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
if [[ ${#RESTARTED_HOMES[@]} -gt 0 ]]; then
    log "Restarted homes   : ${RESTARTED_HOMES[*]}"
else
    log "Restarted homes   : none"
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
