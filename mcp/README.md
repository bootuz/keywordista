# Keywordista MCP server

Stdio Model Context Protocol server that lets Claude (Desktop, Code, or any
MCP client) read and manage your Keywordista tracking data through a small
set of workflow-shaped tools.

It runs alongside an existing Keywordista server — either the macOS menubar
app or a `swift run` instance — and talks to it over `http://127.0.0.1:<port>`.

## Tools

| Tool | What it does |
| --- | --- |
| `list_apps` | All tracked apps with their App Store metadata. |
| `list_keywords` | All tracked keywords (term + country). |
| `keyword_history` | Rank-check timeline for one keyword (optionally one app). |
| `dashboard` | Current rank rollup — every (keyword × app). Filterable by country. |
| `chart_movements` | Current chart positions + recent entered/moved/exited events. |
| `add_app` | Track a new app by iTunes track ID. |
| `add_keyword` | Track a new keyword in a country. Auto-queues a first refresh. |
| `remove_app` | Stop tracking an app (requires `confirm: true`). |
| `remove_keyword` | Stop tracking a keyword (requires `confirm: true`). |
| `refresh` | Trigger a refresh (keyword / all / charts / availability) and wait for it. |

## Install

```bash
cd mcp
npm install
npm run build
```

This produces `dist/index.js` — the stdio entrypoint Claude clients launch.

## Connect Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "keywordista": {
      "command": "node",
      "args": ["/absolute/path/to/keywordista/mcp/dist/index.js"]
    }
  }
}
```

Restart Claude Desktop. The 10 tools will appear under "Keywordista".

## Connect Claude Code

```bash
claude mcp add keywordista node /absolute/path/to/keywordista/mcp/dist/index.js
```

## How it finds your server

The MCP server resolves the Keywordista base URL on first call, in this order:

1. **`KEYWORDISTA_BASE_URL` env var** — escape hatch for Docker or custom hosts.
2. **`~/Library/Application Support/Keywordista/runtime.json`** — written by the menubar app on boot. Contains `{baseURL, pid, writtenAt}`.
3. **Sequential `/health` probe on 127.0.0.1:8080–8090** — last-resort fallback for `swift run` setups or when the sidecar is stale.

If all three fail, the first tool call returns a clear "Keywordista server not running" error rather than a network stack trace.

## Develop

```bash
npm run watch        # tsc --watch
npm test             # vitest (runtime resolution + refresh polling)
npm run inspector    # launch MCP Inspector against dist/index.js
```

From the repo root:

```bash
make mcp-install     # npm install in mcp/
make mcp-build       # tsc
make mcp-check       # tests
make mcp-inspector   # open the inspector
```

## Notes on the async refresh

The Vapor queue is intentionally single-threaded (~1 req/sec to iTunes), so
`refresh kind:"all"` over many keywords can easily exceed the default 60s
timeout. When that happens the tool returns `drained: false` with a `note`
explaining the work continues server-side — re-invoke with a larger
`timeoutMs` or check the dashboard later.
