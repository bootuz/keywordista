import Fluent
import SQLKit
import Vapor

final class TopResultSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "top_result_snapshots"

    @ID(key: .id) var id: UUID?
    @Parent(key: "keyword_id") var keyword: Keyword
    @Field(key: "checked_at") var checkedAt: Date
    @Field(key: "position") var position: Int
    @Field(key: "app_store_id") var appStoreId: Int64
    @Field(key: "name") var name: String
    @OptionalField(key: "icon_url") var iconURL: String?
    @OptionalField(key: "rating_count") var ratingCount: Int?
    @OptionalField(key: "average_rating") var averageRating: Double?
    @OptionalField(key: "release_date") var releaseDate: Date?

    init() {}

    init(
        id: UUID? = nil,
        keywordID: UUID,
        checkedAt: Date,
        position: Int,
        appStoreId: Int64,
        name: String,
        iconURL: String?,
        ratingCount: Int?,
        averageRating: Double?,
        releaseDate: Date?
    ) {
        self.id = id
        self.$keyword.id = keywordID
        self.checkedAt = checkedAt
        self.position = position
        self.appStoreId = appStoreId
        self.name = name
        self.iconURL = iconURL
        self.ratingCount = ratingCount
        self.averageRating = averageRating
        self.releaseDate = releaseDate
    }
}

struct CreateTopResultSnapshot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(TopResultSnapshot.schema)
            .id()
            .field("keyword_id", .uuid, .required, .references(Keyword.schema, "id", onDelete: .cascade))
            .field("checked_at", .datetime, .required)
            .field("position", .int, .required)
            .field("app_store_id", .int64, .required)
            .field("name", .string, .required)
            .field("icon_url", .string)
            .field("rating_count", .int)
            .field("average_rating", .double)
            .field("release_date", .datetime)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS top_results_keyword_time
                ON top_result_snapshots (keyword_id, checked_at DESC)
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(TopResultSnapshot.schema).delete()
    }
}
