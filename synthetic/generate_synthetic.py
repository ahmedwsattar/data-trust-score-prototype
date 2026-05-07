"""
Synthetic data generator for the Data Trust Score prototype.

Produces CSV files in ./data/ that mirror the DDL in ../ddl/. The Streamlit
app reads these the same way it would read the equivalent Snowflake views,
so swapping the data layer to a real connection later is a one-function
change.

Datasets covered (matches the May 2026 P&C inventory):
    1. DT_POSITION_REPORT
    2. STG_POSITION_REPORT_VW
    3. DT_TRENDED_REPORT
    4. STG_TRENDED_REPORT_VW
    5. TRAN_DT_WRKPLCTRNS_CONSOLIDATED
    6. DT_BEELINE_CONSO       (Pending FPA approval -- shows up but flagged)
    7. STG_BEELINE_WBD_WORKER (Pending FPA approval -- shows up but flagged)
"""

from __future__ import annotations

import os
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

RNG = np.random.default_rng(42)
TODAY = date(2026, 5, 6)
HISTORY_DAYS = 90


# --------------------------------------------------------------------------
# 1. Catalog of datasets (would be PNC_SOURCE_CLASSIFICATION in Snowflake)
# --------------------------------------------------------------------------

@dataclass
class DatasetSpec:
    dataset_id: str
    dataset_name: str
    fqn: str
    domain: str
    layer: str
    source_system: str
    classification_tier: str
    is_apm_registered: bool
    is_sox_relevant: bool
    load_frequency: str
    sla_hours: float
    # synthetic-quality knobs (these set the *true* underlying quality the
    # scorer will detect):
    base_quality: float                # 0..1, where 1 = excellent
    has_owner: bool
    owner_name: str | None
    steward_name: str | None
    has_definitions_pct: float         # % fields catalogued
    required_keys: list[str]
    present_keys: list[str]
    notes: str = ""


DATASETS: list[DatasetSpec] = [
    DatasetSpec(
        dataset_id="DS_POSITION_REPORT",
        dataset_name="Workday Position Report",
        fqn="EDLE_DW_DB.PNC_DATA.DT_POSITION_REPORT",
        domain="P&C",
        layer="SILVER",
        source_system="Workday",
        classification_tier="CORE",
        is_apm_registered=True,
        is_sox_relevant=True,
        load_frequency="WEEKLY",  # moving to daily per doc
        sla_hours=24 * 7,
        base_quality=0.86,
        has_owner=True,
        owner_name="Paul Field",
        steward_name="TBD - critical pre-Design gate",
        has_definitions_pct=0.55,
        required_keys=["TWID", "POSITION_ID"],
        present_keys=["TWID", "POSITION_ID"],
        notes="~815K rows, ~200 attributes",
    ),
    DatasetSpec(
        dataset_id="DS_POSITION_REPORT_VW",
        dataset_name="Position Report Public View",
        fqn="EDLE_PUBL_DB.PNC_DATA.STG_POSITION_REPORT_VW",
        domain="P&C",
        layer="VIEW",
        source_system="Workday",
        classification_tier="CORE",
        is_apm_registered=True,
        is_sox_relevant=True,
        load_frequency="WEEKLY",
        sla_hours=24 * 7,
        base_quality=0.84,
        has_owner=True,
        owner_name="Paul Field",
        steward_name=None,
        has_definitions_pct=0.55,
        required_keys=["TWID", "POSITION_ID"],
        present_keys=["TWID", "POSITION_ID"],
    ),
    DatasetSpec(
        dataset_id="DS_TRENDED_REPORT",
        dataset_name="Workday Trended Report",
        fqn="EDLE_DW_DB.PNC_DATA.DT_TRENDED_REPORT",
        domain="P&C",
        layer="SILVER",
        source_system="Workday",
        classification_tier="CORE",
        is_apm_registered=True,
        is_sox_relevant=False,
        load_frequency="MONTHLY",
        sla_hours=24 * 35,
        base_quality=0.78,
        has_owner=True,
        owner_name="Perri Ma",
        steward_name=None,
        has_definitions_pct=0.45,
        required_keys=["TWID", "POSITIONID"],
        present_keys=["TWID", "POSITIONID"],
        notes="Compensation explicitly excluded; IS_DELETED_FROM_FILE flag not surfaced as DQ signal",
    ),
    DatasetSpec(
        dataset_id="DS_TRENDED_REPORT_VW",
        dataset_name="Trended Report Public View",
        fqn="EDLE_PUBL_DB.PNC_DATA.STG_TRENDED_REPORT_VW",
        domain="P&C",
        layer="VIEW",
        source_system="Workday",
        classification_tier="CORE",
        is_apm_registered=True,
        is_sox_relevant=False,
        load_frequency="MONTHLY",
        sla_hours=24 * 35,
        base_quality=0.76,
        has_owner=True,
        owner_name="Perri Ma",
        steward_name=None,
        has_definitions_pct=0.45,
        required_keys=["TWID", "POSITIONID"],
        present_keys=["TWID", "POSITIONID"],
    ),
    DatasetSpec(
        dataset_id="DS_WORKPLACE_TRANSITION",
        dataset_name="Workplace Transition / RTO",
        fqn="EDLE_DW_DB.PNC_DATA.TRAN_DT_WRKPLCTRNS_CONSOLIDATED",
        domain="P&C",
        layer="SILVER",
        source_system="Workday + Badge (CCURE/DSX/RS2)",
        classification_tier="APM",
        is_apm_registered=True,
        is_sox_relevant=False,
        load_frequency="DAILY",
        sla_hours=36,
        base_quality=0.62,  # badge feed only partial sites
        has_owner=False,
        owner_name=None,
        steward_name=None,
        has_definitions_pct=0.40,
        required_keys=["TWID", "POSITION_ID", "BADGE_EVENT_TS"],
        present_keys=["TWID", "POSITION_ID", "BADGE_EVENT_TS"],
        notes="Badge coverage partial: CCURE, DSX, RS2, Atlanta, Hudson Yards only",
    ),
    DatasetSpec(
        dataset_id="DS_BEELINE_CONSO",
        dataset_name="Beeline Consolidated (FPA)",
        fqn="EDLE_DW_DB.FPA_DATA.DT_BEELINE_CONSO",
        domain="FPA",
        layer="SILVER",
        source_system="Beeline",
        classification_tier="APM",
        is_apm_registered=True,
        is_sox_relevant=False,
        load_frequency="DAILY",
        sla_hours=24,
        base_quality=0.70,
        has_owner=False,
        owner_name=None,
        steward_name=None,
        has_definitions_pct=0.35,
        required_keys=["EmployeeID", "CostCenter", "ManagerID"],
        present_keys=["EmployeeID", "CostCenter", "ManagerID"],
        notes="PENDING FPA data-owner approval",
    ),
    DatasetSpec(
        dataset_id="DS_BEELINE_WORKER",
        dataset_name="Beeline WBD Worker (FPA)",
        fqn="EDLE_PUBL_DB.FPA_DATA.STG_BEELINE_WBD_WORKER",
        domain="FPA",
        layer="VIEW",
        source_system="Beeline",
        classification_tier="APM",
        is_apm_registered=True,
        is_sox_relevant=False,
        load_frequency="DAILY",
        sla_hours=24,
        base_quality=0.68,
        has_owner=False,
        owner_name=None,
        steward_name=None,
        has_definitions_pct=0.35,
        required_keys=["EmployeeID", "CostCenter", "ManagerID"],
        present_keys=["EmployeeID", "CostCenter"],  # 1 key missing -> KP score < 100
        notes="PENDING FPA data-owner approval; ManagerID not in current view",
    ),
]


# --------------------------------------------------------------------------
# 2. Weights config
# --------------------------------------------------------------------------

WEIGHTS = pd.DataFrame(
    [
        ("OWNERSHIP",              "Data Ownership",                 12),
        ("SOURCE",                 "Data Source",                    10),
        ("ISSUES",                 "Active Issues",                  12),
        ("TIMELINESS",             "Timeliness",                     14),
        ("COMPLETENESS_KEY_PROPS", "Completeness of Key Properties", 14),
        ("PROFILING",              "Data Profiling",                 12),
        ("DEFINITIONS",            "Data Definitions",                8),
        ("KEY_PROPERTIES",         "Key Properties",                  8),
        ("USAGE",                  "Usage",                           6),
        ("FEEDBACK",               "User Feedback",                   4),
    ],
    columns=["DIMENSION_CODE", "DIMENSION_NAME", "WEIGHT_PCT"],
)
assert WEIGHTS["WEIGHT_PCT"].sum() == 100


# --------------------------------------------------------------------------
# 3. Score helpers
# --------------------------------------------------------------------------

def status_for(score: float, green: float = 80, amber: float = 60) -> str:
    if score >= green:
        return "GREEN"
    if score >= amber:
        return "AMBER"
    return "RED"


def tier_for(overall: float) -> str:
    if overall >= 85:
        return "GOLD"
    if overall >= 70:
        return "SILVER"
    if overall >= 50:
        return "BRONZE"
    return "AT_RISK"


# --------------------------------------------------------------------------
# 4. Generate the registries
# --------------------------------------------------------------------------

def build_source_classification() -> pd.DataFrame:
    rows = []
    for d in DATASETS:
        rows.append(dict(
            DATASET_ID=d.dataset_id,
            DATASET_NAME=d.dataset_name,
            DATASET_FQN=d.fqn,
            SOURCE_SYSTEM=d.source_system,
            SOURCE_DOMAIN=d.domain,
            LAYER=d.layer,
            CLASSIFICATION_TIER=d.classification_tier,
            IS_APM_REGISTERED=d.is_apm_registered,
            IS_SOX_RELEVANT=d.is_sox_relevant,
            LOAD_FREQUENCY=d.load_frequency,
            SLA_HOURS=d.sla_hours,
            UPDATED_AT=datetime.now(),
            UPDATED_BY="prototype",
        ))
    return pd.DataFrame(rows)


def build_ownership_registry() -> pd.DataFrame:
    rows = []
    for d in DATASETS:
        if d.has_owner and d.owner_name:
            status = "ASSIGNED" if d.steward_name and "TBD" not in d.steward_name else "PROVISIONAL"
            confirmed = TODAY - timedelta(days=int(RNG.integers(20, 220)))
        else:
            status = "UNASSIGNED"
            confirmed = None
        rows.append(dict(
            DATASET_ID=d.dataset_id,
            DATASET_NAME=d.dataset_name,
            DATASET_FQN=d.fqn,
            DOMAIN=d.domain,
            BUSINESS_OWNER_NAME=d.owner_name,
            BUSINESS_OWNER_EMAIL=(d.owner_name.lower().replace(" ", ".") + "@wbd.com") if d.owner_name else None,
            DATA_STEWARD_NAME=d.steward_name,
            DATA_STEWARD_EMAIL=(d.steward_name.lower().replace(" ", ".") + "@wbd.com")
                if d.steward_name and "TBD" not in d.steward_name else None,
            TECHNICAL_OWNER_NAME="Data Engineering",
            TECHNICAL_OWNER_EMAIL="data-eng@wbd.com",
            ASSIGNMENT_STATUS=status,
            LAST_CONFIRMED_DATE=confirmed,
            NEXT_REVIEW_DUE_DATE=(confirmed + timedelta(days=180)) if confirmed else None,
            NOTES=d.notes,
            UPDATED_AT=datetime.now(),
            UPDATED_BY="prototype",
        ))
    return pd.DataFrame(rows)


def build_key_property_registry() -> pd.DataFrame:
    rows = []
    for d in DATASETS:
        for key in d.required_keys:
            present = key in d.present_keys
            null_pct = float(np.clip(RNG.normal(loc=(1 - d.base_quality) * 0.15, scale=0.02), 0.0, 0.5)) if present else 1.0
            rows.append(dict(
                DATASET_ID=d.dataset_id,
                DATASET_NAME=d.dataset_name,
                KEY_FIELD_NAME=key,
                KEY_FIELD_ROLE="PRIMARY" if key in d.required_keys[:1] else "JOIN",
                IS_REQUIRED=True,
                IS_PRESENT_IN_SCHEMA=present,
                HAS_APPROVED_DEFINITION=bool(RNG.random() < d.has_definitions_pct),
                APPROVED_DEFINITION_TEXT=None,
                CATALOG_URL=None,
                LAST_PROFILED_AT=datetime.now() - timedelta(hours=int(RNG.integers(1, 30))),
                NULL_PCT=round(null_pct, 4),
                DISTINCT_COUNT=int(RNG.integers(1000, 800000)) if present else 0,
                ROW_COUNT=int(RNG.integers(50000, 900000)),
            ))
    return pd.DataFrame(rows)


# --------------------------------------------------------------------------
# 5. Generate score history (PNC_DQ_RESULTS) and pivot it (DIMENSION_RESULTS)
# --------------------------------------------------------------------------

def _drift(base: float, t: int, seed: int) -> float:
    """Add deterministic + random drift over time so trend charts look real."""
    rng = np.random.default_rng(seed + t)
    return float(np.clip(base + 0.05 * np.sin(t / 14) + rng.normal(0, 0.03), 0.0, 1.0))


def build_dq_results() -> tuple[pd.DataFrame, pd.DataFrame]:
    wide_rows = []
    long_rows = []
    weight_map = dict(zip(WEIGHTS["DIMENSION_CODE"], WEIGHTS["WEIGHT_PCT"] / 100.0))

    for d in DATASETS:
        seed = abs(hash(d.dataset_id)) % 100_000
        for day_offset in range(HISTORY_DAYS, -1, -1):
            run_date = TODAY - timedelta(days=day_offset)
            t = HISTORY_DAYS - day_offset
            q = _drift(d.base_quality, t, seed)

            # ---------- 1. Ownership ------------------------------------
            if d.has_owner and d.steward_name and "TBD" not in d.steward_name:
                own_score = 100.0
            elif d.has_owner:
                own_score = 60.0
            else:
                own_score = 0.0

            # ---------- 2. Source ---------------------------------------
            src_score = {"CORE": 100, "SOX": 90, "APM": 75, "UNCLASSIFIED": 25}[d.classification_tier]

            # ---------- 3. Active Issues --------------------------------
            open_p1 = int(max(0, RNG.poisson((1 - q) * 1.2)))
            open_p2 = int(max(0, RNG.poisson((1 - q) * 4)))
            open_p3 = int(max(0, RNG.poisson((1 - q) * 6)))
            issues_score = max(0.0, 100 - 10 * open_p1 - 3 * open_p2 - 1 * open_p3)
            last_failure = (
                datetime.combine(run_date, datetime.min.time())
                - timedelta(hours=int(RNG.integers(1, 200)))
            )

            # ---------- 4. Timeliness -----------------------------------
            hours_late = max(0.0, RNG.normal((1 - q) * d.sla_hours * 0.5, d.sla_hours * 0.1))
            ratio = hours_late / d.sla_hours if d.sla_hours else 0
            tim_score = float(np.clip(100 * (1 - ratio / 3), 0, 100))
            max_load = datetime.combine(run_date, datetime.min.time()) - timedelta(hours=hours_late)

            # ---------- 5. Completeness of Key Properties ---------------
            null_rates = []
            for key in d.required_keys:
                if key in d.present_keys:
                    null_rates.append(float(np.clip(RNG.normal((1 - q) * 0.1, 0.02), 0, 0.5)))
                else:
                    null_rates.append(1.0)
            worst_idx = int(np.argmax(null_rates))
            comp_score = float(np.clip(100 * (1 - max(null_rates)), 0, 100))

            # ---------- 6. Data Profiling -------------------------------
            checks_total = 24
            checks_passed = int(np.clip(RNG.normal(checks_total * q, 1.5), 0, checks_total))
            prof_score = 100 * checks_passed / checks_total

            # ---------- 7. Data Definitions -----------------------------
            fields_total = int(RNG.integers(40, 220))
            fields_defined = int(fields_total * d.has_definitions_pct + RNG.normal(0, 3))
            fields_defined = int(np.clip(fields_defined, 0, fields_total))
            def_score = 100 * fields_defined / fields_total

            # ---------- 8. Key Properties -------------------------------
            kp_score = 100 * len(d.present_keys) / len(d.required_keys)

            # ---------- 9. Usage (Phase 2) ------------------------------
            unique_consumers = int(max(0, RNG.normal(35 if d.layer == "VIEW" else 12, 6)))
            queries_30d = int(max(0, RNG.normal(unique_consumers * 40, 50)))
            usage_score = float(np.clip(100 * unique_consumers / 60, 0, 100))

            # ---------- 10. User Feedback (Phase 2) ---------------------
            avg_rating = float(np.clip(RNG.normal(2.5 + 2.0 * q, 0.4), 1.0, 5.0))
            responses = int(max(0, RNG.poisson(8)))
            fb_score = avg_rating * 20

            scores = {
                "OWNERSHIP": own_score,
                "SOURCE": src_score,
                "ISSUES": issues_score,
                "TIMELINESS": tim_score,
                "COMPLETENESS_KEY_PROPS": comp_score,
                "PROFILING": prof_score,
                "DEFINITIONS": def_score,
                "KEY_PROPERTIES": kp_score,
                "USAGE": usage_score,
                "FEEDBACK": fb_score,
            }
            overall = sum(scores[c] * weight_map[c] for c in scores)
            tier = tier_for(overall)

            wide_rows.append(dict(
                DATASET_ID=d.dataset_id,
                DATASET_NAME=d.dataset_name,
                DATASET_FQN=d.fqn,
                DOMAIN=d.domain,
                LAYER=d.layer,
                SCORE_RUN_DATE=run_date,
                BATCH_ID=str(uuid.uuid4())[:8],

                DIM_OWNERSHIP_SCORE=own_score,
                DIM_OWNERSHIP_STATUS=status_for(own_score),
                DIM_OWNERSHIP_OWNER_NAME=d.owner_name,
                DIM_OWNERSHIP_LAST_CONFIRMED=None,

                DIM_SOURCE_SCORE=src_score,
                DIM_SOURCE_STATUS=status_for(src_score),
                DIM_SOURCE_SYSTEM=d.source_system,
                DIM_SOURCE_TIER=d.classification_tier,

                DIM_ISSUES_SCORE=issues_score,
                DIM_ISSUES_STATUS=status_for(issues_score),
                DIM_ISSUES_OPEN_P1=open_p1,
                DIM_ISSUES_OPEN_P2=open_p2,
                DIM_ISSUES_OPEN_P3=open_p3,
                DIM_ISSUES_LAST_FAILURE_AT=last_failure,

                DIM_TIMELINESS_SCORE=tim_score,
                DIM_TIMELINESS_STATUS=status_for(tim_score),
                DIM_TIMELINESS_MAX_LOAD_DATE=max_load,
                DIM_TIMELINESS_SLA_HOURS=d.sla_hours,
                DIM_TIMELINESS_HOURS_LATE=round(hours_late, 2),

                DIM_COMPLETENESS_KEY_PROPS_SCORE=comp_score,
                DIM_COMPLETENESS_KEY_PROPS_STATUS=status_for(comp_score),
                DIM_COMPLETENESS_KEYS_CHECKED=",".join(d.required_keys),
                DIM_COMPLETENESS_WORST_KEY=d.required_keys[worst_idx],
                DIM_COMPLETENESS_WORST_KEY_NULL_PCT=round(null_rates[worst_idx] * 100, 2),

                DIM_PROFILING_SCORE=prof_score,
                DIM_PROFILING_STATUS=status_for(prof_score),
                DIM_PROFILING_CHECKS_TOTAL=checks_total,
                DIM_PROFILING_CHECKS_PASSED=checks_passed,

                DIM_DEFINITIONS_SCORE=def_score,
                DIM_DEFINITIONS_STATUS=status_for(def_score),
                DIM_DEFINITIONS_FIELDS_TOTAL=fields_total,
                DIM_DEFINITIONS_FIELDS_DEFINED=fields_defined,

                DIM_KEY_PROPERTIES_SCORE=kp_score,
                DIM_KEY_PROPERTIES_STATUS=status_for(kp_score),
                DIM_KEY_PROPERTIES_REQUIRED=len(d.required_keys),
                DIM_KEY_PROPERTIES_PRESENT=len(d.present_keys),

                DIM_USAGE_SCORE=usage_score,
                DIM_USAGE_STATUS=status_for(usage_score),
                DIM_USAGE_UNIQUE_CONSUMERS_30D=unique_consumers,
                DIM_USAGE_QUERIES_30D=queries_30d,

                DIM_FEEDBACK_SCORE=fb_score,
                DIM_FEEDBACK_STATUS=status_for(fb_score),
                DIM_FEEDBACK_AVG_RATING=round(avg_rating, 2),
                DIM_FEEDBACK_RESPONSES_90D=responses,

                TRUST_SCORE_OVERALL=round(overall, 2),
                TRUST_SCORE_TIER=tier,
                LOAD_DATE=datetime.now(),
                LOAD_BY="prototype",
            ))

            for code, val in scores.items():
                long_rows.append(dict(
                    DATASET_ID=d.dataset_id,
                    DATASET_NAME=d.dataset_name,
                    DOMAIN=d.domain,
                    SCORE_RUN_DATE=run_date,
                    DIMENSION_CODE=code,
                    DIMENSION_NAME=WEIGHTS.set_index("DIMENSION_CODE").loc[code, "DIMENSION_NAME"],
                    SCORE=round(val, 2),
                    STATUS=status_for(val),
                ))

    return pd.DataFrame(wide_rows), pd.DataFrame(long_rows)


# --------------------------------------------------------------------------
# 6. Write everything to ./data/
# --------------------------------------------------------------------------

def main() -> None:
    print("[trust-score] generating synthetic data...")

    src = build_source_classification()
    own = build_ownership_registry()
    keys = build_key_property_registry()
    wide, long = build_dq_results()

    src.to_csv(DATA_DIR / "PNC_SOURCE_CLASSIFICATION.csv", index=False)
    own.to_csv(DATA_DIR / "PNC_DATA_OWNERSHIP_REGISTRY.csv", index=False)
    keys.to_csv(DATA_DIR / "PNC_KEY_PROPERTY_REGISTRY.csv", index=False)
    wide.to_csv(DATA_DIR / "PNC_DQ_RESULTS.csv", index=False)
    long.to_csv(DATA_DIR / "PNC_DQ_DIMENSION_RESULTS.csv", index=False)
    WEIGHTS.assign(EFFECTIVE_FROM=TODAY).to_csv(
        DATA_DIR / "PNC_TRUST_SCORE_WEIGHTS.csv", index=False
    )

    print(f"[trust-score] wrote {len(wide):,} scorecard rows across {wide['DATASET_ID'].nunique()} datasets "
          f"({wide['SCORE_RUN_DATE'].nunique()} days)")
    print(f"[trust-score] output dir: {DATA_DIR}")


if __name__ == "__main__":
    main()
