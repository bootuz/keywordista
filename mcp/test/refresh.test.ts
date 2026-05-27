/**
 * Pin the contract of refreshAndWait + nextPollDelayMs.
 *
 * Two things matter:
 *   1. The loop terminates when /refresh-status reports {pending: 0}.
 *   2. The loop terminates cleanly on timeout, reporting drained=false and
 *      the last known pending count.
 *
 * We inject a fake `sleep` so tests run instantly, and a fake ApiClient
 * whose /refresh-status responses are scripted per call.
 */
import { describe, expect, it, vi } from "vitest";

import { refreshAndWait, nextPollDelayMs } from "../src/refresh.js";
import type { ApiClient } from "../src/client.js";

function fakeClient(statusSequence: number[]): ApiClient {
  let idx = 0;
  return {
    resolution: async () => ({ baseURL: "http://fake", source: "env" }),
    get: async (path: string) => {
      if (path === "/refresh-status") {
        const pending = statusSequence[Math.min(idx, statusSequence.length - 1)] ?? 0;
        idx++;
        return { pending } as unknown;
      }
      throw new Error(`unexpected GET ${path}`);
    },
    post: async () => ({ enqueued: 1 }) as unknown,
    del: async () => {},
  };
}

describe("refreshAndWait", () => {
  it("returns drained=true when the queue empties", async () => {
    // Worker reports 2 pending, then 1, then 0.
    const client = fakeClient([2, 1, 0]);
    const trigger = vi.fn().mockResolvedValue({ enqueued: 2 });
    const sleep = vi.fn().mockResolvedValue(undefined);

    const outcome = await refreshAndWait(trigger, client, { sleep, pollIntervalMs: 10, timeoutMs: 5_000 });

    expect(trigger).toHaveBeenCalledOnce();
    expect(outcome.drained).toBe(true);
    expect(outcome.finalStatus.pending).toBe(0);
    expect(outcome.pollCount).toBe(3);
    // Slept twice between three polls.
    expect(sleep).toHaveBeenCalledTimes(2);
  });

  it("returns drained=false on timeout with the last observed status", async () => {
    // Stays at 5 pending forever — must time out.
    const client = fakeClient([5]);
    const trigger = vi.fn().mockResolvedValue({ enqueued: 5 });
    // Sleep advances time so the loop's elapsedMs check actually fires.
    let virtualNow = 0;
    const sleep = vi.fn().mockImplementation(async (ms: number) => {
      virtualNow += ms;
    });
    vi.spyOn(Date, "now").mockImplementation(() => virtualNow);

    const outcome = await refreshAndWait(trigger, client, { sleep, pollIntervalMs: 100, timeoutMs: 1_000 });

    expect(outcome.drained).toBe(false);
    expect(outcome.finalStatus.pending).toBe(5);
    expect(outcome.pollCount).toBeGreaterThan(0);
  });

  it("accepts either {enqueued} or {queued} trigger shapes", async () => {
    const client = fakeClient([0]);
    const sleep = vi.fn().mockResolvedValue(undefined);

    const aEnqueued = await refreshAndWait(async () => ({ enqueued: 3 }), client, { sleep });
    expect(aEnqueued.trigger).toEqual({ enqueued: 3 });

    const client2 = fakeClient([0]);
    const aQueued = await refreshAndWait(async () => ({ queued: true }), client2, { sleep });
    expect(aQueued.trigger).toEqual({ queued: true });
  });
});

describe("nextPollDelayMs", () => {
  it("starts near the base interval and grows linearly", () => {
    const base = 500;
    expect(nextPollDelayMs(1, base)).toBe(750); // 500 + 250
    expect(nextPollDelayMs(2, base)).toBe(1000);
    expect(nextPollDelayMs(4, base)).toBe(1500);
  });

  it("caps at 5 seconds for long-running batches", () => {
    expect(nextPollDelayMs(20, 500)).toBe(5_000);
    expect(nextPollDelayMs(100, 500)).toBe(5_000);
    expect(nextPollDelayMs(1_000, 500)).toBe(5_000);
  });
});
