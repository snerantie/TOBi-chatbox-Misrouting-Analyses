-- =============================================================================
-- 01_eda.sql — EDA scoped to Step 1 only: extracting the Tobi intent
--
-- Source of truth for the intent log:
--   vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex
--
-- We only need enough EDA here to:
--   (a) confirm the columns we depend on (session_id, row_id, moment, log),
--   (b) see what LOG values exist so the exclusion list is well-defined,
--   (c) measure how often the last log per session is one we need to skip
--       (this justifies the "step-back" rule).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Schema — confirm the column names we need
-- -----------------------------------------------------------------------------
SELECT column_name, data_type
FROM   `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.INFORMATION_SCHEMA.COLUMNS`
WHERE  table_name = 'f_tobi_logs_vertex'
ORDER  BY ordinal_position;


-- -----------------------------------------------------------------------------
-- 2. Volumes
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                    AS n_rows,
  COUNT(DISTINCT session_id)  AS n_sessions,
  MIN(moment)                 AS min_moment,
  MAX(moment)                 AS max_moment
FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`;


-- -----------------------------------------------------------------------------
-- 3. Log values — raw distribution (top 100) and family view
-- -----------------------------------------------------------------------------
SELECT log, COUNT(*) AS n
FROM   `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
GROUP  BY log
ORDER  BY n DESC
LIMIT  100;

-- Grouped by S_PX<num> family, to sanity-check the exclusion list
-- (we should visually confirm PX0, PX102, PX103 line up with what's excluded)
SELECT
  REGEXP_EXTRACT(log, r'^(S_PX\d+)') AS log_family,
  COUNT(*)                            AS n_rows,
  COUNT(DISTINCT session_id)          AS n_sessions
FROM   `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
WHERE  STARTS_WITH(log, 'S_')
GROUP  BY log_family
ORDER  BY n_rows DESC;


-- -----------------------------------------------------------------------------
-- 4. How often is the last log per session an excluded one?
--    This is the whole reason for the step-back rule — good to size it.
-- -----------------------------------------------------------------------------
WITH last_log_per_session AS (
  SELECT
    session_id,
    log,
    ROW_NUMBER() OVER (
      PARTITION BY session_id
      ORDER BY row_id DESC, moment DESC
    ) AS rn_desc
  FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`
)
SELECT
  CASE
    WHEN log IN (
      'S_PX0_I0_E0_V0',
      'S_PX0_I0_E0_V524',
      'S_PX0_I0_E0_V530',
      'S_PX103_I0_E30_V0',
      'S_PX103_I0_E30_V615',
      'S_PX103_I0_E33_V0',
      'S_PX103_I1_E42_V333',
      'S_PX103_I1_E47_V377',
      'S_#!PX[varlubitoresult]!#'
    )                                   THEN 'excluded_explicit'
    WHEN STARTS_WITH(log, 'S_PX102')    THEN 'excluded_px102_family'
    WHEN STARTS_WITH(log, 'S_')         THEN 'intent_candidate'
    ELSE                                     'non_intent'
  END AS last_log_class,
  COUNT(*) AS n_sessions
FROM   last_log_per_session
WHERE  rn_desc = 1
GROUP  BY last_log_class
ORDER  BY n_sessions DESC;
