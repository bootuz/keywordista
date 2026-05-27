/**
 * Wait for the Vapor queue to drain after triggering a refresh.
 *
 * The contract from the server side:
 *   - Refresh endpoints return 202 Accepted immediately with `{enqueued: N}`
 *     or `{queued: true}`.
 *   - The work runs in a single-threaded queue (`workerCount = 1` is
 *     intentional, see Sources/App/configure.swift — parallel workers cause
 *     both iTunes 504s and SQLite "database is locked" errors).
 *   - Completion is signaled by `GET /refresh-status` returning
 *     `{pending: 0}`.
 *
 * Because the worker is rate-limited to ~1 req/sec to iTunes, a
 * "refresh all" over 50 keywords will easily exceed any reasonable
 * single-tool-call timeout. So the contract here is "wait up to
 * `timeoutMs`, then return the last known status with a clear note
 * that work continues server-side." The caller (the workflow tool)
 * is responsible for shaping that hint in its response.
 */
import { QueueStatus, type QueueStatus as QueueStatusT, RefreshResponse, type RefreshResponse as RefreshResponseT } from "./schemas.js";
import { type ApiClient } from "./client.js";

export interface RefreshWaitOptions {
  /** Absolute upper bound on how long this call blocks. Default 60_000. */
  timeoutMs?: number;
  /** Starting poll cadence in ms. Default 500. */
  pollIntervalMs?: number;
  /** Hook for tests to substitute a fake clock. Default `setTimeout`. */
  sleep?: (ms: number) => Promise<void>;
  /** Hook for tests / cancellation. */
  signal?: AbortSignal;
}

export interface RefreshWaitOutcome {
  trigger: RefreshResponseT;
  finalStatus: QueueStatusT;
  /** True if the queue actually drained; false if we returned on timeout. */
  drained: boolean;
  elapsedMs: number;
  pollCount: number;
}

const defaultSleep = (ms: number) =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });

/**
 * Trigger a refresh (via the caller-provided `trigger` thunk) and poll
 * `/refresh-status` until the queue drains or `timeoutMs` elapses.
 *
 * The `trigger` thunk is a callback rather than a URL because each refresh
 * variant hits a different endpoint (POST /keywords/:id/refresh,
 * POST /refresh-all, POST /charts/refresh, POST /apps/:id/availability/refresh)
 * and we want one workflow tool to handle them all.
 */
export async function refreshAndWait(
  trigger: () => Promise<unknown>,
  client: ApiClient,
  opts: RefreshWaitOptions = {},
): Promise<RefreshWaitOutcome> {
  const timeoutMs = opts.timeoutMs ?? 60_000;
  const baseInterval = opts.pollIntervalMs ?? 500;
  const sleep = opts.sleep ?? defaultSleep;
  const signal = opts.signal;

  const startedAt = Date.now();
  const triggerRaw = await trigger();
  const triggerParsed = RefreshResponse.parse(triggerRaw);

  let pollCount = 0;
  let lastStatus: QueueStatusT = { pending: 0 };

  while (true) {
    if (signal?.aborted) {
      throw new DOMException("refresh wait aborted", "AbortError");
    }

    pollCount++;
    const raw = await client.get("/refresh-status");
    lastStatus = QueueStatus.parse(raw);

    const elapsedMs = Date.now() - startedAt;

    if (lastStatus.pending === 0) {
      return { trigger: triggerParsed, finalStatus: lastStatus, drained: true, elapsedMs, pollCount };
    }
    if (elapsedMs >= timeoutMs) {
      return { trigger: triggerParsed, finalStatus: lastStatus, drained: false, elapsedMs, pollCount };
    }

    const remaining = timeoutMs - elapsedMs;
    const wait = Math.min(remaining, nextPollDelayMs(pollCount, baseInterval));
    await sleep(wait);
  }
}

/**
 * Compute the delay before the next /refresh-status poll given how many
 * polls have already happened. Returns milliseconds.
 *
 * Context to consider when shaping the curve:
 *   - The Vapor worker processes ~1 keyword/sec (iTunes rate limit).
 *   - A single-keyword refresh typically finishes in 1–3s; refresh-all
 *     scales linearly with keyword count (50 keywords ≈ 50s).
 *   - Polling too aggressively wastes CPU and floods the log;
 *     polling too lazily makes the agent's response feel sluggish
 *     for the common single-keyword case.
 *   - `baseInterval` is the starting cadence the caller picked (default
 *     500ms). It's reasonable to keep that for the first few polls,
 *     then back off for the long tail.
 *
 * NOTE: implementation is intentionally left for you to fill in — this
 * is the one spot in the file where the choice meaningfully shapes UX.
 * See PoC below; replace with your preferred curve.
 */
export function nextPollDelayMs(pollCount: number, baseInterval: number): number {
  // Linear ramp: starts at `baseInterval` (default 500ms) for snappy
  // single-keyword refreshes (typically done in 2–3 polls), adds 250ms
  // per subsequent poll, and caps at 5s. For a 50-keyword refresh-all
  // (~50s of work at workerCount=1), this settles into ~5s polls after
  // ~20 polls — roughly 12 total polls instead of the ~100 that a flat
  // 500ms cadence would fire.
  const POLL_INCREMENT_MS = 250;
  const POLL_CAP_MS = 5_000;
  return Math.min(POLL_CAP_MS, baseInterval + pollCount * POLL_INCREMENT_MS);
}
