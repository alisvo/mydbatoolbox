-- Check table size of aud:

SET PAGES 999
SET LINES 300
COL OWNER FOR A10 
COL SEGMENT_NAME FOR A20 
COL SEGMENT_TYPE FOR A15 
COL MB FOR 9999999
SELECT OWNER,
       SEGMENT_NAME,
       SEGMENT_TYPE,
       ROUND(BYTES/1024/1024) MB 
FROM
       DBA_SEGMENTS
WHERE
       TABLESPACE_NAME='SYSTEM' 
ORDER BY BYTES DESC
FETCH FIRST 5 ROWS ONLY;

-- Calculate the procedure depending on the count of records that is intended to be deleted.
select count(*) from sys.aud$ where ntimestamp#<sysdate -180


DECLARE
    v_limit NUMBER := 10000; -- Define batch size
BEGIN
    LOOP
        DELETE FROM SYS.AUD$ WHERE ntimestamp#<sysdate -180 AND ROWNUM <= v_limit;
        EXIT WHEN SQL%ROWCOUNT = 0;
        COMMIT;
    END LOOP;
END;
