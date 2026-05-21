-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA/DMF_DT_POSITION_REPORT.sql
--
-- Second scored table — weekly Workday position snapshot.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA;
USE WAREHOUSE PNC_AIML_WH;

ALTER TABLE EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (LOAD_DATE);

ALTER TABLE EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (TWID);

ALTER TABLE EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (POSITION_ID);

-- [TODO] Expand to full POC metric set (9 on Position, 6 on Trended) once privileges confirmed.
