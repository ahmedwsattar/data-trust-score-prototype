-------------------------------------------------------------------------------
-- ddl/45_dts_jira_incidents.sql
-- v2 Data Trust Score -- Jira -> Active Issues dimension.
--
-- The scoring engine (ddl/30) already derives the Active Issues dimension from
-- open rows in DTS_OBSERVABILITY_INCIDENT:
--     ACTIVE_ISSUES = 100 - 10*openP1 - 3*openP2 - 1*openP3   (per family x layer)
-- This file supplies the missing loader (SP_DTS_LOAD_JIRA_ISSUES) plus a sample
-- payload so the dimension is exercised end-to-end before the Atlassian MCP is
-- connected.
--
-- Mapping (matches the agreed design):
--   REPORT_FAMILY  <- the issue's "dataset:<FAMILY>" label (project EDA, board 16274)
--   SEVERITY       <- Jira priority: Highest/High -> P1, Medium -> P2, else P3
--   STATUS         <- statusCategory.key: 'done' -> RESOLVED, else OPEN
--   LAYER          <- expanded to every in-scope layer of the family (issues carry no layer)
--   INCIDENT_TYPE  <- 'JIRA' (so a reload cleanly replaces the prior Jira set)
--
-- Once the MCP is authorized, replace the sample PARSE_JSON payload at the bottom
-- with the array returned by the Jira search tool -- no other change needed.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. Loader: map a Jira issues array (REST/MCP shape) into DTS_OBSERVABILITY_INCIDENT.
--    Re-runnable: clears prior INCIDENT_TYPE='JIRA' rows first.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DTS_LOAD_JIRA_ISSUES(ISSUES VARIANT)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    loaded INTEGER DEFAULT 0;
BEGIN
    DELETE FROM DTS_OBSERVABILITY_INCIDENT WHERE INCIDENT_TYPE = 'JIRA';

    INSERT INTO DTS_OBSERVABILITY_INCIDENT
        (REPORT_FAMILY, LAYER, INCIDENT_TYPE, SEVERITY, STATUS, DETAIL, DETECTED_AT)
    WITH iss AS (
        SELECT f.value AS j
        FROM   LATERAL FLATTEN(input => :ISSUES) f
    )
    , lab AS (
        SELECT
            i.j:key::STRING                                        AS issue_key,
            i.j:fields.summary::STRING                             AS summary,
            i.j:fields.priority.name::STRING                       AS priority,
            COALESCE(i.j:fields.status.statusCategory.key::STRING, 'new') AS status_cat,
            REPLACE(l.value::STRING, 'dataset:', '')               AS report_family
        FROM iss i,
             LATERAL FLATTEN(input => i.j:fields.labels) l
        WHERE l.value::STRING ILIKE 'dataset:%'
    )
    SELECT
        reg.REPORT_FAMILY,
        reg.LAYER,
        'JIRA',
        CASE WHEN lab.priority IN ('Highest','High') THEN 'P1'
             WHEN lab.priority = 'Medium'            THEN 'P2'
             ELSE 'P3' END,
        IFF(lab.status_cat = 'done', 'RESOLVED', 'OPEN'),
        lab.issue_key || ' - ' || COALESCE(lab.summary, ''),
        CURRENT_TIMESTAMP()
    FROM lab
    JOIN DTS_DATASET_REGISTRY reg
      ON reg.REPORT_FAMILY = lab.report_family
     AND reg.IS_IN_SCOPE = TRUE;

    loaded := SQLROWCOUNT;
    RETURN OBJECT_CONSTRUCT('incident_type', 'JIRA', 'rows_loaded', :loaded);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_LOAD_JIRA_ISSUES(VARIANT) IS
    'Map a Jira issues array (REST/MCP shape) into DTS_OBSERVABILITY_INCIDENT; dataset:<FAMILY> label -> REPORT_FAMILY, priority -> P1/P2/P3, expanded to all in-scope layers. Feeds the Active Issues dimension.';

-------------------------------------------------------------------------------
-- 2. SAMPLE payload (remove once the MCP returns real EDA issues).
--    JQL to use with the Atlassian MCP once authorized:
--      project = EDA AND statusCategory != Done
--      AND labels IN ("dataset:POSITION_REPORT","dataset:TRENDED_REPORT")
-------------------------------------------------------------------------------
CALL SP_DTS_LOAD_JIRA_ISSUES(PARSE_JSON('[
  {"key":"EDA-1012","fields":{"summary":"Headcount mismatch vs Workday source","priority":{"name":"High"},   "status":{"statusCategory":{"key":"indeterminate"}},"labels":["dataset:POSITION_REPORT"]}},
  {"key":"EDA-1031","fields":{"summary":"Null POSITION_ID in latest load",     "priority":{"name":"Highest"},"status":{"statusCategory":{"key":"new"}},          "labels":["dataset:POSITION_REPORT"]}},
  {"key":"EDA-1044","fields":{"summary":"Report label typo",                   "priority":{"name":"Low"},    "status":{"statusCategory":{"key":"new"}},          "labels":["dataset:POSITION_REPORT"]}},
  {"key":"EDA-1050","fields":{"summary":"Trended snapshot 2 days late",         "priority":{"name":"Medium"}, "status":{"statusCategory":{"key":"indeterminate"}},"labels":["dataset:TRENDED_REPORT"]}},
  {"key":"EDA-1077","fields":{"summary":"Duplicate Business Process WID",       "priority":{"name":"High"},   "status":{"statusCategory":{"key":"new"}},          "labels":["dataset:TRENDED_REPORT"]}}
]'));

-------------------------------------------------------------------------------
-- 3. Recompute scores so the Active Issues dimension reflects the incidents,
--    then inspect.
-------------------------------------------------------------------------------
CALL SP_DTS_COMPUTE_SCORES();

SELECT REPORT_FAMILY, LAYER, SEVERITY, STATUS, DETAIL
FROM   DTS_OBSERVABILITY_INCIDENT
WHERE  INCIDENT_TYPE = 'JIRA' AND STATUS = 'OPEN'
ORDER BY REPORT_FAMILY, LAYER, SEVERITY;
