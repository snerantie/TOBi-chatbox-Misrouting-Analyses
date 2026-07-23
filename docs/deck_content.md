# Slide Content — Paste Into PowerPoint / Google Slides

*If you can't present from the HTML deck (`docs/deck.html`), copy each
slide's content into your preferred tool. The slide numbers and
titles below match the HTML deck exactly. Every number is verified
against the SQL queries in this repo.*

---

## Slide 1 — TITLE
**Are We Sending Customers To The Right Team?**
*TOBi Chatbot ↔ ACD Misrouting Analysis*
Data Science • Sample window 17 Jul 2025 → 20 Jul 2026

---

## Slide 2 — THE QUESTION
**When we transfer a customer from Tobi to a human agent…**
**…do they land on the team that matches their reason for calling?**

*Footnote:* If they do → routing works. If they don't → we're paying a
cost every time (customer waits, agent transfers again, satisfaction
drops, cost per contact goes up).

---

## Slide 3 — THE HEADLINE
# 75.9%
### of transferred customers are misrouted

**235,378** of **310,146** transferred sessions where we can measure
both sides land on a team whose intent classification disagrees with
Tobi's.

*Speaker note:* Three in every four transferred customers end up in
front of a team that has classified them differently from what Tobi
predicted.

---

## Slide 4 — HOW WE MEASURED IT
**Four steps. Every number is traceable to a specific SQL query.**

| Step | What it does |
|---|---|
| 1. Tobi intent | Extract the customer's intent for each Tobi conversation (last valid intent log) |
| 2. Transfer flag | Was the session transferred to an agent? Diogo's `Corrected_Handover`, chosen by data. |
| 3. ACD intent | What did the ACD system say the customer wanted? First PX at agent pickup. |
| 4. Compare | Same intent → routed correctly. Different intent → misrouted. |

*Callout:* Not an opinion — two systems classify the same customer,
and we're just checking whether they agree.

---

## Slide 5 — STRUCTURAL, NOT SITUATIONAL
**We sliced the 76% across every dimension. It barely moved.**

| Slice | Range | Interpretation |
|---|---|---|
| Consumer vs Business | 75.7% – 76.1% | No difference |
| Business hours (9 – 20) | 74.9% – 76.7% | Flat, not peak-driven |
| Day of week (Mon – Sun) | 75.1% – 76.6% | Flat, not shift-driven |
| **Tobi intent family** | **30% – 100%** | **Massive variation** |

*Callout:* Misrouting is not caused by peak-time capacity, weekend
staffing, or customer type. It is driven entirely by **what the
customer is asking about**.

---

## Slide 6 — WHERE IT FAILS
**8 Tobi intent families drive the problem.**

| Tobi intent family | Sessions | Misroute rate |
|---|---:|---:|
| **PX25** | 10,964 | **100.0%** ← every session |
| PX8 | 10,843 | 99.6% |
| PX9 | 17,446 | 99.2% |
| PX86 | 16,674 | 99.1% |
| PX71 | 6,631 | 94.0% |
| PX50 | 11,566 | 90.6% |
| PX43 | 16,386 | 90.0% |
| PX12 | 5,579 | 89.1% |

*Footnote:* Together these 8 families = **~30% of the KPI universe**
and misroute at **~95% on average**. Fix these and the headline
number drops dramatically.

---

## Slide 7 — WHERE IT WORKS
**Some intents route correctly ~70% of the time.**

| Intent | Misroute rate | Sessions |
|---|---:|---:|
| PX83 | 30.0% | 9,472 |
| PX68 | 30.1% | 12,750 |
| PX74 | 41.7% | 14,472 |

*Bottom line:* The routing infrastructure **can work**. The failure is
specific to 8 intent families, not systemic.

---

## Slide 8 — WHAT THIS ACTUALLY IS
# A taxonomy mismatch — not a routing bug.

Both systems classify customer intent. For a specific set of intent
families they use different labels for the same customer. The routing
may still deliver the customer to the right team — but our KPI
compares the **labels**, and the labels disagree.

**Old framing:** "Fix the routing." → Rebuild the routing model.
**New framing:** "Reconcile the taxonomies." → Fix 8 specific intent families.

*Footnote:* Orders of magnitude smaller in scope. This is the
positive story.

---

## Slide 9 — RECOMMENDATIONS
**Three actions.**

1. **Prioritise taxonomy reconciliation on 8 intent families.**
   PX25, PX8, PX9, PX86, PX71, PX50, PX43, PX12. Own-team meeting
   with Tobi and ACD leads. For each family, confirm what it
   represents on each side, and either align labels or add a
   translation layer.

2. **Build a live monitoring dashboard.**
   Once taxonomies are aligned, we need to watch the KPI move. Full
   spec ready — 8 panels, refresh daily, drill down by intent /
   queue / time / segment.

3. **Repeat the analysis quarterly.**
   Same SQL pipeline on updated (non-sampled) sources. Confirms the
   fix landed and catches regressions.

---

## Slide 10 — DASHBOARD PREVIEW
**Live monitoring for management and operations. 6 panels:**

1. **Headline KPI** — current misroute rate with target line at 30%. Traffic-lighted.
2. **Trend line** — weekly rate over time so we can see the fixes land.
3. **Worst-routed intents** — top 10 Tobi families by misroute rate. Priority list.
4. **Misrouting queues** — which ACD queues absorb the most misrouted traffic.
5. **Confusion heatmap** — Tobi × ACD family grid. Spot the specific confusion pairs.
6. **Time patterns** — 24×7 heatmap for regression detection.

*Footnote:* Estimated build time: **3 – 5 days** for polished version.
Full spec in the analysis repo (`docs/dashboard_spec.md`).

---

## Slide 11 — CAVEATS
**We disclose them up front.**

- **Sample data.** Analysis runs on a fixed 12-month window (17-Jul-2025 → 20-Jul-2026). When productionised on non-sampled sources the SQL translates 1-for-1.
- **The final measurable universe is 310K sessions** — ~2% of the full 16.1M Tobi sessions. Coverage funnel disclosed in the analysis repo.
- **PX103 is a large ACD destination** absorbing traffic from many Tobi families. Awaiting confirmation from the ACD team on whether it is a legitimate product family or a catch-all bucket.

*Footnote:* Every claim in this deck is traceable to a specific SQL
query in the repository. Nothing is hidden.

---

## Slide 12 — ASKS
# Three decisions.

1. **Endorse the workstream** — green-light the taxonomy-reconciliation workstream with Tobi and ACD leads, prioritised on the 8 families.
2. **Green-light the dashboard** — approve the build so we can monitor the KPI live.
3. **Establish cadence** — weekly 30-minute check-in during reconciliation to report on the misroute rate trend.

*Bottom line:* The problem is measurable, the cause is specific, and
the fix is scoped. We just need agreement to start.

---

## Slide 13 — APPENDIX / Q&A
**All metrics in one place.**

| Metric | Value |
|---|---:|
| Total Tobi sessions analysed | 16,134,799 |
| Sessions with Tobi intent extracted | 13,479,208 (83.5%) |
| Sessions transferred to an agent | 719,661 |
| KPI universe (both intent signals present) | 310,146 |
| Misrouted sessions | 235,378 |
| **Misroute rate** | **75.9%** |
| Worst-performing intent | PX25 (100%) |
| Best-performing intents | PX83, PX68 (~30%) |

*Footnote:* Full analytical trail — every query, every result, every
methodological decision — is documented in the analysis repository.

---

## How to use this file

**Option A — HTML deck (recommended):**
Open `docs/deck.html` in Chrome / Edge / Firefox. Press `F` for
fullscreen, arrow keys to navigate, `S` for speaker notes view,
`Esc` to exit. Works offline once loaded.

**Option B — PowerPoint / Google Slides:**
Copy each slide's content above into a new slide. Use your team's
template. Keep the numbers verbatim — they're all cross-verified.
