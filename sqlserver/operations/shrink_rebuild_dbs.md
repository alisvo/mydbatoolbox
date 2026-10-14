# SQL Server: Online Shrink ve Index Bakımı Runbook

Kesintisiz (online) şekilde bir veritabanını küçültmek ve ardından shrink'in yarattığı fragmentasyonu temizlemek için adım adım rehber.

Hedef sürüm: **SQL Server 2022**. Önceki sürümler için farklar ilgili bölümlerde not edilmiştir.

> Placeholder'lar: `<DB_NAME>`, `<DATA_FILE>` (mantıksal data dosyası adı), `<LOG_FILE>` (mantıksal log dosyası adı). Mantıksal adları Adım 1'deki sorgudan alın.

---

## Özet Kontrol Listesi

1. Full backup al.
2. Boş alanın hangi dosyada olduğunu tespit et (data mı, log mu?).
3. Log ise: doğrudan `SHRINKFILE`.
4. Data ise: önce `TRUNCATEONLY`, yetmezse kademeli shrink (mesai dışı).
5. Backup job'ı ile çakışmadığından emin ol.
6. Shrink sonrası index bakımı (edition'a göre REORGANIZE / ONLINE REBUILD).
7. Fragmentasyon kontrolü.
8. Şişen log dosyasını küçült.
9. Düzenli index bakım job'ının açık olduğunu doğrula.

---

## 1. Ön Kontroller

### Dosya bazında boş alan

Database Properties'teki "Space Available" data + log toplamıdır; yöntem hangi dosyada boşluk olduğuna göre değişir.

```sql
USE <DB_NAME>;
SELECT name, type_desc,
       size/128.0                                   AS SizeMB,
       FILEPROPERTY(name,'SpaceUsed')/128.0         AS UsedMB,
       (size - FILEPROPERTY(name,'SpaceUsed'))/128.0 AS FreeMB
FROM sys.database_files;

SELECT recovery_model_desc, log_reuse_wait_desc
FROM sys.databases WHERE name = '<DB_NAME>';
```

- Recovery model **FULL** ve log backup alınmıyorsa log sürekli şişer; asıl çözüm log backup planıdır.
- `log_reuse_wait_desc` = `ACTIVE_TRANSACTION` yoğun yazan uygulamalarda (ör. SCCM) geçici olarak normaldir.

### Edition

```sql
SELECT SERVERPROPERTY('Edition') AS Edition,
       SERVERPROPERTY('ProductVersion') AS Version;
```

- `ONLINE = ON` index rebuild ve `RESUMABLE` yalnızca **Enterprise / Developer**'da vardır.
- Standard'da online seçenek: **REORGANIZE**.

### Sürüm notu

SQL Server **16.x = 2022**, 15.x = 2019, 14.x = 2017, 13.x = 2016. Compatibility level 160 = 2022.

---

## 2. Log Dosyasında Boşluk Varsa

Hızlıdır, saniyeler sürer:

```sql
USE <DB_NAME>;
CHECKPOINT;
DBCC SHRINKFILE (N'<LOG_FILE>', 1024);  -- hedef MB
```

Belirli bir boyutun altına inmiyorsa → bkz. [Bölüm 7](#7-log-dosyası-küçülmüyorsa-vlf-sorunu).

---

## 3. Data Dosyasında Boşluk Varsa

### 3.1 Önce TRUNCATEONLY

Sayfa taşımaz, sadece dosya sonundaki boşluğu bırakır. Anlıktır, yük oluşturmaz.

```sql
DBCC SHRINKFILE (N'<DATA_FILE>', TRUNCATEONLY);
```

Dosyanın sonunda kullanılan sayfa varsa **hiç küçülmeyebilir**. Sonuç satırındaki `CurrentSize` değişmediyse normal shrink gerekir.

### 3.2 Hedef boyutu belirle

```
Hedef = UsedMB + %30–40 pay
```

Pay şu nedenlerle gerekli:

- Index bakımı sırasında ek alan ihtiyacı
- Uygulamanın doğal büyümesi (aksi halde dosya hemen tekrar büyür)

### 3.3 Kademeli shrink (mesai dışı)

```sql
USE <DB_NAME>;
DECLARE @file  SYSNAME = N'<DATA_FILE>';
DECLARE @final INT     = 8192;   -- nihai hedef (MB)
DECLARE @step  INT     = 4096;   -- adım büyüklüğü (MB)
DECLARE @target INT    = (SELECT size/128 FROM sys.database_files WHERE name = @file);

WHILE @target > @final
BEGIN
    SET @target -= @step;
    IF @target < @final SET @target = @final;

    DBCC SHRINKFILE (@file, @target)
        WITH WAIT_AT_LOW_PRIORITY (ABORT_AFTER_WAIT = SELF);   -- SQL 2022+

    RAISERROR('Shrunk to %d MB', 0, 1, @target) WITH NOWAIT;
END
```

- `WAIT_AT_LOW_PRIORITY (ABORT_AFTER_WAIT = SELF)`: shrink kilit için 1 dakikadan fazla beklerse **kendini** iptal eder; uygulama sorgularını bloklamaz. İptal olursa scripti tekrar çalıştırmak yeterli; başlangıç boyutu otomatik okunur.
- **SQL 2019 ve öncesi:** `WITH WAIT_AT_LOW_PRIORITY` satırını kaldırın; bloklanmayı monitoring sorgusuyla takip edin.
- İlk adım beklenenden uzun sürebilir (dosya sonunda yoğun veri varsa). Sonraki adımlar genelde hızlanır.

### 3.4 İzleme

Ayrı bir pencereden, birkaç dakika arayla:

```sql
SELECT session_id, command, start_time,
       DATEDIFF(MINUTE, start_time, GETDATE()) AS elapsed_min,
       percent_complete, reads, writes,
       wait_type, blocking_session_id
FROM sys.dm_exec_requests
WHERE command LIKE 'Dbcc%';
```

| Alan | Anlamı |
|---|---|
| `DbccFilesCompact` | Sayfa taşıma aşaması (asıl iş) |
| `percent_complete` | **O anki tek SHRINKFILE çağrısının** yüzdesi, döngünün tamamı değil |
| `PAGEIOLATCH_SH` | Diskten sayfa okuma beklemesi; shrink için normal |
| `blocking_session_id = 0` | Bloklanma yok (en önemli gösterge) |
| `estimated_completion_time` | Shrink için güvenilir değil |

`percent_complete`, `reads`, `writes` artıyorsa işlem sağlıklıdır. 15–20 dakika hiç değişmiyorsa incele.

### 3.5 Kilit davranışı

- Veritabanı **kilitlenmez**; kullanıcılar çalışmaya devam eder.
- Shrink sayfa/obje bazında kısa süreli kilitler alır; bazı anlarda kısa Sch-M kilidi ister. `WAIT_AT_LOW_PRIORITY` bu riski yönetir.
- Yoğun disk I/O yapar → uygulama yavaşlayabilir. Bu yüzden mesai dışında çalıştırın.
- **Database backup ile aynı anda çalışamaz.** Backup job zamanlamasını kontrol edin.

### 3.6 Durdurmak

- SSMS'te **Cancel** veya başka pencereden `KILL <session_id>;`
- Yapılan iş **kaybolmaz** (sayfalar küçük, ayrı transaction'larla taşınır). Rollback saniyeler sürer.
- Adım ortasında kesilirse dosya boyutu hemen düşmeyebilir. Şununla boşalan kuyruğu bırakın:

```sql
DBCC SHRINKFILE (N'<DATA_FILE>', TRUNCATEONLY);
```

- Sonraki pencerede aynı script kaldığı yerden devam eder.

---

## 4. Shrink Sonrası Neden Index Bakımı Şart?

Shrink dosyanın **sonundan** başlar ve her sayfayı dosyanın **başındaki ilk boş yere** koyar. Index sayfalarının sırası tamamen **tersine döner**. Sonuç: büyük index'lerde fragmentasyon %90–100.

Bu nedenle shrink'ten sonra index bakımı yapılmazsa sorgu performansı (özellikle taramalar ve read-ahead) düşer.

---

## 5. Index Bakım Scripti (Edition'a Duyarlı)

| Edition | ≥ %30 fragmentasyon | %5–30 fragmentasyon |
|---|---|---|
| Enterprise / Developer | ONLINE + RESUMABLE REBUILD | REORGANIZE |
| Standard | REORGANIZE | REORGANIZE |

Özellikler:

- 1000 sayfadan küçük index'ler atlanır.
- Büyükten küçüğe işler (en ağır iş başta biter, ilerleme net görünür).
- Her index ayrı TRY/CATCH; biri hata verirse diğerleri devam eder.
- Rebuild kilit için 1 dakikadan fazla beklerse kendini iptal eder.
- Sonunda `sp_updatestats` (REORGANIZE istatistik güncellemez).

```sql
USE <DB_NAME>;
SET NOCOUNT ON;

DECLARE @isEnterprise BIT =
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 3 THEN 1 ELSE 0 END;

RAISERROR('Edition: %s', 0, 1, @@VERSION) WITH NOWAIT;
IF @isEnterprise = 1 RAISERROR('Mod: ONLINE REBUILD + REORGANIZE', 0, 1) WITH NOWAIT;
ELSE                 RAISERROR('Mod: Standard edition -> sadece REORGANIZE', 0, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#idx') IS NOT NULL DROP TABLE #idx;

SELECT  s.name  AS SchemaName,
        o.name  AS TableName,
        i.name  AS IndexName,
        MAX(ps.avg_fragmentation_in_percent) AS Frag,
        SUM(ps.page_count)                   AS PageCount,
        i.allow_page_locks
INTO    #idx
FROM    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
JOIN    sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
JOIN    sys.objects o ON o.object_id = i.object_id
JOIN    sys.schemas s ON s.schema_id = o.schema_id
WHERE   ps.index_id > 0
  AND   ps.alloc_unit_type_desc = 'IN_ROW_DATA'
  AND   i.type IN (1, 2)              -- clustered / nonclustered rowstore
  AND   i.is_disabled = 0
  AND   i.is_hypothetical = 0
  AND   o.is_ms_shipped = 0
GROUP BY s.name, o.name, i.name, i.allow_page_locks
HAVING  SUM(ps.page_count) >= 1000
   AND  MAX(ps.avg_fragmentation_in_percent) >= 5;

DECLARE @total INT = (SELECT COUNT(*) FROM #idx), @n INT = 0;
RAISERROR('Islenecek index sayisi: %d', 0, 1, @total) WITH NOWAIT;

DECLARE @s SYSNAME, @t SYSNAME, @i SYSNAME, @f FLOAT, @p BIGINT, @apl BIT,
        @sql NVARCHAR(MAX), @op NVARCHAR(20), @msg NVARCHAR(2000), @start DATETIME2;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT SchemaName, TableName, IndexName, Frag, PageCount, allow_page_locks
    FROM #idx ORDER BY PageCount DESC;

OPEN c;
FETCH NEXT FROM c INTO @s, @t, @i, @f, @p, @apl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @n += 1;
    SET @sql = NULL;
    SET @op = NULL;

    IF @f >= 30 AND @isEnterprise = 1
    BEGIN
        SET @op = N'REBUILD';
        SET @sql = N'ALTER INDEX ' + QUOTENAME(@i) + N' ON ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
                 + N' REBUILD WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF)),'
                 + N' RESUMABLE = ON, MAXDOP = 2);';
    END
    ELSE IF @apl = 1
    BEGIN
        SET @op = N'REORGANIZE';
        SET @sql = N'ALTER INDEX ' + QUOTENAME(@i) + N' ON ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
                 + N' REORGANIZE;';
    END

    IF @sql IS NULL
    BEGIN
        SET @msg = CONCAT('[', @n, '/', @total, '] ATLANDI (ALLOW_PAGE_LOCKS=OFF): ', @s, '.', @t, '.', @i);
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
    END
    ELSE
    BEGIN
        SET @start = SYSDATETIME();
        BEGIN TRY
            EXEC sys.sp_executesql @sql;
            SET @msg = CONCAT('[', @n, '/', @total, '] ', @op, ' OK  ', @s, '.', @t, '.', @i,
                              '  frag=', CAST(@f AS DECIMAL(5,1)), '%  pages=', @p,
                              '  sure=', DATEDIFF(SECOND, @start, SYSDATETIME()), 's');
        END TRY
        BEGIN CATCH
            SET @msg = CONCAT('[', @n, '/', @total, '] ', @op, ' HATA ', @s, '.', @t, '.', @i,
                              ' -> ', ERROR_MESSAGE());
        END CATCH
        RAISERROR('%s', 0, 1, @msg) WITH NOWAIT;
    END

    FETCH NEXT FROM c INTO @s, @t, @i, @f, @p, @apl;
END

CLOSE c;
DEALLOCATE c;

RAISERROR('Istatistikler guncelleniyor...', 0, 1) WITH NOWAIT;
EXEC sys.sp_updatestats;
RAISERROR('Bitti.', 0, 1) WITH NOWAIT;
```

> **Dikkat:** Değişken içeren mesajları `RAISERROR(@msg, ...)` ile değil, `RAISERROR('%s', 0, 1, @msg)` ile basın. Aksi halde mesajdaki `%` karakteri format kodu sanılır ve *Msg 2787 Invalid format specification* hatası alınır.

**Sürüm notları:** `RESUMABLE` → 2017+ Enterprise. Online rebuild'de `WAIT_AT_LOW_PRIORITY` → 2014+ Enterprise. Eski sürümde ilgili seçenekleri kaldırın.

### Script çıktısını okumak

| Satır | Anlam |
|---|---|
| `OK` | Başarılı |
| `ATLANDI` | `ALLOW_PAGE_LOCKS = OFF`; REORGANIZE yapılamaz (bazı uygulamalarda normal) |
| `HATA` | İncelenmeli; tek başına tekrar çalıştırılabilir |
| `Bitti.` | İstatistik güncellemesi dahil tamamlandı |

### Durdurmak

- **REORGANIZE:** Cancel yeterli, yapılan iş korunur. Tekrar çalıştırıldığında zaten düzelen index'ler listeye girmez.
- **RESUMABLE REBUILD:** Cancel/KILL edilince **paused** durumda kalır ve kaynak tutar. Açık bırakmayın:

```sql
SELECT OBJECT_NAME(object_id) AS TableName, name, state_desc, percent_complete
FROM sys.index_resumable_operations;

-- devam:   ALTER INDEX [idx] ON [schema].[table] RESUME;
-- vazgeç:  ALTER INDEX [idx] ON [schema].[table] ABORT;
```

---

## 6. Sonuç Kontrolü

```sql
SELECT OBJECT_NAME(ps.object_id) AS TableName, i.name AS IndexName,
       CAST(ps.avg_fragmentation_in_percent AS DECIMAL(5,1)) AS Frag, ps.page_count
FROM sys.dm_db_index_physical_stats(DB_ID('<DB_NAME>'), NULL, NULL, NULL, 'LIMITED') ps
JOIN <DB_NAME>.sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.index_id > 0 AND ps.page_count >= 1000 AND ps.avg_fragmentation_in_percent >= 10
ORDER BY ps.avg_fragmentation_in_percent DESC;
```

Boş sonuç veya yalnızca birkaç satır %10–20 aralığında → iş tamam.

### REORGANIZE üstüne REBUILD gerekir mi?

Genelde **hayır**. Fragmentasyon zaten düşükse rebuild'in ek faydası (üst index seviyeleri, tam fill factor, FULLSCAN istatistik) çok küçüktür. Standard edition'da rebuild **offline** çalışır ve dosyaları yeniden büyütür.

Belirli sorgular yavaşsa, online alternatif:

```sql
UPDATE STATISTICS [schema].[table] WITH FULLSCAN;
```

---

## 7. Log Dosyası Küçülmüyorsa (VLF Sorunu)

Shrink ve REORGANIZE, SIMPLE recovery'de bile **tamamen loglanır**; log dosyası büyür. İçerisi checkpoint sonrası boşalır ama dosya kendiliğinden küçülmez.

Log dosyası **yalnızca sondan** küçülebilir ve **son aktif VLF**'nin gerisine inemez. `UsedMB` düşük olduğu halde shrink belli bir boyutta takılıyorsa sebep budur.

```sql
SELECT vlf_begin_offset/1048576 AS start_mb, vlf_size_mb, vlf_active
FROM sys.dm_db_log_info(DB_ID('<DB_NAME>'))
ORDER BY vlf_begin_offset;
```

Sonlarda `vlf_active = 1` varsa: aktif kısım ilerleyip dosya başına dönene kadar birkaç dakika arayla tekrarlayın:

```sql
USE <DB_NAME>;
CHECKPOINT;
DBCC SHRINKFILE (N'<LOG_FILE>', 1024);
```

Hâlâ inmiyorsa uzun süre açık kalan transaction'ı kontrol edin:

```sql
DBCC OPENTRAN ('<DB_NAME>');
```

> Log'un büyük kalması zararsızdır. Disk sıkıntısı yoksa dokunmamak da geçerli bir tercihtir.

---

## 8. Kalıcı Bakım

- Düzenli index bakım job'ı kurun (ör. haftalık): Ola Hallengren `IndexOptimize` veya uygulamanın kendi bakım görevi (SCCM için: *Site Maintenance → Rebuild Indexes*).
- Autogrowth'u yüzde yerine sabit MB yapın (data: 512 MB–1 GB, log: 512 MB).
- Shrink'i rutin bir işlem haline getirmeyin; yalnızca kalıcı büyük veri silme gibi tek seferlik durumlarda kullanın.

---

## Referans Ölçümler (bir örnek çalıştırma)

SQL Server 2022 Standard, sanal sunucu, SIMPLE recovery:

| İşlem | Değer |
|---|---|
| Data dosyası | ~42 GB → 8 GB (kullanılan ~5.7 GB) |
| Kademeli shrink (4 GB adım) | İlk adım uzun, sonraki adımlar ~3 dk |
| Shrink sonrası fragmentasyon | Büyük index'lerde %50–100 |
| REORGANIZE (59 index) | En büyük index (~32K sayfa) ~26 sn; toplam yaklaşık 10–15 dk |
| Log dosyası büyümesi | ~1 GB → ~4 GB |
