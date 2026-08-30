import Foundation
import XCTest
@testable import LocalLectureSTT

final class StorageRepositoryTests: XCTestCase {
    func testRootRegistryPreservesHistoricalRootAndRestoresActiveRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let codec = TestBookmarkCodec()
        let manager = fixture.manager(codec: codec)

        let first = try await manager.registerSelectedDirectory(fixture.rootA)
        let second = try await manager.registerSelectedDirectory(fixture.rootB)
        let reselected = try await manager.registerSelectedDirectory(fixture.rootA)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(reselected.id, first.id)
        let restored = fixture.manager(codec: codec)
        let restoredAvailability = await restored.availability()
        let stops = await codec.stopCount()
        XCTAssertEqual(restoredAvailability, .available(reselected, refreshedBookmark: false))
        XCTAssertEqual(stops, 1)
    }

    func testStaleBookmarkRefreshesSameRootAndFailedScopeDoesNotRunOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let codec = TestBookmarkCodec(stale: true)
        let manager = fixture.manager(codec: codec)
        let root = try await manager.registerSelectedDirectory(fixture.rootA)
        let refreshedAvailability = await manager.availability()
        let makeCount = await codec.makeCount()
        XCTAssertEqual(refreshedAvailability, .available(root, refreshedBookmark: true))
        XCTAssertGreaterThanOrEqual(makeCount, 2)

        await codec.setAccessAllowed(false)
        let deniedAvailability = await manager.availability()
        let stops = await codec.stopCount()
        XCTAssertEqual(deniedAvailability, .reauthorizationRequired(root))
        XCTAssertEqual(stops, 1)
    }

    func testCorruptRegistryIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let registry = fixture.registryURL
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: registry)
        let availability = await manager.availability()
        XCTAssertEqual(availability, .failed(.registryCorrupt))
        XCTAssertEqual(try Data(contentsOf: registry), corrupt)
    }

    func testSessionLayoutArtifactsRoundTripAndCollisionPreservesOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let repository = FileSessionRepository(roots: manager)
        let sessionID = SessionID(UUID(uuidString: "a1b2c3d4-0000-0000-0000-000000000001")!)
        let createdAt = AbsoluteTime(Date(timeIntervalSince1970: 1_725_000_000))
        let location = try await repository.createSession(sessionID: sessionID, createdAt: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertEqual(location.folderName.rawValue, "20240830-064000_a1b2c3d4")
        let folder = fixture.rootA.appendingPathComponent(location.folderName.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recovery").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(repository.artifactOwnership(.metadata), .authoritativeOrRecovery)
        XCTAssertEqual(repository.artifactOwnership(.transcriptMarkdown), .derived)
        do {
            _ = try await repository.createSession(sessionID: sessionID, createdAt: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTFail("Expected an existing session directory collision")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .sessionDirectoryCollision)
        }

        let metadata = try syntheticMetadata(sessionID: sessionID)
        try await repository.writeMetadata(metadata, at: location)
        let saved = try await repository.readMetadata(at: location)
        XCTAssertEqual(saved, metadata)
        let wrong = try syntheticMetadata(sessionID: SessionID())
        do {
            try await repository.writeMetadata(wrong, at: location)
            XCTFail("Expected session ID mismatch")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .sessionIDMismatch)
        }
        let preserved = try await repository.readMetadata(at: location)
        XCTAssertEqual(preserved, metadata)

        let transcript = try TranscriptDocument(sessionId: sessionID, segments: [])
        let checkpoint = try FinalizationCheckpointDocument(sessionId: sessionID, updatedAt: AbsoluteTime(Date()))
        try await repository.writeTranscript(transcript, at: location)
        try await repository.writeFinalizationCheckpoint(checkpoint, at: location)
        let savedTranscript = try await repository.readTranscript(at: location)
        let savedCheckpoint = try await repository.readFinalizationCheckpoint(at: location)
        XCTAssertEqual(savedTranscript, transcript)
        XCTAssertEqual(savedCheckpoint, checkpoint)
        let journal = try TranscriptJournalRecord(sessionId: sessionID, segment: try TranscriptSegment(
            id: TranscriptSegmentID(), sequence: try TranscriptSegmentSequence(0), startMs: try MediaMilliseconds(0), endMs: try MediaMilliseconds(1), originalText: "original", text: "text", language: try LanguageCode("ko")
        ))
        try await repository.appendTranscriptJournal(journal, at: location)
        let journalURL = folder.appendingPathComponent(SessionArtifact.transcriptJournal.relativePath)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptJournalRecord.self, from: Data(String(decoding: try Data(contentsOf: journalURL), as: UTF8.self).trimmingCharacters(in: .newlines).utf8)), journal)
    }

    func testAtomicWriterPreservesExistingDestinationBeforeRenameFault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.rootA.appendingPathComponent("document.json")
        let original = Data("{\"stable\":true}".utf8)
        try original.write(to: destination)
        let writer = AtomicFileWriter { step in
            if step == .beforeRename { throw StorageError(.atomicRenameFailed) }
        }
        XCTAssertThrowsError(try writer.write(Data("{\"replacement\":true}".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testJSONLAppendRetainsPriorBytesAndEachLineDecodes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let repository = FileSessionRepository(roots: manager)
        let sessionID = SessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let location = try await repository.createSession(sessionID: sessionID, createdAt: AbsoluteTime(Date()), timeZone: .gmt)
        let first = try SessionEventRecord(sessionId: sessionID, eventId: SessionEventID(), occurredAt: AbsoluteTime(Date()), kind: .recordingStarted)
        let second = try SessionEventRecord(sessionId: sessionID, eventId: SessionEventID(), occurredAt: AbsoluteTime(Date()), kind: .recordingEnded)
        try await repository.appendEvent(first, at: location)
        let events = fixture.rootA.appendingPathComponent(location.folderName.rawValue).appendingPathComponent(SessionArtifact.events.relativePath)
        let firstBytes = try Data(contentsOf: events)
        try await repository.appendEvent(second, at: location)
        let allBytes = try Data(contentsOf: events)
        XCTAssertTrue(allBytes.starts(with: firstBytes))
        let records = try String(decoding: allBytes, as: UTF8.self).split(separator: "\n").map { try JSONDecoder().decode(SessionEventRecord.self, from: Data($0.utf8)) }
        XCTAssertEqual(records, [first, second])
    }

    private func syntheticMetadata(sessionID: SessionID) throws -> SessionMetadataDocument {
        try SessionMetadataDocument(
            sessionId: sessionID,
            title: "Synthetic",
            status: .preparing,
            captureOutcome: .notStarted,
            createdAt: AbsoluteTime(Date()),
            activeDurationMs: try MediaMilliseconds(0),
            languageMode: .korean,
            transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)),
            appVersion: "test",
            osVersion: "test",
            lastUpdatedAt: AbsoluteTime(Date())
        )
    }
}

private struct Fixture {
    let base: URL
    let applicationSupport: URL
    let rootA: URL
    let rootB: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLectureSTTTests-\(UUID().uuidString)", isDirectory: true)
        applicationSupport = base.appendingPathComponent("ApplicationSupport", isDirectory: true)
        rootA = base.appendingPathComponent("root-a", isDirectory: true)
        rootB = base.appendingPathComponent("root-b", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
    }

    var registryURL: URL {
        applicationSupport.appendingPathComponent("LocalLectureSTT/Storage/storage-roots.json")
    }

    func manager(codec: TestBookmarkCodec) -> StorageRootManager {
        StorageRootManager(applicationSupportDirectory: applicationSupport, bookmarkCodec: codec, now: { AbsoluteTime(Date(timeIntervalSince1970: 1_725_000_000)) })
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private actor TestBookmarkCodec: SecurityScopedBookmarkCodec {
    private let stale: Bool
    private var accessAllowed = true
    private var makes = 0
    private var stops = 0

    init(stale: Bool = false) { self.stale = stale }

    func makeBookmark(for directory: URL) async throws -> Data {
        makes += 1
        return Data(directory.path.utf8)
    }

    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: stale)
    }

    func startAccessing(_ url: URL) async -> Bool { accessAllowed }
    func stopAccessing(_ url: URL) async { stops += 1 }
    func setAccessAllowed(_ value: Bool) { accessAllowed = value }
    func makeCount() -> Int { makes }
    func stopCount() -> Int { stops }
}
