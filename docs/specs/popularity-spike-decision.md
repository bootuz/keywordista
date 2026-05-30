# Spike: keyword popularity data feasibility (#43)

**Question:** Can Keywordista source a *credible* keyword-popularity signal to power an
opportunity score (popularity × difficulty), within its constraints — local-first,
single-user, free, **no fabricated numbers**?

**Short answer: No — not as a universal, credible number.** A real popularity score is
only available behind gray-area scraping or paid APIs. What *is* legitimately reachable
is narrower: real ASA impressions for the user's own campaign terms, and a clearly-labeled
heuristic proxy. Recommendation below.

## What's reachable, and what it costs

| Source | What it gives | Reachable here? | Verdict |
| --- | --- | --- | --- |
| **Official ASA Campaign Management API** (`api.searchads.apple.com`, OAuth — codebase already authenticates) | Campaigns, keywords, and **reports** (impressions/taps/spend) for *your own* campaign terms. **No** generic Search Popularity for arbitrary keywords. | ✅ already integrated (`AppleSearchAdsClient`, `KeywordSuggestionService` mines search-terms reports) | **Real but sparse** — only terms your campaigns actually served. |
| **ASA internal/dashboard endpoint** (powers ads.apple.com UI) | The real **Search Popularity score (5–100)** + recommendations for any keyword. | ⚠️ requires reverse-engineered session auth; **not** the official API | **Gray-area + brittle.** Also, since **Oct 2025 Apple only returns SP ≥ 35** — the long tail blanks. Violates the ethos. |
| **Paid third-party APIs** (Apify ~$0.02/kw, AppTweak, etc.) | Official SP resold | 💸 costs money | Against local-first/free ethos. |
| **Free heuristic proxy** (à la `facundoolano/aso`) | An *estimated* "traffic" score from autocomplete-presence + top-10 competition | ⚠️ needs a new autocomplete client (the old `MZSearchHints` endpoint is **dead** — returns empty; modern autocomplete is the token-gated `amp-api` endpoint) | **Ordinal estimate, not volume.** Risk: a confident-looking fake number erodes trust in every number (the exact failure the roadmap warned about). |

Notes from the spike:
- The classic `search.itunes.apple.com/.../MZSearchHints` endpoint was tested live and now
  returns an **empty** hints array — dead for App Store autocomplete.
- Difficulty is *already solved* and universal (`HeuristicScorer` over `TopResultSnapshot`) —
  it needs no external popularity data.

## Implications for the Opportunity Score epic (D, #44–#47)

A universal "opportunity score" requires a universal popularity input, which we've shown
isn't credibly/legitimately available. Shipping a composite score backed by a guessed
popularity number would fabricate confidence — explicitly forbidden by the roadmap.

### Options

- **A — ASA-backed, where real (recommended).** Surface ASA search-terms **impressions**
  on tracked keywords *that have campaign data* (already mined by `KeywordSuggestionService`).
  Show it as "ASA impressions," not a universal popularity score. Difficulty shows
  everywhere (already shipped); a true opportunity score appears only for ASA-covered
  keywords, clearly labeled. **No fabricated numbers.** Delivers real value to ASA users;
  degrades to difficulty-only for everyone else.
- **B — Labeled heuristic proxy.** Build the `amp-api` autocomplete client + combine
  autocomplete-presence with competition into an explicitly-labeled "estimated demand"
  indicator (low/med/high, not a number). Universal coverage, but trust risk; must be
  visibly an estimate.
- **C — Kill the composite.** Keep difficulty-only (shipped). Don't build D. Lowest risk,
  least value.

### Recommendation

**Option A.** It's the only path that yields a *real* popularity signal without scraping,
paid data, or fabrication — and most of the plumbing exists. Reframe the epic:
- **#44** → "Surface ASA impressions on tracked keywords where campaign data exists."
- **#45** → Opportunity score = impressions × difficulty, **only for ASA-covered keywords**,
  clearly labeled; difficulty-only otherwise. (Drop the universal-score ambition.)
- **#46 / #47** (UI / MCP) follow, with explicit "ASA-only" framing and graceful empty state.

Optionally pursue **B** later as a clearly-labeled "estimated demand" hint if universal
coverage proves worth the trust risk.

## Sources
- [Apple Ads Campaign Management API 5](https://developer.apple.com/documentation/apple_ads/apple-search-ads-campaign-management-api-5)
- [How Apple Search Popularity works (Sonar)](https://trysonar.app/blog/apple-search-popularity)
- [Apple SP unreliable for ASO (RespectASO)](https://respectaso.com/blog/apple-search-ads-popularity-unreliable-aso-keyword-data/)
- [facundoolano/aso — heuristic scores, no official API](https://github.com/facundoolano/aso)
