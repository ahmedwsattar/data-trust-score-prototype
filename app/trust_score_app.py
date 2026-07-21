"""
P&C Data Trust Score (v2) -- governance + DQ measurement surface.

Reads the live DTS_ objects in EDLE_DW_DB.PNC_DATA. Four pages:

  1. Portfolio Scorecard  -- all scored objects (family x layer): trust score,
                             band, measurable ceiling, foundational-gap flag.
  2. Dataset Detail       -- one object: dimension breakdown (weight x raw x
                             confidence), CDE elements, ceiling/gap.
  3. Lineage DQ           -- INT -> DW -> PUBL comparison per report family;
                             DQ + Observability measured per layer via DMFs.
  4. Methodology          -- weights, bands, confidence factors, DAMA, CDE.

Shared loaders/constants/CSS live in shared.py; framework values in config.py.
v2 is Snowflake-first: locally each page shows an enablement banner.
"""

from __future__ import annotations

import altair as alt
import pandas as pd
import streamlit as st

import config
from shared import (
    DIMENSIONS,
    LAYER_ORDER,
    SCORE_COLOR_SCALE,
    apply_global_css,
    band_color_for,
    enablement_banner,
    load_confidence_factors,
    load_data_elements,
    load_dmf_dimension_scores,
    load_element_dimension_scores,
    load_lineage,
    load_trust_scores,
    load_weights,
    _running_in_snowflake,
)

st.set_page_config(page_title="P&C Data Trust Score v2", page_icon=":bar_chart:", layout="wide")
apply_global_css()

st.title("P&C Data Trust Score")
st.caption(
    "v2 -- 10-dimension trust score measured per layer (INT → DW → PUBL) with "
    "live Snowflake DMFs, DQ confidence factor, CDE weighting, and "
    "measurable-ceiling / foundational-gap tracking."
)

# --------------------------------------------------------------------------
# Sidebar nav
# --------------------------------------------------------------------------
with st.sidebar:
    st.header("Navigation")
    page = st.selectbox(
        "View",
        ["Portfolio Scorecard", "Dataset Detail", "Lineage DQ", "Methodology"],
        label_visibility="collapsed",
    )
    st.caption(f"Namespace: `{config.TARGET_NS}`")
    st.caption(f"Source: {'Snowflake (live)' if _running_in_snowflake() else 'local (no live data)'}")

scores = load_trust_scores()


def _fmt_gaps(v) -> str:
    if isinstance(v, (list, tuple)):
        return ", ".join(v) if len(v) else "-"
    if isinstance(v, str) and v not in ("", "[]"):
        return v
    return "-"


# --------------------------------------------------------------------------
# Page 1 -- Portfolio Scorecard
# --------------------------------------------------------------------------
def render_portfolio() -> None:
    st.subheader("Portfolio scorecard")
    if scores is None:
        enablement_banner(["DTS_VW_DATASET_TRUST_SCORE_LATEST"])
        return
    if scores.empty:
        st.warning("No scores yet. Run `CALL SP_DTS_COMPUTE_SCORES();` after deploying + measuring.")
        return

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Objects scored", len(scores))
    c2.metric("Avg trust score", f"{scores['TRUST_SCORE'].mean():.1f}")
    c3.metric("Certified", int((scores["TRUST_BAND"] == "CERTIFIED").sum()))
    c4.metric("At risk", int((scores["TRUST_BAND"] == "AT_RISK").sum()), delta_color="inverse")
    c5.metric("Foundational gaps", int(scores["FOUNDATIONAL_GAP_FLAG"].sum()), delta_color="inverse")

    st.divider()

    # Heatmap: family x layer trust score
    st.markdown("**Trust score by report family x layer**")
    heat_df = scores.copy()
    heat_df["LAYER"] = pd.Categorical(heat_df["LAYER"], categories=LAYER_ORDER, ordered=True)
    heat = (
        alt.Chart(heat_df)
        .mark_rect()
        .encode(
            x=alt.X("LAYER:N", sort=LAYER_ORDER, axis=alt.Axis(orient="top", labelAngle=0)),
            y=alt.Y("REPORT_FAMILY:N", title="Report family"),
            color=alt.Color("TRUST_SCORE:Q", scale=SCORE_COLOR_SCALE, legend=alt.Legend(title="Trust score")),
            tooltip=["REPORT_FAMILY", "LAYER", alt.Tooltip("TRUST_SCORE:Q", format=".1f"),
                     "TRUST_BAND", alt.Tooltip("MEASURABLE_CEILING:Q", format=".0f")],
        )
        .properties(height=60 * heat_df["REPORT_FAMILY"].nunique() + 40)
    )
    text = (
        alt.Chart(heat_df).mark_text(fontWeight="bold")
        .encode(x=alt.X("LAYER:N", sort=LAYER_ORDER), y="REPORT_FAMILY:N",
                text=alt.Text("TRUST_SCORE:Q", format=".0f"),
                color=alt.condition(alt.datum.TRUST_SCORE >= 75, alt.value("#111827"), alt.value("#F9FAFB")))
    )
    st.altair_chart(heat + text, use_container_width=True)

    st.divider()

    # Ranking table
    st.markdown("**Scored objects**")
    tbl = scores[["REPORT_FAMILY", "LAYER", "DQ_MEASUREMENT_LAYER", "TRUST_SCORE",
                  "TRUST_BAND", "MEASURABLE_CEILING", "FOUNDATIONAL_GAP_FLAG",
                  "FOUNDATIONAL_GAPS"]].copy()
    tbl["FOUNDATIONAL_GAPS"] = tbl["FOUNDATIONAL_GAPS"].map(_fmt_gaps)
    tbl = tbl.sort_values("TRUST_SCORE", ascending=False).reset_index(drop=True)
    tbl.columns = ["Family", "Layer", "Confidence tier", "Score", "Band",
                   "Ceiling", "Gap?", "Missing foundational"]
    st.dataframe(
        tbl, use_container_width=True, hide_index=True,
        column_config={
            "Score": st.column_config.ProgressColumn("Score", min_value=0, max_value=100, format="%.1f"),
            "Ceiling": st.column_config.NumberColumn("Ceiling", format="%.0f"),
        },
    )
    st.caption(
        "**Ceiling** = sum of dimension weights measurable today (DMF-backed + "
        "seeded). Scores can't exceed the ceiling until the remaining dimensions "
        "are seeded. **Gap?** flags an unseeded foundational dimension."
    )


# --------------------------------------------------------------------------
# Page 2 -- Dataset Detail
# --------------------------------------------------------------------------
def render_detail() -> None:
    st.subheader("Dataset detail")
    eds = load_element_dimension_scores()
    weights = load_weights()
    elements = load_data_elements()
    if scores is None or eds is None or weights is None:
        enablement_banner(["DTS_VW_DATASET_TRUST_SCORE_LATEST",
                           "DTS_ELEMENT_DIMENSION_SCORE", "DTS_DIMENSION_WEIGHTS"])
        return
    if scores.empty:
        st.warning("No scores yet.")
        return

    scores["KEY"] = scores["REPORT_FAMILY"] + " · " + scores["LAYER"]
    pick = st.selectbox("Object", scores["KEY"].tolist())
    row = scores[scores["KEY"] == pick].iloc[0]
    fam, layer = row["REPORT_FAMILY"], row["LAYER"]

    h1, h2 = st.columns([2, 1])
    with h1:
        st.markdown(f"### {fam} · {layer}")
        st.markdown(f"<span class='small-muted'>{row['DATASET_FQN']} · confidence tier "
                    f"{row['DQ_MEASUREMENT_LAYER']}</span>", unsafe_allow_html=True)
        gaps = _fmt_gaps(row["FOUNDATIONAL_GAPS"])
        if row["FOUNDATIONAL_GAP_FLAG"]:
            st.markdown(f"<span class='gap-flag'>Foundational gap:</span> {gaps}", unsafe_allow_html=True)
    with h2:
        score = float(row["TRUST_SCORE"])
        color = band_color_for(score)
        st.metric("Trust score", f"{score:.1f} / 100")
        st.markdown(
            f"<div class='score-bar'><div style='width:{min(score,100)}%; background:{color};'></div></div>"
            f"<div style='text-align:center;margin-top:8px;'>"
            f"<span class='band-pill' style='background:{color}'>{row['TRUST_BAND']}</span></div>",
            unsafe_allow_html=True,
        )
        st.caption(f"Measurable ceiling: {row['MEASURABLE_CEILING']:.0f}")

    st.divider()

    # Dimension breakdown for this object
    st.markdown("**Dimension breakdown**")
    w = weights.rename(columns={"DIMENSION_CODE": "DIMENSION_CODE"})
    d = eds[(eds["REPORT_FAMILY"] == fam) & (eds["LAYER"] == layer)].copy()
    d = d.merge(w[["DIMENSION_CODE", "DIMENSION_LABEL", "WEIGHT"]], on="DIMENSION_CODE", how="right")
    d["EFFECTIVE"] = (d["RAW_SCORE"].fillna(0) * d["CONFIDENCE_FACTOR"].fillna(1.0))
    d["CONTRIBUTION"] = d["WEIGHT"] * d["EFFECTIVE"] / 100.0
    out = d[["DIMENSION_LABEL", "WEIGHT", "RAW_SCORE", "CONFIDENCE_FACTOR",
             "EFFECTIVE", "CONTRIBUTION", "IS_MEASURABLE"]].copy()
    out.columns = ["Dimension", "Weight", "Raw", "Confidence", "Effective", "Points", "Measurable"]
    out = out.sort_values("Weight", ascending=False)
    st.dataframe(
        out, use_container_width=True, hide_index=True,
        column_config={
            "Weight": st.column_config.NumberColumn("Weight", format="%.0f"),
            "Raw": st.column_config.ProgressColumn("Raw", min_value=0, max_value=100, format="%.0f"),
            "Confidence": st.column_config.NumberColumn("Conf.", format="%.2f"),
            "Effective": st.column_config.NumberColumn("Effective", format="%.0f"),
            "Points": st.column_config.NumberColumn("Points", format="%.1f"),
        },
    )
    st.caption("Points = Weight × (Raw × Confidence) / 100. DQ and Observability "
               "carry the per-layer confidence factor; other dimensions use 1.0.")

    # CDE elements
    if elements is not None and not elements.empty:
        st.markdown("**Key data elements (CDE = 2× weighted)**")
        el = elements[(elements["REPORT_FAMILY"] == fam) & (elements["LAYER"] == layer)]
        el = el[["COLUMN_NAME", "IS_KEY", "IS_CDE", "CRITICALITY_MULTIPLIER", "PII_TAG", "BUSINESS_TERM"]].copy()
        el.columns = ["Column", "Key", "CDE", "Multiplier", "PII tag", "Business term"]
        st.dataframe(el, use_container_width=True, hide_index=True)


# --------------------------------------------------------------------------
# Page 3 -- Lineage DQ (INT -> DW -> PUBL)
# --------------------------------------------------------------------------
def render_lineage() -> None:
    st.subheader("Lineage DQ — INT → DW → PUBL")
    dmf = load_dmf_dimension_scores()
    lineage = load_lineage()
    if scores is None or dmf is None:
        enablement_banner(["DTS_VW_DATASET_TRUST_SCORE_LATEST", "DTS_VW_DMF_DIMENSION_SCORES"])
        return

    fam = st.selectbox("Report family", sorted(scores["REPORT_FAMILY"].unique()))
    fam_scores = scores[scores["REPORT_FAMILY"] == fam].copy()
    fam_scores["LAYER"] = pd.Categorical(fam_scores["LAYER"], categories=LAYER_ORDER, ordered=True)
    fam_scores = fam_scores.sort_values("LAYER")

    # Trust score across layers
    st.markdown("**Trust score across layers**")
    line = (
        alt.Chart(fam_scores)
        .mark_bar()
        .encode(
            x=alt.X("LAYER:N", sort=LAYER_ORDER, axis=alt.Axis(labelAngle=0)),
            y=alt.Y("TRUST_SCORE:Q", scale=alt.Scale(domain=[0, 100]), title="Trust score"),
            color=alt.Color("LAYER:N", legend=None),
            tooltip=["LAYER", alt.Tooltip("TRUST_SCORE:Q", format=".1f"), "TRUST_BAND"],
        )
        .properties(height=280)
    )
    st.altair_chart(line, use_container_width=True)

    # DQ + Observability sub-scores per layer (from DMFs)
    st.markdown("**Measured DQ & Observability per layer (live DMFs)**")
    d = dmf[dmf["REPORT_FAMILY"] == fam].copy()
    if d.empty:
        st.info("No DMF measurements for this family yet.")
    else:
        melt = d.melt(
            id_vars=["LAYER"],
            value_vars=["DQ_COMPLETENESS_SCORE", "DQ_UNIQUENESS_SCORE",
                        "OBS_FRESHNESS_SCORE", "OBS_VOLUME_SCORE"],
            var_name="Metric", value_name="Score",
        )
        label = {
            "DQ_COMPLETENESS_SCORE": "DQ · Completeness",
            "DQ_UNIQUENESS_SCORE": "DQ · Uniqueness",
            "OBS_FRESHNESS_SCORE": "Obs · Freshness",
            "OBS_VOLUME_SCORE": "Obs · Volume",
        }
        melt["Metric"] = melt["Metric"].map(label)
        chart = (
            alt.Chart(melt)
            .mark_rect()
            .encode(
                x=alt.X("LAYER:N", sort=LAYER_ORDER, axis=alt.Axis(orient="top", labelAngle=0)),
                y=alt.Y("Metric:N", title=None),
                color=alt.Color("Score:Q", scale=SCORE_COLOR_SCALE),
                tooltip=["LAYER", "Metric", alt.Tooltip("Score:Q", format=".1f")],
            )
            .properties(height=200)
        )
        txt = (
            alt.Chart(melt).mark_text(fontWeight="bold")
            .encode(x=alt.X("LAYER:N", sort=LAYER_ORDER), y="Metric:N",
                    text=alt.Text("Score:Q", format=".0f"),
                    color=alt.condition(alt.datum.Score >= 75, alt.value("#111827"), alt.value("#F9FAFB")))
        )
        st.altair_chart(chart + txt, use_container_width=True)

    # Lineage chain
    if lineage is not None and not lineage.empty:
        st.markdown("**Lineage chain**")
        lc = lineage[lineage["REPORT_FAMILY"] == fam][
            ["LAYER", "OBJECT_FQN", "UPSTREAM_FQN", "DOWNSTREAM_FQN", "TRANSFORM_TYPE"]
        ].copy()
        lc.columns = ["Layer", "Object", "Upstream", "Downstream", "Transform"]
        st.dataframe(lc, use_container_width=True, hide_index=True)


# --------------------------------------------------------------------------
# Page 4 -- Methodology
# --------------------------------------------------------------------------
def render_methodology() -> None:
    st.subheader("Methodology & weights")
    weights = load_weights()
    conf = load_confidence_factors()

    st.markdown(
        "The trust score is a weighted average of 10 dimensions (weights sum to "
        "100). Two dimensions — **Data Quality** and **Observability** — are "
        "measured live via Snowflake DMFs on zero-copy clones and multiplied by "
        "a per-layer **DQ confidence factor**. The rest are governance/registry "
        "driven. Scores are capped by the **measurable ceiling** (sum of weights "
        "we can measure today); an unseeded foundational dimension raises a gap flag."
    )

    c1, c2 = st.columns(2)
    with c1:
        st.markdown("**Dimension weights (sum = 100)**")
        wdf = weights if weights is not None else pd.DataFrame(
            [(c, config.DIMENSION_LABEL[c], config.DIMENSION_WEIGHT[c]) for c, *_ in config.DIMENSIONS],
            columns=["DIMENSION_CODE", "DIMENSION_LABEL", "WEIGHT"],
        )
        donut = (
            alt.Chart(wdf).mark_arc(innerRadius=70)
            .encode(theta="WEIGHT:Q",
                    color=alt.Color("DIMENSION_LABEL:N", legend=alt.Legend(title="Dimension")),
                    tooltip=["DIMENSION_LABEL", "WEIGHT"])
            .properties(height=320)
        )
        st.altair_chart(donut, use_container_width=True)

    with c2:
        st.markdown("**DQ confidence factor (by layer)**")
        cdf = conf if conf is not None else pd.DataFrame(
            [("BRONZE", "INT", 0.90), ("SILVER", "DW", 0.75), ("GOLD", "PUBL", 0.60)],
            columns=["CONFIDENCE_TIER", "LAYER", "CONFIDENCE_FACTOR"],
        )
        st.dataframe(cdf, use_container_width=True, hide_index=True)
        st.markdown(
            f"""
            **Trust bands**

            | Band | Score |
            |---|---|
            | CERTIFIED | ≥ 90 |
            | TRUSTED | 75–89 |
            | ESTABLISHED | 60–74 |
            | PROVISIONAL | 40–59 |
            | AT RISK | < 40 |

            **DAMA sub-dimensions of DQ:** {", ".join(config.DAMA_SUB_DIMS)}
            (completeness + uniqueness are DMF-automated; accuracy/consistency/
            validity seeded from IDQ). **CDE multiplier:** {config.CDE_MULTIPLIER:g}×.
            **Measurable ceiling today:** {config.MEASURABLE_CEILING} points.
            """
        )


# --------------------------------------------------------------------------
# Router
# --------------------------------------------------------------------------
if page == "Portfolio Scorecard":
    render_portfolio()
elif page == "Dataset Detail":
    render_detail()
elif page == "Lineage DQ":
    render_lineage()
else:
    render_methodology()
