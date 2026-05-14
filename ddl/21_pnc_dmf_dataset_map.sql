-------------------------------------------------------------------------------
-- 21_pnc_dmf_dataset_map.sql
-- Bridges Snowflake DMF results to the Trust Score model.
--
-- SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS identifies a measurement by
-- (table_database, table_schema, table_name) -- physical Snowflake identity.
-- The Trust Score uses DATASET_ID -- a logical identity. These two tables
-- bridge the gap and let governance configure pass/fail thresholds for each
-- DMF reading without changing code.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;


-------------------------------------------------------------------------------
-- PNC_DMF_DATASET_MAP
--
-- Physical-to-logical bridge. Add one row per (DATASET_ID, physical table)
-- pairing you want included in the trust score. Multiple physical tables
-- can roll up to a single DATASET_ID (e.g. silver + view).
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP (
    DATASET_ID            VARCHAR(64)  NOT NULL  -- FK -> PNC_SOURCE_CLASSIFICATION
  , TABLE_DATABASE        VARCHAR(255) NOT NULL
  , TABLE_SCHEMA          VARCHAR(255) NOT NULL
  , TABLE_NAME            VARCHAR(255) NOT NULL
  , IS_PRIMARY_PHYSICAL   BOOLEAN      NOT NULL DEFAULT TRUE  -- which row drives FRESHNESS / ROW_COUNT
  , NOTES                 VARCHAR(1024)
  , LOAD_DATE             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , CONSTRAINT PK_PNC_DMF_DATASET_MAP
      PRIMARY KEY (DATASET_ID, TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME)
);


-------------------------------------------------------------------------------
-- PNC_DMF_THRESHOLDS
--
-- One row per DMF reading we care about. Defines what "passing" means and
-- the priority of a failure (which then feeds the Active Issues dimension).
--
-- Examples:
--   NULL_PERCENT(TWID) on DS_POSITION_REPORT  -> max 5%, P1 if breached
--   FRESHNESS()        on DS_POSITION_REPORT  -> max 24h * 3600s, P2 if breached
--
-- METRIC_NAME matches the value SNOWFLAKE puts in DATA_QUALITY_MONITORING_RESULTS
-- (e.g. 'NULL_PERCENT', 'FRESHNESS', 'ROW_COUNT', 'DUPLICATE_COUNT').
-- COLUMN_NAME is the column the DMF was attached to ('' / NULL for table-level
-- DMFs like ROW_COUNT or no-arg FRESHNESS).
--
-- DIMENSION_CODE controls which trust-score dimension the reading rolls up to.
-- Allowed values: 'COMPLETENESS_KEY_PROPS', 'TIMELINESS', 'PROFILING'.
-- (ISSUES is derived automatically from FAILED rows across all dimensions.)
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_THRESHOLDS (
    DATASET_ID         VARCHAR(64)  NOT NULL
  , METRIC_NAME        VARCHAR(128) NOT NULL    -- 'NULL_PERCENT','FRESHNESS',...
  , COLUMN_NAME        VARCHAR(128)             -- '' / NULL for table-level
  , DIMENSION_CODE     VARCHAR(64)  NOT NULL    -- 'COMPLETENESS_KEY_PROPS','TIMELINESS','PROFILING'
  , THRESHOLD_OP       VARCHAR(8)   NOT NULL    -- '<=','>=','=','<','>'
  , THRESHOLD_VALUE    NUMBER(18,4) NOT NULL    -- pass if VALUE <op> THRESHOLD_VALUE
  , SEVERITY_ON_FAIL   VARCHAR(8)   NOT NULL    -- 'P1','P2','P3'
  , IS_KEY_COLUMN      BOOLEAN      NOT NULL DEFAULT FALSE  -- counts toward key-completeness
  , NOTES              VARCHAR(512)
  , LOAD_DATE          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , CONSTRAINT PK_PNC_DMF_THRESHOLDS
      PRIMARY KEY (DATASET_ID, METRIC_NAME, COLUMN_NAME)
);
