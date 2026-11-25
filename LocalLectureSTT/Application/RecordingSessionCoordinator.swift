import Foundation

protocol MicrophoneCapturing: Sendable {
    func currentLifecycle() async -> CaptureLifecycle
    func start() async throws -> CaptureHandle
    func stop() async
    func pause() async throws -> CapturePauseBoundary
    func resume() async throws
}

extension MicrophoneCapturing {
    func pause() async throws -> CapturePauseBoundary { throw CaptureError(.startInterrupted) }
    func resume() async throws { throw CaptureError(.startInterrupted) }
}

protocol RecordingStorageRootChecking: Sendable {
    func availability() async -> StorageRootAvailability
}

protocol RecordingCatalogRefreshing: Sendable {
    func reconcile() async throws -> CatalogReconciliationReport
}

protocol AudioRecorderMaking: Sendable {
    func makeRecorder() -> any AudioRecorder
}

struct ClosureAudioRecorderFactory: AudioRecorderMaking {
    private let factory: @Sendable () -> any AudioRecorder

    init(_ factory: @escaping @Sendable () -> any AudioRecorder) {
        self.factory = factory
    }

    func makeRecorder() -> any AudioRecorder { factory() }
}

protocol RecordingTicking: Sendable {
    func ticks() -> AsyncStream<Void>
}

struct SystemRecordingTicker: RecordingTicking {
    let intervalNanoseconds: UInt64

    init(interval: TimeInterval = 1) {
        intervalNanoseconds = UInt64(max(0.05, interval) * 1_000_000_000)
    }

    func ticks() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: intervalNanoseconds)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct RecordingSessionClock: Sendable {
    let wallNow: @Sendable () -> AbsoluteTime
    let monotonicNow: @Sendable () -> TimeInterval

    static let live = RecordingSessionClock(
        wallNow: { AbsoluteTime(Date()) },
        monotonicNow: { ProcessInfo.processInfo.systemUptime }
    )
}

struct RecordingSessionEnvironment: Sendable, Equatable {
    let appVersion: String
    let osVersion: String

    init(appVersion: String, osVersion: String) {
        self.appVersion = appVersion.isEmpty ? "unknown" : appVersion
        self.osVersion = osVersion.isEmpty ? "unknown" : osVersion
    }
}

struct RecordingSessionIdentifiers: Sendable {
    let sessionID: @Sendable () -> SessionID
    let eventID: @Sendable () -> SessionEventID

    static let live = RecordingSessionIdentifiers(
        sessionID: { SessionID() },
        eventID: { SessionEventID() }
    )
}

struct RecordingStartConfiguration: Sendable, Equatable {
    let title: String
    let languageMode: LanguageMode
    let timeZone: TimeZone
    let modelDescriptor: ModelPackageDescriptor?

    init(title: String, languageMode: LanguageMode = .korean, timeZone: TimeZone,
         modelDescriptor: ModelPackageDescriptor? = nil) {
        self.title = title
        self.languageMode = languageMode
        self.timeZone = timeZone
        self.modelDescriptor = modelDescriptor
    }
}

/// A semantic, durable reason for a non-user terminal capture path.  This is
/// deliberately separate from `stop()`: callers must not accidentally turn a
/// sleep or quit interruption into a completed capture.
enum RecordingInterruptionReason: String, Sendable, Equatable {
    case systemSleep
    case applicationQuit
    case systemPowerOff
}

enum RecordingSessionFailure: Error, Sendable, Equatable {
    case busy
    case storageRoot(StorageErrorCode)
    case permission(MicrophonePermissionStatus)
    case capture(CaptureErrorCode)
    case recorder(AudioRecorderErrorCode)
    case persistence(StorageErrorCode)
    case recordingStreamEnded
    case invalidRecorderSummary
    case speechModel(STTErrorCode)
    case cancelled
    case interrupted(RecordingInterruptionReason)
    case unknown

    var stableCode: String {
        switch self {
        case .busy: "session.busy"
        case let .storageRoot(code): "root.\(code.rawValue)"
        case let .permission(status): "permission.\(status.rawValue)"
        case let .capture(code): "capture.\(code.rawValue)"
        case let .recorder(code): "recorder.\(code.rawValue)"
        case let .persistence(code): "persistence.\(code.rawValue)"
        case .recordingStreamEnded: "capture.recordingStreamEnded"
        case let .speechModel(code): "model.\(code.rawValue)"
        case .invalidRecorderSummary: "recorder.invalidSummary"
        case .cancelled: "session.cancelled"
        case let .interrupted(reason): "session.interrupted.\(reason.rawValue)"
        case .unknown: "session.unknown"
        }
    }
}

enum RecordingSessionPhase: String, Sendable, Equatable {
    case idle
    case preparing
    case recording
    case paused
    case securing
    case securedAwaitingFinalization
    case interrupted
    case error
}

struct RecordingSessionSnapshot: Sendable, Equatable {
    let phase: RecordingSessionPhase
    let permissionStatus: MicrophonePermissionStatus?
    let sessionID: SessionID?
    let title: String?
    let languageMode: LanguageMode
    let persistedStatus: SessionStatus?
    let recordingStartedAt: AbsoluteTime?
    let elapsedMilliseconds: UInt64
    let microphoneDisplayName: String?
    let normalizedInputLevel: Float
    let noInputWarning: Bool
    let failure: RecordingSessionFailure?
    let persistenceWarningCode: String?
    let catalogWarningCode: CatalogErrorCode?
    let canStart: Bool
    let canStop: Bool
    let canReset: Bool
    var speech: LiveSTTSnapshot = .idle
    var pauseTransitionInFlight = false
    var canPause: Bool { phase == .recording && canStop && !pauseTransitionInFlight }
    var canResume: Bool { phase == .paused && canStop && !pauseTransitionInFlight }

    static func idle(permissionStatus: MicrophonePermissionStatus? = nil) -> RecordingSessionSnapshot {
        RecordingSessionSnapshot(
            phase: .idle,
            permissionStatus: permissionStatus,
            sessionID: nil,
            title: nil,
            languageMode: .korean,
            persistedStatus: nil,
            recordingStartedAt: nil,
            elapsedMilliseconds: 0,
            microphoneDisplayName: nil,
            normalizedInputLevel: 0,
            noInputWarning: false,
            failure: nil,
            persistenceWarningCode: nil,
            catalogWarningCode: nil,
            canStart: true,
            canStop: false,
            canReset: false
        )
    }
}

struct RecordingSessionSecuredResult: Sendable, Equatable {
    let location: SessionLocation
    let metadata: SessionMetadataDocument
    let recorderSummary: AudioRecorderSummary
}

enum RecordingSessionResult: Sendable, Equatable {
    case secured(RecordingSessionSecuredResult)
    case interrupted(RecordingSessionFailure)
    case error(RecordingSessionFailure)
}

protocol RecordingSessionCoordinating: Sendable {
    func snapshots() async -> AsyncStream<RecordingSessionSnapshot>
    func currentSnapshot() async -> RecordingSessionSnapshot
    func refreshPermissionStatus() async
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot
    func pause() async throws
    func resume() async throws
    func stop() async -> RecordingSessionResult
    func interrupt(_ reason: RecordingInterruptionReason) async -> RecordingSessionResult
    func recordSystemWakeIfApplicable() async
    func reset() async
    func essentialSaveEvidence() async -> EssentialTerminationSaveResult?
    func interruptForLifecycle(_ reason: RecordingInterruptionReason, admission: UInt64?) async -> RecordingSessionResult
    func invalidatePendingStart(_ reason: RecordingInterruptionReason, admission: UInt64?) async
    func settleFinalizationHandoffs() async
    func waitForSpeech(at location: SessionLocation) async
}

extension RecordingSessionCoordinating {
    func pause() async throws { throw RecordingSessionFailure.busy }
    func resume() async throws { throw RecordingSessionFailure.busy }
    func essentialSaveEvidence() async -> EssentialTerminationSaveResult? { nil }
    func interruptForLifecycle(_ reason: RecordingInterruptionReason, admission: UInt64?) async -> RecordingSessionResult { await interrupt(reason) }
    func invalidatePendingStart(_ reason: RecordingInterruptionReason, admission: UInt64?) async {}
    func settleFinalizationHandoffs() async {}
    func waitForSpeech(at location: SessionLocation) async {}
}

actor RecordingSessionCoordinator: RecordingSessionCoordinating {
    private struct ActiveSession {
        let token: UInt64
        let location: SessionLocation
        let activityReservation: SessionActivityReservation?
        let title: String
        let languageMode: LanguageMode
        let createdAt: AbsoluteTime
        let recorder: any AudioRecorder
        var metadata: SessionMetadataDocument
        var captureHandle: CaptureHandle?
        var captureStopIssued = false
        var captureStopTask: Task<Void, Never>?
        var recorderStarted = false
        var recordingStartedAt: AbsoluteTime?
        var recordingStartedMonotonic: TimeInterval?
        var stopRequestedMonotonic: TimeInterval?
        var startedDurably = false
        var expectedStop = false
        var cancellationRequested = false
        var firstFailure: RecordingSessionFailure?
        var persistenceWarningCode: String?
        var operationalFailure: RecordingSessionFailure?
        var settlementWarnings: [String] = []
        var terminalMetadataWritten = false
        var catalogWarningCode: CatalogErrorCode?
        var lastMediaPositionMilliseconds: UInt64 = 0
        var noInputEpisode = 0
        var noInputActive = false
        var eventKeys: Set<String> = []
        var primaryPumpDrainAuthorized = false
        var primaryPumpStartWaiters: [CheckedContinuation<Bool, Never>] = []
        var appendedChunks: UInt64 = 0
        var pumpEnded = false
        var cutoffWaiters: [(UInt64, CheckedContinuation<Bool, Never>)] = []
        var isPaused = false
        var pauseEpoch: UInt64 = 0
        var pauseCutoff: UInt64?
        var elapsedBaseMilliseconds: UInt64 = 0
        var resumedMonotonic: TimeInterval?
        var signalAcceptAfter: TimeInterval = 0
        var pumpTask: Task<PumpOutcome, Never>?
        var captureEventTask: Task<Void, Never>?
        var recorderEventTask: Task<Void, Never>?
        var inputLevelTask: Task<Void, Never>?
        var elapsedTask: Task<Void, Never>?
    }

    private enum PumpOutcome: Sendable, Equatable {
        case drained
        case failed(RecordingSessionFailure)
    }

    private struct StartOperation {
        let token: UInt64
        let task: Task<Result<RecordingSessionSnapshot, RecordingSessionFailure>, Never>
    }

    private struct SettlementOperation {
        let token: UInt64
        let task: Task<RecordingSessionResult, Never>
    }

    private let roots: any RecordingStorageRootChecking
    private let permission: any MicrophonePermissionAuthorizing
    private let capture: any MicrophoneCapturing
    private let recorders: any AudioRecorderMaking
    private let repository: any SessionRepository
    private let catalog: any RecordingCatalogRefreshing
    private let clock: RecordingSessionClock
    private let ticker: any RecordingTicking
    private let makeSpeechModel: (@Sendable () throws -> RecordingSpeechModel)?
    private let makeSelectedSpeechModel: (@Sendable (ModelPackageDescriptor) throws -> RecordingSpeechModel)?
    private let prepareCapture: @Sendable () async -> Void
    private var speechModel: RecordingSpeechModel?
    private let makeSpeechConverter: (@Sendable () -> any SpeechPCMConverting)?
    private var speechOwnsModel = false
    private var speechJobs: [SessionID: LiveSTTCoordinator] = [:]
    private var speechSettlements: [SessionID: Task<Void, Never>] = [:]
    private var speechSnapshot = LiveSTTSnapshot.idle
    private var modelLoad: Task<Void, Error>?
    private let environment: RecordingSessionEnvironment
    private let identifiers: RecordingSessionIdentifiers
    private let onSettlementJoin: @Sendable () -> Void
    private let authority: LifecycleWorkAuthority?
    private var workLease: UUID?
    private var saveEvidence: EssentialTerminationSaveResult?
    private let activity: SessionActivityRegistry?

    private var nextToken: UInt64 = 0
    private var active: ActiveSession?
    private var startOperation: StartOperation?
    private var settlementOperation: SettlementOperation?
    private var pauseTransition: Task<Result<Void, RecordingSessionFailure>, Never>?
    private var cancelledStartTokens: Set<UInt64> = []
    /// An interruption is a durable policy decision for a start attempt.  It
    /// must be recorded before awaiting the start task: the task can be
    /// suspended before `active` exists, then otherwise succeed and leave a
    /// live recorder behind after sleep/quit has already been accepted.
    private var startInterruptionFailures: [UInt64: RecordingSessionFailure] = [:]
    private var snapshot = RecordingSessionSnapshot.idle()
    private var snapshotContinuations: [UUID: AsyncStream<RecordingSessionSnapshot>.Continuation] = [:]
    private var lastResult: RecordingSessionResult?
    private var interruptedWakeLocation: SessionLocation?
    private var interruptedWakePosition: UInt64 = 0
    private var systemWakeRecorded = false

    init(
        roots: any RecordingStorageRootChecking,
        permission: any MicrophonePermissionAuthorizing,
        capture: any MicrophoneCapturing,
        recorders: any AudioRecorderMaking,
        repository: any SessionRepository,
        catalog: any RecordingCatalogRefreshing,
        clock: RecordingSessionClock = .live,
        ticker: any RecordingTicking = SystemRecordingTicker(),
        environment: RecordingSessionEnvironment,
        makeSpeechModel: (@Sendable () throws -> RecordingSpeechModel)? = nil,
        makeSelectedSpeechModel: (@Sendable (ModelPackageDescriptor) throws -> RecordingSpeechModel)? = nil,
        prepareCapture: @escaping @Sendable () async -> Void = {},
        makeSpeechConverter: (@Sendable () -> any SpeechPCMConverting)? = nil,
        identifiers: RecordingSessionIdentifiers = .live,
        activity: SessionActivityRegistry? = nil,
        authority: LifecycleWorkAuthority? = nil,
        onSettlementJoin: @escaping @Sendable () -> Void = {}
    ) {
        self.roots = roots
        self.permission = permission
        self.capture = capture
        self.recorders = recorders
        self.repository = repository
        self.catalog = catalog
        self.clock = clock
        self.ticker = ticker
        self.makeSpeechModel = makeSpeechModel
        self.makeSelectedSpeechModel = makeSelectedSpeechModel
        self.prepareCapture = prepareCapture
        self.makeSpeechConverter = makeSpeechConverter
        self.environment = environment
        self.identifiers = identifiers
        self.activity = activity
        self.authority = authority
        self.onSettlementJoin = onSettlementJoin
    }

    func snapshots() -> AsyncStream<RecordingSessionSnapshot> {
        let id = UUID()
        let pair = AsyncStream<RecordingSessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshotContinuations[id] = pair.continuation
        pair.continuation.yield(snapshot)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotContinuation(id) }
        }
        return pair.stream
    }

    func currentSnapshot() -> RecordingSessionSnapshot { snapshot }
    func essentialSaveEvidence() async -> EssentialTerminationSaveResult? { saveEvidence }

    func refreshPermissionStatus() async {
        guard startOperation == nil, settlementOperation == nil else { return }
        let status = await permission.authorizationStatus()
        guard startOperation == nil, settlementOperation == nil else { return }
        snapshot = replacingSnapshot(permissionStatus: status)
        publishSnapshot()
    }

    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot {
        guard startOperation == nil, settlementOperation == nil, pauseTransition == nil, active == nil,
              speechSnapshot.phase == .idle || speechSnapshot.cleanupComplete else {
            throw RecordingSessionFailure.busy
        }
        let incremented = nextToken.addingReportingOverflow(1)
        guard !incremented.overflow else { throw RecordingSessionFailure.busy }
        workLease = authority?.admit()
        speechSnapshot = .idle
        saveEvidence = nil
        nextToken = incremented.partialValue
        let token = nextToken
        lastResult = nil
        snapshot = RecordingSessionSnapshot(
            phase: .preparing,
            permissionStatus: snapshot.permissionStatus,
            sessionID: nil,
            title: nil,
            languageMode: configuration.languageMode,
            persistedStatus: nil,
            recordingStartedAt: nil,
            elapsedMilliseconds: 0,
            microphoneDisplayName: nil,
            normalizedInputLevel: 0,
            noInputWarning: false,
            failure: nil,
            persistenceWarningCode: nil,
            catalogWarningCode: nil,
            canStart: false,
            canStop: false,
            canReset: false
        )
        publishSnapshot()

        let task = Task { await self.performStart(configuration, token: token) }
        startOperation = StartOperation(token: token, task: task)
        let coordinator = self
        let result = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            Task { await coordinator.cancelStartAttempt(token: token, allowsEstablishedRecordingStop: false) }
        })
        if startOperation?.token == token { startOperation = nil }
        cancelledStartTokens.remove(token)
        startInterruptionFailures[token] = nil
        switch result {
        case let .success(value): return value
        case let .failure(failure):
            if let workLease { authority?.release(workLease); self.workLease = nil }
            throw failure
        }
    }

    func pause() async throws { try await changePauseState(to: true) }
    func resume() async throws { try await changePauseState(to: false) }

    private func changePauseState(to paused: Bool) async throws {
        guard startOperation == nil, settlementOperation == nil, pauseTransition == nil,
              let session = active, session.startedDurably, !session.expectedStop,
              session.firstFailure == nil, session.isPaused != paused else { throw RecordingSessionFailure.busy }
        // App-owned work survives a caller/view task cancellation. Stop can close
        // capture immediately, then joins this writer before terminal persistence.
        let task = Task { await self.performPauseTransition(to: paused, token: session.token) }
        pauseTransition = task
        publishSnapshot()
        let result = await task.value
        pauseTransition = nil
        publishSnapshot()
        try result.get()
    }

    private func performPauseTransition(to paused: Bool, token: UInt64) async -> Result<Void, RecordingSessionFailure> {
        do {
            guard let session = active, session.token == token, !session.expectedStop else { return .failure(.busy) }
            let position: UInt64
            if paused {
                let boundary: CapturePauseBoundary
                do { boundary = try await capture.pause() }
                catch { throw Self.captureFailure(error) }
                guard active?.token == token else { return .failure(.cancelled) }
                active?.isPaused = true
                active?.pauseEpoch = boundary.epoch
                active?.pauseCutoff = boundary.recordingChunkCount
                position = boundary.mediaMilliseconds
                active?.elapsedBaseMilliseconds = position
                active?.resumedMonotonic = nil
                active?.lastMediaPositionMilliseconds = position
            } else {
                do { try await capture.resume() }
                catch { throw Self.captureFailure(error) }
                guard active?.token == token else { return .failure(.cancelled) }
                position = active?.elapsedBaseMilliseconds ?? 0
                active?.isPaused = false
                active?.resumedMonotonic = clock.monotonicNow()
            }
            let occurredAt = clock.wallNow()
            active?.noInputActive = false
            active?.signalAcceptAfter = clock.monotonicNow()
            snapshot = replacingSnapshot(elapsedMilliseconds: position, normalizedInputLevel: 0, noInputWarning: false)
            publishSnapshot()
            if paused {
                // capture.pause returned an atomic count of the accepted prefix.
                // Joining that prefix (not STT) makes flush independent of actor scheduling.
                guard await waitForPauseCutoff(token: token) else {
                    throw active?.firstFailure ?? RecordingSessionFailure.recordingStreamEnded
                }
                do { try await session.recorder.flush() }
                catch { throw Self.recorderFailure(error) }
            }
            guard let current = active, current.token == token else { return .failure(.cancelled) }
            if let failure = current.firstFailure { throw failure }
            do {
                let metadata = try makeMetadata(sessionID: current.location.sessionID, title: current.title,
                    status: paused ? .paused : .recording, outcome: .inProgress, createdAt: current.createdAt,
                    startedAt: current.recordingStartedAt, endedAt: nil, durationMilliseconds: position,
                    languageMode: current.languageMode, audio: current.metadata.audio, updatedAt: occurredAt)
                try await repository.writeMetadata(metadata, at: current.location)
                active?.metadata = metadata
                try await appendEventOnce(key: "pause.\(current.pauseEpoch).\(paused)",
                    kind: paused ? .recordingPaused : .recordingResumed, detailCode: nil,
                    occurredAt: occurredAt, mediaPositionMilliseconds: position, token: token)
            } catch { throw Self.persistenceFailure(error) }
            if active?.expectedStop == false, active?.firstFailure == nil, settlementOperation == nil {
                snapshot = replacingSnapshot(phase: paused ? .paused : .recording,
                    persistedStatus: paused ? .paused : .recording, elapsedMilliseconds: position)
                publishSnapshot()
            }
            return .success(())
        } catch {
            let failure = (error as? RecordingSessionFailure) ?? .unknown
            // Closing input for an already admitted Stop can win the gate call.
            // It does not turn a normal user stop into an operational error.
            if failure == .capture(.startInterrupted), active?.expectedStop == true, active?.firstFailure == nil {
                return .failure(.busy)
            }
            requestAbnormalSettlement(token: token, failure: failure)
            return .failure(failure)
        }
    }

    private func waitForPauseCutoff(token: UInt64) async -> Bool {
        guard let session = active, session.token == token, let cutoff = session.pauseCutoff else { return false }
        if session.appendedChunks >= cutoff { return true }
        if session.pumpEnded { return false }
        return await withCheckedContinuation { active?.cutoffWaiters.append((cutoff, $0)) }
    }

    private func resolveCutoffWaiters(token: UInt64, ended: Bool = false) {
        guard active?.token == token else { return }
        if ended { active?.pumpEnded = true }
        let count = active?.appendedChunks ?? 0
        let waiters = active?.cutoffWaiters ?? []
        active?.cutoffWaiters = waiters.filter { $0.0 > count && !ended }
        for (cutoff, waiter) in waiters where cutoff <= count || ended { waiter.resume(returning: cutoff <= count) }
    }

    func stop() async -> RecordingSessionResult {
        if let operation = settlementOperation {
            return await operation.task.value
        }
        if let operation = startOperation {
            await cancelStartAttempt(token: operation.token, allowsEstablishedRecordingStop: true)
            _ = await operation.task.value
            return lastResult ?? .error(active?.firstFailure ?? .cancelled)
        }
        guard let active else {
            return lastResult ?? .error(.busy)
        }
        return await beginSettlement(token: active.token, expectedUserStop: true)
    }

    func interruptForLifecycle(_ reason: RecordingInterruptionReason, admission: UInt64?) async -> RecordingSessionResult {
        guard admission == authority?.state().generation else { return .error(.busy) }
        return await interrupt(reason)
    }

    func interrupt(_ reason: RecordingInterruptionReason) async -> RecordingSessionResult {
        if let operation = settlementOperation {
            onSettlementJoin()
            // A normal Stop has already acquired the terminal transition.  Its
            // completed outcome is authoritative and may not be rewritten.
            return await operation.task.value
        }
        if let operation = startOperation {
            let interruption = RecordingSessionFailure.interrupted(reason)
            // First interruption wins.  This is deliberately set even before
            // an ActiveSession exists, so every later start await observes it.
            if startInterruptionFailures[operation.token] == nil {
                startInterruptionFailures[operation.token] = interruption
                cancelledStartTokens.insert(operation.token)
                modelLoad?.cancel()
            }
            if active?.token == operation.token {
                requestAbnormalSettlement(token: operation.token,
                                          failure: startInterruptionFailures[operation.token] ?? interruption)
            }
            _ = await operation.task.value
            if let settlement = settlementOperation { return await settlement.task.value }
            return lastResult ?? .error(startInterruptionFailures[operation.token] ?? interruption)
        }
        guard let active else { return lastResult ?? .error(.busy) }
        requestAbnormalSettlement(token: active.token, failure: .interrupted(reason))
        guard let settlement = settlementOperation else { return lastResult ?? .error(.interrupted(reason)) }
        return await settlement.task.value
    }

    func recordSystemWakeIfApplicable() async {
        guard let location = interruptedWakeLocation, !systemWakeRecorded else { return }
        do {
            let event = try SessionEventRecord(sessionId: location.sessionID, eventId: identifiers.eventID(),
                                               occurredAt: clock.wallNow(), kind: .systemWake,
                                               mediaPositionMs: try MediaMilliseconds(Int64(clamping: interruptedWakePosition)),
                                               detail: try SessionEventDetail(code: "systemWake"))
            try await repository.appendEvent(event, at: location)
            systemWakeRecorded = true
        } catch {
            // Wake diagnostics are best effort.  Recovery MOV and the first
            // terminal failure remain authoritative.
        }
    }

    func reset() async {
        guard startOperation == nil, settlementOperation == nil, pauseTransition == nil, active == nil,
              speechSnapshot.phase == .idle || speechSnapshot.cleanupComplete else { return }
        // A new recording must not load another large model while old speech
        // inference is still active. Ordinary reset never discards pending finals.
        for job in Array(speechJobs.values) { await job.waitUntilSettled() }
        guard startOperation == nil, settlementOperation == nil, active == nil else { return }
        let permissionStatus = snapshot.permissionStatus
        speechSnapshot = .idle
        snapshot = .idle(permissionStatus: permissionStatus)
        lastResult = nil
        publishSnapshot()
    }

    private func performStart(
        _ configuration: RecordingStartConfiguration,
        token: UInt64
    ) async -> Result<RecordingSessionSnapshot, RecordingSessionFailure> {
        var reservation: SessionActivityReservation?
        do {
            // Preview cleanup is inside the owned start operation. Sleep/quit
            // can invalidate this admission while cleanup suspends.
            await prepareCapture()
            try ensureStartMayContinue(token)
            for job in Array(speechJobs.values) { await job.waitUntilSettled() }
            try ensureStartMayContinue(token)
            let availableRoot: StorageRootSummary
            switch await roots.availability() {
            case let .available(summary, _): availableRoot = summary
            case .noRootSelected: throw RecordingSessionFailure.storageRoot(.noActiveRoot)
            case .reauthorizationRequired: throw RecordingSessionFailure.storageRoot(.reauthorizationRequired)
            case let .failed(code): throw RecordingSessionFailure.storageRoot(code)
            }
            try ensureStartMayContinue(token)
            reservation = await activity?.reserveRecordingCreation(rootID: availableRoot.id)

            var permissionStatus = await permission.authorizationStatus()
            try ensureStartMayContinue(token)
            if permissionStatus == .notDetermined {
                permissionStatus = await permission.requestAuthorization()
                try ensureStartMayContinue(token)
            }
            snapshot = replacingSnapshot(permissionStatus: permissionStatus)
            publishSnapshot()
            guard permissionStatus == .authorized else {
                throw RecordingSessionFailure.permission(permissionStatus)
            }

            if makeSpeechModel != nil || configuration.modelDescriptor != nil {
                do {
                    let model: RecordingSpeechModel
                    if let selected = configuration.modelDescriptor {
                        guard let makeSelectedSpeechModel else { throw STTEngineError(.unsupportedModel) }
                        model = try makeSelectedSpeechModel(selected)
                    } else {
                        guard let makeSpeechModel else { throw STTEngineError(.unsupportedModel) }
                        model = try makeSpeechModel()
                    }
                    speechModel = model
                    let load = Task { try await model.engine.load(model.configuration) }
                    modelLoad = load
                    defer { modelLoad = nil }
                    try await load.value
                } catch {
                    try ensureStartMayContinue(token)
                    throw RecordingSessionFailure.speechModel((error as? STTEngineError)?.code ?? .loadFailed)
                }
                try ensureStartMayContinue(token)
            }

            let createdAt = clock.wallNow()
            let sessionID = identifiers.sessionID()
            let title = Self.normalizedTitle(configuration.title, createdAt: createdAt, timeZone: configuration.timeZone)
            let location: SessionLocation
            do {
                location = try await repository.createSession(
                    sessionID: sessionID,
                    createdAt: createdAt,
                    timeZone: configuration.timeZone
                )
            } catch {
                throw Self.persistenceFailure(error)
            }
            if let reservation, await activity?.promoteRecording(reservation, at: location) != true {
                throw RecordingSessionFailure.cancelled
            }
            let targetAudio = try Self.audioDescription(for: .recoveryAAC)
            let preparing = try makeMetadata(
                sessionID: sessionID,
                title: title,
                status: .preparing,
                outcome: .notStarted,
                createdAt: createdAt,
                startedAt: nil,
                endedAt: nil,
                durationMilliseconds: 0,
                languageMode: configuration.languageMode,
                audio: targetAudio,
                updatedAt: createdAt
            )
            do {
                try ensureStartMayContinue(token)
            } catch let failure as RecordingSessionFailure {
                await persistUnownedStartFailure(
                    location: location,
                    preparing: preparing
                )
                throw failure
            }
            guard location.rootID == availableRoot.id else {
                let failure = RecordingSessionFailure.storageRoot(.noActiveRoot)
                await persistUnownedStartFailure(
                    location: location,
                    preparing: preparing
                )
                throw failure
            }
            active = ActiveSession(
                token: token,
                location: location,
                activityReservation: reservation,
                title: title,
                languageMode: configuration.languageMode,
                createdAt: createdAt,
                recorder: recorders.makeRecorder(),
                metadata: preparing
            )
            // From this point settlement owns release (or T08 hand-off).
            reservation = nil
            snapshot = RecordingSessionSnapshot(
                phase: .preparing,
                permissionStatus: permissionStatus,
                sessionID: sessionID,
                title: title,
                languageMode: configuration.languageMode,
                persistedStatus: nil,
                recordingStartedAt: nil,
                elapsedMilliseconds: 0,
                microphoneDisplayName: nil,
                normalizedInputLevel: 0,
                noInputWarning: false,
                failure: nil,
                persistenceWarningCode: nil,
                catalogWarningCode: nil,
                canStart: false,
                canStop: false,
                canReset: false
            )
            publishSnapshot()

            try await writeMetadata(preparing, token: token)
            try ensureStartMayContinue(token)

            let handle: CaptureHandle
            do { handle = try await capture.start() }
            catch { throw Self.captureFailure(error) }
            try ensureStartMayContinue(token)
            active?.captureHandle = handle

            guard let recorder = active?.recorder else { throw RecordingSessionFailure.cancelled }
            do { try await recorder.start(at: location, expectedCaptureGeneration: handle.generation) }
            catch { throw Self.recorderFailure(error) }
            active?.recorderStarted = true
            // This must stay directly after `recorder.start`: capture may already have accepted
            // PCM while writer start was suspended, and settlement must be able to drain it even
            // when a stop, caller cancellation, or terminal capture failure has already won.
            startPrimaryPCMPump(handle: handle, recorder: recorder, token: token)
            try ensureStartMayContinue(token)
            let captureLifecycle = await capture.currentLifecycle()
            try ensureStartMayContinue(token)
            switch captureLifecycle {
            case .running:
                break
            case let .failed(code):
                throw RecordingSessionFailure.capture(code)
            case .idle, .starting, .stopping:
                throw RecordingSessionFailure.capture(.startInterrupted)
            }

            authorizePrimaryPumpDrain(token: token)
            startObservers(handle: handle, recorder: recorder, token: token)
            let startedAt = clock.wallNow()
            let startedMonotonic = clock.monotonicNow()
            active?.recordingStartedAt = startedAt
            active?.recordingStartedMonotonic = startedMonotonic

            let recording = try makeMetadata(
                sessionID: sessionID,
                title: title,
                status: .recording,
                outcome: .inProgress,
                createdAt: createdAt,
                startedAt: startedAt,
                endedAt: nil,
                durationMilliseconds: 0,
                languageMode: configuration.languageMode,
                audio: targetAudio,
                updatedAt: startedAt
            )
            try await writeMetadata(recording, token: token)
            try ensureStartMayContinue(token)
            try await appendEventOnce(
                key: "recordingStarted",
                kind: .recordingStarted,
                detailCode: nil,
                occurredAt: startedAt,
                mediaPositionMilliseconds: 0,
                token: token
            )
            // Once the start event is durable, a terminal observed while that append was
            // suspended must finish as an interrupted recording rather than as a not-started
            // setup failure. There is no suspension between this ownership transition and the
            // following first-failure check.
            active?.startedDurably = true
            try ensureStartMayContinue(token)
            await startSpeech(handle: handle, location: location, language: configuration.languageMode)
            try ensureStartMayContinue(token)
            snapshot = RecordingSessionSnapshot(
                phase: .recording,
                permissionStatus: permissionStatus,
                sessionID: sessionID,
                title: title,
                languageMode: configuration.languageMode,
                persistedStatus: .recording,
                recordingStartedAt: startedAt,
                elapsedMilliseconds: 0,
                microphoneDisplayName: handle.device.displayName,
                normalizedInputLevel: 0,
                noInputWarning: false,
                failure: nil,
                persistenceWarningCode: active?.persistenceWarningCode,
                catalogWarningCode: nil,
                canStart: false,
                canStop: true,
                canReset: false
            )
            publishSnapshot()
            return .success(snapshot)
        } catch let failure as RecordingSessionFailure {
            if let reservation { await activity?.release(reservation) }
            let returnedFailure = resolvedStartFailure(failure, token: token)
            await failStart(token: token, failure: returnedFailure)
            return .failure(returnedFailure)
        } catch {
            if let reservation { await activity?.release(reservation) }
            let failure = RecordingSessionFailure.unknown
            let returnedFailure = resolvedStartFailure(failure, token: token)
            await failStart(token: token, failure: returnedFailure)
            return .failure(returnedFailure)
        }
    }

    private func resolvedStartFailure(
        _ observedFailure: RecordingSessionFailure,
        token: UInt64
    ) -> RecordingSessionFailure {
        guard let firstFailure = active?.firstFailure, active?.token == token else {
            return observedFailure
        }
        guard firstFailure != observedFailure else { return firstFailure }
        if case .persistence = observedFailure {
            // A gated required start write can fail after a capture/recorder/cancellation terminal
            // has already won. The terminal reason remains the public session result; retain the
            // persistence fault independently for diagnostics rather than returning it from start.
            notePersistenceWarning(observedFailure, token: token)
        }
        return firstFailure
    }

    private func failStart(token: UInt64, failure: RecordingSessionFailure) async {
        guard active?.token == token else {
            await unloadSpeechModel()
            snapshot = errorSnapshot(failure: failure, phase: .error)
            lastResult = .error(failure)
            publishSnapshot()
            return
        }
        registerFailure(failure, token: token)
        _ = await beginSettlement(token: token, expectedUserStop: false)
    }

    private func unloadSpeechModel() async {
        let model = speechModel
        speechModel = nil
        if !speechOwnsModel { await model?.engine.unload() }
        speechOwnsModel = false
    }

    private func startSpeech(handle: CaptureHandle, location: SessionLocation, language: LanguageMode) async {
        guard let model = speechModel, let makeSpeechConverter else { return }
        let session = STTSessionConfiguration(sessionID: location.sessionID, operationID: .init(UUID()),
            model: model.configuration, languageMode: language)
        let job = LiveSTTCoordinator(engine: model.engine, session: session, repository: repository,
            location: location, converter: makeSpeechConverter()) { [weak self] value in
                await self?.receiveSpeech(value, sessionID: location.sessionID)
            }
        speechOwnsModel = true
        speechSnapshot = .idle
        speechJobs[location.sessionID] = job
        let lease = authority?.admit(invalidating: false)
        let authority = authority
        await job.start(handle)
        Task {
            await job.waitUntilSettled()
            if let lease { authority?.release(lease) }
        }
    }

    private func receiveSpeech(_ value: LiveSTTSnapshot, sessionID: SessionID) {
        guard snapshot.sessionID == sessionID else { return }
        speechSnapshot = value
        publishSnapshot()
    }

    func settleFinalizationHandoffs() async {
        // The wrapper invokes this before joining its T08/STT handoff tasks.
        for job in Array(speechJobs.values) { await job.cancel() }
    }

    func waitForSpeech(at location: SessionLocation) async {
        if let pending = speechSettlements[location.sessionID] { await pending.value; return }
        guard let job = speechJobs[location.sessionID] else { return }
        let task = Task { await self.persistSettledSpeech(job, at: location) }
        speechSettlements[location.sessionID] = task
        await task.value
        speechSettlements[location.sessionID] = nil
    }

    func settleSpeechForTranscript(at location: SessionLocation, control: AudioFinalizationControl) async throws {
        // Do not park the finalization queue on a full STT backlog during quit:
        // lifecycle cancels this optional wait before cancelling/joining STT.
        while let job = speechJobs[location.sessionID] {
            try control.check()
            if await job.currentSnapshot().cleanupComplete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try control.check()
        await waitForSpeech(at: location)
        try control.check()
    }

    private func persistSettledSpeech(_ job: LiveSTTCoordinator, at location: SessionLocation) async {
        await job.waitUntilSettled()
        let value = await job.currentSnapshot()
        // Called after T08 is settled while the shared activity reservation is
        // still held. No read-modify-write races with audio finalization/recovery.
        do {
            let old = try await repository.readMetadata(at: location)
            let updated = try SessionMetadataDocument(schemaVersion: old.schemaVersion, sessionId: old.sessionId,
                title: old.title, status: old.status, captureOutcome: old.captureOutcome, createdAt: old.createdAt,
                recordingStartedAt: old.recordingStartedAt, recordingEndedAt: old.recordingEndedAt,
                activeDurationMs: old.activeDurationMs, languageMode: old.languageMode,
                detectedLanguage: value.language, engine: old.engine, model: old.model,
                modelSettings: old.modelSettings, audio: old.audio, transcript: old.transcript,
                appVersion: old.appVersion, osVersion: old.osVersion, lastUpdatedAt: clock.wallNow())
            try await repository.writeMetadata(updated, at: location)
        } catch {
            if snapshot.sessionID == location.sessionID {
                speechSnapshot.storageWarning = "speechMetadataWriteFailed"
                publishSnapshot()
            }
        }
        speechJobs[location.sessionID] = nil
    }

    private func cancelStartAttempt(token: UInt64, allowsEstablishedRecordingStop: Bool) async {
        guard startOperation?.token == token else { return }
        guard allowsEstablishedRecordingStop || active?.startedDurably != true else { return }
        cancelledStartTokens.insert(token)
        modelLoad?.cancel()
        guard active?.token == token else { return }
        if active?.startedDurably != true {
            registerFailure(.cancelled, token: token)
        }
        active?.cancellationRequested = true
        requestCaptureStop(token: token)
        await waitForCaptureStop(token: token)
    }

    private func persistUnownedStartFailure(
        location: SessionLocation,
        preparing: SessionMetadataDocument
    ) async {
        do {
            let metadata = try makeMetadata(
                sessionID: location.sessionID,
                title: preparing.title,
                status: .error,
                outcome: .notStarted,
                createdAt: preparing.createdAt,
                startedAt: nil,
                endedAt: nil,
                durationMilliseconds: 0,
                languageMode: preparing.languageMode,
                audio: preparing.audio,
                updatedAt: clock.wallNow()
            )
            try await repository.writeMetadata(metadata, at: location)
        } catch {
            // The created folder and last durable bytes remain authoritative. The initiating
            // failure is deliberately not replaced by this best-effort terminal metadata write.
        }
    }

    private func beginSettlement(token: UInt64, expectedUserStop: Bool) async -> RecordingSessionResult {
        if let operation = settlementOperation, operation.token == token {
            return await operation.task.value
        }
        guard active?.token == token else { return lastResult ?? .error(.cancelled) }
        if expectedUserStop {
            active?.expectedStop = true
            active?.stopRequestedMonotonic = clock.monotonicNow()
        }
        snapshot = replacingSnapshot(
            phase: .securing,
            elapsedMilliseconds: currentElapsedMilliseconds(token: token, stopRequested: true),
            canStart: false,
            canStop: false,
            canReset: false
        )
        publishSnapshot()
        let task = Task { await self.performSettlement(token: token) }
        settlementOperation = SettlementOperation(token: token, task: task)
        let result = await task.value
        if settlementOperation?.token == token { settlementOperation = nil }
        return result
    }

    private func requestAbnormalSettlement(token: UInt64, failure: RecordingSessionFailure) {
        guard active?.token == token else { return }
        registerFailure(failure, token: token)
        if active?.startedDurably != true, startOperation?.token == token {
            // `performStart` still owns recording metadata/start-event persistence. Do not run a
            // second terminal writer concurrently; close intake, retain the first failure, and
            // let the start owner hand off through `failStart` after that persistence returns.
            requestCaptureStop(token: token)
            return
        }
        guard settlementOperation == nil else { return }
        snapshot = replacingSnapshot(
            phase: .securing,
            failure: active?.firstFailure,
            canStart: false,
            canStop: false,
            canReset: false
        )
        publishSnapshot()
        let task = Task { await self.performSettlement(token: token) }
        settlementOperation = SettlementOperation(token: token, task: task)
    }

    private func performSettlement(token: UInt64) async -> RecordingSessionResult {
        guard active?.token == token else { return lastResult ?? .error(.cancelled) }
        active?.expectedStop = true
        requestCaptureStop(token: token)
        await waitForCaptureStop(token: token)
        authorizePrimaryPumpDrain(token: token)
        _ = await pauseTransition?.value

        let pumpOutcome = await active?.pumpTask?.value
        if case let .failed(failure) = pumpOutcome {
            registerFailure(failure, token: token)
        }

        var summary: AudioRecorderSummary?
        if active?.recorderStarted == true, let recorder = active?.recorder {
            do { try await recorder.flush() }
            catch { registerFailure(Self.recorderFailure(error), token: token) }
            do { summary = try await recorder.stop() }
            catch { registerFailure(Self.recorderFailure(error), token: token) }
        }

        if case .recorder = active?.firstFailure {
            // T06 publishes one terminal event even for a late subscriber. Consume it before
            // journaling so its stable kind/code/media position cannot lose a race to append/stop.
            await active?.recorderEventTask?.value
        }

        if let summary {
            if validate(summary: summary, token: token) {
                active?.lastMediaPositionMilliseconds = summary.mediaDurationMilliseconds
            } else {
                registerFailure(.invalidRecorderSummary, token: token)
            }
        } else if active?.startedDurably == true, active?.firstFailure == nil {
            registerFailure(.invalidRecorderSummary, token: token)
        }

        if active?.firstFailure != nil, let id = active?.location.sessionID, let job = speechJobs[id] {
            await job.cancel()
            speechJobs[id] = nil
        }
        let result: RecordingSessionResult
        if active?.firstFailure == nil, let summary {
            result = await finishNormally(token: token, summary: summary)
        } else {
            result = await finishAbnormally(token: token, summary: summary)
        }
        if case .secured = result {} else if let id = active?.location.sessionID, let job = speechJobs[id] {
            await job.cancel()
            speechJobs[id] = nil
        }
        if case .secured = result, let reservation = active?.activityReservation {
            _ = await activity?.promoteToFinalization(reservation)
        }
        await stopOwnedTasks(token: token)
        await unloadSpeechModel()
        if case .secured = result {
            // RecordingFinalizationCoordinator now owns release after T08.
        } else if let reservation = active?.activityReservation {
            await activity?.release(reservation)
        }
        if let session = active, session.token == token {
            var warnings = session.settlementWarnings
            if let catalog = session.catalogWarningCode { warnings.append("catalog.\(catalog.rawValue)") }
            saveEvidence = .init(durableRecoveryState: session.terminalMetadataWritten,
                cleanupSettled: true, firstFailure: session.operationalFailure, warnings: warnings,
                requiresUserAttention: session.operationalFailure != nil || !session.terminalMetadataWritten)
            active = nil
        }
        if let workLease { authority?.release(workLease); self.workLease = nil }
        lastResult = result
        publishSnapshot() // observers see settled durability and resource release
        if settlementOperation?.token == token { settlementOperation = nil }
        return result
    }

    private func requestCaptureStop(token: UInt64) {
        guard active?.token == token, active?.captureStopIssued == false else { return }
        active?.captureStopIssued = true
        // Closing intake is intentional even while the start-event write is
        // suspended. Its resulting stream end is not a second operational failure.
        active?.expectedStop = true
        let capture = capture
        active?.captureStopTask = Task { await capture.stop() }
    }

    private func waitForCaptureStop(token: UInt64) async {
        guard active?.token == token else { return }
        requestCaptureStop(token: token)
        let task = active?.captureStopTask
        await task?.value
    }

    private func finishNormally(token: UInt64, summary: AudioRecorderSummary) async -> RecordingSessionResult {
        guard let session = active, session.token == token,
              let startedAt = session.recordingStartedAt else {
            return await finishAbnormally(token: token, summary: summary, forcedFailure: .invalidRecorderSummary)
        }
        let endedAt = clock.wallNow()
        do {
            try await appendEventOnce(
                key: "recordingEnded",
                kind: .recordingEnded,
                detailCode: nil,
                occurredAt: endedAt,
                mediaPositionMilliseconds: summary.mediaDurationMilliseconds,
                token: token
            )
            let metadata = try makeMetadata(
                sessionID: session.location.sessionID,
                title: session.title,
                status: .securing,
                outcome: .completed,
                createdAt: session.createdAt,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMilliseconds: summary.mediaDurationMilliseconds,
                languageMode: session.languageMode,
                audio: try Self.audioDescription(for: summary.outputFormat),
                updatedAt: endedAt
            )
            try await writeMetadata(metadata, token: token)
            active?.terminalMetadataWritten = true
            await refreshCatalogBestEffort(token: token)
            let secured = RecordingSessionSecuredResult(location: session.location, metadata: metadata, recorderSummary: summary)
            snapshot = RecordingSessionSnapshot(
                phase: .securedAwaitingFinalization,
                permissionStatus: snapshot.permissionStatus,
                sessionID: session.location.sessionID,
                title: session.title,
                languageMode: session.languageMode,
                persistedStatus: .securing,
                recordingStartedAt: startedAt,
                elapsedMilliseconds: summary.mediaDurationMilliseconds,
                microphoneDisplayName: session.captureHandle?.device.displayName,
                normalizedInputLevel: 0,
                noInputWarning: false,
                failure: nil,
                persistenceWarningCode: active?.persistenceWarningCode,
                catalogWarningCode: active?.catalogWarningCode,
                canStart: false,
                canStop: false,
                canReset: true
            )
            publishSnapshot()
            return .secured(secured)
        } catch let failure as RecordingSessionFailure {
            registerFailure(failure, token: token)
            return await finishAbnormally(token: token, summary: summary)
        } catch {
            registerFailure(.unknown, token: token)
            return await finishAbnormally(token: token, summary: summary)
        }
    }

    private func finishAbnormally(
        token: UInt64,
        summary: AudioRecorderSummary?,
        forcedFailure: RecordingSessionFailure? = nil
    ) async -> RecordingSessionResult {
        if let forcedFailure { registerFailure(forcedFailure, token: token) }
        guard let session = active, session.token == token else { return .error(forcedFailure ?? .cancelled) }
        let failure = session.firstFailure ?? .unknown
        let endedAt = clock.wallNow()
        let mediaPosition = summary?.mediaDurationMilliseconds ?? session.lastMediaPositionMilliseconds

        await appendFailureEventBestEffort(failure, mediaPosition: mediaPosition, token: token)
        if session.startedDurably {
            do {
                try await appendEventOnce(
                    key: "recordingEnded",
                    kind: .recordingEnded,
                    detailCode: "interrupted.\(failure.stableCode)",
                    occurredAt: endedAt,
                    mediaPositionMilliseconds: mediaPosition,
                    token: token
                )
            } catch {
                notePersistenceWarning(error, token: token)
            }
        }

        let status: SessionStatus = session.startedDurably ? .interrupted : .error
        let outcome: CaptureOutcome = session.startedDurably ? .interrupted : .notStarted
        do {
            let metadata = try makeMetadata(
                sessionID: session.location.sessionID,
                title: session.title,
                status: status,
                outcome: outcome,
                createdAt: session.createdAt,
                startedAt: session.startedDurably ? session.recordingStartedAt : nil,
                endedAt: session.startedDurably ? endedAt : nil,
                durationMilliseconds: mediaPosition,
                languageMode: session.languageMode,
                audio: summary.map { try Self.audioDescription(for: $0.outputFormat) } ?? session.metadata.audio,
                updatedAt: endedAt
            )
            try await repository.writeMetadata(metadata, at: session.location)
            if active?.token == token { active?.metadata = metadata; active?.terminalMetadataWritten = true }
        } catch {
            notePersistenceWarning(error, token: token)
        }
        await refreshCatalogBestEffort(token: token)

        let phase: RecordingSessionPhase = session.startedDurably ? .interrupted : .error
        if session.startedDurably,
           case .interrupted(.systemSleep) = failure {
            interruptedWakeLocation = session.location
            interruptedWakePosition = mediaPosition
            systemWakeRecorded = false
        }
        snapshot = RecordingSessionSnapshot(
            phase: phase,
            permissionStatus: snapshot.permissionStatus,
            sessionID: session.location.sessionID,
            title: session.title,
            languageMode: session.languageMode,
            persistedStatus: status,
            recordingStartedAt: session.startedDurably ? session.recordingStartedAt : nil,
            elapsedMilliseconds: mediaPosition,
            microphoneDisplayName: session.captureHandle?.device.displayName,
            normalizedInputLevel: 0,
            noInputWarning: false,
            failure: active?.operationalFailure ?? failure,
            persistenceWarningCode: active?.persistenceWarningCode,
            catalogWarningCode: active?.catalogWarningCode,
            canStart: false,
            canStop: false,
            canReset: true
        )
        publishSnapshot()
        return session.startedDurably ? .interrupted(failure) : .error(failure)
    }

    private func startPrimaryPCMPump(handle: CaptureHandle, recorder: any AudioRecorder, token: UInt64) {
        let pump = Task { [weak self] in
            guard let self else { return PumpOutcome.failed(.cancelled) }
            return await self.consumeRecordingPCM(handle.recordingPCM, recorder: recorder, token: token)
        }
        guard active?.token == token else {
            pump.cancel()
            return
        }
        active?.pumpTask = pump
    }

    private func authorizePrimaryPumpDrain(token: UInt64) {
        guard active?.token == token, active?.primaryPumpDrainAuthorized == false else { return }
        active?.primaryPumpDrainAuthorized = true
        let waiters = active?.primaryPumpStartWaiters ?? []
        active?.primaryPumpStartWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    private func waitForPrimaryPumpDrainAuthorization(token: UInt64) async -> Bool {
        guard active?.token == token else { return false }
        if active?.primaryPumpDrainAuthorized == true { return true }
        return await withCheckedContinuation { continuation in
            guard active?.token == token else {
                continuation.resume(returning: false)
                return
            }
            if active?.primaryPumpDrainAuthorized == true {
                continuation.resume(returning: true)
            } else {
                active?.primaryPumpStartWaiters.append(continuation)
            }
        }
    }

    private func startObservers(handle: CaptureHandle, recorder: any AudioRecorder, token: UInt64) {
        let captureEvents = Task { [weak self] in
            guard let self else { return }
            for await event in handle.events {
                if Task.isCancelled { break }
                await self.handleCaptureEvent(event, token: token)
            }
        }
        let recorderEvents = Task { [weak self] in
            guard let self else { return }
            let events = await recorder.events()
            for await event in events {
                if Task.isCancelled { break }
                await self.handleRecorderEvent(event, token: token)
                break
            }
        }
        let levels = Task { [weak self] in
            guard let self else { return }
            for await sample in handle.inputSignalStates {
                if Task.isCancelled { break }
                await self.handleInputSignal(sample, token: token)
            }
        }
        let elapsed = Task { [weak self] in
            guard let self else { return }
            for await _ in ticker.ticks() {
                if Task.isCancelled { break }
                await self.handleElapsedTick(token: token)
            }
        }
        active?.captureEventTask = captureEvents
        active?.recorderEventTask = recorderEvents
        active?.inputLevelTask = levels
        active?.elapsedTask = elapsed
    }

    private func consumeRecordingPCM(
        _ stream: AsyncThrowingStream<PCMChunk, Error>,
        recorder: any AudioRecorder,
        token: UInt64
    ) async -> PumpOutcome {
        defer { resolveCutoffWaiters(token: token, ended: true) }
        guard await waitForPrimaryPumpDrainAuthorization(token: token) else {
            return .failed(.cancelled)
        }
        do {
            for try await chunk in stream {
                guard active?.token == token else { return .failed(.cancelled) }
                do { try await recorder.append(chunk) }
                catch {
                    let failure = Self.recorderFailure(error)
                    requestAbnormalSettlement(token: token, failure: failure)
                    return .failed(failure)
                }
                guard active?.token == token else { return .failed(.cancelled) }
                active?.appendedChunks += 1
                resolveCutoffWaiters(token: token)
            }
            guard active?.token == token else { return .failed(.cancelled) }
            if active?.expectedStop == true { return .drained }
            requestAbnormalSettlement(token: token, failure: .recordingStreamEnded)
            return .failed(.recordingStreamEnded)
        } catch {
            let failure = Self.captureFailure(error)
            requestAbnormalSettlement(token: token, failure: failure)
            return .failed(failure)
        }
    }

    private func handleCaptureEvent(_ event: CaptureEvent, token: UInt64) {
        guard active?.token == token else { return }
        switch event {
        case .speechDiscontinuity:
            break
        case let .terminalFailure(code):
            requestAbnormalSettlement(token: token, failure: .capture(code))
        case .stopped:
            if active?.expectedStop != true {
                requestAbnormalSettlement(token: token, failure: .recordingStreamEnded)
            }
        }
    }

    private func handleRecorderEvent(_ event: AudioRecorderEvent, token: UInt64) {
        guard active?.token == token else { return }
        switch event {
        case let .terminalFailure(_, code, mediaPositionMilliseconds):
            if let mediaPositionMilliseconds {
                let priorPosition = active?.lastMediaPositionMilliseconds ?? 0
                active?.lastMediaPositionMilliseconds = max(priorPosition, mediaPositionMilliseconds)
            }
            requestAbnormalSettlement(token: token, failure: .recorder(code))
        }
    }

    private func handleInputSignal(_ sample: InputSignalSample, token: UInt64) async {
        guard active?.token == token,
              sample.generation == active?.captureHandle?.generation,
              active?.isPaused == false, pauseTransition == nil, active?.expectedStop == false,
              sample.monotonicSeconds >= (active?.signalAcceptAfter ?? 0) else { return }
        let noInput = sample.state == .noInput
        snapshot = replacingSnapshot(
            normalizedInputLevel: min(1, max(0, sample.normalizedLevel)),
            noInputWarning: noInput
        )
        publishSnapshot()
        if noInput, active?.noInputActive != true {
            active?.noInputActive = true
            active?.noInputEpisode += 1
            guard active?.startedDurably == true else { return }
            let episode = active?.noInputEpisode ?? 0
            do {
                try await appendEventOnce(
                    key: "noInput.\(episode)",
                    kind: .noInputWarning,
                    detailCode: "capture.noInput",
                    occurredAt: clock.wallNow(),
                    mediaPositionMilliseconds: currentElapsedMilliseconds(token: token, stopRequested: false),
                    token: token
                )
            } catch {
                notePersistenceWarning(error, token: token)
            }
        } else if sample.state == .active {
            active?.noInputActive = false
        }
    }

    private func handleElapsedTick(token: UInt64) {
        guard active?.token == token, snapshot.phase == .recording else { return }
        snapshot = replacingSnapshot(elapsedMilliseconds: currentElapsedMilliseconds(token: token, stopRequested: false))
        publishSnapshot()
    }

    private func stopOwnedTasks(token: UInt64) async {
        guard let session = active, session.token == token else { return }
        let tasks = [session.captureEventTask, session.recorderEventTask, session.inputLevelTask, session.elapsedTask]
        tasks.forEach { $0?.cancel() }
        for task in tasks { await task?.value }
    }

    private func appendFailureEventBestEffort(
        _ failure: RecordingSessionFailure,
        mediaPosition: UInt64,
        token: UInt64
    ) async {
        let mapping = Self.failureEventMapping(failure)
        do {
            try await appendEventOnce(
                key: mapping.key,
                kind: mapping.kind,
                detailCode: failure.stableCode,
                occurredAt: clock.wallNow(),
                mediaPositionMilliseconds: mediaPosition,
                token: token
            )
        } catch {
            notePersistenceWarning(error, token: token)
        }
    }

    private func appendEventOnce(
        key: String,
        kind: SessionEventKind,
        detailCode: String?,
        occurredAt: AbsoluteTime,
        mediaPositionMilliseconds: UInt64?,
        token: UInt64
    ) async throws {
        guard let session = active, session.token == token else { throw RecordingSessionFailure.cancelled }
        guard !session.eventKeys.contains(key) else { return }
        active?.eventKeys.insert(key)
        let detail = try detailCode.map { try SessionEventDetail(code: $0) }
        let media = try mediaPositionMilliseconds.map { try MediaMilliseconds(Int64(clamping: $0)) }
        let event = try SessionEventRecord(
            sessionId: session.location.sessionID,
            eventId: identifiers.eventID(),
            occurredAt: occurredAt,
            kind: kind,
            mediaPositionMs: media,
            detail: detail
        )
        do { try await repository.appendEvent(event, at: session.location) }
        catch { throw Self.persistenceFailure(error) }
        guard active?.token == token else { throw RecordingSessionFailure.cancelled }
    }

    private func writeMetadata(_ metadata: SessionMetadataDocument, token: UInt64) async throws {
        guard let session = active, session.token == token else { throw RecordingSessionFailure.cancelled }
        do { try await repository.writeMetadata(metadata, at: session.location) }
        catch { throw Self.persistenceFailure(error) }
        guard active?.token == token else { throw RecordingSessionFailure.cancelled }
        active?.metadata = metadata
        snapshot = replacingSnapshot(persistedStatus: metadata.status)
        publishSnapshot()
    }

    private func refreshCatalogBestEffort(token: UInt64) async {
        do { _ = try await catalog.reconcile() }
        catch let error as CatalogError {
            if active?.token == token { active?.catalogWarningCode = error.code }
        } catch {
            if active?.token == token { active?.catalogWarningCode = .filesystemScanFailed }
        }
    }

    private func registerFailure(_ failure: RecordingSessionFailure, token: UInt64) {
        guard active?.token == token else { return }
        if active?.firstFailure == nil { active?.firstFailure = failure }
        if case .interrupted = failure { return }
        if active?.operationalFailure == nil { active?.operationalFailure = failure }
        else { active?.settlementWarnings.append(failure.stableCode) }
    }

    private func notePersistenceWarning(_ error: Error, token: UInt64) {
        guard active?.token == token else { return }
        let failure = Self.persistenceFailure(error)
        active?.persistenceWarningCode = failure.stableCode
        registerFailure(failure, token: token)
    }

    private func validate(summary: AudioRecorderSummary, token: UInt64) -> Bool {
        guard let session = active, session.token == token else { return false }
        return summary.location == session.location
            && summary.artifact == .recoveryAudio
            && summary.writtenFrameCount > 0
            && summary.mediaDurationMilliseconds > 0
            && summary.outputFormat == .recoveryAAC
    }

    private func ensureStartMayContinue(_ token: UInt64) throws {
        guard startOperation?.token == token else { throw RecordingSessionFailure.cancelled }
        if let interruption = startInterruptionFailures[token] { throw interruption }
        if active?.token == token, let failure = active?.firstFailure {
            throw failure
        }
        guard !cancelledStartTokens.contains(token) else { throw RecordingSessionFailure.cancelled }
        if active?.token == token {
            if active?.cancellationRequested == true { throw RecordingSessionFailure.cancelled }
        }
    }

    private func currentElapsedMilliseconds(token: UInt64, stopRequested: Bool) -> UInt64 {
        guard let session = active, session.token == token,
              let started = session.recordingStartedMonotonic else { return 0 }
        if session.isPaused { return session.elapsedBaseMilliseconds }
        let end = stopRequested
            ? (session.stopRequestedMonotonic ?? clock.monotonicNow())
            : clock.monotonicNow()
        return session.elapsedBaseMilliseconds + UInt64(max(0, (end - (session.resumedMonotonic ?? started)) * 1_000))
    }

    private func makeMetadata(
        sessionID: SessionID,
        title: String,
        status: SessionStatus,
        outcome: CaptureOutcome,
        createdAt: AbsoluteTime,
        startedAt: AbsoluteTime?,
        endedAt: AbsoluteTime?,
        durationMilliseconds: UInt64,
        languageMode: LanguageMode,
        audio: AudioDescription?,
        updatedAt: AbsoluteTime
    ) throws -> SessionMetadataDocument {
        try SessionMetadataDocument(
            sessionId: sessionID,
            title: title,
            status: status,
            captureOutcome: outcome,
            createdAt: createdAt,
            recordingStartedAt: startedAt,
            recordingEndedAt: endedAt,
            activeDurationMs: MediaMilliseconds(Int64(clamping: durationMilliseconds)),
            languageMode: languageMode,
            detectedLanguage: speechSnapshot.language,
            engine: speechModel?.configuration.engine,
            model: speechModel?.configuration.model,
            modelSettings: speechModel?.settings,
            audio: audio,
            transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)),
            appVersion: environment.appVersion,
            osVersion: environment.osVersion,
            lastUpdatedAt: updatedAt
        )
    }

    private func errorSnapshot(failure: RecordingSessionFailure, phase: RecordingSessionPhase) -> RecordingSessionSnapshot {
        RecordingSessionSnapshot(
            phase: phase,
            permissionStatus: snapshot.permissionStatus,
            sessionID: snapshot.sessionID,
            title: snapshot.title,
            languageMode: snapshot.languageMode,
            persistedStatus: snapshot.persistedStatus,
            recordingStartedAt: snapshot.recordingStartedAt,
            elapsedMilliseconds: snapshot.elapsedMilliseconds,
            microphoneDisplayName: snapshot.microphoneDisplayName,
            normalizedInputLevel: 0,
            noInputWarning: false,
            failure: failure,
            persistenceWarningCode: snapshot.persistenceWarningCode,
            catalogWarningCode: snapshot.catalogWarningCode,
            canStart: snapshot.sessionID == nil,
            canStop: false,
            canReset: snapshot.sessionID != nil
        )
    }

    private func replacingSnapshot(
        phase: RecordingSessionPhase? = nil,
        permissionStatus: MicrophonePermissionStatus?? = nil,
        persistedStatus: SessionStatus?? = nil,
        elapsedMilliseconds: UInt64? = nil,
        normalizedInputLevel: Float? = nil,
        noInputWarning: Bool? = nil,
        failure: RecordingSessionFailure?? = nil,
        canStart: Bool? = nil,
        canStop: Bool? = nil,
        canReset: Bool? = nil
    ) -> RecordingSessionSnapshot {
        RecordingSessionSnapshot(
            phase: phase ?? snapshot.phase,
            permissionStatus: permissionStatus ?? snapshot.permissionStatus,
            sessionID: snapshot.sessionID,
            title: snapshot.title,
            languageMode: snapshot.languageMode,
            persistedStatus: persistedStatus ?? snapshot.persistedStatus,
            recordingStartedAt: snapshot.recordingStartedAt,
            elapsedMilliseconds: elapsedMilliseconds ?? snapshot.elapsedMilliseconds,
            microphoneDisplayName: snapshot.microphoneDisplayName,
            normalizedInputLevel: normalizedInputLevel ?? snapshot.normalizedInputLevel,
            noInputWarning: noInputWarning ?? snapshot.noInputWarning,
            failure: failure ?? snapshot.failure,
            persistenceWarningCode: active?.persistenceWarningCode ?? snapshot.persistenceWarningCode,
            catalogWarningCode: active?.catalogWarningCode ?? snapshot.catalogWarningCode,
            canStart: canStart ?? snapshot.canStart,
            canStop: canStop ?? snapshot.canStop,
            canReset: canReset ?? snapshot.canReset
        )
    }

    private func publishSnapshot() {
        if snapshot.sessionID != nil, [.securedAwaitingFinalization, .interrupted, .error].contains(snapshot.phase) {
            snapshot = replacingSnapshot(canReset: pauseTransition == nil && (speechSnapshot.phase == .idle || speechSnapshot.cleanupComplete))
        }
        snapshot.pauseTransitionInFlight = pauseTransition != nil
        snapshot.speech = speechSnapshot
        snapshotContinuations.values.forEach { $0.yield(snapshot) }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    static func normalizedTitle(_ title: String, createdAt: AbsoluteTime, timeZone: TimeZone) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: createdAt.value)) 녹음"
    }

    private static func audioDescription(for format: AudioRecorderOutputFormat) throws -> AudioDescription {
        try AudioDescription(
            format: "AAC-LC fragmented QuickTime",
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            bitRate: format.targetBitRate
        )
    }

    private static func captureFailure(_ error: Error) -> RecordingSessionFailure {
        if let error = error as? RecordingSessionFailure { return error }
        if let error = error as? CaptureError { return .capture(error.code) }
        if error is CancellationError { return .cancelled }
        return .capture(.runtimeFailure)
    }

    private static func recorderFailure(_ error: Error) -> RecordingSessionFailure {
        if let error = error as? RecordingSessionFailure { return error }
        if let error = error as? AudioRecorderError { return .recorder(error.code) }
        if error is CancellationError { return .recorder(.cancelled) }
        return .recorder(.writerAppendFailed)
    }

    private static func persistenceFailure(_ error: Error) -> RecordingSessionFailure {
        if let error = error as? RecordingSessionFailure { return error }
        if let error = error as? StorageError { return .persistence(error.code) }
        return .persistence(.temporaryWriteFailed)
    }

    private static func failureEventMapping(
        _ failure: RecordingSessionFailure
    ) -> (key: String, kind: SessionEventKind) {
        switch failure {
        case .interrupted(.systemSleep):
            ("systemSleep", .systemSleep)
        case .interrupted(.applicationQuit):
            ("applicationQuit", .applicationTermination)
        case .interrupted(.systemPowerOff):
            ("systemPowerOff", .applicationTermination)
        case let .capture(code) where code == .activeDeviceDisconnected || code == .inputRouteChanged:
            ("microphoneDisconnected.\(code.rawValue)", .microphoneDisconnected)
        case .recorder(.storageAccess), .recorder(.storageRootUnavailable),
             .recorder(.storageReauthorizationRequired), .recorder(.storageRootMissing),
             .recorder(.storageRootNotWritable), .recorder(.unsafeSessionLayout),
             .recorder(.recoveryArtifactExists):
            ("recorder.\(failure.stableCode)", .storageAccessError)
        case .recorder:
            ("recorder.\(failure.stableCode)", .fileWriteError)
        case .storageRoot, .persistence:
            ("storage.\(failure.stableCode)", .storageAccessError)
        default:
            ("abnormal.\(failure.stableCode)", .recordingEnded)
        }
    }
}

extension MicrophoneCaptureController: MicrophoneCapturing {}
