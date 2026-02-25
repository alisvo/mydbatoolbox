#!/usr/bin/env bash
# db_start.sh — /etc/oratab'dan okuyarak Oracle DB başlat (DG varsa otomatik)
# - Listener START EN BAŞTA (her ORACLE_HOME için bir kez)
# - Standalone: sadece startup
# - DG + Broker: PRIMARY→TRANSPORT-ON, STANDBY→APPLY-ON (DGMGRL)
# - DG (No Broker): PRIMARY→ENABLE (yalnız STANDBY dest varsa), STANDBY→MRP start

set -euo pipefail
ORATAB_FILE=${ORATAB_FILE:-/etc/oratab}

[[ -r "$ORATAB_FILE" ]] || { echo "[ERROR] $ORATAB_FILE okunamıyor." >&2; exit 1; }

mapfile -t ENTRIES < <(grep -E '^[[:space:]]*[^#][^:]*:[^:]+:[Yy][[:space:]]*$' "$ORATAB_FILE" | sort -u)
((${#ENTRIES[@]})) || { echo "[INFO] Oratab'da :Y kayıt yok."; exit 0; }

# Listener isimlerini bulma
detect_listeners_for_home() {
  local HOME="$1" LFILE="$HOME/network/admin/listener.ora"
  if [[ -n "${LISTENERS:-}" ]]; then
    # Kullanıcı override
    read -r -a NAMES <<<"$LISTENERS"; printf "%s\n" "${NAMES[@]}"
  elif [[ -r "$LFILE" ]]; then
    awk 'BEGIN{IGNORECASE=1}
         /^[ \t]*LISTENER[0-9A-Z_]*[ \t]*=/ {gsub(/[ \t]*=.*/,"",$1); print $1}' \
      "$LFILE" | sort -u
  else
    echo "LISTENER"
  fi
}

# ORACLE_HOME kümeyi çıkar
declare -A HOMES_SEEN=()
for line in "${ENTRIES[@]}"; do
  IFS=: read -r _ HOME _ <<<"$line"
  HOMES_SEEN["$HOME"]=1
done

# === 0) EN BAŞTA: Listener'ları başlat ===
for HOME in "${!HOMES_SEEN[@]}"; do
  if [[ -x "$HOME/bin/lsnrctl" ]]; then
    mapfile -t LSTS < <(detect_listeners_for_home "$HOME")
    ((${#LSTS[@]})) || LSTS=(LISTENER)
    for L in "${LSTS[@]}"; do
      echo "[INFO] $HOME: lsnrctl start $L"
      "$HOME/bin/lsnrctl" start "$L" >/dev/null 2>&1 || true
    done
  else
    echo "[WARN] $HOME: lsnrctl yok ($HOME/bin/lsnrctl). Listener start atlandı."
  fi
done

# === 1) DB'leri başlat + DG adımları ===
for line in "${ENTRIES[@]}"; do
  IFS=: read -r SID HOME _ <<<"$line"
  export ORACLE_SID="$SID" ORACLE_HOME="$HOME" PATH="$ORACLE_HOME/bin:$PATH"

  if [[ ! -x "$ORACLE_HOME/bin/sqlplus" ]]; then
    echo "[WARN] $SID: sqlplus bulunamadı ($ORACLE_HOME/bin/sqlplus). Atlanıyor."
    continue
  fi

  echo "[INFO] $SID başlatılıyor (startup)"
  "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL'
whenever sqlerror exit 1
startup
exit
SQL
  echo "[OK] $SID başlatıldı."

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
        echo "[INFO] $SID ($DBU): DGMGRL TRANSPORT-ON"
        "$ORACLE_HOME/bin/dgmgrl" -silent <<EOF >/dev/null
connect /
EDIT DATABASE '$DBU' SET STATE='TRANSPORT-ON';
exit
EOF
      else
        echo "[WARN] $SID: db_unique_name okunamadı; DGMGRL atlandı."
      fi
    else
      # STANDBY destinasyonu VARSA ENABLE et
      STBY_CNT=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL' | awk 'NF{print;exit}'
set head off feed off pages 0 verify off echo off
select count(*) from v$archive_dest where target='STANDBY';
exit
SQL
); STBY_CNT="$(echo "$STBY_CNT" | tr -d '\r' | awk '{$1=$1}1')"
      if [[ "$STBY_CNT" -gt 0 ]]; then
        echo "[INFO] $SID: Broker yok/kapalı → STANDBY dest ENABLE ediliyor."
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
      'ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_'||r.dest_id||'=ENABLE SCOPE=BOTH';
  END LOOP;
END;
/
exit
SQL
      else
        echo "[INFO] $SID: STANDBY destinasyonu yok → ENABLE adımı atlandı (standalone)."
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
        echo "[INFO] $SID ($DBU): DGMGRL APPLY-ON"
        "$ORACLE_HOME/bin/dgmgrl" -silent <<EOF >/dev/null
connect /
EDIT DATABASE '$DBU' SET STATE='APPLY-ON';
exit
EOF
      else
        echo "[WARN] $SID: db_unique_name okunamadı; DGMGRL atlandı."
      fi
    else
      echo "[INFO] $SID: Broker yok/kapalı → MRP başlatılıyor (real-time apply)."
      "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'SQL'
whenever sqlerror exit 1
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT;
exit
SQL
    fi
  else
    echo "[INFO] $SID: ROLE=$ROLE — ek DG adımı yok."
  fi
done

echo "[DONE] Tüm uygun veritabanları açıldı; listener(lar) önceden başlatıldı."
