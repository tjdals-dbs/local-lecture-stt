import Foundation

protocol MicrophoneCapturing: Sendable {
    func currentLifecycle() async -> CaptureLifecycle
    func start() async throws -> CaptureHandle
    func stop() async
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

    init(title: String, languageMode: LanguageMode = .korean, timeZone: TimeZone) {
        self.title = title
        self.languageMode = languageMode
        self.timeZone = timeZone
    }
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
    case cancelled
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
        case .invalidRecorderSummary: "recorder.invalidSummary"
        case .cancelled: "session.cancelled"
        case .unknown: "session.unknown"
        }
    }
}

enum RecordingSessionPhase: String, Sendable, Equatable {
    case idle
    case preparing
    case recording
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
    func stop() async -> RecordingSessionResult
    func reset() async
}

actor RecordingSessionCoordinator: RecordingSessionCoordinating {
    private struct ActiveSession {
        let token: UInt64
        let location: SessionLocation
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
        var catalogWarningCode: CatalogErrorCode?
        var lastMediaPositionMilliseconds: UInt64 = 0
        var noInputEpisode = 0
        var noInputActive = false
        var eventKeys: Set<String> = []
        var primaryPumpDrainAuthorized = false
        var primaryPumpStartWaiters: [CheckedContinuation<Bool, Never>] = []
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
    private let environment: RecordingSessionEnvironment
    private let identifiers: RecordingSessionIdentifiers

    private var nextToken: UInt64 = 0
    private var active: ActiveSession?
    private var startOperation: StartOperation?
    private var settlementOperation: SettlementOperation?
    private var cancelledStartTokens: Set<UInt64> = []
    private var snapshot = RecordingSessionSnapshot.idle()
    private var snapshotContinuations: [UUID: AsyncStream<RecordingSessionSnapshot>.Continuation] = [:]
    private var lastResult: RecordingSessionResult?

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
        identifiers: RecordingSessionIdentifiers = .live
    ) {
        self.roots = roots
        self.permission = permission
        self.capture = capture
        self.recorders = recorders
        self.repository = repository
        self.catalog = catalog
        self.clock = clock
        self.ticker = ticker
        self.environment = environment
        self.identifiers = identifiers
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

    func refreshPermissionStatus() async {
        guard startOperation == nil, settlementOperation == nil else { return }
        let status = await permission.authorizationStatus()
        guard startOperation == nil, settlementOperation == nil else { return }
        snapshot = replacingSnapshot(permissionStatus: status)
        publishSnapshot()
    }

    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot {
        guard startOperation == nil, settlementOperation == nil, active == nil else {
            throw RecordingSessionFailure.busy
        }
        let incremented = nextToken.addingReportingOverflow(1)
        guard !incremented.overflow else { throw RecordingSessionFailure.busy }
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
        switch result {
        case let .success(value): return value
        case let .failure(failure): throw failure
        }
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

    func reset() async {
        guard startOperation == nil, settlementOperation == nil, active == nil else { return }
        let permissionStatus = snapshot.permissionStatus
        snapshot = .idle(permissionStatus: permissionStatus)
        lastResult = nil
        publishSnapshot()
    }

    private func performStart(
        _ configuration: RecordingStartConfiguration,
        token: UInt64
    ) async -> Result<RecordingSessionSnapshot, RecordingSessionFailure> {
        do {
            let availableRoot: StorageRootSummary
            switch await roots.availability() {
            case let .available(summary, _): availableRoot = summary
            case .noRootSelected: throw RecordingSessionFailure.storageRoot(.noActiveRoot)
            case .reauthorizationRequired: throw RecordingSessionFailure.storageRoot(.reauthorizationRequired)
            case let .failed(code): throw RecordingSessionFailure.storageRoot(code)
            }
            try ensureStartMayContinue(token)

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
                title: title,
                languageMode: configuration.languageMode,
                createdAt: createdAt,
                recorder: recorders.makeRecorder(),
                metadata: preparing
            )
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
            let returnedFailure = resolvedStartFailure(failure, token: token)
            await failStart(token: token, failure: returnedFailure)
            return .failure(returnedFailure)
        } catch {
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
            snapshot = errorSnapshot(failure: failure, phase: .error)
            lastResult = .error(failure)
            publishSnapshot()
            return
        }
        registerFailure(failure, token: token)
        _ = await beginSettlement(token: token, expectedUserStop: false)
    }

    private func cancelStartAttempt(token: UInt64, allowsEstablishedRecordingStop: Bool) async {
        guard startOperation?.token == token else { return }
        guard allowsEstablishedRecordingStop || active?.startedDurably != true else { return }
        cancelledStartTokens.insert(token)
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

        let result: RecordingSessionResult
        if active?.firstFailure == nil, let summary {
            result = await finishNormally(token: token, summary: summary)
        } else {
            result = await finishAbnormally(token: token, summary: summary)
        }
        await stopOwnedTasks(token: token)
        if active?.token == token { active = nil }
        lastResult = result
        if settlementOperation?.token == token { settlementOperation = nil }
        return result
    }

    private func requestCaptureStop(token: UInt64) {
        guard active?.token == token, active?.captureStopIssued == false else { return }
        active?.captureStopIssued = true
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
            if active?.token == token { active?.metadata = metadata }
        } catch {
            notePersistenceWarning(error, token: token)
        }
        await refreshCatalogBestEffort(token: token)

        let phase: RecordingSessionPhase = session.startedDurably ? .interrupted : .error
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
            failure: failure,
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
              sample.generation == active?.captureHandle?.generation else { return }
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
    }

    private func notePersistenceWarning(_ error: Error, token: UInt64) {
        guard active?.token == token else { return }
        let failure = Self.persistenceFailure(error)
        active?.persistenceWarningCode = failure.stableCode
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
        let end = stopRequested
            ? (session.stopRequestedMonotonic ?? clock.monotonicNow())
            : clock.monotonicNow()
        return UInt64(max(0, (end - started) * 1_000))
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
            detectedLanguage: nil,
            engine: nil,
            model: nil,
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
