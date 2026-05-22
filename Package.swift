// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "keywordista",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.0"),
        .package(url: "https://github.com/vapor/queues.git", from: "1.15.0"),
        .package(url: "https://github.com/m-barthelemy/vapor-queues-fluent-driver.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesFluentDriver", package: "vapor-queues-fluent-driver"),
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
            ],
            path: "Tests/AppTests"
        ),
    ]
)
