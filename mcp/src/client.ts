/**
 * Thin typed fetch wrapper for the Vapor server's /api/v1 surface.
 *
 * Design notes:
 *  - Lazy base-URL resolution: the URL is resolved once on first use and
 *    cached for the process lifetime. The menubar app picks a port on its
 *    boot, not on each request, so re-resolving per call would just slow
 *    us down. If the server moves ports mid-session the user will see
 *    network errors and restart the MCP server — acceptable for a tool
 *    that runs alongside its server.
 *  - Errors are translated, not raw. The Vapor server uses simple HTTP
 *    status mapping (400 for validation, 404 for not-found, 5xx for
 *    bugs/timeouts). We surface those as KeywordistaApiError with the
 *    response body and a status-specific actionable hint, so the agent
 *    can recover or relay clearly without parsing a stack trace.
 *  - Response is `unknown` and validated by zod at the call site. That
 *    keeps the client dumb and the schemas the single source of truth.
 */
import { resolveBaseURL, type ResolutionResult } from "./runtime.js";

const API_PREFIX = "/api/v1";

export class KeywordistaApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
    public readonly url: string,
    hint?: string,
  ) {
    const summary = `${status} ${statusText} from ${url}`;
    const trimmedBody = body.trim().slice(0, 500);
    const parts = [summary];
    if (trimmedBody.length > 0) parts.push(`Body: ${trimmedBody}`);
    if (hint) parts.push(`Hint: ${hint}`);
    super(parts.join(" — "));
    this.name = "KeywordistaApiError";
  }
}

export interface ApiClient {
  /** The resolved base URL + how it was discovered. Useful for diagnostics. */
  resolution(): Promise<ResolutionResult>;
  /** GET /api/v1{path}. Caller validates the returned JSON with a zod schema. */
  get<T = unknown>(path: string, query?: Record<string, string | number | undefined>): Promise<T>;
  /** POST /api/v1{path} with optional JSON body. */
  post<T = unknown>(path: string, body?: unknown): Promise<T>;
  /** DELETE /api/v1{path}. Returns nothing on 204. */
  del(path: string): Promise<void>;
}

export function createApiClient(): ApiClient {
  let cached: ResolutionResult | null = null;

  async function ensureBase(): Promise<ResolutionResult> {
    if (cached) return cached;
    cached = await resolveBaseURL();
    return cached;
  }

  function buildURL(base: string, path: string, query?: Record<string, string | number | undefined>): string {
    const url = new URL(`${API_PREFIX}${path}`, base);
    if (query) {
      for (const [k, v] of Object.entries(query)) {
        if (v !== undefined && v !== null && `${v}`.length > 0) url.searchParams.set(k, String(v));
      }
    }
    return url.toString();
  }

  async function request(method: string, path: string, init: RequestInit, query?: Record<string, string | number | undefined>): Promise<Response> {
    const { baseURL } = await ensureBase();
    const url = buildURL(baseURL, path, query);
    const res = await fetch(url, { ...init, method });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new KeywordistaApiError(res.status, res.statusText, body, url, hintForStatus(res.status, method, path));
    }
    return res;
  }

  return {
    resolution: ensureBase,

    async get<T = unknown>(path: string, query?: Record<string, string | number | undefined>): Promise<T> {
      const res = await request("GET", path, { headers: { Accept: "application/json" } }, query);
      return (await res.json()) as T;
    },

    async post<T = unknown>(path: string, body?: unknown): Promise<T> {
      const init: RequestInit = {
        headers: {
          Accept: "application/json",
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      };
      const res = await request("POST", path, init);
      // 202 Accepted endpoints (refresh) return a small JSON body; 204 No Content
      // is theoretically possible. Handle both.
      if (res.status === 204) return undefined as T;
      const text = await res.text();
      if (text.length === 0) return undefined as T;
      return JSON.parse(text) as T;
    },

    async del(path: string): Promise<void> {
      await request("DELETE", path, {});
    },
  };
}

/**
 * Status-specific hint to make error messages actionable for the agent
 * without forcing the caller to handle each status separately.
 */
function hintForStatus(status: number, method: string, path: string): string | undefined {
  if (status === 404) {
    if (path.startsWith("/keywords/")) return "Keyword id not found. Call `list_keywords` to see valid ids.";
    if (path.startsWith("/apps/")) return "App id not found. Call `list_apps` to see valid ids.";
    return "Resource not found.";
  }
  if (status === 400) {
    return "Validation failed — check the field constraints (country codes are 2 letters, terms are non-empty).";
  }
  if (status === 401 || status === 403) {
    return "Server returned an auth error. The local-mode server should not require auth; check $KEYWORDISTA_BASE_URL points at the right instance.";
  }
  if (status >= 500) {
    return `Server-side ${method} ${path} failed. Check the menubar log at ~/Library/Logs/Keywordista/service.stderr.log.`;
  }
  return undefined;
}
