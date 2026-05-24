# Keywordista server exit codes

When the server binary exits non-zero, the exit code tells you which
broad category of failure occurred. This is the operator's first-line
diagnostic — paired with `docker logs <container>` (or your platform's
equivalent), it should be enough to identify and fix most failures
without filing an issue.

The image's Dockerfile HEALTHCHECK uses curl, which has its own exit-
code convention (notably **22** = "the HTTP code says no"). Those are
documented at the bottom of this page.

---

## Keywordista exit codes

| Code | Meaning                                                            | What to do |
| ---- | ------------------------------------------------------------------ | ---------- |
| **0** | Clean shutdown (SIGTERM / Ctrl-C / orchestrator stop)              | Normal — no action |
| **1** | Unhandled crash (uncaught Swift error, segfault, OOM kill)         | Check `docker logs`. If a crash log mentions a specific subsystem, file an issue with the logs. |
| **2** | A required env var is missing in this mode                         | Log line names the var (e.g. `"KEYWORDISTA_ENCRYPTION_KEY is required in server mode"`). Set the var and restart. |
| **3** | `KEYWORDISTA_ENCRYPTION_KEY` is malformed                          | Must be exactly 64 hex characters (32 bytes). Regenerate: `openssl rand -hex 32`. Setting a new key will make existing encrypted columns in the DB unreadable. |
| **4** | DB connection failed                                               | For SQLite: check `/data` is writable and `DATABASE_PATH` is a valid path. For Postgres: check `DATABASE_URL`'s host/port/credentials are reachable from the container's network. |

Reserved for future use:

| Code | Reserved for                          |
| ---- | ------------------------------------- |
| 5    | (reserved — TBD)                      |
| 6    | (reserved — TBD)                      |
| 64+  | Vapor / NIO internal signal handling  |

---

## What the exit code is NOT

- **It's not a healthcheck failure.** A failing `/health` probe causes
  the orchestrator (Docker, K8s, etc.) to mark the container unhealthy
  but doesn't change the process's exit code. If the binary is up and
  running but `/health` returns 503, that's not in this table — it's
  a runtime issue (the binary is alive but reports degraded), not a
  startup-failure issue.
- **It's not a Vapor route response code.** HTTP status codes from
  endpoints (`401`, `500`, etc.) are separate from process exit codes.

---

## SIGTERM handling

The binary catches `SIGTERM` and:

1. Stops accepting new HTTP connections
2. Waits up to 30s for in-flight requests to finish
3. Lets the current Queues job finish (or aborts after 30s)
4. Flushes the DB
5. Exits with **0**

If 30s isn't enough (slow queue job mid-flight), the orchestrator
typically follows up with `SIGKILL` after its own grace period —
which produces no exit code at all (the process is just terminated).
`docker logs` will show the binary's last activity.

---

## Curl exit codes (for the HEALTHCHECK)

The Dockerfile's `HEALTHCHECK CMD curl -fsS http://127.0.0.1:8080/health
|| exit 1` uses curl. When the healthcheck fails, the container's
HEALTHCHECK status is reported by Docker but the binary itself keeps
running. Common curl exits:

| curl exit | Meaning                                                       |
| --------- | ------------------------------------------------------------- |
| 7         | Couldn't connect — binary is dead or wedged                   |
| 22        | HTTP request failed (`-f` flag treats non-2xx as failure)     |
| 28        | Timeout — `/health` didn't respond within curl's default 5s   |

When you see HEALTHCHECK failures, check the binary's own logs first
to see whether it's running but broken (curl 22) vs. dead (curl 7).

---

## See also

- [`docs/env-vars.md`](../env-vars.md) — env vars these exits reference
- [`docs/architecture/image-contract.md`](image-contract.md) — what the binary promises
- [`docs/deploy/raw-docker.md`](../deploy/raw-docker.md#what-if-it-wont-boot) — operator-side troubleshooting flow
