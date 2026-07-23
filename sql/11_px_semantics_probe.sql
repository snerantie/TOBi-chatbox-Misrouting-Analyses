-- =============================================================================
-- 11_px_semantics_probe.sql — What do the PX codes actually mean?
--
-- Purpose:
--   Neither Tobi's raw data nor ACD's raw data stores a human-readable
--   label next to a PX code.  The taxonomy mapping lives with the ACD team
--   (Diogo).  However, ACD *queue names* (SkillACD) tend to be somewhat
--   descriptive — e.g. a queue may be named with a business area followed
--   by a "T" suffix for Technical.  For each Tobi PX code we ask:
--
--     "When Tobi tags a session with PXn, which ACD queue does the customer
--      actually land on most often?"
--
--   The queue name itself gives us a hint at what business area PXn
--   corresponds to.  This is a PROBE, not a canonical mapping — the
--   canonical mapping still has to come from Diogo.
--
-- Inputs:
--   tmp_misrouting_kpi — one row per KPI-universe session with:
--     tobi_family (e.g. 'PX25'), acd_family (e.g. 'PX103'),
--     skill_acd (the ACD queue name), is_misroute_family.
--
-- No output table — queries return directly.
--
-- Blocks:
--   Block A — Top 10 SkillACD queues per Tobi PX code.
--             This is the main "what does PXn mean" probe.
--   Block B — Top 10 SkillACD queues per Tobi PX for MISROUTED sessions.
--             Answers: "when PXn is misrouted, where does it end up?"
--   Block C — Top 10 SkillACD queues per Tobi PX for CORRECTLY-ROUTED sessions.
--             Answers: "when PXn is correct, which queue is it?"  This is
--             the strongest hint at the intended business meaning.
--   Block D — For the 8 worst-misrouted PX codes flagged on Slide 7 of the
--             deck (PX25, PX8, PX9, PX86, PX71, PX50, PX43, PX12), a
--             compact single-row-per-code summary.
--
-- Warning:
--   SkillACD values may look like short codes themselves (e.g. 'PX36_T').
--   That is still useful — the 'T' suffix signals Technical Support and
--   the numeric part gives us a direct PX-to-queue correspondence.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Block A — Top SkillACD queues per Tobi PX code
--
-- Read as:
--   For each Tobi PX code, which ACD queues receive most of its traffic?
--   Higher pct_of_family = more traffic from PXn goes to that queue.
-- -----------------------------------------------------------------------------
WITH per_family AS (
  SELECT
    tobi_family,
    skill_acd,
    COUNT(*)                                                                          AS n_sessions
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
  WHERE tobi_family IS NOT NULL
    AND skill_acd   IS NOT NULL
    AND TRIM(skill_acd) != ''
  GROUP BY tobi_family, skill_acd
),
ranked AS (
  SELECT
    tobi_family,
    skill_acd,
    n_sessions,
    ROW_NUMBER() OVER (PARTITION BY tobi_family ORDER BY n_sessions DESC)             AS queue_rank,
    ROUND(100 * n_sessions / SUM(n_sessions) OVER (PARTITION BY tobi_family), 2)      AS pct_of_family
  FROM per_family
)
SELECT
  tobi_family,
  queue_rank,
  skill_acd,
  n_sessions,
  pct_of_family
FROM ranked
WHERE queue_rank <= 10
ORDER BY tobi_family, queue_rank;


-- -----------------------------------------------------------------------------
-- Block B — Top SkillACD queues per Tobi PX code — MISROUTED SESSIONS ONLY
--
-- Answers: "When Tobi says PXn but ACD disagrees, which queue does the
-- customer actually land on?"  These are the queues where the mismatch
-- physically happens.
-- -----------------------------------------------------------------------------
WITH per_family_mis AS (
  SELECT
    tobi_family,
    skill_acd,
    COUNT(*)                                                                          AS n_sessions
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
  WHERE is_misroute_family = TRUE
    AND tobi_family IS NOT NULL
    AND skill_acd   IS NOT NULL
    AND TRIM(skill_acd) != ''
  GROUP BY tobi_family, skill_acd
),
ranked_mis AS (
  SELECT
    tobi_family,
    skill_acd,
    n_sessions,
    ROW_NUMBER() OVER (PARTITION BY tobi_family ORDER BY n_sessions DESC)             AS queue_rank,
    ROUND(100 * n_sessions / SUM(n_sessions) OVER (PARTITION BY tobi_family), 2)      AS pct_of_family_misroute
  FROM per_family_mis
)
SELECT
  tobi_family,
  queue_rank,
  skill_acd,
  n_sessions,
  pct_of_family_misroute
FROM ranked_mis
WHERE queue_rank <= 10
ORDER BY tobi_family, queue_rank;


-- -----------------------------------------------------------------------------
-- Block C — Top SkillACD queues per Tobi PX code — CORRECTLY-ROUTED SESSIONS
--
-- This is the strongest semantic hint: when Tobi and ACD agree, which queue
-- name do they agree on?  That queue name is the closest we get to the
-- "intended business meaning" of PXn.
-- -----------------------------------------------------------------------------
WITH per_family_ok AS (
  SELECT
    tobi_family,
    skill_acd,
    COUNT(*)                                                                          AS n_sessions
  FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
  WHERE is_misroute_family = FALSE
    AND tobi_family IS NOT NULL
    AND skill_acd   IS NOT NULL
    AND TRIM(skill_acd) != ''
  GROUP BY tobi_family, skill_acd
),
ranked_ok AS (
  SELECT
    tobi_family,
    skill_acd,
    n_sessions,
    ROW_NUMBER() OVER (PARTITION BY tobi_family ORDER BY n_sessions DESC)             AS queue_rank,
    ROUND(100 * n_sessions / SUM(n_sessions) OVER (PARTITION BY tobi_family), 2)      AS pct_of_family_correct
  FROM per_family_ok
)
SELECT
  tobi_family,
  queue_rank,
  skill_acd,
  n_sessions,
  pct_of_family_correct
FROM ranked_ok
WHERE queue_rank <= 10
ORDER BY tobi_family, queue_rank;


-- -----------------------------------------------------------------------------
-- Block D — Compact summary for the 8 worst-misrouted PX codes (Slide 7)
--
-- One row per top-8 Tobi PX code with:
--   • The #1 ACD queue overall (regardless of misroute)
--   • The #1 ACD queue among CORRECTLY-routed sessions (best semantic hint)
--   • The #1 ACD queue among MISROUTED sessions (where the pain lands)
--
-- If Block C's top queue is meaningful (e.g. contains a business word),
-- use it as the human-readable label for PXn in the deck.
-- -----------------------------------------------------------------------------
WITH top_overall AS (
  SELECT
    tobi_family,
    skill_acd                                                                         AS top1_queue_overall,
    n_sessions                                                                        AS top1_queue_overall_n
  FROM (
    SELECT
      tobi_family, skill_acd, COUNT(*) AS n_sessions,
      ROW_NUMBER() OVER (PARTITION BY tobi_family ORDER BY COUNT(*) DESC)             AS rn
    FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
    WHERE skill_acd IS NOT NULL AND TRIM(skill_acd) != ''
    GROUP BY tobi_family, skill_acd
  )
  WHERE rn = 1
),
top_correct AS (
  SELECT
    tobi_family,
    skill_acd                                                                         AS top1_queue_when_correct,
    n_sessions                                                                        AS top1_queue_when_correct_n
  FROM (
    SELECT
      tobi_family, skill_acd, COUNT(*) AS n_sessions,
      ROW_NUMBER() OVER (PARTITION BY tobi_family ORDER BY COUNT(*) DESC)             AS rn
    FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
    WHERE is_misroute_family = FALSE
      AND skill_acd IS NOT NULL AND TRIM(skill_acd) != ''
    GROUP BY tobi_family, skill_acd
  )
  WHERE rn = 1
),
top_misroute AS (
  SELECT
    tobi_family,
    skill_acd                                                                         AS top1_queue_when_misroute,
    n_sessions                                                                        AS top1_queue_when_misroute_n
  FROM (
    SELECT
      tobi_family, skill_acd, COUNT(*) AS n_sessions,
      ROW_NUMBER() OVER (PARTITION BY tobi_family ORDER BY COUNT(*) DESC)             AS rn
    FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
    WHERE is_misroute_family = TRUE
      AND skill_acd IS NOT NULL AND TRIM(skill_acd) != ''
    GROUP BY tobi_family, skill_acd
  )
  WHERE rn = 1
)
SELECT
  o.tobi_family,
  o.top1_queue_overall,
  o.top1_queue_overall_n,
  c.top1_queue_when_correct,
  c.top1_queue_when_correct_n,
  m.top1_queue_when_misroute,
  m.top1_queue_when_misroute_n
FROM      top_overall  o
LEFT JOIN top_correct  c USING (tobi_family)
LEFT JOIN top_misroute m USING (tobi_family)
WHERE o.tobi_family IN ('PX25','PX8','PX9','PX86','PX71','PX50','PX43','PX12')
ORDER BY
  CASE o.tobi_family
    WHEN 'PX25' THEN 1 WHEN 'PX8'  THEN 2 WHEN 'PX9' THEN 3 WHEN 'PX86' THEN 4
    WHEN 'PX71' THEN 5 WHEN 'PX50' THEN 6 WHEN 'PX43' THEN 7 WHEN 'PX12' THEN 8
  END;
