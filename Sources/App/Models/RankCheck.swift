import Fluent
import SQLKit
import Vapor

final class RankCheck: Model, Content, @unchecked Sendable {
    static let schema = "rank_checks"

    @ID(key: .id) var id: UUID?
    @Parent(key: "keyword_id") var keyword: Keyword
    @Parent(key: "watched_app_id") var watchedApp: WatchedApp
    @OptionalField(key: "rank") var rank: Int?
    @Field(key: "difficulty") var difficulty: Int
    @Field(key: "entry_barrier") var entryBarrier: Int
    // `checkedAt` is now interpreted as the *most recent* time this exact
    // (rank, difficulty, entryBarrier) tuple was observed. RefreshService
    // bumps this on no-change refreshes instead of inserting a duplicate
    // row, so each RankCheck represents a contiguous run of identical
    // observations rather than a single point in time.
    @Field(key: "checked_at") var checkedAt: Date
    // Optional for migration compatibility: existing rows (created before
    // the dedupe optimization) have NULL here. Treat NULL as "same as
    // checkedAt" when reasoning about state-duration.
    @OptionalField(key: "first_seen_at") var firstSeenAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        keywordID: UUID,
        watchedAppID: UUID,
        rank: Int?,
        difficulty: Int,
        entryBarrier: Int,
        checkedAt: Date,
        firstSeenAt: Date? = nil
    ) {
        self.id = id
        self.$keyword.id = keywordID
        self.$watchedApp.id = watchedAppID
        self.rank = rank
        self.difficulty = difficulty
        self.entryBarrier = entryBarrier
        self.checkedAt = checkedAt
        self.firstSeenAt = firstSeenAt
    }
}

struct CreateRankCheck: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(RankCheck.schema)
            .id()
            .field("keyword_id", .uuid, .required, .references(Keyword.schema, "id", onDelete: .cascade))
            .field("watched_app_id", .uuid, .required, .references(WatchedApp.schema, "id", onDelete: .cascade))
            .field("rank", .int)
            .field("difficulty", .int, .required)
            .field("entry_barrier", .int, .required)
            .field("checked_at", .datetime, .required)
            .create()

        // Composite index for "latest rank per (keyword, app)" lookups.
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS rank_checks_keyword_app_time
                ON rank_checks (keyword_id, watched_app_id, checked_at DESC)
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(RankCheck.schema).delete()
    }
}

// Adds the `first_seen_at` column so RefreshService can dedupe no-change
// refreshes by extending the latest row's checkedAt instead of inserting
// an identical duplicate. Nullable to keep the migration trivial on
// existing data — pre-existing rows simply have NULL here, and code treats
// that as "same as checkedAt" semantically.
struct AddFirstSeenAtToRankCheck: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(RankCheck.schema)
            .field("first_seen_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(RankCheck.schema)
            .deleteField("first_seen_at")
            .update()
    }
}
