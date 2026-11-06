// Draws the app icon and writes it as an .iconset folder.
//
//     swift scripts/make-icon.swift <output.iconset>
//
// `iconutil -c icns <output.iconset>` then turns that into AppIcon.icns.
// The build script runs both steps, so the icon never needs to be checked in.

import AppKit
import CoreText

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Draws the icon into a square context `side` pixels across. All geometry is
/// laid out on a 1024-unit canvas and scaled to fit.
func drawIcon(in context: CGContext, side: CGFloat) {
    context.scaleBy(x: side / 1024, y: side / 1024)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }

    // The standard macOS icon shape: a rounded square inset from the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.32))
    context.addPath(shape)
    context.setFillColor(color(0.07, 0.72, 0.52))
    context.fillPath()
    context.restoreGState()

    // Green gradient, lighter at the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.20, 0.92, 0.58), color(0.03, 0.62, 0.50)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    context.restoreGState()

    // Viewfinder corners: the capture frame.
    let frame = body.insetBy(dx: 150, dy: 170)
    let arm: CGFloat = 120
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(46)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (corner, dx, dy) in [
        (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
        (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
    ] {
        context.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
        context.addLine(to: corner)
        context.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        context.strokePath()
    }

    // "GIF" in the middle of the frame.
    let font = NSFont.systemFont(ofSize: 250, weight: .black)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 250) } ?? font
    let text = NSAttributedString(
        string: "GIF",
        attributes: [.font: rounded, .foregroundColor: NSColor.white, .kern: 4])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(x: 512 - bounds.midX, y: 545 - bounds.midY)
    CTLineDraw(line, context)

    // Record dot underneath.
    context.setFillColor(color(1.0, 0.23, 0.19))
    context.fillEllipse(in: CGRect(x: 512 - 50, y: 318 - 50, width: 100, height: 100))
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(16)
    context.strokeEllipse(in: CGRect(x: 512 - 58, y: 318 - 58, width: 116, height: 116))
}

func writePNG(side: Int, name: String) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    drawIcon(in: context, side: CGFloat(side))
    guard let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: output.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try writePNG(side: points, name: "icon_\(points)x\(points).png")
    try writePNG(side: points * 2, name: "icon_\(points)x\(points)@2x.png")
}
