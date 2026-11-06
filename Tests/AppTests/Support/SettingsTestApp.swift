@testable import App
import Crypto
import FluentSQLiteDriver
import Vapor
import XCTVapor

/// In-memory app exposing only `SettingsController` under /api/v1 (local
/// mode shape: no auth). `session` lets Apple Ads calls run against a stub.
enum SettingsTestApp {
    static func make(session: AppleAdsSession? = nil) async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.secretBox = SecretBox(key: SymmetricKey(size: .bits256))
        app.migrations.add(CreateSetting())
        // Saving or deleting Apple Ads credentials purges the mirror.
        app.migrations.add(CreateAppleAdsMirror())
        try await app.autoMigrate()
        if let session { app.appleAdsSession = session }
        app.appleAdsSyncCoordinator = AppleAdsSyncCoordinator(logger: app.logger) { IdleSyncService() }
        try app.routes.grouped("api", "v1").register(collection: SettingsController())
        return app
    }
}

/// A sync that never has anything to do; settings tests never start one.
struct IdleSyncService: AppleAdsSyncServiceProtocol {
    func sync(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun {
        throw AppleAdsError.notConnected
    }
}
