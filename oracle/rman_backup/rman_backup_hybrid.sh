#!/bin/bash
# ------------------------------------------------------------------------------
# Script: rman_backup_hybrid.sh
# ------------------------------------------------------------------------------

# 1. Load Configuration
CONFIG_FILE=$1
if [ -z "${CONFIG_FILE}" ]; then
  echo "CRITICAL ERROR: No config file provided."
  exit 1
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "CRITICAL ERROR: Config file not found at: ${CONFIG_FILE}"
  exit 1
fi

# Load variables
source "${CONFIG_FILE}"

# 2. GUARD RAILS: Check if variables are actually loaded
if [[ -z "$ORACLE_SID" ]]; then echo "ERROR: ORACLE_SID is empty"; exit 1; fi
if [[ -z "$DAILY_RET" ]]; then echo "ERROR: DAILY_RET is empty"; exit 1; fi
if [[ -z "$WEEKLY_RET" ]]; then echo "ERROR: WEEKLY_RET is empty"; exit 1; fi
if [[ -z "$BACKUP_LOC" ]]; then echo "ERROR: BACKUP_LOC is empty"; exit 1; fi

# 3. Setup Environment
export ORACLE_SID
export ORACLE_HOME
export PATH=$ORACLE_HOME/bin:$PATH
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'

# 4. Logic: Sunday vs Weekday
DOW=$(date +%u) # 1=Mon ... 7=Sun

if [[ $DOW -eq 7 ]]; then
  # SUNDAY
  INCR_LEVEL=0
  BKP_TAG="L0_WEEKLY"
  RETENTION_CLAUSE="KEEP UNTIL TIME 'SYSDATE+${WEEKLY_RET}' RESTORE POINT WEEKLY_$(date +%Y_W%U)"
else
  # WEEKDAY
  INCR_LEVEL=1
  BKP_TAG="L1_DAILY"
  RETENTION_CLAUSE="KEEP UNTIL TIME 'SYSDATE+${DAILY_RET}'"
fi

# Log File Setup
mkdir -p ${LOG_DIR}
LOG_FILE=${LOG_DIR}/${ORACLE_SID}_${BKP_TAG}_$(date +%Y-%m-%d_%H%M).log

# 5. RMAN Execution
# FIX: 'CHECK LOGICAL' is moved to the START of the command.
$ORACLE_HOME/bin/rman target / nocatalog msglog=$LOG_FILE append << EOF

CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${PITR_RET} DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${BACKUP_LOC}/%F';
CONFIGURE DEVICE TYPE DISK PARALLELISM ${PARALLELISM} BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE BACKUP OPTIMIZATION ON;

RUN {
    CROSSCHECK BACKUP;
    CROSSCHECK ARCHIVELOG ALL;

    BACKUP CHECK LOGICAL INCREMENTAL LEVEL ${INCR_LEVEL} CUMULATIVE DEVICE TYPE DISK TAG '${BKP_TAG}' DATABASE FORMAT '${BACKUP_LOC}/${ORACLE_SID}_%T_L${INCR_LEVEL}_%U' ${RETENTION_CLAUSE} PLUS ARCHIVELOG TAG 'ARC_BKP' FORMAT '${BACKUP_LOC}/${ORACLE_SID}_%T_arch_%U';

    DELETE NOPROMPT OBSOLETE;
    DELETE NOPROMPT EXPIRED BACKUP;
    DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;
}
EXIT;
EOF

# 6. Final Status
if [ $? -eq 0 ]; then
  echo "SUCCESS: Backup completed." >> $LOG_FILE
else
  echo "CRITICAL: Backup FAILED." >> $LOG_FILE
  exit 1
fi
