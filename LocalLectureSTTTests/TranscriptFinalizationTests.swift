import Foundation
import XCTest
@testable import LocalLectureSTT

final class TranscriptFinalizationTests: XCTestCase {
    func testReplayRejectsTornForeignFutureConflictingAndOutOfOrderRecords() throws {
        let session = SessionID(), first = try segment(0)
        let line = try JSONEncoder().encode(TranscriptJournalRecord(sessionId: session, segment: first))
        var replay = TranscriptJournalReplay(sessionID: session)
        try replay.append(line); try replay.append(line)
        XCTAssertEqual(replay.segments, [first])
        for (data, code) in [
            (Data("{".utf8), TranscriptFailureCode.invalidJournal),
            (try JSONEncoder().encode(TranscriptJournalRecord(sessionId: SessionID(), segment: first)), .sessionMismatch),
            (try JSONEncoder().encode(TranscriptJournalRecord(sessionId: session, segment: segment(2))), .invalidOrder),
            (Data(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99").utf8), .unsupportedSchema)
        ] {
            var candidate = TranscriptJournalReplay(sessionID: session)
            XCTAssertThrowsError(try candidate.append(data)) { XCTAssertEqual(($0 as? TranscriptFailure)?.code, code) }
        }
        var changed = first; changed.text = "external edit"
        XCTAssertThrowsError(try replay.append(JSONEncoder().encode(TranscriptJournalRecord(sessionId: session, segment: changed))))
    }

    func testCanonicalPreservesEditsAndOverlapButRejectsImmutableConflictsAndBadTimes() throws {
        let session = SessionID()
        let first = try segment(0, start: 100, end: 700)
        let second = try segment(1, start: 600, end: 900)
        var edited = first; edited.text = "수정한 GPU 용어"
        let existing = try TranscriptDocument(sessionId: session, segments: [edited])
        let merged = try TranscriptCanonical.compact(sessionID: session, journal: [first, second],
                                                    existing: existing, duration: .init(1_000))
        XCTAssertEqual(merged.segments, [edited, second])
        XCTAssertEqual(merged.segments[0].originalText, first.originalText)
        XCTAssertThrowsError(try TranscriptCanonical.compact(sessionID: session, journal: [segment(0)], existing: existing, duration: .init(1_000)))
        for segments in [[first, try segment(2, start: 50, end: 90)], [try segment(0, end: 1_001)], [first, first]] {
            XCTAssertThrowsError(try TranscriptCanonical.validate(TranscriptDocument(sessionId: session, segments: segments),
                                                                  sessionID: session, duration: .init(1_000)))
        }
    }

    func testRendererIsDeterministicEscapesFrontMatterAndSupportsLongTimesAndUnicode() throws {
        let session = SessionID()
        let time = AbsoluteTime(Date(timeIntervalSince1970: 0))
        let metadata = try SessionMetadataDocument(sessionId: session, title: "---\n제목: \"GPU\" # 😀",
            status: .completed, captureOutcome: .completed, createdAt: time, activeDurationMs: .init(360_001_000),
            languageMode: .korean, engine: .init(id: .init("engine"), version: "v1"),
            model: .init(id: .init("large"), revision: "r1", checksum: "abc"),
            transcript: .init(segmentCount: .init(1)), appVersion: "test", osVersion: "test", lastUpdatedAt: time)
        let doc = try TranscriptDocument(sessionId: session, segments: [segment(0, start: 360_000_000, end: 360_001_000, text: "한국어 GPU 😀\n두 번째 줄")])
        let rendered = try TranscriptRenderer.render(doc, metadata: metadata)
        XCTAssertEqual(rendered, try TranscriptRenderer.render(doc, metadata: metadata))
        let md = String(decoding: rendered.markdown, as: UTF8.self)
        XCTAssertTrue(md.contains("[100:00:00] 한국어 GPU 😀\n두 번째 줄"))
        let titleLine = try XCTUnwrap(md.split(separator: "\n").first { $0.hasPrefix("title: ") })
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(titleLine.dropFirst(7).utf8)), metadata.title)
        XCTAssertTrue(md.contains("1970-01-01T00:00:00.000Z"))
        XCTAssertTrue(md.contains("\"revision\":\"r1\""))
    }

    func testActualFilesCompactEditRegenerateAndReopenWithoutImportingDerivedText() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        let first = try segment(0), second = try segment(1, start: 600, end: 900)
        for value in [first, first, second] { try await journal(value, f.audio) }
        let originalJournal = try Data(contentsOf: f.audio.url(SessionArtifact.transcriptJournal.relativePath))
        let steps = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        XCTAssertEqual(steps, Array(FinalizationStep.allCases.prefix(7)))
        let original = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(original.segments, [first, second])
        let changed = try await f.repository.updateText(at: f.audio.location, segmentID: first.id, expectedText: first.text, text: "정정한 text")
        XCTAssertEqual(changed.segments[0].originalText, first.originalText)
        XCTAssertEqual(changed.segments[0].startMs, first.startMs)
        XCTAssertEqual(changed.segments[0].endMs, first.endMs)
        let canonicalBytes = try Data(contentsOf: f.audio.url("transcript.json"))
        let expectedMarkdown = try Data(contentsOf: f.audio.url("transcript.md"))
        try Data("external changes must not be imported".utf8).write(to: f.audio.url("transcript.md"))
        try FileManager.default.removeItem(at: f.audio.url("transcript.txt"))
        let reopened = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog)
        _ = try await reopened.regenerate(at: f.audio.location)
        _ = try await reopened.finalize(at: f.audio.location, audio: f.ready, control: .init())
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), canonicalBytes)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.md")), expectedMarkdown)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(SessionArtifact.transcriptJournal.relativePath)), originalJournal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.audio.url(FinalizationFileAccess.source).path))
        let metadata = try await f.audio.repository.readMetadata(at: f.audio.location)
        XCTAssertEqual(metadata.status, .completed)
        XCTAssertEqual(metadata.transcript.segmentCount.rawValue, 2)
        do { _ = try await f.repository.updateText(at: f.audio.location, segmentID: first.id, expectedText: "stale", text: "lost update"); XCTFail() }
        catch let error as TranscriptFailure { XCTAssertEqual(error.code, .editConflict) }
        let key = CompletionEvidenceAuthority()
        let proof = try await key.issue(location: f.audio.location, roots: f.audio.roots, verifier: f.repository)
        try key.validate(proof)
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
    }

    func testCorruptAndTornJournalPreserveAllOriginalBytesAndReportLine() async throws {
        for suffix in [Data("{\n".utf8), Data("{".utf8), Data("\n".utf8)] {
            let f = try await fixture(); defer { f.audio.clean() }
            try await journal(segment(0), f.audio)
            let url = f.audio.url(SessionArtifact.transcriptJournal.relativePath)
            var bytes = try Data(contentsOf: url); bytes.append(suffix); try bytes.write(to: url)
            let metadata = try Data(contentsOf: f.audio.url("metadata.json"))
            let checkpoint = try Data(contentsOf: f.audio.url(FinalizationFileAccess.checkpoint))
            let source = try Data(contentsOf: f.audio.url(FinalizationFileAccess.source))
            do { _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init()); XCTFail() }
            catch let error as TranscriptFailure { XCTAssertEqual(error.code, .invalidJournal); XCTAssertEqual(error.line, 2) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try Data(contentsOf: f.audio.url("metadata.json")), metadata)
            XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.checkpoint)), checkpoint)
            XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.source)), source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("transcript.json").path))
        }
    }

    func testEveryWriteBoundaryRetriesWithoutLosingCanonicalOrRecovery() async throws {
        for point in TranscriptWritePoint.allCases {
            let f = try await fixture(); defer { f.audio.clean() }
            let value = try segment(0); try await journal(value, f.audio)
            let source = try Data(contentsOf: f.audio.url(FinalizationFileAccess.source))
            let faulty = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
                hook: { if $0 == point { throw AudioFinalizationCode.diskFull } })
            do { _ = try await faulty.finalize(at: f.audio.location, audio: f.ready, control: .init()); XCTFail("\(point)") }
            catch let error as AudioFinalizationCode { XCTAssertEqual(error, .diskFull, "\(point)") }
            let fresh = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog)
            _ = try await fresh.finalize(at: f.audio.location, audio: f.ready, control: .init())
            let doc = try await f.audio.repository.readTranscript(at: f.audio.location)
            XCTAssertEqual(doc.segments, [value], "\(point)")
            XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.source)), source)
            let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1], "\(point)")
        }
    }

    func testCancelledCompactionAndSymlinkDerivedPathNeverPublishCanonical() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        try await journal(segment(0), f.audio)
        let control = AudioFinalizationControl()
        let cancelled = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
            hook: { if $0 == .beforeCanonical { control.cancel() } })
        do { _ = try await cancelled.finalize(at: f.audio.location, audio: f.ready, control: control); XCTFail() }
        catch let error as AudioFinalizationCode { XCTAssertEqual(error, .cancelled) }
        let external = f.audio.base.appendingPathComponent("external")
        try Data("untouched".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: f.audio.url("transcript.md"), withDestinationURL: external)
        do { _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init()); XCTFail() }
        catch let error as AudioFinalizationCode { XCTAssertEqual(error, .unsafeLayout) }
        XCTAssertEqual(try Data(contentsOf: external), Data("untouched".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("transcript.json").path))
    }

    func testConcurrentEditIsRejectedAndExternalReplacementAcrossAwaitIsPreserved() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        try await journal(segment(0), f.audio)
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        let gate = FinalizationGate()
        let editing = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
            hook: { if $0 == .beforeText { await gate.blockOnce() } })
        let pending = Task { try await editing.regenerate(at: f.audio.location) }
        await gate.waitEntered()
        do { _ = try await editing.regenerate(at: f.audio.location); XCTFail() }
        catch let error as TranscriptFailure { XCTAssertEqual(error.code, .busy) }
        let replacement = Data("external replacement".utf8)
        try replacement.write(to: f.audio.url("transcript.md"), options: .atomic)
        await gate.open()
        do { _ = try await pending.value; XCTFail() }
        catch let error as AudioFinalizationCode { XCTAssertEqual(error, .identityChanged) }
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.md")), replacement)
    }

    func testEmptyJournalCompletesAndCatalogFailureDoesNotClaimCatalogCheckpoint() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        let failed = FileTranscriptRepository(roots: f.audio.roots, catalog: RecoveryFailureCatalog())
        do { _ = try await failed.finalize(at: f.audio.location, audio: f.ready, control: .init()); XCTFail() }
        catch let error as TranscriptFailure { XCTAssertEqual(error.code, .catalog) }
        let cp = try await f.audio.repository.readFinalizationCheckpoint(at: f.audio.location)
        XCTAssertEqual(cp.completedSteps.last, .metadataCompleted)
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        let doc = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertTrue(doc.segments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.txt")), Data())
    }

    func testDerivedFailureAfterTextEditRetainsSavedCanonicalAndRetryPreservesOriginal() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        let value = try segment(0); try await journal(value, f.audio)
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        let failed = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
            hook: { if $0 == .beforeMarkdown { throw AudioFinalizationCode.diskFull } })
        do { _ = try await failed.updateText(at: f.audio.location, segmentID: value.id, expectedText: value.text, text: "saved edit"); XCTFail() }
        catch let error as AudioFinalizationCode { XCTAssertEqual(error, .diskFull) }
        let saved = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(saved.segments[0].text, "saved edit")
        let retried = try await f.repository.updateText(at: f.audio.location, segmentID: value.id, expectedText: value.text, text: "saved edit")
        XCTAssertEqual(retried.segments[0].originalText, value.originalText)
        XCTAssertTrue(String(decoding: try Data(contentsOf: f.audio.url("transcript.md")), as: UTF8.self).contains("saved edit"))
    }

    func testStartupRecoveryResumesEveryTranscriptCrashWindowAndRegeneratesEditedMarkdown() async throws {
        for point in [TranscriptWritePoint.afterCanonical, .afterText, .afterMarkdown, .afterMetadata, .afterCatalog] {
            let f = try await fixture(); defer { f.audio.clean() }
            let value = try segment(0); try await journal(value, f.audio)
            let failed = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
                hook: { if $0 == point { throw AudioFinalizationCode.persistence } })
            do { _ = try await failed.finalize(at: f.audio.location, audio: f.ready, control: .init()); XCTFail() }
            catch {}
            let queue = AudioFinalizationCoordinator(worker: SessionFinalizationWorker(audio: f.audio.worker(), transcripts: f.repository))
            let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: f.audio.roots),
                persistence: f.audio.repository, finalization: queue, catalog: f.catalog, activity: SessionActivityRegistry())
            await recovery.start(); await recovery.waitForCurrentPassSettlement()
            let snapshot = await recovery.currentSnapshot()
            XCTAssertEqual(snapshot.report?.items.first?.code, .sessionReady, "\(point): \(snapshot)")
            let doc = try await f.audio.repository.readTranscript(at: f.audio.location)
            XCTAssertEqual(doc.segments, [value])
            let cp = try await f.audio.repository.readFinalizationCheckpoint(at: f.audio.location)
            XCTAssertEqual(cp.completedSteps.last, .catalogUpdated)
            let edited = try await f.repository.updateText(at: f.audio.location, segmentID: value.id, expectedText: value.text, text: "retained correction")
            try FileManager.default.removeItem(at: f.audio.url("transcript.md"))
            await recovery.refresh(); await recovery.waitForCurrentPassSettlement()
            let reopened = try await f.audio.repository.readTranscript(at: f.audio.location)
            XCTAssertEqual(reopened, edited)
            XCTAssertTrue(String(decoding: try Data(contentsOf: f.audio.url("transcript.md")), as: UTF8.self).contains("retained correction"))
        }
    }

    func testInterruptedRecoveryKeepsCaptureOutcomeAndExistingAudioWhileCompletingTranscript() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        try await journal(segment(0), f.audio)
        try f.audio.editJSON("metadata.json") { $0["status"] = "interrupted"; $0["captureOutcome"] = "interrupted" }
        let queue = AudioFinalizationCoordinator(worker: SessionFinalizationWorker(audio: f.audio.worker(), transcripts: f.repository))
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: f.audio.roots),
            persistence: f.audio.repository, finalization: queue, catalog: f.catalog, activity: SessionActivityRegistry())
        await recovery.start(); await recovery.waitForCurrentPassSettlement()
        let state = await recovery.currentSnapshot()
        XCTAssertEqual(state.report?.items.first?.code, .sessionReady)
        let metadata = try await f.audio.repository.readMetadata(at: f.audio.location)
        XCTAssertEqual(metadata.status, .interrupted)
        XCTAssertEqual(metadata.captureOutcome, .interrupted)
        XCTAssertEqual(metadata.transcript.segmentCount.rawValue, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.audio.url(FinalizationFileAccess.source).path))
    }

    func testTerminalDerivedFailureIsRetryableAndBlocksAutoExitButAllowsEssentialQuit() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        try await journal(segment(0), f.audio)
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        // Healthy completed files now take the read-only verification path.
        // A missing derived file makes this a real repair attempt.
        try FileManager.default.removeItem(at: f.audio.url("transcript.md"))
        let fault = TranscriptOneShotFailure()
        let transcripts = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
            hook: { if $0 == .beforeText { try await fault.hit() } })
        let finalization = AudioFinalizationCoordinator(worker: SessionFinalizationWorker(audio: f.audio.worker(), transcripts: transcripts))
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: f.audio.roots),
            persistence: f.audio.repository, finalization: finalization, catalog: f.catalog, activity: SessionActivityRegistry())
        await recovery.start(); await recovery.waitForCurrentPassSettlement()
        let failed = await recovery.currentSnapshot()
        XCTAssertEqual(failed.report?.items.first?.code, .transcriptFinalizationFailed)
        XCTAssertEqual(failed.report?.items.first?.retryable, true)
        let exits = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: finalization,
            recovery: recovery, activity: LifecycleActivitySpy(), termination: exits)
        await lifecycle.userWindowCountChanged(0)
        let state = await lifecycle.currentSnapshot(), count = await exits.count()
        XCTAssertTrue(state.requiresUserAttention)
        XCTAssertFalse(state.blocksExplicitTermination)
        XCTAssertEqual(count, 0)
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertTrue(allowed)
        await recovery.retry(); await recovery.waitForCurrentPassSettlement()
        let succeeded = await recovery.currentSnapshot()
        XCTAssertEqual(succeeded.report?.items.first?.code, .sessionReady)
    }

    func testUTF8JournalAcrossReadChunksAndReadOnlyBeforeFinalization() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        let longText = String(repeating: "한국어 GPU 😀", count: 900)
        var values: [TranscriptSegment] = []
        for index in 0..<20 {
            let start = Int64(index) * 10
            values.append(try segment(Int64(index), start: start, end: start + 8, text: longText))
        }
        var journalBytes = Data()
        for value in values {
            journalBytes.append(try JSONEncoder().encode(TranscriptJournalRecord(sessionId: f.audio.location.sessionID, segment: value)))
            journalBytes.append(0x0a)
        }
        XCTAssertGreaterThan(journalBytes.count, FinalizationFileAccess.bufferSize * 3)
        try journalBytes.write(to: f.audio.url(SessionArtifact.transcriptJournal.relativePath))
        do { _ = try await f.repository.updateText(at: f.audio.location, segmentID: values[0].id, expectedText: values[0].text, text: "premature"); XCTFail() }
        catch let error as TranscriptFailure { XCTAssertEqual(error.code, .notFinalized) }
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        let document = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(document.segments, values)
    }

    func testCorruptFutureAndForeignCanonicalAreNeverOverwrittenByJournal() async throws {
        for kind in 0..<3 {
            let f = try await fixture(); defer { f.audio.clean() }
            let value = try segment(0); try await journal(value, f.audio)
            let document = try TranscriptDocument(sessionId: kind == 2 ? SessionID() : f.audio.location.sessionID, segments: [value])
            let encoded = try JSONEncoder().encode(document)
            let bytes = kind == 0 ? Data("broken".utf8) : kind == 1
                ? Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99").utf8)
                : encoded
            try bytes.write(to: f.audio.url("transcript.json"))
            do { _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init()); XCTFail() }
            catch let error as TranscriptFailure {
                XCTAssertEqual(error.code, [.canonicalConflict, .unsupportedSchema, .sessionMismatch][kind])
            }
            XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("transcript.md").path))
        }
    }

    private func segment(_ sequence: Int64, start: Int64 = 100, end: Int64 = 500, text: String = "강의 GPU 용어") throws -> TranscriptSegment {
        try .init(id: .init(), sequence: .init(sequence), startMs: .init(start), endMs: .init(end),
                  originalText: text, text: text, language: .init("ko"))
    }
    private func journal(_ segment: TranscriptSegment, _ f: FinalizationFixture) async throws {
        try await f.repository.appendTranscriptJournal(.init(sessionId: f.location.sessionID, segment: segment), at: f.location)
    }
    private func fixture() async throws -> TranscriptFixture {
        let audio = try await FinalizationFixture.make()
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: audio.base.appendingPathComponent("catalog"))
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: audio.roots), store: store)
        let ready = await audio.worker().finalize(.init(location: audio.location), control: .init(), progress: { _ in })
        XCTAssertNil(ready.failure)
        return .init(audio: audio, catalog: catalog, repository: FileTranscriptRepository(roots: audio.roots, catalog: catalog), ready: ready)
    }
}

private struct TranscriptFixture {
    let audio: FinalizationFixture
    let catalog: SessionCatalogReconciler
    let repository: FileTranscriptRepository
    let ready: AudioFinalizationResult
}

private actor TranscriptOneShotFailure {
    private var armed = true
    func hit() throws {
        if armed { armed = false; throw AudioFinalizationCode.diskFull }
    }
}


extension TranscriptFinalizationTests {
    func testReviewT20CompletedSessionReopensOnReadOnlyRoot() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        try await journal(segment(0), f.audio)
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        let paths = ["metadata.json", "transcript.json", "transcript.txt", "transcript.md",
                     FinalizationFileAccess.checkpoint, FinalizationFileAccess.source, FinalizationFileAccess.canonical,
                     SessionArtifact.transcriptJournal.relativePath]
        let files = try FinalizationFileAccess(root: f.audio.root, location: f.audio.location)
        let identities = try paths.map { try files.identity($0) }
        let before = try paths.map { try Data(contentsOf: f.audio.url($0)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.audio.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.audio.root.path) }
        let request = AudioFinalizationRequest(location: f.audio.location, operation: .verifyExistingCanonical)
        let audioOnly = await f.audio.worker().finalize(request, control: .init(), progress: { _ in })
        XCTAssertNil(audioOnly.failure, "Established T09 audio verification works on the readable root")
        let queue = AudioFinalizationCoordinator(worker: SessionFinalizationWorker(audio: f.audio.worker(), transcripts: f.repository))
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: f.audio.roots),
            persistence: f.audio.repository, finalization: queue, catalog: f.catalog, activity: SessionActivityRegistry())
        await recovery.start(); await recovery.waitForCurrentPassSettlement()
        let snapshot = await recovery.currentSnapshot()
        XCTAssertEqual(snapshot.report?.items.first?.code, .sessionReady, "No repair is needed: \(snapshot)")
        XCTAssertEqual(try paths.map { try Data(contentsOf: f.audio.url($0)) }, before)
        XCTAssertEqual(try paths.map { try files.identity($0) }, identities, "Verification must not rewrite identical bytes")
        let state = await queue.allSnapshots()
        XCTAssertNil(state.first?.result?.transcriptFailure)
        let counts = await f.audio.bookmarks.counts()
        XCTAssertEqual(counts[0], counts[1])
    }

    func testReadOnlyDerivedRepairIsDistinguishedAndResumesAfterPermissionReturns() async throws {
        for path in ["transcript.txt", "transcript.md"] {
            for missing in [false, true] {
                let f = try await fixture(); defer { f.audio.clean() }
                let value = try segment(0); try await journal(value, f.audio)
                _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
                let edited = try await f.repository.updateText(at: f.audio.location, segmentID: value.id,
                    expectedText: value.text, text: "보존할 수정")
                let expected = try Data(contentsOf: f.audio.url(path))
                if missing { try FileManager.default.removeItem(at: f.audio.url(path)) }
                else { try Data("stale external export".utf8).write(to: f.audio.url(path), options: .atomic) }
                let protected = ["metadata.json", "transcript.json", FinalizationFileAccess.checkpoint,
                                 FinalizationFileAccess.source, FinalizationFileAccess.canonical,
                                 SessionArtifact.transcriptJournal.relativePath]
                let bytes = try protected.map { try Data(contentsOf: f.audio.url($0)) }
                let files = try FinalizationFileAccess(root: f.audio.root, location: f.audio.location)
                let identities = try protected.map { try files.identity($0) }
                let damaged = try files.identity(path)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.audio.root.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.audio.root.path) }
                let queue = AudioFinalizationCoordinator(worker: SessionFinalizationWorker(audio: f.audio.worker(), transcripts: f.repository))
                let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: f.audio.roots),
                    persistence: f.audio.repository, finalization: queue, catalog: f.catalog, activity: SessionActivityRegistry())
                await recovery.start(); await recovery.waitForCurrentPassSettlement()
                let failed = await recovery.currentSnapshot()
                let report = try XCTUnwrap(failed.report)
                XCTAssertEqual(report.items.first?.code, .transcriptFinalizationFailed)
                XCTAssertEqual(report.items.first?.warning, "transcript.repairRequired")
                let snapshots = await queue.allSnapshots()
                XCTAssertEqual(snapshots.first?.result?.transcriptFailure?.code, .repairRequired)
                let presentation = RecoveryStatusPresentation.make(report: report)
                XCTAssertEqual(presentation.items.first?.action, .reauthorize(f.audio.location.rootID))
                XCTAssertEqual(try protected.map { try Data(contentsOf: f.audio.url($0)) }, bytes)
                XCTAssertEqual(try protected.map { try files.identity($0) }, identities)
                XCTAssertEqual(try files.identity(path), damaged)
                let exits = LifecycleTerminationSpy()
                let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: queue,
                    recovery: recovery, activity: LifecycleActivitySpy(), termination: exits)
                await lifecycle.userWindowCountChanged(0)
                let state = await lifecycle.currentSnapshot(), exitCount = await exits.count()
                XCTAssertTrue(state.requiresUserAttention)
                XCTAssertFalse(state.blocksExplicitTermination)
                XCTAssertEqual(exitCount, 0)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.audio.root.path)
                await recovery.retry(); await recovery.waitForCurrentPassSettlement()
                let ready = await recovery.currentSnapshot()
                XCTAssertEqual(ready.report?.items.first?.code, .sessionReady)
                XCTAssertEqual(try Data(contentsOf: f.audio.url(path)), expected)
                let saved = try await f.audio.repository.readTranscript(at: f.audio.location)
                XCTAssertEqual(saved, edited)
                XCTAssertEqual(try protected.map { try files.identity($0) }, identities)
                let counts = await f.audio.bookmarks.counts()
                XCTAssertEqual(counts[0], counts[1])
            }
        }
    }

    func testReadOnlyVerificationRejectsReplacementDuringCatalogAwait() async throws {
        let f = try await fixture(); defer { f.audio.clean() }
        try await journal(segment(0), f.audio)
        _ = try await f.repository.finalize(at: f.audio.location, audio: f.ready, control: .init())
        let gate = FinalizationGate()
        let verifier = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog,
            hook: { if $0 == .afterCatalog { await gate.blockOnce() } })
        let pending = Task { try await verifier.finalize(at: f.audio.location, audio: f.ready, control: .init()) }
        await gate.waitEntered()
        let replacement = Data("external replacement".utf8)
        try replacement.write(to: f.audio.url("transcript.md"), options: .atomic)
        await gate.open()
        do { _ = try await pending.value; XCTFail("Must not certify bytes replaced while verification was suspended") }
        catch let error as AudioFinalizationCode { XCTAssertEqual(error, .identityChanged) }
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.md")), replacement)
        let counts = await f.audio.bookmarks.counts()
        XCTAssertEqual(counts[0], counts[1])
    }
}
