@testable import App
import Crypto
import Fluent
import FluentSQLiteDriver
import Logging
import Testing
import Vapor
import XCTVapor

/// In-memory app with Settings + Apple Ads controllers, the mirror tables,
/// and a sync coordinator whose Apple reads come from `client`.
/// `routes` decides where AppleAdsController mounts (bare, as in local mode,
/// or a caller-built authenticated group for server-mode tests).
enum AppleAdsTestApp {
    static func make(
        client: ScriptedReportingClient,
        configureRoutes: ((Application) throws -> Void)? = nil,
        base: Application? = nil
    ) async throws -> Application {
        let app: Application
        if let base {
            app = base
        } else {
            app = try await Application.make(.testing)
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.secretBox = SecretBox(key: SymmetricKey(size: .bits256))
            // The creator columns reference users; AuthTestApp bases add it already.
            app.migrations.add(CreateUsers())
        }
        app.migrations.add(CreateSetting())
        app.migrations.add(CreateWatchedApp())
        app.migrations.add(CreateKeyword())
        app.migrations.add(AddPrimaryGenreIdToWatchedApp())
        app.migrations.add(AddCreatorUserIdToWatchedApp())
        app.migrations.add(AddCreatorUserIdToKeyword())
        app.migrations.add(AddKindToWatchedApp())
        app.migrations.add(CreateAppleAdsMirror())
        try await app.autoMigrate()

        app.appleAdsSession = AppleAdsSession(logger: Logger(label: "t")) { _ in
            throw AppleAdsError.unreachable("no live Apple Ads client in tests")
        }
        let db = app.db
        let secretBox = app.requireSecretBox()
        app.appleAdsSyncCoordinator = AppleAdsSyncCoordinator(logger: Logger(label: "t")) {
            AppleAdsSyncService(
                settings: SettingsService(repository: FluentSettingsRepository(db: db), secretBox: secretBox),
                repository: FluentAppleAdsDataRepository(db: db),
                watchedApps: FluentWatchedAppRepository(db: db),
                keywords: FluentKeywordRepository(db: db),
                makeClient: { _ in client },
                today: { "2026-11-06" },
                logger: Logger(label: "t")
            )
        }
        if let configureRoutes {
            try configureRoutes(app)
        } else {
            let api = app.routes.grouped("api", "v1")
            try api.register(collection: SettingsController())
            try api.register(collection: AppleAdsController())
        }
        return app
    }

    /// Polls until the coordinator is idle (bounded, so a hang fails fast).
    static func waitForIdle(_ app: Application) async throws {
        for _ in 0..<500 {
            if await !app.appleAdsSyncCoordinator.isRunning { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("sync never finished")
    }

    static func connect(_ app: Application, clientId: String = "c") async throws {
        try await app.test(.PUT, "api/v1/settings/asa", beforeRequest: { req in
            try req.content.encode(["clientId": clientId, "clientSecret": "s", "adAccountId": "42"])
        }, afterResponse: { res async in #expect(res.status == .ok) })
    }

    static func mirrorRowCount(_ app: Application) async throws -> Int {
        try await AppleAdsCampaignRow.query(on: app.db).count()
            + AppleAdsCampaignDayRow.query(on: app.db).count()
            + AppleAdsSyncRunRow.query(on: app.db).count()
    }
}
