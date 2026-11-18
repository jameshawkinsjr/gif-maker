import XCTest

@testable import GifMakerCore

final class AppVersionTests: XCTestCase {
    private func version(_ string: String, _ build: Int = 1) -> AppVersion {
        AppVersion(version: string, build: build)
    }

    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(version("1.9"), version("1.10"), "not compared as text")
        XCTAssertLessThan(version("1.2.9"), version("1.3"))
        XCTAssertLessThan(version("1.2"), version("1.2.1"))
        XCTAssertLessThan(version("1.99.99"), version("2"))
        XCTAssertGreaterThan(version("10.0"), version("9.9.9"))
    }

    func testTrailingZerosDoNotMatter() {
        XCTAssertEqual(version("1.2"), version("1.2.0"))
        XCTAssertEqual(version("1.2").hashValue, version("1.2.0").hashValue)
        XCTAssertFalse(version("1.2") < version("1.2.0"))
        XCTAssertFalse(version("1.2.0") < version("1.2"))
    }

    func testBuildNumberBreaksTies() {
        XCTAssertLessThan(version("1.2.0", 14), version("1.2.0", 15))
        XCTAssertNotEqual(version("1.2.0", 14), version("1.2.0", 15))
        XCTAssertLessThan(version("1.2.0", 99), version("1.2.1", 1), "the version string comes first")
    }

    func testOddVersionStringsStillCompare() {
        XCTAssertEqual(version(" 1.2.0\n"), version("1.2.0"))
        XCTAssertEqual(version("1.2.0-beta"), version("1.2.0"), "a suffix is ignored")
        XCTAssertLessThan(version("1.2.0-beta"), version("1.2.1"))
        XCTAssertLessThan(version("nonsense"), version("0.0.1"))
    }

    func testReadsTheVersionFromAnInfoDictionary() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "37"]
        XCTAssertEqual(AppVersion(infoDictionary: info), AppVersion(version: "1.4.2", build: 37))
        XCTAssertEqual(AppVersion(infoDictionary: info)?.description, "1.4.2 (37)")
        XCTAssertEqual(AppVersion(infoDictionary: ["CFBundleShortVersionString": "2.0"])?.build, 0)
        XCTAssertNil(AppVersion(infoDictionary: ["CFBundleVersion": "37"]), "a bare build has no version")
        XCTAssertNil(AppVersion(infoDictionary: nil))
    }
}

final class ReleaseManifestTests: XCTestCase {
    private let checksum = String(repeating: "ab", count: 32)

    private func decode(_ json: String) throws -> ReleaseManifest {
        try ReleaseManifest.decode(Data(json.utf8))
    }

    func testDecodesWhatThePublishScriptWrites() throws {
        let manifest = try decode(
            """
            {
              "build" : 14,
              "file" : "GIF-Maker-1.2.0.dmg",
              "notes" : "Fixes the thing.",
              "sha256" : "\(checksum.uppercased())",
              "size" : 4123456,
              "version" : "1.2.0"
            }
            """)
        XCTAssertEqual(manifest.appVersion, AppVersion(version: "1.2.0", build: 14))
        XCTAssertEqual(manifest.file, "GIF-Maker-1.2.0.dmg")
        XCTAssertEqual(manifest.sha256, checksum, "compared in lowercase")
        XCTAssertEqual(manifest.size, 4_123_456)
        XCTAssertEqual(manifest.notes, "Fixes the thing.")
    }

    func testSizeAndNotesAreOptional() throws {
        let manifest = try decode(
            #"{"version": "1.2.0", "build": 14, "file": "a.dmg", "sha256": "\#(checksum)", "notes": "  "}"#)
        XCTAssertNil(manifest.size)
        XCTAssertNil(manifest.notes, "blank notes count as none")
    }

    func testMalformedManifestsAreRejected() {
        func error(_ json: String) -> ReleaseManifest.ValidationError? {
            do {
                _ = try decode(json)
                return nil
            } catch {
                return error as? ReleaseManifest.ValidationError
            }
        }
        func manifest(version: String = "1.2.0", build: String = "14", file: String = "a.dmg", sha256: String? = nil)
            -> String
        {
            #"{"version": "\#(version)", "build": \#(build), "file": "\#(file)", "sha256": "\#(sha256 ?? checksum)"}"#
        }

        XCTAssertNil(error(manifest()), "the baseline is valid")
        XCTAssertEqual(error(""), .notJSON)
        XCTAssertEqual(error("not json"), .notJSON)
        XCTAssertEqual(error(#"{"version": "1.2.0"}"#), .notJSON, "missing fields")
        XCTAssertEqual(error(String(manifest().dropLast(20))), .notJSON, "a half-written file")
        XCTAssertEqual(error(manifest(build: #""fourteen""#)), .notJSON)
        XCTAssertEqual(error(manifest(version: "")), .missingVersion)
        XCTAssertEqual(error(manifest(version: "latest")), .missingVersion)
        XCTAssertEqual(error(manifest(build: "-1")), .invalidBuild)
        XCTAssertEqual(error(manifest(sha256: "abc123")), .invalidChecksum)
        XCTAssertEqual(error(manifest(sha256: String(repeating: "zz", count: 32))), .invalidChecksum)
    }

    /// The manifest comes from a shared folder, so it mustn't be able to name a file anywhere else.
    func testFileNameCannotLeaveTheFolder() {
        for file in ["../evil.dmg", "/tmp/evil.dmg", "sub/evil.dmg", ".hidden.dmg", "", "evil.app", "a:b.dmg"] {
            let json = #"{"version": "1.2.0", "build": 14, "file": "\#(file)", "sha256": "\#(checksum)"}"#
            XCTAssertThrowsError(try decode(json), file) {
                XCTAssertEqual($0 as? ReleaseManifest.ValidationError, .unsafeFileName)
            }
        }
    }
}

final class UpdateCheckerTests: XCTestCase {
    var folder: URL!
    let current = AppVersion(version: "1.2.0", build: 14)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gifmaker-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private var checker: UpdateChecker { UpdateChecker(folder: folder, currentVersion: current) }

    /// Publishes a stand-in disk image and its manifest, the way `make-dmg.sh` does.
    @discardableResult
    private func publish(
        version: String, build: Int, contents: String = "disk image", writeDiskImage: Bool = true,
        sha256: String? = nil, size: Int64? = nil
    ) throws -> ReleaseManifest {
        let file = "GIF-Maker-\(version).dmg"
        let diskImage = folder.appendingPathComponent(file)
        let data = Data(contents.utf8)
        try data.write(to: diskImage)
        let manifest = ReleaseManifest(
            version: version, build: build, file: file, sha256: try sha256 ?? FileChecksum.sha256(of: diskImage),
            size: size ?? Int64(data.count))
        if !writeDiskImage { try FileManager.default.removeItem(at: diskImage) }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(ReleaseManifest.fileName))
        return manifest
    }

    func testNewerVersionIsAvailable() throws {
        let manifest = try publish(version: "1.3.0", build: 20)
        guard case .available(let update) = checker.check() else { return XCTFail("\(checker.check())") }
        XCTAssertEqual(update.manifest, manifest)
        XCTAssertEqual(update.version, AppVersion(version: "1.3.0", build: 20))
        XCTAssertEqual(update.diskImageURL.lastPathComponent, "GIF-Maker-1.3.0.dmg")
        XCTAssertEqual(update.diskImageURL.deletingLastPathComponent().path, folder.path)
    }

    func testSameVersionWithANewerBuildIsAvailable() throws {
        try publish(version: "1.2.0", build: 15)
        guard case .available = checker.check() else { return XCTFail("\(checker.check())") }
    }

    func testSameAndOlderVersionsAreUpToDate() throws {
        try publish(version: "1.2.0", build: 14)
        XCTAssertEqual(checker.check(), .upToDate)
        try publish(version: "1.2", build: 14)
        XCTAssertEqual(checker.check(), .upToDate)
        try publish(version: "1.1.9", build: 99)
        XCTAssertEqual(checker.check(), .upToDate)
        // An older release doesn't need its disk image to be there.
        try publish(version: "1.0.0", build: 3, writeDiskImage: false)
        XCTAssertEqual(checker.check(), .upToDate)
    }

    func testMissingFolderIsAQuietFailure() {
        let missing = UpdateChecker(folder: folder.appendingPathComponent("not-mounted"), currentVersion: current)
        XCTAssertEqual(missing.check(), .failed(.folderUnavailable))
        // A file where the folder should be.
        let file = folder.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertEqual(UpdateChecker(folder: file, currentVersion: current).check(), .failed(.folderUnavailable))
    }

    func testFolderWithoutAManifest() {
        XCTAssertEqual(checker.check(), .failed(.noManifest))
    }

    func testMalformedManifest() throws {
        try Data("{ \"version\": ".utf8).write(to: folder.appendingPathComponent(ReleaseManifest.fileName))
        guard case .failed(.malformedManifest) = checker.check() else { return XCTFail("\(checker.check())") }
    }

    func testManifestWithoutItsDiskImage() throws {
        try publish(version: "1.3.0", build: 20, writeDiskImage: false)
        XCTAssertEqual(checker.check(), .failed(.diskImageMissing("GIF-Maker-1.3.0.dmg")))
    }

    func testPartlySyncedDiskImageIsNotReadyYet() throws {
        // Right size, wrong contents.
        try publish(version: "1.3.0", build: 20, sha256: String(repeating: "0", count: 64))
        XCTAssertEqual(checker.check(), .failed(.stillSyncing("GIF-Maker-1.3.0.dmg")))
        // Shorter than the manifest says.
        try publish(version: "1.3.0", build: 20, size: 1_000_000)
        XCTAssertEqual(checker.check(), .failed(.stillSyncing("GIF-Maker-1.3.0.dmg")))
        // And once the rest arrives, it's offered.
        try publish(version: "1.3.0", build: 20)
        guard case .available = checker.check() else { return XCTFail("\(checker.check())") }
    }

    func testCloudPlaceholdersCountAsStillSyncing() throws {
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(".latest.json.icloud").path, contents: Data())
        XCTAssertEqual(checker.check(), .failed(.stillSyncing("latest.json")))

        try publish(version: "1.3.0", build: 20, writeDiskImage: false)
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(".GIF-Maker-1.3.0.dmg.icloud").path, contents: Data())
        XCTAssertEqual(checker.check(), .failed(.stillSyncing("GIF-Maker-1.3.0.dmg")))
    }

    func testEveryFailureHasAMessage() {
        let failures: [UpdateCheckFailure] = [
            .folderUnavailable, .noManifest, .malformedManifest("it has no version"), .diskImageMissing("a.dmg"),
            .stillSyncing("a.dmg"),
        ]
        for failure in failures { XCTAssertFalse(failure.message.isEmpty) }
    }
}

final class FileChecksumTests: XCTestCase {
    func testMatchesKnownSHA256Values() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gifmaker-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertEqual(
            try FileChecksum.sha256(of: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let abc = directory.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(
            try FileChecksum.sha256(of: abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // Bigger than one read, to cover the chunked path: a million "a"s.
        let large = directory.appendingPathComponent("large")
        try Data(repeating: UInt8(ascii: "a"), count: 1_000_000).write(to: large)
        XCTAssertEqual(
            try FileChecksum.sha256(of: large), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

        XCTAssertThrowsError(try FileChecksum.sha256(of: directory.appendingPathComponent("missing")))
    }
}

/// Runs the real swap script against stand-in app bundles.
final class UpdateInstallPlanTests: XCTestCase {
    var directory: URL!
    var installed: URL!
    var launched: URL!

    override func setUpWithError() throws {
        // The physical path, as the script's check for the running app compares paths.
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("gifmaker-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        installed = directory.appendingPathComponent("Stand In.app")
        launched = directory.appendingPathComponent("launched")
        try makeApp(at: installed, marker: "old")
    }

    override func tearDown() {
        // Stop any stand-in app the test left running.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", directory.lastPathComponent]
        try? kill.run()
        kill.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A folder shaped like an app. Its "executable" is a link to `sleep`, so
    /// starting it gives a process that shows up under the bundle's path.
    private func makeApp(at url: URL, marker: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: macOS.appendingPathComponent("StandIn"), withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/marker"))
    }

    private func marker(of url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    /// Stands in for `open`: records its arguments and, if asked to, starts the
    /// app's executable for `lifetime` seconds.
    private func makeOpener(lifetime: Double?, exitStatus: Int = 0) throws -> String {
        let url = directory.appendingPathComponent("opener.sh")
        var script = "#!/bin/sh\necho \"$@\" >> '\(launched.path)'\n"
        if let lifetime { script += "\"$2/Contents/MacOS/StandIn\" \(lifetime) >/dev/null 2>&1 &\n" }
        script += "exit \(exitStatus)\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func plan(opener: String, processID: Int32 = 999_999) -> UpdateInstallPlan {
        var plan = UpdateInstallPlan(
            processID: processID, installedApp: installed, executablePath: "Contents/MacOS/StandIn",
            relaunchArguments: [UpdateInstallPlan.LaunchArgument.signatureChanged])
        plan.opener = opener
        plan.quitTimeout = 1
        plan.launchTimeout = 1
        plan.settleTime = 1
        return plan
    }

    private func run(_ plan: UpdateInstallPlan) throws -> (status: Int32, log: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = plan.shellArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // The stand-in app inherits the pipe, so read only until the script exits.
        process.waitUntilExit()
        let log = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        return (process.terminationStatus, log)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private var launches: [String] {
        ((try? String(contentsOf: launched, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testStagedAndBackupCopiesSitBesideTheApp() {
        let app = URL(fileURLWithPath: "/Applications/GIF Maker.app")
        XCTAssertEqual(UpdateInstallPlan.stagedURL(for: app).path, "/Applications/.GIF Maker.app.update")
        XCTAssertEqual(UpdateInstallPlan.backupURL(for: app).path, "/Applications/.GIF Maker.app.previous")
    }

    func testSwapsInTheNewVersionAndStartsIt() throws {
        let plan = plan(opener: try makeOpener(lifetime: 30))
        try makeApp(at: plan.stagedApp, marker: "new")

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.installed, result.log)
        XCTAssertEqual(marker(of: installed), "new")
        XCTAssertFalse(exists(plan.stagedApp))
        XCTAssertFalse(exists(plan.backupApp), "the old version goes once the new one is running")
        XCTAssertEqual(launches, ["-n \(installed.path) --args --updated --update-signature-changed"])
    }

    func testWaitsForTheRunningAppToQuit() throws {
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.6"]
        try app.run()
        var plan = plan(opener: try makeOpener(lifetime: 30), processID: app.processIdentifier)
        plan.quitTimeout = 10
        try makeApp(at: plan.stagedApp, marker: "new")
        // Reap the stand-in when it exits, as launchd does for a real app.
        DispatchQueue.global().async { app.waitUntilExit() }

        let started = Date()
        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.installed, result.log)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(marker(of: installed), "new")
    }

    func testLeavesEverythingAloneIfTheAppNeverQuits() throws {
        let plan = plan(opener: try makeOpener(lifetime: 30), processID: ProcessInfo.processInfo.processIdentifier)
        try makeApp(at: plan.stagedApp, marker: "new")

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.appStillRunning, result.log)
        XCTAssertEqual(marker(of: installed), "old")
        XCTAssertFalse(exists(plan.stagedApp), "the unused copy is cleaned up")
        XCTAssertEqual(launches, [], "nothing is relaunched over a running app")
    }

    func testRestoresThePreviousVersionWhenTheNewOneCannotBeOpened() throws {
        let plan = plan(opener: try makeOpener(lifetime: nil, exitStatus: 1))
        try makeApp(at: plan.stagedApp, marker: "new")

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.rolledBack, result.log)
        XCTAssertEqual(marker(of: installed), "old")
        XCTAssertFalse(exists(plan.stagedApp))
        XCTAssertFalse(exists(plan.backupApp))
        XCTAssertEqual(launches.last, "-n \(installed.path) --args --update-failed", "the old version is reopened")
    }

    func testRestoresThePreviousVersionWhenTheNewOneCrashesOnLaunch() throws {
        let plan = plan(opener: try makeOpener(lifetime: 0.3))
        try makeApp(at: plan.stagedApp, marker: "new")

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.rolledBack, result.log)
        XCTAssertEqual(marker(of: installed), "old")
        XCTAssertFalse(exists(plan.backupApp))
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.last, "-n \(installed.path) --args --update-failed")
    }

    func testRestoresThePreviousVersionWhenTheNewOneNeverAppears() throws {
        let plan = plan(opener: try makeOpener(lifetime: nil))
        try makeApp(at: plan.stagedApp, marker: "new")

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.rolledBack, result.log)
        XCTAssertEqual(marker(of: installed), "old")
    }

    func testDoesNothingWithoutAStagedCopy() throws {
        let plan = plan(opener: try makeOpener(lifetime: 30))

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.notInstalled, result.log)
        XCTAssertEqual(marker(of: installed), "old")
        XCTAssertEqual(launches, ["-n \(installed.path) --args --update-failed"])
    }

    func testAStaleBackupDoesNotGetInTheWay() throws {
        let plan = plan(opener: try makeOpener(lifetime: 30))
        try makeApp(at: plan.stagedApp, marker: "new")
        try makeApp(at: plan.backupApp, marker: "stale")

        let result = try run(plan)

        XCTAssertEqual(result.status, UpdateInstallPlan.ExitStatus.installed, result.log)
        XCTAssertEqual(marker(of: installed), "new")
        XCTAssertFalse(exists(plan.backupApp))
    }
}
