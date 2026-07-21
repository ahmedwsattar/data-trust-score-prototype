-------------------------------------------------------------------------------
-- ddl/30_dts_scoring_engine.sql
-- v2 Data Trust Score -- scoring engine.
--
-- SP_DTS_COMPUTE_SCORES(run_date) computes, per scored object
-- (report_family x layer):
--   1. Element-grain DQ completeness for each key column, CDE-weighted (2x for
--      IS_CDE columns) -> a CDE-weighted completeness sub-score.
--   2. DQ dimension = average of available DAMA sub-dims:
--        completeness (CDE-weighted, DMF), uniqueness (DMF),
--        accuracy/consistency/validity (seeded from DTS_DQ_RULE_RESULT).
--   3. Observability dimension = avg(freshness, volume) with open-incident
--      penalties.
--   4. DQ + Observability RAW scores are multiplied by the per-layer confidence
--      factor (INT/Bronze 0.90, DW/Silver 0.75, PUBL/Gold 0.60).
--   5. Registry-driven dims (Ownership, Classification, Auth Source, Lineage,
--      Definitions, Active Issues, Usage, Feedback) scored from their tables.
--   6. Weighted rollup over the 10 dims (blanks = 0) -> TRUST_SCORE (0-100).
--   7. MEASURABLE_CEILING = sum of weights of dims with a non-null score.
--   8. FOUNDATIONAL_GAP_FLAG = TRUE if any foundational dim
--      (Ownership/Classification/Auth Source) is unseeded/zero.
--   9. TRUST_BAND from DTS_TRUST_BANDS.
--
-- Writes DTS_ELEMENT_DIMENSION_SCORE (audit grain) + DTS_DATASET_TRUST_SCORE
-- (final). Idempotent per run_date (deletes that day's rows first).
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

CREATE OR REPLACE PROCEDURE SP_DTS_COMPUTE_SCORES(RUN_DATE DATE DEFAULT CURRENT_DATE())
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    n_dim_rows   INTEGER DEFAULT 0;
    n_score_rows INTEGER DEFAULT 0;
BEGIN
    -- Idempotency: clear this run_date.
    DELETE FROM DTS_ELEMENT_DIMENSION_SCORE WHERE SCORE_RUN_DATE = :RUN_DATE;
    DELETE FROM DTS_DATASET_TRUST_SCORE     WHERE SCORE_RUN_DATE = :RUN_DATE;

    ---------------------------------------------------------------------------
    -- Build the per-(family, layer, dimension) score set, then materialize it
    -- into DTS_ELEMENT_DIMENSION_SCORE (table grain; COLUMN_NAME = NULL).
    -- CONFIDENCE_FACTOR is the layer factor for DQ/OBSERVABILITY, 1.0 otherwise.
    -- RAW_SCORE is pre-confidence, 0-100 (or NULL when not measurable).
    ---------------------------------------------------------------------------
    INSERT INTO DTS_ELEMENT_DIMENSION_SCORE
        (REPORT_FAMILY, LAYER, COLUMN_NAME, DIMENSION_CODE, RAW_SCORE,
         CONFIDENCE_FACTOR, CRITICALITY_MULTIPLIER, IS_MEASURABLE, SCORE_RUN_DATE)
    WITH reg AS (
        SELECT REPORT_FAMILY, LAYER, DQ_MEASUREMENT_LAYER, CLONE_FQN
        FROM   DTS_DATASET_REGISTRY
        WHERE  IS_IN_SCOPE = TRUE
    )
    , cf AS (   -- confidence factor per layer
        SELECT LAYER, CONFIDENCE_FACTOR FROM DTS_DQ_CONFIDENCE_FACTOR WHERE LAYER IS NOT NULL
    )
    , dmf AS (  -- DMF-derived sub-scores per object
        SELECT * FROM DTS_VW_DMF_DIMENSION_SCORES
    )
    ---------------------------------------------------------------------------
    -- DQ: element-grain CDE-weighted completeness across key columns.
    ---------------------------------------------------------------------------
    , null_by_col AS (
        SELECT
            lm.REPORT_FAMILY, lm.LAYER, lm.COLUMN_NAME,
            lm.VALUE AS NULL_CNT
        FROM DTS_VW_DMF_LATEST_MEASUREMENTS lm
        WHERE lm.METRIC_NAME = 'SNOWFLAKE.CORE.NULL_COUNT'
    )
    , rowcount_by_obj AS (
        SELECT REPORT_FAMILY, LAYER, ROW_COUNT_V
        FROM dmf
    )
    , comp_col AS (
        SELECT
            n.REPORT_FAMILY, n.LAYER, n.COLUMN_NAME,
            CASE
                WHEN rc.ROW_COUNT_V IS NULL OR rc.ROW_COUNT_V = 0
                     THEN IFF(n.NULL_CNT = 0, 100, 50)
                ELSE GREATEST(0, 100 - 100.0 * n.NULL_CNT / rc.ROW_COUNT_V)
            END AS COMPLETENESS_SCORE,
            COALESCE(e.CRITICALITY_MULTIPLIER, 1.0) AS CDE_MULT
        FROM null_by_col n
        LEFT JOIN rowcount_by_obj rc
               ON rc.REPORT_FAMILY = n.REPORT_FAMILY AND rc.LAYER = n.LAYER
        LEFT JOIN DTS_DATA_ELEMENT e
               ON e.REPORT_FAMILY = n.REPORT_FAMILY AND e.LAYER = n.LAYER
              AND e.COLUMN_NAME = n.COLUMN_NAME
    )
    , comp_cde AS (   -- CDE-weighted completeness per object
        SELECT
            REPORT_FAMILY, LAYER,
            ROUND(SUM(COMPLETENESS_SCORE * CDE_MULT) / NULLIF(SUM(CDE_MULT), 0), 1)
                AS COMPLETENESS_CDE_SCORE
        FROM comp_col
        GROUP BY REPORT_FAMILY, LAYER
    )
    , dq_seeded AS (  -- seeded DAMA sub-dims (accuracy/consistency/validity)
        SELECT
            REPORT_FAMILY, LAYER,
            AVG(IFF(DAMA_SUB_DIM = 'ACCURACY',    PASS_PCT, NULL)) AS ACCURACY_SCORE,
            AVG(IFF(DAMA_SUB_DIM = 'CONSISTENCY', PASS_PCT, NULL)) AS CONSISTENCY_SCORE,
            AVG(IFF(DAMA_SUB_DIM = 'VALIDITY',    PASS_PCT, NULL)) AS VALIDITY_SCORE
        FROM DTS_DQ_RULE_RESULT
        WHERE SCORE_RUN_DATE <= :RUN_DATE
        GROUP BY REPORT_FAMILY, LAYER
    )
    , dq AS (   -- DQ dimension = mean of available DAMA sub-dims
        SELECT
            r.REPORT_FAMILY, r.LAYER,
            -- average across the non-null DAMA sub-dim scores
            (
              COALESCE(cc.COMPLETENESS_CDE_SCORE, 0) * IFF(cc.COMPLETENESS_CDE_SCORE IS NULL,0,1)
            + COALESCE(d.DQ_UNIQUENESS_SCORE, 0)     * IFF(d.DQ_UNIQUENESS_SCORE IS NULL,0,1)
            + COALESCE(s.ACCURACY_SCORE, 0)          * IFF(s.ACCURACY_SCORE IS NULL,0,1)
            + COALESCE(s.CONSISTENCY_SCORE, 0)       * IFF(s.CONSISTENCY_SCORE IS NULL,0,1)
            + COALESCE(s.VALIDITY_SCORE, 0)          * IFF(s.VALIDITY_SCORE IS NULL,0,1)
            )
            / NULLIF(
                IFF(cc.COMPLETENESS_CDE_SCORE IS NULL,0,1)
              + IFF(d.DQ_UNIQUENESS_SCORE IS NULL,0,1)
              + IFF(s.ACCURACY_SCORE IS NULL,0,1)
              + IFF(s.CONSISTENCY_SCORE IS NULL,0,1)
              + IFF(s.VALIDITY_SCORE IS NULL,0,1), 0)
              AS DQ_RAW
        FROM reg r
        LEFT JOIN comp_cde  cc ON cc.REPORT_FAMILY = r.REPORT_FAMILY AND cc.LAYER = r.LAYER
        LEFT JOIN dmf       d  ON d.REPORT_FAMILY  = r.REPORT_FAMILY AND d.LAYER  = r.LAYER
        LEFT JOIN dq_seeded s  ON s.REPORT_FAMILY  = r.REPORT_FAMILY AND s.LAYER  = r.LAYER
    )
    ---------------------------------------------------------------------------
    -- Observability: avg(freshness, volume) minus open-incident penalties.
    ---------------------------------------------------------------------------
    , incidents AS (
        SELECT REPORT_FAMILY, LAYER,
               SUM(CASE SEVERITY WHEN 'P1' THEN 30 WHEN 'P2' THEN 15 ELSE 5 END) AS PENALTY
        FROM DTS_OBSERVABILITY_INCIDENT
        WHERE STATUS = 'OPEN'
        GROUP BY REPORT_FAMILY, LAYER
    )
    , obs AS (
        SELECT
            r.REPORT_FAMILY, r.LAYER,
            CASE
              WHEN d.OBS_FRESHNESS_SCORE IS NULL AND d.OBS_VOLUME_SCORE IS NULL THEN NULL
              ELSE GREATEST(0,
                   ( COALESCE(d.OBS_FRESHNESS_SCORE,0)*IFF(d.OBS_FRESHNESS_SCORE IS NULL,0,1)
                   + COALESCE(d.OBS_VOLUME_SCORE,0)*IFF(d.OBS_VOLUME_SCORE IS NULL,0,1) )
                   / NULLIF(IFF(d.OBS_FRESHNESS_SCORE IS NULL,0,1)+IFF(d.OBS_VOLUME_SCORE IS NULL,0,1),0)
                   - COALESCE(i.PENALTY,0))
            END AS OBS_RAW
        FROM reg r
        LEFT JOIN dmf d       ON d.REPORT_FAMILY = r.REPORT_FAMILY AND d.LAYER = r.LAYER
        LEFT JOIN incidents i ON i.REPORT_FAMILY = r.REPORT_FAMILY AND i.LAYER = r.LAYER
    )
    ---------------------------------------------------------------------------
    -- Registry-driven dimensions (NULL when unseeded).
    ---------------------------------------------------------------------------
    , own AS (
        SELECT REPORT_FAMILY, LAYER,
               (IFF(HAS_OWNER,50,0) + IFF(HAS_STEWARD,50,0)) AS OWNERSHIP_RAW
        FROM DTS_OWNERSHIP_STEWARDSHIP_REGISTRY
    )
    , cls AS (
        SELECT REPORT_FAMILY, LAYER,
               CASE WHEN CLASSIFIED_COLUMN_PCT > 0 THEN CLASSIFIED_COLUMN_PCT
                    WHEN HAS_CLASSIFICATION THEN 100 ELSE 0 END AS CLASSIFICATION_RAW
        FROM DTS_CLASSIFICATION_REGISTRY
    )
    , auth AS (
        SELECT REPORT_FAMILY, LAYER, IFF(IS_AUTHORITATIVE,100,0) AS AUTH_SOURCE_RAW
        FROM DTS_SOURCE_CERTIFICATION_REGISTRY
    )
    , lin AS (
        SELECT REPORT_FAMILY, LAYER, MAX(100) AS LINEAGE_RAW
        FROM DTS_LINEAGE_REGISTRY
        GROUP BY REPORT_FAMILY, LAYER
    )
    , defn AS (
        SELECT REPORT_FAMILY, LAYER,
               ROUND(100.0 * AVG(IFF(HAS_DEF,1,0)), 1) AS DEFINITIONS_RAW
        FROM (
            SELECT e.REPORT_FAMILY, e.LAYER,
                   IFF(g.HAS_DEFINITION, TRUE, FALSE) AS HAS_DEF
            FROM DTS_DATA_ELEMENT e
            LEFT JOIN DTS_BUSINESS_GLOSSARY g ON g.BUSINESS_TERM = e.BUSINESS_TERM
            WHERE e.BUSINESS_TERM IS NOT NULL
        )
        GROUP BY REPORT_FAMILY, LAYER
    )
    , iss AS (
        SELECT REPORT_FAMILY, LAYER, ACTIVE_ISSUES_DMF_SCORE AS ACTIVE_ISSUES_RAW
        FROM dmf
    )
    , usg AS (
        SELECT REPORT_FAMILY, LAYER,
               CASE WHEN QUERY_COUNT_30D >= 100 THEN 100
                    WHEN QUERY_COUNT_30D >= 20  THEN 75
                    WHEN QUERY_COUNT_30D >= 5   THEN 50
                    WHEN QUERY_COUNT_30D >= 1   THEN 25
                    ELSE 0 END AS USAGE_RAW
        FROM DTS_USAGE_METRICS
        QUALIFY ROW_NUMBER() OVER (PARTITION BY REPORT_FAMILY, LAYER ORDER BY SCORE_RUN_DATE DESC) = 1
    )
    , fb AS (
        SELECT REPORT_FAMILY, LAYER, ROUND(20.0 * AVG(RATING), 1) AS FEEDBACK_RAW
        FROM DTS_USER_FEEDBACK
        GROUP BY REPORT_FAMILY, LAYER
    )
    ---------------------------------------------------------------------------
    -- Unpivot to (family, layer, dim_code, raw_score, confidence_factor).
    ---------------------------------------------------------------------------
    , dim_scores AS (
        SELECT r.REPORT_FAMILY, r.LAYER, 'DQ' AS DIMENSION_CODE,
               dq.DQ_RAW AS RAW_SCORE, COALESCE(cf.CONFIDENCE_FACTOR,1.0) AS CONFIDENCE_FACTOR
        FROM reg r LEFT JOIN dq ON dq.REPORT_FAMILY=r.REPORT_FAMILY AND dq.LAYER=r.LAYER
                   LEFT JOIN cf ON cf.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'OBSERVABILITY',
               obs.OBS_RAW, COALESCE(cf.CONFIDENCE_FACTOR,1.0)
        FROM reg r LEFT JOIN obs ON obs.REPORT_FAMILY=r.REPORT_FAMILY AND obs.LAYER=r.LAYER
                   LEFT JOIN cf ON cf.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'OWNERSHIP', own.OWNERSHIP_RAW, 1.0
        FROM reg r LEFT JOIN own ON own.REPORT_FAMILY=r.REPORT_FAMILY AND own.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'CLASSIFICATION', cls.CLASSIFICATION_RAW, 1.0
        FROM reg r LEFT JOIN cls ON cls.REPORT_FAMILY=r.REPORT_FAMILY AND cls.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'AUTH_SOURCE', auth.AUTH_SOURCE_RAW, 1.0
        FROM reg r LEFT JOIN auth ON auth.REPORT_FAMILY=r.REPORT_FAMILY AND auth.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'LINEAGE', lin.LINEAGE_RAW, 1.0
        FROM reg r LEFT JOIN lin ON lin.REPORT_FAMILY=r.REPORT_FAMILY AND lin.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'DEFINITIONS', defn.DEFINITIONS_RAW, 1.0
        FROM reg r LEFT JOIN defn ON defn.REPORT_FAMILY=r.REPORT_FAMILY AND defn.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'ACTIVE_ISSUES', iss.ACTIVE_ISSUES_RAW, 1.0
        FROM reg r LEFT JOIN iss ON iss.REPORT_FAMILY=r.REPORT_FAMILY AND iss.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'USAGE', usg.USAGE_RAW, 1.0
        FROM reg r LEFT JOIN usg ON usg.REPORT_FAMILY=r.REPORT_FAMILY AND usg.LAYER=r.LAYER
        UNION ALL
        SELECT r.REPORT_FAMILY, r.LAYER, 'FEEDBACK', fb.FEEDBACK_RAW, 1.0
        FROM reg r LEFT JOIN fb ON fb.REPORT_FAMILY=r.REPORT_FAMILY AND fb.LAYER=r.LAYER
    )
    SELECT
        REPORT_FAMILY, LAYER, NULL AS COLUMN_NAME, DIMENSION_CODE,
        ROUND(RAW_SCORE, 1) AS RAW_SCORE,
        CONFIDENCE_FACTOR,
        1.0 AS CRITICALITY_MULTIPLIER,
        IFF(RAW_SCORE IS NOT NULL, TRUE, FALSE) AS IS_MEASURABLE,
        :RUN_DATE
    FROM dim_scores;

    n_dim_rows := SQLROWCOUNT;

    ---------------------------------------------------------------------------
    -- Roll up element/dimension scores to the final dataset trust score.
    -- Effective score = RAW_SCORE * CONFIDENCE_FACTOR (CDE already folded into
    -- DQ RAW). Blanks (NULL) count as 0 in the weighted sum, so TRUST_SCORE is
    -- naturally capped by the measurable ceiling.
    ---------------------------------------------------------------------------
    INSERT INTO DTS_DATASET_TRUST_SCORE
        (REPORT_FAMILY, LAYER, DATASET_FQN, DQ_MEASUREMENT_LAYER, TRUST_SCORE,
         TRUST_BAND, MEASURABLE_CEILING, MEASURED_SUBTOTAL, FOUNDATIONAL_GAP_FLAG,
         FOUNDATIONAL_GAPS, SCORE_RUN_DATE)
    WITH s AS (
        SELECT eds.REPORT_FAMILY, eds.LAYER, eds.DIMENSION_CODE,
               eds.RAW_SCORE, eds.CONFIDENCE_FACTOR, eds.IS_MEASURABLE,
               w.WEIGHT, w.IS_FOUNDATIONAL,
               eds.RAW_SCORE * eds.CONFIDENCE_FACTOR AS EFFECTIVE_SCORE
        FROM DTS_ELEMENT_DIMENSION_SCORE eds
        JOIN DTS_DIMENSION_WEIGHTS w ON w.DIMENSION_CODE = eds.DIMENSION_CODE
        WHERE eds.SCORE_RUN_DATE = :RUN_DATE
    )
    , rollup AS (
        SELECT
            REPORT_FAMILY, LAYER,
            ROUND(SUM(WEIGHT * COALESCE(EFFECTIVE_SCORE,0) / 100.0), 1) AS TRUST_SCORE,
            SUM(IFF(IS_MEASURABLE, WEIGHT, 0))                          AS MEASURABLE_CEILING,
            BOOLOR_AGG(
                (IS_FOUNDATIONAL AND NOT COALESCE(IS_MEASURABLE,FALSE))
                OR (IS_FOUNDATIONAL AND COALESCE(RAW_SCORE,0)=0)
            )                                                           AS FOUNDATIONAL_GAP_FLAG,
            ARRAY_AGG(IFF(IS_FOUNDATIONAL AND COALESCE(RAW_SCORE,0)=0, DIMENSION_CODE, NULL))
                                                                        AS GAPS_RAW
        FROM s
        GROUP BY REPORT_FAMILY, LAYER
    )
    SELECT
        ru.REPORT_FAMILY, ru.LAYER, reg.DATASET_FQN, reg.DQ_MEASUREMENT_LAYER,
        ru.TRUST_SCORE,
        COALESCE(b.BAND_NAME, 'AT_RISK') AS TRUST_BAND,
        ru.MEASURABLE_CEILING,
        ru.TRUST_SCORE AS MEASURED_SUBTOTAL,
        ru.FOUNDATIONAL_GAP_FLAG,
        ARRAY_COMPACT(ru.GAPS_RAW) AS FOUNDATIONAL_GAPS,
        :RUN_DATE
    FROM rollup ru
    JOIN DTS_DATASET_REGISTRY reg
      ON reg.REPORT_FAMILY = ru.REPORT_FAMILY AND reg.LAYER = ru.LAYER
    -- Pick the highest band whose MIN_SCORE the score meets. Using MIN_SCORE
    -- only (not BETWEEN) avoids gaps for fractional FLOAT scores, e.g. 89.5.
    LEFT JOIN DTS_TRUST_BANDS b
      ON ru.TRUST_SCORE >= b.MIN_SCORE
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ru.REPORT_FAMILY, ru.LAYER
        ORDER BY b.MIN_SCORE DESC
    ) = 1;

    n_score_rows := SQLROWCOUNT;

    RETURN OBJECT_CONSTRUCT('run_date', :RUN_DATE,
                            'dimension_rows', :n_dim_rows,
                            'dataset_rows', :n_score_rows);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_COMPUTE_SCORES(DATE) IS
    'Compute v2 trust scores: element DQ (CDE-weighted) + Obs x confidence + registry dims -> weighted rollup -> ceiling/gap/band. Writes DTS_ELEMENT_DIMENSION_SCORE + DTS_DATASET_TRUST_SCORE.';

-- Convenience consumer view: latest run per object.
CREATE OR REPLACE VIEW DTS_VW_DATASET_TRUST_SCORE_LATEST AS
SELECT *
FROM DTS_DATASET_TRUST_SCORE
QUALIFY ROW_NUMBER() OVER (PARTITION BY REPORT_FAMILY, LAYER ORDER BY SCORE_RUN_DATE DESC) = 1;

-- After ddl/40 seeds registries + DMFs have measured:
--   CALL SP_DTS_COMPUTE_SCORES();
--   SELECT * FROM DTS_VW_DATASET_TRUST_SCORE_LATEST ORDER BY TRUST_SCORE DESC;
