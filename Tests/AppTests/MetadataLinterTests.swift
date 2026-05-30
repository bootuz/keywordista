@testable import App
import Foundation
import Testing

@Suite("MetadataLinter")
struct MetadataLinterTests {
    let linter = MetadataLinter()

    private func only(_ result: [LintFinding], _ rule: LintFinding.Rule) -> [LintFinding] {
        result.filter { $0.rule == rule }
    }

    @Test("flags a word that appears in both title and subtitle as wasted")
    func duplicateWordAcrossFields() {
        let result = linter.lint(
            title: "Flashcards Maker",
            subtitle: "Smart Flashcards Study",
            trackedTerms: [],
        )
        let dupes = only(result, .duplicateWord)
        #expect(dupes.count == 1)
        #expect(dupes.first?.severity == .warning)
        #expect(dupes.first?.message.contains("flashcards") == true)
        // Words present in only one field are not duplicates.
        #expect(dupes.allSatisfy { !$0.message.contains("maker") && !$0.message.contains("study") })
    }

    @Test("does not flag stop words as duplicates")
    func stopWordsNotDuplicated() {
        let result = linter.lint(
            title: "Cards and Decks",
            subtitle: "Learn and Study",
            trackedTerms: [],
        )
        #expect(only(result, .duplicateWord).isEmpty)
    }

    @Test("flags a missing subtitle as a warning and an under-filled title as info")
    func wastedBudget() {
        let result = linter.lint(title: "Azri", subtitle: nil, trackedTerms: ["azri"])
        let budget = only(result, .wastedBudget)
        let subtitleFinding = budget.first { $0.field == "subtitle" }
        let titleFinding = budget.first { $0.field == "title" }
        #expect(subtitleFinding?.severity == .warning)
        #expect(subtitleFinding?.message.contains("No subtitle") == true)
        #expect(titleFinding?.severity == .info)
    }

    @Test("flags indexed words the user does not track, but not tracked ones")
    func untrackedIndexedWords() {
        let result = linter.lint(
            title: "Azri FSRS",
            subtitle: "Flashcards",
            trackedTerms: ["flashcards", "spaced repetition"],
        )
        let untracked = only(result, .untrackedWord)
        let words = untracked.map(\.message)
        #expect(words.contains { $0.contains("azri") })
        #expect(words.contains { $0.contains("fsrs") })
        // "flashcards" is tracked → must not be flagged as untracked.
        #expect(untracked.allSatisfy { !$0.message.contains("flashcards") })
    }

    @Test("a clean listing produces no duplicate or untracked findings")
    func cleanListing() {
        let result = linter.lint(
            title: "Spaced Repetition",
            subtitle: "Memory Trainer",
            trackedTerms: ["spaced repetition", "memory", "trainer"],
        )
        #expect(only(result, .duplicateWord).isEmpty)
        #expect(only(result, .untrackedWord).isEmpty)
    }
}
