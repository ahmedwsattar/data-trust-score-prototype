-------------------------------------------------------------------------------
-- PNC_SOURCE_CLASSIFICATION  (NET-NEW) -- POC version
--
-- Closes Trust Score dimension #2 (Data Source). The doc notes source-system
-- classification "exists implicitly" today but is not queryable. This table
-- makes it queryable, and also stores the SLA used by the Timeliness scorer.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION (
    DATASET_ID            VARCHAR(64)   PRIMARY KEY
  , DATASET_NAME          VARCHAR(255)  NOT NULL
  , DATASET_FQN           VARCHAR(512)  NOT NULL

  -- Source system
  , SOURCE_SYSTEM         VARCHAR(128)  NOT NULL    -- 'Workday', 'CCURE', 'DSX', 'RS2', 'Beeline', ...
  , SOURCE_DOMAIN         VARCHAR(64)   NOT NULL    -- 'P&C', 'FPA', ...
  , LAYER                 VARCHAR(32)               -- 'BRONZE','SILVER','GOLD','VIEW'

  -- Classification (drives the DIM_SOURCE_SCORE)
  , CLASSIFICATION_TIER   VARCHAR(16)   NOT NULL    -- 'CORE','SOX','APM','UNCLASSIFIED'
  , IS_APM_REGISTERED     BOOLEAN       NOT NULL DEFAULT FALSE
  , IS_SOX_RELEVANT       BOOLEAN       NOT NULL DEFAULT FALSE

  -- Freshness SLA (drives the DIM_TIMELINESS_SCORE)
  , LOAD_FREQUENCY        VARCHAR(32)               -- 'DAILY','WEEKLY','MONTHLY','EVENT'
  , SLA_HOURS             NUMBER(6,2)               -- max acceptable lag from source to lake

  -- Audit
  , CREATED_AT            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , UPDATED_AT            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , UPDATED_BY            VARCHAR(128)
);
