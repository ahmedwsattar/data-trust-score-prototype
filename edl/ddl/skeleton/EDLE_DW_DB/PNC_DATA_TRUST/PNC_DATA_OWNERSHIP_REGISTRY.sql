-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/PNC_DATA_OWNERSHIP_REGISTRY.sql
--
-- Dimension #1 (Data Ownership). Populated by stewards — not auto-discovered.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE OR REPLACE TABLE EDLE_DW_DB.PNC_DATA_TRUST.PNC_DATA_OWNERSHIP_REGISTRY (
    DATASET_ID                VARCHAR(64)   PRIMARY KEY,
    DATASET_NAME              VARCHAR(255)  NOT NULL,
    DATASET_FQN               VARCHAR(512)  NOT NULL,
    DOMAIN                    VARCHAR(64)   NOT NULL,
    BUSINESS_OWNER_NAME       VARCHAR(255),
    BUSINESS_OWNER_EMAIL      VARCHAR(255),
    DATA_STEWARD_NAME         VARCHAR(255),
    DATA_STEWARD_EMAIL        VARCHAR(255),
    TECHNICAL_OWNER_NAME      VARCHAR(255),
    TECHNICAL_OWNER_EMAIL     VARCHAR(255),
    ASSIGNMENT_STATUS         VARCHAR(32)   NOT NULL,
    LAST_CONFIRMED_DATE       DATE,
    NEXT_REVIEW_DUE_DATE      DATE,
    NOTES                     VARCHAR(2000),
    CREATED_AT                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_BY                VARCHAR(128)
);

-- [TODO] Seed from POC ddl/seed/91c or steward CSV via main/DATA/ load job.
