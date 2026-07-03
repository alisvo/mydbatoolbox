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

Yazma performansını düşüren ve sadece diskte yer kaplayan, `idx_scan` değeri 0 olan asalak indeksleri bulur.

> Not: Primary Key ve Unique indeksler hariç tutulmuştur.

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

Veritabanındaki en obez tablolar hangileri? Tablonun kendi ham boyutu ne, üzerindeki indekslerin toplam boyutu ne ve yaklaşık kaç kayıt var? En büyük yük getirenden küçüğe doğru listeler.

> Not: `estimated_row_count` değeri `pg_stat_user_tables.n_live_tup` üzerinden gelir. Yani anlık `COUNT(*)` değildir; PostgreSQL istatistiklerine dayalı yaklaşık kayıt sayısıdır. Güncel olması için ilgili tablolarda `ANALYZE` çalışmış olmalıdır.

```sql
SELECT
    t.schemaname || '.' || t.relname AS table_name,
    s.n_live_tup AS estimated_row_count,
    s.n_dead_tup AS estimated_dead_rows,
    pg_size_pretty(pg_total_relation_size(t.relid)) AS total_size_with_indexes,
    pg_size_pretty(pg_relation_size(t.relid)) AS table_data_size,
    pg_size_pretty(pg_indexes_size(t.relid)) AS total_index_size,
    s.last_analyze,
    s.last_autoanalyze
FROM pg_catalog.pg_statio_user_tables t
JOIN pg_catalog.pg_stat_user_tables s
  ON s.relid = t.relid
ORDER BY pg_total_relation_size(t.relid) DESC
LIMIT 50;
```

---

## 🧟 4. Vacuum ve Bloat (Ölü Satır) Sağlık Kontrolü

Veritabanındaki tabloların "Ölü Satır" (Dead Tuple) oranlarını hesaplar. Bir tabloda oran %20'leri geçiyorsa, Autovacuum o tabloya yetişemiyor olabilir ve müdahale gerekebilir.

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

Veritabanındaki tabloların üzerinde o an hangi indekslerin var olduğunu, oluşturulma script'leri yani DDL bilgileri ile birlikte hızlıca döküm halinde görmek için kullanılır.

```sql
SELECT 
    schemaname,
    tablename, 
    indexname, 
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
```

---

## ⏱️ 6. CPU ve Zaman Canavarı Sorgular (Performance Insights)

Veritabanında toplam çalışma süresi en yüksek olan, CPU'yu ve RAM'i en çok sömüren sorguları getirir.

---

### 6.1 Standart PostgreSQL (`pg_stat_statements` aktif ise)

`pg_stat_statements`, tarih-saat bazlı geçmiş tutmaz. Bu sorgu, istatistiklerin son sıfırlanma zamanından itibaren biriken veriyi gösterir.

> Zaman aralığı ile analiz yapmak istiyorsan, test öncesinde `pg_stat_statements_reset()` ile istatistikler sıfırlanabilir veya dışarıda metrik toplama sistemi kullanılmalıdır.

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

İstatistiklerin hangi zamandan beri biriktiğini görmek için:

```sql
SELECT
    d.datname,
    d.stats_reset AS database_stats_reset,
    pss.stats_reset AS pg_stat_statements_stats_reset
FROM pg_stat_database d
CROSS JOIN pg_stat_statements_info pss
WHERE d.datname = current_database();
```

---

### 6.2 Azure PostgreSQL Flexible Server (`azure_sys` DB'sinde çalıştırılmalıdır)

Azure PostgreSQL Flexible Server tarafında Query Store verisi üzerinden bakılır. Bu sorguda tarih-saat aralığı opsiyoneldir.

`from_ts` ve `to_ts` değerleri `NULL` bırakılırsa Query Store'daki mevcut tüm veri üzerinden çalışır. Belirli bir aralık için bu iki alan doldurulmalıdır.

```sql
WITH params AS (
    SELECT
        NULL::timestamp AS from_ts,
        NULL::timestamp AS to_ts

        -- Örnek tarih aralığı:
        -- '2026-07-01 20:00:00'::timestamp AS from_ts,
        -- '2026-07-02 02:00:00'::timestamp AS to_ts
)
SELECT 
    q.query_id,
    SUM(q.calls) AS toplam_calisma_sayisi,
    ROUND(SUM(q.total_time)::numeric, 2) AS toplam_harcanan_sure_ms,
    ROUND((SUM(q.total_time) / NULLIF(SUM(q.calls), 0))::numeric, 2) AS agirlikli_ortalama_sure_ms,
    ROUND(MAX(q.max_time)::numeric, 2) AS en_yuksek_sure_ms,
    MIN(q.start_time) AS ilk_gorulen_zaman,
    MAX(q.end_time) AS son_gorulen_zaman
FROM query_store.qs_view q
CROSS JOIN params p
WHERE (p.from_ts IS NULL OR q.end_time >= p.from_ts)
  AND (p.to_ts IS NULL OR q.start_time < p.to_ts)
GROUP BY q.query_id
ORDER BY toplam_harcanan_sure_ms DESC
LIMIT 10;
```

---

### 6.3 Azure PostgreSQL Flexible Server - Tarih Aralıklı Örnek

Örneğin sadece `2026-07-01 20:00` ile `2026-07-02 02:00` arasındaki en pahalı sorguları görmek için:

```sql
	WITH params AS (
    SELECT
        '2026-07-02 15:00:00'::timestamp AS from_ts,
        '2026-07-03 00:00:00'::timestamp AS to_ts
)
SELECT 
    q.query_id,
    SUM(q.calls) AS toplam_calisma_sayisi,
    ROUND(SUM(q.total_time)::numeric, 2) AS toplam_harcanan_sure_ms,
    ROUND((SUM(q.total_time) / NULLIF(SUM(q.calls), 0))::numeric, 2) AS agirlikli_ortalama_sure_ms,
    ROUND(MAX(q.max_time)::numeric, 2) AS en_yuksek_sure_ms,
    MIN(q.start_time) AS ilk_gorulen_zaman,
    MAX(q.end_time) AS son_gorulen_zaman,
	q.query_sql_text 
FROM query_store.qs_view q
CROSS JOIN params p
WHERE q.end_time >= p.from_ts
  AND q.start_time < p.to_ts
GROUP BY q.query_id
ORDER BY toplam_harcanan_sure_ms DESC
LIMIT 10;
```

> Not: `AVG(mean_time)` yerine `SUM(total_time) / SUM(calls)` kullanılmıştır. Bu daha sağlıklıdır, çünkü Query Store içindeki her satır/bucket aynı sayıda execution içermeyebilir.
