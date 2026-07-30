-------------------------------------------------------------------------------
-- ddl/32_dts_element_detail.sql
-- v2 Data Trust Score -- element (column) level score detail.
--
-- DTS_VW_ELEMENT_TRUST_DETAIL exposes, per (report_family, layer, column), a
-- score for each of the 10 trust dimensions -- the drill-down behind the
-- dataset score (the app's "Score - STG_*" matrix from the framework workbook).
--
--   Per-element (true column-grain data where it exists):
--     DQ            -- per-column completeness (NULL_COUNT vs row count) x layer
--                      confidence factor; falls back to the dataset DQ score
--                      when the column has no DMF reading.
--     DEFINITIONS   -- 100 if the column's BUSINESS_TERM has an approved
--                      glossary definition, else 0.
--     CLASSIFICATION-- 100 if the column carries a PII_TAG, else 0.
--     CDE flag / CRITICALITY_MULTIPLIER from DTS_DATA_ELEMENT.
--
--   Inherited from the dataset (table-grain today -- same value for every
--   column of the object): OBSERVABILITY, OWNERSHIP, AUTH_SOURCE, LINEAGE,
--   ACTIVE_ISSUES, USAGE, FEEDBACK. Taken from DTS_ELEMENT_DIMENSION_SCORE
--   (COLUMN_NAME IS NULL) latest run as RAW_SCORE x CONFIDENCE_FACTOR.
--
--   ELEMENT_SCORE /100 = weighted sum of the row's dimension scores using
--   DTS_DIMENSION_WEIGHTS (weights sum to 100) -- mirrors the workbook's
--   "Element Score /100" column.
--
-- Read-only: derives everything from existing objects; does NOT modify the
-- scoring engine or the dataset rollup. Deploy AFTER ddl/30 (needs
-- DTS_ELEMENT_DIMENSION_SCORE populated by SP_DTS_COMPUTE_SCORES at run time).
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

CREATE OR REPLACE VIEW DTS_VW_ELEMENT_TRUST_DETAIL AS
WITH latest_run AS (
    SELECT MAX(SCORE_RUN_DATE) AS RUN_DATE FROM DTS_ELEMENT_DIMENSION_SCORE
)
, reg AS (
    SELECT REPORT_FAMILY, LAYER
    FROM DTS_DATASET_REGISTRY
    WHERE IS_IN_SCOPE = TRUE
)
-- Table-grain dimension EFFECTIVE scores (RAW x CF) for the latest run,
-- pivoted wide so each element can inherit them.
, dim AS (
    SELECT
        REPORT_FAMILY, LAYER,
        MAX(IFF(DIMENSION_CODE = 'DQ',            RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS DQ_DS,
        MAX(IFF(DIMENSION_CODE = 'OBSERVABILITY', RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS OBSERVABILITY_DS,
        MAX(IFF(DIMENSION_CODE = 'OWNERSHIP',     RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS OWNERSHIP_DS,
        MAX(IFF(DIMENSION_CODE = 'CLASSIFICATION',RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS CLASSIFICATION_DS,
        MAX(IFF(DIMENSION_CODE = 'AUTH_SOURCE',   RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS AUTH_SOURCE_DS,
        MAX(IFF(DIMENSION_CODE = 'LINEAGE',       RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS LINEAGE_DS,
        MAX(IFF(DIMENSION_CODE = 'DEFINITIONS',   RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS DEFINITIONS_DS,
        MAX(IFF(DIMENSION_CODE = 'ACTIVE_ISSUES', RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS ACTIVE_ISSUES_DS,
        MAX(IFF(DIMENSION_CODE = 'USAGE',         RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS USAGE_DS,
        MAX(IFF(DIMENSION_CODE = 'FEEDBACK',      RAW_SCORE * CONFIDENCE_FACTOR, NULL)) AS FEEDBACK_DS
    FROM DTS_ELEMENT_DIMENSION_SCORE
    WHERE COLUMN_NAME IS NULL
      AND SCORE_RUN_DATE = (SELECT RUN_DATE FROM latest_run)
    GROUP BY REPORT_FAMILY, LAYER
)
, cf AS (
    SELECT LAYER, CONFIDENCE_FACTOR
    FROM DTS_DQ_CONFIDENCE_FACTOR
    WHERE LAYER IS NOT NULL
)
, rowcnt AS (   -- object row count (for per-column completeness denominator)
    -- DTS_VW_DMF_DIMENSION_SCORES is grained by (family, layer, measurement
    -- layer); collapse to one row per (family, layer) so the join to elements
    -- can never fan out if a second measurement layer ever appears.
    SELECT REPORT_FAMILY, LAYER, MAX(ROW_COUNT_V) AS ROW_COUNT_V
    FROM DTS_VW_DMF_DIMENSION_SCORES
    GROUP BY REPORT_FAMILY, LAYER
)
, nullcol AS (  -- per-column NULL_COUNT, when the DMF has measured it
    SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, VALUE AS NULL_CNT
    FROM DTS_VW_DMF_LATEST_MEASUREMENTS
    WHERE METRIC_NAME = 'SNOWFLAKE.CORE.NULL_COUNT'
      AND COLUMN_NAME IS NOT NULL
)
, elem AS (
    SELECT
        e.REPORT_FAMILY, e.LAYER, e.COLUMN_NAME,
        e.IS_KEY, e.IS_CDE, e.CRITICALITY_MULTIPLIER, e.PII_TAG, e.BUSINESS_TERM,
        -- DQ: per-column completeness x CF, else inherit dataset DQ effective.
        CASE
            WHEN nc.NULL_CNT IS NOT NULL AND rc.ROW_COUNT_V IS NOT NULL AND rc.ROW_COUNT_V > 0
                THEN ROUND(GREATEST(0, 100 - 100.0 * nc.NULL_CNT / rc.ROW_COUNT_V)
                           * COALESCE(cf.CONFIDENCE_FACTOR, 1.0), 1)
            ELSE dim.DQ_DS
        END                                                       AS DQ_EL,
        IFF(g.HAS_DEFINITION, 100, 0)                             AS DEFINITIONS_EL,
        IFF(e.PII_TAG IS NOT NULL, 100, 0)                        AS CLASSIFICATION_EL,
        dim.OBSERVABILITY_DS                                      AS OBSERVABILITY_EL,
        dim.OWNERSHIP_DS                                          AS OWNERSHIP_EL,
        dim.AUTH_SOURCE_DS                                        AS AUTH_SOURCE_EL,
        dim.LINEAGE_DS                                            AS LINEAGE_EL,
        dim.ACTIVE_ISSUES_DS                                      AS ACTIVE_ISSUES_EL,
        dim.USAGE_DS                                              AS USAGE_EL,
        dim.FEEDBACK_DS                                           AS FEEDBACK_EL
    FROM DTS_DATA_ELEMENT e
    JOIN reg r        ON r.REPORT_FAMILY = e.REPORT_FAMILY AND r.LAYER = e.LAYER
    LEFT JOIN dim     ON dim.REPORT_FAMILY = e.REPORT_FAMILY AND dim.LAYER = e.LAYER
    LEFT JOIN cf      ON cf.LAYER = e.LAYER
    LEFT JOIN rowcnt rc ON rc.REPORT_FAMILY = e.REPORT_FAMILY AND rc.LAYER = e.LAYER
    LEFT JOIN nullcol nc ON nc.REPORT_FAMILY = e.REPORT_FAMILY AND nc.LAYER = e.LAYER
                        AND nc.COLUMN_NAME = e.COLUMN_NAME
    LEFT JOIN DTS_BUSINESS_GLOSSARY g ON g.BUSINESS_TERM = e.BUSINESS_TERM
)
-- Unpivot to (column, dimension, score) so ELEMENT_SCORE is computed from the
-- weights table (config-driven) rather than hardcoded coefficients.
, elem_long AS (
    SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'DQ'             AS DIMENSION_CODE, DQ_EL            AS SC FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'OBSERVABILITY',  OBSERVABILITY_EL  FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'OWNERSHIP',      OWNERSHIP_EL      FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'CLASSIFICATION', CLASSIFICATION_EL FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'AUTH_SOURCE',    AUTH_SOURCE_EL    FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'LINEAGE',        LINEAGE_EL        FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'DEFINITIONS',    DEFINITIONS_EL    FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'ACTIVE_ISSUES',  ACTIVE_ISSUES_EL  FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'USAGE',          USAGE_EL          FROM elem
    UNION ALL SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, 'FEEDBACK',       FEEDBACK_EL       FROM elem
)
, elem_score AS (
    SELECT
        el.REPORT_FAMILY, el.LAYER, el.COLUMN_NAME,
        -- Self-normalize over the weights actually present + non-null so a
        -- missing/NULL dimension can't silently understate the score, and the
        -- scale stays correct if the weights table ever drifts from summing 100.
        ROUND(SUM(w.WEIGHT * el.SC)
              / NULLIF(SUM(IFF(el.SC IS NULL, 0, w.WEIGHT)), 0), 1) AS ELEMENT_SCORE
    FROM elem_long el
    JOIN DTS_DIMENSION_WEIGHTS w ON w.DIMENSION_CODE = el.DIMENSION_CODE
    GROUP BY el.REPORT_FAMILY, el.LAYER, el.COLUMN_NAME
)
SELECT
    elem.REPORT_FAMILY, elem.LAYER, elem.COLUMN_NAME,
    elem.IS_KEY, elem.IS_CDE, elem.CRITICALITY_MULTIPLIER, elem.PII_TAG, elem.BUSINESS_TERM,
    elem.DQ_EL, elem.OBSERVABILITY_EL, elem.OWNERSHIP_EL, elem.CLASSIFICATION_EL,
    elem.AUTH_SOURCE_EL, elem.LINEAGE_EL, elem.DEFINITIONS_EL, elem.ACTIVE_ISSUES_EL,
    elem.USAGE_EL, elem.FEEDBACK_EL,
    es.ELEMENT_SCORE
FROM elem
LEFT JOIN elem_score es
       ON es.REPORT_FAMILY = elem.REPORT_FAMILY
      AND es.LAYER = elem.LAYER
      AND es.COLUMN_NAME = elem.COLUMN_NAME;

COMMENT ON VIEW DTS_VW_ELEMENT_TRUST_DETAIL IS
    'Per (report_family, layer, column) score for each of the 10 trust dimensions: DQ/Definitions/Classification/CDE per element, the rest inherited from the dataset; ELEMENT_SCORE = weighted sum. Drill-down behind the dataset trust score.';

-- Sanity after SP_DTS_COMPUTE_SCORES() has run:
--   SELECT REPORT_FAMILY, LAYER, COLUMN_NAME, DQ_EL, DEFINITIONS_EL,
--          CLASSIFICATION_EL, ELEMENT_SCORE
--   FROM DTS_VW_ELEMENT_TRUST_DETAIL
--   WHERE REPORT_FAMILY = 'POSITION_REPORT' AND LAYER = 'DW'
--   ORDER BY ELEMENT_SCORE DESC;
