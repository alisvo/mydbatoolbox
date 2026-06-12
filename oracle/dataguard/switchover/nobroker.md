# Oracle 19c Database Switchover Adımları (Broker Yok)

Bu doküman, Oracle 19c mimarisinde Data Guard Broker kullanılmayan (Manual) ortamlarda switchover işlemlerini gerçekleştirmek için kullanılabilecek adım adım operasyon kılavuzudur.

---

## 1. İşlem Öncesi Adımlar (Pre-checks)

### 1.1. Ağ ve Bağlantı Kontrolleri
Her iki sunucudan da karşılıklı olarak TNS servisleri kontrol edilir.
```bash
tnsping <primary_tns_name>
tnsping <standby_tns_name>
```

### 1.2. Archive Log Durum Kontrolleri
Primary ve Standby sunucularında güncel archivelog durumları sorgulanır.

* **Primary Üzerinde:**
```sql
SELECT thread#, MAX(sequence#) "Last Primary Seq Generated"  
FROM gv$archived_log val, gv$database vdb
WHERE val.resetlogs_change# = vdb.resetlogs_change#
GROUP BY thread# ORDER BY 1;
```

* **Standby Üzerinde (Alınan Loglar):**
```sql
SELECT thread#, MAX(sequence#) "Last Standby Seq Received"  
FROM gv$archived_log val, gv$database vdb
WHERE val.resetlogs_change# = vdb.resetlogs_change#
GROUP BY thread# ORDER BY 1;
```

* **Standby Üzerinde (Uygulanan Loglar):**
```sql
SELECT thread#, MAX(sequence#) "Last Standby Seq Applied"
FROM gv$archived_log val, gv$database vdb
WHERE val.resetlogs_change# = vdb.resetlogs_change#
  AND val.applied IN ('YES','IN-MEMORY')
GROUP BY thread# ORDER BY 1;  
```

### 1.3. Initialization Parametrelerinin Kontrolü
Aşağıdaki parametrelerin doğruluğundan emin olunmalıdır:
* `log_archive_config`: Primary ve tüm standby bilgilerini içermeli.
* `fal_server`: Diğer sunucuların/hedeflerin TNS bilgilerini içermeli.
* `db_unique_name`: Veritabanı unique ismi.
* `log_archive_dest_n`: İlk destination yerel DB, diğerleri uzak hedef DB bilgileri olmalıdır.

```sql
SELECT name, value
FROM v$parameter
WHERE UPPER(name) IN (
    'DB_NAME', 'DB_UNIQUE_NAME', 'FAL_CLIENT', 'FAL_SERVER',
    'LOG_ARCHIVE_CONFIG', 'LOG_ARCHIVE_DEST_2', 'LOG_ARCHIVE_DEST_STATE_2',
    'LOG_ARCHIVE_DEST_3', 'LOG_ARCHIVE_DEST_STATE_3', 'LOG_ARCHIVE_DEST_4',
    'LOG_ARCHIVE_DEST_STATE_4', 'REMOTE_LOGIN_PASSWORDFILE',
    'LOG_ARCHIVE_MAX_PROCESSES', 'STANDBY_FILE_MANAGEMENT'
)
ORDER BY name;
```

### 1.4. Data Guard Çalışma Durumu
Logların yazılmasında veya uygulanmasında sorun varsa, Standby tarafında recovery süreci (MRP) restart edilir:
```sql
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT;
```

### 1.5. Datafile Durum Kontrolleri
Her iki tarafta da offline datafile olup olmadığı kontrol edilir. Varsa online duruma getirilir:
```sql
-- Offline datafile kontrolü
SELECT NAME FROM V$DATAFILE WHERE STATUS='OFFLINE';

-- Online duruma getirme komutu
ALTER DATABASE DATAFILE 'datafile-name' ONLINE;
```

### 1.6. Redo Log ve Standby Redo Log Kontrolleri
* **Primary Redo Log Kontrolü:** Statü `INACTIVE`, `ACTIVE` ya da `CURRENT` olmalıdır. Farklı bir durumda log dosyası silinip gerekirse yeniden oluşturulmalıdır.
```sql
SELECT a.thread#, a.group#, a.bytes, a.blocksize, b.type, a.status, b.member 
FROM v$log a, v$logfile b 
WHERE a.group# = b.group#;
```

* **Standby Redo Log Kontrolü:** Statü `UNASSIGNED` ya da `ACTIVE` olmalıdır. Farklı durumda silinip tekrar oluşturulması gerekir. Silme işlemi için önce MRP kapatılmalıdır.
```sql
SELECT s.thread#, s.group#, s.status, s.bytes, l.type, l.member 
FROM v$logfile l, v$standby_log s 
WHERE s.group# = l.group#;
```

> **Not:** MRP (Managed Recovery Process) kapatıp açmak için kullanılacak komutlar:
> ```sql
> ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
> ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT;
> ```

### 1.7. Block Corruption Kontrolü
Veritabanında herhangi bir blokta bozulma (corruption) olup olmadığı sorgulanır:
```sql
SELECT * FROM v$database_block_corruption;
```

### 1.8. GAP Kontrolü ve Çözümü
Primary veritabanı üzerinde GAP kontrolü gerçekleştirilir:
```sql
SELECT STATUS, GAP_STATUS FROM V$ARCHIVE_DEST_STATUS WHERE DEST_ID = 2;
SELECT STATUS, GAP_STATUS FROM V$ARCHIVE_DEST_STATUS WHERE DEST_ID = 3;
```
> **GAP Tespit Edilirse:** Standby tarafında MRP kapatılır ve gecikmesiz (`NODELAY`) olarak yeniden başlatılır:
> ```sql
> ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
> ALTER DATABASE RECOVER MANAGED STANDBY DATABASE NODELAY;
> ```

### 1.9. Guarantee Restore Point Oluşturulması
Olası bir aksilikte geri dönebilmek amacıyla Primary ve Standby üzerinde geri dönüş noktası oluşturulur. Öncesinde `FORCE LOGGING` kontrol edilir:
```sql
-- Force Logging Kontrolü (Açık değilse açılmalıdır)
SELECT force_logging FROM v$database;

-- Süreç izleme
SELECT PROCESS, STATUS, THREAD#, SEQUENCE#, BLOCK#, BLOCKS FROM V$MANAGED_STANDBY;

-- Restore Point Oluşturma
CREATE RESTORE POINT switchover_bkp GUARANTEE FLASHBACK DATABASE;

-- Kontrol Sorgusu
SELECT NAME, SCN, TIME, GUARANTEE_FLASHBACK_DATABASE FROM V$RESTORE_POINT;
```

### 1.10. Temp File Bilgilerinin Alınması
Primary taraftaki temp file'ların karşı tarafta da eksiksiz oluşturulabilmesi için mevcut yapı listelenir:
```sql
SELECT tf.name filename, bytes, ts.name tablespace 
FROM v$tempfile tf, v$tablespace ts 
WHERE tf.ts# = ts.ts#;
```

### 1.11. Switchover Statü Kontrolü
İşlemlere başlamadan hemen önce switchover durumunun uygunluğu doğrulanır. Çıktı **`TO STANDBY`** veya **`SESSIONS ACTIVE`** olmalıdır:
```sql
SELECT switchover_status FROM v$database;
```

---

## 2. Switchover Adımları

### Adım 1: Switchover Doğrulaması (Verify)
Primary DB üzerinde switchover süreci simüle edilir. Hata alınmazsa işlemlere geçilir:
```sql
ALTER DATABASE SWITCHOVER TO <standby_db_name> VERIFY;
```

### Adım 2: Switchover Tetikleme
Anahtarlama işlemi başlatılır:
```sql
ALTER DATABASE SWITCHOVER TO <standby_db_name>;
-- Örnek: ALTER DATABASE SWITCHOVER TO DRDB;
```

### Adım 3: Yeni Primary Veritabanının Açılması
İşlem tamamlandıktan sonra `sqlplus` oturumu kapatılıp tekrar açılır ve yeni Primary DB ayağa kaldırılır:
```sql
ALTER DATABASE OPEN;
```

### Adım 4: Eski Primary (Yeni Standby) Veritabanının Açılması
* **Senaryo A (Eğer Active Data Guard kullanılacaksa):** `sqlplus` kapatılıp açılır ve veritabanı `STARTUP` modunda açılır:
```sql
STARTUP;
```
* **Senaryo B (Eğer Active Data Guard DEĞİLSE):** Veritabanı sadece mount modda açılır:
```sql
STARTUP MOUNT;
```

### Adım 5: Standby Üzerinde Redo Apply (MRP) Başlatılması
Gelen redo logların işlenmesi için yeni standby üzerinde recovery süreci başlatılır:
```sql
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
```

---

## 3. Switchover Sonrası Kontroller (Post-checks)

### 3.1. Yeni Primary Üzerinde Log Kontrolleri
Yeni Primary üzerinde manuel bir archivelog tetiklenerek durum kontrol edilir:
```sql
ALTER SYSTEM ARCHIVE LOG CURRENT;

SELECT dest_id, error, status FROM v$archive_dest WHERE dest_id = 2; 
SELECT dest_id, error, status FROM v$archive_dest WHERE dest_id = 3; 

SELECT MAX(sequence#), thread# FROM v$log_history GROUP BY thread#;
```

### 3.2. Yeni Standby Üzerinde Kontroller
Logların Standby'a ulaşıp ulaşmadığı ve arka plan süreçleri doğrulanır:
```sql
SELECT MAX(sequence#), thread# FROM v$archived_log GROUP BY thread#;

SELECT name, role, instance, thread#, sequence#, action FROM gv$dataguard_process;
```

### 3.3. Veri Akış Testi (Opsiyonel)
Veri akışının sağlıklı çalıştığından emin olmak adına, Primary üzerinde geçici bir test tablosu oluşturulup içerisine kayıt girilebilir ve bu kaydın Standby tarafına yansıdığı gözlemlenebilir.
```
