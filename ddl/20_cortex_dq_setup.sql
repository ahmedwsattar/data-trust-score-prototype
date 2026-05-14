-------------------------------------------------------------------------------
-- 20_cortex_dq_setup.sql
-- Cortex Data Quality / DMF instrumentation for the MVP.
--
-- Wires Snowflake's native Data Metric Functions (DMFs) into the two real
-- P&C tables (mirrored into the POC schema from the production EDL DDL --
-- see ddl/DT_POSITION_REPORT.sql + ddl/DT_TRENDED_REPORT.sql) so the four
-- trust-score dimensions that Cortex DQ natively covers get measured by
-- the platform itself instead of bespoke logic:
--
--   #3 Active Issues                 -> count of failing DMFs by severity
--   #4 Timeliness                    -> SNOWFLAKE.CORE.FRESHNESS(LOADDATE)
--   #5 Completeness of Key Properties-> SNOWFLAKE.CORE.NULL_PERCENT on key cols
--   #6 Data Profiling                -> NULL_PERCENT, DUPLICATE_COUNT, ROW_COUNT
--
-- The other six trust-score dimensions (Ownership, Source classification,
-- Definitions, Key Properties, Usage, Feedback) remain registry-driven --
-- Cortex DQ doesn't measure them and shouldn't pretend to.
--
-- Target tables (deploy first via ddl/DT_POSITION_REPORT.sql,
-- ddl/DT_TRENDED_REPORT.sql, ddl/ALTER_DT_TRENDED_REPORT.sql):
--
--   ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT  (one row per position; weekly load)
--   ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT   (one row per (employee, period); monthly load)
--
-- These map to DATASET_ID 'DS_POSITION_REPORT' and 'DS_TRENDED_REPORT' in
-- the trust-score catalog (see ddl/04_pnc_source_classification.sql for the
-- SLA values that drive DIM_TIMELINESS_SCORE in the bridge view).
--
-- Run order (MVP):
--   ddl/00_setup.sql
--   ddl/01..10..91*.sql                          (existing prototype scaffolding)
--   ddl/DT_POSITION_REPORT.sql                   <-- create the real table
--   ddl/DT_TRENDED_REPORT.sql                    <-- create the real table
--   ddl/ALTER_DT_TRENDED_REPORT.sql              <-- additive columns
--   load data via internal stage + COPY INTO     <-- your data load step
--   ddl/20_cortex_dq_setup.sql                   <-- this file
--   ddl/21_pnc_dmf_dataset_map.sql               <-- map + thresholds tables
--   ddl/22_vw_pnc_dmf_dimension_scores.sql       <-- bridge views
--   ddl/seed/22a_seed_pnc_dmf_dataset_map.sql    <-- maps + thresholds for both datasets
--
-- Idempotency: SET DATA_METRIC_SCHEDULE is idempotent. ADD DATA METRIC
-- FUNCTION errors if the DMF is already attached -- re-runs should use
-- Section F (tear-down) first, or selectively skip the ADDs that errored.
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- SECTION A: ONE-TIME ACCOUNT PREREQUISITES (needs ACCOUNTADMIN)
--
-- Privileges the working role needs on the account/Snowflake schemas:
--
--   1. EXECUTE DATA METRIC FUNCTION  -- to attach DMFs to owned objects
--   2. SNOWFLAKE.DATA_METRIC_USER    -- to read DATA_QUALITY_MONITORING_RESULTS
--                                       and call SNOWFLAKE.CORE.* DMFs
--   3. SNOWFLAKE.CORTEX_USER         -- only for the Snowsight AI-suggestion UX
--
-- The working role for this POC is DATA_CLEAN_ROOM_ROLE -- it owns
-- ASATTAR_TRUST_SCORE_POC.DQ_POC and therefore the mirrored DT_* tables
-- created by ddl/DT_*.sql. No cross-database grants are needed because
-- everything lives inside ASATTAR_TRUST_SCORE_POC.
-------------------------------------------------------------------------------

/*  -- BEGIN ACCOUNTADMIN BLOCK  -----------------------------------------------

USE ROLE ACCOUNTADMIN;

GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE DATA_CLEAN_ROOM_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE DATA_CLEAN_ROOM_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER      TO ROLE DATA_CLEAN_ROOM_ROLE;  -- optional

-- Confirm both LLMs Cortex DQ needs are allowlisted (only relevant for the
-- AI-suggestion UI; the manual SQL DMF path below works without them):
SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;
-- If 'mistral-7b' and 'llama3.1-8b' are missing:
-- ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = 'mistral-7b,llama3.1-8b,...';

    -- END ACCOUNTADMIN BLOCK  -------------------------------------------- */


-------------------------------------------------------------------------------
-- SECTION B: VERIFY ACCESS + INSPECT THE TARGETS
--
-- Run these once to confirm the working role can SEE the tables and that
-- the columns the DMFs in Section C reference actually exist. If a column
-- is missing, edit Section C before running it.
-------------------------------------------------------------------------------

USE ROLE      DATA_CLEAN_ROOM_ROLE;       -- swap if a different role owns the tables
USE WAREHOUSE WH_DEFAULT;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;

-- Schema spot-check
SELECT TABLE_NAME, ROW_COUNT, BYTES, LAST_ALTERED
  FROM ASATTAR_TRUST_SCORE_POC.INFORMATION_SCHEMA.TABLES
 WHERE TABLE_SCHEMA = 'DQ_POC'
   AND TABLE_NAME IN ('DT_POSITION_REPORT', 'DT_TRENDED_REPORT')
 ORDER BY TABLE_NAME;

-- Column-existence check for the keys + load timestamp the DMFs reference
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
  FROM ASATTAR_TRUST_SCORE_POC.INFORMATION_SCHEMA.COLUMNS
 WHERE TABLE_SCHEMA = 'DQ_POC'
   AND TABLE_NAME IN ('DT_POSITION_REPORT', 'DT_TRENDED_REPORT')
   AND COLUMN_NAME IN (
        -- DT_POSITION_REPORT
        'POSITION_ID', 'WORKER_EMPLOYEE_ID', 'MANAGER_EMPLOYEE_ID', 'L1_EMPLOYEE_ID',
        'REPORT_EFFECTIVE_DATE',
        -- DT_TRENDED_REPORT
        'EMPLOYEEID', 'POSITIONID', 'EFFECTIVEDATE',
        -- both
        'LOADDATE'
   )
 ORDER BY TABLE_NAME, COLUMN_NAME;

-- Quick null/dup spot-check on DT_POSITION_REPORT (so thresholds are sane)
SELECT
    COUNT(*)                                                       AS row_count
  , COUNT_IF(POSITION_ID         IS NULL) / NULLIF(COUNT(*),0) * 100 AS position_id_null_pct
  , COUNT_IF(WORKER_EMPLOYEE_ID  IS NULL) / NULLIF(COUNT(*),0) * 100 AS worker_id_null_pct
  , COUNT_IF(MANAGER_EMPLOYEE_ID IS NULL) / NULLIF(COUNT(*),0) * 100 AS manager_id_null_pct
  , COUNT_IF(LOADDATE            IS NULL) / NULLIF(COUNT(*),0) * 100 AS loaddate_null_pct
  , COUNT(*) - COUNT(DISTINCT POSITION_ID, REPORT_EFFECTIVE_DATE)     AS position_snapshot_duplicates
  , MAX(LOADDATE)                                                     AS most_recent_load
  FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT;

-- Quick null spot-check on DT_TRENDED_REPORT
SELECT
    COUNT(*)                                                  AS row_count
  , COUNT_IF(EMPLOYEEID    IS NULL) / NULLIF(COUNT(*),0) * 100 AS employeeid_null_pct
  , COUNT_IF(POSITIONID    IS NULL) / NULLIF(COUNT(*),0) * 100 AS positionid_null_pct
  , COUNT_IF(EFFECTIVEDATE IS NULL) / NULLIF(COUNT(*),0) * 100 AS effectivedate_null_pct
  , COUNT_IF(LOADDATE      IS NULL) / NULLIF(COUNT(*),0) * 100 AS loaddate_null_pct
  , MIN(EFFECTIVEDATE)                                         AS oldest_period
  , MAX(EFFECTIVEDATE)                                         AS newest_period
  , MAX(LOADDATE)                                              AS most_recent_load
  FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT;


-------------------------------------------------------------------------------
-- SECTION C: ATTACH DMFs TO DT_POSITION_REPORT
--
-- Schedule first, then attach. CRON 0 7 * * * UTC = 02:00 ET, after typical
-- overnight loads. The position report loads weekly per the synthetic catalog
-- (SLA = 168h), so daily checks are appropriate.
--
-- Nine DMFs across the four feedable dimensions:
--
--   ROW_COUNT()                              -> dim #6 profiling (volume baseline)
--   DUPLICATE_COUNT(POSITION_ID, REPORT_EFFECTIVE_DATE)
--                                            -> dim #6 profiling (compound PK
--                                               uniqueness; positions repeat
--                                               across snapshots, so the real
--                                               PK is the (position, snapshot
--                                               effective date) tuple)
--   NULL_PERCENT(POSITION_ID)                -> dim #5 completeness (PK)
--   NULL_PERCENT(WORKER_EMPLOYEE_ID)         -> dim #5 completeness (worker key)
--   NULL_PERCENT(MANAGER_EMPLOYEE_ID)        -> dim #5 completeness (mgr key)
--   NULL_PERCENT(L1_EMPLOYEE_ID)             -> dim #5 completeness (top-of-hierarchy)
--   NULL_PERCENT(REPORT_EFFECTIVE_DATE)      -> dim #6 profiling (business date)
--   NULL_PERCENT(LOADDATE)                   -> dim #6 profiling (audit)
--   FRESHNESS(LOADDATE)                      -> dim #4 timeliness vs SLA_HOURS
-------------------------------------------------------------------------------

USE ROLE DATA_CLEAN_ROOM_ROLE;

ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 7 * * * UTC';

ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT             ON ();
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT       ON (POSITION_ID, REPORT_EFFECTIVE_DATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (POSITION_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (WORKER_EMPLOYEE_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (MANAGER_EMPLOYEE_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (L1_EMPLOYEE_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (REPORT_EFFECTIVE_DATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (LOADDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS             ON (LOADDATE);


-------------------------------------------------------------------------------
-- SECTION D: ATTACH DMFs TO DT_TRENDED_REPORT
--
-- Six DMFs. The trended report has grain (EMPLOYEEID, EFFECTIVEDATE), so
-- DUPLICATE_COUNT on either column alone is duplicate-by-design and not
-- attached -- NULL_PERCENT(EFFECTIVEDATE) is the more meaningful integrity
-- check at this grain.
--
--   ROW_COUNT()                       -> dim #6 profiling
--   NULL_PERCENT(EMPLOYEEID)          -> dim #5 completeness (worker key)
--   NULL_PERCENT(POSITIONID)          -> dim #5 completeness (position key)
--   NULL_PERCENT(EFFECTIVEDATE)       -> dim #6 profiling (period grain integrity)
--   NULL_PERCENT(LOADDATE)            -> dim #6 profiling (audit)
--   FRESHNESS(LOADDATE)               -> dim #4 timeliness vs SLA_HOURS
-------------------------------------------------------------------------------

ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 7 * * * UTC';

ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT             ON ();
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (EMPLOYEEID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (POSITIONID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (EFFECTIVEDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT          ON (LOADDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS             ON (LOADDATE);


-------------------------------------------------------------------------------
-- SECTION E: VALIDATION
--
-- The first scheduled run lands at the next CRON tick. To get an instant
-- measurement during an MVP demo, call each DMF inline -- the result
-- returns immediately and ALSO appears in DATA_QUALITY_MONITORING_RESULTS.
-------------------------------------------------------------------------------

-- Inline measurements for DT_POSITION_REPORT
SELECT SNOWFLAKE.CORE.ROW_COUNT(SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)                          AS row_count;
SELECT SNOWFLAKE.CORE.DUPLICATE_COUNT(SELECT POSITION_ID, REPORT_EFFECTIVE_DATE FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT) AS dup_count_position_snapshot;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT POSITION_ID       FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)       AS null_pct_position_id;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT WORKER_EMPLOYEE_ID  FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)     AS null_pct_worker_id;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT MANAGER_EMPLOYEE_ID FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)     AS null_pct_manager_id;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT L1_EMPLOYEE_ID    FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)       AS null_pct_l1_id;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT REPORT_EFFECTIVE_DATE FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)   AS null_pct_eff_date;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT LOADDATE          FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)       AS null_pct_loaddate;
SELECT SNOWFLAKE.CORE.FRESHNESS(SELECT LOADDATE             FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)       AS freshness_secs;

-- Inline measurements for DT_TRENDED_REPORT
SELECT SNOWFLAKE.CORE.ROW_COUNT(SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT)                           AS row_count;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT EMPLOYEEID        FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT)        AS null_pct_employeeid;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT POSITIONID        FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT)        AS null_pct_positionid;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT EFFECTIVEDATE     FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT)        AS null_pct_effectivedate;
SELECT SNOWFLAKE.CORE.NULL_PERCENT(SELECT LOADDATE          FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT)        AS null_pct_loaddate;
SELECT SNOWFLAKE.CORE.FRESHNESS(SELECT LOADDATE             FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT)        AS freshness_secs;

-- Confirm DMFs are attached to both tables.
SELECT *
  FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
        REF_ENTITY_NAME   => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT'
      , REF_ENTITY_DOMAIN => 'TABLE'));

SELECT *
  FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
        REF_ENTITY_NAME   => 'ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT'
      , REF_ENTITY_DOMAIN => 'TABLE'));

-- Read scheduled measurements (populates within minutes of the next CRON
-- tick; inline calls above appear here too).
SELECT
    measurement_time
  , table_name
  , metric_name
  , arguments_names
  , value
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE table_database = 'ASATTAR_TRUST_SCORE_POC'
  AND table_schema   = 'DQ_POC'
  AND table_name IN ('DT_POSITION_REPORT', 'DT_TRENDED_REPORT')
ORDER BY measurement_time DESC, table_name, metric_name
LIMIT 200;


-------------------------------------------------------------------------------
-- SECTION F: TAG-BASED DMFs (optional; powerful demo of "scale automatically")
--
-- Both tables are heavily PII-tagged with ADMIN_DB.ADMIN_SCH.WPII_*.
-- Snowflake supports ALTER TAG ... ADD DATA METRIC FUNCTION, which attaches
-- a DMF to *every column carrying the tag* in the account -- including new
-- columns added later. Two examples:
--
--   - WPII_ALPHANUM_ID is on every employee/position/manager identifier
--     column in DT_POSITION_REPORT (and similar in DT_TRENDED_REPORT).
--     Attaching NULL_PERCENT once means every ID column gets monitored
--     with no per-column ALTER.
--
--   - WPII_DATE is on every PII-relevant date column. Monitoring those
--     for null rates flags ingestion drops in workforce date attributes.
--
-- Caveat: the role running ALTER TAG ... ADD DATA METRIC FUNCTION needs
-- OWNERSHIP on the tag (or APPLY DATA METRIC FUNCTION privilege on the
-- tag), which typically sits with the tag-management team (ADMIN_DB owners)
-- not the data team. Treat this section as "nice to have, gated on a
-- one-time cross-team grant" -- the per-column DMFs in C/D give you the
-- MVP signal without it.
-------------------------------------------------------------------------------

/*  -- BEGIN OPTIONAL TAG-BASED BLOCK  -----------------------------------------

USE ROLE DATA_CLEAN_ROOM_ROLE;  -- needs OWNERSHIP / APPLY on the tag

-- Every column tagged WPII_ALPHANUM_ID across the account gets NULL_PERCENT.
ALTER TAG ADMIN_DB.ADMIN_SCH.WPII_ALPHANUM_ID
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT
  ON (VARCHAR);

-- Every column tagged WPII_DATE across the account gets NULL_PERCENT.
ALTER TAG ADMIN_DB.ADMIN_SCH.WPII_DATE
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT
  ON (DATE);

-- Verify: every column the tag is on now has the DMF attached.
SELECT *
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
 WHERE TAG_NAME = 'WPII_ALPHANUM_ID'
   AND OBJECT_DATABASE = 'ASATTAR_TRUST_SCORE_POC'
 ORDER BY OBJECT_NAME, COLUMN_NAME;

    -- END OPTIONAL TAG-BASED BLOCK  -------------------------------------- */


-------------------------------------------------------------------------------
-- SECTION G: TEAR-DOWN (optional)
--
-- If you want to retire DMFs (e.g. before re-running the script), uncomment
-- and run as the table-owning role:
-------------------------------------------------------------------------------

/*
USE ROLE DATA_CLEAN_ROOM_ROLE;

-- DT_POSITION_REPORT
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT       ON ();
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (POSITION_ID, REPORT_EFFECTIVE_DATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (POSITION_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (WORKER_EMPLOYEE_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (MANAGER_EMPLOYEE_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (L1_EMPLOYEE_ID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (REPORT_EFFECTIVE_DATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (LOADDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS       ON (LOADDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT UNSET DATA_METRIC_SCHEDULE;

-- DT_TRENDED_REPORT
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT       ON ();
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (EMPLOYEEID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (POSITIONID);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (EFFECTIVEDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_PERCENT    ON (LOADDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  DROP DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS       ON (LOADDATE);
ALTER TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT  UNSET DATA_METRIC_SCHEDULE;
*/


-------------------------------------------------------------------------------
-- SECTION H: FALLBACK -- proxy view if you don't have OWNERSHIP on the tables
--
-- If your role only has SELECT (not OWNERSHIP) on the target tables, the
-- ALTER TABLE statements in Sections C/D will fail with "Insufficient
-- privileges". (The POC sidesteps this by mirroring the EDL DDL into
-- ASATTAR_TRUST_SCORE_POC.DQ_POC, where DATA_CLEAN_ROOM_ROLE owns the
-- tables.) If you ever want to point DMFs at a real EDL table you don't
-- own, the workaround is to create a projection view in a schema you own
-- and attach DMFs to the view instead. Snowflake supports
-- ALTER VIEW ... ADD DATA METRIC FUNCTION; the DMF runner executes the
-- view's SELECT and measures the result rows. See git history of this file
-- for the working proxy-view pattern (renamed to VW_TMP_PNC_TRENDED_REPORT_DMF
-- in the prior POC version). Update PNC_DMF_DATASET_MAP rows to point at
-- the view's TABLE_DATABASE / TABLE_SCHEMA / TABLE_NAME if you go this way.
-------------------------------------------------------------------------------
