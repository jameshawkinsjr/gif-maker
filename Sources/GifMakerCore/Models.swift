import CoreGraphics
import Foundation

public enum LoopType: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case reverse
    case pingPong

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .reverse: return "Reverse"
        case .pingPong: return "Ping-Pong"
        }
    }
}

public enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case standard
    case high
    case max

    public var id: String { rawValue }
    public var framesPerSecond: Double {
        switch self {
        case .low: return 10
        case .standard: return 15
        case .high: return 24
        case .max: return 30
        }
    }
    public var title: String {
        switch self {
        case .low: return "Low"
        case .standard: return "Standard"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case gif
    case mp4

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
}

public enum CaptionAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case fade
    case scale
    case drop
    case move

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum CaptionFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case meme
    case rounded
    case serif
    case typewriter
    case marker

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct CaptionColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = CaptionColor(red: 1, green: 1, blue: 1)
    public static let black = CaptionColor(red: 0.07, green: 0.07, blue: 0.07)
    public static let yellow = CaptionColor(red: 1, green: 0.87, blue: 0.2)
    public static let red = CaptionColor(red: 1, green: 0.27, blue: 0.3)
    public static let green = CaptionColor(red: 0.2, green: 0.9, blue: 0.5)
    public static let blue = CaptionColor(red: 0.25, green: 0.65, blue: 1)
    public static let pink = CaptionColor(red: 1, green: 0.45, blue: 0.8)

    public static let presets: [CaptionColor] = [.white, .black, .yellow, .red, .green, .blue, .pink]

    /// Perceived brightness, 0...1.
    public var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// A piece of text shown over part of the clip.
public struct Caption: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    /// When the caption is visible, in seconds of the source recording.
    public var start: Double
    public var end: Double
    public var font: CaptionFont
    public var color: CaptionColor
    /// Font size as a fraction of the image width.
    public var size: Double
    /// Centre of the text block, as fractions of the image size measured from the top-left.
    public var centerX: Double
    public var centerY: Double
    public var animation: CaptionAnimation
    /// Length of the intro/outro animation in seconds.
    public var animationDuration: Double

    public static let sizeRange: ClosedRange<Double> = 0.03...0.2

    public init(
        id: UUID = UUID(), text: String, start: Double, end: Double, font: CaptionFont = .classic,
        color: CaptionColor = .white, size: Double = 0.07, centerX: Double = 0.5, centerY: Double = 0.84,
        animation: CaptionAnimation = .none, animationDuration: Double = 0.3
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.font = font
        self.color = color
        self.size = size
        self.centerX = centerX
        self.centerY = centerY
        self.animation = animation
        self.animationDuration = animationDuration
    }
}

/// Everything the editor lets you change about a recording.
public struct EditSettings: Codable, Hashable, Sendable {
    public var trimStart: Double
    public var trimEnd: Double
    public var loopType: LoopType
    /// Width of the exported image in pixels; height follows the aspect ratio.
    public var outputWidth: Int
    public var frameRate: FrameRate
    /// Playback speed multiplier. Changes frame timing, not which frames are used.
    public var speed: Double
    public var captions: [Caption]

    public static let speedRange: ClosedRange<Double> = 0.25...4
    public static let minimumTrimLength = 0.1

    public init(
        trimStart: Double, trimEnd: Double, loopType: LoopType = .normal, outputWidth: Int,
        frameRate: FrameRate = .standard, speed: Double = 1, captions: [Caption] = []
    ) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.loopType = loopType
        self.outputWidth = outputWidth
        self.frameRate = frameRate
        self.speed = speed
        self.captions = captions
    }

    public var trimmedDuration: Double { max(0, trimEnd - trimStart) }
}

/// A captured clip plus its edit settings. The video itself lives next to the metadata on disk.
public struct Recording: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point of the display the clip was captured on.
    public var scale: Double
    public var settings: EditSettings

    public static let defaultMaximumOutputWidth = 800
    public static let minimumOutputWidth = 64

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), duration: Double, pixelWidth: Int, pixelHeight: Int,
        scale: Double
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        let pointWidth = Int((Double(pixelWidth) / max(1, scale)).rounded())
        self.settings = EditSettings(
            trimStart: 0, trimEnd: duration,
            outputWidth: max(1, min(pointWidth, Self.defaultMaximumOutputWidth, pixelWidth)))
    }

    public var videoFileName: String { "\(id.uuidString).mov" }
    public var metadataFileName: String { "\(id.uuidString).json" }

    /// Size on screen when it was captured.
    public var pointWidth: Int { Int((Double(pixelWidth) / max(1, scale)).rounded()) }
    public var pointHeight: Int { Int((Double(pixelHeight) / max(1, scale)).rounded()) }

    public var outputWidthRange: ClosedRange<Int> {
        min(Self.minimumOutputWidth, pixelWidth)...pixelWidth
    }
}
