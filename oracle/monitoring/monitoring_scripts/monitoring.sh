#!/bin/bash
# -----------------------------------------------------------------------------
# Script Name : monitoring.sh
# Location    : /home/oracle/scripts/monitoring
# Purpose     : Monitor Oracle DB (incl. Data Guard) and send HTML alerts via
#               CURL (SMTP). Run from crontab every 30 minutes, one call per SID.
#
# Usage       : ./monitoring.sh <ORACLE_SID>
# Crontab     : */30 * * * * /home/oracle/scripts/monitoring/monitoring.sh PRODDB1
#
# Release version is defined ONCE, in monitoring.sql (DEFINE mon_version).
# This script reads it from there, so the two can never drift apart.
# Bump it on every change and add a CHANGELOG line in monitoring.sql.
# -----------------------------------------------------------------------------

# --- Configuration Section ---
ORACLE_SID="$1"
ORACLE_BASE="/home/oracle/scripts/monitoring"
LOG_DIR="${ORACLE_BASE}/log"
ORACLE_HOME="/u01/app/oracle/product/19/dbhome_1"
SQL_SCRIPT="monitoring.sql"

# Housekeeping: delete rotated alert logs older than N days.
# Set to 0 to keep everything forever.
LOG_RETENTION_DAYS=30

# Email Settings
EMAIL_TO="dbmonitorteam@company.com"
EMAIL_FROM="oracle_alerts@company.com"
SMTP_URL="smtp://postacim.company.com:25"

# Timestamp & Files
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
DB_LOG="${LOG_DIR}/db_result_${ORACLE_SID}.html"

# Set Oracle Environment
export ORACLE_HOME
export ORACLE_SID
export PATH=$ORACLE_HOME/bin:$PATH:/bin:/usr/bin:/usr/local/bin:.

# Short hostname - goes into the mail subject so a full inbox stays readable.
# Resolved AFTER the PATH export: cron starts with a minimal PATH and this must
# not silently come back empty.
HOST_SHORT=$(hostname -s 2>/dev/null || uname -n 2>/dev/null)
[[ -z "$HOST_SHORT" ]] && HOST_SHORT="unknown-host"

# --- Input Validation ---
if [[ -z "$ORACLE_SID" ]]; then
    echo "Error: No ORACLE_SID provided."
    echo "Usage: $0 <ORACLE_SID>"
    exit 1
fi

if [[ ! -f "${ORACLE_BASE}/${SQL_SCRIPT}" ]]; then
    echo "Error: ${ORACLE_BASE}/${SQL_SCRIPT} not found."
    exit 1
fi

mkdir -p "$LOG_DIR"

# --- Read the release version from the SQL script (single source of truth) ---
MON_VERSION=$(awk -F'"' '/^DEFINE[ \t]+mon_version/ {print $2; exit}' "${ORACLE_BASE}/${SQL_SCRIPT}")
[[ -z "$MON_VERSION" ]] && MON_VERSION="unknown"

# --- Function: Send Email via CURL ---
send_alert() {
    local subject="$1"
    local log_file="$2"

    # 1. Check if the log contains error keywords (Case Insensitive)
    if grep -iqE 'SEND_MAIL|error|ERROR|ORA-' "$log_file"; then

        echo "[ALERT] Issues detected on $ORACLE_SID. Preparing email..."

        # SID is part of the name: several instances on the same host can alert
        # in the same second, and they must not share (or delete) each other's
        # payload file while curl is still uploading it.
        local email_temp="${LOG_DIR}/email_payload_${ORACLE_SID}_${TIMESTAMP}.eml"

        # 2. Construct Headers
        # Note: We use printf to ensure explicit CRLF (\r\n) in headers
        printf "From: %s\r\n" "$EMAIL_FROM" > "$email_temp"
        printf "To: %s\r\n" "$EMAIL_TO" >> "$email_temp"
        printf "Subject: %s\r\n" "$subject" >> "$email_temp"
        printf "MIME-Version: 1.0\r\n" >> "$email_temp"
        printf "Content-Type: text/html; charset=utf-8\r\n" >> "$email_temp"
        printf "\r\n" >> "$email_temp"

        # 3. Append Body (Cleaning and Converting to CRLF)
        # sed -n '/<html>/,$p' : Drops everything BEFORE the first <html> tag
        # sed 's/$/\r/'        : Adds a Carriage Return to every line for SMTP compliance
        sed -n '/<html>/,$p' "$log_file" | sed 's/$/\r/' >> "$email_temp"

        # 4. Send via CURL
        curl --url "$SMTP_URL" \
             --mail-from "$EMAIL_FROM" \
             --mail-rcpt "$EMAIL_TO" \
             --upload-file "$email_temp" \
             --silent --show-error

        if [ $? -eq 0 ]; then
            echo "[SUCCESS] Email sent successfully."
            mv "$log_file" "${log_file}_${TIMESTAMP}"
        else
            echo "[ERROR] Failed to send email."
        fi

        # Cleanup
        rm -f "$email_temp"

    else
        echo "[INFO] System Healthy. No email needed."
        [ -f "$log_file" ] && rm -f "$log_file"
    fi
}

# =============================================================================
# Execution
# =============================================================================
cd "$ORACLE_BASE" || exit 1

# 1. Run SQLPlus
sqlplus -s / as sysdba @"${SQL_SCRIPT}" > "$DB_LOG" 2>&1

# 2. Process Results
send_alert "[Warning] DB Health Alert: ${ORACLE_SID} @ ${HOST_SHORT}" "$DB_LOG"

# 3. Housekeeping - rotated alert logs would otherwise grow without limit
if [[ "$LOG_RETENTION_DAYS" -gt 0 ]]; then
    find "$LOG_DIR" -maxdepth 1 -type f \
         \( -name "db_result_*.html_*" -o -name "email_payload_*.eml" \) \
         -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
fi

exit 0
