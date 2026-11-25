import Foundation
import XCTest
@testable import LocalLectureSTT

final class StorageRepositoryTests: XCTestCase {
    func testT25OnlyDurableEventsAreMirroredAndRecoveryRetriesStayIdempotent() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let codec = TestBookmarkCodec()
        let manager = fixture.manager(codec: codec)
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let sink = T25RepositoryDiagnostics()
        let repository = FileSessionRepository(roots: manager, diagnostics: sink)
        let id = SessionID()
        let location = try await repository.createSession(sessionID: id, createdAt: .init(Date()), timeZone: .gmt)
        let event = try SessionEventRecord(sessionId: id, eventId: SessionEventID(), occurredAt: .init(Date()),
            kind: .recordingStarted, detail: .init(code: "PRIVATE-CODE", message: "PRIVATE-LECTURE"))
        try await repository.appendEvent(event, at: location)
        XCTAssertEqual(sink.entries.map(\.signal), [.sessionEvent(.recordingStarted)])
        await codec.setAccessAllowed(false)
        do { try await repository.appendEvent(event, at: location); XCTFail("denied event append") }
        catch { XCTAssertNotNil(error as? StorageError) }
        XCTAssertEqual(sink.entries.count, 1)
        await codec.setAccessAllowed(true)
        for _ in 0..<2 {
            let failure = await repository.appendRecoveryEventIfSafe(at: location, kind: .sttError,
                code: "stable-recovery-event", message: "PRIVATE-RECOVERY", occurredAt: .init(Date()))
            XCTAssertNil(failure)
        }
        XCTAssertEqual(sink.entries.map(\.signal), [.sessionEvent(.recordingStarted), .sessionEvent(.sttError)])
        let bytes = try JSONEncoder().encode(sink.entries)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        let path = fixture.rootA.appendingPathComponent(location.folderName.rawValue).appendingPathComponent("events.jsonl")
        XCTAssertEqual(try Data(contentsOf: path).split(separator: 0x0A).count, 2)
    }

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

    func testHistoricalRootReauthorizationPreservesItsIDAndTheCurrentActiveRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let codec = TestBookmarkCodec()
        let manager = fixture.manager(codec: codec)
        let historical = try await manager.registerSelectedDirectory(fixture.rootA)
        let active = try await manager.registerSelectedDirectory(fixture.rootB)

        let reauthorized = try await manager.reauthorize(rootID: historical.id, with: fixture.rootC)
        let restored = fixture.manager(codec: codec)
        let catalog = try await restored.storageRootCatalog()

        XCTAssertEqual(reauthorized.id, historical.id)
        XCTAssertEqual(catalog.activeRootID, active.id)
        XCTAssertEqual(catalog.roots.map(\.id), [historical.id, active.id])
        XCTAssertEqual(catalog.roots.map(\.isActive), [false, true])
        XCTAssertEqual(catalog.roots[0].summary.displayPath, fixture.rootC.path)
        XCTAssertEqual(try JSONDecoder().decode(StorageRootCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
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

    func testStaleAvailabilityReturnsTheRefreshedSummary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let codec = TestBookmarkCodec(stale: true, resolvedURL: fixture.rootB)
        let manager = fixture.manager(codec: codec)
        let original = try await manager.registerSelectedDirectory(fixture.rootA)

        let availability = await manager.availability()

        guard case let .available(summary, refreshedBookmark) = availability else {
            return XCTFail("Expected an available refreshed root")
        }
        XCTAssertTrue(refreshedBookmark)
        XCTAssertEqual(summary.id, original.id)
        XCTAssertEqual(summary.displayName, fixture.rootB.lastPathComponent)
        XCTAssertEqual(summary.displayPath, fixture.rootB.path)
        let catalog = try await manager.storageRootCatalog()
        XCTAssertEqual(catalog.roots.first?.summary, summary)
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

    func testUnsupportedRegistryIsReportedAndNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let registry = fixture.registryURL
        let supported = try Data(contentsOf: registry)
        let unsupported = Data(String(decoding: supported, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":999")
            .utf8)
        try unsupported.write(to: registry)

        let availability = await manager.availability()
        XCTAssertEqual(availability, .failed(.registryUnsupported))
        XCTAssertEqual(try Data(contentsOf: registry), unsupported)
        do {
            _ = try await manager.storageRootCatalog()
            XCTFail("Expected unsupported registry")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .registryUnsupported)
        }
        XCTAssertEqual(try Data(contentsOf: registry), unsupported)
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

    func testDifferentSessionIDsAtTheSameTimeCreateDifferentFoldersAndArtifactsAreExact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let repository = FileSessionRepository(roots: manager)
        let timestamp = AbsoluteTime(Date(timeIntervalSince1970: 1_725_000_000))
        let first = try await repository.createSession(sessionID: SessionID(UUID(uuidString: "a1b2c3d4-0000-0000-0000-000000000001")!), createdAt: timestamp, timeZone: .gmt)
        let second = try await repository.createSession(sessionID: SessionID(UUID(uuidString: "b1c2d3e4-0000-0000-0000-000000000002")!), createdAt: timestamp, timeZone: .gmt)

        XCTAssertNotEqual(first.folderName, second.folderName)
        XCTAssertEqual(first.folderName.rawValue, "20240830-064000_a1b2c3d4")
        XCTAssertEqual(second.folderName.rawValue, "20240830-064000_b1c2d3e4")
        let expected: [(SessionArtifact, String, SessionArtifactOwnership)] = [
            (.metadata, "metadata.json", .authoritativeOrRecovery),
            (.finalAudio, "audio.m4a", .authoritativeOrRecovery),
            (.transcript, "transcript.json", .authoritativeOrRecovery),
            (.transcriptText, "transcript.txt", .derived),
            (.transcriptMarkdown, "transcript.md", .derived),
            (.events, "events.jsonl", .authoritativeOrRecovery),
            (.recoveryAudio, "recovery/audio.recovery.mov", .authoritativeOrRecovery),
            (.transcriptJournal, "recovery/transcript.journal.jsonl", .authoritativeOrRecovery),
            (.finalizationCheckpoint, "recovery/finalization.checkpoint.json", .authoritativeOrRecovery)
        ]
        XCTAssertEqual(expected.map(\.0), SessionArtifact.allCases)
        for (artifact, path, ownership) in expected {
            XCTAssertEqual(artifact.relativePath, path)
            XCTAssertEqual(repository.artifactOwnership(artifact), ownership)
        }
    }

    func testMissingCorruptAndUnsupportedDocumentsRemainDistinct() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let repository = FileSessionRepository(roots: manager)
        let sessionID = SessionID()
        let location = try await repository.createSession(sessionID: sessionID, createdAt: AbsoluteTime(Date()), timeZone: .gmt)
        do {
            _ = try await repository.readMetadata(at: location)
            XCTFail("Expected missing metadata")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .artifactMissing)
        }
        let path = fixture.rootA.appendingPathComponent(location.folderName.rawValue).appendingPathComponent("metadata.json")
        try Data("broken".utf8).write(to: path)
        do {
            _ = try await repository.readMetadata(at: location)
            XCTFail("Expected corrupt metadata")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .documentCorrupt)
        }
        let valid = try syntheticMetadata(sessionID: sessionID)
        let unsupported = try JSONEncoder().encode(valid)
        let text = String(decoding: unsupported, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try Data(text.utf8).write(to: path)
        do {
            _ = try await repository.readMetadata(at: location)
            XCTFail("Expected unsupported metadata")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .documentUnsupported)
        }
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

    func testAtomicWriterReplacesAndPreservesDestinationForEveryPreRenameFault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.rootA.appendingPathComponent("document.json")
        let original = Data("{\"stable\":true}".utf8)
        try original.write(to: destination)
        try AtomicFileWriter().write(Data("{\"replacement\":true}".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("{\"replacement\":true}".utf8))

        for faultStep in ["temporary", "write", "flush", "rename"] {
            try original.write(to: destination)
            let writer = AtomicFileWriter { step in
                let shouldFail: Bool
                switch (faultStep, step) {
                case ("temporary", .afterTemporaryCreate), ("write", .beforeWrite), ("flush", .beforeFlush), ("rename", .beforeRename): shouldFail = true
                default: shouldFail = false
                }
                if shouldFail { throw StorageError(.temporaryWriteFailed) }
            }
            XCTAssertThrowsError(try writer.write(Data("{\"replacement\":true}".utf8), to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testTemporaryFileUsesTheDestinationDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let destination = fixture.rootA.appendingPathComponent("document.json")
        let writer = AtomicFileWriter { step in
            guard case let .afterTemporaryCreate(temporaryPath) = step else { return }
            XCTAssertEqual(URL(fileURLWithPath: temporaryPath).deletingLastPathComponent(), destination.deletingLastPathComponent())
            throw StorageError(.temporaryWriteFailed)
        }
        XCTAssertThrowsError(try writer.write(Data("{}".utf8), to: destination))
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

    func testJSONLJournalAppendEncodeFailureAndConcurrentEventIntegrity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager(codec: TestBookmarkCodec())
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        let repository = FileSessionRepository(roots: manager)
        let sessionID = SessionID()
        let location = try await repository.createSession(sessionID: sessionID, createdAt: AbsoluteTime(Date()), timeZone: .gmt)
        let journal = try TranscriptJournalRecord(sessionId: sessionID, segment: try TranscriptSegment(id: TranscriptSegmentID(), sequence: try TranscriptSegmentSequence(0), startMs: try MediaMilliseconds(0), endMs: try MediaMilliseconds(1), originalText: "source", text: "source", language: try LanguageCode("ko")))
        try await repository.appendTranscriptJournal(journal, at: location)
        try await repository.appendTranscriptJournal(journal, at: location)
        let journalURL = fixture.rootA.appendingPathComponent(location.folderName.rawValue).appendingPathComponent(SessionArtifact.transcriptJournal.relativePath)
        let journalLines = try String(decoding: Data(contentsOf: journalURL), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(try journalLines.map { try JSONDecoder().decode(TranscriptJournalRecord.self, from: Data($0.utf8)) }, [journal, journal])

        let directJSONL = fixture.rootA.appendingPathComponent("direct.jsonl")
        let existing = Data("{\"stable\":true}\n".utf8)
        try existing.write(to: directJSONL)
        XCTAssertThrowsError(try JSONLWriter().append(ThrowingRecord(), to: directJSONL))
        XCTAssertEqual(try Data(contentsOf: directJSONL), existing)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await repository.appendEvent(SessionEventRecord(sessionId: sessionID, eventId: SessionEventID(), occurredAt: AbsoluteTime(Date()), kind: .recordingStarted), at: location)
                }
            }
            try await group.waitForAll()
        }
        let eventsURL = fixture.rootA.appendingPathComponent(location.folderName.rawValue).appendingPathComponent(SessionArtifact.events.relativePath)
        let events = try String(decoding: Data(contentsOf: eventsURL), as: UTF8.self).split(separator: "\n").map { try JSONDecoder().decode(SessionEventRecord.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.count, 20)
        XCTAssertEqual(Set(events.map(\.eventId)).count, 20)
    }

    func testDeniedAccessDoesNotRunRepositoryMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let codec = TestBookmarkCodec()
        let manager = fixture.manager(codec: codec)
        _ = try await manager.registerSelectedDirectory(fixture.rootA)
        await codec.setAccessAllowed(false)
        let repository = FileSessionRepository(roots: manager)
        do {
            _ = try await repository.createSession(sessionID: SessionID(), createdAt: AbsoluteTime(Date()), timeZone: .gmt)
            XCTFail("Expected denied root access")
        } catch let error as StorageError {
            XCTAssertEqual(error.code, .reauthorizationRequired)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.rootA.path), [])
    }

    func testScopedAccessStopsOnceForSuccessfulAndThrowingOperations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let codec = TestBookmarkCodec()
        let manager = fixture.manager(codec: codec)
        let root = try await manager.registerSelectedDirectory(fixture.rootA)
        let success = try await manager.withAccess(to: root.id) { _ in "success" }
        XCTAssertEqual(success, "success")
        do {
            _ = try await manager.withAccess(to: root.id) { _ in throw TestOperationFailure.failed }
            XCTFail("Expected operation failure")
        } catch TestOperationFailure.failed {
        }
        let stops = await codec.stopCount()
        XCTAssertEqual(stops, 2)
    }

    @MainActor
    func testRootViewModelChooseAndChangePassEachSelectedURLAndBecomeAvailable() async throws {
        let first = storageRootSummary(name: "A")
        let second = storageRootSummary(name: "B")
        let firstURL = URL(fileURLWithPath: "/tmp/selected-a")
        let secondURL = URL(fileURLWithPath: "/tmp/selected-b")
        let controller = TestRootController(availability: .noRootSelected, summary: first)
        let selector = TestDirectorySelector(selectedURL: firstURL)
        let model = StorageRootViewModel(controller: controller, directorySelector: selector)

        await model.restore()
        XCTAssertEqual(model.state, .noRoot)
        await model.chooseActiveRoot()
        XCTAssertEqual(model.state, .available(first, refreshedBookmark: false))
        XCTAssertEqual(selector.chooseCount, 1)
        let initialRegistrationURLs = await controller.registrationURLs()
        XCTAssertEqual(initialRegistrationURLs, [firstURL])

        selector.selectedURL = secondURL
        await controller.setRegistrationSummary(second)
        await model.chooseActiveRoot()
        XCTAssertEqual(model.state, .available(second, refreshedBookmark: false))
        XCTAssertEqual(selector.chooseCount, 2)
        let changedRegistrationURLs = await controller.registrationURLs()
        XCTAssertEqual(changedRegistrationURLs, [firstURL, secondURL])
    }

    @MainActor
    func testRootViewModelReauthorizationPassesExistingRootIDAndBecomesAvailable() async throws {
        let root = storageRootSummary(name: "A")
        let replacementURL = URL(fileURLWithPath: "/tmp/reauthorized-a")
        let controller = TestRootController(availability: .reauthorizationRequired(root), summary: root)
        let selector = TestDirectorySelector(selectedURL: replacementURL)
        let model = StorageRootViewModel(controller: controller, directorySelector: selector)

        await model.restore()
        XCTAssertEqual(model.state, .reauthorizationRequired(root))
        await model.reauthorize()

        XCTAssertEqual(model.state, .available(root, refreshedBookmark: false))
        XCTAssertEqual(selector.chooseCount, 1)
        let requests = await controller.reauthorizationRequests()
        XCTAssertEqual(requests, [ReauthorizationRequest(rootID: root.id, url: replacementURL)])
    }

    @MainActor
    func testRootViewModelCancellationPreservesStateAndDoesNotCallController() async throws {
        let available = storageRootSummary(name: "A")
        let chooseController = TestRootController(availability: .available(available, refreshedBookmark: false), summary: available)
        let chooseSelector = TestDirectorySelector(selectedURL: nil)
        let chooseModel = StorageRootViewModel(controller: chooseController, directorySelector: chooseSelector)
        await chooseModel.restore()
        await chooseModel.chooseActiveRoot()
        XCTAssertEqual(chooseModel.state, .available(available, refreshedBookmark: false))
        XCTAssertEqual(chooseSelector.chooseCount, 1)
        let chooseCalls = await chooseController.registrationURLs()
        XCTAssertEqual(chooseCalls, [])

        let reauthorization = storageRootSummary(name: "B")
        let reauthorizeController = TestRootController(availability: .reauthorizationRequired(reauthorization), summary: reauthorization)
        let reauthorizeSelector = TestDirectorySelector(selectedURL: nil)
        let reauthorizeModel = StorageRootViewModel(controller: reauthorizeController, directorySelector: reauthorizeSelector)
        await reauthorizeModel.restore()
        await reauthorizeModel.reauthorize()
        XCTAssertEqual(reauthorizeModel.state, .reauthorizationRequired(reauthorization))
        XCTAssertEqual(reauthorizeSelector.chooseCount, 1)
        let reauthorizeCalls = await reauthorizeController.reauthorizationRequests()
        XCTAssertEqual(reauthorizeCalls, [])
    }

    @MainActor
    func testRootViewModelChooseAndReauthorizationErrorsExposeExactCodes() async throws {
        let chooseRoot = storageRootSummary(name: "A")
        let chooseURL = URL(fileURLWithPath: "/tmp/failed-choice")
        let chooseController = TestRootController(availability: .noRootSelected, summary: chooseRoot)
        let chooseSelector = TestDirectorySelector(selectedURL: chooseURL)
        let chooseModel = StorageRootViewModel(controller: chooseController, directorySelector: chooseSelector)
        await chooseController.setRegistrationError(StorageError(.bookmarkCreateFailed))
        await chooseModel.chooseActiveRoot()
        XCTAssertEqual(chooseModel.state, .failed(.bookmarkCreateFailed))
        XCTAssertEqual(chooseSelector.chooseCount, 1)
        let chooseCalls = await chooseController.registrationURLs()
        XCTAssertEqual(chooseCalls, [chooseURL])

        let reauthorizationRoot = storageRootSummary(name: "B")
        let reauthorizationURL = URL(fileURLWithPath: "/tmp/failed-reauthorization")
        let reauthorizeController = TestRootController(availability: .reauthorizationRequired(reauthorizationRoot), summary: reauthorizationRoot)
        let reauthorizeSelector = TestDirectorySelector(selectedURL: reauthorizationURL)
        let reauthorizeModel = StorageRootViewModel(controller: reauthorizeController, directorySelector: reauthorizeSelector)
        await reauthorizeModel.restore()
        await reauthorizeController.setReauthorizationError(StorageError(.rootNotDirectory))
        await reauthorizeModel.reauthorize()
        XCTAssertEqual(reauthorizeModel.state, .failed(.rootNotDirectory))
        XCTAssertEqual(reauthorizeSelector.chooseCount, 1)
        let reauthorizeCalls = await reauthorizeController.reauthorizationRequests()
        XCTAssertEqual(reauthorizeCalls, [ReauthorizationRequest(rootID: reauthorizationRoot.id, url: reauthorizationURL)])
    }

    private func storageRootSummary(name: String) -> StorageRootSummary {
        StorageRootSummary(id: StorageRootID(), displayName: name, displayPath: "/tmp/\(name)", updatedAt: AbsoluteTime(Date()))
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
    let rootC: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLectureSTTTests-\(UUID().uuidString)", isDirectory: true)
        applicationSupport = base.appendingPathComponent("ApplicationSupport", isDirectory: true)
        rootA = base.appendingPathComponent("root-a", isDirectory: true)
        rootB = base.appendingPathComponent("root-b", isDirectory: true)
        rootC = base.appendingPathComponent("root-c", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootC, withIntermediateDirectories: true)
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
    private let resolvedURL: URL?
    private var accessAllowed = true
    private var makes = 0
    private var stops = 0

    init(stale: Bool = false, resolvedURL: URL? = nil) {
        self.stale = stale
        self.resolvedURL = resolvedURL
    }

    func makeBookmark(for directory: URL) async throws -> Data {
        makes += 1
        return Data(directory.path.utf8)
    }

    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        ResolvedBookmark(url: resolvedURL ?? URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: stale)
    }

    func startAccessing(_ url: URL) async -> Bool { accessAllowed }
    func stopAccessing(_ url: URL) async { stops += 1 }
    func setAccessAllowed(_ value: Bool) { accessAllowed = value }
    func makeCount() -> Int { makes }
    func stopCount() -> Int { stops }
}

private struct ThrowingRecord: Encodable {
    func encode(to encoder: Encoder) throws { throw StorageError(.jsonEncodeFailed) }
}

private enum TestOperationFailure: Error {
    case failed
}

private struct ReauthorizationRequest: Sendable, Equatable {
    let rootID: StorageRootID
    let url: URL
}

private actor TestRootController: StorageRootControlling {
    private var currentAvailability: StorageRootAvailability
    private var registrationSummary: StorageRootSummary
    private var reauthorizationSummary: StorageRootSummary
    private var registrationError: StorageError?
    private var reauthorizationError: StorageError?
    private var recordedRegistrationURLs: [URL] = []
    private var recordedReauthorizationRequests: [ReauthorizationRequest] = []

    init(availability: StorageRootAvailability, summary: StorageRootSummary) {
        currentAvailability = availability
        registrationSummary = summary
        reauthorizationSummary = summary
    }

    func availability() async -> StorageRootAvailability { currentAvailability }
    func storageRootCatalog() async throws -> StorageRootCatalog {
        StorageRootCatalog(activeRootID: registrationSummary.id, roots: [StorageRootReference(summary: registrationSummary, isActive: true)])
    }
    func registerSelectedDirectory(_ url: URL) async throws -> StorageRootSummary {
        recordedRegistrationURLs.append(url)
        if let registrationError { throw registrationError }
        return registrationSummary
    }
    func reauthorize(rootID: StorageRootID, with url: URL) async throws -> StorageRootSummary {
        recordedReauthorizationRequests.append(ReauthorizationRequest(rootID: rootID, url: url))
        if let reauthorizationError { throw reauthorizationError }
        return reauthorizationSummary
    }
    func setRegistrationSummary(_ summary: StorageRootSummary) { registrationSummary = summary }
    func setRegistrationError(_ error: StorageError?) { registrationError = error }
    func setReauthorizationError(_ error: StorageError?) { reauthorizationError = error }
    func registrationURLs() -> [URL] { recordedRegistrationURLs }
    func reauthorizationRequests() -> [ReauthorizationRequest] { recordedReauthorizationRequests }
}

@MainActor
private final class TestDirectorySelector: DirectorySelecting {
    var selectedURL: URL?
    private(set) var chooseCount = 0

    init(selectedURL: URL?) { self.selectedURL = selectedURL }
    func chooseDirectory() -> URL? {
        chooseCount += 1
        return selectedURL
    }
}

private final class T25RepositoryDiagnostics: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DiagnosticEntry] = []
    var entries: [DiagnosticEntry] { lock.withLock { values } }
    func record(_ entry: DiagnosticEntry) { lock.withLock { values.append(entry) } }
}
