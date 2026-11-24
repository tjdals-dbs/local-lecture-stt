import Foundation

/// Synchronous admission authority shared by every production work owner.
/// The lock protects only small in-memory transitions and the final gateway;
/// no actor call, filesystem operation or media work runs under it.
final class LifecycleWorkAuthority: @unchecked Sendable {
    struct State: Sendable, Equatable { let generation: UInt64; let active: Bool }
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var leases: Set<UUID> = []
    private let activity: @Sendable (Bool) -> Void
    init(activity: @escaping @Sendable (Bool) -> Void = { _ in }) { self.activity = activity }
    func admit(invalidating: Bool = true) -> UUID {
        lock.lock(); defer { lock.unlock() }
        if invalidating { generation &+= 1 }
        let lease = UUID()
        if leases.isEmpty { activity(true) }
        leases.insert(lease)
        return lease
    }
    func release(_ lease: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard leases.remove(lease) != nil else { return }
        if leases.isEmpty { activity(false) }
    }
    func state() -> State {
        lock.lock(); defer { lock.unlock() }
        return State(generation: generation, active: !leases.isEmpty)
    }
    @discardableResult
    func authorize(_ expected: UInt64, action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected, leases.isEmpty else { return false }
        action()
        return true
    }
}

/// Framework-free events crossing from the AppKit adapter.  They intentionally
/// contain no notification, window, URL, or ProcessInfo values.
enum AppLifecyclePowerEvent: Sendable, Equatable { case willSleep, didWake, willPowerOff }
enum AppTerminationDecision: Sendable, Equatable { case terminateNow, terminateCancel, terminateLater, needsRecordingChoice }
enum AppTerminationChoice: Sendable, Equatable { case continueUsing, essentialSaveAndQuit }

protocol LifecycleActivityControlling: Sendable {
    func setRelevantWorkActive(_ active: Bool) async
}

protocol LifecycleTerminationRequesting: Sendable {
    /// The App adapter invokes this validation immediately before touching
    /// NSApplication.  It lets the policy reject a reservation invalidated
    /// while an adapter/gateway was waiting to run on the main actor.
    @discardableResult
    func requestAutomaticTermination(isStillValid: @escaping @Sendable () async -> Bool) async -> Bool
}

/// The AppKit delegate cannot await an actor from
/// `applicationShouldTerminate(_:)`.  This narrow owner publishes only a
/// generation-checked semantic answer.  It starts conservatively at
/// `terminateLater`; the adapter may return `terminateNow` synchronously only
/// after the app-lifetime coordinator has freshly established that answer.
@MainActor
protocol LifecycleTerminationReadinessUpdating: AnyObject, Sendable {
    func updateSynchronousTerminationDecision(_ decision: AppTerminationDecision, generation: UInt64?)
}

struct EssentialTerminationSaveResult: Sendable, Equatable {
    let durableRecoveryState: Bool
    let cleanupSettled: Bool
    let firstFailure: RecordingSessionFailure?
    let warnings: [String]
    let requiresUserAttention: Bool

    var mayTerminate: Bool {
        durableRecoveryState && cleanupSettled && firstFailure == nil && !requiresUserAttention
    }
}

protocol LifecycleFinalizationCoordinating: Sendable {
    func snapshots() async -> AsyncStream<[AudioFinalizationSnapshot]>
    func allSnapshots() async -> [AudioFinalizationSnapshot]
    func quiesceOwnedWork() async
}

protocol LifecycleRecoveryCoordinating: Sendable {
    func snapshots() async -> AsyncStream<SessionRecoverySnapshot>
    func currentSnapshot() async -> SessionRecoverySnapshot
    func refresh() async
    func cancelOwnedRecovery() async
    func quiesceOwnedRecovery() async
}

extension LifecycleRecoveryCoordinating {
    func quiesceOwnedRecovery() async { await cancelOwnedRecovery() }
}

extension AudioFinalizationCoordinator: LifecycleFinalizationCoordinating {}
extension SessionRecoveryCoordinator: LifecycleRecoveryCoordinating {}

struct LifecycleAuxiliarySnapshot: Sendable, Equatable {
    let active: Bool
    let requiresAttention: Bool
}
protocol LifecycleAuxiliaryWorking: Sendable {
    func workSnapshots() async -> AsyncStream<LifecycleAuxiliarySnapshot>
    func currentWork() async -> LifecycleAuxiliarySnapshot
    /// Pause network work and cancel/await local installer resource cleanup.
    func quiesce() async
}

struct AppLifecycleSnapshot: Sendable, Equatable {
    let generation: UInt64
    let visibleUserWindowCount: Int
    let hasRelevantWork: Bool
    let requiresUserAttention: Bool
    /// Unsafe essential-save/recovery state also prevents explicit quit.
    /// Speech availability errors only suppress unattended automatic exit.
    let blocksExplicitTermination: Bool
    let autoExitReserved: Bool

    static let initial = AppLifecycleSnapshot(generation: 0, visibleUserWindowCount: 0,
                                              hasRelevantWork: false, requiresUserAttention: false,
                                              blocksExplicitTermination: false,
                                              autoExitReserved: false)
}

/// One app-lifetime owner for policy only.  T07/T08/T09 remain the owners of
/// capture, media I/O and recovery.  Views may observe those owners but never
/// create or cancel their lifetime tasks.
actor AppLifecycleCoordinator {
    private let authority: LifecycleWorkAuthority?
    private let recording: any RecordingSessionCoordinating
    private let finalization: any LifecycleFinalizationCoordinating
    private let recovery: any LifecycleRecoveryCoordinating
    private let auxiliary: (any LifecycleAuxiliaryWorking)?
    private var auxiliaryTask: Task<Void, Never>?
    private let activity: any LifecycleActivityControlling
    private let termination: any LifecycleTerminationRequesting
    private weak var terminationReadiness: (any LifecycleTerminationReadinessUpdating)?
    private var snapshot = AppLifecycleSnapshot.initial
    private var snapshotAdmission: UInt64?
    private var recordingTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var workRefreshGeneration: UInt64 = 0
    private struct SleepCycle {
        let generation: UInt64
        let cleanup: Task<Void, Never>
    }
    private let onWakeJoining: @Sendable (UInt64) -> Void
    private var sleepGeneration: UInt64 = 0
    private var activeSleepCycle: SleepCycle?
    /// Set as soon as wake has claimed a cycle.  A subsequent will-sleep is a
    /// new generation even while the old cycle is still releasing file/scope
    /// ownership; treating it as a duplicate loses the second sleep.
    private var wakeAwaitingCleanupGeneration: UInt64?
    private var nextAutoExitReservation: UInt64 = 0
    private var autoExitReservation: UInt64?
    private var autoExitRequestReservation: UInt64?
    private var reopenAwaitingVisibleUserWindow = false
    private var nextQuitAttempt: UInt64 = 0
    private var activeQuitAttempt: (id: UInt64, task: Task<EssentialTerminationSaveResult, Never>)?

    init(recording: any RecordingSessionCoordinating, finalization: any LifecycleFinalizationCoordinating,
         recovery: any LifecycleRecoveryCoordinating, activity: any LifecycleActivityControlling,
         termination: any LifecycleTerminationRequesting,
         terminationReadiness: (any LifecycleTerminationReadinessUpdating)? = nil,
         authority: LifecycleWorkAuthority? = nil,
         auxiliary: (any LifecycleAuxiliaryWorking)? = nil,
         onWakeJoining: @escaping @Sendable (UInt64) -> Void = { _ in }) {
        self.onWakeJoining = onWakeJoining
        self.authority = authority
        self.auxiliary = auxiliary
        self.recording = recording; self.finalization = finalization; self.recovery = recovery
        self.activity = activity; self.termination = termination
        self.terminationReadiness = terminationReadiness
    }

    func start() async {
        guard recordingTask == nil else { return }
        if let auxiliary {
            auxiliaryTask = Task { [weak self] in
                for await _ in await auxiliary.workSnapshots() { await self?.refreshWorkState() }
            }
        }
        recordingTask = Task { [weak self, recording] in
            let stream = await recording.snapshots()
            for await value in stream { await self?.recordingChanged(value) }
        }
        finalizationTask = Task { [weak self, finalization] in
            let stream = await finalization.snapshots()
            for await value in stream { await self?.finalizationChanged(value) }
        }
        recoveryTask = Task { [weak self, recovery] in
            let stream = await recovery.snapshots()
            for await value in stream { await self?.recoveryChanged(value) }
        }
        await refreshWorkState()
    }

    func currentSnapshot() -> AppLifecycleSnapshot { snapshot }

    func userWindowCountChanged(_ count: Int) async {
        guard count >= 0 else { return }
        if count > 0 {
            reopenAwaitingVisibleUserWindow = false
            autoExitReservation = nil
            autoExitRequestReservation = nil
        } else if !reopenAwaitingVisibleUserWindow, autoExitReservation == nil {
            nextAutoExitReservation &+= 1
            autoExitReservation = nextAutoExitReservation
        }
        snapshot = AppLifecycleSnapshot(generation: snapshot.generation &+ 1, visibleUserWindowCount: count,
                                        hasRelevantWork: snapshot.hasRelevantWork,
                                        requiresUserAttention: snapshot.requiresUserAttention,
                                        blocksExplicitTermination: snapshot.blocksExplicitTermination,
                                        autoExitReserved: autoExitReservation != nil)
        await refreshWorkState()
    }

    func applicationReopened() {
        snapshot = AppLifecycleSnapshot(generation: snapshot.generation &+ 1, visibleUserWindowCount: snapshot.visibleUserWindowCount,
                                        hasRelevantWork: snapshot.hasRelevantWork,
                                        requiresUserAttention: snapshot.requiresUserAttention,
                                        blocksExplicitTermination: snapshot.blocksExplicitTermination,
                                        autoExitReserved: false)
        autoExitReservation = nil
        autoExitRequestReservation = nil
        // AppKit's reopen callback can precede creation/visibility of the
        // window.  A zero count in that gap must not create a new reservation.
        reopenAwaitingVisibleUserWindow = true
    }

    func handlePowerEvent(_ event: AppLifecyclePowerEvent) async {
        switch event {
        case .willSleep, .willPowerOff:
            // Notifications can be duplicated or reordered.  One owned task
            // serializes interruption, T08 cleanup, and T09 cancellation.
            // Duplicate will-sleep before a wake is coalesced.  Once wake has
            // claimed its cleanup, however, another will-sleep is a distinct
            // generation and must not be dropped.
            guard activeSleepCycle == nil || wakeAwaitingCleanupGeneration != nil else { return }
            sleepGeneration &+= 1
            wakeAwaitingCleanupGeneration = nil
            let reason: RecordingInterruptionReason = event == .willPowerOff ? .systemPowerOff : .systemSleep
            let admission = authority?.state().generation
            let recording = recording; let finalization = finalization; let recovery = recovery; let auxiliary = auxiliary
            let previousCleanup = activeSleepCycle?.cleanup
            let cleanupLease = authority?.admit(invalidating: false)
            let authority = authority
            let cleanup = Task {
                defer { if let cleanupLease { authority?.release(cleanupLease) } }
                await recording.invalidatePendingStart(reason, admission: admission)
                await previousCleanup?.value
                await auxiliary?.quiesce()
                let before = await recording.currentSnapshot()
                // A normal Stop already owns `.securing`; sleep/power-off joins
                // its resource settlement below and must not rewrite that
                // capture outcome as interrupted.
                if before.phase == .preparing || before.phase == .recording || before.phase == .securing || before.phase == .securedAwaitingFinalization {
                    _ = await recording.interruptForLifecycle(reason, admission: admission)
                }
                // Never wait for export; cancellation waits only for owned
                // reader/writer/security-scope cleanup.
                await recovery.quiesceOwnedRecovery()
                await finalization.quiesceOwnedWork()
                await recording.settleFinalizationHandoffs()
            }
            activeSleepCycle = .init(generation: sleepGeneration, cleanup: cleanup)
        case .didWake:
            guard let cycle = activeSleepCycle else { return }
            guard wakeAwaitingCleanupGeneration == nil else { return }
            wakeAwaitingCleanupGeneration = cycle.generation
            onWakeJoining(cycle.generation)
            await cycle.cleanup.value
            // Reject an old wake after a newer sleep cycle replaced it.
            guard activeSleepCycle?.generation == cycle.generation,
                  wakeAwaitingCleanupGeneration == cycle.generation else { return }
            await recording.recordSystemWakeIfApplicable()
            guard activeSleepCycle?.generation == cycle.generation,
                  wakeAwaitingCleanupGeneration == cycle.generation else { return }
            activeSleepCycle = nil
            wakeAwaitingCleanupGeneration = nil
            await recovery.refresh()
            await refreshWorkState()
        }
    }

    func terminationDecision() async -> AppTerminationDecision {
        // Delegate observation is intentionally asynchronous.  A termination
        // request must nevertheless make its decision from fresh owners, not
        // from a not-yet-delivered stream value.
        let admission = authority?.state().generation
        await refreshWorkState()
        let recordingSnapshot = await recording.currentSnapshot()
        let evidence = await recording.essentialSaveEvidence()
        let decision: AppTerminationDecision
        switch recordingSnapshot.phase {
        case .preparing, .recording: decision = .needsRecordingChoice
        case .securing: decision = .terminateLater
        case .error, .interrupted: decision = evidence?.mayTerminate == true && !snapshot.hasRelevantWork && !snapshot.blocksExplicitTermination ? .terminateNow : .terminateCancel
        case .idle, .securedAwaitingFinalization:
            decision = snapshot.hasRelevantWork ? .terminateLater : (snapshot.blocksExplicitTermination ? .terminateCancel : .terminateNow)
        }
        await terminationReadiness?.updateSynchronousTerminationDecision(decision, generation: admission)
        return decision
    }

    func resolveTermination(_ choice: AppTerminationChoice, admittedGeneration: UInt64? = nil) async -> Bool {
        guard choice == .essentialSaveAndQuit else { return false }
        if let activeQuitAttempt { return await activeQuitAttempt.task.value.mayTerminate }
        nextQuitAttempt &+= 1
        let attemptID = nextQuitAttempt
        let admission = admittedGeneration ?? authority?.state().generation
        let cleanupLease = authority?.admit(invalidating: false)
        let authority = authority
        let task = Task { [weak self] in
            defer { if let cleanupLease { authority?.release(cleanupLease) } }
            guard let self else {
                return EssentialTerminationSaveResult(durableRecoveryState: false, cleanupSettled: false,
                                                      firstFailure: nil, warnings: ["lifecycleOwnerReleased"],
                                                      requiresUserAttention: true)
            }
            return await self.performEssentialTermination(attemptID: attemptID, admission: admission)
        }
        activeQuitAttempt = (attemptID, task)
        let result = await task.value
        if activeQuitAttempt?.id == attemptID { activeQuitAttempt = nil }
        await refreshWorkState()
        return result.mayTerminate && admission == authority?.state().generation
    }

    private func performEssentialTermination(attemptID: UInt64, admission: UInt64?) async -> EssentialTerminationSaveResult {
        guard admission == authority?.state().generation else {
            return .init(durableRecoveryState: false, cleanupSettled: true, firstFailure: nil,
                         warnings: ["supersededAdmission"], requiresUserAttention: false)
        }
        await recording.invalidatePendingStart(.applicationQuit, admission: admission)
        let initial = await recording.currentSnapshot()
        var evidence = await recording.essentialSaveEvidence()
        var firstFailure: RecordingSessionFailure?
        if initial.phase == .preparing || initial.phase == .recording || initial.phase == .securing || initial.phase == .securedAwaitingFinalization {
            let result = await recording.interruptForLifecycle(.applicationQuit, admission: admission)
            if case let .error(failure) = result {
                if case .interrupted = failure {} else { firstFailure = failure }
            }
            evidence = await recording.essentialSaveEvidence()
        }
        // T08/T09 cancellation waits only for their owned writer/reader/scope
        // settlement.  It deliberately never awaits export or future derived
        // work, leaving the durable checkpoint for the next T09 owner.
        guard admission == authority?.state().generation else { return supersededSave(evidence) }
        await recovery.quiesceOwnedRecovery()
        guard admission == authority?.state().generation else { return supersededSave(evidence) }
        await finalization.quiesceOwnedWork()
        await auxiliary?.quiesce()
        guard admission == authority?.state().generation else { return supersededSave(evidence) }
        await recording.settleFinalizationHandoffs()
        guard activeQuitAttempt?.id == attemptID else {
            return .init(durableRecoveryState: false, cleanupSettled: false, firstFailure: firstFailure,
                         warnings: ["supersededQuitAttempt"], requiresUserAttention: true)
        }
        await refreshWorkState()
        let finalRecording = await recording.currentSnapshot()
        let finalizations = await finalization.allSnapshots()
        let recoverySnapshot = await recovery.currentSnapshot()
        let auxiliarySnapshot = await auxiliary?.currentWork()
        let latestRecording = await recording.currentSnapshot()
        let unchanged = latestRecording == finalRecording && (admission == authority?.state().generation)
        let recordingSafe = unchanged && (finalRecording.phase == .idle || finalRecording.phase == .interrupted ||
            finalRecording.phase == .securedAwaitingFinalization)
        let cleanupSettled = (evidence?.cleanupSettled ?? (initial.phase == .idle)) && !finalizations.contains { $0.result == nil } &&
            recoverySnapshot.phase != .discovering && recoverySnapshot.phase != .recovering && auxiliarySnapshot?.active != true
        firstFailure = evidence?.firstFailure ?? firstFailure
        let durable = recordingSafe && firstFailure == nil && (evidence?.durableRecoveryState ?? (initial.phase == .idle))
        return .init(durableRecoveryState: durable, cleanupSettled: cleanupSettled, firstFailure: firstFailure,
                     warnings: evidence?.warnings ?? [], requiresUserAttention: snapshot.blocksExplicitTermination || evidence?.requiresUserAttention == true)
    }

    private func supersededSave(_ evidence: EssentialTerminationSaveResult?) -> EssentialTerminationSaveResult {
        .init(durableRecoveryState: false, cleanupSettled: evidence?.cleanupSettled ?? true,
              firstFailure: evidence?.firstFailure, warnings: (evidence?.warnings ?? []) + ["supersededAdmission"],
              requiresUserAttention: evidence?.requiresUserAttention ?? false)
    }

    private func recordingChanged(_ value: RecordingSessionSnapshot) async {
        await refreshWorkState()
    }
    private func finalizationChanged(_ values: [AudioFinalizationSnapshot]) async {
        await refreshWorkState()
    }
    private func recoveryChanged(_ value: SessionRecoverySnapshot) async {
        await refreshWorkState()
    }

    private func refreshWorkState(recordingSnapshot: RecordingSessionSnapshot? = nil,
                                  finalizations: [AudioFinalizationSnapshot]? = nil,
                                  recoverySnapshot: SessionRecoverySnapshot? = nil) async {
        let admission = authority?.state().generation
        workRefreshGeneration &+= 1
        let refreshGeneration = workRefreshGeneration
        let recordingValue: RecordingSessionSnapshot
        if let recordingSnapshot { recordingValue = recordingSnapshot }
        else {
            recordingValue = await recording.currentSnapshot()
            guard workRefreshGeneration == refreshGeneration else { return }
        }
        let finalizationValues: [AudioFinalizationSnapshot]
        if let finalizations { finalizationValues = finalizations }
        else {
            finalizationValues = await finalization.allSnapshots()
            guard workRefreshGeneration == refreshGeneration else { return }
        }
        let recoveryValue: SessionRecoverySnapshot
        if let recoverySnapshot { recoveryValue = recoverySnapshot }
        else {
            recoveryValue = await recovery.currentSnapshot()
            guard workRefreshGeneration == refreshGeneration else { return }
        }
        let recordingWork: Bool
        switch recordingValue.phase {
        case .preparing, .recording, .securing:
            recordingWork = true
        case .securedAwaitingFinalization:
            // T07 publishes this state just before T08 is enqueued.  Treat a
            // not-yet-observed queue item as work so there is never a sleep
            // assertion gap at the ownership handoff.
            let matching = finalizationValues.filter { $0.location.sessionID == recordingValue.sessionID }
            recordingWork = matching.isEmpty || matching.contains { $0.result == nil }
        case .idle, .interrupted, .error:
            recordingWork = false
        }
        let finalizationWork = finalizationValues.contains { $0.result == nil }
        let recoveryWork = recoveryValue.phase == .discovering || recoveryValue.phase == .recovering
        // Audio finalization can finish before speech. A terminal inference
        // phase still owns journal/native cleanup until cleanupComplete.
        let speechWork = recordingValue.speech.phase != .idle && !recordingValue.speech.cleanupComplete
        // A failed transcript remains a reason to keep the app available for
        // inspection even after speech cleanup releases its work leases. Normal
        // cancellation and transient backlog are not errors. Storage warnings
        // count independently, including late metadata/diagnostic write failures.
        // A backend cancellation reported as a failed inference is not the
        // coordinator's normal cancellation and must still remain visible.
        let speechAttention = (recordingValue.speech.failure.map {
            $0 != .cancelled || recordingValue.speech.phase != .cancelled
        } ?? false) ||
            recordingValue.speech.storageWarning != nil
        let saveEvidence = await recording.essentialSaveEvidence()
        let transcriptAttention = finalizationValues.contains { $0.result?.transcriptFailure != nil } ||
            recoveryValue.report?.items.contains { $0.code == .transcriptFinalizationFailed } == true
        let safetyAttention = (recordingValue.phase == .error && saveEvidence?.mayTerminate != true) || saveEvidence?.requiresUserAttention == true ||
            finalizationValues.contains { snapshot in
                guard let result = snapshot.result else { return false }
                // Intentional cancellation is safe only after successful resource
                // cleanup. Catalog/diagnostic warnings remain best effort.
                return (result.failure != nil && result.failure != .cancelled && !result.permitsEssentialQuitAfterTranscriptFailure) ||
                    result.warnings.contains { $0.hasPrefix("cleanup.") || $0.hasPrefix("mediaCleanup.") }
            } ||
            recoveryValue.report?.items.contains(where: { issue in
                switch issue.code {
                case .sessionReady, .transcriptFinalizationFailed, .audioReadyAwaitingRemainingFinalization, .audioRevalidated, .interruptedRecordingRecovered,
                     .currentProcessActive, .catalogRefreshFailed: return false
                default: return true
                }
            }) == true ||
            (recoveryValue.report?.discoveryWarning.map { !$0.hasPrefix("catalog.") } ?? false)
        guard workRefreshGeneration == refreshGeneration, admission == authority?.state().generation else { return }
        // The shared leases also cover the metadata/resource handoff after a
        // speech snapshot reports cleanupComplete. Route quit through essential
        // settlement during that gap instead of skipping it and having the
        // final synchronous authority reject the AppKit reply.
        let ownedWork = authority?.state().active == true
        let auxiliaryValue = await auxiliary?.currentWork()
        guard workRefreshGeneration == refreshGeneration, admission == authority?.state().generation else { return }
        snapshotAdmission = admission
        snapshot = AppLifecycleSnapshot(generation: snapshot.generation &+ 1,
                                        visibleUserWindowCount: snapshot.visibleUserWindowCount,
                                        hasRelevantWork: recordingWork || finalizationWork || recoveryWork || speechWork || ownedWork || auxiliaryValue?.active == true,
                                        requiresUserAttention: safetyAttention || speechAttention || transcriptAttention || auxiliaryValue?.requiresAttention == true,
                                        blocksExplicitTermination: safetyAttention,
                                        autoExitReserved: snapshot.autoExitReserved)
        let readiness: AppTerminationDecision
        switch recordingValue.phase {
        case .preparing, .recording: readiness = .needsRecordingChoice
        case .securing: readiness = .terminateLater
        case .error, .interrupted: readiness = saveEvidence?.mayTerminate == true && !snapshot.hasRelevantWork && !snapshot.blocksExplicitTermination ? .terminateNow : .terminateCancel
        case .idle, .securedAwaitingFinalization:
            readiness = snapshot.hasRelevantWork ? .terminateLater : (snapshot.blocksExplicitTermination ? .terminateCancel : .terminateNow)
        }
        await terminationReadiness?.updateSynchronousTerminationDecision(readiness, generation: admission)
        let active = snapshot.hasRelevantWork
        if authority == nil { await activity.setRelevantWorkActive(active) }
        guard workRefreshGeneration == refreshGeneration else { return }
        await evaluateAutomaticTermination()
    }

    private func evaluateAutomaticTermination() async {
        guard snapshotAdmission == authority?.state().generation, authority?.state().active != true, snapshot.autoExitReserved, snapshot.visibleUserWindowCount == 0,
              !snapshot.hasRelevantWork, !snapshot.requiresUserAttention else { return }
        guard let reservation = autoExitReservation, autoExitRequestReservation != reservation else { return }
        autoExitRequestReservation = reservation
        let dispatchGeneration = snapshot.generation
        let accepted = await termination.requestAutomaticTermination { [weak self] in
            await self?.isCurrentAutomaticTerminationReservation(reservation) ?? false
        }
        guard !accepted, autoExitRequestReservation == reservation else { return }
        autoExitRequestReservation = nil
        // A state change may have been observed while the gateway was awaiting
        // authorization. Reconsider it once; never spin on an unchanged refusal.
        if snapshot.generation != dispatchGeneration { await evaluateAutomaticTermination() }
    }

    private func isCurrentAutomaticTerminationReservation(_ reservation: UInt64) -> Bool {
        snapshotAdmission == authority?.state().generation && authority?.state().active != true &&
            autoExitReservation == reservation && autoExitRequestReservation == reservation &&
            snapshot.visibleUserWindowCount == 0 && !snapshot.hasRelevantWork && !snapshot.requiresUserAttention
    }
}
