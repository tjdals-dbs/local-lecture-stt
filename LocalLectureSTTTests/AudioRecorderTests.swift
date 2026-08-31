@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import LocalLectureSTT

final class AudioRecorderTests: XCTestCase {
    func testRecoveryWriterStoresSyntheticRecordingWithoutSpeechConsumer() async throws {
        let fixture = try RecorderFixture()
        defer { fixture.cleanup() }
        let codec = RecorderBookmarkCodec(url: fixture.root)
        let manager = fixture.manager(codec: codec)
        _ = try await manager.registerSelectedDirectory(fixture.root)
        let location = try await fixture.location(using: manager)
        let recorder = AVFoundationAudioRecorder(roots: manager)

        try await recorder.start(at: location, expectedCaptureGeneration: 7)
        for sequence in 0..<12 {
            try await recorder.append(try fixture.chunk(generation: 7, sequence: UInt64(sequence), sampleRate: 48_000, channels: 1, frames: 4_800))
            try await Task.sleep(for: .milliseconds(250))
        }
        try await recorder.flush()
        let activeOutput = fixture.recoveryURL(for: location)
        let activeBytes = try Data(contentsOf: activeOutput)
        XCTAssertFalse(activeBytes.isEmpty)
        let activeAsset = AVURLAsset(url: activeOutput)
        let activeTracks = try await activeAsset.load(.tracks)
        XCTAssertEqual(activeTracks.filter { $0.mediaType == .audio }.count, 1)
        let summary = try await recorder.stop()

        let output = fixture.recoveryURL(for: location)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThanOrEqual(try Data(contentsOf: output).boxMarkerCount(named: "moof"), 1)
        XCTAssertEqual(summary.artifact, .recoveryAudio)
        XCTAssertEqual(summary.outputFormat, .recoveryAAC)
        XCTAssertGreaterThan(summary.writtenFrameCount, 0)
        let stopCount = await codec.stopCount()
        XCTAssertGreaterThanOrEqual(stopCount, 1)

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.load(.tracks)
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(tracks.filter { $0.mediaType == .video }.count, 0)
        let descriptions = try await audioTracks[0].load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
        XCTAssertEqual(asbd.mSampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.5)
    }

    func testSequenceGenerationFormatAndCollisionFailuresPreserveExistingArtifact() async throws {
        let fixture = try RecorderFixture()
        defer { fixture.cleanup() }
        let codec = RecorderBookmarkCodec(url: fixture.root)
        let manager = fixture.manager(codec: codec)
        _ = try await manager.registerSelectedDirectory(fixture.root)
        let location = try await fixture.location(using: manager)
        let existing = fixture.recoveryURL(for: location)
        let original = Data("preserve-me".utf8)
        try original.write(to: existing)
        let collisionRecorder = AVFoundationAudioRecorder(roots: manager)
        do {
            try await collisionRecorder.start(at: location, expectedCaptureGeneration: 1)
            XCTFail("Expected collision")
        } catch let error as AudioRecorderError { XCTAssertEqual(error.code, .recoveryArtifactExists) }
        XCTAssertEqual(try Data(contentsOf: existing), original)
        let collisionStarts = await codec.startCount()
        let collisionStops = await codec.stopCount()
        XCTAssertEqual(collisionStarts, collisionStops)

        try FileManager.default.removeItem(at: existing)
        let recorder = AVFoundationAudioRecorder(roots: manager)
        try await recorder.start(at: location, expectedCaptureGeneration: 3)
        try await recorder.append(try fixture.chunk(generation: 3, sequence: 0, sampleRate: 44_100, channels: 2, frames: 4_410))
        do {
            try await recorder.append(try fixture.chunk(generation: 3, sequence: 2, sampleRate: 44_100, channels: 2, frames: 4_410))
            XCTFail("Expected sequence failure")
        } catch let error as AudioRecorderError { XCTAssertEqual(error.code, .sequenceDiscontinuity) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        let failureStarts = await codec.startCount()
        let failureStops = await codec.stopCount()
        XCTAssertEqual(failureStarts, failureStops)
    }
}

private extension Data {
    func boxMarkerCount(named name: String) -> Int {
        let needle = Array(name.utf8)
        guard needle.count == 4, count >= 8 else { return 0 }
        return indices.dropFirst(4).filter { index in
            guard index >= 4, index + 3 < endIndex else { return false }
            return self[index] == needle[0] && self[index + 1] == needle[1] && self[index + 2] == needle[2] && self[index + 3] == needle[3]
        }.count
    }
}

private actor RecorderBookmarkCodec: SecurityScopedBookmarkCodec {
    private let url: URL
    private var starts = 0
    private var stops = 0

    init(url: URL) { self.url = url }
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark { ResolvedBookmark(url: url, isStale: false) }
    func startAccessing(_ url: URL) async -> Bool { starts += 1; return true }
    func stopAccessing(_ url: URL) async { stops += 1 }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private final class RecorderFixture {
    let base: URL
    let root: URL
    let support: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLectureSTT-Recorder-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        support = base.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func manager(codec: RecorderBookmarkCodec) -> StorageRootManager {
        StorageRootManager(applicationSupportDirectory: support, bookmarkCodec: codec)
    }

    func location(using manager: StorageRootManager) async throws -> SessionLocation {
        let repository = FileSessionRepository(roots: manager)
        return try await repository.createSession(sessionID: SessionID(), createdAt: AbsoluteTime(Date()), timeZone: .gmt)
    }

    func recoveryURL(for location: SessionLocation) -> URL {
        root.appendingPathComponent(location.folderName.rawValue).appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
    }

    func chunk(generation: UInt64, sequence: UInt64, sampleRate: Double, channels: Int, frames: Int) throws -> PCMChunk {
        let format = try PCMFormatDescription(sampleRate: sampleRate, channelCount: channels)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = Float(sin(Double(frame) * 0.03)) * 0.2
            for channel in 0..<channels { samples[frame * channels + channel] = channel == 0 ? value : -value }
        }
        return try PCMChunk(generation: generation, sequence: sequence, format: format, frameCount: frames, sourceSampleTime: Int64(sequence) * Int64(frames), samples: samples)
    }
}
