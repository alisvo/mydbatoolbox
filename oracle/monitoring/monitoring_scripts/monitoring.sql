-- =============================================================================
-- monitoring.sql
-- Oracle database health report (incl. Data Guard), called by monitoring.sh.
-- Location : /home/oracle/scripts/monitoring
-- Runtime  : monitoring.sh + monitoring.sql. Nothing else is read at run time.
-- History  : CHANGELOG.txt in the same directory (documentation only).
--
-- VERSION - single source of truth for the whole package. monitoring.sh reads
-- this DEFINE, so the shell and the SQL can never report different versions.
-- On every change: bump it, describe the change in the block below, and move
-- the previous block to the top of CHANGELOG.txt.
-- =============================================================================
DEFINE mon_version = "2.3.1"

-- -----------------------------------------------------------------------------
-- THIS RELEASE ONLY - full history is in CHANGELOG.txt
-- -----------------------------------------------------------------------------
-- 2.3.1  2026-09-14
--        ! Removed the "Standby Apply Progress seen from Primary" section. It
--          compared ARCHIVED_SEQ# with APPLIED_SEQ# in V$ARCHIVE_DEST_STATUS,
--          but APPLIED_SEQ# on the primary is only refreshed when the standby
--          acknowledges, and real-time apply works from the standby redo logs
--          before a log is archived. A healthy DR node therefore drifted by a
--          few sequences and tripped the 3-log threshold (41921 vs 41917).
--          Apply progress is now measured only on the standby, where it is a
--          live figure: apply lag in minutes plus the local sequence gap.
--          Transport health stays on the primary (destination status/gap_status).
-- -----------------------------------------------------------------------------

-- 1. SETUP (HTML IS OFF INITIALLY)
SET TERMOUT ON
SET TRIMSPOOL ON
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 2000
SET PAGESIZE 9999
SET SERVEROUTPUT ON SIZE UNLIMITED
SET MARKUP HTML OFF

-- -----------------------------------------------------------------------------
-- 1b. THRESHOLDS  (tune here, no need to touch the queries)
-- -----------------------------------------------------------------------------
-- IMPORTANT: never put an inline comment on a DEFINE line. SQLPlus takes
-- everything after the "=" as the value, so the comment text would end up
-- inside the WHERE clauses and comment out the rest of the line.
--
-- dg_transport_lag_min : alert if redo transport lag exceeds N minutes
-- dg_apply_lag_min     : alert if redo apply lag exceeds N minutes
-- dg_seq_gap           : alert if standby is more than N archive logs behind
-- dg_stat_stale_min    : alert if v$dataguard_stats has not refreshed for N minutes
-- dg_msg_window_min    : look back N minutes in v$dataguard_status. Set equal to
--                        the cron interval (30) so each message mails ONCE. A
--                        larger value re-sends the same message on the next run.
-- dg_msg_severity      : which v$dataguard_status severities are worth a mail.
--                        Warning is deliberately EXCLUDED - it repeats every
--                        30 min for transient conditions. To include it again:
--                        DEFINE dg_msg_severity = "'Error','Fatal','Warning'"
-- dg_daily_from /       : window in which the CONFIG level checks are allowed to
-- dg_daily_to             report (standby redo logs missing, force logging off).
--                         Those two stay true until a DBA fixes them, so without
--                         this gate they would mail 48 times a day. The window is
--                         30 minutes wide = exactly one cron run, whatever minute
--                         the crontab entry actually fires on. DB server time.
DEFINE dg_daily_from = "'0800'"
DEFINE dg_daily_to = "'0829'"
DEFINE dg_msg_severity = "'Error','Fatal'"
DEFINE dg_transport_lag_min = 15
DEFINE dg_apply_lag_min = 30
DEFINE dg_seq_gap = 3
DEFINE dg_stat_stale_min = 30
DEFINE dg_msg_window_min = 30

-- 2. GET VARIABLES (Silent Mode - No Empty Tables)
COLUMN INSTANCE_NAME NEW_VALUE INSTANCE_NAME NOPRINT;
COLUMN host_name NEW_VALUE host_name NOPRINT;
select INSTANCE_NAME, TRIM(HOST_NAME) host_name from v$instance;

COLUMN current_database NEW_VALUE current_database NOPRINT;
SELECT rpad(name, 17) current_database FROM v$database;

COLUMN current_date NEW_VALUE current_date NOPRINT;
ALTER session set nls_date_format='DD-MON-YYYY HH24:MI:SS';
SELECT sysdate current_date FROM v$database;

-- -----------------------------------------------------------------------------
-- 2b. DATA GUARD / ROLE DETECTION
--     Every value below is guaranteed NOT NULL, otherwise SQLPlus would stop
--     and prompt for input (which would hang / fail under cron).
-- -----------------------------------------------------------------------------
COLUMN db_role      NEW_VALUE db_role      NOPRINT;
COLUMN db_open_mode NEW_VALUE db_open_mode NOPRINT;
COLUMN db_uname NEW_VALUE db_uname NOPRINT;
SELECT database_role db_role,
       open_mode     db_open_mode,
       db_unique_name db_uname
  FROM v$database;

-- dg_enabled = YES when this database takes part in a Data Guard configuration.
-- On a standalone (non-DG) database it is NO and every DG check below returns
-- zero rows, so nothing is ever mailed.
COLUMN dg_enabled NEW_VALUE dg_enabled NOPRINT;
SELECT CASE
          WHEN TRIM('&db_role') <> 'PRIMARY'                                          THEN 'YES'
          WHEN (SELECT COUNT(*) FROM v$archive_dest
                 WHERE target = 'STANDBY' AND destination IS NOT NULL) > 0      THEN 'YES'
          WHEN (SELECT COUNT(*) FROM v$dataguard_config) > 1                    THEN 'YES'
          ELSE 'NO'
       END dg_enabled
  FROM dual;

-- 3. MANUALLY PRINT HTML HEADER & CSS
-- We print this manually so SQLPlus doesn't add <br> tags inside the CSS
PROMPT <html>
PROMPT <head>
PROMPT <style type='text/css'>
PROMPT body {font:10pt Arial,Helvetica,sans-serif; color:black; background:white;}
PROMPT table {border-collapse:collapse; width:95%; border:1px solid #ccc; margin-bottom:20px;}
PROMPT th {background:#005c99; color:white; padding:8px; border:1px solid #ccc; text-align:left;}
PROMPT td {padding:5px; border:1px solid #ccc;}
PROMPT h3 {color:#005c99; border-bottom: 2px solid #005c99; padding-bottom: 5px; margin-top: 30px;}
PROMPT h3.dg {color:#8a4b00; border-bottom: 2px solid #8a4b00;}
PROMPT .log-text {font-family: 'Courier New', monospace; background: #f4f4f4; padding: 10px; border: 1px solid #ddd;}
PROMPT </style>
PROMPT </head>
PROMPT <body>

PROMPT <h2>Database Health Report: &INSTANCE_NAME on &host_name</h2>
PROMPT <b>Host:</b> &host_name | <b>Instance:</b> &INSTANCE_NAME | <b>DB Unique Name:</b> &db_uname
PROMPT <br><b>Date:</b> &current_date
-- NOTE: never write HTML entities such as the ampersand-nbsp form in a PROMPT
-- line - SQLPlus would treat it as a substitution variable and stop to prompt.
PROMPT <br><b>Role:</b> &db_role | <b>Open Mode:</b> &db_open_mode | <b>Data Guard:</b> &dg_enabled
PROMPT <br><span style='color:#777'>monitoring release &mon_version</span>
PROMPT <hr>

-- 4. TURN ON HTML FOR DATA TABLES
-- HEAD "" BODY "" prevents it from printing a second set of <html><body> tags
SET MARKUP HTML ON HEAD "" BODY "" TABLE "border='1'" ENTMAP OFF

-- =============================================================================
-- BEGIN REPORT
-- =============================================================================

PROMPT <h3>Tablespace Usage (>90%)</h3>
PROMPT <div class='log-text'><pre>

-- Tablespace usage needs DBA_DATA_FILES / DBA_FREE_SPACE, and those are only
-- readable when the database is OPEN. On a MOUNTED physical standby a static
-- reference would raise ORA-01219 at PARSE time - a runtime IF cannot prevent
-- that, which is why the query is opened with dynamic SQL. The block simply
-- returns before touching the dictionary when the database is not open.
DECLARE
   TYPE t_refcur IS REF CURSOR;
   c_ts      t_refcur;
   v_sql     VARCHAR2(4000);
   v_name    VARCHAR2(60);
   v_alloc   NUMBER;
   v_free    NUMBER;
   v_max     NUMBER;
   v_pct     NUMBER;
   v_header  BOOLEAN := FALSE;
BEGIN
   IF TRIM('&db_open_mode') NOT LIKE 'READ%' THEN
      DBMS_OUTPUT.PUT_LINE('Skipped: database is not open, dictionary views are not available.');
      RETURN;
   END IF;

   v_sql :=
      'SELECT a1.tablespace_name,
              a1.size_mb,
              NVL(a2.free_mb, 0),
              a1.max_size_mb,
              NVL(ROUND((a1.size_mb - NVL(a2.free_mb,0)) * 100 / a1.max_size_mb, 2), 100)
         FROM (SELECT b.tablespace_name,
                      SUM(b.max_size_mb) max_size_mb,
                      SUM(b.size_mb)     size_mb
                 FROM (SELECT tablespace_name,
                              CASE WHEN a.maxbytes = 0 THEN ROUND(BYTES/1024/1024, 2)
                                   WHEN a.maxbytes > 0 THEN ROUND(maxbytes/1024/1024, 2)
                              END max_size_mb,
                              ROUND(BYTES/1024/1024, 2) size_mb
                         FROM dba_data_files a) b
                GROUP BY b.tablespace_name) a1,
              (SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024, 2) free_mb
                 FROM dba_free_space
                GROUP BY tablespace_name) a2
        WHERE a1.tablespace_name = a2.tablespace_name(+)
          AND a1.tablespace_name NOT IN (''UNDOTBS1'',''UNDOTBS2'')
          AND NVL(ROUND((a1.size_mb - NVL(a2.free_mb,0)) * 100 / a1.max_size_mb, 2), 100) > 90
        ORDER BY 5 DESC';

   OPEN c_ts FOR v_sql;
   LOOP
      FETCH c_ts INTO v_name, v_alloc, v_free, v_max, v_pct;
      EXIT WHEN c_ts%NOTFOUND;

      IF NOT v_header THEN
         DBMS_OUTPUT.PUT_LINE(RPAD('TABLESPACE', 32) || LPAD('ALLOC_MB', 14)
                           || LPAD('FREE_MB', 14) || LPAD('MAX_MB', 14)
                           || LPAD('PCT_USED', 10));
         DBMS_OUTPUT.PUT_LINE(RPAD('-', 84, '-'));
         v_header := TRUE;
      END IF;

      DBMS_OUTPUT.PUT_LINE(RPAD(v_name, 32)
                        || LPAD(TO_CHAR(v_alloc, '99999999990'), 14)
                        || LPAD(TO_CHAR(v_free,  '99999999990'), 14)
                        || LPAD(TO_CHAR(v_max,   '99999999990'), 14)
                        || LPAD(TO_CHAR(v_pct,   '990.99'), 10)
                        || '   SEND_MAIL');
   END LOOP;
   CLOSE c_ts;
END;
/
PROMPT </pre></div>


PROMPT <h3>ASM Usage - DATA and FRA (>90%)</h3>
select NAME, STATE, TOTAL_MB, USABLE_FILE_MB,
       100 - ROUND(USABLE_FILE_MB*100/TOTAL_MB) PCT_OF_TOTAL_USE,
       'SEND_MAIL' mail_check
  from v$asm_diskgroup
where 100 - ROUND(USABLE_FILE_MB*100/TOTAL_MB) > 90
  and NAME IN ('DATA','FRA')
order by 100 - ROUND(USABLE_FILE_MB*100/TOTAL_MB) desc;


PROMPT <h3>Recovery Area Usage (>90%)</h3>
SELECT name,
       ceil( space_limit / 1024 / 1024) SIZE_M,
       ceil( space_used  / 1024 / 1024) USED_M,
       ceil( space_reclaimable  / 1024 / 1024) RECLAIMABLE_M,
       decode( nvl( space_used, 0), 0, 0, ceil ( ( ( space_used - space_reclaimable ) / space_limit) * 100) ) PCT_USED,
       'SEND_MAIL' mail_check
  FROM v$recovery_file_dest
WHERE decode( nvl( space_used, 0), 0, 0, ceil ( ( ( space_used - space_reclaimable ) / space_limit) * 100) ) > 90
ORDER BY name;


PROMPT <h3>Backup Issues (Last 1 Hour) </h3>
SELECT NVL(object_type, operation) operation,
       mbytes_processed,
       ROUND(input_bytes / 1024 / 1024, 2) input_mb,
       ROUND(output_bytes / 1024 / 1024, 2) output_mb,
       start_time, end_time,
       STATUS,
       'SEND_MAIL' mail_check
  FROM v$rman_status
 WHERE operation != 'RMAN'
   AND start_time >= SYSDATE - 1/24
   AND output_device_type IS NOT NULL
   AND status NOT IN ('COMPLETED', 'RUNNING', 'COMPLETED WITH WARNINGS', 'RUNNING WITH WARNINGS')
UNION ALL
-- "No recent backup" is checked on the PRIMARY only - backups are taken there,
-- and a standby controlfile can still carry stale RMAN records inherited from
-- the primary, which made this fire on one standby and not on another.
--
-- The role test and the NVL both sit in the OUTER query on purpose:
--   * the inline view always returns exactly one row (aggregate, no GROUP BY),
--     so NVL turns "never backed up" into an alert instead of silence. The old
--     HAVING MAX(end_time) < SYSDATE-1 compared NULL and therefore reported
--     nothing at all when there was not a single backup record.
--   * putting the role test inside the aggregate would NOT work: on a standby
--     it would filter every row away, MAX would be NULL, and the NVL would then
--     raise a false alert on exactly the databases we are trying to exclude.
SELECT 'BACKUP DOESNT EXIST' operation, 0, 0, 0,
       last_backup start_time, SYSDATE end_time,
       'MISSING' STATUS,
       'SEND_MAIL' mail_check
  FROM (SELECT MAX(end_time) last_backup
          FROM v$rman_status
         WHERE operation LIKE 'BACKUP%'
           AND OBJECT_TYPE IN ('DB INCR','DATABASE FULL','CONTROLFILE')
           AND status IN ('COMPLETED', 'COMPLETED WITH WARNINGS'))
 WHERE TRIM('&db_role') = 'PRIMARY'
   AND NVL(last_backup, DATE '1900-01-01') < SYSDATE - 1;


-- 5. PL/SQL SECTIONS (Wrap in PRE tags manually)
PROMPT <h3>High PGA Usage Check</h3>
PROMPT <div class='log-text'><pre>

DECLARE
   SESSION_ID              NUMBER;
   SESSION_SERIAL_NUMBER   NUMBER;
   KOMUT                   VARCHAR2 (500);
   PGA_AGGTA               NUMBER;
   USED_PGA                NUMBER;
   INSTANCE_ID             NUMBER;
   MEM_TARGET              NUMBER;
   SGA_SIZE                NUMBER;
   NODE_COUNT              NUMBER;
BEGIN
   SELECT COUNT (INST_ID) INTO NODE_COUNT FROM gv$instance;
   FOR INSTANCE_NUM IN 1 .. NODE_COUNT
   LOOP
      DECLARE
         CURSOR C1 IS
            SELECT a.* FROM (SELECT S.SID SESS_ID, S.SERIAL# SER_NO, S.INST_ID INS_ID
                               FROM GV$PROCESS P, GV$SESSION S
                              WHERE P.ADDR = S.PADDR AND S.INST_ID = INSTANCE_NUM
                             ORDER BY P.PGA_ALLOC_MEM DESC) a
             WHERE ROWNUM < 2;
      BEGIN
         SELECT ROUND (VALUE / 1024 / 1024, 0) INTO PGA_AGGTA FROM V$PARAMETER WHERE LOWER (NAME) = 'pga_aggregate_target';
         SELECT ROUND (VALUE / 1024 / 1024, 0) INTO MEM_TARGET FROM V$PARAMETER WHERE NAME = 'memory_target';
         SELECT ROUND (SUM (BYTES) / 1024 / 1024, 0) INTO SGA_SIZE FROM gv$sgastat WHERE name != 'free memory' AND INST_ID = INSTANCE_NUM;
         SELECT ROUND (VALUE / 1024 / 1024, 0) INTO USED_PGA FROM GV$PGASTAT WHERE name = 'total PGA allocated' AND INST_ID = INSTANCE_NUM;

         IF PGA_AGGTA = 0 THEN
            IF USED_PGA > ( (MEM_TARGET - SGA_SIZE) * 95 / 100) THEN
               FOR SESSION_LIST IN C1 LOOP
                  DBMS_OUTPUT.PUT_LINE ('High PGA Usage - Kill Session ' || SESSION_LIST.SESS_ID || ' - SEND_MAIL');
               END LOOP;
            END IF;
         ELSIF (MEM_TARGET = 0 AND USED_PGA > (PGA_AGGTA * 95 / 100)) THEN
            FOR SESSION_LIST IN C1 LOOP
               DBMS_OUTPUT.PUT_LINE ('High PGA Usage - Kill Session ' || SESSION_LIST.SESS_ID || ' - SEND_MAIL');
            END LOOP;
         END IF;
      END;
   END LOOP;
END;
/
PROMPT </pre></div>

PROMPT <h3>Blocking Sessions (>300 secs)</h3>
PROMPT <div class='log-text'><pre>

SET SERVEROUTPUT ON SIZE 1000000

DECLARE
   -- DBA_OBJECTS is looked up with dynamic SQL so that this block still
   -- COMPILES on a MOUNTED physical standby (static reference would raise
   -- ORA-01219 at compile time and mail a false alert every 30 minutes).
   v_object   VARCHAR2(300);
BEGIN
   DBMS_OUTPUT.enable(1000000);

   FOR do_loop IN (
        SELECT
            b.inst_id       AS inst,
            b.sid           AS session_id,
            b.serial#       AS serial,
            b.username      AS blocker_user,
            b.sql_id        AS blocker_sql_id,
            b.program       AS blocker_program,
            MAX(s.seconds_in_wait) AS secs,
            COUNT(*)        AS blocked_count,
            CASE
                WHEN b.program LIKE '%(J%)%' THEN 'DONT_MAIL'
                ELSE 'SEND_MAIL'
            END AS mail_check
        FROM gv$session s
        JOIN gv$session b
          ON b.inst_id = s.blocking_instance
         AND b.sid     = s.blocking_session
        WHERE s.blocking_session_status = 'VALID'
          AND s.seconds_in_wait > 300
          AND NVL(b.username, '-') NOT IN ('SYS', 'SYSTEM', 'SYSMAN')
        GROUP BY
            b.inst_id,
            b.sid,
            b.serial#,
            b.username,
            b.sql_id,
            b.program
        ORDER BY MAX(s.seconds_in_wait) DESC
   ) LOOP

        DBMS_OUTPUT.put_line(
            'Blocking Session : ' ||
            do_loop.session_id || ' @' || do_loop.inst ||
            ' for ' || do_loop.secs || ' secs - ' ||
            do_loop.mail_check
        );

        DBMS_OUTPUT.put_line('Blocker User  : ' || do_loop.blocker_user);
        DBMS_OUTPUT.put_line('Blocker SQL   : ' || do_loop.blocker_sql_id);
        DBMS_OUTPUT.put_line('Program       : ' || do_loop.blocker_program);
        DBMS_OUTPUT.put_line('Blocked Count : ' || do_loop.blocked_count);

        DBMS_OUTPUT.put_line(
            'Kill Script : ALTER SYSTEM KILL SESSION ''' ||
            do_loop.session_id || ',' || do_loop.serial || ',@' || do_loop.inst ||
            ''' IMMEDIATE;'
        );

        IF do_loop.mail_check = 'SEND_MAIL' THEN

            FOR next_loop IN (
                SELECT
                    s.inst_id,
                    s.sid,
                    s.serial#,
                    s.username,
                    s.seconds_in_wait,
                    s.event,
                    s.sql_id,
                    s.program,
                    s.row_wait_obj#   AS obj_id
                FROM gv$session s
                WHERE s.blocking_session_status = 'VALID'
                  AND s.blocking_instance = do_loop.inst
                  AND s.blocking_session  = do_loop.session_id
                  AND s.seconds_in_wait > 300
                ORDER BY s.seconds_in_wait DESC
            ) LOOP

                DBMS_OUTPUT.put_line(
                    '   -> Blocked Session : ' ||
                    next_loop.sid || ' @' || next_loop.inst_id ||
                    ' for ' || next_loop.seconds_in_wait || ' secs'
                );

                DBMS_OUTPUT.put_line('      Blocked User : ' || next_loop.username);
                DBMS_OUTPUT.put_line('      Blocked SQL  : ' || next_loop.sql_id);
                DBMS_OUTPUT.put_line('      Wait Event   : ' || next_loop.event);
                DBMS_OUTPUT.put_line('      Program      : ' || next_loop.program);

                v_object := NULL;
                IF NVL(next_loop.obj_id, -1) > 0 THEN
                   BEGIN
                      EXECUTE IMMEDIATE
                         'SELECT owner || ''.'' || object_name || '' ('' || object_type || '')'' '
                      || '  FROM dba_objects WHERE object_id = :1 AND ROWNUM = 1'
                         INTO v_object USING next_loop.obj_id;
                   EXCEPTION
                      WHEN OTHERS THEN v_object := NULL;
                   END;
                END IF;

                IF v_object IS NOT NULL THEN
                    DBMS_OUTPUT.put_line('      Object       : ' || v_object);
                ELSE
                    DBMS_OUTPUT.put_line('      Object       : N/A');
                END IF;

            END LOOP;

        END IF;

        DBMS_OUTPUT.put_line('----------------------------------------');

   END LOOP;
END;
/

PROMPT </pre></div>


PROMPT <h3>Parameter Limits (>90%)</h3>

select inst_id, resource_name, current_utilization, max_utilization, limit_value,
       round(((current_utilization / limit_value)*100)) current_pct,
       'SEND_MAIL' mail_check
from gv$resource_limit
where resource_name in ('sessions', 'processes') and ((current_utilization / limit_value)*100) > 90;


PROMPT <h3>Archiver Status</h3>
SELECT instance_name, archiver, database_status, 'SEND_MAIL' mail_check
  FROM v$instance
 WHERE archiver = 'FAILED'
    OR database_status <> 'ACTIVE';


-- =============================================================================
-- DATA GUARD SECTION
-- -----------------------------------------------------------------------------
-- Every query below is guarded by '&dg_enabled' and/or '&db_role', so on a
-- non-Data-Guard database they all return zero rows and only the (empty)
-- headings are printed - exactly like the ASM section on a non-ASM database.
-- NOTE: do NOT put the words "error" or "ORA-" into any PROMPT line here -
-- monitoring.sh greps the whole file for them and would mail every 30 min.
-- =============================================================================

PROMPT <h3 class='dg'>Data Guard Configuration Summary</h3>
SELECT db_unique_name,
       database_role,
       open_mode,
       protection_mode,
       protection_level,
       dataguard_broker broker,
       switchover_status,
       force_logging,
       flashback_on
  FROM v$database
 WHERE TRIM('&dg_enabled') = 'YES';


PROMPT <h3 class='dg'>Data Guard Role and Process Checks</h3>
SELECT dg_check, dg_detail, 'SEND_MAIL' mail_check
  FROM (
        -- Redo apply (MRP) is not running at all on the standby
        SELECT 'REDO APPLY IS NOT RUNNING (no MRP process)' dg_check,
               'Standby ' || (SELECT db_unique_name FROM v$database)
                          || ' - start with: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION' dg_detail
          FROM dual
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND NOT EXISTS (SELECT 1 FROM v$managed_standby WHERE process LIKE 'MRP%')
        UNION ALL
        -- MRP exists but is in a state that means apply is not progressing
        SELECT 'REDO APPLY PROCESS IN BAD STATE: ' || m.process,
               'status=' || m.status || ' thread=' || m.thread# || ' sequence=' || m.sequence#
          FROM v$managed_standby m
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND m.process LIKE 'MRP%'
           AND m.status NOT IN ('APPLYING_LOG', 'WAIT_FOR_LOG', 'IDLE')
        UNION ALL
        -- No RFS process means redo is not arriving from the primary
        SELECT 'REDO IS NOT ARRIVING (no RFS process on standby)',
               'Check listener / tnsnames / log_archive_dest on the primary'
          FROM dual
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND NOT EXISTS (SELECT 1 FROM v$managed_standby WHERE process = 'RFS')
        UNION ALL
        -- Without standby redo logs real-time apply is impossible.
        -- Config-level finding: stays true until a DBA fixes it, so it is
        -- reported only in the daily window instead of 48 times a day.
        SELECT 'STANDBY REDO LOGS ARE MISSING',
               'Real-time apply is not possible, apply lag will always be at least one log'
               || ' (config check, reported once a day)'
          FROM dual
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND TO_CHAR(SYSDATE, 'HH24MI') BETWEEN &dg_daily_from AND &dg_daily_to
           AND NOT EXISTS (SELECT 1 FROM v$standby_log)
        UNION ALL
        -- v$dataguard_stats has stopped refreshing -> apply/monitoring stuck.
        -- TIME_COMPUTED is a VARCHAR2(20) holding TEXT, not a date, and Oracle
        -- writes it in a FIXED 'MM/DD/YYYY HH24:MI:SS' format that ignores the
        -- session NLS_DATE_FORMAT (verified on 19c: session was DD-MON-RR and
        -- the column still read 09/14/2026 08:26:48). Parsing it without an
        -- explicit mask raised ORA-01843 on the standby.
        -- VALIDATE_CONVERSION is kept as a belt-and-braces guard: the CASE
        -- short-circuits, so if a future release ever changes the format the
        -- check quietly yields 0 (no alert) instead of mailing an error.
        SELECT 'DATA GUARD STATISTICS ARE STALE',
               'apply lag last computed at ' || time_computed
          FROM v$dataguard_stats
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND name = 'apply lag'
           AND time_computed IS NOT NULL
           AND CASE WHEN VALIDATE_CONVERSION(time_computed AS DATE,
                                             'MM/DD/YYYY HH24:MI:SS') = 1
                    THEN (SYSDATE - TO_DATE(time_computed,
                                            'MM/DD/YYYY HH24:MI:SS')) * 1440
                    ELSE 0
               END > &dg_stat_stale_min
        UNION ALL
        -- Primary side: protection level has dropped below the configured mode
        SELECT 'PROTECTION LEVEL DOES NOT MATCH PROTECTION MODE',
               'mode=' || protection_mode || ' level=' || protection_level
          FROM v$database
         WHERE TRIM('&db_role') = 'PRIMARY'
           AND TRIM('&dg_enabled') = 'YES'
           AND protection_mode <> protection_level
        UNION ALL
        -- Primary side: NOLOGGING operations would corrupt the standby.
        -- Config-level finding: same daily-window treatment as the SRL check.
        SELECT 'FORCE LOGGING IS DISABLED ON PRIMARY',
               'force_logging=' || force_logging
               || ' (config check, reported once a day)'
          FROM v$database
         WHERE TRIM('&db_role') = 'PRIMARY'
           AND TRIM('&dg_enabled') = 'YES'
           AND TO_CHAR(SYSDATE, 'HH24MI') BETWEEN &dg_daily_from AND &dg_daily_to
           AND force_logging <> 'YES'
       );


PROMPT <h3 class='dg'>Data Guard Lag (transport over &dg_transport_lag_min min / apply over &dg_apply_lag_min min)</h3>
SELECT dg_stat,
       lag_value,
       ROUND(lag_min, 1) lag_minutes,
       time_computed,
       'SEND_MAIL' mail_check
  FROM (SELECT name  dg_stat,
               value lag_value,
               time_computed,
               -- v$dataguard_stats.value is an interval string '+DD HH:MI:SS'.
               -- The CASE guarantees TO_DSINTERVAL is never called on a value
               -- that is empty or in an unexpected format (would raise ORA-01867).
               CASE WHEN REGEXP_LIKE(value, '^\+[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')
                    THEN EXTRACT(DAY    FROM TO_DSINTERVAL(value)) * 1440
                       + EXTRACT(HOUR   FROM TO_DSINTERVAL(value)) * 60
                       + EXTRACT(MINUTE FROM TO_DSINTERVAL(value))
                       + EXTRACT(SECOND FROM TO_DSINTERVAL(value)) / 60
                    ELSE 0
               END lag_min
          FROM v$dataguard_stats
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND name IN ('transport lag', 'apply lag'))
 WHERE (dg_stat = 'transport lag' AND lag_min > &dg_transport_lag_min)
    OR (dg_stat = 'apply lag'     AND lag_min > &dg_apply_lag_min)
 ORDER BY dg_stat;


PROMPT <h3 class='dg'>Data Guard Archive Gap</h3>
SELECT thread#,
       low_sequence#,
       high_sequence#,
       high_sequence# - low_sequence# + 1 missing_logs,
       'SEND_MAIL' mail_check
  FROM v$archive_gap
 WHERE TRIM('&db_role') = 'PHYSICAL STANDBY';


PROMPT <h3 class='dg'>Data Guard Apply Sequence Gap (more than &dg_seq_gap logs)</h3>
SELECT thread#,
       max_received_seq,
       max_applied_seq,
       NVL(max_received_seq, 0) - NVL(max_applied_seq, 0) logs_behind,
       'SEND_MAIL' mail_check
  FROM (SELECT thread#,
               MAX(sequence#) max_received_seq,
               MAX(CASE WHEN applied IN ('YES', 'IN-MEMORY') THEN sequence# END) max_applied_seq
          FROM v$archived_log
         WHERE TRIM('&db_role') = 'PHYSICAL STANDBY'
           AND resetlogs_change# = (SELECT resetlogs_change# FROM v$database)
         GROUP BY thread#)
 WHERE NVL(max_received_seq, 0) - NVL(max_applied_seq, 0) > &dg_seq_gap;


PROMPT <h3 class='dg'>Data Guard Transport Destinations (Primary)</h3>
-- NOTE: V$ARCHIVE_DEST_STATUS has NO "target" column - that one lives on
-- V$ARCHIVE_DEST. Standby destinations are therefore selected by dest_id.
SELECT s.dest_id,
       s.dest_name,
       s.destination,
       s.status,
       s.type,
       s.gap_status,
       s.database_mode,
       s.recovery_mode,
       SUBSTR(s.error, 1, 200) dest_message,
       'SEND_MAIL' mail_check
  FROM v$archive_dest_status s
 WHERE TRIM('&db_role') = 'PRIMARY'
   AND s.destination IS NOT NULL
   AND s.dest_id IN (SELECT d.dest_id
                       FROM v$archive_dest d
                      WHERE d.target = 'STANDBY'
                        AND d.destination IS NOT NULL)
   AND (s.status <> 'VALID' OR NVL(s.gap_status, 'NO GAP') <> 'NO GAP');


-- REMOVED in 2.3.1: "Standby Apply Progress seen from Primary".
-- It compared ARCHIVED_SEQ# with APPLIED_SEQ# in V$ARCHIVE_DEST_STATUS on the
-- primary. APPLIED_SEQ# there is not a live figure - the primary only learns it
-- when the standby acknowledges - and with real-time apply the standby applies
-- redo straight from the standby redo logs, before the log is archived. During
-- normal log switching the two columns therefore drift by a few sequences on a
-- standby that is perfectly in sync, which produced a false alert (41921 vs
-- 41917) on a healthy DR node.
-- Apply progress is measured on the standby instead, where it is real: the
-- "Data Guard Lag" section reads apply lag in minutes from V$DATAGUARD_STATS,
-- and the sequence gap section reads V$ARCHIVED_LOG locally. The same script
-- runs on both nodes, so nothing is left uncovered. Transport health stays on
-- the primary in the "Transport Destinations" section (status, gap_status).


PROMPT <h3 class='dg'>Data Guard Messages (Last &dg_msg_window_min min)</h3>
SELECT facility,
       severity,
       message_num,
       TO_CHAR(timestamp, 'DD-MON-YYYY HH24:MI:SS') event_time,
       SUBSTR(message, 1, 250) dg_message,
       'SEND_MAIL' mail_check
  FROM v$dataguard_status
 WHERE TRIM('&dg_enabled') = 'YES'
   AND severity IN (&dg_msg_severity)
   AND timestamp > SYSDATE - &dg_msg_window_min/1440
 ORDER BY timestamp DESC;


-- 6. CLOSING TAGS
-- Markup is turned OFF first. While HTML markup is ON, SQLPlus appends a <br>
-- to every PROMPT line - which is what left a stray <br> AFTER </html>.
SET MARKUP HTML OFF
PROMPT <br><br>
PROMPT </body></html>
exit
