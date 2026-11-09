// Draws the background of the disk image's Finder window.
//
//     swift scripts/make-dmg-background.swift <output-directory>
//
// Writes background.png (1x) and background@2x.png (2x) for a 560 x 360 point
// window. make-dmg.sh combines them into one Retina-aware TIFF and positions
// the app icon and the Applications folder over the two ends of the arrow.

import AppKit
import CoreText

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output-directory>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Window content size in points. Keep in sync with the window bounds in make-dmg.sh.
let width: CGFloat = 560
let height: CGFloat = 360
/// The image is drawn taller than the window. Finder anchors it to the top-left,
/// so if the window ends up a little taller than planned (title bars vary
/// between macOS versions) the gradient continues instead of stopping short.
let imageHeight: CGFloat = 480

/// Where make-dmg.sh puts the icons (Finder coordinates: points from the top-left).
let appIconCenter = CGPoint(x: 150, y: 150)
let applicationsCenter = CGPoint(x: 410, y: 150)
let iconSize: CGFloat = 128

func draw(in context: CGContext, scale: CGFloat) {
    context.scaleBy(x: scale, y: scale)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }
    /// Converts a Finder y coordinate (from the top) to Core Graphics (from the bottom).
    func flip(_ y: CGFloat) -> CGFloat { imageHeight - y }

    // Soft, light background that reads well under either appearance. The
    // gradient spans the window height; the overflow below it stays flat.
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.975, 0.975, 0.98), color(0.925, 0.925, 0.935)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: flip(0)), end: CGPoint(x: 0, y: flip(height)),
        options: [.drawsAfterEndLocation])

    // Arrow from the app to the Applications folder, in the app's green.
    let gap: CGFloat = 26
    let start = CGPoint(x: appIconCenter.x + iconSize / 2 + gap, y: flip(appIconCenter.y))
    let end = CGPoint(x: applicationsCenter.x - iconSize / 2 - gap, y: flip(applicationsCenter.y))
    let headLength: CGFloat = 26
    let headWidth: CGFloat = 30
    context.setStrokeColor(color(0.07, 0.72, 0.52))
    context.setFillColor(color(0.07, 0.72, 0.52))
    context.setLineWidth(9)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: start)
    context.addLine(to: CGPoint(x: end.x - headLength + 4, y: end.y))
    context.strokePath()
    context.move(to: end)
    context.addLine(to: CGPoint(x: end.x - headLength, y: end.y + headWidth / 2))
    context.addLine(to: CGPoint(x: end.x - headLength, y: end.y - headWidth / 2))
    context.closePath()
    context.fillPath()

    // Caption below the icons and their labels.
    func drawCentered(_ string: String, font: NSFont, color textColor: NSColor, top: CGFloat) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: textColor])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: width / 2 - bounds.midX, y: flip(top) - bounds.midY)
        CTLineDraw(line, context)
    }
    drawCentered(
        "Drag GIF Maker into your Applications folder",
        font: NSFont.systemFont(ofSize: 15, weight: .medium), color: NSColor(white: 0.30, alpha: 1), top: 272)
    drawCentered(
        "Then open it from Applications, or Spotlight.",
        font: NSFont.systemFont(ofSize: 12, weight: .regular), color: NSColor(white: 0.52, alpha: 1), top: 296)
}

func writePNG(scale: Int, name: String) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: nil, width: Int(width) * scale, height: Int(imageHeight) * scale, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    context.setAllowsFontSmoothing(true)
    draw(in: context, scale: CGFloat(scale))
    guard let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output.appendingPathComponent(name))
}

try writePNG(scale: 1, name: "background.png")
try writePNG(scale: 2, name: "background@2x.png")
