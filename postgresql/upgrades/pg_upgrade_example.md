# RHEL Tabanlı Sistemlerde `pg_upgrade` ile PostgreSQL Major Sürüm Yükseltme Rehberi

PostgreSQL'de major sürüm geçişleri (örn. 15 → 18) sistem kataloglarının yapısını değiştirdiği için basit bir paket güncellemesiyle yapılamaz. `pg_dump` / `pg_restore` büyük veritabanlarında saatler sürerken, **`pg_upgrade`** kullanıcı veri dosyalarına dokunmadan yalnızca katalogları yeniden oluşturur; `--link` modunda kesinti süresi veri boyutundan neredeyse bağımsız hale gelir.

Bu rehber RHEL / Rocky / Alma / Oracle Linux üzerinde PGDG paketleriyle kurulmuş bir sunucuyu esas alır. Örnek senaryo **15 → 18**'dir; komutlar değişkenlerle yazıldığı için başka sürüm çiftlerine de uyarlanabilir.

```bash
# Rehber boyunca kullanılan değişkenler (her yeni shell oturumunda tekrar tanımlayın)
export OLD=15
export NEW=18
export OLDBIN=/usr/pgsql-$OLD/bin
export NEWBIN=/usr/pgsql-$NEW/bin
export OLDDATA=/var/lib/pgsql/$OLD/data
export NEWDATA=/var/lib/pgsql/$NEW/data
```

> Rehberdeki komutlar PGDG varsayılan dizin yapısına göredir. Data directory'niz farklı bir yerdeyse (`SHOW data_directory;`) değişkenleri buna göre düzenleyin.

---

## İçindekiler

1. [Hazırlık (kesinti öncesi)](#1-hazırlık-kesinti-öncesi)
2. [Yeni sürümün kurulumu ve `initdb`](#2-yeni-sürümün-kurulumu-ve-initdb)
3. [Uyumluluk kontrolü (`--check`)](#3-uyumluluk-kontrolü---check)
4. [Kesinti başlangıcı: eski cluster'ın durdurulması](#4-kesinti-başlangıcı-eski-clusterın-durdurulması)
5. [Yükseltme](#5-yükseltme)
6. [Konfigürasyonların taşınması](#6-konfigürasyonların-taşınması)
7. [Yeni cluster'ın başlatılması](#7-yeni-clusterın-başlatılması)
8. [İstatistikler ve eklentiler](#8-i̇statistikler-ve-eklentiler)
9. [Doğrulama](#9-doğrulama)
10. [Geri dönüş (rollback) senaryoları](#10-geri-dönüş-rollback-senaryoları)
11. [Standby, yedekleme ve çevre bileşenler](#11-standby-yedekleme-ve-çevre-bileşenler)
12. [Eski cluster'ın temizlenmesi](#12-eski-clusterın-temizlenmesi)
13. [Ek: `--link` gerçekte ne yapar?](#ek---link-gerçekte-ne-yapar)

---

## 1. Hazırlık (kesinti öncesi)

Bu bölümdeki her şey eski cluster çalışırken, kesintiden günler önce yapılabilir.

### 1.1 Yedek

- Fiziksel yedek (`pg_basebackup`, pgBackRest, Barman) veya disk **snapshot**'ı alın ve **geri dönülebildiğini doğrulayın**.
- `--link` modunda yeni cluster başlatıldıktan sonra tek geri dönüş yolu bu yedektir (bkz. [Bölüm 10](#10-geri-dönüş-rollback-senaryoları)).

### 1.2 Envanter

```bash
sudo -u postgres psql <<'SQL'
SELECT version();
SHOW data_directory;
SHOW data_checksums;
SHOW port;

-- Encoding / locale
SELECT datname, pg_encoding_to_char(encoding), datcollate, datctype FROM pg_database;

-- Tablespace'ler (varsa ayrıca planlanmalı)
SELECT spcname, pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname NOT LIKE 'pg_%';

-- Replikasyon slotları ve standby'lar
SELECT slot_name, slot_type, active FROM pg_replication_slots;
SELECT application_name, client_addr, state FROM pg_stat_replication;

-- Prepared transaction olmamalı (pg_upgrade reddeder)
SELECT * FROM pg_prepared_xacts;

-- Yüklenen kütüphaneler
SHOW shared_preload_libraries;
SQL

# Eklentiler her veritabanında ayrı ayrı kontrol edilmeli
for db in $(sudo -u postgres psql -Atc "SELECT datname FROM pg_database WHERE datallowconn"); do
  echo "== $db"; sudo -u postgres psql -d "$db" -Atc "SELECT extname, extversion FROM pg_extension"
done
```

### 1.3 Kontrol listesi

| Konu | Ne kontrol edilmeli |
|---|---|
| **Disk alanı** | `--link` / `--clone` / `--swap` modlarında yalnızca kataloglar için küçük bir alan gerekir. `--copy` (varsayılan) modunda veritabanı boyutu kadar boş alan gerekir. |
| **Dosya sistemi** | `--link` için eski ve yeni data directory **aynı dosya sisteminde** (aynı mount point) olmalıdır; hard link dosya sistemleri arasında çalışmaz. Tablespace'ler kendi dosya sistemleri içinde linklenir. |
| **Eklentiler** | Kullanılan her eklentinin yeni sürüm paketi kurulmalı (`postgis36_18`, `pg_partman_18`, `pgaudit_18` vb.). Eksik kütüphane `--check` aşamasında "required libraries" hatası verir. |
| **Release notes** | Aradaki **tüm** major sürümlerin "Migration" bölümlerini okuyun (15 → 18 için 16, 17 ve 18). |
| **Logical replication** | Slotlar yalnızca eski cluster **17 veya üzeriyse** taşınır. Daha eski kaynaklarda slotlar kaybolur; upgrade sonrası yeniden kurulmalıdır. |
| **Uygulama uyumu** | Sürücü/ORM sürümleri, `psql`/`pg_dump` kullanan scriptler ve PATH içindeki eski binary yolları. |

### 1.4 Sürüme özel dikkat noktaları (örnekler)

- **PG 18 — data checksums:** `initdb` artık checksum'ı **varsayılan olarak açık** oluşturur. Eski cluster'da kapalıysa `pg_upgrade` uyumsuzluk hatası verir (çözüm [Bölüm 2](#2-yeni-sürümün-kurulumu-ve-initdb)'de).
- **PG 18 — MD5 parolalar** kullanımdan kaldırılma sürecindedir (uyarı üretir). Fırsat varken `scram-sha-256`'ya geçişi planlayın.
- **PG 18 — FTS / `pg_trgm` indeksleri:** Varsayılan collation provider'ı `libc` olmayan (ICU/builtin) cluster'larda full text search ve `pg_trgm` indekslerinin upgrade sonrası `REINDEX` edilmesi gerekebilir.
- **PG 17:** `old_snapshot_threshold` ve `db_user_namespace` parametreleri kaldırıldı.
- **PG 16:** `promote_trigger_file`, `vacuum_defer_cleanup_age` kaldırıldı.
- **PG 15:** `pg_start_backup()` / `pg_stop_backup()` → `pg_backup_start()` / `pg_backup_stop()` oldu (özel yedek scriptlerini etkiler); `stats_temp_directory` kaldırıldı.

Kaldırılmış bir parametre yeni `postgresql.conf` içinde kalırsa servis **başlamaz**.

---

## 2. Yeni sürümün kurulumu ve `initdb`

Eski cluster çalışmaya devam ederken:

```bash
sudo dnf install -y postgresql$NEW-server postgresql$NEW-contrib
# + kullandığınız eklentilerin yeni sürüm paketleri
```

`initdb` ayarlarında eski cluster ile **mutlaka** eşleşmesi gerekenler: `data_checksums`, WAL segment boyutu ve blok boyutu. Encoding/locale için:

- **Hedef sürüm 16+ ise:** `pg_upgrade` locale ve encoding'i eski cluster'dan kendisi alır, elle eşleştirmek gerekmez.
- **Hedef sürüm 15 ve altıysa:** encoding, locale ve (15'te) locale provider eski cluster ile aynı verilmelidir.

```bash
# Örnek A — eski cluster'da checksum KAPALI, hedef 18+ (18'de varsayılan açık olduğu için kapatılmalı)
sudo PGSETUP_INITDB_OPTIONS="--no-data-checksums" $NEWBIN/postgresql-$NEW-setup initdb

# Örnek B — eski cluster'da checksum AÇIK, hedef 17 ve altı
sudo PGSETUP_INITDB_OPTIONS="--data-checksums" $NEWBIN/postgresql-$NEW-setup initdb

# Örnek C — ayarlar zaten uyumlu
sudo $NEWBIN/postgresql-$NEW-setup initdb
```

> **Checksum'ı açmak istiyorsanız:** Upgrade sırasında değil, ayrı bir işlem olarak yapın. Eski cluster kapalıyken `pg_checksums --enable -D $OLDDATA` çalıştırılabilir; süresi veri boyutuyla orantılıdır, bu yüzden kesinti penceresini ayrıca hesaplayın.

Yeni cluster'ı **başlatmayın**; `pg_upgrade` boş ve kapalı bir hedef cluster bekler. Yeni cluster'da elle veritabanı, rol veya eklenti oluşturmayın.

---

## 3. Uyumluluk kontrolü (`--check`)

`--check` hiçbir veriyi değiştirmez ve **eski cluster çalışırken** de koşturulabilir. Bu sayede sorunlar kesintiden önce, sakin bir zamanda bulunur. (Yeni cluster kapalı olmalıdır.)

```bash
sudo su - postgres
# (değişkenleri yeniden tanımlayın)

$NEWBIN/pg_upgrade \
  --old-bindir=$OLDBIN \
  --new-bindir=$NEWBIN \
  --old-datadir=$OLDDATA \
  --new-datadir=$NEWDATA \
  --link \
  --check
```

Beklenen son satır: **`*Clusters are compatible*`**

Notlar:

- `--check`'i kullanacağınız transfer moduyla (`--link` vb.) birlikte çalıştırın; böylece hard link yapılabilirliği de test edilir.
- `pg_upgrade`, çalıştırıldığı dizine yazabilmelidir; `postgres` kullanıcısının home dizini (`/var/lib/pgsql`) uygundur. Ayrıntılı loglar `$NEWDATA/pg_upgrade_output.d/` altında tutulur.
- `pg_upgrade` her iki cluster'a da yerel soket üzerinden `postgres` kullanıcısıyla bağlanır. `pg_hba.conf` içindeki `local` satırı `peer` veya `trust` olmalıdır; parola soruyorsa geçici olarak düzenleyin ya da `~/.pgpass` kullanın.
- Hata çıkarsa (uyumsuz veri tipi, eksik kütüphane, prepared transaction vb.) düzeltip `--check`'i tekrar çalıştırın. Kesinti günü son bir kez daha çalıştırın.

---

## 4. Kesinti başlangıcı: eski cluster'ın durdurulması

1. Uygulama trafiğini kesin (uygulamaları durdurun, connection pooler'ı kapatın veya `pg_hba.conf` ile erişimi kısıtlayın).
2. Standby varsa, primary'deki son WAL'ı aldıklarını doğrulayın:

   ```bash
   sudo -u postgres psql -c "SELECT application_name, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
   ```

3. Cluster'ı temiz şekilde durdurun:

   ```bash
   sudo systemctl stop postgresql-$OLD
   sudo systemctl is-active postgresql-$NEW   # "inactive" olmalı
   ```

> Servisleri systemd ile yönetiyorsanız durdurma/başlatma için de `systemctl` kullanın. `pg_ctl` ile elle başlatılan bir instance'ı systemd tanımaz; sunucu yeniden başladığında veya servis komutlarında tutarsızlık oluşur.

---

## 5. Yükseltme

```bash
sudo su - postgres
# (değişkenleri yeniden tanımlayın)

$NEWBIN/pg_upgrade \
  --old-bindir=$OLDBIN \
  --new-bindir=$NEWBIN \
  --old-datadir=$OLDDATA \
  --new-datadir=$NEWDATA \
  --link \
  --jobs=4
```

`--jobs`, çok sayıda veritabanı veya tablespace olduğunda dump/restore ve dosya transferini paralelleştirir.

### Transfer modları

| Mod | Ne yapar | Ek disk | Eski cluster'a dönüş |
|---|---|---|---|
| `--copy` (varsayılan) | Dosyaları kopyalar | Veri boyutu kadar | Her zaman mümkün (eski cluster'a dokunulmaz) |
| `--link` | Hard link oluşturur | Yok denecek kadar az | Yalnızca yeni cluster **hiç başlatılmadıysa** |
| `--clone` | Reflink (CoW) kullanır; XFS (`reflink=1`) / Btrfs gerekir | Başlangıçta yok | Her zaman mümkün |
| `--copy-file-range` (17+) | Çekirdeğin `copy_file_range()` çağrısıyla kopyalar | Dosya sistemine bağlı | Her zaman mümkün |
| `--swap` (18+) | Dizinleri taşır; en hızlısı | Yok | **Mümkün değil** (transfer başladığı anda eski cluster kullanılamaz) |

> **⚠️ `--link` için kritik uyarı:** Eski ve yeni dizindeki dosyalar aynı fiziksel veriyi gösterir. Yeni cluster bir kez başlatıldıktan sonra eski cluster'ı **asla** başlatmayın; ortak dosyalar bozulur. `pg_upgrade` bunu önlemek için eski cluster'ın `global/pg_control` dosyasını `pg_control.old` olarak yeniden adlandırır.

`--link` kullanılsa bile yeni bir data directory zorunludur; çünkü yeni sürüm kendi sistem kataloglarını oluşturur, yalnızca kullanıcı tablo/indeks dosyaları linklenir.

Başarılı çıktının sonunda `Upgrade Complete` görülür ve çalışma dizininde `delete_old_cluster.sh` (ve gerekiyorsa `update_extensions.sql`) oluşur.

**Hata durumunda:** Çıktıdaki *"If pg_upgrade fails after this point, you must re-initdb the new cluster"* satırından sonra hata alırsanız, yeni data directory'yi silip [Bölüm 2](#2-yeni-sürümün-kurulumu-ve-initdb)'deki `initdb`'yi tekrarlamanız gerekir. Hata detayı `$NEWDATA/pg_upgrade_output.d/` altındadır.

---

## 6. Konfigürasyonların taşınması

Yeni cluster varsayılan ayarlarla gelir. Yeni servisi başlatmadan **önce**:

- **`postgresql.conf`:** Eski dosyayı kopyalamayın. Yalnızca değiştirdiğiniz parametreleri yeni dosyaya (veya `conf.d/` altındaki ayrı bir dosyaya) taşıyın. Değiştirilmiş parametreleri eski cluster çalışırken şu sorguyla listeleyebilirsiniz:

  ```sql
  SELECT name, setting, source, sourcefile
  FROM pg_settings
  WHERE source NOT IN ('default', 'override');
  ```

- **`postgresql.auto.conf`:** `ALTER SYSTEM` ile yapılmış ayarlar buradadır; ayrıca kontrol edin.
- **`pg_hba.conf` ve `pg_ident.conf`:** Erişim kurallarını aktarın.
- **`port` ve `listen_addresses`:** Uygulamaların bağlandığı port eski cluster'ınkiyle aynı olmalı. (İki sürümü farklı portlarda test ettiyseniz bu adım kolayca unutulur.)
- **`shared_preload_libraries`:** Eklentiler başlamadan önce yüklenmiş olmalı (`pg_stat_statements`, `pgaudit`, `timescaledb` vb.).
- **Diğer:** SSL sertifika/anahtar dosyaları, `archive_command` / `archive_library`, systemd override'ları (`systemctl cat postgresql-$OLD`), `PGDATA` özelleştirmeleri.
- Kaldırılmış veya adı değişmiş parametreleri ayıklayın ([Bölüm 1.4](#14-sürüme-özel-dikkat-noktaları-örnekler)).

---

## 7. Yeni cluster'ın başlatılması

```bash
exit   # postgres kullanıcısından çık

sudo systemctl disable postgresql-$OLD
sudo systemctl enable --now postgresql-$NEW
sudo systemctl status postgresql-$NEW
```

> `--link` modunda bu adım **geri dönüşü olmayan noktadır**. Emin değilseniz başlatmadan önce [Bölüm 10](#10-geri-dönüş-rollback-senaryoları)'a bakın.

Servis başlamazsa: `sudo journalctl -u postgresql-$NEW -n 50` ve `$NEWDATA/log/` altındaki loglar.

---

## 8. İstatistikler ve eklentiler

### 8.1 Eklenti güncellemeleri

`pg_upgrade` eklentilerin ikili dosyalarını değil, yalnızca tanımlarını taşır. Güncelleme gerekiyorsa çalışma dizininde `update_extensions.sql` oluşturur:

```bash
sudo su - postgres
[ -f update_extensions.sql ] && psql -f update_extensions.sql
```

PostGIS gibi bazı eklentilerin kendi upgrade prosedürü vardır (`SELECT postgis_extensions_upgrade();`); ilgili dokümantasyonu izleyin.

### 8.2 Optimizer istatistikleri

Doğru komut hedef sürüme göre değişir; en güvenilir kaynak `pg_upgrade` çıktısının son satırlarıdır.

**Hedef 18 ve üzeri** — optimizer istatistiklerinin çoğu taşınır; yalnızca eksik kalanlar (ör. extended statistics) toplanır, ardından autovacuum'un ihtiyaç duyduğu kümülatif sayaçlar güncellenir:

```bash
$NEWBIN/vacuumdb --all --analyze-in-stages --missing-stats-only
$NEWBIN/vacuumdb --all --analyze-only --jobs=4
```

**Hedef 14 – 17** — istatistikler taşınmaz, tamamı yeniden toplanmalıdır:

```bash
$NEWBIN/vacuumdb --all --analyze-in-stages
```

**Hedef 13 ve altı** — `pg_upgrade`'in ürettiği `./analyze_new_cluster.sh` scripti kullanılır.

`--analyze-in-stages` önce kaba, sonra giderek ayrıntılı istatistik üretir; böylece uygulamalar ilk aşamadan sonra makul planlarla çalışmaya başlayabilir. Uygulama trafiğini en azından ilk aşama bittikten sonra açın.

---

## 9. Doğrulama

Eski cluster'ı silmeden **önce**:

```bash
sudo -u postgres psql <<'SQL'
SELECT version();
SHOW data_directory;
SHOW port;
\l
-- Geçersiz indeks kalmış mı?
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
SQL

# Her veritabanında eklenti sürümleri
for db in $(sudo -u postgres psql -Atc "SELECT datname FROM pg_database WHERE datallowconn"); do
  echo "== $db"; sudo -u postgres psql -d "$db" -Atc "SELECT extname, extversion FROM pg_extension"
done
```

Ayrıca:

- Kritik tablolarda satır sayısı / örnek sorgu karşılaştırması (upgrade öncesi kaydettiğiniz değerlerle).
- Uygulama bağlantı testi ve smoke test.
- PostgreSQL loglarında `ERROR` / `FATAL` / collation uyarısı taraması.
- Yedekleme, arşivleme (`pg_stat_archiver`) ve izleme araçlarının yeni cluster'la çalıştığının teyidi.

---

## 10. Geri dönüş (rollback) senaryoları

| Durum | Geri dönüş |
|---|---|
| `--check` başarısız | Hiçbir şey değişmedi. Sorunu giderip tekrar deneyin. |
| `pg_upgrade` yarıda hata verdi | Eski cluster sağlamdır. Link aşamasına gelindiyse `pg_control.old` → `pg_control` adlandırmasını geri alın. Yeni data directory'yi silip yeniden `initdb` yapın. |
| `--link` tamamlandı, yeni cluster **hiç başlatılmadı** | `mv $OLDDATA/global/pg_control.old $OLDDATA/global/pg_control` ve ardından `systemctl start postgresql-$OLD`. |
| `--link` tamamlandı, yeni cluster **başlatıldı** | Eski cluster artık güvenle açılamaz. Tek yol: upgrade öncesi yedekten/snapshot'tan dönmek. |
| `--copy` / `--clone` kullanıldı | Yeni cluster'ı durdurun, eski cluster'ı başlatın (`.old` eki bu modlarda eklenmez). Yeni cluster'da yazılan veriler kaybolur. |
| `--swap` kullanıldı | Dosya transferi başladıktan sonra eski cluster yoktur; yalnızca yedekten dönülebilir. |

Yeni cluster üzerinde uygulama veri yazmaya başladıktan sonra yapılacak her geri dönüş, o andan itibaren yazılan verinin kaybı anlamına gelir. Bu yüzden "geri dönüş kararı için son an"ı önceden belirleyin.

---

## 11. Standby, yedekleme ve çevre bileşenler

- **Streaming replication standby'ları:** Standby'lar `pg_upgrade` ile yükseltilmez. En basit ve güvenli yöntem, primary yükseltildikten sonra standby'ları `pg_basebackup` ile yeniden kurmaktır. Büyük veritabanlarında resmi dokümantasyondaki `rsync --hard-links` yöntemi daha hızlıdır ancak adımları harfiyen izlenmezse standby'ı bozar.
- **Patroni / repmgr vb.:** Küme yöneticisinin kendi major upgrade prosedürünü izleyin; yönetici çalışırken servisleri elle durdurup başlatmayın.
- **Logical replication:** Kaynak 17'den eskiyse slotları ve subscription'ları yeniden oluşturun.
- **Yedekleme araçları:** pgBackRest için `stanza-upgrade`, Barman için yeni sunucu konfigürasyonu gerekir. Yeni sürümde hemen bir **full backup** alın; eski sürümün yedekleri ve WAL arşivi yeni cluster'a uygulanamaz.
- **Çevre:** `.bash_profile` içindeki `PATH` / `PGDATA`, cron job'ları, izleme ajanları (exporter'lar), logrotate ve connection pooler ayarlarını yeni sürüm yollarına güncelleyin.

---

## 12. Eski cluster'ın temizlenmesi

Yeni cluster'ın en az birkaç gün sorunsuz çalıştığını ve yeni yedeğin alındığını gördükten sonra:

```bash
sudo su - postgres
./delete_old_cluster.sh
exit

# Eski paketleri kaldırın
sudo dnf remove -y "postgresql$OLD*"
```

`--link` modunda eski dizini silmek veriyi silmez: dosyalar yeni dizindeki linkler üzerinden yaşamaya devam eder, yalnızca eski dizin girdileri ve eski kataloglar kaldırılır.

---

## Ek: `--link` gerçekte ne yapar?

Hard link, aynı fiziksel dosyaya (inode) ikinci bir dizin girdisi eklemektir. Bunu upgrade sırasında gözlemlemek mümkündür:

```bash
# Upgrade ÖNCESİ — bir tablonun dosya yolunu bulun
sudo -u postgres psql -d mydb -Atc "SELECT pg_relation_filepath('myschema.mytable');"
# -> base/16386/16389

stat -c 'Inode=%i Links=%h %n' $OLDDATA/base/16386/16389
# Inode=973746 Links=1

# pg_upgrade --link SONRASI (eski cluster silinmeden önce)
stat -c 'Inode=%i Links=%h %n' $OLDDATA/base/16386/16389 $NEWDATA/base/16386/16389
# Inode=973746 Links=2   <- iki yol, aynı inode
# Inode=973746 Links=2

# delete_old_cluster.sh SONRASI
stat -c 'Inode=%i Links=%h %n' $NEWDATA/base/16386/16389
# Inode=973746 Links=1   <- veri yerinde, yalnızca eski dizin girdisi gitti
```

Inode numarasının değişmemesi verinin kopyalanmadığını, `Links` değerinin **2**'ye çıkması ise iki cluster'ın aynı dosyayı paylaştığını gösterir. Eski cluster'ın yeni cluster başlatıldıktan sonra neden açılmaması gerektiğinin sebebi de budur.

> `pg_upgrade` relfilenode değerlerini koruduğu için (15+) göreli yol (`base/16386/16389`) genellikle aynı kalır; daha eski sürümlerde dosya adı değişebilir, inode yine aynıdır.

---

## Kaynaklar

- [pg_upgrade — PostgreSQL Documentation](https://www.postgresql.org/docs/current/pgupgrade.html)
- [Upgrading a PostgreSQL Cluster](https://www.postgresql.org/docs/current/upgrading.html)
- [Release Notes](https://www.postgresql.org/docs/release/) — aradaki her major sürümün "Migration" bölümü
- [Versioning Policy / EOL tarihleri](https://www.postgresql.org/support/versioning/)
