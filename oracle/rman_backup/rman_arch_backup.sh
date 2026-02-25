#!/bin/bash
# ------------------------------------------------------------------------------
# Script: rman_arch_backup.sh 
# Frequency: HOURLY (Recommended)
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

source "${CONFIG_FILE}"

# 2. GUARD RAILS: Check Vital Variables
if [[ -z "$ORACLE_SID" ]]; then echo "ERROR: ORACLE_SID is empty"; exit 1; fi
if [[ -z "$PITR_RET" ]]; then echo "ERROR: PITR_RET is empty"; exit 1; fi
if [[ -z "$ARCH_LOCAL_RET" ]]; then echo "ERROR: ARCH_LOCAL_RET is empty"; exit 1; fi
if [[ -z "$BACKUP_LOC" ]]; then echo "ERROR: BACKUP_LOC is empty"; exit 1; fi

# 3. Setup Environment
export ORACLE_SID
export ORACLE_HOME
export PATH=$ORACLE_HOME/bin:$PATH
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'

# Log File Setup
mkdir -p ${LOG_DIR}
LOG_FILE=${LOG_DIR}/${ORACLE_SID}_ARCH_HOURLY_$(date +%Y-%m-%d_%H%M).log

# 4. RMAN Execution
# FIX: Replaced '--' comments with '#' to fix RMAN-02001 error
$ORACLE_HOME/bin/rman target / nocatalog msglog=$LOG_FILE append << EOF

# 1. Safety & Performance Configurations
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${PITR_RET} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${PARALLELISM} BACKUP TYPE TO COMPRESSED BACKUPSET;

# CRITICAL: This prevents this script from re-doing work if the L0 is running
CONFIGURE BACKUP OPTIMIZATION ON;

RUN {
    # 2. Housekeeping
    CROSSCHECK ARCHIVELOG ALL;

    # 3. Force a log switch so we have the absolute latest data
    SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';

    # 4. Backup
    # 'NOT BACKED UP 1 TIMES' ensures we never touch a log that is already safe.
    BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL NOT BACKED UP 1 TIMES FORMAT '${BACKUP_LOC}/${ORACLE_SID}_%T_arch_hourly_%s.bkp' TAG 'ARCH_HOURLY';

    # 5. Cleanup (NFS) - Remove backups older than 14 days (PITR_RET)
    DELETE NOPROMPT OBSOLETE;

    # 6. Cleanup (Local Disk/FRA) - Free up space on the server
    # Note: The dash in 'SYSDATE-...' IS valid here because it is inside quotes.
    DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-${ARCH_LOCAL_RET}' BACKED UP 1 TIMES TO DISK;
}
EXIT;
EOF

# 5. Final Status
if [ $? -eq 0 ]; then
  echo "SUCCESS: Archive Backup completed." >> $LOG_FILE
else
  echo "CRITICAL: Archive Backup FAILED." >> $LOG_FILE
  exit 1
fi
