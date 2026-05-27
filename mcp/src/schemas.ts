/**
 * Zod mirrors of the Vapor `Content` DTOs. The shapes here are the wire
 * contract — keep them in lockstep with:
 *   - Sources/App/Models/*.swift               (Fluent models for WatchedApp, Keyword, RankCheck)
 *   - Sources/App/Domain/DomainTypes.swift     (DashboardRow, HistoryPoint, AppKeywordRow)
 *   - Sources/App/Controllers/ChartsController.swift (ChartPositionDTO, ChartEventDTO)
 *   - Sources/App/Services/QueueStatusService.swift  (QueueStatus)
 *
 * Date strategy: the server uses ISO8601 with fractional seconds — JS `new Date()`
 * parses these cleanly. We keep them as strings in zod (using z.string().datetime()
 * with offset support) so MCP clients see them as ISO strings rather than re-encoded
 * Date objects, which is what the SDK does anyway.
 */
import { z } from "zod";

// ISO8601 with optional fractional seconds and offset. Accepts both "Z" and
// "+00:00" suffixes. `offset: true` makes the validator accept timezone offsets
// (without it, only "Z" is allowed).
const iso8601 = z.string().datetime({ offset: true });
const uuid = z.string().uuid();

// ---------------------------------------------------------------------------
// Apps
// ---------------------------------------------------------------------------
export const WatchedApp = z.object({
  id: uuid,
  appStoreId: z.number().int(),
  bundleId: z.string(),
  name: z.string(),
  iconURL: z.string().nullable().optional(),
  primaryGenreId: z.number().int().nullable().optional(),
  addedAt: iso8601.nullable().optional(),
});
export type WatchedApp = z.infer<typeof WatchedApp>;

// ---------------------------------------------------------------------------
// Keywords
// ---------------------------------------------------------------------------
export const Keyword = z.object({
  id: uuid,
  term: z.string(),
  countryCode: z.string().length(2),
  createdAt: iso8601.nullable().optional(),
});
export type Keyword = z.infer<typeof Keyword>;

// ---------------------------------------------------------------------------
// Refresh + queue
// ---------------------------------------------------------------------------
// Both /keywords endpoints return `{enqueued: N}`. The charts/availability
// endpoints return `{queued: true}` (see ChartsController.RefreshAcceptedDTO).
// We accept either shape so callers don't have to care.
export const RefreshResponse = z.union([
  z.object({ enqueued: z.number().int() }),
  z.object({ queued: z.boolean() }),
]);
export type RefreshResponse = z.infer<typeof RefreshResponse>;

export const QueueStatus = z.object({
  pending: z.number().int().min(0),
});
export type QueueStatus = z.infer<typeof QueueStatus>;

// ---------------------------------------------------------------------------
// Dashboard + history (Domain/DomainTypes.swift)
// ---------------------------------------------------------------------------
export const TopResult = z.object({
  position: z.number().int(),
  appStoreId: z.number().int(),
  name: z.string(),
  iconURL: z.string().nullable().optional(),
});

export const DashboardRow = z.object({
  keywordId: uuid,
  term: z.string(),
  countryCode: z.string(),
  watchedAppId: uuid,
  watchedAppName: z.string(),
  rank: z.number().int().nullable(),
  previousRank: z.number().int().nullable(),
  hasPreviousCheck: z.boolean(),
  difficulty: z.number().int(),
  entryBarrier: z.number().int(),
  checkedAt: iso8601.nullable(),
  topResults: z.array(TopResult),
});
export type DashboardRow = z.infer<typeof DashboardRow>;

export const HistoryPoint = z.object({
  checkedAt: iso8601,
  rank: z.number().int().nullable(),
  difficulty: z.number().int(),
  entryBarrier: z.number().int(),
});
export type HistoryPoint = z.infer<typeof HistoryPoint>;

export const AppKeywordRow = z.object({
  keywordId: uuid,
  term: z.string(),
  countryCode: z.string(),
  rank: z.number().int().nullable(),
  difficulty: z.number().int(),
  entryBarrier: z.number().int(),
  checkedAt: iso8601.nullable(),
});
export type AppKeywordRow = z.infer<typeof AppKeywordRow>;

// ---------------------------------------------------------------------------
// Chart watchdog (ChartsController.swift)
// ---------------------------------------------------------------------------
// chart-positions is server-side filtered to non-null positions, so the DTO
// has position: Int (not optional). chart-events keeps position nullable
// because an "exited" event has no current position.
export const ChartPositionDTO = z.object({
  appId: uuid,
  appName: z.string(),
  country: z.string(),
  chartType: z.string(),
  genreId: z.number().int(),
  position: z.number().int(),
  observedAt: iso8601,
});
export type ChartPositionDTO = z.infer<typeof ChartPositionDTO>;

export const ChartEventDTO = z.object({
  id: uuid,
  appId: uuid,
  appName: z.string(),
  country: z.string(),
  chartType: z.string(),
  genreId: z.number().int(),
  kind: z.enum(["entered", "moved", "exited"]),
  position: z.number().int().nullable(),
  prevPosition: z.number().int().nullable(),
  createdAt: iso8601,
});
export type ChartEventDTO = z.infer<typeof ChartEventDTO>;
