-- =============================================================================
-- 02_tobi_intent_extraction.sql — Step 1
--
-- Extract one Tobi intent per SESSION_ID from the raw log table.
--
-- Rule (verbatim from the spec):
--   • For each SESSION_ID, order the logs by ROW_ID, MOMENT.
--   • The intent is the last 'S_' log in the session.
--   • If that last S_ log is in the excluded set, step back to the previous
--     S_ log and use that instead.  Repeat until we find a non-excluded one.
--
-- Note (EDA §4): ~94% of sessions end on a non-S_ log (message/turn events),
--   which means the step-back rule is essential — without it we'd only
--   extract intents for ~5% of sessions.
--
-- Excluded logs (confirmed with the analyst):
--   'S_PX0_I0_E0_V0'
--   'S_PX0_I0_E0_V524'
--   'S_PX0_I0_E0_V530'
--   'S_PX103_I0_E30_V0'             <-- confirmed excluded (was commented out
--                                       in the paste; analyst confirmed it
--                                       should be counted out)
--   'S_PX103_I0_E30_V615'
--   'S_PX103_I0_E33_V0'
--   'S_PX103_I1_E42_V333'
--   'S_PX103_I1_E47_V377'
--   'S_#!PX[varlubitoresult]!#'
--   + any log starting with 'S_PX102'
--
-- Implementation note:
--   "take the last, step back if excluded, repeat" is equivalent to
--   "drop the excluded rows first, then take the last remaining row" — same
--   result, one window function.
--
-- Source table:
--   vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex
--
-- Output columns:
--   session_id
--   tobi_intent_log     — the raw log string (e.g. S_PX44_I1_E18_V210)
--   intent_row_id
--   intent_moment
--   ani                 — calling phone number (from the intent row)
--                         needed as the join key to the ACD tables in Step 3.
--   customer_type       — customer segment (from the intent row)
--                         useful slicing dimension for downstream analysis.
-- =============================================================================

CREATE OR REPLACE TABLE `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
AS
WITH non_excluded_logs AS (
  SELECT
    session_id,
    row_id,
    moment,
    log,
    ani,
    customer_type
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
  WHERE STARTS_WITH(log, 'S_')                         -- intents are S_ codes only
    AND log NOT IN (
          'S_PX0_I0_E0_V0',
          'S_PX0_I0_E0_V524',
          'S_PX0_I0_E0_V530',
          'S_PX103_I0_E30_V0',
          'S_PX103_I0_E30_V615',
          'S_PX103_I0_E33_V0',
          'S_PX103_I1_E42_V333',
          'S_PX103_I1_E47_V377',
          'S_#!PX[varlubitoresult]!#'
        )
    AND NOT STARTS_WITH(log, 'S_PX102')
),
ranked AS (
  SELECT
    session_id,
    row_id,
    moment,
    log,
    ani,
    customer_type,
    ROW_NUMBER() OVER (
      PARTITION BY session_id
      ORDER BY row_id DESC, moment DESC
    ) AS rn_desc
  FROM non_excluded_logs
)
SELECT
  session_id,
  log            AS tobi_intent_log,
  row_id         AS intent_row_id,
  moment         AS intent_moment,
  ani,
  customer_type
FROM ranked
WHERE rn_desc = 1;


-- -----------------------------------------------------------------------------
-- QA #1 — no excluded log leaked into the extracted intents.
-- Expect: 0 rows.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n_leaked_excluded
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
WHERE  tobi_intent_log IN (
         'S_PX0_I0_E0_V0',
         'S_PX0_I0_E0_V524',
         'S_PX0_I0_E0_V530',
         'S_PX103_I0_E30_V0',
         'S_PX103_I0_E30_V615',
         'S_PX103_I0_E33_V0',
         'S_PX103_I1_E42_V333',
         'S_PX103_I1_E47_V377',
         'S_#!PX[varlubitoresult]!#'
       )
   OR STARTS_WITH(tobi_intent_log, 'S_PX102');


-- -----------------------------------------------------------------------------
-- QA #2 — every extracted intent starts with 'S_'.
-- Expect: 0 rows.  (Sanity check for the STARTS_WITH filter above.)
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n_non_s_intents
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
WHERE  NOT STARTS_WITH(tobi_intent_log, 'S_');


-- -----------------------------------------------------------------------------
-- QA #3 — one row per session.
-- Expect: 0 rows.
-- -----------------------------------------------------------------------------
SELECT session_id, COUNT(*) AS n
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
GROUP  BY session_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- QA #4 — sessions in the raw table that have no intent extracted
-- (every log they had was either non-S_ or on the exclusion list).
-- We already know from EDA §4 that ~94% of sessions end on a non-S_ log,
-- so we EXPECT most sessions to still produce an intent via step-back.
-- This check surfaces the sessions where step-back also fails.
-- -----------------------------------------------------------------------------
SELECT COUNT(DISTINCT src.session_id) AS n_sessions_without_intent
FROM   `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex` src
LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` out
  USING (session_id)
WHERE  out.session_id IS NULL;


-- -----------------------------------------------------------------------------
-- Diagnostic — Exclusion completeness for the partially-excluded families
-- (PX0 and PX103).
--
-- Why this query exists:
--   The exclusion list drops specific PX0 and PX103 codes (not the whole
--   family, unlike PX102 which is wildcarded via NOT STARTS_WITH).  Anything
--   in these families that WASN'T listed by name in the exclusion set is
--   allowed to survive as a valid intent.
--
--   This diagnostic surfaces exactly which PX0 / PX103 codes did survive,
--   so the reviewer can confirm each one represents a real customer intent
--   and not housekeeping we forgot to include in the exclusion list.
--
-- How to read the result:
--   • Rows that look like real intents (varied I / E / V structure, healthy
--     n_sessions across several codes)                → current exclusion is
--                                                       complete; keep as is.
--   • Only one or two codes with very high n_sessions → possible unlisted
--                                                       housekeeping; widen
--                                                       exclusion to the
--                                                       whole family.
--   • Empty result                                    → no PX0/PX103 codes
--                                                       survive at all;
--                                                       fine.
-- -----------------------------------------------------------------------------
SELECT
  REGEXP_EXTRACT(tobi_intent_log, r'^(S_PX\d+)') AS px_family,
  tobi_intent_log,
  COUNT(*)                                        AS n_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
WHERE STARTS_WITH(tobi_intent_log, 'S_PX0_')
   OR STARTS_WITH(tobi_intent_log, 'S_PX103')
GROUP BY px_family, tobi_intent_log
ORDER BY px_family, n_sessions DESC;


-- -----------------------------------------------------------------------------
-- Sanity peek — top extracted intents.  Not a mapping, not a taxonomy,
-- just the raw distribution to eyeball.
-- -----------------------------------------------------------------------------
SELECT tobi_intent_log, COUNT(*) AS n_sessions
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
GROUP  BY tobi_intent_log
ORDER  BY n_sessions DESC
LIMIT  50;


-- -----------------------------------------------------------------------------
-- ANI coverage — how usable is it as the ACD join key?
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                    AS n_sessions,
  COUNTIF(ani IS NULL OR TRIM(ani) = '')                      AS n_ani_missing,
  SAFE_DIVIDE(
    COUNTIF(ani IS NULL OR TRIM(ani) = ''),
    COUNT(*)
  )                                                           AS pct_ani_missing
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`;


-- -----------------------------------------------------------------------------
-- Customer type distribution — sanity check on the segmentation column.
-- Note the presence of both 'Consumo' / 'Consumer' (and 'Empresarial' /
-- 'Business') — the English variants are a legacy encoding of the same
-- segments. This is normalised into a 'customer_segment' view in
-- 04_step1_review_summary.sql §3.
-- -----------------------------------------------------------------------------
SELECT customer_type, COUNT(*) AS n_sessions
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
GROUP  BY customer_type
ORDER  BY n_sessions DESC
LIMIT  50;


-- =============================================================================
-- ANALYTICAL BLOCKS
-- The three queries below produce the analytical narrative for Step 1.
-- Each has a header comment stating the question it answers and how to
-- read the result. Ordered from headline (Block A) to diagnostic (Block C).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Block A — Coverage funnel
--
-- Question: of all Tobi sessions in the source table, what share received
-- an extracted intent under Step 1?
--
-- Result shape: one row.
-- • total_sessions           — distinct session_id in the raw log table
-- • sessions_with_intent     — rows in the intent output table (= 1 per session)
-- • sessions_without_intent  — the residual, investigated in file 03
-- • pct_coverage             — sessions_with_intent / total_sessions × 100
--
-- Reconciles to EDA §2 (total_sessions == n_sessions there).
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
-- Block B — Extracted intents grouped by PX family
--
-- Question: at the PX-family level (e.g. PX36, PX36a, PX34…), which intents
-- dominate? This is the priority list for taxonomy labelling with the Tobi
-- team — labelling ~20 families is dramatically less effort than labelling
-- every S_ code.
--
-- Result shape: top 20 rows, sorted by session count desc.
-- • px_family      — the PX{n}{optional letter} prefix of the intent code
-- • n_sessions     — distinct sessions whose extracted intent is in this family
-- • pct_sessions   — share of extracted-intent sessions in this family
-- • pct_cumulative — running total of pct_sessions; tells you "how much of
--                    the population you cover after labelling the top N".
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
-- Block C — Step-back depth distribution
--
-- Question: how far from the last log did the rule have to reach to find a
-- valid intent?  Answers "is the step-back rule cosmetic (depth 1) or is it
-- doing serious work (depth 2+)?"
--
-- Result shape: one row per depth value.
-- • position_from_end — 1 = intent was the last log; 2 = one log came after
--                        the intent; N = N-1 rows came after.
-- • n_sessions        — distinct sessions where the intent sat at this position
-- • pct_sessions      — share of extracted-intent sessions at this depth
-- • pct_cumulative    — cumulative share up to and including this depth
--
-- Cost note: this query scans the full source log table (~412M rows).
-- Add a `datepart` filter if the reviewer is running under a cost cap.
-- -----------------------------------------------------------------------------
WITH ranked_source AS (
  SELECT
    session_id,
    row_id,
    moment,
    ROW_NUMBER() OVER (
      PARTITION BY session_id
      ORDER BY row_id DESC, moment DESC
    ) AS position_from_end
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
),
intent_positions AS (
  SELECT r.position_from_end
  FROM ranked_source r
  INNER JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` i
    ON  i.session_id      = r.session_id
    AND i.intent_row_id   = r.row_id
    AND i.intent_moment   = r.moment
)
SELECT
  position_from_end,
  COUNT(*)                                                                                                       AS n_sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                                                               AS pct_sessions,
  ROUND(100 * SUM(COUNT(*)) OVER (ORDER BY position_from_end ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(COUNT(*)) OVER (), 2)                                                                              AS pct_cumulative
FROM intent_positions
GROUP BY position_from_end
ORDER BY position_from_end
LIMIT 30;
