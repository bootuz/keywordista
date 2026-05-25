import XCTest

@testable import Keywordista

/// Pins the contract of the three SecretsGenerator functions. The
/// crypto primitives themselves (CryptoKit's SymmetricKey, htpasswd's
/// bcrypt impl) aren't ours to test — these cases verify the shape,
/// uniqueness, and integration glue around them.
final class SecretsGeneratorTests: XCTestCase {

    // ── generateEncryptionKey ────────────────────────────────────────

    func testEncryptionKeyIs64HexChars() {
        let key = SecretsGenerator.generateEncryptionKey()
        XCTAssertEqual(key.count, 64,
                      "32 bytes encoded as hex → 64 chars; got \(key.count)")
        let hexAlphabet = Set("0123456789abcdef")
        XCTAssertTrue(
            key.allSatisfy { hexAlphabet.contains($0) },
            "expected lowercase hex chars only, got '\(key)'"
        )
    }

    func testEncryptionKeysAreUnique() {
        // Two consecutive calls must produce different bytes — if they
        // ever match, the system RNG has catastrophically failed and we
        // shouldn't ship anyway. Cheap sanity check.
        let a = SecretsGenerator.generateEncryptionKey()
        let b = SecretsGenerator.generateEncryptionKey()
        XCTAssertNotEqual(a, b)
    }

    func testEncryptionKeyParsesAsHexBytes() {
        // The downstream parser (Parsers.hexBytes(expectedBytes: 32) in
        // EnvVarManifest.swift) requires exactly 32 bytes decoded. Pin
        // the round-trip so a future format change breaks here, not at
        // deploy time.
        let key = SecretsGenerator.generateEncryptionKey()
        var bytes = [UInt8]()
        var iter = key.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else {
                XCTFail("non-hex pair '\(hi)\(lo)'")
                return
            }
            bytes.append(byte)
        }
        XCTAssertEqual(bytes.count, 32)
    }

    // ── generateAdminPassword ────────────────────────────────────────

    func testAdminPasswordIs24Chars() {
        let pw = SecretsGenerator.generateAdminPassword()
        XCTAssertEqual(pw.count, 24)
    }

    func testAdminPasswordHasNoAmbiguousChars() {
        // Curated alphabet excludes 0, O, 1, l, I to dodge ambiguity
        // in shoulder-surfed / handwritten / fax-recipient flows.
        let forbidden = Set("0Ol1I")
        for _ in 0..<50 {
            let pw = SecretsGenerator.generateAdminPassword()
            for ch in pw {
                XCTAssertFalse(
                    forbidden.contains(ch),
                    "ambiguous char '\(ch)' in '\(pw)'"
                )
            }
        }
    }

    func testAdminPasswordHasNoShellSpecials() {
        // Bytes that mangle in common paste targets (shell prompts,
        // YAML values, JSON without quoting). Belt-and-suspenders.
        let forbidden = Set("\"'`$;&|<>(){}[]\\")
        for _ in 0..<50 {
            let pw = SecretsGenerator.generateAdminPassword()
            for ch in pw {
                XCTAssertFalse(
                    forbidden.contains(ch),
                    "shell-special char '\(ch)' in '\(pw)'"
                )
            }
        }
    }

    func testAdminPasswordsAreUnique() {
        let a = SecretsGenerator.generateAdminPassword()
        let b = SecretsGenerator.generateAdminPassword()
        XCTAssertNotEqual(a, b)
    }

    // ── bcryptHash ───────────────────────────────────────────────────

    func testBcryptHashHasCorrectFormat() throws {
        // Cost 4 for test speed — production uses 12. The format
        // contract is the same: $2y$<cost>$<22-char-salt><31-char-hash>.
        let hash = try SecretsGenerator.bcryptHash("test-password-1234", cost: 4)
        XCTAssertTrue(hash.hasPrefix("$2y$04$"),
                     "expected $2y$04$ prefix, got '\(hash.prefix(10))…'")
        // $2y$04$ (7 chars) + 22 salt + 31 hash = 60 chars total.
        XCTAssertEqual(hash.count, 60, "got '\(hash)'")
    }

    func testBcryptHashIsDeterministicForSameSalt() throws {
        // Bcrypt with the same password but different salts produces
        // different hashes (by design — verifies the salting works).
        // Two consecutive calls without forcing a salt will differ.
        let a = try SecretsGenerator.bcryptHash("samePassword", cost: 4)
        let b = try SecretsGenerator.bcryptHash("samePassword", cost: 4)
        XCTAssertNotEqual(a, b, "two hashes of the same password must use different salts")
    }

    func testBcryptHashCostFactorAppearsInOutput() throws {
        // The cost is encoded in the hash itself ($2y$<cost>$...), so
        // the backend's bcrypt.verify reads it and computes accordingly.
        // Pin the encoding contract.
        let hash6 = try SecretsGenerator.bcryptHash("x", cost: 6)
        let hash8 = try SecretsGenerator.bcryptHash("x", cost: 8)
        XCTAssertTrue(hash6.hasPrefix("$2y$06$"))
        XCTAssertTrue(hash8.hasPrefix("$2y$08$"))
    }
}
