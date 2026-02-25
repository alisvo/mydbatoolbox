#!/bin/bash

# ==============================================================================
# Oracle Database Multi-Instance Health Check Script for RHEL 8/9
# - Reads /etc/oratab for databases flagged with 'Y' (Ignores ASM)
# - Checks Listener OS process (tnslsnr)
# Protected against glogin.sql banners and sqlplus hanging
# ==============================================================================

# ANSI Color Codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

ORATAB="/etc/oratab"
ISSUES=()
CHECKED_DBS=()
HEALTHY_DB_COUNT=0
TOTAL_DB_COUNT=0

# 1. Check if at least one Oracle Listener process is running at the OS level
# tnslsnr is the binary for both standard and Grid Infrastructure listeners
if ! pgrep -f "tnslsnr" > /dev/null 2>&1; then
    ISSUES+=("Listener process (tnslsnr) is NOT running on this host.")
fi

# 2. Verify /etc/oratab exists
if [ ! -f "$ORATAB" ]; then
    echo -e "${RED}Critical Error:${NC} $ORATAB not found. Cannot determine databases."
    exit 1
fi

# 3. Parse /etc/oratab for entries ending with :Y 
# (Ignores comments and +ASM instances which do not have a v$database)
DB_LIST=$(grep -v '^\s*#' "$ORATAB" | grep -v '^+ASM' | grep -i ':Y$')

if [ -z "$DB_LIST" ]; then
    echo -e "${YELLOW}Warning:${NC} No standard databases marked with 'Y' found in $ORATAB to check."
    exit 0
fi

# 4. Loop through each database found in oratab
for row in $DB_LIST; do
    # Extract SID and HOME
    DB_SID=$(echo "$row" | awk -F: '{print $1}')
    DB_HOME=$(echo "$row" | awk -F: '{print $2}')
    
    CHECKED_DBS+=("$DB_SID")
    ((TOTAL_DB_COUNT++))
    
    # 4a. Check OS process (PMON) - standard indicator the instance is alive
    if ! pgrep -f "ora_pmon_${DB_SID}" > /dev/null 2>&1; then
        ISSUES+=("DB '${DB_SID}': PMON process is DOWN.")
        continue
    fi
    
    # Setup Oracle Environment for this specific SID
    export ORACLE_SID="$DB_SID"
    export ORACLE_HOME="$DB_HOME"
    export PATH="$ORACLE_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$ORACLE_HOME/lib:$LD_LIBRARY_PATH"

    # 4b. Query Database Role and Open Mode
    # Using -s (silent) and -L (logon once, fail immediately if auth fails/hangs)
    SQL_OUTPUT=$(sqlplus -s -L / as sysdba <<EOF
set pagesize 0 linesize 100 feedback off verify off heading off
select trim(open_mode) || '|' || trim(database_role) 
from v\$database;
exit;
EOF
)
    
    # Strip whitespace/newlines and isolate the result from any glogin.sql banners
    CLEAN_OUTPUT=$(echo "$SQL_OUTPUT" | grep '|' | tail -n 1 | xargs)

    # Validate we actually got a format like STATUS|ROLE
    if [[ ! "$CLEAN_OUTPUT" == *"|"* ]]; then
        ISSUES+=("DB '${DB_SID}': Could not query status/role. SQL*Plus output: $SQL_OUTPUT")
        continue
    fi

    # Extract Open Mode and Role
    DB_OPEN_MODE=$(echo "$CLEAN_OUTPUT" | cut -d'|' -f1)
    DB_ROLE=$(echo "$CLEAN_OUTPUT" | cut -d'|' -f2)

    # 4c. Evaluate Health based on Role Matrix
    case "$DB_ROLE" in
        "PRIMARY")
            if [[ "$DB_OPEN_MODE" == "READ WRITE" ]]; then
                ((HEALTHY_DB_COUNT++))
            else
                ISSUES+=("DB '${DB_SID}': Is PRIMARY but open mode is '${DB_OPEN_MODE}' (Expected READ WRITE).")
            fi
            ;;
        "PHYSICAL STANDBY")
            # Can be MOUNTED (standard) or READ ONLY WITH APPLY (Active Data Guard)
            if [[ "$DB_OPEN_MODE" == "MOUNTED" || "$DB_OPEN_MODE" == "READ ONLY WITH APPLY" ]]; then
                ((HEALTHY_DB_COUNT++))
            else
                ISSUES+=("DB '${DB_SID}': Is PHYSICAL STANDBY but open mode is '${DB_OPEN_MODE}' (Expected MOUNTED or READ ONLY WITH APPLY).")
            fi
            ;;
        "SNAPSHOT STANDBY")
            # Snapshot standbys are open read/write for isolated testing
            if [[ "$DB_OPEN_MODE" == "READ WRITE" ]]; then
                ((HEALTHY_DB_COUNT++))
            else
                ISSUES+=("DB '${DB_SID}': Is SNAPSHOT STANDBY but open mode is '${DB_OPEN_MODE}' (Expected READ WRITE).")
            fi
            ;;
        "LOGICAL STANDBY")
            if [[ "$DB_OPEN_MODE" == "READ WRITE" ]]; then
                ((HEALTHY_DB_COUNT++))
            else
                ISSUES+=("DB '${DB_SID}': Is LOGICAL STANDBY but open mode is '${DB_OPEN_MODE}' (Expected READ WRITE).")
            fi
            ;;
        *)
            ISSUES+=("DB '${DB_SID}': Unknown or transitioning role '${DB_ROLE}' with open mode '${DB_OPEN_MODE}'.")
            ;;
    esac

done

# ==============================================================================
# Summarize and output the results
# ==============================================================================

# Join the checked databases array into a comma-separated string
CHECKED_DBS_STR=$(IFS=', '; echo "${CHECKED_DBS[*]}")

if [ ${#ISSUES[@]} -eq 0 ]; then
    echo -e "${GREEN}Everything is fine:${NC} The listener is running, and all $TOTAL_DB_COUNT configured database(s) ($CHECKED_DBS_STR) are in healthy states corresponding to their Data Guard roles."
    exit 0
else
    echo -e "${RED}Warning: Database health check on ($CHECKED_DBS_STR) detected issues!${NC}"
    for issue in "${ISSUES[@]}"; do
        echo -e " ${RED}-${NC} $issue"
    done
    exit 1
fi
