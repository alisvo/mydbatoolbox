# 🛠️ PostgreSQL DBA İsveç Çakısı (Swiss Army Knife)

Bu doküman, PostgreSQL veritabanlarında performans darboğazlarını bulmak, disk sızıntılarını (bloat) tespit etmek ve indeks optimizasyonu yapmak için günlük hayatta kullanılan "hayat kurtarıcı" SQL sorgularının bir kolajıdır.

---

## 📊 1. Sistem Uptime ve İndeks Kullanım Röntgeni
Sistem ne zamandır ayakta, istatistikler ne zamandır toplanıyor ve **hangi indeksler gerçekten kullanılıyor (hangileri yatıyor)?** Tek sorguda sistemin genel okuma röntgeni:

```sql
SELECT 
    '--- SİSTEM BİLGİSİ ---' AS tablo_adi, 
    '1. İstatistiklerin Sıfırlanma Zamanı' AS indeks_adi, 
    NULL::bigint AS kullanim_sayisi,
    COALESCE(TO_CHAR(stats_reset, 'DD.MM.YYYY HH24:MI:SS'), 'Hiç sıfırlanmadı') AS boyut_veya_detay
FROM pg_stat_database 
WHERE datname = current_database()

UNION ALL

SELECT 
    '--- SİSTEM BİLGİSİ ---' AS tablo_adi, 
    '2. Sunucunun Son Başlatılma (Uptime) Zamanı' AS indeks_adi, 
    NULL::bigint AS kullanim_sayisi,
    TO_CHAR(pg_postmaster_start_time(), 'DD.MM.YYYY HH24:MI:SS') AS boyut_veya_detay

UNION ALL

SELECT 
    relname::text AS tablo_adi, 
    indexrelname::text AS indeks_adi, 
    idx_scan AS kullanim_sayisi,
    pg_size_pretty(pg_relation_size(indexrelid)) AS boyut_veya_detay
FROM pg_stat_user_indexes
ORDER BY kullanim_sayisi DESC NULLS FIRST;
```

---

## 🗑️ 2. Ölü İndeks Avcısı (Kullanılmayan İndeksler)
Yazma performansını düşüren ve sadece diskte yer kaplayan, `idx_scan` değeri 0 olan asalak indeksleri bulur. *(Not: PK ve Unique indeksler hariç tutulmuştur).*

```sql
SELECT 
    schemaname || '.' || relname AS tablo_adi, 
    indexrelname AS indeks_adi, 
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS indeks_boyutu,
    idx_scan AS kullanilma_sayisi
FROM pg_stat_user_indexes i
JOIN pg_index USING (indexrelid)
WHERE idx_scan = 0 
  AND indisunique IS FALSE 
ORDER BY pg_relation_size(i.indexrelid) DESC;
```

---

## 💾 3. Tablo ve İndeks Boyutları (Disk Kullanımı)
Veritabanındaki en obez tablolar hangileri? Tablonun kendi ham boyutu ne, üzerindeki indekslerin toplam boyutu ne? En büyük yük getirenden küçüğe doğru listeler.

```sql
SELECT
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size_with_indexes,
    pg_size_pretty(pg_relation_size(relid)) AS table_data_size,
    pg_size_pretty(pg_indexes_size(relid)) AS total_index_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 50;
```

---

## 🧟 4. Vacuum ve Bloat (Ölü Satır) Sağlık Kontrolü
Veritabanındaki tabloların "Ölü Satır" (Dead Tuple) oranlarını hesaplar. Bir tabloda oran %20'leri geçiyorsa, Autovacuum o tabloya yetişemiyor demektir ve acil müdahale gerekir.

```sql
SELECT 
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size_with_indexes,
    n_live_tup AS estimated_live_rows,
    n_dead_tup AS dead_tuples,
    ROUND((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 2) AS dead_tuple_ratio_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY dead_tuple_ratio_pct DESC NULLS LAST
LIMIT 50;
```

---

## 🗺️ 5. Tablo İndeks Haritası
Veritabanındaki tabloların üzerinde o an hangi indekslerin var olduğunu, oluşturulma script'leri (DDL) ile birlikte hızlıca döküm halinde görmek için kullanılır.

```sql
SELECT 
    tablename, 
    indexname, 
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
```

---

## ⏱️ 6. CPU ve Zaman Canavarı Sorgular (Performance Insights)
Veritabanında toplam çalışma süresi en yüksek olan, CPU'yu ve RAM'i en çok sömüren ilk 10 sorguyu getirir.

### Standart PostgreSQL (`pg_stat_statements` aktif ise)
```sql
SELECT 
    query, 
    calls AS calisma_sayisi, 
    ROUND(total_exec_time::numeric, 2) AS toplam_sure_ms, 
    ROUND(mean_exec_time::numeric, 2) AS ortalama_sure_ms, 
    ROUND(max_exec_time::numeric, 2) AS max_sure_ms,
    shared_blks_hit AS ram_okuma_hit,
    shared_blks_read AS disk_okuma
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

### Azure PostgreSQL Flexible Server (`azure_sys` DB'sinde çalıştırılmalıdır)
```sql
SELECT 
    query_id,
    SUM(calls) AS toplam_calisma_sayisi,
    ROUND(SUM(total_time)::numeric, 2) AS toplam_harcanan_sure_ms,
    ROUND(AVG(mean_time)::numeric, 2) AS ortalama_sure_ms,
    ROUND(MAX(max_time)::numeric, 2) AS en_yuksek_sure_ms
FROM query_store.qs_view
GROUP BY query_id
ORDER BY toplam_harcanan_sure_ms DESC
LIMIT 10;
```
