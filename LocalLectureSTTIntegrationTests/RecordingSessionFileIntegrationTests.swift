import AVFoundation
import Foundation
import XCTest
@testable import LocalLectureSTT

final class RecordingSessionFileIntegrationTests: XCTestCase {
    func testProductionCaptureRepositoryRootRecorderAndCatalogPersistDecodableRecoveryAudio() async throws {
        let fixture = try RecordingFileIntegrationFixture()
        defer { fixture.cleanup() }

        let roots = StorageRootManager(
            applicationSupportDirectory: fixture.applicationSupport,
            bookmarkCodec: fixture.bookmarks
        )
        let rootSummary = try await roots.registerSelectedDirectory(fixture.root)
        let permission = AuthorizedIntegrationPermission()
        let driver = SyntheticIntegrationCaptureDriver(chunkCount: 32, framesPerChunk: 2_048)
        let monitor = InputSignalMonitor(
            clock: FixedIntegrationMonotonicClock(),
            scheduler: NoopIntegrationSignalScheduler()
        )
        let capture = MicrophoneCaptureController(
            permission: permission,
            driver: driver,
            buffers: CaptureBufferConfiguration(recordingCapacity: 64, speechCapacity: 4),
            monitor: monitor
        )
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: fixture.applicationSupport)
        let catalog = SessionCatalogReconciler(
            scanner: SessionFileScanner(roots: roots),
            store: store
        )
        let coordinator = RecordingSessionCoordinator(
            roots: roots,
            permission: permission,
            capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) },
            repository: repository,
            catalog: catalog,
            environment: RecordingSessionEnvironment(appVersion: "0.1.0-integration", osVersion: "integrationOS")
        )

        let initialBookmarkCounts = await fixture.bookmarks.counts()
        let initialPermissionCounts = await permission.counts()
        let initialDriverCounts = await driver.counts()
        XCTAssertEqual(initialBookmarkCounts.start, 0)
        XCTAssertEqual(initialBookmarkCounts.stop, 0)
        XCTAssertEqual(initialPermissionCounts, .init(status: 0, request: 0))
        XCTAssertEqual(initialDriverCounts, .init(prepare: 0, start: 0, stop: 0))

        let started = try await coordinator.start(.init(
            title: "  Production synthetic recording  ",
            languageMode: .english,
            timeZone: .gmt
        ))
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.title, "Production synthetic recording")
        XCTAssertEqual(started.languageMode, .english)
        XCTAssertEqual(started.microphoneDisplayName, "Synthetic Integration Input")

        let result = await coordinator.stop()
        guard case let .secured(secured) = result else {
            return XCTFail("Expected a secured recovery-audio result, got \(result)")
        }

        let sessionDirectory = fixture.root.appendingPathComponent(secured.location.folderName.rawValue, isDirectory: true)
        let recoveryURL = sessionDirectory.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)
        let recoveryBytes = try Data(contentsOf: recoveryURL).count
        let decode = try await decodeIntegrationAsset(at: recoveryURL)
        XCTAssertGreaterThan(recoveryBytes, 0)
        XCTAssertGreaterThan(decode.sampleBufferCount, 0)
        XCTAssertGreaterThan(decode.decodedBytes, 0)
        XCTAssertGreaterThan(decode.durationSeconds, 0)
        XCTAssertEqual(secured.recorderSummary.location, secured.location)
        XCTAssertEqual(secured.recorderSummary.artifact, .recoveryAudio)
        XCTAssertEqual(secured.recorderSummary.writtenFrameCount, 32 * 2_048)
        XCTAssertGreaterThan(secured.recorderSummary.mediaDurationMilliseconds, 0)

        let metadata = try await repository.readMetadata(at: secured.location)
        XCTAssertEqual(metadata.sessionId, secured.location.sessionID)
        XCTAssertEqual(metadata.title, "Production synthetic recording")
        XCTAssertEqual(metadata.languageMode, .english)
        XCTAssertEqual(metadata.status, .securing)
        XCTAssertEqual(metadata.captureOutcome, .completed)
        XCTAssertNotNil(metadata.recordingStartedAt)
        XCTAssertNotNil(metadata.recordingEndedAt)
        XCTAssertEqual(metadata.activeDurationMs.rawValue, Int64(secured.recorderSummary.mediaDurationMilliseconds))
        XCTAssertEqual(metadata.audio?.format, "AAC-LC fragmented QuickTime")
        XCTAssertEqual(metadata.audio?.sampleRate, 48_000)
        XCTAssertEqual(metadata.audio?.channels, 1)
        XCTAssertEqual(metadata.audio?.bitRate, 96_000)
        XCTAssertEqual(metadata.transcript.segmentCount.rawValue, 0)
        XCTAssertNil(metadata.engine)
        XCTAssertNil(metadata.model)
        XCTAssertNil(metadata.detectedLanguage)

        let eventsURL = sessionDirectory.appendingPathComponent(SessionArtifact.events.relativePath)
        let events = try decodeIntegrationEvents(at: eventsURL)
        XCTAssertEqual(events.map(\.kind), [.recordingStarted, .recordingEnded])
        XCTAssertTrue(events.allSatisfy { $0.sessionId == secured.location.sessionID })
        XCTAssertEqual(Set(events.map { $0.eventId.rawValue }).count, events.count)
        XCTAssertEqual(events.first?.mediaPositionMs?.rawValue, 0)
        XCTAssertEqual(events.last?.mediaPositionMs?.rawValue, Int64(secured.recorderSummary.mediaDurationMilliseconds))

        for artifact in [
            SessionArtifact.finalAudio,
            .transcript,
            .transcriptText,
            .transcriptMarkdown,
            .transcriptJournal,
            .finalizationCheckpoint
        ] {
            let url = sessionDirectory.appendingPathComponent(artifact.relativePath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Unexpected T08+ artifact: \(artifact)")
        }

        let catalogItems = try await catalog.orderedItems()
        XCTAssertEqual(catalogItems.count, 1)
        XCTAssertEqual(catalogItems.first?.sessionID, secured.location.sessionID)
        XCTAssertEqual(catalogItems.first?.rootID, rootSummary.id)
        XCTAssertEqual(catalogItems.first?.title, metadata.title)
        XCTAssertEqual(catalogItems.first?.metadataStatus, .securing)
        XCTAssertEqual(catalogItems.first?.captureOutcome, .completed)
        XCTAssertEqual(catalogItems.first?.activeDuration, metadata.activeDurationMs)

        let permissionCounts = await permission.counts()
        let driverCounts = await driver.counts()
        let bookmarkCounts = await fixture.bookmarks.counts()
        XCTAssertEqual(permissionCounts, .init(status: 2, request: 0))
        XCTAssertEqual(driverCounts, .init(prepare: 1, start: 1, stop: 1))
        XCTAssertGreaterThan(bookmarkCounts.start, 0)
        XCTAssertEqual(bookmarkCounts.start, bookmarkCounts.stop)

        try await store.close()
        print(
            "T07_INTEGRATION_EVIDENCE recoveryBytes=\(recoveryBytes) " +
            "sampleBuffers=\(decode.sampleBufferCount) decodedBytes=\(decode.decodedBytes) " +
            "durationMs=\(secured.recorderSummary.mediaDurationMilliseconds) " +
            "bookmarkScopes=\(bookmarkCounts.start)/\(bookmarkCounts.stop)"
        )
    }
}

private struct IntegrationPermissionCounts: Sendable, Equatable {
    var status: Int
    var request: Int
}

private actor AuthorizedIntegrationPermission: MicrophonePermissionAuthorizing {
    private var value = IntegrationPermissionCounts(status: 0, request: 0)

    func authorizationStatus() async -> MicrophonePermissionStatus {
        value.status += 1
        return .authorized
    }

    func requestAuthorization() async -> MicrophonePermissionStatus {
        value.request += 1
        return .authorized
    }

    func counts() -> IntegrationPermissionCounts { value }
}

private struct IntegrationDriverCounts: Sendable, Equatable {
    var prepare: Int
    var start: Int
    var stop: Int
}

private actor SyntheticIntegrationCaptureDriver: MicrophoneCaptureDriving {
    private let chunkCount: Int
    private let framesPerChunk: Int
    private var generation: UInt64?
    private var chunkCallback: (@Sendable (PCMChunk) -> Void)?
    private var value = IntegrationDriverCounts(prepare: 0, start: 0, stop: 0)

    init(chunkCount: Int, framesPerChunk: Int) {
        self.chunkCount = chunkCount
        self.framesPerChunk = framesPerChunk
    }

    func prepare(
        generation: UInt64,
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async throws -> InputDeviceSnapshot {
        value.prepare += 1
        self.generation = generation
        chunkCallback = onChunk
        return InputDeviceSnapshot(identity: "synthetic-integration", displayName: "Synthetic Integration Input")
    }

    func start() async throws {
        value.start += 1
        guard let generation, let chunkCallback else { throw CaptureError(.engineStartFailed) }
        let format = try PCMFormatDescription(sampleRate: 48_000, channelCount: 1)
        for sequence in 0 ..< chunkCount {
            let sampleOffset = sequence * framesPerChunk
            let samples = (0 ..< framesPerChunk).map { frame -> Float in
                let phase = Double(sampleOffset + frame) * 2 * Double.pi * 440 / 48_000
                return Float(sin(phase) * 0.2)
            }
            let chunk = try PCMChunk(
                generation: generation,
                sequence: UInt64(sequence),
                format: format,
                frameCount: framesPerChunk,
                sourceSampleTime: Int64(sampleOffset),
                samples: samples
            )
            chunkCallback(chunk)
        }
    }

    func stop() async {
        value.stop += 1
        generation = nil
        chunkCallback = nil
    }

    func counts() -> IntegrationDriverCounts { value }
}

private struct IntegrationBookmarkCounts: Sendable, Equatable {
    var start: Int
    var stop: Int
}

private actor CountingPathBookmarkCodec: SecurityScopedBookmarkCodec {
    private var value = IntegrationBookmarkCounts(start: 0, stop: 0)

    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }

    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        ResolvedBookmark(
            url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self), isDirectory: true),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) async -> Bool {
        value.start += 1
        return true
    }

    func stopAccessing(_ url: URL) async { value.stop += 1 }
    func counts() -> IntegrationBookmarkCounts { value }
}

private struct FixedIntegrationMonotonicClock: MonotonicClock {
    func now() -> TimeInterval { 100 }
}

private final class NoopIntegrationSignalScheduler: InputSignalScheduling, @unchecked Sendable {
    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {}
    func stop() {}
}

private final class RecordingFileIntegrationFixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let applicationSupport: URL
    let bookmarks = CountingPathBookmarkCodec()

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLectureSTT-T07-Integration-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("selected-root", isDirectory: true)
        applicationSupport = base.appendingPathComponent("application-support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private struct IntegrationDecodeEvidence: Sendable {
    let sampleBufferCount: Int
    let decodedBytes: Int
    let durationSeconds: Double
}

private func decodeIntegrationAsset(at url: URL) async throws -> IntegrationDecodeEvidence {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.load(.tracks)
    guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
        throw AudioRecorderError(.writerFinishFailed)
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    )
    output.alwaysCopiesSampleData = true
    guard reader.canAdd(output) else { throw AudioRecorderError(.writerFinishFailed) }
    reader.add(output)
    guard reader.startReading() else { throw AudioRecorderError(.writerFinishFailed) }

    var count = 0
    var bytes = 0
    while let sample = output.copyNextSampleBuffer() {
        count += 1
        bytes += CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0
    }
    guard reader.status == .completed else { throw AudioRecorderError(.writerFinishFailed) }
    let duration = try await asset.load(.duration)
    return IntegrationDecodeEvidence(
        sampleBufferCount: count,
        decodedBytes: bytes,
        durationSeconds: CMTimeGetSeconds(duration)
    )
}

private func decodeIntegrationEvents(at url: URL) throws -> [SessionEventRecord] {
    let data = try Data(contentsOf: url)
    return try data.split(separator: 0x0A).map { line in
        try JSONDecoder().decode(SessionEventRecord.self, from: Data(line))
    }
}
