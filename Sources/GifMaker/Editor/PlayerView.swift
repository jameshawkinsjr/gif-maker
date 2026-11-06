import AVFoundation
import AppKit
import Combine
import GifMakerCore
import SwiftUI

/// The video preview with captions drawn (and draggable) on top.
struct PlayerView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView(player: model.player)
        let overlay = view.overlay
        overlay.onSelect = { [weak model] id in model?.selectCaption(id) }
        overlay.onMove = { [weak model] id, x, y in model?.moveCaption(id, toCenterX: x, centerY: y) }
        overlay.onBackgroundClick = { [weak model] in model?.togglePlayback() }
        context.coordinator.subscription = model.clock.$time.sink { [weak overlay] time in
            overlay?.time = time
        }
        update(overlay)
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        update(view.overlay)
    }

    private func update(_ overlay: CaptionOverlayView) {
        let plan = model.plan
        overlay.canvasSize = CGSize(width: plan.outputWidth, height: plan.outputHeight)
        overlay.captions = model.settings.captions
        overlay.selectedID = model.selectedCaptionID
        // Captions can only be repositioned from the Captions tab.
        overlay.isEditable = model.tab == .captions
    }

    final class Coordinator {
        var subscription: AnyCancellable?
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()
    let overlay = CaptionOverlayView()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        overlay.frame = bounds
    }
}

/// Draws captions over the video using the same renderer as the exporter, and
/// lets the selected caption be dragged around.
final class CaptionOverlayView: NSView {
    var onSelect: ((UUID?) -> Void)?
    var onMove: ((UUID, Double, Double) -> Void)?
    var onBackgroundClick: (() -> Void)?

    var captions: [Caption] = [] { didSet { if captions != oldValue { needsDisplay = true } } }
    var selectedID: UUID? { didSet { if selectedID != oldValue { needsDisplay = true } } }
    var canvasSize = CGSize(width: 1, height: 1) { didSet { if canvasSize != oldValue { needsDisplay = true } } }
    var isEditable = false { didSet { if isEditable != oldValue { needsDisplay = true } } }
    var time: Double = 0 {
        didSet {
            // Only repaint when there's something whose appearance depends on time.
            if time != oldValue, !captions.isEmpty { needsDisplay = true }
        }
    }

    private var dragging: (id: UUID, offset: CGSize)?

    override var isOpaque: Bool { false }

    /// Where the video sits inside the view (it's letterboxed to keep its shape).
    private var videoRect: CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: canvasSize, insideRect: bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !captions.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = videoRect
        guard rect.width > 0 else { return }

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        // Draw in output-pixel units so text wraps exactly as it will in the export.
        let scale = rect.width / canvasSize.width
        context.scaleBy(x: scale, y: scale)
        CaptionRenderer.draw(captions, at: time, in: context, canvasSize: canvasSize)

        if isEditable, let selected = captions.first(where: { $0.id == selectedID }),
            CaptionRenderer.isVisible(selected, at: time)
        {
            let frame = CaptionRenderer.frame(of: selected, canvasSize: canvasSize)
            let outline = CGRect(
                x: frame.minX, y: canvasSize.height - frame.maxY, width: frame.width, height: frame.height
            ).insetBy(dx: -5 / scale, dy: -3 / scale)
            context.setLineWidth(1.5 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 4 / scale])
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
            context.stroke(outline.offsetBy(dx: 1 / scale, dy: -1 / scale))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.stroke(outline)
        }
        context.restoreGState()
    }

    /// Converts a point in the view to canvas units measured from the top-left.
    private func canvasPoint(_ point: NSPoint) -> CGPoint {
        let rect = videoRect
        guard rect.width > 0 else { return .zero }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * canvasSize.width,
            y: (rect.maxY - point.y) / rect.height * canvasSize.height)
    }

    private func caption(at point: CGPoint) -> Caption? {
        captions.reversed().first { caption in
            CaptionRenderer.isVisible(caption, at: time)
                && CaptionRenderer.frame(of: caption, canvasSize: canvasSize).insetBy(dx: -8, dy: -8).contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = canvasPoint(convert(event.locationInWindow, from: nil))
        guard isEditable, let hit = caption(at: point) else {
            if isEditable, selectedID != nil {
                onSelect?(nil)
            } else {
                onBackgroundClick?()
            }
            return
        }
        onSelect?(hit.id)
        dragging = (
            hit.id,
            CGSize(
                width: hit.centerX * canvasSize.width - point.x, height: hit.centerY * canvasSize.height - point.y)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let point = canvasPoint(convert(event.locationInWindow, from: nil))
        onMove?(
            dragging.id, (point.x + dragging.offset.width) / canvasSize.width,
            (point.y + dragging.offset.height) / canvasSize.height)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }
}
