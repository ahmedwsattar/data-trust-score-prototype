-------------------------------------------------------------------------------
-- PNC_USER_FEEDBACK  (NET-NEW, Phase 2) -- POC version
--
-- Closes Trust Score dimension #10 (User Feedback). Lowest-weight dimension
-- in the doc; deferrable past MVP. One row per submission.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_USER_FEEDBACK (
    FEEDBACK_ID           VARCHAR(64)   PRIMARY KEY
  , DATASET_ID            VARCHAR(64)   NOT NULL
  , SUBMITTED_AT          TIMESTAMP_NTZ NOT NULL
  , SUBMITTED_BY_EMAIL    VARCHAR(255)
  , SUBMITTED_BY_TEAM     VARCHAR(128)
  , RATING                NUMBER(2,1)   NOT NULL  -- 1.0 .. 5.0
  , CATEGORY              VARCHAR(64)              -- 'ACCURACY','TIMELINESS','DEFINITIONS','OTHER'
  , COMMENT_TEXT          VARCHAR(4000)
  , LOAD_DATE             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
