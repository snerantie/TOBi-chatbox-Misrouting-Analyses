# TOBi Chatbot ↔ ACD Misrouting Analysis

Are customers being routed to the wrong live-agent queue after chatting with
Tobi? Specifically — do customers with a **non-technical** Tobi intent end
up in the **Technical Support** ACD queue?

This repo contains the SQL and documentation that build the answer,
step by step.

---

## Current scope

**Step 1 only** — extract one Tobi intent per session from the raw log
stream, characterise the extracted population, and quantify the residual.
Handover flag (Step 2) and ACD queue join (Step 3) come after Step 1 is
signed off.

## Repository layout

```
.
├── README.md
├── docs/
│   ├── step1_intent_extraction_walkthrough.md   -- executive-facing walkthrough
│   └── eda_screenshots/                          -- BigQuery result captures
└── sql/
    ├── 01_eda.sql                                -- schema, volumes, log distribution
    ├── 02_tobi_intent_extraction.sql             -- extraction + QA + analytical blocks
    ├── 03_no_intent_investigation.sql            -- deep-dive on residual sessions
    └── 04_step1_review_summary.sql               -- single-page review summary
```

## What each file produces

| File | Purpose | Runs against |
|---|---|---|
| `01_eda.sql` | Understand the raw log source: schema, volumes, log distribution, last-log-class breakdown. Justifies the step-back rule quantitatively. | `f_tobi_logs_vertex` |
| `02_tobi_intent_extraction.sql` | Build the working table `tmp_tobi_intent_per_session`; run 4 QA checks; then produce three analytical blocks — coverage funnel, PX-family aggregation, step-back depth distribution. | `f_tobi_logs_vertex` → `tmp_tobi_intent_per_session` |
| `03_no_intent_investigation.sql` | Build `tmp_no_intent_sessions`; characterise session length, last-log family, and — critically — overlap with transferred sessions in the extended-sessions table. | `tmp_no_intent_sessions`, `r_tobi_sessions_extended_kafka_sample` |
| `04_step1_review_summary.sql` | Single-page Step 1 review: coverage, top PX families, normalised segment breakdown, ANI reconciliation, data-quality flags. | Reads from the tables built above. |

## Source and working tables

| Table | Role |
|---|---|
| `vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex` | Source — raw Tobi log stream. |
| `vf-pt-copsvertex-live.cops_machine_learning.r_tobi_sessions_extended_kafka_sample` | Source — one row per session; `Handover` column feeds Step 2. |
| `vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session` | Working — created by us in `02`. One row per session with the extracted intent. |
| `vf-pt-copsvertex-live.cops_machine_learning.tmp_no_intent_sessions` | Working — created by us in `03`. Session ids with no extractable intent. |

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

Run the files in order, each in its own query tab:

1. **`sql/01_eda.sql`** — sanity of the source table. All four sections run
   independently; you can skim the last-log-class section for the strongest
   justification of the step-back rule.
2. **`sql/02_tobi_intent_extraction.sql`** — builds the intent table and runs
   4 QA checks plus 3 analytical blocks:
   - **QA #1** — no excluded log leaked → expected 0
   - **QA #2** — every extracted intent starts with `S_` → expected 0
   - **QA #3** — one row per session → expected 0 rows
   - **QA #4** — sessions with no extracted intent → residual, investigated in 03
   - **Block A** — coverage funnel (one row)
   - **Block B** — top 20 PX families with cumulative %
   - **Block C** — step-back depth distribution
3. **`sql/03_no_intent_investigation.sql`** — characterises the residual so
   the reviewer can decide whether to park it (short/abandoned sessions)
   or add a fallback rule (if the residual contains transferred customers).
4. **`sql/04_step1_review_summary.sql`** — the single-page Step 1 review.
   Read the header comment; each of the 5 sections has a plain-English
   "what to conclude" comment on top of the query.

## Output columns of the intent table

| Column | Description |
|---|---|
| `session_id` | Tobi session id |
| `tobi_intent_log` | Extracted intent (last non-excluded S_ log for the session) |
| `intent_row_id` | Row id of the intent event (for traceability) |
| `intent_moment` | Timestamp of the intent event |
| `ani` | Calling phone number — join key to the ACD tables in Step 3 |
| `customer_type` | Raw customer segment; normalised in `04_step1_review_summary.sql §3` |

## Open items before Step 2

- Confirm sign-off on Step 1 based on `04_step1_review_summary.sql`
- Confirm the residual (no-intent sessions) handling: park or fallback
- Then build Step 2 — transferred flag from
  `r_tobi_sessions_extended_kafka_sample.Handover`
