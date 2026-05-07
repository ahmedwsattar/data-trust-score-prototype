-------------------------------------------------------------------------------
-- 91_seed_via_stage.sql  (alternative seed path)
--
-- Loads the synthetic CSVs in ../data/ via a named internal stage + COPY INTO.
-- Use this if you have SnowSQL (or a worksheet that supports PUT). For
-- pasted-into-worksheet loading, use the files in ddl/seed/ instead.
--
-- Workflow:
--   1. Run this file once, up to (and including) the CREATE STAGE line.
--   2. From SnowSQL, run the PUT commands listed below with the absolute
--      path to your local data/ folder substituted in.
--   3. Run the COPY INTO commands.
--   4. Run the trailing row-count SELECT to verify.
--
-- IMPORTANT: each COPY INTO uses an EXPLICIT column list +
-- SELECT $1, $2, ... FROM @stage. This avoids Snowflake's column-count
-- check (the CSVs only contain the columns the synthetic generator
-- populates; table columns absent from the CSV get their column DEFAULT
-- or NULL).
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

-- File format: simple CSV with a header row that we skip.
CREATE OR REPLACE FILE FORMAT ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV
    TYPE                         = CSV
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', 'NULL', 'nan', 'NaN', 'None')
    EMPTY_FIELD_AS_NULL          = TRUE
    TIMESTAMP_FORMAT             = 'AUTO'
    DATE_FORMAT                  = 'AUTO'
    TRIM_SPACE                   = TRUE
;

CREATE OR REPLACE STAGE ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED
    FILE_FORMAT = ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV;

-------------------------------------------------------------------------------
-- Run these from SnowSQL (or a worksheet that supports PUT). Substitute the
-- absolute path to your local data/ folder.
--
-- PUT 'file:///Users/<you>/.../data-trust-score-prototype/data/PNC_TRUST_SCORE_WEIGHTS.csv'      @STG_TRUST_SCORE_SEED OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
-- PUT 'file:///Users/<you>/.../data-trust-score-prototype/data/PNC_SOURCE_CLASSIFICATION.csv'   @STG_TRUST_SCORE_SEED OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
-- PUT 'file:///Users/<you>/.../data-trust-score-prototype/data/PNC_DATA_OWNERSHIP_REGISTRY.csv' @STG_TRUST_SCORE_SEED OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
-- PUT 'file:///Users/<you>/.../data-trust-score-prototype/data/PNC_KEY_PROPERTY_REGISTRY.csv'   @STG_TRUST_SCORE_SEED OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
-- PUT 'file:///Users/<you>/.../data-trust-score-prototype/data/PNC_DQ_RESULTS.csv'              @STG_TRUST_SCORE_SEED OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
-- PUT 'file:///Users/<you>/.../data-trust-score-prototype/data/PNC_DQ_DIMENSION_RESULTS.csv'    @STG_TRUST_SCORE_SEED OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
-------------------------------------------------------------------------------

-- (Optional) clear out partial loads from any earlier failed attempt.
-- TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_TRUST_SCORE_WEIGHTS;
-- TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION;
-- TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_OWNERSHIP_REGISTRY;
-- TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_KEY_PROPERTY_REGISTRY;
-- TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_RESULTS;
-- TRUNCATE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_DIMENSION_RESULTS;


-------------------------------------------------------------------------------
-- 1. PNC_TRUST_SCORE_WEIGHTS  (CSV: 4 cols, table: 8; remaining cols default)
-------------------------------------------------------------------------------
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_TRUST_SCORE_WEIGHTS (
    DIMENSION_CODE, DIMENSION_NAME, WEIGHT_PCT, EFFECTIVE_FROM
)
FROM (
    SELECT $1, $2, $3, $4
    FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PNC_TRUST_SCORE_WEIGHTS.csv
)
FILE_FORMAT = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
ON_ERROR    = 'ABORT_STATEMENT';


-------------------------------------------------------------------------------
-- 2. PNC_SOURCE_CLASSIFICATION  (CSV: 13 cols, table: 14; CREATED_AT defaults)
-------------------------------------------------------------------------------
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION (
    DATASET_ID, DATASET_NAME, DATASET_FQN, SOURCE_SYSTEM, SOURCE_DOMAIN,
    LAYER, CLASSIFICATION_TIER, IS_APM_REGISTERED, IS_SOX_RELEVANT,
    LOAD_FREQUENCY, SLA_HOURS, UPDATED_AT, UPDATED_BY
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13
    FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PNC_SOURCE_CLASSIFICATION.csv
)
FILE_FORMAT = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
ON_ERROR    = 'ABORT_STATEMENT';


-------------------------------------------------------------------------------
-- 3. PNC_DATA_OWNERSHIP_REGISTRY  (CSV: 16 cols, table: 18)
-------------------------------------------------------------------------------
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_OWNERSHIP_REGISTRY (
    DATASET_ID, DATASET_NAME, DATASET_FQN, DOMAIN,
    BUSINESS_OWNER_NAME, BUSINESS_OWNER_EMAIL,
    DATA_STEWARD_NAME, DATA_STEWARD_EMAIL,
    TECHNICAL_OWNER_NAME, TECHNICAL_OWNER_EMAIL,
    ASSIGNMENT_STATUS, LAST_CONFIRMED_DATE, NEXT_REVIEW_DUE_DATE,
    NOTES, UPDATED_AT, UPDATED_BY
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
           $11, $12, $13, $14, $15, $16
    FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PNC_DATA_OWNERSHIP_REGISTRY.csv
)
FILE_FORMAT = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
ON_ERROR    = 'ABORT_STATEMENT';


-------------------------------------------------------------------------------
-- 4. PNC_KEY_PROPERTY_REGISTRY  (CSV: 13 cols, table: 14)
-------------------------------------------------------------------------------
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_KEY_PROPERTY_REGISTRY (
    DATASET_ID, DATASET_NAME,
    KEY_FIELD_NAME, KEY_FIELD_ROLE,
    IS_REQUIRED, IS_PRESENT_IN_SCHEMA,
    HAS_APPROVED_DEFINITION, APPROVED_DEFINITION_TEXT, CATALOG_URL,
    LAST_PROFILED_AT, NULL_PCT, DISTINCT_COUNT, ROW_COUNT
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13
    FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PNC_KEY_PROPERTY_REGISTRY.csv
)
FILE_FORMAT = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
ON_ERROR    = 'ABORT_STATEMENT';


-------------------------------------------------------------------------------
-- 5. PNC_DQ_RESULTS  (CSV: 55 cols, table: 55 -- same shape, but list explicit)
-------------------------------------------------------------------------------
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_RESULTS (
    DATASET_ID, DATASET_NAME, DATASET_FQN, DOMAIN, LAYER, SCORE_RUN_DATE, BATCH_ID,
    DIM_OWNERSHIP_SCORE, DIM_OWNERSHIP_STATUS, DIM_OWNERSHIP_OWNER_NAME, DIM_OWNERSHIP_LAST_CONFIRMED,
    DIM_SOURCE_SCORE, DIM_SOURCE_STATUS, DIM_SOURCE_SYSTEM, DIM_SOURCE_TIER,
    DIM_ISSUES_SCORE, DIM_ISSUES_STATUS, DIM_ISSUES_OPEN_P1, DIM_ISSUES_OPEN_P2, DIM_ISSUES_OPEN_P3, DIM_ISSUES_LAST_FAILURE_AT,
    DIM_TIMELINESS_SCORE, DIM_TIMELINESS_STATUS, DIM_TIMELINESS_MAX_LOAD_DATE, DIM_TIMELINESS_SLA_HOURS, DIM_TIMELINESS_HOURS_LATE,
    DIM_COMPLETENESS_KEY_PROPS_SCORE, DIM_COMPLETENESS_KEY_PROPS_STATUS, DIM_COMPLETENESS_KEYS_CHECKED, DIM_COMPLETENESS_WORST_KEY, DIM_COMPLETENESS_WORST_KEY_NULL_PCT,
    DIM_PROFILING_SCORE, DIM_PROFILING_STATUS, DIM_PROFILING_CHECKS_TOTAL, DIM_PROFILING_CHECKS_PASSED,
    DIM_DEFINITIONS_SCORE, DIM_DEFINITIONS_STATUS, DIM_DEFINITIONS_FIELDS_TOTAL, DIM_DEFINITIONS_FIELDS_DEFINED,
    DIM_KEY_PROPERTIES_SCORE, DIM_KEY_PROPERTIES_STATUS, DIM_KEY_PROPERTIES_REQUIRED, DIM_KEY_PROPERTIES_PRESENT,
    DIM_USAGE_SCORE, DIM_USAGE_STATUS, DIM_USAGE_UNIQUE_CONSUMERS_30D, DIM_USAGE_QUERIES_30D,
    DIM_FEEDBACK_SCORE, DIM_FEEDBACK_STATUS, DIM_FEEDBACK_AVG_RATING, DIM_FEEDBACK_RESPONSES_90D,
    TRUST_SCORE_OVERALL, TRUST_SCORE_TIER,
    LOAD_DATE, LOAD_BY
)
FROM (
    SELECT  $1,  $2,  $3,  $4,  $5,  $6,  $7,
            $8,  $9, $10, $11,
           $12, $13, $14, $15,
           $16, $17, $18, $19, $20, $21,
           $22, $23, $24, $25, $26,
           $27, $28, $29, $30, $31,
           $32, $33, $34, $35,
           $36, $37, $38, $39,
           $40, $41, $42, $43,
           $44, $45, $46, $47,
           $48, $49, $50, $51,
           $52, $53,
           $54, $55
    FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PNC_DQ_RESULTS.csv
)
FILE_FORMAT = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
ON_ERROR    = 'ABORT_STATEMENT';


-------------------------------------------------------------------------------
-- 6. PNC_DQ_DIMENSION_RESULTS  (CSV: 8 cols, table: 12)
-------------------------------------------------------------------------------
COPY INTO ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_DIMENSION_RESULTS (
    DATASET_ID, DATASET_NAME, DOMAIN, SCORE_RUN_DATE,
    DIMENSION_CODE, DIMENSION_NAME, SCORE, STATUS
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8
    FROM @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/PNC_DQ_DIMENSION_RESULTS.csv
)
FILE_FORMAT = (FORMAT_NAME = 'ASATTAR_TRUST_SCORE_POC.DQ_POC.FF_TRUST_SCORE_CSV')
ON_ERROR    = 'ABORT_STATEMENT';


-------------------------------------------------------------------------------
-- Sanity check: row counts should be 10 / 7 / 7 / 17 / 637 / 6,370.
-------------------------------------------------------------------------------
SELECT 'PNC_TRUST_SCORE_WEIGHTS'      AS table_name, COUNT(*) AS row_count FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_TRUST_SCORE_WEIGHTS
UNION ALL SELECT 'PNC_SOURCE_CLASSIFICATION',     COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION
UNION ALL SELECT 'PNC_DATA_OWNERSHIP_REGISTRY',   COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_OWNERSHIP_REGISTRY
UNION ALL SELECT 'PNC_KEY_PROPERTY_REGISTRY',     COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_KEY_PROPERTY_REGISTRY
UNION ALL SELECT 'PNC_DQ_RESULTS',                COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_RESULTS
UNION ALL SELECT 'PNC_DQ_DIMENSION_RESULTS',      COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_DIMENSION_RESULTS
;
