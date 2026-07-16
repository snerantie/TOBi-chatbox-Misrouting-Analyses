-- =============================================================================
-- 04_step1_review_summary.sql
--
-- READ THIS FIRST.
--
-- This file produces the single-page review of Step 1: coverage headline,
-- taxonomy priority list, segmentation view, ANI reconciliation, and a
-- data-quality flag panel. Everything here reads from tables built in
-- files 02 and 03; run those first.
--
-- Order of results (top to bottom):
--   §1  Coverage headline           — did Step 1 cover the population?
--   §2  Top 20 PX families          — priority list for Tobi-team taxonomy
--   §3  Segment breakdown           — normalised customer_type
--   §4  ANI reconciliation          — confirms ANI is usable as ACD join key
--   §5  Data-quality flags          — one row per anomaly detected
-- =============================================================================


-- -----------------------------------------------------------------------------
-- §1 — Coverage headline
--
-- One row.  Reads: "Of X total Tobi sessions, we extracted an intent for
-- Y (Z%). The remaining W sessions are investigated in file 03."
-- -----------------------------------------------------------------------------
WITH source AS (
  SELECT COUNT(DISTINCT session_id) AS n_sessions_total
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
),
extracted AS (
  SELECT COUNT(*) AS n_sessions_with_intent
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
)
SELECT
  source.n_sessions_total                                                       AS total_sessions,
  extracted.n_sessions_with_intent                                              AS sessions_with_intent,
  source.n_sessions_total - extracted.n_sessions_with_intent                    AS sessions_without_intent,
  ROUND(100 * extracted.n_sessions_with_intent / source.n_sessions_total, 2)    AS pct_coverage
FROM source, extracted;


-- -----------------------------------------------------------------------------
-- §2 — Top 20 PX families in the extracted intents
--
-- This is the priority list for the Technical / Non-Technical taxonomy
-- work with the Tobi team.  pct_cumulative shows how much of extracted
-- volume you cover after labelling the first N families.
-- -----------------------------------------------------------------------------
WITH families AS (
  SELECT REGEXP_EXTRACT(tobi_intent_log, r'^(S_PX\d+[a-z]?)') AS px_family
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
),
counted AS (
  SELECT px_family, COUNT(*) AS n_sessions
  FROM families
  GROUP BY px_family
)
SELECT
  px_family,
  n_sessions,
  ROUND(100 * n_sessions / SUM(n_sessions) OVER (), 2)                                                          AS pct_sessions,
  ROUND(100 * SUM(n_sessions) OVER (ORDER BY n_sessions DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(n_sessions) OVER (), 2)                                                                            AS pct_cumulative
FROM counted
ORDER BY n_sessions DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- §3 — Segment breakdown (normalised)
--
-- Consolidates the raw customer_type values:
--   'Consumo'    | 'Consumer'  ── these are the same segment, English vs PT.
--   'Empresarial'| 'Business'  ── same story.
--   NULL / blank                ── grouped as 'Unknown'.
--   'Conta Pré-Paga'            ── kept as 'Pre-paid' (very small).
--
-- The English rows exist in the raw data because of a legacy encoding.
-- Data-quality issue is surfaced explicitly in §5.
-- -----------------------------------------------------------------------------
SELECT
  CASE
    WHEN customer_type IN ('Consumo', 'Consumer')                THEN 'Consumer'
    WHEN customer_type IN ('Empresarial', 'Business')            THEN 'Business'
    WHEN customer_type = 'Conta Pré-Paga'                        THEN 'Pre-paid'
    WHEN customer_type IS NULL OR TRIM(customer_type) = ''       THEN 'Unknown'
    ELSE 'Other'
  END                                              AS customer_segment,
  COUNT(*)                                         AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
GROUP BY customer_segment
ORDER BY n_sessions DESC;


-- -----------------------------------------------------------------------------
-- §4 — ANI reconciliation
--
-- Confirms ANI is populated on effectively 100% of extracted sessions,
-- which validates its use as the join key to the ACD tables in Step 3.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                    AS n_sessions,
  COUNTIF(ani IS NOT NULL AND TRIM(ani) != '')                                AS n_ani_populated,
  COUNTIF(ani IS NULL OR TRIM(ani) = '')                                      AS n_ani_missing,
  ROUND(100 * COUNTIF(ani IS NOT NULL AND TRIM(ani) != '') / COUNT(*), 2)     AS pct_ani_populated
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`;


-- -----------------------------------------------------------------------------
-- §5 — Data-quality flags
--
-- One row per anomaly detected during Step 1.  A row here means the pipeline
-- recognised the issue; it does not mean the issue has been remediated.
-- Review each row and decide whether action is needed.
-- -----------------------------------------------------------------------------
WITH flags AS (

  -- Flag: segment encoding duplication (Consumer vs Consumo, Business vs Empresarial)
  SELECT
    'segment_encoding_duplication'                                                                       AS flag,
    'customer_type has both Portuguese and English encodings of the same segment; normalised in §3.'    AS description,
    CAST(SUM(CASE WHEN customer_type IN ('Consumer', 'Business') THEN 1 ELSE 0 END) AS STRING)          AS n_affected
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`

  UNION ALL

  -- Flag: customer_type null or blank for a share of sessions
  SELECT
    'segment_unknown_share',
    'customer_type is NULL or blank; count is grouped into "Unknown" in §3.',
    CAST(COUNTIF(customer_type IS NULL OR TRIM(customer_type) = '') AS STRING)
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`

  UNION ALL

  -- Flag: sessions with no extractable intent
  SELECT
    'no_intent_sessions',
    'Sessions where every log was non-S_ or excluded; investigated in file 03.',
    CAST(
      (SELECT COUNT(DISTINCT session_id) FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`)
      -
      (SELECT COUNT(*) FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`)
      AS STRING
    )

)
SELECT * FROM flags
ORDER BY flag;
