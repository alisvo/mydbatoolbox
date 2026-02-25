
-- 1. SETUP (HTML IS OFF INITIALLY)
SET TERMOUT ON
SET TRIMSPOOL ON
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 2000
SET PAGESIZE 9999
SET SERVEROUTPUT ON SIZE UNLIMITED
SET MARKUP HTML OFF

-- 2. GET VARIABLES (Silent Mode - No Empty Tables)
COLUMN INSTANCE_NAME NEW_VALUE INSTANCE_NAME NOPRINT;
select INSTANCE_NAME from v$instance;

COLUMN current_database NEW_VALUE current_database NOPRINT;
SELECT rpad(name, 17) current_database FROM v$database;

COLUMN current_date NEW_VALUE current_date NOPRINT;
ALTER session set nls_date_format='DD-MON-YYYY HH24:MI:SS';
SELECT sysdate current_date FROM v$database;

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
PROMPT .log-text {font-family: 'Courier New', monospace; background: #f4f4f4; padding: 10px; border: 1px solid #ddd;}
PROMPT </style>
PROMPT </head>
PROMPT <body>

PROMPT <h2>Database Health Report: &INSTANCE_NAME</h2>
PROMPT <b>Date:</b> &current_date
PROMPT <hr>

-- 4. TURN ON HTML FOR DATA TABLES
-- HEAD "" BODY "" prevents it from printing a second set of <html><body> tags
SET MARKUP HTML ON HEAD "" BODY "" TABLE "border='1'" ENTMAP OFF

-- =============================================================================
-- BEGIN REPORT
-- =============================================================================

PROMPT <h3>Tablespace Usage (>90%)</h3>
SELECT a1.tablespace_name TS_NAME,
       a1.size_mb ALLOCATED_SIZE_MB,
       NVL (a2.free_mb, 0) FREE_MB,
       a1.max_size_mb MAX_SIZE_MB,
       NVL (ROUND ( (a1.size_mb - NVL (a2.free_mb, 0)) * 100 / a1.max_size_mb, 2), 100) PCT_OF_TOTAL_USE,
       'SEND_MAIL' mail_check
  FROM (SELECT b.tablespace_name, SUM (b.max_size_mb) max_size_mb, SUM (b.size_mb) size_mb
          FROM (SELECT tablespace_name,
                       CASE WHEN a.maxbytes = 0 THEN ROUND ( (BYTES) / 1024 / 1024, 2)
                            WHEN a.maxbytes > 0 THEN ROUND ( (maxbytes) / 1024 / 1024, 2)
                       END max_size_mb,
                       ROUND ( (BYTES) / 1024 / 1024, 2) size_mb
                  FROM dba_data_files a) b
         GROUP BY b.tablespace_name) a1,
       (SELECT tablespace_name, ROUND (SUM (bytes) / 1024 / 1024, 2) free_mb
          FROM dba_free_space
         GROUP BY tablespace_name) a2
 WHERE a1.tablespace_name = a2.tablespace_name(+)
   AND a1.tablespace_name not in ('UNDOTBS1','UNDOTBS2')
   AND NVL (ROUND ( (a1.size_mb - NVL (a2.free_mb, 0)) * 100 / a1.max_size_mb, 2),100) > 90
ORDER BY 5 DESC;


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
   AND (SELECT database_role FROM v$database) = 'PRIMARY'
UNION ALL
SELECT 'DB/CTRL BACKUP MISSING > 28h' operation,
       0, 0, 0,
       MAX(end_time) start_time, SYSDATE end_time,
       'MISSING' status,
       'SEND_MAIL' mail_check
  FROM v$rman_status
 WHERE operation LIKE 'BACKUP%'
   AND object_type IN ('DB INCR','DATABASE FULL','CONTROLFILE')
   AND status IN ('COMPLETED','COMPLETED WITH WARNINGS')
   HAVING NVL(MAX(end_time), DATE '1900-01-01') < SYSDATE - (28/24)
  AND (SELECT database_role FROM v$database) = 'PRIMARY'
UNION ALL
SELECT 'ARCHIVELOG BACKUP MISSING > 5h' operation,
       0, 0, 0,
       MAX(end_time) start_time, SYSDATE end_time,
       'MISSING' status,
       'SEND_MAIL' mail_check
  FROM v$rman_status
 WHERE operation LIKE 'BACKUP%'
   AND object_type LIKE 'ARCHIVELOG%'
   AND status IN ('COMPLETED','COMPLETED WITH WARNINGS')
   HAVING NVL(MAX(end_time), DATE '1900-01-01') < SYSDATE - (5/24)
   AND (SELECT database_role FROM v$database) = 'PRIMARY';


-- 5. PL/SQL SECTIONS (Wrap in PRE tags manually)
PROMPT <h3>High PGA Usage Check</h3>
PROMPT <div class='log-text'><pre>


DECLARE
    pga_target_mb   NUMBER;
    pga_limit_mb    NUMBER;
    mem_target_mb   NUMBER;
    sga_used_mb     NUMBER;
    pga_alloc_mb    NUMBER;

    limit_type      VARCHAR2(20);
    effective_limit NUMBER;
    is_danger        BOOLEAN;
BEGIN
    -- Loop real inst_id values (RAC-safe)
    FOR i IN (SELECT inst_id FROM gv$instance ORDER BY inst_id) LOOP

        -- Parameters (bytes -> MB), force numeric conversion safely
        SELECT ROUND(TO_NUMBER(value)/1024/1024,0)
          INTO pga_target_mb
          FROM gv$parameter
         WHERE name = 'pga_aggregate_target'
           AND inst_id = i.inst_id;

        SELECT ROUND(TO_NUMBER(value)/1024/1024,0)
          INTO mem_target_mb
          FROM gv$parameter
         WHERE name = 'memory_target'
           AND inst_id = i.inst_id;

        SELECT ROUND(TO_NUMBER(value)/1024/1024,0)
          INTO pga_limit_mb
          FROM gv$parameter
         WHERE name = 'pga_aggregate_limit'
           AND inst_id = i.inst_id;

        -- Current usage
        SELECT ROUND(value/1024/1024,0)
          INTO pga_alloc_mb
          FROM gv$pgastat
         WHERE name = 'total PGA allocated'
           AND inst_id = i.inst_id;

        -- Decide which limit to compare against
        is_danger := FALSE;
        effective_limit := NULL;

        -- 1) HARD LIMIT: PGA_AGGREGATE_LIMIT (most meaningful in 19c/21c)
        IF pga_limit_mb > 0 THEN
            limit_type := 'HARD_LIMIT';
            effective_limit := pga_limit_mb;
            IF pga_alloc_mb >= pga_limit_mb * 0.90 THEN
                is_danger := TRUE;
            END IF;

        -- 2) AMM case (rare in serious prod, but keep it)
        ELSIF mem_target_mb > 0 THEN
            limit_type := 'MEM_TARGET';

            SELECT ROUND(SUM(bytes)/1024/1024,0)
              INTO sga_used_mb
              FROM gv$sgastat
             WHERE inst_id = i.inst_id
               AND name <> 'free memory';

            effective_limit := GREATEST(mem_target_mb - sga_used_mb, 0);

            IF effective_limit > 0 AND pga_alloc_mb >= effective_limit * 0.95 THEN
                is_danger := TRUE;
            END IF;

        -- 3) Soft target
        ELSE
            limit_type := 'SOFT_TARGET';
            effective_limit := pga_target_mb;
            IF pga_target_mb > 0 AND pga_alloc_mb > pga_target_mb THEN
                is_danger := TRUE;
            END IF;
        END IF;

        -- Output + top PGA session
        IF is_danger THEN
            DBMS_OUTPUT.PUT_LINE(
                'High PGA ('||limit_type||') on Inst '||i.inst_id||
                ' | Used: '||pga_alloc_mb||'MB / Limit: '||effective_limit||'MB'
            );

            FOR r IN (
                SELECT s.sid, s.serial#, NVL(s.username,'(background)') AS username,
                       ROUND(p.pga_alloc_mem/1024/1024,2) pga_mb
                  FROM gv$process p
                  JOIN gv$session s
                    ON s.paddr = p.addr
                   AND s.inst_id = p.inst_id
                 WHERE s.inst_id = i.inst_id
                 ORDER BY p.pga_alloc_mem DESC
                 FETCH FIRST 1 ROWS ONLY
            ) LOOP
                DBMS_OUTPUT.PUT_LINE(
                    ' -> Top Session: '||r.sid||','||r.serial#||
                    ' ('||r.username||') using '||r.pga_mb||' MB - SEND_MAIL'
                );
            END LOOP;
        END IF;

    END LOOP;
END;
/
PROMPT </pre></div>



PROMPT <h3>Blocking Sessions (>300 secs) [Enhanced Mode]</h3>
PROMPT <div class='log-text'><pre>

BEGIN
    DBMS_OUTPUT.ENABLE(1000000);

    FOR r IN (
        WITH
        tx_pairs AS (
          SELECT
              lw.inst_id AS w_inst_id, lw.sid AS w_sid,
              lb.inst_id AS b_inst_id, lb.sid AS b_sid,
              lw.id1, lw.id2
          FROM gv$lock lw
          JOIN gv$lock lb
            ON lb.type   = 'TX'
           AND lw.type   = 'TX'
           AND lb.id1    = lw.id1
           AND lb.id2    = lw.id2
          WHERE lw.request > 0   -- waiter
            AND lb.block   = 1   -- blocker
        ),
        blk_objs AS (
          SELECT
            lo.inst_id, lo.session_id AS sid,
            LISTAGG(o.owner||'.'||o.object_name||'('||o.object_type||')', ', ' ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) 
            WITHIN GROUP (ORDER BY o.owner, o.object_name) AS locked_objects
          FROM gv$locked_object lo
          JOIN dba_objects o ON o.object_id = lo.object_id
          GROUP BY lo.inst_id, lo.session_id
        ),
        sqltxt AS (
          SELECT inst_id, sql_id, SUBSTR(sql_fulltext, 1, 100) AS sql_text -- Log şişmesin diye 100 char limitledim
          FROM gv$sql
        )
        SELECT
          -- WAITER BILGILERI
          sw.inst_id AS w_inst, sw.sid AS w_sid, sw.username AS w_user,
          sw.seconds_in_wait AS w_wait_secs,
          stw.sql_text AS w_sql_text,
          
          -- BLOCKER BILGILERI
          sb.inst_id AS b_inst, sb.sid AS b_sid, sb.serial# AS b_serial, 
          sb.username AS b_user, sb.status AS b_status,
          bo.locked_objects AS b_locked_objects,
          
          CASE WHEN sb.program LIKE '%(J%)%' THEN 'DONT_MAIL' ELSE 'SEND_MAIL' END AS mail_check

        FROM tx_pairs p
        JOIN gv$session sw ON sw.inst_id = p.w_inst_id AND sw.sid = p.w_sid
        JOIN gv$session sb ON sb.inst_id = p.b_inst_id AND sb.sid = p.b_sid
        LEFT JOIN blk_objs bo ON bo.inst_id = sb.inst_id AND bo.sid = sb.sid
        LEFT JOIN sqltxt stw  ON stw.inst_id = sw.inst_id AND stw.sql_id = sw.sql_id
        WHERE sw.seconds_in_wait > 300
          AND sw.event LIKE 'enq: TX%'
          AND NVL(sw.username,'-') NOT IN ('SYS','SYSTEM','SYSMAN')
          AND NVL(sb.username,'-') NOT IN ('SYS','SYSTEM','SYSMAN')
        ORDER BY sw.seconds_in_wait DESC
    ) 
    LOOP
        -- Cikti Formatlama
        DBMS_OUTPUT.PUT_LINE('----------------------------------------');
        DBMS_OUTPUT.PUT_LINE('BLOCKING SESSION : ' || r.b_sid || ' @' || r.b_inst || ' (' || r.b_user || ')');
        DBMS_OUTPUT.PUT_LINE('Status           : ' || r.b_status || ' - ' || r.mail_check);
        DBMS_OUTPUT.PUT_LINE('Locked Objects   : ' || r.b_locked_objects);
        DBMS_OUTPUT.PUT_LINE('Kill Command     : ALTER SYSTEM KILL SESSION ''' || r.b_sid || ',' || r.b_serial || ',@' || r.b_inst || ''';');
        
        DBMS_OUTPUT.PUT_LINE(' ');
        DBMS_OUTPUT.PUT_LINE('   -> WAITING SESSION : ' || r.w_sid || ' @' || r.w_inst || ' (' || r.w_user || ')');
        DBMS_OUTPUT.PUT_LINE('   -> Wait Time       : ' || r.w_wait_secs || ' seconds');
        
        -- Eğer waiter'ın SQL'i yakalanabildiyse onu da yazalım
        IF r.w_sql_text IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('   -> Blocked SQL     : ' || r.w_sql_text);
        END IF;

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

-- 6. CLOSING TAGS
PROMPT <br><br>
PROMPT </body></html>
exit
