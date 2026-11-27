# Oracle RMAN Backup

Tek script ([rman_backup.sh](rman_backup.sh)) ve veritabanı başına bir config dosyası ([mydb.cfg](mydb.cfg)).

## Strateji

| Katman | Nasıl | Saklama |
|---|---|---|
| PITR | Haftalık L0 + günlük L1 cumulative + saatlik archivelog | `PITR_RET` (14 gün) içinde herhangi bir an |
| Haftalık | Haftada bir `KEEP UNTIL` full backup (self-contained) | `WEEKLY_RET` (91 gün) |

- PITR zinciri normal backup'lardan oluşur; `RECOVERY WINDOW OF n DAYS` ve `DELETE OBSOLETE` ile yönetilir.
- Haftalık backup'lar `KEEP` olduğu için retention policy'ye girmez ve zinciri etkilemez. Gereken archivelog,
  controlfile ve spfile backup'larını kendileri içerir. Süreleri dolunca obsolete olur, `daily` çalışmasındaki
  `DELETE OBSOLETE` ile silinir.
- `KEEP` ile incremental birlikte kullanılmaz: Oracle, KEEP'li bir L1 için parent'ın da aynı TAG'e sahip
  KEEP backup olmasını şart koşar.

### Modlar

```
rman_backup.sh <config> daily    # L0_DAY günü L0, diğer günler L1 + archivelog + temizlik
rman_backup.sh <config> l0       # Zorla L0 (ilk kurulum veya zinciri yenileme)
rman_backup.sh <config> weekly   # KEEP UNTIL full backup + restore point
rman_backup.sh <config> arch     # Archivelog backup + lokal archivelog temizliği
```

Aynı veritabanı için iki iş aynı anda çalışmaz (`flock`). `arch` başka bir iş çalışıyorsa o saati atlar;
`daily`/`weekly` en fazla `LOCK_WAIT_MIN` dakika bekler.

---

## Ön koşullar

- Veritabanı ARCHIVELOG modunda olmalı.
- Backup kayıtları controlfile'da tutulduğu için `control_file_record_keep_time`, `WEEKLY_RET`'ten büyük olmalı:

```sql
ALTER SYSTEM SET control_file_record_keep_time=100 SCOPE=BOTH;
```

> ⚠️ Çok daha uzun saklama gerekiyorsa **Recovery Catalog** kullanın.

- `BACKUP_LOC` FRA içinde olmamalı (Oracle, FRA'da `KEEP` backup'a izin vermez).

---

## Kurulum

```bash
sudo su - oracle
mkdir -p /home/oracle/scripts/config
vi /home/oracle/scripts/rman_backup.sh
vi /home/oracle/scripts/config/mydb.cfg
chmod +x /home/oracle/scripts/rman_backup.sh
```

Data Guard primary'de config'teki `ARCH_DELETION_POLICY` değerini
`"APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DEVICE TYPE DISK"` yapın.

İlk çalıştırmada zinciri başlatmak için bir L0 alın:

```bash
nohup /home/oracle/scripts/rman_backup.sh /home/oracle/scripts/config/mydb.cfg l0 > /tmp/rman_l0.out 2>&1 &
```

---

## Crontab

```
# Günlük (Pazar L0, diğer günler L1)
30 19 * * *  /home/oracle/scripts/rman_backup.sh /home/oracle/scripts/config/mydb.cfg daily
# Haftalık KEEP full - Pazar L0 ile aynı geceye denk gelmesin diye Çarşamba
00 23 * * 3  /home/oracle/scripts/rman_backup.sh /home/oracle/scripts/config/mydb.cfg weekly
# Saatlik archivelog
20 * * * *   /home/oracle/scripts/rman_backup.sh /home/oracle/scripts/config/mydb.cfg arch
```

Script hata durumunda stderr'e yazar ve sıfırdan farklı kodla çıkar; crontab'da `MAILTO` tanımlıysa e-posta gelir.
Loglar: `LOG_DIR/<SID>_<mod>_<tarih>.log`, `LOG_RET` günden eskiler otomatik silinir.

---

## Kontrol

```sql
-- Son 14 günün backup'ları: L1 günlerinde boyut L0'a yakınsa zincir sorunlu demektir
SELECT TRUNC(s.completion_time) day, s.backup_type, s.incremental_level lvl, s.keep, s.keep_until,
       ROUND(SUM(p.bytes)/1024/1024/1024,1) gb
FROM   v$backup_set s
JOIN   v$backup_piece p ON p.set_stamp = s.set_stamp AND p.set_count = s.set_count
WHERE  s.completion_time > SYSDATE-14 AND s.backup_type IN ('D','I')
GROUP  BY TRUNC(s.completion_time), s.backup_type, s.incremental_level, s.keep, s.keep_until
ORDER  BY 1;
```

```
RMAN> LIST BACKUP SUMMARY;
RMAN> LIST RESTORE POINT ALL;
RMAN> REPORT OBSOLETE;
```

---

## Restore örnekleri

PITR (son `PITR_RET` gün içinde bir an):

```
RMAN> STARTUP MOUNT;
RMAN> RUN {
        SET UNTIL TIME "TO_DATE('2026-11-20 14:30:00','YYYY-MM-DD HH24:MI:SS')";
        RESTORE DATABASE;
        RECOVER DATABASE;
      }
RMAN> ALTER DATABASE OPEN RESETLOGS;
```

Haftalık backup'a dönüş (restore point adı `LIST RESTORE POINT ALL` ile bulunur):

```
RMAN> STARTUP MOUNT;
RMAN> RUN {
        SET UNTIL RESTORE POINT WEEKLY_20261118_2300;
        RESTORE DATABASE;
        RECOVER DATABASE;
      }
RMAN> ALTER DATABASE OPEN RESETLOGS;
```

---

## Eski script'lerden geçiş

Eski `rman_backup_hybrid.sh`, L0 ve L1'leri `KEEP UNTIL` ile alıyordu. Bu backup'lar KEEP süreleri
dolunca obsolete olur ve `DELETE OBSOLETE` ile kendiliğinden silinir; elle bir şey yapmak gerekmez.
Yeni düzene geçerken crontab'daki eski iki satırı kaldırın ve ilk iş olarak `l0` çalıştırın.
