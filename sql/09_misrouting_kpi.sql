-- =============================================================================
-- 09_misrouting_kpi.sql — Step 3 KPI
--
-- Purpose:
--   Bring the four working tables together into a single KPI table and
--   compute the misrouting rate at the numeric PX-family level (per Diogo).
--
-- Inputs:
--   tmp_tobi_intent_per_session          — Step 1 output (one row per session,
--                                          Tobi intent as S_PXn_In_En_Vn).
--   tmp_tobi_session_handover            — Step 2 output (one row per session,
--                                          is_transferred / handover_destination
--                                          / skill_acd / has_acd_landing).
--   r_tobi_sessions_extended_kafka_sample — bridge table (SessionID → InteractionID).
--   tmp_acd_intent_per_interaction       — Step 3 output (one row per ACD
--                                          interaction, acd_intent as PXn).
--
-- Output: tmp_misrouting_kpi
--   One row per Tobi session that:
--     (a) has an extracted Tobi intent,
--     (b) is flagged is_transferred = TRUE,
--     (c) has a bridge InteractionID in the extended-sessions table,
--     (d) has a matching ACD interaction with px_1st populated.
--
-- Grain and tie-breaking:
--   • Grain: one row per Tobi session_id.
--   • Multi-block bridging: a Tobi session with multiple InteractionIDs in the
--     extended-sessions table — take the EARLIEST by START_MOMENT.  This
--     mirrors Diogo's "first" discipline throughout the pipeline.
--
-- Misroute flag:
--   is_misroute_family compares the NUMERIC PX family from both sides:
--     • Tobi: S_PX36a_I8_E7_V147   → regex extracts "PX36"  (drops S_ and 'a').
--     • ACD:  PX36                  → regex extracts "PX36".
--     • Match  = FALSE (not misrouted).  Mismatch = TRUE (misrouted).
--     • Either side NULL           = NULL (indeterminate).
--
--   Numeric-only chosen because the ACD side stores only PX family (never
--   the letter variant like 'a').  Comparing "PX36a" vs "PX36" as different
--   would count a taxonomy-granularity mismatch as misrouting, which is
--   misleading.  See README §Match granularity for the full reasoning.
-- =============================================================================

CREATE OR REPLACE TABLE `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
AS
WITH bridge AS (
  -- For each Tobi session in the extended-sessions table, keep the
  -- earliest InteractionID by START_MOMENT.  Multi-block sessions are
  -- collapsed to one row here to preserve the KPI's "one row per session"
  -- grain.
  SELECT
    session_id,
    interaction_id
  FROM (
    SELECT
      SessionID                                                                        AS session_id,
      CAST(InteractionID AS STRING)                                                    AS interaction_id,
      ROW_NUMBER() OVER (
        PARTITION BY SessionID
        ORDER BY START_MOMENT ASC
      )                                                                                AS rn
    FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
    WHERE InteractionID IS NOT NULL
      AND TRIM(CAST(InteractionID AS STRING)) != ''
  )
  WHERE rn = 1
)
SELECT
  tobi.session_id,
  br.interaction_id,
  tobi.tobi_intent_log,
  REGEXP_EXTRACT(tobi.tobi_intent_log, r'^S_(PX\d+)')                                  AS tobi_family,
  acd.acd_intent,
  REGEXP_EXTRACT(acd.acd_intent, r'^(PX\d+)')                                          AS acd_family,
  hand.handover_destination,
  hand.skill_acd,
  tobi.intent_moment,
  tobi.ani,
  tobi.customer_type,
  CASE
    WHEN REGEXP_EXTRACT(tobi.tobi_intent_log, r'^S_(PX\d+)') IS NULL
      OR REGEXP_EXTRACT(acd.acd_intent,       r'^(PX\d+)') IS NULL              THEN NULL
    WHEN REGEXP_EXTRACT(tobi.tobi_intent_log, r'^S_(PX\d+)')
       = REGEXP_EXTRACT(acd.acd_intent,       r'^(PX\d+)')                     THEN FALSE
    ELSE                                                                              TRUE
  END                                                                                  AS is_misroute_family
FROM       `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`   tobi
INNER JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`     hand
  USING (session_id)
INNER JOIN bridge br
  ON tobi.session_id = br.session_id
INNER JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction` acd
  ON br.interaction_id = acd.interaction_id
WHERE hand.is_transferred = TRUE;


-- =============================================================================
-- QA CHECKS
-- =============================================================================


-- -----------------------------------------------------------------------------
-- QA #1 — One row per session_id.  Expect: 0 rows.
--
-- Multi-interaction sessions were collapsed in the bridge CTE (ROW_NUMBER = 1).
-- If duplicates appear here, the bridge logic misfired somewhere.
-- -----------------------------------------------------------------------------
SELECT session_id, COUNT(*) AS n
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
GROUP  BY session_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- QA #2 — No row has is_transferred anything other than TRUE.
--         Should be trivially guaranteed by the WHERE clause but we surface
--         it here so any drift on the tmp_tobi_session_handover semantics
--         gets caught.  Expect: 0.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n_not_transferred
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi` k
INNER JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover` h
  USING (session_id)
WHERE  h.is_transferred IS DISTINCT FROM TRUE;


-- =============================================================================
-- ANALYTICAL BLOCKS
-- Each block is a small query the reviewer can read directly without a
-- BI tool.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Block A — Coverage funnel
--
-- Reads: "Of X total Tobi sessions, Y have an intent, Z are transferred,
-- W have a bridge to an ACD interaction, and V land in the KPI universe."
--
-- Each row is a stage in the pipeline.  Cumulative drop from stage 1 to
-- stage 5 shows how the population narrows to the KPI-usable subset.
-- -----------------------------------------------------------------------------
SELECT '01_tobi_sessions_total'         AS stage, COUNT(DISTINCT session_id) AS n_sessions
FROM   `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`

UNION ALL

SELECT '02_with_tobi_intent',                     COUNT(*)
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`

UNION ALL

SELECT '03_transferred',                          COUNTIF(is_transferred = TRUE)
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`

UNION ALL

SELECT '04_transferred_with_acd_landing',         COUNTIF(is_transferred = TRUE AND has_acd_landing = TRUE)
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`

UNION ALL

SELECT '05_kpi_universe',                          COUNT(*)
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`

ORDER BY stage;


-- -----------------------------------------------------------------------------
-- Block B — Headline KPI
--
-- One-row summary.  This is the number the report leads with.
--
-- pct_misroute is computed on the DETERMINATE population (excluding rows
-- where either family is NULL).  Reporting NULL sessions as "indeterminate"
-- rather than folding them into the misroute rate keeps the KPI honest.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                            AS n_kpi_universe,
  COUNTIF(is_misroute_family = TRUE)                                                  AS n_misroute,
  COUNTIF(is_misroute_family = FALSE)                                                 AS n_not_misroute,
  COUNTIF(is_misroute_family IS NULL)                                                 AS n_indeterminate,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 2)                       AS pct_misroute
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`;


-- -----------------------------------------------------------------------------
-- Block C — Confusion matrix: top Tobi × ACD family pairs
--
-- The top 30 combinations of (tobi_family, acd_family) with their session
-- counts.  Read as:
--   • Rows where tobi_family = acd_family → correctly routed.  These
--     should dominate the top rows if the routing is generally working.
--   • Rows where tobi_family ≠ acd_family → misrouted.  The bigger those
--     rows, the more they contribute to the headline pct_misroute.
--
-- This view IS the "how much" narrative and the seed of the "why" analysis
-- in file 10 -- it tells us which Tobi intents get most frequently confused
-- with which ACD intents.
-- -----------------------------------------------------------------------------
SELECT
  tobi_family,
  acd_family,
  is_misroute_family,
  COUNT(*)                                                                            AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                                    AS pct_of_kpi
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
WHERE tobi_family IS NOT NULL AND acd_family IS NOT NULL
GROUP BY tobi_family, acd_family, is_misroute_family
ORDER BY n_sessions DESC
LIMIT 30;
