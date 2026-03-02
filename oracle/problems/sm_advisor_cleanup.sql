-- ======================================================================
-- Workaround for Oracle 19.28 Bug:
-- SYSAUX grows excessively with entries for AUTO_STATS_ADVISOR_TASK
-- Doc ID: 3104754.1
-- ======================================================================

SET SERVEROUTPUT ON
SET FEEDBACK ON
SET ECHO ON
SET TIMING ON

PROMPT === Step 1: Create new table excluding AUTO_STATS_ADVISOR_TASK entries ===
BEGIN
  EXECUTE IMMEDIATE '
    CREATE TABLE WRI$_ADV_OBJECTS_NEW AS
    SELECT * 
    FROM WRI$_ADV_OBJECTS
    WHERE TASK_ID != (
      SELECT DISTINCT ID 
      FROM WRI$_ADV_TASKS 
      WHERE NAME = ''AUTO_STATS_ADVISOR_TASK''
    )
  ';
  DBMS_OUTPUT.PUT_LINE('WRI$_ADV_OBJECTS_NEW table created successfully.');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Error during table creation: ' || SQLERRM);
END;
/

PROMPT === Step 2: Check new table record count ===
SELECT COUNT(*) AS RECORD_COUNT_NEW FROM WRI$_ADV_OBJECTS_NEW;

PROMPT === Step 3: Truncate the original table ===
TRUNCATE TABLE WRI$_ADV_OBJECTS;

PROMPT === Step 4: Reinsert cleaned data ===
INSERT INTO WRI$_ADV_OBJECTS(
  "ID","TYPE","TASK_ID","EXEC_NAME",
  "ATTR1","ATTR2","ATTR3","ATTR4","ATTR5","ATTR6","ATTR7","ATTR8","ATTR9","ATTR10",
  "ATTR11","ATTR12","ATTR13","ATTR14","ATTR15","ATTR16","ATTR17","ATTR18","ATTR19","ATTR20",
  "OTHER","SPARE_N1","SPARE_N2","SPARE_N3","SPARE_N4",
  "SPARE_C1","SPARE_C2","SPARE_C3","SPARE_C4"
)
SELECT
  "ID","TYPE","TASK_ID","EXEC_NAME",
  "ATTR1","ATTR2","ATTR3","ATTR4","ATTR5","ATTR6","ATTR7","ATTR8","ATTR9","ATTR10",
  "ATTR11","ATTR12","ATTR13","ATTR14","ATTR15","ATTR16","ATTR17","ATTR18","ATTR19","ATTR20",
  "OTHER","SPARE_N1","SPARE_N2","SPARE_N3","SPARE_N4",
  "SPARE_C1","SPARE_C2","SPARE_C3","SPARE_C4"
FROM WRI$_ADV_OBJECTS_NEW;

COMMIT;

PROMPT === Step 5: Rebuild indexes ===
ALTER INDEX WRI$_ADV_OBJECTS_IDX_02 REBUILD;
ALTER INDEX WRI$_ADV_OBJECTS_IDX_01 REBUILD;
ALTER INDEX WRI$_ADV_OBJECTS_PK REBUILD;

PROMPT === Step 6: Post-cleanup verification ===
SELECT COUNT(*) AS FINAL_RECORD_COUNT FROM WRI$_ADV_OBJECTS;

PROMPT === Step 7: Optionally drop the temporary table ===
DROP TABLE WRI$_ADV_OBJECTS_NEW PURGE;

PROMPT === Cleanup complete. SYSAUX bloat should now be mitigated. ===
