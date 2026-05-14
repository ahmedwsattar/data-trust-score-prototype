-------------------------------------------------------------------------------
-- 22_vw_pnc_dmf_dimension_scores.sql
-- Bridges DQ measurements to Trust Score dimension scores.
--
-- Reads from PNC_DQ_MEASUREMENTS_MANUAL (populated by SP_COMPUTE_DQ_MEASUREMENTS
-- in file 25), joins to PNC_DMF_DATASET_MAP and PNC_DMF_THRESHOLDS, and
-- produces:
--
--   VW_PNC_DMF_LATEST_MEASUREMENTS   -- latest reading per (dataset, metric, col)
--                                       with computed PASS/FAIL status
--
--   VW_PNC_DMF_DIMENSION_SCORES      -- one row per dataset with derived
--                                       0-100 scores for dims 3/4/5/6
--
-- The Streamlit app reads VW_PNC_DMF_DIMENSION_SCORES; the existing
-- PNC_DQ_RESULTS table is unchanged. When governance is ready to swap the
-- bespoke dim 3/4/5/6 logic for DMF-derived scores, write a small task that
-- UPDATEs PNC_DQ_RESULTS from this view nightly.
--
-- Native Cortex DQ swap-back: if the working role gets EXECUTE DATA METRIC
-- FUNCTION + SNOWFLAKE.DATA_METRIC_USER granted later, switch the FROM
-- clause in the `raw` CTE below from
--   ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL
-- to
--   SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
-- and run file 20 instead of file 25. The two sources have identical column
-- shapes (METRIC_NAME, ARGUMENTS_NAMES, VALUE, MEASUREMENT_TIME,
-- TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME), so nothing else changes.
-------------------------------------------------------------------------------

USE SCHEMA ASATTAR_TRUST_SCORE_POC.DQ_POC;


-------------------------------------------------------------------------------
-- VW_PNC_DMF_LATEST_MEASUREMENTS
--
-- One row per (DATASET_ID, METRIC_NAME, COLUMN_NAME) with the most recent
-- VALUE, joined to its threshold definition, and a derived PASS/FAIL flag.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DMF_LATEST_MEASUREMENTS AS
WITH raw AS (
    SELECT
        m.DATASET_ID
      , r.metric_name                                        AS METRIC_NAME
      -- Concatenate ALL DMF argument columns (not just [0]) so multi-column
      -- DMFs like DUPLICATE_COUNT(POSITION_ID, REPORT_EFFECTIVE_DATE) join
      -- to their threshold row. PNC_DMF_THRESHOLDS.COLUMN_NAME stores the
      -- same comma+space-separated form for compound keys.
      , COALESCE(ARRAY_TO_STRING(r.arguments_names, ', ')::VARCHAR, '') AS COLUMN_NAME
      , r.value::NUMBER(18,4)                                AS VALUE
      , r.measurement_time                                   AS MEASUREMENT_TIME
      , r.table_database                                     AS TABLE_DATABASE
      , r.table_schema                                       AS TABLE_SCHEMA
      , r.table_name                                         AS TABLE_NAME
    FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DQ_MEASUREMENTS_MANUAL r
    JOIN ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP m
      ON  m.TABLE_DATABASE = r.table_database
      AND m.TABLE_SCHEMA   = r.table_schema
      AND m.TABLE_NAME     = r.table_name
)
, ranked AS (
    SELECT
        raw.*
      , ROW_NUMBER() OVER (
            PARTITION BY DATASET_ID, METRIC_NAME, COLUMN_NAME
            ORDER BY MEASUREMENT_TIME DESC
        ) AS rn
    FROM raw
)
SELECT
    l.DATASET_ID
  , l.METRIC_NAME
  , l.COLUMN_NAME
  , l.VALUE
  , l.MEASUREMENT_TIME
  , l.TABLE_DATABASE
  , l.TABLE_SCHEMA
  , l.TABLE_NAME
  , t.DIMENSION_CODE
  , t.THRESHOLD_OP
  , t.THRESHOLD_VALUE
  , t.SEVERITY_ON_FAIL
  , t.IS_KEY_COLUMN
  , CASE
      WHEN t.THRESHOLD_OP IS NULL THEN NULL  -- no threshold defined yet
      WHEN t.THRESHOLD_OP = '<=' AND l.VALUE <= t.THRESHOLD_VALUE THEN 'PASS'
      WHEN t.THRESHOLD_OP = '<'  AND l.VALUE <  t.THRESHOLD_VALUE THEN 'PASS'
      WHEN t.THRESHOLD_OP = '>=' AND l.VALUE >= t.THRESHOLD_VALUE THEN 'PASS'
      WHEN t.THRESHOLD_OP = '>'  AND l.VALUE >  t.THRESHOLD_VALUE THEN 'PASS'
      WHEN t.THRESHOLD_OP = '='  AND l.VALUE =  t.THRESHOLD_VALUE THEN 'PASS'
      ELSE 'FAIL'
    END  AS STATUS
FROM ranked l
LEFT JOIN ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_THRESHOLDS t
       ON  t.DATASET_ID  = l.DATASET_ID
       AND t.METRIC_NAME = l.METRIC_NAME
       AND COALESCE(t.COLUMN_NAME, '') = l.COLUMN_NAME
WHERE l.rn = 1;


-------------------------------------------------------------------------------
-- VW_PNC_DMF_DIMENSION_SCORES
--
-- Per-dataset 0..100 scores derived from the latest DMF measurements.
--
--   DIM_PROFILING_SCORE
--      = 100 * (passed / total) across ALL DMFs with a threshold defined.
--
--   DIM_COMPLETENESS_KEY_PROPS_SCORE
--      = 100 * (1 - max(NULL_PERCENT among IS_KEY_COLUMN=TRUE columns) / 100)
--      Falls back to NULL when no key-column thresholds are defined.
--
--   DIM_TIMELINESS_SCORE
--      = 100 if FRESHNESS within SLA, linear decay, 0 if >= 3x SLA late.
--      Pulls SLA_HOURS from PNC_SOURCE_CLASSIFICATION; FRESHNESS DMF returns
--      seconds, so we convert.
--
--   DIM_ISSUES_SCORE
--      = 100 - 10*p1 - 3*p2 - 1*p3 (floored at 0), where p1/p2/p3 are the
--      counts of FAILED measurements at each severity. This matches the
--      formula used by the bespoke scorer in PNC_DQ_RESULTS.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DMF_DIMENSION_SCORES AS
WITH meas AS (
    SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DMF_LATEST_MEASUREMENTS
)
, profiling AS (
    SELECT
        DATASET_ID
      , COUNT_IF(STATUS IS NOT NULL)        AS CHECKS_TOTAL
      , COUNT_IF(STATUS = 'PASS')           AS CHECKS_PASSED
      , CASE WHEN COUNT_IF(STATUS IS NOT NULL) = 0 THEN NULL
             ELSE 100.0 * COUNT_IF(STATUS = 'PASS') / COUNT_IF(STATUS IS NOT NULL)
        END AS DIM_PROFILING_SCORE
    FROM meas
    GROUP BY DATASET_ID
)
, completeness AS (
    SELECT
        DATASET_ID
      , MAX(VALUE)            AS WORST_NULL_PCT
      , CASE WHEN MAX(VALUE) IS NULL THEN NULL
             ELSE GREATEST(0, 100.0 - MAX(VALUE))
        END AS DIM_COMPLETENESS_KEY_PROPS_SCORE
    FROM meas
    WHERE METRIC_NAME = 'NULL_PERCENT'
      AND IS_KEY_COLUMN = TRUE
    GROUP BY DATASET_ID
)
, timeliness AS (
    SELECT
        m.DATASET_ID
      , m.VALUE / 3600.0                      AS HOURS_LATE
      , s.SLA_HOURS
      , CASE
          WHEN s.SLA_HOURS IS NULL OR s.SLA_HOURS = 0 THEN NULL
          ELSE GREATEST(0,
                LEAST(100, 100.0 * (1 - (m.VALUE / 3600.0 / s.SLA_HOURS) / 3.0)))
        END AS DIM_TIMELINESS_SCORE
    FROM meas m
    LEFT JOIN ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION s
           ON s.DATASET_ID = m.DATASET_ID
    WHERE m.METRIC_NAME = 'FRESHNESS'
)
, issues AS (
    SELECT
        DATASET_ID
      , COUNT_IF(STATUS = 'FAIL' AND SEVERITY_ON_FAIL = 'P1') AS OPEN_P1
      , COUNT_IF(STATUS = 'FAIL' AND SEVERITY_ON_FAIL = 'P2') AS OPEN_P2
      , COUNT_IF(STATUS = 'FAIL' AND SEVERITY_ON_FAIL = 'P3') AS OPEN_P3
      , GREATEST(0, 100
            - 10 * COUNT_IF(STATUS = 'FAIL' AND SEVERITY_ON_FAIL = 'P1')
            -  3 * COUNT_IF(STATUS = 'FAIL' AND SEVERITY_ON_FAIL = 'P2')
            -  1 * COUNT_IF(STATUS = 'FAIL' AND SEVERITY_ON_FAIL = 'P3')
        ) AS DIM_ISSUES_SCORE
    FROM meas
    GROUP BY DATASET_ID
)
, datasets AS (
    SELECT DISTINCT DATASET_ID FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_DMF_DATASET_MAP
)
SELECT
    d.DATASET_ID
  , s.DATASET_NAME
  , s.DATASET_FQN
  , s.SOURCE_DOMAIN                           AS DOMAIN
  , s.LAYER
  , s.SLA_HOURS

  , i.DIM_ISSUES_SCORE
  , i.OPEN_P1                                 AS DIM_ISSUES_OPEN_P1
  , i.OPEN_P2                                 AS DIM_ISSUES_OPEN_P2
  , i.OPEN_P3                                 AS DIM_ISSUES_OPEN_P3

  , t.DIM_TIMELINESS_SCORE
  , t.HOURS_LATE                              AS DIM_TIMELINESS_HOURS_LATE

  , c.DIM_COMPLETENESS_KEY_PROPS_SCORE
  , c.WORST_NULL_PCT                          AS DIM_COMPLETENESS_WORST_NULL_PCT

  , p.DIM_PROFILING_SCORE
  , p.CHECKS_TOTAL                            AS DIM_PROFILING_CHECKS_TOTAL
  , p.CHECKS_PASSED                           AS DIM_PROFILING_CHECKS_PASSED

  , CURRENT_TIMESTAMP()                       AS COMPUTED_AT
FROM datasets d
LEFT JOIN ASATTAR_TRUST_SCORE_POC.DQ_POC.PNC_SOURCE_CLASSIFICATION s ON s.DATASET_ID = d.DATASET_ID
LEFT JOIN profiling    p ON p.DATASET_ID = d.DATASET_ID
LEFT JOIN completeness c ON c.DATASET_ID = d.DATASET_ID
LEFT JOIN timeliness   t ON t.DATASET_ID = d.DATASET_ID
LEFT JOIN issues       i ON i.DATASET_ID = d.DATASET_ID;
