import Fluent
import FluentSQLiteDriver
import Foundation
import Queues
import QueuesFluentDriver
import SQLKit
import Vapor

public func configure(_ app: Application) async throws {
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
    let rawPublicDir = Environment.get("KEYWORDISTA_PUBLIC_DIR") ?? app.directory.publicDirectory
    let publicDir = rawPublicDir.hasSuffix("/") ? rawPublicDir : rawPublicDir + "/"

    // Static files (Public/) — serves built SPA assets in production.
    // Runs before routing: any GET that matches a file in Public/ short-circuits.
    app.middleware.use(FileMiddleware(publicDirectory: publicDir))

    // SPA fallback — runs last; converts non-API 404 GETs into index.html so
    // client-side routes (refresh on /dashboard, /settings, etc.) keep working.
    app.middleware.use(SPAFallbackMiddleware(indexPath: publicDir + "index.html"))

    let dbPath = Environment.get("DATABASE_PATH") ?? "db.sqlite"
    app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

    // SQLite tuning. Two changes that together eliminate the "database is
    // locked" storm we hit with parallel jobs:
    //   • WAL journal mode lets a writer and many readers run concurrently
    //     without exclusive locks. The mode change is persistent in the
    //     .db file header — runs once, sticks across restarts.
    //   • busy_timeout asks SQLite to wait up to 5s for a contended lock to
    //     clear instead of immediately returning SQLITE_BUSY. Combined with
    //     serial queue workers (below), this is enough headroom for the
    //     dashboard's reads to never collide with a writer.
    if let sql = app.db as? any SQLDatabase {
        try await sql.raw("PRAGMA journal_mode=WAL").run()
        try await sql.raw("PRAGMA busy_timeout=5000").run()
    }

    app.migrations.add(CreateWatchedApp())
    app.migrations.add(CreateKeyword())
    app.migrations.add(CreateRankCheck())
    app.migrations.add(CreateTopResultSnapshot())
    app.migrations.add(CreateSetting())
    app.migrations.add(JobModelMigrate())
    app.migrations.add(AddFirstSeenAtToRankCheck())

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
