import Combine
import SwiftUI
import XCTest
@testable import LocalLectureSTT

@MainActor
final class ActiveRecordingUITests: XCTestCase {
    func testTenThousandFinalsAreUnchangedByOneThousandPartialUpdates() throws {
        let presentation = LiveTranscriptPresentation()
        let session = SessionID()
        var speech = LiveSTTSnapshot(phase: .listening)
        speech.finals = try (0..<10_000).map(segment)
        presentation.update(sessionID: session, speech: speech)
        let pages = presentation.pages
        var historyUpdates = 0
        var pageUpdates = 0
        var partialUpdates = 0
        var observers = pages.map { $0.objectWillChange.sink { pageUpdates += 1 } }
        observers.append(presentation.objectWillChange.sink { historyUpdates += 1 })
        observers.append(presentation.partial.objectWillChange.sink { partialUpdates += 1 })
        for index in 0..<1_000 {
            speech.partial = "새로운 임시 발화 \(index)"
            presentation.update(sessionID: session, speech: speech)
        }
        XCTAssertEqual(historyUpdates, 0)
        XCTAssertEqual(pageUpdates, 0)
        XCTAssertEqual(partialUpdates, 1_000)
        XCTAssertEqual(presentation.pages.map(\.id), pages.map(\.id))
        XCTAssertEqual(presentation.pages.flatMap(\.segments), speech.finals)
        XCTAssertTrue(presentation.pages.allSatisfy { $0.segments.count <= 64 })
        withExtendedLifetime(observers) {}
    }

    func testAppendingAcrossPageBoundariesPreservesEarlierIdentityOrderAndOverlappingTimes() throws {
        let presentation = LiveTranscriptPresentation(); let session = SessionID()
        var speech = LiveSTTSnapshot(phase: .listening)
        speech.finals = try (0..<130).map(segment)
        presentation.update(sessionID: session, speech: speech)
        let first = presentation.pages[0]; let second = presentation.pages[1]; let tail = presentation.pages[2]
        var frozenUpdates = 0; var tailUpdates = 0
        let observers = [first.objectWillChange.sink { frozenUpdates += 1 },
                         second.objectWillChange.sink { frozenUpdates += 1 },
                         tail.objectWillChange.sink { tailUpdates += 1 }]
        // Sequence remains authoritative: valid overlapping/equal timestamps must not sort or merge rows.
        let next = try TranscriptSegment(id: .init(), sequence: .init(130), startMs: .init(0), endMs: .init(0),
            originalText: "다시 확인합니다", text: "다시 확인합니다", language: .init("ko"))
        speech.finals.append(next)
        speech.finals += try (131..<260).map(segment)
        presentation.update(sessionID: session, speech: speech)
        XCTAssertTrue(presentation.pages[0] === first); XCTAssertTrue(presentation.pages[1] === second)
        XCTAssertTrue(presentation.pages[2] === tail)
        XCTAssertEqual(frozenUpdates, 0); XCTAssertEqual(tailUpdates, 1)
        XCTAssertEqual(presentation.pages.flatMap(\.segments), speech.finals)
        withExtendedLifetime(observers) {}
    }

    func testPartialToFinalTransitionAndLateSubscriberKeepDurableFinals() throws {
        let presentation = LiveTranscriptPresentation(); let session = SessionID()
        var speech = LiveSTTSnapshot(phase: .listening, partial: "바뀔 수 있는 임시")
        presentation.update(sessionID: session, speech: speech)
        XCTAssertTrue(presentation.pages.isEmpty)
        speech.finals = [try segment(0)]; speech.partial = nil
        presentation.update(sessionID: session, speech: speech)
        XCTAssertNil(presentation.partial.text)
        let reopened = LiveTranscriptPresentation()
        reopened.update(sessionID: session, speech: speech)
        XCTAssertEqual(reopened.pages.flatMap(\.segments), presentation.pages.flatMap(\.segments))
        var changes = 0
        let observation = presentation.contentChanges.sink { _ in changes += 1 }
        speech.partial = ""; presentation.update(sessionID: session, speech: speech)
        XCTAssertEqual(changes, 0, "nil and empty partial should not cause scroll/layout churn")
        withExtendedLifetime(observation) {}
    }

    func testNewSessionWithSameFinalCountClearsOldContentAndResetsFollowSignal() throws {
        let presentation = LiveTranscriptPresentation()
        let first = SessionID(); let second = SessionID()
        presentation.update(sessionID: first, speech: .init(phase: .listening, finals: [try segment(0)], partial: "이전 임시"))
        let oldPage = presentation.pages[0]
        var resets = 0
        let observer = presentation.contentChanges.sink { if case .reset = $0 { resets += 1 } }
        let next = try segment(1)
        presentation.update(sessionID: second, speech: .init(phase: .listening, finals: [next]))
        XCTAssertEqual(presentation.pages.flatMap(\.segments), [next]); XCTAssertNil(presentation.partial.text)
        XCTAssertFalse(presentation.pages[0] === oldPage); XCTAssertEqual(resets, 1)
        presentation.update(sessionID: nil, speech: .idle)
        XCTAssertTrue(presentation.pages.isEmpty); XCTAssertEqual(presentation.finalCount, 0)
        XCTAssertEqual(presentation.notices.state.phase, .idle); XCTAssertEqual(resets, 2)
        withExtendedLifetime(observer) {}
    }

    func testUserScrollSuspendsFollowingUntilBottomOrExplicitLatest() {
        var following = TranscriptScrollFollowing()
        XCTAssertTrue(following.shouldScroll)
        following.userBeganScrolling()
        for _ in 0..<1_000 { XCTAssertFalse(following.shouldScroll) }
        following.userEndedScrolling(atBottom: false)
        XCTAssertFalse(following.followsLatest); XCTAssertFalse(following.shouldScroll)
        // Content growth/partial replacements do not call a user transition.
        following.showLatest(); XCTAssertTrue(following.shouldScroll)
        following.userBeganScrolling(); following.userEndedScrolling(atBottom: true)
        XCTAssertTrue(following.shouldScroll)
        following.userBeganScrolling(); following.showLatest()
        XCTAssertTrue(following.shouldScroll, "explicit Latest also supersedes deceleration")
        following.userBeganScrolling(); following.reset()
        XCTAssertTrue(following.shouldScroll)
    }

    func testNoticesDoNotInvalidateFinalOrPartialContent() throws {
        let presentation = LiveTranscriptPresentation(); let session = SessionID()
        var speech = LiveSTTSnapshot(phase: .listening, finals: [try segment(0)], partial: "임시")
        presentation.update(sessionID: session, speech: speech)
        var history = 0; var partial = 0; var scroll = 0; var notice = 0
        let observers = [presentation.objectWillChange.sink { history += 1 },
                         presentation.pages[0].objectWillChange.sink { history += 1 },
                         presentation.partial.objectWillChange.sink { partial += 1 },
                         presentation.contentChanges.sink { _ in scroll += 1 },
                         presentation.notices.objectWillChange.sink { notice += 1 }]
        speech.degraded = true; speech.pendingFinals = 4
        speech.inputDiscontinuities = 1; speech.failure = .inferenceFailed
        speech.storageWarning = "journalAppendFailed"; speech.phase = .failed
        presentation.update(sessionID: session, speech: speech)
        XCTAssertEqual(notice, 1); XCTAssertEqual(history, 0); XCTAssertEqual(partial, 0); XCTAssertEqual(scroll, 0)
        XCTAssertEqual(presentation.notices.state.failure, .inferenceFailed)
        XCTAssertEqual(presentation.notices.state.storageWarning, "journalAppendFailed")
        XCTAssertTrue(presentation.notices.state.degraded)
        withExtendedLifetime(observers) {}
    }

    func testMeterAndElapsedUpdatesDoNotInvalidateTranscriptAndStopSurvivesSTTFailure() async throws {
        let coordinator = ActiveUICoordinator()
        let model = RecordingSessionViewModel(coordinator: coordinator)
        model.startObserving(); defer { model.stopObserving() }
        let session = SessionID()
        let speech = LiveSTTSnapshot(phase: .failed, finals: [try segment(0)], pendingFinals: 4,
            degraded: true, failure: .inferenceFailed, storageWarning: "journalAppendFailed")
        await coordinator.emit(recording(session, speech: speech))
        await eventually { model.transcript.finalCount == 1 }
        var publications = 0
        let observers = [model.transcript.objectWillChange.sink { publications += 1 },
                         model.transcript.pages[0].objectWillChange.sink { publications += 1 },
                         model.transcript.partial.objectWillChange.sink { publications += 1 }]
        var observedLevels = Set<Float>()
        for i in 1...100 {
            await coordinator.emit(recording(session, speech: speech, elapsed: UInt64(i * 1_000)))
            await eventually { model.snapshot.elapsedMilliseconds == UInt64(i * 1_000) }
            observedLevels.insert(model.snapshot.normalizedInputLevel)
        }
        XCTAssertEqual(observedLevels.count, 100)
        XCTAssertEqual(publications, 0); XCTAssertEqual(model.elapsedText, "00:01:40")
        XCTAssertEqual(model.displayState, .recording); XCTAssertTrue(model.snapshot.noInputWarning)
        XCTAssertTrue(model.actions.canStop); XCTAssertFalse(model.actions.canEditConfiguration)
        XCTAssertFalse(model.actions.canStart)
        await model.stopRecording()
        let stops = await coordinator.stops; XCTAssertEqual(stops, 1)
        withExtendedLifetime(observers) {}
    }

    func testFinishingAndObservationRestartPreserveFinalsWithoutOwningRecording() async throws {
        let coordinator = ActiveUICoordinator(); let model = RecordingSessionViewModel(coordinator: coordinator)
        let session = SessionID(); let segment = try segment(0)
        model.startObserving()
        await coordinator.emit(recording(session, speech: .init(phase: .finishing, finals: [segment]), phase: .securedAwaitingFinalization))
        await eventually { model.transcript.notices.state.phase == .finishing }
        XCTAssertEqual(model.displayState, .secured); XCTAssertFalse(model.actions.canStop)
        model.stopObserving()
        model.startObserving()
        await coordinator.emit(recording(session, speech: .init(phase: .finished, finals: [segment]), phase: .securedAwaitingFinalization))
        await eventually { model.transcript.notices.state.phase == .finished }
        XCTAssertEqual(model.transcript.pages.flatMap(\.segments), [segment])
        let stops = await coordinator.stops; XCTAssertEqual(stops, 0)
        model.stopObserving()
    }

    func testBackgroundSummaryKeepsEarlierFailureVisibleBesideAnotherSession() {
        let location = location()
        let failed = finalizationFailure(location)
        let first = AudioFinalizationSnapshot(location: location, generation: 1, operation: .resume, phase: .failed, result: failed)
        let second = AudioFinalizationSnapshot(location: self.location(), generation: 2, operation: .resume, phase: .exporting, result: nil)
        let summary = RecordingSessionViewModel.backgroundWorkText([first, second], speech: .finishing)
        XCTAssertTrue(summary?.contains("남은 전사 처리 중") == true)
        XCTAssertTrue(summary?.contains("마무리 작업 1개") == true)
        XCTAssertTrue(summary?.contains("마무리 확인 필요 1개") == true)
        XCTAssertNil(RecordingSessionViewModel.backgroundWorkText([], speech: .finished))
    }

    func testRetryPreservesReadOnlyVerificationOperationAndSeparateJobIdentity() async {
        let worker = UIFinalizationWorker()
        let queue = AudioFinalizationCoordinator(worker: worker)
        let model = RecordingSessionViewModel(coordinator: ActiveUICoordinator(), finalization: queue)
        let location = location()
        for operation in [AudioFinalizationOperation.resume, .verifyExistingCanonical] {
            let request = AudioFinalizationRequest(location: location, operation: operation)
            _ = await queue.finalize(request)
            let failed = await queue.currentSnapshot(at: location, operation: operation)!
            await model.retryFinalization(failed)
            _ = await queue.waitForResult(at: location, operation: operation)
        }
        let requests = await worker.requests
        XCTAssertEqual(requests.map(\.operation), [.resume, .resume, .verifyExistingCanonical, .verifyExistingCanonical])
        XCTAssertTrue(requests.allSatisfy { $0.location == location })
        let snapshots = await queue.allSnapshots()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertNotEqual(snapshots[0].generation, snapshots[1].generation,
                          "same session can have two rows; UI identity is the job generation")
    }

    private func location() -> SessionLocation {
        let id = SessionID()
        return .init(rootID: .init(), sessionID: id,
            folderName: .init(sessionID: id, createdAt: .init(Date(timeIntervalSince1970: 0)), timeZone: .init(secondsFromGMT: 0)!))
    }

    private func segment(_ index: Int) throws -> TranscriptSegment {
        try .init(id: .init(), sequence: .init(Int64(index)), startMs: .init(Int64(index * 1_000)),
            endMs: .init(Int64(index * 1_000 + 800)), originalText: "문장 \(index) API", text: "문장 \(index) API", language: .init("ko"))
    }

    private func recording(_ id: SessionID, speech: LiveSTTSnapshot, elapsed: UInt64 = 0,
                           phase: RecordingSessionPhase = .recording) -> RecordingSessionSnapshot {
        .init(phase: phase, permissionStatus: .authorized, sessionID: id, title: "합성 강의",
            languageMode: .korean, persistedStatus: nil, recordingStartedAt: .init(Date(timeIntervalSince1970: 0)),
            elapsedMilliseconds: elapsed, microphoneDisplayName: "Synthetic", normalizedInputLevel: Float((elapsed / 1_000) % 100) / 100,
            noInputWarning: true, failure: nil, persistenceWarningCode: nil, catalogWarningCode: nil,
            canStart: false, canStop: phase == .recording, canReset: false, speech: speech)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<5_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("UI did not observe the emitted snapshot")
    }
}

private func finalizationFailure(_ location: SessionLocation) -> AudioFinalizationResult {
    .init(location: location, phase: .failed, failure: .storageAccess, warnings: [], media: nil,
        source: nil, final: nil, completedSteps: [], retainedPaths: [], presentPaths: [], recoveryWasRemoved: false)
}

private actor UIFinalizationWorker: AudioFinalizationWorking {
    private(set) var requests: [AudioFinalizationRequest] = []
    func finalize(_ request: AudioFinalizationRequest, control: AudioFinalizationControl,
                  progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        requests.append(request)
        return finalizationFailure(request.location)
    }
    func removeRecovery(_ evidence: FinalizationCompletionEvidence, control: AudioFinalizationControl,
                        progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        finalizationFailure(evidence.location)
    }
}

private actor ActiveUICoordinator: RecordingSessionCoordinating {
    private var value = RecordingSessionSnapshot.idle()
    private var continuations: [UUID: AsyncStream<RecordingSessionSnapshot>.Continuation] = [:]
    private(set) var stops = 0
    func snapshots() -> AsyncStream<RecordingSessionSnapshot> {
        let id = UUID(); let pair = AsyncStream<RecordingSessionSnapshot>.makeStream()
        continuations[id] = pair.continuation; pair.continuation.yield(value)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return pair.stream
    }
    private func remove(_ id: UUID) { continuations.removeValue(forKey: id) }
    func emit(_ value: RecordingSessionSnapshot) { self.value = value; continuations.values.forEach { $0.yield(value) } }
    func currentSnapshot() -> RecordingSessionSnapshot { value }
    func refreshPermissionStatus() {}
    func start(_ configuration: RecordingStartConfiguration) -> RecordingSessionSnapshot { value }
    func stop() -> RecordingSessionResult { stops += 1; return .error(.busy) }
    func interrupt(_ reason: RecordingInterruptionReason) -> RecordingSessionResult { .interrupted(.interrupted(reason)) }
    func recordSystemWakeIfApplicable() {}
    func reset() { emit(.idle()) }
}
