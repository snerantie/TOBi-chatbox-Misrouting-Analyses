# Step 1 — Identifying What the Customer Wanted in Tobi

*A plain-English walk-through of how we extract each customer's intent from
the Tobi chatbot logs, prepared for business stakeholders.*

---

## 1. The business question we are answering

> When a customer is transferred from Tobi to a live agent, are they landing
> in the **right queue**?
>
> Specifically: how often does a customer start with a **non-technical**
> question in Tobi but end up routed to **Technical Support**?

To answer that, before anything else we need one clean fact per customer
conversation:

> **What did this customer actually want when they were chatting with Tobi?**

That fact is what Step 1 delivers.

---

## 2. What the raw data looks like

Every customer chat with Tobi produces a **stream of log entries** — think of
it as a timeline of everything the customer clicked, said, or navigated
through during the conversation.

Each log entry is a coded string like `S_PX44_I1_E18_V210`. These codes are
Tobi's internal way of tagging *what state the conversation was in* at that
moment. Some codes correspond to real customer intents ("I want to check my
bill", "my internet is down"), and some correspond to system or navigation
events (menus, greetings, fallbacks).

For each conversation we have:

| Field | Meaning |
|---|---|
| `SESSION_ID` | The unique ID of the customer's Tobi conversation |
| `ROW_ID`, `MOMENT` | Together they give us the chronological order of events |
| `LOG` | The coded event, e.g. `S_PX44_I1_E18_V210` |

---

## 3. Why we can't just "pick the intent"

You might think: *"The intent is just whatever the customer said last, right?"*
Almost — but not quite. The last event in a conversation is often **not** a
real intent; it's a housekeeping event like "session closed", "handover
started", or "customer confirmed transfer".

If we naïvely took the very last log, we would be measuring plumbing events,
not customer intent. So we need a rule that skips over the housekeeping
events and lands on the last **real** intent the customer expressed.

**How big is this problem?** On 16.1 million Tobi sessions we looked at,
**~94% of conversations end on a non-intent event** (mostly bot or customer
message turns, and session-end markers). Only about 5% end directly on a
valid intent code, and less than 1% end on a housekeeping code we need to
skip. Bottom line: without the step-back rule, we would produce an intent
for only 1 in 20 conversations. **The rule is essential, not optional.**

---

## 4. The rule (in plain English)

For each conversation:

1. Put all the events in chronological order.
2. Look at the **last** event.
3. If that event is one of the known **housekeeping / non-intent events**,
   ignore it and step back to the previous one.
4. Keep stepping back until you find an event that *is* a real intent.
5. That event is the customer's intent for the conversation.

The list of events that count as "housekeeping" was provided by the Tobi
team. It includes:

- A handful of generic system events (`S_PX0_...`, `S_PX103_...`)
- The entire family of `S_PX102_...` events (transfer/handover mechanics)
- One malformed template string (`S_#!PX[varlubitoresult]!#`)

Anything not on that list is treated as a valid intent candidate.

---

## 5. A worked example

**Conversation 12345** produced three log events, in order:

| # | Event | What it represents |
|---|---|---|
| 1 | `S_PX25_I1_E12_V101` | A customer intent |
| 2 | `S_PX44_I1_E18_V210` | Another customer intent |
| 3 | `S_PX103_I0_E30_V615` | *Housekeeping* — on the exclusion list |

- Last event? → `S_PX103_I0_E30_V615`.
- On the housekeeping list? → **Yes**. Skip it.
- Step back → `S_PX44_I1_E18_V210`.
- On the housekeeping list? → No. **This is the customer's intent.**

Result: `Session 12345 → intent = S_PX44_I1_E18_V210`.

---

## 6. What the SQL actually does, in one paragraph

We take every event from the Tobi log table, drop the ones on the
housekeeping list, and for each conversation we keep only the **latest**
surviving event. That single event is stored as the conversation's intent,
alongside the timestamp so we know when it happened.

This is mathematically the same as "step back until you find a real intent",
just phrased in a way the database can execute in one pass instead of one
step at a time. **Same answer, faster.**

---

## 7. How we prove the output is trustworthy

Three checks are built into the pipeline:

| Check | What it proves | Expected result |
|---|---|---|
| **No leakage** | None of the housekeeping events slipped through into our intent output | 0 rows |
| **One intent per conversation** | We didn't accidentally produce duplicates | 0 rows |
| **Coverage** | Conversations where every single event was housekeeping (so we couldn't extract any intent) | A small, explainable count |

All three checks run automatically after the extraction. If any of them
comes back with unexpected numbers, the pipeline fails loudly rather than
silently producing a wrong dataset.

---

## 8. What Step 1 unlocks

Once every conversation has one clean intent attached to it, we can:

- Attach the **transferred-to-agent flag** (Step 2)
- Attach the **ACD queue** the call actually landed in (Step 3)
- Compare intent vs. queue and quantify the misrouting rate

Without Step 1, none of that is possible — the whole misrouting story starts
here.

---

## 9. Assumptions and limitations, stated up front

- **The housekeeping list is authoritative.** We are trusting the list
  provided by the Tobi team. If a code that *should* be treated as
  housekeeping is not on the list (or vice versa), it will bias the intent.
  A periodic review of that list with the Tobi team is recommended.
- **Intent categorisation is out of scope for Step 1.** We produce the raw
  intent code per conversation. Translating that code into "Technical" vs
  "Non-Technical" requires the official Tobi intent taxonomy, which we will
  request before running Step 3.
- **Data volume is a sample.** The tables used here are sample tables, not
  the full production feed. Final numbers should be produced against the
  non-sampled sources.

---

## 10. Bottom line

Step 1 gives every Tobi conversation a single, defensible answer to the
question *"what did this customer want?"* — after filtering out the noise of
system and navigation events. It is the foundation on which the misrouting
KPI will be built.
