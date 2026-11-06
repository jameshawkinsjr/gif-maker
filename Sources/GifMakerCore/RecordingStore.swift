import AVFoundation
import Combine
import CoreGraphics
import Foundation

/// The library of captured clips. Each clip is a `.mov` plus a `.json` with its
/// metadata and edit settings, stored in Application Support.
@MainActor
public final class RecordingStore: ObservableObject {
    /// Newest first.
    @Published public private(set) var recordings: [Recording] = []

    public let directory: URL
    private var thumbnails: [UUID: CGImage] = [:]

    public nonisolated static var defaultDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GIF Maker/Captures", isDirectory: true)
    }

    public init(directory: URL = RecordingStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    public func videoURL(for recording: Recording) -> URL {
        directory.appendingPathComponent(recording.videoFileName)
    }

    public func videoURL(forNewRecording id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).mov")
    }

    private func metadataURL(for recording: Recording) -> URL {
        directory.appendingPathComponent(recording.metadataFileName)
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Recording] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let recording = try? decoder.decode(Recording.self, from: data),
                FileManager.default.fileExists(atPath: videoURL(for: recording).path)
            else { continue }
            loaded.append(recording)
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recording) else { return }
        try? data.write(to: metadataURL(for: recording), options: .atomic)
    }

    public func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        save(recording)
    }

    /// Stores changed edit settings.
    public func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        guard recordings[index] != recording else { return }
        recordings[index] = recording
        save(recording)
    }

    public func recording(withID id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    public func delete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        thumbnails[recording.id] = nil
        try? FileManager.default.removeItem(at: videoURL(for: recording))
        try? FileManager.default.removeItem(at: metadataURL(for: recording))
    }

    public func deleteAll() {
        for recording in recordings { delete(recording) }
    }

    /// A small still from the start of the clip, cached after the first request.
    public func thumbnail(for recording: Recording) async -> CGImage? {
        if let cached = thumbnails[recording.id] { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL(for: recording)))
        generator.maximumSize = CGSize(width: 400, height: 240)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: min(0.1, recording.duration / 2), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        thumbnails[recording.id] = image
        return image
    }
}
