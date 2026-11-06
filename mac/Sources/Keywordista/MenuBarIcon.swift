import AppKit

/// The menubar glyph: the app icon's radar, drawn as a template image so
/// macOS tints it for light/dark menubars and the selected state.
///
/// Why drawn in code instead of shipped as a PDF asset: the SPM target has
/// no resource bundle, and the status variants (badge, slash) are cheap to
/// compose here but would each need their own file otherwise. The shape
/// follows web/src/components/RadarMark.svelte (same 1024-unit design
/// space), with thicker strokes and no glow because the menubar draws it
/// at 18 pt.
enum MenuBarIcon {
    enum Variant: Equatable {
        case normal
        /// A server update is waiting — radar plus a dot badge.
        case updateAvailable
        /// Some instances are unhealthy — radar at reduced strength.
        case degraded
        /// Every instance is down — dimmed radar with a slash through it.
        case down
    }

    /// Health wins over the update badge: a down or flaky server is the
    /// thing the user needs to see first. Matches the previous SF Symbol
    /// mapping, where only the green state showed the update badge.
    static func variant(health: RollupStatus, hasUpdateNotification: Bool) -> Variant {
        switch health {
        case .green: return hasUpdateNotification ? .updateAvailable : .normal
        case .yellow: return .degraded
        case .red: return .down
        }
    }

    static let pointSize = NSSize(width: 18, height: 18)

    /// Built once per variant; the label re-renders on every health tick.
    static func image(for variant: Variant) -> NSImage {
        switch variant {
        case .normal: return normal
        case .updateAvailable: return updateAvailable
        case .degraded: return degraded
        case .down: return down
        }
    }

    private static let normal = make(.normal)
    private static let updateAvailable = make(.updateAvailable)
    private static let degraded = make(.degraded)
    private static let down = make(.down)

    // The radar spans 184…840 in the 1024-unit design space (656 units),
    // the same crop the SPA mark uses.
    private static let designOrigin: CGFloat = 184
    private static let designSpan: CGFloat = 656

    private static func make(_ variant: Variant) -> NSImage {
        let image = NSImage(size: pointSize, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            ctx.saveGState()
            if variant == .degraded || variant == .down {
                ctx.setAlpha(0.45)
            }
            let scale = rect.width / designSpan
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -designOrigin, y: -designOrigin)
            drawRadar(in: ctx)
            ctx.restoreGState()

            switch variant {
            case .updateAvailable:
                // Knock a ring out around the badge so it reads as separate
                // from the radar rings behind it.
                let badge = CGPoint(x: rect.maxX - 3.5, y: rect.minY + 3.5)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: badge.x - 4.5, y: badge.y - 4.5, width: 9, height: 9))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: badge.x - 3, y: badge.y - 3, width: 6, height: 6))
            case .down:
                ctx.setLineCap(.round)
                ctx.setBlendMode(.clear)
                ctx.setLineWidth(4)
                ctx.move(to: CGPoint(x: 2.5, y: 2.5))
                ctx.addLine(to: CGPoint(x: rect.maxX - 2.5, y: rect.maxY - 2.5))
                ctx.strokePath()
                ctx.setBlendMode(.normal)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: 2.5, y: 2.5))
                ctx.addLine(to: CGPoint(x: rect.maxX - 2.5, y: rect.maxY - 2.5))
                ctx.strokePath()
            case .normal, .degraded:
                break
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Keywordista"
        return image
    }

    /// Draws in design units (y down, like the SVG). Only alpha matters in
    /// a template image, so everything is black at varying opacity.
    private static func drawRadar(in ctx: CGContext) {
        let c = CGPoint(x: 512, y: 512)
        let black = NSColor.black

        // Rings: thicker than the SVG's 18 units so they survive at 18 pt.
        ctx.setStrokeColor(black.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(38)
        for r: CGFloat in [108, 206, 296] {
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // Sweep wedge from -105° to -40°, fading in toward the leading edge.
        let r: CGFloat = 316
        let start = CGFloat(-105) * .pi / 180
        let end = CGFloat(-40) * .pi / 180
        let lead = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
        let tail = CGPoint(x: c.x + r * cos(start), y: c.y + r * sin(start))
        ctx.saveGState()
        ctx.move(to: c)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.closePath()
        ctx.clip()
        if let gradient = CGGradient(
            colorSpace: CGColorSpaceCreateDeviceGray(),
            colorComponents: [0, 0, 0, 0.6],
            locations: [0, 1],
            count: 2
        ) {
            ctx.drawLinearGradient(gradient, start: tail, end: lead, options: [])
        }
        ctx.restoreGState()

        // Leading edge.
        ctx.setStrokeColor(black.cgColor)
        ctx.setLineWidth(52)
        ctx.setLineCap(.round)
        ctx.move(to: c)
        ctx.addLine(to: lead)
        ctx.strokePath()

        // Blips: two dim ones from the watchlist, one bright hit, the centre.
        func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ alpha: CGFloat) {
            ctx.setFillColor(black.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        dot(325, 620, 40, 0.55)
        dot(568, 609, 36, 0.5)
        dot(636, 335, 58, 1)
        dot(512, 512, 50, 1)
    }
}
