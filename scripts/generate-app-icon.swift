#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-app-icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create bitmap graphics context\n", stderr)
    exit(1)
}

bitmap.size = NSSize(width: pixels, height: pixels)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let iconRect = NSRect(x: 40, y: 40, width: 944, height: 944)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 224, yRadius: 224)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.86, alpha: 1.0),
    NSColor(calibratedRed: 0.06, green: 0.16, blue: 0.48, alpha: 1.0)
])!
gradient.draw(in: iconPath, angle: -45)

let highlight = NSBezierPath(
    roundedRect: NSRect(x: 82, y: 564, width: 860, height: 350),
    xRadius: 170,
    yRadius: 170
)
NSColor.white.withAlphaComponent(0.08).setFill()
highlight.fill()

let hangulAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 430, weight: .heavy),
    .foregroundColor: NSColor.white
]
let hangul = NSString(string: "가")
let hangulSize = hangul.size(withAttributes: hangulAttributes)
hangul.draw(
    at: NSPoint(x: 512 - hangulSize.width / 2 - 28, y: 286),
    withAttributes: hangulAttributes
)

let badgeRect = NSRect(x: 570, y: 132, width: 302, height: 142)
let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 71, yRadius: 71)
NSColor(calibratedRed: 0.16, green: 0.84, blue: 0.68, alpha: 1.0).setFill()
badge.fill()

let badgeAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 82, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 0.04, alpha: 1.0),
    .kern: 2.0
]
let badgeText = NSString(string: "NFC")
let badgeTextSize = badgeText.size(withAttributes: badgeAttributes)
badgeText.draw(
    at: NSPoint(
        x: badgeRect.midX - badgeTextSize.width / 2,
        y: badgeRect.midY - badgeTextSize.height / 2 + 5
    ),
    withAttributes: badgeAttributes
)

let arrow = NSBezierPath()
arrow.lineWidth = 26
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 224, y: 198))
arrow.line(to: NSPoint(x: 388, y: 198))
arrow.line(to: NSPoint(x: 350, y: 236))
arrow.move(to: NSPoint(x: 388, y: 198))
arrow.line(to: NSPoint(x: 350, y: 160))
NSColor.white.withAlphaComponent(0.82).setStroke()
arrow.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode icon PNG\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
