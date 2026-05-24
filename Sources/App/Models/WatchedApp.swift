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

    /// Auth attribution (M1.8): the user who added this app. Nullable
    /// because (a) pre-auth rows have no creator (= "system / pre-auth
    /// era"), and (b) local mode never has users so the column stays
    /// NULL there. FK ON DELETE SET NULL preserves the WatchedApp row
    /// when its creator is later deleted — losing audit fidelity, not
    /// losing the user's data.
    @OptionalParent(key: "creator_user_id") var creator: User?

    init() {}

    init(
        id: UUID? = nil,
        appStoreId: Int64,
        bundleId: String,
        name: String,
        iconURL: String?,
        primaryGenreId: Int? = nil,
        creatorID: UUID? = nil
    ) {
        self.id = id
        self.appStoreId = appStoreId
        self.bundleId = bundleId
        self.name = name
        self.iconURL = iconURL
        self.primaryGenreId = primaryGenreId
        self.$creator.id = creatorID
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

// M1.8 — Auth attribution. Nullable + FK ON DELETE SET NULL so:
//   • Existing pre-auth rows migrate to NULL ("system" / pre-auth era).
//   • Deleting the creating user later preserves the WatchedApp row
//     (the team still wants to track the app) but loses the audit
//     pointer. The Invite model uses the same SET NULL semantics for
//     consumed_by — same intent, same cascade.
//
// MUST run AFTER CreateUsers (FK target must exist); configure.swift
// registers in that order.
struct AddCreatorUserIdToWatchedApp: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .field(
                "creator_user_id",
                .uuid,
                .references(User.schema, "id", onDelete: .setNull)
            )
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .deleteField("creator_user_id")
            .update()
    }
}
