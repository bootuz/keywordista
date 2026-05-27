/**
 * Cover the three-tier resolution order in runtime.ts.
 *
 * The strategies are intentionally independent (env > file > probe), so each
 * branch is testable in isolation by stubbing the others. We inject the
 * sidecar path explicitly (production reads runtimeFilePath()) so tests
 * don't depend on or touch the real user home dir, and stub global fetch
 * for the port-probe branch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

import { resolveBaseURL, BaseURLResolutionError, runtimeFilePath } from "../src/runtime.js";

const TEST_ENV_VAR = "KEYWORDISTA_TEST_BASE_URL"; // isolated from any real shell env

describe("resolveBaseURL precedence", () => {
  let tmpDir: string;
  let missingSidecar: string;

  beforeEach(async () => {
    delete process.env[TEST_ENV_VAR];
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "keywordista-mcp-"));
    missingSidecar = path.join(tmpDir, "does-not-exist.json");
  });

  afterEach(async () => {
    delete process.env[TEST_ENV_VAR];
    vi.restoreAllMocks();
    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  it("uses the env var when set", async () => {
    process.env[TEST_ENV_VAR] = "http://example.test:9999";
    const fetchSpy = vi.spyOn(globalThis, "fetch");

    const result = await resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath: missingSidecar });
    expect(result.source).toBe("env");
    expect(result.baseURL).toBe("http://example.test:9999");
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("trims a trailing slash from the env var", async () => {
    process.env[TEST_ENV_VAR] = "http://example.test:9999/";
    const result = await resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath: missingSidecar });
    expect(result.baseURL).toBe("http://example.test:9999");
  });

  it("falls back to the runtime sidecar when env is unset", async () => {
    const sidecarPath = path.join(tmpDir, "runtime.json");
    await fs.writeFile(
      sidecarPath,
      JSON.stringify({ baseURL: "http://127.0.0.1:8083", pid: 12345, writtenAt: new Date().toISOString() }),
    );
    const fetchSpy = vi.spyOn(globalThis, "fetch");

    const result = await resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath });
    expect(result.source).toBe("runtime-file");
    expect(result.baseURL).toBe("http://127.0.0.1:8083");
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("falls back to a port probe when env and sidecar are missing", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : (input as URL).toString();
      // Pretend only :8082 is alive.
      if (url.includes(":8082")) return new Response("ok", { status: 200 });
      return new Response("", { status: 503 });
    });

    const result = await resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath: missingSidecar });
    expect(result.source).toBe("port-probe");
    expect(result.baseURL).toBe("http://127.0.0.1:8082");
  });

  it("throws an actionable error when all strategies fail", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 503 }));
    await expect(resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath: missingSidecar })).rejects.toThrow(
      BaseURLResolutionError,
    );
    await expect(resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath: missingSidecar })).rejects.toThrow(
      /Could not find a running Keywordista server/,
    );
  });

  it("ignores a malformed sidecar file (treats it as missing)", async () => {
    const sidecarPath = path.join(tmpDir, "runtime.json");
    await fs.writeFile(sidecarPath, "this is not json");
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 503 }));

    // Should not throw a JSON parse error — should bubble up the resolution error.
    await expect(resolveBaseURL({ envVar: TEST_ENV_VAR, sidecarPath })).rejects.toThrow(BaseURLResolutionError);
  });
});

describe("runtimeFilePath", () => {
  it("returns a platform-appropriate Keywordista path", () => {
    const p = runtimeFilePath();
    expect(p).toMatch(/Keywordista/);
    expect(p).toMatch(/runtime\.json$/);
  });
});
