# Keywordista Roadmap

## Thesis

**Keywordista is the indie developer's local-first ASO copilot.** It already wins at
*observation*. The next phase is climbing from observation → orientation → decision:
turning the data it already collects into trustworthy guidance about what to do next —
without ever becoming a $500/mo enterprise suite or breaking the local-first,
no-account ethos.

## The arc (OODA loop)

The product's direction maps onto the OODA loop, which also happens to map onto the
codebase:

| Stage       | State              | What lives here |
| ----------- | ------------------ | --------------- |
| **Observe** | Largely done       | rank history (`RankCheck`), chart watchdog, competitor metadata snapshots, top-5 incumbents (`TopResultSnapshot`), ASA/ASC keyword feeds |
| **Orient**  | Current frontier   | scoring, competitor keyword gap, metadata optimizer — *making collected data legible* |
| **Decide**  | Next phase         | recommendations + the AI/MCP copilot reasoning over the data |
| **Act**     | Directional        | push metadata changes back to App Store Connect (creds already wired) |

The spine of this roadmap is **moving up one OODA rung**, not shipping disconnected
features. Every Orient feature also becomes fuel for the Later AI bet — the copilot is
only as smart as the scores and gaps it can read.

## Now / Next / Later

Format is intentional: solo maintainer, no fixed dates. Now/Next/Later refuses to fake
precision. Each item is tagged with the **decision it unlocks** and **data feasibility**
(the real cost driver).

### NOW — make existing data legible (theme: Orient)

| Item | Decision it unlocks | Feasibility / caveat |
| ---- | ------------------- | -------------------- |
| **Competitor keyword gap view** | "What are competitors winning that I'm not?" | Cheap, **not free.** Competitors are currently filtered out of `rank_checks` (`.filter { $0.typedKind == .own }` in `RefreshService`) and `TopResultSnapshot` caps at top 5. Needs a small capture change: rank competitors too (bounded, polite to Apple). Builds on the existing compare page. |
| **Difficulty signal** | "Can I realistically rank for this?" | Cheapest real win. `TopResultSnapshot` already stores rating counts / age of the top 5 — a "giants vs. minnows above me" score is a function over data we already have. Ship **difficulty-only, clearly labeled.** |

> Discipline: NOW is two items, not five. Everything else waits.

### NEXT — turn legible data into guidance (theme: Orient → Decide)

| Item | Decision it unlocks | Feasibility |
| ---- | ------------------- | ----------- |
| **Metadata optimizer / linter** | "What should I put in my listing?" | Pure local compute on `AppMetadataSnapshot` (char budgets, duplicate words across title/subtitle, untracked title words). Cheap + satisfying. |
| **Opportunity score** (popularity × difficulty) | "Is this keyword worth chasing?" | **Gated on data-credibility** (see Risks). Popularity needs ASA, or a clearly-labeled proxy. Do not ship a fake composite. |
| **Keyword alerts + weekly digest** | "Where am I bleeding right now?" | Extends the existing chart watchdog. |

### LATER — directional bets (theme: Decide → Act)

| Item | The bet |
| ---- | ------- |
| **AI/MCP copilot** | The wedge. "Point Claude at your ASO data, ask what to change." Depends on the Now/Next Orient features existing — the AI needs scores + gaps to reason over. Local-first + MCP is something a hosted enterprise suite can't copy. |
| **Free keyword discovery** (autocomplete-based) | Unblocks the segment of users who don't run ASA campaigns. |
| **Closed loop** (push metadata to ASC) | Owns the whole OODA loop. High power, high risk. Directional only. |

### Explicitly NOT now (decisions, not omissions)

- **Reviews / ratings tracking** — a *tab* gap, not a *decision* gap for the user.
- **Estimated downloads / revenue** — no credible data → would be fake → erodes trust.
- **Android / Play Store** — scope explosion; breaks focus.

## Governing risk

**Data credibility.** Every Orient feature lives or dies on whether the numbers are
trustworthy. The **Opportunity Score is blocked** until the popularity-data question is
answered (can we compute a credible number from ASA / reachable proxies, or is a
half-accurate score worse than none?). Treat that investigation as the **gating
dependency for NEXT** — cheap to run, do it before committing to the score.
