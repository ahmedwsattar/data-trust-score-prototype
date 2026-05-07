-------------------------------------------------------------------------------
-- VW_PNC_DATA_TRUST_SCORE  (consumer-facing view) -- POC version
--
-- This is the surface Ella's team and downstream consumers query.
-- One row per dataset, latest snapshot, with the named owner joined in
-- so the dashboard does not need to issue a second lookup.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DATA_TRUST_SCORE AS
WITH latest AS (
    SELECT
        r.*
      , ROW_NUMBER() OVER (PARTITION BY DATASET_ID ORDER BY SCORE_RUN_DATE DESC) AS rn
    FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_RESULTS r
)
SELECT
    l.DATASET_ID
  , l.DATASET_NAME
  , l.DATASET_FQN
  , l.DOMAIN
  , l.LAYER
  , l.SCORE_RUN_DATE                      AS AS_OF_DATE

  , l.TRUST_SCORE_OVERALL
  , l.TRUST_SCORE_TIER

  -- Per-dimension scores
  , l.DIM_OWNERSHIP_SCORE
  , l.DIM_SOURCE_SCORE
  , l.DIM_ISSUES_SCORE
  , l.DIM_TIMELINESS_SCORE
  , l.DIM_COMPLETENESS_KEY_PROPS_SCORE
  , l.DIM_PROFILING_SCORE
  , l.DIM_DEFINITIONS_SCORE
  , l.DIM_KEY_PROPERTIES_SCORE
  , l.DIM_USAGE_SCORE
  , l.DIM_FEEDBACK_SCORE

  -- Convenient joins for the consumer
  , o.BUSINESS_OWNER_NAME
  , o.DATA_STEWARD_NAME
  , o.ASSIGNMENT_STATUS                   AS OWNERSHIP_ASSIGNMENT_STATUS
  , o.LAST_CONFIRMED_DATE                 AS OWNERSHIP_LAST_CONFIRMED_DATE
  , s.SOURCE_SYSTEM
  , s.CLASSIFICATION_TIER                 AS SOURCE_TIER
  , s.SLA_HOURS
  , l.DIM_TIMELINESS_HOURS_LATE
  , l.DIM_ISSUES_OPEN_P1
  , l.DIM_ISSUES_OPEN_P2
  , l.DIM_ISSUES_OPEN_P3

FROM latest l
LEFT JOIN ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DATA_OWNERSHIP_REGISTRY o
       ON o.DATASET_ID = l.DATASET_ID
LEFT JOIN ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION s
       ON s.DATASET_ID = l.DATASET_ID
WHERE l.rn = 1;
