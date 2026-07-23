# TOBi ↔ ACD Misrouting Dashboard — Specification

**Purpose:** live monitoring of the misrouting KPI for business owners
and operations leads, with drill-down into the "why" dimensions.

**Data source:** `tmp_misrouting_kpi` (built by `sql/09_misrouting_kpi.sql`).
Once productionised, swap the sampled sources for their non-sampled
equivalents; the SQL translates 1-for-1.

**Recommended tool:** Looker Studio / Tableau / Power BI — whichever the
BI team is standardised on. All panels are simple aggregations directly
against `tmp_misrouting_kpi`.

**Refresh cadence:** daily (or hourly if the underlying pipeline runs
that frequently on the live sources).

---

## Global filters (top of dashboard)

| Filter | Options | Default |
|---|---|---|
| Date range | last 7 / 30 / 90 days, custom | last 30 days |
| Customer segment | Consumer / Business / Pre-paid / Unknown / All | All |
| Tobi intent family | dropdown of all PX families | All |
| ACD queue | dropdown of `skill_acd` values | All |

Every panel below respects the global filters.

---

## Panel 1 — Headline KPI card (top-left, largest)

**What it shows:** current misroute rate as one big number.

**Data:**
```
SELECT
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 1) AS pct_misroute,
  COUNT(*) AS n_kpi_universe
FROM tmp_misrouting_kpi
WHERE <global filters>
```

**Visual:** giant number (e.g. "75.9%") with sub-caption "misroute rate
on N transferred sessions". Colour-coded (red > 50%, yellow 30–50%,
green < 30%). Target line at 30% (reflecting our best-routed families).

---

## Panel 2 — Trend line (top-right)

**What it shows:** misroute rate over time.

**Data:** same as Panel 1 but grouped by `DATE_TRUNC(intent_moment, WEEK)`.

**Visual:** line chart, X = week, Y = misroute %. Horizontal target
line at 30%. Overlay a second line showing volume (KPI universe size)
if space allows.

**Why it matters:** shows whether the taxonomy reconciliation is having
an effect (the number should trend down over weeks/months).

---

## Panel 3 — Top 10 worst-routed Tobi intent families

**What it shows:** which intents have the highest misroute rate.

**Data:**
```
SELECT
  tobi_family,
  COUNT(*) AS n_sessions,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 1) AS pct_misroute
FROM tmp_misrouting_kpi
WHERE <global filters> AND tobi_family IS NOT NULL
GROUP BY tobi_family
HAVING COUNT(*) >= 100
ORDER BY pct_misroute DESC
LIMIT 10
```

**Visual:** horizontal bar chart. Bar length = pct_misroute. Bar
colour by session volume (darker = higher volume). Include a change
indicator vs previous period (▲ or ▼).

**Why it matters:** priority list for the reconciliation workstream.

---

## Panel 4 — Top 10 misrouting queues

**What it shows:** which ACD queues receive the most misrouted traffic.

**Data:**
```
SELECT
  skill_acd,
  (skill_acd LIKE '% T') AS is_technical_queue,
  COUNT(*) AS n_sessions,
  COUNTIF(is_misroute_family = TRUE) AS n_misroute,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 1) AS pct_misroute
FROM tmp_misrouting_kpi
WHERE <global filters> AND skill_acd IS NOT NULL
GROUP BY skill_acd, is_technical_queue
ORDER BY n_misroute DESC
LIMIT 10
```

**Visual:** table with columns for queue name, T-suffix flag, session
count, misroute count, misroute rate. Highlight rows where
`is_technical_queue = TRUE` and misroute rate > 50% (technical queues
receiving heavy non-technical traffic — the operations pain point).

---

## Panel 5 — Confusion matrix (Tobi × ACD family)

**What it shows:** heatmap of Tobi PX family × ACD PX family.

**Data:**
```
SELECT
  tobi_family,
  acd_family,
  COUNT(*) AS n_sessions
FROM tmp_misrouting_kpi
WHERE <global filters>
GROUP BY tobi_family, acd_family
```

**Visual:** heatmap grid. Rows = top 20 Tobi families, columns = top 20
ACD families. Cell colour intensity = session count. Diagonal cells
(where `tobi_family = acd_family`) are correctly routed; off-diagonal
cells are misroutes.

**Why it matters:** at a glance, spot the specific Tobi→ACD confusion
pairs. E.g., "Tobi says PX36, ACD says PX103" is a hot cell.

---

## Panel 6 — Time-of-day heatmap

**What it shows:** misroute rate by hour × day-of-week.

**Data:**
```
SELECT
  EXTRACT(HOUR FROM intent_moment) AS hour_of_day,
  EXTRACT(DAYOFWEEK FROM intent_moment) AS day_of_week,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 1) AS pct_misroute,
  COUNT(*) AS n_sessions
FROM tmp_misrouting_kpi
WHERE <global filters>
GROUP BY hour_of_day, day_of_week
```

**Visual:** 24 × 7 heatmap. Cell colour = misroute rate. Cell size or
tooltip = session volume. Expected outcome: mostly flat, confirming
"not a time-based problem" — but useful for regression detection later.

---

## Panel 7 — Segment breakdown

**What it shows:** misroute rate by customer segment.

**Data:**
```
SELECT
  CASE
    WHEN customer_type IN ('Consumo', 'Consumer')       THEN 'Consumer'
    WHEN customer_type IN ('Empresarial', 'Business')   THEN 'Business'
    WHEN customer_type = 'Conta Pré-Paga'               THEN 'Pre-paid'
    ELSE 'Unknown/Other'
  END AS segment,
  COUNT(*) AS n_sessions,
  ROUND(100 * COUNTIF(is_misroute_family = TRUE)
        / NULLIF(COUNTIF(is_misroute_family IS NOT NULL), 0), 1) AS pct_misroute
FROM tmp_misrouting_kpi
WHERE <global filters>
GROUP BY segment
```

**Visual:** four large tiles, one per segment. Each shows the segment
name, session volume, and misroute rate.

---

## Panel 8 — Data quality panel (bottom, small)

**What it shows:** coverage funnel and known limitations.

**Content:**

- Total Tobi sessions in the source window: [N]
- Sessions with Tobi intent extracted: [N] ([%])
- Sessions transferred to an agent: [N]
- **KPI universe (all three signals present)**: [N] ← this is what everything above reports on
- Sample window: [start] to [end]
- Last refresh: [timestamp]

**Visual:** small text block, bottom of dashboard. Not glamorous but
essential — every business audience will ask "what's not in this
number?" and this panel answers it.

---

## Access & permissions

- **Business owners:** read-only access, all panels.
- **Data-science team:** read-write; can drill down into raw
  `tmp_misrouting_kpi` for ad-hoc analysis.
- **Ops leads:** read-only; can filter by their queue in the global
  filter.
- **Executive dashboard:** a stripped-down mobile-friendly version
  showing only Panels 1 and 2.

---

## Alerts (optional, phase 2)

- Misroute rate rises above baseline + 2 percentage points week-on-week
  → email/Slack alert to data science team.
- New Tobi intent family enters the top 10 worst-routed (i.e. wasn't
  there last week) → alert.
- KPI universe size drops materially (e.g. > 20% week-on-week) → alert
  (indicates a pipeline issue).

---

## Implementation notes

- All panels are simple aggregations on `tmp_misrouting_kpi`. No custom
  ETL required.
- The dashboard tool should connect directly to BigQuery for live data.
- Estimated build time (Looker Studio): 1 day for a working prototype,
  3–5 days for the polished version with all panels and filters.

---

## Not in scope for phase 1

- Live drill-down into individual session logs (privacy considerations).
- Predictive alerting (would require a separate ML model).
- Automated taxonomy reconciliation (business decision needed first).

Those become phase 2/3 once the initial dashboard is in production.
