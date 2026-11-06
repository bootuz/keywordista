# Apple Ads space (Phase 2) — design

Status: ready for approval · 2026-11-06 · builds on Phase 1 (PR #60, Platform API v1 client)

## Why

Keywordista already reads the user's Apple Ads data, but only in two hidden places:
keyword suggestions sit in a tab of a keyword's history panel, and the opportunity
score is a column on the dashboard. A user who runs Apple Ads can't see how their
ads perform or decide what to bid on without going to ads.apple.com.

The user wants two things from a dedicated **Apple Ads** area:

1. **See how the ads are performing.**
2. **See which keywords to bid on.**

Success is measured by cost per install. Revenue and return on ad spend are out of scope.

**"Installs" means tap installs** (my call) everywhere a number is computed:
CPI, CR (tap installs ÷ taps), "converted" and "wasted". This matches Apple's
own CPI (`tapInstallCPI`) and keeps CR meaningful, because view installs never
had a tap. Total installs (tap + view) is shown as a secondary column on
Overview, labelled as such.

## Market context (research, 2026-11-06)

- **The basics are free elsewhere.** MobileAction (which now owns SearchAds.com),
  SplitMetrics Acquire and AppTweak give away the basics below $10–25K/month of
  spend. The basics are a daily dashboard (spend, impressions, taps, installs,
  TTR, CR, CPT, CPI by campaign, keyword and country with period comparison), a
  search-terms view, bulk edits, rules and alerts.
- **The valuable parts cost money.** Revenue-based ROAS, bid automation,
  keyword-gap research and hourly data sit behind "contact sales" tiers or a 2–5%
  cut of spend. Indie-focused tools ($10–50/month, or AI agents that need approval
  for each change) are newer and small.
- **Gap 1: nobody puts paid and organic side by side.** No tool we found shows
  a keyword's ad results next to its organic rank for the same app. "Am I paying
  for a term I already rank #2 for?" goes unanswered. Keywordista already tracks
  organic rank, so this is its natural differentiator.
- **Gap 2: thin data looks like real data.** Common indie advice is to wait for
  about 50 taps per keyword before acting. Tools rarely say "not enough data yet".
- **Popularity has a long-tail gap.** Apple's search-term popularity endpoint is
  a ranked top list: it covers almost nothing below popularity 46. The user
  accepted this: keywords outside the list show no popularity.

## Goals

1. An **Apple Ads** entry in the sidebar, with four tabs: **Overview**,
   **Keywords**, **Bid ideas**, **Setup**.
2. **Overview.** For a chosen period (7 or 30 days) compared with the period
   before, show:
   - totals: spend, installs, cost per install, conversion rate (installs ÷
     taps), taps, impressions;
   - a per-campaign table with the same numbers and the campaign status;
   - a simple daily trend of spend and installs.
3. **Keywords.** List every keyword the user bids on, per country:
   - spend, taps, installs, CPT, CPI, CR, current bid, and Apple's bid
     recommendation when the report includes one;
   - the user's **organic rank** for the same term and country, when the
     keyword is tracked;
   - a flag when the user pays for a term they already rank highly for
     organically;
   - a "Track" action that starts organic tracking for an untracked term.
4. **Bid ideas.** Candidate terms, each shown with popularity (when Apple has
   it), organic rank and difficulty (when tracked), and a "Track" action:
   - **Converted search terms:** search terms that produced installs and aren't
     yet an exact-match keyword;
   - **Apple's keyword suggestions** for the app;
   - **Wasted spend:** search terms with spend and zero installs after enough
     taps (candidates for negatives; acting on them is Phase 3).
   - **Related to a keyword:** today's per-keyword suggestions, with a keyword
     picker. The history panel's "Related" tab stays as a shortcut to the same
     list (my call: the feature becomes visible in its own space without losing
     the in-context entry point). Both read synced data.
5. **Setup.** The Apple Ads credentials form and ad-account picker move here
   from the Settings panel, plus sync status (last sync, last error) and a
   **Sync now** button.
6. **Low-data marking.** CPI and CR are marked "not enough data" when the row
   has fewer than 50 taps in the period. They are never hidden.
7. **Local data.** All Apple Ads numbers are synced into Keywordista's database
   and read locally (approach B below).

## Non-goals (this phase)

- Revenue, LTV and ROAS (would need App Store Connect sales joined in).
- Any change to campaigns, bids, budgets, keywords or negatives. That's Phase 3.
- Rules, alerts, automation, dayparting, hourly data.
- Impression share, brand campaigns, multi-placement reporting.
- MCP tools for the new data. The data will be reachable later; no new tools now.
- The phrase-popularity lookup for long-tail keywords.

## Anti-goals

- A number that looks precise but is invented or rests on too little data.
- Hammering Apple's API: the sync stays polite and sequential.
- Acting on the user's ads account in any way.

## Approaches considered

- **A. Ask Apple live on every page view, with a short cache.**
  - For: no new tables.
  - Against: slow and blank when offline or rate-limited; the paid-vs-organic
    view needs a cross-source join on every request.
- **B. Sync daily into local tables, read locally (chosen).** A scheduled job
  pulls daily campaign, keyword and search-term numbers plus weekly popularity;
  backfills on first connect; manual refresh like keyword refresh.
  - For: instant, offline, and paid data sits next to rank history, so the
    differentiating view is a plain query; fits the local-first, scheduled-job
    design.
  - Against: tables, migrations, a sync job with backfill and revision edge
    cases; data is up to a day old without a manual sync.
- **C. Hybrid:** sync history, fetch the overview live.
  - Against: two data paths for little gain, since Apple's numbers for today
    are still settling anyway.

**The user chose B and asked for a manual refresh like the keywords one.**

## How (decided)

### Data

These are new Fluent models plus migrations. Names are the builder's call; contents
are decided:

- **Campaigns:** Apple ID, ad account ID, app (`promotedObjectId`, which matches
  `WatchedApp.appStoreId`), name, status, countries, daily budget and currency,
  last-synced time.
- **Ad keywords:** Apple ID, campaign, ad group, text, match type, status, bid,
  and currency.
- **Daily campaign metrics:** one row per campaign per day.
- **Daily keyword metrics:** one row per keyword, country and day, using the
  report's `countryOrRegion` group-by. Includes Apple's bid recommendation when
  present.
- **Daily search-term metrics:** one row per campaign, ad group, keyword
  (if any), search term, country and day. A null term is stored as `LOW_VOLUME`,
  matching Phase 1.
- **Search-term popularity:** one row per term, country, genre and week, holding
  1–100, 1–5 and rank in genre.
- **Sync runs:** started at, finished at, outcome, error text, date range
  pulled. Used by the Setup tab and the status chip.

Metric columns are the ones Apple reports that we display: impressions, taps,
tap installs, view installs, total installs, local spend (amount + currency),
plus CPT, CPI, TTR and CR computed from those rather than stored.

**Dates.** Dates are the org's reporting-timezone day (`ORTZ`), stored as
`yyyy-MM-dd`. Search-term reports only support ORTZ, so all reports use it for
consistency.

**This is a mirror, not an append-only log.** Apple revises recent days, so each
sync replaces the trailing window. This deliberately differs from `RankCheck`'s
append-only timeline, and the code must say so.

### Retention

- **While connected:** keep every synced day, with no pruning (my call; even
  daily search-term rows stay small for an indie account).
- **On disconnect** (`DELETE /settings/asa`): delete all synced Apple Ads data
  (campaigns, keywords, every metrics table, popularity, sync runs). This is the
  user's decision: disconnecting removes everything Keywordista copied from Apple.
  Apple keeps its own history, so reconnecting backfills 90 days again.
- **When the ad account changes** (a different `adAccountId` is saved, or the
  client ID changes, which clears it): delete the previous account's data the
  same way before the next sync. Every synced row carries its ad account ID, so
  stale rows can never be shown under the new account.

### Sync

- **The sync runs outside the queue worker** (my call), like the three
  existing daily jobs, with an in-process guard so only one sync runs at a time.
  Why: a 90-day backfill takes minutes, and on the single worker it would block
  keyword refreshes and inflate the refresh chip's pending count.
  `workerCount = 1` stays. Sync writes go in per-report transactions, so they
  can interleave with keyword-refresh writes under SQLite's busy timeout.
  Its status comes from the sync-runs table, not `_jobs`.
- **Daily schedule at 04:30 UTC**, after the three existing jobs (03:00, 03:30,
  04:00), so nothing stacks. It runs only when Apple Ads is configured and an ad
  account resolves.
- **Window:**
  - First sync, or a gap since the last good sync: backfill **90 days** (Apple's
    daily-report maximum span).
  - Otherwise: re-pull the **last 7 days** and replace them.
  - Popularity: the latest available week, for every keyword the user bids on or
    tracks and every Bid ideas candidate (my call, so that column isn't mostly
    empty), in their countries and the app's genre.
- **Manual "Sync now"** starts the same sync. If one is already running, it
  returns the running one instead of starting another. The SPA polls the sync
  run's status and shows a progress chip like keyword refresh.
- **Failure handling:** a failed sync records its `AppleAdsError` text on the
  sync run and leaves previously synced data intact. Setup shows the error, and
  Overview shows a one-line notice with the time of the last good sync.
- **Rate:** sequential requests, the Phase 1 retry middleware for 429s, and
  pagination at 5000 rows.

### Existing features

- **Suggestions and opportunity score** read the synced search-term data instead
  of calling Apple live. Their user-visible behavior stays the same, and they
  get faster. The "rethrow when every report fails" rule from Phase 1 becomes
  "show the last sync's error when there is no synced data".
- The dashboard keeps its opportunity column; it's about tracked keywords.

### UI

- **Navigation.** The sidebar gets an **Apple Ads** entry. The route is
  `/apple-ads`, with tabs as sub-routes or a tab state (builder's call); all
  routes go in `ROUTES`.
- **App scope.** The area follows the app switcher (`currentAppId`) and shows
  campaigns whose `promotedObjectId` matches the current own app. If the
  account has campaigns for apps the user doesn't watch, Overview mentions how
  many, with no data shown.
- **Not configured yet.** Every tab except Setup shows a short empty state that
  links to Setup.
- **Settings panel.** The Apple Ads section is replaced by a one-line link to
  Apple Ads → Setup.
- **Copy.** Say "Apple Ads", never "Search Ads" or "ASA", in all user-facing
  text, including the strings that move.

### Server mode (teams)

- Every signed-in member can view the area and press Sync now; Sync now is
  treated like keyword refresh.
- Setup changes stay admin-only, through the existing settings endpoints.

### Thresholds (my calls)

- **Low data:** fewer than 50 taps in the row's period.
- **"You already rank well" flag:** organic rank 1–5 in the same country, from
  the latest rank check.
- **Wasted spend:** at least 50 taps and zero installs in the period.
- **Converted search term:** at least 1 install in the period, and not already
  an exact-match keyword in any campaign.

## Left to the builder

- Table and column names, indexes, migration split.
- Whether tabs are sub-routes or in-page state.
- Chart rendering. The SPA has no chart library: hand-rolled SVG is fine, and
  adding a dependency needs a reason.
- How to batch popularity queries (filter `searchTerm IN …`, by country and genre).
- How the app's genre maps to Apple's popularity genre values. If no mapping
  exists for an app, skip popularity for it.
- How to pull Apple's keyword suggestions: during sync, cached per app, or on
  demand when Bid ideas opens.

## Open questions (not answerable without a live account)

1. Whether report rows come back in the shapes the generated types claim. Phase 1
   has the same open question.
2. How many days Apple keeps revising. Seven is a guess.
3. Whether `insights.bidRecommendation` appears on keyword rows for small accounts.
