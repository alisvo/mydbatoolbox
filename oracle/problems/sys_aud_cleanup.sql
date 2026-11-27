-- =====================================================================
-- SYS.AUD$ temizliği (standart / traditional audit trail)
-- =====================================================================
-- !!! Bu dosya bir runbook'tur. Tamamını tek seferde (@dosya / F5) ÇALIŞTIRMAYIN.
--     Bölümleri sırayla ve tek tek çalıştırın. SYS (AS SYSDBA) ile bağlanın.
--
--   0) Kontroller ve değişkenler          -> her zaman çalıştırın
--   A) Büyük birikimi temizleme           -> CTAS + TRUNCATE + geri yükleme
--   A2) AUD$'ı SYSTEM'den taşıma          -> A'dan sonra (tablo küçükken)
--   B) Kalıcı otomatik temizlik           -> DBMS_AUDIT_MGMT + scheduler job
--   C) Alternatif: kesintisiz toplu silme -> A uygun değilse (DBMS_PARALLEL_EXECUTE)
--
-- Hangi yöntem?
--   * Silinecek kayıt oranı yüksekse (örn. 4 yıl birikmiş, 6 ay tutulacak): A.
--     Az veriyi kopyalamak, çok veriyi silmekten çok daha hızlı ve az redo üretir.
--     Üstelik TRUNCATE HWM'yi sıfırlar ve alan gerçekten serbest kalır.
--   * Kısa da olsa audit kaydı kaybı kabul edilemiyorsa: C.
--   * Temizlikten sonra birikimin tekrar oluşmaması için: B.
--
-- Not: "ROWNUM <= n" ile döngü içinde DELETE yöntemi büyük tablolarda önerilmez.
--      AUD$'ta index olmadığı için her tur tabloyu baştan tarar. Silinen bloklar
--      HWM altında boş kaldığından her tur bir öncekinden yavaş olur.
--      Ayrıca DELETE tablespace'te alan geri kazandırmaz.
-- =====================================================================


-- =====================================================================
-- 0) KONTROLLER VE DEĞİŞKENLER
-- =====================================================================
SET PAGES 999
SET LINES 300
SET VERIFY OFF

-- Saklanacak süre (ay)
DEFINE RETENTION_MONTHS = 6

-- Sınır tarihi bir kez hesaplanır ve tüm bölümlerde aynı değer kullanılır.
-- Not: ntimestamp# UTC tutar, SYSDATE yereldir. Aradaki birkaç saatlik fark
--      retention açısından önemsizdir.
COL CUTOFF NEW_VALUE CUTOFF
SELECT TO_CHAR(ADD_MONTHS(SYSDATE, -&RETENTION_MONTHS), 'YYYY-MM-DD HH24:MI:SS') CUTOFF FROM DUAL;

-- SYSTEM tablespace'teki en büyük segmentler
COL OWNER FOR A10
COL SEGMENT_NAME FOR A30
COL SEGMENT_TYPE FOR A15
COL TABLESPACE_NAME FOR A15
COL MB FOR 9999999
SELECT OWNER,
       SEGMENT_NAME,
       SEGMENT_TYPE,
       ROUND(BYTES/1024/1024) MB
FROM   DBA_SEGMENTS
WHERE  TABLESPACE_NAME = 'SYSTEM'
ORDER  BY BYTES DESC
FETCH FIRST 5 ROWS ONLY;

-- AUD$ / FGA_LOG$ ve LOB segmentlerinin boyutu ve bulunduğu tablespace
SELECT S.OWNER,
       S.SEGMENT_NAME,
       S.SEGMENT_TYPE,
       S.TABLESPACE_NAME,
       ROUND(S.BYTES/1024/1024) MB
FROM   DBA_SEGMENTS S
WHERE  S.OWNER = 'SYS'
AND   (S.SEGMENT_NAME IN ('AUD$', 'FGA_LOG$')
       OR S.SEGMENT_NAME IN (SELECT L.SEGMENT_NAME
                             FROM   DBA_LOBS L
                             WHERE  L.OWNER = 'SYS'
                             AND    L.TABLE_NAME IN ('AUD$', 'FGA_LOG$')))
ORDER  BY S.BYTES DESC;

-- Kayıt dağılımı: toplam / silinecek / kalacak (full scan yapar, büyük tabloda sürebilir)
SELECT COUNT(*)                                                                         TOTAL_ROWS,
       SUM(CASE WHEN NTIMESTAMP# <  TO_DATE('&CUTOFF','YYYY-MM-DD HH24:MI:SS') THEN 1 ELSE 0 END) TO_DELETE,
       SUM(CASE WHEN NTIMESTAMP# >= TO_DATE('&CUTOFF','YYYY-MM-DD HH24:MI:SS') THEN 1 ELSE 0 END) TO_KEEP,
       MIN(NTIMESTAMP#)                                                                 OLDEST,
       MAX(NTIMESTAMP#)                                                                 NEWEST
FROM   SYS.AUD$;

-- Unified auditing açık mı? (12c+). TRUE ise AUDSYS.AUD$UNIFIED de dolu olabilir;
-- bu dosyadaki A/C bölümleri ona dokunmaz, sadece DBMS_AUDIT_MGMT ile temizlenir (bkz. B).
COL PARAMETER FOR A20
COL VALUE FOR A10
SELECT PARAMETER, VALUE FROM V$OPTION WHERE PARAMETER = 'Unified Auditing';

SELECT OWNER, SEGMENT_NAME, SEGMENT_TYPE, TABLESPACE_NAME, ROUND(SUM(BYTES)/1024/1024) MB
FROM   DBA_SEGMENTS
WHERE  OWNER = 'AUDSYS'
GROUP  BY OWNER, SEGMENT_NAME, SEGMENT_TYPE, TABLESPACE_NAME
ORDER  BY MB DESC;

-- Mevcut DBMS_AUDIT_MGMT yapılandırması (daha önce kurulmuş mu?)
COL PARAMETER_NAME FOR A30
COL PARAMETER_VALUE FOR A30
COL AUDIT_TRAIL FOR A30
SELECT PARAMETER_NAME, PARAMETER_VALUE, AUDIT_TRAIL FROM DBA_AUDIT_MGMT_CONFIG_PARAMS ORDER BY AUDIT_TRAIL, PARAMETER_NAME;
SELECT * FROM DBA_AUDIT_MGMT_LAST_ARCH_TS;
SELECT * FROM DBA_AUDIT_MGMT_CLEANUP_JOBS;


-- =====================================================================
-- A) BÜYÜK BİRİKİMİ TEMİZLEME: CTAS + TRUNCATE + GERİ YÜKLEME
-- =====================================================================
-- Ön koşullar:
--   * Bakım penceresinde yapın. A1 ile A4 arasında oluşan audit kayıtları kaybolabilir
--     (A3 bu aralığı birkaç saniyeye indirir).
--   * Saklanacak veri kadar boş alanı olan bir tablespace seçin (aşağıda USERS).
--   * FORCE LOGGING açıksa (Data Guard) NOLOGGING etkisizdir; redo/arşiv alanını kontrol edin.
--   * Eski kayıtların arşivlenmesi gerekiyorsa önce A0'ı çalıştırın.

-- A0) (Opsiyonel) Silinecek kayıtları arşivleme.
--     expdp SYS şemasındaki nesneleri export etmez; bu yüzden önce başka bir şemaya kopyalanır.
-- CREATE TABLE SYSTEM.AUD_ARCHIVE TABLESPACE USERS NOLOGGING AS
--   SELECT * FROM SYS.AUD$ WHERE NTIMESTAMP# < TO_DATE('&CUTOFF','YYYY-MM-DD HH24:MI:SS');
-- $ expdp system tables=SYSTEM.AUD_ARCHIVE directory=DATA_PUMP_DIR dumpfile=aud_archive.dmp logfile=aud_archive.log
-- DROP TABLE SYSTEM.AUD_ARCHIVE PURGE;

-- A1) Saklanacak kayıtları ayır
CREATE TABLE SYSTEM.AUD_KEEP TABLESPACE USERS NOLOGGING AS
  SELECT * FROM SYS.AUD$ WHERE NTIMESTAMP# >= TO_DATE('&CUTOFF','YYYY-MM-DD HH24:MI:SS');

-- A2) Kontrol: bu sayı 0) bölümündeki TO_KEEP ile uyumlu olmalı
SELECT COUNT(*) KEEP_ROWS, MIN(NTIMESTAMP#) OLDEST, MAX(NTIMESTAMP#) NEWEST FROM SYSTEM.AUD_KEEP;

-- A3) A1'den bu yana yazılan kayıtları da ekle (kayıp aralığını daraltır).
--     A4'ü bunun hemen ardından çalıştırın.
INSERT INTO SYSTEM.AUD_KEEP
  SELECT * FROM SYS.AUD$ WHERE NTIMESTAMP# > (SELECT MAX(NTIMESTAMP#) FROM SYSTEM.AUD_KEEP);
COMMIT;

-- A4) Tabloyu boşalt: HWM sıfırlanır, extentler serbest kalır
TRUNCATE TABLE SYS.AUD$;

-- A5) Saklanan kayıtları geri yükle
INSERT /*+ APPEND */ INTO SYS.AUD$ SELECT * FROM SYSTEM.AUD_KEEP;
COMMIT;

-- A6) Kontrol: AUD$'taki satır sayısı en az KEEP_ROWS kadar olmalı
--     (aradan yeni kayıtlar yazıldıysa biraz fazla olabilir)
SELECT (SELECT COUNT(*) FROM SYSTEM.AUD_KEEP) KEEP_ROWS,
       (SELECT COUNT(*) FROM SYS.AUD$)        AUD_ROWS
FROM   DUAL;

-- A7) Geçici tabloyu kaldır (A6 doğrulandıktan sonra)
DROP TABLE SYSTEM.AUD_KEEP PURGE;


-- =====================================================================
-- A2) AUD$'I SYSTEM TABLESPACE'TEN TAŞIMA
-- =====================================================================
-- AUD$'ın SYSTEM'de büyümesi SYSTEM tablespace'in dolmasına yol açar. SYSAUX'a
-- veya ayrı bir tablespace'e taşıyın. Taşıma tabloyu fiziksel olarak kopyalar,
-- bu yüzden A'dan sonra, tablo küçükken yapın.
-- Hedef tablespace ASSM (automatic segment space management) olmalıdır.
BEGIN
  DBMS_AUDIT_MGMT.SET_AUDIT_TRAIL_LOCATION(
    audit_trail_type           => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,   -- FGA_LOG$ için: AUDIT_TRAIL_FGA_STD
    audit_trail_location_value => 'SYSAUX');
END;
/

-- Kontrol
SELECT OWNER, SEGMENT_NAME, TABLESPACE_NAME FROM DBA_SEGMENTS WHERE OWNER = 'SYS' AND SEGMENT_NAME = 'AUD$';


-- =====================================================================
-- B) KALICI OTOMATİK TEMİZLİK: DBMS_AUDIT_MGMT
-- =====================================================================
-- B1) Temizlik altyapısını başlat (bir kez).
--     Not: Bazı sürümlerde INIT_CLEANUP, AUD$ SYSTEM'deyse onu SYSAUX'a taşır.
--     Büyük tabloda uzun sürer; bu yüzden önce A'yı yapın.
BEGIN
  IF NOT DBMS_AUDIT_MGMT.IS_CLEANUP_INITIALIZED(DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD) THEN
    DBMS_AUDIT_MGMT.INIT_CLEANUP(
      audit_trail_type         => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,
      default_cleanup_interval => 24);
  END IF;
END;
/

-- B2) Günlük job: sınır zamanı güncelle, sonra o zamandan eski kayıtları sil.
--     DBMS_AUDIT_MGMT kendi içinde batch'ler halinde siler (DB_DELETE_BATCH_SIZE, varsayılan 10000).
--     Sınır zaman, veritabanı audit trail'leri için UTC olarak verilir.
--     Unified auditing için iki yerde AUDIT_TRAIL_AUD_STD yerine AUDIT_TRAIL_UNIFIED kullanın
--     (unified için B1 gerekmez).
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'SYS.AUD_STD_PURGE_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[BEGIN
                            DBMS_AUDIT_MGMT.SET_LAST_ARCHIVE_TIMESTAMP(
                              audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,
                              last_archive_time => CAST(ADD_MONTHS(SYS_EXTRACT_UTC(SYSTIMESTAMP), -&RETENTION_MONTHS) AS TIMESTAMP));
                            DBMS_AUDIT_MGMT.CLEAN_AUDIT_TRAIL(
                              audit_trail_type        => DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD,
                              use_last_arch_timestamp => TRUE);
                          END;]',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0; BYSECOND=0',
    enabled         => TRUE,
    comments        => 'AUD$ retention purge (&RETENTION_MONTHS months)');
END;
/

-- B3) Job'ı hemen bir kez çalıştırıp sonucu kontrol et
EXEC DBMS_SCHEDULER.RUN_JOB('SYS.AUD_STD_PURGE_JOB', use_current_session => TRUE);

COL JOB_NAME FOR A25
COL STATUS FOR A12
COL ADDITIONAL_INFO FOR A80
SELECT JOB_NAME, STATUS, ACTUAL_START_DATE, RUN_DURATION, ADDITIONAL_INFO
FROM   DBA_SCHEDULER_JOB_RUN_DETAILS
WHERE  JOB_NAME = 'AUD_STD_PURGE_JOB'
ORDER  BY ACTUAL_START_DATE DESC
FETCH FIRST 5 ROWS ONLY;

SELECT * FROM DBA_AUDIT_MGMT_LAST_ARCH_TS;

-- Geri almak için:
-- EXEC DBMS_SCHEDULER.DROP_JOB('SYS.AUD_STD_PURGE_JOB');
-- EXEC DBMS_AUDIT_MGMT.CLEAR_LAST_ARCHIVE_TIMESTAMP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD);
-- EXEC DBMS_AUDIT_MGMT.DEINIT_CLEANUP(DBMS_AUDIT_MGMT.AUDIT_TRAIL_AUD_STD);


-- =====================================================================
-- C) ALTERNATİF: KESİNTİSİZ TOPLU SİLME (DBMS_PARALLEL_EXECUTE)
-- =====================================================================
-- A'daki kısa kayıp aralığı kabul edilemiyorsa kullanın. Tablo ROWID aralıklarına
-- bölünür ve her aralık ayrı silinip commit edilir. Böylece tablo baştan tekrar tekrar
-- taranmaz, iş yarıda kalırsa kaldığı yerden devam edebilir.
-- Dezavantajları: DELETE olduğu için yüksek redo üretir ve alan geri kazandırmaz.
-- Önce test ortamında deneyin.

-- C1) Görevi oluştur ve tabloyu parçalara böl (chunk_size = blok sayısı)
BEGIN
  DBMS_PARALLEL_EXECUTE.CREATE_TASK(task_name => 'AUD_PURGE');
  DBMS_PARALLEL_EXECUTE.CREATE_CHUNKS_BY_ROWID(
    task_name   => 'AUD_PURGE',
    table_owner => 'SYS',
    table_name  => 'AUD$',
    by_row      => FALSE,
    chunk_size  => 10000);
END;
/

-- C2) Çalıştır. parallel_level redo üretim hızını belirler; arşiv/Data Guard durumuna göre 1-4 arası seçin.
BEGIN
  DBMS_PARALLEL_EXECUTE.RUN_TASK(
    task_name      => 'AUD_PURGE',
    sql_stmt       => q'[DELETE FROM SYS.AUD$
                         WHERE  ROWID BETWEEN :start_id AND :end_id
                         AND    NTIMESTAMP# < TO_DATE('&CUTOFF','YYYY-MM-DD HH24:MI:SS')]',
    language_flag  => DBMS_SQL.NATIVE,
    parallel_level => 2);
END;
/

-- C3) İlerleme (başka bir oturumdan izlenebilir)
SELECT STATUS, COUNT(*) CHUNKS
FROM   DBA_PARALLEL_EXECUTE_CHUNKS
WHERE  TASK_NAME = 'AUD_PURGE'
GROUP  BY STATUS;

SELECT TASK_NAME, STATUS FROM DBA_PARALLEL_EXECUTE_TASKS WHERE TASK_NAME = 'AUD_PURGE';

-- C4) Hata/kesinti olduysa (STATUS = FINISHED_WITH_ERROR / CRASHED) kaldığı yerden devam et
-- EXEC DBMS_PARALLEL_EXECUTE.RESUME_TASK('AUD_PURGE');

-- C5) Bitince görevi kaldır
EXEC DBMS_PARALLEL_EXECUTE.DROP_TASK('AUD_PURGE');
