"""
Data Trust Score - Streamlit dashboard.

Runs in two environments:

  1. Streamlit in Snowflake (SiS, including Workspaces): pulls data live
     from ASATTAR_TRUST_SCORE_POC.DQ_POC via the active Snowpark session.
  2. Local development: falls back to the CSVs in ../data/ produced by
     ../synthetic/generate_synthetic.py.

The two paths are isolated in the load_*() functions; everything below is
shared.

Charting uses altair (pre-installed in the SiS runtime, no EAI required).
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

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
SF_SCHEMA = "ASATTAR_TRUST_SCORE_POC.DQ_POC"

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

TIER_COLOR = {
    "GOLD":    "#C9A227",
    "SILVER":  "#9BA4B5",
    "BRONZE":  "#B07A3D",
    "AT_RISK": "#C44545",
}
STATUS_COLOR = {"GREEN": "#2E7D32", "AMBER": "#ED9B0F", "RED": "#C44545"}

# Heatmap colour ramp (dark blue -> teal -> yellow). Designed for the
# dark theme; readable text contrast handled below via mark_text condition.
SCORE_COLOR_SCALE = alt.Scale(
    domain=[0, 50, 60, 80, 100],
    range=["#00204C", "#1F4E79", "#4C78A8", "#A1A84B", "#FDE725"],
)


# --------------------------------------------------------------------------
# Data loading - Snowflake when available, local CSVs otherwise.
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
# Cortex DQ / DMF loaders. These read live from the bridge views created in
# ddl/22_*.sql. They return None in every other case so the page can render
# a "not enabled" state instead of crashing.
#
# Source of measurements (whichever one populated the bridge view):
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
# Workforce analytics loaders. These read live from the views created in
# ddl/40_workforce_analytics_views.sql. Same pattern as the DMF loaders --
# return None when the view is missing or we're running locally so the
# page can render a graceful "not enabled" state.
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
# Page setup
# --------------------------------------------------------------------------

st.set_page_config(
    page_title="P&C Data Trust Score (Prototype)",
    page_icon=":bar_chart:",
    layout="wide",
)

st.markdown(
    """
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
    """,
    unsafe_allow_html=True,
)

st.title("P&C Data Trust Score")
st.caption(
    "Prototype on synthetic data. Mirrors proposed extension to "
    "`PNC_DQ_RESULTS` + 4 net-new registries (per Reuse Assessment, May 2026)."
)


# --------------------------------------------------------------------------
# Sidebar: filters & nav
# --------------------------------------------------------------------------

dq = load_dq_results()
ownership = load_ownership()
src = load_source_classification()
keys = load_keys()
weights = load_weights()
dim_long = load_dq_dimension_results()

latest_date = dq["SCORE_RUN_DATE"].max()

with st.sidebar:
    st.header("Navigation")
    page = st.selectbox(
        "View",
        [
            "Portfolio Scorecard",
            "Dataset Detail",
            "Cortex DQ",
            "Workforce Shifts",
            "TA Analytics",
            "Methodology & Weights",
        ],
        label_visibility="collapsed",
    )
    st.divider()
    st.header("Filters")
    domain_options = sorted(dq["DOMAIN"].unique())
    domain_filter = st.multiselect("Domain", domain_options, default=domain_options)
    tier_options = ["GOLD", "SILVER", "BRONZE", "AT_RISK"]
    tier_filter = st.multiselect("Tier", tier_options, default=tier_options)
    st.caption(f"As-of: **{pd.Timestamp(latest_date).date()}**")
    st.caption(
        f"Source: {'Snowflake' if _running_in_snowflake() else 'local CSV'}"
    )

dq_latest = dq[dq["SCORE_RUN_DATE"] == latest_date]
dq_latest = dq_latest[dq_latest["DOMAIN"].isin(domain_filter)]
dq_latest = dq_latest[dq_latest["TRUST_SCORE_TIER"].isin(tier_filter)]


# --------------------------------------------------------------------------
# Page 1 - Portfolio Scorecard
# --------------------------------------------------------------------------

def render_portfolio() -> None:
    st.subheader("Portfolio scorecard")
    if dq_latest.empty:
        st.info("No datasets match the current filters.")
        return

    # KPI strip ----------------------------------------------------------
    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Datasets in scope", f"{dq_latest['DATASET_ID'].nunique()}")
    c2.metric("Avg Trust Score", f"{dq_latest['TRUST_SCORE_OVERALL'].mean():.1f}")
    c3.metric("Gold tier", int((dq_latest["TRUST_SCORE_TIER"] == "GOLD").sum()))
    c4.metric(
        "At-Risk tier",
        int((dq_latest["TRUST_SCORE_TIER"] == "AT_RISK").sum()),
        delta_color="inverse",
    )
    open_p1 = int(dq_latest["DIM_ISSUES_OPEN_P1"].sum())
    c5.metric("Open P1 issues (sum)", open_p1, delta_color="inverse")

    st.divider()

    left, right = st.columns([1.7, 0.25])

    # Heatmap: datasets x dimensions -------------------------------------
    with left:
        st.markdown("**10-dimension heatmap (latest scores)**")
        heatmap_cols = [c for _, _, c in DIMENSIONS]
        label_map = {c: name for _, name, c in DIMENSIONS}
        melt = dq_latest.melt(
            id_vars=["DATASET_NAME"],
            value_vars=heatmap_cols,
            var_name="dim_col",
            value_name="Score",
        )
        melt["Dimension"] = melt["dim_col"].map(label_map)

        heat = (
            alt.Chart(melt)
            .mark_rect()
            .encode(
                x=alt.X(
                    "Dimension:N",
                    sort=[name for _, name, _ in DIMENSIONS],
                    axis=alt.Axis(orient="top", labelAngle=0, labelFontSize=11, labelAlign="center"),
                ),
                y=alt.Y(
                    "DATASET_NAME:N",
                    title="Dataset Title",
                    axis=alt.Axis(labelFontSize=10, labelAlign="right"),
                ),
                color=alt.Color("Score:Q", scale=SCORE_COLOR_SCALE, legend=alt.Legend(title="Score")),
                tooltip=["DATASET_NAME", "Dimension", alt.Tooltip("Score:Q", format=".1f")],
            )
            .properties(height=50 * dq_latest["DATASET_NAME"].nunique() + 40)
        )
        text = (
            alt.Chart(melt)
            .mark_text(fontWeight="bold")
            .encode(
                x=alt.X("Dimension:N", sort=[name for _, name, _ in DIMENSIONS]),
                y="DATASET_NAME:N",
                text=alt.Text("Score:Q", format=".0f"),
                color=alt.condition(
                    alt.datum.Score >= 90,
                    alt.value("#111827"),
                    alt.value("#F9FAFB"),
                ),
            )
        )
        st.altair_chart(heat + text, width='stretch')

    # Data Sources mini-list (key alongside the heatmap y-axis) ----------
    with right:
        st.markdown("**Data Sources**")
        sources = (
            dq_latest[["DATASET_NAME", "DOMAIN"]]
            .sort_values("DATASET_NAME", ascending=True)
            .reset_index(drop=True)
        )
        sources.columns = ["Dataset", "Domain"]
        st.dataframe(
            sources,
            width='stretch',
            height=50 * dq_latest["DATASET_NAME"].nunique() + 40,
            hide_index=True,
        )

    st.divider()

    # Tier ranking -------------------------------------------------------
    st.markdown("**Trust tier ranking**")
    ranking = (
        dq_latest[
            [
                "DATASET_NAME",
                "DOMAIN",
                "TRUST_SCORE_OVERALL",
                "TRUST_SCORE_TIER",
                "DIM_ISSUES_OPEN_P1",
                "DIM_TIMELINESS_HOURS_LATE",
            ]
        ]
        .sort_values("TRUST_SCORE_OVERALL", ascending=False)
        .reset_index(drop=True)
    )
    ranking.columns = ["Dataset", "Domain", "Score", "Tier", "P1 issues", "Hours late"]
    st.dataframe(
        ranking,
        width='stretch',
        hide_index=True,
        column_config={
            "Score": st.column_config.ProgressColumn(
                "Score", min_value=0, max_value=100, format="%.1f"
            ),
            "Tier": st.column_config.TextColumn("Tier"),
            "Hours late": st.column_config.NumberColumn("Hours late", format="%.1f"),
        },
    )

    st.divider()

    # Domain rollup ------------------------------------------------------
    st.markdown("**Average score by dimension and domain**")
    label_map = {c: name for _, name, c in DIMENSIONS}
    melt2 = dq_latest.melt(
        id_vars=["DATASET_NAME", "DOMAIN"],
        value_vars=[c for _, _, c in DIMENSIONS],
        var_name="dim_col",
        value_name="Score",
    )
    melt2["Dimension"] = melt2["dim_col"].map(label_map)
    grouped = melt2.groupby(["DOMAIN", "Dimension"], as_index=False)["Score"].mean()

    bar = (
        alt.Chart(grouped)
        .mark_bar()
        .encode(
            x=alt.X("DOMAIN:N", title="Domain", axis=alt.Axis(labelAngle=0)),
            y=alt.Y("Score:Q", title="Average Score", scale=alt.Scale(domain=[0, 100])),
            color=alt.Color("DOMAIN:N", legend=None),
            column=alt.Column(
                "Dimension:N",
                sort=[name for _, name, _ in DIMENSIONS],
                header=alt.Header(labelAngle=0, labelAlign="right", labelFontSize=10),
            ),
            tooltip=["DOMAIN", "Dimension", alt.Tooltip("Score:Q", format=".1f")],
        )
        .properties(width=120, height=300)
    )
    st.altair_chart(bar, width='content')


# --------------------------------------------------------------------------
# Page 2 - Dataset Detail
# --------------------------------------------------------------------------

def _tier_color_for(score: float) -> str:
    if score >= 85:
        return TIER_COLOR["GOLD"]
    if score >= 70:
        return TIER_COLOR["SILVER"]
    if score >= 50:
        return TIER_COLOR["BRONZE"]
    return TIER_COLOR["AT_RISK"]


def render_detail() -> None:
    st.subheader("Dataset Detail")
    if dq_latest.empty:
        st.info("No datasets match the current filters.")
        return

    dataset_name = st.selectbox(
        "Dataset",
        sorted(dq_latest["DATASET_NAME"].unique()),
    )
    row = dq_latest[dq_latest["DATASET_NAME"] == dataset_name].iloc[0]
    own_row = ownership[ownership["DATASET_ID"] == row["DATASET_ID"]]
    src_row = src[src["DATASET_ID"] == row["DATASET_ID"]]
    key_rows = keys[keys["DATASET_ID"] == row["DATASET_ID"]]

    # Header card --------------------------------------------------------
    h1, h2 = st.columns([2, 1])
    with h1:
        st.markdown(f"### {dataset_name}")
        st.markdown(
            f"<span style='color:#39FF14;' class='small-muted'>{row['DATASET_FQN']} &middot; "
            f"{row['DOMAIN']} &middot; {row['LAYER']}</span>",
            unsafe_allow_html=True,
        )
        if not own_row.empty:
            o = own_row.iloc[0]
            steward = o.get("DATA_STEWARD_NAME") or "**unassigned**"
            owner = o.get("BUSINESS_OWNER_NAME") or "**unassigned**"
            st.markdown(
                f"**Owner:** {owner}  &nbsp;&nbsp; **Steward:** {steward}  "
                f"&nbsp;&nbsp; **Status:** {o['ASSIGNMENT_STATUS']}"
            )
        if not src_row.empty:
            s = src_row.iloc[0]
            st.markdown(
                f"**Source system:** {s['SOURCE_SYSTEM']}  &nbsp;&nbsp; "
                f"**Tier:** {s['CLASSIFICATION_TIER']}  &nbsp;&nbsp; "
                f"**SLA:** {s['SLA_HOURS']:.0f} h  &nbsp;&nbsp; "
                f"**Cadence:** {s['LOAD_FREQUENCY']}"
            )

    with h2:
        score = float(row["TRUST_SCORE_OVERALL"])
        tier = row["TRUST_SCORE_TIER"]
        color = TIER_COLOR.get(tier, "#888")
        st.metric(label="Trust Score", value=f"{score:.1f} / 100")
        st.markdown(
            f"<div class='score-bar'><div style='width:{score}%; background:{color};'></div></div>"
            f"<div style='text-align:center; margin-top:8px;'>"
            f"<span class='tier-pill' style='background:{color}'>{tier}</span>"
            f"</div>",
            unsafe_allow_html=True,
        )

    st.divider()

    # Dimension breakdown ------------------------------------------------
    st.markdown("**Dimension breakdown (latest)**")
    rows_out = []
    weight_map = weights.set_index("DIMENSION_CODE")["WEIGHT_PCT"].astype(float).to_dict()
    for code, name, col in DIMENSIONS:
        weight = float(weight_map.get(code, 0))
        score_v = float(row[col])
        status_col = col.replace("_SCORE", "_STATUS")
        status = row.get(status_col, "")
        rows_out.append(
            dict(Dimension=name, Code=code, Weight=weight, Score=score_v, Status=status)
        )
    breakdown = pd.DataFrame(rows_out)
    st.dataframe(
        breakdown,
        width='stretch',
        hide_index=True,
        column_config={
            "Weight": st.column_config.NumberColumn("Weight %", format="%.0f"),
            "Score": st.column_config.ProgressColumn(
                "Score", min_value=0, max_value=100, format="%.1f"
            ),
        },
    )

    # Trend --------------------------------------------------------------
    st.markdown("**90-day trend**")
    trend = (
        dq[dq["DATASET_ID"] == row["DATASET_ID"]]
        .sort_values("SCORE_RUN_DATE")
        .copy()
    )
    base = (
        alt.Chart(trend)
        .mark_line(strokeWidth=3, color="#1F4E79")
        .encode(
            x=alt.X("SCORE_RUN_DATE:T", title=""),
            y=alt.Y(
                "TRUST_SCORE_OVERALL:Q",
                title="Overall Trust Score",
                scale=alt.Scale(domain=[0, 100]),
            ),
            tooltip=["SCORE_RUN_DATE", alt.Tooltip("TRUST_SCORE_OVERALL:Q", format=".1f")],
        )
        .properties(height=300)
    )
    rules = (
        alt.Chart(
            pd.DataFrame(
                {
                    "y": [85, 70, 50],
                    "label": ["GOLD", "SILVER", "AT_RISK"],
                    "color": ["#2E7D32", "#9BA4B5", "#C44545"],
                }
            )
        )
        .mark_rule(strokeDash=[3, 3])
        .encode(y="y:Q", color=alt.Color("color:N", scale=None, legend=None))
    )
    st.altair_chart(base + rules, width='stretch')

    # Per-dimension trend (single selection) ------------------------------
    st.markdown("**Per-dimension trend**")

    dim_trend = dim_long[dim_long["DATASET_ID"] == row["DATASET_ID"]].copy()
    dimensions = sorted(dim_trend["DIMENSION_NAME"].dropna().unique())

    selected_dim = st.selectbox(
        "Choose a dimension",
        options=dimensions,
        key=f"dim_selector_{row['DATASET_ID']}",
    )

    filtered = dim_trend[dim_trend["DIMENSION_NAME"] == selected_dim]

    single_trend = (
        alt.Chart(filtered)
        .mark_line(point=True)
        .encode(
            x=alt.X("SCORE_RUN_DATE:T", title="Run Date", axis=alt.Axis(format="%d %b %Y")),
            y=alt.Y("SCORE:Q", scale=alt.Scale(domain=[0, 100]), title="Score"),
            color=alt.Color("DIMENSION_NAME:N", legend=None),
            tooltip=[
                alt.Tooltip("DIMENSION_NAME:N", title="Dimension"),
                alt.Tooltip("SCORE_RUN_DATE:T", title="Run date"),
                alt.Tooltip("SCORE:Q", format=".1f", title="Score"),
            ],
        )
        .properties(width=260, height=260)
    )

    st.altair_chart(single_trend, width='stretch')

    # Sub-fact tables ----------------------------------------------------
    a, b = st.columns(2)
    with a:
        st.markdown("**Active issues (latest snapshot)**")
        st.metric("Open P1", int(row["DIM_ISSUES_OPEN_P1"]))
        st.metric("Open P2", int(row["DIM_ISSUES_OPEN_P2"]))
        st.metric("Open P3", int(row["DIM_ISSUES_OPEN_P3"]))
        last_failure = row.get("DIM_ISSUES_LAST_FAILURE_AT")
        if pd.notna(last_failure):
            st.caption(f"Last failure: {last_failure}")
    with b:
        st.markdown("**Key property profiling**")
        if key_rows.empty:
            st.info("No key registry rows for this dataset.")
        else:
            display = key_rows[
                [
                    "KEY_FIELD_NAME",
                    "KEY_FIELD_ROLE",
                    "IS_REQUIRED",
                    "IS_PRESENT_IN_SCHEMA",
                    "HAS_APPROVED_DEFINITION",
                    "NULL_PCT",
                ]
            ].rename(
                columns={
                    "KEY_FIELD_NAME": "Field",
                    "KEY_FIELD_ROLE": "Role",
                    "IS_REQUIRED": "Required",
                    "IS_PRESENT_IN_SCHEMA": "In schema",
                    "HAS_APPROVED_DEFINITION": "Has definition",
                    "NULL_PCT": "Null %",
                }
            )
            bool_cols = ["Required", "In schema", "Has definition"]
            for col in bool_cols:
                display[col] = display[col].map({True: "Yes", False: "No"}).fillna("Unknown")

            display["Null %"] = (display["Null %"] * 100).round(2)

            def style_bool(v: str) -> str:
                if v == "Yes":
                    return "color:#0B6E3D; background-color:#EAF7EE; font-weight:700;"
                if v == "No":
                    return "color:#8A1525; background-color:#FDECEE; font-weight:700;"
                return "color:#475569; background-color:#F8FAFC; font-weight:600;"

            def style_null_pct(v: float) -> str:
                if pd.isna(v):
                    return ""
                if v >= 20:
                    return "color:#7A0612; background-color:#FDECEE; font-weight:700;"
                if v >= 5:
                    return "color:#8A5A00; background-color:#FFF7E6; font-weight:700;"
                return "color:#0B6E3D; background-color:#EAF7EE; font-weight:700;"

            def style_string(v: str) -> str:
                if v == "Yes":
                    return "color:#0B6E3D; background-color:#EAF7EE; font-weight:700;"
                if v == "No":
                    return "color:#8A1525; background-color:#FDECEE; font-weight:700;"
                return "color:#475569; background-color:#F8FAFC; font-weight:600;"

            styled = (
                display.style
                .map(style_string, subset=["Field", "Role"])
                .map(style_bool, subset=bool_cols)
                .map(style_null_pct, subset=["Null %"])
                .format({"Null %": "{:.2f}%"})
            )

            st.dataframe(styled, width='stretch', hide_index=True)


# --------------------------------------------------------------------------
# Page 3 - Cortex DQ (live DMF measurements bridged to dimensions 3/4/5/6)
# --------------------------------------------------------------------------

CORTEX_DQ_HOWTO = """
This page reads live measurements from `VW_PNC_DMF_LATEST_MEASUREMENTS` and
`VW_PNC_DMF_DIMENSION_SCORES`. Two interchangeable tracks populate them:

**Track A — native Snowflake Cortex DQ** (cleanest, but ACCOUNTADMIN must
grant `EXECUTE DATA METRIC FUNCTION` + `SNOWFLAKE.DATA_METRIC_USER` to the
working role).

```
ddl/20_cortex_dq_setup.sql               -- attach 9 + 6 native DMFs
ddl/21_pnc_dmf_dataset_map.sql           -- physical->logical bridge
ddl/22_vw_pnc_dmf_dimension_scores.sql   -- bridge views this page reads
ddl/seed/22a_seed_pnc_dmf_dataset_map.sql
```

**Track B — manual SQL fallback** (no ACCOUNTADMIN required; computes the
same 15 metrics in plain SQL inside a stored procedure). Use this when
your role can't get the native-DMF privileges granted.

```
ddl/25_manual_dmf_fallback.sql           -- SP + measurements table
ddl/21_pnc_dmf_dataset_map.sql
ddl/22_vw_pnc_dmf_dimension_scores.sql
ddl/seed/22a_seed_pnc_dmf_dataset_map.sql
```

To refresh measurements at any time:
`CALL ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS();`
"""


def render_cortex_dq() -> None:
    st.subheader("Cortex Data Quality (DMF-derived dimensions)")
    st.caption(
        "Live measurements from Snowflake Data Metric Functions (or the "
        "manual SP fallback), bridged into Trust Score dimensions 3 (Active "
        "Issues), 4 (Timeliness), 5 (Completeness of Key Properties), and "
        "6 (Data Profiling)."
    )

    if not _running_in_snowflake():
        st.info(
            "Cortex DQ data is only available when this app runs inside "
            "Streamlit in Snowflake (SiS). Locally the bridge views don't "
            "exist, so this page is read-only documentation."
        )
        with st.expander("How to enable", expanded=True):
            st.markdown(CORTEX_DQ_HOWTO)
        return

    measurements = load_dmf_measurements()
    scores = load_dmf_dimension_scores()

    if measurements is None or scores is None:
        st.warning(
            "The bridge views (`VW_PNC_DMF_LATEST_MEASUREMENTS`, "
            "`VW_PNC_DMF_DIMENSION_SCORES`) aren't in this schema yet."
        )
        with st.expander("How to enable", expanded=True):
            st.markdown(CORTEX_DQ_HOWTO)
        return

    if measurements.empty:
        st.warning(
            "Bridge views exist but no measurements have landed yet. "
            "Track A: the first scheduled DMF run may take up to 5 minutes; "
            "trigger an instant reading via the inline scans in Section E "
            "of `ddl/20_cortex_dq_setup.sql`. "
            "Track B: run "
            "`CALL ASATTAR_TRUST_SCORE_POC.DQ_POC.SP_COMPUTE_DQ_MEASUREMENTS();`"
        )
        return

    # KPI strip ----------------------------------------------------------
    total_checks = len(measurements)
    failing = int((measurements["STATUS"] == "FAIL").sum())
    passing = int((measurements["STATUS"] == "PASS").sum())
    untested = total_checks - failing - passing
    last_seen = measurements["MEASUREMENT_TIME"].max()

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Datasets wired", scores["DATASET_ID"].nunique())
    c2.metric("DMF readings", total_checks)
    c3.metric("Passing", passing)
    c4.metric("Failing", failing, delta_color="inverse")
    c5.metric(
        "Last measurement",
        pd.Timestamp(last_seen).strftime("%H:%M") if pd.notna(last_seen) else "—",
    )
    if untested:
        st.caption(
            f"{untested} reading(s) have no threshold defined yet — add rows "
            "to `PNC_DMF_THRESHOLDS` to score them."
        )

    st.divider()

    # Per-dataset derived dimension scores -------------------------------
    st.markdown("**Derived dimension scores (live from DMFs)**")
    score_cols = [
        "DATASET_NAME",
        "DOMAIN",
        "DIM_ISSUES_SCORE",
        "DIM_TIMELINESS_SCORE",
        "DIM_COMPLETENESS_KEY_PROPS_SCORE",
        "DIM_PROFILING_SCORE",
        "DIM_ISSUES_OPEN_P1",
        "DIM_TIMELINESS_HOURS_LATE",
    ]
    available = [c for c in score_cols if c in scores.columns]
    display = scores[available].copy()
    rename = {
        "DATASET_NAME": "Dataset",
        "DOMAIN": "Domain",
        "DIM_ISSUES_SCORE": "Active Issues",
        "DIM_TIMELINESS_SCORE": "Timeliness",
        "DIM_COMPLETENESS_KEY_PROPS_SCORE": "Completeness (keys)",
        "DIM_PROFILING_SCORE": "Profiling",
        "DIM_ISSUES_OPEN_P1": "Open P1",
        "DIM_TIMELINESS_HOURS_LATE": "Hours late",
    }
    display = display.rename(columns=rename)
    progress_cols = ["Active Issues", "Timeliness", "Completeness (keys)", "Profiling"]
    column_config = {
        c: st.column_config.ProgressColumn(c, min_value=0, max_value=100, format="%.1f")
        for c in progress_cols
        if c in display.columns
    }
    column_config["Hours late"] = st.column_config.NumberColumn(
        "Hours late", format="%.1f"
    )
    st.dataframe(
        display, width='stretch', hide_index=True, column_config=column_config
    )

    st.divider()

    # Raw measurements table ---------------------------------------------
    st.markdown("**Latest DMF measurements (raw)**")
    raw = measurements.copy()
    raw["MEASUREMENT_TIME"] = pd.to_datetime(raw["MEASUREMENT_TIME"], errors="coerce")
    show_cols = [
        "DATASET_ID",
        "METRIC_NAME",
        "COLUMN_NAME",
        "VALUE",
        "THRESHOLD_OP",
        "THRESHOLD_VALUE",
        "STATUS",
        "SEVERITY_ON_FAIL",
        "MEASUREMENT_TIME",
    ]
    show_cols = [c for c in show_cols if c in raw.columns]
    raw_display = raw[show_cols].sort_values(
        ["DATASET_ID", "METRIC_NAME", "COLUMN_NAME"]
    )

    def _row_style(row: pd.Series) -> list[str]:
        # Light pastels with dark text -- legible on either light or dark theme.
        if row.get("STATUS") == "FAIL":
            return ["background-color:#FDECEE; color:#8A1525; font-weight:600"] * len(row)
        if row.get("STATUS") == "PASS":
            return ["background-color:#EAF7EE; color:#0B6E3D; font-weight:600"] * len(row)
        return [""] * len(row)

    st.dataframe(
        raw_display.style.apply(_row_style, axis=1),
        width='stretch',
        hide_index=True,
    )

    # Comparison with bespoke scores -------------------------------------
    st.divider()
    st.markdown("**DMF-derived vs current synthetic score (per wired dataset)**")
    compare_rows = []
    for _, srow in scores.iterrows():
        ds_id = srow["DATASET_ID"]
        bespoke = dq_latest[dq_latest["DATASET_ID"] == ds_id]
        if bespoke.empty:
            continue
        b = bespoke.iloc[0]
        for label, dmf_col, syn_col in [
            ("Active Issues",       "DIM_ISSUES_SCORE",                "DIM_ISSUES_SCORE"),
            ("Timeliness",          "DIM_TIMELINESS_SCORE",            "DIM_TIMELINESS_SCORE"),
            ("Completeness (keys)", "DIM_COMPLETENESS_KEY_PROPS_SCORE","DIM_COMPLETENESS_KEY_PROPS_SCORE"),
            ("Profiling",           "DIM_PROFILING_SCORE",             "DIM_PROFILING_SCORE"),
        ]:
            dmf_val = srow.get(dmf_col)
            syn_val = b.get(syn_col)
            if pd.isna(dmf_val) or pd.isna(syn_val):
                continue
            compare_rows.append({
                "Dataset": srow.get("DATASET_NAME") or ds_id,
                "Dimension": label,
                "DMF-derived": float(dmf_val),
                "Current (synthetic)": float(syn_val),
                "Delta": float(dmf_val) - float(syn_val),
            })
    if compare_rows:
        cmp_df = pd.DataFrame(compare_rows)
        st.dataframe(
            cmp_df,
            width='stretch',
            hide_index=True,
            column_config={
                "DMF-derived":         st.column_config.ProgressColumn("DMF-derived",         min_value=0, max_value=100, format="%.1f"),
                "Current (synthetic)": st.column_config.ProgressColumn("Current (synthetic)", min_value=0, max_value=100, format="%.1f"),
                "Delta":               st.column_config.NumberColumn("Delta", format="%+.1f"),
            },
        )
        st.caption(
            "Once governance signs off on the DMF-derived scores, swap them "
            "into `PNC_DQ_RESULTS` via a nightly task and retire the bespoke "
            "logic for these four dimensions."
        )
    else:
        st.caption(
            "No overlap between wired DMF datasets and the synthetic "
            "scorecard — the comparison panel will populate once you map a "
            "common DATASET_ID."
        )


# --------------------------------------------------------------------------
# Page 4 - Workforce Shifts
#
# Powered by ddl/40_workforce_analytics_views.sql:
#   - VW_WORKFORCE_ANOMALIES        (z-score per week / L1 / metric)
#   - VW_WORKFORCE_WEEKLY_METRICS   (time series with rolling baselines)
#   - VW_REORG_EVENTS               (bulk L1/L2 movements)
# --------------------------------------------------------------------------

ANOMALY_COLOR = {
    "ANOMALY":              "#C44545",
    "NOTABLE":              "#ED9B0F",
    "NORMAL":               "#4C78A8",
    "INSUFFICIENT_HISTORY": "#9BA4B5",
}


def _empty_workforce_state() -> None:
    st.info(
        "Workforce analytics views aren't available in this session. They live "
        "in `ASATTAR_TRUST_SCORE_POC.DQ_POC` (Snowflake). Run "
        "`ddl/40_workforce_analytics_views.sql` and open this app inside "
        "Streamlit in Snowflake to enable."
    )


def render_workforce_shifts() -> None:
    st.subheader("Workforce Shifts (anomaly + reorg detection)")
    st.caption(
        "Weekly z-score anomalies on hires, terminations, and promotions "
        "by L1, plus bulk L1/L2 movements between snapshots. Surfaces the "
        "kind of upstream-calculation-error pattern the client called out "
        "(e.g. \"involuntary turnover dropped 50% suddenly\")."
    )

    if not _running_in_snowflake():
        _empty_workforce_state()
        return

    anomalies = load_workforce_anomalies()
    weekly = load_workforce_weekly()
    reorgs = load_reorg_events()

    if anomalies is None or weekly is None or reorgs is None:
        _empty_workforce_state()
        return

    if anomalies.empty:
        st.warning(
            "Views exist but no metric history yet. Confirm "
            "`DT_TRENDED_REPORT` is loaded and re-run "
            "`ddl/40_workforce_analytics_views.sql`."
        )
        return

    # KPI strip ----------------------------------------------------------
    latest_week = anomalies["WEEK_START"].max()
    latest_anom = anomalies[anomalies["WEEK_START"] == latest_week]
    n_anom = int((latest_anom["STATUS"] == "ANOMALY").sum())
    n_notable = int((latest_anom["STATUS"] == "NOTABLE").sum())
    n_l1 = anomalies["L1"].nunique()
    n_reorgs = int(len(reorgs))

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("As-of week", pd.Timestamp(latest_week).strftime("%d %b %Y"))
    c2.metric("Anomalies (latest wk)", n_anom, delta_color="inverse")
    c3.metric("Notable signals (latest wk)", n_notable)
    c4.metric("L1 orgs tracked", n_l1)
    c5.metric("Reorg events detected", n_reorgs)

    st.divider()

    # Anomaly trend ------------------------------------------------------
    st.markdown("**Weekly trend with anomaly overlay**")

    f1, f2 = st.columns([1, 1])
    l1_options = ["(all L1s)"] + sorted(anomalies["L1"].dropna().unique().tolist())
    metric_options = sorted(anomalies["METRIC_NAME"].dropna().unique().tolist())
    with f1:
        sel_l1 = st.selectbox("L1 organization", l1_options, key="wf_l1")
    with f2:
        sel_metrics = st.multiselect(
            "Metrics",
            metric_options,
            default=metric_options,
            key="wf_metrics",
        )

    filt = anomalies.copy()
    if sel_l1 != "(all L1s)":
        filt = filt[filt["L1"] == sel_l1]
    if sel_metrics:
        filt = filt[filt["METRIC_NAME"].isin(sel_metrics)]

    if filt.empty:
        st.info("No data for the current filter selection.")
    else:
        # Aggregate across L1s when "(all)" -- sum actuals so the chart shows
        # a single line per metric instead of a tangle.
        if sel_l1 == "(all L1s)":
            agg = (
                filt.groupby(["WEEK_START", "METRIC_NAME"], as_index=False)
                .agg(
                    ACTUAL=("ACTUAL", "sum"),
                    BASELINE=("BASELINE", "sum"),
                    Z_SCORE=("Z_SCORE", "max"),  # surface the worst signal
                )
            )
            agg["STATUS"] = agg["Z_SCORE"].apply(
                lambda z: (
                    "INSUFFICIENT_HISTORY" if pd.isna(z)
                    else "ANOMALY" if abs(z) >= 2
                    else "NOTABLE" if abs(z) >= 1
                    else "NORMAL"
                )
            )
            chart_df = agg
        else:
            chart_df = filt.copy()

        line = (
            alt.Chart(chart_df)
            .mark_line(strokeWidth=2)
            .encode(
                x=alt.X("WEEK_START:T", title="Week"),
                y=alt.Y("ACTUAL:Q", title="Count"),
                color=alt.Color("METRIC_NAME:N", title="Metric"),
                tooltip=[
                    alt.Tooltip("WEEK_START:T", title="Week"),
                    "METRIC_NAME",
                    alt.Tooltip("ACTUAL:Q", format=".0f"),
                    alt.Tooltip("BASELINE:Q", format=".1f", title="Baseline"),
                    alt.Tooltip("Z_SCORE:Q", format=".2f", title="Z-score"),
                    "STATUS",
                ],
            )
        )
        points = (
            alt.Chart(chart_df)
            .mark_point(size=120, filled=True, strokeWidth=2, stroke="white")
            .encode(
                x="WEEK_START:T",
                y="ACTUAL:Q",
                color=alt.Color(
                    "STATUS:N",
                    scale=alt.Scale(
                        domain=list(ANOMALY_COLOR.keys()),
                        range=list(ANOMALY_COLOR.values()),
                    ),
                    legend=alt.Legend(title="Anomaly status"),
                ),
                shape=alt.Shape("METRIC_NAME:N", legend=None),
                tooltip=[
                    alt.Tooltip("WEEK_START:T", title="Week"),
                    "METRIC_NAME",
                    alt.Tooltip("ACTUAL:Q", format=".0f"),
                    alt.Tooltip("BASELINE:Q", format=".1f", title="Baseline"),
                    alt.Tooltip("Z_SCORE:Q", format=".2f", title="Z-score"),
                    "STATUS",
                ],
            )
        )
        st.altair_chart(
            (line + points).properties(height=380),
            width="stretch",
        )

    st.divider()

    # Anomaly table ------------------------------------------------------
    st.markdown("**Top anomalies (ranked by absolute z-score)**")
    flagged = (
        anomalies[anomalies["STATUS"].isin(["ANOMALY", "NOTABLE"])]
        .copy()
        .assign(ABS_Z=lambda d: d["Z_SCORE"].abs())
        .sort_values("ABS_Z", ascending=False)
        .head(25)
    )
    if flagged.empty:
        st.success("No metric crossed the z-score thresholds in this window.")
    else:
        show = flagged[
            ["WEEK_START", "L1", "METRIC_NAME", "ACTUAL", "BASELINE",
             "Z_SCORE", "STATUS", "DIRECTION"]
        ].rename(
            columns={
                "WEEK_START":  "Week",
                "L1":          "L1",
                "METRIC_NAME": "Metric",
                "ACTUAL":      "Actual",
                "BASELINE":    "Baseline",
                "Z_SCORE":     "Z-score",
                "STATUS":      "Status",
                "DIRECTION":   "Direction",
            }
        )

        def _row_style(row: pd.Series) -> list[str]:
            if row.get("Status") == "ANOMALY":
                return ["background-color:#FDECEE; color:#8A1525; font-weight:600"] * len(row)
            if row.get("Status") == "NOTABLE":
                return ["background-color:#FFF7E6; color:#8A5A00; font-weight:600"] * len(row)
            return [""] * len(row)

        st.dataframe(
            show.style.apply(_row_style, axis=1).format(
                {"Actual": "{:.0f}", "Baseline": "{:.1f}", "Z-score": "{:+.2f}"}
            ),
            width="stretch",
            hide_index=True,
        )

    st.divider()

    # Reorg detector panel -----------------------------------------------
    st.markdown("**Reorg detector — bulk L1/L2 movements between snapshots**")
    st.caption(
        "Each row = N employees moved from one org to another between two "
        "consecutive weekly snapshots. Threshold is N >= 5; tune in the SQL view."
    )

    if reorgs.empty:
        st.info(
            "No movements above the >=5 threshold in this window. Lower the "
            "threshold in `VW_REORG_EVENTS` if you expect smaller reorgs."
        )
    else:
        level_options = sorted(reorgs["LEVEL_NAME"].dropna().unique().tolist())
        sel_level = st.radio(
            "Movement level",
            level_options,
            horizontal=True,
            key="reorg_level",
        )
        rd = reorgs[reorgs["LEVEL_NAME"] == sel_level].copy()
        rd = rd.sort_values(["MOVEMENT_DATE", "EMPLOYEES_MOVED"], ascending=[False, False])
        rd = rd.rename(
            columns={
                "MOVEMENT_DATE":   "Snapshot date",
                "LEVEL_NAME":      "Level",
                "FROM_ORG":        "From",
                "TO_ORG":          "To",
                "EMPLOYEES_MOVED": "Employees moved",
            }
        )
        st.dataframe(
            rd[["Snapshot date", "Level", "From", "To", "Employees moved"]],
            width="stretch",
            hide_index=True,
            column_config={
                "Employees moved": st.column_config.ProgressColumn(
                    "Employees moved",
                    min_value=0,
                    max_value=int(rd["Employees moved"].max()) if not rd.empty else 1,
                    format="%d",
                )
            },
        )


# --------------------------------------------------------------------------
# Page 5 - TA Analytics (time-to-fill + recruiter workload)
#
# Powered by ddl/40_workforce_analytics_views.sql:
#   - VW_TIME_TO_FILL          (per-position vacate -> fill duration)
#   - VW_RECRUITER_WORKLOAD    (active reqs per recruiter, latest snapshot)
# --------------------------------------------------------------------------

FILL_TYPE_LABEL = {
    "REFILL":       "Refill (vacated → filled again)",
    "INITIAL_FILL": "Initial fill (newly created → first fill)",
    "STILL_OPEN":   "Currently vacant (days open today)",
}


def _ta_diagnostic_panel() -> None:
    """Show what's actually populated in the underlying snapshot when the
    derived views look empty. Helps the user decide whether the data is
    sparse, the column names changed, or the view filters need to relax.
    """
    st.markdown("**Source-column profile (latest DT_POSITION_REPORT snapshot)**")
    try:
        session = get_active_session()
        diag = session.sql("""
            WITH latest AS (
                SELECT * FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT
                WHERE REPORT_EFFECTIVE_DATE = (
                    SELECT MAX(REPORT_EFFECTIVE_DATE)
                    FROM ASATTAR_TRUST_SCORE_POC.DQ_POC.DT_POSITION_REPORT)
            )
            SELECT
                COUNT(*)                                                            AS total_positions
              , COUNT(POSITION_VACATE_DATE)                                         AS has_vacate_date
              , COUNT(POSITION_LAST_FILL_DATE)                                      AS has_last_fill_date
              , COUNT(POSITION_CREATED_MOMENT)                                      AS has_created_moment
              , COUNT_IF(POSITION_LAST_FILL_DATE >= POSITION_VACATE_DATE)           AS refilled
              , COUNT_IF(POSITION_VACATE_DATE IS NULL AND POSITION_LAST_FILL_DATE IS NOT NULL)
                                                                                    AS initial_fill_only
              , COUNT(JOB_REQUISITION_PRIMARY_RECRUITER)                            AS has_recruiter
              , COUNT(OPEN_JOB_REQUISITION_ID)                                      AS has_open_req_id
            FROM latest
        """).to_pandas()
        st.dataframe(diag, width="stretch", hide_index=True)
        st.caption(
            "If `has_vacate_date`, `has_last_fill_date`, `has_recruiter`, or "
            "`has_open_req_id` is near zero, that field is sparsely populated "
            "in your snapshot and the view will be empty by design. "
            "Section G of `ddl/40_workforce_analytics_views.sql` has the full "
            "diagnostic block including status-value distributions."
        )
    except Exception as exc:  # pragma: no cover
        st.caption(f"Diagnostic query failed: {exc}")


def render_ta_analytics() -> None:
    st.subheader("TA Analytics — time-to-fill & recruiter workload")
    st.caption(
        "Distribution of days-to-fill, by job family, plus a recruiter "
        "workload view that surfaces capacity outliers. Both panels use the "
        "latest DT_POSITION_REPORT snapshot. Each panel renders independently "
        "so one empty data source doesn't blank the page."
    )

    if not _running_in_snowflake():
        st.info(
            "TA analytics views aren't available in this session. Run "
            "`ddl/40_workforce_analytics_views.sql` and open inside "
            "Streamlit in Snowflake to enable."
        )
        return

    ttf = load_time_to_fill()
    workload = load_recruiter_workload()

    if ttf is None and workload is None:
        st.info(
            "TA analytics views aren't available in this session. Run "
            "`ddl/40_workforce_analytics_views.sql` and open inside "
            "Streamlit in Snowflake to enable."
        )
        return

    # KPI strip ----------------------------------------------------------
    if ttf is not None and not ttf.empty:
        avg_days = float(ttf["DAYS_TO_FILL"].mean())
        median_days = float(ttf["DAYS_TO_FILL"].median())
        n_filled = int(len(ttf))
    else:
        avg_days = median_days = 0.0
        n_filled = 0

    if workload is not None and not workload.empty:
        n_recruiters = int(workload["RECRUITER"].nunique())
        active_workload = (
            int(workload["ACTIVE_WORKLOAD"].sum())
            if "ACTIVE_WORKLOAD" in workload.columns else 0
        )
        positions_touched = int(workload["POSITIONS_TOUCHED"].sum())
    else:
        n_recruiters = active_workload = positions_touched = 0

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Positions w/ fill data", n_filled)
    c2.metric("Avg days to fill", f"{avg_days:.1f}" if n_filled else "—")
    c3.metric("Median days to fill", f"{median_days:.1f}" if n_filled else "—")
    c4.metric("Active recruiters", n_recruiters)
    c5.metric(
        "Active workload (open + frozen)",
        active_workload if active_workload else positions_touched,
    )

    st.divider()

    # ---------- TIME-TO-FILL PANEL --------------------------------------
    st.markdown("### Time-to-fill")
    if ttf is None or ttf.empty:
        st.warning(
            "`VW_TIME_TO_FILL` returned no rows. The view now accepts three "
            "fill types (REFILL, INITIAL_FILL, STILL_OPEN). If it's still "
            "empty, the underlying date columns are likely sparse in your "
            "data sample. Diagnostic below."
        )
        with st.expander("Show source-column profile", expanded=True):
            _ta_diagnostic_panel()
    else:
        # FILL_TYPE breakdown + filter
        type_counts = (
            ttf["FILL_TYPE"].value_counts(dropna=False).rename_axis("FILL_TYPE").reset_index(name="n")
        )
        type_counts["Label"] = type_counts["FILL_TYPE"].map(
            lambda v: FILL_TYPE_LABEL.get(v, str(v))
        )
        st.markdown("**Population by fill type**")
        cols = st.columns(len(type_counts) if len(type_counts) <= 4 else 4)
        for i, (_, r) in enumerate(type_counts.iterrows()):
            cols[i % len(cols)].metric(r["Label"], int(r["n"]))

        type_options = ttf["FILL_TYPE"].dropna().unique().tolist()
        sel_types = st.multiselect(
            "Include fill types",
            options=type_options,
            default=type_options,
            format_func=lambda v: FILL_TYPE_LABEL.get(v, str(v)),
            key="ttf_fill_types",
        )
        ttf_f = ttf[ttf["FILL_TYPE"].isin(sel_types)] if sel_types else ttf

        if ttf_f.empty:
            st.info("No positions match the selected fill types.")
        else:
            left, right = st.columns([1.2, 1])

            with left:
                st.markdown("**Days-to-fill distribution**")
                cap_p = ttf_f["DAYS_TO_FILL"].quantile(0.99)
                max_d = int(cap_p) + 1 if pd.notna(cap_p) and cap_p > 0 else 30
                clip = ttf_f[ttf_f["DAYS_TO_FILL"] <= max_d]
                hist = (
                    alt.Chart(clip)
                    .mark_bar()
                    .encode(
                        x=alt.X(
                            "DAYS_TO_FILL:Q",
                            bin=alt.Bin(maxbins=30),
                            title="Days to fill",
                        ),
                        y=alt.Y("count()", title="Positions"),
                        color=alt.Color(
                            "FILL_TYPE:N",
                            scale=alt.Scale(
                                domain=["REFILL", "INITIAL_FILL", "STILL_OPEN"],
                                range=["#4C78A8", "#A1A84B", "#C44545"],
                            ),
                            legend=alt.Legend(title="Fill type"),
                        ),
                        tooltip=["FILL_TYPE", alt.Tooltip("count()", title="Positions")],
                    )
                    .properties(height=320)
                )
                med_v = float(ttf_f["DAYS_TO_FILL"].median())
                median_rule = (
                    alt.Chart(pd.DataFrame({"x": [med_v]}))
                    .mark_rule(color="#FDE725", strokeDash=[4, 4], strokeWidth=2)
                    .encode(x="x:Q")
                )
                st.altair_chart(hist + median_rule, width="stretch")
                st.caption(
                    f"Yellow dashed line = median ({med_v:.0f} days). Tail above "
                    f"the 99th percentile ({max_d} days) is hidden for chart readability."
                )

            with right:
                st.markdown("**Avg days by job family group**")
                by_group = (
                    ttf_f.dropna(subset=["JOB_FAMILY_GROUP"])
                    .groupby("JOB_FAMILY_GROUP")
                    .agg(
                        positions=("POSITION_ID", "count"),
                        avg_days=("DAYS_TO_FILL", "mean"),
                        median_days=("DAYS_TO_FILL", "median"),
                    )
                    .reset_index()
                    .sort_values("positions", ascending=False)
                    .head(15)
                )
                if by_group.empty:
                    st.info("No job family group data available.")
                else:
                    bars = (
                        alt.Chart(by_group)
                        .mark_bar()
                        .encode(
                            x=alt.X("avg_days:Q", title="Avg days to fill"),
                            y=alt.Y("JOB_FAMILY_GROUP:N", sort="-x", title=""),
                            color=alt.Color(
                                "avg_days:Q",
                                scale=SCORE_COLOR_SCALE,
                                legend=None,
                            ),
                            tooltip=[
                                alt.Tooltip("JOB_FAMILY_GROUP:N", title="Job family group"),
                                alt.Tooltip("positions:Q", title="Positions"),
                                alt.Tooltip("avg_days:Q", format=".1f", title="Avg days"),
                                alt.Tooltip("median_days:Q", format=".1f", title="Median days"),
                            ],
                        )
                        .properties(height=320)
                    )
                    st.altair_chart(bars, width="stretch")

    st.divider()

    # ---------- RECRUITER WORKLOAD PANEL --------------------------------
    st.markdown("### Recruiter workload (current snapshot)")
    if workload is None or workload.empty:
        st.warning(
            "`VW_RECRUITER_WORKLOAD` returned no rows. Most likely "
            "`JOB_REQUISITION_PRIMARY_RECRUITER` is sparsely populated in your "
            "snapshot. Diagnostic below."
        )
        with st.expander("Show source-column profile", expanded=False):
            _ta_diagnostic_panel()
    else:
        # ACTIVE_WORKLOAD = vacant + frozen positions. This is the primary
        # workload signal because POSITION_STAFFING_STATUS is reliably
        # populated for every row, whereas OPEN_JOB_REQUISITION_ID is only
        # set on positions with an active req. Fall back to POSITIONS_TOUCHED
        # only if the new column is missing (older view definition).
        if "ACTIVE_WORKLOAD" in workload.columns and workload["ACTIVE_WORKLOAD"].sum() > 0:
            load_col, load_label = "ACTIVE_WORKLOAD", "Active workload"
        elif "ACTIVE_REQS" in workload.columns and workload["ACTIVE_REQS"].sum() > 0:
            load_col, load_label = "ACTIVE_REQS", "Active reqs"
        elif "OPEN_REQS" in workload.columns and workload["OPEN_REQS"].sum() > 0:
            load_col, load_label = "OPEN_REQS", "Open reqs"
        else:
            load_col, load_label = "POSITIONS_TOUCHED", "Positions touched"

        median_load = float(workload[load_col].median())
        threshold = max(median_load * 1.5, median_load + 1)
        wl = workload.sort_values(load_col, ascending=False).copy()
        wl["WORKLOAD_FLAG"] = wl[load_col].apply(
            lambda x: "OVERLOADED" if x >= threshold else "NORMAL"
        )

        # Friendly column names; only rename what's present.
        rename_map = {
            "RECRUITER":            "Recruiter",
            "POSITIONS_TOUCHED":    "Positions touched",
            "ACTIVE_WORKLOAD":      "Active workload",
            "VACANT_POSITIONS":     "Vacant",
            "FROZEN_POSITIONS":     "Frozen",
            "ACTIVE_REQS":          "Active reqs",
            "OPEN_REQS":            "Open reqs",
            "FILLED_TO_DATE":       "Filled to date",
            "JOB_FAMILIES_COVERED": "Job families",
            "L1_ORGS_COVERED":      "L1 orgs",
            "WORKLOAD_FLAG":        "Status",
        }
        wl_display = wl.rename(columns={k: v for k, v in rename_map.items() if k in wl.columns})

        # Column ordering: the workload metric goes first after Recruiter, then
        # the breakdown columns, then coverage, then status.
        preferred = [
            "Recruiter", load_label, "Vacant", "Frozen", "Active reqs",
            "Open reqs", "Positions touched", "Filled to date",
            "Job families", "L1 orgs", "Status",
        ]
        display_cols = [c for c in preferred if c in wl_display.columns]
        wl_display = wl_display[display_cols]

        def _row_style(row: pd.Series) -> list[str]:
            if row.get("Status") == "OVERLOADED":
                return ["background-color:#FDECEE; color:#8A1525; font-weight:600"] * len(row)
            return [""] * len(row)

        st.dataframe(
            wl_display.style.apply(_row_style, axis=1),
            width="stretch",
            hide_index=True,
            column_config={
                load_label: st.column_config.ProgressColumn(
                    load_label,
                    min_value=0,
                    max_value=int(wl[load_col].max()),
                    format="%d",
                ),
            },
        )
        if load_col == "ACTIVE_WORKLOAD":
            st.caption(
                "Workload is **vacant + frozen positions** the recruiter is "
                "currently named on (using `POSITION_STAFFING_STATUS`, which "
                "is reliably populated for every position). "
                f"Median recruiter is carrying **{median_load:.0f}** active "
                f"positions; anyone at or above **{threshold:.0f}** flagged "
                "as OVERLOADED."
            )
        elif load_col == "ACTIVE_REQS":
            st.caption(
                f"Workload is open requisitions (`JOB_REQUISITION_STATUS = 'Open'`). "
                f"Median is **{median_load:.0f}** active reqs; recruiters at or "
                f"above **{threshold:.0f}** flagged as OVERLOADED."
            )
        elif load_col == "OPEN_REQS":
            st.caption(
                f"Median recruiter has **{median_load:.0f}** open reqs "
                f"(`OPEN_JOB_REQUISITION_ID` count). Recruiters at or above "
                f"**{threshold:.0f}** flagged as OVERLOADED."
            )
        else:
            st.caption(
                "All status columns are unpopulated, so workload is computed "
                "from total positions the recruiter is named on. "
                f"Median load is **{median_load:.0f}**; recruiters at or above "
                f"**{threshold:.0f}** flagged as OVERLOADED."
            )


# --------------------------------------------------------------------------
# Page 6 - Methodology & Weights
# --------------------------------------------------------------------------

def render_methodology() -> None:
    st.subheader("Methodology & Weights")
    st.markdown(
        "The Trust Score is a weighted average of 10 dimensions. Weights, "
        "thresholds, and tier cut-points are stored in "
        "`PNC_TRUST_SCORE_WEIGHTS` so Governance can change them without "
        "code deploys."
    )

    c1, c2 = st.columns([1, 1])
    with c1:
        st.markdown("**Weights (sum = 100)**")
        st.dataframe(
            weights[["DIMENSION_CODE", "DIMENSION_NAME", "WEIGHT_PCT"]],
            width='stretch',
            hide_index=True,
            column_config={
                "DIMENSION_CODE": "Code",
                "DIMENSION_NAME": "Dimension",
                "WEIGHT_PCT": st.column_config.NumberColumn("Weight %", format="%.0f"),
            },
        )
        donut = (
            alt.Chart(weights)
            .mark_arc(innerRadius=70)
            .encode(
                theta=alt.Theta("WEIGHT_PCT:Q"),
                color=alt.Color("DIMENSION_NAME:N", legend=alt.Legend(title="Dimension")),
                tooltip=["DIMENSION_NAME", alt.Tooltip("WEIGHT_PCT:Q", format=".0f")],
            )
            .properties(height=320)
        )
        st.altair_chart(donut, width='stretch')

    with c2:
        st.markdown("**Per-dimension status thresholds**")
        st.markdown(
            """
            | Status | Score range |
            |---|---|
            | GREEN  | >= 80 |
            | AMBER  | 60 - 79 |
            | RED    | < 60 |

            **Overall tier**

            | Tier     | Score range |
            |---|---|
            | GOLD     | >= 85 |
            | SILVER   | 70 - 84 |
            | BRONZE   | 50 - 69 |
            | AT_RISK  | < 50 |
            """
        )
        st.markdown(
            """
            **Reuse assessment summary** (from May 2026 doc)

            - 6 of 10 dimensions sourceable from existing assets
            - 4 dimensions require net-new registries (Ownership, Source classification, Usage, Feedback)
            - **No existing pipeline tables need to be modified** for MVP -- see `ddl/99_existing_tables_changes.md`
            - The closest existing surface candidate, `PNC_DQ_RESULTS`, is *extended* (not replaced)
            """
        )


# --------------------------------------------------------------------------
# Router
# --------------------------------------------------------------------------

if page == "Portfolio Scorecard":
    render_portfolio()
elif page == "Dataset Detail":
    render_detail()
elif page == "Cortex DQ":
    render_cortex_dq()
elif page == "Workforce Shifts":
    render_workforce_shifts()
elif page == "TA Analytics":
    render_ta_analytics()
else:
    render_methodology()
