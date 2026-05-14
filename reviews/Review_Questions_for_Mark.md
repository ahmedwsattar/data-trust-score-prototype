# Data Trust Score — Review Questions for the Author

**For:** Mark Risis (EDAI Executive Sponsor, author)
**From:** Ahmed Sattar (Data Solutions, EDAI)
**Re:** `01a_Discovery_Opportunity_Brief`, `02_Discovery_Reuse_Assessment`, `03_Design_Product_Charter`
**Date:** May 2026

---

The three artifacts hang together cleanly — the Brief frames the problem and the 10-dimension framework, the Reuse Assessment grounds it in what P&C actually has today, and the Charter narrows MVP to the three live datasets. Most of my open questions are operational and the team can work them. The eight below are the ones where your view as author and executive sponsor is what unlocks the next phase. The first one is the strategic anchor — every other answer flows from it.

---

## Top 8 questions

### 1. Org-wide data trust platform — Informatica or Snowflake (or both, with a seam)?
This is the question that frames everything else, and it's where I'd most want your read before we go further. The two real candidates for an enterprise data-trust capability are **Informatica** (IDMC / IDQ — platform-agnostic, mature rule library, strong stewardship workflow, battle-tested for SOX/HIPAA, but a 6–12 month rollout, significant license, and another platform to operate) and **Snowflake Cortex DQ** (native to where most of our data already lives, AI-suggested DMFs, near-zero time-to-value, cost is just compute — but Snowflake-only, newer, and no built-in stewardship workflow).

In most enterprises the honest answer is "both, layered" — Cortex DQ as the measurement engine for Snowflake-resident data, Informatica for cross-system semantic rules and stewardship workflow, and a unifying surface (the Trust Score itself) that abstracts where measurements come from. What changes per org is *where the seam goes*. The five things that move the seam:

- **Where the data lives** — if ~80%+ of WBD's analytical data is already in Snowflake (which the EDL story suggests for P&C), Cortex DQ does a lot of the job for free; if a meaningful share sits in Oracle, mainframe, files, or pre-ingestion, Informatica becomes hard to avoid
- **Existing investment** — are we already paying for Informatica licenses anywhere in WBD, or is this greenfield?
- **Architecture stance** — is Snowflake the strategic platform of record, or are we deliberately multi-warehouse?
- **DQ scope** — technical metrics (null %, freshness, distribution) → either platform; cross-system business rules, address validation, semantic checks → Informatica is materially stronger today
- **Workflow vs measurement** — if "trust" is fundamentally a *measurement* problem to you, Snowflake wins on speed and cost; if it's a *stewardship and accountability* problem, Informatica's workflow layer matters

**Looking for:** your view on which platform anchors org-wide data trust at WBD, where the seam should sit, and what role you'd see for the Trust Score product within that stack. This decision sets the architecture for question 4 (Cortex DQ in MVP) and frames question 8 (relationship to other enterprise DQ initiatives).

### 2. What does success look like to you at MVP launch?
The Charter lists six success criteria, but they're a mix of delivery checkboxes ("3 datasets scored") and adoption targets ("3 consumers self-serving"). Knowing which of these you'd actually point to in a leadership review would help us prioritize where to spend the last 20% of effort.
**Looking for:** the one or two outcomes that make this a credible Q3 launch in your eyes — versus the ones where "good enough" is fine.

### 3. Enterprise scope — what's the trigger, and how soon?
The Charter is explicit that P&C-only is intentional for MVP, with enterprise generalization as a post-MVP leadership decision requiring your alignment with domain leads. That decision casts a long shadow on design choices we're making now (the ownership registry, source classification table, and methodology governance all look very different at one-domain vs. enterprise scale).
**Looking for:** what would tip you toward "make this the EDAI standard" — number of certified P&C datasets, a leadership ask, a date — and how much of the enterprise design we should bake in now vs. defer.

### 4. Methodology authority — who owns it across domains?
The Charter says weight or gate-definition changes need "Product Owner sign-off and a documented changelog," with Ella as Product Owner. That works at P&C scale. If this becomes the enterprise standard (per question 3), the Product Owner of the P&C MVP probably shouldn't unilaterally control methodology for the Finance or Tech domains.
**Looking for:** your view on the long-term governance model — does methodology authority sit with EDAI Data Governance, with a cross-domain council, or stay product-owner-led?

### 5. Cortex Data Quality in MVP — yes, optional, or hold?
Flowing from question 1: even if we don't lock the org-wide platform decision today, we need a stance for MVP. Snowflake shipped the Cortex DQ catalog UI in May, and four of our ten dimensions (Active Issues, Timeliness, Completeness, Profiling) are derivable directly from native DMFs. The prototype has a working interop layer for this; the Charter doesn't mention it.
**Looking for:** your read on whether we architect MVP for Cortex DQ as the measurement engine, treat it as optional reuse, or hold it back entirely until the platform decision in question 1 is made.

### 6. The MVP score is mathematically capped at ~95
Usage (3 pts) and User Feedback (2 pts) are deferred to Phase 2 and score 0 in MVP. Combined with realistic-case scoring on the other eight dimensions, no MVP dataset is likely to reach the Certified band (85+). That's a perception problem the moment we publish — consumers will read "no datasets are Certified" as a quality story rather than a Phase 2 deferral story.
**Looking for:** are you comfortable launching with a band ladder that's effectively `Trusted` at the top, or should the band thresholds be adjusted for MVP and revised again at Phase 2?

### 7. Resourcing and capacity — is the build team named?
The Charter lists Engineering Lead, Architecture Lead, and Data Governance Lead as `TBD`, with several MVP dependencies marked `⚠ Not started` (PNC_DQ_RESULTS extension, ownership registry, source classification, issues register). The Q3 Build target only works if those leads are named soon and the dependencies enter someone's backlog.
**Looking for:** your read on whether we have committed capacity for Q3, or whether the Charter timeline needs a softer target until those roles are filled.

### 8. Relationship to other enterprise DQ initiatives
The Brief calls out alignment with the Enterprise Data Quality Initiative and references early Informatica DQ conversations. From your vantage point you can see across these in a way the artifact authors lower down can't.
**Looking for:** is the Trust Score positioned to be *the* trust signal across these initiatives, a complement to them, or one of several? And is there overlap with anything else in flight that we should be deconflicting now rather than at Phase 2?

---

## What I'd suggest happens next

- **Anchor decision (you):** Informatica vs Snowflake (vs both) for org-wide data trust — question 1
- **You set direction on:** enterprise scope timing, methodology authority model, Cortex DQ in MVP, MVP band treatment (questions 3, 4, 5, 6)
- **You + Ella align on:** capacity / named leads and a defensible Q3 timeline (question 7)
- **You signal:** what success looks like and how this product relates to the broader EDAI DQ portfolio (questions 2, 8)

The operational items (steward assignment, weight confirmation with Paul and Perri, schema build dates, scoring scale per dimension, UAT consumer identification, appeals workflow) sit with Ella and the P&C sponsors — happy to drive those in parallel as Data Solutions partner so they aren't on your plate.
