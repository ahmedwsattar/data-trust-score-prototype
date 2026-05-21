-------------------------------------------------------------------------------
-- Target: main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/PNC_DQ_RESULTS.sql
--
-- Wide scorecard surface (1 row per dataset × score_run_date). Nightly task
-- merges registry inputs + DMF bridge scores into dimension columns.
-------------------------------------------------------------------------------

USE ROLE PNC_DEVELOPER_RL;
USE DATABASE EDLE_DW_DB;
USE SCHEMA PNC_DATA_TRUST;
USE WAREHOUSE PNC_AIML_WH;

CREATE OR REPLACE TABLE EDLE_DW_DB.PNC_DATA_TRUST.PNC_DQ_RESULTS (
    DATASET_ID                          VARCHAR(64)   NOT NULL,
    DATASET_NAME                        VARCHAR(255)  NOT NULL,
    DATASET_FQN                         VARCHAR(512)  NOT NULL,
    DOMAIN                              VARCHAR(64)   NOT NULL,
    LAYER                               VARCHAR(32),
    SCORE_RUN_DATE                      DATE          NOT NULL,
    BATCH_ID                            VARCHAR(64),
    DIM_OWNERSHIP_SCORE                 NUMBER(5,2),
    DIM_OWNERSHIP_STATUS                VARCHAR(8),
    DIM_SOURCE_SCORE                    NUMBER(5,2),
    DIM_SOURCE_STATUS                   VARCHAR(8),
    DIM_ISSUES_SCORE                    NUMBER(5,2),
    DIM_ISSUES_STATUS                   VARCHAR(8),
    DIM_ISSUES_OPEN_P1                  NUMBER(6,0),
    DIM_ISSUES_OPEN_P2                  NUMBER(6,0),
    DIM_ISSUES_OPEN_P3                  NUMBER(6,0),
    DIM_TIMELINESS_SCORE                NUMBER(5,2),
    DIM_TIMELINESS_STATUS               VARCHAR(8),
    DIM_TIMELINESS_HOURS_LATE           NUMBER(8,2),
    DIM_COMPLETENESS_KEY_PROPS_SCORE    NUMBER(5,2),
    DIM_COMPLETENESS_KEY_PROPS_STATUS   VARCHAR(8),
    DIM_PROFILING_SCORE                 NUMBER(5,2),
    DIM_PROFILING_STATUS                VARCHAR(8),
    DIM_DEFINITIONS_SCORE               NUMBER(5,2),
    DIM_DEFINITIONS_STATUS              VARCHAR(8),
    DIM_KEY_PROPERTIES_SCORE            NUMBER(5,2),
    DIM_KEY_PROPERTIES_STATUS           VARCHAR(8),
    DIM_USAGE_SCORE                     NUMBER(5,2),
    DIM_USAGE_STATUS                    VARCHAR(8),
    DIM_FEEDBACK_SCORE                  NUMBER(5,2),
    DIM_FEEDBACK_STATUS                 VARCHAR(8),
    TRUST_SCORE_OVERALL                 NUMBER(5,2),
    TRUST_SCORE_TIER                    VARCHAR(16),
    CREATED_AT                          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_PNC_DQ_RESULTS PRIMARY KEY (DATASET_ID, SCORE_RUN_DATE)
);

-- [TODO] SP_REBUILD_TRUST_SCORE_SNAPSHOT: MERGE from registries + VW_PNC_DMF_DIMENSION_SCORES.
-- [USER]: confirm Phase-1 columns match POC ddl/01_pnc_dq_results_extended.sql exactly.
