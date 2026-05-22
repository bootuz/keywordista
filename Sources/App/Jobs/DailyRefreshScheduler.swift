import Fluent
import Foundation
import Queues
import Vapor

struct DailyRefreshScheduler: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let service = context.application.keywordServiceFactory(context)
        let count = try await service.enqueueRefreshAll()
        context.logger.info("DailyRefreshScheduler enqueued \(count) keyword refreshes")
    }
}
