import XCTest

@testable import Keywordista

/// Pins which radar variant the menubar shows for each health/update
/// combination, and that the glyph stays a template image (otherwise it
/// renders black on a dark menubar instead of following the system tint).
final class MenuBarIconTests: XCTestCase {

    func testHealthyWithoutUpdateIsPlainRadar() {
        XCTAssertEqual(MenuBarIcon.variant(health: .green, hasUpdateNotification: false), .normal)
    }

    func testHealthyWithUpdateShowsBadge() {
        XCTAssertEqual(MenuBarIcon.variant(health: .green, hasUpdateNotification: true), .updateAvailable)
    }

    /// Health problems outrank the update badge.
    func testUnhealthyStatesIgnoreUpdateBadge() {
        for update in [false, true] {
            XCTAssertEqual(MenuBarIcon.variant(health: .yellow, hasUpdateNotification: update), .degraded)
            XCTAssertEqual(MenuBarIcon.variant(health: .red, hasUpdateNotification: update), .down)
        }
    }

    func testEveryVariantIsAnEighteenPointTemplate() {
        for variant: MenuBarIcon.Variant in [.normal, .updateAvailable, .degraded, .down] {
            let image = MenuBarIcon.image(for: variant)
            XCTAssertTrue(image.isTemplate, "\(variant)")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(variant)")
        }
    }
}
