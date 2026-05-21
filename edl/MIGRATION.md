# Migrating Data Trust Score into edl-pnc-repo

Step-by-step import from this prototype workspace into [edl-pnc-repo](https://github.com/wcet-enterprise-tech/edl-pnc-repo) on branch `dev`.

**Not carried forward:** POC `ddl/*` (except as reference), `data/`, `synthetic/`, `ddl/91_seed*.sql`, manual-DMF path unless native DMF privileges fail.

---

## Prerequisites

1. Run `edl/ddl/00_privilege_self_check.sql` in EDLE-DEV; resolve FAIL rows via DBA template below.
2. JIRA ticket assigned (placeholder `<JIRA_TICKET>`).
3. Local git credentials for both remotes.

---

## Step 1 — Clone target repo

```bash
cd ~/Documents/GitHub
git clone https://github.com/wcet-enterprise-tech/edl-pnc-repo.git
cd edl-pnc-repo
git checkout dev
git pull origin dev
```

---

## Step 2 — Create feature branch

```bash
git checkout -b feature/<JIRA_TICKET>-data-trust-score
```

---

## Step 3 — Copy artifacts (file-by-file)

From `data-trust-score-prototype/edl/` → `edl-pnc-repo/main/`:

| Prototype path | Target path |
|----------------|-------------|
| `edl/ddl/skeleton/EDLE_DW_DB/PNC_DATA_TRUST/*.sql` | `main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/` |
| `edl/ddl/skeleton/EDLE_DW_DB/PNC_DATA/DMF_*.sql` | `main/DDL/EDLE_DW_DB/PNC_DATA/` |
| `edl/ddl/00_privilege_self_check.sql` | `main/SQL/UTIL/privilege_self_check_data_trust.sql` |
| `app/trust_score_app.py` | `main/Python/streamlit/trust_score_app.py` |
| `app/ai_use_cases_app.py` | `main/Python/streamlit/ai_use_cases_app.py` |
| `app/shared.py` | `main/Python/streamlit/shared.py` |
| `app/.streamlit/config.toml` | `main/Python/streamlit/.streamlit/config.toml` |
| `edl/PLAN.md` | `main/Config/docs/DATA_TRUST_SCORE_PLAN.md` (optional) |

**Python edits before commit** (in `shared.py`):

- Replace `ASATTAR_TRUST_SCORE_POC.DQ_POC` with `EDLE_DW_DB.PNC_DATA_TRUST`.
- Bind dashboard to `VW_PNC_TRUST_SCORE_DASHBOARD` (or keep table names if views are synonyms).
- Workforce loaders: query `TECH_DW_DB.TECH_AIML.SV_POSITION_TRENDED` instead of POC views.

---

## Step 4 — Deploy order (Snowflake)

Run in EDLE-DEV after PR merge to `dev` (or manually for validation):

1. `SCHEMA_PNC_DATA_TRUST.sql`
2. All `PNC_*.sql` tables
3. `VW_PNC_DMF_*.sql`, `VW_PNC_TRUST_SCORE_DASHBOARD.sql`
4. `SP_REFRESH_DATASET_CATALOG.sql` → `CALL SP_REFRESH_DATASET_CATALOG();`
5. Steward seed / registry loads (`main/DATA/` if added)
6. `DMF_DT_*.sql` (requires ownership + `DATA_METRIC_USER`)
7. PUT Streamlit files → `STREAMLIT_STAGE_AND_APPS.sql`

---

## Step 5 — Commit and PR

```bash
git add main/DDL/EDLE_DW_DB/PNC_DATA_TRUST main/DDL/EDLE_DW_DB/PNC_DATA/DMF_*.sql \
        main/SQL/UTIL/privilege_self_check_data_trust.sql \
        main/Python/streamlit
git status
git commit -m "$(cat <<'EOF'
<JIRA_TICKET>: Add Data Trust Score governance schema and Streamlit apps.

Introduces PNC_DATA_TRUST schema, DMF wiring on DT_* tables, and SiS apps
for portfolio trust scoring and workforce analytics.
EOF
)"
git push -u origin feature/<JIRA_TICKET>-data-trust-score
```

Create PR to `dev`:

```bash
gh pr create --base dev --title "<JIRA_TICKET>: Data Trust Score governance and Streamlit" --body "$(cat <<'EOF'
## Summary
- Adds `EDLE_DW_DB.PNC_DATA_TRUST` governance schema (catalog, registries, score tables, DMF bridge views).
- Attaches native DMFs to `DT_TRENDED_REPORT` and `DT_POSITION_REPORT`.
- Deploys Trust Score + P&C HR Analytics Streamlit apps.

## Test plan
- [ ] Run `privilege_self_check_data_trust.sql` Sections A–C; no unexpected FAIL on CREATE/DMF/Cortex.
- [ ] Jenkins `jenkinsfile_SF` dev deploy green.
- [ ] `CALL SP_REFRESH_DATASET_CATALOG()` returns DT_* rows.
- [ ] `SELECT * FROM VW_PNC_TRUST_SCORE_DASHBOARD LIMIT 5` after seed/rebuild.
- [ ] Open both Streamlit apps in Snowsight; Portfolio + Cortex DQ pages render.
- [ ] Confirm DMF results appear in `VW_PNC_DMF_LATEST_MEASUREMENTS` within one schedule cycle.

EOF
)"
```

---

## Step 6 — Jenkins

**[USER]:** Paste current `main/jenkinsfile_SF`. Expected additions:

- Include `main/DDL/EDLE_DW_DB/PNC_DATA_TRUST/` in SQL deploy loop.
- Stage `main/Python/streamlit/**` → `@EDLE_DW_DB.PNC_DATA_TRUST.STREAMLIT_APP_STAGE`.
- Run `STREAMLIT_STAGE_AND_APPS.sql` after PUT.

Until confirmed, treat Streamlit deploy as **manual Snowsight PUT** in EDLE-DEV.

---

## DBA grant-request template

Parametric block — send to DBA with FAIL lines from privilege self-check:

```sql
-- ============================================================================
-- Data Trust Score — grant request (EDLE-DEV)
-- Requestor: <YOUR_NAME>   JIRA: <JIRA_TICKET>   Date: <DATE>
-- ============================================================================
-- Replace <ROLE> with PNC_DEVELOPER_RL and/or PNC_AIML_DEVELOPER_RL per row.

-- Native DMF (both roles if AIML executes measurements)
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE <ROLE>;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE <ROLE>;

-- Cortex (Trust Score COMPLETE / Agent)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <ROLE>;

-- Governance schema (after CREATE SCHEMA by developer)
GRANT USAGE ON DATABASE EDLE_DW_DB TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT USAGE ON SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT SELECT ON ALL TABLES IN SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT SELECT ON FUTURE TABLES IN SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT SELECT ON ALL VIEWS IN SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA EDLE_DW_DB.PNC_DATA_TRUST TO ROLE PNC_AIML_DEVELOPER_RL;

-- Streamlit consumers
GRANT USAGE ON STREAMLIT EDLE_DW_DB.PNC_DATA_TRUST.PNC_DATA_TRUST_SCORE TO ROLE <END_USER_ROLE>;
GRANT USAGE ON STREAMLIT EDLE_DW_DB.PNC_DATA_TRUST.PNC_PC_HR_ANALYTICS TO ROLE <END_USER_ROLE>;

-- Optional: scheduled scoring
GRANT EXECUTE TASK ON ACCOUNT TO ROLE PNC_DEVELOPER_RL;

-- Optional: developer warehouse if missing
GRANT USAGE ON WAREHOUSE PNC_AIML_WH TO ROLE PNC_DEVELOPER_RL;
GRANT USAGE ON WAREHOUSE PNC_AIML_WH_UOM TO ROLE PNC_AIML_DEVELOPER_RL;
```

---

## Rollback

- Drop Streamlit objects and stage under `PNC_DATA_TRUST`.
- `DROP SCHEMA EDLE_DW_DB.PNC_DATA_TRUST;` (after backup if populated).
- Remove DMF associations: `ALTER TABLE … DROP DATA METRIC FUNCTION …` per table (see Snowflake docs).

---

## Cortex Code handoff

After running privilege checks in Snowsight, paste failures into Cortex Code:

> Rewrite the failing cell in `privilege_self_check_data_trust.sql` to use SHOW GRANTS + RESULT_SCAN only — no ACCOUNT_USAGE, no bare DECLARE at worksheet top level. Object: `PNC_DEVELOPER_RL`, check: `<CHECK_NAME>`.

Integrate any Cortex Code rewrites back into `edl/ddl/00_privilege_self_check.sql` in this prototype repo before copying to edl-pnc-repo.
