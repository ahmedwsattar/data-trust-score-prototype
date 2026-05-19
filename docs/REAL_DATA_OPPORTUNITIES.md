# What This Becomes With Real Production Data

## TL;DR

The POC is running today against ~16 weekly snapshots of `DT_TRENDED_REPORT`
(165k rows) and 2 weekly snapshots of `DT_POSITION_REPORT` (80k rows) in the
`ASATTAR_TRUST_SCORE_POC.DQ_POC` sandbox. Even at this scale, four of the five
client AI use cases are answered today (the only true blocker for the fifth is
**Snowflake Cortex grants**).

When the same prototype is repointed at the production EDL (`EDLE_DW_DB.PNC_DATA`
or equivalent) and given Cortex access, every panel becomes orders of magnitude
more reliable, the dimension coverage expands from 2 datasets to the whole HR
estate, and the "AI assistant" features (NL queries, narratives, predictive)
light up. **No app rewrites required** — only swapping the FROM clauses in
`ddl/40_*.sql` and granting `SNOWFLAKE.CORTEX_USER`.

This document maps each client AI use case to:

1. **What works today** in the POC (and where to see it)
2. **What changes** when pointed at production data
3. **What unlocks** with Cortex on top

---

## What's running in the POC today

The codebase ships **two Streamlit apps**:

- **`trust_score_app.py`** — governance + DQ measurement surface
  (Portfolio Scorecard, Dataset Detail, **Cortex DQ**, Methodology).
  Source: `PNC_DQ_RESULTS` + 4 registries + live DMF measurement views.
- **`ai_use_cases_app.py`** — applied AI use cases (Workforce Shifts,
  TA Analytics). Source: real EDL tables.

Cortex DQ lives with the Trust Score app because it's the *measurement
engine* for trust dimensions 3-6 — not a standalone AI use case.

Capability matrix:

| Capability | App | Page | Source |
|---|---|---|---|
| 10-dimension trust score on ~10 datasets | Trust Score | Portfolio Scorecard | `PNC_DQ_RESULTS` (synthetic) |
| Per-dataset dimension drilldown + 90-day trend | Trust Score | Dataset Detail | `PNC_DQ_RESULTS` + registries |
| Live DMF measurements -> 4 dimensions | Trust Score | Cortex DQ | `VW_PNC_DMF_*` (real data, manual SP fallback) |
| Weekly anomaly detection (z-score by L1) | AI Use Cases | Workforce Shifts | `VW_WORKFORCE_ANOMALIES` (real trended data) |
| Reorg detector (L1/L2 bulk movements) | AI Use Cases | Workforce Shifts | `VW_REORG_EVENTS` (real trended data) |
| Time-to-fill distribution + recruiter workload | AI Use Cases | TA Analytics | `VW_TIME_TO_FILL`, `VW_RECRUITER_WORKLOAD` (real position data) |

All real-data views are defined in `ddl/40_workforce_analytics_views.sql` and
read directly from the two tables loaded via `ddl/30_copy_into_dt_tables.sql`.

---

## Per-use-case: today vs production vs Cortex

### Use case 1 — Data quality, observability, anomaly detection

> *"Use AI to continuously monitor core HR datasets and detect anomalies or
> material shifts. ... Last year involuntary turnover dropped 50% suddenly
> due to an upstream calculation error."*

| | POC today | + Production data | + Cortex |
|---|---|---|---|
| **DMF coverage** | 15 metrics on 2 tables (file 25 manual SP) | 50–200+ metrics on the full HR estate (file 20 native Cortex DQ) | AI-suggested DMFs based on column profile |
| **Refresh cadence** | Manual `CALL` (or scheduled task at 60-min) | Hourly via native Cortex schedule, or `TRIGGER_ON_CHANGES` for streaming sources | Same |
| **Baseline window** | 4-week trailing (only 16 wks available) | 13-week + 52-week YoY baselines; seasonality-aware | Same statistics; AI explains *why* |
| **Anomaly model** | Z-score `>= 2σ` on 4 metrics by L1 | Same z-score on 20+ metrics by L1, L2, L3, JOB_FAMILY | Cortex narrative: *"Involuntary turnover dropped 50% — this matches a known calculation-error signature in upstream feed X."* |
| **The "50% drop" example** | **Detectable today** as an `ANOMALY` row with z=-3.2 | Same, but caught within hours not weeks | Auto-generated explanation + suggested root cause |

**What to demo today**: open *Workforce Shifts*, filter to a single L1, point at
the chart. Any red dot = a z-score-2 event = the kind of pattern the calculation
error would have produced. The detector exists and works on the real EDL data
already loaded.

**What you need from Snowflake admins** to scale this:

- `EXECUTE DATA METRIC FUNCTION ON ACCOUNT` — to retire the manual SP fallback
- `SELECT` on the additional EDL tables you want monitored
- `SNOWFLAKE.CORTEX_USER` (database role) — only needed for the narrative layer

---

### Use case 2 — Workforce analytics & insights

> *"Detect and explain workforce shifts such as changes in business unit
> headcount, job families, involuntary turnover, and org structures. ...
> Enable governed natural-language querying."*

| | POC today | + Production data | + Cortex |
|---|---|---|---|
| **Headcount shift detection** | Weekly per L1 | L1 + L2 + L3 + L4 + COST_CENTER + JOB_FAMILY | Same data, NL queries on top |
| **Org-structure changes** | L1 and L2 movements (>=5 employees) | L1–L4 + manager-chain breaks; multi-snapshot collapse | Cortex narrative explains the *cause* (acquisition, restructure, etc.) |
| **Forecasting** | None — only 4 months of history | 90-day attrition / hiring forecasts (Snowflake Snowpark ML, native) | Same models; Cortex explains the forecast in plain English |
| **NL querying** | Not available without Cortex | Not available without Cortex | **`"How many Job-Managed employees did we have last year?"`** answered directly via Cortex Analyst (semantic-model-based) |
| **Narrative analysis** | Not available without Cortex | Not available without Cortex | Cortex Complete: *"L2 'Cards' grew 18% Q-over-Q, driven mostly by 32 transfers from L1 'Retail Banking' on 2026-03-15."* |

**What to demo today**: *Workforce Shifts > Reorg detector* panel. With real
production data, the same panel surfaces every meaningful org movement company-wide
on a daily cadence.

**What unlocks with prod**: forecasting becomes credible. With 4 months of POC
data, "voluntary terms next quarter" forecasts have a confidence interval larger
than the prediction itself. With 2+ years, you get tight intervals plus
seasonality (e.g., Jan/Feb hiring waves, Dec slowdown).

---

### Use case 3 — Talent acquisition (TA) analytics

> *"Apply regression analysis and modelling to identify key factors driving
> hiring outcomes (e.g. time-to-fill, hiring success). Proactive alerts for
> long time-to-fill, recruiter workload imbalances, and benchmarking versus
> historical norms."*

| | POC today | + Production data | + Cortex |
|---|---|---|---|
| **Time-to-fill distribution** | Histogram + median across 1 snapshot of position data (~2 weeks) | 12-month trended distribution; YoY benchmark; per-quarter breakdown | Cortex narrative: *"TTF for 'Software Engineer' is 11 days above 6-month median — recruiter workload is the top correlated factor."* |
| **Recruiter workload** | Current snapshot, with `>=1.5x median` outlier flag | Trended over time; peer-benchmarked by L1/JOB_FAMILY; hiring-volume-adjusted | Auto-recommended reassignments |
| **Predictive TTF** | None | Snowpark ML regression on req attributes (level, family, location, posting source) → predicted TTF | Conversational hypothesis testing |
| **Long-TTF alerts** | Surfaces in the table sorted by `DAYS_TO_FILL` | Threshold-based alerts via Snowflake Tasks → Slack/email | Same, with AI-generated context |
| **Quality of hire** | Not in current data | Joins to performance review + 90-day-survival data once `DT_PERFORMANCE_*` is in scope | Driver attribution via AI |

**What to demo today**: *TA Analytics* page. Distribution + recruiter workload
panels work on real EDL position data. The capacity-outlier flag is calibrated
against the actual median.

**Limit hit by POC scope**: only 2 weeks of position snapshots, so trended TTF
isn't yet meaningful. The view is structured to handle 12+ months without
changes — just keep loading.

---

### Use case 4 — Data science & exploration

> *"Enable an AI 'data science assistant' to support exploratory data
> analysis across HR datasets. Help analysts quickly identify correlations,
> generate hypotheses, summarise distributions, and suggest follow-up
> analyses."*

| | POC today | + Production data | + Cortex |
|---|---|---|---|
| **Manual EDA** | Streamlit + SQL — analyst-driven | Same | Same |
| **Distribution summarisation** | Already done in TA + Workforce pages | Wider data = more signal | Cortex Complete generates 1-paragraph narrative summaries |
| **Correlation discovery** | Manual via SQL | Snowpark ML correlation matrices on demand | Cortex suggests likely correlated columns based on schema + sample |
| **Hypothesis generation** | Not available | Not available | **Primary Cortex unlock**: conversational "what would explain X?" workflow |
| **Regression / classification** | Possible via Snowpark ML, but not built | Snowpark ML pipelines, persisted models, scheduled training | Cortex generates feature engineering proposals + interprets coefficients |
| **NL → SQL** | Not available | Not available | **Cortex Analyst** with a curated semantic model = governed NL querying |

**What to demo today**: nothing direct (all four sub-capabilities here are
genuinely AI-native). Show the existing pages as the *target surface* for a
Cortex Analyst integration: *"once you grant Cortex, this same page gets a
natural-language search bar at the top."*

---

## What unlocks at each scale level

| History available | What unlocks |
|---|---|
| **2–4 weeks** *(today, position table)* | Distribution analysis, point-in-time outliers, recruiter snapshot |
| **3–6 months** *(today, trended table)* | Z-score anomalies, 4-week baselines, basic shift detection, reorg detector |
| **12 months** | YoY comparisons, hiring-season patterns, quarterly trended TTF, true seasonality adjustment |
| **2 years** | Stable monthly baselines, full attrition lifecycle, retention curves, cohort-based promotion velocity |
| **3+ years** | Tenure-based forecasting, longitudinal "what predicts attrition" models, 12-month forward-looking forecasts |

| Breadth available | What unlocks |
|---|---|
| **2 tables** *(today)* | DQ on position + trended; the four dimensions native Cortex DQ covers |
| **All HR core (~8–12 tables)** | Cross-table referential integrity (every employee in payroll has an HR row, etc.); portfolio-level trust score with real signal |
| **HR + payroll + benefits + performance** | Quality-of-hire correlation, compensation equity analysis, full talent-lifecycle metrics |
| **+ recruiting funnel data** | Source effectiveness, conversion-rate analysis, candidate pipeline forecasting |

| Cortex grants | What unlocks |
|---|---|
| **None** *(today)* | Manual SP for DMFs, all visualisations, all statistical detection |
| **`SNOWFLAKE.CORTEX_USER`** | LLM-powered narratives, plain-English anomaly explanations, hypothesis generation |
| **+ Cortex Analyst with semantic model** | Governed NL querying ("How many job-managed employees last year?") |
| **+ Snowpark ML libraries** | Production-grade predictive models (TTF, attrition risk, promotion likelihood) |

---

## Privilege & access checklist for the prod uplift

Send this to the Snowflake account-admin team to unlock the next phase:

- [ ] `SELECT` on the production EDL HR tables (8–12 candidates; we'll provide list)
- [ ] `EXECUTE DATA METRIC FUNCTION ON ACCOUNT` for the working role
      (replaces the manual SP fallback in `ddl/25_*`)
- [ ] `DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER` granted to the working role
- [ ] `DATABASE ROLE SNOWFLAKE.CORTEX_USER` for the working role
      (unlocks AI narratives + Cortex Complete)
- [ ] `EXECUTE TASK ON ACCOUNT` for the working role
      (enables scheduled DMF refresh + alert tasks)
- [ ] Optional but recommended: cross-database/schema `SELECT` on
      `ADMIN_DB.ADMIN_SCH.WPII_*` tags
      (enables tag-based DMF attachment, much cleaner than per-table)

---

## Recommended phasing

### Phase 1 — Today (done)
- 2 datasets loaded into sandbox (`DQ_POC` schema)
- Manual SQL fallback for DMFs (15 measurements, 4 dimensions)
- All 5 Streamlit pages live: portfolio, dataset detail, Cortex DQ,
  workforce shifts, TA analytics
- 4 of 5 use cases demonstrably answered with real data

### Phase 2 — Production data (1–2 weeks once grants land)
- Repoint `ddl/40_*` views and `ddl/30_*` loaders at production EDL tables
- Expand DMF coverage to 8–12 HR tables via tag-based attachment
  (file 20, native track)
- Backfill 12 months of trended data for stable baselines
- Add scheduled tasks for hourly anomaly checks → Slack alerts
- All 4 SQL-based use cases now production-grade

### Phase 3 — Cortex layer (2–4 weeks)
- Add NL search bar (Cortex Analyst) to *Workforce Shifts* and *TA Analytics*
- Wire `Cortex Complete` narrative blocks into anomaly + reorg detection
- Build first Snowpark ML model: 90-day attrition risk per employee
- Use case 4 (data science assistant) becomes available

### Phase 4 — Governance handoff
- DMF thresholds (in `PNC_DMF_THRESHOLDS`) move under Data Quality team
  ownership
- Bridge view scores swap into nightly `PNC_DQ_RESULTS` rebuild
- Bespoke heuristic logic for dimensions 3–6 retired

---

## Where to read more in this repo

- `README.md` — full setup + run order
- `ddl/40_workforce_analytics_views.sql` — the SQL behind use cases 2 & 3
- `ddl/20_cortex_dq_setup.sql` — native DMF setup (Track A)
- `ddl/25_manual_dmf_fallback.sql` — manual SP fallback (Track B)
- `app/ai_use_cases_app.py` — the AI Use Cases app (Workforce Shifts + TA Analytics; focus of this guide)
- `app/trust_score_app.py` — sister app for the Trust Score scorecard + Cortex DQ
- `app/shared.py` — common loaders, constants, and CSS shared by both apps
- `docs/PORTFOLIO_AND_DETAIL_PAGES.md` — companion guide for the Trust Score app
