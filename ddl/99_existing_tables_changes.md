# Changes to existing tables

> **POC scope note:** The DDLs in this folder deploy to a *standalone* POC
> database (`ASATTAR_TRUST_SCORE_POC.DQ_POC`). They do **not** touch `EDLE_DW_DB.PNC_DATA`
> or `EDLE_PUBL_DB.PNC_DATA`. The table below describes what would (or
> would not) be required if/when this graduates from POC to production.

**TL;DR — almost none.** The Reuse Assessment is explicit: the Trust Score is
*"primarily a curation, aggregation, and surface product — not a net-new
data build."* All ten dimensions can be sourced without re-piping the
underlying datasets, **as long as** the four net-new registries in this
prototype are populated.

## Existing assets evaluated

| Asset | DDL location | Recommendation |
|---|---|---|
| `EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT`        | `edl-pnc-repo/main/DDL/EDLE_DW_DB/DT_POSITION_REPORT.sql` | **No schema change.** |
| `EDLE_PUBL_DB.PNC_DATA.STG_POSITION_REPORT_VW`  | `edl-pnc-repo/main/DDL/EDLE_PUBL_DB/STG_POSITION_REPORT_VW.sql` | No change. |
| `EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT`         | `edl-pnc-repo/main/DDL/EDLE_DW_DB/DT_TRENDED_REPORT.sql` | No change. |
| `EDLE_PUBL_DB.PNC_DATA.STG_TRENDED_REPORT_VW`   | `edl-pnc-repo/main/DDL/EDLE_PUBL_DB/STG_TRENDED_REPORT_VW.sql` | No change. |
| `TRAN_DT_WRKPLCTRNS_CONSOLIDATED`               | (workplace transition pipeline) | No change. |
| `DT_BEELINE_CONSO`, `STG_BEELINE_WBD_WORKER`    | FPA domain | **Pending FPA data-owner approval** before we can read it (per doc). No DDL change needed on our side. |
| `PNC_ACTIVITY_DETAIL_LOG`                       | `edl-pnc-repo/main/SQL/FRAMEWORK/DML/PNC_ACTIVITY_DETAIL_LOG.sql` | No change. We will **read** it to derive `DIM_ISSUES_*` and `DIM_PROFILING_*` columns. |

## Why no schema change is required

| Trust Score dimension | Sourced from | Modification to existing table? |
|---|---|---|
| 1. Data Ownership                | `PNC_DATA_OWNERSHIP_REGISTRY` (net-new) | None |
| 2. Data Source                   | `PNC_SOURCE_CLASSIFICATION` (net-new)   | None |
| 3. Active Issues                 | `PNC_ACTIVITY_DETAIL_LOG` + JIRA register | None — we already log per-batch failures |
| 4. Timeliness                    | `MAX(LOAD_DATE)` on existing tables vs `PNC_SOURCE_CLASSIFICATION.SLA_HOURS` | None — `LOAD_DATE` already stamped |
| 5. Completeness of Key Properties | Profiling job over existing tables, joined to `PNC_KEY_PROPERTY_REGISTRY` | None |
| 6. Data Profiling                | `PNC_ACTIVITY_DETAIL_LOG` + planned `PNC_DQ_RESULTS` | None |
| 7. Data Definitions              | `PNC_KEY_PROPERTY_REGISTRY.HAS_APPROVED_DEFINITION` | None |
| 8. Key Properties                | `PNC_KEY_PROPERTY_REGISTRY` (net-new) | None |
| 9. Usage                         | Snowflake `ACCOUNT_USAGE.QUERY_HISTORY` filtered to PNC FQNs | None |
| 10. User Feedback                | `PNC_USER_FEEDBACK` (net-new)           | None |

## Optional, low-risk additions to *pipelines* (not schemas)

If we want to make scoring cheaper to compute on the warehouse, we can add
these as **separate** DAG steps without changing the existing tables:

1. A nightly job that calls profiling on `TWID`, `POSITION_ID`, and
   `EmployeeID` per dataset and upserts `PNC_KEY_PROPERTY_REGISTRY`.
2. A nightly job that aggregates `PNC_ACTIVITY_DETAIL_LOG` rows from the
   last 24h into `PNC_DQ_RESULTS` columns.
3. A weekly job that scrapes `ACCOUNT_USAGE.QUERY_HISTORY` and aggregates
   into `PNC_USAGE_TELEMETRY` (Phase 2).

## What WOULD trigger a schema change later (Phase 2)

- If we want the Trust Score to surface **field-level** scores (not just
  dataset-level), we'd add a long companion table
  `PNC_DQ_FIELD_RESULTS(dataset_id, field_name, score_run_date, score)`.
  Out of scope for MVP per the doc.
- If Informatica DQ is adopted, its results become an additional input to
  `DIM_PROFILING_*` — still no change to existing pipeline tables.
