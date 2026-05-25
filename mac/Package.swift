// swift-tools-version: 5.10
import PackageDescription

// SPM package for the Keywordista menubar app. Separate from the root
// Package.swift (which is the Vapor server) so the menubar app's macOS-only
// SwiftUI deps don't bleed into the cross-platform server build.
//
// The build flow is:
//   1. swift build (here in mac/) produces the SwiftUI binary
//   2. build-app.sh wraps that binary into Keywordista.app and copies in the
//      server binary + Public/ from the repo root
let package = Package(
    name: "Keywordista",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Keywordista",
            path: "Sources/Keywordista"
        ),
        // Unit tests for the menubar app. Scoped to pure-function regression
        // guards (the v0.3.5 spawn-env bug being the founding case) — full
        // end-to-end "launch the supervisor against a real server binary"
        // integration testing is a release-pipeline concern, not a CI unit
        // job. Keep this target small and fast.
        .testTarget(
            name: "KeywordistaTests",
            dependencies: ["Keywordista"],
            path: "Tests/KeywordistaTests"
        ),
    ]
)
