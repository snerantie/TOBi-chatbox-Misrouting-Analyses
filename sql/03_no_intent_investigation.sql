-- =============================================================================
-- 03_no_intent_investigation.sql
--
-- Purpose:
--   QA #4 in 02_tobi_intent_extraction.sql revealed that ~16.5% of Tobi
--   sessions produce no extractable intent under Step 1 (every log in
--   those sessions is either non-S_ or on the exclusion list).
--
--   This file characterises that population so the reviewer can decide
--   whether it is safe to park (short/abandoned sessions) or whether it
--   contains transferred customers we cannot afford to lose. If the latter,
--   Step 1 has a blind spot and we need a fallback rule.
--
-- Structure:
--   Query 1 — Materialise the no-intent session list into a working table.
--   Query 2 — Sanity: count matches QA #4 from file 02.
--   Query 3 — Session-length distribution (short/abandoned vs long).
--   Query 4 — Last-log prefix family (what do these sessions end on?).
--   Query 5 — Overlap with transferred sessions from the extended-sessions
--             table.  This is the decision-driving question.
--
-- Run after 02_tobi_intent_extraction.sql.  Reads from the raw log table
-- and from the extended-sessions table.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Materialise the no-intent session ids into a working table.
-- Kept small (one column) so the follow-up queries can filter cheaply.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions` AS
SELECT DISTINCT src.session_id
FROM      `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex` src
LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`      out
  USING (session_id)
WHERE out.session_id IS NULL;


-- -----------------------------------------------------------------------------
-- Query 2 — Sanity check.  Should match QA #4 in 02_tobi_intent_extraction.sql.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n_no_intent_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions`;


-- -----------------------------------------------------------------------------
-- Query 3 — Session-length distribution among no-intent sessions.
--
-- Reads: "Of the sessions that produced no intent, how many logs did they
-- actually contain?"  If most are 1–3 logs, they are welcome-and-out
-- sessions where nothing customer-meaningful happened. If they extend
-- past 10 logs the story is different and worth investigating further.
-- -----------------------------------------------------------------------------
WITH per_session AS (
  SELECT session_id, COUNT(*) AS n_logs
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
  WHERE session_id IN (
    SELECT session_id
    FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions`
  )
  GROUP BY session_id
),
bucketed AS (
  SELECT
    CASE
      WHEN n_logs = 1               THEN '01_1_log'
      WHEN n_logs BETWEEN 2 AND 3   THEN '02_2_to_3_logs'
      WHEN n_logs BETWEEN 4 AND 10  THEN '03_4_to_10_logs'
      WHEN n_logs BETWEEN 11 AND 50 THEN '04_11_to_50_logs'
      ELSE                               '05_over_50_logs'
    END AS length_bucket
  FROM per_session
)
SELECT
  length_bucket,
  COUNT(*)                                        AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_sessions
FROM bucketed
GROUP BY length_bucket
ORDER BY length_bucket;


-- -----------------------------------------------------------------------------
-- Query 4 — Last-log prefix family among no-intent sessions.
--
-- Reads: "When these customers give up (or the session terminates), what
-- do they end on?"  Bot response (R_), transfer (T_), event (E_), or the
-- specific excluded S_ codes we already know about.
-- -----------------------------------------------------------------------------
WITH last_log AS (
  SELECT
    session_id,
    log,
    ROW_NUMBER() OVER (
      PARTITION BY session_id
      ORDER BY row_id DESC, moment DESC
    ) AS rn_desc
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
  WHERE session_id IN (
    SELECT session_id
    FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions`
  )
)
SELECT
  SUBSTR(log, 1, 2)                                AS log_prefix,
  COUNT(*)                                          AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_sessions
FROM last_log
WHERE rn_desc = 1
GROUP BY log_prefix
ORDER BY n_sessions DESC;


-- -----------------------------------------------------------------------------
-- Query 5 — Overlap with transferred sessions.  The decision query.
--
-- Reads: "Of the sessions with no extractable intent, how many were
-- transferred to a live agent?"  Answered against the Handover column
-- in the extended-sessions table.
--
-- Note on join key (from schema inspection):
--   • Extended-sessions table uses column `SessionID` (camelCase),
--     not `session_id`. Explicit ON clause below.
--   • Extended-sessions table also uses `Handover` (capital H).
--
-- • transferred = TRUE and material share ⇒ Step 1 has a blind spot;
--   we need a fallback rule (e.g. use the T_ transfer code or the
--   Handover value as a coarse intent).
-- • transferred = FALSE dominates ⇒ safe to park.
-- -----------------------------------------------------------------------------
SELECT
  ext.Handover IS NOT NULL AND TRIM(CAST(ext.Handover AS STRING)) != ''  AS is_transferred,
  COUNT(*)                                                                AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                        AS pct_sessions
FROM      `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions`                        ni
LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`         ext
  ON ni.session_id = ext.SessionID
GROUP BY is_transferred
ORDER BY n_sessions DESC;
