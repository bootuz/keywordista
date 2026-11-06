# Apple Ads Platform API v1: wire-protocol reference for the Swift port

## Sources and how each item is labelled

- **[ASC]**: the `asc` CLI Go source, tag `6.5.0` (commit `08c8ffcefbc57210cfe829bd00a4b695f192752d`), cloned from `bootuz/App-Store-Connect-CLI`. That repo is a fork of `rorkai/App-Store-Connect-CLI` and has the same tag. Main files:
  - `internal/appleads/{auth.go, client.go, errors.go, pagination.go, endpoints.go, platform_endpoints_campaigns.go, platform_endpoints_reports.go, testdata/platform_v1_endpoints.tsv}`
  - `internal/cli/ads/{endpoints.go, search_optimization.go, auth.go, workflows.go}`
  - `docs/design/apple-ads-platform-api-v1.md`, `docs/release-notes-apple-ads-v5-removal.md`
- **[DOCS]**: Apple's DocC JSON for `https://developer.apple.com/documentation/apple-ads-platform-api/...`. I crawled all 755 pages through `developer.apple.com/tutorials/data/documentation/apple-ads-platform-api/<page>.json`. Each doc citation below is that base URL plus the page slug.
- **[BOTH]**: the two sources agree.


Apple's changelog says v1.0 was "Released in August, 2026" and that the Campaign Management API sunsets on **January 26, 2027** [DOCS `changelog-apple-ads-platform-api`].

I ran no live API calls; everything below comes from source and docs.

---

## 0. Global wire conventions (read first)

| Topic | v1 fact | Source |
|---|---|---|
| Base URL | `https://api.ads.apple.com/v1/` (v5 used `https://api.searchads.apple.com/api/v5/`) | [BOTH] `client.go` `PlatformBaseURL`; DOCS `calling-apple-ads-platform-api` |
| Casing | camelCase JSON everywhere. Enums are UPPER_SNAKE, except geo entity types (`Country`, `AdminArea`, `Locality`, `PostalCode`) and groupBy values (`countryOrRegion`, `deviceClass`, …) | [DOCS] |
| Success envelope | `{"result": <object or array>, "pagination": {...}?}`. There is no `data` key; v5's `data` became `result` | [BOTH] DOCS `response`, `queryresponse`; ASC `pagination.go` (`platformPaginatedEnvelope{Result, Pagination}`) |
| Query pagination (response) | `{"offset": int, "pageSize": int, "totalCount": int64?}`. `pageSize` is the **number of rows actually returned**, not the size you requested. `totalCount` only appears when the request sets `fetchTotalCount: true`. Apple's last-page rule is `offset + pagination.pageSize >= totalCount` | [DOCS] `querypaginationresult` |
| Query pagination (request) | `{"offset": int32, "pageSize": int32 (max 1000), "fetchTotalCount": bool (default false)}`. v5's `limit` is now `pageSize` | [BOTH] DOCS `querypagination`; ASC `endpoints.go` migration guard |
| Report pagination (request) | `{"offset": int, "pageSize": int}`, max **5000**, default 100 | [DOCS] `requestpagination` |
| List vs find | Almost every list is now `POST /v1/<entity>/query` with a `QueryRequest` body. GET lists are gone, except `GET /v1/search/apps` and `GET /v1/search/geo` | [BOTH] |
| Hierarchy | Entities are top-level resources. There are no nested `/campaigns/{id}/adgroups/...` paths; you scope with filters (`campaignId`, `adGroupId`) | [DOCS] `calling-apple-ads-platform-api` |
| Partial update | `PUT` changes only the fields you send. **Arrays replace wholesale** | [DOCS] |
| Money | `{"amount": "<decimal string>", "currency": "<ISO 4217>"}`. `amount` is required and is a **string**; no leading zeros (`"5.00"`, not `"05.00"`). Currency must equal the ad account's `currency` | [DOCS] `money` |
| Date-times | Format `yyyy-MM-dd'T'HH:mm:ss.SSS` with **no zone designator** (e.g. `"2025-09-01T00:00:00.000"`); entity schedule times are UTC. `ISO8601DateFormatter` will **not** parse this. Use a `DateFormatter` with that exact format and a UTC zone, or keep the value as `String` | [DOCS] `campaign`, `campaigncreate` |
| Report dates | `timeRange.start`/`end` are `YYYY-MM-DD`. Metric `date` is `YYYY-MM-DD`, or `YYYY-MM-DD HH` for HOURLY | [DOCS] `timerange`, `appsmetrics` |
| IDs | The docs schema types every entity id as **int64**: `id`, `adAccountId`, `campaignId`, `adGroupId`, `orgId`, `userId`, ACL `adAccount.id`, `AppInfo.adamId`. **Strings** are `promotedObjectId`, `AppDetails.id`, and every path parameter (`{id}`). **Conflict:** asc's release notes say "V1 responses use … string resource IDs", and asc decodes IDs with a `flexibleInt64` that accepts both `123` and `"123"`. The generic `QueryResponse`/`Response` doc examples also show `"id": "123456789"`. **Decode IDs tolerantly (accept number or string).** | [DOCS] vs [ASC] `search_optimization.go` `flexibleInt64`, `release-notes-apple-ads-v5-removal.md` |
| Filter `value` type | Doc examples are inconsistent: ad-group and keyword queries send numbers (`"value": 444555666`), while the search-term report example sends strings (`"value": "444555666"`) and the `AppsReportingRequest` example sends `["444555666"]`. asc sends int64 for `campaignId`. `promotedObjectId` filters always use strings | [DOCS]/[ASC] |
| Deletes | Soft delete. `HTTP 200`, body `{}` | [DOCS] `delete-campaigns-_id_` |

---

## 1. Auth

### 1.1 Client-secret JWT — [BOTH]
(DOCS `implementing-oauth-for-the-apple-ads-platform-api`; ASC `internal/appleads/auth.go` `GenerateClientSecret`)

- **Header:** `{"alg": "ES256", "kid": "<keyId>"}`. The private key is EC P-256 (`prime256v1`) PEM.
- **Claims:**
  - `iss` = **teamId** (e.g. `SEARCHADS.9703f56c-…`)
  - `sub` = **clientId** (e.g. `SEARCHADS.27478e71-…`)
  - `aud` = `"https://appleid.apple.com"`
  - `iat` = Unix seconds
  - `exp` = Unix seconds; must be later than now and at most 180 days after `iat`
- asc signs a fresh 10-minute secret per token refresh and backdates `iat` by 60 s. Apple's sample uses a 180-day secret. Either is valid.
- `clientId`, `teamId` and `keyId` are the three values shown in the Ads UI (Account Settings > API) after you upload the public key.

### 1.2 Token exchange — [BOTH]

```
POST https://appleid.apple.com/auth/oauth2/token
Content-Type: application/x-www-form-urlencoded
(Apple's docs also list Host: appleid.apple.com)

grant_type=client_credentials&client_id=<clientId>&client_secret=<JWT>&scope=searchadsorg
```

Response:
```json
{"access_token":"eyJ…","token_type":"Bearer","expires_in":3600,"scope":"searchadsorg"}
```

- asc sends these as form body fields. Apple's first curl example puts them in the query string; its second example (`access-overview`) uses `-d` body fields.
- On OAuth failure the error body is `{"error":"invalid_client" | "invalid_grant" | "unauthorized_client"}` [ASC].
- **The scope is still `searchadsorg`** and the token endpoint is unchanged from v5 [BOTH]. asc's design doc: "OAuth token endpoint, client-secret JWT, and `searchadsorg` scope remain unchanged."

### 1.3 Do existing v5 credentials work for v1?

- The OAuth procedure, key type, claims, endpoint and scope are byte-for-byte the same as v5 [DOCS].
- asc uses one stored credential (client ID, team ID, key ID, private key) for v1, and keeps `--org`/`org_id` only as informational context.
- No Apple page says outright "your v5 API user keeps working", so this is **strongly implied, not verified live**.
- **You cannot reuse a stored client-secret JWT forever:** it has an `exp` of at most 180 days. If you currently store a user-generated secret rather than the private key, you still need to regenerate it before it expires. That is the same as v5.

### 1.4 Headers on API calls

- `Authorization: Bearer <access_token>` [BOTH]
- `Accept: application/json`, plus `Content-Type: application/json` when there is a body [ASC `client.go`]
- **Context header:** `X-AP-Context: adAccountId=<adAccountId>`
  - This replaces v5's `X-AP-Context: orgId=<orgId>`.
  - Apple's docs show it **without** a trailing semicolon. asc sends `adAccountId=<id>;` **with** one (`client.go` `contextHeader`), and asc rejects ids containing `;` or control characters.
  - I couldn't confirm live which forms the server accepts. Use Apple's documented form.
- **Omit the context header** on `GET /v1/me`, `GET /v1/acls`, `GET /v1/orgs/{id}`, `GET /v1/advertiser-resources` and `POST /v1/ad-accounts` [BOTH].
- Budget-order (`/v1/shared-budgets`) endpoints are org-scoped. asc omits the header on create/update/delete and sends it optionally on view/query [ASC `platform_endpoints_campaigns.go`].
- Every other endpoint in this report requires the header.

---

## 2. Account discovery

### 2.1 `GET /v1/me` (no context header) — [BOTH]
DOCS `get-current-user-details`, `me`, `meresponse`

```json
{ "result": { "userId": 3962840, "orgId": 27154130 } }
```

`Me`: `userId: int64`, `orgId: int64`. `MeResponse`: `result: Me`, `error: Error?`.

### 2.2 `GET /v1/acls` (no context header) — [BOTH]
DOCS `get-user-acls`, `useracllistresponse`, `useraccessresult`, `useracl`, `acladaccount`

```json
{ "result": { "acls": [ { "adAccount": { "id": 123456789, "name": "AwayFinder", "orgId": 40669820 }, "roles": ["Admin"] } ] } }
```

- **Shape change from v5:** `result` is an **object** wrapping `acls`, not a bare array.
- `AclAdAccount`: `id: int64`, `name: string`, `orgId: int64`.
- Role strings: `Admin`, `API Account Manager`, `API Account Read Only`, `Limited Access: API Read & Write`, `Limited Access: API Read Only`.
- "Each access token binds to exactly one org. The `orgId` on every returned `adAccount` will be the same."
- An empty `acls` means the org has no ad accounts yet. Create one with `POST /v1/ad-accounts`, which needs `name` plus exactly one `productFeatures` value (`APPSTORE_APP_MANUAL` | `BUSINESS_BRAND_MANUAL`) [ASC validation].

### 2.3 Getting the ad account ID; v5 orgId mapping

- The **ad account ID is `result.acls[].adAccount.id`**. It is not the org ID [BOTH]. asc's `auth discover` reads exactly this field, and asc never falls back from `--org` to `--ad-account`.
- **Mapping a v5 orgId:** no official mapping or migration doc exists. What the docs do say:
  - The old v5 org corresponds to the v1 **Org** (`Me.orgId`, `GET /v1/orgs/{id}`).
  - An Org owns one or more Ad Accounts ("Org → Ad Accounts → Campaigns").
  - Practical mapping: call `/v1/acls` and pick the `adAccount` whose `orgId == oldOrgId`. If there are several, pick one with `productFeatures` containing `APPSTORE_APP_MANUAL` (check via `GET /v1/ad-accounts/{id}`).
- Whether Apple auto-created one ad account per v5 org, and whether old v5 campaign IDs carry over, is **not documented**.

### 2.4 `GET /v1/ad-accounts/{id}` (header `adAccountId` must equal the path id) — [BOTH]
DOCS `access-overview`, `adaccount`

```json
{"result":{"id":123456789,"name":"AwayFinder Ad Account","orgId":27154130,"timezone":"America/New_York","currency":"USD","paymentModel":"PAYG","systemStatus":"ACTIVE","systemStatusReasons":[],"productFeatures":["APPSTORE_APP_MANUAL"],"delegations":[{"resourceId":"12345678","resourceType":"CONTENT_PROVIDER","resourceName":"AwayFinder Apps"}],"creationTime":"2025-01-10T08:00:00.000","modificationTime":"2025-01-10T08:00:00.000"}}
```

- App Store campaigns need both `productFeatures: ["APPSTORE_APP_MANUAL"]` and a `CONTENT_PROVIDER` delegation whose `resourceId` is the CPID.
- `currency` and `timezone` are what you must use for Money and for `ORTZ` reports.
- Enums: `paymentModel` = `PAYG` | `LOC`; `systemStatus` = `ACTIVE` | `INACTIVE`.

---

## 3. Campaigns

### Enums and shared types [DOCS]

- `CampaignStatus`: `ENABLED` | `PAUSED`. This is the only pause/resume control.
- `CampaignSystemStatus`: `RUNNING` | `NOT_RUNNING`.
- `CampaignDisplayStatus`: `RUNNING` | `PAUSED` | `ON_HOLD` | `LIMITED` | `PROCESSING` | `DELETED`.
- `systemStatusReasons`: about 33 values (e.g. `PAUSED_BY_USER`, `DELETED_BY_USER`, `APP_NOT_ELIGIBLE`, `BUDGET_ORDER_EXHAUSTED`, `SCHEDULE_PENDING`, …). `systemStatusLimitingReasons`: about 24 values. **Decode both as `[String]`.**
- `BillingEvent`: `TAPS` | `IMPRESSIONS` (IMPRESSIONS is Maps-only). App Store campaigns use `TAPS`.
- `PromotedObjectType`: `APPSTORE_APP` | `BUSINESS_BRAND`.
- `PaymentModel`: `PAYG` | `LOC`.
- `BidStrategyType`: `MANUAL_CPT` | `MANUAL_CPM` | `MAX_CONVERSIONS` | `MAX_ENGAGEMENTS`.
- `BidStrategyGoal`: `TAP` | `IMPRESSION` | `INSTALL`. Allowed pairs: `MANUAL_CPT`↔`TAP`, `MANUAL_CPM`↔`IMPRESSION`, `MAX_CONVERSIONS`↔`INSTALL`, `MAX_ENGAGEMENTS`↔`TAP`. Type and goal must always be sent together.
- `BidStrategy`: `{bidStrategyType, bidStrategyGoal, bid: Money?}`.
- Targeting dimension shape: `{"include": [String], "exclude": [String]?}`. At campaign level the dimensions are include-only.
- **Daily budget is wrapped:** `dailyBudget: {"value": Money}`. **Breaking change from v5's `dailyBudgetAmount: Money`.**
- `sharedBudgets: [{"budgetId": int64}]` (budget orders).
- `regulationResponses: [{"regulationType": "CAMPAIGN_SAPIN_LAW", "responseValue": "NOT_ANSWERED" | "NOT_AGENT" | …}]`.

### `Campaign` (response) fields [DOCS `campaign`]

- **IDs and naming:** `id` int64, `adAccountId` int64, `name`, `deleted` bool.
- **Promoted object and billing (read-only after create):** `promotedObjectType`, `promotedObjectId` **string**, `billingEvent`, `paymentModel`.
- **Schedule and timestamps:** `startTime`, `endTime`, `creationTime`, `modificationTime`.
- **Status:** `status`, `systemStatus`, `systemStatusReasons`, `systemStatusLimitingReasons`, `displayStatus`.
- **Budget:** `dailyBudget{value: Money}`, `sharedBudgets[]`.
- **Targeting:**
  - Shape: `targeting{supplySource, supplyPlacement, countryOrRegion}`, each dimension `{include: [String]}`.
  - Values: `supplySource` ∈ `APPSTORE`, `MAPS`; `supplyPlacement` ∈ `APPSTORE_SEARCH_RESULTS`, `APPSTORE_SEARCH_TAB`, `APPSTORE_TODAY_TAB`, `APPSTORE_PRODUCT_PAGES`, `MAPS_SEARCH_RESULTS`, `MAPS_SEARCH_HOME`; `countryOrRegion` = ISO alpha-2 codes.
  - **Country/storefront list moved here:** it lives under `targeting.countryOrRegion.include`, not v5's top-level `countriesOrRegions`.
- **Other:** `bidStrategy`, `invoiceDetail` (`name`, `orderNumber`, `clientName`, `primaryBuyerName`, `primaryBuyerEmail`, `billingEmail`), `regulationResponses`.
- **Removed from v5:** `adChannelType` and `supplySources` no longer appear on the entity (`adChannelType` survives only in report metadata).

### 3.1 Query (find/list): `POST /v1/campaigns/query` — [BOTH]
DOCS `post-campaigns-query`; ASC command `campaigns find`

The body is a `QueryRequest`:

```json
{
  "filters":[{"field":"promotedObjectType","operator":"EQUALS","value":"APPSTORE_APP"},
             {"field":"promotedObjectId","operator":"EQUALS","value":"123456789"}],
  "sorting":[{"field":"modificationTime","order":"DESC"}],
  "pagination":{"offset":0,"pageSize":20,"fetchTotalCount":true}
}
```

- An empty body `{}` returns every non-deleted campaign in the account. `pageSize` max is 1000.

**`QueryRequest` / `QueryFilter` / `QuerySort` rules:**
- Request keys are `filters`, `sorting`, `pagination`. Filters combine with AND.
- Each filter is `{field, operator, value?, ignoreCase?: Bool}`.
- **v5 renames:** `conditions`→`filters`, `values`→`value`, `orderBy`→`sorting`, `sortOrder`→`order`, `ASCENDING`/`DESCENDING`→`ASC`/`DESC`, `STARTSWITH`/`ENDSWITH`→`STARTS_WITH`/`ENDS_WITH`. The v5 `selector` wrapper is gone; the members sit at top level. asc rejects the v5 spellings before sending (`internal/cli/ads/endpoints.go`).
- **Operators:** `EQUALS`, `NOT_EQUALS`, `IN`, `NOT_IN`, `CONTAINS_ANY`, `NOT_CONTAINS_ANY`, `CONTAINS_ALL`, `NOT_CONTAINS_ALL`, `LIKE` (`%` wildcard), `NOT_LIKE`, `STARTS_WITH`, `ENDS_WITH`, `GREATER_THAN`, `GREATER_THAN_OR_EQUAL_TO`, `LESS_THAN`, `LESS_THAN_OR_EQUAL_TO`, `BETWEEN` (`[min, max]`), `IS_NULL`, `IS_NOT_NULL`.
- **`value` cardinality by operator:**
  - Array for `IN`, `NOT_IN`, `CONTAINS_*` and `BETWEEN`.
  - For `EQUALS`, either a scalar or a one-element array.
  - Omit `value` entirely for `IS_NULL` and `IS_NOT_NULL`.
  - In Swift, model `value` as an enum that encodes a scalar or an array, and leave it out when nil.

**Campaign filterable fields:**
- `id` (EQUALS, IN)
- `name` (EQUALS, IN, LIKE, STARTS_WITH, ENDS_WITH)
- `status`, `systemStatus`, `billingEvent`, `paymentModel` (EQUALS, IN)
- `systemStatusReasons`, `systemStatusLimitingReasons` (CONTAINS_* variants)
- `promotedObjectType`, `promotedObjectId` (EQUALS, NOT_EQUALS, IN, NOT_IN)
- `startTime`, `endTime`, `creationTime`, `modificationTime` (comparison operators)
- `deleted` (EQUALS, IN). Deleted campaigns are included only when you filter `deleted IN [true,false]`.

Response:
```json
{"result":[{"id":444555666,"name":"AwayFinder App Campaign","adAccountId":123456789,"promotedObjectType":"APPSTORE_APP","promotedObjectId":"123456789","status":"ENABLED","billingEvent":"TAPS","startTime":"2025-09-01T00:00:00.000","endTime":"2025-12-31T23:59:59.000","dailyBudget":{"value":{"amount":"100.00","currency":"USD"}},"targeting":{"countryOrRegion":{"include":["US"]},"supplyPlacement":{"include":["APPSTORE_SEARCH_RESULTS"]}},"bidStrategy":{"bidStrategyType":"MANUAL_CPT","bidStrategyGoal":"TAP"},"creationTime":"2025-01-10T08:00:00.000","modificationTime":"2025-01-10T08:00:00.000","deleted":false,"paymentModel":"PAYG","systemStatus":"RUNNING","systemStatusReasons":[],"systemStatusLimitingReasons":[],"displayStatus":"RUNNING"}],
 "pagination":{"totalCount":1,"offset":0,"pageSize":20}}
```

### 3.2 Get one: `GET /v1/campaigns/{id}` — [BOTH]
Returns `{"result": Campaign}`. It also returns deleted campaigns, with `"deleted": true`, `displayStatus: "DELETED"` and `systemStatusReasons: ["DELETED_BY_USER"]`.

### 3.3 Update: `PUT /v1/campaigns/{id}` with body `CampaignUpdate` — [BOTH]

- **Updatable fields:** `name`, `startTime`, `endTime`, `status`, `dailyBudget{value}`, `sharedBudgets`, `targeting{supplyPlacement, countryOrRegion}` (`supplySource` is immutable and must not be sent), `bidStrategy` (type and goal together), `invoiceDetail`, `regulationResponses`.
- **Not updatable:** `billingEvent`, `promotedObjectType`, `promotedObjectId`.
- **No v5-style envelope.** v5 wrapped the body as `{"campaign":{...}}` (`UpdateCampaignRequest`); v1 takes the fields flat.
- Pause:
  ```json
  {"status":"PAUSED"}
  ```
- Resume:
  ```json
  {"status":"ENABLED"}
  ```
  asc's `asc ads campaigns pause|resume` sends exactly these (`internal/cli/ads/workflows.go`).
- Change daily budget:
  ```json
  {"dailyBudget":{"value":{"amount":"1200.00","currency":"USD"}}}
  ```
- The response is `{"result": Campaign}`, the full updated entity.

### 3.4 Create: `POST /v1/campaigns` with body `CampaignCreate`

**Required fields per the schema [DOCS `campaigncreate`] (matches asc's BodyHint [ASC]):** `adAccountId` (int64), `billingEvent`, `dailyBudget` (`{value: Money}`), `name` (1–200 characters), `promotedObjectId` (string adamId), `promotedObjectType`, `targeting`.

**Apple's endpoint page says more is needed.** DOCS `post-campaigns` has a table that lists `adAccountId`, `billingEvent`, **`bidStrategy`**, `dailyBudget`, `name`, `promotedObjectId`, `promotedObjectType`, **`startTime`**, **`endTime`**, `targeting` as required. That contradicts the schema, which marks `startTime`/`endTime` optional and says to omit `endTime` to run indefinitely. Apple's own journey example also omits start and end. To be safe, always send `bidStrategy`.

**Optional fields:** `status` (`ENABLED`/`PAUSED`). asc recommends `PAUSED` for safe creation; the schema doesn't document a default. Also `startTime`, `endTime`, `sharedBudgets`, `invoiceDetail` (required for LOC accounts), `regulationResponses`.

Minimal App Store Search example [DOCS `journey-app-store-ads`]:
```json
{
  "name": "AwayFinder - Brand Keywords - US",
  "adAccountId": 123456789,
  "billingEvent": "TAPS",
  "promotedObjectType": "APPSTORE_APP",
  "promotedObjectId": "123456789",
  "dailyBudget": { "value": { "amount": "100.00", "currency": "USD" } },
  "targeting": {
    "countryOrRegion": { "include": ["US"] },
    "supplyPlacement": { "include": ["APPSTORE_SEARCH_RESULTS"] }
  },
  "bidStrategy": { "bidStrategyType": "MANUAL_CPT", "bidStrategyGoal": "TAP" },
  "status": "PAUSED"
}
```

- The response is `{"result": Campaign}`.
- Apple's App Store examples omit `supplySource`. The guide says to set `APPSTORE`; whether it is inferred when omitted is not stated.

### 3.5 Delete: `DELETE /v1/campaigns/{id}` → `200 {}` — [BOTH]
Soft delete, which cascades to the campaign's ad groups, keywords and ads.

### Extra endpoint
`GET /v1/campaigns/{id}/legacy-app-limited-status-reason-details` [ASC TSV].

---

## 4. Ad groups

### Enums [DOCS]
- `AdGroupStatus`: `ENABLED` | `PAUSED`.
- `PricingModel`: `CPA` | `CPM` | `CPT`. It is required on create and immutable. Use `CPT` with `TAPS` and `CPM` with `IMPRESSIONS`.
- `AdGroupSystemStatus`: `RUNNING` | `NOT_RUNNING`.
- `AdGroupDisplayStatus`: `CAMPAIGN_ON_HOLD` | `DELETED` | `LIMITED` | `ON_HOLD` | `PAUSED` | `PROCESSING` | `RUNNING`.

### `AdGroup` fields
`id`, `adAccountId`, `campaignId` (int64), `name`, `startTime`, `endTime`, `pricingModel`, `automatedKeywordsOptIn` (Search Match), `automatedKeywordsRequired`, `status`, `systemStatus`, `systemStatusReasons`, `systemStatusLimitingReasons`, `displayStatus`, `bidStrategy`, `targeting`, `creationTime`, `modificationTime`, `deleted`, `cpaCap` (deprecated).

**The default bid moved:**
- **There is no `defaultBidAmount`.** The ad-group bid is now `bidStrategy.bid` (Money).
- If `bidStrategy` is omitted, the campaign-level bid strategy applies.
- Under `MAX_CONVERSIONS`/`MAX_ENGAGEMENTS` campaigns, ad groups inherit the campaign's strategy.

**Targeting** (each dimension is `{include, exclude?}`; only `appCategory` and `appDownloader` support `exclude`):
- Geo: `country`, `adminArea`, `locality`, `postalCode` (ids from Geo Search), `locationGroup`, `radius`.
- Audience: `deviceClass` (`IPHONE`/`IPAD`), `minAge`/`maxAge` (string numbers 18–64), `gender` (`M`/`F`), `appCategory`, `appDownloader`.
- Time: `daypart` (slot integers 0–167, include-only).

[DOCS `adgroup`, `adgrouptargetingcreate`, `targetingdata`]

### 4.1 Find by campaign: `POST /v1/adgroups/query` — [BOTH]

```json
{"filters":[{"field":"campaignId","operator":"EQUALS","value":444555666}],
 "sorting":[{"field":"creationTime","order":"DESC"}],
 "pagination":{"offset":0,"pageSize":20,"fetchTotalCount":true}}
```

- **Filterable fields:**
  - `id` (EQUALS, IN)
  - `campaignId` (**EQUALS only**)
  - `name` (EQUALS, STARTS_WITH)
  - `status` (EQUALS, IN)
  - `startTime`/`endTime` (LESS_THAN, GREATER_THAN)
  - `deleted` (EQUALS)
- An empty body returns all ad groups in the account. The response is `{"result":[AdGroup], "pagination":{…}}`.

### 4.2 Update: `PUT /v1/adgroups/{id}` — [BOTH]

- **Mutable:** `name`, `status`, `startTime`, `endTime`, `automatedKeywordsOptIn`, `bidStrategy`, `targeting` (only the dimensions you send change).
- **Immutable:** `campaignId`, `pricingModel`, `automatedKeywordsRequired`.

Pause:
```json
{"status":"PAUSED"}
```

Change the default bid (type and goal must be sent with `bid`):
```json
{"bidStrategy":{"bidStrategyType":"MANUAL_CPT","bidStrategyGoal":"TAP","bid":{"amount":"7.50","currency":"USD"}}}
```

The response is `{"result": AdGroup}`.

### 4.3 Create minimal: `POST /v1/adgroups` with body `AdGroupCreate` — [BOTH]

- **Required:** `name`, `campaignId` (int64), `pricingModel`.
- **Optional:** `startTime`, `endTime`, `status` ("No default is applied when this field is omitted", so send it), `automatedKeywordsOptIn`, `automatedKeywordsRequired`, `bidStrategy`, `targeting`.
- Keywords **cannot** be created inline.

```json
{"campaignId":542317095,"name":"AwayFinder - Brand Keywords - US","pricingModel":"CPT",
 "bidStrategy":{"bidStrategyType":"MANUAL_CPT","bidStrategyGoal":"TAP","bid":{"amount":"1.00","currency":"USD"}},
 "status":"ENABLED","startTime":"2026-01-01T00:00:00.000","endTime":"2026-03-31T23:59:59.999"}
```

The response is `{"result": AdGroup}`.

Delete: `DELETE /v1/adgroups/{id}` returns `200 {}`.

### For a campaign to actually serve [DOCS journey]
You must also create a creative and an ad:

1. `POST /v1/creatives`:
   ```json
   {"name":"…","creativeType":"DEFAULT_PRODUCT_PAGE","creativeSpec":{},"destination":{"destinationType":"APP_STORE_PRODUCT_PAGE","parameters":{"adamId":"123456789"}}}
   ```
   The response's `result.id` is the `creativeId`.
2. `POST /v1/ads`:
   ```json
   {"adGroupId":…, "creativeId":…, "name":"…", "status":"ENABLED"}
   ```
   All four fields are required.

v5 auto-created a default ad; whether v1 does is undocumented.

---

## 5. Targeting keywords

### Enums [DOCS]
- `KeywordMatchType`: `EXACT` | `BROAD` (App Store) | `PHRASE` | `CATEGORY` (Apple Maps only).
- `KeywordStatus`: **`ENABLED` | `PAUSED`**. This differs from v5, which used `ACTIVE`/`PAUSED`.
- `KeywordDisplayStatus`: `RUNNING` | `PAUSED` | `DELETED` | `AD_GROUP_ON_HOLD` | `CAMPAIGN_ON_HOLD`.

### `Keyword` fields
`id`, `adAccountId`, `campaignId`, `adGroupId` (int64), `text`, `matchType`, `bid` (Money; overrides the ad-group bid; not used under MAX_CONVERSIONS), `status`, `displayStatus`, `creationTime`, `modificationTime`, `deleted`.
- `text` and `matchType` are immutable.
- **The v5 `bidAmount` field is now `bid`.**

### 5.1 Find: `POST /v1/keywords/query` — [BOTH]

- **A filter on `adGroupId` or `campaignId` is required** unless you filter by `id`.
- **Filterable fields:**
  - `adGroupId` (EQUALS, IN; up to 1000 values)
  - `campaignId` (EQUALS only)
  - `id` (EQUALS, IN)
  - `text` (EQUALS, STARTS_WITH)
  - `matchType`, `status` (EQUALS, IN)
  - `deleted` (EQUALS)
- asc enforces the same rule client-side ("include at least one filter for id, adGroupId, or campaignId").

```json
{"filters":[{"field":"adGroupId","operator":"EQUALS","value":555666777}],"pagination":{"offset":0,"pageSize":1000,"fetchTotalCount":true}}
```
Response:
```json
{"result":[{"id":888999000,"adAccountId":123456789,"campaignId":444555666,"adGroupId":555666777,"text":"photo editor","matchType":"EXACT","bid":{"amount":"2.50","currency":"USD"},"status":"ENABLED","deleted":false,"creationTime":"2025-01-10T08:00:00.000","modificationTime":"2025-01-10T08:00:00.000"}],"pagination":{"totalCount":1,"offset":0,"pageSize":1}}
```

### 5.2 Create bulk: `POST /v1/keywords/bulk-create` with body `KeywordCreateBulkRequest` — [BOTH]

The body is a wrapper object. **It is not v5's raw array.**
```json
{"allowPartialSuccess":true,
 "items":[{"correlationId":1,"data":{"adGroupId":555666777,"text":"travel app","matchType":"BROAD","bid":{"amount":"1.25","currency":"USD"},"status":"ENABLED"}}]}
```

- `items[].correlationId` is int64 and supplied by you.
- `items[].data` is `BulkKeywordCreate`: `adGroupId` (required int64), `text` (required), `matchType`, `bid` (Money or null), `status`.
- **`campaignId` is not part of the item.** v5 had it in the path.
- `allowPartialSuccess` omitted or false means one item failure rejects the whole batch.

Response (`KeywordCreateBulkResponse`):
```json
{"result":[{"correlationId":1,"operation":"CREATE","success":true,"result":{ …Keyword… },"error":null}]}
```
- Per item: `correlationId`, `operation` (`CREATE`/`UPDATE`/`DELETE`), `success`, `result` (Keyword, null on failure), `error` (Error, per item).
- The top-level `error` is set only when the whole request is rejected.

Single create: `POST /v1/keywords` with a flat `KeywordCreate` (`adGroupId`, `text`, `matchType`, `bid`, `status`), returning `{"result": Keyword}`.

### 5.3 Update bid or status

**Single:** `PUT /v1/keywords/{id}` with body `KeywordUpdate`. Only `bid` and `status` are accepted. `bid: null` is an error.
```json
{"bid":{"amount":"2.50","currency":"USD"},"status":"PAUSED"}
```
The response is `{"result": Keyword}`.

**Bulk:** `POST /v1/keywords/bulk-update`. **The method is POST, not PUT.**
```json
{"allowPartialSuccess":true,"items":[{"correlationId":0,"data":{"id":888999000,"bid":{"amount":"3.00","currency":"USD"}}},{"correlationId":2,"data":{"id":888999002,"status":"PAUSED"}}]}
```
The response has the same shape as bulk-create, with `operation: "UPDATE"`.

### 5.4 Delete

- **Single:** `DELETE /v1/keywords/{id}` returns `200 {}`.
- **Bulk:** `POST /v1/keywords/bulk-delete` **[DOCS only; not in asc 6.5.0]**. asc's 6.5.0 design doc says v1 "has no bulk-delete endpoint", but Apple's docs now document one.
  ```json
  {"allowPartialSuccess":true,"items":[{"correlationId":0,"data":{"id":888999000}}]}
  ```
  Response:
  ```json
  {"result":[{"correlationId":0,"operation":"DELETE","success":true}]}
  ```
  No entity is returned.

---

## 6. Negative keywords

There is a single unified resource, `/v1/negative-keywords`, for both levels. v5 had separate campaign and ad-group collections.

### Enums and fields [DOCS]
- `NegativeKeywordStatus`: `ENABLED` | `PAUSED`.
- `matchType`: `EXACT`/`BROAD` for App Store, `PHRASE` for Maps. `CATEGORY` is not allowed.
- `NegativeKeyword` fields: `id`, `adAccountId`, `campaignId`, `adGroupId` (null or absent at campaign level), `text`, `matchType`, `status`, `creationTime`, `modificationTime`, `deleted`.
- Deleted negatives are never returned by query, and GET by id on a deleted negative returns 404.

### 6.1 Find: `POST /v1/negative-keywords/query` — [BOTH]

- **Campaign-level:**
  ```json
  {"filters":[{"field":"campaignId","operator":"EQUALS","value":444555666},{"field":"adGroupId","operator":"IS_NULL"}],"pagination":{"offset":0,"pageSize":1000,"fetchTotalCount":true}}
  ```
- **Ad-group-level:** `adGroupId EQUALS`, or `IN` with up to 1000 values; `campaignId` is optional here.
- **All ad-group negatives in a campaign:** `campaignId EQUALS` + `adGroupId IS_NOT_NULL`.
- An `adGroupId` filter is always required unless you filter by `id`. `campaignId` supports EQUALS only.
- asc runs the IS_NULL and IS_NOT_NULL queries one after the other to collect all negatives for a campaign (`search_optimization.go` `fetchOptimizationNegatives`).

Response:
```json
{"result":[{"id":777888999,"adAccountId":123456789,"campaignId":444555666,"text":"free app","matchType":"BROAD","status":"ENABLED","deleted":false,"creationTime":"2025-01-10T08:00:00.000","modificationTime":"2025-01-10T08:00:00.000"}],"pagination":{"totalCount":1,"offset":0,"pageSize":1}}
```

### 6.2 Create

**Single:** `POST /v1/negative-keywords`.
- Campaign-level: `{"campaignId":444555666,"text":"free app","matchType":"BROAD","status":"ENABLED"}` (no `adGroupId`).
- Ad-group-level: `{"adGroupId":555666777,"text":"cheap downloads","matchType":"EXACT","status":"ENABLED"}`. **Do not set `campaignId`** together with `adGroupId`.
- Defaults: `matchType` = `BROAD`, `status` = `ENABLED`.
- Returns `{"result": NegativeKeyword}`.

**Bulk:** `POST /v1/negative-keywords/bulk-create`. The wrapper is the same as for keywords; `data` is `BulkNegativeKeywordCreate` (`campaignId?`, `adGroupId?`, `text` required, `matchType`, `status`). You can mix campaign- and ad-group-level items.
- Apple's bulk example sends **both** `campaignId` and `adGroupId` for an ad-group item. That contradicts the single-create rule, so send only `adGroupId` for ad-group items to be safe.

### 6.3 Update and delete

- **Update:** `PUT /v1/negative-keywords/{id}` with `{"status":"PAUSED"}`. Only `status` is accepted.
- **Bulk update:** `POST /v1/negative-keywords/bulk-update`, items with `data: {id, status}`.
- **Delete:** `DELETE /v1/negative-keywords/{id}` returns `200 {}`. This is permanent; the negative can't be re-enabled.
- **Bulk delete:** `POST /v1/negative-keywords/bulk-delete` **[DOCS only]**, with `items[].data = {"id": int64}`.

---

## 7. Reports

**Endpoints**, all `POST` with the context header [BOTH]:

| Report | Path |
|---|---|
| Campaigns | `/v1/reports/apps/campaigns/query` |
| Ad groups | `/v1/reports/apps/adgroups/query` |
| Keywords | `/v1/reports/apps/keywords/query` |
| **Search terms** | `/v1/reports/apps/searchterms/query` |
| Ads | `/v1/reports/apps/ads/query` |

- Maps (brand) reports use `/v1/reports/business-brands/...`.
- **`campaignId` is no longer in the path.** It moved into `filters`. It is **required** for ad-group, ad, keyword and search-term reports, and optional for campaign reports.

### 7.1 Request body: `AppsReportingRequest` [BOTH] (DOCS `appsreportingrequest`, `timerange`, `appsoptions`, `filter`, `sorting`, `requestpagination`)

```json
{
  "timeRange": {"start":"2026-10-07","end":"2026-11-05","timeZone":"ORTZ","granularity":"DAILY"},
  "filters":   [{"field":"campaignId","operator":"EQUALS","value":444555666}],
  "fields":    ["impressions","taps","localSpend","tapInstalls","totalInstalls"],
  "groupBy":   ["countryOrRegion"],
  "sorting":   [{"field":"localSpend","order":"DESC"}],
  "options":   {"includeRows":["GRAND_TOTAL"]},
  "pagination":{"offset":0,"pageSize":1000}
}
```

**`timeRange`:**
- `start`/`end` are inclusive `YYYY-MM-DD`.
- `timeZone` ∈ `UTC`|`ORTZ` (default `ORTZ`). **Search terms support `ORTZ` only.**
- `granularity` ∈ `HOURLY`|`DAILY`|`WEEKLY`|`MONTHLY`, optional.
- Constraints: DAILY spans at most 90 days; WEEKLY at least 14; MONTHLY at least 90; HOURLY at most 7 days, start within the last 365 days, and not available for ads or search terms. For a single day, omit `granularity`.
- **v5 renames:** `startTime`/`endTime`/`timeZone`/`granularity` were top-level in v5 and now sit under `timeRange`.

**`filters`** use the report `Filter` object. Operators: `EQUALS`, `NOT_EQUALS`, `GREATER_THAN`, `LESS_THAN`, `GREATER_THAN_OR_EQUAL_TO`, `LESS_THAN_OR_EQUAL_TO`, `IN`, `LIKE`, `STARTS_WITH`, `CONTAINS`, `ENDS_WITH`, `CONTAINS_ANY`, `CONTAINS_ALL`, `BETWEEN`. `value` is a bare value or an array.

**`groupBy`** (apps):
- Campaign and ad-group reports: `deviceClass`, `ageRange`, `gender`, `countryCode`, `adminArea`, `locality`, `countryOrRegion`.
- **Keyword and search-term reports: only `deviceClass` and `countryOrRegion`.**
- Ad reports: only `countryOrRegion`.

**`options.includeRows`:** `GRAND_TOTAL` and/or `EMPTY_METRICS`.
- `EMPTY_METRICS` can't be combined with `groupBy` and is not supported for search terms.
- **v5 renames:** v5's `returnGrandTotals: true` → `GRAND_TOTAL`; `returnRecordsWithNoMetrics: true` → `EMPTY_METRICS`; `returnRowTotals` has no v1 equivalent.

**`fields`** is an optional projection; omit it to get every field. **The v5 `selector` wrapper is gone**: `filters`, `sorting` and `pagination` are top-level, and pagination is inside the body (`pageSize` max 5000).

### 7.2 Response envelope (all apps reports) [BOTH]

```json
{ "result": { "rows": [ Row… ], "summary": { "grandTotal": Metrics } },
  "pagination": { "offset": 0, "pageSize": 20, "totalCount": 1 } }
```

- Row shape: `{ "metadata": <entity-specific>, "totalMetrics": Metrics, "granularMetrics": [Metrics]? }`.
- `granularMetrics` is present only when `granularity` is set.
- **If nothing matches, `result` is `{}`**, so make `rows` optional.
- Keyword rows can also carry `insights: { bidRecommendation … }`.
- **v5 renames:** v5's `row.metadata`/`total`/`granularity` became `metadata`/`totalMetrics`/`granularMetrics`; v5's `reportingDataResponse.row` became `result.rows`.

**Metric fields (`AppsMetrics`; the same set for campaign, ad-group, keyword and search-term reports) [DOCS `appsmetrics`]:**

| JSON field | Type | Meaning |
|---|---|---|
| `date` | string | Present in `granularMetrics` (and in some `totalMetrics` examples) |
| `impressions` | int64 | |
| `taps` | int64 | |
| `ttr` | number | Tap-through rate, taps ÷ impressions (a fraction, e.g. 0.0189) |
| `localSpend` | Money | Spend |
| `cpt` | Money | **Average CPT** |
| `cpm` | Money | |
| `tapInstalls` | int64 | |
| `viewInstalls` | int64 | |
| `totalInstalls` | int64 | |
| `tapNewDownloads`, `tapRedownloads`, `viewNewDownloads`, `viewRedownloads`, `totalNewDownloads`, `totalRedownloads` | int64 | |
| `tapInstallCPI` | Money | **Average cost per tap-install** (the closest thing to v5's `avgCPA`) |
| `totalAvgCPI` | Money | Average cost per install, all attribution types |
| `tapInstallRate` | number | Tap installs ÷ taps (the closest thing to v5's `conversionRate`) |
| `totalInstallRate` | number | Total installs ÷ taps |
| `tapPreOrdersPlaced`, `viewPreOrdersPlaced`, `totalPreOrdersPlaced` | int64 | |

- **There are no `avgCPA`, `avgCPT` or `conversionRate` fields in v1.**
- **Metrics are sparse.** Apple's own examples omit fields (e.g. `cpt`, `totalInstalls`), so make every metric optional.

**Per-row `metadata`:**

*Campaign report (`AppsReportingCampaign`):*
- Identity and promoted object: `id`, `adAccountId`, `name`, `promotedObjectType` (`APPSTORE_APP`), `promotedObjectId` (string), `promotedObject`.
- Status: `status`, `systemStatus`, `systemStatusReasons`, `systemStatusLimitingReasons`, `displayStatus`, `deleted`.
- Budget and bidding: `dailyBudget` (**`{value: Money}`**), `lifetimeBudget`, `bidStrategy`, `billingEvent`, `adChannelType` (`SEARCH`|`DISPLAY`).
- Targeting: `targeting{supplyPlacement, lifetimeStorefronts, countryOrRegion}`, each `{include: []}`.
- Times: `startTime`, `endTime`, `creationTime`, `modificationTime`.
- groupBy dimension values (only those you grouped by): `countryOrRegion`, `deviceClass`, `gender`, `ageRange`, `locality`, `countryCode`, `adminArea`.

*Ad-group report (`AppsReportingAdGroup`):*
- `id`, `campaignId`, `adAccountId`, `name`, `status`, `deleted`, `systemStatus`, `systemStatusReasons`, `systemStatusLimitingReasons`, `displayStatus`.
- `automatedKeywordsOptIn`, `automatedKeywordsRequired`, `pricingModel`, `cpaCap`, `bidStrategy`, `campaign{}`.
- Times: `startTime`, `endTime`, `creationTime`, `modificationTime`.
- Dimension fields as above.

*Keyword report (`ReportingKeyword`):*
- `id`, `campaignId`, `adAccountId`, `adGroupId`, `text`, `matchType`, `bid` (Money).
- `status` (`ENABLED`/`PAUSED`/`DELETED`), `displayStatus`, `deleted`.
- `creationTime`, `modificationTime`, `adGroup{name, deleted}`, `countryOrRegion`, `deviceClass`.

### 7.3 Search-terms report (most important) [BOTH]
DOCS `get-app-search-term-reports`, `appssearchtermreportresponse`, `reportingsearchterm`; ASC `search_optimization.go` `fetchOptimizationSearchTerms` and `searchTermReportResponse`

**Request** for the last 30 days, search term + impressions for one campaign (requests go one campaign at a time, because `campaignId` is required):
```json
POST /v1/reports/apps/searchterms/query
X-AP-Context: adAccountId=123456789

{
  "filters":   [{"field":"campaignId","operator":"EQUALS","value":444555666}],
  "fields":    ["impressions","taps","localSpend","tapInstalls","totalInstalls"],
  "groupBy":   ["countryOrRegion"],
  "timeRange": {"start":"2026-10-07","end":"2026-11-05","timeZone":"ORTZ","granularity":"DAILY"},
  "pagination":{"offset":0,"pageSize":5000}
}
```

- This is exactly asc's request shape: asc uses `ORTZ`, `DAILY`, `pageSize` 5000, and the same `fields` and `groupBy`.
- Optionally narrow with `{"field":"adGroupId","operator":"EQUALS","value":…}`.
- Leave out `groupBy` if you want one aggregate row per term.
- `timeZone: "UTC"` is rejected for this endpoint.

**Response row:**
```json
{"result":{"rows":[{
   "metadata":{
     "campaignId":444555666,"adAccountId":123456789,
     "searchTermText":"best productivity app 2025",
     "searchTermSource":"AUTO",
     "keyword":{"id":888999000,"campaignId":444555666,"adAccountId":123456789,"deleted":false,"text":"productivity app","status":"ENABLED","matchType":"BROAD","bid":{"amount":"0.35","currency":"USD"},"adGroupId":555666777,"modificationTime":"2024-12-15T08:00:00.000","creationTime":"2024-11-01T08:00:00.000","displayStatus":"RUNNING","adGroup":{"name":"Productivity - Broad Match","deleted":false}},
     "adGroupId":555666777,
     "adGroup":{"name":"Productivity - Broad Match","deleted":false},
     "countryOrRegion":"US"
   },
   "totalMetrics":{"localSpend":{"amount":"45.00","currency":"USD"},"impressions":3000,"taps":150,"ttr":0.05,"tapInstalls":35,"totalInstalls":42},
   "granularMetrics":[{"date":"2025-01-01","localSpend":{"amount":"1.50","currency":"USD"},"impressions":100,"taps":5,"tapInstalls":1}]
 }],
 "summary":{"grandTotal":{…}}},
 "pagination":{"pageSize":20,"offset":0,"totalCount":1}}
```

`ReportingSearchTerm` (the `metadata` object):

| Field | Type | Notes |
|---|---|---|
| `searchTermText` | string | The user's query. **v5 called this `searchTermText` too** |
| `searchTermSource` | `AUTO` \| `TARGETED` | v5 used the same values |
| `campaignId`, `adGroupId`, `adAccountId` | int64 | |
| `keyword` | ReportingKeyword? | The matched keyword, nested. **v5 had flat `keyword`, `keywordId`, `matchType`** |
| `adGroup` | `{name, deleted}` | |
| `countryOrRegion` | string? | Present only when grouped by it |
| `deviceClass` | `IPHONE` \| `IPAD`? | Present only when grouped by it |

- Read the term text from `metadata.searchTermText` and impressions from `totalMetrics.impressions`.
- Low-volume terms may be suppressed or aggregated for privacy. Whether that shows up as a null `searchTermText` (as in v5) or the row is simply missing isn't documented, so treat `searchTermText` as optional.
- Search Match (AUTO) rows with no keyword: assume `keyword` may be absent.

---

## 8. App search

`GET /v1/search/apps` **with the context header** (v5 needed `orgId`; v1 needs `adAccountId`) [BOTH]. DOCS `searches-for-a-list-of-apps`, `appssearchresponse`, `appinfo`; ASC `endpoints.go`.

**Query parameters:**
- `query` (string, at least 3 characters, 2 for CJK)
- `returnOwnedApps` (bool, default false)
- `cpids` (comma-separated content-provider IDs)
- `storeFronts` (ISO alpha-2, **repeat the parameter** for multiple values, e.g. `storeFronts=US&storeFronts=GB`; a bad code gives `INVALID_COUNTRY_CODE`)
- `offset` (default 0)
- `limit` (default 20)

At least one of `query`, `cpids` or `returnOwnedApps=true` is required, otherwise you get `INVALID_INPUT`.

Example:
```
GET /v1/search/apps?returnOwnedApps=true&storeFronts=US&limit=50&offset=0
```
```json
{"result":[{"adamId":123456789,"appName":"AwayFinder","developerName":"AwayFinder Inc.","countryOrRegionCodes":["US","GB","CA","AU"]}],
 "pagination":{"totalCount":1,"offset":0,"pageSize":1}}
```

- `AppInfo`: `adamId` int64 (**the v5 field was `adamId` too**), `appName`, `developerName`, `countryOrRegionCodes: [String]`. All four are required.
- **Field renames from v5:** `appName`, `developerName` and `countryOrRegionCodes` are the v1 names; check them against your current Codable.
- Pagination is query-string offset/limit; the response `pagination` is `QueryPaginationResult`. asc pages it with `--paginate`.
- To map a tracked App Store app ID: `promotedObjectId = String(adamId)`.

**Related:**
- `GET /v1/apps/{adamId}` returns `AppDetails`: `id` (**string**), `appName`, `artistName`, `primaryLanguage`, `primaryGenre`, `secondaryGenre`, `deviceClasses`, `iconPictureUrl`, `isPreorder`, `availableStorefronts`.
- `POST /v1/eligibilities/apps/query` takes filters on `adamId`, `supplyPlacement`, `supplySource`, `countryOrRegion`, `deviceClass`, `state` (`ELIGIBLE`/`INELIGIBLE`). asc reads rows as `{countryOrRegion, supplyPlacement, deviceClass, state, reasons[]}` [ASC].

---

## 9. Errors and rate limits

### Error envelope [DOCS `error`, `errorresponse`, `errordetail`; ASC `errors.go`]

```json
{"error":{"code":"VALIDATION_ERROR","message":"Validation errors found",
  "details":[{"code":"DUPLICATE_NAME","message":"AdGroup name already exists under this Campaign.","info":{"field":"name"}}]}}
```

- `Error`: `code` (string, required), `message` (string or null), `details` (array of `ErrorDetail`).
- `ErrorDetail`: `code`, `message`, `info` (free-form object).
- **v5 renames:** v5 used `{"error":{"errors":[{"field","message","messageCode"}]}}`.
- **Inconsistency in Apple's docs:**
  - The `put-campaigns-_id_` "Not Found" example shows a v5-like `{"error":{"errors":[{"code":"CAMPAIGN_NOT_FOUND","message":"…"}]}}`.
  - The docs also say some endpoints return a bare `ErrorResponse`.
  - asc parses, in order: wrapped `{error:{code,message,details}}`, then direct `{code,message,details}`, then the v5 `{error:{errors:[…]}}`, then raw text. **Do the same.**
- Change-history endpoints use their own `ErrorMessage` whose `code` is one of `BAD_REQUEST`, `NOT_FOUND`, `NOT_AUTHED`.

### Status codes [DOCS]

| Status | Code |
|---|---|
| 400 | `bad_request` |
| 401 | `unauthorized` (invalid or expired token) |
| 403 | `forbidden` |
| 404 | `not_found` |
| 429 | `rate_limit_exceeded` |
| 500 | `internal_server_error` |

asc retries GET/HEAD and `/query` POSTs on 408, 429, 500, 502, 503, 504 [ASC `client.go`].

### Rate limits [DOCS `rate-limits`]

- Every response carries `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset`. `Reset` is a **delta in seconds**, not a timestamp.
- A 429 also carries `Retry-After` (seconds). Prefer it over `RateLimit-Reset`.
- Recommended backoff: double the wait per consecutive 429, capped at about 16 s; throttle when `Remaining` gets low.
- **No numeric quota is published.** The example shows `RateLimit-Limit: 100`. asc records these headers (`errors.go` `rateLimitFromHeaders`).

---

## 10. Other v1-vs-v5 differences that will bite the port

1. **Host, path and context all change:**
   - `api.searchads.apple.com/api/v5` → `api.ads.apple.com/v1`.
   - `orgId=` → `adAccountId=`.
   - No nested campaign paths.
   - Bulk keyword ops are `POST …/bulk-create`, `…/bulk-update` and `…/bulk-delete`, with an `{items:[{correlationId, data}]}` wrapper.
2. **Envelope:** `data` → `result`. Pagination keys changed from `itemsPerPage/startIndex/totalResults` to `pageSize/offset/totalCount`. You only get `totalCount` on queries if you send `fetchTotalCount: true`. Response `pageSize` is the actual row count.
3. **Selector:** see the §3.1 renames. Selector `fields` no longer exists on `QueryRequest`; only report requests accept `fields` [ASC guard].
4. **Campaign fields:**
   - `adamId` → `promotedObjectId` (string) + `promotedObjectType: "APPSTORE_APP"`.
   - `dailyBudgetAmount: Money` → `dailyBudget: {value: Money}`.
   - `countriesOrRegions` → `targeting.countryOrRegion.include`.
   - `supplySources: ["APPSTORE_SEARCH_RESULTS"]` → `targeting.supplyPlacement.include`, plus `supplySource: APPSTORE`.
   - `adChannelType` is removed from the entity.
   - Campaign create now needs `adAccountId` in the body.
   - Update has no `{"campaign":…}` wrapper.
5. **Ad group:** `defaultBidAmount` → `bidStrategy{bidStrategyType, bidStrategyGoal, bid}`. `pricingModel` is required. `cpaCap` is deprecated in favour of `MAX_CONVERSIONS`.
6. **Keyword:**
   - `bidAmount` → `bid`.
   - Status `ACTIVE` → `ENABLED`.
   - Campaign and ad group ids now go in the body or filters, not the path.
   - New match types `PHRASE` and `CATEGORY` (Maps), so make your enum tolerant of unknown values.
7. **Negative keywords** are one resource. The level is set by whether `adGroupId` is present.
8. **Reports:**
   - `campaignId` moved from the path into `filters`.
   - `timeRange` object replaces the top-level `startTime`/`endTime`/`timeZone`/`granularity`.
   - `options.includeRows` replaces the boolean flags.
   - The row container keys changed.
   - Metric names: no `avgCPA`/`avgCPT`/`conversionRate`; use `cpt`, `tapInstallCPI`, `totalAvgCPI`, `tapInstallRate`, `totalInstallRate`.
   - `installs` → `tapInstalls`/`totalInstalls`.
9. **IDs:** int64 in the docs schema, strings per asc. `promotedObjectId` and path params are strings. Decode tolerantly.
10. **Date-times** have no zone (`2025-09-01T00:00:00.000`) and must not be fed to your app's `.withFractionalSeconds` ISO8601 decoder. Use a separate decoder for the Apple client.
11. **Enums grow.** `systemStatusReasons` and similar lists are long and Apple adds values, so decode unknowns as raw strings.
12. **Deletes** are soft and return `{}`. Deleted negatives become invisible; deleted campaigns, ad groups and keywords are queryable only with `deleted` filters.

---

## Open questions / not confirmed

1. **Do existing v5 API-user credentials work against v1 unchanged?** Strongly implied (same OAuth flow, scope `searchadsorg`, same UI-issued clientId/teamId/keyId) but not stated explicitly by Apple, and not tested live.
2. **v5 orgId → v1 adAccountId mapping.** Undocumented. The only supported route is `GET /v1/acls`, then pick the `adAccount` with a matching `orgId` (and `productFeatures` including `APPSTORE_APP_MANUAL`). It is unknown whether Apple auto-migrated v5 orgs or campaigns, or whether old campaign IDs stay valid in v1.
3. **`X-AP-Context` trailing semicolon.** Apple documents `adAccountId=<id>`; asc sends `adAccountId=<id>;`. Not verified live which forms are accepted.
4. **ID JSON types.** The docs say int64 numbers; asc says string IDs and decodes both. Not verified live.
5. **Required fields for `POST /v1/campaigns`.** The schema doesn't require `bidStrategy`, `startTime` or `endTime`; the endpoint page's table does. The default `status` when omitted is not documented. Whether `targeting.supplySource` is required or inferred for App Store campaigns is not stated (Apple's examples omit it).
6. **Whether a campaign serves without an explicit creative and ad** (v5 created a default ad). Apple's journey creates one explicitly; I found no doc on implicit defaults.
7. **Search-terms report with a 30-day range and no `granularity`.** Docs only describe omitting granularity for single-day requests. Whether a multi-day range without granularity is accepted (returning `totalMetrics` only) is unconfirmed. Sending `"granularity":"DAILY"` (≤90 days) is the documented-safe choice, and it is what asc does.
8. **Search terms and `fields`.** Does `fields` affect `metadata`, or is `searchTermText` always returned? Also unknown: how privacy-suppressed or Search Match rows appear (null `searchTermText`, absent `keyword`, or dropped rows).
9. **Report filter `value` type** for `campaignId`/`adGroupId` (number vs string vs array). Apple's examples mix all three. asc sends numbers.
10. **`POST /v1/keywords/bulk-delete` and `/v1/negative-keywords/bulk-delete`** appear only in Apple's current docs; asc 6.5.0 doesn't implement them and says none exist. Not verified live.
11. **Negative bulk-create:** whether sending both `campaignId` and `adGroupId` on an ad-group item is accepted (bulk example) or rejected (single-create rule).
12. **The error envelope actually returned** on 404s and other failures. The docs show both `{error:{code,message,details}}` and `{error:{errors:[…]}}`.
13. **Rate-limit quotas** are not published, only the headers.
14. **Search-term-popularity sorting:** asc says the live endpoint rejects the documented `sorting[].order` and needs `sortOrder`, an asc-only runtime finding (`docs/design/apple-ads-platform-api-v1.md`). Not relevant to your reports, but a sign that live behaviour can drift from the docs.

