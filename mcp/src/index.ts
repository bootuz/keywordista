#!/usr/bin/env node
/**
 * Keywordista MCP server — stdio entrypoint.
 *
 * Registers 12 workflow tools against the running Vapor server. The server
 * URL is resolved lazily on first tool call (env var → runtime.json → port
 * probe; see runtime.ts) so the MCP server can start cleanly even when the
 * menubar app isn't running yet — the user gets an actionable error on
 * their first call instead of a connect-time crash.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z, type ZodTypeAny } from "zod";

import { createApiClient } from "./client.js";
import {
  listApps,
  listAppsInput,
  listAppsOutput,
  listKeywords,
  listKeywordsInput,
  listKeywordsOutput,
  keywordHistory,
  keywordHistoryInput,
  keywordHistoryOutput,
  dashboard,
  dashboardInput,
  dashboardOutput,
  chartMovements,
  chartMovementsInput,
  chartMovementsOutput,
  competitorGaps,
  competitorGapsInput,
  competitorGapsOutput,
  keywordOpportunity,
  keywordOpportunityInput,
  keywordOpportunityOutput,
} from "./tools/reads.js";
import {
  addApp,
  addAppInput,
  addAppOutput,
  addKeyword,
  addKeywordInput,
  addKeywordOutput,
  removeApp,
  removeAppInput,
  removeAppOutput,
  removeKeyword,
  removeKeywordInput,
  removeKeywordOutput,
} from "./tools/writes.js";
import { refresh, refreshInput, refreshOutput } from "./tools/refresh.js";

const PKG_NAME = "keywordista-mcp";
const PKG_VERSION = "0.1.0";

const server = new McpServer({ name: PKG_NAME, version: PKG_VERSION });
const client = createApiClient();

/**
 * Wrap a tool handler so:
 *  - Input is validated by zod (defense in depth — the SDK does this too).
 *  - Output is validated by zod and returned both as text (one-line summary
 *    for chat-only clients) and structuredContent (for clients that render
 *    structured data natively).
 *  - Thrown errors are caught and returned as `isError: true` content
 *    blocks with the message, instead of crashing the transport.
 */
function wrap<I extends z.ZodTypeAny, O extends z.ZodTypeAny>(
  name: string,
  inputSchema: I,
  outputSchema: O,
  handler: (input: z.infer<I>) => Promise<z.infer<O>>,
  summarize: (output: z.infer<O>) => string,
) {
  return async (rawInput: unknown) => {
    try {
      const input = inputSchema.parse(rawInput);
      const output = await handler(input);
      // Re-parse to enforce the contract on the way out — catches accidental
      // drift between handler return values and the declared output schema.
      const validated = outputSchema.parse(output);
      return {
        content: [{ type: "text" as const, text: summarize(validated) }],
        structuredContent: validated as Record<string, unknown>,
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        isError: true,
        content: [{ type: "text" as const, text: `${name} failed: ${message}` }],
      };
    }
  };
}

// Helper: many tools take an empty input. The MCP SDK requires the raw shape
// for inputSchema, not the ZodObject itself.
function shapeOf<T extends z.ZodObject<Record<string, ZodTypeAny>>>(schema: T) {
  return schema.shape;
}

// ---------------------------------------------------------------------------
// Read tools
// ---------------------------------------------------------------------------
server.registerTool(
  "list_apps",
  {
    title: "List tracked apps",
    description: "Return all apps Keywordista is tracking, with their App Store metadata.",
    inputSchema: shapeOf(listAppsInput),
    outputSchema: shapeOf(listAppsOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("list_apps", listAppsInput, listAppsOutput,
    (i) => listApps(client, i),
    (o) => `${o.count} tracked app${o.count === 1 ? "" : "s"}.`),
);

server.registerTool(
  "list_keywords",
  {
    title: "List tracked keywords",
    description: "Return all keywords with their term and country, across all tracked apps.",
    inputSchema: shapeOf(listKeywordsInput),
    outputSchema: shapeOf(listKeywordsOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("list_keywords", listKeywordsInput, listKeywordsOutput,
    (i) => listKeywords(client, i),
    (o) => `${o.count} tracked keyword${o.count === 1 ? "" : "s"}.`),
);

server.registerTool(
  "keyword_history",
  {
    title: "Keyword rank history",
    description:
      "Return the full rank-check timeline for one keyword. Optionally filter to a single tracked app. " +
      "Each point is one observed rank (with difficulty and entry barrier) at a point in time.",
    inputSchema: shapeOf(keywordHistoryInput),
    outputSchema: shapeOf(keywordHistoryOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("keyword_history", keywordHistoryInput, keywordHistoryOutput,
    (i) => keywordHistory(client, i),
    (o) => `${o.count} rank check${o.count === 1 ? "" : "s"} for keyword ${o.keywordId}${o.watchedAppId ? ` on app ${o.watchedAppId}` : ""}.`),
);

server.registerTool(
  "dashboard",
  {
    title: "Dashboard rollup",
    description:
      "Return the latest (keyword × app) rank rollup — same data the SPA dashboard shows. " +
      "Optionally filter by 2-letter country code.",
    inputSchema: shapeOf(dashboardInput),
    outputSchema: shapeOf(dashboardOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("dashboard", dashboardInput, dashboardOutput,
    (i) => dashboard(client, i),
    (o) => `${o.count} dashboard row${o.count === 1 ? "" : "s"}${o.countryFilter ? ` (country=${o.countryFilter})` : ""}.`),
);

server.registerTool(
  "chart_movements",
  {
    title: "Chart positions + recent events",
    description:
      "Return current charted positions for all tracked apps PLUS the recent activity feed " +
      "(entered / moved / exited). Answers 'what's happening on the charts right now?' in one call.",
    inputSchema: shapeOf(chartMovementsInput),
    outputSchema: shapeOf(chartMovementsOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("chart_movements", chartMovementsInput, chartMovementsOutput,
    (i) => chartMovements(client, i),
    (o) => `${o.positionsCount} active position${o.positionsCount === 1 ? "" : "s"}, ${o.eventsCount} recent event${o.eventsCount === 1 ? "" : "s"}.`),
);

server.registerTool(
  "competitor_gaps",
  {
    title: "Competitor keyword gaps",
    description:
      "For one of YOUR apps, return the (keyword × competitor) gap matrix: where each competitor " +
      "out-ranks you ('behind') or ranks while you're absent ('pureGap'), plus where you're ahead/tied. " +
      "Rows are sorted most-urgent-first. Get the app id from `list_apps` (kind == 'own').",
    inputSchema: shapeOf(competitorGapsInput),
    outputSchema: shapeOf(competitorGapsOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("competitor_gaps", competitorGapsInput, competitorGapsOutput,
    (i) => competitorGaps(client, i),
    (o) => `${o.losingCount} losing gap${o.losingCount === 1 ? "" : "s"} of ${o.count} cell${o.count === 1 ? "" : "s"}.`),
);

server.registerTool(
  "keyword_opportunity",
  {
    title: "Keyword opportunity scores",
    description:
      "Opportunity scores (impressions ÷ difficulty) for ASA-covered keywords — real Apple Search " +
      "Ads impressions weighed against difficulty, best bets first. Only keywords with ASA data " +
      "appear; everything else stays difficulty-only.",
    inputSchema: shapeOf(keywordOpportunityInput),
    outputSchema: shapeOf(keywordOpportunityOutput),
    annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
  },
  wrap("keyword_opportunity", keywordOpportunityInput, keywordOpportunityOutput,
    (i) => keywordOpportunity(client, i),
    (o) => `${o.count} keyword${o.count === 1 ? "" : "s"} with an opportunity score.`),
);

// ---------------------------------------------------------------------------
// Write tools
// ---------------------------------------------------------------------------
server.registerTool(
  "add_app",
  {
    title: "Track a new app",
    description:
      "Add an app to track by its iTunes track id (the number in apps.apple.com/.../id<NUMBER>). " +
      "Triggers a background storefront-availability probe across all 175 territories.",
    inputSchema: shapeOf(addAppInput),
    outputSchema: shapeOf(addAppOutput),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  wrap("add_app", addAppInput, addAppOutput,
    (i) => addApp(client, i),
    (o) => `Now tracking ${o.app.name} (id ${o.app.id}).`),
);

server.registerTool(
  "add_keyword",
  {
    title: "Track a new keyword",
    description:
      "Add a keyword to track in a specific App Store country. The server immediately " +
      "queues a first refresh; call `refresh` with kind:'keyword' afterward to block on results.",
    inputSchema: shapeOf(addKeywordInput),
    outputSchema: shapeOf(addKeywordOutput),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  wrap("add_keyword", addKeywordInput, addKeywordOutput,
    (i) => addKeyword(client, i),
    (o) => `Now tracking '${o.keyword.term}' in ${o.keyword.countryCode} (id ${o.keyword.id}).`),
);

server.registerTool(
  "remove_app",
  {
    title: "Stop tracking an app",
    description: "Delete a tracked app and all its rank history. Requires `confirm: true`.",
    inputSchema: shapeOf(removeAppInput),
    outputSchema: shapeOf(removeAppOutput),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true },
  },
  wrap("remove_app", removeAppInput, removeAppOutput,
    (i) => removeApp(client, i),
    (o) => `Deleted app ${o.id}.`),
);

server.registerTool(
  "remove_keyword",
  {
    title: "Stop tracking a keyword",
    description: "Delete a tracked keyword and all its rank history. Requires `confirm: true`.",
    inputSchema: shapeOf(removeKeywordInput),
    outputSchema: shapeOf(removeKeywordOutput),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true },
  },
  wrap("remove_keyword", removeKeywordInput, removeKeywordOutput,
    (i) => removeKeyword(client, i),
    (o) => `Deleted keyword ${o.id}.`),
);

// ---------------------------------------------------------------------------
// Workflow tool: refresh
// ---------------------------------------------------------------------------
// refreshInput is a ZodEffects (object + refine), not a bare ZodObject — so
// we reach into its inner shape via the schema's `_def`. The MCP SDK only
// reads the raw shape for JSON-Schema generation; the .refine() validation
// runs inside `wrap()` via the full schema's .parse() call.
const refreshInnerShape = (refreshInput as unknown as { _def: { schema: z.ZodObject<Record<string, ZodTypeAny>> } })._def.schema.shape;
server.registerTool(
  "refresh",
  {
    title: "Refresh and wait",
    description:
      "Trigger a refresh (single keyword, all keywords, charts, or app availability) and " +
      "poll the queue until it drains or `timeoutMs` elapses. If timed out, the work continues " +
      "server-side at ~1 keyword/sec — re-invoke or query the dashboard later.",
    inputSchema: refreshInnerShape,
    outputSchema: shapeOf(refreshOutput),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  wrap("refresh", refreshInput, refreshOutput,
    (i) => refresh(client, i),
    (o) => o.drained
      ? `Refresh (${o.kind}) drained in ${Math.round(o.elapsedMs / 1000)}s after ${o.pollCount} polls.`
      : `Refresh (${o.kind}) still in flight after ${Math.round(o.elapsedMs / 1000)}s — ${o.finalStatus.pending} job(s) pending server-side.`),
);

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
const transport = new StdioServerTransport();
await server.connect(transport);
// No console.log here — stdio MCP servers use stdout for JSON-RPC frames.
// Diagnostics belong on stderr if needed.
