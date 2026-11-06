// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "keywordista",
    platforms: [
        // macOS 15 floor comes from apple/apple-ads-platform-api-swift, which
        // declares it statically; the bundled server inherits it.
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.0"),
        // Postgres driver — added in M0.5 to support DATABASE_URL routing
        // (§4.10). Operator picks SQLite or Postgres at deploy time; both
        // drivers are linked in every build so the choice is purely runtime.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/queues.git", from: "1.15.0"),
        .package(url: "https://github.com/m-barthelemy/vapor-queues-fluent-driver.git", from: "2.0.0"),
        // ES256 JWT signing for App Store Connect API calls. swift-crypto is
        // already pinned transitively via Vapor; declaring it here just
        // exposes the `Crypto` product to the App target.
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"5.0.0"),
        // Apple's official Platform API v1 client (Campaign Management v5 is
        // retired 2027-01-26). Pinned exact: the package is generated from a
        // moving OpenAPI spec, so minor bumps can reshape generated types.
        .package(url: "https://github.com/apple/apple-ads-platform-api-swift", exact: "1.109.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesFluentDriver", package: "vapor-queues-fluent-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AppleAdsClient", package: "apple-ads-platform-api-swift"),
            ],
            path: "Sources/App",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=minimal"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                // M1.12: XCTVapor ships with the main vapor package
                // (no new repo dep). Powers real-HTTP integration
                // tests of the auth flow + admin gating.
                .product(name: "XCTVapor", package: "vapor"),
            ],
            path: "Tests/AppTests"
        ),
    ],
    // Tools 6.2 is required to resolve the Apple Ads package; keep Swift 5
    // language mode so the toolchain bump isn't also a Swift 6 migration.
    swiftLanguageModes: [.v5]
)
