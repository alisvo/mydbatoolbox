#!/usr/bin/env bash
# db_stop.sh — /etc/oratab'da :Y olan instance'ları kapatır, en sonda listener'ları durdurur
#   Ortam: 19c+, single instance, non-ASM/Grid/RAC, physical standby
#
#   - Data Guard durumu DEĞİŞTİRİLMEZ (TRANSPORT-OFF / APPLY-OFF / DEFER yapılmaz).
#     Broker intended state'i kalıcı saklar; DB açılınca transport/apply kendiliğinden
#     döner, aradaki redo boşluğu (gap) otomatik kapanır.
#   - Broker'sız standby: MRP varsa önce CANCEL edilir.
#   - shutdown immediate; SHUTDOWN_TIMEOUT içinde bitmezse shutdown abort.
#   - Bir DB'nin hatası diğerlerini durdurmaz; hata varsa exit 1.
#   oracle kullanıcısıyla çalıştırın (systemd: User=oracle).

set -uo pipefail
export LC_ALL=C
cd / || exit 1

ORATAB=${ORATAB:-/etc/oratab}
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-600}   # DB başına shutdown immediate süresi (sn)
BASE_PATH=$PATH
FAILED=()

read -r -d '' Q_INFO <<'SQL' || true
select database_role||'|'||(select value from v$parameter where name='dg_broker_start')
from v$database;
SQL
read -r -d '' Q_MRP <<'SQL' || true
select count(*) from v$dataguard_process where name like 'MRP%';
SQL

log() { echo "$(date '+%F %T') $*"; }

ora_env() {  # $1=ORACLE_HOME [$2=SID]
  export ORACLE_HOME=$1 ORACLE_SID=${2:-} PATH="$1/bin:$BASE_PATH" LD_LIBRARY_PATH="$1/lib"
  export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
  ORACLE_BASE=$("$1/bin/orabase"); export ORACLE_BASE
  unset TWO_TASK
}

sql() {  # $1=SQL -> dolu satırlar; hata -> ORA satırları stderr'e, rc 1
  local out
  out=$(sqlplus -S -L / as sysdba 2>&1 <<EOF
whenever sqlerror exit failure
set heading off feedback off pagesize 0 linesize 500 trimout on
$1
exit
EOF
) || { grep -m3 -E 'ORA-|SP2-' <<<"$out" >&2 || head -3 <<<"$out" >&2; return 1; }
  awk 'NF { $1 = $1; print }' <<<"$out"
}

pmon_up() { pgrep -f "^ora_pmon_$1\$" >/dev/null; }

wait_down() {  # $1=SID — pmon'un kaybolmasını en fazla 15 sn bekle
  for _ in {1..15}; do pmon_up "$1" || return 0; sleep 1; done
  return 1
}

lsnr_up() { [[ $(lsnrctl status "$1" 2>&1) == *Uptime* ]]; }

stop_listeners() {  # $1=ORACLE_HOME — tespit db_start.sh ile aynı
  local f l names
  ora_env "$1"
  f="${TNS_ADMIN:-$(orabasehome)/network/admin}/listener.ora"
  names=$(awk '
    function flush() { if (k != "" && k !~ /^SID_LIST_/ && b ~ /\( *(ADDRESS|DESCRIPTION)/) print k; k = b = "" }
    { sub(/#.*/, "") }
    /^[A-Za-z][A-Za-z0-9_.-]* *=/ { flush(); k = toupper($0); sub(/ *=.*/, "", k) }
    { b = b toupper($0) }
    END { flush() }' "$f" 2>/dev/null)
  for l in ${names:-LISTENER}; do
    lsnr_up "$l" || continue
    log "Listener $l durduruluyor ($1)"
    lsnrctl stop "$l" >/dev/null 2>&1
    lsnr_up "$l" && { log "HATA: listener $l durmadı"; FAILED+=("listener:$l"); }
  done
}

stop_db() {  # $1=SID $2=ORACLE_HOME
  local sid=$1 role bkr n
  ora_env "$2" "$sid"
  pmon_up "$sid" || { log "$sid: zaten kapalı"; return 0; }

  IFS='|' read -r role bkr <<<"$(sql "$Q_INFO" 2>/dev/null)"   # NOMOUNT'ta boş gelir, sorun değil
  log "$sid: rol=${role:-?}, broker=${bkr:-?}"

  if [[ $role == "PHYSICAL STANDBY" && $bkr != TRUE ]]; then
    n=$(sql "$Q_MRP") || n=0
    if ((n > 0)); then
      log "$sid: MRP cancel"
      sql 'alter database recover managed standby database cancel;' >/dev/null ||
        log "UYARI: $sid MRP cancel başarısız, shutdown ile devam"
    fi
  fi

  log "$sid: shutdown immediate"
  timeout -k 10 "$SHUTDOWN_TIMEOUT" sqlplus -S -L / as sysdba <<<"shutdown immediate"
  if ! wait_down "$sid"; then
    log "UYARI: $sid ${SHUTDOWN_TIMEOUT} sn içinde kapanmadı -> shutdown abort"
    sqlplus -S -L / as sysdba <<<"shutdown abort"
    wait_down "$sid" || { log "HATA: $sid kapatılamadı"; return 1; }
  fi
  log "$sid: kapandı"
}

# ------------------------------------------------------------------ main
((EUID != 0)) || { log "HATA: root ile değil, oracle kullanıcısıyla çalıştırın"; exit 1; }
[[ -r $ORATAB ]] || { log "HATA: $ORATAB okunamıyor"; exit 1; }

mapfile -t ENTRIES < <(awk -F: '{ sub(/#.*/, ""); gsub(/[ \t\r]/, "") }
  NF >= 3 && $1 != "*" && $1 !~ /^[+-]/ && $3 ~ /^[Yy]/ && !seen[$1]++ { print $1 ":" $2 }' "$ORATAB")
((${#ENTRIES[@]})) || { log "oratab'da :Y kayıt yok"; exit 0; }

for e in "${ENTRIES[@]}"; do
  stop_db "${e%%:*}" "${e#*:}" || FAILED+=("${e%%:*}")
done

declare -A homes=()
for e in "${ENTRIES[@]}"; do
  h=${e#*:}
  [[ -n ${homes[$h]:-} ]] && continue
  homes[$h]=1
  stop_listeners "$h"
done

if ((${#FAILED[@]})); then log "BİTTİ — hatalı: ${FAILED[*]}"; exit 1; fi
log "BİTTİ — tüm instance'lar ve listener'lar kapalı"
