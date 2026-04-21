# RHEL/CentOS Ortamında `pg_upgrade` ile PostgreSQL Sürüm Yükseltme Rehberi

PostgreSQL veritabanında "Major" (ana) sürüm güncellemeleri (örneğin 12'den 15'e) veritabanı dosyalarının fiziksel formatında değişiklikler içerdiği için basit bir paket güncellemesi ile yapılamaz. Geleneksel `pg_dumpall` / `pg_restore` yöntemi büyük veritabanları için saatler sürebilecekken, **`pg_upgrade`** aracı bu işlemi dakikalar, hatta `--link` modu ile saniyeler içinde tamamlamanızı sağlar.

Bu rehberde, Red Hat, CentOS, Rocky Linux veya Oracle Linux gibi RHEL tabanlı sistemler üzerindeki PostgreSQL sunucularınızı nasıl güvenle yükselteceğinizi adım adım inceleyeceğiz.

## 🛠️ Ön Koşullar ve Hazırlık

Herhangi bir major upgrade işlemine başlamadan önce aşağıdaki adımları eksiksiz tamamlamanız kritiktir:

1. **Kesinlikle Yedek Alın:** Fiziksel bir yedek (örn. `pg_basebackup`) veya sanal/bulut ortamındaysanız sunucu diskinin bir **Snapshot**'ını mutlaka alın.
2. **Disk Alanı Kontrolü:** Eğer `--link` modu kullanmayacaksanız (`copy` modu), veritabanınızın mevcut boyutu kadar sunucuda ek boş disk alanına ihtiyacınız olacaktır.
3. **Eklentiler (Extensions):** `PostGIS`, `pg_stat_statements` gibi eklentiler kullanıyorsanız, yeni sürüm için uyumlu binary kütüphanelerinin (`dnf install postgis33_15` vb.) sisteme kurulduğundan emin olun.

## 🚀 Adım Adım Sürüm Yükseltme Süreci

Aşağıdaki senaryoda mevcut sürümümüzün **12**, hedeflediğimiz yeni sürümün ise **15** olduğunu varsayarak ilerliyoruz.

### 1. Yeni Sürümün Kurulumu ve İnitialize Edilmesi (initdb)

Eski veritabanı çalışmaya devam ederken yeni sürümü sunucuya kurun ve veri dizinini (`/var/lib/pgsql/15/data/`) oluşturmak için başlatın. RHEL sistemlerinde kurulumdan sonra `initdb` manuel tetiklenmelidir.

```bash
sudo dnf install -y postgresql15-server postgresql15-contrib

# Yeni cluster'ı initialize ediyoruz
sudo /usr/pgsql-15/bin/postgresql-15-setup initdb
```

### 2. Servislerin Durdurulması

Veri tutarlılığını sağlamak ve `pg_upgrade`'in dosyalara güvenle müdahale edebilmesi için her iki servisi de durdurun.

```bash
sudo systemctl stop postgresql-12
sudo systemctl stop postgresql-15
```

### 3. Uyumluluk Kontrolü (Dry-Run Modu)

Gerçek yükseltme öncesinde veritabanınızın uyumlu olup olmadığını kontrol etmelisiniz. Bu adım veri üzerinde hiçbir değişiklik yapmaz. Bu işlemi ve sonrasındaki adımları **`postgres`** kullanıcısı ile yapmalıyız.

```bash
sudo su - postgres

/usr/pgsql-15/bin/pg_upgrade \
  -b /usr/pgsql-12/bin \
  -B /usr/pgsql-15/bin \
  -d /var/lib/pgsql/12/data \
  -D /var/lib/pgsql/15/data \
  -c
```

Ekranın sonunda **"Clusters are compatible"** (Kümeler uyumlu) mesajını görüyorsanız her şey yolundadır.

### 4. Asıl Yükseltme İşleminin Başlatılması

Kontrol başarılıysa, `-c` (check) parametresini kaldırıp işlemi başlatın. Kesinti süresini minimize etmek ve disk alanından tasarruf etmek için `--link` parametresini kullanın.

```bash
/usr/pgsql-15/bin/pg_upgrade \
  -b /usr/pgsql-12/bin \
  -B /usr/pgsql-15/bin \
  -d /var/lib/pgsql/12/data \
  -D /var/lib/pgsql/15/data \
  --link
```

> **💡 Uzman Notu (`--link` Nasıl Çalışır?):** > `--link` parametresi kullanıldığında dahi yeni bir data directory (`-D`) belirtmek zorunludur çünkü PostgreSQL'in yeni sürümü kendi yeni sistem kataloglarına ihtiyaç duyar. `--link`, veri dosyalarını kopyalamak yerine işletim sistemi seviyesinde **"Hard Link"** oluşturur. Yani eski ve yeni dizindeki dosyalar diskin üzerindeki aynı fiziksel alana (inode) işaret eder.
>
> **⚠️ KRİTİK UYARI:** Hard link kullanıldığı için dosyalar ortaktır. Yükseltme tamamlanıp yeni sunucu (v15) başlatıldıktan sonra, eski sunucuyu (v12) **ASLA** tekrar başlatmayın. Aksi takdirde veri dosyaları bozulabilir.

### 5. Konfigürasyonların Taşınması

Yeni sürüm, kendi varsayılan `postgresql.conf` ve `pg_hba.conf` ayarlarıyla (standart 5432 portu vs.) kurulmuştur. Eski sürümdeki (`/var/lib/pgsql/12/data/`) özel memory ayarlarınızı (shared_buffers, work_mem vs.) ve erişim kurallarınızı yeni konfigürasyon dosyalarına dikkatlice aktarın.

Eski sunucunun `postgresql.conf` dosyasını doğrudan kopyalamayın, sadece değiştirdiğiniz parametreleri yeni dosyaya uyarlayın.

### 6. Yeni Servisi Başlatma ve İstatistikleri Güncelleme

Yeni servisi başlatın. Yükseltme işlemi sonrasında Query Planner'ın doğru çalışabilmesi için veritabanı istatistiklerinin yeniden toplanması gerekir. `pg_upgrade` işlemi sonrasında `postgres` kullanıcısının bulunduğu dizine bunun için bir script bırakılır.

```bash
# root kullanıcısına dönüp servisi başlatın
exit
sudo systemctl enable postgresql-15
sudo systemctl start postgresql-15
sudo systemctl disable postgresql-12

# İstatistikleri toplayın (yeniden postgres kullanıcısına geçerek)
sudo su - postgres
./analyze_new_cluster.sh
```

### 7. Eski Cluster'ı Temizleme (Opsiyonel)

Her şeyin sorunsuz çalıştığından emin olduktan sonra, yine `pg_upgrade` tarafından oluşturulan temizlik scripti ile eski veri dosyalarını silerek güvenli bir kapanış yapabilirsiniz.

```bash
./delete_old_cluster.sh
```
