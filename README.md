# TOBi Chatbot ↔ ACD Misrouting Analysis

Are customers being routed to the wrong live-agent queue after chatting with
Tobi? Specifically — do customers with a **non-technical** Tobi intent end
up in the **Technical Support** ACD queue?

This repo contains the SQL and documentation that build the answer,
step by step.

---

## Current scope

- **Step 1** — extract one Tobi intent per session, characterise the
  extracted population, and quantify the residual. **Signed off.** Reports
  the intent on 83.5% of sessions; the 16.5% residual is disclosed as a
  coverage caveat on the misrouting KPI (fallback investigation closed —
  see walkthrough §9–10).
- **Step 2** — attach a defensible `is_transferred` flag to every Tobi
  session. **Built.** EDA (`05_handover_eda.sql` Query 5) resolved the
  `Handover` vs `Corrected_Handover` disagreement with data: 100% of
  sessions Handover flagged TRANSFERED but Corrected_Handover corrected
  to RETAINED had no ACD landing. `Corrected_Handover` is authoritative.
  Build query is in `06_handover_flag.sql` awaiting first run + QA.
- **Step 3** — ACD-side intent extraction + misrouting KPI. **EDA starting**
  (`07_acd_eda.sql`). Method (per Diogo): mirror of Step 1 — extract the
  **first** `PX` intent per session from
  `r_cops_queue_and_interaction_all_sample` (opposite direction to
  Step 1's "last `S_`"). Compare TOBi intent vs ACD intent on the
  transferred subset (`is_transferred = TRUE`). Match granularity:
  **exact 4-part code** (strict).

## Repository layout

```
.
├── README.md
├── docs/
│   ├── management_presentation.md                -- business-facing narrative for the review meeting
│   ├── dashboard_spec.md                          -- live-monitoring dashboard blueprint
│   ├── step1_intent_extraction_walkthrough.md   -- executive-facing walkthrough (Step 1)
│   ├── lead_review_agenda.md                     -- 40-min repo-tour agenda for the data-science lead
│   └── eda_screenshots/                          -- BigQuery result captures
└── sql/
    ├── 01_eda.sql                                -- Step 1: schema, volumes, log distribution
    ├── 02_tobi_intent_extraction.sql             -- Step 1: extraction + QA + analytical blocks
    ├── 03_no_intent_investigation.sql            -- Step 1: deep-dive on residual sessions
    ├── 04_step1_review_summary.sql               -- Step 1: single-page review summary
    ├── 05_handover_eda.sql                       -- Step 2: EDA on handover-related columns
    ├── 06_handover_flag.sql                       -- Step 2: build tmp_tobi_session_handover + QA + narrative
    ├── 07_acd_eda.sql                             -- Step 3: schema-first EDA on the ACD source (+ sample time-range check)
    ├── 08_acd_intent_extraction.sql               -- Step 3: build tmp_acd_intent_per_interaction (dedup, whitespace normalised)
    ├── 09_misrouting_kpi.sql                      -- Step 3: build tmp_misrouting_kpi + is_misroute_family + funnel + confusion matrix
    └── 10_misrouting_why_analysis.sql             -- Step 3: 5 diagnostic slices (segment / Tobi family / ACD queue / hour / day)
```

## What each file produces

| File | Step | Purpose | Runs against |
|---|---|---|---|
| `01_eda.sql` | 1 | Understand the raw log source: schema, volumes, log distribution, last-log-class breakdown. Justifies the step-back rule quantitatively. | `f_tobi_logs_vertex` |
| `02_tobi_intent_extraction.sql` | 1 | Build the working table `tmp_tobi_intent_per_session`; run 4 QA checks; then produce three analytical blocks — coverage funnel, PX-family aggregation, step-back depth distribution. | `f_tobi_logs_vertex` → `tmp_tobi_intent_per_session` |
| `03_no_intent_investigation.sql` | 1 | Build `tmp_no_intent_sessions`; characterise session length, last-log family, transfer overlap, and fallback viability in the extended-sessions table. | `tmp_no_intent_sessions`, `r_tobi_sessions_extended_kafka_sample` |
| `04_step1_review_summary.sql` | 1 | Single-page Step 1 review: coverage, top PX families, normalised segment breakdown, ANI reconciliation, data-quality flags. | Reads from the tables built above. |
| `05_handover_eda.sql` | 2 | EDA on the handover-related columns (`Handover`, `Corrected_Handover`, `Transfered_ACD`) before we commit to an `is_transferred` rule. Query 5 identifies the authoritative column. | `f_tobi_logs_vertex`, `r_tobi_sessions_extended_kafka_sample` |
| `06_handover_flag.sql` | 2 | Build the working table `tmp_tobi_session_handover` (one row per Tobi session with `is_transferred`, `handover_destination`, `skill_acd`, `has_acd_landing`); run 4 QA checks and 3 analytical blocks (coverage funnel, intent × handover cross-tab, top ACD queues). | `f_tobi_logs_vertex`, `r_tobi_sessions_extended_kafka_sample` → `tmp_tobi_session_handover` |
| `07_acd_eda.sql` | 3 | Section 1: schema of the ACD source table. Section 2: cross-table time-range verification (confirms the 17-Jul-2025 to 20-Jul-2026 sample window from Diogo). Sections 3-5 (volumes, intent distribution, first-row class buckets) come in a follow-up commit once the ACD schema is confirmed. | `r_cops_queue_and_interaction_all_sample`, `r_tobi_sessions_extended_kafka_sample`, `f_tobi_logs_vertex` |
| `08_acd_intent_extraction.sql` | 3 | *(planned)* Build `tmp_acd_intent_per_session` — one row per ACD session with the first PX intent (mirror of Step 1's last S_ rule, reversed direction). Depends on the ACD schema from file 07. | `r_cops_queue_and_interaction_all_sample` → `tmp_acd_intent_per_session` |
| `09_misrouting_kpi.sql` | 3 | Build `tmp_misrouting_kpi` — one row per Tobi session in the KPI universe (transferred + intent extracted + bridged to an ACD interaction with `px_1st`). Bridge via the extended-sessions `InteractionID`, earliest-by-`START_MOMENT`. Compute `is_misroute_family` at the numeric PX-family level (drops the `a` suffix on both sides). Includes 2 QA checks and 3 analytical blocks: coverage funnel, headline KPI, Tobi × ACD confusion matrix. | The three `tmp_*` tables + `r_tobi_sessions_extended_kafka_sample` |
| `10_misrouting_why_analysis.sql` | 3 | Five diagnostic slicing blocks against `tmp_misrouting_kpi` to answer the *why*: **A** misroute rate by customer segment (normalised); **B** top 20 Tobi PX families by misroute rate (which Tobi intents get misrouted most); **C** top 20 SkillACD queues by absolute misroute count (which ACD queues absorb the pain, with T-suffix technical flag); **D** misroute rate by hour of day; **E** misroute rate by day of week. Read-only — no pipeline tables changed. | `tmp_misrouting_kpi` |

## Source and working tables

| Table | Role |
|---|---|
| `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex` | Source — raw Tobi log stream. |
| `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample` | Source — one row per session (with multi-block rows in some cases); feeds Step 2 and Step 3. |
| `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` | Working — created by `02`. One row per session with the extracted intent. |
| `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions` | Working — created by `03`. Session ids with no extractable intent. |
| `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_session_handover` | Working — created by `06`. One row per Tobi session with `is_transferred`, `handover_destination` (from `Corrected_Handover`), `skill_acd`, `has_acd_landing`. |

## Extraction rule (verbatim from spec)

For each `SESSION_ID`:

1. Order the logs by `ROW_ID, MOMENT`.
2. Take the last log.
3. If it is in the excluded set, step back to the previous log; repeat
   until the log is not excluded. That log is the intent.

Excluded set:

```
S_PX0_I0_E0_V0
S_PX0_I0_E0_V524
S_PX0_I0_E0_V530
S_PX103_I0_E30_V0
S_PX103_I0_E30_V615
S_PX103_I0_E33_V0
S_PX103_I1_E42_V333
S_PX103_I1_E47_V377
S_#!PX[varlubitoresult]!#
+ every log that starts with S_PX102
```

Implementation is **"filter first, then take last"** — mathematically
identical to the step-back phrasing, expressed in one window function.
The filter also requires `log LIKE 'S_%'` because the spec is explicit
that the intent is the last *S_* log; EDA §4 showed ~94% of sessions end
on a non-S_ log, so without the `S_` prefix requirement those would leak
into the output.

## How to run (BigQuery)

Run the files in order, each in its own query tab. Step 1 (files 01–04)
is fully signed off; Step 2 (file 05) is the current work-in-progress.

**Step 1:**

1. **`sql/01_eda.sql`** — sanity of the source table. All four sections
   run independently; the last-log-class section is the strongest
   justification for the step-back rule.
2. **`sql/02_tobi_intent_extraction.sql`** — builds the intent table
   and runs 4 QA checks plus 3 analytical blocks:
   - **QA #1** — no excluded log leaked → expected 0
   - **QA #2** — every extracted intent starts with `S_` → expected 0
   - **QA #3** — one row per session → expected 0 rows
   - **QA #4** — sessions with no extracted intent → residual, investigated in 03
   - **Block A** — coverage funnel (one row)
   - **Block B** — top 20 PX families with cumulative %
   - **Block C** — step-back depth distribution
3. **`sql/03_no_intent_investigation.sql`** — 7 queries characterising
   the residual, including the fallback investigation (Queries 6–7).
4. **`sql/04_step1_review_summary.sql`** — the single-page Step 1 review.
   Read the header comment; each of the 5 sections has a plain-English
   "what to conclude" comment above the query.

**Step 2:**

5. **`sql/05_handover_eda.sql`** — 5 EDA queries on the handover-related
   columns. Query 5 resolves the `Handover` vs `Corrected_Handover`
   disagreement with data.
6. **`sql/06_handover_flag.sql`** — builds `tmp_tobi_session_handover`
   using `Corrected_Handover` as the authoritative signal; runs 4 QA
   checks and 3 analytical blocks:
   - **QA #1** — one row per session → expected 0 rows
   - **QA #2** — output count matches source distinct sessions → equal
   - **QA #3** — `is_transferred` distribution → ≈ 720K TRUE, 7.63M FALSE, 7.78M NULL
   - **QA #4** — every intent-table session appears in handover table → 0 rows
   - **Block A** — Coverage funnel from raw sessions to KPI-usable universe
   - **Block B** — Intent × handover cross-tab (recasts the Step 1 residual against the new signal)
   - **Block C** — Top SkillACD queues among transferred sessions (peek toward Step 3)

## Output columns of the intent table

| Column | Description |
|---|---|
| `session_id` | Tobi session id |
| `tobi_intent_log` | Extracted intent (last non-excluded S_ log for the session) |
| `intent_row_id` | Row id of the intent event (for traceability) |
| `intent_moment` | Timestamp of the intent event |
| `ani` | Calling phone number — join key to the ACD tables in Step 3 |
| `customer_type` | Raw customer segment; normalised in `04_step1_review_summary.sql §3` |

## Step 1 outcome, summarised

- ✅ Intent extracted for **83.5%** of Tobi sessions (13.48M of 16.14M).
- ⚠ **16.5%** residual (2.66M sessions); 54% of the residual were transferred
  to an agent — a coverage caveat, not a bug.
- ❌ Extended-sessions `PX` column is not a usable fallback (verified via
  `03_no_intent_investigation.sql` Query 7). Decision: report the KPI on
  the 83.5% subset with an explicit *"Tobi intent unavailable"* bucket.

## Next steps

- **Now:** run `sql/07_acd_eda.sql` — both sections 1 (schema) and 2
  (sample time-range verification). Share the schema output so Sections
  3-5 and file 08 can be written against real column names.
- **Then:** `sql/08_acd_intent_extraction.sql` builds
  `tmp_acd_intent_per_session` (first PX per session) — mirror of
  `02_tobi_intent_extraction.sql`, direction reversed.
- **Then:** `sql/09_misrouting_kpi.sql` joins TOBi intent + transfer
  flag + ACD intent, filters to `is_transferred = TRUE`, and computes
  `is_misroute_family` (ACD-side data only carries PX-family, so a
  strict 4-part match is not feasible — see Match granularity note).
- **Also delivered:** `sql/10_misrouting_why_analysis.sql` slices the
  KPI by segment, Tobi PX family, ACD queue, hour of day and day of
  week — the diagnostic material for the *why* narrative.

### Note on match granularity

Initially the plan was to compute both a strict 4-part exact-code
match and a PX-family match. **EDA on the ACD source (`sql/07_acd_eda.sql`
Section 4) revealed the ACD side only stores the PX family** (e.g.
`PX36`), not the full 4-part code that TOBi carries
(e.g. `S_PX36_I8_E7_V147`). A strict comparison is therefore not
feasible on this data.

The KPI is computed at the **PX-family level** only. Each transferred
session carries a single `is_misroute_family` flag: Tobi's PX family
extracted from `tobi_intent_log` versus the ACD's `acd_intent`, both
normalised for whitespace (the source contains both `PX 36` and
`PX36` for the same family).

### Confirmed inputs from the lead

The following are confirmed and locked into the pipeline:

- **T suffix on `SkillACD` = *Técnica* (Technical).** The queue
  classifier for the secondary "where did misrouted traffic land"
  view is `SkillACD LIKE '% T'`.
- **The sample date range is 17 July 2025 – 20 July 2026** — a fixed
  snapshot. Explains the ~47% of Tobi sessions absent from the
  extended-sessions table (they fall outside this window).
- **The KPI must also explain the *why*.** Not just how much
  misrouting happens, but which segments / channels / intents drive
  it. Handled in a dedicated file 10 — see below.
