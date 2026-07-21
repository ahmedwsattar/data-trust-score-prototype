-------------------------------------------------------------------------------
-- ddl/20_dts_clone_and_dmf.sql
-- v2 Data Trust Score -- clone machinery + baseline DMF attachment.
--
-- Adapted from edl-pnc-repo PNC_DATA_TRUST/40_CLONE_SOURCE_SCHEMAS.sql +
-- 50_SP_ATTACH_BASELINE_DMFS.sql, but WITHOUT creating new schemas. Because
-- PNC_DEVELOPER_RL cannot CREATE SCHEMA on the shared EDLE databases, we clone
-- each scored object as an individual DTS_CLONE__<db>__<schema>__<obj> object
-- INSIDE EDLE_DW_DB.PNC_DATA:
--   - TABLES  -> zero-copy CREATE TABLE ... CLONE (cross-db clone is allowed)
--   - VIEWS   -> CTAS snapshot (views cannot be zero-copy cloned)
--
-- Production objects are never altered; DMFs attach only to the clones.
--
-- Prereqs (ACCOUNTADMIN, one-time):
--   GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT  TO ROLE PNC_DEVELOPER_RL;
--   GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE PNC_DEVELOPER_RL;
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. SP_DTS_CLONE_SCORED_OBJECTS
--    Iterates DTS_DATASET_REGISTRY (IS_IN_SCOPE), clones each object into
--    PNC_DATA, and sets CLONE_FQN + CLONE_EXISTS. Re-runnable (CREATE OR REPLACE
--    per clone re-snapshots current source state).
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DTS_CLONE_SCORED_OBJECTS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    cloned_count INTEGER DEFAULT 0;
    failed_count INTEGER DEFAULT 0;
    failures     ARRAY   DEFAULT ARRAY_CONSTRUCT();
    src_fqn      STRING;
    clone_nm     STRING;
    clone_fqn    STRING;
    is_view      BOOLEAN;
    sql_stmt     STRING;
    c CURSOR FOR
        SELECT REPORT_FAMILY, LAYER, DATABASE_NAME, SCHEMA_NAME, OBJECT_NAME,
               DATASET_FQN, IS_VIEW
        FROM   DTS_DATASET_REGISTRY
        WHERE  IS_IN_SCOPE = TRUE
        ORDER BY REPORT_FAMILY, LAYER;
BEGIN
    FOR rec IN c DO
        src_fqn  := rec.DATASET_FQN;
        is_view  := rec.IS_VIEW;
        clone_nm := 'DTS_CLONE__' || rec.DATABASE_NAME || '__'
                                   || rec.SCHEMA_NAME  || '__'
                                   || rec.OBJECT_NAME;
        clone_fqn := 'EDLE_DW_DB.PNC_DATA.' || clone_nm;

        BEGIN
            IF (is_view) THEN
                -- Views can't be zero-copy cloned: snapshot via CTAS.
                sql_stmt := 'CREATE OR REPLACE TABLE ' || clone_fqn
                         || ' AS SELECT * FROM ' || src_fqn;
            ELSE
                -- Tables: fast metadata-only zero-copy clone.
                sql_stmt := 'CREATE OR REPLACE TABLE ' || clone_fqn
                         || ' CLONE ' || src_fqn;
            END IF;
            EXECUTE IMMEDIATE :sql_stmt;

            UPDATE DTS_DATASET_REGISTRY
               SET CLONE_FQN = :clone_fqn, CLONE_EXISTS = TRUE
             WHERE REPORT_FAMILY = rec.REPORT_FAMILY
               AND LAYER = rec.LAYER;

            cloned_count := cloned_count + 1;
        EXCEPTION
            WHEN OTHER THEN
                failed_count := failed_count + 1;
                failures := ARRAY_APPEND(failures,
                    OBJECT_CONSTRUCT('src', :src_fqn, 'clone', :clone_fqn,
                                     'sqlerr', SQLERRM));
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT('cloned', :cloned_count,
                            'failed', :failed_count,
                            'failures', :failures);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_CLONE_SCORED_OBJECTS() IS
    'Clone every in-scope object in DTS_DATASET_REGISTRY into PNC_DATA (CTAS for views); sets CLONE_FQN + CLONE_EXISTS.';

-------------------------------------------------------------------------------
-- 2. SP_DTS_ATTACH_BASELINE_DMFS
--    Attaches SNOWFLAKE.CORE.ROW_COUNT + FRESHNESS(anchor) to every clone.
--    Uses FRESHNESS_COLUMN from the registry when set, else the ranked picker
--    (LOADDATE #1) mirrored from edl-pnc-repo's SP_ATTACH_BASELINE_DMFS.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DTS_ATTACH_BASELINE_DMFS(
    SCHEDULE_MINUTES INTEGER DEFAULT 1440
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    attached_count INTEGER DEFAULT 0;
    failed_count   INTEGER DEFAULT 0;
    failures       ARRAY   DEFAULT ARRAY_CONSTRUCT();
    clone_fqn      STRING;
    clone_nm       STRING;
    date_col       STRING;
    sql_stmt       STRING;
    c CURSOR FOR
        SELECT CLONE_FQN, OBJECT_NAME, DATABASE_NAME, SCHEMA_NAME, FRESHNESS_COLUMN
        FROM   DTS_DATASET_REGISTRY
        WHERE  IS_IN_SCOPE = TRUE AND CLONE_EXISTS = TRUE
        ORDER BY REPORT_FAMILY, LAYER;
BEGIN
    FOR rec IN c DO
        clone_fqn := rec.CLONE_FQN;
        clone_nm  := SPLIT_PART(rec.CLONE_FQN, '.', 3);
        date_col  := rec.FRESHNESS_COLUMN;

        BEGIN
            -- Schedule must be set before the first ADD DATA METRIC FUNCTION.
            sql_stmt := 'ALTER TABLE ' || clone_fqn
                     || ' SET DATA_METRIC_SCHEDULE = ''' || :SCHEDULE_MINUTES || ' MINUTE''';
            EXECUTE IMMEDIATE :sql_stmt;

            -- Table-level ROW_COUNT (guards against truncate/empty loads).
            sql_stmt := 'ALTER TABLE ' || clone_fqn
                     || ' ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ()';
            EXECUTE IMMEDIATE :sql_stmt;

            -- Freshness anchor: registry column if present, else ranked picker
            -- against the clone's own INFORMATION_SCHEMA (clone lives in PNC_DATA).
            IF (date_col IS NULL) THEN
                EXECUTE IMMEDIATE
                    'SELECT COLUMN_NAME FROM EDLE_DW_DB.INFORMATION_SCHEMA.COLUMNS '
                    || 'WHERE TABLE_SCHEMA = ''PNC_DATA'' AND TABLE_NAME = ''' || clone_nm || ''' '
                    || 'AND DATA_TYPE IN (''DATE'',''TIMESTAMP_NTZ'',''TIMESTAMP_LTZ'',''TIMESTAMP_TZ'') '
                    || 'ORDER BY CASE '
                    || '  WHEN COLUMN_NAME ILIKE ''LOADDATE''     THEN 1 '
                    || '  WHEN COLUMN_NAME ILIKE ''LOAD\\_DATE''  THEN 1 '
                    || '  WHEN COLUMN_NAME ILIKE ''LOAD\\_TS''    THEN 1 '
                    || '  WHEN COLUMN_NAME ILIKE ''LAST\\_LOADED%'' THEN 2 '
                    || '  WHEN COLUMN_NAME ILIKE ''INGEST%''      THEN 2 '
                    || '  WHEN COLUMN_NAME ILIKE ''UPDATED\\_AT'' THEN 3 '
                    || '  WHEN COLUMN_NAME ILIKE ''CREATED\\_AT'' THEN 4 '
                    || '  WHEN COLUMN_NAME ILIKE ''REPORT\\_RUN\\_DATE'' THEN 5 '
                    || '  WHEN COLUMN_NAME ILIKE ''EFFECTIVEDATE'' THEN 6 '
                    || '  ELSE 99 END, ORDINAL_POSITION LIMIT 1';
                SELECT $1 INTO :date_col FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
            END IF;

            IF (date_col IS NOT NULL) THEN
                sql_stmt := 'ALTER TABLE ' || clone_fqn
                         || ' ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON ("'
                         || date_col || '")';
                EXECUTE IMMEDIATE :sql_stmt;
            END IF;

            attached_count := attached_count + 1;
        EXCEPTION
            WHEN OTHER THEN
                failed_count := failed_count + 1;
                failures := ARRAY_APPEND(failures,
                    OBJECT_CONSTRUCT('clone', :clone_fqn, 'sqlerr', SQLERRM));
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT('attached', :attached_count,
                            'failed', :failed_count,
                            'schedule_minutes', :SCHEDULE_MINUTES,
                            'failures', :failures);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_ATTACH_BASELINE_DMFS(INTEGER) IS
    'Attach ROW_COUNT + FRESHNESS to every DTS_CLONE__* in DTS_DATASET_REGISTRY (CLONE_EXISTS=TRUE).';

-------------------------------------------------------------------------------
-- 3. Run order (after registry is seeded in ddl/40):
--      CALL SP_DTS_CLONE_SCORED_OBJECTS();
--      CALL SP_DTS_ATTACH_BASELINE_DMFS();       -- daily schedule (1440)
--    Then attach the key-column DMFs in ddl/21.
-------------------------------------------------------------------------------
