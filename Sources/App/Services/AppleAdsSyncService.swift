import Foundation
import Logging

protocol AppleAdsSyncServiceProtocol: Sendable {
    /// Pulls the configured ad account's Apple Ads data into the local mirror
    /// and records the attempt. Throws `AppleAdsError.notConnected` (without
    /// recording a run) when Apple Ads isn't set up.
    func sync(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun
}

/// Fetches everything first, then writes it in one transaction: a sync that
/// fails halfway leaves the previously synced numbers untouched.
struct AppleAdsSyncService: AppleAdsSyncServiceProtocol {
    /// Apple's DAILY report maximum span.
    static let backfillDays = 90
    /// Apple revises recent days; every sync re-pulls this many.
    static let revisionDays = 7

    let settings: any SettingsServiceProtocol
    let repository: any AppleAdsDataRepositoryProtocol
    let watchedApps: any WatchedAppRepositoryProtocol
    let keywords: any KeywordRepositoryProtocol
    let makeClient: @Sendable (ASACredentials) -> any AppleAdsReportingClientProtocol
    /// Today as `yyyy-MM-dd` (UTC). Injected so tests pin the window.
    let today: @Sendable () -> String
    let logger: Logger

    func sync(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun {
        guard let credentials = try await settings.getASACredentials() else { throw AppleAdsError.notConnected }
        let client = makeClient(credentials)
        let run = try await repository.startRun(trigger: trigger)

        let adAccountId: Int64
        do {
            adAccountId = try await client.resolveAdAccountId()
        } catch {
            try await finish(run, account: nil, outcome: .failed, window: nil, error: error)
            throw error
        }

        let window = try await window(for: adAccountId)
        do {
            // An account switch (also one made outside Settings) must never
            // show the old account's numbers.
            try await repository.purge(exceptAdAccountId: adAccountId)
            let snapshot = try await fetch(client, from: window.from, to: window.to)
            // A disconnect cancels the sync; never write after it purged.
            try Task.checkCancellation()
            try await repository.replace(adAccountId: adAccountId, from: window.from, to: window.to, with: snapshot)
        } catch {
            if !(error is CancellationError) {
                try? await finish(run, account: adAccountId, outcome: .failed, window: window, error: error)
            }
            throw error
        }
        return try await finish(run, account: adAccountId, outcome: .succeeded, window: window, error: nil)
    }

    // MARK: Window

    private func window(for adAccountId: Int64) async throws -> (from: String, to: String) {
        let to = today()
        let revisionStart = Self.shift(to, days: -(Self.revisionDays - 1))
        let lastGood = try await repository.lastSuccessfulRun(adAccountId: adAccountId)
        // Gap since the last good sync wider than the revision window: backfill.
        if let lastTo = lastGood?.toDate, lastTo >= Self.shift(to, days: -Self.revisionDays) {
            return (revisionStart, to)
        }
        return (Self.shift(to, days: -(Self.backfillDays - 1)), to)
    }

    static func shift(_ day: String, days: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return formatter.string(from: moved)
    }

    // MARK: Fetch

    private func fetch(_ client: any AppleAdsReportingClientProtocol, from: String, to: String) async throws -> AppleAdsSnapshot {
        let campaigns = try await client.campaignInfos()
        var snapshot = AppleAdsSnapshot(
            campaigns: campaigns, keywords: [], campaignDays: [], keywordDays: [],
            searchTermDays: [], popularity: [], ideas: []
        )
        snapshot.campaignDays = try await client.campaignDays(campaignIds: campaigns.map(\.id), from: from, to: to)
        for campaign in campaigns {
            snapshot.keywords += try await client.keywords(campaignId: campaign.id)
            snapshot.keywordDays += try await client.keywordDays(campaignId: campaign.id, from: from, to: to)
            snapshot.searchTermDays += try await client.searchTermDays(campaignId: campaign.id, from: from, to: to)
        }
        try await addIdeasAndPopularity(client, into: &snapshot)
        return snapshot
    }

    /// Best-effort: popularity and suggestions enrich the area but must
    /// never cost the user their performance numbers.
    private func addIdeasAndPopularity(_ client: any AppleAdsReportingClientProtocol, into snapshot: inout AppleAdsSnapshot) async throws {
        let ownApps = try await watchedApps.all().filter { $0.typedKind == .own }
        let tracked = try await keywords.all()
        for app in ownApps {
            let appCampaigns = snapshot.campaigns.filter { $0.appStoreId == app.appStoreId }
            guard !appCampaigns.isEmpty else { continue }
            let campaignIds = Set(appCampaigns.map(\.id))
            let countries = Set(appCampaigns.flatMap(\.countries)).sorted()

            var ideas: [AppleAdsKeywordIdea] = []
            for country in countries {
                do {
                    ideas += try await client.keywordIdeas(appStoreId: app.appStoreId, country: country)
                } catch {
                    logger.warning("Apple Ads keyword suggestions failed: app=\(app.appStoreId) country=\(country) error=\(error)")
                }
            }
            snapshot.ideas += ideas

            guard let genre = AppleAdsGenre.forITunesGenreId(app.primaryGenreId) else { continue }
            let bidTerms = snapshot.keywords.filter { campaignIds.contains($0.campaignId) }.map(\.text)
            let converted = snapshot.searchTermDays
                .filter { campaignIds.contains($0.campaignId) && $0.metrics.tapInstalls > 0 && $0.term != AppleAdsPlatformClient.lowVolumeText }
            for country in countries {
                var terms = Set(bidTerms.map { $0.lowercased() })
                terms.formUnion(tracked.filter { $0.countryCode.uppercased() == country }.map { $0.term.lowercased() })
                terms.formUnion(converted.filter { $0.country == country }.map { $0.term.lowercased() })
                terms.formUnion(ideas.filter { $0.country == country }.map { $0.text.lowercased() })
                guard !terms.isEmpty else { continue }
                do {
                    snapshot.popularity += try await client.termPopularity(terms: terms.sorted(), country: country, genre: genre)
                } catch {
                    logger.warning("Apple Ads popularity failed: country=\(country) genre=\(genre) error=\(error)")
                }
            }
        }
    }

    // MARK: Runs

    @discardableResult
    private func finish(
        _ run: AppleAdsSyncRun, account: Int64?, outcome: AppleAdsSyncOutcome,
        window: (from: String, to: String)?, error: (any Error)?
    ) async throws -> AppleAdsSyncRun {
        let message = error.map { AppleAdsError.from($0).description }
        try await repository.finishRun(
            id: run.id, adAccountId: account, outcome: outcome,
            fromDate: window?.from, toDate: window?.to, error: message
        )
        return AppleAdsSyncRun(
            id: run.id, adAccountId: account, trigger: run.trigger, outcome: outcome,
            startedAt: run.startedAt, finishedAt: Date(), fromDate: window?.from, toDate: window?.to, error: message
        )
    }
}
