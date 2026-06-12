# Oracle 19c Database Failover Adımları (Broker Aktif - DGMGRL)

Failover işlemi, Primary sunucuya erişilemediği veya veritabanının kurtarılamayacak şekilde çöktüğü (Disaster) senaryolarda, Standby veritabanını yeni Primary olarak devreye almak için kullanılır. Broker (DGMGRL) bu süreci otomatikleştirir ve veri kaybını en aza indirmeye çalışır.

---

## 1. DGMGRL Aracına Bağlanma
Primary sunucu çöktüğü için işlemleri **Standby sunucusu** üzerinden gerçekleştireceğiz. Terminal üzerinden Data Guard Broker komut satırına bağlanılır.

```bash
# İşletim sistemi kullanıcısı (oracle) ile:
dgmgrl /
```

---

## 2. Failover İşlemini Başlatma
Standby veritabanını Primary rolüne çekmek için failover komutu çalıştırılır. Broker, Standby üzerinde bulunan tüm logları uygulamaya çalışarak (Complete Failover) veri kaybını sıfıra veya en aza indirmeyi hedefler.

```sql
DGMGRL> FAILOVER TO <standby_db_name>;
-- Örnek: FAILOVER TO DRDB;
```

> **Uyarı (Immediate Failover):** Eğer normal failover komutu takılırsa veya Standby'da logların uygulanmasını beklemeden sistemi anında açmak zorundaysanız `FAILOVER TO <standby_db_name> IMMEDIATE;` komutu kullanılabilir. Ancak bu komut uygulanmamış tüm logları çöpe atar ve **kesin veri kaybına** yol açar. Sadece son çare olarak kullanılmalıdır.

---

## 3. Yeni Konfigürasyonun Kontrolü
İşlem tamamlandıktan sonra yapının durumunu kontrol edin. Eski Primary veritabanı artık yapılandırmada "O disabled_by_user" veya "Needs to be reinstated" gibi bir uyarı statüsünde görünecektir.

```sql
DGMGRL> SHOW CONFIGURATION;
DGMGRL> SHOW DATABASE <yeni_primary_db_name>;
```

---

## 4. OPSIYONEL: Eski Primary Sunucuyu Geri Kazanma (REINSTATE)

Felaket anı atlatıldıktan ve çöken **eski Primary sunucu fiziksel/mantıksal olarak onarıldıktan sonra**, onu yeni yapının Standby veritabanı olarak geri ekleyebilirsiniz. 

**Ön Şart:** Eski Primary veritabanında çökmeden önce `Flashback Database` özelliğinin açık olması zorunludur.

### Adım 4.1: Eski Sunucuyu Mount Modda Açma
Eski sunucudaki arızayı giderdikten sonra, veritabanını sadece `MOUNT` moduna getirin (Kesinlikle OPEN yapmayın).

```sql
# Eski primary sunucusunda:
sqlplus / as sysdba
SQL> STARTUP MOUNT;
```

### Adım 4.2: Reinstate Komutunu Çalıştırma
Yeni Primary veya Standby sunucularından herhangi birinde DGMGRL üzerinden geri kazanım (Reinstate) komutu çalıştırılır.

```sql
DGMGRL> REINSTATE DATABASE <eski_primary_db_name>;
```

> **Arka Planda Ne Olur?**
> Broker, eski primary'yi Failover'ın gerçekleştiği SCN noktasına geri sarar (Flashback), rolünü Physical Standby olarak değiştirir ve yeni Primary'den log almaya/uygulamaya otomatik olarak başlatır.

### Adım 4.3: Son Durum Kontrolü
Reinstate işlemi tamamlandıktan sonra konfigürasyonun tamamen `SUCCESS` durumuna döndüğünden emin olun.

```sql
DGMGRL> SHOW CONFIGURATION;
```
