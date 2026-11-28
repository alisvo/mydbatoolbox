-- 1) RMAN job geçmişi (son 60 gün), en yeni önce
--    Not: Geçmişin ne kadar geriye gittiği CONTROL_FILE_RECORD_KEEP_TIME'a bağlı
--    (varsayılan 7 gün). Daha uzun geçmiş için catalog'daki RC_RMAN_BACKUP_JOB_DETAILS.
--    Diğer tipler için: 'DATAFILE FULL', 'DATAFILE INCR', 'CONTROLFILE', 'SPFILE' ...
SELECT j.session_key,
       j.command_id                                   AS "BACKUP NAME",
       j.input_type                                   AS "TYPE",
       j.status,
       TO_CHAR(j.start_time, 'YYYY-MM-DD HH24:MI:SS') AS "START TIME",
       TO_CHAR(j.end_time,   'YYYY-MM-DD HH24:MI:SS') AS "END TIME",
       j.time_taken_display                           AS "TIME TAKEN",
       j.output_device_type                           AS "OUTPUT DEVICES",
       j.input_bytes_display                          AS "INPUT SIZE",
       j.output_bytes_display                         AS "OUTPUT SIZE",
       ROUND(j.compression_ratio, 2)                  AS "COMPR RATIO",
       j.input_bytes_per_sec_display                  AS "INPUT/SEC",
       j.output_bytes_per_sec_display                 AS "OUTPUT/SEC"
  FROM v$rman_backup_job_details j
 WHERE j.input_type IN ('DB FULL', 'DB INCR', 'ARCHIVELOG')
   AND j.start_time >= TRUNC(SYSDATE) - 60
 ORDER BY j.start_time DESC;


-- 2) Hangi backup job'u hangi piece dosyalarını üretti?
--    piece_status: A=Available, X=Expired, D=Deleted, U=Unavailable
--    Sadece restore'da kullanılabilir piece'ler için: AND p.status = 'A'
SELECT j.session_key,
       j.command_id                                   AS job_name,
       j.input_type                                   AS job_type,
       j.status                                       AS job_status,
       TO_CHAR(j.start_time, 'YYYY-MM-DD HH24:MI:SS') AS job_start,
       p.bs_key,
       p.piece#,
       p.copy#,
       DECODE(s.backup_type, 'D', 'FULL', 'I', 'INCR', 'L', 'ARCHIVELOG',
              s.backup_type)                          AS piece_content,
       s.incremental_level                            AS incr_lvl,
       s.controlfile_included                         AS cf_incl,
       p.tag,
       p.device_type,
       p.status                                       AS piece_status,
       p.size_bytes_display                           AS piece_size,
       TO_CHAR(p.completion_time, 'YYYY-MM-DD HH24:MI:SS') AS piece_done,
       p.handle                                       AS piece_file
  FROM v$rman_backup_job_details j
  JOIN v$backup_piece_details    p ON p.session_key = j.session_key
  JOIN v$backup_set              s ON s.set_stamp   = p.set_stamp
                                  AND s.set_count   = p.set_count
 WHERE j.input_type IN ('DB FULL', 'DB INCR', 'ARCHIVELOG')
   AND j.status LIKE 'COMPLETED%'       -- COMPLETED WITH WARNINGS da dahil
   AND j.start_time >= TRUNC(SYSDATE) - 14
 ORDER BY j.start_time DESC, p.bs_key, p.piece#, p.copy#;
