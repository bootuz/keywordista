import Foundation

// The opportunity heuristic, in one place: real ASA impressions weighed
// against difficulty. Tunable — change the formula here and every consumer
// (dashboard, MCP) follows, since none of them duplicate it.
enum OpportunityScore {
    /// `impressions ÷ difficulty`. Returns nil when difficulty is unknown (0)
    /// — we won't rank a keyword we can't assess. Higher = a better bet
    /// (popular and not too contested).
    static func compute(impressions: Int, difficulty: Int) -> Int? {
        guard difficulty >= 1 else { return nil }
        return impressions / difficulty
    }
}
