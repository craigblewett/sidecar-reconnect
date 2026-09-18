//  ArrangementWindow.swift — drag the screens around, like System Settings.
//
//  A menu of "left of / right of" is fine for one tablet and tedious for three
//  screens. This draws them to scale and lets them be dragged, which is how
//  everyone already expects to arrange displays.
//
//  The view works directly in macOS's global display coordinates — origin at the
//  top-left of the main screen, y increasing downward — and only scales when it
//  comes to draw. That keeps the arithmetic honest: what's dragged is the real
//  rectangle, and the only conversion is for pixels on screen.

import AppKit
import CoreGraphics

final class ArrangementWindowController: NSWindowController {

    private static var shared: ArrangementWindowController?

    static func present() {
        if let existing = shared, let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            (window.contentView as? ArrangementView)?.reload()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ArrangementView(frame: NSRect(x: 0, y: 0, width: 620, height: 400))
        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Arrange Displays"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        let controller = ArrangementWindowController(window: window)
        shared = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class ArrangementView: NSView {

    private struct Tile {
        let id: CGDirectDisplayID
        let name: String
        let isMain: Bool
        /// In global display coordinates — the real thing, not a drawing rect.
        var bounds: CGRect
    }

    private var tiles: [Tile] = []
    private var draggingIndex: Int?
    private var grabOffset: CGPoint = .zero

    /// Global-coordinate distance within which edges snap together. macOS won't
    /// leave gaps between screens, so landing "close enough" should mean
    /// "touching" rather than being quietly shoved somewhere else afterwards.
    private let snapDistance: CGFloat = 60

    override var isFlipped: Bool { true }   // match display space: y downward

    override init(frame: NSRect) {
        super.init(frame: frame)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        tiles = DisplayArrangement.all().map {
            Tile(id: $0.id, name: $0.name, isMain: $0.isMain, bounds: $0.bounds)
        }
        needsDisplay = true
    }

    // MARK: Scaling between display space and the view

    private var union: CGRect {
        tiles.dropFirst().reduce(tiles.first?.bounds ?? .zero) { $0.union($1.bounds) }
    }

    private var scale: CGFloat {
        let box = union
        guard box.width > 0, box.height > 0 else { return 1 }
        let inset = bounds.insetBy(dx: 40, dy: 40)
        return min(inset.width / box.width, inset.height / box.height)
    }

    private func viewRect(for rect: CGRect) -> CGRect {
        let box = union, s = scale
        let offsetX = (bounds.width - box.width * s) / 2
        let offsetY = (bounds.height - box.height * s) / 2
        return CGRect(x: (rect.origin.x - box.origin.x) * s + offsetX,
                      y: (rect.origin.y - box.origin.y) * s + offsetY,
                      width: rect.width * s, height: rect.height * s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        for (index, tile) in tiles.enumerated() {
            let rect = viewRect(for: tile.bounds).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

            (draggingIndex == index ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                                    : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (draggingIndex == index ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = draggingIndex == index ? 2.5 : 1.5
            path.stroke()

            // The main screen carries the menu bar, which is the cue everyone
            // uses to recognise it at a glance.
            if tile.isMain {
                let strip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 5)
                NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(rect: strip).fill()
            }

            let label = "\(tile.name)\n\(Int(tile.bounds.width)) × \(Int(tile.bounds.height))"
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
            let size = (label as NSString).boundingRect(
                with: CGSize(width: rect.width - 8, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: attributes).size
            (label as NSString).draw(
                in: CGRect(x: rect.minX + 4, y: rect.midY - size.height / 2,
                           width: rect.width - 8, height: size.height),
                withAttributes: attributes)
        }

        let hint = tiles.count < 2
            ? "Only one screen connected."
            : "Drag a screen to move it. The strip marks the main display."
        (hint as NSString).draw(
            at: CGPoint(x: 12, y: bounds.height - 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Topmost first, so the one drawn last is the one grabbed.
        for index in tiles.indices.reversed() where viewRect(for: tiles[index].bounds).contains(point) {
            // The main display defines the origin everything else is placed
            // against; moving it just shifts the whole arrangement.
            guard !tiles[index].isMain else { continue }
            draggingIndex = index
            let rect = viewRect(for: tiles[index].bounds)
            grabOffset = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = draggingIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        let box = union, s = scale
        let offsetX = (bounds.width - box.width * s) / 2
        let offsetY = (bounds.height - box.height * s) / 2
        // Back out of view coordinates into the real display space.
        tiles[index].bounds.origin = CGPoint(
            x: (point.x - grabOffset.x - offsetX) / s + box.origin.x,
            y: (point.y - grabOffset.y - offsetY) / s + box.origin.y)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = draggingIndex else { return }
        draggingIndex = nil
        snap(index)
        let tile = tiles[index]
        DisplayArrangement.move(tile.id, to: tile.bounds.origin)
        // Ask the system what it actually did, rather than trusting our guess.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reload() }
    }

    /// Pull the dragged screen's edges onto a neighbour's, so screens end up
    /// touching rather than overlapping or leaving a gap.
    private func snap(_ index: Int) {
        var rect = tiles[index].bounds
        for (other, tile) in tiles.enumerated() where other != index {
            let neighbour = tile.bounds

            // Horizontal: sit against the left or right edge.
            for (candidate, reference) in [(neighbour.maxX, rect.minX), (neighbour.minX - rect.width, rect.minX)]
            where abs(candidate - reference) < snapDistance {
                rect.origin.x = candidate
            }
            // Vertical: sit above or below.
            for (candidate, reference) in [(neighbour.maxY, rect.minY), (neighbour.minY - rect.height, rect.minY)]
            where abs(candidate - reference) < snapDistance {
                rect.origin.y = candidate
            }
            // Line the other axis up when nearly aligned, so edges are flush.
            if abs(rect.minY - neighbour.minY) < snapDistance { rect.origin.y = neighbour.minY }
            if abs(rect.minX - neighbour.minX) < snapDistance { rect.origin.x = neighbour.minX }
        }
        tiles[index].bounds = rect
    }
}
