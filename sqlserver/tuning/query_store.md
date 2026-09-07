# Query Store Rehberi

Azure SQL Database ve SQL Server üzerinde Query Store'un kurulumu, yapılandırılması, bakımı ve sorun giderilmesi.

> Bu doküman SunExpress IT tarafından, SMARTOPS veritabanında yaşanan gerçek bir Query Store kesintisi sonrası hazırlanmıştır. Sonundaki **Vaka Notu** bölümü o olayı ve çıkarılan dersleri içerir.

---

## İçindekiler

- [Query Store nedir](#query-store-nedir)
- [Durum kontrolü](#durum-kontrolü)
- [Açma ve ilk yapılandırma](#açma-ve-ilk-yapılandırma)
- [Ayar referansı](#ayar-referansı)
- [Yapılandırmayı değiştirme](#yapılandırmayı-değiştirme)
- [Temizleme ve silme](#temizleme-ve-silme)
- [READ_ONLY sorunu](#read_only-sorunu)
- [Dikkat edilmesi gerekenler](#dikkat-edilmesi-gerekenler)
- [Faydalı sorgular](#faydalı-sorgular)
- [Vaka notu: SMARTOPS](#vaka-notu-smartops)
- [Kaynaklar](#kaynaklar)

---

## Query Store nedir

Query Store, veritabanı seviyesinde çalışan bir "uçuş kayıt cihazı"dır. Çalıştırılan sorguların metnini, üretilen execution plan'ları ve her plan için çalışma istatistiklerini (CPU, süre, logical read, bekleme türleri) zaman aralıkları hâlinde saklar.

Plan cache'ten farkı: **plan cache uçucudur**, restart/failover/memory pressure ile silinir. Query Store veriyi kullanıcı tablolarında kalıcı tutar, dolayısıyla "geçen salı gece 03:00'te ne yavaşladı" sorusuna cevap verebilir.

Tipik kullanım alanları:

- En çok CPU / IO / süre tüketen sorguları bulmak
- Bir sorgunun planının zamanla değişip değişmediğini görmek (plan regresyonu)
- Index veya kod değişikliğinin öncesi/sonrası etkisini ölçmek
- Bekleme türü kırılımı (CPU mu, blocking mi, network mü)
- Kötü plan yerine iyi planı zorlamak (plan forcing)

---

## Durum kontrolü

Herhangi bir işlem yapmadan önce mevcut durumu görün:

```sql
SELECT
    actual_state_desc,
    desired_state_desc,
    readonly_reason,
    current_storage_size_mb,
    max_storage_size_mb,
    CAST(100.0 * current_storage_size_mb
         / NULLIF(max_storage_size_mb, 0) AS decimal(5,1)) AS doluluk_yuzde,
    query_capture_mode_desc,
    size_based_cleanup_mode_desc,
    stale_query_threshold_days,
    max_plans_per_query,
    interval_length_minutes,
    flush_interval_seconds,
    wait_stats_capture_mode_desc
FROM sys.database_query_store_options;
```

`actual_state_desc` ile `desired_state_desc` **farklıysa** bir sorun var demektir — genellikle `READ_ONLY`'ye düşmüştür. Sebebi için [READ_ONLY sorunu](#read_only-sorunu) bölümüne bakın.

**Gerekli yetki:** SQL Server 2022 ve Azure SQL için `VIEW DATABASE PERFORMANCE STATE`, SQL Server 2016–2019 için `VIEW DATABASE STATE`.

---

## Açma ve ilk yapılandırma

Azure SQL Database'de Query Store **varsayılan olarak açıktır**. SQL Server'da (2016+) `master`, `model`, `msdb` ve `tempdb` dışındaki kullanıcı veritabanlarında manuel açılır; SQL Server 2022'den itibaren yeni veritabanlarında varsayılan açıktır.

### Açma

```sql
ALTER DATABASE [VeritabaniAdi] SET QUERY_STORE = ON;
```

### Önerilen başlangıç yapılandırması

```sql
ALTER DATABASE [VeritabaniAdi] SET QUERY_STORE (
    OPERATION_MODE              = READ_WRITE,
    MAX_STORAGE_SIZE_MB         = 1024,
    SIZE_BASED_CLEANUP_MODE     = AUTO,
    CLEANUP_POLICY              = (STALE_QUERY_THRESHOLD_DAYS = 30),
    QUERY_CAPTURE_MODE          = AUTO,
    MAX_PLANS_PER_QUERY         = 200,
    INTERVAL_LENGTH_MINUTES     = 60,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    WAIT_STATS_CAPTURE_MODE     = ON
);
```

Azure SQL'de mevcut veritabanı için `[VeritabaniAdi]` yerine `CURRENT` kullanılabilir:

```sql
ALTER DATABASE CURRENT SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 1024);
```

### Neden bu değerler

| Ayar | Gerekçe |
|---|---|
| `MAX_STORAGE_SIZE_MB = 1024` | 100 MB gerçek bir üretim yükü için genellikle yetersiz; birkaç haftada dolar ve Query Store sessizce susar. |
| `SIZE_BASED_CLEANUP_MODE = AUTO` | Limite yaklaşınca eski veriyi otomatik siler, `READ_ONLY`'ye düşmeyi engeller. **Kapalı bırakılmamalı.** |
| `QUERY_CAPTURE_MODE = AUTO` | Önemsiz / nadiren çalışan sorguları yakalamaz. `ALL` modu ad-hoc yükü olan sistemlerde depolamayı hızla doldurur. |
| `WAIT_STATS_CAPTURE_MODE = ON` | Bekleme kırılımı olmadan "yavaş ama CPU tüketmiyor" tipi sorunlar teşhis edilemez. |
| `INTERVAL_LENGTH_MINUTES = 60` | Küçültmek veri hacmini doğrudan katlar. Detaylı analiz için geçici olarak düşürülebilir. |

---

## Ayar referansı

| Ayar | Tip / geçerli değerler | Varsayılan | Not |
|---|---|---|---|
| `OPERATION_MODE` | `OFF`, `READ_ONLY`, `READ_WRITE` | `READ_WRITE` | `READ_ONLY` = okur ama yeni kayıt almaz |
| `MAX_STORAGE_SIZE_MB` | tam sayı | SQL Server ≤2017: 100<br>SQL Server 2019+: 1024<br>Azure SQL Premium: 1024<br>Azure SQL Basic: 10 | Dolunca `READ_ONLY`'ye düşer |
| `SIZE_BASED_CLEANUP_MODE` | `OFF`, `AUTO` | `AUTO` | %90'da tetiklenir, %80'e inince durur |
| `CLEANUP_POLICY (STALE_QUERY_THRESHOLD_DAYS)` | tam sayı, `0` = kapalı | 30 (Azure Basic: 7) | Zaman bazlı temizlik |
| `QUERY_CAPTURE_MODE` | `ALL`, `AUTO`, `NONE`, `CUSTOM` | SQL Server: `ALL`<br>Azure SQL: `AUTO` | `NONE` yalnızca zaten yakalanmış sorguları izlemeye devam eder |
| `MAX_PLANS_PER_QUERY` | tam sayı, `0` = sınırsız | 200 | Aşılırsa yeni planlar kaydedilmez |
| `INTERVAL_LENGTH_MINUTES` | **yalnızca** 1, 5, 10, 15, 30, 60, 1440 | 60 | Başka değer kabul edilmez |
| `DATA_FLUSH_INTERVAL_SECONDS` | tam sayı | 900 | Bellekten diske yazma sıklığı |
| `WAIT_STATS_CAPTURE_MODE` | `OFF`, `ON` | `ON` (SQL Server 2017+) | Bekleme türü kırılımı |

### CUSTOM yakalama modu

`AUTO` yeterince seçici değilse eşikler elle belirlenebilir:

```sql
ALTER DATABASE CURRENT SET QUERY_STORE (
    QUERY_CAPTURE_MODE = CUSTOM,
    QUERY_CAPTURE_POLICY = (
        STALE_CAPTURE_POLICY_THRESHOLD = 24 HOURS,
        EXECUTION_COUNT                = 30,
        TOTAL_COMPILE_CPU_TIME_MS      = 1000,
        TOTAL_EXECUTION_CPU_TIME_MS    = 100
    )
);
```

Belirlenen pencere içinde bu eşiklerden **herhangi birini** aşan sorgular yakalanır. Parantez içindeki değerler varsayılanlardır.

---

## Yapılandırmayı değiştirme

Tüm değişiklikler `ALTER DATABASE ... SET QUERY_STORE (...)` ile yapılır. Birden fazla ayar tek komutta verilebilir; verilmeyen ayarlar değişmeden kalır.

```sql
-- Tek ayar
ALTER DATABASE CURRENT SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 2048);

-- Birden fazla ayar
ALTER DATABASE CURRENT SET QUERY_STORE (
    MAX_STORAGE_SIZE_MB     = 2048,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    QUERY_CAPTURE_MODE      = AUTO
);

-- Sadece okuma moduna al (bakım / analiz dönemi)
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_ONLY);

-- Tamamen kapat (veriler korunur)
ALTER DATABASE CURRENT SET QUERY_STORE = OFF;
```

### Bellekteki veriyi diske zorlama

Son dakikaların istatistiklerini hemen görmek için (varsayılan flush aralığı 15 dakikadır):

```sql
EXEC sys.sp_query_store_flush_db;
```

---

## Temizleme ve silme

### Tüm geçmişi silme

```sql
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;
```

> **Geri dönüşü yoktur.** Tüm sorgu metinleri, planlar, çalışma istatistikleri ve bekleme verileri silinir. Öncesinde önemli baseline'ları dışarı almış olun.

Yalnızca çalışma istatistiklerini silip sorgu/plan kayıtlarını korumak için:

```sql
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;   -- her şey
EXEC sys.sp_query_store_reset_exec_stats @plan_id = 1234;  -- tek plan
```

### Tek bir sorguyu veya planı silme

```sql
-- Belirli bir planı sil (eski/kötü plan cache'te takılı kaldıysa)
EXEC sys.sp_query_store_remove_plan @plan_id = 1234;

-- Sorguyu, tüm planlarını ve istatistiklerini sil
EXEC sys.sp_query_store_remove_query @query_id = 5678;
```

### Plan zorlama ve kaldırma

```sql
EXEC sys.sp_query_store_force_plan   @query_id = 5678, @plan_id = 1234;
EXEC sys.sp_query_store_unforce_plan @query_id = 5678, @plan_id = 1234;
```

### Sorgu ipucu (hint) uygulama — kod değiştirmeden

SQL Server 2022 ve Azure SQL'de, uygulama kodunu değiştirmeden bir sorguya hint uygulanabilir:

```sql
EXEC sys.sp_query_store_set_hints
     @query_id = 5678,
     @query_hints = N'OPTION(MAXDOP 1, RECOMPILE)';

EXEC sys.sp_query_store_clear_hints @query_id = 5678;
```

Üçüncü parti veya kaynak koduna erişilemeyen uygulamalarda çok değerlidir.

---

## READ_ONLY sorunu

En sık karşılaşılan Query Store arızası budur ve **sessizdir**: hiçbir hata mesajı üretilmez, uygulama etkilenmez, sadece Query Store yeni veri kaydetmeyi bırakır. Fark edilmesi haftalar alabilir.

### Teşhis

```sql
SELECT actual_state_desc, desired_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb
FROM sys.database_query_store_options;
```

### readonly_reason değerleri

Bitmask'tir; birden fazla sebep varsa değerler toplanır (örn. `65536 + 131072 = 196608`).

| Değer | Anlamı | Çözüm |
|---|---|---|
| `1` | Veritabanı read-only modda | Veritabanını read-write yapın |
| `2` | Single user modda | Multi user'a alın |
| `4` | Emergency modda | Veritabanını normale döndürün |
| `8` | İkincil replika (AG / geo-replication) | Beklenen davranış; birincil replikaya bağlanın |
| `65536` | **Depolama limiti doldu** | Limiti yükseltin veya temizleyin |
| `131072` | Farklı ifade sayısı bellek limitine ulaştı | Ad-hoc sorgu şişkinliğini giderin |
| `262144` | Diske yazılmayı bekleyen kayıtlar limite ulaştı | Geçicidir, genellikle kendi düzelir |
| `524288` | Veritabanı disk boyutu limitine ulaştı | Veritabanı boyutunu büyütün veya yer açın |

### Çözüm — `readonly_reason = 65536` için

**Sıra önemlidir.** Önce yer açın, sonra `READ_WRITE` yapın. Yer açmadan `READ_WRITE` yaparsanız anında tekrar `READ_ONLY`'ye düşer.

```sql
-- 1) Limiti yükselt ve otomatik temizliği aç
ALTER DATABASE CURRENT SET QUERY_STORE (
    MAX_STORAGE_SIZE_MB     = 1024,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    CLEANUP_POLICY          = (STALE_QUERY_THRESHOLD_DAYS = 14),
    QUERY_CAPTURE_MODE      = AUTO
);
GO

-- 2) Read-write moda al
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE);
GO

-- 3) Teyit et
SELECT actual_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb
FROM sys.database_query_store_options;
```

Limiti yükseltmek istemiyorsanız alternatif geçmişi silmektir:

```sql
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;
GO
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE);
```

### ERROR durumu

`actual_state_desc = 'ERROR'` görülürse Query Store tutarlılık kontrolünden geçirilmelidir:

```sql
-- Bu işlem uzun sürebilir, bakım penceresinde çalıştırın
EXEC sys.sp_query_store_consistency_check;
```

---

## Dikkat edilmesi gerekenler

### 1. READ_ONLY'ye düşme sessizdir — izleyin

Hiçbir uyarı üretilmez. Doluluk oranını periyodik kontrol eden bir iş kurun:

```sql
SELECT
    DB_NAME() AS veritabani,
    actual_state_desc,
    readonly_reason,
    CAST(100.0 * current_storage_size_mb
         / NULLIF(max_storage_size_mb, 0) AS decimal(5,1)) AS doluluk_yuzde
FROM sys.database_query_store_options;
-- doluluk_yuzde > 80  veya  actual_state_desc <> 'READ_WRITE'  ise alarm üret
```

### 2. Ad-hoc ve parametre sayısı değişen sorgular Query Store'u şişirir

Query Store'u dolduran en yaygın sebep budur. Özellikle şu desen tehlikelidir:

```sql
-- Her farklı liste uzunluğu YENİ bir sorgu metni üretir
WHERE Id IN (@ids1, @ids2, ..., @ids300)
WHERE Id IN (@ids1, @ids2, ..., @ids299)   -- ayrı query_id
WHERE Id IN (@ids1, @ids2, ..., @ids250)   -- ayrı query_id
```

Bu desen hem plan cache'i hem Query Store'u parçalar. Çözüm: **TVP (table-valued parameter)** veya **`OPENJSON`** kullanarak sabit sorgu metni üretmek.

```sql
-- Sabit metin, tek plan
SELECT t.*
FROM dbo.Tablo t
JOIN OPENJSON(@idsJson) WITH (Id int '$') j ON j.Id = t.Id;
```

Entity Framework Core 8 ve sonrası `Contains()` çağrılarını otomatik olarak `OPENJSON`'a çevirir; eski sürümlerde her eleman ayrı parametre olarak gönderilir.

Parametrelenmemiş sorguları tespit etmek için:

```sql
SELECT qsq.query_id, qsqt.query_sql_text
FROM sys.query_store_query AS qsq
JOIN sys.query_store_query_text AS qsqt
     ON qsqt.query_text_id = qsq.query_text_id
WHERE qsq.query_parameterization_type = 0;
```

### 3. Yer açmadan READ_WRITE yapmak işe yaramaz

Limit dolu kaldığı sürece Query Store saniyeler içinde tekrar `READ_ONLY`'ye döner. Önce `MAX_STORAGE_SIZE_MB` yükseltin veya `CLEAR` yapın.

### 4. `SIZE_BASED_CLEANUP_MODE = AUTO` açık olmalı, ama limite yaklaşmayın

Otomatik temizlik %90 doluluk seviyesinde tetiklenir ve %80'e inene kadar çalışır. Bu işlem CPU ve IO tüketir; sürekli limitin dibinde çalışan bir Query Store, temizlik yüzünden ölçmeye çalıştığı sistemi yavaşlatabilir. Doğru yaklaşım: limiti yeterince yüksek tutup temizliği emniyet supabı olarak bırakmak.

### 5. `INTERVAL_LENGTH_MINUTES` küçültmek veri hacmini katlar

60 dakikadan 5 dakikaya inmek, saklanan satır sayısını yaklaşık 12 katına çıkarır. Yalnızca kısa süreli detaylı analiz için düşürün, sonra geri alın.

### 6. Yalnızca geçerli aralık değerleri kabul edilir

`INTERVAL_LENGTH_MINUTES` için sadece **1, 5, 10, 15, 30, 60, 1440** kullanılabilir. Başka bir değer hata verir.

### 7. Flush aralığı kadar veri kaybı riski vardır

`DATA_FLUSH_INTERVAL_SECONDS` (varsayılan 900 sn) boyunca istatistikler bellekte tutulur. Beklenmedik bir kapanma veya failover bu penceredeki veriyi kaybettirir. Kritik ölçüm öncesi `sys.sp_query_store_flush_db` çağırın.

### 8. `MAX_PLANS_PER_QUERY` limitine dikkat

Varsayılan 200'dür. Plan kararsızlığı olan bir sorgu bu sınırı aşarsa yeni planlar kaydedilmez ve analiz eksik kalır. Yüksek plan sayısı zaten başlı başına bir bulgudur — sebebini araştırın (parameter sniffing, değişen istatistikler).

### 9. Plan forcing kalıcı bir çözüm değildir

Zorlanan plan, şema değişikliği (index silinmesi gibi) sonrası geçersiz hâle gelebilir. Bu durumda SQL Server sessizce normal optimizasyona döner. Zorlanan planları düzenli kontrol edin:

```sql
SELECT p.query_id, p.plan_id, p.is_forced_plan,
       p.force_failure_count, p.last_force_failure_reason_desc
FROM sys.query_store_plan p
WHERE p.is_forced_plan = 1;
```

`force_failure_count > 0` ise zorlama çalışmıyor demektir.

### 10. Query Store'un kendi yükü

Genellikle düşüktür (tipik olarak %3–5 CPU), ancak çok yüksek işlem hacimli sistemlerde ölçülmelidir. `QUERY_CAPTURE_MODE = ALL` bu yükü belirgin şekilde artırır; üretimde `AUTO` tercih edilmelidir.

### 11. Sayaçlar ve DMV'ler farklı davranır

Query Store verisi kalıcıdır ve failover'dan etkilenmez. Buna karşılık `sys.dm_db_index_usage_stats`, `sys.dm_exec_query_stats` ve `sys.dm_db_missing_index_*` DMV'leri failover veya restart'ta **sıfırlanır**. Bir analizde düşük sayılar görüyorsanız önce sayaçların ne zamandır biriktiğini kontrol edin.

### 12. İkincil replikada beklenen davranıştır

`readonly_reason = 8` bir arıza değildir. Okuma amaçlı ikincil replikaya bağlıysanız Query Store zaten yazamaz. SQL Server 2022+ ve Azure SQL'de ikincil replikalar için ayrı bir mod vardır (`READ_CAPTURE_SECONDARY`).

---

## Faydalı sorgular

### En çok CPU tüketen sorgular (son 7 gün)

```sql
SELECT TOP 25
    q.query_id,
    SUM(rs.count_executions)                                            AS execs,
    CAST(SUM(rs.avg_cpu_time * rs.count_executions)/1000.0 AS bigint)   AS total_cpu_ms,
    CAST(SUM(rs.avg_duration * rs.count_executions)/1000.0 AS bigint)   AS total_duration_ms,
    CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) AS bigint)  AS total_reads,
    CAST(SUM(rs.avg_logical_io_reads * rs.count_executions)
         / NULLIF(SUM(rs.count_executions),0) AS bigint)                AS avg_reads,
    COUNT(DISTINCT p.plan_id)                                           AS plan_count,
    LEFT(MIN(qt.query_sql_text), 150)                                   AS sorgu_basi
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i
      ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan       p  ON p.plan_id       = rs.plan_id
JOIN sys.query_store_query      q  ON q.query_id      = p.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE i.start_time >= DATEADD(day, -7, SYSUTCDATETIME())
GROUP BY q.query_id
ORDER BY total_cpu_ms DESC;
```

> **Not:** `interval` bazında gruplamayın. Aksi hâlde aynı sorgu her saat için ayrı satır olarak görünür ve gerçek toplamı göremezsiniz.

### Bekleme türü kırılımı

Sorgu yavaş ama CPU tüketmiyorsa cevap buradadır.

```sql
SELECT p.query_id, ws.wait_category_desc,
       SUM(ws.total_query_wait_time_ms) AS wait_ms
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_plan p ON p.plan_id = ws.plan_id
JOIN sys.query_store_runtime_stats_interval i
      ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
WHERE i.start_time >= DATEADD(day, -7, SYSUTCDATETIME())
GROUP BY p.query_id, ws.wait_category_desc
ORDER BY wait_ms DESC;
```

Sık görülen kategoriler:

| Kategori | Anlamı |
|---|---|
| `CPU` | Gerçek hesaplama |
| `Network IO` | Uygulama sonucu yavaş tüketiyor (`ASYNC_NETWORK_IO`) |
| `Lock` | Blocking |
| `Buffer IO` / `Other Disk IO` | Fiziksel okuma |
| `Memory` | Bellek grant bekleme |

### Plan regresyonu tespiti

Aynı sorgunun farklı planları arasında performans karşılaştırması:

```sql
SELECT
    p.query_id, p.plan_id,
    p.initial_compile_start_time,
    p.last_execution_time,
    p.is_forced_plan,
    SUM(rs.count_executions)                                        AS execs,
    CAST(SUM(rs.avg_cpu_time * rs.count_executions)
         / NULLIF(SUM(rs.count_executions),0) / 1000.0 AS decimal(18,2)) AS avg_cpu_ms,
    CAST(SUM(rs.avg_logical_io_reads * rs.count_executions)
         / NULLIF(SUM(rs.count_executions),0) AS bigint)            AS avg_reads
FROM sys.query_store_plan p
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
WHERE p.query_id = 12345
GROUP BY p.query_id, p.plan_id, p.initial_compile_start_time,
         p.last_execution_time, p.is_forced_plan
ORDER BY p.last_execution_time DESC;
```

### Query Store'u kim dolduruyor

```sql
SELECT TOP 20
    COUNT(*)                    AS farkli_sorgu_sayisi,
    CAST(SUM(LEN(qt.query_sql_text)) / 1024.0 / 1024.0 AS decimal(10,2)) AS metin_mb,
    LEFT(qt.query_sql_text, 60) AS metin_basi
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
GROUP BY LEFT(qt.query_sql_text, 60)
ORDER BY farkli_sorgu_sayisi DESC;
```

Aynı metin başlangıcına sahip binlerce sorgu görüyorsanız, o kod yolu parametre sayısı değişen bir `IN` listesi üretiyor demektir.

### Bir planı tam olarak inceleme

```sql
SELECT p.query_id, p.plan_id, p.count_compiles,
       TRY_CAST(p.query_plan AS xml) AS plan_xml
FROM sys.query_store_plan p
WHERE p.plan_id = 1234;
```

SSMS'te sonuçtaki XML bağlantısına tıklayarak grafiksel planı açabilirsiniz.

---

## Vaka notu: SMARTOPS

**Tarih:** Eylül 2026
**Ortam:** Azure SQL Database, 4 vCore

### Ne oldu

Performans analizi sırasında Query Store'un **17 saattir hiçbir veri kaydetmediği** fark edildi. Uygulanan index'lerin etkisini ölçmek için çalıştırılan sorgular, bir gün önceki eski planları döndürüyordu. Hiçbir hata mesajı yoktu.

Teşhis:

```
actual_state_desc  : READ_ONLY
desired_state_desc : READ_WRITE
readonly_reason    : 65536          -- depolama limiti doldu
max_storage_size_mb: 100
```

### Kök sebep

Veritabanındaki Entity Framework sorguları, ID listelerini parametre parametre gönderiyordu:

```sql
WHERE [s].[LegId] IN (@legIds1, @legIds2, ..., @legIds300)
```

Liste uzunluğu her çağrıda değiştiği için (`250`, `299`, `300`, `350`, `400`, `450`...) her varyant **ayrı bir sorgu metni** olarak kaydediliyordu. Binlerce farklı metin, varsayılan 100 MB'lık Query Store alanını doldurmuştu.

Aynı desen paralel olarak plan cache'i de parçalıyor ve her varyant için ayrı derleme maliyeti üretiyordu — yani tek bir kod deseni hem performansı hem gözlemlenebilirliği bozuyordu.

### Yapılanlar

1. `MAX_STORAGE_SIZE_MB` 100 → 1024
2. `SIZE_BASED_CLEANUP_MODE = AUTO`
3. `OPERATION_MODE = READ_WRITE`
4. Geliştirme ekibine `IN` listelerinin TVP / `OPENJSON`'a taşınması için talep açıldı

### Çıkarılan dersler

- **Query Store'un çalıştığını varsaymayın, doğrulayın.** Analiz yaptığınız verinin ne zamana kadar güncel olduğunu her seferinde kontrol edin (`MAX(last_execution_time)`).
- **100 MB varsayılanı gerçek üretim yükü için yetersizdir.**
- **Doluluk oranı izlenmelidir.** %80 üzerinde alarm üreten bir kontrol, bu olayı 17 saat değil 17 dakika içinde ortaya çıkarırdı.
- **Query Store dolmuşsa, alternatif ölçüm kaynağı `sys.dm_exec_query_stats`'tir.** Plan cache'teki canlı istatistikler Query Store'dan bağımsızdır ve index değişikliği sonrası planlar zaten yenilendiği için "sonrası" ölçümü olarak kullanılabilir:

```sql
SELECT TOP 25
    qs.execution_count,
    qs.total_logical_reads / NULLIF(qs.execution_count,0)  AS avg_reads,
    CAST(qs.total_worker_time / NULLIF(qs.execution_count,0)
         / 1000.0 AS decimal(18,2))                        AS avg_cpu_ms,
    qs.creation_time,
    qs.last_execution_time,
    SUBSTRING(st.text, NULLIF(CHARINDEX(N'FROM ', st.text),0), 120) AS from_kismi
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE st.text LIKE N'%TabloAdi%'
ORDER BY qs.total_logical_reads DESC;
```

---

## Kaynaklar

- [Best practices for managing the Query Store](https://learn.microsoft.com/en-us/sql/relational-databases/performance/manage-the-query-store)
- [Best practices for monitoring workloads with Query Store](https://learn.microsoft.com/en-us/sql/relational-databases/performance/best-practice-with-the-query-store)
- [sys.database_query_store_options (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-database-query-store-options-transact-sql)
- [ALTER DATABASE SET Options (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-set-options)
- [Query Store for secondary replicas](https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-for-secondary-replicas)
