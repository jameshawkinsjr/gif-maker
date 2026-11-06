import XCTest

@testable import GifMakerCore

@MainActor
final class RecordingStoreTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gifmaker-store-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Adds a recording backed by a placeholder movie file.
    private func addRecording(to store: RecordingStore, createdAt: Date = Date()) throws -> Recording {
        let recording = Recording(createdAt: createdAt, duration: 4, pixelWidth: 1280, pixelHeight: 800, scale: 2)
        try Data("movie".utf8).write(to: store.videoURL(for: recording))
        store.add(recording)
        return recording
    }

    func testNewRecordingDefaultsToItsOnScreenSize() {
        let retina = Recording(duration: 4, pixelWidth: 1280, pixelHeight: 800, scale: 2)
        XCTAssertEqual(retina.pointWidth, 640)
        XCTAssertEqual(retina.settings.outputWidth, 640, "a Retina capture exports at its on-screen size by default")
        XCTAssertEqual(retina.settings.trimEnd, 4)

        let huge = Recording(duration: 4, pixelWidth: 3000, pixelHeight: 1000, scale: 1)
        XCTAssertEqual(huge.settings.outputWidth, Recording.defaultMaximumOutputWidth)

        let tiny = Recording(duration: 4, pixelWidth: 40, pixelHeight: 40, scale: 1)
        XCTAssertEqual(tiny.outputWidthRange, 40...40)
    }

    func testRecordingsAndTheirEditsSurviveReloading() throws {
        let store = RecordingStore(directory: directory)
        let older = try addRecording(to: store, createdAt: Date(timeIntervalSinceNow: -100))
        var newer = try addRecording(to: store)

        newer.settings.loopType = .pingPong
        newer.settings.trimStart = 1.5
        newer.settings.captions = [Caption(text: "Hello", start: 0, end: 2, font: .meme, animation: .drop)]
        store.update(newer)

        let reloaded = RecordingStore(directory: directory)
        XCTAssertEqual(reloaded.recordings.map(\.id), [newer.id, older.id], "newest first")
        XCTAssertEqual(reloaded.recordings.first, newer)
        XCTAssertEqual(reloaded.recording(withID: older.id), older)
    }

    func testDeletingRemovesTheMovieAndItsMetadata() throws {
        let store = RecordingStore(directory: directory)
        let recording = try addRecording(to: store)
        let kept = try addRecording(to: store)

        store.delete(recording)

        XCTAssertEqual(store.recordings.map(\.id), [kept.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.videoURL(for: recording).path))
        XCTAssertEqual(RecordingStore(directory: directory).recordings.map(\.id), [kept.id])

        store.deleteAll()
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testMetadataWithoutItsMovieIsIgnored() throws {
        let store = RecordingStore(directory: directory)
        let recording = try addRecording(to: store)
        try FileManager.default.removeItem(at: store.videoURL(for: recording))
        XCTAssertTrue(RecordingStore(directory: directory).recordings.isEmpty)
    }

    func testOnlyAbandonedMoviesAreCleanedUp() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let abandoned = directory.appendingPathComponent("\(UUID().uuidString).mov")
        let inProgress = directory.appendingPathComponent("\(UUID().uuidString).mov")
        let unreadable = directory.appendingPathComponent("\(UUID().uuidString).mov")
        for file in [abandoned, inProgress, unreadable] { try Data("movie".utf8).write(to: file) }
        // Metadata that exists but can't be decoded (say, written by a newer version).
        try Data("not json".utf8).write(to: unreadable.deletingPathExtension().appendingPathExtension("json"))
        let longAgo = Date(timeIntervalSinceNow: -RecordingStore.orphanGracePeriod - 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: abandoned.path)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: unreadable.path)

        let store = RecordingStore(directory: directory)

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path), "old movie with no metadata is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgress.path), "a recent movie may still be recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path), "unreadable metadata isn't grounds to delete")
    }
}
