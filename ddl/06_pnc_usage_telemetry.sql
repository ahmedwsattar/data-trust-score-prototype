-------------------------------------------------------------------------------
-- PNC_USAGE_TELEMETRY  (NET-NEW, Phase 2) -- POC version
--
-- Closes Trust Score dimension #9 (Usage). Backed by Snowflake ACCOUNT_USAGE
-- query history filtered to PNC datasets. Aggregated daily; the Trust Score
-- summarizes a 30-day rolling window.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_USAGE_TELEMETRY (
    DATASET_ID            VARCHAR(64)   NOT NULL
  , DATASET_NAME          VARCHAR(255)  NOT NULL
  , USAGE_DATE            DATE          NOT NULL
  , QUERIES_RUN           NUMBER(10,0)  NOT NULL DEFAULT 0
  , UNIQUE_USERS          NUMBER(6,0)   NOT NULL DEFAULT 0
  , UNIQUE_TEAMS          NUMBER(4,0)   NOT NULL DEFAULT 0
  , BYTES_SCANNED         NUMBER(18,0)  NOT NULL DEFAULT 0
  , LOAD_DATE             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , CONSTRAINT PK_PNC_USAGE_TELEMETRY PRIMARY KEY (DATASET_ID, USAGE_DATE)
);
