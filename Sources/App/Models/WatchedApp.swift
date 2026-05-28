import Fluent
import SQLKit
import Vapor

/// Distinguishes apps the user actively tracks for ranks/charts (`own`)
/// from competitor apps tracked only for metadata snapshotting
/// (`competitor`). The flag is load-bearing: `RefreshService` and
/// `ChartTrackerService` filter on `typedKind == .own` so competitors
/// never enter the iTunes-rate-budget refresh pipeline.
///
/// Keywords themselves are GLOBAL — `KeywordService.create` takes only
/// `(term, countryCode)` and is not per-app, so no kind-based guard
/// lives there. Competitors are excluded from the rank pipeline purely
/// via the `RefreshService` filter; if you ever introduce per-app
/// keywords, add the matching guard at the keyword create site.
enum WatchedAppKind: String, Codable, Sendable {
    case own
    case competitor
}

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
    // `kind` is stored as `String` (the raw rawValue) because Fluent's
    // SQLite driver doesn't support typed enum columns uniformly across
    // both SQLite + Postgres. This matches `ChartEvent.kind`. The model
    // exposes a typed accessor below for ergonomic call-site usage.
    // OptionalField because the migration adds the column nullable +
    // backfills 'own', and pre-migration tests/in-memory rows that omit
    // the kind shouldn't blow up — the typed accessor coerces NULL to
    // `.own`, which is the conservative default.
    //
    // Property name `kind` (not `kindRaw`) so Vapor's auto-synthesized
    // Codable serialization emits the field as `kind` over the wire —
    // matching the SPA's `WatchedApp.kind: 'own' | 'competitor'` type.
    // The typed accessor lives under `typedKind` to avoid the
    // property-name collision.
    @OptionalField(key: "kind") var kind: String?
    @Timestamp(key: "added_at", on: .create) var addedAt: Date?

    /// Auth attribution (M1.8): the user who added this app. Nullable
    /// because (a) pre-auth rows have no creator (= "system / pre-auth
    /// era"), and (b) local mode never has users so the column stays
    /// NULL there. FK ON DELETE SET NULL preserves the WatchedApp row
    /// when its creator is later deleted — losing audit fidelity, not
    /// losing the user's data.
    @OptionalParent(key: "creator_user_id") var creator: User?

    /// Typed accessor over the stored `kind` String. Unknown values
    /// (e.g. a future enum case rolled back to an older binary) fall
    /// back to `.own` so the app keeps being treated as the user's —
    /// the conservative choice since the wrong direction (competitor →
    /// own) at worst surfaces an app on the dashboard that shouldn't
    /// be there, while the opposite (own → competitor) would silently
    /// stop refreshing it.
    ///
    /// Named `typedKind` so it doesn't collide with the @OptionalField
    /// `kind` storage property; call sites read `app.typedKind` for the
    /// strongly-typed enum value.
    var typedKind: WatchedAppKind {
        get { kind.flatMap(WatchedAppKind.init(rawValue:)) ?? .own }
        set { kind = newValue.rawValue }
    }

    init() {}

    init(
        id: UUID? = nil,
        appStoreId: Int64,
        bundleId: String,
        name: String,
        iconURL: String?,
        primaryGenreId: Int? = nil,
        kind: WatchedAppKind = .own,
        creatorID: UUID? = nil
    ) {
        self.id = id
        self.appStoreId = appStoreId
        self.bundleId = bundleId
        self.name = name
        self.iconURL = iconURL
        self.primaryGenreId = primaryGenreId
        self.kind = kind.rawValue
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

// Competitor-analysis (v2): a per-row classifier so the dashboard's
// keyword-rank machinery can keep ignoring competitors while a sibling
// metadata-snapshot pipeline scoops them up. Default 'own' backfills
// every pre-existing row to the conservative interpretation — they were
// added before competitor tracking existed, so they're the user's apps.
//
// The column is NULLABLE on the schema side (deliberately — see
// `prepare()`). NULL-safety at read time comes from `WatchedApp.typedKind`'s
// `?? .own` coercion plus the backfill UPDATE that runs in this same
// migration. A partially-applied migration is therefore safe: pre-backfill
// rows read as `.own` via the coercion, and no code path is required
// to handle NULL explicitly.
struct AddKindToWatchedApp: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .field("kind", .string)        // nullable; backfilled below
            .update()
        // Backfill in a single statement. Single-user / single-machine →
        // no row-count concerns, and the typed accessor's `?? .own`
        // fallback means a partially-applied migration is still safe.
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            UPDATE watched_apps SET kind = 'own' WHERE kind IS NULL
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(WatchedApp.schema)
            .deleteField("kind")
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
