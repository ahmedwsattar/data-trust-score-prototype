-------------------------------------------------------------------------------
-- ddl/40_dts_seed_metadata.sql
-- v2 Data Trust Score -- seed the registries + lineage + interim signals.
--
-- Populates the governance/metadata tables for the 5 scored objects:
--   POSITION_REPORT: INT, DW, PUBL      TRENDED_REPORT: DW, PUBL (INT skipped --
--   empty at rest; DW is source-of-record).
--
-- Child tables carry DATASET_ID; we look it up from DTS_DATASET_REGISTRY by the
-- (REPORT_FAMILY, LAYER) natural key so IDENTITY values don't have to be known.
--
-- Run AFTER ddl/00-04. Then clone + attach DMFs (ddl/20, 21), let DMFs measure,
-- and CALL SP_DTS_COMPUTE_SCORES() (ddl/30).
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. DTS_DATASET_REGISTRY -- the 5 scored objects.
-------------------------------------------------------------------------------
TRUNCATE TABLE DTS_DATASET_REGISTRY;
INSERT INTO DTS_DATASET_REGISTRY
    (REPORT_FAMILY, LAYER, DATABASE_NAME, SCHEMA_NAME, OBJECT_NAME, OBJECT_TYPE,
     DATASET_FQN, DQ_MEASUREMENT_LAYER, IS_VIEW, FRESHNESS_COLUMN, KEY_COLUMNS,
     MARKETPLACE_STATUS, IS_IN_SCOPE, CLONE_EXISTS)
SELECT 'POSITION_REPORT','INT','EDLE_INT_DB','PNC_WORKDAY01','STG_POSITION_REPORT','TABLE',
     'EDLE_INT_DB.PNC_WORKDAY01.STG_POSITION_REPORT','BRONZE',FALSE,'LOADDATE',
     ARRAY_CONSTRUCT('POSITION_ID','REPORT_EFFECTIVE_DATE','REPORT_ENTRY_DATE'),'INTERNAL',TRUE,FALSE
UNION ALL
SELECT 'POSITION_REPORT','DW','EDLE_DW_DB','PNC_DATA','DT_POSITION_REPORT','TABLE',
     'EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT','SILVER',FALSE,'LOADDATE',
     ARRAY_CONSTRUCT('POSITION_ID','REPORT_EFFECTIVE_DATE','REPORT_ENTRY_DATE'),'INTERNAL',TRUE,FALSE
UNION ALL
SELECT 'POSITION_REPORT','PUBL','EDLE_PUBL_DB','PNC_ANALYTICS','STG_POSITION_REPORT_VW','VIEW',
     'EDLE_PUBL_DB.PNC_ANALYTICS.STG_POSITION_REPORT_VW','GOLD',TRUE,'Load Date date and timestamp',
     ARRAY_CONSTRUCT('Position ID','Report Effective Date','Report Entry Date'),'INTERNAL',TRUE,FALSE
UNION ALL
SELECT 'TRENDED_REPORT','DW','EDLE_DW_DB','PNC_DATA','DT_TRENDED_REPORT','TABLE',
     'EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT','SILVER',FALSE,'LOADDATE',
     ARRAY_CONSTRUCT('BUSINESS_PROCESS_WID','EFFECTIVEDATE','EMPLOYEEID','RECORDTYPE'),'INTERNAL',TRUE,FALSE
UNION ALL
SELECT 'TRENDED_REPORT','PUBL','EDLE_PUBL_DB','PNC_ANALYTICS','STG_TRENDED_REPORT_VW','VIEW',
     'EDLE_PUBL_DB.PNC_ANALYTICS.STG_TRENDED_REPORT_VW','GOLD',TRUE,'Load Date date and timestamp',
     ARRAY_CONSTRUCT('Business Process WID','Effective Date','Employee ID','Record Type'),'INTERNAL',TRUE,FALSE;

-------------------------------------------------------------------------------
-- 2. DTS_DATA_ELEMENT -- key-column inventory + CDE flags.
--    Identifier keys (POSITION_ID, EMPLOYEEID, BUSINESS_PROCESS_WID) are CDE
--    (2.0x). Date keys are keys but not CDE. Additional CDE columns can be
--    added later from the WPII_/WSPII_ PII tag list.
-------------------------------------------------------------------------------
DELETE FROM DTS_DATA_ELEMENT;
INSERT INTO DTS_DATA_ELEMENT
    (DATASET_ID, REPORT_FAMILY, LAYER, COLUMN_NAME, IS_KEY, IS_CDE,
     CRITICALITY_MULTIPLIER, PII_TAG, BUSINESS_TERM)
SELECT r.DATASET_ID, v.column1, v.column2, v.column3, v.column4, v.column5,
       v.column6, v.column7, v.column8
FROM VALUES
    -- POSITION family (same key set at each layer)
    ('POSITION_REPORT','INT','POSITION_ID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Position ID'),
    ('POSITION_REPORT','INT','REPORT_EFFECTIVE_DATE',TRUE,FALSE,1.0,NULL,'Report Effective Date'),
    ('POSITION_REPORT','INT','REPORT_ENTRY_DATE',TRUE,FALSE,1.0,NULL,'Report Entry Date'),
    ('POSITION_REPORT','DW','POSITION_ID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Position ID'),
    ('POSITION_REPORT','DW','REPORT_EFFECTIVE_DATE',TRUE,FALSE,1.0,NULL,'Report Effective Date'),
    ('POSITION_REPORT','DW','REPORT_ENTRY_DATE',TRUE,FALSE,1.0,NULL,'Report Entry Date'),
    ('POSITION_REPORT','PUBL','Position ID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Position ID'),
    ('POSITION_REPORT','PUBL','Report Effective Date',TRUE,FALSE,1.0,NULL,'Report Effective Date'),
    ('POSITION_REPORT','PUBL','Report Entry Date',TRUE,FALSE,1.0,NULL,'Report Entry Date'),
    -- TRENDED family (DW, PUBL)
    ('TRENDED_REPORT','DW','BUSINESS_PROCESS_WID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Business Process WID'),
    ('TRENDED_REPORT','DW','EFFECTIVEDATE',TRUE,FALSE,1.0,NULL,'Effective Date'),
    ('TRENDED_REPORT','DW','EMPLOYEEID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Employee ID'),
    ('TRENDED_REPORT','DW','RECORDTYPE',TRUE,FALSE,1.0,NULL,'Record Type'),
    ('TRENDED_REPORT','PUBL','Business Process WID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Business Process WID'),
    ('TRENDED_REPORT','PUBL','Effective Date',TRUE,FALSE,1.0,NULL,'Effective Date'),
    ('TRENDED_REPORT','PUBL','Employee ID',TRUE,TRUE,2.0,'WPII_ALPHANUM_ID','Employee ID'),
    ('TRENDED_REPORT','PUBL','Record Type',TRUE,FALSE,1.0,NULL,'Record Type') v
JOIN DTS_DATASET_REGISTRY r
  ON r.REPORT_FAMILY = v.column1 AND r.LAYER = v.column2;

-------------------------------------------------------------------------------
-- 3. DTS_BUSINESS_GLOSSARY -- definitions for the seeded business terms.
-------------------------------------------------------------------------------
DELETE FROM DTS_BUSINESS_GLOSSARY;
INSERT INTO DTS_BUSINESS_GLOSSARY (BUSINESS_TERM, DEFINITION, HAS_DEFINITION, STEWARD, SOURCE_SYSTEM)
VALUES
    ('Position ID','Unique identifier of a Workday position.',TRUE,'P&C Data Steward','COLLIBRA'),
    ('Report Effective Date','Business-effective date of the position snapshot.',TRUE,'P&C Data Steward','COLLIBRA'),
    ('Report Entry Date','Date the record entered the report.',TRUE,'P&C Data Steward','COLLIBRA'),
    ('Business Process WID','Workday business-process instance identifier.',TRUE,'P&C Data Steward','COLLIBRA'),
    ('Effective Date','Effective date of the trended record.',TRUE,'P&C Data Steward','COLLIBRA'),
    ('Employee ID','Unique Workday employee identifier.',TRUE,'P&C Data Steward','COLLIBRA'),
    ('Record Type',NULL,FALSE,NULL,'COLLIBRA');   -- intentionally undefined (coverage < 100%)

-------------------------------------------------------------------------------
-- 4. Foundational dims: ownership, source certification, classification.
-------------------------------------------------------------------------------
DELETE FROM DTS_OWNERSHIP_STEWARDSHIP_REGISTRY;
INSERT INTO DTS_OWNERSHIP_STEWARDSHIP_REGISTRY
    (DATASET_ID, REPORT_FAMILY, LAYER, DATA_OWNER, DATA_STEWARD, TECHNICAL_OWNER, HAS_OWNER, HAS_STEWARD)
SELECT r.DATASET_ID, r.REPORT_FAMILY, r.LAYER,
       'P&C Analytics Lead', 'P&C Data Steward', 'EDL Platform Team', TRUE, TRUE
FROM DTS_DATASET_REGISTRY r;

DELETE FROM DTS_SOURCE_CERTIFICATION_REGISTRY;
INSERT INTO DTS_SOURCE_CERTIFICATION_REGISTRY
    (DATASET_ID, REPORT_FAMILY, LAYER, SOURCE_SYSTEM, IS_AUTHORITATIVE, CERTIFIED_BY, CERTIFIED_DATE)
SELECT r.DATASET_ID, r.REPORT_FAMILY, r.LAYER, 'WORKDAY', TRUE, 'EDAI Governance', CURRENT_DATE()
FROM DTS_DATASET_REGISTRY r;

DELETE FROM DTS_CLASSIFICATION_REGISTRY;
INSERT INTO DTS_CLASSIFICATION_REGISTRY
    (DATASET_ID, REPORT_FAMILY, LAYER, HAS_CLASSIFICATION, SENSITIVITY_LEVEL, PII_PRESENT, CLASSIFIED_COLUMN_PCT)
SELECT r.DATASET_ID, r.REPORT_FAMILY, r.LAYER, TRUE, 'CONFIDENTIAL', TRUE, 100
FROM DTS_DATASET_REGISTRY r;

-------------------------------------------------------------------------------
-- 5. DTS_LINEAGE_REGISTRY -- the two confirmed chains (from edl-pnc-repo).
-------------------------------------------------------------------------------
DELETE FROM DTS_LINEAGE_REGISTRY;
INSERT INTO DTS_LINEAGE_REGISTRY
    (REPORT_FAMILY, LAYER, OBJECT_FQN, UPSTREAM_FQN, DOWNSTREAM_FQN, TRANSFORM_TYPE, HAS_UPSTREAM, HAS_DOWNSTREAM)
VALUES
    -- POSITION chain: S3 -> INT (COPY) -> DW (INSERT) -> PUBL (VIEW)
    ('POSITION_REPORT','INT','EDLE_INT_DB.PNC_WORKDAY01.STG_POSITION_REPORT',
     'S3://edl-pnc-workday', 'EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT','COPY',TRUE,TRUE),
    ('POSITION_REPORT','DW','EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT',
     'EDLE_INT_DB.PNC_WORKDAY01.STG_POSITION_REPORT','EDLE_PUBL_DB.PNC_ANALYTICS.STG_POSITION_REPORT_VW','INSERT',TRUE,TRUE),
    ('POSITION_REPORT','PUBL','EDLE_PUBL_DB.PNC_ANALYTICS.STG_POSITION_REPORT_VW',
     'EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT', NULL,'VIEW',TRUE,FALSE),
    -- TRENDED chain (DW is source-of-record; INT omitted)
    ('TRENDED_REPORT','DW','EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT',
     'EDLE_INT_DB.PNC_WORKDAY01.STG_TRENDED_REPORT','EDLE_PUBL_DB.PNC_ANALYTICS.STG_TRENDED_REPORT_VW','MERGE',TRUE,TRUE),
    ('TRENDED_REPORT','PUBL','EDLE_PUBL_DB.PNC_ANALYTICS.STG_TRENDED_REPORT_VW',
     'EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT', NULL,'VIEW',TRUE,FALSE);

-------------------------------------------------------------------------------
-- 6. Interim DQ rule results (IDQ seeds for accuracy/consistency/validity).
--    Completeness + uniqueness come from live DMFs; these three are interim
--    until native rules exist. PASS_PCT feeds the DQ dimension blend.
-------------------------------------------------------------------------------
DELETE FROM DTS_DQ_RULE_RESULT WHERE SOURCE_SYSTEM = 'IDQ';
INSERT INTO DTS_DQ_RULE_RESULT
    (REPORT_FAMILY, LAYER, COLUMN_NAME, DAMA_SUB_DIM, RULE_NAME, IS_DMF_AUTOMATED,
     PASS_PCT, MEASURED_VALUE, THRESHOLD, STATUS, SOURCE_SYSTEM, SCORE_RUN_DATE)
SELECT r.REPORT_FAMILY, r.LAYER, NULL, v.column1, v.column2, FALSE,
       v.column3, v.column3, 95, IFF(v.column3 >= 95,'PASS','WARN'), 'IDQ', CURRENT_DATE()
FROM VALUES
    ('ACCURACY',   'IDQ accuracy profile',    92),
    ('CONSISTENCY','IDQ cross-field consistency', 96),
    ('VALIDITY',   'IDQ domain/format validity',  90) v
CROSS JOIN DTS_DATASET_REGISTRY r;

-------------------------------------------------------------------------------
-- 7. Usage + feedback (minimal seeds; Usage can later come from ACCESS_HISTORY).
-------------------------------------------------------------------------------
DELETE FROM DTS_USAGE_METRICS;
INSERT INTO DTS_USAGE_METRICS (REPORT_FAMILY, LAYER, QUERY_COUNT_30D, DISTINCT_USERS_30D, LAST_QUERIED_AT, SCORE_RUN_DATE)
SELECT r.REPORT_FAMILY, r.LAYER,
       IFF(r.LAYER='PUBL', 120, IFF(r.LAYER='DW', 40, 8)),
       IFF(r.LAYER='PUBL', 15, IFF(r.LAYER='DW', 6, 2)),
       CURRENT_TIMESTAMP(), CURRENT_DATE()
FROM DTS_DATASET_REGISTRY r;

DELETE FROM DTS_USER_FEEDBACK;
INSERT INTO DTS_USER_FEEDBACK (REPORT_FAMILY, LAYER, RATING, COMMENT_TEXT, SUBMITTED_BY)
SELECT r.REPORT_FAMILY, r.LAYER, 4, 'Reliable for reporting.', 'analyst@wbd.com'
FROM DTS_DATASET_REGISTRY r WHERE r.LAYER = 'PUBL';

-------------------------------------------------------------------------------
-- Verify seed counts.
-------------------------------------------------------------------------------
SELECT 'DATASET_REGISTRY' AS tbl, COUNT(*) AS n FROM DTS_DATASET_REGISTRY
UNION ALL SELECT 'DATA_ELEMENT', COUNT(*) FROM DTS_DATA_ELEMENT
UNION ALL SELECT 'LINEAGE', COUNT(*) FROM DTS_LINEAGE_REGISTRY
UNION ALL SELECT 'DQ_RULE_RESULT', COUNT(*) FROM DTS_DQ_RULE_RESULT
ORDER BY tbl;
