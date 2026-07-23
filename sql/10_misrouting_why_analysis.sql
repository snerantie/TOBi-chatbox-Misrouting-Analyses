-- =============================================================================
-- 10_misrouting_why_analysis.sql — Step 3 diagnostic slicing
--
-- Purpose:
--   The headline KPI (file 09 Block B) is 75.9% misroute rate at the
--   numeric PX-family level.  Business wants to know WHY -- which
--   segments, intents, queues, and time windows drive the number.
--
--   This file slices tmp_misrouting_kpi along four dimensions.  Each
--   block is a stand-alone query with a header comment describing the
--   question it answers and how to read the result.  None of the
--   blocks change any pipeline table -- they are read-only diagnostics
--   for the report.
--
-- Structure:
--   Block A -- Misroute rate by customer segment (normalised
--              customer_type).  Answers: which customer groups
--              experience the most misrouting?
--   Block B -- Misroute rate by Tobi PX family (top 20 by transfer
--              volume).  Answers: which intents on the Tobi side are
--              most likely to end up in the wrong ACD family?
--   Block C -- Misroute rate by ACD queue (SkillACD).  Answers: which
--              queues absorb the most misrouted traffic (i.e. which
--              operations teams see the pain)?
--   Block D -- Misroute rate by time (hour of day, day of week).
--              Answers: does misrouting concentrate at particular
--              times?  Often reveals capacity or model-training gaps.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Block A — Misroute rate by customer segment
--
-- Uses the normalisation from 04_step1_review_summary.sql §3.  The
-- raw customer_type field carries both 'Consumo'/'Consumer' and
-- 'Empresarial'/'Business' for the same segment; we collapse those
-- here before grouping so 'Consumer' and 'Business' don't appear as
-- tiny separate rows.
--
-- Reads: "Consumers are misrouted at X%, businesses at Y%, ..."
-- -----------------------------------------------------------------------------
SELECT
  CASE
    WHEN customer_type IN ('Consumo', 'Consumer')               THEN 'Consumer'
    WHEN customer_type IN ('Empresarial', 'Business')           THEN 'Business'
    WHEN customer_type = 'Conta Pré-Paga'                       THEN 'Pre-paid'
    WHEN customer_type IS NULL OR TRIM(customer_type) = ''      THEN 'Unknown'
    ELSE 'Other'
  END                                                                                AS customer_segment,
  COUNT(*)                                                                            AS n_sessions,
  COUNTIF(is_misroute_family = TRUE)                                                  AS n_misroute,
  COUNTIF(is_misroute_family = FALSE)                                                 AS n_not_misroute,
  COUNTIF(is_misroute_family IS NULL)                                                 AS n_indeterminate,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 2)                       AS pct_misroute
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
GROUP BY customer_segment
ORDER BY n_sessions DESC;


-- -----------------------------------------------------------------------------
-- Block B — Top 20 misrouting Tobi PX families
--
-- Ordered by transfer volume so the biggest families dominate.  Also
-- includes pct_misroute so a "small but heavily misrouted" family
-- surfaces even if it isn't top by volume (compare pct_misroute
-- against the 75.9% headline).
--
-- Reads: "Sessions where Tobi thought the intent was PX36 misroute
-- at X% (vs 75.9% overall)."  Anything materially higher than 75.9%
-- is a Tobi-side intent that's especially prone to misclassification.
-- Anything materially lower is a family the routing works well for.
-- -----------------------------------------------------------------------------
SELECT
  tobi_family,
  COUNT(*)                                                                            AS n_sessions,
  COUNTIF(is_misroute_family = TRUE)                                                  AS n_misroute,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 2)                       AS pct_misroute
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
WHERE tobi_family IS NOT NULL
GROUP BY tobi_family
ORDER BY n_sessions DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- Block C — Top 20 SkillACD queues absorbing misrouted traffic
--
-- Ranked by absolute misroute count (n_misroute), so the "operational
-- owner receiving the most misrouted calls" comes first.  Includes
-- is_technical_queue (the confirmed 'T' suffix rule from Diogo) so
-- Technical vs non-Technical queues can be told apart at a glance.
--
-- Reads: "The 16913 - Internet T queue receives N misrouted sessions,
-- which is X% of its total transferred volume."
-- -----------------------------------------------------------------------------
SELECT
  skill_acd,
  acd_family,
  (skill_acd LIKE '% T')                                                              AS is_technical_queue,
  COUNT(*)                                                                            AS n_sessions,
  COUNTIF(is_misroute_family = TRUE)                                                  AS n_misroute,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 2)                       AS pct_misroute
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
WHERE skill_acd IS NOT NULL
GROUP BY skill_acd, acd_family
ORDER BY n_misroute DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- Block D — Misroute rate by hour of day
--
-- Uses intent_moment (the timestamp of the extracted Tobi intent).
-- Watch for hours where pct_misroute is materially higher than the
-- 75.9% overall -- those often correspond to peak-time queue
-- overflows or model-training gaps on specific shifts.
-- -----------------------------------------------------------------------------
SELECT
  EXTRACT(HOUR FROM intent_moment)                                                    AS hour_of_day,
  COUNT(*)                                                                            AS n_sessions,
  COUNTIF(is_misroute_family = TRUE)                                                  AS n_misroute,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 2)                       AS pct_misroute
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
WHERE intent_moment IS NOT NULL
GROUP BY hour_of_day
ORDER BY hour_of_day;


-- -----------------------------------------------------------------------------
-- Block E — Misroute rate by day of week
--
-- Companion to Block D; 1 = Sunday through 7 = Saturday in BigQuery's
-- DAYOFWEEK convention.  Weekends often behave differently from
-- weekdays because staffing / customer-mix differ.
-- -----------------------------------------------------------------------------
SELECT
  EXTRACT(DAYOFWEEK FROM intent_moment)                                               AS day_of_week,
  CASE EXTRACT(DAYOFWEEK FROM intent_moment)
    WHEN 1 THEN 'Sun' WHEN 2 THEN 'Mon' WHEN 3 THEN 'Tue' WHEN 4 THEN 'Wed'
    WHEN 5 THEN 'Thu' WHEN 6 THEN 'Fri' WHEN 7 THEN 'Sat'
  END                                                                                 AS day_label,
  COUNT(*)                                                                            AS n_sessions,
  COUNTIF(is_misroute_family = TRUE)                                                  AS n_misroute,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 2)                       AS pct_misroute
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_misrouting_kpi`
WHERE intent_moment IS NOT NULL
GROUP BY day_of_week, day_label
ORDER BY day_of_week;
