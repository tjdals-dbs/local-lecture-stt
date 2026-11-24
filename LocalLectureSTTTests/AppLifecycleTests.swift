import XCTest
import AppKit
@testable import LocalLectureSTT

final class AppLifecycleTests: XCTestCase {
    @MainActor
    func testReviewCachedIdleDecisionMustNotAllowQuitAfterRecordingStarts() async {
        let readiness = SynchronousTerminationReadiness()
        let recording = LifecycleRecordingStub()
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: LifecycleFinalizationStub(),
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy(),
            terminationReadiness: readiness)
        _ = await lifecycle.terminationDecision()
        XCTAssertEqual(readiness.currentDecision(), .terminateNow)
        // Simulates the interval after a producer changes state but before its
        // asynchronous stream observation reaches the main-actor mirror.
        await recording.setSnapshot(.lifecycle(.recording))
        let delegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
            presenter: LifecycleQuitPresenterSpy(), terminationReply: LifecycleTerminationReplySpy(),
            windowClassifier: LifecycleWindowClassifierSpy(), terminationReadiness: readiness)
        delegate.configure(recording: recording, finalization: LifecycleFinalizationStub(), recovery: LifecycleRecoveryStub())
        let answer = delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertNotEqual(answer, .terminateNow, "A cached idle result must not bypass a new live recording")
    }

    func testReviewNewRecordingDuringFinalQuitReadsMustDenyOldQuit() async {
        let gate = LifecycleGate()
        let recording = LifecycleRecordingStub(snapshot: .lifecycle(.recording))
        let finalization = ReviewFinalizationReadGate(gate: gate)
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: finalization,
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        let quit = Task { await lifecycle.resolveTermination(.essentialSaveAndQuit) }
        await gate.waitEntered()
        // The quit already read the interrupted snapshot. A newer recording
        // begins while its next owner read is suspended.
        await recording.setSnapshot(.lifecycle(.recording))
        await gate.release()
        let allowed = await quit.value
        XCTAssertFalse(allowed, "The old quit must not authorize termination of newer capture")
    }

    func testProductionActivityOptionsProtectSystemSleepButAllowDisplaySleep() {
        let options = ProcessInfoLifecycleActivityAdapter.activityOptions
        XCTAssertTrue(options.contains(.idleSystemSleepDisabled))
        XCTAssertTrue(options.contains(.automaticTerminationDisabled))
        XCTAssertTrue(options.contains(.suddenTerminationDisabled))
        XCTAssertFalse(options.contains(.idleDisplaySleepDisabled))
    }

    func testLastWindowReservationRequestsAutomaticTerminationExactlyOnceAndReopenCancelsIt() async {
        let termination = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination)
        await lifecycle.userWindowCountChanged(0)
        await lifecycle.userWindowCountChanged(0)
        let requestCount = await termination.count()
        XCTAssertEqual(requestCount, 1)
        await lifecycle.applicationReopened()
        let snapshot = await lifecycle.currentSnapshot()
        XCTAssertFalse(snapshot.autoExitReserved)
    }

    func testNoWorkTerminatesNowAndContinueUsingCancelsWithoutMutation() async {
        let recording = LifecycleRecordingStub()
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        let decision = await lifecycle.terminationDecision()
        let allowed = await lifecycle.resolveTermination(.continueUsing)
        let interrupts = await recording.interruptCount()
        XCTAssertEqual(decision, .terminateNow)
        XCTAssertFalse(allowed)
        XCTAssertEqual(interrupts, 0)
    }

    @MainActor
    func testDelegateReturnsTerminateNowSynchronouslyWithoutReplyOrSideEffects() {
        let readiness = SynchronousTerminationReadiness(initial: .terminateNow)
        let reply = LifecycleTerminationReplySpy()
        let delegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
                                            presenter: LifecycleQuitPresenterSpy(), terminationReply: reply,
                                            windowClassifier: LifecycleWindowClassifierSpy(), terminationReadiness: readiness)
        let replyValue = delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(replyValue, .terminateNow)
        XCTAssertEqual(reply.count, 0)
    }

    @MainActor
    func testDelegateDistinguishesSynchronousCancelAndLaterReplyPaths() async {
        let cancelReadiness = SynchronousTerminationReadiness(initial: .terminateCancel)
        let cancelReply = LifecycleTerminationReplySpy()
        let cancelDelegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
                                                  presenter: LifecycleQuitPresenterSpy(), terminationReply: cancelReply,
                                                  windowClassifier: LifecycleWindowClassifierSpy(), terminationReadiness: cancelReadiness)
        XCTAssertEqual(cancelDelegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(cancelReply.count, 0)

        let gate = LifecycleGate()
        let laterReply = LifecycleTerminationReplySpy()
        let laterDelegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
                                                 presenter: LifecycleQuitPresenterSpy(), terminationReply: laterReply,
                                                 windowClassifier: LifecycleWindowClassifierSpy(),
                                                 terminationReadiness: SynchronousTerminationReadiness(initial: .terminateLater))
        laterDelegate.configure(recording: LifecycleRecordingStub(currentGate: gate),
                               finalization: LifecycleFinalizationStub(), recovery: LifecycleRecoveryStub())
        XCTAssertEqual(laterDelegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await gate.waitEntered()
        laterDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(laterReply.values, [false])
        await gate.release()
        XCTAssertEqual(laterDelegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await laterDelegate.waitForPendingTermination()
        XCTAssertEqual(laterReply.values, [false], "the owned terminate-later request receives exactly one reply")
    }

    func testRepeatedEssentialQuitSharesOneInterruptedSaveAndOwnedCleanup() async {
        let gate = LifecycleGate()
        let recording = LifecycleRecordingStub(snapshot: .lifecycle(.recording), interruptGate: gate)
        let finalization = LifecycleFinalizationStub()
        let recovery = LifecycleRecoveryStub()
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: finalization, recovery: recovery,
                                                activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        let first = Task { await lifecycle.resolveTermination(AppTerminationChoice.essentialSaveAndQuit) }
        await gate.waitEntered()
        let second = Task { await lifecycle.resolveTermination(AppTerminationChoice.essentialSaveAndQuit) }
        await gate.release()
        let firstAllowed = await first.value
        let secondAllowed = await second.value
        let interrupts = await recording.interruptCount()
        let finalizationCalls = await finalization.quiesceCount()
        let recoveryCalls = await recovery.cancelCount()
        XCTAssertTrue(firstAllowed)
        XCTAssertTrue(secondAllowed)
        XCTAssertEqual(interrupts, 1)
        XCTAssertEqual(finalizationCalls, 1)
        XCTAssertEqual(recoveryCalls, 1)
    }

    func testEssentialQuitFailureIsDeniedAndRetainsFirstTypedFailure() async {
        let recording = LifecycleRecordingStub(snapshot: .lifecycle(.recording),
                                                interruptResult: RecordingSessionResult.error(.recorder(.writerFinishFailed)))
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        let allowed = await lifecycle.resolveTermination(AppTerminationChoice.essentialSaveAndQuit)
        let interrupts = await recording.interruptCount()
        XCTAssertFalse(allowed)
        XCTAssertEqual(interrupts, 1)
    }

    func testWakeWaitsForTheOwnedSleepCleanupBeforeRefreshingRecovery() async {
        let gate = LifecycleGate()
        let recovery = LifecycleRecoveryStub(cancelGate: gate)
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                                                recovery: recovery, activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        await lifecycle.handlePowerEvent(.willSleep)
        await gate.waitEntered()
        let wake = Task { await lifecycle.handlePowerEvent(.didWake) }
        let beforeRelease = await recovery.refreshCount()
        XCTAssertEqual(beforeRelease, 0)
        await gate.release()
        await wake.value
        let afterRelease = await recovery.refreshCount()
        XCTAssertEqual(afterRelease, 1)
    }

    func testNormalStopSecuringRacingSleepDoesNotRewriteItAsInterrupted() async {
        let recording = LifecycleRecordingStub(snapshot: .lifecycle(.securing))
        let finalization = LifecycleFinalizationStub()
        let recovery = LifecycleRecoveryStub()
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: finalization, recovery: recovery,
                                                activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        await lifecycle.handlePowerEvent(.willSleep)
        // The sleep callback schedules work.  A wake joins its owned cleanup
        // without allowing a second termination path to edit normal Stop.
        await lifecycle.handlePowerEvent(.didWake)
        let interrupts = await recording.interruptCount()
        let quiesces = await finalization.quiesceCount()
        XCTAssertEqual(interrupts, 0)
        XCTAssertEqual(quiesces, 1)
    }

    func testDuplicateAndStaleWakeAcrossTwoGenerationsRefreshesOnlyCurrentCycle() async {
        let firstGate = LifecycleGate()
        let recovery = LifecycleRecoveryStub(cancelGates: [firstGate])
        let wakeJoined = expectation(description: "wake joined cleanup")
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                                                recovery: recovery, activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy(),
                                                onWakeJoining: { if $0 == 1 { wakeJoined.fulfill() } })
        await lifecycle.handlePowerEvent(.willSleep)
        await firstGate.waitEntered()
        let staleWake = Task { await lifecycle.handlePowerEvent(.didWake) }
        await fulfillment(of: [wakeJoined], timeout: 3)
        await lifecycle.handlePowerEvent(.willSleep)
        await firstGate.release()
        await staleWake.value
        let staleRefreshes = await recovery.refreshCount()
        XCTAssertEqual(staleRefreshes, 0)
        await lifecycle.handlePowerEvent(.didWake)
        let currentRefreshes = await recovery.refreshCount()
        XCTAssertEqual(currentRefreshes, 1)
    }

    func testClosingLastWindowWhileRecordingDoesNotStopOrPresentQuit() async {
        let recording = LifecycleRecordingStub(snapshot: .lifecycle(.recording))
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        _ = await lifecycle.terminationDecision()
        await lifecycle.userWindowCountChanged(0)
        let interrupts = await recording.interruptCount()
        let snapshot = await lifecycle.currentSnapshot()
        XCTAssertEqual(interrupts, 0)
        XCTAssertTrue(snapshot.hasRelevantWork)
        XCTAssertTrue(snapshot.autoExitReserved)
    }

    @MainActor
    func testWindowClassifierExcludesHiddenUtilitiesAndPanels() {
        let classifier = AppKitUserWindowClassifier()
        let visibleMain = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        visibleMain.orderFront(nil)
        let hidden = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.orderFront(nil)
        XCTAssertTrue(classifier.isUserWindow(visibleMain))
        XCTAssertFalse(classifier.isUserWindow(hidden))
        XCTAssertFalse(classifier.isUserWindow(panel))
        visibleMain.orderOut(nil)
        panel.orderOut(nil)
    }

    func testFreshLifecycleOwnerHasNoPersistedAutoExitReservation() async {
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        let snapshot = await lifecycle.currentSnapshot()
        XCTAssertFalse(snapshot.autoExitReserved)
        XCTAssertEqual(snapshot.visibleUserWindowCount, 0)
    }

    func testReopenBeforeWindowVisibilityDoesNotCreateAnotherAutoExitReservation() async {
        let termination = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination)
        await lifecycle.applicationReopened()
        await lifecycle.userWindowCountChanged(0)
        let snapshot = await lifecycle.currentSnapshot()
        let count = await termination.count()
        XCTAssertFalse(snapshot.autoExitReserved)
        XCTAssertEqual(count, 0)
    }

    func testReopenWhileAutomaticGatewayIsWaitingRejectsLateTermination() async {
        let termination = DeferredTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination)
        let close = Task { await lifecycle.userWindowCountChanged(0) }
        await termination.waitUntilEntered()
        await lifecycle.applicationReopened()
        await termination.release()
        await close.value
        let count = await termination.count()
        XCTAssertEqual(count, 0)
    }

    func testLastWindowWaitsForFiniteFinalizationThenRequestsAutomaticTerminationOnce() async throws {
        let sessionID = SessionID()
        let location = SessionLocation(
            rootID: StorageRootID(), sessionID: sessionID,
            folderName: SessionFolderName(sessionID: sessionID, createdAt: AbsoluteTime(Date(timeIntervalSince1970: 0)), timeZone: .gmt)
        )
        let finalization = LifecycleFinalizationStub(values: [
            .init(location: location, generation: 1, operation: .resume, phase: .exporting, result: nil)
        ])
        let termination = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: finalization,
                                                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination)
        let before = await lifecycle.terminationDecision()
        await lifecycle.userWindowCountChanged(0)
        let beforeCount = await termination.count()
        XCTAssertEqual(before, .terminateLater)
        XCTAssertEqual(beforeCount, 0)

        await finalization.setValues([])
        _ = await lifecycle.terminationDecision()
        let afterCount = await termination.count()
        XCTAssertEqual(afterCount, 1)
    }

    func testStaleWorkRefreshCannotReleaseANewerActivityGeneration() async {
        let gate = LifecycleGate()
        let recording = LifecycleRecordingStub(snapshot: .idle(), currentGate: gate)
        let activity = LifecycleActivitySpy()
        let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: LifecycleFinalizationStub(),
                                                recovery: LifecycleRecoveryStub(), activity: activity, termination: LifecycleTerminationSpy())
        let staleDecision = Task { await lifecycle.terminationDecision() }
        await gate.waitEntered()
        await recording.setSnapshot(.lifecycle(.recording))
        _ = await lifecycle.terminationDecision()
        await gate.release()
        _ = await staleDecision.value
        let calls = await activity.calls()
        XCTAssertEqual(calls, [true], "a stale inactive refresh must not release the newer active assertion")
    }

}

actor ReviewFinalizationReadGate: LifecycleFinalizationCoordinating {
    let gate: LifecycleGate
    var reads = 0
    init(gate: LifecycleGate) { self.gate = gate }
    func snapshots() -> AsyncStream<[AudioFinalizationSnapshot]> { AsyncStream { $0.finish() } }
    func allSnapshots() async -> [AudioFinalizationSnapshot] {
        reads += 1
        if reads == 2 { await gate.enterAndWait() }
        return []
    }
    func quiesceOwnedWork() {}
}

actor LifecycleRecordingStub: RecordingSessionCoordinating {
    private var interrupts = 0
    private var snapshotValue: RecordingSessionSnapshot
    private let currentGate: LifecycleGate?
    private let interruptGate: LifecycleGate?
    private let interruptResult: RecordingSessionResult?
    init(snapshot: RecordingSessionSnapshot = .idle(), currentGate: LifecycleGate? = nil,
         interruptGate: LifecycleGate? = nil, interruptResult: RecordingSessionResult? = nil) {
        self.snapshotValue = snapshot
        self.currentGate = currentGate
        self.interruptGate = interruptGate
        self.interruptResult = interruptResult
    }
    func snapshots() -> AsyncStream<RecordingSessionSnapshot> { AsyncStream { $0.yield(.idle()); $0.finish() } }
    func currentSnapshot() async -> RecordingSessionSnapshot { let captured = snapshotValue; await currentGate?.enterAndWait(); return captured }
    func refreshPermissionStatus() {}
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot { .idle() }
    func stop() -> RecordingSessionResult { .error(.busy) }
    func interrupt(_ reason: RecordingInterruptionReason) async -> RecordingSessionResult {
        if snapshotValue.phase == .securing { return .error(.busy) } // this fake models a joined normal Stop
        interrupts += 1
        await interruptGate?.enterAndWait()
        if let interruptResult { return interruptResult }
        snapshotValue = .lifecycle(.interrupted)
        return .interrupted(.interrupted(reason))
    }
    func essentialSaveEvidence() async -> EssentialTerminationSaveResult? {
        .init(durableRecoveryState: true, cleanupSettled: true, firstFailure: nil, warnings: [], requiresUserAttention: false)
    }
    func recordSystemWakeIfApplicable() {}
    func reset() {}
    func interruptCount() -> Int { interrupts }
    func setSnapshot(_ value: RecordingSessionSnapshot) { snapshotValue = value }
}

actor LifecycleFinalizationStub: LifecycleFinalizationCoordinating {
    private var values: [AudioFinalizationSnapshot]
    private var quiesces = 0
    init(values: [AudioFinalizationSnapshot] = []) { self.values = values }
    func snapshots() -> AsyncStream<[AudioFinalizationSnapshot]> { let values = values; return AsyncStream { $0.yield(values); $0.finish() } }
    func allSnapshots() -> [AudioFinalizationSnapshot] { values }
    func quiesceOwnedWork() { quiesces += 1 }
    func setValues(_ values: [AudioFinalizationSnapshot]) { self.values = values }
    func quiesceCount() -> Int { quiesces }
}

actor LifecycleRecoveryStub: LifecycleRecoveryCoordinating {
    private var cancelGates: [LifecycleGate]
    private var refreshes = 0
    private var cancellations = 0
    init(cancelGate: LifecycleGate? = nil, cancelGates: [LifecycleGate] = []) {
        self.cancelGates = cancelGate.map { [$0] } ?? cancelGates
    }
    func snapshots() -> AsyncStream<SessionRecoverySnapshot> { AsyncStream { $0.yield(.init(generation: 0, phase: .idle, report: nil)); $0.finish() } }
    func currentSnapshot() -> SessionRecoverySnapshot { .init(generation: 0, phase: .idle, report: nil) }
    func refresh() { refreshes += 1 }
    func cancelOwnedRecovery() async {
        cancellations += 1
        guard !cancelGates.isEmpty else { return }
        let gate = cancelGates.removeFirst()
        await gate.enterAndWait()
    }
    func refreshCount() -> Int { refreshes }
    func cancelCount() -> Int { cancellations }
}

actor LifecycleActivitySpy: LifecycleActivityControlling {
    private var values: [Bool] = []
    func setRelevantWorkActive(_ active: Bool) { values.append(active) }
    func calls() -> [Bool] { values }
}

@MainActor
final class LifecycleTerminationReplySpy: AppTerminationReplying {
    private(set) var values: [Bool] = []
    var count: Int { values.count }
    var onReply: ((Bool) -> Void)?
    func replyToApplicationShouldTerminate(_ allowed: Bool) { values.append(allowed); onReply?(allowed) }
}
@MainActor
final class LifecycleQuitPresenterSpy: RecordingQuitPresenting {
    var gate: LifecycleGate?
    var choice: AppTerminationChoice = .continueUsing
    var calls = 0
    func chooseRecordingQuitAction() async -> AppTerminationChoice { calls += 1; await gate?.enterAndWait(); return choice }
}
@MainActor
final class LifecycleWindowClassifierSpy: UserWindowClassifying {
    var count = 0
    func visibleUserWindowCount() -> Int { count }
}

extension RecordingSessionSnapshot {
    static func lifecycle(_ phase: RecordingSessionPhase) -> RecordingSessionSnapshot {
        RecordingSessionSnapshot(phase: phase, permissionStatus: .authorized, sessionID: nil, title: nil,
                                 languageMode: .korean, persistedStatus: nil, recordingStartedAt: nil,
                                 elapsedMilliseconds: 0, microphoneDisplayName: nil, normalizedInputLevel: 0,
                                 noInputWarning: false, failure: nil, persistenceWarningCode: nil,
                                 catalogWarningCode: nil, canStart: phase == .idle, canStop: phase == .recording,
                                 canReset: phase == .error || phase == .interrupted)
    }
}
actor LifecycleTerminationSpy: LifecycleTerminationRequesting {
    private var value = 0
    func requestAutomaticTermination(isStillValid: @escaping @Sendable () async -> Bool) async -> Bool {
        if await isStillValid() { value += 1; return true }
        return false
    }
    func count() -> Int { value }
}
actor DeferredTerminationSpy: LifecycleTerminationRequesting {
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var accepted = 0
    func requestAutomaticTermination(isStillValid: @escaping @Sendable () async -> Bool) async -> Bool {
        didEnter = true
        if let entered { self.entered = nil; entered.resume() }
        await withCheckedContinuation { released = $0 }
        if await isStillValid() { accepted += 1; return true }
        return false
    }
    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { let continuation = released; released = nil; continuation?.resume() }
    func count() -> Int { accepted }
}
actor LifecycleGate {
    private var didEnter = false
    private var entered: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        guard !didEnter else { return }
        didEnter = true
        if let entered { self.entered = nil; entered.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { let continuation = releaseContinuation; releaseContinuation = nil; continuation?.resume() }
}

extension AppLifecycleTests {
    func testProductionActivityLeasesOverlapAndRejectCapturedOldIdleGeneration() async {
        let probe = ActivityTokenProbe()
        let adapter = ProcessInfoLifecycleActivityAdapter(begin: { probe.begin() }, end: { probe.end($0) })
        let authority = LifecycleWorkAuthority(activity: { adapter.update($0) })
        let oldIdle = authority.state()
        let recording = authority.admit()
        let handoff = authority.admit(invalidating: false)
        XCTAssertEqual(probe.counts(), [1, 0])
        authority.release(recording)
        let finalization = authority.admit(invalidating: false)
        authority.release(handoff)
        XCTAssertEqual(probe.counts(), [1, 0])
        XCTAssertFalse(authority.authorize(oldIdle.generation, action: { XCTFail("stale inactive result") }))
        authority.release(finalization)
        authority.release(finalization)
        XCTAssertEqual(probe.counts(), [1, 1])
        let oldCompleted = authority.state()
        let newer = authority.admit()
        authority.release(recording)
        XCTAssertFalse(authority.authorize(oldCompleted.generation, action: { XCTFail("newer work was admitted") }))
        XCTAssertEqual(probe.counts(), [2, 1])
        authority.release(newer)
        XCTAssertEqual(probe.counts(), [2, 2])
    }

    @MainActor
    func testAutomaticGatewayRechecksActualWindowsAndAdmissionAfterValidationAwait() async {
        let authority = LifecycleWorkAuthority()
        let gateway = MacAutomaticTerminationGateway()
        let windows = LifecycleWindowClassifierSpy()
        var terminations = 0
        gateway.authority = authority
        gateway.isWindowReservationCurrent = { windows.count == 0 }
        gateway.terminate = { terminations += 1 }
        let gate = LifecycleGate()
        let request = Task { await gateway.requestAutomaticTermination { await gate.enterAndWait(); return true } }
        await gate.waitEntered()
        windows.count = 1 // Settings or Main becomes visible before main-actor dispatch
        await gate.release(); await request.value
        XCTAssertEqual(terminations, 0)
        windows.count = 0
        let gate2 = LifecycleGate()
        let request2 = Task { await gateway.requestAutomaticTermination { await gate2.enterAndWait(); return true } }
        await gate2.waitEntered()
        let lease = authority.admit()
        await gate2.release(); await request2.value
        XCTAssertEqual(terminations, 0)
        authority.release(lease)
        await gateway.requestAutomaticTermination { true }
        XCTAssertEqual(terminations, 1)
    }

    @MainActor
    func testMainSettingsCloseOrderAndDockReservationUseCurrentWindows() async {
        let authority = LifecycleWorkAuthority()
        let gateway = MacAutomaticTerminationGateway()
        let windows = LifecycleWindowClassifierSpy()
        var terminations = 0
        gateway.terminate = { terminations += 1 }
        let delegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: gateway,
            presenter: LifecycleQuitPresenterSpy(), terminationReply: LifecycleTerminationReplySpy(), windowClassifier: windows)
        delegate.configure(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(), recovery: LifecycleRecoveryStub(), authority: authority)
        windows.count = 2; delegate.userWindowsChanged()
        windows.count = 1; delegate.userWindowsChanged() // Main closes; Settings remains
        XCTAssertFalse(gateway.isWindowReservationCurrent())
        XCTAssertEqual(terminations, 0)
        windows.count = 0; delegate.userWindowsChanged()
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        delegate.userWindowsChanged() // no visible window yet must not reserve again
        XCTAssertFalse(gateway.isWindowReservationCurrent())
        XCTAssertEqual(terminations, 0)
        windows.count = 1; delegate.userWindowsChanged()
        windows.count = 0; delegate.userWindowsChanged()
        XCTAssertTrue(gateway.isWindowReservationCurrent())
        XCTAssertEqual(terminations, 0, "synchronous window bookkeeping does not itself call the gateway")
    }
}

extension AppLifecycleTests {
    @MainActor
    func testAppCompositionAndPreviewsAreInertAndLifecycleContractsAreFrameworkFree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots = StorageRootManager(applicationSupportDirectory: directory)
        let catalog = LocalLectureSTTApp.makeCatalog(roots: roots, directory: { directory })
        let startup = CatalogStartupCoordinator(catalog: catalog)
        let preview = RecordingSessionViewModel.preview
        _ = RecordingSessionView(viewModel: preview)
        let probe = ActivityTokenProbe()
        let activity = ProcessInfoLifecycleActivityAdapter(begin: { probe.begin() }, end: { probe.end($0) })
        let presenter = LifecycleQuitPresenterSpy(), replies = LifecycleTerminationReplySpy()
        let delegate = MacLifecycleDelegate(activity: activity, automaticTermination: LifecycleTerminationSpy(),
            presenter: presenter, terminationReply: replies, windowClassifier: LifecycleWindowClassifierSpy())
        delegate.configure(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(), recovery: LifecycleRecoveryStub())
        XCTAssertEqual(delegate.installedObserverCount, 0)
        XCTAssertEqual(probe.counts(), [0, 0]); XCTAssertEqual(presenter.calls, 0); XCTAssertEqual(replies.values, [])
        XCTAssertEqual(startup.state, .idle); XCTAssertEqual(preview.displayState, .configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contracts = try String(contentsOf: base.appendingPathComponent("LocalLectureSTT/Application/AppLifecycle.swift"), encoding: .utf8)
        for declaration in ["import AppKit", "import SwiftUI", "import IOKit", ": URL", ": NSError", ": NSWindow", ": Notification", "ProcessInfo.ActivityOptions"] {
            XCTAssertFalse(contracts.contains(declaration))
        }
        let app = try String(contentsOf: base.appendingPathComponent("LocalLectureSTT/App/LocalLectureSTTApp.swift"), encoding: .utf8)
        for binding in ["@NSApplicationDelegateAdaptor", "LifecycleWorkAuthority(activity:", "Self.makeCatalog(roots:", "lifecycleDelegate.configure(", "authority: authority"] {
            XCTAssertTrue(app.contains(binding))
        }
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(AppLifecycleSnapshot.initial)
        requireSendable(AppLifecyclePowerEvent.willSleep)
        requireSendable(EssentialTerminationSaveResult(durableRecoveryState: true, cleanupSettled: true,
            firstFailure: nil, warnings: [], requiresUserAttention: false))
    }
}

extension AppLifecycleTests {
    func testAttentionBlocksAutomaticExitAfterFiniteWorkSettles() async throws {
        let id = SessionID()
        let location = SessionLocation(rootID: StorageRootID(), sessionID: id,
            folderName: SessionFolderName(sessionID: id, createdAt: AbsoluteTime(Date()), timeZone: .gmt))
        let result = AudioFinalizationResult(location: location, phase: .failed, failure: .persistence, warnings: [], media: nil,
            source: nil, final: nil, completedSteps: [], retainedPaths: [], presentPaths: [], recoveryWasRemoved: false)
        let finalization = LifecycleFinalizationStub(values: [.init(location: location, generation: 1, operation: .resume, phase: .failed, result: result)])
        let gateway = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: finalization,
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: gateway)
        _ = await lifecycle.terminationDecision()
        await lifecycle.userWindowCountChanged(0)
        let snapshot = await lifecycle.currentSnapshot(), count = await gateway.count()
        XCTAssertTrue(snapshot.requiresUserAttention); XCTAssertEqual(count, 0)
    }

    @MainActor
    func testProductionWindowObserversSeeMainAndSettingsVisibilityChanges() async {
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        defer { main.orderOut(nil); settings.orderOut(nil) }
        let classifier = WindowSubsetClassifier(windows: [main, settings])
        let changed = expectation(description: "Settings remains after Main closes")
        var armed = false, fulfilled = false
        let delegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
            presenter: LifecycleQuitPresenterSpy(), terminationReply: LifecycleTerminationReplySpy(), windowClassifier: classifier,
            onWindowObservation: { count in
                if armed && count == 1 && !fulfilled { fulfilled = true; changed.fulfill() }
            })
        delegate.configure(recording: LifecycleRecordingStub(snapshot: .lifecycle(.recording)),
            finalization: LifecycleFinalizationStub(), recovery: LifecycleRecoveryStub())
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertGreaterThan(delegate.installedObserverCount, 3)
        main.orderFront(nil); settings.orderFront(nil)
        XCTAssertEqual(classifier.visibleUserWindowCount(), 2)
        main.orderOut(nil); armed = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: main)
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(classifier.visibleUserWindowCount(), 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(delegate.installedObserverCount, 0)
    }
}

@MainActor
private final class WindowSubsetClassifier: UserWindowClassifying {
    let windows: [NSWindow]
    let production = AppKitUserWindowClassifier()
    init(windows: [NSWindow]) { self.windows = windows }
    func visibleUserWindowCount() -> Int { windows.filter(production.isUserWindow).count }
}

extension AppLifecycleTests {
    func testNonRetryableRecoveryDamageBlocksExitButCatalogWarningDoesNot() async {
        for damaged in [true, false] {
            let gateway = LifecycleTerminationSpy()
            let recovery = LifecycleRecoveryReportStub(damaged: damaged)
            let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                recovery: recovery, activity: LifecycleActivitySpy(), termination: gateway)
            _ = await lifecycle.terminationDecision()
            await lifecycle.userWindowCountChanged(0)
            let state = await lifecycle.currentSnapshot(), exits = await gateway.count()
            XCTAssertEqual(state.requiresUserAttention, damaged)
            XCTAssertEqual(exits, damaged ? 0 : 1)
        }
    }
}
private actor LifecycleRecoveryReportStub: LifecycleRecoveryCoordinating {
    let damaged: Bool
    init(damaged: Bool) { self.damaged = damaged }
    func snapshots() -> AsyncStream<SessionRecoverySnapshot> { AsyncStream { $0.finish() } }
    func currentSnapshot() -> SessionRecoverySnapshot {
        .init(generation: 1, phase: .ready, report: .init(items: damaged ? [
            .init(rootID: StorageRootID(), folderName: nil, sessionID: nil, code: .metadataCorrupt,
                  preserved: true, retryable: false, warning: nil)
        ] : [], catalogWarning: damaged ? nil : .stepFailed, discoveryWarning: damaged ? nil : "catalog.stepFailed"))
    }
    func refresh() {}
    func cancelOwnedRecovery() {}
}

extension AppLifecycleTests {
    @MainActor
    func testAuditDuplicateEmptyWindowObservationCannotLoseAutomaticExit() async {
        let authority = LifecycleWorkAuthority()
        let gate = LifecycleGate()
        let base = MacAutomaticTerminationGateway()
        var windowGeneration: UInt64 = 1
        var exits = 0
        base.authority = authority
        base.windowReservationGeneration = { windowGeneration }
        base.isWindowReservationCurrent = { true } // still no visible windows, same reservation
        base.terminate = { exits += 1 }
        let gateway = AuditDelayedAutomaticGateway(base: base, gate: gate)
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: gateway, authority: authority)
        let close = Task { await lifecycle.userWindowCountChanged(0) }
        await gate.waitEntered()
        // Production userWindowsChanged increments this on every observation,
        // including a second notification with the same zero-window count.
        windowGeneration += 1
        await lifecycle.userWindowCountChanged(0)
        await gate.release()
        await close.value
        _ = await lifecycle.terminationDecision()
        let snapshot = await lifecycle.currentSnapshot()
        XCTAssertTrue(snapshot.autoExitReserved)
        XCTAssertFalse(snapshot.hasRelevantWork)
        XCTAssertFalse(snapshot.requiresUserAttention)
        XCTAssertEqual(exits, 1, "A rejected dispatch must permit a new valid request for the still-current reservation")
    }
    @MainActor
    func testRejectedAutomaticDispatchReevaluatesAfterNewFiniteWork() async {
        let authority = LifecycleWorkAuthority()
        let gate = LifecycleGate()
        let base = MacAutomaticTerminationGateway()
        var windowGeneration: UInt64 = 1
        var exits = 0
        base.authority = authority
        base.windowReservationGeneration = { windowGeneration }
        base.isWindowReservationCurrent = { true } // still no visible windows, same reservation
        base.terminate = { exits += 1 }
        let gateway = AuditDelayedAutomaticGateway(base: base, gate: gate)
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: gateway, authority: authority)
        let close = Task { await lifecycle.userWindowCountChanged(0) }
        await gate.waitEntered()
        // New finite work completes before the old dispatch is authorized.
        let work = authority.admit()
        authority.release(work)
        _ = await lifecycle.terminationDecision()
        await gate.release()
        await close.value
        _ = await lifecycle.terminationDecision()
        let snapshot = await lifecycle.currentSnapshot()
        XCTAssertTrue(snapshot.autoExitReserved)
        XCTAssertFalse(snapshot.hasRelevantWork)
        XCTAssertFalse(snapshot.requiresUserAttention)
        XCTAssertEqual(exits, 1, "A rejected dispatch must permit a new valid request for the still-current reservation")
    }
}
@MainActor
private final class AuditDelayedAutomaticGateway: LifecycleTerminationRequesting {
    let base: MacAutomaticTerminationGateway
    let gate: LifecycleGate
    init(base: MacAutomaticTerminationGateway, gate: LifecycleGate) { self.base=base; self.gate=gate }
    func requestAutomaticTermination(isStillValid: @escaping @Sendable () async -> Bool) async -> Bool {
        return await base.requestAutomaticTermination { [gate] in
            await gate.enterAndWait()
            return await isStillValid()
        }
    }
}

extension AppLifecycleTests {
    @MainActor
    func testT19SpeechOnlyQuitJoinsCleanupAndRepliesExactlyOnce() async {
        // A terminal inference phase is not proof of completed journal/native
        // cleanup. Even cleanupComplete can precede the metadata handoff.
        for (phase, cleaned) in [(LiveSTTPhase.finishing, false), (.finished, false),
                                  (.cancelled, false), (.failed, false), (.finished, true)] {
            let authority = LifecycleWorkAuthority()
            let gate = LifecycleGate()
            let entered = expectation(description: "speech settlement entered: \(phase)/\(cleaned)")
            let recording = T19LifecycleSpeechStub(phase: phase, cleaned: cleaned, authority: authority,
                gate: gate, onCleanup: { entered.fulfill() }, failure: phase == .failed ? .inferenceFailed : nil)
            let audio = LifecycleFinalizationStub(values: [recording.finishedAudio])
            let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: audio,
                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(),
                termination: LifecycleTerminationSpy(), authority: authority)
            let decision = await lifecycle.terminationDecision()
            XCTAssertEqual(decision, .terminateLater, "STT or its handoff still owns work")
            // Fail promptly against the old implementation instead of leaving
            // a test waiting forever for a cleanup path it never entered.
            guard decision == .terminateLater else {
                entered.fulfill()
                await fulfillment(of: [entered], timeout: 3)
                await recording.finishHandoff()
                continue
            }
            let reply = LifecycleTerminationReplySpy(), presenter = LifecycleQuitPresenterSpy()
            let delegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
                presenter: presenter, terminationReply: reply, windowClassifier: LifecycleWindowClassifierSpy())
            delegate.configure(recording: recording, finalization: audio, recovery: LifecycleRecoveryStub(), authority: authority)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertTrue(reply.values.isEmpty, "journal/native cleanup must finish before the AppKit reply")
            XCTAssertTrue(authority.state().active)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await gate.release()
            await delegate.waitForPendingTermination()
            let calls = await recording.cleanupCalls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(presenter.calls, 0, "capture has already stopped")
            XCTAssertEqual(reply.values, [true])
            XCTAssertFalse(authority.state().active)
        }
    }

    func testT19SpeechOnlyDecisionWithoutSharedAuthorityStillRequiresCleanup() async {
        let recording = T19LifecycleSpeechStub()
        let lifecycle = AppLifecycleCoordinator(recording: recording,
            finalization: LifecycleFinalizationStub(values: [recording.finishedAudio]), recovery: LifecycleRecoveryStub(),
            activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy())
        let decision = await lifecycle.terminationDecision()
        XCTAssertEqual(decision, .terminateLater)
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertTrue(allowed)
        let calls = await recording.cleanupCalls
        XCTAssertEqual(calls, 1)
    }

    func testT19ClosedWindowWaitsForSpeechAndMetadataHandoffThenExitsOnce() async {
        let authority = LifecycleWorkAuthority()
        let recording = T19LifecycleSpeechStub(authority: authority)
        let termination = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: recording,
            finalization: LifecycleFinalizationStub(values: [recording.finishedAudio]), recovery: LifecycleRecoveryStub(),
            activity: LifecycleActivitySpy(), termination: termination, authority: authority)
        await lifecycle.userWindowCountChanged(0)
        let before = await termination.count()
        XCTAssertEqual(before, 0)
        await recording.finishSpeech()
        let pendingHandoff = await lifecycle.terminationDecision()
        XCTAssertEqual(pendingHandoff, .terminateLater)
        let during = await termination.count()
        XCTAssertEqual(during, 0)
        await recording.finishHandoff()
        // Production T08 emits handoffResourcesSettled after releasing its
        // lease. Refresh the same policy after that owner transition.
        _ = await lifecycle.terminationDecision()
        _ = await lifecycle.terminationDecision()
        let after = await termination.count(), calls = await recording.cleanupCalls
        XCTAssertEqual(after, 1)
        XCTAssertEqual(calls, 0, "closing a window must let STT finish normally")
    }

    @MainActor
    func testT19SpeechProblemsBlockAutoExitButAllowSafeExplicitQuit() async {
        let problems: [(STTErrorCode?, String?)] = [(.inferenceFailed, nil), (.backlogFull, nil), (.cancelled, nil),
            (nil, "jsonlAppendFailed"), (nil, "jsonlFlushFailed"), (nil, "speechMetadataWriteFailed"),
            (.cancelled, "jsonlAppendFailed")]
        for (failure, warning) in problems {
            let authority = LifecycleWorkAuthority()
            let recording = T19LifecycleSpeechStub(phase: failure == nil ? .finished : .failed,
                authority: authority, failure: failure, storageWarning: warning)
            let audio = LifecycleFinalizationStub(values: [recording.finishedAudio])
            let automatic = LifecycleTerminationSpy()
            let lifecycle = AppLifecycleCoordinator(recording: recording, finalization: audio,
                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: automatic, authority: authority)
            await lifecycle.userWindowCountChanged(0)
            await recording.finishHandoff()
            let decision = await lifecycle.terminationDecision()
            let state = await lifecycle.currentSnapshot(), exits = await automatic.count()
            XCTAssertTrue(state.requiresUserAttention, "speech failure/storage warning must remain visible")
            XCTAssertEqual(exits, 0)
            XCTAssertEqual(decision, .terminateNow, "safe explicit quit must not be blocked by transcript availability")
            let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
            XCTAssertTrue(allowed)
            let afterCleanup = await automatic.count()
            XCTAssertEqual(afterCleanup, 0, "settlement must not erase an unresolved speech problem")
            let replies = LifecycleTerminationReplySpy()
            let delegate = MacLifecycleDelegate(activity: LifecycleActivitySpy(), automaticTermination: LifecycleTerminationSpy(),
                presenter: LifecycleQuitPresenterSpy(), terminationReply: replies, windowClassifier: LifecycleWindowClassifierSpy())
            delegate.configure(recording: recording, finalization: audio, recovery: LifecycleRecoveryStub(), authority: authority)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await delegate.waitForPendingTermination()
            XCTAssertEqual(replies.values, [true])
        }
    }

    func testT19CancellationAndDelayDoNotBecomeAutomaticExitErrors() async {
        for (phase, failure, degraded) in [(LiveSTTPhase.cancelled, Optional<STTErrorCode>.none, false),
                                          (.cancelled, .cancelled, false), (.finishing, nil, true)] {
            let authority = LifecycleWorkAuthority()
            let recording = T19LifecycleSpeechStub(phase: phase, authority: authority, failure: failure, degraded: degraded)
            let automatic = LifecycleTerminationSpy()
            let lifecycle = AppLifecycleCoordinator(recording: recording,
                finalization: LifecycleFinalizationStub(values: [recording.finishedAudio]), recovery: LifecycleRecoveryStub(),
                activity: LifecycleActivitySpy(), termination: automatic, authority: authority)
            await lifecycle.userWindowCountChanged(0)
            let pending = await lifecycle.currentSnapshot(), before = await automatic.count()
            XCTAssertFalse(pending.requiresUserAttention)
            XCTAssertTrue(pending.hasRelevantWork)
            XCTAssertEqual(before, 0)
            await recording.finishHandoff()
            _ = await lifecycle.terminationDecision()
            _ = await lifecycle.terminationDecision()
            let settled = await lifecycle.currentSnapshot(), after = await automatic.count()
            XCTAssertFalse(settled.requiresUserAttention)
            XCTAssertEqual(after, 1)
        }
    }

    func testT19SpeechWarningDoesNotBypassUnsafeEssentialSave() async {
        let recording = T19LifecycleSpeechStub(storageWarning: "jsonlAppendFailed", saveIsSafe: false)
        await recording.finishHandoff()
        let automatic = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: recording,
            finalization: LifecycleFinalizationStub(values: [recording.finishedAudio]), recovery: LifecycleRecoveryStub(),
            activity: LifecycleActivitySpy(), termination: automatic)
        await lifecycle.userWindowCountChanged(0)
        let decision = await lifecycle.terminationDecision()
        XCTAssertEqual(decision, .terminateCancel)
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit), exits = await automatic.count()
        XCTAssertFalse(allowed)
        XCTAssertEqual(exits, 0)
    }

    func testT19LateSpeechErrorInvalidatesPendingAutomaticExit() async {
        let recording = T19LifecycleSpeechStub()
        await recording.finishHandoff()
        let automatic = DeferredTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: recording,
            finalization: LifecycleFinalizationStub(values: [recording.finishedAudio]), recovery: LifecycleRecoveryStub(),
            activity: LifecycleActivitySpy(), termination: automatic)
        let closing = Task { await lifecycle.userWindowCountChanged(0) }
        await automatic.waitUntilEntered()
        // E.g. detected-language metadata reports a failure after inference
        // completed, while the main-actor automatic gateway is suspended.
        await recording.setStorageWarning("speechMetadataWriteFailed")
        _ = await lifecycle.terminationDecision()
        await automatic.release()
        await closing.value
        let exits = await automatic.count()
        XCTAssertEqual(exits, 0)
    }
}

private actor T19LifecycleSpeechStub: RecordingSessionCoordinating {
    nonisolated let finishedAudio: AudioFinalizationSnapshot
    private var value: RecordingSessionSnapshot
    private let authority: LifecycleWorkAuthority?
    private let lease: UUID?
    private let gate: LifecycleGate?
    private let onCleanup: @Sendable () -> Void
    private let saveIsSafe: Bool
    private(set) var cleanupCalls = 0

    init(phase: LiveSTTPhase = .finishing, cleaned: Bool = false, authority: LifecycleWorkAuthority? = nil,
         gate: LifecycleGate? = nil, onCleanup: @escaping @Sendable () -> Void = {},
         failure: STTErrorCode? = nil, storageWarning: String? = nil, degraded: Bool = false, saveIsSafe: Bool = true) {
        self.authority = authority; self.lease = authority?.admit(invalidating: false)
        self.gate = gate; self.onCleanup = onCleanup
        self.saveIsSafe = saveIsSafe
        let sessionID = SessionID()
        let location = SessionLocation(rootID: StorageRootID(), sessionID: sessionID,
            folderName: SessionFolderName(sessionID: sessionID, createdAt: AbsoluteTime(Date()), timeZone: .gmt))
        var speech = LiveSTTSnapshot()
        speech.phase = phase; speech.cleanupComplete = cleaned; speech.pendingFinals = cleaned ? 0 : 2
        speech.failure = failure; speech.storageWarning = storageWarning; speech.degraded = degraded
        value = RecordingSessionSnapshot(phase: .securedAwaitingFinalization, permissionStatus: .authorized,
            sessionID: sessionID, title: "speech still owned", languageMode: .korean, persistedStatus: .finalizing,
            recordingStartedAt: nil, elapsedMilliseconds: 20_000, microphoneDisplayName: nil,
            normalizedInputLevel: 0, noInputWarning: false, failure: nil, persistenceWarningCode: nil,
            catalogWarningCode: nil, canStart: false, canStop: false, canReset: false, speech: speech)
        let result = AudioFinalizationResult(location: location, phase: .audioReadyAwaitingRemainingFinalization,
            failure: nil, warnings: [], media: nil, source: nil, final: nil, completedSteps: [],
            retainedPaths: [], presentPaths: [], recoveryWasRemoved: false)
        finishedAudio = .init(location: location, generation: 1, operation: .resume, phase: result.phase, result: result)
    }
    func snapshots() -> AsyncStream<RecordingSessionSnapshot> { let value = value; return AsyncStream { $0.yield(value); $0.finish() } }
    func currentSnapshot() -> RecordingSessionSnapshot { value }
    func refreshPermissionStatus() {}
    func start(_ configuration: RecordingStartConfiguration) throws -> RecordingSessionSnapshot { throw RecordingSessionFailure.busy }
    func stop() -> RecordingSessionResult { .error(.busy) }
    func interrupt(_ reason: RecordingInterruptionReason) -> RecordingSessionResult { .interrupted(.interrupted(reason)) }
    func recordSystemWakeIfApplicable() {}
    func reset() {}
    func essentialSaveEvidence() -> EssentialTerminationSaveResult? {
        .init(durableRecoveryState: saveIsSafe, cleanupSettled: true, firstFailure: nil, warnings: [], requiresUserAttention: !saveIsSafe)
    }
    func settleFinalizationHandoffs() async {
        cleanupCalls += 1
        onCleanup()
        await gate?.enterAndWait()
        finishHandoff()
    }
    func finishSpeech() {
        if value.speech.phase == .finishing || value.speech.phase == .listening { value.speech.phase = .finished }
        value.speech.cleanupComplete = true
    }
    func setStorageWarning(_ warning: String) { value.speech.storageWarning = warning }
    func finishHandoff() {
        finishSpeech()
        if let lease { authority?.release(lease) }
    }
}
