-------------------------------------------------------------------------------
-- ddl/01_dts_registries.sql
-- v2 Data Trust Score -- registry / metadata tables (governance-driven dims).
--
-- These tables hold the human/governance-curated signals that Cortex DQ does
-- NOT measure: dataset inventory, element (column) inventory + CDE flags,
-- business glossary, ownership, authoritative-source certification, lineage,
-- and classification. Scores for the registry-driven dimensions are derived
-- from these in ddl/30_dts_scoring_engine.sql.
--
-- Grain notes:
--   DTS_DATASET_REGISTRY  : one row per (report_family, layer) scored object.
--   DTS_DATA_ELEMENT      : one row per (dataset, column) -- element grain.
-- All tables CREATE OR REPLACE so the deploy is idempotent.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. DTS_DATASET_REGISTRY -- the scored-object inventory.
--    One row per object we measure across the INT->DW->PUBL lineage.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_DATASET_REGISTRY (
    DATASET_ID            NUMBER IDENTITY(1,1) PRIMARY KEY,
    REPORT_FAMILY         VARCHAR    NOT NULL,   -- POSITION_REPORT | TRENDED_REPORT
    LAYER                 VARCHAR    NOT NULL,   -- INT | DW | PUBL
    DATABASE_NAME         VARCHAR    NOT NULL,
    SCHEMA_NAME           VARCHAR    NOT NULL,
    OBJECT_NAME           VARCHAR    NOT NULL,
    OBJECT_TYPE           VARCHAR    NOT NULL,   -- TABLE | VIEW
    DATASET_FQN           VARCHAR    NOT NULL,   -- db.schema.object (source)
    CLONE_FQN             VARCHAR,               -- DTS_CLONE__... (set by clone SP)
    DQ_MEASUREMENT_LAYER  VARCHAR    NOT NULL,   -- BRONZE | SILVER | GOLD (confidence tier)
    IS_VIEW               BOOLEAN    NOT NULL DEFAULT FALSE,
    FRESHNESS_COLUMN      VARCHAR,               -- ranked #1 anchor for FRESHNESS DMF
    KEY_COLUMNS           ARRAY,                 -- composite key for DUPLICATE_COUNT
    MARKETPLACE_STATUS    VARCHAR    DEFAULT 'INTERNAL',
    IS_IN_SCOPE           BOOLEAN    NOT NULL DEFAULT TRUE,
    CLONE_EXISTS          BOOLEAN    NOT NULL DEFAULT FALSE,
    CREATED_AT            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_DATASET UNIQUE (REPORT_FAMILY, LAYER)
);
COMMENT ON TABLE DTS_DATASET_REGISTRY IS
    'v2 scored-object inventory: one row per (report_family, layer) across INT/DW/PUBL. CLONE_FQN + CLONE_EXISTS maintained by the clone SP.';

-------------------------------------------------------------------------------
-- 2. DTS_DATA_ELEMENT -- element (column) inventory + CDE flags.
--    Element-grain scoring in ddl/30 rolls these up with the CDE 2x multiplier.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_DATA_ELEMENT (
    ELEMENT_ID              NUMBER IDENTITY(1,1) PRIMARY KEY,
    DATASET_ID              NUMBER    NOT NULL,
    REPORT_FAMILY           VARCHAR   NOT NULL,
    LAYER                   VARCHAR   NOT NULL,
    COLUMN_NAME             VARCHAR   NOT NULL,
    IS_KEY                  BOOLEAN   NOT NULL DEFAULT FALSE,
    IS_CDE                  BOOLEAN   NOT NULL DEFAULT FALSE,  -- critical data element
    CRITICALITY_MULTIPLIER  FLOAT     NOT NULL DEFAULT 1.0,    -- 2.0 when IS_CDE
    PII_TAG                 VARCHAR,                            -- source WPII_/WSPII_ tag if any
    BUSINESS_TERM           VARCHAR,                            -- FK-ish to glossary term
    CREATED_AT              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_ELEMENT UNIQUE (REPORT_FAMILY, LAYER, COLUMN_NAME)
);
COMMENT ON TABLE DTS_DATA_ELEMENT IS
    'Per-column inventory. IS_CDE + CRITICALITY_MULTIPLIER (2.0) drive the CDE-weighted rollup. CDE candidates seeded from repo PII tags.';

-------------------------------------------------------------------------------
-- 3. DTS_BUSINESS_GLOSSARY -- business definitions coverage (Definitions dim).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_BUSINESS_GLOSSARY (
    TERM_ID          NUMBER IDENTITY(1,1) PRIMARY KEY,
    BUSINESS_TERM    VARCHAR NOT NULL,
    DEFINITION       VARCHAR,
    HAS_DEFINITION   BOOLEAN NOT NULL DEFAULT FALSE,
    STEWARD          VARCHAR,
    SOURCE_SYSTEM    VARCHAR DEFAULT 'COLLIBRA',
    CREATED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_TERM UNIQUE (BUSINESS_TERM)
);
COMMENT ON TABLE DTS_BUSINESS_GLOSSARY IS
    'Business glossary terms; HAS_DEFINITION drives the Definitions dimension coverage %.';

-------------------------------------------------------------------------------
-- 4. DTS_OWNERSHIP_STEWARDSHIP_REGISTRY -- Ownership dimension (foundational).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_OWNERSHIP_STEWARDSHIP_REGISTRY (
    DATASET_ID        NUMBER NOT NULL,
    REPORT_FAMILY     VARCHAR NOT NULL,
    LAYER             VARCHAR NOT NULL,
    DATA_OWNER        VARCHAR,
    DATA_STEWARD      VARCHAR,
    TECHNICAL_OWNER   VARCHAR,
    HAS_OWNER         BOOLEAN NOT NULL DEFAULT FALSE,
    HAS_STEWARD       BOOLEAN NOT NULL DEFAULT FALSE,
    CREATED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_OWNER UNIQUE (REPORT_FAMILY, LAYER)
);
COMMENT ON TABLE DTS_OWNERSHIP_STEWARDSHIP_REGISTRY IS
    'Ownership/stewardship per scored object (foundational dim -- gap flag if unseeded).';

-------------------------------------------------------------------------------
-- 5. DTS_SOURCE_CERTIFICATION_REGISTRY -- Authoritative Source dim (foundational).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_SOURCE_CERTIFICATION_REGISTRY (
    DATASET_ID          NUMBER NOT NULL,
    REPORT_FAMILY       VARCHAR NOT NULL,
    LAYER               VARCHAR NOT NULL,
    SOURCE_SYSTEM       VARCHAR,                 -- e.g. WORKDAY
    IS_AUTHORITATIVE    BOOLEAN NOT NULL DEFAULT FALSE,
    CERTIFIED_BY        VARCHAR,
    CERTIFIED_DATE      DATE,
    CREATED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_SRC UNIQUE (REPORT_FAMILY, LAYER)
);
COMMENT ON TABLE DTS_SOURCE_CERTIFICATION_REGISTRY IS
    'Authoritative-source certification per object (foundational dim).';

-------------------------------------------------------------------------------
-- 6. DTS_LINEAGE_REGISTRY -- Lineage dimension. Seeded with the two confirmed
--    chains; UPSTREAM/DOWNSTREAM null-ness drives lineage coverage.
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_LINEAGE_REGISTRY (
    LINEAGE_ID        NUMBER IDENTITY(1,1) PRIMARY KEY,
    REPORT_FAMILY     VARCHAR NOT NULL,
    LAYER             VARCHAR NOT NULL,
    OBJECT_FQN        VARCHAR NOT NULL,
    UPSTREAM_FQN      VARCHAR,                   -- null at the earliest layer
    DOWNSTREAM_FQN    VARCHAR,                   -- null at the terminal layer
    TRANSFORM_TYPE    VARCHAR,                   -- COPY | INSERT | MERGE | VIEW
    HAS_UPSTREAM      BOOLEAN NOT NULL DEFAULT FALSE,
    HAS_DOWNSTREAM    BOOLEAN NOT NULL DEFAULT FALSE,
    CREATED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
COMMENT ON TABLE DTS_LINEAGE_REGISTRY IS
    'Lineage edges per object; seeded with the POSITION and TRENDED chains from edl-pnc-repo.';

-------------------------------------------------------------------------------
-- 7. DTS_CLASSIFICATION_REGISTRY -- Classification dimension (foundational).
-------------------------------------------------------------------------------
CREATE OR REPLACE TABLE DTS_CLASSIFICATION_REGISTRY (
    DATASET_ID           NUMBER NOT NULL,
    REPORT_FAMILY        VARCHAR NOT NULL,
    LAYER                VARCHAR NOT NULL,
    HAS_CLASSIFICATION   BOOLEAN NOT NULL DEFAULT FALSE,
    SENSITIVITY_LEVEL    VARCHAR,               -- PUBLIC | INTERNAL | CONFIDENTIAL | RESTRICTED
    PII_PRESENT          BOOLEAN NOT NULL DEFAULT FALSE,
    CLASSIFIED_COLUMN_PCT FLOAT  NOT NULL DEFAULT 0,  -- % of columns tagged
    CREATED_AT           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT UQ_DTS_CLASS UNIQUE (REPORT_FAMILY, LAYER)
);
COMMENT ON TABLE DTS_CLASSIFICATION_REGISTRY IS
    'Classification coverage per object (foundational dim -- gap flag if unseeded).';
