# Snowsight notebooks (export-only)

Cortex Code in Snowsight produces **export-only** artifacts — they are not the deploy source of truth.

| Keep in git | When |
|-------------|------|
| `.sql` export | Privilege checks, one-off DBA worksheets, DDL experiments worth preserving (`edl/ddl/00_privilege_self_check.sql` is the canonical example). |
| `.ipynb` | Multi-cell investigations with charts or narrative you want versioned. |

**Do not** duplicate every Notebook cell in git if the same logic already lives under `edl/ddl/skeleton/` or `main/DDL/` in edl-pnc-repo.

Workflow: develop in Snowsight → export → drop under `edl/notebooks/` → promote validated SQL into `edl/ddl/skeleton/` before the Jenkins path.
