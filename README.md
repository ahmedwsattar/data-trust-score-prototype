# Data Trust Score v2 — DMF-measured, per-layer

A **data trust scorecard** for the P&C Workday reporting datasets, measured
**per layer across the INT → DW → PUBL lineage** using live Snowflake **Data
Metric Functions (DMFs)**.

v2 replaces the v1 synthetic prototype (`ASATTAR_TRUST_SCORE_POC.DQ_POC`, CSV
fallback, dataset-grain). All objects are now `DTS_`-prefixed and hosted in
`EDLE_DW_DB.PNC_DATA`, deployed under `PNC_DEVELOPER_RL`.

---

## What v2 adds over v1

| v1 | v2 |
|---|---|
| Synthetic CSV data | Live DMFs on zero-copy clones of the real tables |
| One score per dataset | Score per **(report family × layer)** — INT, DW, PUBL |
| Flat 10-dim average | **DQ confidence factor** per layer (Bronze/Silver/Gold) |
| — | **CDE 2× weighting** at element (column) grain |
| — | **Measurable ceiling** + **foundational-gap flag** |
| 4 tiers | 5 **trust bands** (Certified ≥ 90) |

## The 10-dimension framework (weights sum to 100)

| Dimension | Weight | Source |
|---|---:|---|
| Data Quality (DAMA) | 22 | **DMF** (completeness, uniqueness) + seeded IDQ (accuracy, consistency, validity) |
| Observability | 12 | **DMF** (freshness, volume) + incidents |
| Ownership & Stewardship | 12 | registry *(foundational)* |
| Classification | 12 | registry *(foundational)* |
| Authoritative Source | 10 | registry *(foundational)* |
| Lineage | 10 | registry (2 confirmed chains) |
| Business Definitions | 9 | glossary coverage |
| Active Issues | 5 | DMF fails + incidents |
| Usage | 5 | usage metrics |
| User Feedback | 3 | feedback ratings |

- **DQ confidence factor** multiplies the measured DQ + Observability scores by
  layer: **INT = Bronze 0.90, DW = Silver 0.75, PUBL = Gold 0.60**.
- **CDE 2×**: completeness on Critical Data Element columns (identifier keys) is
  double-weighted in the DQ rollup.
- **Measurable ceiling** = sum of weights we can measure today (34: DQ 22 +
  Observability 12) plus any seeded registry dims. A score can't exceed the
  ceiling until the remaining dimensions are seeded.
- **Foundational gap** flag fires when Ownership / Classification / Authoritative
  Source is unseeded or zero.
- **Trust bands**: Certified ≥ 90 · Trusted 75–89 · Established 60–74 ·
  Provisional 40–59 · At Risk < 40 (tunable in `DTS_TRUST_BANDS`).

## Scored objects (lineage)

```
POSITION_REPORT
  INT  EDLE_INT_DB.PNC_WORKDAY01.STG_POSITION_REPORT   (COPY)
  DW   EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT          (INSERT)
  PUBL EDLE_PUBL_DB.PNC_ANALYTICS.STG_POSITION_REPORT_VW (VIEW)
  key: (POSITION_ID, REPORT_EFFECTIVE_DATE, REPORT_ENTRY_DATE)

TRENDED_REPORT   (INT skipped — TRUNCATE+COPY, empty at rest; DW is source-of-record)
  DW   EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT           (MERGE)
  PUBL EDLE_PUBL_DB.PNC_ANALYTICS.STG_TRENDED_REPORT_VW (VIEW)
  key: (BUSINESS_PROCESS_WID, EFFECTIVEDATE, EMPLOYEEID, RECORDTYPE)
```

Freshness anchor for both: `LOADDATE`.

---

## Repo layout

```
data-trust-score-prototype/
├── app/
│   ├── config.py             # single source of truth (namespace, dims, weights, bands, confidence, scored objects)
│   ├── shared.py             # Snowflake-first DTS_ loaders + UI helpers
│   ├── trust_score_app.py    # Portfolio, Dataset Detail, Lineage DQ, Methodology
│   ├── ai_use_cases_app.py   # (orthogonal) Workforce/TA analytics
│   └── .streamlit/config.toml
├── ddl/
│   ├── 00_setup.sql              # session pin -> PNC_DEVELOPER_RL / EDLE_DW_DB.PNC_DATA
│   ├── 01_dts_registries.sql     # 7 registry tables (dataset, element+CDE, glossary, ownership, source, lineage, classification)
│   ├── 02_dts_config.sql         # weights (=100), 5 bands, confidence factors
│   ├── 03_dts_measured.sql       # DQ rule results, incidents, usage, feedback
│   ├── 04_dts_scores.sql         # element-dim + dataset trust-score output tables
│   ├── 20_dts_clone_and_dmf.sql  # SP_DTS_CLONE_SCORED_OBJECTS + SP_DTS_ATTACH_BASELINE_DMFS (Track A)
│   ├── 21_dts_key_dmfs.sql       # SP_DTS_ATTACH_KEY_DMFS (NULL_COUNT + DUPLICATE_COUNT, Track A)
│   ├── 25_dts_dmf_measurements.sql # DTS_DMF_MEASUREMENTS store + Track A/B populators
│   ├── 26_dts_bridge_views.sql   # DMF output -> 0-100 DQ/Observability sub-scores (after 25)
│   ├── 30_dts_scoring_engine.sql # SP_DTS_COMPUTE_SCORES (+ latest view)
│   ├── 40_dts_seed_metadata.sql  # seed 5 objects, elements, lineage, foundational dims
│   └── 50_create_streamlit_apps.sql
├── docs/
└── README.md
```

---

## Deploy run order (worksheet, role `PNC_DEVELOPER_RL`)

```
1.  ddl/00_setup.sql
2.  ddl/01_dts_registries.sql
3.  ddl/02_dts_config.sql
4.  ddl/03_dts_measured.sql
5.  ddl/04_dts_scores.sql
6.  ddl/20_dts_clone_and_dmf.sql        -- defines clone SP (+ native-DMF attach SP, Track A only)
7.  ddl/21_dts_key_dmfs.sql             -- defines native key-DMF attach SP (Track A only)
8.  ddl/25_dts_dmf_measurements.sql     -- unified store + Track A/B populators  (MUST precede 26)
9.  ddl/26_dts_bridge_views.sql         -- bridge reads DTS_DMF_MEASUREMENTS  (after 25)
10. ddl/30_dts_scoring_engine.sql
11. ddl/40_dts_seed_metadata.sql        -- seeds the registry (must precede the CALLs below)

-- clone the scored objects (both tracks need the clones):
CALL SP_DTS_CLONE_SCORED_OBJECTS();     -- fills CLONE_FQN + CLONE_EXISTS
```

### DMF measurement — pick a track

**Track B — manual SQL (default; NO account grant needed):**
```sql
CALL SP_DTS_COMPUTE_DQ_MEASUREMENTS();  -- computes metrics over the clones
CALL SP_DTS_COMPUTE_SCORES();
SELECT * FROM DTS_VW_DATASET_TRUST_SCORE_LATEST ORDER BY TRUST_SCORE DESC;
```

**Track A — native DMFs (once the grants below exist):**
```sql
CALL SP_DTS_ATTACH_BASELINE_DMFS();     -- ROW_COUNT + FRESHNESS on clones
CALL SP_DTS_ATTACH_KEY_DMFS();          -- NULL_COUNT + DUPLICATE_COUNT on keys
-- wait for the first scheduled DMF run, then:
CALL SP_DTS_SYNC_NATIVE_DMF_RESULTS();  -- copy SNOWFLAKE.LOCAL -> DTS_DMF_MEASUREMENTS
CALL SP_DTS_COMPUTE_SCORES();
```

Both tracks write the same `DTS_DMF_MEASUREMENTS` table, so the bridge view,
scoring engine, and app are identical. Switch tracks by choosing which
populator SP you schedule.

### Native-DMF grants (ACCOUNTADMIN — only needed for Track A)

`PNC_DEVELOPER_RL` does **not** have these by default (verified 2026-07):

```sql
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE PNC_DEVELOPER_RL;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE PNC_DEVELOPER_RL;
```

Until then, **use Track B** — it produces the same scorecard with only the
`PNC_DATA_RWC` privileges the role already holds.

### Streamlit apps

See `ddl/50_create_streamlit_apps.sql` — creates a stage, uploads
`config.py + shared.py + trust_score_app.py + ai_use_cases_app.py +
.streamlit/config.toml`, and defines two named `STREAMLIT` objects.

---

## Design decisions

1. **No new schema.** `PNC_DEVELOPER_RL` can't `CREATE SCHEMA` on the shared
   EDLE databases, so every object is `DTS_`-prefixed inside
   `EDLE_DW_DB.PNC_DATA` (it holds `PNC_DATA_RWC`).
2. **Clone-based DMFs.** Production tables are never altered. Each scored object
   is cloned to `DTS_CLONE__<db>__<schema>__<obj>` (CTAS snapshot for PUBL
   views, which can't be zero-copy cloned); DMFs attach to the clone.
3. **`config.py` is the single source of truth.** Dimensions, weights, bands,
   confidence factors, and the scored-object map live there; the DDL seeds
   mirror it and the app imports it, so nothing drifts.
4. **Snowflake-first app.** No synthetic CSVs — the score is computed live. The
   app renders an enablement banner until the DTS_ objects exist and
   `SP_DTS_COMPUTE_SCORES()` has run.
