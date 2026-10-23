

## 1. Primary kontrolü

Replikasyonun sağlığı en güvenilir şekilde primary'den görülür: her replica için `state = 'streaming'` olan bir satır beklenir.

```sql
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag, reply_time
FROM pg_stat_replication;
```

Replication slot kullanılıyorsa slot durumu ve tutulan WAL miktarı:

```sql
SELECT slot_name, slot_type, active, active_pid, wal_status,
       pg_size_pretty(safe_wal_size) AS safe_wal_size,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

## 2. Replica kontrolü

Replica'ya bağlıyken tek sorguyla bağlanılan sunucu, recovery durumu, yetki ve WAL receiver bilgisi alınır.

```sql
SELECT inet_server_addr()   AS server_ip,
       inet_server_port()   AS server_port,
       pg_is_in_recovery()  AS is_replica,
       pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER') AS can_read_stats,
       (SELECT status FROM pg_stat_wal_receiver) AS wal_receiver_status,
       pg_last_wal_receive_lsn() AS receive_lsn,
       pg_last_wal_replay_lsn()  AS replay_lsn,
       pg_last_xact_replay_timestamp() AS last_replay_time;
```

WAL receiver detayı:

```sql
SELECT status, sender_host, sender_port, slot_name,
       flushed_lsn, latest_end_lsn, last_msg_receipt_time
FROM pg_stat_wal_receiver;
```

`pg_stat_wal_receiver` detaylarını yalnızca superuser veya `pg_read_all_stats` üyeleri görür; diğerleri kolonları NULL görür. `pg_last_wal_*` fonksiyonları yetki istemez.

## 3. Lag ölçümü

Lag için birincil kaynak primary'deki `replay_lag` ve byte farkıdır; replica tarafı yalnızca aldığı ile uyguladığı arasındaki farkı bilir.

**Primary'den (byte + saniye):**

```sql
SELECT application_name, client_addr, state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_bytes,
       EXTRACT(EPOCH FROM replay_lag) AS replay_lag_sec
FROM pg_stat_replication;
```

**Replica'dan (saniye):**

```sql
SELECT CASE
         WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
         ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())
       END AS lag_seconds,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS replay_pending;
```

**Heartbeat (trafikten bağımsız kesin ölçüm):**

```sql
-- Primary: bir kez
CREATE TABLE replication_heartbeat (id int PRIMARY KEY, ts timestamptz NOT NULL);
INSERT INTO replication_heartbeat VALUES (1, now());
-- Primary: periyodik (ör. pg_cron ile 10 sn'de bir)
UPDATE replication_heartbeat SET ts = now() WHERE id = 1;
-- Replica: ölçüm
SELECT EXTRACT(EPOCH FROM now() - ts) AS lag_seconds FROM replication_heartbeat WHERE id = 1;
```

Yazma trafiği yokken primary'deki lag kolonları NULL olur ve replica'daki `now() - pg_last_xact_replay_timestamp()` yapay olarak büyür; ikisi de hata değildir.

## 4. Sonuçların yorumlanması

Sağlıklı kurulumda primary'de `streaming`, replica'da `is_replica = true` ve ilerleyen LSN'ler görülür.

| Kontrol | Sağlıklı | Sorun belirtisi |
| --- | --- | --- |
| `pg_stat_replication.state` | `streaming` | Satır yok veya uzun süre `startup` / `catchup` |
| `sync_state` | Async: `async`; senkron: `sync` / `quorum` | Beklenenden farklı mod |
| `replay_lag` / lag byte | Küçük ve sabit | Sürekli büyüyor |
| Slot `wal_status` | `reserved` | `extended` uyarı; `unreserved` / `lost` kritik |
| Replica `pg_is_in_recovery()` | `true` | `false` = yanlış host'a (primary'ye) bağlanılmış |
| `pg_stat_wal_receiver.status` | `streaming` | Satır yok = receiver çalışmıyor; kolonlar NULL = yetki eksik |
| `last_msg_receipt_time` | Birkaç saniye içinde | Eski zaman = bağlantı kopmuş olabilir |

## 5. Azure Flexible Server notları

- **HA standby'a bağlanılamaz:** okuma sorguları için kullanılamaz; sağlığı primary'deki `pg_stat_replication` satırından (senkron, `sync_state = 'sync'`) ve Portal'daki HA health status ekranından izlenir.
- **Read replica ayrı bir sunucudur:** kendi FQDN'i vardır, asenkron streaming replication kullanır; replica sorguları bu endpoint'e bağlanılarak çalıştırılır.
- **`inet_server_addr()`** VM'in iç IP'sini döndürür; DNS'in çözümlediği IP'den farklı olabilir ve failover sonrası değişir.
- **"Promote to primary server" (switchover)** virtual endpoint ister. `VirtualEndpointsRequiredForReplicaSiteSwap` hatası, primary'de ReadWrite virtual endpoint olmadığı ya da reader endpoint'in promote edilecek replica'yı göstermediği anlamına gelir. Çözüm: Primary → Replication → Create endpoint (reader hedefi = ilgili replica), sonra promote'u tekrar denemek.
- **"Promote to independent server"** virtual endpoint istemez ama geri alınamaz; replica replikasyondan tamamen kopar.
- Promote to primary için replica'nın compute/storage konfigürasyonu primary ile aynı olmalıdır.
- Uygulamalar sunucu FQDN'i yerine virtual endpoint hostname'lerini kullanırsa switchover sonrası connection string değişikliği gerekmez.

```bash
az postgres flexible-server virtual-endpoint list -g <resource-group> --server-name <primary-adi>
```

## Kaynaklar

- [High availability – Azure Database for PostgreSQL Flexible Server](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-high-availability)
- [Virtual endpoints for read replicas](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-read-replicas-virtual-endpoints)
- [Switch over read replica to primary](https://docs.azure.cn/en-us/postgresql/read-replica/how-to-switch-over-replica-to-primary)
