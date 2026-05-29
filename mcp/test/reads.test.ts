/**
 * Pins the competitor_gaps tool's contract:
 *   1. Vapor OMITS nil optionals, so absent ranks arrive as missing keys —
 *      they must normalize to explicit null, not crash the zod parse.
 *   2. Rows come back sorted most-urgent-first (by verdict.score).
 *   3. losingCount counts the actionable kinds (behind + pureGap).
 */
import { describe, expect, it } from "vitest";

import { competitorGaps, metadataLint } from "../src/tools/reads.js";
import type { ApiClient } from "../src/client.js";

function fakeClient(rows: unknown): ApiClient {
  return {
    resolution: async () => ({ baseURL: "http://fake", source: "env" }),
    get: async (path: string) => {
      if (path.endsWith("/gaps")) return rows;
      throw new Error(`unexpected GET ${path}`);
    },
    post: async () => ({}) as unknown,
    del: async () => {},
  };
}

const APP = "11111111-1111-1111-1111-111111111111";
const KW = "22222222-2222-2222-2222-222222222222";
const C1 = "33333333-3333-3333-3333-333333333333";
const C2 = "44444444-4444-4444-4444-444444444444";

describe("competitorGaps", () => {
  it("normalizes omitted ranks to null, sorts by urgency, counts losing rows", async () => {
    // Wire shape exactly as Vapor emits it: nil optionals are ABSENT keys.
    const raw = [
      // ahead: I rank, competitor absent (competitorRank key omitted)
      { keywordId: KW, term: "x", countryCode: "us", competitorAppId: C1, competitorName: "A", myRank: 3, verdict: { kind: "ahead", score: -1 } },
      // pureGap: competitor ranks, I'm absent (myRank key omitted) — most urgent
      { keywordId: KW, term: "x", countryCode: "us", competitorAppId: C2, competitorName: "B", competitorRank: 2, verdict: { kind: "pureGap", score: 10198 } },
      // behind: both rank, competitor ahead
      { keywordId: KW, term: "x", countryCode: "us", competitorAppId: C1, competitorName: "A", myRank: 40, competitorRank: 5, verdict: { kind: "behind", score: 230 } },
    ];
    const out = await competitorGaps(fakeClient(raw), { appId: APP });

    expect(out.count).toBe(3);
    expect(out.losingCount).toBe(2); // pureGap + behind
    expect(out.rows.map((r) => r.verdict.kind)).toEqual(["pureGap", "behind", "ahead"]);

    const pure = out.rows[0];
    expect(pure.myRank).toBeNull(); // omitted → normalized to null
    expect(pure.competitorRank).toBe(2);

    const ahead = out.rows[2];
    expect(ahead.competitorRank).toBeNull(); // omitted → normalized to null
  });
});

function fakeLintClient(rows: unknown): ApiClient {
  return {
    resolution: async () => ({ baseURL: "http://fake", source: "env" }),
    get: async (path: string) => {
      if (path.endsWith("/metadata/lint")) return rows;
      throw new Error(`unexpected GET ${path}`);
    },
    post: async () => ({}) as unknown,
    del: async () => {},
  };
}

describe("metadataLint", () => {
  it("parses findings and counts warnings", async () => {
    const raw = [
      { rule: "duplicateWord", severity: "warning", field: "title+subtitle", message: "x" },
      { rule: "wastedBudget", severity: "info", field: "title", message: "y" },
      { rule: "untrackedWord", severity: "info", field: "title+subtitle", message: "z" },
    ];
    const out = await metadataLint(fakeLintClient(raw), { appId: APP });
    expect(out.count).toBe(3);
    expect(out.warningCount).toBe(1);
    expect(out.findings.map((f) => f.rule)).toEqual([
      "duplicateWord",
      "wastedBudget",
      "untrackedWord",
    ]);
  });
});
