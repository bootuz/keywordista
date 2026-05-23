import Fluent
import Foundation
import Vapor

// HTTP surface for the chart-position watchdog.
//   GET  /chart-positions                       → currently-charted snapshot rows
//   GET  /chart-events?since=&limit=            → activity feed for the SPA
//   POST /charts/refresh                        → kick off ChartTrackerService now
//   POST /apps/:id/availability/refresh         → re-probe a single app's storefronts
struct ChartsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("chart-positions", use: chartPositions)
        routes.get("chart-events", use: chartEvents)
        routes.post("charts", "refresh", use: refreshNow)
        routes.post("apps", ":id", "availability", "refresh", use: refreshAvailability)
    }

    // MARK: - DTOs (kept here rather than DomainTypes.swift because they're
    // the wire format for one feature; nothing else consumes them.)

    struct ChartPositionDTO: Content {
        let appId: UUID
        let appName: String
        let country: String
        let chartType: String
        let genreId: Int
        let position: Int
        let observedAt: Date
    }

    struct ChartEventDTO: Content {
        let id: UUID
        let appId: UUID
        let appName: String
        let country: String
        let chartType: String
        let genreId: Int
        let kind: String
        let position: Int?
        let prevPosition: Int?
        let createdAt: Date
    }

    struct RefreshAcceptedDTO: Content { let queued: Bool }

    // MARK: - Handlers

    @Sendable func chartPositions(req: Request) async throws -> [ChartPositionDTO] {
        // Snapshot rows with a non-null position == "currently charted".
        let snaps = try await ChartPositionSnapshot.query(on: req.db)
            .filter(\.$position != nil)
            .with(\.$watchedApp)
            .all()

        return snaps.compactMap { snap -> ChartPositionDTO? in
            guard
                let appID = snap.watchedApp.id,
                let position = snap.position
            else { return nil }
            return ChartPositionDTO(
                appId: appID,
                appName: snap.watchedApp.name,
                country: snap.country,
                chartType: snap.chartType,
                genreId: snap.genreId,
                position: position,
                observedAt: snap.observedAt
            )
        }
    }

    @Sendable func chartEvents(req: Request) async throws -> [ChartEventDTO] {
        let sinceStr = try? req.query.get(String.self, at: "since")
        let limit = (try? req.query.get(Int.self, at: "limit")).map { min(max($0, 1), 200) } ?? 50

        var q = ChartEvent.query(on: req.db).with(\.$watchedApp)
        if let s = sinceStr {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let since = formatter.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
            if let since {
                q = q.filter(\.$createdAt > since)
            }
        }

        let events = try await q
            .sort(\.$createdAt, .descending)
            .range(..<limit)
            .all()

        return events.compactMap { ev -> ChartEventDTO? in
            guard let evID = ev.id, let appID = ev.watchedApp.id else { return nil }
            return ChartEventDTO(
                id: evID,
                appId: appID,
                appName: ev.watchedApp.name,
                country: ev.country,
                chartType: ev.chartType,
                genreId: ev.genreId,
                kind: ev.kind,
                position: ev.position,
                prevPosition: ev.prevPosition,
                createdAt: ev.createdAt
            )
        }
    }

    @Sendable func refreshNow(req: Request) async throws -> Response {
        // Detached task so the HTTP response returns immediately. The job
        // can take tens of seconds for a few apps × 30 countries; tying the
        // request lifetime to it would block the SPA on the "Check now" click.
        let service = req.chartTrackerService()
        let logger = req.logger
        Task.detached {
            do {
                _ = try await service.refreshAll(now: Date())
            } catch {
                logger.error("Manual chart refresh failed: \(error)")
            }
        }
        let response = Response(status: .accepted)
        try response.content.encode(RefreshAcceptedDTO(queued: true))
        return response
    }

    @Sendable func refreshAvailability(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid app id")
        }
        let prober = req.availabilityProber()
        let logger = req.logger
        Task.detached {
            do {
                _ = try await prober.probe(watchedAppID: id)
            } catch {
                logger.error("Availability probe failed for app=\(id): \(error)")
            }
        }
        let response = Response(status: .accepted)
        try response.content.encode(RefreshAcceptedDTO(queued: true))
        return response
    }
}
