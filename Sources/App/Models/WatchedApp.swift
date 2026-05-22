import Fluent
import Vapor

final class WatchedApp: Model, Content, @unchecked Sendable {
    static let schema = "watched_apps"

    @ID(key: .id) var id: UUID?
    @Field(key: "app_store_id") var appStoreId: Int64
    @Field(key: "bundle_id") var bundleId: String
    @Field(key: "name") var name: String
    @OptionalField(key: "icon_url") var iconURL: String?
    @Timestamp(key: "added_at", on: .create) var addedAt: Date?

    init() {}

    init(id: UUID? = nil, appStoreId: Int64, bundleId: String, name: String, iconURL: String?) {
        self.id = id
        self.appStoreId = appStoreId
        self.bundleId = bundleId
        self.name = name
        self.iconURL = iconURL
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
