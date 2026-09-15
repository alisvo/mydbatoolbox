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

# Last line of defence on mail size. monitoring.sql already caps its unbounded
# sections, so this should never fire - but an oversized mail can be rejected by
# the SMTP server, and a monitoring alert that never arrives is the worst
# possible outcome. Beyond this the body is cut and the mail says where the full
# report was kept. Set to 0 to disable.
MAX_MAIL_KB=512

# Email Settings
EMAIL_TO="databaseteam@mycomp.com"
EMAIL_FROM="oraclealerting@mycomp.com"
SMTP_URL="smtp://mailsender.mycomp.com:25"

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

    # 1. Decide whether this run is worth a mail.
    #
    #    CASE SENSITIVE and anchored on purpose. The old pattern was
    #        grep -iqE 'SEND_MAIL|error|ERROR|ORA-'
    #    which matched the word "error" ANYWHERE in the file, including inside
    #    reported data. That made it impossible to print anything informational:
    #    a Data Guard message whose severity reads "Error" mailed on its own,
    #    even with no SEND_MAIL anywhere. Now:
    #
    #      SEND_MAIL      - a check deliberately raised an alert. The only
    #                       trigger that comes from the report itself.
    #      ^ERROR         - SQLPlus prints "ERROR at line N:" before a failed
    #                       statement and "ERROR:" before a failed logon, both
    #                       at the start of a line. This is the safety net that
    #                       surfaces a broken script (bad column, bad
    #                       ORACLE_HOME, logon denied). Data cells never match:
    #                       the severity value is "Error", not "ERROR".
    #      ^SP2-          - SQLPlus level failures, e.g. a missing script file.
    #
    #    A sqlplus binary that will not even start prints nothing we could grep,
    #    so its exit code is checked separately below.
    if [[ "$SQLPLUS_RC" -ne 0 ]] || grep -qE 'SEND_MAIL|^ERROR|^SP2-' "$log_file"; then

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
        local body_bytes
        body_bytes=$(wc -c < "$log_file")

        if [[ "$MAX_MAIL_KB" -gt 0 ]] && (( body_bytes > MAX_MAIL_KB * 1024 )); then
            echo "[WARN] Report is $(( body_bytes / 1024 )) KB, cutting the mail at ${MAX_MAIL_KB} KB."
            sed -n '/<html>/,$p' "$log_file" \
                | head -c $(( MAX_MAIL_KB * 1024 )) \
                | sed 's/$/\r/' >> "$email_temp"
            # The log file is renamed to this path right after a successful send.
            printf '<hr><p style="color:#8a4b00"><b>[MAIL TRUNCATED]</b> The report was %s KB and was cut at %s KB.<br>Full report on %s: %s</p>\r\n' \
                   "$(( body_bytes / 1024 ))" "$MAX_MAIL_KB" "$HOST_SHORT" "${log_file}_${TIMESTAMP}" >> "$email_temp"
            printf '</body></html>\r\n' >> "$email_temp"
        else
            sed -n '/<html>/,$p' "$log_file" | sed 's/$/\r/' >> "$email_temp"
        fi

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

# 1. Run SQLPlus. The exit code is kept: if sqlplus cannot start at all there
#    is nothing in the log for grep to find, and a silent monitoring script is
#    worse than a noisy one.
sqlplus -s / as sysdba @"${SQL_SCRIPT}" > "$DB_LOG" 2>&1
SQLPLUS_RC=$?

# 2. Process Results
send_alert "[Warning] DB Health Alert: ${ORACLE_SID} @ ${HOST_SHORT}" "$DB_LOG"

# 3. Housekeeping - rotated alert logs would otherwise grow without limit
if [[ "$LOG_RETENTION_DAYS" -gt 0 ]]; then
    find "$LOG_DIR" -maxdepth 1 -type f \
         \( -name "db_result_*.html_*" -o -name "email_payload_*.eml" \) \
         -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
fi

exit 0
