import Fluent
import Vapor

// Records which App Store storefronts a watched app is actually published
// in. Populated by AvailabilityProber after an app is added (and on demand
// via /apps/:id/availability/refresh). ChartTrackerService consults this to
// avoid 175 wasted RSS fetches per cycle when the app only ships in a dozen
// countries.
final class AppStorefrontAvailability: Model, Content, @unchecked Sendable {
    static let schema = "app_storefront_availability"

    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Parent(key: "app_id") var watchedApp: WatchedApp
    @Field(key: "country") var country: String
    @Field(key: "available") var available: Bool
    @Field(key: "checked_at") var checkedAt: Date

    init() {}

    init(
        id: UUID? = nil,
        watchedAppID: UUID,
        country: String,
        available: Bool,
        checkedAt: Date
    ) {
        self.id = id ?? UUID()
        self.$watchedApp.id = watchedAppID
        self.country = country.lowercased()
        self.available = available
        self.checkedAt = checkedAt
    }
}

struct CreateAppStorefrontAvailability: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AppStorefrontAvailability.schema)
            .id()
            .field("app_id", .uuid, .required, .references(WatchedApp.schema, "id", onDelete: .cascade))
            .field("country", .string, .required)
            .field("available", .bool, .required)
            .field("checked_at", .datetime, .required)
            .unique(on: "app_id", "country")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AppStorefrontAvailability.schema).delete()
    }
}
