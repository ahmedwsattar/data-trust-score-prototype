#!/usr/bin/env python3
"""Generate DTS_v2_Deploy.ipynb from the ddl/*.sql files.

Produces a Snowflake Workspace notebook (native SQL cells) that runs the v2
Data Trust Score deploy in the correct Track B (no-grant) order.

Cell-splitting rules (important for Snowflake Notebooks):
- A `$$`-quoted CREATE PROCEDURE must sit ALONE in its cell. If it shares a cell
  with other statements, the notebook's statement splitter breaks the body at its
  internal semicolons ("unexpected 'row'"). So we split each file into statements
  with a $$-aware splitter and isolate every $$ statement into its own cell.
- Consecutive non-$$ statements (CREATE TABLE, INSERT, COMMENT, SELECT) are grouped
  into one cell — those parse fine together.
- Redundant per-file `USE ROLE/WAREHOUSE/DATABASE/SCHEMA` lines are stripped from
  every file except the setup cell (session context persists across notebook cells).

Re-run after editing any ddl/*.sql so the notebook stays in sync:
    python build_deploy_notebook.py
"""
import json
import re
import uuid
import pathlib

BASE = pathlib.Path(__file__).resolve().parent
DDL = BASE / "ddl"

_USE_RE = re.compile(r"^\s*USE\s+(ROLE|WAREHOUSE|DATABASE|SCHEMA)\b", re.IGNORECASE)


def cid() -> str:
    return uuid.uuid4().hex[:8]


def md(text: str) -> dict:
    return {"cell_type": "markdown", "id": cid(), "metadata": {},
            "source": text.splitlines(keepends=True)}


def sql_cell(name: str, text: str) -> dict:
    return {"cell_type": "code", "id": cid(), "execution_count": None,
            "metadata": {"language": "sql", "name": name}, "outputs": [],
            "source": text.splitlines(keepends=True)}


def py_cell(name: str, code: str) -> dict:
    return {"cell_type": "code", "id": cid(), "execution_count": None,
            "metadata": {"language": "python", "name": name}, "outputs": [],
            "source": code.splitlines(keepends=True)}


def split_statements(text: str) -> list[str]:
    """Split SQL on top-level ';', respecting $$ bodies, '' strings, and -- comments."""
    stmts, buf = [], []
    i, n = 0, len(text)
    in_dollar = in_squote = in_line_comment = False
    while i < n:
        ch = text[i]
        two = text[i:i + 2]
        if in_line_comment:
            buf.append(ch)
            if ch == "\n":
                in_line_comment = False
            i += 1
        elif in_dollar:
            if two == "$$":
                buf.append("$$"); i += 2; in_dollar = False
            else:
                buf.append(ch); i += 1
        elif in_squote:
            if ch == "'" and text[i + 1:i + 2] == "'":
                buf.append("''"); i += 2
            elif ch == "'":
                buf.append(ch); i += 1; in_squote = False
            else:
                buf.append(ch); i += 1
        elif two == "--":
            in_line_comment = True; buf.append(two); i += 2
        elif two == "$$":
            in_dollar = True; buf.append("$$"); i += 2
        elif ch == "'":
            in_squote = True; buf.append(ch); i += 1
        elif ch == ";":
            buf.append(ch); _flush(stmts, buf); buf = []; i += 1
        else:
            buf.append(ch); i += 1
    _flush(stmts, buf)
    return stmts


def _flush(stmts: list[str], buf: list[str]) -> None:
    s = "".join(buf).strip()
    # Drop empty / comment-only fragments.
    if s and any(ln.strip() and not ln.strip().startswith("--") for ln in s.splitlines()):
        stmts.append(s)


def cells_for_file(fname: str, cell_base: str, keep_use: bool) -> list[dict]:
    """Return SQL cells for one ddl file: $$ statements isolated, others grouped."""
    stmts = split_statements((DDL / fname).read_text())
    if not keep_use:
        stmts = [s for s in stmts if not _USE_RE.match(s)]
    groups, cur = [], []
    for s in stmts:
        if "$$" in s:
            if cur:
                groups.append(cur); cur = []
            groups.append([s])
        else:
            cur.append(s)
    if cur:
        groups.append(cur)
    out = []
    for idx, g in enumerate(groups, 1):
        name = cell_base if len(groups) == 1 else f"{cell_base}_{idx}"
        if len(g) == 1 and "$$" in g[0]:
            # $$-quoted procedures must run via session.sql(): the notebook SQL-cell
            # splitter breaks $$ bodies at their internal semicolons. repr() encodes
            # the SQL safely regardless of embedded quotes/newlines.
            out.append(py_cell(name, "session.sql(" + repr(g[0]) + ").collect()"))
        else:
            out.append(sql_cell(name, "\n\n".join(g)))
    return out


# (file, cell-base, markdown header) in Track B deploy order.
STEPS = [
    ("00_setup.sql", "setup",
     "## 0 · Session context\n\n"
     "Pins role `PNC_DEVELOPER_RL`, warehouse `PNC_WH`, and schema "
     "`EDLE_DW_DB.PNC_DATA`. If you deploy with a different role/warehouse, edit "
     "the `USE` lines here — the rest of the notebook inherits this session context."),
    ("01_dts_registries.sql", "registries",
     "## 1 · Registry / metadata tables"),
    ("02_dts_config.sql", "config",
     "## 2 · Config tables (weights, bands, confidence factors)"),
    ("03_dts_measured.sql", "measured",
     "## 3 · Measured / event tables"),
    ("04_dts_scores.sql", "scores",
     "## 4 · Score output tables"),
    ("20_dts_clone_and_dmf.sql", "clone_and_dmf",
     "## 5 · Clone + baseline DMF procedures\n\n"
     "Each procedure is in its own cell (a `$$` body cannot share a cell with other "
     "statements). `SP_DTS_CLONE_SCORED_OBJECTS` is used by both tracks; "
     "`SP_DTS_ATTACH_BASELINE_DMFS` is Track A only."),
    ("21_dts_key_dmfs.sql", "key_dmfs",
     "## 6 · Key-column DMF procedure  _(Track A only)_"),
    ("25_dts_dmf_measurements.sql", "dmf_measurements",
     "## 7 · Measurement store + populators  _(must run before step 8)_\n\n"
     "`DTS_DMF_MEASUREMENTS` + Track B `SP_DTS_COMPUTE_DQ_MEASUREMENTS` (no grant) "
     "and Track A `SP_DTS_SYNC_NATIVE_DMF_RESULTS`."),
    ("26_dts_bridge_views.sql", "bridge_views",
     "## 8 · Bridge views  _(reads DTS_DMF_MEASUREMENTS from step 7)_"),
    ("30_dts_scoring_engine.sql", "scoring_engine",
     "## 9 · Scoring engine (`SP_DTS_COMPUTE_SCORES` + latest view)"),
    ("40_dts_seed_metadata.sql", "seed_metadata",
     "## 10 · Seed registries + metadata  _(run before the CALLs below)_"),
    ("45_dts_jira_incidents.sql", "jira_incidents",
     "## 10b · Jira -> Active Issues  (loader + sample)\n\n"
     "Creates `SP_DTS_LOAD_JIRA_ISSUES` and loads a **sample** payload into "
     "`DTS_OBSERVABILITY_INCIDENT` so the Active Issues dimension is exercised end-to-end. "
     "Replace the sample `PARSE_JSON(...)` with the real EDA issues array once the Atlassian "
     "MCP is authorized. This step also re-runs `SP_DTS_COMPUTE_SCORES()`."),
]

cells = [md(
    "# Data Trust Score v2 — Deploy Notebook\n\n"
    "Runs the full v2 deploy against **`EDLE_DW_DB.PNC_DATA`** using the "
    "**Track B** (no account-grant) DMF path. Generated from `ddl/*.sql` — "
    "regenerate with `python build_deploy_notebook.py` after editing the DDL.\n\n"
    "**Before running:** set the notebook role to `PNC_DEVELOPER_RL` and warehouse "
    "to `PNC_WH`, then **Run All**. Stored procedures run via `session.sql()` in "
    "Python cells (the notebook SQL-cell splitter can't parse `$$` bodies); tables, "
    "views, inserts, and CALLs use SQL cells.\n\n"
    "Track A (native DMFs) needs `EXECUTE DATA METRIC FUNCTION ON ACCOUNT` + "
    "`SNOWFLAKE.DATA_METRIC_USER`; skip those cells unless the grants exist.")]

cells.append(py_cell("init_session",
    "# Procedures are created from Python cells via session.sql(...).collect() so their\n"
    "# $$-quoted bodies reach Snowflake as a single statement (the SQL-cell splitter\n"
    "# would otherwise break them at internal semicolons).\n"
    "from snowflake.snowpark.context import get_active_session\n"
    "session = get_active_session()"))

for i, (fname, base_name, header) in enumerate(STEPS):
    cells.append(md(header))
    cells.extend(cells_for_file(fname, base_name, keep_use=(i == 0)))

cells.append(md(
    "## 11 · Run the pipeline (Track B — no grant)\n\n"
    "Clones the 5 scored objects, computes DMF-equivalent metrics in plain SQL over "
    "the clones, then computes the trust scores. Each CALL is its own cell so you can "
    "inspect the returned VARIANT (`failed`/`failures`) between steps."))
cells.append(sql_cell("call_clone", "CALL SP_DTS_CLONE_SCORED_OBJECTS();"))
cells.append(sql_cell("call_measure", "CALL SP_DTS_COMPUTE_DQ_MEASUREMENTS();"))
cells.append(sql_cell("call_score", "CALL SP_DTS_COMPUTE_SCORES();"))

cells.append(md("## 12 · Results — latest trust score per object"))
cells.append(sql_cell("results",
    "SELECT REPORT_FAMILY, LAYER, DQ_MEASUREMENT_LAYER, TRUST_SCORE, TRUST_BAND,\n"
    "       MEASURABLE_CEILING, FOUNDATIONAL_GAP_FLAG, FOUNDATIONAL_GAPS\n"
    "FROM   DTS_VW_DATASET_TRUST_SCORE_LATEST\n"
    "ORDER BY TRUST_SCORE DESC;"))

cells.append(md(
    "## 13 · Streamlit apps  _(manual step — not fully runnable here)_\n\n"
    "`ddl/50` creates a stage + two `STREAMLIT` objects, but you must first **upload** "
    "`app/config.py`, `app/shared.py`, `app/trust_score_app.py`, `app/ai_use_cases_app.py`, "
    "and `app/.streamlit/config.toml` to the stage. Run these cells after the files are uploaded."))
cells.extend(cells_for_file("50_create_streamlit_apps.sql", "streamlit_apps", keep_use=False))

nb = {
    "cells": cells,
    "metadata": {
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {
            "codemirror_mode": {"name": "ipython", "version": 3},
            "file_extension": ".py", "mimetype": "text/x-python", "name": "python",
            "nbconvert_exporter": "python", "pygments_lexer": "ipython3", "version": "3.10",
        },
    },
    "nbformat": 4,
    "nbformat_minor": 5,
}

out = BASE / "DTS_v2_Deploy.ipynb"
out.write_text(json.dumps(nb, indent=1))
n_sql = sum(1 for c in cells if c["cell_type"] == "code")
n_md = sum(1 for c in cells if c["cell_type"] == "markdown")
print(f"Wrote {out} with {len(cells)} cells ({n_sql} SQL, {n_md} markdown).")
