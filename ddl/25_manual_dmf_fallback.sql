-------------------------------------------------------------------------------
-- 25_manual_dmf_fallback.sql
--
-- Fallback measurement layer for accounts where the working role can't get
-- EXECUTE DATA METRIC FUNCTION granted (an ACCOUNTADMIN-only privilege that
-- native Cortex DQ requires). Computes the same 15 metrics as Section C/D
-- of file 20, in plain SQL, and writes them to a table that mimics the
-- shape of SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS so the bridge
-- views in file 22 work unchanged.
--
-- Use INSTEAD OF ddl/20_cortex_dq_setup.sql when:
--   - Working role lacks EXECUTE DATA METRIC FUNCTION on ACCOUNT, or
--   - Working role lacks DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER, or
--   - Account has no ACCOUNTADMIN access available to grant either of those
--
-- Privilege requirements (all of these you already have as the schema owner):
--   - OWNERSHIP / USAGE on ASATTAR_TRUST_SCORE_POC.DQ_POC
--   - SELECT on DT_POSITION_REPORT, DT_TRENDED_REPORT
--   - USAGE on a warehouse
--
-- Run order: replaces file 20 entirely. After this, run files 21, 22, 22a
-- the same as in the native-DMF path. The bridge view in file 22 will be
-- updated by the same patch that introduces this file to read from
-- PNC_DQ_MEASUREMENTS_MANUAL instead of SNOWFLAKE.LOCAL.
--
-- Append-only design: the SP appends a new row per (table, metric, column)
-- on every CALL. The bridge view picks the latest reading via ROW_NUMBER,
-- so re-running the SP just refreshes the dashboard. Free historical
-- trending if you ever want a "trust score over time" chart later.
-------------------------------------------------------------------------------

USE ROLE      DATA_CLEAN_ROOM_ROLE;
USE WAREHOUSE WH_DEFAULT;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;


-------------------------------------------------------------------------------
-- SECTION A: MEASUREMENTS TABLE
--
-- Schema mirrors the columns the bridge view in file 22 reads from:
--   metric_name, arguments_names, value, measurement_time,
--   table_database, table_schema, table_name
-- (Snowflake's DATA_QUALITY_MONITORING_RESULTS uses lowercase identifiers;
--  Snowflake folds unquoted column names to uppercase, and ARRAY_TO_STRING
--  in the bridge view reads ARGUMENTS_NAMES case-insensitively, so this
--  table works as a drop-in replacement.)
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL (
    METRIC_NAME       VARCHAR
  , ARGUMENTS_NAMES   ARRAY
  , VALUE             FLOAT
  , MEASUREMENT_TIME  TIMESTAMP_NTZ
  , TABLE_DATABASE    VARCHAR
  , TABLE_SCHEMA      VARCHAR
  , TABLE_NAME        VARCHAR
);


-------------------------------------------------------------------------------
-- SECTION B: STORED PROCEDURE
--
-- One CALL recomputes all 15 metrics and appends one row each. Each table
-- is scanned exactly once via a CTE; the metric values fan out into rows
-- via a UNION ALL of constant-projecting SELECTs against the 1-row CTE.
--
-- EXECUTE AS CALLER is the default and the right choice here -- the SP
-- runs with the caller's privileges (OWNERSHIP/SELECT on the tables),
-- so no extra grants are needed.
-------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- ----------------------------------------------------------------------
    -- DT_POSITION_REPORT  -- 9 metrics
    --   ROW_COUNT()
    --   NULL_PERCENT(POSITION_ID | WORKER_EMPLOYEE_ID | MANAGER_EMPLOYEE_ID
    --                | L1_EMPLOYEE_ID | REPORT_EFFECTIVE_DATE | LOADDATE)
    --   DUPLICATE_COUNT(POSITION_ID, REPORT_EFFECTIVE_DATE)  -- compound PK
    --   FRESHNESS(LOADDATE)
    -- ----------------------------------------------------------------------
    INSERT INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL
        (METRIC_NAME, ARGUMENTS_NAMES, VALUE, MEASUREMENT_TIME, TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME)
    WITH s AS (
        SELECT
            COUNT(*)::FLOAT                                                              AS rc
          , COUNT_IF(POSITION_ID          IS NULL) / NULLIF(COUNT(*),0) * 100.0          AS np_position_id
          , COUNT_IF(WORKER_EMPLOYEE_ID   IS NULL) / NULLIF(COUNT(*),0) * 100.0          AS np_worker
          , COUNT_IF(MANAGER_EMPLOYEE_ID  IS NULL) / NULLIF(COUNT(*),0) * 100.0          AS np_manager
          , COUNT_IF(L1_EMPLOYEE_ID       IS NULL) / NULLIF(COUNT(*),0) * 100.0          AS np_l1
          , COUNT_IF(REPORT_EFFECTIVE_DATE IS NULL) / NULLIF(COUNT(*),0) * 100.0         AS np_red
          , COUNT_IF(LOADDATE             IS NULL) / NULLIF(COUNT(*),0) * 100.0          AS np_loaddate
          , (COUNT(*) - COUNT(DISTINCT POSITION_ID, REPORT_EFFECTIVE_DATE))::FLOAT       AS dup_position_snapshot
          , DATEDIFF('second', MAX(LOADDATE), CURRENT_TIMESTAMP())::FLOAT                AS freshness_secs
        FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
    )
    SELECT 'ROW_COUNT'      , ARRAY_CONSTRUCT()                                          , s.rc                    , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT'   , ARRAY_CONSTRUCT('POSITION_ID')                             , s.np_position_id        , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT'   , ARRAY_CONSTRUCT('WORKER_EMPLOYEE_ID')                      , s.np_worker             , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT'   , ARRAY_CONSTRUCT('MANAGER_EMPLOYEE_ID')                     , s.np_manager            , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT'   , ARRAY_CONSTRUCT('L1_EMPLOYEE_ID')                          , s.np_l1                 , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT'   , ARRAY_CONSTRUCT('REPORT_EFFECTIVE_DATE')                   , s.np_red                , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT'   , ARRAY_CONSTRUCT('LOADDATE')                                , s.np_loaddate           , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'DUPLICATE_COUNT', ARRAY_CONSTRUCT('POSITION_ID', 'REPORT_EFFECTIVE_DATE')    , s.dup_position_snapshot , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s
    UNION ALL
    SELECT 'FRESHNESS'      , ARRAY_CONSTRUCT('LOADDATE')                                , s.freshness_secs        , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_POSITION_REPORT' FROM s;

    -- ----------------------------------------------------------------------
    -- DT_TRENDED_REPORT  -- 6 metrics
    --   ROW_COUNT()
    --   NULL_PERCENT(EMPLOYEEID | POSITIONID | EFFECTIVEDATE | LOADDATE)
    --   FRESHNESS(LOADDATE)
    -- (No DUPLICATE_COUNT -- the table is deliberately at grain
    --  (EMPLOYEEID, EFFECTIVEDATE) so neither column alone is unique;
    --  see Section D of file 20 for the rationale.)
    -- ----------------------------------------------------------------------
    INSERT INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL
        (METRIC_NAME, ARGUMENTS_NAMES, VALUE, MEASUREMENT_TIME, TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME)
    WITH s AS (
        SELECT
            COUNT(*)::FLOAT                                                              AS rc
          , COUNT_IF(EMPLOYEEID    IS NULL) / NULLIF(COUNT(*),0) * 100.0                 AS np_employeeid
          , COUNT_IF(POSITIONID    IS NULL) / NULLIF(COUNT(*),0) * 100.0                 AS np_positionid
          , COUNT_IF(EFFECTIVEDATE IS NULL) / NULLIF(COUNT(*),0) * 100.0                 AS np_effectivedate
          , COUNT_IF(LOADDATE      IS NULL) / NULLIF(COUNT(*),0) * 100.0                 AS np_loaddate
          , DATEDIFF('second', MAX(LOADDATE), CURRENT_TIMESTAMP())::FLOAT                AS freshness_secs
        FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
    )
    SELECT 'ROW_COUNT'   , ARRAY_CONSTRUCT()                       , s.rc               , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_TRENDED_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT', ARRAY_CONSTRUCT('EMPLOYEEID')           , s.np_employeeid    , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_TRENDED_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT', ARRAY_CONSTRUCT('POSITIONID')           , s.np_positionid    , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_TRENDED_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT', ARRAY_CONSTRUCT('EFFECTIVEDATE')        , s.np_effectivedate , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_TRENDED_REPORT' FROM s
    UNION ALL
    SELECT 'NULL_PERCENT', ARRAY_CONSTRUCT('LOADDATE')             , s.np_loaddate      , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_TRENDED_REPORT' FROM s
    UNION ALL
    SELECT 'FRESHNESS'   , ARRAY_CONSTRUCT('LOADDATE')             , s.freshness_secs   , CURRENT_TIMESTAMP(), 'ASATTAR_TRUST_SCORE_POC', 'DQ_POC', 'DT_TRENDED_REPORT' FROM s;

    RETURN 'OK: 15 measurements written at ' || CURRENT_TIMESTAMP()::VARCHAR;
END;
$$;


-------------------------------------------------------------------------------
-- SECTION C: FIRST CALL
--
-- After running this once, the bridge view in file 22 (after its source-swap
-- patch) will surface measurements the same way it would for native DMFs.
-- Re-run any time you want to refresh the dashboard.
-------------------------------------------------------------------------------

CALL ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS();


-------------------------------------------------------------------------------
-- SECTION D: OPTIONAL SCHEDULE
--
-- Snowflake TASKs need EXECUTE TASK on the account (or
-- EXECUTE MANAGED TASK if running serverless). If your role doesn't have
-- either, just CALL the SP manually whenever you want fresh readings --
-- the dashboard reflects them immediately.
-------------------------------------------------------------------------------

/*
CREATE OR REPLACE TASK ASATTAR_TRUST_SCORE_POC.DQ_POC.TSK_COMPUTE_DQ_MEASUREMENTS
  WAREHOUSE = WH_DEFAULT
  SCHEDULE  = 'USING CRON 0 */6 * * * UTC'   -- every 6h; tune to taste
AS
  CALL ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS();

ALTER TASK ASATTAR_TRUST_SCORE_POC.DQ_POC.TSK_COMPUTE_DQ_MEASUREMENTS RESUME;
*/


-------------------------------------------------------------------------------
-- SECTION E: VERIFY THE SP
--
-- One query, no downstream dependencies -- proves the SP wrote the 15
-- measurements it should have. Should return 15 rows immediately after the
-- CALL in Section C, with very recent MEASUREMENT_TIME values.
--
-- The end-to-end verification (bridge view + dimension scores) lives at
-- the bottom of ddl/seed/22a_seed_pnc_dmf_dataset_map.sql -- it has to
-- live there because it depends on files 21, 22, AND 22a all having run.
-------------------------------------------------------------------------------

SELECT
    TABLE_NAME
  , METRIC_NAME
  , ARRAY_TO_STRING(ARGUMENTS_NAMES, ', ') AS COLUMNS
  , VALUE
  , MEASUREMENT_TIME
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL
WHERE MEASUREMENT_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
ORDER BY TABLE_NAME, METRIC_NAME, COLUMNS;


-------------------------------------------------------------------------------
-- SECTION F: TEAR-DOWN  (optional)
-------------------------------------------------------------------------------

/*
DROP PROCEDURE IF EXISTS ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS();
DROP TABLE     IF EXISTS ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL;
-- DROP TASK   IF EXISTS ASATTAR_TRUST_SCORE_POC.DQ_POC.TSK_COMPUTE_DQ_MEASUREMENTS;  -- if Section D was used
*/
