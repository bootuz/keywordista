/**
 * Resolve the Keywordista server's base URL.
 *
 * Resolution order (first hit wins):
 *   1. `KEYWORDISTA_BASE_URL` env var.
 *      Escape hatch for Docker / self-hosted / custom setups, and the channel
 *      MCPB clients use when the user fills in `base_url` in the UI.
 *   2. Runtime sidecar at `~/Library/Application Support/Keywordista/runtime.json`.
 *      Written by `ServiceSupervisor.start()` after the menubar app picks a
 *      free port from 8080–8090. Shape: `{ baseURL, pid, writtenAt }`.
 *   3. Sequential `/health` probe across 8080–8090.
 *      Last-resort fallback so the MCP server is useful even if the sidecar
 *      file got corrupted, an older menubar build didn't write it, or the
 *      user is running `swift run` by hand.
 *
 * If all three fail, throws a single error with actionable guidance for the
 * agent to relay to the user. The error is intentionally human-readable —
 * it's the most common failure mode (server not running) and the agent
 * shouldn't have to invent a diagnosis from a network stack trace.
 */
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

const ENV_VAR = "KEYWORDISTA_BASE_URL";
const PORT_RANGE_START = 8080;
const PORT_RANGE_END = 8090;
const PROBE_TIMEOUT_MS = 800;

export interface ResolutionResult {
  baseURL: string;
  source: "env" | "runtime-file" | "port-probe";
}

export class BaseURLResolutionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BaseURLResolutionError";
  }
}

/**
 * The runtime sidecar lives in the same app-support dir that
 * ServiceSupervisor uses for the data dir and the downloaded service binary.
 * On macOS this is `~/Library/Application Support/Keywordista/runtime.json`.
 * On Linux/Windows we follow the same convention under the OS's data dir —
 * the menubar app only runs on macOS, but a future Linux build could write
 * the same file under `~/.local/share/Keywordista/`.
 */
export function runtimeFilePath(): string {
  const platform = process.platform;
  if (platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "Keywordista", "runtime.json");
  }
  if (platform === "win32") {
    const appData = process.env["APPDATA"] ?? path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "Keywordista", "runtime.json");
  }
  // Linux / others: XDG_DATA_HOME with the conventional fallback.
  const xdg = process.env["XDG_DATA_HOME"] ?? path.join(os.homedir(), ".local", "share");
  return path.join(xdg, "Keywordista", "runtime.json");
}

async function readRuntimeFile(sidecarPath: string): Promise<string | null> {
  try {
    const raw = await fs.readFile(sidecarPath, "utf8");
    const parsed = JSON.parse(raw) as { baseURL?: unknown };
    if (typeof parsed.baseURL === "string" && parsed.baseURL.length > 0) {
      return parsed.baseURL;
    }
    return null;
  } catch {
    // ENOENT, malformed JSON, permission denied — all fall through to the
    // next strategy. The probe will report the real "server is down" error
    // if it turns out the file's absence is the actual problem.
    return null;
  }
}

async function probeHealth(baseURL: string, timeoutMs: number): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${baseURL}/health`, { signal: controller.signal });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function probePortRange(): Promise<string | null> {
  for (let port = PORT_RANGE_START; port <= PORT_RANGE_END; port++) {
    const url = `http://127.0.0.1:${port}`;
    if (await probeHealth(url, PROBE_TIMEOUT_MS)) return url;
  }
  return null;
}

export interface ResolveOptions {
  /** Override the runtime sidecar path. For tests; production uses runtimeFilePath(). */
  sidecarPath?: string;
  /** Override the env var name to read. For tests. */
  envVar?: string;
}

export async function resolveBaseURL(opts: ResolveOptions = {}): Promise<ResolutionResult> {
  const envVarName = opts.envVar ?? ENV_VAR;
  const sidecarPath = opts.sidecarPath ?? runtimeFilePath();

  const envValue = process.env[envVarName];
  if (envValue && envValue.length > 0) {
    return { baseURL: trimTrailingSlash(envValue), source: "env" };
  }

  const fromFile = await readRuntimeFile(sidecarPath);
  if (fromFile) {
    return { baseURL: trimTrailingSlash(fromFile), source: "runtime-file" };
  }

  const fromProbe = await probePortRange();
  if (fromProbe) {
    return { baseURL: fromProbe, source: "port-probe" };
  }

  throw new BaseURLResolutionError(
    [
      "Could not find a running Keywordista server.",
      "",
      "Tried:",
      `  • $${envVarName} env var (not set)`,
      `  • ${sidecarPath} (missing or invalid)`,
      `  • HTTP probe on 127.0.0.1:${PORT_RANGE_START}–${PORT_RANGE_END} (no response)`,
      "",
      "Fix: launch the Keywordista menubar app, run `swift run` in the project, " +
        `or set ${envVarName}=http://your-host:port and retry.`,
    ].join("\n"),
  );
}

function trimTrailingSlash(url: string): string {
  return url.endsWith("/") ? url.slice(0, -1) : url;
}
