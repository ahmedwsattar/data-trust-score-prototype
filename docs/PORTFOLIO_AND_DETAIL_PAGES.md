# Portfolio Scorecard & Dataset Detail — User Guide

The two flagship pages of the **Trust Score app**
(`app/trust_score_app.py`) are the **executive surface** and the
**practitioner drill-down**. Both are driven by the same underlying
tables (`PNC_DQ_RESULTS` + the four registries), but they're tuned for
different audiences and different decisions.

> The Trust Score app also includes a **Cortex DQ** page (the live DMF
> measurement engine for dimensions 3-6) and a **Methodology & Weights**
> reference page — both rooted in the trust framework.
>
> The applied-analytics pages (Workforce Shifts, TA Analytics) live in
> a sister app — see `app/ai_use_cases_app.py` and
> `docs/REAL_DATA_OPPORTUNITIES.md`.

| Page | Audience | Decision it supports |
|---|---|---|
| **Portfolio Scorecard** | EDAI leadership, governance, business consumers of the scorecard | "Where do we have the worst data trust risk across our portfolio, and which domains drag the average down?" |
| **Dataset Detail** | Data stewards, owners, engineering on-call | "Why is *this* specific dataset scoring where it is, and what one thing should I fix to move its tier?" |

Both pages share the same sidebar filters (Domain, Tier, as-of date) so a
filter set applied on the portfolio carries through to the drill-down.

---

## Common: the 10-dimension framework these pages render

Every score on either page rolls up to one of the 10 trust dimensions defined
in `02_Discovery_Reuse_Assessment_Data_Trust_Score.docx` (May 2026):

| # | Dimension | Source in this prototype | What it measures |
|---|---|---|---|
| 1 | Data Ownership | `PNC_DATA_OWNERSHIP_REGISTRY` (net-new) | Is there a named owner + steward? Are assignments current? |
| 2 | Data Source | `PNC_SOURCE_CLASSIFICATION` (net-new) | Source-system tier, SLA, load cadence |
| 3 | Active Issues | `PNC_DQ_RESULTS` (extended) **or** Cortex DMFs | Open P1/P2/P3 issues, count of failing checks |
| 4 | Timeliness | `PNC_DQ_RESULTS` (extended) **or** `FRESHNESS(LOADDATE)` DMF | Hours late vs SLA |
| 5 | Completeness of Key Properties | `PNC_DQ_RESULTS` (extended) **or** `NULL_PERCENT` DMF | % null on registered key columns |
| 6 | Data Profiling | `PNC_DQ_RESULTS` (extended) **or** all-DMF pass rate | % of attached DMFs passing thresholds |
| 7 | Data Definitions | net-new (registry flag) | % of fields with an approved business definition |
| 8 | Key Properties | `PNC_KEY_PROPERTY_REGISTRY` (net-new) | Are key fields registered, present in schema, validated? |
| 9 | Usage | `PNC_USAGE_TELEMETRY` (Phase 2) | Query frequency, user diversity |
| 10 | User Feedback | `PNC_USER_FEEDBACK` (Phase 2) | Stewardship signals from consumers |

The overall **Trust Score** is the weighted average; weights live in
`PNC_TRUST_SCORE_WEIGHTS` so governance can tune them without code changes.

### Tier and status thresholds

These are applied identically on both pages:

| Overall Tier | Score range | Color used in pills, gauges, tier ranking |
|---|---|---|
| GOLD | ≥ 85 | gold (`#C9A227`) |
| SILVER | 70 – 84 | silver-grey (`#9BA4B5`) |
| BRONZE | 50 – 69 | bronze-tan (`#B07A3D`) |
| AT_RISK | < 50 | red (`#C44545`) |

| Per-dimension Status | Score range |
|---|---|
| GREEN | ≥ 80 |
| AMBER | 60 – 79 |
| RED | < 60 |

The heatmap and dimension breakdown use a continuous **blue → teal → yellow**
gradient (defined in `SCORE_COLOR_SCALE`) — readable in dark mode, and
consistent with the Cortex DQ + workforce pages.

---

## Page 1 — Portfolio Scorecard

### What it answers in 30 seconds

Open the page and you should be able to answer, without scrolling:

1. How many datasets are we monitoring, and what's the average trust score?
2. How many are in the "investigate now" tier (At-Risk)?
3. How many open P1 issues are outstanding across the portfolio?
4. Which dataset is the worst overall? Which dimension is its weakest?
5. Which domain is dragging the average down?

### Panel-by-panel

#### 1. KPI strip (top of page)

Five compact cards in a single row:

| Card | Source | Notes |
|---|---|---|
| **Datasets in scope** | `dq_latest['DATASET_ID'].nunique()` | Respects sidebar filters |
| **Avg Trust Score** | mean of `TRUST_SCORE_OVERALL` | Float, 1 decimal |
| **Gold tier** | count where `TRUST_SCORE_TIER = 'GOLD'` | |
| **At-Risk tier** | count where `TRUST_SCORE_TIER = 'AT_RISK'` | Inverse delta-color (red = bad) |
| **Open P1 issues (sum)** | sum of `DIM_ISSUES_OPEN_P1` | Inverse delta-color |

These are the numbers you'd put in a status email. They re-compute live as
you change the Domain / Tier filters in the sidebar.

#### 2. 10-dimension heatmap

The main visual on the page. One row per dataset, one column per dimension.
Cell color = score, with the number printed inside the cell:

- **Brightest yellow** (≥ 90) means strong; text inverts to dark for legibility
- **Mid teal** (60 – 80) is the warning band
- **Dark blue** (< 50) is the AT_RISK band

How to read it:

- **Scan vertically** to find the worst dataset (a dark row)
- **Scan horizontally** to find the weakest dimension (a dark column)
- **Spot dark clusters** to see if a particular domain has structural issues
  in a specific dimension family (e.g., the Talent domain underperforming
  on Ownership across all 4 of its datasets = a process gap, not a
  one-dataset problem)

Hover any cell for an exact tooltip (`Dataset / Dimension / Score`).

#### 3. Data Sources mini-list

A compact key alongside the heatmap's y-axis (right side). Just the dataset
name + domain, sorted alphabetically. It exists because the heatmap labels
can be truncated on narrow screens; this gives an unambiguous reference.

#### 4. Trust tier ranking

A sortable, paginated table below the heatmap. Columns:

| Column | Source | UI control |
|---|---|---|
| Dataset | `DATASET_NAME` | Plain text |
| Domain | `DOMAIN` | Plain text |
| Score | `TRUST_SCORE_OVERALL` | Progress bar 0–100 |
| Tier | `TRUST_SCORE_TIER` | Tag |
| P1 issues | `DIM_ISSUES_OPEN_P1` | Number |
| Hours late | `DIM_TIMELINESS_HOURS_LATE` | Number, 1 decimal |

Sorted by Score descending by default. Click any column header to re-sort
(Streamlit native). Use this when the question is "give me the ranked list
to triage" — the heatmap is for spotting patterns, this is for sequencing
work.

#### 5. Average score by dimension and domain

A faceted bar chart at the bottom: one small chart per dimension, with a
bar per domain inside it.

What it tells you:

- **Stripe pattern** (each dim has the same domain on top) means trust
  varies by *domain*, not by dimension — a governance problem in the
  weakest domain
- **Dimension-by-dimension swings** (different domain wins different dims)
  means trust varies by *capability* — different teams are good at
  different parts of the framework
- **Tall single bars in dim 9 (Usage) or 10 (Feedback)** are normal in the
  current build because both are Phase 2 and use placeholder values

### Filters that affect this page

Sidebar:

- **Domain (multi-select)** — restricts the dataset population
- **Tier (multi-select)** — restricts to e.g. "show me only AT_RISK + BRONZE"
- The displayed as-of date is `MAX(SCORE_RUN_DATE)` from `PNC_DQ_RESULTS`;
  trends use the full history but the page itself always renders the latest
  snapshot

### Common workflows on this page

1. **"Where do I focus this week?"** — set Tier filter to {AT_RISK, BRONZE},
   read the tier ranking table top-down. The first 3 rows are your queue.
2. **"Is dimension X a portfolio-wide problem?"** — look at the heatmap
   column for X. If the whole column is dark, it's a framework issue (e.g.,
   no one has registered key properties yet). If only one row is dark,
   it's dataset-specific.
3. **"Is domain Y systematically weaker?"** — look at the domain bar chart.
   If Y is at the bottom of more than half the dimension panels, raise it
   in the next governance review.
4. **"Walking into an exec readout"** — KPI strip + heatmap screenshot is
   the answer. Tier ranking is the appendix.

### Where the code lives

`app/trust_score_app.py` → `render_portfolio()`.
Underlying loaders (in `app/shared.py`): `load_dq_results()`,
`load_ownership()`, `load_source_classification()`, `load_keys()`.

---

## Page 2 — Dataset Detail

### What it answers in 30 seconds

Pick a dataset and you should be able to answer:

1. Who owns it? Is the assignment current?
2. What's its overall trust score and tier?
3. Which one or two dimensions are pulling the score down?
4. Has the score been improving or degrading over the last 90 days?
5. Are the registered key properties present and populated?

### Panel-by-panel

#### 1. Dataset selector

A standard selectbox listing every dataset in the (filtered) portfolio.
Pick one to populate the rest of the page. Sidebar filters still apply, so
if you've narrowed Tier to AT_RISK in the sidebar, only AT_RISK datasets
appear in the selector.

#### 2. Header card (left side)

| Line | Source | Purpose |
|---|---|---|
| Dataset name (h3) | `DATASET_NAME` | Identity |
| FQN · Domain · Layer (small caption, neon green) | `DATASET_FQN`, `DOMAIN`, `LAYER` | Where the table lives in Snowflake |
| **Owner**, **Steward**, **Status** | `PNC_DATA_OWNERSHIP_REGISTRY` | Accountability — bold "**unassigned**" if missing |
| **Source system**, **Tier**, **SLA**, **Cadence** | `PNC_SOURCE_CLASSIFICATION` | Where the data comes from + governance commitment |

If either registry has no row for this dataset, the corresponding line is
silently omitted — that itself is a signal that the dataset is missing
metadata.

#### 3. Trust Score gauge + tier pill (right side)

A single large `st.metric("Trust Score", "{score} / 100")` plus a custom
horizontal score bar with the tier color filling the bar to score%, capped
by a tier pill below (color matches the bar).

The bar provides an immediate visual: a half-empty bronze bar tells the
same story as a long script of words.

#### 4. Dimension breakdown table

The 10 dimensions in framework order, with:

| Column | Source |
|---|---|
| Dimension | name |
| Code | `DIMENSION_CODE` |
| Weight % | from `PNC_TRUST_SCORE_WEIGHTS` (config-driven) |
| Score | from the per-dimension column on `PNC_DQ_RESULTS` |
| Status | from the per-dimension `_STATUS` column (GREEN/AMBER/RED) |

Score column is rendered as a 0–100 progress bar so you can spot the weak
dimensions visually without reading the numbers.

This panel is the *answer* to "which dimension is the problem?". The
weight column matters — a 60 in a 5%-weighted dim moves the overall score
much less than a 60 in a 20%-weighted dim. Pair the two columns mentally
when prioritising.

#### 5. 90-day trend (overall)

A single line chart: `TRUST_SCORE_OVERALL` over `SCORE_RUN_DATE`.
Horizontal dashed reference lines at 85 (GOLD floor), 70 (SILVER floor),
and 50 (BRONZE floor) coloured to match the tier pills.

How to read it:

- **Crossing a reference line** = a tier change event (worth a steward
  conversation)
- **Steady line near a tier floor** = "one bad week away from a downgrade"
- **Sawtooth pattern** = scoring is sensitive to a single noisy dimension;
  look at the per-dimension trend below to identify which one

#### 6. Per-dimension trend (single-select)

A selectbox lets you pick one dimension; the chart below shows that
dimension's score over time. Reads from `PNC_DQ_DIMENSION_RESULTS` (the
narrow companion table that stores one row per dataset × dimension × date).

When a dimension's status flips from GREEN → AMBER → RED, this is the
chart you'd put in a postmortem.

#### 7. Active issues panel (left, below the trend)

Three stacked metric cards:

- Open P1 (`DIM_ISSUES_OPEN_P1`)
- Open P2 (`DIM_ISSUES_OPEN_P2`)
- Open P3 (`DIM_ISSUES_OPEN_P3`)

Plus a caption with the timestamp of the most recent failure
(`DIM_ISSUES_LAST_FAILURE_AT`).

This panel is the bridge to your Active Issues / on-call surface — these
are the same numbers that drive the Active Issues dimension score.

#### 8. Key property profiling (right, below the trend)

The most data-rich table on the page. One row per registered key field for
this dataset, from `PNC_KEY_PROPERTY_REGISTRY`. Columns:

| Column | Source | Conditional formatting |
|---|---|---|
| Field | `KEY_FIELD_NAME` | — |
| Role | `KEY_FIELD_ROLE` | — |
| Required | `IS_REQUIRED` | Yes = green pill, No = red pill |
| In schema | `IS_PRESENT_IN_SCHEMA` | Yes/No green/red |
| Has definition | `HAS_APPROVED_DEFINITION` | Yes/No green/red |
| Null % | `NULL_PCT` × 100 | Green < 5%, amber 5–20%, red ≥ 20% |

A red cell in any column = something a steward should fix:

- "Required + No in schema" = **breaking** — the field is on the registry
  but missing from the actual table
- "Required + No has-definition" = **definition gap** — registered without
  an approved business glossary entry
- "Null % red" = **completeness gap** — even though the column exists,
  most rows don't populate it

If no key registry rows exist, the panel shows an info message — that
itself becomes a signal you can act on (the dataset isn't covered by the
key-property framework yet).

### Filters that affect this page

The sidebar Domain / Tier filters scope the **selector** above. As-of
date is whatever `MAX(SCORE_RUN_DATE)` is in the underlying data; the
trend panels use the full history regardless.

### Common workflows on this page

1. **"Why is this dataset Bronze?"** — read the Dimension breakdown table.
   The 1 or 2 rows with red Score bars are the answer.
2. **"Did our steward changes from last month help?"** — look at the
   90-day trend. An upward slope after the change date confirms it.
3. **"What single fix would move this dataset to Silver?"** — combine
   Dimension breakdown + weights. Find the highest-weight dimension with
   the largest gap to GREEN; that's the fix with the biggest expected ROI.
4. **"Are our key properties really being captured?"** — look at the Key
   property profiling panel. Any red cell = work item.
5. **"Need to write the dataset writeup"** — header card + tier pill +
   dimension table screenshots are 80% of the writeup; trend chart is the
   "movement over time" paragraph.

### Where the code lives

`app/trust_score_app.py` → `render_detail()`. Helper:
`tier_color_for()` (in `app/shared.py`) for the tier-pill color logic.
Underlying loaders (also in `shared.py`): `load_dq_results()`,
`load_dq_dimension_results()`, `load_ownership()`,
`load_source_classification()`, `load_keys()`, `load_weights()`.

---

## How the two pages work together — the drill-down pattern

The intended workflow is:

1. Open **Portfolio Scorecard**. Spot the AT_RISK dataset / weak dimension
   on the heatmap.
2. Note the dataset name from the tier ranking table.
3. Switch to **Dataset Detail** in the sidebar selectbox.
4. Pick the same dataset; the detail page is now scoped to it.
5. The Dimension breakdown table tells you *which* dimension to fix.
6. The 90-day trend tells you whether it's a new regression or a chronic
   issue.
7. The Key property profiling table (and the Active issues panel) tells
   you the *concrete* work items to file.

Sidebar filters carry between pages, so if you set `Tier = AT_RISK` on
Portfolio and switch to Detail, only AT_RISK datasets will be in the
selector — keeps the drill-down focused.

---

## Underlying data model — quick reference

Both pages read from these tables (Snowflake) or CSVs (local dev):

| Table | Granularity | Used by |
|---|---|---|
| `PNC_DQ_RESULTS` | 1 row per dataset × score-run-date (wide) | Both pages — the scorecard surface |
| `PNC_DQ_DIMENSION_RESULTS` | 1 row per dataset × dimension × date (narrow) | Detail page — per-dim trend |
| `PNC_DATA_OWNERSHIP_REGISTRY` | 1 row per dataset | Detail page header |
| `PNC_SOURCE_CLASSIFICATION` | 1 row per dataset | Detail page header |
| `PNC_KEY_PROPERTY_REGISTRY` | 1 row per dataset × key field | Detail page key-property panel |
| `PNC_TRUST_SCORE_WEIGHTS` | 1 row per dimension | Detail page dimension breakdown (weight column) |

**Key principle**: `PNC_DQ_RESULTS` is *extended* (not replaced) from its
production form — see the Reuse Assessment doc for context. The 6
dimensions sourceable from existing data become columns on this table; the
4 net-new dimensions come from the registries above. Both pages are
agnostic to *how* a dimension's score got there — they just read it.

### Where Cortex DMF measurements fit in

When the Cortex DQ track is enabled (`ddl/20_*` or `ddl/25_*`), the
DMF-derived scores for dimensions 3, 4, 5, 6 land in
`VW_PNC_DMF_DIMENSION_SCORES`. The Cortex DQ page surfaces them
side-by-side with the synthetic ones; once governance signs off, the plan
is to swap them into `PNC_DQ_RESULTS` via a nightly task. At that point,
both Portfolio and Detail pages render real measurement data for those
four dimensions automatically — no code changes.

---

## Customisation points

Things you'll likely want to adjust per environment:

| Want to change | File / object | Notes |
|---|---|---|
| Tier thresholds (Gold ≥ 85 etc.) | `PNC_TRUST_SCORE_WEIGHTS` semantics + `tier_color_for()` in `app/shared.py` | Currently hardcoded in the helper; could be moved to config |
| Per-dimension status thresholds (Green ≥ 80 etc.) | `_STATUS` column population in `PNC_DQ_RESULTS` | Computed upstream; status is read as a string |
| Dimension weights | `PNC_TRUST_SCORE_WEIGHTS` table | Page reads live, no redeploy needed |
| Heatmap color ramp | `SCORE_COLOR_SCALE` constant in `app/shared.py` | Single edit propagates to heatmap, dimension breakdown, TA bar chart |
| Sidebar filters | sidebar block in `app/trust_score_app.py` | Add another `multiselect` if you want e.g. Layer or Owner filters |
| Dataset selector ordering | `sorted(...)` in `render_detail()` | Currently alphabetical; could sort by tier or score |

---

## Where to read more

- `README.md` — full setup + run order
- `docs/REAL_DATA_OPPORTUNITIES.md` — what these pages become with
  production-scale data and Cortex grants
- `02_Discovery_Reuse_Assessment_Data_Trust_Score.docx` (May 2026) — the
  source framework these pages implement
- `app/trust_score_app.py` — the Trust Score governance app (the focus
  of this guide)
- `app/ai_use_cases_app.py` — sister app with Cortex DQ + Workforce
  Shifts + TA Analytics (operational analytics)
- `app/shared.py` — common loaders, constants, and CSS shared by both apps
