import Fluent
import Foundation
import Vapor

// Batched probe that asks iTunes lookup "is this app published in country X?"
// for every App Store storefront. Used after an app is added and via
// /apps/:id/availability/refresh. Results land in app_storefront_availability
// and ChartTrackerService consults that table to avoid 175 RSS fetches per
// cycle when the app only ships in ~30 countries.
//
// Side effect: if WatchedApp.primaryGenreId is nil, this opportunistically
// backfills it from the first successful lookup. Existing rows added before
// the chart-tracking feature shipped get healed automatically the next time
// they're probed.

protocol AvailabilityProberProtocol: Sendable {
    func probe(watchedAppID: UUID) async throws -> Int
}

struct AvailabilityProber: AvailabilityProberProtocol {
    let db: any Database
    let lookupClient: any ITunesLookupClientProtocol
    let logger: Logger
    // Run at most N lookups in flight against iTunes at once. iTunes' edge
    // tolerates much higher fan-out but 8 is plenty to finish the 175-probe
    // sweep in under a minute without being a thundering herd.
    var concurrency: Int = 8

    @discardableResult
    func probe(watchedAppID: UUID) async throws -> Int {
        guard let app = try await WatchedApp.find(watchedAppID, on: db) else {
            throw Abort(.notFound, reason: "WatchedApp \(watchedAppID) not found")
        }
        let appStoreId = app.appStoreId
        let now = Date()

        // Fan out lookups in batches of `concurrency` to keep iTunes happy.
        // For each country we map to one of three states:
        //   .ok(primaryGenreId?)   — app exists in this storefront
        //   .notAvailable          — confirmed 404 from iTunes
        //   .skipped               — transient error; leave existing row alone
        let results = try await withThrowingTaskGroup(of: (String, ProbeOutcome).self) { group in
            var iterator = AppStoreCountries.all.makeIterator()
            var inFlight = 0
            var collected: [(String, ProbeOutcome)] = []

            // Prime the pipeline.
            while inFlight < concurrency, let country = iterator.next() {
                group.addTask {
                    let outcome = await self.probeOne(appStoreId: appStoreId, country: country)
                    return (country, outcome)
                }
                inFlight += 1
            }
            while let next = try await group.next() {
                collected.append(next)
                inFlight -= 1
                if let country = iterator.next() {
                    group.addTask {
                        let outcome = await self.probeOne(appStoreId: appStoreId, country: country)
                        return (country, outcome)
                    }
                    inFlight += 1
                }
            }
            return collected
        }

        var written = 0
        var backfilledGenre: Int? = nil
        for (country, outcome) in results {
            switch outcome {
            case .ok(let genreId):
                if backfilledGenre == nil, let genreId { backfilledGenre = genreId }
                try await upsertAvailability(appID: watchedAppID, country: country, available: true, at: now)
                written += 1
            case .notAvailable:
                try await upsertAvailability(appID: watchedAppID, country: country, available: false, at: now)
                written += 1
            case .skipped:
                continue
            }
        }

        // Backfill primary_genre_id if absent. Existing rows from before the
        // chart-tracking feature shipped don't have this and we need it to
        // know which top-free chart to poll.
        if app.primaryGenreId == nil, let g = backfilledGenre {
            app.primaryGenreId = g
            try await app.save(on: db)
        }

        logger.info("AvailabilityProber app=\(appStoreId) wrote=\(written) genre=\(app.primaryGenreId ?? -1)")
        return written
    }

    private enum ProbeOutcome {
        case ok(primaryGenreId: Int?)
        case notAvailable
        case skipped
    }

    private func probeOne(appStoreId: Int64, country: String) async -> ProbeOutcome {
        do {
            let result = try await lookupClient.lookup(appStoreId: appStoreId, country: country)
            return .ok(primaryGenreId: result.primaryGenreId)
        } catch let abort as AbortError where abort.status == .notFound {
            return .notAvailable
        } catch {
            // Transient (timeout, 5xx, DNS). Don't write a stale row.
            logger.warning("AvailabilityProber transient error app=\(appStoreId) country=\(country): \(error)")
            return .skipped
        }
    }

    private func upsertAvailability(
        appID: UUID,
        country: String,
        available: Bool,
        at: Date
    ) async throws {
        let cc = country.lowercased()
        if let existing = try await AppStorefrontAvailability.query(on: db)
            .filter(\.$watchedApp.$id == appID)
            .filter(\.$country == cc)
            .first()
        {
            existing.available = available
            existing.checkedAt = at
            try await existing.save(on: db)
        } else {
            let row = AppStorefrontAvailability(
                watchedAppID: appID,
                country: cc,
                available: available,
                checkedAt: at
            )
            try await row.save(on: db)
        }
    }
}

// The 175 App Store storefronts, verified against
// developer.apple.com/help/app-store-connect/reference/pricing-and-availability/...
// Kept in sync with web/src/lib/countries.ts; if Apple adds territories,
// update both lists.
enum AppStoreCountries {
    static let all: [String] = [
        "af", "al", "dz", "ao", "ai", "ag", "ar", "am", "au", "at", "az",
        "bs", "bh", "bb", "by", "be", "bz", "bj", "bm", "bt", "bo", "ba",
        "bw", "br", "vg", "bn", "bg", "bf",
        "kh", "cm", "ca", "cv", "ky", "td", "cl", "cn", "co", "cd", "cg",
        "cr", "ci", "hr", "cy", "cz",
        "dk", "dm", "do", "ec", "eg", "sv", "ee", "sz", "fj", "fi", "fr",
        "ga", "gm", "ge", "de", "gh", "gr", "gd", "gt", "gw", "gy",
        "hn", "hk", "hu", "is", "in", "id", "iq", "ie", "il", "it",
        "jm", "jp", "jo", "kz", "ke", "xk", "kw", "kg",
        "la", "lv", "lb", "lr", "ly", "lt", "lu",
        "mo", "mg", "mw", "my", "mv", "ml", "mt", "mr", "mu", "mx",
        "fm", "md", "mn", "me", "ms", "ma", "mz", "mm",
        "na", "nr", "np", "nl", "nz", "ni", "ng", "mk", "no",
        "om", "pk", "pw", "pa", "pg", "py", "pe", "ph", "pl", "pt",
        "qa", "kr", "ro", "ru", "rw",
        "st", "sa", "sn", "rs", "sc", "sl", "sg", "sk", "si", "sb", "za",
        "es", "lk", "kn", "lc", "vc", "sr", "se", "ch",
        "tw", "tj", "tz", "th", "to", "tt", "tn", "tr", "tm", "tc",
        "ug", "ua", "ae", "gb", "us", "uy", "uz",
        "vu", "ve", "vn", "ye", "zm", "zw",
    ]
}
