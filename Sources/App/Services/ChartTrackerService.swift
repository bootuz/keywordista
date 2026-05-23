import Fluent
import Foundation
import Vapor

// One refresh pass of the chart-position watchdog. For each watched app,
// for each country where the app is available, fetch the top-free chart in
// the app's primary genre and diff the result against the stored snapshot.
// Emits ChartEvent rows for entered / moved / exited transitions; no event
// for stable-charted or still-not-charted.
//
// Called from RefreshChartsJob on a daily Queues schedule and from
// POST /api/v1/charts/refresh.

protocol ChartTrackerServiceProtocol: Sendable {
    func refreshAll(now: Date) async throws -> ChartRefreshSummary
}

struct ChartRefreshSummary: Sendable, Equatable {
    let appsProcessed: Int
    let chartsFetched: Int
    let eventsEmitted: Int
}

// What the diff algorithm decided for a single (app, country) result.
// Extracted from ChartTrackerService so it can be unit-tested without a DB.
enum ChartTransition: Sendable, Equatable {
    case entered(position: Int)
    case moved(from: Int, to: Int)
    case exited(from: Int)
    case stableCharted(at: Int)       // unchanged position; bump observed_at only
    case stableTombstone              // had a tombstone row, still not charted; bump observed_at
    case noop                         // never had a snapshot row and still not charted; write nothing

    var shouldWriteSnapshot: Bool {
        if case .noop = self { return false }
        return true
    }

    var eventKind: ChartEvent.Kind? {
        switch self {
        case .entered: return .entered
        case .moved:   return .moved
        case .exited:  return .exited
        case .stableCharted, .stableTombstone, .noop: return nil
        }
    }
}

// Pure-function form of the watchdog's diff logic. Given the previous
// snapshot state and the position observed in the just-fetched chart,
// decide what transition happened. No DB, no I/O — easy to unit test.
func decideChartTransition(prev: Int?, new: Int?, hasPriorRow: Bool) -> ChartTransition {
    switch (prev, new) {
    case (nil, nil):
        return hasPriorRow ? .stableTombstone : .noop
    case (nil, .some(let n)):
        return .entered(position: n)
    case (.some(let p), nil):
        return .exited(from: p)
    case let (.some(p), .some(n)) where p != n:
        return .moved(from: p, to: n)
    case (.some(let p), .some):
        return .stableCharted(at: p)
    }
}

struct ChartTrackerService: ChartTrackerServiceProtocol {
    let db: any Database
    let chartsClient: any ITunesChartsClientProtocol
    let lookupClient: any ITunesLookupClientProtocol
    let logger: Logger
    // Max concurrent country-level fetches per app. Plays nice with iTunes
    // while still finishing a ~30-country sweep in seconds.
    var countryConcurrency: Int = 4
    // Only the top-free chart is watched in MVP. Hard-coded here rather than
    // a column on the snapshot so adding top-paid/top-grossing later is just
    // a loop expansion.
    var chartType: String = "top-free"

    @discardableResult
    func refreshAll(now: Date) async throws -> ChartRefreshSummary {
        let apps = try await WatchedApp.query(on: db).all()
        var totalCharts = 0
        var totalEvents = 0

        for app in apps {
            guard let appID = app.id else { continue }
            // Backfill primary_genre_id for legacy rows by re-running the
            // iTunes lookup. One-off cost; subsequent passes use the cached
            // value.
            let genreId: Int
            if let cached = app.primaryGenreId {
                genreId = cached
            } else {
                do {
                    let info = try await lookupClient.lookup(appStoreId: app.appStoreId, country: "us")
                    guard let g = info.primaryGenreId else {
                        logger.warning("ChartTracker skip app=\(app.appStoreId) — no primaryGenreId from iTunes")
                        continue
                    }
                    app.primaryGenreId = g
                    try await app.save(on: db)
                    genreId = g
                } catch {
                    logger.warning("ChartTracker backfill failed app=\(app.appStoreId): \(error)")
                    continue
                }
            }

            // Available countries for this app. If the prober hasn't run
            // (e.g. the app was added before this feature shipped), fall
            // back to every storefront — the prober will populate this
            // table over time.
            let availabilityRows = try await AppStorefrontAvailability.query(on: db)
                .filter(\.$watchedApp.$id == appID)
                .filter(\.$available == true)
                .all()
            let countries: [String]
            if availabilityRows.isEmpty {
                countries = AppStoreCountries.all
            } else {
                countries = availabilityRows.map { $0.country }
            }

            let (charts, events) = await refreshOne(
                appID: appID,
                appStoreId: app.appStoreId,
                genreId: genreId,
                countries: countries,
                now: now
            )
            totalCharts += charts
            totalEvents += events
        }

        logger.info("ChartTracker pass: apps=\(apps.count) charts=\(totalCharts) events=\(totalEvents)")
        return .init(appsProcessed: apps.count, chartsFetched: totalCharts, eventsEmitted: totalEvents)
    }

    private func refreshOne(
        appID: UUID,
        appStoreId: Int64,
        genreId: Int,
        countries: [String],
        now: Date
    ) async -> (charts: Int, events: Int) {
        // Bounded-concurrency country sweep. Each task returns the count of
        // events it emitted (0 or 1).
        return await withTaskGroup(of: Int.self) { group in
            var iterator = countries.makeIterator()
            var inFlight = 0
            var charts = 0
            var events = 0

            while inFlight < countryConcurrency, let country = iterator.next() {
                group.addTask {
                    await self.refreshOneCountry(
                        appID: appID, appStoreId: appStoreId,
                        genreId: genreId, country: country, now: now
                    )
                }
                inFlight += 1
            }
            while let emitted = await group.next() {
                charts += 1
                events += emitted
                inFlight -= 1
                if let country = iterator.next() {
                    group.addTask {
                        await self.refreshOneCountry(
                            appID: appID, appStoreId: appStoreId,
                            genreId: genreId, country: country, now: now
                        )
                    }
                    inFlight += 1
                }
            }
            return (charts, events)
        }
    }

    private func refreshOneCountry(
        appID: UUID,
        appStoreId: Int64,
        genreId: Int,
        country: String,
        now: Date
    ) async -> Int {
        do {
            let entries = try await chartsClient.topFree(country: country, genreId: genreId, limit: 200)
            let newPosition = entries.first(where: { $0.appStoreId == appStoreId })?.position
            return try await applyDiff(
                appID: appID, country: country, genreId: genreId,
                newPosition: newPosition, now: now
            )
        } catch {
            // Don't emit "exited" off a failed fetch — the apparent absence
            // is a network failure, not a real chart drop. Next cycle fixes it.
            logger.warning("ChartTracker fetch failed app=\(appStoreId) country=\(country): \(error)")
            return 0
        }
    }

    // Heart of the watchdog. Returns the number of events emitted (0 or 1).
    // Atomic per (app, country) so an interrupted job can't desync the
    // snapshot from the event log.
    private func applyDiff(
        appID: UUID,
        country: String,
        genreId: Int,
        newPosition: Int?,
        now: Date
    ) async throws -> Int {
        return try await db.transaction { tx in
            let cc = country.lowercased()
            let existing = try await ChartPositionSnapshot.query(on: tx)
                .filter(\.$watchedApp.$id == appID)
                .filter(\.$country == cc)
                .filter(\.$chartType == chartType)
                .filter(\.$genreId == genreId)
                .first()

            // Flatten the layered optional:
            //   no snapshot row      → prev = nil
            //   tombstone (position) → prev = nil
            //   charted at #M        → prev = M
            let prevPosition: Int? = existing?.position ?? nil
            let hasPriorRow = existing != nil

            let transition = decideChartTransition(
                prev: prevPosition, new: newPosition, hasPriorRow: hasPriorRow
            )
            if !transition.shouldWriteSnapshot { return 0 }

            // Upsert snapshot.
            if let existing {
                existing.position = newPosition
                existing.observedAt = now
                try await existing.save(on: tx)
            } else {
                let snap = ChartPositionSnapshot(
                    watchedAppID: appID,
                    country: cc,
                    chartType: chartType,
                    genreId: genreId,
                    position: newPosition,
                    observedAt: now
                )
                try await snap.save(on: tx)
            }

            // Emit event if needed.
            if let kind = transition.eventKind {
                let ev = ChartEvent(
                    watchedAppID: appID,
                    country: cc,
                    chartType: chartType,
                    genreId: genreId,
                    kind: kind,
                    position: newPosition,
                    prevPosition: prevPosition,
                    createdAt: now
                )
                try await ev.save(on: tx)
                return 1
            }

            return 0
        }
    }
}
