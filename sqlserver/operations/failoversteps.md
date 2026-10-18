# SQL Server Always On: T-SQL ile Manuel Yük Devretme (Failover)

Bu doküman, SQL Server Always On Availability Groups (AG) yapısında, veri kaybı olmadan planlı bir el ile yük devretme (**Planned Manual Failover**) işleminin T-SQL kullanılarak nasıl yapılacağını adım adım açıklamaktadır.

> T-SQL ile failover işlemi yapmak, genellikle SSMS Arayüzü (GUI) kullanmaktan daha hızlıdır.

Senaryomuzda:
- **Mevcut Primary:** `PROD03`
- **Hedef Secondary (Yeni Primary Olacak):** `PROD04`
- **AG ismi:** `[AG_ISMI_BURAYA]` (Object Explorer → **Always On High Availability → Availability Groups** altında görülebilir)

---

## ⚠️ Ön Koşullar (Prerequisites)

- Hedef replica **Synchronous-Commit** modunda olmalıdır.
- Hedef replica'daki **tüm** veritabanları **`SYNCHRONIZED`** ve **`HEALTHY`** olmalıdır.
- AG dışında kalan nesneler (SQL login'ler, Agent job'lar, linked server'lar, credential'lar) hedef sunucuda da tanımlı olmalıdır. SQL login'lerin **SID**'leri iki sunucuda aynı olmalıdır; aksi halde failover sonrası kullanıcılar "orphan" kalır.
- Uygulamalar sunucu ismine değil **Listener**'a bağlanıyor olmalıdır (multi-subnet ortamda `MultiSubnetFailover=True`).
- Failover sırasında primary'deki aktif bağlantılar kopar; uygun bir bakım penceresi seçin.

---

## 🚀 Failover Adımları

### Adım 1: Ön Kontrol

**PROD03 (Primary)** üzerinde replica modlarını kontrol edin:

```sql
SELECT ag.name AS ag_name,
       ar.replica_server_name,
       ar.availability_mode_desc,
       ar.failover_mode_desc
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id;
```

Hedef replica `ASYNCHRONOUS_COMMIT` ise failover'dan önce senkron moda alın (yine **PROD03** üzerinde) ve veritabanlarının `SYNCHRONIZED` olmasını bekleyin:

```sql
ALTER AVAILABILITY GROUP [AG_ISMI_BURAYA]
MODIFY REPLICA ON N'PROD04' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
```

**PROD04 (Hedef)** üzerinde veritabanlarının failover'a hazır olduğunu doğrulayın:

```sql
SELECT ag.name AS ag_name,
       DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc,
       drs.synchronization_health_desc,
       drcs.is_failover_ready
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag
    ON ag.group_id = drs.group_id
JOIN sys.dm_hadr_database_replica_cluster_states drcs
    ON drcs.replica_id = drs.replica_id
   AND drcs.group_database_id = drs.group_database_id
WHERE drs.is_local = 1;
```

Tüm satırlarda `SYNCHRONIZED`, `HEALTHY` ve `is_failover_ready = 1` görülmelidir. Biri bile `0` ise failover yapmayın.

---

### Adım 2: Failover Komutunu Çalıştırın

Failover komutu her zaman **hedef sunucu** (yeni Primary olacak sunucu) üzerinden çalıştırılır. SSMS'te **PROD04**'e bağlanıp:

```sql
-- DİKKAT: Bu komut mutlaka hedef Secondary sunucuda (örn: PROD04) çalıştırılmalıdır!
ALTER AVAILABILITY GROUP [AG_ISMI_BURAYA] FAILOVER;
```

> ⛔ `FORCE_FAILOVER_ALLOW_DATA_LOSS` **planlı failover için kullanılmaz**; yalnızca primary'nin tamamen kaybedildiği felaket senaryolarında, veri kaybı göze alınarak kullanılır.

---

### Adım 3: İşlemi Doğrulayın

**PROD04** üzerinde replica rollerini kontrol edin:

```sql
SELECT ag.name AS ag_name,
       ar.replica_server_name,
       rs.role_desc,
       rs.connected_state_desc,
       rs.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id;
```

Veritabanı bazında senkronizasyonu kontrol edin (eski primary'nin secondary olarak veri almaya başladığını görmek için):

```sql
SELECT ar.replica_server_name,
       DB_NAME(drs.database_id) AS database_name,
       drs.synchronization_state_desc,
       drs.is_suspended,
       drs.log_send_queue_size,
       drs.redo_queue_size
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
ORDER BY ar.replica_server_name, database_name;
```

Listener üzerinden bağlanarak yeni primary'ye yönlendirildiğinizi doğrulayın:

```sql
SELECT @@SERVERNAME;   -- PROD04 dönmeli
```

**Beklenen Çıktı:**

| Kontrol | Değer |
|---|---|
| PROD04 `role_desc` | `PRIMARY` |
| PROD03 `role_desc` | `SECONDARY` |
| `connected_state_desc` | `CONNECTED` |
| `synchronization_health_desc` | `HEALTHY` |
| Veritabanları | `SYNCHRONIZED`, `is_suspended = 0` |
| Listener üzerinden `@@SERVERNAME` | `PROD04` |

> Data movement `SUSPENDED` görünüyorsa ilgili veritabanı için secondary'de `ALTER DATABASE [DB_ISMI] SET HADR RESUME;` çalıştırın.

---

### Adım 4: Failover Sonrası

- Adım 1'de async → sync değişikliği yaptıysanız, eski moda geri almayı unutmayın (yeni primary **PROD04** üzerinde `MODIFY REPLICA ... AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT`).
- Agent job'ların yeni primary'de çalıştığını, eski primary'de ise hata vermediğini kontrol edin (job'larda `sys.fn_hadr_is_primary_replica('DB_ISMI')` kontrolü önerilir).
- Uygulama bağlantılarını ve backup job'larını (`automated_backup_preference`) kontrol edin.
- **Geri dönüş (Failback):** Aynı adımlar bu kez **PROD03** üzerinden çalıştırılarak yapılır.
