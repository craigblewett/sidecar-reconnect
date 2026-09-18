//  DisplayArrangement.swift — read and set where every screen sits.
//
//  macOS puts all displays in one coordinate space, and a display's "position"
//  is just the origin of its rectangle in that space. Which means the same
//  CGConfigureDisplayOrigin call that places the Android tablet places a Sidecar
//  iPad or an HDMI monitor — there's nothing special about the virtual one.
//
//  Worth knowing: macOS remembers where physical screens go, but not the
//  virtual one, which it treats as a new display every time it appears.

import AppKit
import CoreGraphics

enum DisplayArrangement {

    struct Screen {
        let id: CGDirectDisplayID
        let name: String
        let bounds: CGRect
        let isMain: Bool

        var summary: String {
            "\(name) — \(Int(bounds.width))×\(Int(bounds.height))"
                + (isMain ? " (main)" : " at \(Int(bounds.origin.x)), \(Int(bounds.origin.y))")
        }
    }

    enum Side: String, CaseIterable {
        case left, right, above, below
        var label: String {
            switch self {
            case .left:  return "Left of"
            case .right: return "Right of"
            case .above: return "Above"
            case .below: return "Below"
            }
        }
    }

    /// Every display macOS currently has, main first.
    static func all() -> [Screen] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }

        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            Screen(id: id, name: name(of: id), bounds: CGDisplayBounds(id), isMain: id == main)
        }.sorted { $0.isMain && !$1.isMain }
    }

    /// NSScreen knows the human-readable name; CoreGraphics doesn't. They're
    /// matched on the display ID NSScreen carries in its device description.
    private static func name(of id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               CGDirectDisplayID(number.uint32Value) == id {
                return screen.localizedName
            }
        }
        return "Display \(id)"
    }

    /// Put `moving` at an absolute position — what dragging produces.
    @discardableResult
    static func move(_ moving: CGDirectDisplayID, to origin: CGPoint) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config = config else {
            Log.write("couldn't begin a display configuration")
            return false
        }
        guard CGConfigureDisplayOrigin(config, moving, Int32(origin.x), Int32(origin.y)) == .success,
              CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            Log.write("couldn't move \(name(of: moving))")
            return false
        }
        Log.write("moved \(name(of: moving)) to \(Int(origin.x)), \(Int(origin.y))")
        return true
    }

    /// Put `moving` on the given side of `anchor`. Both are looked up fresh,
    /// since bounds change as other displays move around.
    @discardableResult
    static func place(_ moving: CGDirectDisplayID,
                      _ side: Side,
                      of anchor: CGDirectDisplayID) -> Bool {
        let anchorBounds = CGDisplayBounds(anchor)
        let size = CGDisplayBounds(moving).size
        let origin: CGPoint
        switch side {
        case .right: origin = CGPoint(x: anchorBounds.maxX, y: anchorBounds.minY)
        case .left:  origin = CGPoint(x: anchorBounds.minX - size.width, y: anchorBounds.minY)
        case .above: origin = CGPoint(x: anchorBounds.minX, y: anchorBounds.minY - size.height)
        case .below: origin = CGPoint(x: anchorBounds.minX, y: anchorBounds.maxY)
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config = config else {
            Log.write("couldn't begin a display configuration")
            return false
        }
        guard CGConfigureDisplayOrigin(config, moving, Int32(origin.x), Int32(origin.y)) == .success else {
            CGCancelDisplayConfiguration(config)
            Log.write("couldn't move display \(moving)")
            return false
        }
        // Permanently, so it survives until something moves it again — but note
        // macOS won't remember a virtual display's place across sessions.
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            Log.write("couldn't apply the new arrangement")
            return false
        }
        Log.write("moved \(name(of: moving)) \(side.rawValue) of \(name(of: anchor))")
        return true
    }
}
