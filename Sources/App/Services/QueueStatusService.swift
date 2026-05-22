import Fluent
import Foundation
import SQLKit

// Reports how much work is left in the in-process Vapor Queues. Used by the
// SPA to show progress while "Refresh all" is grinding through the keyword
// list. The _jobs table is created by QueuesFluentDriver; we read it directly
// because the queues package doesn't expose pending counts as a first-class
// API and the join is too simple to justify a wrapper library.

struct QueueStatus: Codable, Sendable, Equatable {
    let pending: Int  // unfinished jobs: state IN ('pending', 'processing')
}

protocol QueueStatusServiceProtocol: Sendable {
    func status() async throws -> QueueStatus
}

struct QueueStatusService: QueueStatusServiceProtocol {
    let db: any Database

    func status() async throws -> QueueStatus {
        guard let sql = db as? any SQLDatabase else {
            return QueueStatus(pending: 0)
        }
        // QueuesFluentDriver stores all queued/completed jobs in _jobs and
        // flips the state column as the worker progresses.
        let rows = try await sql.raw("""
        SELECT COUNT(*) AS count
          FROM _jobs
         WHERE state IN ('pending', 'processing')
        """).all()
        guard let row = rows.first else { return QueueStatus(pending: 0) }
        let count = try row.decode(column: "count", as: Int.self)
        return QueueStatus(pending: count)
    }
}
