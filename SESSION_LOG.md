# Data Trust Score v2 — Session Log & Context

> Purpose: full working context so a new Cortex Code session started from the
> `data-trust-score-prototype/` folder can pick up without re-discovery.
> Last updated: 2026-07-20.

---

## 1. What this project is

A per-layer **Data Trust Score** scorecard for the P&C Workday reporting datasets,
computed with Snowflake **Data Metric Functions (DMFs)** and rolled up to a 0–100
score across **10 dimensions** with **5 trust bands** (Certified ≥90 … At Risk <40).

- **v1** (history): `ASATTAR_TRUST_SCORE_POC.DQ_POC`, synthetic CSVs, one score per dataset.
- **v2** (current): all objects `DTS_`-prefixed, hosted **inside `EDLE_DW_DB.PNC_DATA`**
  (no new schema — the deploy role can't `CREATE SCHEMA` on shared EDLE databases),
  deployed under role **`PNC_DEVELOPER_RL`** / warehouse **`PNC_WH`**.
- Production tables are never altered: each scored object is cloned to
  `DTS_CLONE__<db>__<schema>__<obj>` (zero-copy clone for tables, CTAS snapshot for
  PUBL views) and metrics run on the **clones**.

### Framework (weights sum to 100)
DQ 22 · Observability 12 · Ownership 12 · Classification 12 · Auth Source 10 ·
Lineage 10 · Business Definitions 9 · Active Issues 5 · Usage 5 · User Feedback 3.
- **DQ + Observability** are DMF-measured; multiplied by a per-layer **DQ confidence
  factor**: INT/Bronze 0.90, DW/Silver 0.75, PUBL/Gold 0.60.
- **CDE** columns (identifier keys) get a **2× multiplier** in the DQ rollup.
- **Measurable ceiling** (sum of weights measurable today) + **foundational-gap flag**
  (Ownership/Classification/Auth Source unseeded or zero) are surfaced.
- `app/config.py` is the **single source of truth** (namespace, dims/weights, bands,
  confidence factors, scored-object map); DDL seeds mirror it and the app imports it.

---

## 2. Scored objects (5 rows in `DTS_DATASET_REGISTRY`)

| Family | Layer | Source object | Notes |
|---|---|---|---|
| POSITION_REPORT | INT | `EDLE_INT_DB.PNC_WORKDAY01.STG_POSITION_REPORT` | clean underscore cols |
| POSITION_REPORT | DW | `EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT` | **core target** |
| POSITION_REPORT | PUBL | `EDLE_PUBL_DB.PNC_ANALYTICS.STG_POSITION_REPORT_VW` | spaced col names |
| TRENDED_REPORT | DW | `EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT` | **core target** |
| TRENDED_REPORT | PUBL | `EDLE_PUBL_DB.PNC_ANALYTICS.STG_TRENDED_REPORT_VW` | spaced col names |

- **TRENDED INT is intentionally excluded**: `EDLE_INT_DB.PNC_WORKDAY01.STG_TRENDED_REPORT`
  is TRUNCATE+COPY and **empty at rest** (verified 2026-07-20: 0 rows vs DW 1,798,608).
  Scoring it would give a false "0 rows / stale / 100% null" picture; DW is the
  source-of-record for the TRENDED family.
- Keys: POSITION = (POSITION_ID, REPORT_EFFECTIVE_DATE, REPORT_ENTRY_DATE);
  TRENDED = (BUSINESS_PROCESS_WID, EFFECTIVEDATE, EMPLOYEEID, RECORDTYPE).
  Freshness anchor: `LOADDATE` (INT/DW). **PUBL views rename these** — see §5.

---

## 3. Dual-track DMF design (handles the missing account grant)

Both tracks write to ONE table `DTS_DMF_MEASUREMENTS`; the bridge view + scoring
engine read only that table, so nothing references `SNOWFLAKE.LOCAL` directly.

- **Track B (DEFAULT, no grant):** `SP_DTS_COMPUTE_DQ_MEASUREMENTS()` computes
  ROW_COUNT / FRESHNESS / NULL_COUNT(keys) / DUPLICATE_COUNT in plain SQL over the
  clones. Uses only `PNC_DATA_RWC` privileges the role already has.
- **Track A (needs grants):** `SP_DTS_SYNC_NATIVE_DMF_RESULTS()` copies native DMF
  readings from `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS`. Requires
  `EXECUTE DATA METRIC FUNCTION ON ACCOUNT` + `SNOWFLAKE.DATA_METRIC_USER` (which
  `PNC_DEVELOPER_RL` does **not** have as of 2026-07) and `ddl/20`+`21` attach steps.

---

## 4. Files & correct deploy order

DDL lives in `ddl/`; app in `app/`. **Numeric file order now equals dependency order.**

```
00_setup.sql              session context (PNC_DEVELOPER_RL / PNC_WH / EDLE_DW_DB.PNC_DATA)
01_dts_registries.sql     registry tables (dataset, element+CDE, glossary, ownership, source, lineage, classification)
02_dts_config.sql         DTS_DIMENSION_WEIGHTS (=100), DTS_TRUST_BANDS (5), DTS_DQ_CONFIDENCE_FACTOR
03_dts_measured.sql       DTS_DQ_RULE_RESULT, DTS_OBSERVABILITY_INCIDENT, DTS_USAGE_METRICS, DTS_USER_FEEDBACK
04_dts_scores.sql         DTS_ELEMENT_DIMENSION_SCORE, DTS_DATASET_TRUST_SCORE
20_dts_clone_and_dmf.sql  SP_DTS_CLONE_SCORED_OBJECTS + SP_DTS_ATTACH_BASELINE_DMFS (Track A)
21_dts_key_dmfs.sql       SP_DTS_ATTACH_KEY_DMFS (Track A only)
25_dts_dmf_measurements.sql  DTS_DMF_MEASUREMENTS + Track A/B populators   (MUST precede 26)
26_dts_bridge_views.sql   DTS_VW_DMF_LATEST_MEASUREMENTS + DTS_VW_DMF_DIMENSION_SCORES (was 22; reads 25's table)
30_dts_scoring_engine.sql SP_DTS_COMPUTE_SCORES + DTS_VW_DATASET_TRUST_SCORE_LATEST
40_dts_seed_metadata.sql  seeds the 5 objects, elements/CDE, glossary, ownership/source/classification, lineage, IDQ, usage/feedback
50_create_streamlit_apps.sql  stage + two STREAMLIT objects
```

### Snowsight deploy notebook
- `DTS_v2_Deploy.ipynb` (repo root) — Snowflake Workspace notebook that runs the whole
  Track B deploy in order (native SQL cells, one per ddl file + the CALLs + results).
  Set role `PNC_DEVELOPER_RL` / warehouse `PNC_WH`, then Run All.
- `build_deploy_notebook.py` — regenerates the notebook from `ddl/*.sql`; re-run after DDL edits.


**Deploy (Track B):** run files 00→04, then 40 (seed), then 20, 25, 26, 30
(21 optional — Track A only). Then:
```sql
CALL SP_DTS_CLONE_SCORED_OBJECTS();      -- fills CLONE_FQN + CLONE_EXISTS
CALL SP_DTS_COMPUTE_DQ_MEASUREMENTS();   -- Track B, no grant
CALL SP_DTS_COMPUTE_SCORES();
SELECT * FROM DTS_VW_DATASET_TRUST_SCORE_LATEST ORDER BY TRUST_SCORE DESC;
```
App: `ddl/50` (create stage → upload `app/*.py` + `app/.streamlit/config.toml` → create STREAMLITs).

### App layer
- `app/config.py` — single source of truth.
- `app/shared.py` — Snowflake-first `DTS_` loaders + UI helpers.
- `app/trust_score_app.py` — Portfolio Scorecard, Dataset Detail, Lineage DQ, Methodology.
- `app/ai_use_cases_app.py` — orthogonal Workforce/TA analytics (needs `VW_WORKFORCE_*` views, not built; renders enablement messages).
- Two SiS apps created by `ddl/50`: `DTS_PNC_DATA_TRUST_SCORE`, `DTS_PNC_HR_AI_USE_CASES`.

---

## 5. Fixes applied this session (2026-07-20)

1. **Deploy-order bug fixed:** `22_dts_bridge_views.sql` created a view over
   `DTS_DMF_MEASUREMENTS` (made in `25`) but sorted before it → `CREATE VIEW` would
   fail. **Renamed 22 → `26_dts_bridge_views.sql`**; updated cross-refs in `ddl/03`,
   `ddl/25`, and README (run order + repo layout).
2. **Added `app/.streamlit/config.toml`** (dark theme) — referenced by `ddl/50` + README but missing.
3. **PUBL clones made measurable** (all 5 kept in scope by user choice). PUBL views
   expose spaced/renamed columns:
   - POSITION PUBL keys → `"Position ID"`, `"Report Effective Date"`, `"Report Entry Date"`
   - TRENDED PUBL keys → `"Business Process WID"`, `"Effective Date"`, `"Employee ID"`, `"Record Type"`
   - PUBL freshness anchor → `"Load Date date and timestamp"`
   Fixes: (a) double-quoted all dynamically-built column identifiers in `ddl/25`
   (Track B), `ddl/20` (FRESHNESS), `ddl/21` (NULL/DUPLICATE); (b) seeded PUBL registry
   `KEY_COLUMNS`/`FRESHNESS_COLUMN` + `DTS_DATA_ELEMENT` column names with the real
   spaced names in `ddl/40`, mirrored in `config.py` (`PUBL_FRESHNESS_ANCHOR`).
   DW/INT keep uppercase underscore names (quoting is safe for those too).
4. Moved this project's plan file into `data-trust-score-prototype/.snowflake/cortex/plans/`.
5. **Deploy-time fixes folded back from the working notebook (2026-07-21)** — verified by
   regenerating `DTS_v2_Deploy.ipynb` and diffing to the working export (0 differences):
   - `row` is a reserved word in Snowflake Scripting -> renamed cursor-loop var `row`->`rec` in the
     4 looping procedures (`ddl/20` clone + baseline, `ddl/21` key DMFs, `ddl/25` Track B).
   - Clone SP `UPDATE` uses `rec.FIELD` with NO `:` bind prefix (`:rec.` errored) — `ddl/20`.
   - `ARRAY_CONSTRUCT` is not allowed in a `VALUES` clause -> `DTS_DATASET_REGISTRY` seed rewritten
     to `SELECT ... UNION ALL` — `ddl/40`.
   - `SHOW STREAMLITS` has no `main_file` column -> dropped from the verify SELECT — `ddl/50`.
   - `$$` procedures run from Python cells (`session.sql(...).collect()`) in the notebook.

---

## 6. Verified (read-only)

- `PNC_DEVELOPER_RL` holds `EDLE_DW_DB.PNC_DATA_RWC` and owns PNC_DATA tables (can create
  DTS_ objects + clones); its DMF grants appear **absent** → Track B is the path.
- All key/freshness columns exist in both DW tables; PUBL view spaced column names captured.
- TRENDED INT staging is empty at rest (0 rows) — confirms its exclusion.
- Column contracts consistent: `ddl/26` views ↔ `ddl/30` scoring engine ↔ `config.py` ↔ Streamlit app.

---

## 7. Current state & open items

- **Nothing deployed yet** in `EDLE_DW_DB.PNC_DATA` (no `DTS_` objects). Code reviewed
  + fixed but **not executed** — per user preference this session.
- Migration is **uncommitted** in the working tree (branch `snowflake_cortex_code`).
  Deletions of the old v1 files + new v2 files are staged as working-tree changes.
- `docs/UNIFIED_TRUST_SCORE_MODEL.md` is a **conceptual reference** with illustrative
  file names; not the deploy guide (README is). Left as-is.
- **Optional:** add TRENDED INT to scope only if you want to *catch* empty-at-rest loads
  as a volume/freshness signal (one-line add in `ddl/40` registry + `DTS_DATA_ELEMENT`).

---

## 8. Working preferences (this collaborator)

- **Move straight to action**; minimize confirmation round-trips.
- **Review/fix code only** — do NOT execute DDL/DML against Snowflake (read-only
  SELECT / INFORMATION_SCHEMA lookups are fine); the user deploys themselves.
- **Skip DMF grants** for now → Track B is the default measurement path.
- Keep all 5 clones (did not want to trim to just the 2 DW tables).
- Note: CoCo working dir this session was `edl-procurement-repo`; the code lives in
  `data-trust-score-prototype`. Open that folder as the workspace to root the session here.
