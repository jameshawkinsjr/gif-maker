import AppKit
import CoreText

/// Draws captions with Core Text. The editor preview and the exporter both go
/// through here, so what you see while editing is what ends up in the file.
public enum CaptionRenderer {
    /// Text never gets wider than this fraction of the image before wrapping.
    private static let maximumWidthFraction = 0.94

    /// Captions cover the half-open range `start..<end`. Both ends are nudged by
    /// the same sliver so rounding noise in a frame's timestamp can't flip the answer.
    public static func isVisible(_ caption: Caption, at time: Double) -> Bool {
        time >= caption.start - 0.0005 && time < caption.end - 0.0005
    }

    /// Draws every caption visible at `time`.
    ///
    /// `context` must use a bottom-left origin and span `canvasSize` units (scale
    /// the context first to draw at another size without changing line wrapping).
    public static func draw(_ captions: [Caption], at time: Double, in context: CGContext, canvasSize: CGSize) {
        for caption in captions where isVisible(caption, at: time) {
            guard let layout = Layout(caption: caption, canvasSize: canvasSize) else { continue }
            let pose = Pose(caption: caption, time: time, rect: layout.rect, canvasSize: canvasSize)
            guard pose.alpha > 0.003, pose.scale > 0.003 else { continue }

            // Layout rects are top-left based; Core Text draws bottom-left based.
            let drawRect = CGRect(
                x: layout.rect.minX, y: canvasSize.height - layout.rect.maxY,
                width: layout.rect.width, height: layout.rect.height)
            let center = CGPoint(x: drawRect.midX + pose.dx, y: drawRect.midY - pose.dy)

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: pose.scale, y: pose.scale)
            context.translateBy(x: -drawRect.midX, y: -drawRect.midY)
            context.setAlpha(pose.alpha)
            context.setShadow(
                offset: CGSize(width: 0, height: -layout.fontSize * 0.03), blur: layout.fontSize * 0.09,
                color: CGColor(gray: 0, alpha: 0.55))
            // Composite outline + fill as one unit so alpha and shadow apply once.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setLineJoin(.round)
            let path = CGPath(rect: drawRect, transform: nil)
            for setter in [layout.outline, layout.fill] {
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
                CTFrameDraw(frame, context)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// Where a caption sits when it isn't animating, in canvas units from the top-left.
    /// Empty captions get a small placeholder rect so they can still be grabbed.
    public static func frame(of caption: Caption, canvasSize: CGSize) -> CGRect {
        if let layout = Layout(caption: caption, canvasSize: canvasSize) { return layout.rect }
        let fontSize = caption.size * canvasSize.width
        let size = CGSize(width: fontSize * 4, height: fontSize * 1.2)
        return CGRect(
            x: caption.centerX * canvasSize.width - size.width / 2,
            y: caption.centerY * canvasSize.height - size.height / 2, width: size.width, height: size.height)
    }

    public static func font(_ font: CaptionFont, size: CGFloat) -> CTFont {
        func named(_ name: String) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
        switch font {
        case .classic: return named("HelveticaNeue-Bold")
        case .meme: return named("Impact")
        case .serif: return named("Georgia-Bold")
        case .typewriter: return named("AmericanTypewriter-Bold")
        case .marker: return named("MarkerFelt-Wide")
        case .rounded:
            let system = NSFont.systemFont(ofSize: size, weight: .heavy)
            if let descriptor = system.fontDescriptor.withDesign(.rounded),
                let rounded = NSFont(descriptor: descriptor, size: size)
            {
                return rounded
            }
            return system
        }
    }

    // MARK: Layout

    private struct Layout {
        let fill: CTFramesetter
        let outline: CTFramesetter
        let rect: CGRect  // top-left origin
        let fontSize: CGFloat

        init?(caption: Caption, canvasSize: CGSize) {
            var text = caption.text
            if caption.font == .meme { text = text.uppercased() }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                canvasSize.width > 0, canvasSize.height > 0
            else { return nil }

            fontSize = max(4, caption.size * canvasSize.width)
            let font = CaptionRenderer.font(caption.font, size: fontSize)

            var alignment = CTTextAlignment.center
            let paragraph = withUnsafePointer(to: &alignment) { pointer -> CTParagraphStyle in
                var setting = CTParagraphStyleSetting(
                    spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }

            // Dark text gets a light outline and vice versa, so it reads on any background.
            let outlineColor =
                caption.color.luminance < 0.4
                ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
            let outlineWidth: CGFloat = caption.font == .meme ? 14 : 9  // percent of font size

            let fillAttributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: caption.color.cgColor,
                kCTParagraphStyleAttributeName: paragraph,
            ]
            let outlineAttributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: outlineColor,
                kCTStrokeColorAttributeName: outlineColor,
                kCTStrokeWidthAttributeName: outlineWidth,  // positive = stroke only
                kCTParagraphStyleAttributeName: paragraph,
            ]
            fill = CTFramesetterCreateWithAttributedString(
                CFAttributedStringCreate(nil, text as CFString, fillAttributes as CFDictionary))
            outline = CTFramesetterCreateWithAttributedString(
                CFAttributedStringCreate(nil, text as CFString, outlineAttributes as CFDictionary))

            let limit = CGSize(
                width: canvasSize.width * CaptionRenderer.maximumWidthFraction,
                height: CGFloat.greatestFiniteMagnitude)
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
                fill, CFRange(location: 0, length: 0), nil, limit, nil)
            let size = CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height) + 2)
            rect = CGRect(
                x: caption.centerX * canvasSize.width - size.width / 2,
                y: caption.centerY * canvasSize.height - size.height / 2,
                width: size.width, height: size.height)
        }
    }

    // MARK: Animation

    /// How a caption is displaced at a given moment. `dy` is positive downwards.
    private struct Pose {
        var alpha: CGFloat = 1
        var scale: CGFloat = 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0

        init(caption: Caption, time: Double, rect: CGRect, canvasSize: CGSize) {
            let length = max(0.001, min(caption.animationDuration, (caption.end - caption.start) / 2))
            let intro = CGFloat(min(1, max(0, (time - caption.start) / length)))
            let outro = CGFloat(min(1, max(0, (caption.end - time) / length)))

            switch caption.animation {
            case .none:
                break
            case .fade:
                alpha = min(intro, outro)
            case .scale:
                scale = intro < 1 ? Self.easeOutBack(intro) : Self.easeOutCubic(outro)
                alpha = min(1, 3 * min(intro, outro))
            case .drop:
                // Falls in from above the image with a bounce, then fades away.
                dy = -(1 - Self.easeOutBounce(intro)) * rect.maxY
                alpha = outro
            case .move:
                // Slides in from the left edge and out past the right edge.
                if intro < 1 {
                    dx = -(1 - Self.easeOutCubic(intro)) * rect.maxX
                } else if outro < 1 {
                    dx = (1 - Self.easeOutCubic(outro)) * (canvasSize.width - rect.minX)
                }
            }
        }

        static func easeOutCubic(_ p: CGFloat) -> CGFloat {
            1 - pow(1 - p, 3)
        }

        static func easeOutBack(_ p: CGFloat) -> CGFloat {
            let c1: CGFloat = 1.70158
            let c3 = c1 + 1
            return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
        }

        static func easeOutBounce(_ p: CGFloat) -> CGFloat {
            let n: CGFloat = 7.5625
            let d: CGFloat = 2.75
            var x = p
            if x < 1 / d {
                return n * x * x
            } else if x < 2 / d {
                x -= 1.5 / d
                return n * x * x + 0.75
            } else if x < 2.5 / d {
                x -= 2.25 / d
                return n * x * x + 0.9375
            } else {
                x -= 2.625 / d
                return n * x * x + 0.984375
            }
        }
    }
}
