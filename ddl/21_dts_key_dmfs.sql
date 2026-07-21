-------------------------------------------------------------------------------
-- ddl/21_dts_key_dmfs.sql
-- v2 Data Trust Score -- key-column DMFs (completeness + uniqueness).
--
-- On top of the ROW_COUNT + FRESHNESS baseline (ddl/20), this attaches the
-- DAMA-relevant column DMFs to each clone, driven by KEY_COLUMNS in
-- DTS_DATASET_REGISTRY:
--   - SNOWFLAKE.CORE.NULL_COUNT      ON (<each key column>)      -> Completeness
--   - SNOWFLAKE.CORE.DUPLICATE_COUNT ON (<composite key tuple>)  -> Uniqueness
--
-- ADD DATA METRIC FUNCTION is idempotent-unsafe (throws on duplicate), so the
-- per-DMF ADD is wrapped in its own block and duplicate errors are tolerated.
-------------------------------------------------------------------------------

USE ROLE      PNC_DEVELOPER_RL;
USE WAREHOUSE PNC_WH;
USE SCHEMA    EDLE_DW_DB.PNC_DATA;

CREATE OR REPLACE PROCEDURE SP_DTS_ATTACH_KEY_DMFS()
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
    key_cols       ARRAY;
    n_keys         INTEGER;
    i              INTEGER;
    one_col        STRING;
    tuple_cols     STRING;
    sql_stmt       STRING;
    c CURSOR FOR
        SELECT CLONE_FQN, KEY_COLUMNS
        FROM   DTS_DATASET_REGISTRY
        WHERE  IS_IN_SCOPE = TRUE AND CLONE_EXISTS = TRUE
          AND  KEY_COLUMNS IS NOT NULL
        ORDER BY REPORT_FAMILY, LAYER;
BEGIN
    FOR rec IN c DO
        clone_fqn := rec.CLONE_FQN;
        key_cols  := rec.KEY_COLUMNS;
        n_keys    := ARRAY_SIZE(key_cols);

        -- NULL_COUNT per individual key column (completeness).
        i := 0;
        WHILE (i < n_keys) DO
            one_col := GET(key_cols, i)::STRING;
            BEGIN
                sql_stmt := 'ALTER TABLE ' || clone_fqn
                         || ' ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON ("'
                         || one_col || '")';
                EXECUTE IMMEDIATE :sql_stmt;
                attached_count := attached_count + 1;
            EXCEPTION
                WHEN OTHER THEN
                    failed_count := failed_count + 1;
                    failures := ARRAY_APPEND(failures,
                        OBJECT_CONSTRUCT('clone', :clone_fqn, 'dmf', 'NULL_COUNT('||:one_col||')',
                                         'sqlerr', SQLERRM));
            END;
            i := i + 1;
        END WHILE;

        -- DUPLICATE_COUNT on the composite key tuple (uniqueness). Columns are
        -- double-quoted so spaced PUBL-view names (e.g. "Position ID") resolve.
        tuple_cols := '"' || ARRAY_TO_STRING(key_cols, '", "') || '"';
        BEGIN
            sql_stmt := 'ALTER TABLE ' || clone_fqn
                     || ' ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT ON ('
                     || tuple_cols || ')';
            EXECUTE IMMEDIATE :sql_stmt;
            attached_count := attached_count + 1;
        EXCEPTION
            WHEN OTHER THEN
                failed_count := failed_count + 1;
                failures := ARRAY_APPEND(failures,
                    OBJECT_CONSTRUCT('clone', :clone_fqn, 'dmf', 'DUPLICATE_COUNT('||:tuple_cols||')',
                                     'sqlerr', SQLERRM));
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT('attached', :attached_count,
                            'failed', :failed_count,
                            'failures', :failures);
END;
$$;
COMMENT ON PROCEDURE SP_DTS_ATTACH_KEY_DMFS() IS
    'Attach NULL_COUNT (per key col) + DUPLICATE_COUNT (composite key) to each clone, from DTS_DATASET_REGISTRY.KEY_COLUMNS.';

-- Run after SP_DTS_ATTACH_BASELINE_DMFS():
--   CALL SP_DTS_ATTACH_KEY_DMFS();
