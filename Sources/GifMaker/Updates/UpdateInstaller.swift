import Foundation
import GifMakerCore

/// Installs a published update over the running app.
///
/// `prepare` does everything that can be done while the app is still running:
/// it copies the disk image out of the publish folder, checks it against the
/// manifest, opens it, checks the app inside, and puts a verified copy beside
/// the installed app. `startSwap` then hands over to the script in
/// `UpdateInstallPlan`, which replaces the app once it has quit.
///
/// Releases aren't signed with a Developer ID, so there is no publisher to
/// check. What is checked: the disk image is the one the manifest describes,
/// the app in it is this app (by bundle identifier), it is newer, and its
/// signature is intact.
struct UpdateInstaller: Sendable {
    enum InstallError: LocalizedError, Equatable {
        /// The app isn't somewhere it can replace itself, e.g. a folder only an
        /// administrator can change, or the disk image it was opened from.
        case locationNotWritable(String)
        case notReady(String)
        case diskImageUnusable(String)
        case appNotFound
        case notNewer(String)
        case manifestMismatch(String)
        case invalidSignature(String)
        case stagingFailed(String)

        var errorDescription: String? {
            switch self {
            case .locationNotWritable(let folder):
                return
                    "GIF Maker can't replace itself in \(folder). Open the disk image and drag GIF Maker to Applications instead."
            case .notReady(let file):
                return "\(file) doesn't match its published checksum. It may still be syncing; try again in a moment."
            case .diskImageUnusable(let reason): return "The disk image couldn't be opened. \(reason)"
            case .appNotFound: return "The disk image doesn't contain GIF Maker."
            case .notNewer(let version): return "The disk image contains version \(version), which isn't newer."
            case .manifestMismatch(let version):
                return "The disk image contains version \(version), not the version it was published as."
            case .invalidSignature(let reason): return "The new version's code signature isn't valid. \(reason)"
            case .stagingFailed(let reason): return "The new version couldn't be copied into place. \(reason)"
            }
        }
    }

    /// A verified copy of the new version, staged and ready to swap in.
    struct Prepared: Sendable {
        let plan: UpdateInstallPlan
        let version: AppVersion
        /// The new version doesn't satisfy the running app's signing requirement,
        /// so macOS will treat it as a different app for Screen Recording.
        let signatureChanged: Bool
    }

    /// The installed app bundle that is to be replaced.
    let installedApp: URL
    let bundleIdentifier: String
    let currentVersion: AppVersion

    /// An installer for the running app, or `nil` when it isn't running from an
    /// app bundle with a version (a bare development build).
    static func forRunningApp() -> UpdateInstaller? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let identifier = bundle.bundleIdentifier,
            let version = AppVersion(infoDictionary: bundle.infoDictionary)
        else { return nil }
        return UpdateInstaller(installedApp: bundle.bundleURL, bundleIdentifier: identifier, currentVersion: version)
    }

    static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/GIF Maker/Update.log")

    /// Throws `locationNotWritable` unless the app can be swapped where it is.
    func checkInstallLocation() throws {
        let folder = installedApp.deletingLastPathComponent()
        // A quarantined app that was never moved runs from a read-only copy
        // somewhere random ("translocation"); replacing that would achieve nothing.
        let translocated = installedApp.path.contains("/AppTranslocation/")
        guard !translocated, FileManager.default.isWritableFile(atPath: folder.path),
            FileManager.default.isWritableFile(atPath: installedApp.path)
        else {
            throw InstallError.locationNotWritable(translocated ? "its current location" : folder.path)
        }
    }

    /// Verifies the update and stages it beside the installed app. Blocks while
    /// it copies and checks, so call it off the main thread. Leaves nothing
    /// behind if it throws.
    func prepare(_ update: AvailableUpdate, progress: @Sendable (String) -> Void) throws -> Prepared {
        try checkInstallLocation()
        let files = FileManager.default
        let manifest = update.manifest

        let workspace = files.temporaryDirectory.appendingPathComponent("GIFMakerUpdate-\(UUID().uuidString)")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        // Work on a private copy: the file in the publish folder can change
        // under us, and what gets checked must be what gets installed.
        progress("Copying \(manifest.file)…")
        let diskImage = workspace.appendingPathComponent(manifest.file)
        do {
            try files.copyItem(at: update.diskImageURL, to: diskImage)
        } catch {
            throw InstallError.notReady(manifest.file)
        }
        guard (try? FileChecksum.sha256(of: diskImage)) == manifest.sha256 else {
            throw InstallError.notReady(manifest.file)
        }

        progress("Opening the disk image…")
        let volume = workspace.appendingPathComponent("volume")
        try files.createDirectory(at: volume, withIntermediateDirectories: true)
        do {
            try Shell.run(
                "/usr/bin/hdiutil",
                ["attach", diskImage.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", volume.path])
        } catch {
            throw InstallError.diskImageUnusable(error.localizedDescription)
        }
        defer { Self.detach(volume) }

        progress("Checking the new version…")
        let candidates = ((try? files.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard
            let source = candidates.first(where: {
                AppVersion.infoDictionary(ofBundleAt: $0)?["CFBundleIdentifier"] as? String == bundleIdentifier
            }), let version = AppVersion(bundleAt: source)
        else { throw InstallError.appNotFound }
        guard version > currentVersion else { throw InstallError.notNewer(version.description) }
        guard version == manifest.appVersion else { throw InstallError.manifestMismatch(version.description) }
        do {
            try CodeSignature.verify(source)
        } catch {
            throw InstallError.invalidSignature(Self.reason(from: error))
        }

        progress("Copying the new version…")
        let plan = UpdateInstallPlan(
            processID: ProcessInfo.processInfo.processIdentifier, installedApp: installedApp,
            executablePath: try Self.executablePath(of: source))
        try? files.removeItem(at: plan.stagedApp)
        do {
            try Shell.run("/usr/bin/ditto", [source.path, plan.stagedApp.path])
            // Anything that arrived through a browser or a sync service may be
            // quarantined; the installed app shouldn't be.
            _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", plan.stagedApp.path])
            // The copy is what will run, so it is the copy that has to verify.
            try CodeSignature.verify(plan.stagedApp)
            guard AppVersion(bundleAt: plan.stagedApp) == version else {
                throw InstallError.stagingFailed("The copy doesn't match the original.")
            }
        } catch {
            try? files.removeItem(at: plan.stagedApp)
            throw (error as? InstallError) ?? InstallError.stagingFailed(Self.reason(from: error))
        }

        let signatureChanged = !CodeSignature.satisfiesDesignatedRequirement(
            of: installedApp, candidate: plan.stagedApp)
        var finalPlan = plan
        if signatureChanged {
            finalPlan.relaunchArguments = [UpdateInstallPlan.LaunchArgument.signatureChanged]
        }
        return Prepared(plan: finalPlan, version: version, signatureChanged: signatureChanged)
    }

    /// Removes a staged copy that isn't going to be installed after all.
    func discard(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.plan.stagedApp)
    }

    /// Starts the script that swaps the apps once this one quits. The caller
    /// quits the app next. `onExit` is called with the script's exit status if
    /// it finishes while the app is still running, which means the app never
    /// quit and nothing was installed.
    func startSwap(_ prepared: Prepared, onExit: @escaping @Sendable (Int32) -> Void) throws {
        let files = FileManager.default
        try? files.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: Self.logURL.path, contents: nil)
        let log = FileHandle(forWritingAtPath: Self.logURL.path) ?? FileHandle.nullDevice

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = prepared.plan.shellArguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
    }

    /// The part of a tool's complaint worth showing: codesign and ditto prefix
    /// theirs with the full path of the file, which here is a temporary one.
    private static func reason(from error: Error) -> String {
        guard let failure = error as? Shell.Failure, let line = failure.output.split(separator: "\n").first,
            let range = line.range(of: ": ", options: .backwards)
        else { return error.localizedDescription }
        let reason = String(line[range.upperBound...])
        return reason.prefix(1).uppercased() + reason.dropFirst() + "."
    }

    private static func executablePath(of app: URL) throws -> String {
        guard let name = AppVersion.infoDictionary(ofBundleAt: app)?["CFBundleExecutable"] as? String,
            !name.isEmpty, !name.contains("/"),
            FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(name)").path)
        else { throw InstallError.appNotFound }
        return "Contents/MacOS/\(name)"
    }

    private static func detach(_ volume: URL) {
        if (try? Shell.run("/usr/bin/hdiutil", ["detach", volume.path])) == nil {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", volume.path, "-force"])
        }
    }
}
