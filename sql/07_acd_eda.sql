-- =============================================================================
-- 07_acd_eda.sql — Step 3 EDA (schema-first)
--
-- Goal:
--   Understand the ACD source table before we commit to a "first PX per
--   session" extraction rule (the mirror of Step 1's "last S_ per session").
--
-- Source:
--   vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample
--
-- Discipline:
--   Same pattern used for f_tobi_logs_vertex on day 1 — get the schema
--   before assuming any column names.
--
-- Structure of this file:
--   Section 1 — Schema of the ACD source table (INFORMATION_SCHEMA).
--   Section 2 — Sample time-range verification (all three source tables
--               compared against Diogo's stated 17-Jul-2025 to 20-Jul-2026
--               window).
--   Section 3 — Volumes.                                    (added after §1)
--   Section 4 — Intent-value distribution.                  (added after §1)
--   Section 5 — First-row class buckets per session.        (added after §1)
--
-- Sections 3-5 depend on the confirmed column names from Section 1:
--     • the session join key (session_id / SessionID / interaction_id / ANI?)
--     • the ordering column (row_id / moment / timestamp?)
--     • the intent column (log / PX / Intent / intent_code?)
--     • whether "PX records" means rows with a shape like PX36_... or rows
--       where a specific PX column is populated
--
-- After Sections 3-5 land, file 08 (acd_intent_extraction) can be written.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Section 1 — Schema of the ACD source table
--
-- Reads the column list from INFORMATION_SCHEMA.  Paste the result back
-- and I fill in Sections 2-4 against real column names in a follow-up
-- commit.
-- -----------------------------------------------------------------------------
SELECT column_name, data_type
FROM   `vf-pt-copsvertex-live.cops_machine_learning.INFORMATION_SCHEMA.COLUMNS`
WHERE  table_name = 'r_cops_queue_and_interaction_all_sample'
ORDER  BY ordinal_position;



-- -----------------------------------------------------------------------------
-- Section 2 — Sample time-range verification
--
-- Diogo confirmed the sample tables are a fixed snapshot covering
-- 17-Jul-2025 to 20-Jul-2026 (~369 days). This query records the actual
-- time bounds and session counts of each source table we use, so the
-- window is documented in the pipeline itself and not just in a message.
--
-- Interpretation:
--   • The extended-sessions and ACD sample tables SHOULD both fall inside
--     Diogo's stated window (min ≥ 2025-07-17, max ≤ 2026-07-20).
--   • The raw log stream (f_tobi_logs_vertex) covers a longer window
--     (~2024-07-16 to ~2026-07-16); the ~47% of Tobi sessions absent
--     from the extended sample are those logged before 2025-07-17.
--   • If the ACD sample's date column has a different name than
--     START_MOMENT / moment, adjust after Section 1 output is inspected.
--
-- If any of these ranges is out of bounds, escalate to Diogo — the sample
-- window is the anchor for every KPI number we produce.
-- -----------------------------------------------------------------------------
SELECT
  'r_tobi_sessions_extended_kafka_sample'                           AS source_table,
  MIN(START_MOMENT)                                                  AS min_moment,
  MAX(START_MOMENT)                                                  AS max_moment,
  DATE_DIFF(DATE(MAX(START_MOMENT)), DATE(MIN(START_MOMENT)), DAY)   AS n_days,
  COUNT(DISTINCT SessionID)                                          AS n_sessions
FROM `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample`

UNION ALL

SELECT
  'f_tobi_logs_vertex',
  MIN(moment),
  MAX(moment),
  DATE_DIFF(DATE(MAX(moment)), DATE(MIN(moment)), DAY),
  COUNT(DISTINCT session_id)
FROM `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`;

-- Once Section 1 confirms the ACD table's date column and session key,
-- add a third row to this UNION for
-- r_cops_queue_and_interaction_all_sample so all three sources are
-- documented in one panel.



-- -----------------------------------------------------------------------------
-- Section 3 — Volumes and px_1st coverage
--
-- Question: how many rows / distinct interactions in the ACD table, and
-- what share have a first-PX intent recorded?  Also the ANI universe.
--
-- Reads: single-row summary.
--   • n_rows                — total rows in the table (interaction grain).
--   • n_distinct_interactions — distinct interactionid values.
--   • n_distinct_anis       — distinct Final_ani values (unique phone numbers).
--   • n_with_px_1st         — rows where px_1st is populated.
--   • pct_with_px_1st       — % coverage of the first-PX field.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                                     AS n_rows,
  COUNT(DISTINCT interactionid)                                                                AS n_distinct_interactions,
  COUNT(DISTINCT Final_ani)                                                                    AS n_distinct_anis,
  COUNTIF(px_1st IS NOT NULL AND TRIM(CAST(px_1st AS STRING)) != '')                           AS n_with_px_1st,
  ROUND(100 * COUNTIF(px_1st IS NOT NULL AND TRIM(CAST(px_1st AS STRING)) != '') / COUNT(*), 2) AS pct_with_px_1st,
  MIN(ulcstart_orig)                                                                            AS min_start,
  MAX(ulcstart_orig)                                                                            AS max_start
FROM `vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample`;


-- -----------------------------------------------------------------------------
-- Section 4 — Top values of px_1st
--
-- Question: what does the first-PX intent field actually contain?  Format
-- (with or without S_ prefix?), top codes, share concentration.
--
-- The result also tells us whether the ACD-side codes match the shape of
-- the Tobi-side codes (S_PXn_In_En_Vn).  If they do, the strict-match
-- misroute rule works directly.  If the ACD side omits the S_ prefix or
-- uses a different structure, file 09 needs a normalisation step.
-- -----------------------------------------------------------------------------
SELECT
  px_1st,
  COUNT(*)                                                                                     AS n_interactions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                                             AS pct_interactions,
  ROUND(100 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(COUNT(*)) OVER (), 2)                                                             AS pct_cumulative
FROM `vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample`
WHERE px_1st IS NOT NULL AND TRIM(CAST(px_1st AS STRING)) != ''
GROUP BY px_1st
ORDER BY n_interactions DESC
LIMIT 30;


-- -----------------------------------------------------------------------------
-- Section 5 — ACD-side PX-family aggregation
--
-- Mirror of the Tobi-side PX-family aggregation from file 02 Block B.
-- Tells us which product families the ACD side sees most often, which is
-- what the PX-family misroute flag in file 09 will compare against.
--
-- The regex tolerates both "S_PXn_..." and "PXn_..." formats (in case the
-- ACD side omits the S_ prefix that Tobi uses).  If the top codes in
-- Section 4 above show a completely different shape, adjust the regex.
-- -----------------------------------------------------------------------------
WITH families AS (
  SELECT REGEXP_EXTRACT(px_1st, r'^(?:S_)?(PX\d+[a-z]?)') AS px_family
  FROM `vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample`
  WHERE px_1st IS NOT NULL AND TRIM(CAST(px_1st AS STRING)) != ''
),
counted AS (
  SELECT px_family, COUNT(*) AS n_interactions
  FROM families
  GROUP BY px_family
)
SELECT
  px_family,
  n_interactions,
  ROUND(100 * n_interactions / SUM(n_interactions) OVER (), 2)                                                                 AS pct_interactions,
  ROUND(100 * SUM(n_interactions) OVER (ORDER BY n_interactions DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(n_interactions) OVER (), 2)                                                                                       AS pct_cumulative
FROM counted
ORDER BY n_interactions DESC
LIMIT 20;
