import Foundation
import Queues
import Vapor

struct RefreshKeywordJob: AsyncJob {
    typealias Payload = UUID

    func dequeue(_ context: QueueContext, _ keywordID: UUID) async throws {
        let service = context.application.refreshServiceFactory(context)
        try await service.refresh(keywordID: keywordID, now: Date())
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: UUID) async throws {
        context.logger.error("RefreshKeywordJob failed for keyword=\(payload): \(error)")
    }
}
