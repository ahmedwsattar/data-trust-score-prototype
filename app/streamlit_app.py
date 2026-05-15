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
        ["Portfolio Scorecard", "Dataset Detail", "Cortex DQ", "Methodology & Weights"],
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
# Page 4 - Methodology & Weights
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
else:
    render_methodology()
