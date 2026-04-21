# PostgreSQL `pg_upgrade` Aracı ile Sürüm Yükseltme Rehberi

PostgreSQL veritabanında "Major" (ana) sürüm güncellemeleri (örneğin 11'den 15'e) veritabanı dosyalarının fiziksel formatında değişiklikler içerdiği için basit bir "binary" (ikili dosya) değişimi ile yapılamaz. Geleneksel `pg_dumpall` / `pg_restore` yöntemi büyük veritabanları için saatler sürebilecekken, **`pg_upgrade`** aracı bu işlemi dakikalar, hatta `--link` modu ile saniyeler içinde tamamlamanızı sağlar.

Bu rehberde, on-premise, AWS EC2 veya Azure VM üzerindeki PostgreSQL sunucularınızı nasıl güvenle yükselteceğinizi adım adım inceleyeceğiz.

## 🛠️ Ön Koşullar ve Hazırlık

Herhangi bir major upgrade işlemine başlamadan önce aşağıdaki adımları eksiksiz tamamlamanız kritiktir:

1. **Kesinlikle Yedek Alın:** Fiziksel bir yedek (örn. `pg_basebackup`) veya bulut ortamındaysanız (AWS EBS, Azure Managed Disks) diskin bir **Snapshot**'ını mutlaka alın.
2. **Disk Alanı Kontrolü:** Eğer `--link` modu kullanmayacaksanız (`copy` modu), veritabanınızın mevcut boyutu kadar sunucuda ek boş disk alanına ihtiyacınız olacaktır.
3. **Eklentiler (Extensions):** `PostGIS`, `pg_stat_statements` gibi eklentiler kullanıyorsanız, yeni sürüm için uyumlu binary kütüphanelerinin sisteme kurulduğundan emin olun.

## 🚀 Adım Adım Sürüm Yükseltme Süreci

Aşağıdaki senaryoda eski sürümümüzün **12**, hedeflediğimiz yeni sürümün ise **15** olduğunu varsayarak ilerliyoruz.

### 1. Yeni Sürüm Binaries Kurulumu

Eski veritabanı çalışmaya devam ederken yeni sürümü sunucuya kurun.

**Ubuntu/Debian Örneği:**
```bash
sudo apt-get update
sudo apt-get install postgresql-15 postgresql-server-dev-15
```

### 2. Servislerin Durdurulması

Veri tutarlılığını sağlamak ve `pg_upgrade`'in dosyalara müdahale edebilmesi için her iki servisi de durdurun.

```bash
sudo systemctl stop postgresql@12-main
sudo systemctl stop postgresql@15-main
```

### 3. Uyumluluk Kontrolü (Dry-Run Modu)

Gerçek yükseltme öncesinde veritabanınızın uyumlu olup olmadığını kontrol etmelisiniz. Bu adım veri üzerinde hiçbir değişiklik yapmaz. İşlemleri `postgres` kullanıcısı ile yapmalıyız.

```bash
sudo su - postgres

/usr/lib/postgresql/15/bin/pg_upgrade \
  -b /usr/lib/postgresql/12/bin \
  -B /usr/lib/postgresql/15/bin \
  -d /var/lib/postgresql/12/main \
  -D /var/lib/postgresql/15/main \
  -c
```
*(Yollar işletim sisteminize göre farklılık gösterebilir. CentOS/RHEL sistemlerinde yollar genelde `/usr/pgsql-15/bin/` şeklindedir.)*

Ekranın sonunda **"Clusters are compatible"** (Kümeler uyumlu) mesajını görüyorsanız her şey yolundadır.

### 4. Asıl Yükseltme İşleminin Başlatılması

Kontrol başarılıysa, `-c` (check) parametresini kaldırıp işlemi başlatın. Eğer disk alanınız kısıtlıysa veya terabaytlarca veriniz varsa kesinti süresini minimize etmek için `--link` parametresini kullanın.

```bash
/usr/lib/postgresql/15/bin/pg_upgrade \
  -b /usr/lib/postgresql/12/bin \
  -B /usr/lib/postgresql/15/bin \
  -d /var/lib/postgresql/12/main \
  -D /var/lib/postgresql/15/main \
  --link
```

> **💡 Uzman Notu (`--link` Nasıl Çalışır?):** > `--link` parametresi kullanıldığında dahi yeni bir data directory (`-D`) belirtmek zorunludur çünkü PostgreSQL'in yeni sürümü kendi yeni sistem kataloglarına ihtiyaç duyar. `--link`, veri dosyalarını kopyalamak yerine işletim sistemi seviyesinde **"Hard Link"** oluşturur. Yani eski ve yeni dizindeki dosyalar diskin üzerindeki aynı fiziksel alana (inode) işaret eder.
>
> **⚠️ KRİTİK UYARI:** Hard link kullanıldığı için dosyalar ortaktır. Yükseltme tamamlanıp yeni sunucu (v15) başlatıldıktan sonra, eski sunucuyu (v12) **ASLA** tekrar başlatmayın. Aksi takdirde veri dosyaları bozulabilir.

### 5. Konfigürasyonların Taşınması ve Port Ayarları

Yeni cluster, varsayılan olarak farklı bir portta (örneğin 5433) veya kendi varsayılan `postgresql.conf` ayarlarıyla açılmaya çalışabilir. Eski sürümdeki (`12/main/`) `postgresql.conf` (özel memory ayarlarınız, work_mem vs.) ve `pg_hba.conf` (erişim kuralları) dosyalarındaki spesifik ayarlarınızı yeni konfigürasyon dosyalarına dikkatlice aktarın.
Eski sunucu 5432'de ise yeni sunucunun konfigürasyonunu da port 5432 olacak şekilde ayarlamayı unutmayın.

### 6. Yeni Servisi Başlatma ve İstatistikleri Güncelleme

Yeni servisi başlatın. Yükseltme işlemi sonrasında Query Planner'ın doğru çalışabilmesi için veritabanı istatistiklerinin toplanması gerekir. `pg_upgrade` bulunduğunuz dizine bunun için bir script bırakmıştır.

```bash
# Servisi başlat
exit  # postgres kullanıcısından çık
sudo systemctl start postgresql@15-main

# İstatistikleri topla (yeniden postgres kullanıcısı ile)
sudo su - postgres
./analyze_new_cluster.sh
```

### 7. Eski Cluster'ı Temizleme (Opsiyonel)

Her şeyin sorunsuz çalıştığından emin olduktan sonra, yine `pg_upgrade` tarafından oluşturulan script ile eski veri dosyalarını silerek disk alanını geri kazanabilirsiniz.

```bash
./delete_old_cluster.sh
```

## ☁️ Bulut (AWS & Azure) Uzman Notları

* **IaaS (AWS EC2, Azure VM):** Eğer PostgreSQL'i sanal makinelerde kendiniz yönetiyorsanız, yukarıdaki süreç birebir geçerlidir. *Uzman tavsiyesi:* Sürüm yükseltmesine başlamadan hemen önce **AWS EBS Snapshot** veya **Azure Managed Disk Snapshot** alın. Eğer yükseltme sırasında bir şey ters giderse, snapshot'tan yeni bir disk oluşturup bağlayarak dakikalar içerisinde hiçbir şey olmamış gibi geri dönebilirsiniz.
* **PaaS (AWS RDS, Aurora, Azure Database for PostgreSQL):** Bu yönetilen servislerde `pg_upgrade` aracı komut satırından manuel olarak çalıştırılmaz. AWS Console, Azure Portal veya CLI araçları (örn: `aws rds modify-db-instance --engine-version 15.x`) üzerinden "Upgrade" işlemi tetiklenir. Bulut sağlayıcı arka planda bu rehberdeki `pg_upgrade` sürecini otomatik ve kontrollü bir şekilde yürütür.
