-------------------------------------------------------------------------------
-- role_split_for_dba.sql  (POST-DEPLOY CLEANUP -- requires DBA / SECURITYADMIN)
--
-- Hand this file to a DBA after the POC has been deployed and validated.
-- It is NOT required for the POC to function. Today the POC objects are
-- owned by DATA_CLEAN_ROOM_ROLE; this script splits them out into a
-- dedicated TRUST_SCORE_POC_ROLE so:
--   * The clean-room role stops accumulating unrelated objects.
--   * Other people can be granted access to the dashboard data without
--     also receiving DCR privileges.
--
-- BEFORE RUNNING
--   * Replace <YOUR_USER> with the username that should own the POC role
--     (the human DRI for the POC -- typically the analyst who built it).
--   * Replace <YOUR_WH> with the warehouse the POC should use.
--   * USERADMIN / SECURITYADMIN are needed for CREATE ROLE + grant role
--     to user. ACCOUNTADMIN can do everything in one role.
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- STEP 1 -- create the role and grant it to the POC owner.
-- Requires USERADMIN (or ACCOUNTADMIN).
-------------------------------------------------------------------------------
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS TRUST_SCORE_POC_ROLE
  COMMENT = 'Owns the Data Trust Score POC database (ASATTAR_TRUST_SCORE_POC).';

GRANT ROLE TRUST_SCORE_POC_ROLE TO USER <YOUR_USER>;


-------------------------------------------------------------------------------
-- STEP 2 -- give the new role a warehouse to run on.
-- Requires the role that owns the warehouse (often SYSADMIN or ACCOUNTADMIN).
-------------------------------------------------------------------------------
USE ROLE SYSADMIN;   -- or ACCOUNTADMIN if SYSADMIN is not the WH owner

GRANT USAGE   ON WAREHOUSE <YOUR_WH> TO ROLE TRUST_SCORE_POC_ROLE;
GRANT OPERATE ON WAREHOUSE <YOUR_WH> TO ROLE TRUST_SCORE_POC_ROLE;


-------------------------------------------------------------------------------
-- STEP 3 -- transfer database, schema, and all objects from
-- DATA_CLEAN_ROOM_ROLE to the new role.
-- Requires DATA_CLEAN_ROOM_ROLE (current owner) or ACCOUNTADMIN.
--
-- COPY CURRENT GRANTS preserves any read access already granted to other
-- roles, so downstream consumers don't get locked out.
-------------------------------------------------------------------------------
USE ROLE DATA_CLEAN_ROOM_ROLE;

GRANT OWNERSHIP ON DATABASE ASATTAR_TRUST_SCORE_POC
  TO ROLE TRUST_SCORE_POC_ROLE
  COPY CURRENT GRANTS;

GRANT OWNERSHIP ON SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC
  TO ROLE TRUST_SCORE_POC_ROLE
  COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL TABLES IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC
  TO ROLE TRUST_SCORE_POC_ROLE
  COPY CURRENT GRANTS;

GRANT OWNERSHIP ON ALL VIEWS IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC
  TO ROLE TRUST_SCORE_POC_ROLE
  COPY CURRENT GRANTS;

-- Optional -- if 91_seed_via_stage.sql was used to load via PUT/COPY:
-- GRANT OWNERSHIP ON ALL FILE FORMATS IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC
--   TO ROLE TRUST_SCORE_POC_ROLE COPY CURRENT GRANTS;
-- GRANT OWNERSHIP ON ALL STAGES IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC
--   TO ROLE TRUST_SCORE_POC_ROLE COPY CURRENT GRANTS;


-------------------------------------------------------------------------------
-- STEP 4 -- verify, then update ddl/00_setup.sql to switch the deploy
-- script's USE ROLE line back to TRUST_SCORE_POC_ROLE so re-deploys land
-- under the new owner.
-------------------------------------------------------------------------------
USE ROLE TRUST_SCORE_POC_ROLE;
USE WAREHOUSE <YOUR_WH>;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;

SHOW DATABASES LIKE 'ASATTAR_TRUST_SCORE_POC';                    -- "owner" should be TRUST_SCORE_POC_ROLE
SHOW TABLES    IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;          -- all rows should show owner = TRUST_SCORE_POC_ROLE
SHOW VIEWS     IN SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;          -- same
