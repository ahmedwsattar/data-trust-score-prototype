-------------------------------------------------------------------------------
-- ddl/04_dts_scores.sql
-- v2 Data Trust Score -- score output tables (written by ddl/30 scoring engine).
--
--   DTS_ELEMENT_DIMENSION_SCORE : finest grain -- (object x element x dim x run).
--                                 0-100 per cell before rollup.
--   DTS_DATASET_TRUST_SCORE     : final per-(object, run) trust score with band,
--                                 measurable ceiling, and foundational-gap flag.
--
-- Both are CREATE OR REPLACE; the scoring engine TRUNCATE+INSERTs per run_date.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. DTS_ELEMENT_DIMENSION_SCORE
--    Element-grain dimension scores. For table-grain dimensions the
--    COLUMN_NAME is null (one row per object x dim). For DQ, rows can be per
--    column so the CDE multiplier applies at element grain.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_ELEMENT_DIMENSION_SCORE (
    SCORE_ROW_ID          NUMBER IDENTITY(1,1) PRIMARY KEY,
    REPORT_FAMILY         VARCHAR NOT NULL,
    LAYER                 VARCHAR NOT NULL,
    COLUMN_NAME           VARCHAR,                 -- null = table-grain
    DIMENSION_CODE        VARCHAR NOT NULL,
    RAW_SCORE             FLOAT,                   -- 0-100 before confidence/CDE; NULL = not measurable
    CONFIDENCE_FACTOR     FLOAT   NOT NULL DEFAULT 1.0,   -- layer factor (DQ/Obs only)
    CRITICALITY_MULTIPLIER FLOAT  NOT NULL DEFAULT 1.0,   -- 2.0 for CDE columns
    IS_MEASURABLE         BOOLEAN NOT NULL DEFAULT TRUE,  -- FALSE = unseeded foundational
    SCORE_RUN_DATE        DATE    NOT NULL DEFAULT CURRENT_DATE(),
    CREATED_AT            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
COMMENT ON TABLE DTS_ELEMENT_DIMENSION_SCORE IS
    'Element x dimension 0-100 scores per run, with confidence factor and CDE multiplier, before weighted rollup.';

-------------------------------------------------------------------------------
-- 2. DTS_DATASET_TRUST_SCORE -- final per-(object, run) score.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_DATASET_TRUST_SCORE (
    REPORT_FAMILY          VARCHAR NOT NULL,
    LAYER                  VARCHAR NOT NULL,
    DATASET_FQN            VARCHAR,
    DQ_MEASUREMENT_LAYER   VARCHAR,                -- BRONZE|SILVER|GOLD
    TRUST_SCORE            FLOAT   NOT NULL,       -- 0-100 weighted, CDE-adjusted
    TRUST_BAND             VARCHAR NOT NULL,       -- from DTS_TRUST_BANDS
    MEASURABLE_CEILING     FLOAT   NOT NULL,       -- sum of weights measurable today
    MEASURED_SUBTOTAL      FLOAT   NOT NULL,       -- score from measurable dims only
    FOUNDATIONAL_GAP_FLAG  BOOLEAN NOT NULL,       -- TRUE if a foundational dim unseeded
    FOUNDATIONAL_GAPS      ARRAY,                  -- which foundational dims are missing
    SCORE_RUN_DATE         DATE    NOT NULL DEFAULT CURRENT_DATE(),
    CREATED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_TRUST_SCORE UNIQUE (REPORT_FAMILY, LAYER, SCORE_RUN_DATE)
);
COMMENT ON TABLE DTS_DATASET_TRUST_SCORE IS
    'Final v2 trust score per (report_family, layer, run): weighted+CDE-adjusted, banded, with measurable ceiling and foundational-gap flag.';
