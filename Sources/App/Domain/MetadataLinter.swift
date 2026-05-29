import Foundation

// Lints a watched app's *indexed* short fields — title + subtitle — for
// common ASO waste, against the user's tracked keywords. Mirrors the
// KeywordScorer pattern: a small, pure, protocol-fronted heuristic.
//
// Scope note: Apple's search algorithm indexes the title, subtitle, and the
// (private) keyword field — and IGNORES the description for ranking. So the
// linter deliberately reads only title + subtitle. The keyword field lives
// in App Store Connect, not the public snapshot, so it's out of v1 scope.
protocol MetadataLinterProtocol: Sendable {
    func lint(title: String, subtitle: String?, trackedTerms: [String]) -> [LintFinding]
}

struct MetadataLinter: MetadataLinterProtocol {
    // Apple's character limits for the indexed short fields.
    static let titleLimit = 30
    static let subtitleLimit = 30
    // Only flag wasted budget when a meaningful amount is unused — a couple
    // of spare characters isn't actionable advice.
    static let wastedThreshold = 6
    // Tokens shorter than this, or in the stop list, are dropped before the
    // duplicate/untracked rules so findings stay high-signal. (2 keeps "ai".)
    static let minTokenLength = 2
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "your", "you", "app", "apps", "free",
        "pro", "best", "new", "get", "all", "are", "that", "this", "from",
        "of", "to", "in", "on", "or", "an", "is", "it", "at", "as", "by", "be",
    ]

    func lint(title: String, subtitle: String?, trackedTerms: [String]) -> [LintFinding] {
        let trimmedSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasSubtitle = !trimmedSubtitle.isEmpty

        return duplicateWordFindings(title: title, subtitle: trimmedSubtitle)
            + wastedBudgetFindings(title: title, subtitle: trimmedSubtitle, hasSubtitle: hasSubtitle)
            + untrackedWordFindings(title: title, subtitle: trimmedSubtitle, trackedTerms: trackedTerms)
    }

    // MARK: - Rules

    // A word indexed in BOTH title and subtitle is wasted — Apple indexes
    // each term once regardless of how many fields it appears in.
    private func duplicateWordFindings(title: String, subtitle: String) -> [LintFinding] {
        let titleSet = Set(significantTokens(in: title))
        var seen = Set<String>()
        return significantTokens(in: subtitle).compactMap { word in
            guard titleSet.contains(word), seen.insert(word).inserted else { return nil }
            return LintFinding(
                rule: .duplicateWord, severity: .warning, field: "title+subtitle",
                message: "\"\(word)\" appears in both the title and subtitle — Apple indexes each word once, so the repeat is wasted. Reuse that space for another keyword.",
            )
        }
    }

    private func wastedBudgetFindings(title: String, subtitle: String, hasSubtitle: Bool) -> [LintFinding] {
        var out: [LintFinding] = []
        let titleUnused = Self.titleLimit - title.count
        if titleUnused >= Self.wastedThreshold {
            out.append(LintFinding(
                rule: .wastedBudget, severity: .info, field: "title",
                message: "Title uses \(title.count)/\(Self.titleLimit) characters — \(titleUnused) unused. Consider adding a high-value keyword.",
            ))
        }
        if !hasSubtitle {
            out.append(LintFinding(
                rule: .wastedBudget, severity: .warning, field: "subtitle",
                message: "No subtitle set — \(Self.subtitleLimit) indexable characters unused. The subtitle is prime keyword real estate.",
            ))
        } else {
            let unused = Self.subtitleLimit - subtitle.count
            if unused >= Self.wastedThreshold {
                out.append(LintFinding(
                    rule: .wastedBudget, severity: .info, field: "subtitle",
                    message: "Subtitle uses \(subtitle.count)/\(Self.subtitleLimit) characters — \(unused) unused.",
                ))
            }
        }
        return out
    }

    // Words the listing indexes for but the user doesn't track — coverage
    // they're earning rank on without monitoring.
    private func untrackedWordFindings(title: String, subtitle: String, trackedTerms: [String]) -> [LintFinding] {
        let tracked = Set(trackedTerms.flatMap { significantTokens(in: $0) })
        var seen = Set<String>()
        return (significantTokens(in: title) + significantTokens(in: subtitle)).compactMap { word in
            guard !tracked.contains(word), seen.insert(word).inserted else { return nil }
            return LintFinding(
                rule: .untrackedWord, severity: .info, field: "title+subtitle",
                message: "Your listing indexes for \"\(word)\" but you don't track it. Add it as a keyword to watch your rank.",
            )
        }
    }

    // MARK: - Tokenization

    // Lowercase, split on any non-alphanumeric, drop stop words and tokens
    // shorter than the minimum. Order-preserving.
    private func significantTokens(in text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= Self.minTokenLength && !Self.stopWords.contains($0) }
    }
}
