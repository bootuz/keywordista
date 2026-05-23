import Fluent
import SQLKit
import Vapor

// Append-only audit log of chart transitions. Drives both the activity feed
// rendered on /charts and the polling loop that fires browser notifications.
// One row per detected change — entered (not charted → #N), moved (#M → #N),
// exited (#M → not charted). Stable transitions and "still not charted" both
// produce no row.
final class ChartEvent: Model, Content, @unchecked Sendable {
    static let schema = "chart_event"

    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Parent(key: "app_id") var watchedApp: WatchedApp
    @Field(key: "country") var country: String
    @Field(key: "chart_type") var chartType: String
    @Field(key: "genre_id") var genreId: Int
    @Field(key: "kind") var kind: String              // entered | moved | exited
    @OptionalField(key: "position") var position: Int?
    @OptionalField(key: "prev_position") var prevPosition: Int?
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(
        id: UUID? = nil,
        watchedAppID: UUID,
        country: String,
        chartType: String,
        genreId: Int,
        kind: Kind,
        position: Int?,
        prevPosition: Int?,
        createdAt: Date
    ) {
        self.id = id ?? UUID()
        self.$watchedApp.id = watchedAppID
        self.country = country.lowercased()
        self.chartType = chartType
        self.genreId = genreId
        self.kind = kind.rawValue
        self.position = position
        self.prevPosition = prevPosition
        self.createdAt = createdAt
    }

    enum Kind: String, Sendable {
        case entered, moved, exited
    }
}

struct CreateChartEvent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ChartEvent.schema)
            .id()
            .field("app_id", .uuid, .required, .references(WatchedApp.schema, "id", onDelete: .cascade))
            .field("country", .string, .required)
            .field("chart_type", .string, .required)
            .field("genre_id", .int, .required)
            .field("kind", .string, .required)
            .field("position", .int)
            .field("prev_position", .int)
            .field("created_at", .datetime, .required)
            .create()

        // Activity feed and the SPA polling loop both want newest-first by
        // created_at. The composite (app_id, created_at DESC) covers both
        // "events globally, newest first" (the polling query) and
        // "events for this app, newest first" (the per-app history view).
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS chart_event_app_time
                ON chart_event (app_id, created_at DESC)
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(ChartEvent.schema).delete()
    }
}
