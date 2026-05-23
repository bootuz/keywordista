@testable import App
import Foundation
import Testing

// Pure-function coverage of the watchdog's diff logic. The full
// ChartTrackerService wraps each transition in a Fluent transaction; that
// path is verified by the manual smoke test in the plan. These tests own
// the decision matrix that determines what event (if any) we emit.
@Suite("decideChartTransition")
struct ChartTransitionTests {
    @Test("never charted, still not charted — no-op (no snapshot row written)")
    func noPriorRow_stillNotCharted_isNoop() {
        let t = decideChartTransition(prev: nil, new: nil, hasPriorRow: false)
        #expect(t == .noop)
        #expect(t.eventKind == nil)
        #expect(t.shouldWriteSnapshot == false)
    }

    @Test("tombstone, still not charted — bump observed_at only")
    func tombstone_stillNotCharted_isStableTombstone() {
        let t = decideChartTransition(prev: nil, new: nil, hasPriorRow: true)
        #expect(t == .stableTombstone)
        #expect(t.eventKind == nil)
        #expect(t.shouldWriteSnapshot)
    }

    @Test("never charted → #57 emits entered")
    func enteredFromNothing() {
        let t = decideChartTransition(prev: nil, new: 57, hasPriorRow: false)
        #expect(t == .entered(position: 57))
        #expect(t.eventKind == .entered)
    }

    @Test("tombstone → #87 emits entered (resumes from exit)")
    func enteredFromTombstone() {
        let t = decideChartTransition(prev: nil, new: 87, hasPriorRow: true)
        #expect(t == .entered(position: 87))
        #expect(t.eventKind == .entered)
    }

    @Test("#45 → #30 emits moved")
    func movedUp() {
        let t = decideChartTransition(prev: 45, new: 30, hasPriorRow: true)
        #expect(t == .moved(from: 45, to: 30))
        #expect(t.eventKind == .moved)
    }

    @Test("#89 → #87 emits moved (down inside chart counts too)")
    func movedDown() {
        let t = decideChartTransition(prev: 89, new: 87, hasPriorRow: true)
        #expect(t == .moved(from: 89, to: 87))
        #expect(t.eventKind == .moved)
    }

    @Test("#94 → not found emits exited")
    func exited() {
        let t = decideChartTransition(prev: 94, new: nil, hasPriorRow: true)
        #expect(t == .exited(from: 94))
        #expect(t.eventKind == .exited)
    }

    @Test("#45 → #45 emits no event but still bumps observed_at")
    func stableCharted() {
        let t = decideChartTransition(prev: 45, new: 45, hasPriorRow: true)
        #expect(t == .stableCharted(at: 45))
        #expect(t.eventKind == nil)
        #expect(t.shouldWriteSnapshot)
    }
}
