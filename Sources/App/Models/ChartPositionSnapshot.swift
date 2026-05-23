import Fluent
import Vapor

// Last-known position for a watched app on a single (country, chart, genre)
// chart. NULL position means "polled this cycle but the app wasn't in the
// top-100" — kept as a tombstone so the diff algorithm can distinguish
// "still not charted" (no event) from "just exited" (emit `exited`).
final class ChartPositionSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "chart_position_snapshot"

    @ID(custom: .id, generatedBy: .user) var id: UUID?
    @Parent(key: "app_id") var watchedApp: WatchedApp
    @Field(key: "country") var country: String
    @Field(key: "chart_type") var chartType: String
    @Field(key: "genre_id") var genreId: Int
    @OptionalField(key: "position") var position: Int?
    @Field(key: "observed_at") var observedAt: Date

    init() {}

    init(
        id: UUID? = nil,
        watchedAppID: UUID,
        country: String,
        chartType: String,
        genreId: Int,
        position: Int?,
        observedAt: Date
    ) {
        self.id = id ?? UUID()
        self.$watchedApp.id = watchedAppID
        self.country = country.lowercased()
        self.chartType = chartType
        self.genreId = genreId
        self.position = position
        self.observedAt = observedAt
    }
}

struct CreateChartPositionSnapshot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ChartPositionSnapshot.schema)
            .id()
            .field("app_id", .uuid, .required, .references(WatchedApp.schema, "id", onDelete: .cascade))
            .field("country", .string, .required)
            .field("chart_type", .string, .required)
            .field("genre_id", .int, .required)
            .field("position", .int)
            .field("observed_at", .datetime, .required)
            .unique(on: "app_id", "country", "chart_type", "genre_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ChartPositionSnapshot.schema).delete()
    }
}
