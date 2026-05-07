-------------------------------------------------------------------------------
-- PNC_DQ_DIMENSION_RESULTS  (narrow companion fact) -- POC version
--
-- Same data as the wide PNC_DQ_RESULTS, but pivoted long: one row per
-- (dataset, dimension, score-run-date). Used for trend charts and dimension-
-- level audit drill-down.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_DIMENSION_RESULTS (
    DATASET_ID         VARCHAR(64)   NOT NULL
  , DATASET_NAME       VARCHAR(255)  NOT NULL
  , DOMAIN             VARCHAR(64)
  , SCORE_RUN_DATE     DATE          NOT NULL
  , DIMENSION_CODE     VARCHAR(64)   NOT NULL  -- FK -> PNC_TRUST_SCORE_WEIGHTS
  , DIMENSION_NAME     VARCHAR(128)
  , RAW_METRIC_NAME    VARCHAR(128)            -- e.g. 'TWID_NULL_PCT'
  , RAW_METRIC_VALUE   NUMBER(18,4)            -- e.g. 0.0123
  , SCORE              NUMBER(5,2)             -- 0..100
  , STATUS             VARCHAR(8)              -- 'GREEN' / 'AMBER' / 'RED'
  , NOTES              VARCHAR(2000)
  , LOAD_DATE          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , CONSTRAINT PK_PNC_DQ_DIMENSION_RESULTS
      PRIMARY KEY (DATASET_ID, SCORE_RUN_DATE, DIMENSION_CODE)
);
