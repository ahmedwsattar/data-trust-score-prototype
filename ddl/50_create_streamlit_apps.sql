-------------------------------------------------------------------------------
-- 50_create_streamlit_apps.sql  (v2)
--
-- Creates the TWO Streamlit-in-Snowflake (SiS) app objects in
-- EDLE_DW_DB.PNC_DATA so they show up as separate apps in Snowsight.
--
-- Each SiS app is identified by (database, schema, name). Two deploys with the
-- same triple replace each other, so we create two explicitly named STREAMLIT
-- objects sharing one stage but pointing at different MAIN_FILEs.
--
-- Run order:
--   1. Deploy the DTS_ objects first (ddl/00 -> 40) and run SP_DTS_COMPUTE_SCORES.
--   2. Run Section A once to create the stage.
--   3. Upload app/*.py (incl. config.py) + app/.streamlit/config.toml.
--   4. Run Section C to create the two STREAMLIT objects.
--   5. Run Section D to grant USAGE.
--   6. Run Section E to verify.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE DATABASE  EDLE_DW_DB;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;


-------------------------------------------------------------------------------
-- SECTION A: ONE-TIME STAGE FOR APP SOURCE FILES
-------------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT   = 'Source files for the v2 Data Trust Score Streamlit apps';


-------------------------------------------------------------------------------
-- SECTION B: FILE UPLOAD (SnowSQL example -- skip if using Snowsight UI)
--
-- Required files in the stage (flat, plus the .streamlit/ subfolder):
--   config.py            -- single source of truth (imported by shared.py)
--   shared.py            -- loaders / constants / CSS
--   trust_score_app.py   -- Trust Score app entry point
--   ai_use_cases_app.py  -- AI Use Cases app entry point
--   .streamlit/config.toml
--
-- Snowsight UI:
--   Data > Databases > EDLE_DW_DB > PNC_DATA > Stages >
--   DTS_STREAMLIT_APP_STAGE > +Files. Drag the files in (keep .streamlit/).
--
-- SnowSQL (from repo root):
--   snowsql -q "PUT file://app/config.py            @EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/shared.py            @EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/trust_score_app.py   @EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/ai_use_cases_app.py  @EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/.streamlit/config.toml @EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE/.streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE"

ALTER STAGE EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE REFRESH;
LS @EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE;


-------------------------------------------------------------------------------
-- SECTION C: CREATE THE TWO STREAMLIT OBJECTS
-------------------------------------------------------------------------------
CREATE OR REPLACE STREAMLIT EDLE_DW_DB.PNC_DATA.DTS_PNC_DATA_TRUST_SCORE
    ROOT_LOCATION   = '@EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE'
    MAIN_FILE       = 'trust_score_app.py'
    QUERY_WAREHOUSE = PNC_WH
    TITLE           = 'P&C Data Trust Score (v2)'
    COMMENT         = 'v2 governance surface: Portfolio Scorecard, Dataset Detail, Lineage DQ (INT->DW->PUBL), Methodology';

CREATE OR REPLACE STREAMLIT EDLE_DW_DB.PNC_DATA.DTS_PNC_HR_AI_USE_CASES
    ROOT_LOCATION   = '@EDLE_DW_DB.PNC_DATA.DTS_STREAMLIT_APP_STAGE'
    MAIN_FILE       = 'ai_use_cases_app.py'
    QUERY_WAREHOUSE = PNC_WH
    TITLE           = 'P&C HR Analytics (AI use cases)'
    COMMENT         = 'Applied analytics: Workforce Shifts, TA Analytics (requires VW_WORKFORCE_* views)';


-------------------------------------------------------------------------------
-- SECTION D: GRANT USAGE (edit roles to match your consumers)
-------------------------------------------------------------------------------
-- GRANT USAGE ON STREAMLIT EDLE_DW_DB.PNC_DATA.DTS_PNC_DATA_TRUST_SCORE TO ROLE PNC_REPORTING_RL;
-- GRANT USAGE ON STREAMLIT EDLE_DW_DB.PNC_DATA.DTS_PNC_HR_AI_USE_CASES  TO ROLE PNC_REPORTING_RL;


-------------------------------------------------------------------------------
-- SECTION E: VERIFY
-------------------------------------------------------------------------------
SHOW STREAMLITS IN SCHEMA EDLE_DW_DB.PNC_DATA;

SELECT "name" AS app_name, "title" AS app_title,
       "query_warehouse" AS warehouse, "url_id" AS url_id, "comment" AS comment
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";
