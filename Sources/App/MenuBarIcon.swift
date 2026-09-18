//  MenuBarIcon.swift — a glyph that isn't Apple's.
//
//  The obvious SF Symbol for this app is `rectangle.on.rectangle`, which is
//  exactly the symbol macOS already uses for Screen Mirroring — so the two sat
//  side by side in the menu bar looking identical. This draws a screen with a
//  reconnect arrow curling out of it instead: same subject, unmistakably not the
//  system's icon.
//
//  Drawn rather than an SF Symbol so it can't collide with a system glyph again,
//  and as a template image so macOS tints it for light and dark menu bars.

import AppKit

enum MenuBarIcon {

    static let connected = make(state: .connected)
    static let disconnected = make(state: .disconnected)
    static let working = make(state: .working)

    private enum State { case connected, disconnected, working }

    private static func make(state: State) -> NSImage {
        // 18pt is the menu bar's usable height; everything is drawn to fit it.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // The screen: a rounded rectangle sitting slightly low and left,
            // leaving the top-right free for the arrow.
            let screen = NSRect(x: 1.5, y: 4.0, width: 12.0, height: 9.0)
            let body = NSBezierPath(roundedRect: screen, xRadius: 1.8, yRadius: 1.8)
            body.lineWidth = 1.5

            switch state {
            case .connected:
                // Filled reads as "live" at a glance, even at this size.
                body.fill()
            case .disconnected, .working:
                body.stroke()
            }

            // A little stand, so it reads as a display rather than a card.
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 5.5, y: 3.0))
            stand.line(to: NSPoint(x: 9.5, y: 3.0))
            stand.lineWidth = 1.5
            stand.lineCapStyle = .round
            stand.stroke()

            // The reconnect arrow: an arc curling clockwise over the top-right
            // corner, with a solid head. This is the part Apple's glyph lacks.
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 12.5, y: 12.5), radius: 4.2,
                          startAngle: 200, endAngle: 20, clockwise: true)
            arc.lineWidth = 1.7
            arc.lineCapStyle = .round
            arc.stroke()

            let head = NSBezierPath()
            head.move(to: NSPoint(x: 16.9, y: 14.5))
            head.line(to: NSPoint(x: 16.1, y: 10.9))
            head.line(to: NSPoint(x: 13.6, y: 13.1))
            head.close()
            head.fill()

            // No slash: one drawn across the whole glyph tangles with the arrow
            // and turns to mush at 18pt. Filled versus outlined already reads
            // clearly at a glance, and "working" is told apart by its pulse.
            return true
        }
        image.isTemplate = true      // follow the menu bar's light/dark tint
        image.accessibilityDescription = {
            switch state {
            case .connected:    return "Sidecar connected"
            case .disconnected: return "Sidecar not connected"
            case .working:      return "Reconnecting"
            }
        }()
        return image
    }
}
