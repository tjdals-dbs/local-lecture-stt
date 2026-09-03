import Foundation

/// App-owned serial queue. Only small requests/proofs/results are retained here;
/// all blocking file/media work runs in a detached worker, outside capture's actor.
actor AudioFinalizationCoordinator {
    private struct Key: Hashable { let root: StorageRootID; let session: SessionID }
    private struct Job {
        let request: AudioFinalizationRequest
        let evidence: FinalizationCompletionEvidence?
        let generation: UInt64
        let control: AudioFinalizationControl
    }
    private let worker: any AudioFinalizationWorking
    private var generation: UInt64 = 0
    private var pending: [Job] = []
    private var active: Job?
    private var pumping = false
    private var snapshotsByKey: [Key: AudioFinalizationSnapshot] = [:]
    private var waiters: [UInt64: [CheckedContinuation<AudioFinalizationResult, Never>]] = [:]
    private var observers: [UUID: AsyncStream<[AudioFinalizationSnapshot]>.Continuation] = [:]

    init(worker: any AudioFinalizationWorking) { self.worker = worker }
    private func key(_ location: SessionLocation) -> Key { .init(root: location.rootID, session: location.sessionID) }

    @discardableResult
    func enqueue(_ request: AudioFinalizationRequest, retry: Bool = false) -> AudioFinalizationSnapshot {
        enqueue(request, evidence: nil, retry: retry)
    }
    private func enqueue(_ request: AudioFinalizationRequest, evidence: FinalizationCompletionEvidence?, retry: Bool) -> AudioFinalizationSnapshot {
        let key = key(request.location)
        if request.schemaVersion != 1 { return rejected(request, code: .unsupportedSchema) }
        guard request.location.folderName.matches(request.location.sessionID),
              snapshotsByKey[key].map({ $0.location == request.location }) ?? true else {
            return rejected(request, code: .invalidRequest)
        }
        if let existing = snapshotsByKey[key], existing.result == nil || !retry { return existing }
        generation += 1
        let job = Job(request: request, evidence: evidence, generation: generation, control: .init())
        pending.append(job)
        let snapshot = AudioFinalizationSnapshot(location: request.location, generation: generation, phase: .queued, result: nil)
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
        return .init(location: request.location, generation: 0, phase: .failed, result: result)
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
    func waitForResult(at location: SessionLocation) async -> AudioFinalizationResult? {
        guard let snapshot = snapshotsByKey[key(location)], snapshot.location == location else { return nil }
        return await wait(snapshot)
    }
    private func wait(_ snapshot: AudioFinalizationSnapshot) async -> AudioFinalizationResult {
        if let result = snapshot.result { return result }
        // Actor serialization makes registering this waiter atomic with completing a job.
        if let current = snapshotsByKey[key(snapshot.location)], current.generation == snapshot.generation,
           let result = current.result { return result }
        return await withCheckedContinuation { waiters[snapshot.generation, default: []].append($0) }
    }
    func cancel(at location: SessionLocation) async -> AudioFinalizationResult? {
        let key = key(location)
        guard let snapshot = snapshotsByKey[key], snapshot.location == location else { return nil }
        if active.map({ self.key($0.request.location) }) == key { active?.control.cancel() }
        for job in pending where self.key(job.request.location) == key { job.control.cancel() }
        if snapshot.result == nil {
            snapshotsByKey[key] = .init(location: location, generation: snapshot.generation, phase: .cancelling, result: nil)
            publish()
        }
        return await wait(snapshot)
    }
    func currentSnapshot(at location: SessionLocation) -> AudioFinalizationSnapshot? { snapshotsByKey[key(location)] }
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
        let key = key(job.request.location)
        guard snapshotsByKey[key]?.generation == job.generation else { return }
        snapshotsByKey[key] = .init(location: job.request.location, generation: job.generation, phase: phase, result: nil)
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
            let key = key(job.request.location)
            if snapshotsByKey[key]?.generation == job.generation {
                snapshotsByKey[key] = .init(location: job.request.location, generation: job.generation, phase: result.phase, result: result)
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
    let finalization: AudioFinalizationCoordinator
    init(recording: any RecordingSessionCoordinating, finalization: AudioFinalizationCoordinator) {
        self.recording = recording; self.finalization = finalization
    }
    func snapshots() async -> AsyncStream<RecordingSessionSnapshot> { await recording.snapshots() }
    func currentSnapshot() async -> RecordingSessionSnapshot { await recording.currentSnapshot() }
    func refreshPermissionStatus() async { await recording.refreshPermissionStatus() }
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot { try await recording.start(configuration) }
    func stop() async -> RecordingSessionResult {
        let result = await recording.stop()
        if case let .secured(secured) = result {
            await finalization.enqueue(.init(location: secured.location))
        }
        return result
    }
    func reset() async { await recording.reset() }
}
