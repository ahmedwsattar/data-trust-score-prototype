-------------------------------------------------------------------------------
-- ddl/26_dts_bridge_views.sql
-- v2 Data Trust Score -- DMF bridge views (raw DMF output -> 0-100 dim scores).
--
-- MUST be deployed AFTER ddl/25 (it selects from DTS_DMF_MEASUREMENTS, which
-- ddl/25 creates). Both DMF tracks write to that unified table:
--   Track B -- SP_DTS_COMPUTE_DQ_MEASUREMENTS (plain SQL, no account grant)
--   Track A -- SP_DTS_SYNC_NATIVE_DMF_RESULTS (copies SNOWFLAKE.LOCAL results)
-- This view reads ONLY DTS_DMF_MEASUREMENTS, so it never references
-- SNOWFLAKE.LOCAL directly and works regardless of DMF privileges. Switch
-- tracks by choosing which populator SP you run.
-- These two views:
--   1. DTS_VW_DMF_LATEST_MEASUREMENTS -- latest reading per (report_family,
--      layer, metric, column) from DTS_DMF_MEASUREMENTS, with inline PASS/FAIL.
--   2. DTS_VW_DMF_DIMENSION_SCORES    -- per (report_family, layer) 0-100 scores
--      for the DMF-measured pieces of two dimensions:
--        DQ (DAMA): completeness (NULL_COUNT), uniqueness (DUPLICATE_COUNT)
--        OBSERVABILITY: freshness (FRESHNESS vs SLA), volume (ROW_COUNT >= 1)
--      plus an ACTIVE_ISSUES contribution from DMF FAIL counts.
--
-- The scoring engine (ddl/30) reads DTS_VW_DMF_DIMENSION_SCORES and blends it
-- with the registry-driven dimensions, applying the per-layer confidence factor.
--
-- SLA per family (freshness): POSITION weekly=168h, TRENDED monthly=840h.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. DTS_VW_DMF_LATEST_MEASUREMENTS
-------------------------------------------------------------------------------
CREATE OR REPLACE VIEW DTS_VW_DMF_LATEST_MEASUREMENTS AS
WITH source AS (
    SELECT
        m.CLONE_FQN
      , m.METRIC_NAME
      , NULLIF(m.COLUMN_NAME, '')            AS COLUMN_NAME
      , m.VALUE
      , m.MEASUREMENT_TIME
      , m.SOURCE_TRACK
      , d.REPORT_FAMILY
      , d.LAYER
      , d.DATASET_FQN
      , d.DQ_MEASUREMENT_LAYER
    FROM DTS_DMF_MEASUREMENTS m
    JOIN DTS_DATASET_REGISTRY d
      ON d.CLONE_FQN = m.CLONE_FQN
    WHERE d.IS_IN_SCOPE = TRUE
)
, ranked AS (
    SELECT s.*,
           ROW_NUMBER() OVER (
             PARTITION BY REPORT_FAMILY, LAYER, METRIC_NAME, COALESCE(COLUMN_NAME, '<table>')
             ORDER BY MEASUREMENT_TIME DESC
           ) AS rn
    FROM source s
)
SELECT
    r.CLONE_FQN
  , r.REPORT_FAMILY
  , r.LAYER
  , r.DATASET_FQN                          -- original source FQN
  , r.DQ_MEASUREMENT_LAYER
  , r.METRIC_NAME
  , r.COLUMN_NAME
  , r.VALUE
  , r.MEASUREMENT_TIME
  , r.SOURCE_TRACK
  -- SLA (seconds) for freshness, by family.
  , CASE r.REPORT_FAMILY
        WHEN 'POSITION_REPORT' THEN 168 * 3600
        WHEN 'TRENDED_REPORT'  THEN 840 * 3600
        ELSE 24 * 3600
    END                                                                       AS SLA_SECS
  , CASE
        WHEN r.METRIC_NAME = 'SNOWFLAKE.CORE.NULL_COUNT'      AND r.VALUE <= 0 THEN 'PASS'
        WHEN r.METRIC_NAME = 'SNOWFLAKE.CORE.DUPLICATE_COUNT' AND r.VALUE <= 0 THEN 'PASS'
        WHEN r.METRIC_NAME = 'SNOWFLAKE.CORE.ROW_COUNT'       AND r.VALUE >= 1 THEN 'PASS'
        WHEN r.METRIC_NAME = 'SNOWFLAKE.CORE.FRESHNESS'
             AND r.VALUE <= (CASE r.REPORT_FAMILY
                                WHEN 'POSITION_REPORT' THEN 168 * 3600
                                WHEN 'TRENDED_REPORT'  THEN 840 * 3600
                                ELSE 24 * 3600 END)                           THEN 'PASS'
        ELSE 'FAIL'
    END                                                                       AS STATUS
FROM ranked r
WHERE r.rn = 1;

COMMENT ON VIEW DTS_VW_DMF_LATEST_MEASUREMENTS IS
    'Latest DMF reading per (clone, metric, column) joined to DTS_DATASET_REGISTRY; source FQN recovered, PASS/FAIL inline.';

-------------------------------------------------------------------------------
-- 2. DTS_VW_DMF_DIMENSION_SCORES
--    Per (report_family, layer): DMF-derived 0-100 for DQ sub-dims +
--    Observability sub-dims + an Active Issues contribution.
-------------------------------------------------------------------------------
CREATE OR REPLACE VIEW DTS_VW_DMF_DIMENSION_SCORES AS
WITH m AS (
    SELECT * FROM DTS_VW_DMF_LATEST_MEASUREMENTS
)
, agg AS (
    SELECT
        REPORT_FAMILY
      , LAYER
      , DQ_MEASUREMENT_LAYER
      , MAX(IFF(METRIC_NAME = 'SNOWFLAKE.CORE.ROW_COUNT', VALUE, NULL))        AS ROW_COUNT_V
      , MAX(IFF(METRIC_NAME = 'SNOWFLAKE.CORE.FRESHNESS', VALUE, NULL))        AS FRESHNESS_SECS
      , MAX(SLA_SECS)                                                          AS SLA_SECS
      -- completeness: worst NULL_COUNT across key columns vs row count
      , MAX(IFF(METRIC_NAME = 'SNOWFLAKE.CORE.NULL_COUNT', VALUE, NULL))       AS MAX_NULLS
      -- uniqueness: worst DUPLICATE_COUNT across composite key
      , MAX(IFF(METRIC_NAME = 'SNOWFLAKE.CORE.DUPLICATE_COUNT', VALUE, NULL))  AS MAX_DUPS
      , COUNT(*)                                                               AS CHECKS_TOTAL
      , SUM(IFF(STATUS = 'FAIL', 1, 0))                                        AS FAIL_COUNT
    FROM m
    GROUP BY REPORT_FAMILY, LAYER, DQ_MEASUREMENT_LAYER
)
SELECT
    REPORT_FAMILY
  , LAYER
  , DQ_MEASUREMENT_LAYER

  -- DAMA completeness: 100 when no nulls; else decay by null fraction.
  , CASE
        WHEN MAX_NULLS IS NULL THEN NULL
        WHEN ROW_COUNT_V IS NULL OR ROW_COUNT_V = 0 THEN IFF(MAX_NULLS = 0, 100, 50)
        ELSE GREATEST(0, ROUND(100 - 100.0 * MAX_NULLS / ROW_COUNT_V, 1))
    END                                                                       AS DQ_COMPLETENESS_SCORE

  -- DAMA uniqueness: 100 when no dups on the composite key; else 0.
  , CASE
        WHEN MAX_DUPS IS NULL THEN NULL
        ELSE IFF(MAX_DUPS <= 0, 100, 0)
    END                                                                       AS DQ_UNIQUENESS_SCORE

  -- Observability freshness: 100 within SLA, linear decay to 0 at 3x SLA.
  , CASE
        WHEN FRESHNESS_SECS IS NULL THEN NULL
        WHEN FRESHNESS_SECS <= SLA_SECS THEN 100
        WHEN FRESHNESS_SECS >= 3 * SLA_SECS THEN 0
        ELSE ROUND(100 - 100.0 * (FRESHNESS_SECS - SLA_SECS) / (2.0 * SLA_SECS), 1)
    END                                                                       AS OBS_FRESHNESS_SCORE

  -- Observability volume: 100 if the table has rows, else 0.
  , CASE
        WHEN ROW_COUNT_V IS NULL THEN NULL
        ELSE IFF(ROW_COUNT_V >= 1, 100, 0)
    END                                                                       AS OBS_VOLUME_SCORE

  -- Active Issues contribution from DMF fails (P3-equivalent, -25 each).
  , GREATEST(0, 100 - 25 * COALESCE(FAIL_COUNT, 0))                           AS ACTIVE_ISSUES_DMF_SCORE

  , ROW_COUNT_V
  , FRESHNESS_SECS
  , SLA_SECS
  , MAX_NULLS
  , MAX_DUPS
  , CHECKS_TOTAL
  , FAIL_COUNT
  , CURRENT_TIMESTAMP()                                                       AS COMPUTED_AT
FROM agg;

COMMENT ON VIEW DTS_VW_DMF_DIMENSION_SCORES IS
    'Per (report_family, layer) DMF-derived 0-100 sub-scores: DQ completeness/uniqueness, Observability freshness/volume, Active Issues.';
