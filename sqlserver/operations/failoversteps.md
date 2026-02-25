# SQL Server Always On: T-SQL ile Manuel Yük Devretme (Failover)

Bu doküman, SQL Server Always On Availability Groups (AG) yapısında, veri kaybı olmadan planlı bir el ile yük devretme (**Planned Manual Failover**) işleminin T-SQL kullanılarak nasıl yapılacağını adım adım açıklamaktadır.

> T-SQL ile failover işlemi yapmak, genellikle SSMS Arayüzü (GUI) kullanmaktan daha hızlıdır.

---

## ⚠️ Ön Koşullar (Prerequisites)

İşleme başlamadan önce aşağıdaki şartların sağlandığından emin olun:

- Availability Group **Synchronous-Commit (Senkron)** modunda olmalıdır.
- Hedeflenen Secondary sunucunun senkronizasyon durumu **`HEALTHY`** ve **`SYNCHRONIZED`** olmalıdır.

---

## 🚀 Failover Adımları

Senaryomuzda:
- **Mevcut Primary:** `PROD03`
- **Hedef Secondary (Yeni Primary Olacak):** `PROD04`

---

### Adım 1: Hedef Sunucuya Bağlanın

Failover komutu her zaman **hedef sunucu** (yeni Primary olacak sunucu) üzerinden tetiklenmelidir.

SSMS'te *(SQL Server Management Studio)* **PROD04** (Secondary) sunucusuna bağlanın ve yeni bir sorgu (**New Query**) penceresi açın.

---

### Adım 2: Failover Komutunu Çalıştırın

Aşağıdaki komutta yer alan `[AG_ISMI_BURAYA]` alanını kendi Availability Group isminizle değiştirerek komutu çalıştırın:
```sql
-- DİKKAT: Bu komut mutlaka hedef Secondary sunucuda (örn: PROD04) çalıştırılmalıdır!
ALTER AVAILABILITY GROUP [AG_ISMI_BURAYA] FAILOVER;
```

> 💡 Availability Group isminizi Object Explorer'da **"Availability Groups"** klasörü altında görebilirsiniz.

---

### Adım 3: İşlemi Doğrulayın

Komut başarıyla tamamlandıktan (*"Command(s) completed successfully"* mesajını aldıktan) sonra, rollerin başarıyla değiştiğini teyit etmek için **PROD04** üzerinde aşağıdaki kontrol sorgusunu çalıştırın:
```sql
SELECT
    ar.replica_server_name,
    rs.role_desc,
    rs.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas ar
    ON rs.replica_id = ar.replica_id;
```

**Beklenen Çıktı:**

Sorgu sonucunda;
- Komutu çalıştırdığınız **PROD04** sunucusunun → `PRIMARY`
- Eski primary olan **PROD03** sunucusunun → `SECONDARY`

durumuna geçtiğini ve her ikisinin health durumunun **`HEALTHY`** olduğunu görmelisiniz.
