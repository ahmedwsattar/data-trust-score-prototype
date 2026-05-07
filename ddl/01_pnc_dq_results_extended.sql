-------------------------------------------------------------------------------
-- PNC_DQ_RESULTS  (EXTENDED for Data Trust Score) -- POC version
--
-- Per Reuse Assessment (May 2026): the planned PNC_DQ_RESULTS scorecard view
-- is the closest existing candidate for the Trust Score surface. Today it
-- covers 3 dimensions (Active Issues, Data Profiling, Timeliness). This
-- DDL extends it to all 10 dimensions.
--
-- Grain: 1 row per (DATASET_ID, SCORE_RUN_DATE).
-- Latest snapshot is exposed via VW_PNC_DATA_TRUST_SCORE (see file 10).
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;

CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_RESULTS (

  -- Identity / lineage ------------------------------------------------------
    DATASET_ID                          VARCHAR(64)   NOT NULL  -- FK -> PNC_SOURCE_CLASSIFICATION.DATASET_ID
  , DATASET_NAME                        VARCHAR(255)  NOT NULL
  , DATASET_FQN                         VARCHAR(512)  NOT NULL  -- e.g. EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT
  , DOMAIN                              VARCHAR(64)   NOT NULL  -- 'P&C', 'FPA', ...
  , LAYER                               VARCHAR(32)             -- 'BRONZE','SILVER','GOLD','VIEW'
  , SCORE_RUN_DATE                      DATE          NOT NULL
  , BATCH_ID                            VARCHAR(64)

  -- Dimension 1: Data Ownership --------------------------------------------
  -- Source: PNC_DATA_OWNERSHIP_REGISTRY (net-new). 100 if a named steward
  -- exists AND was confirmed within last 180 days; 50 if assigned but stale; 0 if unassigned.
  , DIM_OWNERSHIP_SCORE                 NUMBER(5,2)
  , DIM_OWNERSHIP_STATUS                VARCHAR(8)    -- 'GREEN' / 'AMBER' / 'RED'
  , DIM_OWNERSHIP_OWNER_NAME            VARCHAR(255)
  , DIM_OWNERSHIP_LAST_CONFIRMED        DATE

  -- Dimension 2: Data Source ------------------------------------------------
  -- Source: PNC_SOURCE_CLASSIFICATION (net-new). 100 if APM-registered Core
  -- system, 75 if APM-registered non-Core, 50 if registered but unclassified,
  -- 0 if no source classification.
  , DIM_SOURCE_SCORE                    NUMBER(5,2)
  , DIM_SOURCE_STATUS                   VARCHAR(8)
  , DIM_SOURCE_SYSTEM                   VARCHAR(128)  -- e.g. 'Workday'
  , DIM_SOURCE_TIER                     VARCHAR(16)   -- 'CORE' / 'SOX' / 'APM' / 'UNCLASSIFIED'

  -- Dimension 3: Active Issues ---------------------------------------------
  -- Source: existing 8-category DQ framework + JIRA register. Score is
  -- 100 - (10 * open_p1) - (3 * open_p2) - (1 * open_p3), floored at 0.
  , DIM_ISSUES_SCORE                    NUMBER(5,2)
  , DIM_ISSUES_STATUS                   VARCHAR(8)
  , DIM_ISSUES_OPEN_P1                  NUMBER(6,0)
  , DIM_ISSUES_OPEN_P2                  NUMBER(6,0)
  , DIM_ISSUES_OPEN_P3                  NUMBER(6,0)
  , DIM_ISSUES_LAST_FAILURE_AT          TIMESTAMP_NTZ

  -- Dimension 4: Timeliness ------------------------------------------------
  -- Source: MAX(LOAD_DATE) on the dataset vs. SLA stored in
  -- PNC_SOURCE_CLASSIFICATION.SLA_HOURS. 100 if within SLA, linear decay,
  -- 0 if >= 3x SLA late.
  , DIM_TIMELINESS_SCORE                NUMBER(5,2)
  , DIM_TIMELINESS_STATUS               VARCHAR(8)
  , DIM_TIMELINESS_MAX_LOAD_DATE        TIMESTAMP_NTZ
  , DIM_TIMELINESS_SLA_HOURS            NUMBER(6,2)
  , DIM_TIMELINESS_HOURS_LATE           NUMBER(8,2)

  -- Dimension 5: Completeness of Key Properties ----------------------------
  -- Source: profiling on TWID / POSITION_ID / EmployeeID null rate per
  -- dataset (see PNC_KEY_PROPERTY_REGISTRY for which keys per dataset).
  -- Score = 100 * (1 - max_null_rate_among_required_keys).
  , DIM_COMPLETENESS_KEY_PROPS_SCORE    NUMBER(5,2)
  , DIM_COMPLETENESS_KEY_PROPS_STATUS   VARCHAR(8)
  , DIM_COMPLETENESS_KEYS_CHECKED       VARCHAR(512)  -- comma-separated key list
  , DIM_COMPLETENESS_WORST_KEY          VARCHAR(64)
  , DIM_COMPLETENESS_WORST_KEY_NULL_PCT NUMBER(5,2)

  -- Dimension 6: Data Profiling --------------------------------------------
  -- Source: existing 8-category DQ framework: type-safe coercion,
  -- null-safe keys, real-change detection, volume baseline.
  -- Score = % of profiling checks that passed in the last run.
  , DIM_PROFILING_SCORE                 NUMBER(5,2)
  , DIM_PROFILING_STATUS                VARCHAR(8)
  , DIM_PROFILING_CHECKS_TOTAL          NUMBER(6,0)
  , DIM_PROFILING_CHECKS_PASSED         NUMBER(6,0)

  -- Dimension 7: Data Definitions ------------------------------------------
  -- Source: catalog flag on PNC_KEY_PROPERTY_REGISTRY. Score = % of fields
  -- in the dataset that have an approved business definition in the catalog.
  , DIM_DEFINITIONS_SCORE               NUMBER(5,2)
  , DIM_DEFINITIONS_STATUS              VARCHAR(8)
  , DIM_DEFINITIONS_FIELDS_TOTAL        NUMBER(6,0)
  , DIM_DEFINITIONS_FIELDS_DEFINED      NUMBER(6,0)

  -- Dimension 8: Key Properties --------------------------------------------
  -- Source: PNC_KEY_PROPERTY_REGISTRY (net-new). Score = % of REQUIRED key
  -- identifiers actually present in the dataset's schema.
  , DIM_KEY_PROPERTIES_SCORE            NUMBER(5,2)
  , DIM_KEY_PROPERTIES_STATUS           VARCHAR(8)
  , DIM_KEY_PROPERTIES_REQUIRED         NUMBER(4,0)
  , DIM_KEY_PROPERTIES_PRESENT          NUMBER(4,0)

  -- Dimension 9: Usage (Phase 2) -------------------------------------------
  -- Source: PNC_USAGE_TELEMETRY (net-new). Score is a percentile of unique
  -- consumers in the last 30 days vs portfolio.
  , DIM_USAGE_SCORE                     NUMBER(5,2)
  , DIM_USAGE_STATUS                    VARCHAR(8)
  , DIM_USAGE_UNIQUE_CONSUMERS_30D      NUMBER(6,0)
  , DIM_USAGE_QUERIES_30D               NUMBER(10,0)

  -- Dimension 10: User Feedback (Phase 2) ----------------------------------
  -- Source: PNC_USER_FEEDBACK (net-new). Score = avg star rating * 20.
  , DIM_FEEDBACK_SCORE                  NUMBER(5,2)
  , DIM_FEEDBACK_STATUS                 VARCHAR(8)
  , DIM_FEEDBACK_AVG_RATING             NUMBER(3,2)
  , DIM_FEEDBACK_RESPONSES_90D          NUMBER(6,0)

  -- Aggregate ---------------------------------------------------------------
  -- Weighted average using PNC_TRUST_SCORE_WEIGHTS (config table).
  , TRUST_SCORE_OVERALL                 NUMBER(5,2)
  , TRUST_SCORE_TIER                    VARCHAR(16)   -- 'GOLD','SILVER','BRONZE','AT_RISK'

  -- Audit -------------------------------------------------------------------
  , LOAD_DATE                           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
  , LOAD_BY                             VARCHAR(128)  DEFAULT CURRENT_USER()

  , CONSTRAINT PK_PNC_DQ_RESULTS PRIMARY KEY (DATASET_ID, SCORE_RUN_DATE)
);

-------------------------------------------------------------------------------
-- Companion config: weights per dimension (sum = 100). Owned by Governance.
-- Seed rows are loaded by ddl/seed/91a_seed_pnc_trust_score_weights.sql.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_TRUST_SCORE_WEIGHTS (
    DIMENSION_CODE        VARCHAR(64) PRIMARY KEY  -- e.g. 'OWNERSHIP'
  , DIMENSION_NAME        VARCHAR(128) NOT NULL
  , WEIGHT_PCT            NUMBER(5,2) NOT NULL
  , RAG_GREEN_THRESHOLD   NUMBER(5,2) DEFAULT 80
  , RAG_AMBER_THRESHOLD   NUMBER(5,2) DEFAULT 60
  , EFFECTIVE_FROM        DATE NOT NULL
  , EFFECTIVE_TO          DATE
  , UPDATED_BY            VARCHAR(128)
);
