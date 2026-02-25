#!/usr/bin/env bash
# db_stop.sh — /etc/oratab'dan okuyarak Oracle DB kapatma (DG varsa otomatik)
# - Standalone: sadece shutdown immediate
# - DG + Broker: PRIMARY→TRANSPORT-OFF, STANDBY→APPLY-OFF (DGMGRL)
# - DG (No Broker): PRIMARY→DEFER (yalnız STANDBY dest varsa), STANDBY→MRP CANCEL
# - Listener stop en sonda (her ORACLE_HOME için bir kez)

set -euo pipefail
ORATAB_FILE=${ORATAB_FILE:-/etc/oratab}

[[ -r "$ORATAB_FILE" ]] || { echo "[ERROR] $ORATAB_FILE okunamıyor." >&2; exit 1; }

mapfile -t ENTRIES < <(grep -E '^[[:space:]]*[^#][^:]*:[^:]+:[Yy][[:space:]]*$' "$ORATAB_FILE" | sort -u)
((${#ENTRIES[@]})) || { echo "[INFO] Oratab'da :Y kayıt yok."; exit 0; }

declare -A HOMES_SEEN=()

for line in "${ENTRIES[@]}"; do
  IFS=: read -r SID HOME _ <<<"$line"
  HOMES_SEEN["$HOME"]=1

  export ORACLE_SID="$SID" ORACLE_HOME="$HOME" PATH="$ORACLE_HOME/bin:$PATH"

  if [[ ! -x "$ORACLE_HOME/bin/sqlplus" ]]; then
    echo "[WARN] $SID: sqlplus bulunamadı ($ORACLE_HOME/bin/sqlplus). Atlanıyor."
    continue
  fi

  # Rol & Broker
  ROLE=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL' | awk 'NF{print;exit}'
set head off feed off pages 0 verify off echo off
select database_role from v$database;
exit
SQL
); ROLE="$(echo "$ROLE" | tr -d '\r' | awk '{$1=$1}1')"

  BKR=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL' | awk 'NF{print;exit}'
set head off feed off pages 0 verify off echo off
select value from v$parameter where name='dg_broker_start';
exit
SQL
); BKR="$(echo "$BKR" | tr -d '\r' | awk '{$1=$1}1')"

  if [[ "$ROLE" == "PRIMARY" ]]; then
    if [[ "${BKR^^}" == "TRUE" && -x "$ORACLE_HOME/bin/dgmgrl" ]]; then
      DBU=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL' | awk 'NF{print;exit}'
set head off feed off pages 0 verify off echo off
select value from v$parameter where name='db_unique_name';
exit
SQL
); DBU="$(echo "$DBU" | awk '{$1=$1}1')"
      if [[ -n "$DBU" ]]; then
        echo "[INFO] $SID ($DBU): DGMGRL TRANSPORT-OFF"
        "$ORACLE_HOME/bin/dgmgrl" -silent <<EOF >/dev/null
connect /
EDIT DATABASE '$DBU' SET STATE='TRANSPORT-OFF';
exit
EOF
      else
        echo "[WARN] $SID: db_unique_name okunamadı; DGMGRL atlandı."
      fi
    else
      # STANDBY destinasyonu VARSA DEFER et, yoksa skip
      STBY_CNT=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL' | awk 'NF{print;exit}'
set head off feed off pages 0 verify off echo off
select count(*) from v$archive_dest where target='STANDBY';
exit
SQL
); STBY_CNT="$(echo "$STBY_CNT" | tr -d '\r' | awk '{$1=$1}1')"
      if [[ "$STBY_CNT" -gt 0 ]]; then
        echo "[INFO] $SID: Broker yok/kapalı → STANDBY dest DEFER ediliyor."
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL'
whenever sqlerror exit 1
DECLARE
  CURSOR c IS
    SELECT dest_id
    FROM   v$archive_dest
    WHERE  target='STANDBY' AND status IN ('VALID','DEFERRED');
BEGIN
  FOR r IN c LOOP
    EXECUTE IMMEDIATE
      'ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_'||r.dest_id||'=DEFER SCOPE=BOTH';
  END LOOP;
END;
/
exit
SQL
      else
        echo "[INFO] $SID: Hiç STANDBY destinasyonu yok → DEFER adımı atlandı (standalone)."
      fi
    fi

  elif [[ "$ROLE" == *"STANDBY"* ]]; then
    if [[ "${BKR^^}" == "TRUE" && -x "$ORACLE_HOME/bin/dgmgrl" ]]; then
      DBU=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL' | awk 'NF{print;exit}'
set head off feed off pages 0 verify off echo off
select value from v$parameter where name='db_unique_name';
exit
SQL
); DBU="$(echo "$DBU" | awk '{$1=$1}1')"
      if [[ -n "$DBU" ]]; then
        echo "[INFO] $SID ($DBU): DGMGRL APPLY-OFF"
        "$ORACLE_HOME/bin/dgmgrl" -silent <<EOF >/dev/null
connect /
EDIT DATABASE '$DBU' SET STATE='APPLY-OFF';
exit
EOF
      else
        echo "[WARN] $SID: db_unique_name okunamadı; DGMGRL atlandı."
      fi
    else
      echo "[INFO] $SID: Broker yok/kapalı → MRP CANCEL ediliyor."
      "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL'
whenever sqlerror exit 1
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
exit
SQL
    fi
  else
    echo "[INFO] $SID: ROLE=$ROLE — ek DG adımı yok."
  fi

  echo "[INFO] $SID kapatılıyor (shutdown immediate)"
  "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL'
whenever sqlerror exit 1
shutdown immediate
exit
SQL
  echo "[OK] $SID kapatıldı."
done

# === SONDA: Listener'ları durdur (her ORACLE_HOME için bir kez) ===
for HOME in "${!HOMES_SEEN[@]}"; do
  if [[ -x "$HOME/bin/lsnrctl" ]]; then
    if [[ -n "${LISTENERS:-}" ]]; then
      read -r -a NAMES <<<"$LISTENERS"
    elif [[ -r "$HOME/network/admin/listener.ora" ]]; then
      mapfile -t NAMES < <(awk 'BEGIN{IGNORECASE=1}
        /^[ \t]*LISTENER[0-9A-Z_]*[ \t]*=/ { gsub(/[ \t]*=.*/,"",$1); print $1 }' \
        "$HOME/network/admin/listener.ora" | sort -u)
      [[ ${#NAMES[@]} -eq 0 ]] && NAMES=(LISTENER)
    else
      NAMES=(LISTENER)
    fi
    for L in "${NAMES[@]}"; do
      echo "[INFO] $HOME: lsnrctl stop $L"
      "$HOME/bin/lsnrctl" stop "$L" >/dev/null 2>&1 || true
    done
  fi
done

echo "[DONE] Tüm uygun veritabanları kapatıldı; listener(lar) durduruldu."
