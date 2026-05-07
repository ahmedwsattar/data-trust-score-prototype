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

# Heatmap colour ramp (red -> amber -> green).
SCORE_COLOR_SCALE = alt.Scale(
    domain=[0, 50, 60, 80, 100],
    range=["#C44545", "#C44545", "#ED9B0F", "#FFD971", "#2E7D32"],
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
    page = st.radio(
        "View",
        ["Portfolio Scorecard", "Dataset Detail", "Methodology & Weights"],
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

    left, right = st.columns([1.4, 1])

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
                    axis=alt.Axis(orient="top", labelAngle=-30),
                ),
                y=alt.Y("DATASET_NAME:N", title=""),
                color=alt.Color("Score:Q", scale=SCORE_COLOR_SCALE, legend=alt.Legend(title="Score")),
                tooltip=["DATASET_NAME", "Dimension", alt.Tooltip("Score:Q", format=".1f")],
            )
            .properties(height=40 * dq_latest["DATASET_NAME"].nunique() + 30)
        )
        text = (
            alt.Chart(melt)
            .mark_text(color="white", fontWeight="bold")
            .encode(
                x=alt.X("Dimension:N", sort=[name for _, name, _ in DIMENSIONS]),
                y="DATASET_NAME:N",
                text=alt.Text("Score:Q", format=".0f"),
            )
        )
        st.altair_chart(heat + text, use_container_width=True)

    # Tier table ---------------------------------------------------------
    with right:
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
            use_container_width=True,
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
            x=alt.X("DOMAIN:N", title="", axis=alt.Axis(labelAngle=0)),
            y=alt.Y("Score:Q", scale=alt.Scale(domain=[0, 100])),
            color=alt.Color("DOMAIN:N", legend=None),
            column=alt.Column(
                "Dimension:N",
                sort=[name for _, name, _ in DIMENSIONS],
                header=alt.Header(labelAngle=-30, labelAlign="right", labelFontSize=10),
            ),
            tooltip=["DOMAIN", "Dimension", alt.Tooltip("Score:Q", format=".1f")],
        )
        .properties(width=70, height=260)
    )
    st.altair_chart(bar, use_container_width=False)


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
    st.subheader("Dataset detail")
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
            f"<span class='small-muted'>{row['DATASET_FQN']} &middot; "
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
        use_container_width=True,
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
    st.altair_chart(base + rules, use_container_width=True)

    # Per-dimension trend (small multiples) ------------------------------
    st.markdown("**Per-dimension trend**")
    dim_trend = dim_long[dim_long["DATASET_ID"] == row["DATASET_ID"]]
    facet = (
        alt.Chart(dim_trend)
        .mark_line()
        .encode(
            x=alt.X("SCORE_RUN_DATE:T", title=""),
            y=alt.Y("SCORE:Q", scale=alt.Scale(domain=[0, 100]), title=""),
            color=alt.Color("DIMENSION_NAME:N", legend=None),
            tooltip=["DIMENSION_NAME", "SCORE_RUN_DATE", alt.Tooltip("SCORE:Q", format=".1f")],
        )
        .properties(width=140, height=110)
        .facet(
            facet=alt.Facet("DIMENSION_NAME:N", header=alt.Header(labelFontSize=10)),
            columns=5,
        )
    )
    st.altair_chart(facet, use_container_width=False)

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
            display["Null %"] = (display["Null %"] * 100).round(2)
            st.dataframe(display, use_container_width=True, hide_index=True)


# --------------------------------------------------------------------------
# Page 3 - Methodology & Weights
# --------------------------------------------------------------------------

def render_methodology() -> None:
    st.subheader("Methodology & weights")
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
            use_container_width=True,
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
        st.altair_chart(donut, use_container_width=True)

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
else:
    render_methodology()
