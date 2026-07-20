-- =============================================================================
-- 06_handover_flag.sql — Step 2 build
--
-- Purpose:
--   Attach a defensible transfer signal to every Tobi session, using
--   Corrected_Handover as the authoritative "actually transferred to
--   agent" column.  Rule chosen after Query 5 in 05_handover_eda.sql
--   resolved the Handover vs Corrected_Handover disagreement with data:
--     • Corrected_Handover = TRANSFERED → 47% land at a SkillACD queue.
--     • Corrected_Handover = RETAINED   → 0% land at a SkillACD queue
--                                          (even when Handover = TRANSFERED).
--   Handover on its own is ~2x too permissive and would introduce ~1.68M
--   "false transfers" into the KPI.  It is not used here.
--
-- Design choices (both recommended defaults; see chat trail):
--   1. Null handling — STRICT.  If Corrected_Handover is null, is_transferred
--      is NULL.  No fallback to Handover.
--   2. Columns — RICHER.  Carry SkillACD and has_acd_landing so that Step 3
--      can be a single view over this table instead of another join.
--
-- Multi-block handling:
--   Some sessions have multiple rows in the extended-sessions table
--   (agg_session_id / block_number).  The CTE below aggregates per
--   SessionID with a "any block says TRANSFERED wins" rule (so we never
--   accidentally under-count transfers), then a "any block says
--   RETAINED wins" rule for the remainder.  If no block populates
--   Corrected_Handover the session is treated as unknown.
--
-- Output columns:
--   session_id            — Tobi session id
--   is_transferred        — BOOL (TRUE / FALSE / NULL)
--   handover_destination  — STRING: 'TRANSFERED' / 'RETAINED' / NULL
--   skill_acd             — STRING: ACD queue value from the same session,
--                            when present
--   has_acd_landing       — BOOL: whether a SkillACD queue value exists at all
--
-- Scope:
--   All Tobi sessions in f_tobi_logs_vertex (16.14M), including the 16.5%
--   Step 1 no-intent residual.  This lets Step 3 report "transferred with
--   intent" and "transferred but intent unavailable" separately.
-- =============================================================================

CREATE OR REPLACE TABLE `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`
AS
WITH universe AS (
  SELECT DISTINCT session_id
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
),
extended_agg AS (
  SELECT
    SessionID,
    -- "Any block says TRANSFERED" wins; else "any block says RETAINED"; else NULL.
    MAX(CASE WHEN Corrected_Handover = 'TRANSFERED' THEN 1 ELSE 0 END)                    AS any_transferred,
    MAX(CASE WHEN Corrected_Handover = 'RETAINED'   THEN 1 ELSE 0 END)                    AS any_retained,
    -- Any non-null SkillACD value across blocks; null if none.
    MAX(IF(SkillACD IS NOT NULL AND TRIM(CAST(SkillACD AS STRING)) != '', SkillACD, NULL)) AS skill_acd_value,
    MAX(IF(SkillACD IS NOT NULL AND TRIM(CAST(SkillACD AS STRING)) != '', 1, 0))          AS has_skill_acd_flag
  FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
  GROUP BY SessionID
)
SELECT
  u.session_id,
  CASE
    WHEN e.any_transferred = 1 THEN TRUE
    WHEN e.any_retained    = 1 THEN FALSE
    ELSE NULL
  END                                      AS is_transferred,
  CASE
    WHEN e.any_transferred = 1 THEN 'TRANSFERED'
    WHEN e.any_retained    = 1 THEN 'RETAINED'
    ELSE NULL
  END                                      AS handover_destination,
  e.skill_acd_value                        AS skill_acd,
  CASE
    WHEN e.has_skill_acd_flag = 1 THEN TRUE
    WHEN e.SessionID IS NOT NULL  THEN FALSE
    ELSE NULL
  END                                      AS has_acd_landing
FROM      universe u
LEFT JOIN extended_agg e
  ON u.session_id = e.SessionID;


-- =============================================================================
-- QA CHECKS
-- Each check has an expected result stated in the header comment.  Any
-- deviation should stop the pipeline for review before Step 3 runs.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- QA #1 — One row per session.  Expected: 0 rows.
-- -----------------------------------------------------------------------------
SELECT session_id, COUNT(*) AS n
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`
GROUP  BY session_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- QA #2 — Row count matches the source universe.
-- Expected: n_output = n_distinct_source_sessions.
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*)          FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`) AS n_output,
  (SELECT COUNT(DISTINCT session_id) FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`) AS n_source_distinct;


-- -----------------------------------------------------------------------------
-- QA #3 — is_transferred distribution reconciles with Query 5 in file 05.
-- Expected:
--   is_transferred = TRUE           ~= 719,661
--   is_transferred = FALSE          ~= 5,953,080 + 1,679,577 = 7,632,657
--   is_transferred = NULL           ~= 16,134,799 - 8,352,318 = 7,782,481
-- Small drift is acceptable (multi-block edge cases + source refresh).
-- -----------------------------------------------------------------------------
SELECT
  is_transferred,
  COUNT(*)                                              AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)      AS pct_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`
GROUP BY is_transferred
ORDER BY n_sessions DESC;


-- -----------------------------------------------------------------------------
-- QA #4 — Reconciliation with Step 1 intent table.
-- Expected: every session in tmp_tobi_intent_per_session appears in the
-- handover table (LEFT JOIN with is_transferred not always defined, but
-- session_id always present).  0 rows expected.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n_intent_sessions_missing_from_handover
FROM      `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` i
LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`   h
  USING (session_id)
WHERE h.session_id IS NULL;


-- =============================================================================
-- ANALYTICAL BLOCKS
-- The three blocks below produce the Step 2 narrative for the reviewer.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Block A — Coverage funnel from raw sessions to KPI-usable universe.
--
-- Reads: "Of X total Tobi sessions, Y have a Corrected_Handover, Z are
-- flagged transferred, and W have both an ACD queue landing AND a Step 1
-- intent extracted (the clean misrouting-KPI universe)."
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                                    AS n_total_sessions,
  COUNTIF(handover_destination IS NOT NULL)                                                   AS n_with_corrected_handover,
  COUNTIF(is_transferred = TRUE)                                                              AS n_transferred,
  COUNTIF(is_transferred = TRUE AND has_acd_landing = TRUE)                                   AS n_transferred_with_acd_landing,
  -- Intent-side reconciliation
  COUNTIF(is_transferred = TRUE AND session_id IN (
    SELECT session_id FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
  ))                                                                                          AS n_transferred_with_step1_intent,
  COUNTIF(is_transferred = TRUE AND has_acd_landing = TRUE AND session_id IN (
    SELECT session_id FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
  ))                                                                                          AS n_kpi_universe
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`;


-- -----------------------------------------------------------------------------
-- Block B — Intent × handover cross-tab.
--
-- For sessions that DO have a Step 1 intent extracted, what is the
-- transfer distribution?  For sessions that do NOT, what is the transfer
-- distribution?  The second row is the "blind spot" from Step 1 recast
-- against the new authoritative signal.
-- -----------------------------------------------------------------------------
WITH sessions AS (
  SELECT
    h.session_id,
    h.is_transferred,
    h.has_acd_landing,
    (i.session_id IS NOT NULL) AS has_step1_intent
  FROM      `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover` h
  LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` i
    USING (session_id)
)
SELECT
  has_step1_intent,
  is_transferred,
  has_acd_landing,
  COUNT(*)                                                                                    AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY has_step1_intent), 2)               AS pct_within_has_intent
FROM sessions
GROUP BY has_step1_intent, is_transferred, has_acd_landing
ORDER BY has_step1_intent DESC, n_sessions DESC;


-- -----------------------------------------------------------------------------
-- Block C — Top SkillACD queues among transferred sessions.
--
-- Early peek toward Step 3.  For sessions where is_transferred = TRUE and
-- SkillACD is populated, what queues dominate?  The 'T' suffix pattern
-- (Televisao T, WiFi T, Internet T, Voz T, ...) will likely drive the
-- Technical / Non-Technical classification in Step 3.
-- -----------------------------------------------------------------------------
SELECT
  skill_acd,
  COUNT(*)                                                                                    AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                                            AS pct_sessions,
  ROUND(100 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(COUNT(*)) OVER (), 2)                                                            AS pct_cumulative
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover`
WHERE is_transferred = TRUE
  AND skill_acd IS NOT NULL
GROUP BY skill_acd
ORDER BY n_sessions DESC
LIMIT 30;
