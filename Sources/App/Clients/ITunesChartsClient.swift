import Vapor

// Vapor's existing iTunes clients live under Services/ITunesSearchClient.swift
// etc., but the chart-RSS endpoint serves a different envelope shape and a
// different host path style ("/<country>/rss/topfreeapplications/...") so it
// gets its own thin client. Mirrors the timeout pattern of ITunesSearchClient.

protocol ITunesChartsClientProtocol: Sendable {
    func topFree(country: String, genreId: Int, limit: Int) async throws -> [ChartEntry]
}

struct ChartEntry: Sendable, Equatable {
    let appStoreId: Int64
    let position: Int          // 1-indexed
    let name: String
}

struct ITunesChartsClient: ITunesChartsClientProtocol {
    let client: any Client
    let logger: Logger
    static let requestTimeoutSeconds: UInt64 = 30

    func topFree(country: String, genreId: Int, limit: Int) async throws -> [ChartEntry] {
        let cc = country.lowercased()
        // RSS feeds for category-scoped charts. The legacy
        // /<country>/rss/<chart>/limit=<n>/genre=<id>/json path is the only
        // one that supports the genre filter; the newer applemarketingtools
        // v2 API drops it.
        let url = URI(string:
            "https://itunes.apple.com/\(cc)/rss/topfreeapplications/limit=\(limit)/genre=\(genreId)/json"
        )

        let response: ClientResponse = try await withThrowingTaskGroup(of: ClientResponse.self) { group in
            let theClient = client
            let theURL = url
            let timeoutSeconds = Self.requestTimeoutSeconds
            group.addTask { try await theClient.get(theURL) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw Abort(.gatewayTimeout, reason: "iTunes charts timed out after \(timeoutSeconds)s")
            }
            guard let first = try await group.next() else {
                throw Abort(.internalServerError, reason: "iTunes charts produced no result")
            }
            group.cancelAll()
            return first
        }

        guard response.status == .ok else {
            logger.error("iTunes charts returned \(response.status) for country=\(cc) genre=\(genreId)")
            throw Abort(.badGateway, reason: "iTunes charts failed with \(response.status)")
        }

        guard let buffer = response.body else { return [] }
        return try ITunesChartsClient.parseEntries(from: Data(buffer: buffer))
    }

    // Pure JSON-to-`[ChartEntry]` parser, exposed for unit testing without a
    // live Vapor Client. Marked `static` because it doesn't touch `client`
    // or `logger`.
    static func parseEntries(from data: Data) throws -> [ChartEntry] {
        let envelope = try JSONDecoder().decode(RSSEnvelope.self, from: data)
        return envelope.feed.entry?.enumerated().compactMap { (idx, entry) -> ChartEntry? in
            guard let idStr = entry.id.attributes.imId, let appStoreId = Int64(idStr) else {
                return nil
            }
            return ChartEntry(
                appStoreId: appStoreId,
                position: idx + 1,
                name: entry.imName.label
            )
        } ?? []
    }
}

// MARK: - RSS envelope (Apple's "iTunes RSS feed in JSON form" shape).
//
// The endpoint returns either an array of entries (when the chart has
// results) or omits the `entry` key entirely (for empty / unknown genres).
// `entry` is therefore optional.
private struct RSSEnvelope: Decodable {
    let feed: RSSFeed
}

private struct RSSFeed: Decodable {
    let entry: [RSSEntry]?
}

private struct RSSEntry: Decodable {
    let imName: ImName
    let id: RSSEntryId

    enum CodingKeys: String, CodingKey {
        case imName = "im:name"
        case id
    }

    struct ImName: Decodable {
        let label: String
    }

    struct RSSEntryId: Decodable {
        let attributes: Attributes
        struct Attributes: Decodable {
            // Apple uses dotted/colon keys ("im:id") which Swift cannot
            // express as a property name; decode via a custom CodingKey.
            let imId: String?
            enum CodingKeys: String, CodingKey {
                case imId = "im:id"
            }
        }
    }
}
