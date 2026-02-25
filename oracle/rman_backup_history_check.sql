# Ordered by start date / descending

SELECT command_id
             "BACKUP NAME",
         STATUS,
         TO_CHAR (start_time, 'Mon DD,YYYY HH24:MI:SS')
             "START TIME",
              TO_CHAR (end_time, 'Mon DD,YYYY HH24:MI:SS')
             "END TIME",
         time_taken_display
             "TIME TAKEN",
         input_type
             "TYPE",
         output_device_type
             "OUTPUT DEVICES",
         input_bytes_display
             "INPUT SIZE",
             input_bytes_per_sec_display
             "INPUT BYTES PER SECOND",
         output_bytes_display
             "OUTPUT SIZE",
                  output_bytes_per_sec_display
             "OUTPUT BYTES PER SECOND"
    FROM V$RMAN_BACKUP_JOB_DETAILS
   WHERE INPUT_TYPE IN ('DB FULL', 'DB INCR','ARCHIVELOG') --INPUT_TYPE IN ('ARCHIVELOG') --INPUT_TYPE IN ('DATAFILE FULL')
         AND TRUNC (start_time) BETWEEN TRUNC (SYSDATE - 60) AND TRUNC (SYSDATE)         
ORDER BY START_TIME DESC NULLS LAST;


# Which backup has which files?



  SELECT
  j.session_recid      AS job_recid,
  j.session_stamp      AS job_stamp,
  j.command_id         AS job_name,
  j.input_type         AS job_type,
  TO_CHAR(j.start_time,'YYYY-MM-DD HH24:MI:SS') AS start_time,
  TO_CHAR(j.end_time,  'YYYY-MM-DD HH24:MI:SS') AS end_time,
  p.handle             AS piece_file
FROM
  V$RMAN_BACKUP_JOB_DETAILS j
  JOIN V$BACKUP_PIECE_DETAILS p
    ON j.session_key   = p.session_key
   AND j.session_recid = p.session_recid
   AND j.session_stamp = p.session_stamp
WHERE
  j.input_type IN ('DB FULL','DB INCR','ARCHIVELOG')  -- filter types :contentReference[oaicite:1]{index=1}
  AND j.status = 'COMPLETED'
ORDER BY
  j.start_time DESC, p.handle;
