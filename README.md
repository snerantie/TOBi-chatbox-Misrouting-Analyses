# TOBi Chatbot ↔ ACD Misrouting Analysis

Are customers being routed to the wrong live-agent queue after chatting with
Tobi? Specifically — do customers with a **non-technical** Tobi intent end
up in the **Technical Support** ACD queue?

This repo contains the SQL and documentation that build the answer,
step by step.

---

## Current scope

**Step 1 only** — extract one Tobi intent per session from the raw log
stream. Handover flag (Step 2) and ACD queue join (Step 3) come after
Step 1 is signed off.

## Repository layout

```
.
├── README.md
├── docs/
│   └── step1_intent_extraction_walkthrough.md   -- executive walkthrough
└── sql/
    ├── 01_eda.sql                               -- schema + log distribution + exclusion sanity
    └── 02_tobi_intent_extraction.sql            -- the extraction + 3 QA checks
```

- **`docs/step1_intent_extraction_walkthrough.md`** — the business-facing
  version of Step 1: what it does, why, worked example, assumptions.
  Use this for exec / stakeholder communication.
- **`sql/01_eda.sql`** — the exploratory queries. Run first.
- **`sql/02_tobi_intent_extraction.sql`** — the extraction itself + 3 QA
  checks.

## Source table

`vf-pt-copsvertex-live.vfpt_dh_lake_cops_pub_investigation.f_tobi_logs_vertex`

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

Implementation is "filter first, then take last" — mathematically
identical to the step-back phrasing, expressed in one window function.

The filter also requires `log LIKE 'S_%'` — the spec is explicit that the
intent is the last **S_** log. This matters because EDA §4 showed that
~94% of sessions end on a non-S_ log (message/turn events), and without
the `S_` prefix requirement those would leak into the output.

## How to run

1. Run `sql/01_eda.sql`. Confirm the column names in `f_tobi_logs_vertex`
   are `session_id`, `row_id`, `moment`, `log` (adjust if not).
2. Run `sql/02_tobi_intent_extraction.sql`. Verify the four QA checks:
   - **QA #1** — no excluded log leaked → expected **0 rows**
   - **QA #2** — every extracted intent starts with `S_` → expected **0 rows**
   - **QA #3** — one row per session → expected **0 rows**
   - **QA #4** — sessions with no extracted intent → small, explainable count

Output table:
`vf-pt-copsvertex-live.cops_machine_learning.tmp_tobi_intent_per_session`
(rename the target if you'd rather it live elsewhere).

## Open items before Step 2

- Confirm the exact column names in `f_tobi_logs_vertex` after §1 of the
  EDA (schema query).
- Confirm the working dataset for the output table.
- Once QA passes, we build the handover flag from
  `r_tobi_sessions_extended_kafka_sample.Handover`.
