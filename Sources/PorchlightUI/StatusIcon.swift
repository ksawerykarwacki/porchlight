import AppKit
import PorchlightCore
import SwiftUI

/// The menu-bar icon: a small wall lantern.
///
/// - Idle: an unlit outline, drawn as a template so the menu bar colours it.
/// - Waiting: lit amber.
/// - Overdue: lit red, with rays around it.
///
/// The shape changes with the colour (unlit, lit, lit with rays), so the three states stay
/// distinguishable without colour.
public enum StatusIcon {
    public static let size = NSSize(width: 18, height: 18)

    static func tint(for status: MenuBarStatus) -> NSColor? {
        switch status {
        case .idle: nil
        case .waiting: NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.16, alpha: 1)
        case .overdue: NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.22, alpha: 1)
        }
    }

    static func showsRays(for status: MenuBarStatus) -> Bool {
        if case .overdue = status { return true }
        return false
    }

    @MainActor
    public static func image(for status: MenuBarStatus) -> NSImage {
        let tint = tint(for: status)
        let rays = showsRays(for: status)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, ink: tint ?? .black, lit: tint != nil, rays: rays)
            return true
        }
        // A template image takes the menu bar's own colour; a lit lantern keeps its own.
        image.isTemplate = tint == nil
        image.accessibilityDescription = status.summary
        return image
    }

    /// Draws the lantern in an 18-unit square scaled to `rect`: in `ink`, with a filled glass and a
    /// flame when `lit`, and rays around it when `rays`.
    static func draw(in rect: NSRect, ink: NSColor, lit: Bool, rays: Bool) {
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
        if lit {
            body.fill()
            body.stroke()
            // The flame: a pale core, so the lantern reads as lit rather than just coloured.
            NSColor(calibratedWhite: 1, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 8.5 * unit, y: rect.minY + 6.4 * unit, width: 2.2 * unit, height: 3.6 * unit)).fill()
            ink.setFill()
        } else {
            body.stroke()
        }

        // Base and finial.
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 7.9 * unit, y: rect.minY + 3.2 * unit, width: 3.4 * unit, height: 1.5 * unit),
                     xRadius: 0.5 * unit, yRadius: 0.5 * unit).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 8.9 * unit, y: rect.minY + 1.6 * unit, width: 1.4 * unit, height: 1.4 * unit)).fill()

        guard rays else { return }
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

/// What sits in the menu bar: the icon, and the count when something waits.
public struct StatusLabel: View {
    let status: MenuBarStatus

    public init(status: MenuBarStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.image(for: status))
            if status.count > 0 {
                Text("\(status.count)")
            }
        }
        .help(status.summary)
        .accessibilityLabel(status.summary)
    }
}
