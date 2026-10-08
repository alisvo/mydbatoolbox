# Oracle DB otomatik start/stop servisi (systemd)

`/home/oracle/scripts` altındaki scriptler, sunucu açılırken `/etc/oratab`'da `:Y` olan Oracle instance'larını başlatır, kapanırken de temiz şekilde kapatır. Bu iş için tek bir systemd servisi (`oracle-db.service`) kullanılır.

- **Kapsam:** 19c ve üstü, single instance, non-ASM / non-Grid / non-RAC, Data Guard physical standby olabilir veya olmayabilir.
- **Doğrulandığı ortam:** Oracle 19c physical standby (broker'sız, ADG), Azure üzerinde Linux VM.

---

## 1. Dosyalar

| Dosya | Görevi |
|---|---|
| `/home/oracle/scripts/db_start.sh` | Listener'ları ve DB'leri açar, Data Guard apply/transport'u kontrol eder |
| `/home/oracle/scripts/db_stop.sh` | DB'leri `shutdown immediate` ile kapatır, sonra listener'ları durdurur |
| `/home/oracle/scripts/oracle-db.service` | systemd unit'inin kaynak kopyası. Kurulumda `/etc/systemd/system/` altına kopyalanır |
| `/home/oracle/scripts/README.md` | Bu doküman |

## 2. Ne yapar?

### Açılışta (`db_start.sh`)

1. Her ORACLE_HOME için `listener.ora`'da tanımlı listener'lar çalışmıyorsa başlatılır.
2. Her `:Y` instance için `startup` yapılır:
   - **PRIMARY** → READ WRITE açılır.
   - **PHYSICAL STANDBY** → READ ONLY (ADG) açılır. `MOUNT_SIDS` listesindeki instance'lar MOUNT'ta kalır.
3. Data Guard:
   - **Broker varsa:** intended state `TRANSPORT-ON` (primary) veya `APPLY-ON` (standby) değilse düzeltilir.
   - **Broker yoksa:** primary'de DEFERRED/ERROR durumundaki standby destinasyonları ENABLE edilir; standby'da MRP çalışmıyorsa başlatılır.

### Kapanışta (`db_stop.sh`)

1. Broker'sız standby'da MRP varsa önce `CANCEL` edilir.
2. `shutdown immediate` gönderilir. `SHUTDOWN_TIMEOUT` (varsayılan 600 sn) içinde bitmezse `shutdown abort` yapılır. Abort durumunda bir sonraki açılışta crash recovery olur; commit edilmiş veri kaybolmaz.
3. En sonda listener'lar durdurulur.

### İki scriptin ortak özellikleri

- **Data Guard durumu değiştirilmez.** `TRANSPORT-OFF`, `APPLY-OFF` veya `DEFER` yapılmaz. DB açıldığında transport ve apply kendiliğinden devam eder, aradaki redo boşluğu (gap) otomatik kapanır.
- **Tekrar çalıştırmak güvenlidir.** Zaten açık olanı açmaya, kapalı olanı kapatmaya çalışmaz.
- **Hatalar izoledir.** Bir DB'nin hatası diğerlerini durdurmaz. Hata varsa exit 1 döner ve log'a `HATA` satırı yazılır.
- **Uygulama servislerini yönetmez.** Rol bazlı servisler (ör. `<DB>_RW`, `<DB>_RO`) DB tarafındaki mekanizmayla, role göre açılır.

## 3. Ön koşullar

- [ ] Tüm ORACLE_HOME'lar `oracle` kullanıcısına ait. Scriptler root ile çalıştırılırsa reddeder.
- [ ] Açılacak instance'lar `/etc/oratab`'da `SID:ORACLE_HOME:Y` olarak tanımlı.
- [ ] DB'ler spfile kullanıyor (`scope=both` için gerekli).
- [ ] Physical standby'lar READ ONLY açılacaksa Active Data Guard lisansı var. MOUNT'ta kalması gerekenler `MOUNT_SIDS`'e yazılır.
- [ ] Sunucuda persistent journal açık. Değilse: `mkdir -p /var/log/journal && systemctl restart systemd-journald`
- [ ] Eski başlatma/kapatma mekanizmaları (eski `db_start.sh`/`db_stop.sh`, `dbora`, cron `@reboot`) kaldırılmış. İki mekanizma aynı anda çalışmamalı.

## 4. Ayarlar

Ayarlar unit dosyasında `Environment=` satırlarıyla yapılır.

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `ORATAB` | `/etc/oratab` | oratab dosyasının yolu |
| `MOUNT_SIDS` | (boş) | Boşlukla ayrılmış SID listesi. Bu instance'lar standby ise MOUNT'ta kalır |
| `BROKER_WAIT` | `120` | Broker'ın hazır olmasını bekleme süresi (sn) |
| `SHUTDOWN_TIMEOUT` | `600` | DB başına `shutdown immediate` süresi (sn). Süre dolarsa `abort` yapılır |

`TimeoutStopSec` değeri, kabaca **DB sayısı × (SHUTDOWN_TIMEOUT + 60)** değerinden büyük olmalı; varsayılan 3600. Daha kısa olursa systemd, kapanış bitmeden süreçleri öldürür.

## 5. Kurulum

### Hangi adım hangi kullanıcıyla?

`/etc/systemd/system/` altına yazmak ve `systemctl enable/start/stop` çalıştırmak **root** yetkisi ister; `oracle` kullanıcısı bunları yapamaz. Scriptlerin kendisi ise her zaman **oracle** kullanıcısıyla çalışır. Servis üzerinden çalıştırıldığında bunu systemd, unit dosyasındaki `User=oracle` satırıyla kendisi sağlar.

| İşlem | Kullanıcı |
|---|---|
| Scriptleri `/home/oracle/scripts` altına kopyalama, `chown`/`chmod`, SELinux etiketi | root |
| Unit dosyasını `/etc/systemd/system/` altına kopyalama, `daemon-reload` | root |
| `systemctl enable / start / stop / restart oracle-db` | root (veya sudo yetkisi olan kullanıcı) |
| `systemctl status oracle-db`, `systemctl is-active oracle-db` | herhangi bir kullanıcı |
| `journalctl -u oracle-db` | root ya da `systemd-journal` grubundaki kullanıcı |
| `db_start.sh` / `db_stop.sh`'ı elle çalıştırma | oracle (root ile çalıştırılırsa script reddeder) |
| sqlplus ile kontroller (`v$dataguard_stats` vb.) | oracle |

Bu bölümdeki komut blokları **root** ile çalıştırılır. Oracle kullanıcısıyla yapılması gereken adımlar, root oturumundan `su - oracle -c "<komut>"` şeklinde verilmiştir.

> `oracle` kullanıcısına servisi yönetme yetkisi vermek isterseniz sudoers'a örneğin şu satır eklenebilir (`visudo -f /etc/sudoers.d/oracle-db`):
> `oracle ALL=(root) NOPASSWD: /usr/bin/systemctl start oracle-db, /usr/bin/systemctl stop oracle-db, /usr/bin/systemctl restart oracle-db, /usr/bin/systemctl status oracle-db`

### 5.1 Dosyaları yerleştirin

```bash
mkdir -p /home/oracle/scripts
# db_start.sh, db_stop.sh, oracle-db.service, README.md bu dizine kopyalanır
chown oracle:oinstall /home/oracle/scripts/*
chmod 755 /home/oracle/scripts/db_start.sh /home/oracle/scripts/db_stop.sh
chmod 644 /home/oracle/scripts/oracle-db.service /home/oracle/scripts/README.md
```

**SELinux kontrolü:** `getenforce` komutu `Enforcing` dönerse, systemd `/home` altındaki scriptleri çalıştıramayabilir ve "Permission denied" hatası alırsınız. Bu durumda dizini etiketleyin:

```bash
semanage fcontext -a -t bin_t '/home/oracle/scripts(/.*)?'
restorecon -Rv /home/oracle/scripts
```

### 5.2 Gerekirse unit'i düzenleyin

Sunucuya özel ayarları `/home/oracle/scripts/oracle-db.service` içinde yapın. Örneğin MOUNT'ta kalması gereken bir standby varsa:

```ini
Environment="MOUNT_SIDS=STBY2"
```

### 5.3 Unit'i kurun

```bash
cp /home/oracle/scripts/oracle-db.service /etc/systemd/system/oracle-db.service
chmod 644 /etc/systemd/system/oracle-db.service
systemctl daemon-reload
```

### 5.4 DB'leri servisin altına alın

Elle (SSH oturumundan) başlatılmış DB'lerin süreçleri o oturuma aittir. Kapanışta systemd bu süreçleri `db_stop.sh`'tan önce öldürebilir. Bu yüzden DB'ler bir kez kapatılıp servis üzerinden açılmalıdır.

```bash
su - oracle -c /home/oracle/scripts/db_stop.sh     # mevcut DB'leri temiz kapat
systemctl enable --now oracle-db                   # açılışta aktif et + şimdi başlat
```

> Primary'de bu adım kesinti demektir; bakım penceresinde yapın. Standby'da kısa bir apply kesintisi olur, sonrasında aradaki redo kendiliğinden gelir.

## 6. Test

### 6.1 Servis üzerinden açılış

```bash
systemctl status oracle-db --no-pager                 # "active (exited)"
journalctl -u oracle-db -b 0 --no-pager | tail -10    # "BİTTİ — tüm instance'lar ve listener'lar ayakta"
grep -E '^0::|name=systemd' /proc/$(pgrep -f '^ora_pmon_<SID>$')/cgroup   # .../oracle-db.service görünmeli
su - oracle -c "lsnrctl status"
```

Standby'da apply'ı kontrol edin:

```sql
select name, value from v$dataguard_stats where name in ('transport lag','apply lag');
select process, status, sequence# from v$managed_standby where process like 'MRP%';
```

Beklenen: lag değerleri `+00 00:00:00` veya birkaç saniye, MRP0 durumu `APPLYING_LOG`.

### 6.2 Reboot testi (asıl test)

DB'lere dokunmadan **OS içinden** reboot gönderin:

```bash
reboot
```

Sunucu açıldıktan sonra:

```bash
# Kapanış (önceki boot)
journalctl -u oracle-db -b -1 --no-pager | tail -15
#   Stopping Oracle Database instances ...
#   <SID>: shutdown immediate ... <SID>: kapandı
#   BİTTİ — tüm instance'lar ve listener'lar kapalı
#   oracle-db.service: Succeeded.

# Açılış (bu boot)
journalctl -u oracle-db -b 0 --no-pager | tail -8
#   BİTTİ — tüm instance'lar ve listener'lar ayakta

# Alert.log
grep -nE 'Shutting down ORACLE instance|Instance shutdown complete|Crash Recovery|Starting ORACLE instance' \
  /u01/app/oracle/diag/rdbms/<db_unique_name>/<SID>/trace/alert_<SID>.log | tail -5
```

Temiz kapanışta son satırların sırası şöyledir:

```
Shutting down ORACLE instance (immediate)
Instance shutdown complete
Starting ORACLE instance (normal)
```

Açılışta `Beginning crash recovery` (primary) ya da `Beginning Standby Crash Recovery` (standby) satırı görünüyorsa kapanış temiz olmamıştır. Bu durumda 8. bölüme bakın.

> Sunucu saati UTC ise journal ve alert.log da UTC yazar; saatleri yorumlarken yerel saat farkını hesaba katın.

## 7. Operasyon kuralları

| Durum | Yapılacak |
|---|---|
| Planlı reboot / kapatma | OS içinden `reboot` veya `shutdown -h now`. Servis DB'leri kendisi kapatır. |
| **Azure portalından Stop** | **Önce** OS içinden `shutdown -h now` (veya `systemctl stop oracle-db`), **sonra** portaldan Stop/Deallocate. Testte portal Stop'u OS'e kapanma sinyali göndermedi ve DB öldürüldü. |
| DB'yi elle `startup` ile açtıysanız (patch vb.) | Bir sonraki reboot'tan önce `systemctl restart oracle-db` ya da reboot'tan hemen önce `systemctl stop oracle-db` çalıştırın. |
| Tüm DB'leri elle kapatıp açmak | `systemctl stop oracle-db` / `systemctl start oracle-db` |
| Tek bir DB'yi bakım için kapalı tutmak | oratab'da `:N` yapın. Servis o DB'ye dokunmaz. |
| Log'lara bakmak | `journalctl -u oracle-db` (son boot için `-b 0`, önceki boot için `-b -1`) |

`oracle` kullanıcısının journal'ı okuyabilmesi için: `usermod -aG systemd-journal oracle` (yeniden login sonrası geçerli olur).

## 8. Sorun giderme

| Belirti | Olası sebep / çözüm |
|---|---|
| Reboot sonrası `journalctl -u oracle-db -b -1` çıktısında `Stopping ...` satırı yok | OS düzgün kapanmadı (Azure Stop, hard reset, `reboot -f`). `last -x \| head` çıktısında `crash` görünür. 7. bölümdeki Azure kuralını uygulayın. |
| Unit `failed` durumda | `ExecStart`/`ExecStop` satırlarının başındaki `-` silinmiş olabilir. `systemctl cat oracle-db \| grep Exec` ile kontrol edin. `failed` durumdaki bir unit için kapanışta ExecStop çalışmaz. |
| `Permission denied` / `203/EXEC` | Script çalıştırılabilir değil (`chmod 755`) ya da SELinux engelliyor (bkz. 5.1). |
| `Configuration file ... is marked world-inaccessible` | `chmod 644 /etc/systemd/system/oracle-db.service` |
| `HATA: <SID> açılamadı` | Hemen üstündeki ORA- satırına ve alert.log'a bakın. Diğer DB'ler yine de açılmış olur. |
| `UYARI: <SID> 600 sn içinde kapanmadı -> shutdown abort` | Uzun transaction veya asılı oturum. Abort güvenlidir; açılışta crash recovery yapılır. Sık oluyorsa `SHUTDOWN_TIMEOUT` artırılabilir. |
| `-bash: TMOUT: readonly variable` | `su - oracle` sırasında çıkan, profil kaynaklı zararsız bir uyarı. Servisi etkilemez. |
| `systemd-cgls -u` hata veriyor | Eski systemd sürümü bu parametreyi desteklemez. Yerine `/proc/<pid>/cgroup` veya `systemctl status oracle-db` kullanın. |

## 9. Geri alma

```bash
systemctl disable --now oracle-db      # DİKKAT: --now DB'leri kapatır
rm /etc/systemd/system/oracle-db.service
systemctl daemon-reload
```

DB'leri şimdi kapatmadan otomatik başlatmayı iptal etmek için `systemctl disable oracle-db` (`--now` olmadan) yeterlidir. Servis bu boot'ta hâlâ aktif olduğu için bir sonraki kapanışta `db_stop.sh` son bir kez çalışır; sonraki açılışlarda servis hiç devreye girmez.

## 10. Örnek test kaydı — physical standby, broker yok

| Adım | Test | Sonuç |
|---|---|---|
| 1 | `db_stop.sh` elle çalıştırıldı | MRP cancel, `shutdown immediate` ~50 sn, listener durdu ✔ |
| 2 | `systemctl enable --now oracle-db` | Listener açıldı, DB READ ONLY açıldı, MRP başladı ✔ |
| 3 | Bulut portalından VM Stop / Start | ✘ OS'e kapanma sinyali gelmedi, DB öldürüldü (`Standby Crash Recovery`). Veri kaybı yok. → 7. bölümdeki Azure kuralı buradan çıktı |
| 4 | OS içinden `reboot` | Kapanış ~25 sn (`shutdown immediate` + listener stop), açılış otomatik, MRP çalışıyor ✔ |
