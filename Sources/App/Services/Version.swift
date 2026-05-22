import Foundation

// The running service's version. CI replaces the literal below before
// building a tagged release; dev / source builds stay at "0.0.0" so the
// menubar app can tell "dev install" apart from any tagged release.
//
// Manual bump:
//   change the constant, rebuild.
// CI bump (sed, in .github/workflows/release-service.yml):
//   sed -i '' 's/static let current = "0.0.0"/static let current = "X.Y.Z"/' \
//     Sources/App/Services/Version.swift
enum Version {
    static let current = "0.0.0"
}
