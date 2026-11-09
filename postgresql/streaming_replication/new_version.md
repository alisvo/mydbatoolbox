# Azure PostgreSQL Flexible Server – Failover / Switchover Durum Kontrolü

Switchover, failover veya replica promote sonrasında bir node'un **rolünü**, **ne zaman promote olduğunu** ve **ters yöndeki replikasyonun hazır olup olmadığını** tek sorguyla gösteren kontrol scripti.

Aynı sorgu hem primary'de hem standby/replica'da çalışır. Node'un rolünü kendisi algılar ve satırları ona göre doldurur.

## Gereksinimler

- PostgreSQL 13+ (PostgreSQL 16 üzerinde test edildi)
- `pg_monitor` (veya `pg_read_all_stats`) yetkisine sahip kullanıcı. Azure admin kullanıcısında bu yetki varsayılan olarak bulunur.
- Yetki eksikse:

  ```sql
  GRANT pg_monitor TO <kullanici>;
  ```

## Sorgu

```sql
SET TIME ZONE 'Europe/Istanbul';   -- sadece bu oturumu etkiler

WITH
st   AS (SELECT pg_is_in_recovery() AS standby),
wr   AS (SELECT * FROM pg_stat_wal_receiver),
cp   AS (SELECT * FROM pg_control_checkpoint()),
-- Güncel timeline: primary'de mevcut WAL dosya adından, standby'da WAL receiver'dan
tl   AS (SELECT CASE
                  WHEN (SELECT standby FROM st)
                    THEN coalesce((SELECT received_tli FROM wr), (SELECT timeline_id FROM cp))
                  ELSE ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int
                END AS tli),
me   AS (SELECT CASE WHEN (SELECT standby FROM st) THEN pg_last_wal_replay_lsn()
                     ELSE pg_current_wal_lsn() END AS lsn),
-- Güncel timeline'a ait history dosyası (ör. TL 11 -> 0000000B.history)
hist AS (SELECT name, modification
         FROM pg_ls_waldir()
         WHERE name = lpad(upper(to_hex((SELECT tli FROM tl))), 8, '0') || '.history'),
rep  AS (SELECT * FROM pg_stat_replication),
slot AS (SELECT * FROM pg_replication_slots)
SELECT bilgi AS "Kontrol", deger AS "Değer"
FROM (
  -- ===== GENEL =====
  SELECT 1 AS s, 'Rol'::text AS bilgi,
         CASE WHEN (SELECT standby FROM st) THEN 'STANDBY / REPLICA (read-only)'
              ELSE 'PRIMARY (read-write)' END::text AS deger
  UNION ALL SELECT 2, 'Sunucu IP:port', coalesce(host(inet_server_addr()) || ':' || inet_server_port(), 'local socket')
  UNION ALL SELECT 3, 'PG sürüm', current_setting('server_version')
  UNION ALL SELECT 4, 'Şu an (TR)', to_char(now(), 'YYYY-MM-DD HH24:MI:SS')
  UNION ALL SELECT 5, 'Timeline (güncel)', (SELECT tli::text FROM tl)
  UNION ALL SELECT 6,
            CASE WHEN (SELECT standby FROM st) THEN 'TL history alındı (promote anı DEĞİL)'
                 ELSE 'Promote zamanı (TL history)' END,
            coalesce((SELECT to_char(modification, 'YYYY-MM-DD HH24:MI:SS') || '  (' || name || ')' FROM hist),
                     CASE WHEN (SELECT tli FROM tl) = 1 THEN '— yok (timeline 1, hiç promote olmamış)'
                          ELSE '— dosya bulunamadı' END)
  UNION ALL SELECT 7, 'Process başlangıç (son restart)', to_char(pg_postmaster_start_time(), 'YYYY-MM-DD HH24:MI:SS')
  UNION ALL SELECT 8, 'Uptime', date_trunc('second', now() - pg_postmaster_start_time())::text
  UNION ALL SELECT 9,
            CASE WHEN (SELECT standby FROM st) THEN 'Son restartpoint' ELSE 'Son checkpoint' END,
            to_char((SELECT checkpoint_time FROM cp), 'YYYY-MM-DD HH24:MI:SS')
  UNION ALL SELECT 10, 'Yetki: pg_read_all_stats',
            CASE WHEN pg_has_role(current_user, 'pg_read_all_stats', 'member') THEN 'var'
                 ELSE 'YOK → replikasyon detayları NULL görünür' END

  -- ===== PRIMARY TARAFI: bu node'a bağlı standby'lar =====
  UNION ALL SELECT 20, 'Bağlı standby sayısı', (SELECT count(*)::text FROM rep)
  UNION ALL SELECT 21, 'Standby adres / durum',
            coalesce((SELECT string_agg(coalesce(host(client_addr), '?') || ' | '
                                        || coalesce(state, '?') || '/' || coalesce(sync_state, '?'), E'\n')
                      FROM rep), '— yok')
  UNION ALL SELECT 22, 'Standby bağlandı (TR)',
            coalesce((SELECT string_agg(coalesce(to_char(backend_start, 'YYYY-MM-DD HH24:MI:SS'), '?'), E'\n')
                      FROM rep), '— yok')
  UNION ALL SELECT 23, 'LAG byte (replay)',
            coalesce((SELECT string_agg(coalesce(pg_size_pretty(pg_wal_lsn_diff((SELECT lsn FROM me), replay_lsn)), 'görünmüyor'), E'\n')
                      FROM rep), '— yok')
  UNION ALL SELECT 24, 'LAG süre (write / flush / replay)',
            coalesce((SELECT string_agg(coalesce(write_lag::text, 'boşta') || ' / '
                                        || coalesce(flush_lag::text, 'boşta') || ' / '
                                        || coalesce(replay_lag::text, 'boşta'), E'\n')
                      FROM rep), '— yok')

  -- ===== STANDBY TARAFI: bu node replica ise =====
  UNION ALL SELECT 30, 'WAL receiver',
            coalesce((SELECT status || ' ← ' || coalesce(sender_host, '?')
                             || ' | TL ' || coalesce(received_tli::text, '?')
                             || ' | son mesaj: ' || coalesce(to_char(last_msg_receipt_time, 'YYYY-MM-DD HH24:MI:SS'), '?')
                      FROM wr),
                     CASE WHEN (SELECT standby FROM st) THEN '— ÇALIŞMIYOR' ELSE '— yok (primary için normal)' END)
  UNION ALL SELECT 31, 'LAG byte (alınan → uygulanan)',
            CASE WHEN (SELECT standby FROM st)
                 THEN coalesce(pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())), '?')
                 ELSE '— (bu node primary)' END
  UNION ALL SELECT 32, 'Son uygulanan işlemden beri',
            CASE WHEN (SELECT standby FROM st)
                 THEN coalesce(date_trunc('second', now() - pg_last_xact_replay_timestamp())::text, '?')
                      || '  (primary boştayken doğal olarak artar)'
                 ELSE '— (bu node primary)' END

  -- ===== ORTAK =====
  UNION ALL SELECT 40, 'Replication slot',
            coalesce((SELECT string_agg(slot_name || ' (' || slot_type || ', active=' || active || ')', E'\n') FROM slot), '— yok')

  UNION ALL SELECT 99, '>> DURUM',
            CASE
              WHEN (SELECT standby FROM st) AND EXISTS (SELECT 1 FROM wr WHERE status = 'streaming')
                THEN 'STANDBY, primary''den WAL alıyor (streaming) → replikasyon çalışıyor'
              WHEN (SELECT standby FROM st)
                THEN 'STANDBY, ama WAL receiver streaming DEĞİL → kontrol et'
              WHEN NOT EXISTS (SELECT 1 FROM rep)
                THEN 'PRIMARY, bağlı standby yok → ters yön henüz kurulmamış / Azure kuruyor olabilir'
              WHEN EXISTS (SELECT 1 FROM rep WHERE state IS NULL)
                THEN 'PRIMARY, standby bağlı ama detay görünmüyor (yetki eksik, bkz. Yetki satırı)'
              WHEN EXISTS (SELECT 1 FROM rep WHERE state = 'streaming'
                           AND pg_wal_lsn_diff((SELECT lsn FROM me), replay_lsn) < 16 * 1024 * 1024)
                THEN 'PRIMARY + standby STREAMING, lag < 16 MB → geri dönüşe hazır'
              ELSE 'PRIMARY, standby bağlı ama henüz yakalamadı (catchup / lag yüksek)'
            END
) t
ORDER BY s;
```

## Çıktı nasıl okunur

### Genel

| Satır | Anlamı |
|---|---|
| Rol | `PRIMARY` = read-write, `STANDBY / REPLICA` = read-only (`pg_is_in_recovery()`) |
| Timeline (güncel) | Her promote'ta 1 artar. Primary'de güncel WAL dosyasından, standby'da WAL receiver'dan okunur. |
| Promote zamanı (TL history) | **Sadece primary'de anlamlıdır.** Güncel timeline'ın `.history` dosyasının oluşma zamanı = promote anı. |
| TL history alındı | Standby'da gösterilir. History dosyasının primary'den **bu node'a ulaştığı** zamandır, promote anı değildir. |
| Process başlangıç (son restart) | PostgreSQL process'inin son açılışı. Azure promote sonrası restart ettiyse promote'tan birkaç saniye sonrasını gösterir. Saf promote'ta restart olmayabilir, bu yüzden promote zamanı olarak kullanılmamalıdır. |
| Son checkpoint / restartpoint | Bilgi amaçlı. Standby'da bu değer bir önceki timeline'a ait olabilir. |

### Primary tarafı (ters yöndeki standby)

| Satır | Anlamı |
|---|---|
| Bağlı standby sayısı | `0` ise ters yön replikasyon henüz kurulmamış demektir. |
| Standby adres / durum | `streaming` = yakalamış ve canlı akıyor. `startup` / `catchup` = hâlâ kuruluyor. `sync`/`async` replikasyon tipini gösterir. |
| Standby bağlandı (TR) | Ters yön replikasyon bağlantısının açıldığı zaman. |
| LAG byte (replay) | **En güvenilir lag göstergesi.** 0 veya birkaç KB = tam yakalamış. |
| LAG süre | Sadece yazma trafiği varken dolar. Sistem boştayken PostgreSQL NULL döner, burada `boşta` görünür. |

### Standby tarafı

| Satır | Anlamı |
|---|---|
| WAL receiver | `streaming` olmalı. Hangi primary'den ve hangi timeline'dan WAL aldığını, son mesaj zamanını gösterir. Son mesaj "Şu an"a yakınsa bağlantı canlıdır. |
| LAG byte (alınan → uygulanan) | Alınıp henüz uygulanmamış WAL miktarı. |
| Son uygulanan işlemden beri | Primary'de yazma yokken doğal olarak büyür, tek başına sorun göstergesi değildir. |

### `>> DURUM`

| Değer | Anlamı |
|---|---|
| `STANDBY, ... streaming → replikasyon çalışıyor` | Standby sağlıklı. |
| `STANDBY, ama WAL receiver streaming DEĞİL` | Standby primary'den veri almıyor, kontrol edilmeli. |
| `PRIMARY, bağlı standby yok` | Ters yön henüz kurulmamış, Azure hâlâ kuruyor olabilir. |
| `PRIMARY, standby bağlı ama detay görünmüyor` | Yetki eksik (`pg_read_all_stats`). |
| `PRIMARY + standby STREAMING, lag < 16 MB` | Geri dönüşe hazır. |
| `PRIMARY, standby bağlı ama henüz yakalamadı` | Bekleyip tekrar çalıştırın. |

## Örnek: Switchover sonrası zaman çizelgesi çıkarmak

Sorgu her iki node'da çalıştırılıp sonuçlar yan yana okunur:

| Kaynak | Olay |
|---|---|
| Yeni primary → *Promote zamanı* | Promote anı, timeline artışı |
| Yeni primary → *Process başlangıç* | Azure'un promote sonrası restart'ı, bağlantı kabul etmeye başladığı an |
| Yeni standby → *Process başlangıç* | Eski primary'nin standby olarak yeniden açıldığı an |
| Yeni primary → *Standby bağlandı* | Ters yön replikasyonun bağlandığı an |
| Yeni primary → *LAG byte* ≈ 0 | Geri dönüşe hazır |

Kesintinin başlangıcı (switchover'ın tetiklendiği an) için Azure Portal → **Activity log** kullanılır.

## Bilinen tuzaklar

- **Standby'da history dosyası zamanı promote anı değildir.** Promote zamanı her zaman primary'den okunmalıdır.
- **Standby'da `pg_control_checkpoint().timeline_id` eski kalabilir.** Bir sonraki restartpoint'e kadar önceki timeline'ı gösterir. Bu yüzden sorgu standby'da timeline'ı `pg_stat_wal_receiver.received_tli`'dan okur.
- **Async replica ile geri dönüş:** Slot adı `azure_geoasyncreplica_...` ve `sync_state = async` ise bu yapı HA standby değil, geo read replica'dır. Geri dönüş **planned switchover** ile yapılmalıdır. Forced switchover lag'i beklemez ve veri kaybı riski taşır.
- **HA (zone-redundant) standby'a doğrudan bağlanılamaz.** HA standby `pg_stat_replication`'da görünmüyorsa Azure tarafındaki duruma bakılır:

  ```bash
  az postgres flexible-server show -g <rg> -n <server> --query "highAvailability.state" -o tsv
  # CreatingStandby / ReplicatingData → hâlâ kuruluyor, Healthy → hazır
  ```

- **Replikasyonun tam yakalandığı an** PostgreSQL katalogunda tutulmaz. Gerekirse:
  - Server logları (Log Analytics `PostgreSQLLogs`): `is now a synchronous standby`, `started streaming`, `selected new timeline ID`
  - Azure Monitor metrikleri: `Max Physical Replication Lag` / `Read Replica Lag` (1 dk granülerlik)
- `SET TIME ZONE` yalnızca o oturumu etkiler, sunucu ayarını değiştirmez.
