import Fluent
import Vapor

// Generic key/value settings store. Lets us add new integrations (ASC, ASA,
// future Slack webhooks, etc.) without a migration per integration.
// Keys are namespaced strings like "asc.keyId", "asa.clientSecret".
final class Setting: Model, @unchecked Sendable {
    static let schema = "settings"

    @ID(key: .id) var id: UUID?
    @Field(key: "key") var key: String
    @Field(key: "value") var value: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

struct CreateSetting: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Setting.schema)
            .id()
            .field("key", .string, .required)
            .field("value", .string, .required)
            .field("updated_at", .datetime)
            .unique(on: "key")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Setting.schema).delete()
    }
}
