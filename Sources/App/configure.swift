import Fluent
import Foundation
import Queues
import QueuesFluentDriver
import SQLKit
import Vapor

public func configure(_ app: Application) async throws {
    // ── Env-var contract ──────────────────────────────────────────────
    //
    // Resolve and validate the §4.6.3 env-var contract once at boot,
    // BEFORE any other init. Missing-required-var failures surface here
    // with a clear "KEYWORDISTA_X is required in server mode" message —
    // far less confusing than discovering halfway through migration
    // setup that ENCRYPTION_KEY is missing. See Sources/App/Config/
    // EnvVarManifest.swift for the typed accessors.
    let manifest = try Manifest.bootstrap()

    // ── Default bind address & port ───────────────────────────────────
    //
    // Server mode → 0.0.0.0 (public PaaS deploy: container needs to
    // accept connections from the provider's load balancer);
    // local mode → 127.0.0.1 (Mac menubar spawn: only the local
    // browser talks to it).
    //
    // The menubar app's ServiceSupervisor still passes the explicit
    // `--hostname 127.0.0.1 --port <chosen>` CLI flags. Vapor's CLI
    // flags override these defaults if both are set, so behavior for
    // the existing menubar path is unchanged.
    app.http.server.configuration.hostname = try manifest.require(EnvVars.hostname)
    app.http.server.configuration.port = try manifest.require(EnvVars.port)

    // ── JSON date precision ────────────────────────────────────────────
    //
    // Vapor's default .iso8601 strategy emits dates with whole-second
    // precision ("2026-05-21T23:21:53Z"). The SPA captures a ms-precision
    // `startedAt` at click time and waits for the row's `checkedAt` to
    // catch up; if the parsed-back `checkedAt` truncates to the same
    // wall-clock second, the comparison never succeeds and the refresh
    // spinner spins forever. Switch the whole JSON layer to fractional-
    // seconds ISO 8601 so the round-trip preserves the precision SQLite
    // already stores. See web/src/lib/stores.ts reconcile() for the other
    // side of this contract.
    //
    // Formatters are constructed inside each closure because
    // ISO8601DateFormatter isn't Sendable; the allocation cost is trivial
    // compared to JSON encoding itself.
    let jsonEncoder = JSONEncoder()
    jsonEncoder.dateEncodingStrategy = .custom { date, encoder in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var container = encoder.singleValueContainer()
        try container.encode(formatter.string(from: date))
    }

    let jsonDecoder = JSONDecoder()
    jsonDecoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        let primary = ISO8601DateFormatter()
        primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = primary.date(from: str) { return date }
        // Belt-and-suspenders: accept the legacy second-precision form so
        // an old curl one-liner in the README still posts dates cleanly.
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withInternetDateTime]
        if let date = legacy.date(from: str) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected ISO 8601 date, got \(str)"
        )
    }

    ContentConfiguration.global.use(encoder: jsonEncoder, for: .json)
    ContentConfiguration.global.use(decoder: jsonDecoder, for: .json)

    // Public directory: the menubar app supervisor sets KEYWORDISTA_PUBLIC_DIR
    // to point at the bundled (or downloaded) SPA assets in its data dir.
    // When unset (dev / source builds), fall back to Vapor's convention.
    // FileMiddleware wants a trailing slash; tolerate either form from the
    // env var.
    let rawPublicDir = try manifest.optional(EnvVars.publicDir) ?? app.directory.publicDirectory
    let publicDir = rawPublicDir.hasSuffix("/") ? rawPublicDir : rawPublicDir + "/"

    // Static files (Public/) — serves built SPA assets in production.
    // Runs before routing: any GET that matches a file in Public/ short-circuits.
    app.middleware.use(FileMiddleware(publicDirectory: publicDir))

    // SPA fallback — runs last; converts non-API 404 GETs into index.html so
    // client-side routes (refresh on /dashboard, /settings, etc.) keep working.
    app.middleware.use(SPAFallbackMiddleware(indexPath: publicDir + "index.html"))

    // Database driver. Routes per §4.10: DATABASE_URL → Postgres,
    // otherwise SQLite at DATABASE_PATH. Local mode (menubar-spawned)
    // always resolves to SQLite. Driver-specific tuning (SQLite PRAGMAs)
    // is encapsulated in DatabaseProvider and a no-op for Postgres.
    let database = try DatabaseProvider.resolve(from: manifest)
    try database.register(on: app)
    try await database.applyDriverSpecificTuning(on: app)

    app.migrations.add(CreateWatchedApp())
    app.migrations.add(CreateKeyword())
    app.migrations.add(CreateRankCheck())
    app.migrations.add(CreateTopResultSnapshot())
    app.migrations.add(CreateSetting())
    app.migrations.add(JobModelMigrate())
    app.migrations.add(AddFirstSeenAtToRankCheck())
    app.migrations.add(AddPrimaryGenreIdToWatchedApp())
    app.migrations.add(CreateAppStorefrontAvailability())
    app.migrations.add(CreateChartPositionSnapshot())
    app.migrations.add(CreateChartEvent())
    // M1 — auth + multi-user tables. Safe to register in both modes:
    // local-mode boots will create the tables but never insert into
    // them (auth middleware is server-only). Keeps the migration set
    // identical across local + server so a `local` install can be
    // upgraded to `server` later without manual SQL.
    app.migrations.add(CreateUsers())

    try await app.autoMigrate()

    // Orphan-job sweeper: any job left in 'processing' state at boot is
    // by definition stranded — the worker that picked it up is gone
    // (crash, kill -9, sudden shutdown). Mark them completed so the
    // queue's pending count can drop to 0 and the SPA's refresh chip
    // clears via its queue-empty safety net. Without this, a single
    // stranded job permanently wedges the chip until manual DB surgery.
    if let sql = app.db as? any SQLDatabase {
        try await sql.raw("""
        UPDATE _jobs SET state = 'completed'
         WHERE state = 'processing'
        """).run()
    }

    app.queues.use(.fluent())
    app.queues.add(RefreshKeywordJob())
    app.queues.schedule(DailyRefreshScheduler())
        .daily()
        .at("3:00am")
    // Chart-position watchdog. Lands one hour after the keyword refresh so
    // it doesn't pile on top of iTunes simultaneously, and 4 hours after
    // Apple's midnight-PT chart refresh window so the RSS feeds are settled.
    app.queues.schedule(RefreshChartsScheduler())
        .daily()
        .at("4:00am")

    // Serial worker. The original plan called for "~1 req/sec to iTunes"
    // to stay below Apple's edge throttling; running multiple workers in
    // parallel both flooded iTunes (yielding 504 timeouts) AND fought each
    // other for SQLite write locks (yielding "database is locked" errors).
    // workerCount=1 = at-most-one RefreshKeywordJob in flight at a time;
    // the FluentDriver's poll interval (default 1s) gives the polite pacing
    // for free.
    app.queues.configuration.workerCount = 1

    try app.queues.startInProcessJobs(on: .default)
    try app.queues.startScheduledJobs()

    try routes(app)
}
