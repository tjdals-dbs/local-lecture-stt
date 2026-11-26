import XCTest
@testable import LocalLectureSTT

final class SpeechRecoveryTests: XCTestCase {
    func testCoverageSubtractsCompleteSilenceAndSplitsOnlyMissingIntervals() throws {
        var doc = try SpeechRecoveryDocument(session: STTTestFixture.session(), language: .init("ko"))
        doc.register(try .init(1_000, 2_000)); doc.entries[0].state = .complete
        try doc.addMissing(.init(0, 50_000))
        XCTAssertEqual(doc.entries.map(\.range.start), [1_000, 0, 2_000, 22_000, 42_000])
        XCTAssertEqual(doc.entries.map(\.range.end), [2_000, 1_000, 22_000, 42_000, 50_000])
        XCTAssertEqual(doc.summary.pending, 4)
        try doc.validate(sessionID: doc.session.sessionID)
    }

    func testCanonicalInsertsGapPreservingEditsIDsAndNonmonotonicT18SegmentOrder() throws {
        var doc = try SpeechRecoveryDocument(session: STTTestFixture.session(), language: .init("ko"), captureEnded: true)
        let a = try segment(0, 100, 900, "기존"), b = try segment(1, 600, 800, "뒤 구간"), gap = try segment(0, 1_200, 1_400, "복구")
        let c = try segment(2, 2_000, 2_500, "마지막")
        for (range, values) in [(try SpeechRecoveryRange(0, 1_000), [a, b]), (try .init(1_000, 2_000), [gap]), (try .init(2_000, 3_000), [c])] {
            doc.register(range); doc.entries[doc.entries.count - 1].state = .complete
            doc.entries[doc.entries.count - 1].segments = values
        }
        var edited = a; edited.text = "사용자 수정"
        let existing = try TranscriptDocument(sessionId: doc.session.sessionID, segments: [edited, b, c])
        let result = try doc.canonical(existing: existing, journal: [a, b, c], duration: .init(3_000))
        XCTAssertEqual(result.segments.map(\.id), [a.id, b.id, gap.id, c.id])
        XCTAssertEqual(result.segments.map(\.text), ["사용자 수정", "뒤 구간", "복구", "마지막"])
        XCTAssertEqual(result.segments.map(\.sequence.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(result.segments.map(\.startMs.rawValue), [100, 600, 1_200, 2_000])
    }

    func testActualAudioGapRepairAndCanonicalRetryAreIdempotentAndPreserveAudio() async throws {
        let f = try await RecoveryFixture.make(); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let kept = try segment(0, 0, 500, "기존 확정")
        try await f.store.prepare([kept], range: .init(0, 1_000), language: .init("ko"), at: f.audio.location)
        try await f.audio.repository.appendTranscriptJournal(.init(sessionId: f.audio.location.sessionID, segment: kept), at: f.audio.location)
        _ = try await f.store.complete(.init(0, 1_000), at: f.audio.location)
        let source = try Data(contentsOf: f.audio.url(FinalizationFileAccess.source))
        let first = await f.finish()
        XCTAssertNil(first.failure)
        let doc = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(doc.segments.map(\.text), ["기존 확정", "복구 1000"])
        XCTAssertEqual(doc.segments.first?.id, kept.id)
        let requests = await f.engine.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].context.mediaStart.rawValue, 1_000)
        XCTAssertTrue((15_984...16_000).contains(requests[0].audio.frameCount))
        XCTAssertEqual(requests[0].context.mediaEnd.rawValue, 2_000)
        let samples = requests[0].audio.samples
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertTrue((1_250...1_390).contains(crossings), "actual decoded second-half tone must be 1320 Hz")
        let canonical = try Data(contentsOf: f.audio.url("transcript.json"))
        let result = await f.finish()
        XCTAssertNil(result.failure)
        let count = await f.engine.requests.count; XCTAssertEqual(count, 1)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), canonical)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.source)), source)
        XCTAssertEqual(try f.ledger().summary, .init(pending: 0, unresolved: 0, recovered: 1, pendingRanges: [], unresolvedRanges: []))
        let detail = try await f.detail.load(f.audio.location)
        XCTAssertTrue(detail.editable); XCTAssertEqual(detail.speechRecovery?.recovered, 1)
        let scopes = await f.audio.bookmarks.counts(); XCTAssertEqual(scopes[0], scopes[1])
    }

    func testPreparedResultSurvivesCrashBeforeJournalAndDoesNotReinfer() async throws {
        let f = try await RecoveryFixture.make(); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let value = try segment(0, 100, 900, "저장 직전")
        try await f.store.prepare([value], range: .init(0, 1_000), language: .init("ko"), at: f.audio.location)
        try await f.store.prepare([], range: .init(1_000, 2_000), language: .init("ko"), at: f.audio.location)
        // Fresh store simulates losing all in-memory completion state.
        let fresh = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine })
        let result = await f.finish(store: fresh)
        XCTAssertNil(result.failure)
        let output = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(output.segments, [value])
        let requests = await f.engine.requests; XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try f.ledger().summary.pending, 0)
    }

    func testPersistentAttemptLimitPublishesPartialNoticeAndNeverRetriesExhaustedGap() async throws {
        let f = try await RecoveryFixture.make(failure: .inferenceFailed); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let result = await f.finish()
        XCTAssertEqual(result.transcriptFailure?.code, .speechIncomplete)
        let ledger = try f.ledger()
        XCTAssertEqual(ledger.summary, .init(pending: 0, unresolved: 2, recovered: 0, pendingRanges: [], unresolvedRanges: [try .init(0, 1_000), try .init(1_000, 2_000)]))
        XCTAssertEqual(ledger.entries.map(\.attempts), [2, 2])
        let md = try String(contentsOf: f.audio.url("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("미복구 2구간"))
        let detail = try await f.detail.load(f.audio.location)
        XCTAssertEqual(detail.speechRecovery?.unresolved, 2); XCTAssertTrue(detail.editable)
        _ = await f.finish(store: .init(roots: f.audio.roots, makeEngine: { _ in f.engine }))
        let count = await f.engine.requests.count; XCTAssertEqual(count, 4)
    }

    func testMissingModelLeavesPendingAndLocksEditingUntilModelRestored() async throws {
        let f = try await RecoveryFixture.make(loadFailure: true); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let first = await f.finish()
        XCTAssertEqual(first.transcriptFailure?.code, .speechIncomplete)
        XCTAssertEqual(try f.ledger().entries.map(\.attempts), [0, 0])
        let detail = try await f.detail.load(f.audio.location)
        XCTAssertFalse(detail.editable); XCTAssertEqual(detail.speechRecovery?.pending, 2)
        do { try await f.transcripts.updateTitle(at: f.audio.location, expectedTitle: "Synthetic finalization", title: "changed"); XCTFail("pending repair must lock edits") }
        catch { XCTAssertEqual((error as? TranscriptFailure)?.code, .notFinalized) }
        await f.engine.restoreModel()
        let fresh = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine })
        let second = await f.finish(store: fresh)
        XCTAssertNil(second.failure); XCTAssertEqual(try f.ledger().summary.pending, 0)
        let models = await f.engine.loaded; XCTAssertTrue(models.allSatisfy { $0 == f.session.model })
    }

    func testCancellationCheckpointResumesOnlyUncommittedGapInFreshStore() async throws {
        let gate = T14Gate()
        let f = try await RecoveryFixture.make(gateAt: 1, gate: gate); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let control = AudioFinalizationControl()
        let run = Task { await f.finish(control: control) }
        try await gate.wait(); control.cancel(); await gate.release()
        let cancelled = await run.value
        XCTAssertEqual(cancelled.failure, .cancelled)
        let before = try f.ledger()
        XCTAssertEqual(before.entries.map(\.state), [.complete, .pending])
        XCTAssertEqual(before.entries.map(\.attempts), [1, 0])
        let firstID = before.entries[0].segments[0].id
        let fresh = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine })
        let done = await f.finish(store: fresh)
        XCTAssertNil(done.failure)
        let requests = await f.engine.requests
        XCTAssertEqual(requests.map(\.context.mediaStart.rawValue), [0, 1_000, 1_000])
        XCTAssertEqual(try f.ledger().entries[0].segments[0].id, firstID)
        let scopes = await f.audio.bookmarks.counts(); XCTAssertEqual(scopes[0], scopes[1])
    }

    func testCorruptLedgerAndModelMismatchFailClosedPreservingAllSessionBytes() async throws {
        let f = try await RecoveryFixture.make(); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let path = f.audio.url(SpeechRecoveryDocument.path)
        let original = try Data(contentsOf: path), source = try Data(contentsOf: f.audio.url(FinalizationFileAccess.source))
        try Data("{broken".utf8).write(to: path)
        let result = await f.finish()
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(try Data(contentsOf: path), Data("{broken".utf8))
        try original.write(to: path)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var session = try XCTUnwrap(json["session"] as? [String: Any])
        var model = try XCTUnwrap(session["model"] as? [String: Any])
        var identity = try XCTUnwrap(model["model"] as? [String: Any]); identity["revision"] = "foreign"
        model["model"] = identity; session["model"] = model; json["session"] = session
        let altered = try JSONSerialization.data(withJSONObject: json); try altered.write(to: path)
        let mismatch = await f.finish()
        XCTAssertNotNil(mismatch.failure); XCTAssertEqual(try Data(contentsOf: path), altered)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.source)), source)
        let loaded = await f.engine.loaded; XCTAssertTrue(loaded.isEmpty)
    }

    func testTimeoutConsumesBoundedAttemptAndJoinsEngineBeforeReleasingScope() async throws {
        let f = try await RecoveryFixture.make(hang: true); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let store = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine }, requestTimeout: .milliseconds(100))
        let result = await f.finish(store: store)
        XCTAssertEqual(result.transcriptFailure?.code, .speechIncomplete)
        XCTAssertEqual(try f.ledger().entries[0].attempts, 1)
        let counts = await f.engine.counts; XCTAssertGreaterThanOrEqual(counts[0], 1); XCTAssertEqual(counts[1], 1)
        let scopes = await f.audio.bookmarks.counts(); XCTAssertEqual(scopes[0], scopes[1])
    }

    func testSecondTimeoutPublishesExhaustedPartialWithoutThirdInferenceAndPreservesExistingData() async throws {
        let f = try await RecoveryFixture.make(hang: true)
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let kept = try segment(0, 1_100, 1_900, "기존 확정")
        try await f.store.prepare([kept], range: .init(1_000, 2_000), language: .init("ko"), at: f.audio.location)
        try await f.audio.repository.appendTranscriptJournal(.init(sessionId: f.audio.location.sessionID, segment: kept), at: f.audio.location)
        _ = try await f.store.complete(.init(1_000, 2_000), at: f.audio.location)
        var edited = kept; edited.text = "사용자 수정"
        let canonical = try TranscriptDocument(sessionId: f.audio.location.sessionID, segments: [edited])
        try JSONEncoder().encode(canonical).write(to: f.audio.url("transcript.json"))
        let source = try Data(contentsOf: f.audio.url(FinalizationFileAccess.source))
        let journal = try Data(contentsOf: f.audio.url(SessionArtifact.transcriptJournal.relativePath))
        var finalAudio: Data?
        for attempt in 1...2 {
            let control = AudioFinalizationControl()
            let fresh = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine }, requestTimeout: .milliseconds(50))
            let result = await f.finish(store: fresh, control: control)
            XCTAssertEqual(result.transcriptFailure?.code, .speechIncomplete)
            XCTAssertEqual(result.failure, .transcript) // Partial output is not a healthy completion.
            XCTAssertNil(control.outcome().0) // Publication retains a usable cancellation control.
            let ledger = try f.ledger()
            let missing = try XCTUnwrap(ledger.entries.first { $0.range.start == 0 })
            XCTAssertEqual(missing.attempts, attempt)
            XCTAssertEqual(missing.state, attempt == 1 ? .pending : .exhausted)
            XCTAssertEqual(ledger.summary.pending, attempt == 1 ? 1 : 0)
            XCTAssertEqual(ledger.summary.unresolved, attempt == 1 ? 0 : 1)
            let detail = try await f.detail.load(f.audio.location)
            XCTAssertEqual(detail.editable, attempt == 2)
            XCTAssertEqual(detail.speechRecovery, ledger.summary)
            let output = try await f.audio.repository.readTranscript(at: f.audio.location)
            XCTAssertEqual(output.segments, [edited])
            let md = (try? String(contentsOf: f.audio.url("transcript.md"), encoding: .utf8)) ?? ""
            XCTAssertTrue(md.contains(attempt == 1 ? "복구 대기 1구간" : "미복구 1구간"))
            XCTAssertTrue(md.contains("사용자 수정"))
            let audio = try Data(contentsOf: f.audio.url("audio.m4a"))
            if let finalAudio { XCTAssertEqual(audio, finalAudio) } else { finalAudio = audio }
        }
        // Exhausted work and partial publication must not depend on an available model.
        let noModel = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in
            XCTFail("an exhausted gap must not construct an engine"); throw STTEngineError(.loadFailed)
        })
        let again = await f.finish(store: noModel)
        XCTAssertEqual(again.transcriptFailure?.code, .speechIncomplete)
        let requests = await f.engine.requests
        XCTAssertEqual(requests.map(\.context.mediaStart.rawValue), [0, 0])
        XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.source)), source)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(SessionArtifact.transcriptJournal.relativePath)), journal)
        let scopes = await f.audio.bookmarks.counts(); XCTAssertEqual(scopes[0], scopes[1])
    }

    func testCanonicalPublicationFaultResumesFromDurableResultWithoutAnotherInference() async throws {
        let f = try await RecoveryFixture.make(); addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let failing = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: { point in
            if point == .afterCanonical { throw TranscriptFailure(code: .storage) }
        })
        let worker = SessionFinalizationWorker(audio: f.audio.worker(), transcripts: failing, gapRepair: f.store)
        let first = await worker.finalize(.init(location: f.audio.location), control: .init(), progress: { _ in })
        XCTAssertNotNil(first.failure)
        let saved = try Data(contentsOf: f.audio.url("transcript.json"))
        let second = await f.finish()
        XCTAssertNil(second.failure)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), saved)
        let count = await f.engine.requests.count; XCTAssertEqual(count, 2)
    }

    func testAlreadyConsumedPendingBudgetPublishesPartialWithoutConstructingMissingModel() async throws {
        let f = try await RecoveryFixture.make(loadFailure: true)
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        _ = await f.finish() // Seal capture and publish pending work without consuming attempts.
        var ledger = try f.ledger()
        for i in ledger.entries.indices { ledger.entries[i].attempts = 2 }
        // Simulate the durable checkpoint left by the old build or a process exit.
        try JSONEncoder().encode(ledger).write(to: f.audio.url(SpeechRecoveryDocument.path))
        let source = try Data(contentsOf: f.audio.url(FinalizationFileAccess.source))
        let store = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in
            XCTFail("budget normalization must precede model construction"); throw STTEngineError(.loadFailed)
        })
        let result = await f.finish(store: store)
        XCTAssertEqual(result.transcriptFailure?.code, .speechIncomplete)
        let exhausted = try f.ledger()
        XCTAssertEqual(exhausted.entries.map(\.id), ledger.entries.map(\.id))
        XCTAssertEqual(exhausted.entries.map(\.attempts), [2, 2])
        XCTAssertEqual(exhausted.entries.map(\.state), [.exhausted, .exhausted])
        XCTAssertEqual(exhausted.summary.pending, 0); XCTAssertEqual(exhausted.summary.unresolved, 2)
        let detail = try await f.detail.load(f.audio.location)
        XCTAssertTrue(detail.editable); XCTAssertEqual(detail.speechRecovery, exhausted.summary)
        let md = try String(contentsOf: f.audio.url("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("미복구 2구간"))
        let requests = await f.engine.requests; XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(FinalizationFileAccess.source)), source)
    }

    func testExplicitCancelOfSecondAttemptRefundsBudgetAndPreservesPublishedPartial() async throws {
        let gate = T14Gate()
        let f = try await RecoveryFixture.make(gateAt: 1, gate: gate, hang: true)
        addTeardownBlock { await gate.release(); try await f.catalogStore.close(); f.audio.clean() }
        let firstStore = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine }, requestTimeout: .milliseconds(50))
        let first = await f.finish(store: firstStore)
        XCTAssertEqual(first.transcriptFailure?.code, .speechIncomplete)
        let paths = ["transcript.json", "transcript.txt", "transcript.md", "audio.m4a", FinalizationFileAccess.source]
        let before = try paths.map { try Data(contentsOf: f.audio.url($0)) }
        let control = AudioFinalizationControl()
        let run = Task { await f.finish(control: control) }
        try await gate.wait(); control.cancel(); await gate.release()
        let cancelled = await run.value
        XCTAssertEqual(cancelled.failure, .cancelled)
        let ledger = try f.ledger()
        let missing = try XCTUnwrap(ledger.entries.first { $0.range.start == 0 })
        XCTAssertEqual(missing.attempts, 1); XCTAssertEqual(missing.state, .pending)
        XCTAssertEqual(try paths.map { try Data(contentsOf: f.audio.url($0)) }, before)
        let counts = await f.engine.counts; XCTAssertEqual(counts[1], 2)
        let scopes = await f.audio.bookmarks.counts(); XCTAssertEqual(scopes[0], scopes[1])
    }

    func testTimeoutCleanupIsJoinedAndLaterUserCancelDoesNotRefundConsumedTimeout() async throws {
        let gate = T14Gate()
        let f = try await RecoveryFixture.make(hang: true, cancelGate: gate)
        addTeardownBlock { await gate.release(); try await f.catalogStore.close(); f.audio.clean() }
        let control = AudioFinalizationControl()
        let store = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine }, requestTimeout: .milliseconds(50))
        let run = Task { await f.finish(store: store, control: control) }
        try await gate.wait()
        let held = await f.engine.counts; XCTAssertEqual(held, [1, 0])
        let activeScopes = await f.audio.bookmarks.counts(); XCTAssertGreaterThan(activeScopes[0], activeScopes[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("transcript.md").path))
        control.cancel(); await gate.release()
        let cancelled = await run.value
        XCTAssertEqual(cancelled.failure, .cancelled)
        XCTAssertEqual(try f.ledger().entries.first { $0.range.start == 0 }?.attempts, 1)
        let counts = await f.engine.counts; XCTAssertEqual(counts[1], 1)
        let scopes = await f.audio.bookmarks.counts(); XCTAssertEqual(scopes[0], scopes[1])
    }

    func testSecondTimeoutPublicationFaultRetriesSavedPartialWithoutModelOrInference() async throws {
        let f = try await RecoveryFixture.make(hang: true)
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let kept = try segment(0, 1_100, 1_900, "보존할 문장")
        try await f.store.prepare([kept], range: .init(1_000, 2_000), language: .init("ko"), at: f.audio.location)
        _ = try await f.store.complete(.init(1_000, 2_000), at: f.audio.location)
        let store = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine }, requestTimeout: .milliseconds(50))
        _ = await f.finish(store: store)
        let failing = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: { point in
            // Canonical text is unchanged; fail the required incomplete-notice update.
            if point == .beforeMarkdown { throw TranscriptFailure(code: .storage) }
        })
        let worker = SessionFinalizationWorker(audio: f.audio.worker(), transcripts: failing, gapRepair: store)
        let failed = await worker.finalize(.init(location: f.audio.location), control: .init(), progress: { _ in })
        XCTAssertEqual(failed.transcriptFailure?.code, .storage)
        XCTAssertEqual(try f.ledger().summary.unresolved, 1)
        let canonical = try Data(contentsOf: f.audio.url("transcript.json"))
        let noModel = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in
            XCTFail("publication retry must not load a model"); throw STTEngineError(.loadFailed)
        })
        let result = await f.finish(store: noModel)
        XCTAssertEqual(result.transcriptFailure?.code, .speechIncomplete)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), canonical)
        let output = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(output.segments, [kept])
        let md = try String(contentsOf: f.audio.url("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("미복구 1구간")); XCTAssertTrue(md.contains("보존할 문장"))
        let count = await f.engine.requests.count; XCTAssertEqual(count, 2)
    }

    func testStartupScannerResumesPendingRepairAfterModelRestored() async throws {
        let f = try await RecoveryFixture.make(loadFailure: true)
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        _ = await f.finish()
        await f.engine.restoreModel()
        let repair = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in f.engine })
        let worker = SessionFinalizationWorker(audio: f.audio.worker(), transcripts: f.transcripts, gapRepair: repair)
        let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: f.audio.roots), persistence: f.audio.repository,
            finalization: AudioFinalizationCoordinator(worker: worker), catalog: f.catalog)
        await recovery.start(); await recovery.waitForCurrentPassSettlement()
        let metadata = try await f.audio.repository.readMetadata(at: f.audio.location)
        XCTAssertEqual(metadata.transcript.recovery?.pending, 0)
        XCTAssertEqual(metadata.transcript.recovery?.recovered, 2)
        let transcript = try await f.audio.repository.readTranscript(at: f.audio.location)
        XCTAssertEqual(transcript.segments.count, 2)
    }

    func testHealthyCompletedRecoveryValidatesReadOnlyWithoutLoadingEngine() async throws {
        let f = try await RecoveryFixture.make()
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let first = await f.finish(); XCTAssertNil(first.failure)
        let original = try Data(contentsOf: f.audio.url(SpeechRecoveryDocument.path))
        let canonical = try Data(contentsOf: f.audio.url("transcript.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.audio.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.audio.root.path) }
        let store = FileSpeechRecoveryStore(roots: f.audio.roots, makeEngine: { _ in throw STTEngineError(.loadFailed) })
        let worker = SessionFinalizationWorker(audio: f.audio.worker(), transcripts: f.transcripts, gapRepair: store)
        let result = await worker.finalize(.init(location: f.audio.location, operation: .verifyExistingCanonical), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(SpeechRecoveryDocument.path)), original)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), canonical)
    }

    func testMissingLedgerIsNotLegacyAndIncompleteJournalIsNeverSilentlyDiscarded() async throws {
        let f = try await RecoveryFixture.make()
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let path = f.audio.url(SpeechRecoveryDocument.path), original = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        let missing = await f.finish()
        XCTAssertEqual(missing.transcriptFailure?.code, .missingCanonical)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("transcript.json").path))
        let detail = try await f.detail.load(f.audio.location)
        XCTAssertFalse(detail.editable); XCTAssertTrue(detail.issues.contains { $0.artifact == SpeechRecoveryDocument.path })
        try original.write(to: path)
        let broken = Data("{torn".utf8)
        try broken.write(to: f.audio.url(SessionArtifact.transcriptJournal.relativePath))
        let torn = await f.finish()
        XCTAssertNotNil(torn.transcriptFailure)
        XCTAssertEqual(try Data(contentsOf: f.audio.url(SessionArtifact.transcriptJournal.relativePath)), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("transcript.json").path))
    }

    func testLegacySessionWithoutRecoveryMarkerDoesNotTranscribeEntireAudio() async throws {
        let audio = try await FinalizationFixture.make()
        let catalogStore = try SQLiteSessionCatalogStore(applicationSupportDirectory: audio.base.appendingPathComponent("catalog"))
        addTeardownBlock { try await catalogStore.close(); audio.clean() }
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: audio.roots), store: catalogStore)
        let repair = FileSpeechRecoveryStore(roots: audio.roots, makeEngine: { _ in XCTFail("legacy must not create engine"); throw STTEngineError(.loadFailed) })
        let worker = SessionFinalizationWorker(audio: audio.worker(), transcripts: FileTranscriptRepository(roots: audio.roots, catalog: catalog), gapRepair: repair)
        let result = await worker.finalize(.init(location: audio.location), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure)
        let metadata = try await audio.repository.readMetadata(at: audio.location)
        XCTAssertNil(metadata.transcript.recovery)
    }

    func testCrashTailAndOverlappingPendingRangeExcludeAlreadyCommittedSpeech() async throws {
        let f = try await RecoveryFixture.make()
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        var ledger = try f.ledger()
        ledger.entries.removeLast()
        ledger.entries[0].state = .complete // explicitly processed silence 0...1000
        ledger.scannedThrough = 500
        ledger.register(try .init(500, 1_500))
        try JSONEncoder().encode(ledger).write(to: f.audio.url(SpeechRecoveryDocument.path))
        let result = await f.finish(); XCTAssertNil(result.failure)
        let requests = await f.engine.requests
        XCTAssertEqual(requests.map(\.context.mediaStart.rawValue), [1_000, 1_500])
        XCTAssertEqual(requests.map(\.context.mediaEnd.rawValue), [1_500, 2_000])
        let ranges = try f.ledger().entries.map(\.range)
        XCTAssertEqual(ranges, [try .init(0, 1_000), try .init(1_000, 1_500), try .init(1_500, 2_000)])
    }

    func testCompletedLedgerStillChecksModelProvenanceBeforeReadOnlySuccess() async throws {
        let f = try await RecoveryFixture.make()
        addTeardownBlock { try await f.catalogStore.close(); f.audio.clean() }
        let first = await f.finish(); XCTAssertNil(first.failure)
        let path = f.audio.url("metadata.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var model = try XCTUnwrap(json["model"] as? [String: Any])
        model["revision"] = "changed-after-completion"; json["model"] = model
        let altered = try JSONSerialization.data(withJSONObject: json); try altered.write(to: path)
        let second = await f.finish()
        XCTAssertNotNil(second.failure)
        XCTAssertEqual(try Data(contentsOf: path), altered)
        let detail = try await f.detail.load(f.audio.location)
        XCTAssertFalse(detail.editable)
    }

    private func segment(_ sequence: Int64, _ start: Int64, _ end: Int64, _ text: String) throws -> TranscriptSegment {
        try .init(id: .init(UUID()), sequence: .init(sequence), startMs: .init(start), endMs: .init(end), originalText: text, text: text, language: .init("ko"))
    }
}

private struct RecoveryFixture: Sendable {
    let audio: FinalizationFixture
    let session: STTSessionConfiguration
    let engine: RecoveryEngine
    let store: FileSpeechRecoveryStore
    let transcripts: FileTranscriptRepository
    let catalog: SessionCatalogReconciler
    let catalogStore: SQLiteSessionCatalogStore
    let detail: FileSessionDetailStore
    func ledger() throws -> SpeechRecoveryDocument {
        try JSONDecoder().decode(SpeechRecoveryDocument.self, from: Data(contentsOf: audio.url(SpeechRecoveryDocument.path)))
    }
    func finish(store override: FileSpeechRecoveryStore? = nil, control: AudioFinalizationControl = .init()) async -> AudioFinalizationResult {
        await SessionFinalizationWorker(audio: audio.worker(), transcripts: transcripts, gapRepair: override ?? store)
            .finalize(.init(location: audio.location), control: control, progress: { _ in })
    }
    static func make(failure: STTErrorCode? = nil, loadFailure: Bool = false,
                     gateAt: Int? = nil, gate: T14Gate? = nil, hang: Bool = false, cancelGate: T14Gate? = nil) async throws -> Self {
        let audio = try await FinalizationFixture.make()
        let model = try STTTestFixture.model()
        let session = STTSessionConfiguration(sessionID: audio.location.sessionID, operationID: .init(UUID()), model: model, languageMode: .korean)
        let old = try await audio.repository.readMetadata(at: audio.location)
        let metadata = try SessionMetadataDocument(sessionId: old.sessionId, title: old.title, status: old.status, captureOutcome: old.captureOutcome,
            createdAt: old.createdAt, recordingStartedAt: old.recordingStartedAt, recordingEndedAt: old.recordingEndedAt,
            activeDurationMs: old.activeDurationMs, languageMode: .korean, engine: model.engine, model: model.model,
            modelSettings: .init(weightSHA256: String(repeating: "0", count: 64), quantization: "none", inference: model.options, decodingStrategy: "default"),
            transcript: .init(segmentCount: old.transcript.segmentCount, recovery: .init(pending: 0, unresolved: 0, recovered: 0)), appVersion: old.appVersion, osVersion: old.osVersion, lastUpdatedAt: old.lastUpdatedAt)
        try await audio.repository.writeMetadata(metadata, at: audio.location)
        let engine = try RecoveryEngine(failure: failure, loadFailure: loadFailure, gateAt: gateAt, gate: gate, hang: hang, cancelGate: cancelGate)
        let store = FileSpeechRecoveryStore(roots: audio.roots, makeEngine: { _ in engine })
        try await store.initialize(session, at: audio.location)
        _ = try await store.observe(windows: [.init(0, 1_000), .init(1_000, 2_000)], missing: [], through: 2_000, ended: true, at: audio.location)
        let catalogStore = try SQLiteSessionCatalogStore(applicationSupportDirectory: audio.base.appendingPathComponent("catalog"))
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: audio.roots), store: catalogStore)
        let transcripts = FileTranscriptRepository(roots: audio.roots, catalog: catalog)
        return .init(audio: audio, session: session, engine: engine, store: store, transcripts: transcripts, catalog: catalog, catalogStore: catalogStore,
            detail: FileSessionDetailStore(roots: audio.roots, transcripts: transcripts, catalog: catalog, activity: .init()))
    }
}

private actor RecoveryEngine: STTEngine {
    nonisolated let capabilities: STTCapabilities
    let failure: STTErrorCode?
    var loadFailure: Bool
    let gateAt: Int?, gate: T14Gate?, hang: Bool
    let cancelGate: T14Gate?
    var loaded: [STTModelConfiguration] = [], requests: [STTInferenceRequest] = []
    var pending: (STTInferenceRequest, STTEventFeed)?
    var counts = [0, 0] // cancel, unload
    init(failure: STTErrorCode?, loadFailure: Bool, gateAt: Int?, gate: T14Gate?, hang: Bool, cancelGate: T14Gate?) throws {
        capabilities = try STTTestFixture.capabilities(); self.failure = failure; self.loadFailure = loadFailure
        self.gateAt = gateAt; self.gate = gate; self.hang = hang; self.cancelGate = cancelGate
    }
    func restoreModel() { loadFailure = false }
    func load(_ model: STTModelConfiguration) throws { loaded.append(model); if loadFailure { throw STTEngineError(.loadFailed) } }
    func start(_ session: STTSessionConfiguration) throws {}
    func infer(_ request: STTInferenceRequest) async throws -> STTEventFeed {
        let index = requests.count; requests.append(request)
        let feed = STTEventFeed(withdraw: {})
        if gateAt == index { await gate?.hold() }
        try Task.checkCancellation()
        if hang { pending = (request, feed); return feed }
        if let failure { feed.publish(try .init(context: request.context, revision: 1, kind: .failed, failure: .init(failure))) }
        else {
            feed.publish(try .init(context: request.context, revision: 1, kind: .final, segments: [
                .init(start: request.context.mediaStart, end: request.context.mediaEnd, text: "복구 \(request.context.mediaStart.rawValue)")], detectedLanguage: .init("ko")))
        }
        return feed
    }
    func end() throws {}
    func cancel() async throws {
        counts[0] += 1
        await cancelGate?.hold()
        if let (request, feed) = pending { feed.publish(try .init(context: request.context, revision: 1, kind: .cancelled, failure: .init(.cancelled))); pending = nil }
    }
    func unload() { counts[1] += 1 }
}
