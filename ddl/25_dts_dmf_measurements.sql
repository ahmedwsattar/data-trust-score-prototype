-------------------------------------------------------------------------------
-- ddl/25_dts_dmf_measurements.sql
-- v2 Data Trust Score -- unified DMF measurement store + two populators.
--
-- WHY: PNC_DEVELOPER_RL does not (yet) have EXECUTE DATA METRIC FUNCTION on the
-- account, so native DMFs can't attach. To stay switchable, both tracks write
-- to ONE normalized table (DTS_DMF_MEASUREMENTS) and the bridge view in ddl/26
-- reads only that table -- so nothing references SNOWFLAKE.LOCAL directly and
-- there is no privilege error in manual mode.
--
--   Track B (default, no grant needed):  SP_DTS_COMPUTE_DQ_MEASUREMENTS()
--       computes ROW_COUNT / FRESHNESS / NULL_COUNT(keys) / DUPLICATE_COUNT in
--       plain SQL over the DTS_CLONE__* tables (which PNC_DEVELOPER_RL owns).
--
--   Track A (once granted):              SP_DTS_SYNC_NATIVE_DMF_RESULTS()
--       copies the latest native DMF readings from
--       SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS into the same table.
--       Requires the ddl/20 + 21 ALTER ... ADD DATA METRIC FUNCTION to have run
--       (needs EXECUTE DATA METRIC FUNCTION + SNOWFLAKE.DATA_METRIC_USER).
--
-- Switch tracks by choosing which populator you schedule; the bridge view and
-- scoring engine don't change. Metric names mirror SNOWFLAKE.CORE.* so the
-- bridge logic is identical for both tracks.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

-------------------------------------------------------------------------------
-- 1. Unified measurement store (both tracks INSERT here).
-------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DTS_DMF_MEASUREMENTS (
    CLONE_FQN         VARCHAR       NOT NULL,
    REPORT_FAMILY     VARCHAR       NOT NULL,
    LAYER             VARCHAR       NOT NULL,
    METRIC_NAME       VARCHAR       NOT NULL,   -- SNOWFLAKE.CORE.ROW_COUNT etc.
    COLUMN_NAME       VARCHAR,                   -- NULL for table-grain metrics
    VALUE             FLOAT,
    MEASUREMENT_TIME  TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    SOURCE_TRACK      VARCHAR       NOT NULL     -- MANUAL | NATIVE
);
COMMENT ON TABLE DTS_DMF_MEASUREMENTS IS
    'Unified DMF measurement store. Track B (SP_DTS_COMPUTE_DQ_MEASUREMENTS) or Track A (SP_DTS_SYNC_NATIVE_DMF_RESULTS) populate it; the bridge view reads only this table.';

-------------------------------------------------------------------------------
-- 2. TRACK B -- manual SQL computation over the clones (no account grant).
--    Metric names mirror the native DMFs so ddl/26 treats both identically.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DTS_COMPUTE_DQ_MEASUREMENTS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    rows_written INTEGER DEFAULT 0;
    failed_count INTEGER DEFAULT 0;
    failures     ARRAY   DEFAULT ARRAY_CONSTRUCT();
    clone_fqn    STRING;
    fam          STRING;
    lyr          STRING;
    fcol         STRING;
    key_cols     ARRAY;
    n_keys       INTEGER;
    i            INTEGER;
    one_col      STRING;
    tuple_cols   STRING;
    tuple_cols_q STRING;
    sql_stmt     STRING;
    c CURSOR FOR
        SELECT CLONE_FQN, REPORT_FAMILY, LAYER, FRESHNESS_COLUMN, KEY_COLUMNS
        FROM   DTS_DATASET_REGISTRY
        WHERE  IS_IN_SCOPE = TRUE AND CLONE_EXISTS = TRUE
        ORDER BY REPORT_FAMILY, LAYER;
BEGIN
    -- Fresh snapshot for this run: clear prior MANUAL rows.
    DELETE FROM DTS_DMF_MEASUREMENTS WHERE SOURCE_TRACK = 'MANUAL';

    FOR rec IN c DO
        clone_fqn := rec.CLONE_FQN;
        fam := rec.REPORT_FAMILY; lyr := rec.LAYER;
        fcol := rec.FRESHNESS_COLUMN; key_cols := rec.KEY_COLUMNS;

        BEGIN
            -- ROW_COUNT (table-grain)
            sql_stmt := 'INSERT INTO DTS_DMF_MEASUREMENTS '
                || '(CLONE_FQN,REPORT_FAMILY,LAYER,METRIC_NAME,COLUMN_NAME,VALUE,SOURCE_TRACK) '
                || 'SELECT ''' || clone_fqn || ''',''' || fam || ''',''' || lyr || ''','
                || '''SNOWFLAKE.CORE.ROW_COUNT'',NULL,(SELECT COUNT(*) FROM ' || clone_fqn || '),''MANUAL''';
            EXECUTE IMMEDIATE :sql_stmt;
            rows_written := rows_written + 1;

            -- NULL_COUNT per key column (completeness)
            n_keys := ARRAY_SIZE(key_cols);
            i := 0;
            WHILE (i < n_keys) DO
                one_col := GET(key_cols, i)::STRING;
                sql_stmt := 'INSERT INTO DTS_DMF_MEASUREMENTS '
                    || '(CLONE_FQN,REPORT_FAMILY,LAYER,METRIC_NAME,COLUMN_NAME,VALUE,SOURCE_TRACK) '
                    || 'SELECT ''' || clone_fqn || ''',''' || fam || ''',''' || lyr || ''','
                    || '''SNOWFLAKE.CORE.NULL_COUNT'',''' || one_col || ''','
                    || '(SELECT COUNT(*) FROM ' || clone_fqn || ' WHERE "' || one_col || '" IS NULL),''MANUAL''';
                EXECUTE IMMEDIATE :sql_stmt;
                rows_written := rows_written + 1;
                i := i + 1;
            END WHILE;

            -- DUPLICATE_COUNT on the composite key (uniqueness): extra rows beyond
            -- the first in each key group. Guarded: skip when there are no keys
            -- (empty GROUP BY would be a syntax error).
            IF (n_keys > 0) THEN
                tuple_cols   := ARRAY_TO_STRING(key_cols, ', ');
                tuple_cols_q := '"' || ARRAY_TO_STRING(key_cols, '", "') || '"';
                sql_stmt := 'INSERT INTO DTS_DMF_MEASUREMENTS '
                    || '(CLONE_FQN,REPORT_FAMILY,LAYER,METRIC_NAME,COLUMN_NAME,VALUE,SOURCE_TRACK) '
                    || 'SELECT ''' || clone_fqn || ''',''' || fam || ''',''' || lyr || ''','
                    || '''SNOWFLAKE.CORE.DUPLICATE_COUNT'',''' || tuple_cols || ''','
                    || 'COALESCE((SELECT SUM(c-1) FROM (SELECT COUNT(*) c FROM ' || clone_fqn
                    || ' GROUP BY ' || tuple_cols_q || ' HAVING COUNT(*) > 1)),0),''MANUAL''';
                EXECUTE IMMEDIATE :sql_stmt;
                rows_written := rows_written + 1;
            END IF;

        EXCEPTION
            WHEN OTHER THEN
                failed_count := failed_count + 1;
                failures := ARRAY_APPEND(failures,
                    OBJECT_CONSTRUCT('clone', :clone_fqn, 'stage', 'core_metrics', 'sqlerr', SQLERRM));
        END;

        -- FRESHNESS (seconds since latest anchor) -- isolated so a missing anchor
        -- column (e.g. a PUBL view without LOADDATE) doesn't drop the core metrics.
        IF (fcol IS NOT NULL) THEN
            BEGIN
                sql_stmt := 'INSERT INTO DTS_DMF_MEASUREMENTS '
                    || '(CLONE_FQN,REPORT_FAMILY,LAYER,METRIC_NAME,COLUMN_NAME,VALUE,SOURCE_TRACK) '
                    || 'SELECT ''' || clone_fqn || ''',''' || fam || ''',''' || lyr || ''','
                    || '''SNOWFLAKE.CORE.FRESHNESS'',''' || fcol || ''','
                    || 'DATEDIFF(''second'', MAX("' || fcol || '"), CURRENT_TIMESTAMP()),''MANUAL'' FROM ' || clone_fqn
                    || ' HAVING MAX("' || fcol || '") IS NOT NULL';
                EXECUTE IMMEDIATE :sql_stmt;
                rows_written := rows_written + 1;
            EXCEPTION
                WHEN OTHER THEN
                    failed_count := failed_count + 1;
                    failures := ARRAY_APPEND(failures,
                        OBJECT_CONSTRUCT('clone', :clone_fqn, 'stage', 'freshness',
                                         'col', :fcol, 'sqlerr', SQLERRM));
            END;
        END IF;
    END FOR;

    RETURN OBJECT_CONSTRUCT('track','MANUAL','rows_written',:rows_written,
                            'failed',:failed_count,'failures',:failures);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_COMPUTE_DQ_MEASUREMENTS() IS
    'Track B: compute ROW_COUNT/FRESHNESS/NULL_COUNT(keys)/DUPLICATE_COUNT in plain SQL over the clones; write MANUAL rows to DTS_DMF_MEASUREMENTS. No account grant needed.';

-------------------------------------------------------------------------------
-- 3. TRACK A -- sync native DMF results (run only once the grants exist and
--    ddl/20 + 21 have attached DMFs to the clones).
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DTS_SYNC_NATIVE_DMF_RESULTS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    rows_written INTEGER DEFAULT 0;
BEGIN
    DELETE FROM DTS_DMF_MEASUREMENTS WHERE SOURCE_TRACK = 'NATIVE';

    INSERT INTO DTS_DMF_MEASUREMENTS
        (CLONE_FQN, REPORT_FAMILY, LAYER, METRIC_NAME, COLUMN_NAME, VALUE, MEASUREMENT_TIME, SOURCE_TRACK)
    SELECT
        r.CLONE_FQN, d.REPORT_FAMILY, d.LAYER,
        UPPER(r.METRIC_DATABASE || '.' || r.METRIC_SCHEMA || '.' || r.METRIC_NAME),
        ARRAY_TO_STRING(r.ARGUMENT_NAMES, ','),
        r.VALUE, r.MEASUREMENT_TIME, 'NATIVE'
    FROM (
        SELECT TABLE_DATABASE || '.' || TABLE_SCHEMA || '.' || TABLE_NAME AS CLONE_FQN,
               METRIC_DATABASE, METRIC_SCHEMA, METRIC_NAME, ARGUMENT_NAMES, VALUE, MEASUREMENT_TIME,
               ROW_NUMBER() OVER (
                 PARTITION BY TABLE_DATABASE, TABLE_SCHEMA, TABLE_NAME, METRIC_NAME,
                              ARRAY_TO_STRING(ARGUMENT_NAMES, ',')
                 ORDER BY MEASUREMENT_TIME DESC) AS rn
        FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
    ) r
    JOIN DTS_DATASET_REGISTRY d ON d.CLONE_FQN = r.CLONE_FQN
    WHERE r.rn = 1 AND d.IS_IN_SCOPE = TRUE;

    rows_written := SQLROWCOUNT;
    RETURN OBJECT_CONSTRUCT('track','NATIVE','rows_written',:rows_written);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_SYNC_NATIVE_DMF_RESULTS() IS
    'Track A: copy latest native DMF readings from SNOWFLAKE.LOCAL into DTS_DMF_MEASUREMENTS. Needs EXECUTE DATA METRIC FUNCTION + SNOWFLAKE.DATA_METRIC_USER and ddl/20+21 attached.';

-------------------------------------------------------------------------------
-- Usage:
--   Track B (today):  CALL SP_DTS_COMPUTE_DQ_MEASUREMENTS();
--   Track A (granted): CALL SP_DTS_SYNC_NATIVE_DMF_RESULTS();
-- then:               CALL SP_DTS_COMPUTE_SCORES();
-------------------------------------------------------------------------------
