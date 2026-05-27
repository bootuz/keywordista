import Vapor

protocol ITunesLookupClientProtocol: Sendable {
    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp
    /// Rich variant for the metadata snapshot pipeline. Sibling method
    /// (not a replacement) so the thin `lookup` keeps doing minimal
    /// decoding work on the hot chart-watchdog backfill path — see
    /// `RichLookupResultApp`'s doc-comment for the rationale.
    func lookupRich(appStoreId: Int64, country: String) async throws -> RichLookupResultApp
}

struct ITunesLookupClient: ITunesLookupClientProtocol {
    let client: any Client

    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp {
        var url = URI(string: "https://itunes.apple.com/lookup")
        url.query = "id=\(appStoreId)&country=\(country.lowercased())&entity=software"

        let response = try await client.get(url)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "iTunes lookup failed with \(response.status)")
        }

        struct Envelope: Codable { let resultCount: Int; let results: [LookupResultApp] }
        guard let buffer = response.body else {
            throw Abort(.badGateway, reason: "iTunes lookup empty body")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(buffer: buffer))
        guard let first = envelope.results.first else {
            throw Abort(.notFound, reason: "No app found for id=\(appStoreId) in country=\(country)")
        }
        return first
    }

    func lookupRich(appStoreId: Int64, country: String) async throws -> RichLookupResultApp {
        var url = URI(string: "https://itunes.apple.com/lookup")
        url.query = "id=\(appStoreId)&country=\(country.lowercased())&entity=software"

        let response = try await client.get(url)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "iTunes lookup failed with \(response.status)")
        }

        struct Envelope: Codable { let resultCount: Int; let results: [RichLookupResultApp] }
        guard let buffer = response.body else {
            throw Abort(.badGateway, reason: "iTunes lookup empty body")
        }
        // `.iso8601` parses `releaseDate: "2012-02-02T18:57:49Z"` —
        // Apple's lookup response uses non-fractional ISO 8601 even
        // though the rest of Keywordista's wire format prefers
        // fractional. Stand alone here (don't reuse configure.swift's
        // ContentConfiguration encoder/decoder) because this is reading
        // a third-party API with its own contract.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: Data(buffer: buffer))
        guard let first = envelope.results.first else {
            throw Abort(.notFound, reason: "No app found for id=\(appStoreId) in country=\(country)")
        }
        return first
    }
}
