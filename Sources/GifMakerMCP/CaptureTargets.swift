import AppKit
import CoreGraphics

/// Displays and windows that can be recorded.
///
/// Every rectangle here is in global screen coordinates: points, with the origin
/// at the top-left corner of the main display and y growing downwards. That is
/// the space screenshots and most automation tools use.
enum CaptureTargets {
    struct Display {
        let id: CGDirectDisplayID
        let bounds: CGRect
        let scale: CGFloat
        let isMain: Bool

        var summary: [String: Any] {
            [
                "display_id": Int(id), "is_main": isMain, "scale": Double(scale),
                "bounds": rectSummary(bounds),
            ]
        }
    }

    struct Window {
        let id: CGWindowID
        let processID: pid_t
        let appName: String
        let bundleID: String?
        let title: String
        let bounds: CGRect

        var summary: [String: Any] {
            var summary: [String: Any] = [
                "window_id": Int(id), "app": appName, "title": title, "bounds": rectSummary(bounds),
            ]
            if let bundleID { summary["bundle_id"] = bundleID }
            return summary
        }
    }

    /// The part of one display to record.
    struct Region {
        let display: Display
        /// In the display's own space (points, origin at its top-left), as the recorder expects.
        let localRect: CGRect
        let description: String
        var globalRect: CGRect { localRect.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY) }
    }

    static func displays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let pixelWidth = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) } ?? bounds.width
            return Display(id: id, bounds: bounds, scale: max(1, pixelWidth / max(1, bounds.width)), isMain: id == main)
        }
    }

    /// Ordinary app windows currently on screen, front to back.
    ///
    /// Titles are only visible to processes with Screen Recording permission;
    /// without it they come back empty.
    static func windows() -> [Window] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                let number = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? Int, pid_t(pid) != ownPID,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                bounds.width >= 40, bounds.height >= 40,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            let app = NSRunningApplication(processIdentifier: pid_t(pid))
            return Window(
                id: CGWindowID(number), processID: pid_t(pid),
                appName: info[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "",
                bundleID: app?.bundleIdentifier, title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds)
        }
    }

    /// The windows of the app whose name or bundle identifier matches `app`,
    /// front to back, optionally narrowed to titles containing `title`.
    static func windows(ofApp app: String, title: String? = nil) -> [Window] {
        let wanted = app.lowercased()
        let all = windows()
        let exact = all.filter { $0.appName.lowercased() == wanted || $0.bundleID?.lowercased() == wanted }
        var matches = exact.isEmpty ? all.filter { $0.appName.lowercased().contains(wanted) } : exact
        if let title, !title.isEmpty {
            matches = matches.filter { $0.title.localizedCaseInsensitiveContains(title) }
        }
        return matches
    }

    /// Clips a global rectangle to the display it mostly lies on.
    static func region(for globalRect: CGRect, description: String) throws -> Region {
        let rect = globalRect.standardized
        let candidates = displays().map { display -> (Display, CGRect) in
            (display, display.bounds.intersection(rect))
        }
        guard
            let (display, visible) = candidates.filter({ !$0.1.isNull })
                .max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }),
            visible.width >= 8, visible.height >= 8
        else {
            throw ToolError(
                "\(description) isn't on any display. Coordinates are global screen points with the origin at the "
                    + "top-left of the main display; call list_windows to see the displays.")
        }
        let local = visible.offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY)
        return Region(display: display, localRect: local.integral, description: description)
    }

    /// Brings an app to the front, as clicking its Dock icon would.
    @MainActor
    static func activate(processID: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: processID), !app.isActive else { return }
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app.activate()
        }
        // Give the window server a moment to reorder windows before frames are taken.
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}

func rectSummary(_ rect: CGRect) -> [String: Any] {
    ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
}
