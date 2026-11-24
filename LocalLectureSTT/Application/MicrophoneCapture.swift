import Foundation

enum MicrophonePermissionStatus: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

protocol MicrophonePermissionAuthorizing: Sendable {
    func authorizationStatus() async -> MicrophonePermissionStatus
    func requestAuthorization() async -> MicrophonePermissionStatus
}

enum PCMLayout: String, Sendable, Equatable {
    /// Samples are frame-major: `frame0.channel0, frame0.channel1, ...`.
    case float32Interleaved
}

struct PCMFormatDescription: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    let layout: PCMLayout

    init(sampleRate: Double, channelCount: Int, layout: PCMLayout = .float32Interleaved) throws {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw CaptureError(.invalidInputFormat)
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.layout = layout
    }
}

struct PCMChunk: Sendable, Equatable {
    let generation: UInt64
    let sequence: UInt64
    let format: PCMFormatDescription
    let frameCount: Int
    let sourceSampleTime: Int64
    /// An owned Float32 copy. No AVFoundation buffer or unsafe pointer escapes here.
    let samples: [Float]

    init(generation: UInt64, sequence: UInt64, format: PCMFormatDescription, frameCount: Int, sourceSampleTime: Int64, samples: [Float]) throws {
        guard frameCount > 0, sourceSampleTime >= 0 else { throw CaptureError(.invalidPCM) }
        let expected = frameCount.multipliedReportingOverflow(by: format.channelCount)
        guard !expected.overflow, expected.partialValue == samples.count, samples.allSatisfy(\.isFinite) else {
            throw CaptureError(.invalidPCM)
        }
        self.generation = generation
        self.sequence = sequence
        self.format = format
        self.frameCount = frameCount
        self.sourceSampleTime = sourceSampleTime
        self.samples = samples
    }
}

struct InputDeviceSnapshot: Sendable, Equatable {
    /// A stable, privacy-safe-to-display platform-neutral identity. Core Audio IDs stay in Infrastructure.
    let identity: String
    let displayName: String
}

enum CaptureLifecycle: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
    case failed(CaptureErrorCode)
}

enum CaptureErrorCode: String, Sendable, Equatable {
    case permissionNotDetermined
    case permissionDenied
    case permissionRestricted
    case permissionUnavailable
    case alreadyRunning
    case noCurrentInputDevice
    case invalidInputFormat
    case invalidPCM
    case tapInstallationFailed
    case engineStartFailed
    case pcmCopyFailed
    case recordingBackpressure
    case recordingConsumerTerminated
    case startInterrupted
    case activeDeviceDisconnected
    case inputRouteChanged
    case engineConfigurationChanged
    case runtimeFailure
}

struct CaptureError: Error, Sendable, Equatable {
    let code: CaptureErrorCode

    init(_ code: CaptureErrorCode) { self.code = code }
}

enum CaptureEvent: Sendable, Equatable {
    case speechDiscontinuity(droppedCount: UInt64)
    case terminalFailure(CaptureErrorCode)
    case stopped
}

enum CaptureRuntimeEvent: Sendable, Equatable {
    case activeDeviceDisconnected
    case inputRouteChanged
    case engineConfigurationChanged
    case pcmCopyFailed
    case runtimeFailure

    var error: CaptureError {
        switch self {
        case .activeDeviceDisconnected: CaptureError(.activeDeviceDisconnected)
        case .inputRouteChanged: CaptureError(.inputRouteChanged)
        case .engineConfigurationChanged: CaptureError(.engineConfigurationChanged)
        case .pcmCopyFailed: CaptureError(.pcmCopyFailed)
        case .runtimeFailure: CaptureError(.runtimeFailure)
        }
    }
}

struct CaptureBufferConfiguration: Sendable, Equatable {
    let recordingCapacity: Int
    let speechCapacity: Int

    static let production = CaptureBufferConfiguration(recordingCapacity: 256, speechCapacity: 32)

    init(recordingCapacity: Int = 256, speechCapacity: Int = 32) {
        self.recordingCapacity = max(1, recordingCapacity)
        self.speechCapacity = max(1, speechCapacity)
    }
}

/// Established by fan-out before either consumer sees PCM. A delayed speech
/// consumer must use the recording origin even if its first chunks were dropped.
final class CaptureTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: Int64?
    func recordOrigin(_ sampleTime: Int64) {
        lock.withLock { if origin == nil { origin = sampleTime } }
    }
    func sourceOrigin() -> Int64? { lock.withLock { origin } }
}

struct CaptureHandle: Sendable {
    let generation: UInt64
    let device: InputDeviceSnapshot
    let recordingPCM: AsyncThrowingStream<PCMChunk, Error>
    let speechPCM: AsyncThrowingStream<PCMChunk, Error>
    let events: AsyncStream<CaptureEvent>
    let inputSignalStates: AsyncStream<InputSignalSample>
    var timeline = CaptureTimeline()
}

protocol MicrophoneCaptureDriving: Sendable {
    func prepare(
        generation: UInt64,
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async throws -> InputDeviceSnapshot
    func start() async throws
    func stop() async
}

/// Serializes the live engine lifecycle. Its fan-out is intentionally synchronous so a tap callback
/// never awaits an actor; it only copies/yields bounded values and creates a Task on one terminal failure.
actor MicrophoneCaptureController {
    private let permission: any MicrophonePermissionAuthorizing
    private let driver: any MicrophoneCaptureDriving
    private let buffers: CaptureBufferConfiguration
    private let monitor: InputSignalMonitor
    private var lifecycle: CaptureLifecycle = .idle
    private var generation: UInt64 = 0
    private var activeAttempt: UInt64?
    private var endingAttempt: UInt64?
    private var endingFailure: CaptureError?
    private var lastTerminalAttempt: UInt64?
    private var lastTerminalFailure: CaptureError?
    private var distributor: PCMDistributor?

    init(
        permission: any MicrophonePermissionAuthorizing,
        driver: any MicrophoneCaptureDriving,
        buffers: CaptureBufferConfiguration = .production,
        monitor: InputSignalMonitor
    ) {
        self.permission = permission
        self.driver = driver
        self.buffers = buffers
        self.monitor = monitor
    }

    func currentLifecycle() -> CaptureLifecycle { lifecycle }

    func start() async throws -> CaptureHandle {
        switch lifecycle {
        case .idle, .failed: break
        case .starting, .running, .stopping: throw CaptureError(.alreadyRunning)
        }
        // Mark before awaiting permission status so concurrent starts cannot both install a tap.
        generation &+= 1
        let currentAttempt = generation
        activeAttempt = currentAttempt
        lastTerminalAttempt = nil
        lastTerminalFailure = nil
        lifecycle = .starting
        let status = await permission.authorizationStatus()
        try ensureStarting(attempt: currentAttempt)
        guard status == .authorized else {
            let error = CaptureError.permissionError(for: status)
            activeAttempt = nil
            lifecycle = .failed(error.code)
            lastTerminalAttempt = currentAttempt
            lastTerminalFailure = error
            throw error
        }

        let distributor = PCMDistributor(configuration: buffers) { [weak self] error in
            // This is only invoked once for a terminal enqueue failure, never once per audio buffer.
            Task { await self?.fail(error, attempt: currentAttempt) }
        }
        self.distributor = distributor
        let signalStates = monitor.start(generation: currentAttempt)

        do {
            let device = try await driver.prepare(
                generation: currentAttempt,
                onChunk: { [weak distributor, weak monitor] chunk in
                    guard let distributor, distributor.accept(chunk) else { return }
                    monitor?.receive(chunk)
                },
                onRuntimeEvent: { [weak self] event in
                    Task { await self?.fail(event.error, attempt: currentAttempt) }
                }
            )
            try ensureStarting(attempt: currentAttempt)
            try await driver.start()
            try ensureStarting(attempt: currentAttempt)
            lifecycle = .running
            return CaptureHandle(
                generation: currentAttempt,
                device: device,
                recordingPCM: distributor.recordingStream,
                speechPCM: distributor.speechStream,
                events: distributor.eventStream,
                inputSignalStates: signalStates,
                timeline: distributor.timeline
            )
        } catch let error as CaptureError {
            if error.code == .startInterrupted { throw error }
            throw await rollbackStart(error, attempt: currentAttempt)
        } catch {
            let typed = CaptureError(.engineStartFailed)
            throw await rollbackStart(typed, attempt: currentAttempt)
        }
    }

    func stop() async {
        guard let attempt = activeAttempt, lifecycle == .running || lifecycle == .starting else { return }
        lifecycle = .stopping
        endingAttempt = attempt
        endingFailure = nil
        let endingDistributor = distributor
        distributor = nil
        endingDistributor?.closeIntake()
        monitor.stop()
        endingDistributor?.finishNormally()
        await driver.stop()
        guard activeAttempt == attempt, lifecycle == .stopping, endingAttempt == attempt else { return }
        activeAttempt = nil
        endingAttempt = nil
        lifecycle = .idle
    }

    private func rollbackStart(_ error: CaptureError, attempt: UInt64) async -> CaptureError {
        guard activeAttempt == attempt, lifecycle == .starting else {
            return interruptionError(for: attempt)
        }
        lifecycle = .stopping
        endingAttempt = attempt
        endingFailure = error
        let endingDistributor = distributor
        distributor = nil
        endingDistributor?.closeIntake()
        monitor.stop()
        endingDistributor?.finish(with: error)
        await driver.stop()
        guard activeAttempt == attempt, lifecycle == .stopping, endingAttempt == attempt else { return interruptionError(for: attempt) }
        activeAttempt = nil
        endingAttempt = nil
        lifecycle = .failed(error.code)
        lastTerminalAttempt = attempt
        lastTerminalFailure = error
        return error
    }

    private func fail(_ error: CaptureError, attempt eventAttempt: UInt64) async {
        guard activeAttempt == eventAttempt, lifecycle == .running || lifecycle == .starting else { return }
        lifecycle = .stopping
        endingAttempt = eventAttempt
        endingFailure = error
        let endingDistributor = distributor
        distributor = nil
        endingDistributor?.closeIntake()
        monitor.stop()
        endingDistributor?.finish(with: error)
        await driver.stop()
        guard activeAttempt == eventAttempt, lifecycle == .stopping, endingAttempt == eventAttempt else { return }
        activeAttempt = nil
        endingAttempt = nil
        lifecycle = .failed(error.code)
        lastTerminalAttempt = eventAttempt
        lastTerminalFailure = error
    }

    private func ensureStarting(attempt: UInt64) throws {
        guard activeAttempt == attempt, lifecycle == .starting else { throw interruptionError(for: attempt) }
    }

    private func interruptionError(for attempt: UInt64) -> CaptureError {
        if endingAttempt == attempt, let endingFailure { return endingFailure }
        if lastTerminalAttempt == attempt, let lastTerminalFailure { return lastTerminalFailure }
        return CaptureError(.startInterrupted)
    }
}

extension CaptureError {
    static func permissionError(for status: MicrophonePermissionStatus) -> CaptureError {
        switch status {
        case .notDetermined: CaptureError(.permissionNotDetermined)
        case .denied: CaptureError(.permissionDenied)
        case .restricted: CaptureError(.permissionRestricted)
        case .authorized: CaptureError(.permissionUnavailable)
        case .unavailable: CaptureError(.permissionUnavailable)
        }
    }
}

/// The lock is held only while yielding into bounded continuations and updating counters. It owns no
/// AVFoundation object, does no I/O, and never waits for a consumer.
private final class PCMDistributor: @unchecked Sendable {
    let recordingStream: AsyncThrowingStream<PCMChunk, Error>
    let speechStream: AsyncThrowingStream<PCMChunk, Error>
    let eventStream: AsyncStream<CaptureEvent>

    private let lock = NSLock()
    private var recording: AsyncThrowingStream<PCMChunk, Error>.Continuation!
    private var speech: AsyncThrowingStream<PCMChunk, Error>.Continuation!
    private var events: AsyncStream<CaptureEvent>.Continuation!
    private var acceptsInput = true
    private var finished = false
    private var speechDropped: UInt64 = 0
    let timeline = CaptureTimeline()
    private let terminal: @Sendable (CaptureError) -> Void

    init(configuration: CaptureBufferConfiguration, terminal: @escaping @Sendable (CaptureError) -> Void) {
        self.terminal = terminal
        var recordingContinuation: AsyncThrowingStream<PCMChunk, Error>.Continuation!
        recordingStream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(configuration.recordingCapacity)) {
            recordingContinuation = $0
        }
        recording = recordingContinuation
        var speechContinuation: AsyncThrowingStream<PCMChunk, Error>.Continuation!
        speechStream = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(configuration.speechCapacity)) {
            speechContinuation = $0
        }
        speech = speechContinuation
        var eventContinuation: AsyncStream<CaptureEvent>.Continuation!
        eventStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { eventContinuation = $0 }
        events = eventContinuation
        recording.onTermination = { [weak self] _ in
            // `finish` may synchronously invoke onTermination; hop out of its lock before inspecting state.
            Task { self?.recordingConsumerTerminated() }
        }
    }

    func accept(_ chunk: PCMChunk) -> Bool {
        var terminalError: CaptureError?
        lock.lock()
        guard acceptsInput, !finished else { lock.unlock(); return false }
        timeline.recordOrigin(chunk.sourceSampleTime)
        switch recording.yield(chunk) {
        case .enqueued: break
        case .dropped:
            terminalError = CaptureError(.recordingBackpressure)
            acceptsInput = false
            finished = true
            events.yield(.terminalFailure(.recordingBackpressure))
            recording.finish(throwing: terminalError)
            speech.finish(throwing: terminalError)
            events.finish()
        case .terminated:
            terminalError = CaptureError(.recordingConsumerTerminated)
            acceptsInput = false
            finished = true
            events.yield(.terminalFailure(.recordingConsumerTerminated))
            recording.finish(throwing: terminalError)
            speech.finish(throwing: terminalError)
            events.finish()
        @unknown default:
            terminalError = CaptureError(.recordingBackpressure)
        }
        if let terminalError {
            lock.unlock()
            // This is the sole terminal callback for the generation, after the short lock is released.
            terminal(terminalError)
            return false
        }
        switch speech.yield(chunk) {
        case .enqueued: break
        case .dropped:
            speechDropped &+= 1
            events.yield(.speechDiscontinuity(droppedCount: speechDropped))
        case .terminated: break
        @unknown default: break
        }
        lock.unlock()
        return true
    }

    func closeIntake() {
        lock.lock(); acceptsInput = false; lock.unlock()
    }

    private func recordingConsumerTerminated() {
        var terminalError: CaptureError?
        lock.lock()
        if acceptsInput, !finished {
            terminalError = CaptureError(.recordingConsumerTerminated)
            acceptsInput = false
            finished = true
            events.yield(.terminalFailure(.recordingConsumerTerminated))
            speech.finish(throwing: terminalError)
            events.finish()
        }
        lock.unlock()
        if let terminalError { terminal(terminalError) }
    }

    func finishNormally() { finish(event: .stopped, error: nil) }
    func finish(with error: CaptureError) { finish(event: .terminalFailure(error.code), error: error) }

    private func finish(event: CaptureEvent, error: CaptureError?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        acceptsInput = false
        finished = true
        events.yield(event)
        if let error {
            recording.finish(throwing: error)
            speech.finish(throwing: error)
        } else {
            recording.finish()
            speech.finish()
        }
        events.finish()
    }
}
