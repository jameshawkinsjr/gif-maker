import Foundation

/// A published build that is newer than the running app and ready to install.
public struct AvailableUpdate: Equatable, Sendable {
    public let manifest: ReleaseManifest
    /// The disk image in the publish folder.
    public let diskImageURL: URL

    public init(manifest: ReleaseManifest, diskImageURL: URL) {
        self.manifest = manifest
        self.diskImageURL = diskImageURL
    }

    public var version: AppVersion { manifest.appVersion }
}

/// Why a check found nothing to offer. None of these is worth an error dialog:
/// a folder on a cloud drive is often missing, empty or half synced.
public enum UpdateCheckFailure: Equatable, Sendable {
    /// The folder doesn't exist or can't be read, e.g. a drive that isn't mounted.
    case folderUnavailable
    /// The folder is there but nothing has been published to it.
    case noManifest
    /// `latest.json` exists but isn't a usable release description.
    case malformedManifest(String)
    /// The manifest names a disk image that isn't in the folder.
    case diskImageMissing(String)
    /// The named file is there but incomplete: a cloud placeholder, the wrong
    /// size, or the wrong checksum. It will usually be ready on a later check.
    case stillSyncing(String)

    public var message: String {
        switch self {
        case .folderUnavailable: return "The update folder isn't available right now."
        case .noManifest: return "No release has been published to the update folder."
        case .malformedManifest(let reason): return "\(ReleaseManifest.fileName) can't be used: \(reason)."
        case .diskImageMissing(let file): return "\(file) isn't in the update folder yet."
        case .stillSyncing(let file): return "\(file) hasn't finished syncing yet."
        }
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
    case failed(UpdateCheckFailure)
}

/// Looks in a folder for a build newer than the running one.
///
/// The folder holds `latest.json` and the disk image it names. Nothing here
/// touches the network; a synced folder (iCloud Drive, Dropbox, a file share)
/// is what makes a build published on one Mac show up on another.
public struct UpdateChecker: Sendable {
    public let folder: URL
    public let currentVersion: AppVersion

    public init(folder: URL, currentVersion: AppVersion) {
        self.folder = folder
        self.currentVersion = currentVersion
    }

    /// Reads the folder. This does file I/O, including hashing the disk image
    /// when there is a newer one, so call it off the main thread.
    public func check() -> UpdateCheckResult {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
            files.isReadableFile(atPath: folder.path)
        else { return .failed(.folderUnavailable) }

        let manifestURL = folder.appendingPathComponent(ReleaseManifest.fileName)
        guard files.fileExists(atPath: manifestURL.path) else {
            if Self.requestDownload(of: manifestURL) { return .failed(.stillSyncing(ReleaseManifest.fileName)) }
            return .failed(.noManifest)
        }
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .failed(.stillSyncing(ReleaseManifest.fileName))
        }
        let manifest: ReleaseManifest
        do {
            manifest = try ReleaseManifest.decode(data)
        } catch {
            return .failed(.malformedManifest(error.localizedDescription))
        }

        guard manifest.appVersion > currentVersion else { return .upToDate }

        // The manifest is written after the disk image, but a sync service may
        // deliver them in either order, or deliver the image in pieces.
        let diskImage = folder.appendingPathComponent(manifest.file)
        guard files.fileExists(atPath: diskImage.path) else {
            if Self.requestDownload(of: diskImage) { return .failed(.stillSyncing(manifest.file)) }
            return .failed(.diskImageMissing(manifest.file))
        }
        if let expected = manifest.size,
            let actual = (try? files.attributesOfItem(atPath: diskImage.path)[.size] as? NSNumber)?.int64Value,
            actual != expected
        {
            return .failed(.stillSyncing(manifest.file))
        }
        guard let checksum = try? FileChecksum.sha256(of: diskImage), checksum == manifest.sha256 else {
            return .failed(.stillSyncing(manifest.file))
        }
        return .available(AvailableUpdate(manifest: manifest, diskImageURL: diskImage))
    }

    /// iCloud Drive can leave a `.name.icloud` placeholder where a file that
    /// hasn't been downloaded should be. If there is one, asks for the real
    /// file and returns true.
    private static func requestDownload(of url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard FileManager.default.fileExists(atPath: placeholder.path) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }
}
