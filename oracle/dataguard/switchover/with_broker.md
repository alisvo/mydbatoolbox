# Oracle 19c Database Switchover Adımları (Broker Aktif - DGMGRL)

Bu doküman, Oracle 19c mimarisinde Data Guard Broker (DGMGRL) kullanılan ortamlarda switchover işlemlerini gerçekleştirmek için kullanılacak operasyon kılavuzudur. Broker, süreci otomatikleştirerek manuel hata riskini en aza indirir.

---

## 1. İşlem Öncesi Kontroller (Pre-checks)

Switchover işlemine başlamadan önce Data Guard yapısının sağlıklı olduğundan ve senkronizasyonun tam olduğundan emin olunmalıdır.

### 1.1. DGMGRL Aracına Bağlanma
Primary veya Standby sunucularından birinde terminal üzerinden Data Guard Broker komut satırına bağlanılır.
```bash
# İşletim sistemi kullanıcısı (oracle) ile doğrudan bağlanmak için:
dgmgrl /

# Veya TNS ile bağlanmak için:
dgmgrl sys/<sifre>@<primary_tns_name>
```

### 1.2. Konfigürasyon Durumunu Kontrol Etme
Genel yapının durumunu görmek için aşağıdaki komut çalıştırılır. Beklenen çıktı **`SUCCESS`** olmalıdır.
```sql
DGMGRL> SHOW CONFIGURATION;
```

### 1.3. Veritabanlarının Detaylı Durum Kontrolü
Primary ve Standby veritabanlarında hata (Warning/Error) olup olmadığı kontrol edilir.
```sql
DGMGRL> SHOW DATABASE <primary_db_name>;
DGMGRL> SHOW DATABASE <standby_db_name>;
```

### 1.4. Switchover İçin Doğrulama (Validate)
Standby veritabanının switchover işlemi için hazır olup olmadığını doğrulamak (simulate etmek) için aşağıdaki komut kullanılır.
Beklenen çıktı: **`Ready for Switchover: YES`**
```sql
DGMGRL> VALIDATE DATABASE <standby_db_name>;
```
> **Not:** Eğer bu adımda eksik tempfile, uygulanmamış log veya network problemi gibi uyarılar çıkarsa, switchover komutunu çalıştırmadan önce bu sorunlar giderilmelidir.

---

## 2. Switchover İşlemi (Execution)

Tüm doğrulamalar başarılı ("SUCCESS" ve "Ready for Switchover: YES") ise, switchover işlemi tek bir komutla başlatılır.

### 2.1. Switchover Komutunun Çalıştırılması
Hedef (yeni primary olacak) standby veritabanının ismi yazılarak işlem tetiklenir.
```sql
DGMGRL> SWITCHOVER TO <standby_db_name>;
-- Örnek: SWITCHOVER TO DRDB;
```

> **İşlem Sırasında Arka Planda Neler Olur?**
> Broker otomatik olarak:
> 1. Eski primary veritabanını kapatır ve Standby (Mount) modunda geri açar.
> 2. Kalan tüm logları eski primary'den yeni primary'ye taşır ve uygular.
> 3. Eski standby veritabanını Primary rolüne çeker ve (Open) modunda açar.
> 4. Veri akışını (Redo Transport) yeni primary'den yeni standby'a doğru tersine çevirir.

---

## 3. Switchover Sonrası Kontroller (Post-checks)

İşlem tamamlandıktan sonra (komut satırı size geri döndüğünde) yapının yeni durumunu doğrulamak gerekir.

### 3.1. Yeni Konfigürasyon Durumu
Rollerin başarıyla değiştiğini ve yeni yapının **`SUCCESS`** durumunda olduğunu kontrol edin.
```sql
DGMGRL> SHOW CONFIGURATION;
```
*(Çıktıda eski standby'ın artık "Primary database", eski primary'nin ise "Physical standby database" olarak göründüğünden emin olun.)*

### 3.2. Yeni Veritabanı Rollerinin Kontrolü
Veritabanlarının detaylı durumlarına tekrar bakılır.
```sql
DGMGRL> SHOW DATABASE <yeni_primary_db_name>;
DGMGRL> SHOW DATABASE <yeni_standby_db_name>;
```

### 3.3. Veri Akış Testi (SQLPlus Üzerinden - Opsiyonel)
Redo aktarımının sorunsuz başladığından %100 emin olmak için yeni Primary üzerinde manuel log switch yapılabilir.
```bash
# Yeni Primary sunucusunda SQL*Plus ile bağlanıp log switch tetikleyin:
sqlplus / as sysdba
SQL> ALTER SYSTEM SWITCH LOGFILE;
```
Ardından DGMGRL üzerinden veya Standby sunucusunda SQL*Plus ile logların ulaşıp apply edildiği kontrol edilebilir.
