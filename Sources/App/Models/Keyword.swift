import Fluent
import Vapor

final class Keyword: Model, Content, @unchecked Sendable {
    static let schema = "keywords"

    @ID(key: .id) var id: UUID?
    @Field(key: "term") var term: String
    @Field(key: "country_code") var countryCode: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, term: String, countryCode: String) {
        self.id = id
        self.term = term
        self.countryCode = countryCode.lowercased()
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
