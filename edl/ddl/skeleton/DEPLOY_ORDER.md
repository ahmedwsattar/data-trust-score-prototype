# Skeleton deploy order

Mirror this sequence in Jenkins `jenkinsfile_SF` once confirmed.

1. `EDLE_DW_DB/PNC_DATA_TRUST/SCHEMA_PNC_DATA_TRUST.sql`
2. Tables: `PNC_DATASET_CATALOG` → registries → `PNC_TRUST_SCORE_WEIGHTS` → `PNC_DQ_*`
3. Views: `VW_PNC_DMF_LATEST_MEASUREMENTS` → `VW_PNC_DMF_DIMENSION_SCORES` → `VW_PNC_TRUST_SCORE_DASHBOARD`
4. `SP_REFRESH_DATASET_CATALOG.sql` + initial `CALL`
5. Steward data load (`main/DATA/` — TBD)
6. `EDLE_DW_DB/PNC_DATA/DMF_DT_*.sql`
7. PUT `main/Python/streamlit/*` → stage
8. `STREAMLIT_STAGE_AND_APPS.sql`
