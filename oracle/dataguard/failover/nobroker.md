# Oracle 19c Database Failover Adımları (Broker Yok / Manual)

Failover işlemi, Primary veritabanının kurtarılamadığı (Disaster) senaryolarda Standby veritabanının Production olarak (Primary rolünde) hizmete alınması için kullanılır.

---

## 1. (Mümkünse) Redo Logları Flush Etmek (Primary Üzerinde)
Eğer Primary sunucuya işletim sistemi seviyesinde erişilebiliyor ve veritabanı sadece sorun yaşıyor ama en azından `MOUNT` moda alınabiliyorsa, henüz Standby'a gönderilmemiş redo logların aktarılması sağlanır.

> **DİKKAT:** Primary sunucu tamamen kapandıysa, donanım arızası varsa veya sunucuya hiçbir şekilde **ulaşılamıyorsa**, bu adımı atlayıp vakit kaybetmeden doğrudan **Adım 2'ye (Standby)** geçin.

```sql
-- Eğer primary MOUNT modda açılabiliyorsa çalıştırılacak komutlar:
STARTUP MOUNT;
ALTER SYSTEM FLUSH REDO TO '<standby_db_name>';
```

---

## 2. Standby Üzerinde Recovery Sürecini Durdurma
Artık tüm işlemleri **Standby sunucusu** üzerinden yapacağız. Standby veritabanına bağlanılır ve logları apply eden MRP (Managed Recovery Process) iptal edilir.

```sql
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
```

---

## 3. Bekleyen Tüm Logların Uygulanması (FINISH)
Standby üzerinde hali hazırda bulunan tüm archivelog ve standby redo logların eksiksiz bir şekilde işlenmesini sağlamak için `FINISH` komutu çalıştırılır. Bu adım, "Graceful Failover" (veri kaybını sıfırlamak veya minimuma indirmek) için kritiktir.

```sql
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE FINISH;
```

> **Eğer bu komut HATA verirse (Örn: ORA-16089 / Eksik Log-GAP durumu):**
> Geri getirilemeyen veya Primary'de kalan loglar sebebiyle `FINISH` komutu hata dönüyorsa; ancak siz veritabanını **veri kaybını göze alarak** mecburen ayağa kaldırmak zorundaysanız bu adımı atlayıp doğrudan zorunlu aktivasyon (Adım 4) komutunu çalıştırabilirsiniz.

---

## 4. Standby Veritabanını Primary Olarak Aktive Etme
Standby veritabanını kalıcı olarak Primary rolüne geçiriyoruz. (Bu işlem "Resetlogs" operasyonu yapılmasını gerektiren bir yol ayrımıdır).

```sql
ALTER DATABASE ACTIVATE STANDBY DATABASE;
```

---

## 5. Yeni Primary Veritabanını Açma
Statü değiştikten sonra veritabanını erişime açıyoruz.

```sql
ALTER DATABASE OPEN;
```

---

## 6. İşlem Sonrası Kontroller ve Sonraki Adımlar (Post-Failover)

Yeni veritabanının rolü ve statüsü kontrol edilmelidir:
```sql
SELECT name, open_mode, database_role FROM v$database;
```
*Beklenen Çıktı:* `OPEN_MODE = READ WRITE` ve `DATABASE_ROLE = PRIMARY`

> **Failover Sonrası Çok Önemli Uyarılar:**
> 1. **Tam Yedek (Full Backup):** Veritabanı Failover sonrası yeni bir "Incarnation" (Resetlogs) ile açıldığı için **ACİLEN tam bir veritabanı yedeği** alınmalıdır. Aksi halde bu noktadan sonraki olası bir arızada geri dönüş şansınız olmaz.
> 2. **Eski Primary'nin Durumu:** Eski Primary veritabanı onarılıp ayağa kalktığında artık otomatik olarak bu yapının bir parçası olamaz. Eğer `Flashback Database` özelliği açıksa, eski primary'yi "Flashback" ile Failover öncesi SCN numarasına döndürüp (Reinstate) yeni yapının Standby'ı yapabilirsiniz. Aksi halde eski sunucudaki her şeyi silip, RMAN Duplicate ile sıfırdan bir Standby kurulumu yapmanız gerekecektir.
