import Fluent
import Foundation
import Queues
import Vapor

// Daily metadata-snapshot pass. Refreshes the metadata for every tracked
// app across the storefronts the user cares about, deduping into the
// append-only `app_metadata_snapshots` timeline.
//
// Cadence is configured in configure.swift to 03:30 UTC — between
// DailyRefreshScheduler (03:00) and RefreshChartsScheduler (04:00) so
// the three daily jobs don't stack on the same minute. Apple's CDN has
// settled in PT timezones by then.
//
// Why this runs serially (no parallelism, no per-app enqueueing): same
// reason as the existing schedulers. `workerCount = 1` is load-bearing
// (see configure.swift comment), and the polite-~1-req/sec posture to
// iTunes is part of the project's contract with Apple. A handful of
// apps × ~10 storefronts × 2 HTTP calls each (iTunes + HTML scrape)
// completes well under the job's available window.
//
// Storefront strategy:
//   • Own apps → every storefront in AppStorefrontAvailability for that
//     app (the prober has narrowed this down from 175 to 1–10 typical).
//   • Competitor apps → the storefronts where any keyword exists, plus
//     a default storefront (we don't probe 175 per competitor because
//     they don't participate in chart-watching — paying for 175 lookups
//     per competitor per day for no user-visible win would balloon the
//     iTunes rate budget).
struct DailyMetadataSnapshotJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let logger = context.logger
        let service = app.appMetadataSnapshotServiceFactory(context)
        let db = app.db

        let allApps = try await WatchedApp.query(on: db).all()

        // Hoist the keyword-country set ONCE. The previous shape called
        // `Keyword.query.all()` inside `countries(for:)` on every
        // competitor iteration — an N+1 against a table that never
        // changes mid-pass. Hoisting collapses N queries to 1 with no
        // semantic change.
        let keywordCountries = Set(
            try await Keyword.query(on: db).all().map { $0.countryCode.lowercased() }
        )

        var totalSnapshots = 0
        var totalFailures = 0

        for watched in allApps {
            guard let appID = watched.id else { continue }
            let snapshotsService = service
            let countries = try await Self.countries(
                for: watched,
                appID: appID,
                on: db,
                keywordCountries: keywordCountries,
                snapshotsService: snapshotsService
            )
            if countries.isEmpty {
                logger.debug("DailyMetadataSnapshot: app=\(appID) has no storefronts to refresh; skipping")
                continue
            }
            for country in countries {
                do {
                    _ = try await snapshotsService.snapshot(watchedAppID: appID, country: country)
                    totalSnapshots += 1
                } catch {
                    // Fail-soft per (app, country). One bad lookup
                    // shouldn't kill the rest of the cohort — the next
                    // run will retry.
                    totalFailures += 1
                    logger.warning("DailyMetadataSnapshot: app=\(appID) country=\(country) failed: \(error)")
                }
            }
        }

        logger.info(
            "DailyMetadataSnapshot done: apps=\(allApps.count) snapshots=\(totalSnapshots) failures=\(totalFailures)"
        )
    }

    /// Decide which storefronts to refresh for a given app.
    ///
    /// Own apps get the full availability set.
    ///
    /// Competitors get the UNION of:
    ///   • storefronts where any keyword exists (the user's tracked
    ///     coverage)
    ///   • storefronts ALREADY snapshotted for this competitor (so the
    ///     add-time `lookupCountry` keeps getting refreshed even when no
    ///     keyword exists in it — otherwise that snapshot ages forever).
    /// Fallback to "us" when both sets are empty (newly-added competitor
    /// with no keywords anywhere).
    private static func countries(
        for app: WatchedApp,
        appID: UUID,
        on db: any Database,
        keywordCountries: Set<String>,
        snapshotsService: any AppMetadataSnapshotServiceProtocol
    ) async throws -> [String] {
        switch app.typedKind {
        case .own:
            let avail = try await AppStorefrontAvailability.query(on: db)
                .filter(\.$watchedApp.$id == appID)
                .filter(\.$available == true)
                .all()
            // Fallback: if the prober hasn't run yet (newly-added app),
            // snapshot just the default storefront — the next pass will
            // see availability rows and expand.
            if avail.isEmpty { return ["us"] }
            return avail.map { $0.country }

        case .competitor:
            // Already-snapshotted countries — these include whichever
            // `lookupCountry` the user added the competitor with, plus
            // any countries lazy-backfilled by `/compare` after the
            // user explored other storefronts. Keeping them in the
            // refresh set means none of them go stale.
            let existing = try await snapshotsService.latestPerCountry(watchedAppID: appID)
            let snapshotted = Set(existing.keys.map { $0.lowercased() })
            let combined = keywordCountries.union(snapshotted)
            if combined.isEmpty { return ["us"] }
            return Array(combined).sorted()
        }
    }
}
