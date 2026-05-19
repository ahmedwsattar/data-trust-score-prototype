"""
Shared constants, loaders, and helpers for the two Streamlit apps:

  - trust_score_app.py    -- Portfolio Scorecard + Dataset Detail + Methodology
  - ai_use_cases_app.py   -- Cortex DQ + Workforce Shifts + TA Analytics

Both apps `from shared import (...)` the items they need. Caching decorators
(@st.cache_data) are applied here so each app gets identical caching behaviour.

Runs in two environments:

  1. Streamlit in Snowflake (SiS, including Workspaces): pulls data live
     from ASATTAR_TRUST_SCORE_POC.DQ_POC via the active Snowpark session.
  2. Local development: falls back to the CSVs in ../data/ produced by
     ../synthetic/generate_synthetic.py. Snowflake-only loaders return None
     so each page can render a graceful "not enabled" state.

If you need Snowflake-only objects (DMFs, workforce/TA views), you must
deploy ddl/20-25 and ddl/40 first. See the README for run order.
"""

from __future__ import annotations

from pathlib import Path

import altair as alt
import pandas as pd
import streamlit as st

try:
    from snowflake.snowpark.context import get_active_session
    _SNOWPARK_AVAILABLE = True
except Exception:  # pragma: no cover - local dev path
    _SNOWPARK_AVAILABLE = False


# --------------------------------------------------------------------------
# Paths & schema constants
# --------------------------------------------------------------------------

# DATA_DIR is only used by the local-CSV fallback loaders. In Streamlit in
# Snowflake (SiS) the file-path resolution can raise
#   "TypeError: bad argument type for built-in operation"
# because the runtime's virtual filesystem rejects os.path.realpath() on
# stage-backed paths. Wrapping in try/except keeps the import side-effect-
# free in SiS while preserving the real path for local dev.
try:
    DATA_DIR = Path(__file__).resolve().parent.parent / "data"
except Exception:  # pragma: no cover -- SiS sandbox path
    DATA_DIR = Path("data")

SF_SCHEMA = "ASATTAR_TRUST_SCORE_POC.DQ_POC"


# --------------------------------------------------------------------------
# 10-dimension framework definition
# --------------------------------------------------------------------------

DIMENSIONS = [
    ("OWNERSHIP",              "Data Ownership",                 "DIM_OWNERSHIP_SCORE"),
    ("SOURCE",                 "Data Source",                    "DIM_SOURCE_SCORE"),
    ("ISSUES",                 "Active Issues",                  "DIM_ISSUES_SCORE"),
    ("TIMELINESS",             "Timeliness",                     "DIM_TIMELINESS_SCORE"),
    ("COMPLETENESS_KEY_PROPS", "Completeness of Key Properties", "DIM_COMPLETENESS_KEY_PROPS_SCORE"),
    ("PROFILING",              "Data Profiling",                 "DIM_PROFILING_SCORE"),
    ("DEFINITIONS",            "Data Definitions",               "DIM_DEFINITIONS_SCORE"),
    ("KEY_PROPERTIES",         "Key Properties",                 "DIM_KEY_PROPERTIES_SCORE"),
    ("USAGE",                  "Usage",                          "DIM_USAGE_SCORE"),
    ("FEEDBACK",               "User Feedback",                  "DIM_FEEDBACK_SCORE"),
]


# --------------------------------------------------------------------------
# Color palettes (tier pills, status text, score gradient)
# --------------------------------------------------------------------------

TIER_COLOR = {
    "GOLD":    "#C9A227",
    "SILVER":  "#9BA4B5",
    "BRONZE":  "#B07A3D",
    "AT_RISK": "#C44545",
}

STATUS_COLOR = {"GREEN": "#2E7D32", "AMBER": "#ED9B0F", "RED": "#C44545"}

# Continuous heatmap ramp: dark blue -> teal -> yellow. Tuned for the dark
# theme; readable text contrast handled via mark_text condition where used.
SCORE_COLOR_SCALE = alt.Scale(
    domain=[0, 50, 60, 80, 100],
    range=["#00204C", "#1F4E79", "#4C78A8", "#A1A84B", "#FDE725"],
)


# --------------------------------------------------------------------------
# Environment detection + low-level data access
# --------------------------------------------------------------------------

def _running_in_snowflake() -> bool:
    """True when there's an active Snowpark session (i.e. inside SiS)."""
    if not _SNOWPARK_AVAILABLE:
        return False
    try:
        get_active_session()
        return True
    except Exception:
        return False


def _read_snowflake(table: str, date_cols: list[str] | None = None) -> pd.DataFrame:
    """Read a table from Snowflake and coerce date columns to pandas datetime."""
    session = get_active_session()
    df = session.table(f"{SF_SCHEMA}.{table}").to_pandas()
    for col in date_cols or []:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors="coerce")
    return df


def _read_csv(filename: str, date_cols: list[str] | None = None) -> pd.DataFrame:
    return pd.read_csv(DATA_DIR / filename, parse_dates=date_cols or [])


def get_snowpark_session():
    """Return the active Snowpark session (only call when _running_in_snowflake())."""
    return get_active_session()


# --------------------------------------------------------------------------
# Trust-score loaders -- used by trust_score_app.py and the Cortex DQ
# comparison panel in ai_use_cases_app.py.
# --------------------------------------------------------------------------

@st.cache_data(show_spinner=False)
def load_dq_results() -> pd.DataFrame:
    if _running_in_snowflake():
        return _read_snowflake("PNC_DQ_RESULTS", date_cols=["SCORE_RUN_DATE"])
    return _read_csv("PNC_DQ_RESULTS.csv", date_cols=["SCORE_RUN_DATE"])


@st.cache_data(show_spinner=False)
def load_dq_dimension_results() -> pd.DataFrame:
    if _running_in_snowflake():
        return _read_snowflake("PNC_DQ_DIMENSION_RESULTS", date_cols=["SCORE_RUN_DATE"])
    return _read_csv("PNC_DQ_DIMENSION_RESULTS.csv", date_cols=["SCORE_RUN_DATE"])


@st.cache_data(show_spinner=False)
def load_ownership() -> pd.DataFrame:
    if _running_in_snowflake():
        return _read_snowflake("PNC_DATA_OWNERSHIP_REGISTRY")
    return _read_csv("PNC_DATA_OWNERSHIP_REGISTRY.csv")


@st.cache_data(show_spinner=False)
def load_source_classification() -> pd.DataFrame:
    if _running_in_snowflake():
        return _read_snowflake("PNC_SOURCE_CLASSIFICATION")
    return _read_csv("PNC_SOURCE_CLASSIFICATION.csv")


@st.cache_data(show_spinner=False)
def load_keys() -> pd.DataFrame:
    if _running_in_snowflake():
        return _read_snowflake("PNC_KEY_PROPERTY_REGISTRY")
    return _read_csv("PNC_KEY_PROPERTY_REGISTRY.csv")


@st.cache_data(show_spinner=False)
def load_weights() -> pd.DataFrame:
    if _running_in_snowflake():
        return _read_snowflake("PNC_TRUST_SCORE_WEIGHTS")
    return _read_csv("PNC_TRUST_SCORE_WEIGHTS.csv")


# --------------------------------------------------------------------------
# Cortex DQ / DMF loaders. Read live from the bridge views in ddl/22_*.sql.
# Return None on local dev or when the views don't exist so each page can
# render a "not enabled" state instead of crashing.
#
# Source of measurements (whichever populated the bridge view):
#   - Track A: SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS (native DMFs)
#   - Track B: PNC_DQ_MEASUREMENTS_MANUAL                       (file 25 SP)
# --------------------------------------------------------------------------

@st.cache_data(show_spinner=False, ttl=60)
def load_dmf_measurements() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake(
            "VW_PNC_DMF_LATEST_MEASUREMENTS",
            date_cols=["MEASUREMENT_TIME"],
        )
    except Exception:
        return None


@st.cache_data(show_spinner=False, ttl=60)
def load_dmf_dimension_scores() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake(
            "VW_PNC_DMF_DIMENSION_SCORES",
            date_cols=["COMPUTED_AT"],
        )
    except Exception:
        return None


# --------------------------------------------------------------------------
# Workforce / TA analytics loaders. Read live from the views in
# ddl/40_workforce_analytics_views.sql. Same None-on-failure pattern.
# --------------------------------------------------------------------------

@st.cache_data(show_spinner=False, ttl=120)
def load_workforce_anomalies() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake(
            "VW_WORKFORCE_ANOMALIES",
            date_cols=["WEEK_START"],
        )
    except Exception:
        return None


@st.cache_data(show_spinner=False, ttl=120)
def load_workforce_weekly() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake(
            "VW_WORKFORCE_WEEKLY_METRICS",
            date_cols=["WEEK_START"],
        )
    except Exception:
        return None


@st.cache_data(show_spinner=False, ttl=120)
def load_reorg_events() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake(
            "VW_REORG_EVENTS",
            date_cols=["MOVEMENT_DATE"],
        )
    except Exception:
        return None


@st.cache_data(show_spinner=False, ttl=120)
def load_time_to_fill() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake(
            "VW_TIME_TO_FILL",
            date_cols=["POSITION_VACATE_DATE", "POSITION_LAST_FILL_DATE"],
        )
    except Exception:
        return None


@st.cache_data(show_spinner=False, ttl=120)
def load_recruiter_workload() -> pd.DataFrame | None:
    if not _running_in_snowflake():
        return None
    try:
        return _read_snowflake("VW_RECRUITER_WORKLOAD")
    except Exception:
        return None


# --------------------------------------------------------------------------
# UI helpers
# --------------------------------------------------------------------------

_GLOBAL_CSS = """
<style>
    .tier-pill {
        display:inline-block; padding:4px 12px; border-radius:14px;
        color:white; font-weight:600; font-size:0.85rem;
    }
    .small-muted { color:#666; font-size:0.85rem; }
    .stMetric label { font-size:0.85rem !important; }
    .score-bar {
        height: 14px; border-radius: 7px; background: #eee; overflow: hidden;
        margin-top: 6px;
    }
    .score-bar > div { height: 100%; }
</style>
"""


def apply_global_css() -> None:
    """Inject the shared CSS rules. Call once after st.set_page_config()."""
    st.markdown(_GLOBAL_CSS, unsafe_allow_html=True)


def tier_color_for(score: float) -> str:
    """Return the tier hex color for a given overall score."""
    if score >= 85:
        return TIER_COLOR["GOLD"]
    if score >= 70:
        return TIER_COLOR["SILVER"]
    if score >= 50:
        return TIER_COLOR["BRONZE"]
    return TIER_COLOR["AT_RISK"]
