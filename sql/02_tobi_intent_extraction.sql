-- =============================================================================
-- 02_tobi_intent_extraction.sql — Step 1
--
-- Extract one Tobi intent per SESSION_ID from the raw log table.
--
-- Rule (verbatim from the spec):
--   • For each SESSION_ID, order the logs by ROW_ID, MOMENT.
--   • Take the LAST log in the session.
--   • If that last log is in the excluded set, step back to the previous log
--     and use that instead.  Repeat until we find a non-excluded log.
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
-- =============================================================================

CREATE OR REPLACE TABLE `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
AS
WITH non_excluded_logs AS (
  SELECT
    session_id,
    row_id,
    moment,
    log
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
  WHERE log NOT IN (
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
    ROW_NUMBER() OVER (
      PARTITION BY session_id
      ORDER BY row_id DESC, moment DESC
    ) AS rn_desc
  FROM non_excluded_logs
)
SELECT
  session_id,
  log     AS tobi_intent_log,
  row_id  AS intent_row_id,
  moment  AS intent_moment
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
-- QA #2 — one row per session.
-- Expect: 0 rows.
-- -----------------------------------------------------------------------------
SELECT session_id, COUNT(*) AS n
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
GROUP  BY session_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- QA #3 — sessions in the raw table that have no intent extracted
-- (all their logs were excluded). Worth eyeballing to make sure the
-- exclusion list isn't wiping out anyone we actually care about.
-- -----------------------------------------------------------------------------
SELECT COUNT(DISTINCT src.session_id) AS n_sessions_without_intent
FROM   `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex` src
LEFT JOIN `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` out
  USING (session_id)
WHERE  out.session_id IS NULL;


-- -----------------------------------------------------------------------------
-- Sanity peek — top extracted intents.  Not a mapping, not a taxonomy,
-- just the raw distribution to eyeball.
-- -----------------------------------------------------------------------------
SELECT tobi_intent_log, COUNT(*) AS n_sessions
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
GROUP  BY tobi_intent_log
ORDER  BY n_sessions DESC
LIMIT  50;
