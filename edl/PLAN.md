# Data Trust Score — EDL Migration Plan

**Status:** Draft for EDLE-DEV (`PNC_DEVELOPER_RL` + `PNC_AIML_DEVELOPER_RL`)  
**Target repo:** [wcet-enterprise-tech/edl-pnc-repo](https://github.com/wcet-enterprise-tech/edl-pnc-repo) (`dev` → `qa` → `prod`)

---

## 1. Architecture recommendation — **Plan B**

| Plan | Layout | Verdict |
|------|--------|---------|
| A | New `PNC_DATA_TRUST_DB` | **Reject** — new DB needs elevated DBA approval; no evidence `PNC_DEVELOPER_RL` has `CREATE DATABASE`. |
| **B** | **`EDLE_DW_DB.PNC_DATA_TRUST`** schema | **Recommended** — role already has `CREATE SCHEMA` on `EDLE_DW_DB`, `_RWC` on `PNC_DATA`, owns `DT_*` tables and pipeline objects. |
| C | Prefixed tables in `PNC_DATA` | **Reject** — pollutes operational schema; harder RBAC for AIML read-only consumers. |

### End-to-end object layout

```
EDLE_DW_DB
├── PNC_DATA                          ← existing scored sources (OWNED by PNC_DEVELOPER_RL)
│   ├── DT_TRENDED_REPORT             ← native DMFs attached here
│   ├── DT_POSITION_REPORT
│   └── …
└── PNC_DATA_TRUST                    ← NEW governance schema (Plan B)
    ├── PNC_DATASET_CATALOG           ← auto-discovery + steward curation
    ├── PNC_DATA_OWNERSHIP_REGISTRY
    ├── PNC_SOURCE_CLASSIFICATION
    ├── PNC_KEY_PROPERTY_REGISTRY
    ├── PNC_TRUST_SCORE_WEIGHTS
    ├── PNC_DQ_RESULTS                ← wide scorecard (nightly rebuild)
    ├── PNC_DQ_DIMENSION_RESULTS      ← narrow trend history
    ├── VW_PNC_DMF_LATEST_MEASUREMENTS
    ├── VW_PNC_DMF_DIMENSION_SCORES
    ├── VW_PNC_TRUST_SCORE_DASHBOARD  ← Streamlit primary bind
    ├── SP_REFRESH_DATASET_CATALOG
    ├── STREAMLIT_APP_STAGE
    ├── PNC_DATA_TRUST_SCORE          ← Streamlit object (trust_score_app.py)
    └── PNC_PC_HR_ANALYTICS           ← Streamlit object (ai_use_cases_app.py)

TECH_DW_DB.TECH_AIML                  ← existing AIML (read via PNC_AIML_DEVELOPER_RL)
    ├── WORKFORCE_ANALYTICS_AGENT
    └── SV_POSITION_TRENDED

SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS  ← native DMF output (read-only)
```

**Data flow**

1. `SP_REFRESH_DATASET_CATALOG` discovers `EDLE_DW_DB.PNC_DATA.DT_%` tables.
2. Stewards maintain registries (ownership, source tier, key properties).
3. `PNC_DEVELOPER_RL` attaches DMFs on owned `DT_*` tables; Snowflake schedules measurement.
4. `PNC_AIML_DEVELOPER_RL` (+ `DATA_METRIC_USER`) executes DMFs; results land in `SNOWFLAKE.LOCAL.*`.
5. Bridge views in `PNC_DATA_TRUST` normalize DMF output for UI.
6. Nightly task (Phase 2) merges registries + DMF views → `PNC_DQ_RESULTS` / `PNC_DQ_DIMENSION_RESULTS`.
7. Streamlit apps read `VW_PNC_TRUST_SCORE_DASHBOARD` + DMF views; Workforce page queries Semantic View / Agent.

---

## 2. Role split

| Object / action | Create / own | Run / read | Notes |
|-----------------|-------------|------------|-------|
| Schema `PNC_DATA_TRUST` | `PNC_DEVELOPER_RL` | both roles `USAGE` | Developer grants AIML `SELECT` on tables/views. |
| Governance tables | `PNC_DEVELOPER_RL` | Dev: R/W; AIML: `SELECT` | Registry edits via steward SQL or future UI. |
| Bridge views | `PNC_DEVELOPER_RL` | both `SELECT` | Insulates Streamlit from `SNOWFLAKE.LOCAL` shape. |
| `SP_REFRESH_DATASET_CATALOG` | `PNC_DEVELOPER_RL` | Dev deploy; AIML may `CALL` if granted | Task owner = Developer. |
| `ALTER TABLE … ADD DMF` on `DT_*` | `PNC_DEVELOPER_RL` | — | Requires **OWNERSHIP** on target table. |
| DMF scheduled execution | — | `PNC_AIML_DEVELOPER_RL` + `DATA_METRIC_USER` | AIML has `_R` on source DBs, not ownership. |
| Read `DATA_QUALITY_MONITORING_RESULTS` | — | both (if granted) | Privilege check Cell A7/B7. |
| Streamlit stage + apps | `PNC_DEVELOPER_RL` | End users via `USAGE` grant | `QUERY_WAREHOUSE`: Trust=`PNC_AIML_WH`, HR=`PNC_AIML_WH_UOM`. |
| `WORKFORCE_ANALYTICS_AGENT` | AIML team (existing) | `PNC_AIML_DEVELOPER_RL` | Trust app: optional NL Q&A sidebar (Phase 2). |
| `SV_POSITION_TRENDED` | AIML team (existing) | `PNC_AIML_DEVELOPER_RL` | Powers Workforce Shifts page via semantic SQL. |
| Nightly score rebuild task | `PNC_DEVELOPER_RL` | `PNC_DEVELOPER_RL` | Needs `EXECUTE TASK` (check A9). |

---

## 3. AIML integration

| Artifact | Trust Score app | AI Use Cases app |
|----------|-----------------|------------------|
| `WORKFORCE_ANALYTICS_AGENT` | Phase 2: governed NL Q&A on portfolio metrics (Cortex Agent API in Streamlit) | Primary for natural-language workforce questions |
| `SV_POSITION_TRENDED` | Optional join for usage/lineage context | **Workforce Shifts** page — replace POC `VW_WORKFORCE_*` with semantic view SQL |
| Native DMFs on `DT_*` | **Cortex DQ** page via `VW_PNC_DMF_*` | Anomaly context only (UC #1 observability) |

**MVP split**

- **Now:** DMF bridge + dashboard views + SiS deploy under `PNC_DATA_TRUST`.
- **Next:** Wire `shared.py` Snowflake loaders to `EDLE_DW_DB.PNC_DATA_TRUST` and `SV_POSITION_TRENDED`.
- **Later:** Embedded Cortex Agent UI in Trust Score (requires product sign-off).

---

## 4. Repo mapping (prototype → edl-pnc-repo)

Convention observed in POC docs (could not fetch live `dev` tree — network blocked):  
`main/DDL/<DATABASE>/<OBJECT>.sql`, `main/SQL/...`, `main/Python/...`.

| Source (this repo) | Target (`edl-pnc-repo`) | Notes |
|--------------------|-------------------------|-------|
| `edl/ddl/skeleton/EDLE_DW_DB/PNC_DATA_TRUST/*.sql` | `main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/` | Deploy in dependency order (schema → tables → views → SP → Streamlit). |
| `edl/ddl/skeleton/EDLE_DW_DB/PNC_DATA/DMF_*.sql` | `main/DDL/EDLE_DW_DB/PNC_DATA/` | After base table DDL exists in repo. |
| `edl/ddl/00_privilege_self_check.sql` | `main/SQL/UTIL/privilege_self_check_data_trust.sql` | Pre-flight only; not Jenkins-deployed to prod. |
| `app/trust_score_app.py` | `main/Python/streamlit/trust_score_app.py` | Set `SNOWFLAKE_SCHEMA=PNC_DATA_TRUST` or equivalent in shared loader. |
| `app/ai_use_cases_app.py` | `main/Python/streamlit/ai_use_cases_app.py` | Point workforce loaders at `SV_POSITION_TRENDED`. |
| `app/shared.py` | `main/Python/streamlit/shared.py` | Replace POC DB `ASATTAR_TRUST_SCORE_POC.DQ_POC` with `EDLE_DW_DB.PNC_DATA_TRUST`. |
| `app/.streamlit/config.toml` | `main/Python/streamlit/.streamlit/config.toml` | Stage subfolder on PUT. |
| POC `ddl/00_setup.sql` … `10_*.sql` | — | **Not carried forward** (superseded by `edl/ddl/skeleton`). |
| POC `ddl/25_manual_dmf_fallback.sql` | — | Fallback only if native DMF privileges fail. |
| POC `ddl/91_seed*.sql`, `data/`, `synthetic/` | — | **Not carried forward** — use steward loads / real EDL data. |
| `docs/PORTFOLIO_AND_DETAIL_PAGES.md` | `main/Config/docs/` or wiki | Reference for QA acceptance. |
| `docs/REAL_DATA_OPPORTUNITIES.md` | same | Phase 2 backlog. |
| Future `main/SQL/.../SP_REBUILD_TRUST_SCORE.sql` | `main/SQL/PNC_DATA_TRUST/DML/` | Not drafted yet — nightly merge job. |
| Future steward seed CSVs | `main/DATA/PNC_DATA_TRUST/` | Optional `COPY INTO` templates. |

---

## 5. CI/CD flow

| Item | Value |
|------|-------|
| Branch | `feature/<JIRA_TICKET>-data-trust-score` from `dev` |
| PR title | `<JIRA_TICKET>: Data Trust Score governance schema and Streamlit apps` (JIRA token **required** — Jenkins fails without it) |
| Reviewers | 1× `@wcet-enterprise-tech/edl_developers` on `dev` |
| Promotion | `dev` → `qa` → `prod` (prod merges **only** from `qa`, GitHub Actions enforced) |
| Jenkins | `jenkinsfile_SF` deploys DDL + SQL; Streamlit needs PUT + `CREATE STREAMLIT` steps — **[USER]: paste current `main/jenkinsfile_SF`** so we align stage paths. |

**Suggested deploy order in Jenkins**

1. `main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/SCHEMA_*.sql`
2. Tables → views → procedures
3. `main/DDL/EDLE_DW_DB/PNC_DATA/DMF_*.sql` (idempotent `ALTER TABLE ADD` may need guard procedures)
4. PUT Python → stage → `STREAMLIT_*.sql`

---

## 6. Pre-flight

Run `edl/ddl/00_privilege_self_check.sql` in Snowsight (Sections A → B → C). Share Cell C output before first `dev` deploy.

---

## 7. Open questions

- **[USER]** JIRA ticket ID for branch/PR title (placeholder: `<JIRA_TICKET>`).
- **[USER]** Confirm governance schema name: `EDLE_DW_DB.PNC_DATA_TRUST` vs alternative.
- **[USER]** Integrate `WORKFORCE_ANALYTICS_AGENT` in Trust Score Streamlit for MVP, or Phase 2 only?
- **[USER]** DMFs on production `DT_*` directly vs secure views in `PNC_DATA_TRUST` (if ownership blocks `ALTER`)?
- **[USER]** Is embedded Cortex Agent UI required for sign-off, or Snowsight Agents app is enough?
- **[USER]** Warehouse for `PNC_DEVELOPER_RL` Streamlit: `PNC_AIML_WH` vs corporate default WH?
- **[USER]** Paste `main/jenkinsfile_SF`, one sample `main/DDL/EDLE_DW_DB/*.sql`, and `.github/CODEOWNERS` — clone/API unreachable from build environment.
- **[USER]** Confirm `LOAD_DATE` / key column names on `DT_TRENDED_REPORT` and `DT_POSITION_REPORT` for DMF DDL.
- **[USER]** Steward source for registry initial load (CSV path, ServiceNow export, manual Snowflake worksheet)?
- **[USER]** FPA datasets (`DT_BEELINE_CONSO`) — include in catalog now or wait for data-owner approval?
