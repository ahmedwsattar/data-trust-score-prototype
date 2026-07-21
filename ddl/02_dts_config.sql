-------------------------------------------------------------------------------
-- ddl/02_dts_config.sql
-- v2 Data Trust Score -- scoring configuration (tunable by governance).
--
-- Three small config tables the scoring engine reads:
--   DTS_DIMENSION_WEIGHTS   : 10 dims, weights sum to 100, + flags
--   DTS_TRUST_BANDS         : 5 bands (Certified >=90 pinned; rest tunable)
--   DTS_DQ_CONFIDENCE_FACTOR: per-layer confidence multiplier on measured DQ
--
-- Values mirror app/config.py exactly (single source of truth). Seeded inline
-- here so the DDL deploy is self-contained.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. DTS_DIMENSION_WEIGHTS
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_DIMENSION_WEIGHTS (
    DIMENSION_CODE    VARCHAR NOT NULL PRIMARY KEY,
    DIMENSION_LABEL   VARCHAR NOT NULL,
    WEIGHT            NUMBER  NOT NULL,      -- sums to 100 across rows
    IS_FOUNDATIONAL   BOOLEAN NOT NULL,      -- gap flag if unseeded/zero
    IS_DMF_MEASURED   BOOLEAN NOT NULL       -- contributes to measurable ceiling
);

INSERT INTO DTS_DIMENSION_WEIGHTS
    (DIMENSION_CODE, DIMENSION_LABEL, WEIGHT, IS_FOUNDATIONAL, IS_DMF_MEASURED)
VALUES
    ('DQ',             'Data Quality (DAMA)',      22, FALSE, TRUE),
    ('OBSERVABILITY',  'Observability',            12, FALSE, TRUE),
    ('OWNERSHIP',      'Ownership & Stewardship',  12, TRUE,  FALSE),
    ('CLASSIFICATION', 'Classification',           12, TRUE,  FALSE),
    ('AUTH_SOURCE',    'Authoritative Source',     10, TRUE,  FALSE),
    ('LINEAGE',        'Lineage',                  10, FALSE, FALSE),
    ('DEFINITIONS',    'Business Definitions',      9, FALSE, FALSE),
    ('ACTIVE_ISSUES',  'Active Issues',             5, FALSE, FALSE),
    ('USAGE',          'Usage',                     5, FALSE, FALSE),
    ('FEEDBACK',       'User Feedback',             3, FALSE, FALSE);

-- Guard: weights must sum to 100.
SELECT IFF(SUM(WEIGHT) = 100, 'OK', 'ERROR: weights sum = ' || SUM(WEIGHT)) AS weight_check
FROM DTS_DIMENSION_WEIGHTS;

-------------------------------------------------------------------------------
-- 2. DTS_TRUST_BANDS  (Certified >=90 pinned by framework; others are defaults)
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_TRUST_BANDS (
    BAND_NAME       VARCHAR NOT NULL PRIMARY KEY,
    MIN_SCORE       NUMBER  NOT NULL,   -- inclusive
    MAX_SCORE       NUMBER  NOT NULL,   -- inclusive
    SORT_ORDER      NUMBER  NOT NULL,
    HEX_COLOR       VARCHAR NOT NULL
);

INSERT INTO DTS_TRUST_BANDS (BAND_NAME, MIN_SCORE, MAX_SCORE, SORT_ORDER, HEX_COLOR)
VALUES
    ('CERTIFIED',   90, 100, 1, '#1E8E3E'),
    ('TRUSTED',     75,  89, 2, '#66BB6A'),
    ('ESTABLISHED', 60,  74, 3, '#C9A227'),
    ('PROVISIONAL', 40,  59, 4, '#ED9B0F'),
    ('AT_RISK',      0,  39, 5, '#C44545');

-------------------------------------------------------------------------------
-- 3. DTS_DQ_CONFIDENCE_FACTOR
--    Layer -> confidence tier -> multiplier applied to the measured DQ + Obs
--    dimensions. INT=Bronze, DW=Silver, PUBL=Gold (Source reserved, unused).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_DQ_CONFIDENCE_FACTOR (
    CONFIDENCE_TIER   VARCHAR NOT NULL PRIMARY KEY,   -- SOURCE|BRONZE|SILVER|GOLD
    LAYER             VARCHAR,                         -- INT|DW|PUBL (null for SOURCE)
    CONFIDENCE_FACTOR FLOAT   NOT NULL
);

INSERT INTO DTS_DQ_CONFIDENCE_FACTOR (CONFIDENCE_TIER, LAYER, CONFIDENCE_FACTOR)
VALUES
    ('SOURCE', NULL,   1.00),
    ('BRONZE', 'INT',  0.90),
    ('SILVER', 'DW',   0.75),
    ('GOLD',   'PUBL', 0.60);
