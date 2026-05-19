-------------------------------------------------------------------------------
-- 50_create_streamlit_apps.sql
--
-- Creates the TWO Streamlit-in-Snowflake (SiS) app objects so they show up
-- as separate apps in Snowsight instead of replacing each other.
--
-- Background
-- ----------
-- Each SiS app is a Snowflake database object identified by
-- (database, schema, name). If two deploys use the same triple, the second
-- one replaces the first -- even if MAIN_FILE is different. The fix is to
-- create two explicitly named STREAMLIT objects that share the same stage
-- of source files but point at different entry-point files.
--
-- Run order:
--   1. Make sure ASATTAR_TRUST_SCORE_POC.DQ_POC exists (file 00_setup).
--   2. Run Section A once to create the stage.
--   3. Upload app/*.py + app/.streamlit/config.toml to the stage
--      (Snowsight UI: stage browser -> +Files;
--       SnowSQL:      see Section B template).
--   4. Run Section C to create the two STREAMLIT objects.
--   5. Run Section D to grant USAGE so other roles can open the apps.
--   6. Run Section E to verify both apps appear.
--
-- Re-deploying: re-upload changed files to the stage, then re-run Section C.
-- The CREATE OR REPLACE STREAMLIT statements refresh the objects in place
-- (they don't touch other apps in the schema because they use distinct names).
-------------------------------------------------------------------------------

USE ROLE      DATA_CLEAN_ROOM_ROLE;
USE WAREHOUSE WH_DEFAULT;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;


-------------------------------------------------------------------------------
-- SECTION A: ONE-TIME STAGE FOR APP SOURCE FILES
--
-- Both Streamlit objects read from this single stage; what differentiates
-- them is the MAIN_FILE setting on each CREATE STREAMLIT below.
-------------------------------------------------------------------------------

CREATE STAGE IF NOT EXISTS ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT   = 'Source files for the Data Trust Score Streamlit apps';


-------------------------------------------------------------------------------
-- SECTION B: FILE UPLOAD (SnowSQL example -- skip if using Snowsight UI)
--
-- Required files in the stage (flat, no subfolders):
--   shared.py                  -- common loaders/constants/CSS
--   trust_score_app.py         -- Trust Score app entry point
--   ai_use_cases_app.py        -- AI Use Cases app entry point
--   .streamlit/config.toml     -- shared dark-theme config
--
-- Snowsight UI:
--   Data > Databases > ASATTAR_TRUST_SCORE_POC > DQ_POC > Stages >
--   STREAMLIT_APP_STAGE > +Files. Drag the four files in (preserve the
--   .streamlit/ subfolder).
--
-- SnowSQL (run from the repo root, replace path if needed):
--   snowsql -q "PUT file://app/shared.py             @ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/trust_score_app.py    @ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/ai_use_cases_app.py   @ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--   snowsql -q "PUT file://app/.streamlit/config.toml @ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE/.streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
--
-- After uploading, refresh the stage so the directory table sees the files:
ALTER STAGE ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE REFRESH;

-- Sanity check that all four files are present:
LS @ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE;


-------------------------------------------------------------------------------
-- SECTION C: CREATE THE TWO STREAMLIT OBJECTS
--
-- THIS is what makes them show up as two separate apps in Snowsight.
-- The objects have DIFFERENT NAMES, so they don't collide.
-- They share a ROOT_LOCATION (the stage) but point at DIFFERENT MAIN_FILEs.
-------------------------------------------------------------------------------

CREATE OR REPLACE STREAMLIT ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_TRUST_SCORE
    ROOT_LOCATION   = '@ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE'
    MAIN_FILE       = 'trust_score_app.py'
    QUERY_WAREHOUSE = WH_DEFAULT
    TITLE           = 'P&C Data Trust Score'
    COMMENT         = 'Governance + Cortex DQ surface: Portfolio Scorecard, Dataset Detail, Cortex DQ, Methodology & Weights';

CREATE OR REPLACE STREAMLIT ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_HR_AI_USE_CASES
    ROOT_LOCATION   = '@ASATTAR_TRUST_SCORE_POC.DQ_POC.STREAMLIT_APP_STAGE'
    MAIN_FILE       = 'ai_use_cases_app.py'
    QUERY_WAREHOUSE = WH_DEFAULT
    TITLE           = 'P&C HR Analytics (AI use cases)'
    COMMENT         = 'Applied analytics: Workforce Shifts, TA Analytics';


-------------------------------------------------------------------------------
-- SECTION D: GRANT USAGE
--
-- Whoever should be able to OPEN each app needs USAGE on the STREAMLIT
-- object. They also need SELECT on the underlying tables/views (already
-- handled by the trust-score schema setup).
--
-- Edit the role names below to match the consumers you want.
-------------------------------------------------------------------------------

-- Example: let everyone in the read role open both apps
-- GRANT USAGE ON STREAMLIT ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_TRUST_SCORE  TO ROLE PUBLIC;
-- GRANT USAGE ON STREAMLIT ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_HR_AI_USE_CASES   TO ROLE PUBLIC;


-------------------------------------------------------------------------------
-- SECTION E: VERIFY
--
-- Both rows should appear with different MAIN_FILE values and different
-- LAST_ALTERED timestamps. If only one shows up, Section C didn't create
-- two distinct objects -- check the names match what you intended.
-------------------------------------------------------------------------------

SHOW STREAMLITS IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

SELECT
    "name"             AS app_name
  , "title"            AS app_title
  , "main_file"        AS main_file
  , "query_warehouse"  AS warehouse
  , "url_id"           AS url_id
  , "comment"          AS comment
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";

-- Direct URLs (use these in a browser, or open from Snowsight > Streamlit):
--   https://app.snowflake.com/<account>/<region>/#/streamlit-apps/ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_TRUST_SCORE
--   https://app.snowflake.com/<account>/<region>/#/streamlit-apps/ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_HR_AI_USE_CASES


-------------------------------------------------------------------------------
-- SECTION F: COMMON MISTAKES THAT CAUSE "ONE APP REPLACES THE OTHER"
--
-- 1. Same NAME, different MAIN_FILE.
--    Two CREATE STREAMLIT statements with the same fully-qualified name
--    will REPLACE each other (that's what OR REPLACE means). MAIN_FILE
--    being different doesn't help.
--    --> Use two DIFFERENT names, like Section C above.
--
-- 2. "Create a Streamlit App" twice in Snowsight with the same name.
--    Same outcome -- Snowsight will offer to overwrite.
--    --> Pick distinct names in the create dialog.
--
-- 3. Workspaces with a single STREAMLIT object.
--    If you open both files in the same Workspace and use the "Run" button,
--    Snowsight may bind one STREAMLIT object to whichever file you ran
--    last. Workspaces is great for editing but not for managing the
--    object identity of two distinct deployed apps.
--    --> Use SQL DDL (Section C) for the deploy step.
--
-- 4. Both apps deployed to the same stage path with the same MAIN_FILE.
--    Not the case here since each STREAMLIT object explicitly sets
--    MAIN_FILE. But worth noting if you adapt this template.
-------------------------------------------------------------------------------
