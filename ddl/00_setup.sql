-------------------------------------------------------------------------------
-- ddl/00_setup.sql
-- v2 Data Trust Score -- session context.
--
-- Pins the worksheet so every v2 DDL deploys under the same role, warehouse,
-- database, and schema. v2 objects are DTS_-prefixed and live INSIDE the
-- existing EDLE_DW_DB.PNC_DATA schema (no new schema is created -- the deploy
-- role cannot CREATE SCHEMA on the shared EDLE databases, but it holds the
-- PNC_DATA_RWC database role, which lets it create DTS_ tables/views/procs and
-- the DTS_CLONE__* clone tables here).
--
-- Production tables are NEVER modified: DMFs attach only to the DTS_CLONE__*
-- copies created in ddl/20_dts_clone_and_dmf.sql.
--
-- If PNC_WH is not the warehouse you use, edit the USE WAREHOUSE line.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE DATABASE  EDLE_DW_DB;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-- Sanity check: confirm the active context before deploying.
SELECT CURRENT_ROLE()      AS active_role,
       CURRENT_DATABASE()  AS db,
       CURRENT_SCHEMA()    AS sch,
       CURRENT_WAREHOUSE() AS wh;
