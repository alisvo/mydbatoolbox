#!/usr/bin/env bash
# db_start.sh — /etc/oratab'da :Y olan instance'ları başlatır
#   Ortam: 19c+, single instance, non-ASM/Grid/RAC, physical standby (ADG lisanslı)
#
#   1) Her ORACLE_HOME için listener.ora'daki listener'lar (çalışmıyorsa) başlatılır
#   2) startup -> PRIMARY: READ WRITE, PHYSICAL STANDBY: READ ONLY (ADG)
#      MOUNT_SIDS'teki instance'lar MOUNT'ta kalır (primary çıkarsa yine OPEN edilir)
#   3) Broker varsa : intended state TRANSPORT-ON (primary) / APPLY-ON (standby)
#      Broker yoksa : primary -> DEFERRED/ERROR standby dest ENABLE, standby -> MRP
#   Zaten açık olan adımlar atlanır; bir DB'nin hatası diğerlerini durdurmaz.
#   Hata varsa exit 1. oracle kullanıcısıyla çalıştırın (systemd: User=oracle).

set -uo pipefail
export LC_ALL=C
cd / || exit 1

ORATAB=${ORATAB:-/etc/oratab}
MOUNT_SIDS=${MOUNT_SIDS:-}          # örn. "STBY2 STBY3"
BROKER_WAIT=${BROKER_WAIT:-120}     # broker'ın hazır olmasını bekleme (sn)
BASE_PATH=$PATH
FAILED=()

read -r -d '' Q_INFO <<'SQL' || true
select database_role||'|'||open_mode||'|'||
       (select value from v$parameter where name='dg_broker_start')||'|'||
       (select value from v$parameter where name='db_unique_name')
from v$database;
SQL
read -r -d '' Q_DEFERRED <<'SQL' || true
select dest_id from v$archive_dest
where target='STANDBY' and status in ('DEFERRED','ERROR');
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

lsnr_up() { [[ $(lsnrctl status "$1" 2>&1) == *Uptime* ]]; }

start_listeners() {  # $1=ORACLE_HOME
  local f l names
  ora_env "$1"
  f="${TNS_ADMIN:-$(orabasehome)/network/admin}/listener.ora"
  # 1. sütundan başlayan, değerinde ADDRESS/DESCRIPTION geçen ve SID_LIST_ olmayan her girdi bir listener'dır
  names=$(awk '
    function flush() { if (k != "" && k !~ /^SID_LIST_/ && b ~ /\( *(ADDRESS|DESCRIPTION)/) print k; k = b = "" }
    { sub(/#.*/, "") }
    /^[A-Za-z][A-Za-z0-9_.-]* *=/ { flush(); k = toupper($0); sub(/ *=.*/, "", k) }
    { b = b toupper($0) }
    END { flush() }' "$f" 2>/dev/null)
  for l in ${names:-LISTENER}; do
    lsnr_up "$l" && continue
    log "Listener $l başlatılıyor ($1)"
    lsnrctl start "$l" >/dev/null 2>&1
    lsnr_up "$l" || { log "HATA: listener $l başlamadı"; FAILED+=("listener:$l"); }
  done
}

broker_on() {  # $1=SID $2=db_unique_name $3=role ; rc 2 = broker config yok
  local want=APPLY-ON out state i
  [[ $3 == PRIMARY ]] && want=TRANSPORT-ON
  for ((i = 0; i < BROKER_WAIT; i += 5)); do
    out=$(dgmgrl -silent / "show database '$2'" 2>&1)
    [[ $out == *ORA-16525* ]] || break          # ORA-16525: broker henüz hazır değil
    sleep 5
  done
  [[ $out == *ORA-16532* ]] && return 2          # broker açık ama konfigürasyon yok
  state=$(awk -F: '/Intended State/ { gsub(/[ \t]/, "", $2); print $2 }' <<<"$out")
  [[ -n $state ]] || { log "HATA: $1 broker durumu okunamadı"; grep -m3 'ORA-' <<<"$out"; return 1; }
  [[ $state == "$want" ]] && { log "$1: broker $state"; return 0; }
  log "$1: broker $state -> $want"
  out=$(dgmgrl -silent / "edit database '$2' set state='$want'" 2>&1)
  [[ $out == *Succeeded* ]] || { log "HATA: $1 broker state değişmedi"; grep -m3 'ORA-' <<<"$out"; return 1; }
}

manual_dg() {  # $1=SID $2=role
  local id ids n
  if [[ $2 == PRIMARY ]]; then
    ids=$(sql "$Q_DEFERRED") || return 1
    for id in $ids; do
      log "$1: log_archive_dest_state_$id=ENABLE"
      sql "alter system set log_archive_dest_state_$id=ENABLE scope=both;" >/dev/null || return 1
    done
  else
    n=$(sql "$Q_MRP") || return 1
    ((n > 0)) && { log "$1: MRP çalışıyor"; return 0; }
    log "$1: MRP başlatılıyor"
    sql 'alter database recover managed standby database disconnect from session;' >/dev/null
  fi
}

start_db() {  # $1=SID $2=ORACLE_HOME
  local sid=$1 cmd=startup st role omode bkr dbu rc
  ora_env "$2" "$sid"

  if ! pgrep -f "^ora_pmon_${sid}\$" >/dev/null; then
    [[ " $MOUNT_SIDS " == *" $sid "* ]] && cmd="startup mount"
    log "$sid: $cmd"
    sqlplus -S -L / as sysdba <<<"$cmd"           # çıktı doğrudan log'a
  fi
  st=$(sql 'select status from v$instance;') || st=DOWN
  [[ $st == MOUNTED || $st == OPEN ]] || { log "HATA: $sid açılamadı (durum=$st)"; return 1; }

  IFS='|' read -r role omode bkr dbu <<<"$(sql "$Q_INFO")"
  if [[ $role == PRIMARY && $omode == MOUNTED ]]; then
    log "$sid: primary MOUNT'ta -> open"
    sql 'alter database open;' >/dev/null || return 1
    omode="READ WRITE"
  fi
  log "$sid: rol=$role, open_mode=$omode, broker=$bkr"

  [[ $role == PRIMARY || $role == "PHYSICAL STANDBY" ]] || return 0   # snapshot vb.: DG adımı yok
  if [[ $bkr == TRUE ]]; then
    broker_on "$sid" "$dbu" "$role"; rc=$?
    ((rc == 2)) || return $rc
    log "$sid: broker açık ama konfigürasyon yok -> manuel DG"
  fi
  manual_dg "$sid" "$role"
}

# ------------------------------------------------------------------ main
((EUID != 0)) || { log "HATA: root ile değil, oracle kullanıcısıyla çalıştırın"; exit 1; }
[[ -r $ORATAB ]] || { log "HATA: $ORATAB okunamıyor"; exit 1; }

# SID:HOME — yorumlar, *, +ASM atlanır; sıra korunur, tekrarlar atılır
mapfile -t ENTRIES < <(awk -F: '{ sub(/#.*/, ""); gsub(/[ \t\r]/, "") }
  NF >= 3 && $1 != "*" && $1 !~ /^[+-]/ && $3 ~ /^[Yy]/ && !seen[$1]++ { print $1 ":" $2 }' "$ORATAB")
((${#ENTRIES[@]})) || { log "oratab'da :Y kayıt yok"; exit 0; }

declare -A homes=()
for e in "${ENTRIES[@]}"; do
  h=${e#*:}
  [[ -n ${homes[$h]:-} ]] && continue
  homes[$h]=1
  start_listeners "$h"
done

for e in "${ENTRIES[@]}"; do
  start_db "${e%%:*}" "${e#*:}" || FAILED+=("${e%%:*}")
done

if ((${#FAILED[@]})); then log "BİTTİ — hatalı: ${FAILED[*]}"; exit 1; fi
log "BİTTİ — tüm instance'lar ve listener'lar ayakta"
