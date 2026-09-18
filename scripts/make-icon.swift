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

    // The two screens, drawn in one transparency layer so the gap between them
    // can be punched out without erasing the gradient underneath.
    let stroke = 38 * u
    let gap = 30 * u
    let back = CGRect(x: 250 * u, y: 430 * u, width: 400 * u, height: 300 * u)
    let front = CGRect(x: 392 * u, y: 286 * u, width: 400 * u, height: 300 * u)
    let radius = 52 * u

    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(stroke)
    cg.addPath(CGPath(roundedRect: back.insetBy(dx: stroke / 2, dy: stroke / 2),
                      cornerWidth: radius - stroke / 2,
                      cornerHeight: radius - stroke / 2, transform: nil))
    cg.strokePath()

    // Clear a margin around the front screen so the two shapes stay legible
    // where they overlap, exactly as the SF Symbol does.
    cg.setBlendMode(.destinationOut)
    cg.setFillColor(NSColor.black.cgColor)
    cg.addPath(CGPath(roundedRect: front.insetBy(dx: -gap, dy: -gap),
                      cornerWidth: radius + gap, cornerHeight: radius + gap,
                      transform: nil))
    cg.fillPath()

    cg.setBlendMode(.normal)
    cg.setFillColor(NSColor.white.cgColor)
    cg.addPath(CGPath(roundedRect: front, cornerWidth: radius,
                      cornerHeight: radius, transform: nil))
    cg.fillPath()

    cg.endTransparencyLayer()

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
