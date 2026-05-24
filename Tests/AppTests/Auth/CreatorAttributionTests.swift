@testable import App
import Foundation
import Testing

/// M1.8 added `@OptionalParent creator: User?` to WatchedApp and
/// Keyword. The init param is optional (default nil) so the existing
/// service-layer callers continue to compile without changes; M1.10
/// will update them to thread `req.auth.user.id` through.
///
/// These tests pin the API:
///   • The new column is OPTIONAL (default-nil init param works)
///   • Passing a creatorID sets the @OptionalParent's id correctly
///   • The default-nil case yields a nil creator (so existing
///     pre-auth rows continue to behave the same after migration)
@Suite("Creator attribution (M1.8)")
struct CreatorAttributionTests {

    // ── WatchedApp ───────────────────────────────────────────────────

    @Suite("WatchedApp")
    struct WatchedAppTests {

        @Test("Init without creatorID leaves creator nil (matches pre-auth behavior)")
        func defaultNilCreator() {
            let app = WatchedApp(
                appStoreId: 123,
                bundleId: "com.example",
                name: "Example",
                iconURL: nil
            )
            #expect(app.$creator.id == nil)
        }

        @Test("Init with creatorID sets the @OptionalParent's id")
        func explicitCreator() {
            let creatorID = UUID()
            let app = WatchedApp(
                appStoreId: 123,
                bundleId: "com.example",
                name: "Example",
                iconURL: nil,
                creatorID: creatorID
            )
            #expect(app.$creator.id == creatorID)
        }

        @Test("Existing init signature still compiles (backwards-compat)")
        func existingSignatureCompiles() {
            // The AppService caller writes:
            //   WatchedApp(id:, appStoreId:, bundleId:, name:, iconURL:, primaryGenreId:)
            // Adding a new param at the end with a default value must
            // not break this call site. If this test fails to compile,
            // the M1.8 migration broke the existing service-layer
            // contract — M1.10 will need to update the caller before
            // landing the activation.
            _ = WatchedApp(
                id: UUID(),
                appStoreId: 1,
                bundleId: "x",
                name: "x",
                iconURL: nil,
                primaryGenreId: 6014
            )
        }
    }

    // ── Keyword ──────────────────────────────────────────────────────

    @Suite("Keyword")
    struct KeywordTests {

        @Test("Init without creatorID leaves creator nil")
        func defaultNilCreator() {
            let kw = Keyword(term: "habit tracker", countryCode: "US")
            #expect(kw.$creator.id == nil)
        }

        @Test("Init with creatorID sets the @OptionalParent's id")
        func explicitCreator() {
            let creatorID = UUID()
            let kw = Keyword(term: "habit tracker", countryCode: "US", creatorID: creatorID)
            #expect(kw.$creator.id == creatorID)
        }

        @Test("countryCode is still lowercased (existing behavior preserved)")
        func countryCodeNormalized() {
            let kw = Keyword(term: "x", countryCode: "DE", creatorID: nil)
            #expect(kw.countryCode == "de")
        }

        @Test("Existing init signature still compiles (backwards-compat)")
        func existingSignatureCompiles() {
            // KeywordService.create writes:
            //   Keyword(term:, countryCode:)
            // Same backwards-compat concern as WatchedApp's test.
            _ = Keyword(term: "x", countryCode: "us")
        }
    }
}
