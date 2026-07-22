-- =============================================================================
-- 08_acd_intent_extraction.sql — Step 3 build (ACD side)
--
-- Purpose:
--   Materialise the ACD-side intent using Diogo's pre-computed `px_1st`
--   column, which already applies the "first PX record per interaction"
--   rule she described.  Symmetric to Step 1's tmp_tobi_intent_per_session
--   in intent, but with a different grain -- see below.
--
-- Grain:
--   The ACD source (r_cops_queue_and_interaction_all_sample) is at
--   INTERACTION grain, not session grain.  A single customer session may
--   produce zero or more ACD interactions (a call, a transfer, a
--   consult...).  We keep this table at the same grain -- one row per
--   ACD interactionid -- and let the KPI join in file 09 handle the
--   Tobi-session ↔ ACD-interaction mapping via the extended-sessions
--   bridge (which carries both SessionID and InteractionID).
--
-- Rule:
--   For each row where px_1st is populated, keep px_1st as acd_intent.
--   Filter out interactions with no first-PX value -- those cannot
--   participate in the intent-vs-intent comparison.
--
-- Design notes:
--   • interactionid is FLOAT64 in the source but the extended-sessions
--     table's InteractionID is STRING.  We CAST here so both sides speak
--     STRING when file 09 joins them.
--   • We carry through ANI, timestamps, and service so downstream files
--     (09 KPI, 10 why-analysis) don't need another read on the raw source.
--   • No exclusion list on the ACD side -- Diogo's px_1st is already the
--     right value.  If Section 4 of file 07 reveals housekeeping-looking
--     codes dominating, we revisit and add exclusion logic.
--
-- Output columns:
--   interaction_id     -- STRING; the ACD interactionid, joinable to the
--                        extended-sessions InteractionID column.
--   acd_intent         -- STRING; the first PX intent for this interaction.
--   ani                -- STRING; Final_ani (phone number).  Available for
--                        sanity checks or backup joins.
--   interaction_start  -- TIMESTAMP; ulcstart_orig, useful for time-window
--                        checks in the KPI join.
--   interaction_end    -- TIMESTAMP; atcend.
--   acd_service        -- STRING; the ACD service, kept for the "why"
--                        slicing in file 10.
-- =============================================================================

CREATE OR REPLACE TABLE `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction`
AS
WITH ranked AS (
  -- The source table stores each interaction on 2 rows (confirmed by
  -- file 07 Section 6 -- likely inbound/outbound or before/after transfer).
  -- We deduplicate to exactly one row per interactionid, keeping the
  -- EARLIEST row by utcstart_orig.  This aligns with Diogo's "first PX"
  -- discipline: even in the rare case where the two rows disagree on
  -- px_1st, the earlier row's intent is authoritative.
  SELECT
    CAST(interactionid AS STRING)                                                    AS interaction_id,
    -- Normalise whitespace: the source has BOTH 'PX36' and 'PX 36' for the
    -- same intent.  Strip all whitespace so the two encodings collapse into
    -- a canonical 'PX36' before any join or comparison downstream.
    REGEXP_REPLACE(CAST(px_1st AS STRING), r'\s+', '')                               AS acd_intent,
    Final_ani                                                                         AS ani,
    utcstart_orig                                                                     AS interaction_start,
    utcend                                                                            AS interaction_end,
    service                                                                           AS acd_service,
    ROW_NUMBER() OVER (
      PARTITION BY interactionid
      ORDER BY utcstart_orig ASC, atcend ASC
    )                                                                                 AS rn
  FROM `vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample`
  WHERE px_1st IS NOT NULL
    AND TRIM(CAST(px_1st AS STRING)) != ''
)
SELECT
  interaction_id,
  acd_intent,
  ani,
  interaction_start,
  interaction_end,
  acd_service
FROM ranked
WHERE rn = 1;


-- =============================================================================
-- QA CHECKS
-- =============================================================================


-- -----------------------------------------------------------------------------
-- QA #1 — One row per interaction_id.  Expect: 0 rows.
--
-- The source is at interaction grain, so this should hold trivially.  A
-- violation here would mean interactionid isn't actually unique in the
-- source table (or that our CAST introduced collisions).
-- -----------------------------------------------------------------------------
SELECT interaction_id, COUNT(*) AS n
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction`
GROUP  BY interaction_id
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- QA #2 — No null acd_intent.  Expect: 0.
--
-- Guaranteed by the WHERE clause on the CREATE, but re-checked here so a
-- silent schema change (px_1st column being renamed / retyped) surfaces
-- as a failed QA rather than an empty KPI in file 09.
-- -----------------------------------------------------------------------------
SELECT COUNT(*) AS n_null_acd_intent
FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction`
WHERE  acd_intent IS NULL OR TRIM(CAST(acd_intent AS STRING)) = '';


-- -----------------------------------------------------------------------------
-- QA #3 — Coverage vs the source table.
--
-- Reconciles the output back to the source.  Two numbers:
--   n_output               — rows in our extraction table.
--   n_source_with_px_1st   — rows in the raw source with px_1st populated.
--   Difference             — should be 0 (extraction is a strict filter,
--                             no aggregation).
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*)
   FROM   `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction`)                                        AS n_output,
  (SELECT COUNTIF(px_1st IS NOT NULL AND TRIM(CAST(px_1st AS STRING)) != '')
   FROM   `vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample`)                              AS n_source_with_px_1st,
  (SELECT COUNT(*)
   FROM   `vf-pt-copsvertex-live.cops_machine_learning.r_cops_queue_and_interaction_all_sample`)                              AS n_source_total_rows;


-- -----------------------------------------------------------------------------
-- Sanity peek — top ACD intents in the extracted table.
--
-- Should match the top values from file 07 Section 4 exactly (extraction
-- is just a filter + rename).  Included here so a reviewer opening this
-- file gets the shape of the output without cross-referencing.
-- -----------------------------------------------------------------------------
SELECT
  acd_intent,
  COUNT(*) AS n_interactions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_interactions
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction`
GROUP BY acd_intent
ORDER BY n_interactions DESC
LIMIT 30;


-- -----------------------------------------------------------------------------
-- Sanity peek — ANI coverage in the output.
--
-- Confirms Final_ani is populated for the interactions we're carrying
-- forward.  We use ANI as a backup / disambiguation signal in the KPI
-- join if the InteractionID bridge is incomplete.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                                                     AS n_interactions,
  COUNTIF(ani IS NOT NULL AND TRIM(CAST(ani AS STRING)) != '')                 AS n_with_ani,
  ROUND(100 * COUNTIF(ani IS NOT NULL AND TRIM(CAST(ani AS STRING)) != '') / COUNT(*), 2) AS pct_with_ani
FROM `vf-pt-copsvertex-live.cops_machine_learning.tmp_acd_intent_per_interaction`;
