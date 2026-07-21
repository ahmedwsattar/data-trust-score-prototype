"""
shared.py -- v2 loaders, constants, and UI helpers for the Streamlit apps.

v2 is Snowflake-first: the trust score is computed live in EDLE_DW_DB.PNC_DATA
by the DTS_ objects (see ddl/). There is no synthetic-CSV fallback -- when the
app runs outside Streamlit-in-Snowflake the DTS_ loaders return None and each
page renders an enablement banner.

All framework constants (dimensions, weights, bands, confidence factors) come
from config.py so the app, the DDL, and the docs never drift.
"""

from __future__ import annotations

import altair as alt
import pandas as pd
import streamlit as st

import config

try:
    from snowflake.snowpark.context import get_active_session
    _SNOWPARK_AVAILABLE = True
except Exception:  # pragma: no cover - local dev path
    _SNOWPARK_AVAILABLE = False


# --------------------------------------------------------------------------
# Namespace + framework constants (from config.py)
# --------------------------------------------------------------------------

SF_SCHEMA = config.TARGET_NS               # EDLE_DW_DB.PNC_DATA

# (code, label, weight) tuples for iteration in the UI.
DIMENSIONS = [(code, config.DIMENSION_LABEL[code], config.DIMENSION_WEIGHT[code])
              for code, *_ in config.DIMENSIONS]

BAND_COLOR = {name: hexc for name, _lo, _hi, hexc in config.TRUST_BANDS}

STATUS_COLOR = {"GREEN": "#2E7D32", "AMBER": "#ED9B0F", "RED": "#C44545"}

SCORE_COLOR_SCALE = alt.Scale(
    domain=[0, 40, 60, 75, 90, 100],
    range=["#C44545", "#ED9B0F", "#C9A227", "#66BB6A", "#1E8E3E", "#0B6E3D"],
)

LAYER_ORDER = ["INT", "DW", "PUBL"]


# --------------------------------------------------------------------------
# Environment detection + low-level access
# --------------------------------------------------------------------------

def _running_in_snowflake() -> bool:
    if not _SNOWPARK_AVAILABLE:
        return False
    try:
        get_active_session()
        return True
    except Exception:
        return False


def get_snowpark_session():
    return get_active_session()


def _read(table_or_view: str, date_cols: list[str] | None = None) -> pd.DataFrame | None:
    """Read a DTS_ object from Snowflake; None on local dev or if it doesn't exist."""
    if not _running_in_snowflake():
        return None
    try:
        session = get_active_session()
        df = session.table(f"{SF_SCHEMA}.{table_or_view}").to_pandas()
        for col in date_cols or []:
            if col in df.columns:
                df[col] = pd.to_datetime(df[col], errors="coerce")
        return df
    except Exception:
        return None


# --------------------------------------------------------------------------
# v2 loaders (all Snowflake-first; None -> render enablement banner)
# --------------------------------------------------------------------------

@st.cache_data(show_spinner=False, ttl=120)
def load_trust_scores() -> pd.DataFrame | None:
    return _read("DTS_VW_DATASET_TRUST_SCORE_LATEST", date_cols=["SCORE_RUN_DATE"])


@st.cache_data(show_spinner=False, ttl=120)
def load_trust_scores_history() -> pd.DataFrame | None:
    return _read("DTS_DATASET_TRUST_SCORE", date_cols=["SCORE_RUN_DATE"])


@st.cache_data(show_spinner=False, ttl=120)
def load_element_dimension_scores() -> pd.DataFrame | None:
    return _read("DTS_ELEMENT_DIMENSION_SCORE", date_cols=["SCORE_RUN_DATE"])


@st.cache_data(show_spinner=False, ttl=60)
def load_dmf_dimension_scores() -> pd.DataFrame | None:
    return _read("DTS_VW_DMF_DIMENSION_SCORES", date_cols=["COMPUTED_AT"])


@st.cache_data(show_spinner=False, ttl=60)
def load_dmf_measurements() -> pd.DataFrame | None:
    return _read("DTS_VW_DMF_LATEST_MEASUREMENTS", date_cols=["MEASUREMENT_TIME"])


@st.cache_data(show_spinner=False, ttl=300)
def load_dataset_registry() -> pd.DataFrame | None:
    return _read("DTS_DATASET_REGISTRY")


@st.cache_data(show_spinner=False, ttl=300)
def load_data_elements() -> pd.DataFrame | None:
    return _read("DTS_DATA_ELEMENT")


@st.cache_data(show_spinner=False, ttl=300)
def load_weights() -> pd.DataFrame | None:
    return _read("DTS_DIMENSION_WEIGHTS")


@st.cache_data(show_spinner=False, ttl=300)
def load_bands() -> pd.DataFrame | None:
    return _read("DTS_TRUST_BANDS")


@st.cache_data(show_spinner=False, ttl=300)
def load_lineage() -> pd.DataFrame | None:
    return _read("DTS_LINEAGE_REGISTRY")


@st.cache_data(show_spinner=False, ttl=300)
def load_confidence_factors() -> pd.DataFrame | None:
    return _read("DTS_DQ_CONFIDENCE_FACTOR")


# --------------------------------------------------------------------------
# Workforce / TA analytics loaders (sister ai_use_cases_app.py).
# Orthogonal to the trust score; the underlying VW_WORKFORCE_* views are not
# part of the v2 DTS_ set, so these return None until those views are recreated
# under EDLE_DW_DB.PNC_DATA. Each HR page then renders an enablement message.
# --------------------------------------------------------------------------

@st.cache_data(show_spinner=False, ttl=120)
def load_workforce_anomalies() -> pd.DataFrame | None:
    return _read("VW_WORKFORCE_ANOMALIES", date_cols=["WEEK_START"])


@st.cache_data(show_spinner=False, ttl=120)
def load_workforce_weekly() -> pd.DataFrame | None:
    return _read("VW_WORKFORCE_WEEKLY_METRICS", date_cols=["WEEK_START"])


@st.cache_data(show_spinner=False, ttl=120)
def load_reorg_events() -> pd.DataFrame | None:
    return _read("VW_REORG_EVENTS", date_cols=["MOVEMENT_DATE"])


@st.cache_data(show_spinner=False, ttl=120)
def load_time_to_fill() -> pd.DataFrame | None:
    return _read("VW_TIME_TO_FILL", date_cols=["POSITION_VACATE_DATE", "POSITION_LAST_FILL_DATE"])


@st.cache_data(show_spinner=False, ttl=120)
def load_recruiter_workload() -> pd.DataFrame | None:
    return _read("VW_RECRUITER_WORKLOAD")


# --------------------------------------------------------------------------
# UI helpers
# --------------------------------------------------------------------------

_GLOBAL_CSS = """
<style>
    .band-pill {
        display:inline-block; padding:4px 12px; border-radius:14px;
        color:white; font-weight:600; font-size:0.85rem;
    }
    .small-muted { color:#888; font-size:0.85rem; }
    .stMetric label { font-size:0.85rem !important; }
    .score-bar {
        height:14px; border-radius:7px; background:#eee; overflow:hidden; margin-top:6px;
    }
    .score-bar > div { height:100%; }
    .gap-flag { color:#C44545; font-weight:700; }
</style>
"""


def apply_global_css() -> None:
    st.markdown(_GLOBAL_CSS, unsafe_allow_html=True)


def band_color_for(score: float) -> str:
    return BAND_COLOR.get(config.band_for(score), "#888")


def enablement_banner(view_names: list[str]) -> None:
    """Consistent 'run in Snowflake' banner for pages needing live DTS_ data."""
    st.info(
        "This page reads live data from the DTS_ objects in "
        f"`{SF_SCHEMA}`. It only renders inside Streamlit in Snowflake after "
        "the DDL is deployed and `SP_DTS_COMPUTE_SCORES()` has run."
    )
    with st.expander("What this page needs", expanded=False):
        st.markdown(
            "Deploy `ddl/00` → `ddl/40`, run the clone + DMF SPs, then "
            "`CALL SP_DTS_COMPUTE_SCORES();`. Objects read here:\n\n"
            + "\n".join(f"- `{SF_SCHEMA}.{v}`" for v in view_names)
        )
