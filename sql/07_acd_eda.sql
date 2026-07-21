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
--   before assuming any column names.  Section 1 below runs unambiguously
--   against INFORMATION_SCHEMA regardless of table shape.  Sections 2-4
--   will be added in a follow-up commit once the schema is confirmed —
--   they depend on knowing:
--     • the session join key (session_id / SessionID / interaction_id / ANI?)
--     • the ordering column (row_id / moment / timestamp?)
--     • the intent column (log / PX / Intent / intent_code?)
--     • whether "PX records" means rows with a shape like PX36_... or rows
--       where a specific PX column is populated
--
-- Once we have Section 1's output, follow-up commits add:
--   Section 2 — Volumes (row count, distinct sessions, time range).
--   Section 3 — Intent-value distribution: top codes to eyeball the "PX
--               record" filter and see if there's a housekeeping equivalent
--               to the TOBi exclusion list.
--   Section 4 — First-row class buckets per session (PX / non-PX / null),
--               the mirror of file 01 Section 4.
--
--   Then 08_acd_intent_extraction.sql — builds tmp_acd_intent_per_session
--   using the confirmed rule.
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
