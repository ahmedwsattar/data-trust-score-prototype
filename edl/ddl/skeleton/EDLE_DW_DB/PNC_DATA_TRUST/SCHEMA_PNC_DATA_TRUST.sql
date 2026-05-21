-------------------------------------------------------------------------------
-- Target path: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/SCHEMA_PNC_DATA_TRUST.sql
--
-- Creates the governance schema for Data Trust Score inside EDLE_DW_DB.
-- Plan B: dedicated schema in an existing DB (PNC_DEVELOPER_RL already has
-- CREATE SCHEMA on EDLE_DW_DB and owns PNC_DATA pipeline objects).
--
-- [USER]: confirm schema name PNC_DATA_TRUST vs PNC_DATA_GOVERNANCE.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PUBLIC;
USE WAREHOUSE PNC_AIML_WH;

CREATE SCHEMA IF NOT EXISTS EDLE_DW_DB.PNC_DATA_TRUST
    COMMENT = 'Data Trust Score governance: registries, score tables, DMF bridge views, Streamlit stage';

GRANT USAGE ON SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT SELECT ON ALL TABLES IN SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT SELECT ON ALL VIEWS IN SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
