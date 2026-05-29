import Foundation

// Encodes what a "gap" *means* and how urgently it should surface. Mirrors
// the `KeywordScorer` pattern: a small, pure, swappable heuristic fronted by
// a protocol so the service can be tested with a stub and the rule can be
// tuned without touching the matrix-building plumbing.
protocol CompetitorGapClassifierProtocol: Sendable {
    func classify(myRank: Int?, competitorRank: Int?) -> GapVerdict
}

struct DefaultGapClassifier: CompetitorGapClassifierProtocol {
    // Ranks run 1...searchLimit (200). `prominence` converts a rank into
    // "how high up" — 200 at #1, falling to ~0 at the tail — so urgency
    // weights the top of the results, where visibility actually matters.
    private static let maxRank = 200
    // Floor that lifts every pure gap above any finite "behind" score. The
    // worst behind tops out near 2·maxRank, so this clears it with margin.
    private static let pureGapFloor = 10_000

    func classify(myRank: Int?, competitorRank: Int?) -> GapVerdict {
        switch (myRank, competitorRank) {
        case (nil, nil):
            // Nobody ranks for this term — nothing to act on.
            return GapVerdict(kind: .neither, score: 0)

        case (_?, nil):
            // I rank, the competitor doesn't — I'm winning this cell.
            return GapVerdict(kind: .ahead, score: -1)

        case (nil, let competitor?):
            // The competitor ranks and I'm absent: the single most
            // actionable signal. Tiered above every "behind"; within the
            // tier, a higher-placed competitor is more urgent.
            let prominence = Self.maxRank - competitor
            return GapVerdict(kind: .pureGap, score: Self.pureGapFloor + prominence)

        case (let mine?, let competitor?):
            if mine == competitor {
                // Neck and neck — noteworthy but not urgent.
                return GapVerdict(kind: .tied, score: 1)
            }
            if competitor < mine {
                // Competitor is ahead. Urgency grows with the deficit AND
                // with how high the fight is — being beaten in the top 5
                // stings more than at #150.
                let deficit = mine - competitor
                let prominence = Self.maxRank - competitor
                return GapVerdict(kind: .behind, score: deficit + prominence)
            }
            // I'm ahead (better finite rank). Least urgent.
            return GapVerdict(kind: .ahead, score: -1)
        }
    }
}
