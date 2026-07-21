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
