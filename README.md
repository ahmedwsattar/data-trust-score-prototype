# Data Trust Score — Streamlit Prototype

Prototype for the P&C **Data Trust Score** scorecard described in
`02_Discovery_Reuse_Assessment_Data_Trust_Score.docx` (May 2026,
EDAI Data Strategy & Governance — Phase 1 / Discovery / Artifact 2 of 3).

This is a **read-only visualization prototype** built on synthetic data so
we can socialize the scorecard structure with Ella / Paul / Perri before
the underlying tables are extended in Snowflake.

---

## What this prototype demonstrates

The doc's reuse decision is *Extend Existing — with targeted net-new additions*.
Six of ten dimensions are sourceable from existing assets; four are
governance/process gaps. This prototype shows what the **consumer-facing
surface** would look like once the planned `PNC_DQ_RESULTS` is extended,
plus the four net-new registries needed to fill the gaps.

The 10 Trust Score dimensions:

| # | Dimension                       | Source in prototype                        |
|---|---------------------------------|--------------------------------------------|
| 1 | Data Ownership                  | net-new `PNC_DATA_OWNERSHIP_REGISTRY`      |
| 2 | Data Source                     | net-new `PNC_SOURCE_CLASSIFICATION`        |
| 3 | Active Issues                   | extend `PNC_DQ_RESULTS` (8-cat framework)  |
| 4 | Timeliness                      | extend `PNC_DQ_RESULTS` (MAX(LOAD_DATE) vs SLA) |
| 5 | Completeness of Key Properties  | extend `PNC_DQ_RESULTS` (TWID/POS_ID null %) |
| 6 | Data Profiling                  | extend `PNC_DQ_RESULTS` (8-cat framework)  |
| 7 | Data Definitions                | net-new (catalog flag column on registry)  |
| 8 | Key Properties                  | net-new `PNC_KEY_PROPERTY_REGISTRY`        |
| 9 | Usage                           | net-new `PNC_USAGE_TELEMETRY` (Phase 2)    |
| 10| User Feedback                   | net-new `PNC_USER_FEEDBACK` (Phase 2)      |

---

## Repo layout

```
data-trust-score-prototype/
├── ddl/
│   ├── 00_setup.sql                       # USE ROLE / WH / DB / SCHEMA
│   ├── dba/
│   │   └── role_split_for_dba.sql         # post-deploy cleanup; needs DBA
│   ├── 01_pnc_dq_results_extended.sql     # extended scorecard fact + weights
│   ├── 02_pnc_dq_dimension_results.sql    # narrow companion fact (trends)
│   ├── 03_pnc_data_ownership_registry.sql
│   ├── 04_pnc_source_classification.sql
│   ├── 05_pnc_key_property_registry.sql
│   ├── 06_pnc_usage_telemetry.sql         # Phase 2
│   ├── 07_pnc_user_feedback.sql           # Phase 2
│   ├── 10_vw_pnc_data_trust_score.sql     # consumer-facing view
│   ├── 91_seed_data.sql                   # checklist for the seed/ files
│   ├── 91_seed_via_stage.sql              # alt: PUT + COPY INTO
│   ├── seed/                              # paste-into-worksheet INSERTs
│   │   ├── 91a_seed_pnc_trust_score_weights.sql
│   │   ├── 91b_seed_pnc_source_classification.sql
│   │   ├── 91c_seed_pnc_data_ownership_registry.sql
│   │   ├── 91d_seed_pnc_key_property_registry.sql
│   │   ├── 91e_seed_pnc_dq_results.sql
│   │   └── 91f_seed_pnc_dq_dimension_results.sql
│   └── 99_existing_tables_changes.md      # what (if anything) to ALTER
├── synthetic/
│   ├── generate_synthetic.py              # writes CSVs to ./data/
│   └── generate_snowflake_seed.py         # writes seed SQL to ./ddl/seed/
├── app/
│   └── streamlit_app.py
├── requirements.txt
└── README.md
```

---

## Running locally (Streamlit prototype)

```bash
cd data-trust-score-prototype
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 1. generate synthetic snapshot + 90-day history
python synthetic/generate_synthetic.py

# 2. launch dashboard
streamlit run app/streamlit_app.py
```

---

## Deploying to Snowflake (ASATTAR_TRUST_SCORE_POC.DQ_POC)

All DDLs target `ASATTAR_TRUST_SCORE_POC.DQ_POC` and use `CREATE OR REPLACE`,
so the deploy is safe to re-run.

### Role

The database is owned by `DATA_CLEAN_ROOM_ROLE`, so today the deploy runs
under that role. `00_setup.sql` pins it for you -- just edit the
warehouse name on line 14 if `COMPUTE_WH` is not what your account uses.

Eventually we want the POC isolated from the clean-room work, so a DBA
should run `ddl/dba/role_split_for_dba.sql` once they have a window. That
script creates a dedicated `TRUST_SCORE_POC_ROLE`, transfers ownership of
the database / schema / tables / views to it, and `COPY CURRENT GRANTS`
preserves any read access already granted to other roles. **Not required
for the POC to function** -- pure cleanup.

### Path A -- worksheet only (simplest)

In a Snowflake worksheet, run the following files in order. Each file is
self-contained -- just paste and execute.

```
ddl/00_setup.sql
ddl/01_pnc_dq_results_extended.sql
ddl/02_pnc_dq_dimension_results.sql
ddl/03_pnc_data_ownership_registry.sql
ddl/04_pnc_source_classification.sql
ddl/05_pnc_key_property_registry.sql
ddl/06_pnc_usage_telemetry.sql
ddl/07_pnc_user_feedback.sql
ddl/10_vw_pnc_data_trust_score.sql

ddl/seed/91a_seed_pnc_trust_score_weights.sql
ddl/seed/91b_seed_pnc_source_classification.sql
ddl/seed/91c_seed_pnc_data_ownership_registry.sql
ddl/seed/91d_seed_pnc_key_property_registry.sql
ddl/seed/91e_seed_pnc_dq_results.sql
ddl/seed/91f_seed_pnc_dq_dimension_results.sql
```

Then run a sanity query:

```sql
SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.VW_PNC_DATA_TRUST_SCORE
ORDER BY TRUST_SCORE_OVERALL DESC;
```

You should see 7 rows (one per dataset), with the Workday Position/Trended
Reports landing in **Silver** and the Workplace Transition / FPA Beeline
datasets in **Bronze** -- consistent with the May 2026 assessment findings.

### Path B -- SnowSQL with PUT + COPY INTO (faster for re-loads)

Use `ddl/91_seed_via_stage.sql` instead of the `seed/` files. It creates a
file format + named stage, then COPY INTOs each table from CSVs you upload
with `PUT`. The PUT commands are commented at the bottom of that file.

### Re-generating the seed scripts

If you tweak `synthetic/generate_synthetic.py` (e.g. add a dataset or change
quality knobs), regenerate the seed SQL with:

```bash
python synthetic/generate_synthetic.py        # rewrites ./data/*.csv
python synthetic/generate_snowflake_seed.py   # rewrites ./ddl/seed/91*.sql
```

---

## Key design decisions (reflecting the doc)

1. **`PNC_DQ_RESULTS` is the surface.** Per the doc (slide 10 / planned),
   the existing scorecard view is the closest candidate. We *extend* it
   from 3 dimensions to 10, rather than building a parallel table.
2. **One row per dataset per score-run-date.** Wide table for the
   scorecard surface, plus a narrow companion (`PNC_DQ_DIMENSION_RESULTS`)
   for trend charts and dimension-level audit.
3. **Existing pipeline tables are NOT modified.** All new signals are
   computed in views or net-new registries. See `ddl/99_existing_tables_changes.md`.
4. **Weights are explicit and tunable.** Defaults reflect the doc's
   guidance ("User Feedback can be deferred — lowest weight"). Stored in
   a small config table so governance can change them without code.
5. **Status thresholds are explicit.** Green ≥ 80, Amber 60–79, Red < 60
   per dimension. Overall tier: Gold ≥ 85, Silver 70–84, Bronze 50–69, At-Risk < 50.

---

## Appendix A — Cortex Data Quality (MVP measurement layer)

In May 2026 Snowflake shipped a Catalog UI for **Cortex Data Quality**: AI
suggests Data Metric Functions (DMFs) for a table, you accept them, Snowflake
schedules the runs, and results land in
`SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS`. For the MVP we use Cortex
DQ as the **measurement engine for the four trust-score dimensions it
natively covers**, with the prototype's bridge views translating raw DMF
output into per-dimension 0–100 scores:

| Trust Score dimension | Sourced from |
|---|---|
| #3 Active Issues | count of FAILED DMFs by severity (P1/P2/P3) |
| #4 Timeliness | `SNOWFLAKE.CORE.FRESHNESS(LOADDATE)` vs `SLA_HOURS` |
| #5 Completeness of Key Properties | `SNOWFLAKE.CORE.NULL_PERCENT` on key columns |
| #6 Data Profiling | % of all attached DMFs passing thresholds |

The other six dimensions (Ownership, Source, Definitions, Key Properties,
Usage, Feedback) remain registry-driven — Cortex DQ does not measure them.

### MVP target tables

The MVP instruments the two Workday tables that this product depends on,
mirrored into the POC schema from the production EDL DDL:

| | |
|---|---|
| Position FQN (POC) | `ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT` |
| Trended FQN (POC)  | `ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_TRENDED_REPORT` |
| Production EDL FQNs | `EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT` / `…DT_TRENDED_REPORT` |
| Working role | `DATA_CLEAN_ROOM_ROLE` (owns `ASATTAR_TRUST_SCORE_POC.DQ_POC`) |
| DMFs attached | 9 on Position, 6 on Trended (15 total) |
| Schedule | `USING CRON 0 7 * * * UTC` (~02:00 ET, post-overnight loads) |

The POC mirrors the EDL table shape exactly (same columns and types) but
strips the `WITH TAG (ADMIN_DB.ADMIN_SCH.WPII_*)` clauses from the
production DDL — `ADMIN_DB` requires admin-level access this account
doesn't have. Stripping them only disables the optional tag-based DMF demo
in Section F of file 20; everything else works the same. Apply the tags
later if/when the role gets USAGE on `ADMIN_DB.ADMIN_SCH`.

`DT_POSITION_REPORT` is registered as `DS_POSITION_REPORT` (weekly load,
SLA = 168h); `DT_TRENDED_REPORT` is `DS_TRENDED_REPORT` (monthly load,
SLA = 840h). Both have a real `LOADDATE TIMESTAMP_NTZ` column, so
`FRESHNESS(LOADDATE)` is a true freshness signal — no proxy column needed.

### Files

```
ddl/DT_POSITION_REPORT.sql               -- real table DDL (deploy first)
ddl/DT_TRENDED_REPORT.sql                -- real table DDL (deploy first)
ddl/ALTER_DT_TRENDED_REPORT.sql          -- additive columns for trended
ddl/30_copy_into_dt_tables.sql           -- file format + COPY INTO from internal stage
ddl/20_cortex_dq_setup.sql               -- TRACK A: attach 9 + 6 native DMFs
ddl/25_manual_dmf_fallback.sql           -- TRACK B: SP + manual measurements table
ddl/21_pnc_dmf_dataset_map.sql           -- physical->logical map + threshold config
ddl/22_vw_pnc_dmf_dimension_scores.sql   -- bridge views the Streamlit page reads
ddl/seed/22a_seed_pnc_dmf_dataset_map.sql
```

### One-time prerequisites (DBA / ACCOUNTADMIN)

The setup script has these commented at the top of `ddl/20_*.sql`:

```sql
USE ROLE ACCOUNTADMIN;

GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE DATA_CLEAN_ROOM_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE DATA_CLEAN_ROOM_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER      TO ROLE DATA_CLEAN_ROOM_ROLE;  -- optional
```

The optional `CORTEX_USER` and `CORTEX_MODELS_ALLOWLIST` (`mistral-7b`,
`llama3.1-8b`) are only needed for the Snowsight AI-suggestion UX. The
manual SQL DMF path the prototype uses works without them.

### MVP run order

There are two interchangeable paths for step 8 — pick one based on whether
the working role can be granted the account-level privileges that native
Cortex DQ requires. Everything before and after step 8 is identical.

```
 1. ddl/00_setup.sql                         -- session pin
 2. ddl/01..10..91*.sql                      -- prototype scaffolding (existing)
 3. ddl/DT_POSITION_REPORT.sql               -- create the POC mirror tables
 4. ddl/DT_TRENDED_REPORT.sql
 5. ddl/ALTER_DT_TRENDED_REPORT.sql
 6. <upload CSVs to @ASATTAR_TRUST_SCORE_POC.DQ_POC.STG_TRUST_SCORE_SEED/  via PUT or Snowsight UI>
 7. ddl/30_copy_into_dt_tables.sql           -- file format + COPY INTO
 8a. ddl/20_cortex_dq_setup.sql              -- TRACK A: native Cortex DQ
                                                (requires ACCOUNTADMIN to grant
                                                 EXECUTE DATA METRIC FUNCTION +
                                                 SNOWFLAKE.DATA_METRIC_USER)
 8b. ddl/25_manual_dmf_fallback.sql          -- TRACK B: manual SQL fallback
                                                (works with just schema OWNERSHIP
                                                 and SELECT on the source tables)
 9. ddl/21_pnc_dmf_dataset_map.sql
10. ddl/22_vw_pnc_dmf_dimension_scores.sql
11. ddl/seed/22a_seed_pnc_dmf_dataset_map.sql
```

**Track A (native Cortex DQ)** uses `SNOWFLAKE.CORE.*` data metric functions
attached to the tables, scheduled by Snowflake itself, with results landing
in `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS`. Cleaner long-term but
requires ACCOUNTADMIN to run the grants in Section A of file 20.

**Track B (manual SQL fallback)** computes the same 15 metrics in plain SQL
inside a stored procedure, writes them to `PNC_DQ_MEASUREMENTS_MANUAL`
(same column shape as the native results view), and lets the bridge view
in file 22 read from there instead. No ACCOUNTADMIN needed; the SP runs
with the caller's privileges. To refresh the dashboard:
`CALL ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS();`. If the
role also has `EXECUTE TASK`, Section D of file 25 provides an optional
TASK definition to run it on a CRON schedule.

The bridge view in file 22 is wired to the manual table by default. Comment
at the top of file 22 documents the one-line swap to point it back at
`SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS` if you switch to Track A
later.

File 30 uses `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` so CSV column order
doesn't have to match the table — Snowflake matches by header name.
Because that mode is incompatible with `VALIDATION_MODE`, the pre-flight
uses `INFER_SCHEMA` plus a header-diff query that lists any CSV columns
that wouldn't land anywhere (those would otherwise be silently dropped).
The COPY itself runs with `ON_ERROR = CONTINUE` so a few bad rows don't
abort the batch, and `TABLE(VALIDATE(..., JOB_ID => '_LAST'))` surfaces
any line-level rejections after the load.

Section B of file 20 spot-checks the schema and prints a quick null/dup
profile so you can sanity-check the seed thresholds against the actual
data.

### Triggering the first measurement

The first scheduled run lands at the next CRON tick (07:00 UTC). To get
instant measurements during a demo, Section E of `ddl/20_*.sql` calls each
DMF inline — those readings also land in
`SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS` immediately.

### Tag-based DMFs (optional — Section F of file 20)

Both EDL tables are heavily PII-tagged with `ADMIN_DB.ADMIN_SCH.WPII_*`.
`ALTER TAG … ADD DATA METRIC FUNCTION` attaches a DMF to **every column
carrying the tag** in the account, including new columns added later.
That means one statement can monitor every employee/manager identifier
(`WPII_ALPHANUM_ID`) or PII date (`WPII_DATE`) without per-column
ALTERs. Gated on the tag-management team granting `OWNERSHIP` or `APPLY`
on the tag — covered in Section F as an optional advanced path.

### Verifying in the dashboard

In Streamlit (SiS), open the **Cortex DQ** page. It shows:

- KPI strip (datasets wired, total readings, passing/failing, last
  measurement timestamp)
- Per-dataset derived scores for dimensions 3, 4, 5, 6
- Raw DMF measurements with PASS/FAIL highlighting
- Side-by-side comparison of DMF-derived vs current synthetic scores so
  governance can review before swapping the source-of-truth

Locally, the page renders the enablement instructions instead of live data.

### Fallback if the MVP role doesn't have OWNERSHIP

`ALTER TABLE … ADD DATA METRIC FUNCTION` requires OWNERSHIP. If your role
only has SELECT on `EDLE_DW_DB.PNC_DATA`, Section H of `ddl/20_*.sql`
points to the prior proxy-view pattern (preserved in git history) — wrap
the source in a view in a schema you own and attach DMFs to the view
instead. Update the rows in `PNC_DMF_DATASET_MAP` to point at the view's
FQN if you take this path.
