-------------------------------------------------------------------------------
-- ddl/03_dts_measured.sql
-- v2 Data Trust Score -- measured / event tables.
--
-- These capture the non-DMF measured signals feeding several dimensions:
--   DTS_DQ_RULE_RESULT      : DAMA-tagged rule outcomes (accuracy/consistency/
--                             validity seeded from IDQ; completeness/uniqueness
--                             also mirrored here from DMFs for a unified view).
--   DTS_OBSERVABILITY_INCIDENT : freshness/volume incidents (Observability +
--                             Active Issues dims).
--   DTS_USAGE_METRICS       : query/consumer counts (Usage dim).
--   DTS_USER_FEEDBACK       : consumer feedback ratings (Feedback dim).
--
-- The authoritative DMF measurements themselves live in Snowflake's DMF result
-- store and are surfaced by the bridge views in ddl/26. This file holds the
-- seeded / interim and applied-signal tables.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. DTS_DQ_RULE_RESULT -- one row per (object, DAMA sub-dim, run).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_DQ_RULE_RESULT (
    RESULT_ID         NUMBER IDENTITY(1,1) PRIMARY KEY,
    REPORT_FAMILY     VARCHAR NOT NULL,
    LAYER             VARCHAR NOT NULL,
    COLUMN_NAME       VARCHAR,                    -- null = table-grain rule
    DAMA_SUB_DIM      VARCHAR NOT NULL,           -- COMPLETENESS|ACCURACY|CONSISTENCY|VALIDITY|UNIQUENESS
    RULE_NAME         VARCHAR NOT NULL,
    IS_DMF_AUTOMATED  BOOLEAN NOT NULL DEFAULT FALSE,
    PASS_PCT          FLOAT,                       -- 0-100 (score contribution)
    MEASURED_VALUE    FLOAT,                       -- raw metric (e.g. null_pct)
    THRESHOLD         FLOAT,
    STATUS            VARCHAR,                      -- PASS|WARN|FAIL
    SOURCE_SYSTEM     VARCHAR DEFAULT 'IDQ',        -- IDQ|COLLIBRA|DMF
    SCORE_RUN_DATE    DATE    NOT NULL DEFAULT CURRENT_DATE(),
    CREATED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
COMMENT ON TABLE DTS_DQ_RULE_RESULT IS
    'DAMA-tagged DQ rule outcomes per object/column/run. DMF-automated rows have IS_DMF_AUTOMATED=TRUE; others are interim IDQ/Collibra seeds.';

-------------------------------------------------------------------------------
-- 2. DTS_OBSERVABILITY_INCIDENT -- freshness/volume incidents.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_OBSERVABILITY_INCIDENT (
    INCIDENT_ID       NUMBER IDENTITY(1,1) PRIMARY KEY,
    REPORT_FAMILY     VARCHAR NOT NULL,
    LAYER             VARCHAR NOT NULL,
    INCIDENT_TYPE     VARCHAR NOT NULL,            -- FRESHNESS|VOLUME|SCHEMA_DRIFT
    SEVERITY          VARCHAR NOT NULL,            -- P1|P2|P3
    STATUS            VARCHAR NOT NULL DEFAULT 'OPEN',  -- OPEN|RESOLVED
    DETAIL            VARCHAR,
    DETECTED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    RESOLVED_AT       TIMESTAMP_NTZ
);
COMMENT ON TABLE DTS_OBSERVABILITY_INCIDENT IS
    'Observability incidents (freshness/volume). Open incidents reduce Observability + Active Issues scores.';

-------------------------------------------------------------------------------
-- 3. DTS_USAGE_METRICS -- consumption signals (Usage dim).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_USAGE_METRICS (
    REPORT_FAMILY     VARCHAR NOT NULL,
    LAYER             VARCHAR NOT NULL,
    QUERY_COUNT_30D   NUMBER  NOT NULL DEFAULT 0,
    DISTINCT_USERS_30D NUMBER NOT NULL DEFAULT 0,
    LAST_QUERIED_AT   TIMESTAMP_NTZ,
    SCORE_RUN_DATE    DATE    NOT NULL DEFAULT CURRENT_DATE(),
    CONSTRAINT UQ_DTS_USAGE UNIQUE (REPORT_FAMILY, LAYER, SCORE_RUN_DATE)
);
COMMENT ON TABLE DTS_USAGE_METRICS IS
    'Per-object usage counts (30d) feeding the Usage dimension. Can later be populated from ACCOUNT_USAGE.ACCESS_HISTORY.';

-------------------------------------------------------------------------------
-- 4. DTS_USER_FEEDBACK -- consumer feedback (Feedback dim).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_USER_FEEDBACK (
    FEEDBACK_ID       NUMBER IDENTITY(1,1) PRIMARY KEY,
    REPORT_FAMILY     VARCHAR NOT NULL,
    LAYER             VARCHAR NOT NULL,
    RATING            NUMBER,                      -- 1-5
    COMMENT_TEXT      VARCHAR,
    SUBMITTED_BY      VARCHAR,
    SUBMITTED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
COMMENT ON TABLE DTS_USER_FEEDBACK IS
    'Consumer feedback ratings feeding the Feedback dimension (lowest weight, 3).';
