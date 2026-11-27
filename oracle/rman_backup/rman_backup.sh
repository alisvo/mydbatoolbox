#!/bin/bash
# ------------------------------------------------------------------------------
# rman_backup.sh - Oracle RMAN backup
#
# Kullanım: rman_backup.sh <config_dosyası> <daily|l0|weekly|arch>
#   daily  : L0_DAY günü L0, diğer günler L1 cumulative + archivelog + temizlik
#   l0     : daily ile aynı, ama her zaman L0 (ilk kurulum / zinciri yenileme)
#   weekly : KEEP UNTIL ile self-contained full backup (WEEKLY_RET gün saklanır)
#   arch   : archivelog backup + lokal archivelog temizliği
#
# Strateji:
#   * PITR (PITR_RET gün): daily/l0 + arch zinciri, RECOVERY WINDOW ile yönetilir.
#   * Uzun saklama (WEEKLY_RET gün): weekly KEEP backup'ları. Retention policy'ye
#     girmezler; KEEP süresi dolunca obsolete olur ve DELETE OBSOLETE ile silinirler.
# ------------------------------------------------------------------------------

usage() { echo "Kullanım: $0 <config_dosyası> <daily|l0|weekly|arch>" >&2; exit 1; }
log()   { echo "$(date '+%F %T') $*" >> "${LOG_FILE:-/dev/null}"; }
die()   { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }

CONFIG_FILE=$1
MODE=$2
[[ -f "$CONFIG_FILE" ]] || usage
[[ "$MODE" =~ ^(daily|l0|weekly|arch)$ ]] || usage
source "$CONFIG_FILE"

# Varsayılanlar (config'te yoksa)
LOG_RET=${LOG_RET:-30}
L0_DAY=${L0_DAY:-7}
LOCK_WAIT_MIN=${LOCK_WAIT_MIN:-360}
ARCH_DELETION_POLICY=${ARCH_DELETION_POLICY:-"BACKED UP 1 TIMES TO DEVICE TYPE DISK"}

# Config kontrolleri
for v in ORACLE_SID ORACLE_HOME BACKUP_LOC LOG_DIR; do
  [[ -n "${!v}" ]] || die "$v config dosyasında tanımlı değil"
done
for v in PARALLELISM PITR_RET WEEKLY_RET ARCH_LOCAL_RET LOG_RET L0_DAY LOCK_WAIT_MIN; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v sayı olmalı (değer: '${!v}')"
done

export ORACLE_SID ORACLE_HOME ORACLE_BASE
export PATH=$ORACLE_HOME/bin:$PATH
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'

# Log
mkdir -p "$LOG_DIR" || die "LOG_DIR oluşturulamadı: $LOG_DIR"
LOG_FILE=$LOG_DIR/${ORACLE_SID}_${MODE}_$(date +%Y%m%d_%H%M).log
find "$LOG_DIR" -name "${ORACLE_SID}_*.log" -mtime +"$LOG_RET" -delete

# Backup hedefi erişilebilir mi?
# NFS bağlı değilken çalışırsak CROSSCHECK tüm backup'ları EXPIRED işaretler ve
# DELETE EXPIRED kayıtlarını siler. Bu yüzden klasörü bilerek oluşturmuyoruz.
[[ -d "$BACKUP_LOC" && -w "$BACKUP_LOC" ]] || die "BACKUP_LOC erişilemiyor/yazılamıyor: $BACKUP_LOC"

# Aynı DB için iki RMAN işinin çakışmasını engelle.
# arch: başka iş çalışıyorsa atla (daily zaten archivelog'ları alıyor).
# Diğerleri: LOCK_WAIT_MIN dakikaya kadar bekle.
command -v flock >/dev/null || die "flock bulunamadı (util-linux paketi gerekli)"
exec 9>"$LOG_DIR/.${ORACLE_SID}_rman.lock"
if [[ $MODE == arch ]]; then
  flock -n 9 || { log "SKIP: başka bir RMAN işi çalışıyor"; exit 0; }
else
  flock -w $((LOCK_WAIT_MIN * 60)) 9 || die "lock ${LOCK_WAIT_MIN} dakikada alınamadı"
fi

# ---------------------------- RMAN komutları ----------------------------------
# CONFIGURE her modda çalışır: arch tek başına çalışsa bile deletion policy
# tanımlı olsun ve backup alınmamış archivelog silinmesin.
CONFIG_CMDS="
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${PITR_RET} DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${BACKUP_LOC}/%F';
CONFIGURE DEVICE TYPE DISK PARALLELISM ${PARALLELISM} BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE ARCHIVELOG DELETION POLICY TO ${ARCH_DELETION_POLICY};"

# DELETE ARCHIVELOG (FORCE olmadan) deletion policy'ye uyar:
# backup'ı alınmamış (ve Data Guard politikasıyla, uygulanmamış) log silinmez.
ARCH_CMDS="
CROSSCHECK ARCHIVELOG ALL;
SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
BACKUP ARCHIVELOG ALL NOT BACKED UP 1 TIMES TAG 'ARCH' FORMAT '${BACKUP_LOC}/%d_%T_arch_%U';
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-${ARCH_LOCAL_RET}';"

case $MODE in
  daily|l0)
    if [[ $MODE == l0 || $(date +%u) -eq $L0_DAY ]]; then
      LVL=0; LEVEL_CLAUSE="INCREMENTAL LEVEL 0"
    else
      LVL=1; LEVEL_CLAUSE="INCREMENTAL LEVEL 1 CUMULATIVE"
    fi
    RMAN_CMDS="
RUN {
  BACKUP CHECK LOGICAL ${LEVEL_CLAUSE} DATABASE TAG 'DAILY_L${LVL}' FORMAT '${BACKUP_LOC}/%d_%T_L${LVL}_%U';
}
${ARCH_CMDS}
CROSSCHECK BACKUP;
DELETE NOPROMPT EXPIRED BACKUP;
DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;
DELETE NOPROMPT OBSOLETE;"
    ;;
  weekly)
    # Tag her hafta farklı: aynı tag'li eski KEEP backup varsa backup optimization
    # (örn. read-only tablespace'lerde) dosyaları atlayıp eski backup'a güvenebilir.
    # KEEP backup gereken archivelog, controlfile ve spfile'ı kendisi alır.
    STAMP=$(date +%Y%m%d_%H%M)
    RMAN_CMDS="
BACKUP CHECK LOGICAL DATABASE TAG 'WEEKLY_${STAMP}' FORMAT '${BACKUP_LOC}/%d_%T_weekly_%U'
  KEEP UNTIL TIME 'SYSDATE+${WEEKLY_RET}' RESTORE POINT WEEKLY_${STAMP};"
    ;;
  arch)
    RMAN_CMDS=$ARCH_CMDS
    ;;
esac

# ------------------------------- Çalıştır -------------------------------------
log "START: mode=$MODE"
rman target / nocatalog msglog="$LOG_FILE" append <<EOF
${CONFIG_CMDS}
${RMAN_CMDS}
EXIT;
EOF
RC=$?

if [[ $RC -eq 0 ]]; then
  log "SUCCESS: mode=$MODE"
else
  die "RMAN başarısız (mode=$MODE, rc=$RC). Detay: $LOG_FILE"
fi
