-------------------------------------------------------------------------------
-- PNC_DATA_OWNERSHIP_REGISTRY  (NET-NEW) -- POC version
--
-- Closes Trust Score dimension #1 (Data Ownership), which the doc lists as
-- a hard Gap. One named owner + named steward per dataset, queryable.
-- "Critical open item before Design gate" per the doc -- must be populated
-- before MVP launch.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_OWNERSHIP_REGISTRY (
    DATASET_ID                VARCHAR(64)   PRIMARY KEY
  , DATASET_NAME              VARCHAR(255)  NOT NULL
  , DATASET_FQN               VARCHAR(512)  NOT NULL
  , DOMAIN                    VARCHAR(64)   NOT NULL

  -- Roles
  , BUSINESS_OWNER_NAME       VARCHAR(255)
  , BUSINESS_OWNER_EMAIL      VARCHAR(255)
  , DATA_STEWARD_NAME         VARCHAR(255)
  , DATA_STEWARD_EMAIL        VARCHAR(255)
  , TECHNICAL_OWNER_NAME      VARCHAR(255)
  , TECHNICAL_OWNER_EMAIL     VARCHAR(255)

  -- Lifecycle
  , ASSIGNMENT_STATUS         VARCHAR(32)   NOT NULL    -- 'ASSIGNED','PROVISIONAL','UNASSIGNED'
  , LAST_CONFIRMED_DATE       DATE                       -- steward must reconfirm every 180d
  , NEXT_REVIEW_DUE_DATE      DATE
  , NOTES                     VARCHAR(2000)

  -- Audit
  , CREATED_AT                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , UPDATED_AT                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , UPDATED_BY                VARCHAR(128)
);
