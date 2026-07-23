# TOBi ↔ ACD Misrouting — Management Presentation

*A tight, executive-facing narrative for the business-review meeting.
Each section is a single talking point with one number and one takeaway.
Read this before the meeting; use it as speaker notes.*

**Audience:** business owners and management
**Duration:** ~15 minutes + Q&A
**Data source:** SQL pipeline in this repository (files 01–10), sample
window 17-Jul-2025 → 20-Jul-2026

---

## 1. The question we set out to answer

> *"When we transfer a customer from Tobi to a human agent, do they land
> in the team that matches what they came for?"*

Concretely — do customers whose Tobi intent is *X* end up on an ACD queue
whose intent is also *X*? If yes, the routing is doing its job. If no,
we're paying a cost every time.

---

## 2. The headline

> **~76% of transferred customers are misrouted.**

- KPI universe (transferred + intent captured on both sides): 310,146 sessions
- Misrouted (Tobi intent ≠ ACD intent at the PX-family level): 235,378
- Correctly routed: 74,744
- Rate: **75.9%**

**Say out loud:** *"Three in every four transferred customers end up in
front of a team that has classified them differently from what Tobi
predicted. This is a large, measurable, and repeatable finding."*

---

## 3. How we measured it — the credibility slide

Every number is data-driven and traceable to a specific SQL query in the
repo. The pipeline runs in four steps:

| Step | What it does |
|---|---|
| **Step 1** | Extract Tobi's intent for each conversation (last non-housekeeping S_ log per session) |
| **Step 2** | Attach whether the session was transferred to an agent (from Diogo's `Corrected_Handover`, chosen after data-driven cross-check against actual ACD landings) |
| **Step 3** | Attach the ACD-side intent (Diogo's pre-computed `px_1st` — the first PX intent per interaction) |
| **KPI**    | Compare intent to intent at the PX-family level (letters normalised) |

**Say out loud:** *"This is not an opinion. Two systems classify the same
customer, and we're just checking whether they agree."*

---

## 4. It's structural — not situational

We sliced the 76% rate across every dimension available. It barely moved:

| Slice | Range of misroute rate |
|---|---|
| Consumer vs Business | 75.7% vs 76.1% — no meaningful difference |
| Business hours (9am–8pm) | 74.9% – 76.7% |
| Days of the week (Mon–Sun) | 75.1% – 76.6% |
| **Tobi intent family** | **30% – 100% — massive variation** |

**Say out loud:** *"The misrouting is not caused by peak-time capacity,
weekend staffing, or customer type. It is driven entirely by **what the
customer is asking about**."*

---

## 5. Where it fails — the specific intents

A small number of Tobi intent families essentially never route to the
matching ACD family:

| Tobi intent family | Sessions | Misroute rate |
|---|---:|---:|
| **PX25** | 10,964 | **100.0%** ← every single one |
| PX8  | 10,843 | 99.6% |
| PX9  | 17,446 | 99.2% |
| PX86 | 16,674 | 99.1% |
| PX71 |  6,631 | 94.0% |
| PX50 | 11,566 | 90.6% |
| PX43 | 16,386 | 90.0% |
| PX12 |  5,579 | 89.1% |

These 8 families together represent **~30% of the KPI universe** and
misroute at **~95%** on average. Fix these and the headline rate drops
dramatically.

**Say out loud:** *"For customers whose intent Tobi classifies as PX25,
**every single one** ends up in front of a team that considers them a
different kind of customer. This is not random — it's a systematic
mismatch."*

---

## 6. Where it works — routing infrastructure is not broken

| Tobi intent family | Sessions | Misroute rate |
|---|---:|---:|
| PX83 | 9,472 | 30.0% |
| PX68 | 12,750 | 30.1% |
| PX74 | 14,472 | 41.7% |

These families tell us the routing *can* work when both sides agree on
what the intent is.

**Say out loud:** *"The infrastructure works. The problem is specific,
not systemic."*

---

## 7. What this actually is

Not a routing bug. Not a capacity issue. Not agent training. Not customer
segmentation.

**A taxonomy mismatch between Tobi and ACD.**

Tobi and ACD each classify customer intent. For 8 specific intent
families, they simply use different labels for the same customer. The
routing rule may still send the customer to the right team — but our
KPI compares the labels themselves, and the labels disagree.

**Old framing:** *"Fix the routing."* → implies rebuilding the routing model.
**New framing:** *"Reconcile the taxonomies."* → fixes a specific list of 8 families.

The new framing is orders of magnitude smaller in scope. That is the
positive story.

---

## 8. Recommendations

1. **Prioritise taxonomy reconciliation on 8 intent families:**
   `PX25`, `PX8`, `PX9`, `PX86`, `PX71`, `PX50`, `PX43`, `PX12`.
   Own-team meeting with Tobi and ACD leads. For each family, confirm
   what it represents on each side, and either align labels or add a
   translation layer.

2. **Build a live monitoring dashboard.**
   Once taxonomies are aligned, we need to watch the KPI move. The
   dashboard is specified in `docs/dashboard_spec.md` — refresh daily,
   drill down by intent family / queue / time / segment.

3. **Repeat the analysis quarterly** using the same SQL pipeline on
   updated (non-sampled) sources. This confirms the fix landed and
   catches regressions.

---

## 9. Caveats — we disclose them up front

- **Sample data.** The analysis runs on a fixed 12-month window
  (17-Jul-2025 → 20-Jul-2026). When productionised on non-sampled
  sources the SQL translates 1-for-1.
- **The final measurable universe is 310K sessions** — approximately 2%
  of the full 16.1M Tobi sessions. The coverage funnel is disclosed in
  `docs/step1_intent_extraction_walkthrough.md`.
- **PX103 is a large ACD destination** that receives traffic from many
  different Tobi intent families. Awaiting confirmation from the ACD
  team on whether PX103 is a specific product area or a catch-all
  fallback — depending on the answer, we may split PX103 out from the
  headline rate in a follow-up cut.

---

## 10. What we're asking for today

1. **Endorsement to open the taxonomy-reconciliation workstream** with
   the Tobi and ACD teams, prioritised on the 8 families above.
2. **Green light to build the monitoring dashboard** — see the spec
   in this repo.
3. **A weekly 30-minute check-in** for the reconciliation phase so we
   can report progress on the misroute rate.

The full analytical trail — every query, every result, every
methodological decision — is in this repository. Nothing is opinion;
everything is one click away from being verified.

---

## Appendix — one-slide numbers table

For the deck, if you want a single summary slide:

| Metric | Value |
|---|---|
| Total Tobi sessions analysed | 16,134,799 |
| Sessions with Tobi intent extracted | 13,479,208 (83.5%) |
| Sessions transferred to an agent | 719,661 |
| Sessions with an ACD intent captured (KPI universe) | 310,146 |
| Misrouted (Tobi intent ≠ ACD intent, PX-family) | 235,378 |
| **Misroute rate** | **75.9%** |
| Top misrouting intent family | `PX25` at 100% |
| Well-routed intent families | `PX83`, `PX68` at ~30% |
