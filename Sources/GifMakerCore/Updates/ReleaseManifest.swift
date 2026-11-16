import Foundation

/// Describes the newest published build. `scripts/make-dmg.sh` writes it as
/// `latest.json` beside the disk image when `PUBLISH_DIR` is set:
///
///     {
///       "build" : 14,
///       "file" : "GIF-Maker-1.2.0.dmg",
///       "sha256" : "…",
///       "size" : 4123456,
///       "version" : "1.2.0"
///     }
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public static let fileName = "latest.json"

    public var version: String
    public var build: Int
    /// The disk image's file name, in the same folder as the manifest.
    public var file: String
    /// SHA-256 of the disk image, as hex.
    public var sha256: String
    /// The disk image's size in bytes. Optional; a cheap first check that the
    /// file has finished syncing.
    public var size: Int64?
    public var notes: String?

    public init(version: String, build: Int, file: String, sha256: String, size: Int64? = nil, notes: String? = nil) {
        self.version = version
        self.build = build
        self.file = file
        self.sha256 = sha256
        self.size = size
        self.notes = notes
    }

    public var appVersion: AppVersion { AppVersion(version: version, build: build) }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case notJSON
        case missingVersion
        case invalidBuild
        case unsafeFileName
        case invalidChecksum

        public var errorDescription: String? {
            switch self {
            case .notJSON: return "it isn't a release description"
            case .missingVersion: return "it has no version"
            case .invalidBuild: return "its build number isn't valid"
            case .unsafeFileName: return "its file name isn't a plain .dmg file name"
            case .invalidChecksum: return "its sha256 isn't a SHA-256 checksum"
            }
        }
    }

    /// Decodes and validates a manifest. Anyone who can write to the folder
    /// controls this file, so nothing in it is trusted as it stands: the file
    /// name in particular must not be able to point outside the folder.
    public static func decode(_ data: Data) throws -> ReleaseManifest {
        var manifest: ReleaseManifest
        do {
            manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        } catch {
            throw ValidationError.notJSON
        }
        manifest.version = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.sha256 = manifest.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard manifest.version.first?.isNumber == true else { throw ValidationError.missingVersion }
        guard manifest.build >= 0 else { throw ValidationError.invalidBuild }
        let file = manifest.file
        guard !file.isEmpty, !file.hasPrefix("."), !file.contains("/"), !file.contains(":"), !file.contains("\0"),
            file.lowercased().hasSuffix(".dmg")
        else { throw ValidationError.unsafeFileName }
        let hexDigits = Set("0123456789abcdef")
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy(hexDigits.contains) else {
            throw ValidationError.invalidChecksum
        }
        if let size = manifest.size, size <= 0 { manifest.size = nil }
        if manifest.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { manifest.notes = nil }
        return manifest
    }
}
