@testable import App
import Foundation
import Testing

// Pins the gap-sorting semantics as ORDERINGS, not exact magic numbers — so
// the heuristic can be re-tuned freely as long as the urgency order holds.
@Suite("CompetitorGapClassifier (DefaultGapClassifier)")
struct CompetitorGapClassifierTests {
    private let classifier = DefaultGapClassifier()

    @Test("classifies each rank combination into the right kind")
    func kinds() {
        #expect(classifier.classify(myRank: nil, competitorRank: nil).kind == .neither)
        #expect(classifier.classify(myRank: 5, competitorRank: nil).kind == .ahead)
        #expect(classifier.classify(myRank: nil, competitorRank: 3).kind == .pureGap)
        #expect(classifier.classify(myRank: 5, competitorRank: 5).kind == .tied)
        #expect(classifier.classify(myRank: 5, competitorRank: 2).kind == .behind)  // competitor ahead
        #expect(classifier.classify(myRank: 2, competitorRank: 5).kind == .ahead)   // I'm ahead
    }

    @Test("a pure gap outranks even the worst 'behind' — being absent is most actionable")
    func pureGapBeatsAnyBehind() {
        let worstBehind = classifier.classify(myRank: 200, competitorRank: 1).score   // deficit 199, top of results
        let weakestPureGap = classifier.classify(myRank: nil, competitorRank: 200).score
        #expect(weakestPureGap > worstBehind)
    }

    @Test("among pure gaps, a higher-ranked competitor is more urgent")
    func pureGapUrgencyTracksCompetitorPosition() {
        #expect(
            classifier.classify(myRank: nil, competitorRank: 1).score >
            classifier.classify(myRank: nil, competitorRank: 50).score
        )
    }

    @Test("among 'behind' cells, a fight near the top beats a deeper one with a bigger deficit")
    func behindWeightsProminenceOverRawDeficit() {
        let topFight = classifier.classify(myRank: 5, competitorRank: 2).score      // deficit 3, prominence 198
        let deepFight = classifier.classify(myRank: 150, competitorRank: 140).score // deficit 10, prominence 60
        #expect(topFight > deepFight)
    }

    @Test("non-urgent tiers order: behind > tied > neither > ahead")
    func tierOrdering() {
        let behind = classifier.classify(myRank: 5, competitorRank: 2).score
        let tied = classifier.classify(myRank: 5, competitorRank: 5).score
        let neither = classifier.classify(myRank: nil, competitorRank: nil).score
        let ahead = classifier.classify(myRank: 2, competitorRank: 5).score
        #expect(behind > tied)
        #expect(tied > neither)
        #expect(neither > ahead)
    }
}
