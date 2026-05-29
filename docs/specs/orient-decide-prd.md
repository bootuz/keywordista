# PRD: Orient → Decide layer (NOW + NEXT)

> Spec for the roadmap's NOW + NEXT horizons. See [docs/roadmap.md](../roadmap.md) for
> the thesis and sequencing. This batch moves Keywordista up the OODA loop from
> *Observe* (done) into *Orient* and the first step of *Decide*.

## Shared frame

**Who:** the indie developer running Keywordista on their own apps. The user *is* the
customer — there is no funnel, so success is measured by **decisions enabled**, not
adoption curves.

**Shared non-goals (apply to every feature below):**
- No paid/enterprise data sources (Sensor Tower-style crawled corpora). Everything must
  derive from data Keywordista can already reach (iTunes search, `TopResultSnapshot`,
  `AppMetadataSnapshot`, ASA/ASC).
- No fabricated numbers. A signal we cannot compute credibly is **not shown** rather than
  shown wrong — trust in the dashboard is the core asset.
- No Android/Play Store. No reviews/ratings tracking (deferred — a tab gap, not a
  decision gap).
- Keep the iTunes contract: `workerCount = 1`, ~1 req/sec, storefront-aware.

---

## Feature A — Competitor keyword gap view  *(NOW)*

**Problem.** The user tracks competitors' *metadata* and can compare listings, but cannot
answer the question that compare page silently begs: *"across the keywords I track, where
do my competitors out-rank me — and which terms do they win that I'm not even watching?"*

**Goals.**
- Surface, per tracked keyword, the user's rank vs. each tracked competitor's rank.
- Make "competitor beats me by the largest margin" sortable, so the worklist is obvious.
- Expose the same gap data via MCP so it can be reasoned over by an AI copilot later.

**Non-goals.** Discovering competitor keywords *outside* the tracked set (that needs a
keyword corpus — deferred to Free keyword discovery). Tracking unlimited competitors.

**User stories.**
- As an indie dev, I want to see where each competitor out-ranks me on my tracked
  keywords, so I know which terms to fight for.
- As an indie dev, I want to sort by gap size, so I spend effort where I'm losing most.

**Requirements.**
- **P0** — Capture competitor app ranks during refresh (today they are filtered out of
  `rank_checks`). Gap query joining own vs. competitor rank per keyword. API + a sortable
  web view.
  - *Given* a competitor is tracked and a keyword refresh has run, *when* I open the gap
    view, *then* I see my rank and the competitor's rank side by side for each keyword,
    with the delta.
  - *Given* a competitor ranks for a tracked keyword and I do not, *then* that row is
    flagged as a pure gap (they're in, I'm out).
- **P1** — MCP tool exposing the gap data.
- **P2** — Gaps for keywords *outside* the tracked set (depends on discovery corpus).

**Open questions.**
- *(engineering)* Reuse `rank_checks` with competitor `watched_app_id`, or a separate
  table? The code comment in `RefreshService` warns competitor rows would "litter
  `rank_checks`". **Blocking** — decided in task A1.

---

## Feature B — Difficulty signal  *(NOW)*

**Problem.** Every tracked keyword looks equal. The user can't tell a winnable term from
one owned by 500k-review giants, so effort is mis-allocated.

**Goals.**
- Give each keyword a **difficulty indicator** derived from the strength of the apps
  currently ranking at the top.
- Ship it **clearly labeled as an estimate** — difficulty only, no fake popularity.

**Non-goals.** Popularity/volume (separate, gated feature). A composite opportunity score
(Feature D).

**User stories.**
- As an indie dev, I want to see how contested a keyword is, so I can avoid chasing terms
  I can't realistically win.

**Requirements.**
- **P0** — Difficulty scoring function over `TopResultSnapshot` (rating counts, average
  rating, app age of the top 5). Surfaced in the keyword API + a labeled UI indicator.
  - *Given* a keyword's top-5 incumbents all have very high rating counts, *then* its
    difficulty reads "hard"; *given* mostly small apps, *then* "winnable".
  - *Given* there is no `TopResultSnapshot` data yet, *then* difficulty shows "unknown",
    never a fabricated value.
- **P1** — Expose difficulty via MCP keyword tools.
- **P2** — Feed difficulty into the opportunity score (Feature D).

**Open questions.**
- *(data)* Exact weighting of rating-count vs. age vs. rating value. Non-blocking —
  tune during implementation; start with rating-count-dominant.

---

## Feature C — Metadata optimizer / linter  *(NEXT)*

**Problem.** The user has no quick check that their listing is *indexing efficiently* —
wasted characters, words duplicated across title/subtitle/keyword field, or title words
they aren't even tracking.

**Goals.**
- Lint a watched app's metadata and surface concrete findings with severity.
- 100% local computation over `AppMetadataSnapshot` — no new data source.

**Non-goals.** Auto-rewriting metadata. Pushing changes to App Store Connect (that's the
Later "closed loop" bet).

**User stories.**
- As an indie dev, I want to see if I'm wasting characters or duplicating words across my
  indexed fields, so I can reclaim ranking surface.
- As an indie dev, I want to see title/subtitle words I'm not tracking, so I can start
  watching them.

**Requirements.**
- **P0** — Rules engine: character-budget usage (30 title / 30 subtitle / 100 keyword
  field), duplicate words across fields, indexed words not in tracked keywords. API +
  findings UI with severity.
  - *Given* a word appears in both title and keyword field, *then* a "duplicate
    indexing" finding is raised.
  - *Given* the keyword field uses 60/100 chars, *then* a "wasted budget" finding is
    raised.
- **P1** — MCP tool exposing optimizer findings.

**Open questions.** None blocking — depends only on existing snapshots.

---

## Feature D — Opportunity score  *(NEXT — gated)*

**Problem.** Difficulty alone doesn't answer "is this worth it?" — a winnable keyword
nobody searches is worthless. The user needs **popularity × difficulty** in one number.

**Goals.**
- A single opportunity score per keyword **only if** popularity can be sourced credibly.

**Non-goals.** Shipping a composite score before the popularity input is trustworthy.

**User stories.**
- As an indie dev, I want one "is this keyword worth chasing?" number, so I can rank my
  whole watchlist by opportunity.

**Requirements.**
- **P0 (research)** — Popularity-data feasibility spike: can we get a credible popularity
  number from ASA / reachable proxies (autocomplete presence, result-set size), or is a
  half-accurate score worse than none? Output: a decision doc. **This blocks all build
  work below.**
- **P0 (build, post-spike)** — Popularity signal + opportunity score = f(popularity,
  difficulty). Requires the difficulty signal (Feature B).
- **P1** — UI + MCP exposure.

**Open questions.**
- *(data, BLOCKING)* Is credible popularity reachable without paid data? Resolved by the
  spike (task D0).

---

## Feature E — Keyword alerts + weekly digest  *(NEXT)*

**Problem.** The user only learns about rank drops or competitor moves by manually
opening the app. The chart watchdog already proves the pattern for chart events.

**Goals.**
- Alert on meaningful keyword-rank changes (drop out of top N, large slide).
- Alert on competitor metadata changes (title/subtitle edits).
- A periodic digest summarizing movement.

**Non-goals.** Real-time/push infrastructure beyond the existing notification mechanism.

**User stories.**
- As an indie dev, I want to be told when I fall out of the top 10 for a keyword, so I can
  react before losing more ground.
- As an indie dev, I want a weekly summary, so I stay aware without checking daily.

**Requirements.**
- **P0** — Rank-change detection over `rank_checks` (reuse watchdog pattern). Competitor
  metadata-change detection over `AppMetadataSnapshot`. Digest aggregation + delivery.
  Alerts settings UI.
  - *Given* my rank for a keyword drops from 8 to 14, *then* a "fell out of top 10" alert
    fires once.
- **P1** — Configurable thresholds.

**Open questions.**
- *(engineering)* Reuse `ChartEvent`-style storage or a generic alerts table?
  Non-blocking.

---

## Success metrics (right-sized for a single-user tool)

Not adoption funnels. Per feature, the bar is: **does it change what the user does?**
- Competitor gap / difficulty / opportunity: the user can name a keyword they
  started/stopped chasing *because of* the signal.
- Optimizer: the user makes at least one metadata edit prompted by a finding.
- Alerts: the user reacts to a drop they'd otherwise have missed.

## Sequencing & cross-feature dependencies

- **Parallel non-blocked entry points:** A1 (capture competitor rank), B1 (difficulty
  function), C1 (linter engine), D0 (popularity spike), E1 (rank-change detection).
- **Key cross-epic edge:** the opportunity score (D) is blocked by the difficulty signal
  (B1) *and* the popularity spike (D0) — this is the "Orient feeds Decide" rung made
  concrete.
