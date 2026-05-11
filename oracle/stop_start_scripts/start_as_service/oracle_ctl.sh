#!/bin/bash
# Usage: oracle_ctl.sh [start|stop]
ACTION=${1:-start}
SQL_CMD=$([ "$ACTION" == "stop" ] && echo "shutdown immediate;" || echo "startup;")

# Step 1: Manage Databases (Parse /etc/oratab for SIDs marked with 'Y')
awk -F: '/^[^#*]/ && $3 == "Y" {print $1, $2}' /etc/oratab | while read -r SID OHOME; do
    export ORACLE_SID=$SID ORACLE_HOME=$OHOME PATH=$OHOME/bin:$PATH
    echo "--- Executing $ACTION on Database: $SID ---"
    sqlplus -S / as sysdba <<< "$SQL_CMD"
done

# Step 2: Manage Listeners (Extract unique ORACLE_HOMEs to avoid duplicate triggers)
awk -F: '/^[^#*]/ && $3 == "Y" {print $2}' /etc/oratab | sort -u | while read -r OHOME; do
    export ORACLE_HOME=$OHOME PATH=$OHOME/bin:$PATH
    echo "--- Executing $ACTION on Listener from $OHOME ---"
    lsnrctl "$ACTION" > /dev/null 2>&1
done
