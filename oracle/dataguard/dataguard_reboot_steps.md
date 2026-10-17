# Oracle 19c Data Guard Ortamı Reboot Adımları (Broker Yok)

Primary + Physical Standby ortamının OS bakımı/patch için kontrollü kapatılıp açılması.

**Varsayımlar:** Single instance (non-RAC), physical standby, log shipping `log_archive_dest_2` üzerinden.
`[ADG]` ile işaretli adımlar Active Data Guard lisansı gerektirir.

---

## 1. Kapatma Öncesi (Primary)

Son redo'yu gönder ve standby'ın senkron olduğunu doğrula:

```sql
-- Primary
ALTER SYSTEM ARCHIVE LOG CURRENT;

SELECT THREAD#, MAX(SEQUENCE#) FROM V$ARCHIVED_LOG GROUP BY THREAD#;
```

```sql
-- Standby: primary'deki değer ile aynı olmalı
SELECT THREAD#, MAX(SEQUENCE#) FROM V$ARCHIVED_LOG WHERE APPLIED = 'YES' GROUP BY THREAD#;
```

## 2. Primary'yi Kapat

```sql
ALTER SYSTEM SET log_archive_dest_state_2 = 'DEFER' SCOPE=BOTH;
SHUTDOWN IMMEDIATE;
EXIT;
```

```bash
lsnrctl stop
```

## 3. Standby'ı Kapat

```sql
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
SHUTDOWN IMMEDIATE;
EXIT;
```

```bash
lsnrctl stop
```

---

## 4. OS Bakımı

- OS patch / update uygulanır, her iki node reboot edilir.
- Devam etmeden önce iki node'un da tamamen ayağa kalktığından emin olun.

> Oracle Restart / systemd ile otomatik başlatma varsa, DB ve listener boot sırasında açılmış olabilir. Önce durumu kontrol edin (`ps -ef | grep pmon`, `lsnrctl status`).

---

## 5. Standby'ı Aç

```bash
lsnrctl start
```

```sql
STARTUP MOUNT;

-- [ADG] Opsiyonel: read-only aç (MRP başlatılmadan önce)
ALTER DATABASE OPEN READ ONLY;

-- MRP başlat (19c'de real-time apply varsayılandır)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
EXIT;
```

## 6. Primary'yi Aç ve Log Shipping'i Etkinleştir

```bash
lsnrctl start
```

```sql
STARTUP;
ALTER SYSTEM REGISTER;
ALTER SYSTEM SET log_archive_dest_state_2 = 'ENABLE' SCOPE=BOTH;
ALTER SYSTEM ARCHIVE LOG CURRENT;
EXIT;
```

---

## 7. Doğrulama

**Primary:**

```sql
SELECT DEST_ID, STATUS, ERROR FROM V$ARCHIVE_DEST_STATUS WHERE DEST_ID = 2;   -- STATUS = VALID, ERROR boş

SELECT THREAD#, MAX(SEQUENCE#) FROM V$ARCHIVED_LOG GROUP BY THREAD#;
```

**Standby:**

```sql
SELECT NAME, DB_UNIQUE_NAME, DATABASE_ROLE, OPEN_MODE FROM V$DATABASE;

SELECT NAME, ROLE, ACTION, THREAD#, SEQUENCE#
  FROM V$DATAGUARD_PROCESS
 WHERE NAME LIKE 'MRP%';

SELECT THREAD#, MAX(SEQUENCE#) FROM V$ARCHIVED_LOG WHERE APPLIED = 'YES' GROUP BY THREAD#;

SELECT NAME, VALUE, TIME_COMPUTED FROM V$DATAGUARD_STATS
 WHERE NAME IN ('transport lag', 'apply lag');

SELECT TIMESTAMP, SEVERITY, MESSAGE FROM V$DATAGUARD_STATUS
 ORDER BY TIMESTAMP DESC FETCH FIRST 20 ROWS ONLY;
```

Beklenen:

| Kontrol | Değer |
|---|---|
| `DATABASE_ROLE` | `PHYSICAL STANDBY` |
| `OPEN_MODE` | `MOUNTED` (ADG ile `READ ONLY WITH APPLY`) |
| MRP0 `ACTION` | `APPLYING_LOG` veya `IDLE` (yeni redo bekliyor) |
| Applied sequence | Primary ile aynı (veya 1 geride) |
| transport / apply lag | `+00 00:00:00` civarı |

---

## Özet

| Adım | Primary | Standby |
|---|---|---|
| Kapatma öncesi | `ARCHIVE LOG CURRENT` + senkron kontrolü | – |
| Kapatma (sıra) | 1. `dest_state_2=DEFER`, `SHUTDOWN IMMEDIATE`, `lsnrctl stop` | 2. MRP `CANCEL`, `SHUTDOWN IMMEDIATE`, `lsnrctl stop` |
| OS reboot | ✓ | ✓ |
| Açılış (sıra) | 2. `lsnrctl start`, `STARTUP`, `dest_state_2=ENABLE` | 1. `lsnrctl start`, `STARTUP MOUNT`, [ADG] `OPEN READ ONLY`, MRP `DISCONNECT` |

## Notlar

- **Kapatma sırası:** Primary önce kapatılır; standby kapanmadan önce primary'nin son redo'sunu almış olur.
- **Açılış sırası:** Standby önce açılır; primary'de shipping `ENABLE` edildiğinde redo alıp uygulamaya hazır olur. (Shipping `DEFER` ile kapatıldığı için primary önce açılsa da sorun olmaz, `ENABLE` standby hazır olduktan sonra yapılmalıdır.)
- `SHUTDOWN ABORT` sadece son çare; bir sonraki açılışta instance recovery gerektirir.
- `USING CURRENT LOGFILE` 12.1'den itibaren deprecated; real-time apply standby redo log (SRL) varsa varsayılan olarak çalışır.
- `V$MANAGED_STANDBY` 12.2'den itibaren deprecated; yerine `V$DATAGUARD_PROCESS` kullanılır.
- **Oracle Restart (srvctl) kullanılıyorsa** `sqlplus` / `lsnrctl` yerine:

  ```bash
  # Kapatma
  srvctl stop database -db <db_unique_name> -stopoption immediate
  srvctl stop listener

  # Açılış
  srvctl start listener
  srvctl start database -db <db_unique_name> -startoption mount   # standby
  srvctl start database -db <db_unique_name>                      # primary
  ```

  Standby'ın Oracle Restart kaydında role `PHYSICAL_STANDBY`, start option `MOUNT` (ADG ile `"READ ONLY"`) olmalıdır: `srvctl config database -db <db_unique_name>`.
