#!/bin/bash
# -----------------------------------------------------------------------------
# Script Name: db_monitoring.sh
# Purpose: Monitor Oracle DB and send HTML Alerts via CURL (SMTP)
# -----------------------------------------------------------------------------

# --- Configuration Section ---
ORACLE_SID="$1"
ORACLE_BASE="/home/oracle/scripts/monitoringv2"
LOG_DIR="${ORACLE_BASE}/log"
ORACLE_HOME="/u01/app/oracle/product/19/dbhome_1"

# Email Settings
EMAIL_TO="dbateam@mycompmail.com"
EMAIL_FROM="oracle_alerts@mycompmail.com"
SMTP_URL="smtp://mycompmailserver.mycompmail.com:25" 

# Timestamp & Files
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
DB_LOG="${LOG_DIR}/db_result_${ORACLE_SID}.html"

# Set Oracle Environment
export ORACLE_HOME
export ORACLE_SID
export PATH=$ORACLE_HOME/bin:$PATH:/bin:/usr/bin:/usr/local/bin:.

# --- Input Validation ---
if [[ -z "$ORACLE_SID" ]]; then
    echo "Error: No ORACLE_SID provided."
    echo "Usage: $0 <ORACLE_SID>"
    exit 1
fi

mkdir -p "$LOG_DIR"

# --- Function: Send Email via CURL ---
send_alert() {
    local subject="$1"
    local log_file="$2"

    # 1. Check if the log contains error keywords (Case Insensitive)
    if grep -iqE 'SEND_MAIL|error|ERROR|ORA-' "$log_file"; then
        
        echo "[ALERT] Issues detected on $ORACLE_SID. Preparing email..."
        
        local email_temp="${LOG_DIR}/email_payload_${TIMESTAMP}.eml"
        
        # 2. Construct Headers
        # Note: We use printf to ensure explicit CRLF (\r\n) in headers
        printf "From: %s\r\n" "$EMAIL_FROM" > "$email_temp"
        printf "To: %s\r\n" "$EMAIL_TO" >> "$email_temp"
        printf "Subject: %s\r\n" "$subject" >> "$email_temp"
        printf "MIME-Version: 1.0\r\n" >> "$email_temp"
        printf "Content-Type: text/html; charset=utf-8\r\n" >> "$email_temp"
        printf "\r\n" >> "$email_temp" 

        # 3. Append Body (Cleaning and Converting to CRLF)
        # sed '1,/<html>/!d' : Deletes everything BEFORE the first <html> tag (removes blank lines)
        # sed 's/$/\r/'      : Adds a Carriage Return (\r) to the end of every line for SMTP compliance
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
sqlplus -s / as sysdba @monitoring_v2.sql > "$DB_LOG" 2>&1

# 2. Process Results
send_alert "[Warning] DB Health Alert: $ORACLE_SID" "$DB_LOG"

exit 0
