import Foundation
import Queues

protocol RefreshDispatcherProtocol: Sendable {
    func dispatch(keywordID: UUID) async throws
}

struct QueueRefreshDispatcher: RefreshDispatcherProtocol {
    let queue: any Queue

    func dispatch(keywordID: UUID) async throws {
        try await queue.dispatch(RefreshKeywordJob.self, keywordID)
    }
}
