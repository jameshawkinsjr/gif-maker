// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GifMaker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GifMaker", targets: ["GifMaker"]),
        .library(name: "GifMakerCore", targets: ["GifMakerCore"]),
        .executable(name: "gifmaker-mcp", targets: ["GifMakerMCP"]),
    ],
    targets: [
        // Everything that doesn't need a window: recording, GIF/MP4 encoding, models.
        .target(name: "GifMakerCore"),
        // The AppKit/SwiftUI app.
        .executableTarget(name: "GifMaker", dependencies: ["GifMakerCore"]),
        // An MCP server so AI agents can record the screen and make GIFs.
        .executableTarget(name: "GifMakerMCP", dependencies: ["GifMakerCore"]),
        .testTarget(name: "GifMakerCoreTests", dependencies: ["GifMakerCore"]),
    ]
)
