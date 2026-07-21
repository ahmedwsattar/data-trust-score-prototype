"""
config.py -- v2 Data Trust Score configuration (single source of truth).

Everything that the DDL, the seed generators, and the Streamlit app need to
agree on lives here: the target Snowflake namespace, the DTS_ object prefix,
the per-layer source map for the two report families, the 10-dimension
framework + weights, the 5 DAMA sub-dimensions, the DQ confidence factors,
the CDE multiplier, and the trust bands.

v2 objects are DTS_-prefixed and hosted in EDLE_DW_DB.PNC_DATA. See the
ddl/ files (00-50) for the DDL that materializes the tables described here.
This replaces the v1 build (previously ASATTAR_TRUST_SCORE_POC.DQ_POC,
synthetic, dataset-grain); v1 lives on in git history / branches.

Design notes
------------
- No new schema: PNC_DEVELOPER_RL cannot CREATE SCHEMA on the shared EDLE
  databases, so every v2 object is a DTS_-prefixed object inside the existing
  EDLE_DW_DB.PNC_DATA schema (it holds PNC_DATA_RWC).
- Clone-based DMFs: production tables are never altered. Each scored object is
  zero-copy cloned (CTAS-snapshotted for PUBL views, which can't be cloned)
  into a DTS_CLONE__<db>__<schema>__<obj> table in PNC_DATA, and DMFs attach to
  the clone.
- TRENDED INT layer is intentionally not scored: EDLE_INT_DB...STG_TRENDED_REPORT
  is TRUNCATE+COPY and empty at rest, so the DW table is treated as the
  source-of-record for the TRENDED family.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Target namespace + object naming
# ---------------------------------------------------------------------------

DEPLOY_ROLE = "PNC_DEVELOPER_RL"       # owns PNC_DATA_RWC; runs all v2 DDL
DEPLOY_WAREHOUSE = "PNC_WH"            # adjust in ddl/v2/00_setup.sql if needed

TARGET_DB = "EDLE_DW_DB"
TARGET_SCHEMA = "PNC_DATA"
TARGET_NS = f"{TARGET_DB}.{TARGET_SCHEMA}"   # EDLE_DW_DB.PNC_DATA

DTS_PREFIX = "DTS_"

# Clone tables live alongside the DTS_ objects in PNC_DATA. Double underscores
# separate the source coordinates so the origin is unambiguous and reversible.
CLONE_PREFIX = "DTS_CLONE__"


def clone_name(src_db: str, src_schema: str, src_obj: str) -> str:
    """DTS_CLONE__<db>__<schema>__<obj> (unqualified name within PNC_DATA)."""
    return f"{CLONE_PREFIX}{src_db}__{src_schema}__{src_obj}"


def clone_fqn(src_db: str, src_schema: str, src_obj: str) -> str:
    return f"{TARGET_NS}.{clone_name(src_db, src_schema, src_obj)}"


# ---------------------------------------------------------------------------
# Layer model + DQ confidence factor
#   INT  = Bronze (0.90)   staging landing of raw Workday extract
#   DW   = Silver (0.75)   curated / deduped warehouse table
#   PUBL = Gold   (0.60)   consumer-facing analytics view
# "Source" (1.0) is reserved for a future raw-file layer; unused today.
# ---------------------------------------------------------------------------

LAYER_CONFIDENCE = {
    "SOURCE": 1.00,
    "BRONZE": 0.90,
    "SILVER": 0.75,
    "GOLD":   0.60,
}

LAYER_TO_CONFIDENCE_TIER = {
    "INT":  "BRONZE",
    "DW":   "SILVER",
    "PUBL": "GOLD",
}


def layer_confidence(layer: str) -> float:
    return LAYER_CONFIDENCE[LAYER_TO_CONFIDENCE_TIER[layer]]


# ---------------------------------------------------------------------------
# Scored objects per report family + layer (the lineage we measure)
#   - keys      : composite business/dedup key used for DUPLICATE_COUNT DMFs
#   - freshness : ranked #1 anchor column for the FRESHNESS DMF
#   - is_view   : PUBL views can't be zero-copy cloned -> CTAS snapshot
#
# TRENDED INT is deliberately omitted (empty at rest; DW is source-of-record).
# ---------------------------------------------------------------------------

FRESHNESS_ANCHOR = "LOADDATE"          # INT/DW anchor; PUBL views rename it (see below)
PUBL_FRESHNESS_ANCHOR = "Load Date date and timestamp"   # PUBL views' renamed LOADDATE

SCORED_OBJECTS = [
    # ---- POSITION_REPORT family ----
    {
        "report_family": "POSITION_REPORT",
        "layer": "INT",
        "db": "EDLE_INT_DB", "schema": "PNC_WORKDAY01", "object": "STG_POSITION_REPORT",
        "object_type": "TABLE", "is_view": False,
        "dq_measurement_layer": "BRONZE",
        "key_columns": ["POSITION_ID", "REPORT_EFFECTIVE_DATE", "REPORT_ENTRY_DATE"],
        "freshness_column": FRESHNESS_ANCHOR,
    },
    {
        "report_family": "POSITION_REPORT",
        "layer": "DW",
        "db": "EDLE_DW_DB", "schema": "PNC_DATA", "object": "DT_POSITION_REPORT",
        "object_type": "TABLE", "is_view": False,
        "dq_measurement_layer": "SILVER",
        "key_columns": ["POSITION_ID", "REPORT_EFFECTIVE_DATE", "REPORT_ENTRY_DATE"],
        "freshness_column": FRESHNESS_ANCHOR,
    },
    {
        "report_family": "POSITION_REPORT",
        "layer": "PUBL",
        "db": "EDLE_PUBL_DB", "schema": "PNC_ANALYTICS", "object": "STG_POSITION_REPORT_VW",
        "object_type": "VIEW", "is_view": True,
        "dq_measurement_layer": "GOLD",
        "key_columns": ["Position ID", "Report Effective Date", "Report Entry Date"],
        "freshness_column": PUBL_FRESHNESS_ANCHOR,
    },
    # ---- TRENDED_REPORT family (DW is source-of-record; INT skipped) ----
    {
        "report_family": "TRENDED_REPORT",
        "layer": "DW",
        "db": "EDLE_DW_DB", "schema": "PNC_DATA", "object": "DT_TRENDED_REPORT",
        "object_type": "TABLE", "is_view": False,
        "dq_measurement_layer": "SILVER",
        "key_columns": ["BUSINESS_PROCESS_WID", "EFFECTIVEDATE", "EMPLOYEEID", "RECORDTYPE"],
        "freshness_column": FRESHNESS_ANCHOR,
    },
    {
        "report_family": "TRENDED_REPORT",
        "layer": "PUBL",
        "db": "EDLE_PUBL_DB", "schema": "PNC_ANALYTICS", "object": "STG_TRENDED_REPORT_VW",
        "object_type": "VIEW", "is_view": True,
        "dq_measurement_layer": "GOLD",
        "key_columns": ["Business Process WID", "Effective Date", "Employee ID", "Record Type"],
        "freshness_column": PUBL_FRESHNESS_ANCHOR,
    },
]


# ---------------------------------------------------------------------------
# 10-dimension framework + weights (sum = 100). DQ and Observability are the
# two DMF-measurable dimensions; the rest are registry/governance driven.
#
# is_foundational -> unseeded/zero triggers FOUNDATIONAL_GAP_FLAG.
# dmf_measured    -> contributes to the "measurable ceiling" today.
# ---------------------------------------------------------------------------

DIMENSIONS = [
    # code,                weight, foundational, dmf_measured, label
    ("DQ",             22, False, True,  "Data Quality (DAMA)"),
    ("OBSERVABILITY",  12, False, True,  "Observability"),
    ("OWNERSHIP",      12, True,  False, "Ownership & Stewardship"),
    ("CLASSIFICATION", 12, True,  False, "Classification"),
    ("AUTH_SOURCE",    10, True,  False, "Authoritative Source"),
    ("LINEAGE",        10, False, False, "Lineage"),
    ("DEFINITIONS",     9, False, False, "Business Definitions"),
    ("ACTIVE_ISSUES",   5, False, False, "Active Issues"),
    ("USAGE",           5, False, False, "Usage"),
    ("FEEDBACK",        3, False, False, "User Feedback"),
]

DIMENSION_WEIGHT = {code: w for code, w, _f, _m, _l in DIMENSIONS}
DIMENSION_LABEL = {code: l for code, _w, _f, _m, l in DIMENSIONS}
FOUNDATIONAL_DIMS = [code for code, _w, f, _m, _l in DIMENSIONS if f]
DMF_MEASURED_DIMS = [code for code, _w, _f, m, _l in DIMENSIONS if m]

assert sum(DIMENSION_WEIGHT.values()) == 100, "dimension weights must sum to 100"

# Measurable ceiling = sum of weights for dims we can actually measure today
# (DMF-backed). Registry dims contribute only once seeded.
MEASURABLE_CEILING = sum(DIMENSION_WEIGHT[c] for c in DMF_MEASURED_DIMS)  # 34

# ---------------------------------------------------------------------------
# DAMA sub-dimensions of the DQ dimension. DMFs cover completeness (NULL) and
# uniqueness (DUPLICATE); accuracy/consistency/validity are seeded from IDQ /
# Collibra interim signals until native rules exist.
# ---------------------------------------------------------------------------

DAMA_SUB_DIMS = ["COMPLETENESS", "ACCURACY", "CONSISTENCY", "VALIDITY", "UNIQUENESS"]

DAMA_DMF_AUTOMATED = {
    "COMPLETENESS": True,    # SNOWFLAKE.CORE.NULL_PERCENT / NULL_COUNT
    "UNIQUENESS":   True,    # SNOWFLAKE.CORE.DUPLICATE_COUNT / UNIQUE_COUNT
    "ACCURACY":     False,   # seeded (IDQ)
    "CONSISTENCY":  False,   # seeded (IDQ)
    "VALIDITY":     False,   # seeded (Collibra)
}

# ---------------------------------------------------------------------------
# CDE (Critical Data Element) multiplier: element-level scores for CDE columns
# are weighted 2x in the dataset rollup.
# ---------------------------------------------------------------------------

CDE_MULTIPLIER = 2.0

# ---------------------------------------------------------------------------
# Trust bands (Certified >=90 pinned by framework; the other four are
# defaults, tunable in DTS_TRUST_BANDS). Ordered high -> low.
#   band, min_inclusive, max_inclusive, hex
# ---------------------------------------------------------------------------

TRUST_BANDS = [
    ("CERTIFIED",   90, 100, "#1E8E3E"),
    ("TRUSTED",     75,  89, "#66BB6A"),
    ("ESTABLISHED", 60,  74, "#C9A227"),
    ("PROVISIONAL", 40,  59, "#ED9B0F"),
    ("AT_RISK",      0,  39, "#C44545"),
]


def band_for(score: float) -> str:
    # Highest band whose min the score meets (matches ddl/30 pick-highest logic;
    # avoids gaps for fractional scores like 89.5).
    for band, lo, _hi, _hex in TRUST_BANDS:   # ordered high -> low
        if score >= lo:
            return band
    return "AT_RISK"
