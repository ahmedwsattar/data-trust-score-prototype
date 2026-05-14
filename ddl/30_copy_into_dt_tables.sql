-------------------------------------------------------------------------------
-- 30_copy_into_dt_tables.sql
-- Loads the Workday extract CSVs from an internal stage into the POC mirror
-- tables created by ddl/DT_POSITION_REPORT.sql + ddl/DT_TRENDED_REPORT.sql.
--
-- Stage layout (both files uploaded at stage root):
--   @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/TrendedReport.csv
--   @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PositionReport.csv
--
-- Run order: after the three DT_*.sql files, before ddl/20_cortex_dq_setup.sql.
-- (DMFs work on empty tables, but the inline measurements in file 20 Section E
-- are only meaningful once rows are loaded.)
--
-- Loading strategy: MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE so the CSV column
-- order doesn't have to match the table's column order -- Snowflake matches
-- by header name, ignores extras, and writes NULL for any table column the
-- CSV is missing. Robust to Workday extract drift and far less fragile than
-- positional loading on a 100+ column table.
-------------------------------------------------------------------------------

USE ROLE      DATA_CLEAN_ROOM_ROLE;
USE WAREHOUSE WH_DEFAULT;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;


-------------------------------------------------------------------------------
-- SECTION A: PRE-FLIGHT
--
-- The stage is assumed to exist (you uploaded a file to it). The CREATE
-- statement below is idempotent and safe to leave in -- it just documents
-- where the stage lives so the script is self-contained.
-------------------------------------------------------------------------------

CREATE STAGE IF NOT EXISTS ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED
  COMMENT = 'Internal stage for Trust Score MVP raw uploads (Workday extracts).';

-- Confirm the file is where the COPY expects it.
LIST @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED;


-------------------------------------------------------------------------------
-- SECTION B: FILE FORMAT
--
-- Workday-style CSV with header row and quoted fields. PARSE_HEADER = TRUE
-- is required for MATCH_BY_COLUMN_NAME to work in Section C/D. NULL_IF
-- catches the values Workday uses for "no value" so they land as NULL
-- instead of literal strings.
-------------------------------------------------------------------------------

CREATE OR REPLACE FILE FORMAT ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV
  TYPE                          = CSV
  PARSE_HEADER                  = TRUE
  FIELD_DELIMITER               = ','
  FIELD_OPTIONALLY_ENCLOSED_BY  = '"'
  ESCAPE_UNENCLOSED_FIELD       = NONE
  TRIM_SPACE                    = TRUE
  EMPTY_FIELD_AS_NULL           = TRUE
  NULL_IF                       = ('', 'NULL', 'null', 'N/A', '\\N')
  DATE_FORMAT                   = 'AUTO'
  TIMESTAMP_FORMAT              = 'AUTO'
  REPLACE_INVALID_CHARACTERS    = TRUE
  ENCODING                      = 'UTF8';


-------------------------------------------------------------------------------
-- SECTION C: LOAD DT_TRENDED_REPORT
--
-- Snowflake forbids combining MATCH_BY_COLUMN_NAME with VALIDATION_MODE
-- (the former is treated as a "transform" COPY, the latter only supports
-- plain file-to-table). So instead of a VALIDATION_MODE dry run, the
-- pre-flight uses INFER_SCHEMA + a header diff -- this directly surfaces
-- the failure mode MATCH_BY_COLUMN_NAME hides (silently dropped columns
-- when a CSV header doesn't match any table column).
--
-- Steps:
--   1. Preview the headers Snowflake reads from the CSV.
--   2. Diff CSV headers vs DT_TRENDED_REPORT columns -- anything in the
--      diff would be silently ignored by the COPY. Fix the CSV header (or
--      add the column to the table) before continuing.
--   3. Run the COPY with ON_ERROR = 'CONTINUE' so individual bad rows get
--      logged instead of aborting the batch.
--   4. Inspect rejected rows via TABLE(VALIDATE(..., '_LAST')).
-------------------------------------------------------------------------------

-- Step 1: preview CSV headers (these are what MATCH_BY_COLUMN_NAME tries
-- to match against the table, case-insensitively).
SELECT COLUMN_NAME, TYPE, ORDER_ID
FROM TABLE(
  INFER_SCHEMA(
    LOCATION    => '@ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/TrendedReport.csv'
  , FILE_FORMAT => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV'
  )
)
ORDER BY ORDER_ID;

-- Step 2: header diff -- CSV columns that won't land anywhere.
-- Empty result = every CSV header has a matching table column = safe to load.
WITH csv AS (
  SELECT UPPER(COLUMN_NAME) AS col
  FROM TABLE(
    INFER_SCHEMA(
      LOCATION    => '@ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/TrendedReport.csv'
    , FILE_FORMAT => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV'
    )
  )
)
, tbl AS (
  SELECT UPPER(COLUMN_NAME) AS col
  FROM ASATTAR_TRUST_SCORE_POC.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'DQ_POC'
    AND TABLE_NAME   = 'DT_TRENDED_REPORT'
)
SELECT csv.col AS unmatched_csv_header
  FROM csv LEFT JOIN tbl USING (col)
 WHERE tbl.col IS NULL
 ORDER BY 1;

-- Step 3: load.
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/TrendedReport.csv
  FILE_FORMAT          = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA     = (LOADDATE = METADATA$START_SCAN_TIME, FILENAME = METADATA$FILENAME)
  ON_ERROR             = 'CONTINUE';

-- INCLUDE_METADATA notes:
--   LOADDATE  -- Snowflake's metadata-driven load timestamp. Lets the
--                FRESHNESS DMF read a real load time even if the CSV doesn't
--                carry one. Remove this clause to let the CSV's own LOADDATE
--                column win instead.
--   FILENAME  -- audit breadcrumb so per-row provenance is queryable later.

-- Step 4: inspect any rejected rows from the most recent COPY.
SELECT *
  FROM TABLE(VALIDATE(ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT, JOB_ID => '_LAST'));


-------------------------------------------------------------------------------
-- SECTION D: LOAD DT_POSITION_REPORT
--
-- Same 4-step pattern as Section C: preview headers, diff against table,
-- COPY, then inspect rejects.
-------------------------------------------------------------------------------

-- Step 1: preview CSV headers
SELECT COLUMN_NAME, TYPE, ORDER_ID
FROM TABLE(
  INFER_SCHEMA(
    LOCATION    => '@ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PositionReport.csv'
  , FILE_FORMAT => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV'
  )
)
ORDER BY ORDER_ID;

-- Step 2: header diff
WITH csv AS (
  SELECT UPPER(COLUMN_NAME) AS col
  FROM TABLE(
    INFER_SCHEMA(
      LOCATION    => '@ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PositionReport.csv'
    , FILE_FORMAT => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV'
    )
  )
)
, tbl AS (
  SELECT UPPER(COLUMN_NAME) AS col
  FROM ASATTAR_TRUST_SCORE_POC.INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'DQ_POC'
    AND TABLE_NAME   = 'DT_POSITION_REPORT'
)
SELECT csv.col AS unmatched_csv_header
  FROM csv LEFT JOIN tbl USING (col)
 WHERE tbl.col IS NULL
 ORDER BY 1;

-- Step 3: load
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PositionReport.csv
  FILE_FORMAT          = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA     = (LOADDATE = METADATA$START_SCAN_TIME, FILENAME = METADATA$FILENAME)
  ON_ERROR             = 'CONTINUE';

-- Step 4: inspect rejects
SELECT *
  FROM TABLE(VALIDATE(ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT, JOB_ID => '_LAST'));


-------------------------------------------------------------------------------
-- SECTION E: POST-LOAD VALIDATION
--
-- Mirrors Section B of file 20 -- the same null/dup profile the Cortex DQ
-- thresholds in 22a_seed_*.sql were tuned against. If anything looks off
-- (e.g. EMPLOYEEID null rate >> seed threshold), revisit the thresholds
-- before running file 20 so the dashboard's first reading is meaningful.
-------------------------------------------------------------------------------

-- Recent COPY history for the trended table
SELECT
    TABLE_NAME
  , FILE_NAME
  , STATUS
  , ROW_COUNT
  , ROW_PARSED
  , ERROR_COUNT
  , LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT'
      , START_TIME => DATEADD('hour', -24, CURRENT_TIMESTAMP())))
ORDER BY LAST_LOAD_TIME DESC;

-- Recent COPY history for the position table
SELECT
    TABLE_NAME
  , FILE_NAME
  , STATUS
  , ROW_COUNT
  , ROW_PARSED
  , ERROR_COUNT
  , LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT'
      , START_TIME => DATEADD('hour', -24, CURRENT_TIMESTAMP())))
ORDER BY LAST_LOAD_TIME DESC;

-- Trended-report profile (matches the seeded thresholds for DS_TRENDED_REPORT)
SELECT
    'DT_TRENDED_REPORT'                                        AS table_name
  , COUNT(*)                                                   AS row_count
  , COUNT_IF(EMPLOYEEID    IS NULL) / NULLIF(COUNT(*),0) * 100 AS employeeid_null_pct
  , COUNT_IF(POSITIONID    IS NULL) / NULLIF(COUNT(*),0) * 100 AS positionid_null_pct
  , COUNT_IF(EFFECTIVEDATE IS NULL) / NULLIF(COUNT(*),0) * 100 AS effectivedate_null_pct
  , COUNT_IF(LOADDATE      IS NULL) / NULLIF(COUNT(*),0) * 100 AS loaddate_null_pct
  , MIN(EFFECTIVEDATE)                                         AS oldest_period
  , MAX(EFFECTIVEDATE)                                         AS newest_period
  , MAX(LOADDATE)                                              AS most_recent_load
  FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT;

-- Position-report profile (matches the seeded thresholds for DS_POSITION_REPORT).
-- NOTE: column names (POSITION_ID, WORKER_EMPLOYEE_ID, MANAGER_EMPLOYEE_ID,
-- L1_EMPLOYEE_ID, REPORT_EFFECTIVE_DATE) follow the snake_case convention
-- used in DT_POSITION_REPORT.sql. If your DDL ended up with camel-case
-- (e.g. POSITIONID), rename the columns below to match -- the seeded
-- thresholds in 22a_seed_*.sql also assume snake_case and would need the
-- same rename for consistency.
SELECT
    'DT_POSITION_REPORT'                                                AS table_name
  , COUNT(*)                                                            AS row_count
  , COUNT_IF(POSITION_ID         IS NULL) / NULLIF(COUNT(*),0) * 100    AS position_id_null_pct
  , COUNT_IF(WORKER_EMPLOYEE_ID  IS NULL) / NULLIF(COUNT(*),0) * 100    AS worker_employee_id_null_pct
  , COUNT_IF(MANAGER_EMPLOYEE_ID IS NULL) / NULLIF(COUNT(*),0) * 100    AS manager_employee_id_null_pct
  , COUNT_IF(L1_EMPLOYEE_ID      IS NULL) / NULLIF(COUNT(*),0) * 100    AS l1_employee_id_null_pct
  , COUNT_IF(REPORT_EFFECTIVE_DATE IS NULL) / NULLIF(COUNT(*),0) * 100  AS report_effective_date_null_pct
  , COUNT_IF(LOADDATE            IS NULL) / NULLIF(COUNT(*),0) * 100    AS loaddate_null_pct
  , COUNT(*) - COUNT(DISTINCT POSITION_ID, REPORT_EFFECTIVE_DATE)       AS position_snapshot_duplicates
  , MAX(LOADDATE)                                                       AS most_recent_load
  FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT;


-------------------------------------------------------------------------------
-- SECTION F: NEXT STEP
--
-- With data loaded, run ddl/20_cortex_dq_setup.sql Section E (the inline
-- DMF calls) for instant readings -- those will appear in
-- SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS within seconds and the
-- Streamlit Cortex DQ page will start showing live measurements.
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- SECTION G: RELOAD / TRUNCATE (optional)
--
-- COPY INTO is incremental by default -- files already loaded are skipped.
-- To force a reload (e.g. after correcting the upstream CSV), either:
--   1. Truncate and re-run the COPY:
--      TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT;
--   2. Or add FORCE = TRUE to the COPY (re-loads even if file was loaded
--      before -- creates duplicates if you don't truncate first).
-------------------------------------------------------------------------------

/*
TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT;
TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT;
*/
