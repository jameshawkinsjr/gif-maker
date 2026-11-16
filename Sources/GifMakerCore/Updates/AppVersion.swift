import Foundation

/// An app version: the marketing version ("1.2.0") plus the build number.
///
/// Versions are ordered by their dot-separated numbers, then by build, so
/// 1.10 is newer than 1.9, 1.2 equals 1.2.0, and a rebuild of the same version
/// with a higher build number counts as newer.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let version: String
    public let build: Int

    public init(version: String, build: Int) {
        self.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.build = build
    }

    /// Reads `CFBundleShortVersionString` and `CFBundleVersion` from an Info.plist
    /// dictionary. `nil` when there is no version, as in a bare development build.
    public init?(infoDictionary: [String: Any]?) {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return nil
        }
        let build = (infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        self.init(version: version, build: build)
    }

    /// The version of the app bundle at `url`, read from its Info.plist on disk.
    public init?(bundleAt url: URL) {
        self.init(infoDictionary: Self.infoDictionary(ofBundleAt: url))
    }

    /// Reads a bundle's Info.plist directly. `Bundle(url:)` caches what it read
    /// the first time, which is wrong for a bundle that gets replaced.
    public static func infoDictionary(ofBundleAt url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The numbers in the version string. Each dot-separated part counts up to
    /// its first non-digit ("0-beta" is 0), and trailing zeros are dropped.
    var components: [Int] {
        var numbers = version.split(separator: ".", omittingEmptySubsequences: false).map { part -> Int in
            Int(part.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
        while numbers.last == 0 { numbers.removeLast() }
        return numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let left = lhs.components
        let right = rhs.components
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return lhs.build < rhs.build
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components == rhs.components && lhs.build == rhs.build
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
        hasher.combine(build)
    }

    public var description: String { "\(version) (\(build))" }
}
