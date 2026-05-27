/**
 * One workflow tool that wraps all four refresh endpoints + the poll loop.
 *
 *   kind: "keyword"      → POST /keywords/:id/refresh
 *   kind: "all"          → POST /refresh-all
 *   kind: "charts"       → POST /charts/refresh
 *   kind: "availability" → POST /apps/:id/availability/refresh
 *
 * In all four cases the server replies 202 Accepted, then runs the work in
 * the single-threaded queue. We trigger the right endpoint, then poll
 * /refresh-status until {pending: 0} or the timeout fires.
 *
 * Why one tool instead of four: the agent's mental model collapses to
 * "there is one refresh action." Each variant is just a parameter.
 */
import { z } from "zod";
import type { ApiClient } from "../client.js";
import { refreshAndWait } from "../refresh.js";
import { QueueStatus } from "../schemas.js";

// Flat object (not a discriminatedUnion) so the MCP SDK's registerTool can
// accept it as a ZodRawShape. The cross-field validation lives in `.refine()`
// below — agent sees a clean schema with one optional id field per kind.
export const refreshInput = z
  .object({
    kind: z
      .enum(["keyword", "all", "charts", "availability"])
      .describe(
        "What to refresh. 'keyword' refreshes one keyword for all tracked apps; " +
          "'all' refreshes every keyword (rate-limited to ~1/sec); 'charts' kicks " +
          "the chart-watchdog cycle; 'availability' re-probes one app's storefronts.",
      ),
    keywordId: z
      .string()
      .uuid()
      .optional()
      .describe("Required when kind='keyword'. Keyword UUID from `list_keywords`."),
    appId: z
      .string()
      .uuid()
      .optional()
      .describe("Required when kind='availability'. App UUID from `list_apps`."),
    timeoutMs: z
      .number()
      .int()
      .positive()
      .max(300_000)
      .optional()
      .describe("Upper bound on how long this call blocks (max 300_000ms / 5min). Default 60_000."),
  })
  .strict()
  .refine((v) => (v.kind === "keyword" ? !!v.keywordId : true), {
    message: "kind='keyword' requires keywordId",
    path: ["keywordId"],
  })
  .refine((v) => (v.kind === "availability" ? !!v.appId : true), {
    message: "kind='availability' requires appId",
    path: ["appId"],
  });

export const refreshOutput = z.object({
  kind: z.enum(["keyword", "all", "charts", "availability"]),
  drained: z.boolean().describe("True if the queue drained within the timeout; false if work continues server-side."),
  finalStatus: QueueStatus,
  elapsedMs: z.number().int(),
  pollCount: z.number().int(),
  note: z.string().optional(),
});

export async function refresh(client: ApiClient, input: z.infer<typeof refreshInput>) {
  const trigger = () => triggerForKind(client, input);
  const opts = input.timeoutMs !== undefined ? { timeoutMs: input.timeoutMs } : {};
  const outcome = await refreshAndWait(trigger, client, opts);

  const note = outcome.drained
    ? undefined
    : `Queue still has ${outcome.finalStatus.pending} pending job(s) after ${Math.round(
        outcome.elapsedMs / 1000,
      )}s. Work continues server-side at ~1 keyword/sec; call this tool again with a longer timeoutMs or query the dashboard later.`;

  return {
    kind: input.kind,
    drained: outcome.drained,
    finalStatus: outcome.finalStatus,
    elapsedMs: outcome.elapsedMs,
    pollCount: outcome.pollCount,
    ...(note !== undefined ? { note } : {}),
  };
}

function triggerForKind(client: ApiClient, input: z.infer<typeof refreshInput>): Promise<unknown> {
  switch (input.kind) {
    case "keyword":
      // refine() above guarantees keywordId is present at this point.
      return client.post(`/keywords/${input.keywordId!}/refresh`);
    case "all":
      return client.post("/refresh-all");
    case "charts":
      return client.post("/charts/refresh");
    case "availability":
      return client.post(`/apps/${input.appId!}/availability/refresh`);
  }
}
