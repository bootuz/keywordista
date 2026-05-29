/**
 * Read-only workflow tools.
 *
 * Each tool returns *structured* output (validated against a zod schema) so
 * MCP clients that support `structuredContent` can render it natively, plus
 * a text fallback for chat-only clients. The text fallback is intentionally
 * brief — a one-line summary, not a re-dump of the structured data.
 */
import { z } from "zod";
import type { ApiClient } from "../client.js";
import {
  WatchedApp,
  Keyword,
  HistoryPoint,
  DashboardRow,
  CompetitorGapRow,
  KeywordOpportunity,
  ChartPositionDTO,
  ChartEventDTO,
} from "../schemas.js";

// ---------------------------------------------------------------------------
// list_apps
// ---------------------------------------------------------------------------
export const listAppsInput = z.object({}).strict();
export const listAppsOutput = z.object({
  apps: z.array(WatchedApp),
  count: z.number().int(),
});

export async function listApps(client: ApiClient, _input: z.infer<typeof listAppsInput>) {
  const raw = await client.get<unknown>("/apps");
  const apps = z.array(WatchedApp).parse(raw);
  return { apps, count: apps.length };
}

// ---------------------------------------------------------------------------
// list_keywords
// ---------------------------------------------------------------------------
export const listKeywordsInput = z.object({}).strict();
export const listKeywordsOutput = z.object({
  keywords: z.array(Keyword),
  count: z.number().int(),
});

export async function listKeywords(client: ApiClient, _input: z.infer<typeof listKeywordsInput>) {
  const raw = await client.get<unknown>("/keywords");
  const keywords = z.array(Keyword).parse(raw);
  return { keywords, count: keywords.length };
}

// ---------------------------------------------------------------------------
// keyword_history
// ---------------------------------------------------------------------------
export const keywordHistoryInput = z
  .object({
    keywordId: z.string().uuid().describe("UUID of the keyword (from `list_keywords`)."),
    watchedAppId: z
      .string()
      .uuid()
      .optional()
      .describe("Optional — filter the timeline to one tracked app."),
  })
  .strict();
export const keywordHistoryOutput = z.object({
  keywordId: z.string().uuid(),
  watchedAppId: z.string().uuid().nullable(),
  points: z.array(HistoryPoint),
  count: z.number().int(),
});

export async function keywordHistory(client: ApiClient, input: z.infer<typeof keywordHistoryInput>) {
  const raw = await client.get<unknown>(`/keywords/${input.keywordId}/history`, {
    ...(input.watchedAppId !== undefined ? { watchedAppId: input.watchedAppId } : {}),
  });
  const points = z.array(HistoryPoint).parse(raw);
  return {
    keywordId: input.keywordId,
    watchedAppId: input.watchedAppId ?? null,
    points,
    count: points.length,
  };
}

// ---------------------------------------------------------------------------
// dashboard
// ---------------------------------------------------------------------------
export const dashboardInput = z
  .object({
    country: z
      .string()
      .length(2)
      .optional()
      .describe("Optional 2-letter ISO country code (e.g. 'us', 'de'). Lowercase."),
  })
  .strict();
export const dashboardOutput = z.object({
  rows: z.array(DashboardRow),
  count: z.number().int(),
  countryFilter: z.string().nullable(),
});

export async function dashboard(client: ApiClient, input: z.infer<typeof dashboardInput>) {
  const raw = await client.get<unknown>(
    "/dashboard",
    input.country !== undefined ? { country: input.country } : undefined,
  );
  const rows = z.array(DashboardRow).parse(raw);
  return { rows, count: rows.length, countryFilter: input.country ?? null };
}

// ---------------------------------------------------------------------------
// chart_movements
// ---------------------------------------------------------------------------
// Composite read: returns the current charted positions for all tracked apps
// PLUS the recent activity feed (entered/moved/exited events). One tool call
// answers "what's happening on the charts right now?" without the agent
// having to compose two reads + reconcile them.
export const chartMovementsInput = z
  .object({
    since: z
      .string()
      .datetime({ offset: true })
      .optional()
      .describe("ISO8601 timestamp — only return events after this. Defaults to ~24h ago server-side semantics."),
    limit: z
      .number()
      .int()
      .min(1)
      .max(200)
      .optional()
      .describe("Max events to return (1–200, default 50)."),
  })
  .strict();
export const chartMovementsOutput = z.object({
  positions: z.array(ChartPositionDTO),
  events: z.array(ChartEventDTO),
  positionsCount: z.number().int(),
  eventsCount: z.number().int(),
});

export async function chartMovements(client: ApiClient, input: z.infer<typeof chartMovementsInput>) {
  // Fire both reads in parallel — they're independent and the server handles
  // them cheaply. Halves the wall-clock for the agent.
  const [positionsRaw, eventsRaw] = await Promise.all([
    client.get<unknown>("/chart-positions"),
    client.get<unknown>("/chart-events", {
      ...(input.since !== undefined ? { since: input.since } : {}),
      ...(input.limit !== undefined ? { limit: input.limit } : {}),
    }),
  ]);
  const positions = z.array(ChartPositionDTO).parse(positionsRaw);
  const events = z.array(ChartEventDTO).parse(eventsRaw);
  return {
    positions,
    events,
    positionsCount: positions.length,
    eventsCount: events.length,
  };
}

// ---------------------------------------------------------------------------
// competitor_gaps
// ---------------------------------------------------------------------------
// For one of the user's OWN apps, the full (keyword × competitor) matrix:
// where each competitor stands vs the user's app on every tracked keyword.
const LOSING_KINDS = new Set(["behind", "pureGap"]);
export const competitorGapsInput = z
  .object({
    appId: z
      .string()
      .uuid()
      .describe("UUID of YOUR app (kind == 'own', from `list_apps`) to compute gaps for."),
    country: z
      .string()
      .length(2)
      .optional()
      .describe("Optional 2-letter ISO country code (lowercase) to scope keywords."),
  })
  .strict();
export const competitorGapsOutput = z.object({
  appId: z.string().uuid(),
  rows: z.array(CompetitorGapRow),
  count: z.number().int(),
  // behind + pureGap — the rows actually worth acting on.
  losingCount: z.number().int(),
});

export async function competitorGaps(client: ApiClient, input: z.infer<typeof competitorGapsInput>) {
  const raw = await client.get<unknown>(
    `/apps/${input.appId}/gaps`,
    input.country !== undefined ? { country: input.country } : undefined,
  );
  const rows = z
    .array(CompetitorGapRow)
    .parse(raw)
    // Normalize Vapor's omitted-nil keys to explicit null for a clean contract.
    .map((r) => ({ ...r, myRank: r.myRank ?? null, competitorRank: r.competitorRank ?? null }))
    // Most-urgent-first so the agent reads the actionable rows up top.
    .sort((a, b) => b.verdict.score - a.verdict.score);
  const losingCount = rows.filter((r) => LOSING_KINDS.has(r.verdict.kind)).length;
  return { appId: input.appId, rows, count: rows.length, losingCount };
}

// ---------------------------------------------------------------------------
// keyword_opportunity
// ---------------------------------------------------------------------------
// Opportunity scores (impressions ÷ difficulty) for ASA-covered keywords —
// real Apple Search Ads impressions weighed against difficulty. Only keywords
// with ASA data appear; everything else is difficulty-only on the dashboard.
export const keywordOpportunityInput = z.object({}).strict();
export const keywordOpportunityOutput = z.object({
  rows: z.array(KeywordOpportunity),
  count: z.number().int(),
});

export async function keywordOpportunity(
  client: ApiClient,
  _input: z.infer<typeof keywordOpportunityInput>,
) {
  const raw = await client.get<unknown>("/keywords/opportunity");
  const rows = z.array(KeywordOpportunity).parse(raw);
  return { rows, count: rows.length };
}
