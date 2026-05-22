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
        )
    ]
)
