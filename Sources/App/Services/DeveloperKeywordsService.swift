import Foundation
import Vapor

// Orchestrates the per-app ASC fetches and translates ASC locales into the
// storefront-code keys the dashboard already uses. The wire shape is the
// nested map the SPA's `developerKeywords` store consumes:
//
//   { "<watchedAppUUID>": { "us": [...], "jp": [...], ... }, ... }
//
// When ASC credentials are absent or the user has no watched apps we return
// `[:]` instead of erroring — that lets the SPA call this endpoint
// unconditionally on every load.

protocol DeveloperKeywordsServiceProtocol: Sendable {
    func fetchAll() async throws -> [String: [String: [String]]]
}

struct DeveloperKeywordsService: DeveloperKeywordsServiceProtocol {
    let settings: any SettingsServiceProtocol
    let watchedApps: any WatchedAppRepositoryProtocol
    let makeClient: @Sendable (ASCCredentials) -> any AppStoreConnectClientProtocol
    let logger: Logger

    func fetchAll() async throws -> [String: [String: [String]]] {
        guard let creds = try await settings.getASCCredentials() else { return [:] }
        let apps = try await watchedApps.all()
        if apps.isEmpty { return [:] }

        let client = makeClient(creds)

        // Fan out per-app fetches concurrently. A handful of apps × 3
        // round-trips each completes in well under 2 s on a normal link.
        return try await withThrowingTaskGroup(of: (String, [String: [String]])?.self) { group in
            for app in apps {
                guard let appId = app.id else { continue }
                let appIdString = appId.uuidString
                let bundleId = app.bundleId
                let theClient = client
                let theLogger = logger
                group.addTask {
                    do {
                        let byLocale = try await theClient.fetchKeywords(forBundleId: bundleId)
                        return (appIdString, foldLocalesToStorefronts(byLocale))
                    } catch {
                        // One bad app shouldn't kill the whole response — the
                        // user may legitimately have an app they don't own,
                        // and the others still have useful data. Log it and
                        // return an empty map for that app so the UI can show
                        // "0 keywords" rather than nothing at all.
                        theLogger.warning("ASC fetch failed for bundleId=\(bundleId): \(String(describing: error))")
                        return (appIdString, [:])
                    }
                }
            }
            var out: [String: [String: [String]]] = [:]
            for try await item in group {
                if let (appIdString, perStorefront) = item {
                    out[appIdString] = perStorefront
                }
            }
            return out
        }
    }
}

/// Folds an ASC-locale-keyed map into a storefront-keyed map using
/// `ASCLocaleMapping`. A locale that maps to multiple storefronts (e.g.
/// `en-GB` → `gb` + `ie`) contributes its keyword set to each. Exposed at
/// file scope so the test target can exercise it without instantiating the
/// service.
func foldLocalesToStorefronts(_ byLocale: [String: [String]]) -> [String: [String]] {
    var out: [String: Set<String>] = [:]
    for (locale, terms) in byLocale {
        for store in ASCLocaleMapping.storefronts(for: locale) {
            out[store, default: []].formUnion(terms)
        }
    }
    return out.mapValues { Array($0).sorted() }
}
