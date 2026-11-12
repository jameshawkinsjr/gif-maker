import AppKit
import Foundation

// gifmaker-mcp: a Model Context Protocol server that lets AI agents record the
// screen and make GIFs with GIF Maker's recorder and encoder. MCP clients start
// it and talk to it over standard input and output; see the README.

/// The version of the GIF Maker app this copy shipped in ("dev" when run from a build folder).
let serverVersion: String = {
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    while url.pathComponents.count > 1 {
        if url.pathExtension == "app" {
            return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        }
        url.deleteLastPathComponent()
    }
    return "dev"
}()

if CommandLine.arguments.contains("--version") {
    print(serverVersion)
    exit(0)
}
if CommandLine.arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
    print(
        """
        gifmaker-mcp \(serverVersion)
        A Model Context Protocol server for GIF Maker. It speaks JSON-RPC on standard input and output and
        is meant to be started by an MCP client, for example:

            claude mcp add --scope user gif-maker -- "\(CommandLine.arguments[0])"
        """)
    exit(0)
}

// Connect to the window server without showing a Dock icon or menu bar.
NSApplication.shared.setActivationPolicy(.prohibited)

let session = RecordingSession()
let server = MCPServer(
    name: "gif-maker", version: serverVersion, instructions: Tools.instructions, tools: Tools.all(session: session))
server.onShutdown = { await session.shutdown() }
server.start()
RunLoop.main.run()
