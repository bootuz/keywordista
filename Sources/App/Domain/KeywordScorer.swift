import Foundation

struct KeywordScores: Sendable, Equatable {
    let difficulty: Int
    let entryBarrier: Int

    static let zero = KeywordScores(difficulty: 0, entryBarrier: 0)
}

protocol KeywordScorerProtocol: Sendable {
    func score(topFive: [SearchResultApp], referenceDate: Date) -> KeywordScores
}

// Heuristic chosen for personal use: difficulty buckets by avg rating count
// across top 5; entry barrier combines leader dominance with cohort age.
// Both scores are frozen into RankCheck rows at write time, so any future
// tuning here won't rewrite history.
struct HeuristicScorer: KeywordScorerProtocol {
    func score(topFive: [SearchResultApp], referenceDate: Date) -> KeywordScores {
        guard !topFive.isEmpty else { return .zero }
        return KeywordScores(
            difficulty: difficulty(topFive: topFive),
            entryBarrier: entryBarrier(topFive: topFive, referenceDate: referenceDate)
        )
    }

    private func difficulty(topFive: [SearchResultApp]) -> Int {
        let ratings = topFive.prefix(5).map { Double($0.userRatingCount ?? 0) }
        let avg = ratings.reduce(0, +) / Double(ratings.count)
        switch avg {
        case ..<1_000: return 1
        case ..<10_000: return 2
        case ..<100_000: return 3
        case ..<500_000: return 4
        default: return 5
        }
    }

    private func entryBarrier(topFive: [SearchResultApp], referenceDate: Date) -> Int {
        guard let leader = topFive.first else { return 0 }
        let othersAvg = max(averageRatings(of: topFive.dropFirst().prefix(4)), 1)
        let dominance = Double(leader.userRatingCount ?? 0) / othersAvg
        let ageYears = averageAgeYears(of: topFive.prefix(5), referenceDate: referenceDate)
        return min(5, dominanceScore(dominance) + ageScore(ageYears))
    }

    private func averageRatings(of apps: some Collection<SearchResultApp>) -> Double {
        guard !apps.isEmpty else { return 0 }
        let total = apps.reduce(0.0) { $0 + Double($1.userRatingCount ?? 0) }
        return total / Double(apps.count)
    }

    private func averageAgeYears(of apps: some Collection<SearchResultApp>, referenceDate: Date) -> Double {
        let years: [Double] = apps.compactMap { app in
            guard let release = app.releaseDate else { return nil }
            return referenceDate.timeIntervalSince(release) / (365.25 * 24 * 3600)
        }
        guard !years.isEmpty else { return 0 }
        return years.reduce(0, +) / Double(years.count)
    }

    private func dominanceScore(_ dominance: Double) -> Int {
        switch dominance {
        case ..<2: return 0
        case ..<5: return 1
        case ..<15: return 2
        default: return 3
        }
    }

    private func ageScore(_ years: Double) -> Int {
        switch years {
        case ..<2: return 0
        case ..<5: return 1
        default: return 2
        }
    }
}
