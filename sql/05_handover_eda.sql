-- =============================================================================
-- 05_handover_eda.sql — Step 2 EDA
--
-- Goal:
--   Understand the handover / transfer-related columns in
--   r_tobi_sessions_extended_kafka_sample before we commit to a
--   'is_transferred' rule in 06_handover_flag.sql.
--
--   The extended-sessions table has multiple transfer-related columns
--   (Handover, Corrected_Handover, Transfered_ACD, ...). We do not know
--   yet:
--     • Which column is authoritative for "was this session transferred
--       to a live agent?"
--     • Whether the columns agree with each other, and where they diverge.
--     • What values populate each — destination queue names, Yes/No,
--       something else?
--
--   The four queries below answer those questions with data, not
--   assumptions, before we build the flag.
--
-- Scope: all Tobi sessions in f_tobi_logs_vertex (16.14M). The Handover
--   flag will be attached across the whole population, including the
--   16.5% no-intent residual — so Step 3 can distinguish "transferred
--   with a Tobi intent we can classify" from "transferred but Tobi intent
--   unavailable".
--
-- Note on the extended-sessions table:
--   Some sessions appear in multiple rows (agg_session_id / block_number).
--   Every query below aggregates to one-row-per-session first (MAX of a
--   populated flag, or the non-null value) before doing any counting.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Coverage of the transfer-related columns across all Tobi sessions
--
-- Question: for every Tobi session in f_tobi_logs_vertex, are the
-- transfer-related columns populated in the extended-sessions table?
--
-- Reading the result:
--   • pct_in_extended        — share of Tobi sessions that appear at all
--                              in the extended-sessions table.
--   • pct_handover           — share populated on Handover.
--   • pct_corrected_handover — share populated on Corrected_Handover.
--   • pct_transfered_acd     — share populated on Transfered_ACD.
--
-- If pct_in_extended is well below 100%, we have sessions in the log
-- table that don't exist in the extended-sessions table at all. Those
-- sessions will need is_transferred = FALSE (or NULL) by construction.
-- -----------------------------------------------------------------------------
WITH universe AS (
  SELECT DISTINCT session_id
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
),
per_session AS (
  SELECT
    u.session_id,
    MAX(IF(ext.SessionID          IS NOT NULL,                                                                1, 0)) AS in_extended,
    MAX(IF(ext.Handover           IS NOT NULL AND TRIM(CAST(ext.Handover           AS STRING)) != '',         1, 0)) AS has_handover,
    MAX(IF(ext.Corrected_Handover IS NOT NULL AND TRIM(CAST(ext.Corrected_Handover AS STRING)) != '',         1, 0)) AS has_corrected_handover,
    MAX(IF(ext.Transfered_ACD     IS NOT NULL AND TRIM(CAST(ext.Transfered_ACD     AS STRING)) != '',         1, 0)) AS has_transfered_acd
  FROM      universe u
  LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample` ext
    ON u.session_id = ext.SessionID
  GROUP BY u.session_id
)
SELECT
  COUNT(*)                                                                    AS n_sessions_total,
  SUM(in_extended)                                                            AS n_in_extended,
  SUM(has_handover)                                                           AS n_handover_populated,
  SUM(has_corrected_handover)                                                 AS n_corrected_handover_populated,
  SUM(has_transfered_acd)                                                     AS n_transfered_acd_populated,
  ROUND(100 * SUM(in_extended)             / COUNT(*), 2)                     AS pct_in_extended,
  ROUND(100 * SUM(has_handover)            / COUNT(*), 2)                     AS pct_handover,
  ROUND(100 * SUM(has_corrected_handover)  / COUNT(*), 2)                     AS pct_corrected_handover,
  ROUND(100 * SUM(has_transfered_acd)      / COUNT(*), 2)                     AS pct_transfered_acd
FROM per_session;


-- -----------------------------------------------------------------------------
-- Query 2a — Top values of Handover
--
-- Question: what does Handover actually contain? Yes/No, destination names,
-- codes, something else? Read the top 30 rows to see the shape.
--
-- We aggregate to session level via ARRAY_AGG_DISTINCT-style ANY_VALUE-
-- for-single-value pattern — simpler here: count distinct sessions per
-- Handover value.
-- -----------------------------------------------------------------------------
SELECT
  Handover,
  COUNT(DISTINCT SessionID)                                                   AS n_sessions,
  ROUND(100 * COUNT(DISTINCT SessionID)
        / SUM(COUNT(DISTINCT SessionID)) OVER (), 2)                          AS pct_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
WHERE Handover IS NOT NULL AND TRIM(CAST(Handover AS STRING)) != ''
GROUP BY Handover
ORDER BY n_sessions DESC
LIMIT 30;


-- -----------------------------------------------------------------------------
-- Query 2b — Top values of Corrected_Handover
--
-- Same shape as Query 2a but for Corrected_Handover. Comparing the two
-- top-N lists tells us how much of Handover survives the correction, and
-- whether Corrected_Handover introduces categories Handover doesn't have.
-- -----------------------------------------------------------------------------
SELECT
  Corrected_Handover,
  COUNT(DISTINCT SessionID)                                                   AS n_sessions,
  ROUND(100 * COUNT(DISTINCT SessionID)
        / SUM(COUNT(DISTINCT SessionID)) OVER (), 2)                          AS pct_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
WHERE Corrected_Handover IS NOT NULL AND TRIM(CAST(Corrected_Handover AS STRING)) != ''
GROUP BY Corrected_Handover
ORDER BY n_sessions DESC
LIMIT 30;


-- -----------------------------------------------------------------------------
-- Query 3 — Agreement matrix: Handover × Corrected_Handover × Transfered_ACD
--
-- Question: where do the three transfer-related columns AGREE (all say
-- "transferred" or all say "not transferred"), and where do they DISAGREE
-- (one says transferred, another does not)?
--
-- Each column is normalised to a boolean flag:
--   1 = populated (non-null, non-blank)
--   0 = not populated
--
-- We aggregate per session first (MAX) so multi-block rows don't count twice.
--
-- Reading the result:
--   • The (1, 1, 1) row     — the three columns agree on "transferred".
--                             Ideal outcome; picking any of them gives the
--                             same answer for these sessions.
--   • The (0, 0, 0) row     — they agree on "not transferred".
--   • Any mixed row (e.g. (1, 0, 0), (0, 1, 1))
--                            — the columns DISAGREE. These are the
--                            sessions we need to think about before
--                            choosing which column is authoritative.
--   • The share of mixed rows tells us how big the disagreement is.
-- -----------------------------------------------------------------------------
WITH per_session AS (
  SELECT
    SessionID,
    MAX(IF(Handover           IS NOT NULL AND TRIM(CAST(Handover           AS STRING)) != '', 1, 0)) AS h,
    MAX(IF(Corrected_Handover IS NOT NULL AND TRIM(CAST(Corrected_Handover AS STRING)) != '', 1, 0)) AS ch,
    MAX(IF(Transfered_ACD     IS NOT NULL AND TRIM(CAST(Transfered_ACD     AS STRING)) != '', 1, 0)) AS ta
  FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
  GROUP BY SessionID
)
SELECT
  h                                                                            AS handover_populated,
  ch                                                                           AS corrected_handover_populated,
  ta                                                                           AS transfered_acd_populated,
  COUNT(*)                                                                     AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                             AS pct_sessions
FROM per_session
GROUP BY h, ch, ta
ORDER BY n_sessions DESC;


-- -----------------------------------------------------------------------------
-- Query 4 — Handover × SkillACD cross-tab (early peek toward Step 3)
--
-- Question: for sessions where Handover is populated, what SkillACD
-- (the ACD queue) do they end up in?
--
-- This is not the Step 3 KPI. It is a sanity check that the transfer
-- signal on the Tobi side lines up with a real queue landing on the ACD
-- side, and it gives us an early view of the SkillACD taxonomy we will
-- need to classify (Technical vs Non-Technical) in Step 3.
--
-- Reading the result:
--   • If Handover-populated sessions consistently land in a small set of
--     SkillACD values, the signal is coherent.
--   • If SkillACD is null on many Handover-populated sessions, we may
--     need a different join or another column to bridge Tobi → ACD.
-- -----------------------------------------------------------------------------
WITH per_session AS (
  SELECT
    SessionID,
    ANY_VALUE(Handover)                                                        AS handover_value,
    ANY_VALUE(SkillACD)                                                        AS skill_acd_value
  FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
  WHERE Handover IS NOT NULL AND TRIM(CAST(Handover AS STRING)) != ''
  GROUP BY SessionID
)
SELECT
  handover_value,
  skill_acd_value,
  COUNT(*)                                                                     AS n_sessions
FROM per_session
GROUP BY handover_value, skill_acd_value
ORDER BY n_sessions DESC
LIMIT 100;



-- -----------------------------------------------------------------------------
-- Query 5 — Handover VALUE x Corrected_Handover VALUE x SkillACD alignment
--
-- Why this query exists:
--   Query 2a showed Handover = TRANSFERED on 2.65M sessions (30.7%).
--   Query 2b showed Corrected_Handover = TRANSFERED on only 0.72M sessions (8.6%).
--   Query 4 showed 87% of Handover = TRANSFERED sessions have NO SkillACD.
--
--   The two columns disagree on ~1.93M sessions. This query resolves the
--   disagreement with data by checking: for each combination of Handover
--   value and Corrected_Handover value, what share has SkillACD populated
--   (i.e. actually landed at an ACD queue)?
--
--   The column whose TRANSFERED value has a high SkillACD-populated rate is
--   the ground-truth "actually transferred" signal.
--
-- Reading the result:
--   • (TRANSFERED, TRANSFERED)  with high pct_with_skill_acd
--       Both columns agree; these are real transfers that landed at ACD.
--   • (TRANSFERED, RETAINED)    with low pct_with_skill_acd
--       Handover said transferred but Corrected_Handover said retained AND
--       there is no ACD queue landing. Corrected_Handover is right.
--       Conclusion: Corrected_Handover is the authoritative signal.
--   • (TRANSFERED, RETAINED)    with high pct_with_skill_acd
--       Correction is discarding real transfers. Escalate to Diogo -- this
--       would mean Corrected_Handover is too aggressive.
--   • (RETAINED, TRANSFERED)    with any pct_with_skill_acd
--       Rare inverse case; correction is upgrading retention to transfer.
--       Investigate case-by-case.
--
-- Output shape: one row per (Handover value, Corrected_Handover value)
-- combination that appears in the data, sorted by session count.
-- -----------------------------------------------------------------------------
WITH per_session AS (
  SELECT
    SessionID,
    ANY_VALUE(Handover)                                                                                 AS h_val,
    ANY_VALUE(Corrected_Handover)                                                                       AS ch_val,
    MAX(IF(SkillACD IS NOT NULL AND TRIM(CAST(SkillACD AS STRING)) != '', 1, 0))                        AS has_skill_acd
  FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`
  WHERE Handover           IS NOT NULL AND TRIM(CAST(Handover           AS STRING)) != ''
    AND Corrected_Handover IS NOT NULL AND TRIM(CAST(Corrected_Handover AS STRING)) != ''
  GROUP BY SessionID
)
SELECT
  h_val                                                                                                  AS handover_value,
  ch_val                                                                                                 AS corrected_handover_value,
  COUNT(*)                                                                                               AS n_sessions,
  SUM(has_skill_acd)                                                                                     AS n_with_skill_acd,
  ROUND(100 * SUM(has_skill_acd) / COUNT(*), 2)                                                          AS pct_with_skill_acd
FROM per_session
GROUP BY h_val, ch_val
ORDER BY n_sessions DESC;
