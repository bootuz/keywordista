import Fluent
import Foundation
import Queues
import QueuesFluentDriver
import SQLKit
import Vapor

public func configure(_ app: Application) async throws {
    let manifest = try Manifest.bootstrap()

    app.http.server.configuration.hostname = try manifest.require(EnvVars.hostname)
    app.http.server.configuration.port = try manifest.require(EnvVars.port)

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

    let rawPublicDir = try manifest.optional(EnvVars.publicDir) ?? app.directory.publicDirectory
    let publicDir = rawPublicDir.hasSuffix("/") ? rawPublicDir : rawPublicDir + "/"

    app.middleware.use(FileMiddleware(publicDirectory: publicDir))
    app.middleware.use(SPAFallbackMiddleware(indexPath: publicDir + "index.html"))

    let database = try DatabaseProvider.resolve(from: manifest)
    try database.register(on: app)
    try await database.applyDriverSpecificTuning(on: app)
    app.databaseProvider = database

    let encryptionKey = try EncryptionKeyResolver.resolve(
        mode: manifest.mode,
        explicit: try manifest.optional(EnvVars.encryptionKey)
    )
    let secretBox = SecretBox(key: encryptionKey)
    app.secretBox = secretBox

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
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateAuthSessions())
    app.migrations.add(CreateInvites())
    app.migrations.add(AddCreatorUserIdToWatchedApp())
    app.migrations.add(AddCreatorUserIdToKeyword())
    app.migrations.add(EncryptExistingSecrets(secretBox: secretBox))

    try await app.autoMigrate()

    let bootstrapOutcome = try await AdminBootstrap.run(
        manifest: manifest,
        on: app.db,
        logger: app.logger
    )
    switch bootstrapOutcome {
    case .seeded:
        break
    case .alreadyHasUsers:
        app.logger.info("admin bootstrap skipped: users table not empty")
    case .envVarsNotProvided:
        app.logger.info("""
            admin bootstrap skipped: KEYWORDISTA_ADMIN_EMAIL / \
            KEYWORDISTA_ADMIN_PASSWORD_HASH not set. No admin user \
            will be auto-created — bootstrap one with \
            `keywordista createsuperuser` (e.g. \
            `docker exec -it <container> keywordista createsuperuser`).
            """)
    }

    let purged = try await AuthSession.purgeExpired(on: app.db)
    if purged > 0 {
        app.logger.info("purged \(purged) expired auth session(s) at boot")
    }

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
    app.queues.schedule(RefreshChartsScheduler())
        .daily()
        .at("4:00am")

    app.queues.configuration.workerCount = 1

    try app.queues.startInProcessJobs(on: .default)
    try app.queues.startScheduledJobs()

    try routes(app, manifest: manifest)

    // ── CLI commands ──────────────────────────────────────────────────
    //
    // M3.25: register the Django-style `createsuperuser` subcommand.
    // Vapor's `app.execute()` dispatches on the first argv after the
    // binary name — `keywordista serve` is the default, `keywordista
    // createsuperuser` runs this command. Same configure() runs for
    // both because `app.execute()` is invoked AFTER configure(app),
    // so DB connections + migrations + the manifest are all ready by
    // the time the command's run() body executes.
    //
    // Raw-docker operators invoke this via `docker exec <container>
    // keywordista createsuperuser` after the container is up. See
    // Sources/App/Commands/CreateSuperUserCommand.swift for the
    // full rationale.
    app.asyncCommands.use(
        CreateSuperUserCommand(cost: try manifest.require(EnvVars.bcryptCost)),
        as: "createsuperuser"
    )
}
