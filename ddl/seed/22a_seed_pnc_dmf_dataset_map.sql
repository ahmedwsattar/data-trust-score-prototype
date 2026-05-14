-------------------------------------------------------------------------------
-- 22a_seed_pnc_dmf_dataset_map.sql
-- Seeds the physical-to-logical map and DMF thresholds for the MVP tables
-- wired up by ddl/20_cortex_dq_setup.sql.
--
-- Two datasets registered:
--
--   DS_POSITION_REPORT  (Workday Position Report)
--     -> EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT
--     -> 9 thresholds (matches the 9 DMFs in Section C of file 20)
--     -> SLA = 168h (weekly load)
--
--   DS_TRENDED_REPORT   (Workday Trended Report)
--     -> EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT
--     -> 6 thresholds (matches the 6 DMFs in Section D of file 20)
--     -> SLA = 840h (monthly load, 35 days)
--
-- Tweak THRESHOLD_VALUE / SEVERITY_ON_FAIL freely -- this is exactly the
-- governance surface (Ella owns the semantics; PNC stewards own the values).
-------------------------------------------------------------------------------

USE ROLE   DATA_CLEAN_ROOM_ROLE;
USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;


-- ============================================================================
-- DS_POSITION_REPORT
-- ============================================================================

-- Map ----------------------------------------------------------------------
DELETE FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP
 WHERE DATASET_ID = 'DS_POSITION_REPORT';

INSERT INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP
    (DATASET_ID, TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME, IS_PRIMARY_PHYSICAL, NOTES)
VALUES
    ('DS_POSITION_REPORT'
   , 'ASATTAR_TRUST_SCORE_POC'
   , 'DQ_POC'
   , 'DT_POSITION_REPORT'
   , TRUE
   , 'Workday Position Report -- POC mirror of EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT (weekly load).');


-- Thresholds ---------------------------------------------------------------
-- Weekly cadence; SLA_HOURS = 168 in PNC_SOURCE_CLASSIFICATION.
-- FRESHNESS hard ceiling = 2x SLA = 336h = 1,209,600s.
DELETE FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_THRESHOLDS
 WHERE DATASET_ID = 'DS_POSITION_REPORT';

INSERT INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_THRESHOLDS
    (DATASET_ID, METRIC_NAME, COLUMN_NAME, DIMENSION_CODE,
     THRESHOLD_OP, THRESHOLD_VALUE, SEVERITY_ON_FAIL, IS_KEY_COLUMN, NOTES)
VALUES
    -- Completeness on key columns (NULL_PERCENT returns 0..100)
    ('DS_POSITION_REPORT', 'NULL_PERCENT', 'POSITION_ID',           'COMPLETENESS_KEY_PROPS',
       '<=',  0.5,  'P1', TRUE,  'POSITION_ID is the PK; tolerate <=0.5% nulls')
  , ('DS_POSITION_REPORT', 'NULL_PERCENT', 'WORKER_EMPLOYEE_ID',    'COMPLETENESS_KEY_PROPS',
       '<=', 30.0,  'P2', TRUE,  'Vacant positions are valid; warn if >30% (suggests staffing data drop)')
  , ('DS_POSITION_REPORT', 'NULL_PERCENT', 'MANAGER_EMPLOYEE_ID',   'COMPLETENESS_KEY_PROPS',
       '<=',  5.0,  'P2', TRUE,  'Manager should be set for almost all positions; tolerate <=5% nulls')
  , ('DS_POSITION_REPORT', 'NULL_PERCENT', 'L1_EMPLOYEE_ID',        'COMPLETENESS_KEY_PROPS',
       '<=',  1.0,  'P1', TRUE,  'Top-of-hierarchy must be near-complete; tolerate <=1% nulls')

    -- Profiling
  , ('DS_POSITION_REPORT', 'DUPLICATE_COUNT', 'POSITION_ID, REPORT_EFFECTIVE_DATE', 'PROFILING',
       '<=',  0.0,  'P1', FALSE, 'Compound PK: positions repeat across snapshots, so the (position, snapshot effective date) tuple must be unique. Same row appearing twice within an effective-date snapshot indicates an ETL bug.')
  , ('DS_POSITION_REPORT', 'NULL_PERCENT', 'REPORT_EFFECTIVE_DATE', 'PROFILING',
       '<=',  0.0,  'P2', FALSE, 'Business effective date must always be set')
  , ('DS_POSITION_REPORT', 'NULL_PERCENT', 'LOADDATE',              'PROFILING',
       '<=',  0.0,  'P2', FALSE, 'Audit timestamp must always be set')
  , ('DS_POSITION_REPORT', 'ROW_COUNT',    '',                      'PROFILING',
       '>=', 1000.0, 'P2', FALSE, 'Volume floor of 1000 (catches accidental truncation)')

    -- Timeliness: FRESHNESS returns seconds. SLA = 168h * 3600 = 604,800s.
    -- Hard ceiling at 2x SLA = 336h = 1,209,600s; bridge view does linear
    -- decay against SLA_HOURS for DIM_TIMELINESS_SCORE.
  , ('DS_POSITION_REPORT', 'FRESHNESS',    'LOADDATE',              'TIMELINESS',
       '<=', 1209600.0, 'P3', FALSE, 'Hard ceiling = 2x SLA (336h for weekly cadence)');


-- ============================================================================
-- DS_TRENDED_REPORT
-- ============================================================================

-- Map ----------------------------------------------------------------------
DELETE FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP
 WHERE DATASET_ID = 'DS_TRENDED_REPORT';

INSERT INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP
    (DATASET_ID, TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME, IS_PRIMARY_PHYSICAL, NOTES)
VALUES
    ('DS_TRENDED_REPORT'
   , 'ASATTAR_TRUST_SCORE_POC'
   , 'DQ_POC'
   , 'DT_TRENDED_REPORT'
   , TRUE
   , 'Workday Trended Report -- POC mirror of EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT (monthly load).');


-- Thresholds ---------------------------------------------------------------
-- Monthly cadence; SLA_HOURS = 840 in PNC_SOURCE_CLASSIFICATION.
-- FRESHNESS hard ceiling = 2x SLA = 70d = 6,048,000s.
DELETE FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_THRESHOLDS
 WHERE DATASET_ID = 'DS_TRENDED_REPORT';

INSERT INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_THRESHOLDS
    (DATASET_ID, METRIC_NAME, COLUMN_NAME, DIMENSION_CODE,
     THRESHOLD_OP, THRESHOLD_VALUE, SEVERITY_ON_FAIL, IS_KEY_COLUMN, NOTES)
VALUES
    -- Completeness on key columns
    ('DS_TRENDED_REPORT', 'NULL_PERCENT', 'EMPLOYEEID',    'COMPLETENESS_KEY_PROPS',
       '<=',  5.0,  'P1', TRUE,  'EMPLOYEEID is the worker join key; tolerate <=5% nulls')
  , ('DS_TRENDED_REPORT', 'NULL_PERCENT', 'POSITIONID',    'COMPLETENESS_KEY_PROPS',
       '<=',  2.0,  'P1', TRUE,  'POSITIONID is the position key; tolerate <=2% nulls')

    -- Profiling
  , ('DS_TRENDED_REPORT', 'NULL_PERCENT', 'EFFECTIVEDATE', 'PROFILING',
       '<=',  0.0,  'P1', FALSE, 'EFFECTIVEDATE is the period grain; must never be NULL')
  , ('DS_TRENDED_REPORT', 'NULL_PERCENT', 'LOADDATE',      'PROFILING',
       '<=',  0.0,  'P2', FALSE, 'Audit timestamp must always be set')
  , ('DS_TRENDED_REPORT', 'ROW_COUNT',    '',              'PROFILING',
       '>=', 10000.0, 'P2', FALSE, 'Volume floor of 10K (trended rolls forward each period)')

    -- Timeliness vs monthly SLA
  , ('DS_TRENDED_REPORT', 'FRESHNESS',    'LOADDATE',      'TIMELINESS',
       '<=', 6048000.0, 'P3', FALSE, 'Hard ceiling = 2x SLA (70d) measured against LOADDATE');


-- ============================================================================
-- END-TO-END VERIFICATION
--
-- After this seed runs, all four pieces are in place:
--   - measurements (file 25 manual SP, OR file 20 native DMFs)
--   - logical-to-physical map (file 21)
--   - bridge views (file 22)
--   - thresholds (this file)
--
-- These two queries are the equivalent of file 25 Section E -- they're here
-- because they need the bridge view (file 22) and the threshold seed (this
-- file) to both exist. Run them once after this file finishes to confirm
-- the dashboard's data source is wired correctly.
-- ============================================================================

-- Latest reading per (dataset, metric, column), with PASS/FAIL vs threshold.
-- Should show 15 rows. STATUS column reflects the seeded thresholds above.
SELECT
    DATASET_ID
  , METRIC_NAME
  , COLUMN_NAME
  , VALUE
  , THRESHOLD_OP
  , THRESHOLD_VALUE
  , STATUS
  , SEVERITY_ON_FAIL
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DMF_LATEST_MEASUREMENTS
ORDER BY DATASET_ID, METRIC_NAME, COLUMN_NAME;

-- Per-dataset 0-100 scores for the four Cortex-DQ-covered Trust Score
-- dimensions (this is what the Streamlit Cortex DQ page reads).
SELECT
    DATASET_ID
  , DIM_ISSUES_SCORE
  , DIM_ISSUES_OPEN_P1
  , DIM_ISSUES_OPEN_P2
  , DIM_ISSUES_OPEN_P3
  , DIM_TIMELINESS_SCORE
  , DIM_TIMELINESS_HOURS_LATE
  , DIM_COMPLETENESS_KEY_PROPS_SCORE
  , DIM_COMPLETENESS_WORST_NULL_PCT
  , DIM_PROFILING_SCORE
  , DIM_PROFILING_CHECKS_PASSED
  , DIM_PROFILING_CHECKS_TOTAL
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DMF_DIMENSION_SCORES
ORDER BY DATASET_ID;
