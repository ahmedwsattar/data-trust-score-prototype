-------------------------------------------------------------------------------
-- 00_setup.sql
-- Data Trust Score POC -- session context.
--
-- Pins the worksheet so every later DDL deploys under the same role,
-- warehouse, database, and schema.
--
-- Today the database is owned by DATA_CLEAN_ROOM_ROLE, so we deploy under
-- that role. Once a DBA runs ddl/dba/role_split_for_dba.sql, swap the
-- USE ROLE line below to TRUST_SCORE_POC_ROLE.
-------------------------------------------------------------------------------

USE ROLE      DATA_CLEAN_ROOM_ROLE;
USE WAREHOUSE WH_DEFAULT;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;
