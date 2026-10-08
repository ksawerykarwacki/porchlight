import AppKit
import PorchlightCore
import SwiftUI

/// The menu-bar icon: a small wall lantern in the menu bar's own colour, like its neighbours.
/// Only the light inside it is coloured.
///
/// - Idle: unlit, an empty glass.
/// - Waiting: the glass glows amber.
/// - Overdue: the glass glows red and throws rays.
///
/// The shape changes with the colour (empty, lit, lit with rays), so the three states stay
/// distinguishable without colour.
public enum StatusIcon {
    public static let size = NSSize(width: 18, height: 18)

    /// The colour of the light, or nil when the lantern is unlit.
    static func tint(for status: MenuBarStatus) -> NSColor? {
        switch status {
        case .idle: nil
        case .waiting: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.14, alpha: 1)
        case .overdue: NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.27, alpha: 1)
        }
    }

    static func showsRays(for status: MenuBarStatus) -> Bool {
        if case .overdue = status { return true }
        return false
    }

    /// - Parameter onDarkBar: whether the menu bar's own icons are light (a dark bar). Only matters
    ///   for a lit lantern: an unlit one is a template image, which the menu bar colours itself.
    @MainActor
    public static func image(for status: MenuBarStatus, onDarkBar: Bool = true) -> NSImage {
        let light = tint(for: status)
        let rays = showsRays(for: status)
        let ink: NSColor = light == nil ? .black : (onDarkBar ? .white : NSColor(calibratedWhite: 0, alpha: 0.85))
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, ink: ink, light: light, rays: rays)
            return true
        }
        // A template image cannot carry the light's colour, so a lit lantern draws its own ink.
        image.isTemplate = light == nil
        image.accessibilityDescription = status.summary
        return image
    }

    /// Draws the lantern in an 18-unit square scaled to `rect`: the frame in `ink`, and, when
    /// `light` is given, the glass filled with it, plus rays in the same colour when `rays`.
    static func draw(in rect: NSRect, ink: NSColor, light: NSColor?, rays: Bool) {
        let unit = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        ink.setStroke()
        ink.setFill()

        // Wall plate and the arm that holds the lantern.
        let arm = NSBezierPath()
        arm.lineWidth = 1.3 * unit
        arm.lineCapStyle = .round
        arm.lineJoinStyle = .round
        arm.move(to: point(2.6, 13.4))
        arm.line(to: point(2.6, 17.2))
        arm.move(to: point(2.6, 16.1))
        arm.line(to: point(7.4, 16.1))
        arm.curve(to: point(9.6, 14.3), controlPoint1: point(8.9, 16.1), controlPoint2: point(9.6, 15.4))
        arm.stroke()

        // Roof.
        let roof = NSBezierPath()
        roof.move(to: point(5.4, 12.3))
        roof.line(to: point(9.6, 14.7))
        roof.line(to: point(13.8, 12.3))
        roof.close()
        roof.lineJoinStyle = .round
        roof.lineWidth = 0.9 * unit
        roof.fill()
        roof.stroke()

        // Glass body, wider at the top.
        let body = NSBezierPath()
        body.move(to: point(6.3, 11.6))
        body.line(to: point(12.9, 11.6))
        body.line(to: point(11.7, 4.9))
        body.line(to: point(7.5, 4.9))
        body.close()
        body.lineJoinStyle = .round
        body.lineWidth = 1.2 * unit
        if let light {
            // The light fills the glass; the frame stays in ink around it, so the lantern keeps
            // its outline and the colour reads as a light inside it.
            light.setFill()
            body.fill()
            ink.setFill()
        }
        body.stroke()

        // Base and finial.
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 7.9 * unit, y: rect.minY + 3.2 * unit, width: 3.4 * unit, height: 1.5 * unit),
                     xRadius: 0.5 * unit, yRadius: 0.5 * unit).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 8.9 * unit, y: rect.minY + 1.6 * unit, width: 1.4 * unit, height: 1.4 * unit)).fill()

        guard rays, let light else { return }
        light.setStroke()
        let glow = NSBezierPath()
        glow.lineWidth = 1.1 * unit
        glow.lineCapStyle = .round
        for (from, to) in [
            (point(14.6, 10.6), point(16.4, 11.6)),
            (point(14.6, 8.2), point(16.8, 8.2)),
            (point(14.3, 5.8), point(16.0, 4.8)),
            (point(4.8, 8.2), point(2.8, 8.2)),
            (point(5.2, 5.8), point(3.6, 4.8)),
        ] {
            glow.move(to: from)
            glow.line(to: to)
        }
        glow.stroke()
    }
}

extension StatusIcon {
    /// The app's own icon, as shown on notifications and in System Settings: the lit lantern on a
    /// night-blue tile, with its glow on the wall behind it.
    public static func drawAppIcon(in rect: NSRect) {
        let side = rect.width
        // macOS icons sit inside their canvas with a margin and a continuous-corner tile.
        let tile = rect.insetBy(dx: side * 0.098, dy: side * 0.098)
        let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.36, alpha: 1),
            NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.17, alpha: 1),
        ])?.draw(in: tile, angle: -90)

        // The light the lantern throws.
        let centre = NSPoint(x: tile.midX + tile.width * 0.03, y: tile.midY - tile.height * 0.04)
        NSGradient(colors: [
            NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.22, alpha: 0.62),
            NSColor(calibratedRed: 1.0, green: 0.60, blue: 0.15, alpha: 0.20),
            NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.10, alpha: 0),
        ], atLocations: [0, 0.45, 1], colorSpace: .genericRGB)?
            .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: tile.width * 0.52, options: [])
        NSGraphicsContext.restoreGraphicsState()

        let lantern = tile.insetBy(dx: tile.width * 0.14, dy: tile.width * 0.14)
        // On the tile the whole lantern is warm: a pale frame around the amber light.
        draw(in: lantern, ink: NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.80, alpha: 1),
             light: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.14, alpha: 1), rays: false)
    }

    /// The app icon as a bitmap of exactly `pixels` by `pixels`.
    @MainActor
    public static func appIconBitmap(pixels: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}

/// What sits in the menu bar: the icon, and the count when something waits.
public struct StatusLabel: View {
    let status: MenuBarStatus
    /// The menu bar is dark or light depending on the wallpaper behind it, not only on the
    /// system appearance; the label's own colour scheme follows the bar.
    @Environment(\.colorScheme) private var colorScheme

    public init(status: MenuBarStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.image(for: status, onDarkBar: colorScheme == .dark))
            if let badge = status.badge {
                Text(badge)
            }
        }
        .help(status.summary)
        .accessibilityLabel(status.summary)
    }
}
