import Foundation

/// Turns edit settings into a concrete list of frames: which moments of the
/// source to sample, in what order to show them, and for how long.
public struct FramePlan: Equatable, Sendable {
    /// Moments of the source recording to sample, ascending.
    public let sourceTimes: [Double]
    /// Indices into `sourceTimes` in the order they are shown.
    public let sequence: [Int]
    /// How long each output frame is shown, in seconds.
    public let frameDelay: Double
    public let outputWidth: Int
    public let outputHeight: Int

    /// GIF players can't reliably show frames faster than 50 fps.
    public static let maximumOutputFPS = 50.0

    public var frameCount: Int { sequence.count }
    public var duration: Double { Double(sequence.count) * frameDelay }
    public var outputFPS: Double { 1 / frameDelay }

    public init(
        settings: EditSettings, sourceWidth: Int, sourceHeight: Int, sourceDuration: Double,
        evenDimensions: Bool = false
    ) {
        let start = max(0, min(settings.trimStart, sourceDuration))
        let end = max(start, min(settings.trimEnd, sourceDuration))
        let length = end - start
        let speed = min(max(settings.speed, EditSettings.speedRange.lowerBound), EditSettings.speedRange.upperBound)

        // Speed changes how long each frame is shown rather than which frames are
        // used, until that would exceed what players can show; then sample less often.
        var sampleFPS = settings.frameRate.framesPerSecond
        if sampleFPS * speed > Self.maximumOutputFPS {
            sampleFPS = Self.maximumOutputFPS / speed
        }
        frameDelay = 1 / (sampleFPS * speed)

        let count = max(1, Int((length * sampleFPS).rounded()))
        let lastUsable = max(start, end - 0.001)
        sourceTimes = (0..<count).map { min(start + Double($0) / sampleFPS, lastUsable) }

        switch settings.loopType {
        case .normal:
            sequence = Array(0..<count)
        case .reverse:
            sequence = Array((0..<count).reversed())
        case .pingPong:
            // Forward, then back again without repeating either end frame.
            sequence = Array(0..<count) + (count > 2 ? Array((1..<(count - 1)).reversed()) : [])
        }

        var width = max(1, min(settings.outputWidth, sourceWidth))
        var height = max(1, Int((Double(width) * Double(sourceHeight) / Double(max(1, sourceWidth))).rounded()))
        if evenDimensions {
            // Video encoders need even dimensions.
            width = max(2, width - width % 2)
            height = max(2, height - height % 2)
        }
        outputWidth = width
        outputHeight = height
    }
}
