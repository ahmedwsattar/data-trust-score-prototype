-------------------------------------------------------------------------------
-- PNC_KEY_PROPERTY_REGISTRY  (NET-NEW) -- POC version
--
-- Closes Trust Score dimensions #5 (Completeness of Key Properties),
-- #7 (Data Definitions) and #8 (Key Properties).
--
-- One row per (dataset, key field). Captures (a) whether the key is
-- declared required, (b) whether it is present in the dataset's schema,
-- (c) whether it has an approved business definition in the catalog,
-- and (d) the most recent profiled null rate for that field.
--
-- Today, anchor keys (TWID, POSITION_ID) are documented in inventory slides
-- only. This table makes that documentation queryable and joinable to
-- profiling output.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_KEY_PROPERTY_REGISTRY (
    DATASET_ID                  VARCHAR(64)   NOT NULL
  , DATASET_NAME                VARCHAR(255)  NOT NULL
  , KEY_FIELD_NAME              VARCHAR(128)  NOT NULL  -- e.g. 'TWID', 'POSITION_ID'
  , KEY_FIELD_ROLE              VARCHAR(32)   NOT NULL  -- 'PRIMARY','JOIN','BUSINESS','NONE'
  , IS_REQUIRED                 BOOLEAN       NOT NULL  -- declared required for this dataset?
  , IS_PRESENT_IN_SCHEMA        BOOLEAN       NOT NULL  -- physically exists in the schema?

  -- Catalog / definitions
  , HAS_APPROVED_DEFINITION     BOOLEAN       NOT NULL DEFAULT FALSE
  , APPROVED_DEFINITION_TEXT    VARCHAR(4000)
  , CATALOG_URL                 VARCHAR(512)

  -- Profiling (latest snapshot -- refreshed by the DQ pipeline)
  , LAST_PROFILED_AT            TIMESTAMP_NTZ
  , NULL_PCT                    NUMBER(5,4)             -- 0.0000..1.0000
  , DISTINCT_COUNT              NUMBER(18,0)
  , ROW_COUNT                   NUMBER(18,0)

  , LOAD_DATE                   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()

  , CONSTRAINT PK_PNC_KEY_PROPERTY_REGISTRY PRIMARY KEY (DATASET_ID, KEY_FIELD_NAME)
);
