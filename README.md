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
