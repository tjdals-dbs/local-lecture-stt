import Foundation

/// App-owned serial queue. Only small requests/proofs/results are retained here;
/// all blocking file/media work runs in a detached worker, outside capture's actor.
actor AudioFinalizationCoordinator {
    private struct Key: Hashable {
        let root: StorageRootID
        let session: SessionID
        let operation: AudioFinalizationOperation
    }
    private struct Job {
        let request: AudioFinalizationRequest
        let evidence: FinalizationCompletionEvidence?
        let generation: UInt64
        let control: AudioFinalizationControl
        let lease: UUID?
    }
    private let authority: LifecycleWorkAuthority?
    private let worker: any AudioFinalizationWorking
    private var generation: UInt64 = 0
    private var pending: [Job] = []
    private var active: Job?
    private var pumping = false
    private var snapshotsByKey: [Key: AudioFinalizationSnapshot] = [:]
    private var waiters: [UInt64: [CheckedContinuation<AudioFinalizationResult, Never>]] = [:]
    private var observers: [UUID: AsyncStream<[AudioFinalizationSnapshot]>.Continuation] = [:]

    init(worker: any AudioFinalizationWorking, authority: LifecycleWorkAuthority? = nil) { self.worker = worker; self.authority = authority }
    private func key(_ request: AudioFinalizationRequest) -> Key {
        .init(root: request.location.rootID, session: request.location.sessionID, operation: request.operation)
    }
    private func key(_ location: SessionLocation, operation: AudioFinalizationOperation = .resume) -> Key {
        .init(root: location.rootID, session: location.sessionID, operation: operation)
    }

    @discardableResult
    func enqueue(_ request: AudioFinalizationRequest, retry: Bool = false, ownedHandoff: Bool = false) -> AudioFinalizationSnapshot {
        enqueue(request, evidence: nil, retry: retry, ownedHandoff: ownedHandoff)
    }
    private func enqueue(_ request: AudioFinalizationRequest, evidence: FinalizationCompletionEvidence?, retry: Bool, ownedHandoff: Bool = false) -> AudioFinalizationSnapshot {
        let key = key(request)
        if request.schemaVersion != 1 { return rejected(request, code: .unsupportedSchema) }
        guard request.location.folderName.matches(request.location.sessionID),
              snapshotsByKey[key].map({ $0.location == request.location }) ?? true else {
            return rejected(request, code: .invalidRequest)
        }
        if let existing = snapshotsByKey[key], existing.result == nil || !retry { return existing }
        generation += 1
        let job = Job(request: request, evidence: evidence, generation: generation, control: .init(), lease: authority?.admit(invalidating: !ownedHandoff))
        pending.append(job)
        let snapshot = AudioFinalizationSnapshot(location: request.location, generation: generation, operation: request.operation, phase: .queued, result: nil)
        snapshotsByKey[key] = snapshot
        publish()
        if !pumping {
            pumping = true
            Task { await self.pump() }
        }
        return snapshot
    }
    private func rejected(_ request: AudioFinalizationRequest, code: AudioFinalizationCode) -> AudioFinalizationSnapshot {
        let result = AudioFinalizationResult(location: request.location, phase: .failed, failure: code, warnings: [],
            media: nil, source: nil, final: nil, completedSteps: [], retainedPaths: [], presentPaths: [], recoveryWasRemoved: false)
        return .init(location: request.location, generation: 0, operation: request.operation, phase: .failed, result: result)
    }
    func finalize(_ request: AudioFinalizationRequest, retry: Bool = false) async -> AudioFinalizationResult {
        let submitted = enqueue(request, retry: retry)
        return await wait(submitted)
    }
    func removeRecovery(_ evidence: FinalizationCompletionEvidence) async -> AudioFinalizationResult {
        // If audio finalization owns the session, wait for its settled resources first.
        while let current = snapshotsByKey[key(evidence.location)], current.result == nil {
            if active?.evidence == evidence || pending.contains(where: { $0.evidence == evidence }) { return await wait(current) }
            _ = await wait(current)
        }
        return await wait(enqueue(.init(location: evidence.location), evidence: evidence, retry: true))
    }
    func waitForResult(at location: SessionLocation, operation: AudioFinalizationOperation = .resume) async -> AudioFinalizationResult? {
        guard let snapshot = snapshotsByKey[key(location, operation: operation)], snapshot.location == location else { return nil }
        return await wait(snapshot)
    }
    private func wait(_ snapshot: AudioFinalizationSnapshot) async -> AudioFinalizationResult {
        if let result = snapshot.result { return result }
        // Actor serialization makes registering this waiter atomic with completing a job.
        if let current = snapshotsByKey[key(snapshot.location, operation: snapshot.operation)], current.generation == snapshot.generation,
           let result = current.result { return result }
        return await withCheckedContinuation { waiters[snapshot.generation, default: []].append($0) }
    }
    func cancel(at location: SessionLocation) async -> AudioFinalizationResult? {
        let matching = snapshotsByKey.filter { $0.key.root == location.rootID && $0.key.session == location.sessionID && $0.value.location == location }
        guard let (_, snapshot) = matching.max(by: { $0.value.generation < $1.value.generation }) else { return nil }
        if active.map({ $0.request.location == location }) == true { active?.control.cancel() }
        for job in pending where job.request.location == location { job.control.cancel() }
        for (key, value) in matching where value.result == nil {
            snapshotsByKey[key] = .init(location: location, generation: value.generation, operation: key.operation, phase: .cancelling, result: nil)
        }
        publish()
        return await wait(snapshot)
    }
    func currentSnapshot(at location: SessionLocation, operation: AudioFinalizationOperation = .resume) -> AudioFinalizationSnapshot? {
        snapshotsByKey[key(location, operation: operation)]
    }
    func allSnapshots() -> [AudioFinalizationSnapshot] { values() }
    func handoffResourcesSettled() { publish() }
    func quiesceOwnedWork() async {
        var locations: [SessionLocation] = []
        for snapshot in snapshotsByKey.values where snapshot.result == nil {
            if !locations.contains(snapshot.location) { locations.append(snapshot.location) }
        }
        for location in locations { _ = await cancel(at: location) }
    }
    func snapshots() -> AsyncStream<[AudioFinalizationSnapshot]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(values())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func values() -> [AudioFinalizationSnapshot] { snapshotsByKey.values.sorted { $0.generation < $1.generation } }
    private func publish() { let values = values(); for observer in observers.values { observer.yield(values) } }
    private func update(_ phase: AudioFinalizationPhase, job: Job) {
        guard active?.generation == job.generation else { return }
        let key = key(job.request)
        guard snapshotsByKey[key]?.generation == job.generation else { return }
        snapshotsByKey[key] = .init(location: job.request.location, generation: job.generation, operation: job.request.operation, phase: phase, result: nil)
        publish()
    }
    private func pump() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            active = job
            let worker = self.worker
            let task = Task.detached(priority: .utility) { [self] in
                let progress: @Sendable (AudioFinalizationPhase) async -> Void = { phase in await self.update(phase, job: job) }
                if let evidence = job.evidence { return await worker.removeRecovery(evidence, control: job.control, progress: progress) }
                return await worker.finalize(job.request, control: job.control, progress: progress)
            }
            let result = await task.value
            guard active?.generation == job.generation else { continue }
            active = nil
            if let lease = job.lease { authority?.release(lease) }
            let key = key(job.request)
            if snapshotsByKey[key]?.generation == job.generation {
                snapshotsByKey[key] = .init(location: job.request.location, generation: job.generation, operation: job.request.operation, phase: result.phase, result: result)
                publish()
            }
            let completions = waiters.removeValue(forKey: job.generation) ?? []
            for completion in completions { completion.resume(returning: result) }
        }
        pumping = false
    }
}

/// This app-level boundary receives T07's settled result. It does not wait for
/// long finalization; standalone RecordingSessionCoordinator still only secures MOV.
actor RecordingFinalizationCoordinator: RecordingSessionCoordinating {
    private let recording: any RecordingSessionCoordinating
    private let authority: LifecycleWorkAuthority?
    private let beforeHandoff: @Sendable () async -> Void
    private var handoffTasks: [UUID: Task<Void, Never>] = [:]
    private var stopTask: Task<RecordingSessionResult, Never>?
    private var awaitingInitialDiscovery = false
    private var pendingStartAdmission: UInt64?
    private var pendingStartInterruption: RecordingInterruptionReason?
    private var pendingStartWaiters: [CheckedContinuation<Void, Never>] = []
    let finalization: AudioFinalizationCoordinator
    private let startupRecovery: SessionRecoveryCoordinator?
    private let activity: SessionActivityRegistry?
    init(recording: any RecordingSessionCoordinating, finalization: AudioFinalizationCoordinator,
         startupRecovery: SessionRecoveryCoordinator? = nil, activity: SessionActivityRegistry? = nil,
         authority: LifecycleWorkAuthority? = nil,
         beforeHandoff: @escaping @Sendable () async -> Void = {}) {
        self.authority = authority
        self.beforeHandoff = beforeHandoff
        self.recording = recording; self.finalization = finalization; self.startupRecovery = startupRecovery; self.activity = activity
    }
    func snapshots() async -> AsyncStream<RecordingSessionSnapshot> { await recording.snapshots() }
    func currentSnapshot() async -> RecordingSessionSnapshot { await recording.currentSnapshot() }
    func refreshPermissionStatus() async { await recording.refreshPermissionStatus() }
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot {
        // This is deliberately only the bounded filesystem-discovery gate; it
        // never waits for old media export/verification.
        guard !awaitingInitialDiscovery else { throw RecordingSessionFailure.busy }
        let lease = authority?.admit()
        defer { if let lease { authority?.release(lease) } }
        awaitingInitialDiscovery = true
        pendingStartAdmission = authority?.state().generation
        pendingStartInterruption = nil
        await startupRecovery?.waitForInitialDiscovery()
        let interruption = pendingStartInterruption
        awaitingInitialDiscovery = false
        pendingStartAdmission = nil
        pendingStartInterruption = nil
        let waiters = pendingStartWaiters
        pendingStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let interruption { throw RecordingSessionFailure.interrupted(interruption) }
        return try await recording.start(configuration)
    }
    func pause() async throws { try await recording.pause() }
    func resume() async throws { try await recording.resume() }
    func stop() async -> RecordingSessionResult {
        if let stopTask { return await stopTask.value }
        let lease = authority?.admit(invalidating: false)
        let task = Task {
            let result = await self.performStop()
            if let lease { self.authority?.release(lease) }
            return result
        }
        stopTask = task
        let result = await task.value
        stopTask = nil
        return result
    }
    private func performStop() async -> RecordingSessionResult {
        let result = await recording.stop()
        if case let .secured(secured) = result {
            await beforeHandoff()
            await finalization.enqueue(.init(location: secured.location), ownedHandoff: true)
            let finalization = finalization
            let activity = activity
            let lease = authority?.admit(invalidating: false)
            let authority = authority
            let handoffID = UUID()
            handoffTasks[handoffID] = Task {
                _ = await finalization.waitForResult(at: secured.location)
                await recording.waitForSpeech(at: secured.location)
                await activity?.releaseRecordingOrFinalization(at: secured.location)
                if let lease { authority?.release(lease) }
                self.handoffTasks[handoffID] = nil
                await finalization.handoffResourcesSettled()
            }
        }
        return result
    }
    func interrupt(_ reason: RecordingInterruptionReason) async -> RecordingSessionResult {
        // Interrupted sessions retain their MOV for T09; unlike a normal Stop,
        // they must never be submitted as a completed T08 finalization job.
        if let stopTask { return await stopTask.value }
        return await recording.interrupt(reason)
    }
    func interruptForLifecycle(_ reason: RecordingInterruptionReason, admission: UInt64?) async -> RecordingSessionResult {
        guard admission == authority?.state().generation else { return .error(.busy) }
        if let stopTask { return await stopTask.value }
        return await recording.interruptForLifecycle(reason, admission: admission)
    }
    func invalidatePendingStart(_ reason: RecordingInterruptionReason, admission: UInt64?) async {
        guard awaitingInitialDiscovery else { return }
        // T09 or another independent owner may have advanced the shared epoch
        // after this start was admitted. Invalidate only a request that already
        // existed at the event, never a newer start.
        if let pendingStartAdmission, let admission {
            guard pendingStartAdmission <= admission else { return }
        } else if pendingStartAdmission != admission { return }
        if pendingStartInterruption == nil { pendingStartInterruption = reason }
    }
    func settleFinalizationHandoffs() async {
        // Lifecycle marks the pending request before cancelling T09 discovery.
        // Join it only after that cancellation, so neither owner waits on itself.
        if awaitingInitialDiscovery, pendingStartInterruption != nil {
            await withCheckedContinuation { pendingStartWaiters.append($0) }
        }
        if let stopTask { _ = await stopTask.value }
        await recording.settleFinalizationHandoffs()
        let tasks = handoffTasks
        for (_, task) in tasks { await task.value }
    }
    func essentialSaveEvidence() async -> EssentialTerminationSaveResult? { await recording.essentialSaveEvidence() }
    func recordSystemWakeIfApplicable() async { await recording.recordSystemWakeIfApplicable() }
    func reset() async { await recording.reset() }
}
