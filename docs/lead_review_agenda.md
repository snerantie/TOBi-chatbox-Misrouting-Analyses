# Step 1–2 Review — Lead Agenda

Live repo-tour for reviewing the TOBi ↔ ACD misrouting pipeline with the
data-science lead. **Target length: 30–40 minutes.** Format: screen-share
the branch page on GitHub or the local repo. Follow this document top to
bottom.

- **Repo:** `snerantie/TOBi-chatbox-Misrouting-Analyses`
- **Branch:** `step1-tobi-intent-extraction`
- **Prep:** open in browser tabs before the meeting — see the checklist at
  the end of this document.

---

## Run of show

| # | Section | Time |
|---|---|---:|
| 0 | Frame the meeting | 2 min |
| 1 | Repo overview | 3 min |
| 2 | Step 1 — the rule and its QA | 7 min |
| 3 | The critical EDA finding (94% non-intent-last-log) | 2 min |
| 4 | Step 1 — residual investigation and closed fallback | 7 min |
| 5 | Step 2 — the Handover column choice | 10 min |
| 6 | Step 3 status and what you need from the lead | 4 min |
| 7 | Wrap-up and asks | 3 min |
| — | **Total** | **~38 min** |

If the meeting is 20 minutes, cut sections 3 and 6 to 1 minute each and
move the deep-dive material to appendix / follow-up. If it's 60 minutes,
plan for 20 minutes of Q&A at the end and let the lead drive the tour.

---

## 0. Frame the meeting (2 min)

Before opening anything, set the stage:

> "I want to walk you through the pipeline for the Tobi–ACD misrouting
> analysis. Steps 1 and 2 are built and QA'd. Step 3 is opened —
> schema-first — because I want your input on a couple of things before I
> write extraction SQL against the ACD table. About 40 minutes. Interrupt
> me anywhere."

State the three goals of the meeting explicitly:

1. Sign off Steps 1 and 2 as built.
2. Align on the Step 3 scope and the match-granularity choice.
3. Get help closing four open questions that need domain input.

---

## 1. Repo overview (3 min)

**Open:** `README.md` on the branch.

Point to:

- The scope statement at the top — Step 1 signed off, Step 2 built, Step 3
  opened.
- The file layout — 7 SQL files + walkthrough + EDA screenshots.
- The clear source-vs-working table separation.
- The "Match granularity" note at the bottom flagging the strict-match
  decision.

Say:

> "Every step follows the same discipline: EDA first, then build with QA,
> then a review summary. Files are numbered so you can run them in order
> and see what each produces."

Skip the extraction rule details for now — comes in section 2.

---

## 2. Step 1 — the rule and its QA (7 min)

**Open:** `sql/02_tobi_intent_extraction.sql`

### 2a. The header comment (2 min)

Read out loud or point to:

- Rule verbatim from spec — "last non-excluded `S_` log per session, ordered
  by `(row_id, moment)`."
- Why "filter first then take last" is mathematically equivalent to
  step-back — same answer, one window function.
- The full exclusion list (10 items, including the wildcarded `S_PX102*`).
- The `STARTS_WITH(log, 'S_')` requirement — added after EDA revealed a
  bug in the first cut.

### 2b. The 4 QA checks (3 min)

Walk through what each proves and the observed result:

| # | Proves | Observed |
|---|---|---|
| QA #1 | No excluded log leaked into the output | 0 rows |
| QA #2 | Every extracted intent starts with `S_` | 0 rows |
| QA #3 | One row per session | 0 rows |
| QA #4 | Sessions where the rule found nothing (residual) | 2,664,087 (16.5%) — handled in file 03 |

**Anticipated question:** *"Why did you need QA #2?"*

Answer:
> "EDA in file 01 §4 showed 94% of sessions end on a non-S_ log. My first
> cut of the filter dropped excluded S_ codes but did not require the
> `S_` prefix — so a non-S_ log could sneak through as the last remaining
> row and get selected as the intent. QA #2 catches that regression."

### 2c. The exclusion-completeness diagnostic (1 min)

Scroll to the diagnostic block right after QA #4. Explain:

> "The spec's PX102 exclusion was wildcarded but PX0 and PX103 only listed
> specific codes. This query surfaces every PX0 / PX103 code that survives
> as an extracted intent so we can eyeball whether each is a real customer
> intent or housekeeping we forgot to list."

### 2d. The three analytical blocks (1 min)

Show blocks A / B / C at the bottom of the file:

- **Block A** — coverage funnel: 16.14M source → 13.48M extracted → 2.66M
  residual. Reconciles exactly to `01_eda.sql` §2.
- **Block B** — PX-family aggregation: 20 families cover most volume. This
  is the taxonomy priority list to walk through with the Tobi team.
- **Block C** — step-back depth distribution. Confirms the rule is doing
  real work, not cosmetic filtering.

---

## 3. The critical EDA finding — 94% non-intent-last-log (2 min)

**Open:** `sql/01_eda.sql` §4 (last-log-class buckets).

**Also open:** `docs/eda_screenshots/` — find the last-log-class result
image.

Say:

> "This is the single biggest justification for the step-back rule. 94% of
> Tobi sessions end on something that isn't a valid intent code — mostly
> bot responses and message turns. If we naively took the last log we'd
> measure the wrong thing for 15 in 16 conversations. Only 5.3% of
> sessions end directly on a valid S_ intent."

**Anticipated question:** *"How confident are you the exclusion list is
complete?"*

Answer:
> "The exclusion-completeness diagnostic in file 02 lists every PX0 / PX103
> code that survives as an intent. Every surviving code showed varied I / E
> / V structure and healthy volume across several codes — no single
> housekeeping-looking code dominates unnaturally. I would still want to
> walk through the output with you to confirm."

---

## 4. Step 1 — residual investigation and closed fallback (7 min)

**Open:** `sql/03_no_intent_investigation.sql`

This file is why Step 1 close-out took a few iterations — the residual
isn't what we first thought.

### 4a. Query 1 — set-subtraction (1 min)

Explain the LEFT JOIN + IS NULL pattern:

> "Set-subtract on session_id between the raw log table and our intent
> output — that gives us the sessions where the rule found nothing. Stored
> as a working table so the four queries below don't have to recompute it."

### 4b. Query 5 — the residual is transferred (2 min)

Point to the query and its result: **54% transferred** (using Handover as
the naive signal).

Say:
> "My first hypothesis was that the residual would be mostly short
> abandoned sessions. Query 5 broke that. Over half of the no-intent
> sessions were transferred to a live agent. That opened the door to
> whether we needed a fallback rule."

### 4c. Query 6 and 7 — the fallback investigation (3 min)

**Open the Query 7 screenshot** in `docs/eda_screenshots/`.

Walk through:

- Query 6 asked: for the 1.45M transferred no-intent sessions, do the
  pre-computed `PX` / `Intent` columns in the extended-sessions table have
  values?
- Result: `PX` is populated for 100% of them. Looked like a fallback lived
  there.
- Query 7 asked: **what values**?
- Result: 63% PX102, 17% SemLOG, 15% PX0, 5% PX103 — exactly the
  housekeeping our own rule filters out.

Say:
> "The extended-sessions PX column is computed as the raw last log with no
> exclusion filter. For sessions where every log is housekeeping — which
> is precisely what makes them a residual — it just re-surfaces that
> housekeeping. Not usable as a fallback."

### 4d. The decision (1 min)

**Open:** `docs/step1_intent_extraction_walkthrough.md` §9-10.

Point to the closed finding:

- Fallback investigation closed.
- Decision: accept the 16.5% residual, report the KPI on the 83.5%
  subset, disclose the residual as a coverage caveat with an explicit
  *"Tobi intent unavailable"* bucket.

**Anticipated question:** *"Have you considered other fallback signals —
`INTENT_LIST`, `PMotivo`, `HOTLINE_REASON_CODE`?"*

Answer:
> "Listed in walkthrough §9 as future work. Out of scope for the current
> KPI cut. If we need to lift coverage later, that's the natural next
> place to look."

---

## 5. Step 2 — the Handover column choice (10 min)

The big-payoff section. Take your time here.

**Open:** `sql/05_handover_eda.sql`

### 5a. The setup (2 min)

Explain:

> "The extended-sessions table has seven transfer-related columns. Five
> EDA queries in this file resolve which one is authoritative."

Skim Queries 1–4:

- Query 1 — coverage: `Handover` on 53% of sessions; `Corrected_Handover`
  on 52%; `Transfered_ACD` on only 22%. Also flags the 47% of Tobi
  sessions absent from the extended table entirely.
- Query 2a — `Handover` distribution: ~31% TRANSFERED.
- Query 2b — `Corrected_Handover` distribution: ~9% TRANSFERED. **Big
  disagreement.**
- Query 3 — agreement matrix at the populated-flag level.
- Query 4 — `Handover` × `SkillACD` cross-tab: 87% of Handover=TRANSFERED
  sessions have no ACD queue landing.

### 5b. Query 5 — the resolution (3 min)

**Open the Query 5 screenshot** in `docs/eda_screenshots/` (or point to
the query result).

Three rows:

| Handover | Corrected_Handover | Sessions | % with SkillACD |
|---|---|---:|---:|
| RETAINED | RETAINED | 5.95M | 0.09% |
| TRANSFERED | **RETAINED** | 1.68M | **0.00%** |
| TRANSFERED | TRANSFERED | 720K | 46.75% |

Say:
> "Row 2 is the resolution. 1.68 million sessions where Handover said
> TRANSFERED but Corrected_Handover corrected them to RETAINED — and
> **zero of them** actually landed at ACD. The correction is validated by
> ground truth. Handover on its own would double-count the transferred
> population by around 2x. `Corrected_Handover` is authoritative."

### 5c. The build — file 06 (3 min)

**Open:** `sql/06_handover_flag.sql`

Walk through:

- The rule — Corrected_Handover directly drives `is_transferred`.
- Null handling: **strict**. No fallback to Handover. If Corrected_Handover
  is null, `is_transferred = NULL`.
- Multi-block-safe aggregation — "any block says TRANSFERED wins".
- Rich output columns: `session_id`, `is_transferred`,
  `handover_destination`, `skill_acd`, `has_acd_landing`.
- 4 QA checks, all pass or trivial off-by-one.

### 5d. Block A — the funnel (1 min)

Point to the funnel:

- 16.14M total sessions
- 8.35M with Corrected_Handover populated
- 720K flagged transferred
- 336K transferred and landed at ACD
- **336K KPI universe** (transferred + ACD landing + Step 1 intent)

Say:
> "336K is what Step 3 will compute the misrouting rate on. Small in
> percentage terms, but that's what 'we know both sides' honestly looks
> like."

### 5e. Block B — the blind-spot collapse (1 min)

Say:
> "Remember Step 1 said 16.5% of sessions have no intent and 54% of those
> are transferred. Under the authoritative `Corrected_Handover`, only 591
> of them landed at ACD. The KPI-relevant blind spot is essentially
> 0.18% — 2400x smaller than what the naive Handover signal suggested."

---

## 6. Step 3 status and what I need (4 min)

**Open:** `sql/07_acd_eda.sql`

Say:
> "The ACD side mirrors Step 1 with the direction reversed — first PX
> record per session from `r_cops_queue_and_interaction_all_sample`, per
> your direction. I'm doing schema-first, same as day 1. Sections 2-4
> land once the schema is confirmed."

**Point to:** the "T suffix" observation in Block C of file 06. Say:

> "Also worth noting — 93.6% of transfers in the KPI universe land on
> queues with a 'T' suffix (Televisao T, WiFi T, Internet T, Voz T, TV
> APPs T). If T is short for Técnica, the queue classification for the
> secondary view (misrouted → landed where) is a one-line rule. I want to
> confirm that with you."

**Open:** the messages we drafted for Diogo (paste from chat). Recap:

- Q1: T suffix = Técnica?
- Q2: Where do non-technical transfers go? (Different channel or all
  retained in Tobi?)
- Q3: PX-family → Technical / Non-Technical mapping? (Blocks the KPI
  itself.)
- Q4: What is `Transfered_ACD` for?
- Q5: Why do 47% of sessions not appear in the extended table?
- Q6: Multi-block explanation?

Say:
> "Questions 1–3 unblock Step 3. Questions 4–6 are for the write-up. If
> you can help me close 1–3, I can write file 08 (ACD extraction) and
> file 09 (KPI) inside a couple of days."

---

## 7. Wrap-up and asks (3 min)

Three explicit asks, one at a time:

**Ask 1 — Sign-off**

> "Are you comfortable signing off Steps 1 and 2 as they stand? If not,
> what would you want to see changed?"

**Ask 2 — Domain questions**

> "Can you help me close the four blocking Diogo questions — the T suffix,
> the non-technical transfer channel, the PX taxonomy, and the missing 47%?"

**Ask 3 — Match granularity confirmation**

> "You confirmed strict exact 4-part-code match earlier. I want to
> double-check because it will produce a higher misroute rate than
> PX-family. Are you sure you want strict?"

Then pause. Take questions. Have `docs/eda_screenshots/` open on a second
monitor / tab so you can jump to any screenshot in one click.

---

## Anticipated hard questions — short answers

| Question | Answer |
|---|---|
| Why is the residual 16.5%? Is it a bug? | Not a bug — these are sessions whose entire log stream is housekeeping. Query 3 in file 03 shows most are short (1–3 logs). The transferred subset (Query 5) shrinks to 591 when we use `Corrected_Handover`. Disclosed in walkthrough §8–10. |
| Why exact match instead of PX-family? | Your call earlier — I flagged that strict will produce a higher misroute rate than PX-family. If we want a softer view we can add PX-family as a secondary column later. |
| How do you know `Corrected_Handover` is right? | Query 5 in file 05: for the 1.68M sessions where Handover said TRANSFERED but Corrected said RETAINED, 0% actually reached ACD. Validated by ground truth. |
| What about the 47% of sessions missing from the extended table? | Open question with Diogo. We currently keep them as NULL rather than reclassifying. Could revise to FALSE if her answer justifies it — one-line change. |
| How big is the KPI sample? | 335,862 sessions after all joins. ~2% of total. Small in %, but that's what "we know both sides" looks like. |
| Are these tables refreshed automatically? | No — `_sample` tables aren't recurrent, per Diogo's day-1 note. We refresh manually. |
| Why did you keep both `handover_destination` and `is_transferred`? | Redundant on paper — is_transferred is derived from handover_destination. Kept both so downstream queries can filter with a boolean or slice on the raw string without an extra CASE. |
| What if the ACD table has a completely different schema? | File 07 is schema-first — we don't commit any extraction logic until INFORMATION_SCHEMA has confirmed column names. Same discipline as day 1. |
| Does the pipeline handle a data refresh cleanly? | Yes — every working table is `CREATE OR REPLACE`. Rerun files 02, 03, 06 in order and everything rebuilds. Idempotent by design. |

---

## Pre-meeting checklist

Have all of these open in browser tabs before the meeting starts:

- [ ] Branch page on GitHub — `main` tab (README visible)
- [ ] `sql/02_tobi_intent_extraction.sql`
- [ ] `sql/03_no_intent_investigation.sql`
- [ ] `sql/05_handover_eda.sql`
- [ ] `sql/06_handover_flag.sql`
- [ ] `sql/07_acd_eda.sql`
- [ ] `docs/step1_intent_extraction_walkthrough.md`
- [ ] `docs/eda_screenshots/` folder — the last-log-class, Query 5 (Corrected vs Handover), and Query 7 (fallback) screenshots at minimum
- [ ] The message draft for Diogo (from chat)
- [ ] This agenda file — on a second monitor if you have one

Rehearse the 2-minute elevator version out loud once before the meeting
starts:

> "We built an intent extraction from Tobi logs covering 83.5% of sessions.
> We attached a transfer flag using `Corrected_Handover` — proven
> authoritative by data (Query 5 in file 05). The clean KPI universe is
> 336K sessions. Once we extract the ACD-side intent by the mirror rule
> (first PX), we can compute the misrouting rate. Coverage caveats are
> quantified and disclosed."

Good luck.
