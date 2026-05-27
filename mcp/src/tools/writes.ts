/**
 * Mutation tools — add/remove apps and keywords.
 *
 * Deletes require an explicit `confirm: true` flag. The MCP spec lets clients
 * elicit confirmation interactively, but not every client (or every agent
 * invocation) honors it. Failing closed on accidental destructive calls is
 * cheap insurance for a single-user tool where the data is hand-curated.
 */
import { z } from "zod";
import type { ApiClient } from "../client.js";
import { WatchedApp, Keyword } from "../schemas.js";

// ---------------------------------------------------------------------------
// add_app
// ---------------------------------------------------------------------------
export const addAppInput = z
  .object({
    appStoreId: z
      .number()
      .int()
      .positive()
      .describe("iTunes track ID — the numeric id from apps.apple.com/.../id<NUMBER>."),
    lookupCountry: z
      .string()
      .length(2)
      .optional()
      .describe(
        "2-letter ISO country code used only to fetch the app's metadata (name, bundle id, icon). " +
          "Defaults to 'us'. This is NOT the country the app is tracked in — that's per-keyword.",
      ),
  })
  .strict();

export const addAppOutput = z.object({
  app: WatchedApp,
});

export async function addApp(client: ApiClient, input: z.infer<typeof addAppInput>) {
  const raw = await client.post<unknown>("/apps", {
    appStoreId: input.appStoreId,
    ...(input.lookupCountry !== undefined ? { lookupCountry: input.lookupCountry } : {}),
  });
  return { app: WatchedApp.parse(raw) };
}

// ---------------------------------------------------------------------------
// add_keyword
// ---------------------------------------------------------------------------
// Creation triggers an automatic refresh server-side (KeywordService.create
// dispatches immediately). We don't expose `waitForFirstRank` here — if the
// user wants to block on a rank, they call `refresh` with kind:"keyword" after.
// Keeps each tool single-purpose; the agent composes cleanly.
export const addKeywordInput = z
  .object({
    term: z.string().min(1).describe("The keyword phrase. Non-empty."),
    countryCode: z
      .string()
      .length(2)
      .describe("2-letter ISO country code for the App Store storefront to track in (e.g. 'us', 'de')."),
  })
  .strict();

export const addKeywordOutput = z.object({
  keyword: Keyword,
  refreshEnqueued: z
    .boolean()
    .describe(
      "Always true — keyword creation server-side dispatches an immediate refresh. " +
        "Call `refresh` with kind:'keyword' and this id to block on the first rank result.",
    ),
});

export async function addKeyword(client: ApiClient, input: z.infer<typeof addKeywordInput>) {
  const raw = await client.post<unknown>("/keywords", {
    term: input.term,
    countryCode: input.countryCode,
  });
  return { keyword: Keyword.parse(raw), refreshEnqueued: true };
}

// ---------------------------------------------------------------------------
// remove_app
// ---------------------------------------------------------------------------
export const removeAppInput = z
  .object({
    id: z.string().uuid().describe("App UUID (from `list_apps`)."),
    confirm: z
      .literal(true)
      .describe("Must be set to `true`. Guard against accidental deletes."),
  })
  .strict();
export const removeAppOutput = z.object({
  id: z.string().uuid(),
  deleted: z.literal(true),
});

export async function removeApp(client: ApiClient, input: z.infer<typeof removeAppInput>) {
  await client.del(`/apps/${input.id}`);
  return { id: input.id, deleted: true as const };
}

// ---------------------------------------------------------------------------
// remove_keyword
// ---------------------------------------------------------------------------
export const removeKeywordInput = z
  .object({
    id: z.string().uuid().describe("Keyword UUID (from `list_keywords`)."),
    confirm: z.literal(true).describe("Must be set to `true`. Guard against accidental deletes."),
  })
  .strict();
export const removeKeywordOutput = z.object({
  id: z.string().uuid(),
  deleted: z.literal(true),
});

export async function removeKeyword(client: ApiClient, input: z.infer<typeof removeKeywordInput>) {
  await client.del(`/keywords/${input.id}`);
  return { id: input.id, deleted: true as const };
}
