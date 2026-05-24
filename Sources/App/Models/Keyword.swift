import Fluent
import Vapor

final class Keyword: Model, Content, @unchecked Sendable {
    static let schema = "keywords"

    @ID(key: .id) var id: UUID?
    @Field(key: "term") var term: String
    @Field(key: "country_code") var countryCode: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    /// Auth attribution (M1.8). See WatchedApp.creator for the
    /// rationale on nullability + ON DELETE SET NULL. NULL =
    /// "pre-auth era" or "creator was deleted later."
    @OptionalParent(key: "creator_user_id") var creator: User?

    init() {}

    init(id: UUID? = nil, term: String, countryCode: String, creatorID: UUID? = nil) {
        self.id = id
        self.term = term
        self.countryCode = countryCode.lowercased()
        self.$creator.id = creatorID
    }
}

struct CreateKeyword: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Keyword.schema)
            .id()
            .field("term", .string, .required)
            .field("country_code", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "term", "country_code")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Keyword.schema).delete()
    }
}

// M1.8 — Auth attribution. See AddCreatorUserIdToWatchedApp for the
// matching design rationale (nullable + SET NULL); same intent here.
// MUST run AFTER CreateUsers (FK target must exist).
struct AddCreatorUserIdToKeyword: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Keyword.schema)
            .field(
                "creator_user_id",
                .uuid,
                .references(User.schema, "id", onDelete: .setNull)
            )
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Keyword.schema)
            .deleteField("creator_user_id")
            .update()
    }
}
