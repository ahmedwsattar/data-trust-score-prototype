"""
P&C HR Analytics (AI use cases) -- applied analytics surface.

Two pages:

  1. Workforce Shifts -- weekly z-score anomalies + reorg detector
  2. TA Analytics     -- time-to-fill distribution + recruiter workload

Both answer client AI use cases on real EDL data:
  - UC #1 Data Quality / Observability  -- anomaly detection in workforce metrics
  - UC #2 Workforce Analytics & Insights -- shift detection + reorg detection
  - UC #3 TA Analytics                    -- time-to-fill + recruiter workload

Sister app `trust_score_app.py` hosts the Trust Score governance surface
(Portfolio Scorecard, Dataset Detail, Cortex DQ, Methodology). Cortex DQ
lives there because it's the measurement engine for trust dimensions 3-6.

Shared loaders, constants, and CSS live in `shared.py`.

Local dev:    streamlit run app/ai_use_cases_app.py
SiS deploy:   upload as a Streamlit app from app/ (entry: ai_use_cases_app.py)
"""

from __future__ import annotations

import altair as alt
import pandas as pd
import streamlit as st

from shared import (
    SCORE_COLOR_SCALE,
    apply_global_css,
    get_snowpark_session,
    load_recruiter_workload,
    load_reorg_events,
    load_time_to_fill,
    load_workforce_anomalies,
    load_workforce_weekly,
    _running_in_snowflake,
)


# --------------------------------------------------------------------------
# Page setup
# --------------------------------------------------------------------------

st.set_page_config(
    page_title="P&C HR Analytics (AI use cases)",
    page_icon=":sparkles:",
    layout="wide",
)
apply_global_css()

st.title("P&C HR Analytics (AI use cases)")
st.caption(
    "Applied analytics on real EDL data: workforce anomaly + reorg "
    "detection, time-to-fill distribution, and recruiter workload. "
    "Answers client AI use cases #1 (DQ observability via anomaly "
    "detection), #2 (workforce analytics), and #3 (TA analytics)."
)


# --------------------------------------------------------------------------
# Sidebar: nav (no filters here -- each page has its own inline filters)
# --------------------------------------------------------------------------

with st.sidebar:
    st.header("Navigation")
    page = st.selectbox(
        "View",
        [
            "Workforce Shifts",
            "TA Analytics",
        ],
        label_visibility="collapsed",
    )
    st.markdown("---")
    st.caption(
        f"Source: {'Snowflake' if _running_in_snowflake() else 'local CSV'}"
    )
    st.markdown("---")
    st.caption(
        "Trust Score scorecard + Cortex DQ measurements live in the "
        "**Data Trust Score** app."
    )


# --------------------------------------------------------------------------
# Page 1 -- Workforce Shifts (anomaly detection + reorg detector)
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
    weekly    = load_workforce_weekly()
    reorgs    = load_reorg_events()

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
    n_anom    = int((latest_anom["STATUS"] == "ANOMALY").sum())
    n_notable = int((latest_anom["STATUS"] == "NOTABLE").sum())
    n_l1      = anomalies["L1"].nunique()
    n_reorgs  = int(len(reorgs))

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("As-of week", pd.Timestamp(latest_week).strftime("%d %b %Y"))
    c2.metric("Anomalies (latest wk)", n_anom, delta_color="inverse")
    c3.metric("Notable signals (latest wk)", n_notable)
    c4.metric("L1 orgs tracked", n_l1)
    c5.metric("Reorg events detected", n_reorgs)

    st.markdown("---")

    # Anomaly trend ------------------------------------------------------
    st.markdown("**Weekly trend with anomaly overlay**")

    f1, f2 = st.columns([1, 1])
    l1_options     = ["(all L1s)"] + sorted(anomalies["L1"].dropna().unique().tolist())
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
        if sel_l1 == "(all L1s)":
            agg = (
                filt.groupby(["WEEK_START", "METRIC_NAME"], as_index=False)
                .agg(
                    ACTUAL=("ACTUAL", "sum"),
                    BASELINE=("BASELINE", "sum"),
                    Z_SCORE=("Z_SCORE", "max"),
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
            use_container_width=True,
        )

    st.markdown("---")

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
            use_container_width=True,
        )

    st.markdown("---")

    # Reorg detector panel -----------------------------------------------
    st.markdown("**Reorg detector -- bulk L1/L2 movements between snapshots**")
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
        # ProgressColumn requires max_value > min_value, so floor at 1.
        # Some Streamlit runtimes also choke on Styler + ProgressColumn
        # combos, so we keep the dataframe raw here.
        max_moved = int(rd["Employees moved"].max()) if not rd.empty else 1
        max_moved = max(max_moved, 1)
        st.dataframe(
            rd[["Snapshot date", "Level", "From", "To", "Employees moved"]],
            use_container_width=True,
        )


# --------------------------------------------------------------------------
# Page 2 -- TA Analytics (time-to-fill + recruiter workload)
# --------------------------------------------------------------------------

FILL_TYPE_LABEL = {
    "REFILL":       "Refill (vacated -> filled again)",
    "INITIAL_FILL": "Initial fill (newly created -> first fill)",
    "STILL_OPEN":   "Currently vacant (days open today)",
}


def _ta_diagnostic_panel() -> None:
    """Show what's actually populated in the underlying snapshot when the
    derived views look empty. Helps decide whether the data is sparse, the
    column names changed, or the view filters need to relax.
    """
    st.markdown("**Source-column profile (latest DT_POSITION_REPORT snapshot)**")
    try:
        session = get_snowpark_session()
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
        st.dataframe(diag, use_container_width=True)
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
    st.subheader("TA Analytics -- time-to-fill & recruiter workload")
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

    ttf      = load_time_to_fill()
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
        avg_days    = float(ttf["DAYS_TO_FILL"].mean())
        median_days = float(ttf["DAYS_TO_FILL"].median())
        n_filled    = int(len(ttf))
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
    c2.metric("Avg days to fill", f"{avg_days:.1f}" if n_filled else "-")
    c3.metric("Median days to fill", f"{median_days:.1f}" if n_filled else "-")
    c4.metric("Active recruiters", n_recruiters)
    c5.metric(
        "Active workload (open + frozen)",
        active_workload if active_workload else positions_touched,
    )

    st.markdown("---")

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
                st.altair_chart(hist + median_rule, use_container_width=True)
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
                    st.altair_chart(bars, use_container_width=True)

    st.markdown("---")

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
        # Pick the primary workload column in priority order. ACTIVE_WORKLOAD
        # is most reliable because POSITION_STAFFING_STATUS is populated for
        # every row; OPEN_REQS / ACTIVE_REQS depend on requisition fields
        # that only fire on currently-open positions; POSITIONS_TOUCHED is
        # the legacy fallback for older view definitions.
        if "ACTIVE_WORKLOAD" in workload.columns and workload["ACTIVE_WORKLOAD"].sum() > 0:
            load_col, load_label = "ACTIVE_WORKLOAD", "Active workload"
        elif "ACTIVE_REQS" in workload.columns and workload["ACTIVE_REQS"].sum() > 0:
            load_col, load_label = "ACTIVE_REQS", "Active reqs"
        elif "OPEN_REQS" in workload.columns and workload["OPEN_REQS"].sum() > 0:
            load_col, load_label = "OPEN_REQS", "Open reqs"
        else:
            load_col, load_label = "POSITIONS_TOUCHED", "Positions touched"

        median_load = float(workload[load_col].median())
        threshold   = max(median_load * 1.5, median_load + 1)
        wl = workload.sort_values(load_col, ascending=False).copy()
        wl["WORKLOAD_FLAG"] = wl[load_col].apply(
            lambda x: "OVERLOADED" if x >= threshold else "NORMAL"
        )

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

        # Mixing a pandas Styler with column_config.ProgressColumn produces
        # React #306 on the SiS frontend because the Styler hands the
        # ProgressColumn pre-formatted cells where it expects raw numerics.
        # We keep the row-level OVERLOADED highlight (the more informative
        # signal) and drop the progress bar.
        numeric_cols = [c for c in wl_display.columns if c != "Recruiter" and c != "Status"]
        st.dataframe(
            wl_display.style.apply(_row_style, axis=1).format(
                {c: "{:.0f}" for c in numeric_cols}
            ),
            use_container_width=True,
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
# Router
# --------------------------------------------------------------------------

if page == "Workforce Shifts":
    render_workforce_shifts()
else:
    render_ta_analytics()
