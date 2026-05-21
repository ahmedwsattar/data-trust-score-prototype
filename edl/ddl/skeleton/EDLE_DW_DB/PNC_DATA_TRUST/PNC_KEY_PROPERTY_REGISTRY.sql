-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/PNC_KEY_PROPERTY_REGISTRY.sql
--
-- Dimensions #5, #7, #8 — key columns, definitions, profiled null rates.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE OR REPLACE TABLE EDLE_DW_DB.PNC_DATA_TRUST.PNC_KEY_PROPERTY_REGISTRY (
    DATASET_ID                  VARCHAR(64)   NOT NULL,
    DATASET_NAME                VARCHAR(255)  NOT NULL,
    KEY_FIELD_NAME              VARCHAR(128)  NOT NULL,
    KEY_FIELD_ROLE              VARCHAR(32)   NOT NULL,
    IS_REQUIRED                 BOOLEAN       NOT NULL,
    IS_PRESENT_IN_SCHEMA        BOOLEAN       NOT NULL,
    HAS_APPROVED_DEFINITION     BOOLEAN       NOT NULL DEFAULT FALSE,
    APPROVED_DEFINITION_TEXT    VARCHAR(4000),
    CATALOG_URL                 VARCHAR(512),
    LAST_PROFILED_AT            TIMESTAMP_NTZ,
    NULL_PCT                    NUMBER(5,4),
    DISTINCT_COUNT              NUMBER(18,0),
    ROW_COUNT                   NUMBER(18,0),
    LOAD_DATE                   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_PNC_KEY_PROPERTY_REGISTRY PRIMARY KEY (DATASET_ID, KEY_FIELD_NAME)
);

-- [TODO] Nightly profile job: NULL_PCT from DMFs or INFORMATION_SCHEMA + sample queries.
