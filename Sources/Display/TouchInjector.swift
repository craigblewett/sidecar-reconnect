//  TouchInjector.swift — turns the tablet's touches into macOS mouse events.
//
//  The tablet sends normalised coordinates (0…1) within its own screen plus an
//  action code; we map those onto the virtual display's bounds and post real
//  events, which is why this needs Accessibility permission.
//
//  Scope: one finger — move, click and drag. Side Screen's own handler adds a
//  two-finger state machine for scroll and pinch (AppDelegate.handleTouch, about
//  350 lines); porting that is the obvious next step and this deliberately does
//  not pretend to cover it.

import Foundation
import CoreGraphics
import ApplicationServices

final class TouchInjector {

    /// Action codes as the Side Screen wire protocol sends them.
    private enum Action {
        static let down = 0
        static let move = 1
        static let up = 2
    }

    private var isDown = false
    private var warnedAboutAccessibility = false

    /// - Parameters:
    ///   - x, y: normalised 0…1 within the tablet's view of the display.
    ///   - displayID: the virtual display, whose bounds we map onto. Read each
    ///     time rather than cached — the display moves when the user rearranges
    ///     screens in System Settings.
    func handle(x: Float, y: Float, action: Int, pointerCount: Int,
                x2: Float, y2: Float, on displayID: CGDirectDisplayID) {
        guard AXIsProcessTrusted() else {
            if !warnedAboutAccessibility {
                warnedAboutAccessibility = true
                Log.write("touch ignored — allow this app in System Settings › "
                        + "Privacy & Security › Accessibility")
            }
            return
        }

        // Two-finger gestures aren't implemented; swallow them rather than
        // treating a second finger as a stray click.
        guard pointerCount < 2 else { return }

        let bounds = CGDisplayBounds(displayID)
        let point = CGPoint(x: bounds.origin.x + CGFloat(x) * bounds.width,
                            y: bounds.origin.y + CGFloat(y) * bounds.height)

        switch action {
        case Action.down:
            post(.leftMouseDown, at: point)
            isDown = true
        case Action.move:
            post(isDown ? .leftMouseDragged : .mouseMoved, at: point)
        case Action.up:
            post(.leftMouseUp, at: point)
            isDown = false
        default:
            break
        }
    }

    /// Called when streaming stops, so a finger that was down when the tablet
    /// disconnected doesn't leave the mouse button stuck.
    func releaseIfNeeded(on displayID: CGDirectDisplayID) {
        guard isDown else { return }
        let bounds = CGDisplayBounds(displayID)
        post(.leftMouseUp, at: CGPoint(x: bounds.midX, y: bounds.midY))
        isDown = false
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        let button: CGMouseButton = .left
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }
}
