-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA/DMF_DT_TRENDED_REPORT.sql
--
-- Native DMF attachment on a real EDL table. PNC_DEVELOPER_RL must OWN the
-- table; scheduled execution runs under PNC_AIML_DEVELOPER_RL + DATA_METRIC_USER.
--
-- [USER]: confirm LOAD_DATE column name on DT_TRENDED_REPORT in EDLE-DEV.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA;
USE WAREHOUSE PNC_AIML_WH;

ALTER TABLE EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (LOAD_DATE);

ALTER TABLE EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (TWID);

ALTER TABLE EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON (TWID, POSITION_ID);

-- [USER]: set schedule cadence aligned to monthly load
-- ALTER TABLE ... SET DATA_METRIC_SCHEDULE = 'USING CRON 0 6 * * 1 America/New_York';
