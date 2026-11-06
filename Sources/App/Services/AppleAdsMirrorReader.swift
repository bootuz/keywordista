import Foundation

/// The read side every Apple Ads consumer shares: which synced account to
/// read, and the search terms of the recent window.
struct AppleAdsMirrorReader: Sendable {
    let repository: any AppleAdsDataRepositoryProtocol
    let today: @Sendable () -> String

    /// The account of the last successful sync, or nil before one exists.
    ///
    /// Why throw when only failures exist: an empty suggestions panel or
    /// popularity column reads as "Apple has nothing for you", when really
    /// Apple refused. Once one sync has succeeded, its data stays readable
    /// and the Setup tab shows the newer failure.
    func syncedAccount() async throws -> Int64? {
        if let account = try await repository.lastSuccessfulRun(adAccountId: nil)?.adAccountId {
            return account
        }
        if let latest = try await repository.latestRun(), latest.outcome == .failed {
            throw AppleAdsError.syncFailed(latest.error ?? "unknown error")
        }
        return nil
    }

    /// Search-term rows from the `days` days ending at the newest synced day.
    func recentSearchTerms(account: Int64, days: Int) async throws -> [AppleAdsSearchTermDay] {
        let end = try await repository.latestDate(adAccountId: account) ?? today()
        return try await repository.searchTermDays(
            adAccountId: account, from: AppleAdsMath.shift(end, days: -(days - 1)), to: end
        )
    }

    static func isLowVolume(_ term: String) -> Bool {
        term.uppercased() == AppleAdsPlatformClient.lowVolumeText
    }
}
