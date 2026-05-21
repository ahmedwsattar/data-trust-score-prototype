-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/PNC_TRUST_SCORE_WEIGHTS.sql
--
-- Config-driven dimension weights — Streamlit reads live without redeploy.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE OR REPLACE TABLE EDLE_DW_DB.PNC_DATA_TRUST.PNC_TRUST_SCORE_WEIGHTS (
    DIMENSION_CODE    VARCHAR(32)   NOT NULL,
    DIMENSION_NAME    VARCHAR(128)  NOT NULL,
    WEIGHT_PCT        NUMBER(5,2)   NOT NULL,
    EFFECTIVE_FROM    DATE          NOT NULL,
    EFFECTIVE_TO      DATE,
    CONSTRAINT PK_PNC_TRUST_SCORE_WEIGHTS PRIMARY KEY (DIMENSION_CODE, EFFECTIVE_FROM)
);

-- [TODO] INSERT default 10-dimension weights from POC ddl/seed/91a.
