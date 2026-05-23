import Fluent
import Vapor

final class WatchedApp: Model, Content, @unchecked Sendable {
    static let schema = "watched_apps"

    @ID(key: .id) var id: UUID?
    @Field(key: "app_store_id") var appStoreId: Int64
    @Field(key: "bundle_id") var bundleId: String
    @Field(key: "name") var name: String
    @OptionalField(key: "icon_url") var iconURL: String?
    // iTunes "Primary Category" (e.g. 6017 = Education, 6014 = Games).
    // Optional only because the column was added later; AppService fills it
    // on every newly-created row, and ChartTrackerService lazily backfills
    // existing rows by re-running the iTunes lookup on first chart-refresh.
    @OptionalField(key: "primary_genre_id") var primaryGenreId: Int?
    @Timestamp(key: "added_at", on: .create) var addedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        appStoreId: Int64,
        bundleId: String,
        name: String,
        iconURL: String?,
        primaryGenreId: Int? = nil
    ) {
        self.id = id
        self.appStoreId = appStoreId
        self.bundleId = bundleId
        self.name = name
        self.iconURL = iconURL
        self.primaryGenreId = primaryGenreId
    }
}

struct CreateWatchedApp: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .id()
            .field("app_store_id", .int64, .required)
            .field("bundle_id", .string, .required)
            .field("name", .string, .required)
            .field("icon_url", .string)
            .field("added_at", .datetime)
            .unique(on: "app_store_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(WatchedApp.schema).delete()
    }
}

// Added to support chart-tracking: the primary genre drives which top-free
// chart we poll per app. Nullable for migration compatibility — existing
// rows get backfilled on the next iTunes lookup (either /availability/refresh
// or the first chart-refresh cycle).
struct AddPrimaryGenreIdToWatchedApp: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .field("primary_genre_id", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .deleteField("primary_genre_id")
            .update()
    }
}
