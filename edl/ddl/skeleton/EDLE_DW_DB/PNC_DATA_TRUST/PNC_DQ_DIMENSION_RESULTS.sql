-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/PNC_DQ_DIMENSION_RESULTS.sql
--
-- Narrow history for per-dimension trend charts on Dataset Detail page.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE OR REPLACE TABLE EDLE_DW_DB.PNC_DATA_TRUST.PNC_DQ_DIMENSION_RESULTS (
    DATASET_ID          VARCHAR(64)   NOT NULL,
    DATASET_NAME        VARCHAR(255)  NOT NULL,
    DIMENSION_CODE      VARCHAR(32)   NOT NULL,
    DIMENSION_NAME      VARCHAR(128)  NOT NULL,
    SCORE_RUN_DATE      DATE          NOT NULL,
    SCORE               NUMBER(5,2),
    STATUS              VARCHAR(8),
    WEIGHT_PCT          NUMBER(5,2),
    DETAIL_JSON         VARIANT,
    CREATED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_PNC_DQ_DIMENSION_RESULTS
        PRIMARY KEY (DATASET_ID, DIMENSION_CODE, SCORE_RUN_DATE)
);

-- [TODO] Populate from PNC_DQ_RESULTS unpivot during nightly rebuild SP.
