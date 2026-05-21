-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/PNC_DATASET_CATALOG.sql
--
-- Auto-discovered inventory of scoreable tables. SP_REFRESH_DATASET_CATALOG
-- upserts from INFORMATION_SCHEMA; stewards curate DOMAIN/SLA in sibling tables.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE OR REPLACE TABLE EDLE_DW_DB.PNC_DATA_TRUST.PNC_DATASET_CATALOG (
    DATASET_ID          VARCHAR(64)   NOT NULL,
    DATASET_NAME        VARCHAR(255)  NOT NULL,
    DATASET_FQN         VARCHAR(512)  NOT NULL,
    TABLE_CATALOG       VARCHAR(128)  NOT NULL,
    TABLE_SCHEMA        VARCHAR(128)  NOT NULL,
    TABLE_NAME          VARCHAR(256)  NOT NULL,
    TABLE_TYPE          VARCHAR(32),
    ROW_COUNT           NUMBER(18,0),
    IS_SCORE_ENABLED    BOOLEAN       NOT NULL DEFAULT TRUE,
    DISCOVERED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_REFRESHED_AT   TIMESTAMP_NTZ,
    UPDATED_BY          VARCHAR(128),
    CONSTRAINT PK_PNC_DATASET_CATALOG PRIMARY KEY (DATASET_ID)
);

-- [TODO] Initial load: CALL SP_REFRESH_DATASET_CATALOG('EDLE_DW_DB', 'PNC_DATA', 'DT_%');
-- [TODO] Steward workflow: disable IS_SCORE_ENABLED for out-of-scope tables.
