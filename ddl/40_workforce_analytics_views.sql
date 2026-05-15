-------------------------------------------------------------------------------
-- 40_workforce_analytics_views.sql
-- Applied analytics views on top of DT_TRENDED_REPORT and DT_POSITION_REPORT.
-- Powers the Workforce Shifts and TA Analytics pages of the Streamlit app.
--
-- Each view answers a specific client AI use case using only SQL (no Cortex,
-- no DMF privileges, no Python). The architecture stays the same when scaled
-- to production -- just point the FROM clauses at the prod tables.
--
-- Views:
--   VW_WORKFORCE_WEEKLY_METRICS  -- weekly counts by L1, with rolling baselines
--   VW_WORKFORCE_ANOMALIES       -- z-score per (week, L1, metric) flag
--   VW_REORG_EVENTS              -- bulk L1/L2 movements between snapshots
--   VW_TIME_TO_FILL              -- per-position vacate -> fill duration
--   VW_RECRUITER_WORKLOAD        -- active reqs per recruiter (latest snapshot)
--
-- Run order: after DT_* tables exist and have been populated (file 30).
-- These views don't depend on the Cortex DQ infrastructure so can run
-- independently of files 20-25.
-------------------------------------------------------------------------------

USE ROLE      DATA_CLEAN_ROOM_ROLE;
USE WAREHOUSE WH_DEFAULT;
USE DATABASE  ASATTAR_TRUST_SCORE_POC;
USE SCHEMA    ASATTAR_TRUST_SCORE_POC.DQ_POC;


-------------------------------------------------------------------------------
-- SECTION A: WORKFORCE WEEKLY METRICS + BASELINES
--
-- Aggregates DT_TRENDED_REPORT into weekly counts per L1, then attaches a
-- 4-week trailing baseline (mean + stddev, excluding the current week).
--
-- Columns aggregated correspond to the trended report's per-employee event
-- flags: HIRECOUNT, VOLUNTARYTERMINATIONCOUNT, INVOLUNTARYTERMINATIONCOUNT,
-- PROMOCOUNT. SUM across (L1, week) gives a meaningful event volume.
-- HEADCOUNT is COUNT(DISTINCT EMPLOYEEID) -- physical people in the L1.
--
-- 4-week trailing window is intentionally short for the POC (only 16 weekly
-- snapshots available). With a full year of history, change to:
--    ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING       (13-week trailing)
--    or use a partition-by-quarter or partition-by-month-of-year for YoY.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_WORKFORCE_WEEKLY_METRICS AS
WITH weekly_agg AS (
    SELECT
        DATE_TRUNC('week', EFFECTIVEDATE)::DATE         AS WEEK_START
      , COALESCE(L1, '(unknown)')                       AS L1
      , COUNT(DISTINCT EMPLOYEEID)                      AS HEADCOUNT
      , COALESCE(SUM(HIRECOUNT), 0)                     AS HIRES
      , COALESCE(SUM(VOLUNTARYTERMINATIONCOUNT), 0)     AS VOLUNTARY_TERMS
      , COALESCE(SUM(INVOLUNTARYTERMINATIONCOUNT), 0)   AS INVOLUNTARY_TERMS
      , COALESCE(SUM(PROMOCOUNT), 0)                    AS PROMOTIONS
    FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
    GROUP BY 1, 2
)
SELECT
    WEEK_START
  , L1
  , HEADCOUNT
  , HIRES
  , VOLUNTARY_TERMS
  , INVOLUNTARY_TERMS
  , PROMOTIONS
  , AVG(HIRES)              OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS HIRES_BASELINE
  , STDDEV(HIRES)           OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS HIRES_STD
  , AVG(VOLUNTARY_TERMS)    OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS VOLUNTARY_TERMS_BASELINE
  , STDDEV(VOLUNTARY_TERMS) OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS VOLUNTARY_TERMS_STD
  , AVG(INVOLUNTARY_TERMS)  OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS INVOLUNTARY_TERMS_BASELINE
  , STDDEV(INVOLUNTARY_TERMS) OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS INVOLUNTARY_TERMS_STD
  , AVG(PROMOTIONS)         OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS PROMOTIONS_BASELINE
  , STDDEV(PROMOTIONS)      OVER (PARTITION BY L1 ORDER BY WEEK_START ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS PROMOTIONS_STD
FROM weekly_agg;


-------------------------------------------------------------------------------
-- SECTION B: WORKFORCE ANOMALY FLAGGING
--
-- Long-format view -- one row per (week, L1, metric). Computes z-score
-- against the trailing baseline and assigns a STATUS:
--   - INSUFFICIENT_HISTORY  -- not enough trailing weeks for a baseline
--   - NORMAL                -- |z| < 1
--   - NOTABLE               -- 1 <= |z| < 2
--   - ANOMALY               -- |z| >= 2
--
-- This is the exact failure mode the client called out: "involuntary
-- turnover dropped 50% suddenly" -> ANOMALY row with negative z-score.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_WORKFORCE_ANOMALIES AS
WITH wide AS (
    SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_WORKFORCE_WEEKLY_METRICS
)
, long AS (
    SELECT WEEK_START, L1, 'Hires'             AS METRIC_NAME, HIRES             AS ACTUAL, HIRES_BASELINE             AS BASELINE, HIRES_STD             AS STD,
           CASE WHEN HIRES_STD             > 0 THEN (HIRES             - HIRES_BASELINE)             / HIRES_STD             END AS Z_SCORE
    FROM wide WHERE HIRES_BASELINE IS NOT NULL
    UNION ALL
    SELECT WEEK_START, L1, 'Voluntary terms',     VOLUNTARY_TERMS,   VOLUNTARY_TERMS_BASELINE,   VOLUNTARY_TERMS_STD,
           CASE WHEN VOLUNTARY_TERMS_STD   > 0 THEN (VOLUNTARY_TERMS   - VOLUNTARY_TERMS_BASELINE)   / VOLUNTARY_TERMS_STD   END
    FROM wide WHERE VOLUNTARY_TERMS_BASELINE IS NOT NULL
    UNION ALL
    SELECT WEEK_START, L1, 'Involuntary terms',   INVOLUNTARY_TERMS, INVOLUNTARY_TERMS_BASELINE, INVOLUNTARY_TERMS_STD,
           CASE WHEN INVOLUNTARY_TERMS_STD > 0 THEN (INVOLUNTARY_TERMS - INVOLUNTARY_TERMS_BASELINE) / INVOLUNTARY_TERMS_STD END
    FROM wide WHERE INVOLUNTARY_TERMS_BASELINE IS NOT NULL
    UNION ALL
    SELECT WEEK_START, L1, 'Promotions',          PROMOTIONS,        PROMOTIONS_BASELINE,        PROMOTIONS_STD,
           CASE WHEN PROMOTIONS_STD        > 0 THEN (PROMOTIONS        - PROMOTIONS_BASELINE)        / PROMOTIONS_STD        END
    FROM wide WHERE PROMOTIONS_BASELINE IS NOT NULL
)
SELECT
    WEEK_START
  , L1
  , METRIC_NAME
  , ACTUAL
  , BASELINE
  , STD
  , Z_SCORE
  , CASE
        WHEN Z_SCORE IS NULL          THEN 'INSUFFICIENT_HISTORY'
        WHEN ABS(Z_SCORE) >= 2        THEN 'ANOMALY'
        WHEN ABS(Z_SCORE) >= 1        THEN 'NOTABLE'
        ELSE                               'NORMAL'
    END AS STATUS
  , CASE
        WHEN Z_SCORE IS NULL          THEN NULL
        WHEN Z_SCORE > 0              THEN 'UP'
        WHEN Z_SCORE < 0              THEN 'DOWN'
        ELSE                               'FLAT'
    END AS DIRECTION
FROM long;


-------------------------------------------------------------------------------
-- SECTION C: REORG EVENTS
--
-- Tracks bulk L1 and L2 movements between consecutive snapshots. Threshold
-- of >= 5 employees moved in a single (week, from->to) tuple is the cut-off
-- for a "noteworthy event" -- tune EMPLOYEES_MOVED >= N at the bottom of
-- each branch to make it more or less sensitive.
--
-- The client's example ("alerted to reorganizations - large movements
-- between L1/L2") lands here: each event row is exactly one alert.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_REORG_EVENTS AS
WITH employee_history AS (
    SELECT
        EMPLOYEEID
      , EFFECTIVEDATE
      , L1
      , L2
      , LAG(L1) OVER (PARTITION BY EMPLOYEEID ORDER BY EFFECTIVEDATE) AS PREV_L1
      , LAG(L2) OVER (PARTITION BY EMPLOYEEID ORDER BY EFFECTIVEDATE) AS PREV_L2
    FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT
    WHERE EMPLOYEEID IS NOT NULL
)
, l1_movements AS (
    SELECT
        EFFECTIVEDATE                                AS MOVEMENT_DATE
      , 'L1'                                         AS LEVEL_NAME
      , PREV_L1                                      AS FROM_ORG
      , L1                                           AS TO_ORG
      , COUNT(*)                                     AS EMPLOYEES_MOVED
    FROM employee_history
    WHERE PREV_L1 IS NOT NULL
      AND L1      IS NOT NULL
      AND PREV_L1 != L1
    GROUP BY 1, 2, 3, 4
)
, l2_movements AS (
    SELECT
        EFFECTIVEDATE                                AS MOVEMENT_DATE
      , 'L2'                                         AS LEVEL_NAME
      , PREV_L2                                      AS FROM_ORG
      , L2                                           AS TO_ORG
      , COUNT(*)                                     AS EMPLOYEES_MOVED
    FROM employee_history
    WHERE PREV_L2 IS NOT NULL
      AND L2      IS NOT NULL
      AND PREV_L2 != L2
    GROUP BY 1, 2, 3, 4
)
SELECT * FROM l1_movements WHERE EMPLOYEES_MOVED >= 5
UNION ALL
SELECT * FROM l2_movements WHERE EMPLOYEES_MOVED >= 5;


-------------------------------------------------------------------------------
-- SECTION D: TIME-TO-FILL
--
-- Computed from the LATEST DT_POSITION_REPORT snapshot (avoids double-
-- counting from the weekly snapshots). Returns one row per position with
-- a meaningful fill duration. Three fill types are accepted:
--
--   REFILL        -> position was vacated and then refilled
--                    days = LAST_FILL_DATE - VACATE_DATE
--   INITIAL_FILL  -> newly created position filled for the first time
--                    days = LAST_FILL_DATE - POSITION_CREATED_MOMENT
--   STILL_OPEN    -> position is currently vacant; days = how long it's
--                    been open as of today (signals long-vacant reqs)
--
-- Combining these gives the page a population to chart even when the
-- data sample is sparse on refill events. Filter by FILL_TYPE in the UI.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_TIME_TO_FILL AS
WITH latest AS (
    SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
    WHERE REPORT_EFFECTIVE_DATE = (
            SELECT MAX(REPORT_EFFECTIVE_DATE)
            FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)
)
, computed AS (
    SELECT
        POSITION_ID
      , JOB_FAMILY
      , JOB_FAMILY_GROUP
      , JOB_REQUISITION_PRIMARY_RECRUITER             AS RECRUITER
      , JOB_REQUISITION_STATUS
      , POSITION_STAFFING_STATUS
      , L1
      , L2
      , POSITION_CREATED_MOMENT
      , POSITION_VACATE_DATE
      , POSITION_LAST_FILL_DATE
      , CASE
            WHEN POSITION_VACATE_DATE     IS NOT NULL
             AND POSITION_LAST_FILL_DATE  IS NOT NULL
             AND POSITION_LAST_FILL_DATE >= POSITION_VACATE_DATE
                THEN 'REFILL'
            WHEN POSITION_VACATE_DATE     IS NULL
             AND POSITION_LAST_FILL_DATE  IS NOT NULL
             AND POSITION_CREATED_MOMENT  IS NOT NULL
             AND POSITION_LAST_FILL_DATE >= POSITION_CREATED_MOMENT
                THEN 'INITIAL_FILL'
            WHEN POSITION_VACATE_DATE     IS NOT NULL
             AND (POSITION_LAST_FILL_DATE IS NULL OR POSITION_LAST_FILL_DATE < POSITION_VACATE_DATE)
                THEN 'STILL_OPEN'
        END                                            AS FILL_TYPE
      , CASE
            WHEN POSITION_VACATE_DATE     IS NOT NULL
             AND POSITION_LAST_FILL_DATE  IS NOT NULL
             AND POSITION_LAST_FILL_DATE >= POSITION_VACATE_DATE
                THEN DATEDIFF('day', POSITION_VACATE_DATE, POSITION_LAST_FILL_DATE)
            WHEN POSITION_VACATE_DATE     IS NULL
             AND POSITION_LAST_FILL_DATE  IS NOT NULL
             AND POSITION_CREATED_MOMENT  IS NOT NULL
             AND POSITION_LAST_FILL_DATE >= POSITION_CREATED_MOMENT
                THEN DATEDIFF('day', POSITION_CREATED_MOMENT, POSITION_LAST_FILL_DATE)
            WHEN POSITION_VACATE_DATE     IS NOT NULL
             AND (POSITION_LAST_FILL_DATE IS NULL OR POSITION_LAST_FILL_DATE < POSITION_VACATE_DATE)
                THEN DATEDIFF('day', POSITION_VACATE_DATE, CURRENT_DATE())
        END                                            AS DAYS_TO_FILL
    FROM latest
)
SELECT *
FROM computed
WHERE DAYS_TO_FILL IS NOT NULL
  AND DAYS_TO_FILL >= 0;


-------------------------------------------------------------------------------
-- SECTION E: RECRUITER WORKLOAD
--
-- Active recruitment workload per recruiter, current snapshot. Uses
-- POSITION_STAFFING_STATUS as the primary signal (reliably populated for
-- every position) instead of OPEN_JOB_REQUISITION_ID (which is only set
-- on positions with an active req).
--
-- Columns:
--   POSITIONS_TOUCHED  -- every position the recruiter is named on
--                         (includes historical fills the recruiter ran)
--   ACTIVE_WORKLOAD    -- vacant + frozen positions = current pipeline
--                         (PRIMARY workload metric for the page)
--   VACANT_POSITIONS   -- POSITION_STAFFING_STATUS = 'Open'
--   FROZEN_POSITIONS   -- POSITION_STAFFING_STATUS = 'Frozen'
--   ACTIVE_REQS        -- JOB_REQUISITION_STATUS = 'Open' (when populated)
--   OPEN_REQS          -- DISTINCT OPEN_JOB_REQUISITION_ID (sparse)
--   FILLED_TO_DATE     -- POSITION_STAFFING_STATUS = 'Filled' (history)
--
-- HAVING ACTIVE_WORKLOAD > 0 keeps only recruiters with current pipeline.
-- Drop the HAVING if you want to see historical fills with no active load.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_RECRUITER_WORKLOAD AS
WITH latest AS (
    SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
    WHERE REPORT_EFFECTIVE_DATE = (
            SELECT MAX(REPORT_EFFECTIVE_DATE)
            FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)
)
SELECT
    JOB_REQUISITION_PRIMARY_RECRUITER                          AS RECRUITER
  , COUNT(DISTINCT POSITION_ID)                                AS POSITIONS_TOUCHED
  , COUNT_IF(POSITION_STAFFING_STATUS IN ('Open', 'Frozen'))   AS ACTIVE_WORKLOAD
  , COUNT_IF(POSITION_STAFFING_STATUS = 'Open')                AS VACANT_POSITIONS
  , COUNT_IF(POSITION_STAFFING_STATUS = 'Frozen')              AS FROZEN_POSITIONS
  , COUNT_IF(JOB_REQUISITION_STATUS = 'Open')                  AS ACTIVE_REQS
  , COUNT(DISTINCT OPEN_JOB_REQUISITION_ID)                    AS OPEN_REQS
  , COUNT_IF(POSITION_STAFFING_STATUS = 'Filled')              AS FILLED_TO_DATE
  , COUNT(DISTINCT JOB_FAMILY)                                 AS JOB_FAMILIES_COVERED
  , COUNT(DISTINCT L1)                                         AS L1_ORGS_COVERED
FROM latest
WHERE JOB_REQUISITION_PRIMARY_RECRUITER IS NOT NULL
GROUP BY 1
HAVING COUNT_IF(POSITION_STAFFING_STATUS IN ('Open', 'Frozen')) > 0;


-------------------------------------------------------------------------------
-- SECTION F: SMOKE TEST QUERIES
--
-- Run these once after the CREATEs to confirm each view is producing data.
-------------------------------------------------------------------------------

SELECT 'VW_WORKFORCE_WEEKLY_METRICS' AS view_name, COUNT(*) AS row_count
  FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_WORKFORCE_WEEKLY_METRICS
UNION ALL
SELECT 'VW_WORKFORCE_ANOMALIES'      , COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_WORKFORCE_ANOMALIES
UNION ALL
SELECT 'VW_REORG_EVENTS'             , COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_REORG_EVENTS
UNION ALL
SELECT 'VW_TIME_TO_FILL'             , COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_TIME_TO_FILL
UNION ALL
SELECT 'VW_RECRUITER_WORKLOAD'       , COUNT(*) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_RECRUITER_WORKLOAD;

-- Top anomalies (recent, ranked by absolute z-score)
SELECT WEEK_START, L1, METRIC_NAME, ACTUAL, BASELINE, Z_SCORE, STATUS, DIRECTION
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_WORKFORCE_ANOMALIES
WHERE STATUS IN ('ANOMALY', 'NOTABLE')
ORDER BY ABS(Z_SCORE) DESC NULLS LAST
LIMIT 20;

-- Recent reorg events
SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_REORG_EVENTS
ORDER BY MOVEMENT_DATE DESC, EMPLOYEES_MOVED DESC
LIMIT 20;

-- Time-to-fill breakdown by FILL_TYPE (sanity check after the patch)
SELECT
    FILL_TYPE
  , COUNT(*)                                          AS POSITIONS
  , ROUND(AVG(DAYS_TO_FILL), 1)                       AS AVG_DAYS
  , ROUND(MEDIAN(DAYS_TO_FILL), 1)                    AS MEDIAN_DAYS
  , MAX(DAYS_TO_FILL)                                 AS MAX_DAYS
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_TIME_TO_FILL
GROUP BY 1;

-- Time-to-fill summary by job family group (top 20 families with data)
SELECT
    JOB_FAMILY_GROUP
  , COUNT(*)                                          AS POSITIONS
  , ROUND(AVG(DAYS_TO_FILL), 1)                       AS AVG_DAYS
  , ROUND(MEDIAN(DAYS_TO_FILL), 1)                    AS MEDIAN_DAYS
  , MAX(DAYS_TO_FILL)                                 AS MAX_DAYS
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_TIME_TO_FILL
GROUP BY 1
ORDER BY POSITIONS DESC
LIMIT 20;

-------------------------------------------------------------------------------
-- SECTION G: SOURCE-COLUMN PROFILING (run when the views look empty)
--
-- If VW_TIME_TO_FILL or VW_RECRUITER_WORKLOAD has zero rows, run this block
-- to see why -- it profiles the underlying columns in the latest snapshot
-- so you can tell whether the dates / IDs / recruiter fields are sparsely
-- populated.
-------------------------------------------------------------------------------

WITH latest AS (
    SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
    WHERE REPORT_EFFECTIVE_DATE = (
        SELECT MAX(REPORT_EFFECTIVE_DATE)
        FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)
)
SELECT
    COUNT(*)                                                                       AS total_positions
  , COUNT(POSITION_VACATE_DATE)                                                    AS has_vacate_date
  , COUNT(POSITION_LAST_FILL_DATE)                                                 AS has_last_fill_date
  , COUNT(POSITION_CREATED_MOMENT)                                                 AS has_created_moment
  , COUNT_IF(POSITION_VACATE_DATE IS NOT NULL AND POSITION_LAST_FILL_DATE IS NOT NULL) AS has_both_fill_dates
  , COUNT_IF(POSITION_LAST_FILL_DATE >= POSITION_VACATE_DATE)                      AS refilled_positions
  , COUNT_IF(POSITION_VACATE_DATE IS NULL  AND POSITION_LAST_FILL_DATE IS NOT NULL) AS initial_fill_only
  , COUNT(JOB_REQUISITION_PRIMARY_RECRUITER)                                       AS has_recruiter
  , COUNT(OPEN_JOB_REQUISITION_ID)                                                 AS has_open_req_id
  , COUNT_IF(JOB_REQUISITION_PRIMARY_RECRUITER IS NOT NULL AND OPEN_JOB_REQUISITION_ID IS NOT NULL) AS has_both_recruiter_fields
FROM latest;

-- Distinct status values to understand what "open" means in your data
SELECT 'POSITION_STAFFING_STATUS' AS field, POSITION_STAFFING_STATUS AS value, COUNT(*) AS cnt
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
WHERE REPORT_EFFECTIVE_DATE = (SELECT MAX(REPORT_EFFECTIVE_DATE) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)
GROUP BY 1, 2
UNION ALL
SELECT 'JOB_REQUISITION_STATUS', JOB_REQUISITION_STATUS, COUNT(*)
FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
WHERE REPORT_EFFECTIVE_DATE = (SELECT MAX(REPORT_EFFECTIVE_DATE) FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)
GROUP BY 1, 2
ORDER BY 1, cnt DESC;
