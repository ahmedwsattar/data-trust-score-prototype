-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/STREAMLIT_STAGE_AND_APPS.sql
--
-- Streamlit-in-Snowflake deploy for Trust Score + AI Use Cases apps.
-- Jenkins PUT step uploads main/Python/streamlit/* to STREAMLIT_APP_STAGE.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE STAGE IF NOT EXISTS EDLE_DW_DB.PNC_DATA_TRUST.STREAMLIT_APP_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Data Trust Score + P&C HR Analytics Streamlit sources';

CREATE OR REPLACE STREAMLIT EDLE_DW_DB.PNC_DATA_TRUST.PNC_DATA_TRUST_SCORE
    ROOT_LOCATION = '@EDLE_DW_DB.PNC_DATA_TRUST.STREAMLIT_APP_STAGE'
    MAIN_FILE = 'trust_score_app.py'
    QUERY_WAREHOUSE = PNC_AIML_WH
    TITLE = 'PNC Data Trust Score';

CREATE OR REPLACE STREAMLIT EDLE_DW_DB.PNC_DATA_TRUST.PNC_PC_HR_ANALYTICS
    ROOT_LOCATION = '@EDLE_DW_DB.PNC_DATA_TRUST.STREAMLIT_APP_STAGE'
    MAIN_FILE = 'ai_use_cases_app.py'
    QUERY_WAREHOUSE = PNC_AIML_WH_UOM
    TITLE = 'P&C HR Analytics (AI Use Cases)';

GRANT USAGE ON STREAMLIT EDLE_DW_DB.PNC_DATA_TRUST.PNC_DATA_TRUST_SCORE
    TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT USAGE ON STREAMLIT EDLE_DW_DB.PNC_DATA_TRUST.PNC_PC_HR_ANALYTICS
    TO ROLE PNC_AIML_DEVELOPER_RL;

-- [USER]: paste jenkinsfile_SF Streamlit PUT/CREATE steps — align stage path + object names.
