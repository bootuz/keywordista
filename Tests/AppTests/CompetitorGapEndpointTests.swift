@testable import App
import Fluent
import FluentSQLiteDriver
import Foundation
import Vapor
import XCTVapor
import Testing

// Integration test for the gap endpoint. Boots a minimal local-mode app
// (no auth) with just the migrations the route touches, seeds a tiny
// matrix, and hits the real HTTP surface — proving the route is wired and
// the JSON contract holds. The gap math itself is unit-tested in
// CompetitorGapServiceTests / CompetitorGapClassifierTests.
@Suite("Competitor gap endpoint")
struct CompetitorGapEndpointTests {

    private static func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.databaseProvider = .sqlite(path: ":memory:")
        // Canonical order (mirrors configure.swift). Users first because
        // the creator_user_id columns FK into it; base tables before the
        // alterations that add columns the models read/write.
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateWatchedApp())
        app.migrations.add(CreateKeyword())
        app.migrations.add(CreateRankCheck())
        app.migrations.add(AddFirstSeenAtToRankCheck())
        app.migrations.add(AddPrimaryGenreIdToWatchedApp())
        app.migrations.add(AddCreatorUserIdToWatchedApp())
        app.migrations.add(AddCreatorUserIdToKeyword())
        app.migrations.add(AddKindToWatchedApp())
        try await app.autoMigrate()
        try app.grouped("api", "v1").register(collection: DashboardController())
        return app
    }

    @Test("GET /apps/:id/gaps returns the competitor matrix for that own app")
    func gapsEndpoint() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }

        let ownID = UUID()
        let compID = UUID()
        let kwID = UUID()
        let now = Date()

        try await WatchedApp(id: ownID, appStoreId: 1, bundleId: "com.mine", name: "Mine", iconURL: nil, kind: .own).create(on: app.db)
        try await WatchedApp(id: compID, appStoreId: 2, bundleId: "com.rival", name: "Rival", iconURL: nil, kind: .competitor).create(on: app.db)
        try await Keyword(id: kwID, term: "flashcards", countryCode: "us").create(on: app.db)
        // me #7, rival #3 → I'm behind
        try await RankCheck(keywordID: kwID, watchedAppID: ownID, rank: 7, difficulty: 0, entryBarrier: 0, checkedAt: now, firstSeenAt: now).create(on: app.db)
        try await RankCheck(keywordID: kwID, watchedAppID: compID, rank: 3, difficulty: 0, entryBarrier: 0, checkedAt: now, firstSeenAt: now).create(on: app.db)

        try await app.test(.GET, "/api/v1/apps/\(ownID)/gaps", afterResponse: { res async in
            #expect(res.status == .ok)
            let rows = try? res.content.decode([CompetitorGapRow].self)
            #expect(rows?.count == 1)
            let row = rows?.first
            #expect(row?.competitorAppId == compID)
            #expect(row?.myRank == 7)
            #expect(row?.competitorRank == 3)
            #expect(row?.verdict.kind == .behind)
        })
    }
}
