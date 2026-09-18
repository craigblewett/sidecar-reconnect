//  make-icon.swift — draws Resources/AppIcon.icns.
//
//  The icon is checked in, but it's generated rather than hand-drawn so it can
//  be regenerated or adjusted without a design tool:
//
//      swift scripts/make-icon.swift
//
//  The artwork is two overlapping screens — the same metaphor as the menu bar
//  glyph (`rectangle.on.rectangle`), so the app looks like itself in Finder.
//  Deliberately only two shapes: at 16pt anything finer turns to mush.

import AppKit
import Foundation

private let canvas: CGFloat = 1024

/// Everything is expressed against a 1024pt canvas and scaled, so each size is
/// drawn at full detail rather than resampled from one bitmap.
private func draw(size pixels: Int) -> Data {
    let side = CGFloat(pixels)
    let u = side / canvas          // one canvas point, in this bitmap's pixels

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not allocate a \(pixels)px bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext

    // The rounded square macOS draws app icons in: inset from the canvas so the
    // icon sits correctly next to system ones.
    let plate = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * u,
                           cornerHeight: 185 * u, transform: nil)

    cg.saveGState()
    cg.addPath(platePath)
    cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    // Blue to indigo, top to bottom — reads as a display, and stays distinct
    // from the grey of most utility icons.
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(colorSpace: space, components: [0.36, 0.64, 1.00, 1.0])!,
        CGColor(colorSpace: space, components: [0.29, 0.25, 0.83, 1.0])!,
    ] as CFArray, locations: [0.0, 1.0])!
    cg.drawLinearGradient(gradient,
                          start: CGPoint(x: plate.midX, y: plate.maxY),
                          end: CGPoint(x: plate.midX, y: plate.minY),
                          options: [])
    cg.restoreGState()

    // A screen with a reconnect arrow curling over its shoulder — the same
    // motif as the menu bar glyph in Sources/App/MenuBarIcon.swift, and
    // deliberately *not* two overlapping rectangles, which is what macOS itself
    // uses for Screen Mirroring. Two near-identical icons side by side in the
    // menu bar helps nobody.
    cg.setFillColor(NSColor.white.cgColor)
    cg.setStrokeColor(NSColor.white.cgColor)

    // The screen.
    let screen = CGRect(x: 238 * u, y: 289 * u, width: 428 * u, height: 321 * u)
    cg.addPath(CGPath(roundedRect: screen, cornerWidth: 54 * u,
                      cornerHeight: 54 * u, transform: nil))
    cg.fillPath()

    // Its stand, so it reads as a display rather than a card.
    cg.setLineWidth(54 * u)
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: 380 * u, y: 253 * u))
    cg.addLine(to: CGPoint(x: 523 * u, y: 253 * u))
    cg.strokePath()

    // The arrow: an arc over the top-right, with a solid head.
    cg.setLineWidth(61 * u)
    cg.addArc(center: CGPoint(x: 630 * u, y: 592 * u), radius: 150 * u,
              startAngle: 200 * .pi / 180, endAngle: 20 * .pi / 180, clockwise: true)
    cg.strokePath()

    cg.move(to: CGPoint(x: 787 * u, y: 664 * u))
    cg.addLine(to: CGPoint(x: 759 * u, y: 535 * u))
    cg.addLine(to: CGPoint(x: 670 * u, y: 614 * u))
    cg.closePath()
    cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode the \(pixels)px bitmap")
    }
    return png
}

// MARK: - Write the iconset

let here = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()            // scripts/
    .deletingLastPathComponent()            // repo root
let resources = here.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (filename base, points, scale) — the set `iconutil` expects.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                              (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    try draw(size: points * scale).write(to: iconset.appendingPathComponent(name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// The .iconset is scratch; only the .icns is kept.
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
