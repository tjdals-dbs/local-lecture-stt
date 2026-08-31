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

struct CaptureHandle: Sendable {
    let generation: UInt64
    let device: InputDeviceSnapshot
    let recordingPCM: AsyncThrowingStream<PCMChunk, Error>
    let speechPCM: AsyncThrowingStream<PCMChunk, Error>
    let events: AsyncStream<CaptureEvent>
    let inputSignalStates: AsyncStream<InputSignalSample>
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
        lifecycle = .starting
        let status = await permission.authorizationStatus()
        guard status == .authorized else {
            let error = CaptureError.permissionError(for: status)
            lifecycle = .failed(error.code)
            throw error
        }

        generation &+= 1
        let currentGeneration = generation
        let distributor = PCMDistributor(configuration: buffers) { [weak self] error in
            // This is only invoked once for a terminal enqueue failure, never once per audio buffer.
            Task { await self?.fail(error, generation: currentGeneration) }
        }
        self.distributor = distributor
        let signalStates = monitor.start(generation: currentGeneration)

        do {
            let device = try await driver.prepare(
                generation: currentGeneration,
                onChunk: { [weak distributor, weak monitor] chunk in
                    guard let distributor, distributor.accept(chunk) else { return }
                    monitor?.receive(chunk)
                },
                onRuntimeEvent: { [weak self] event in
                    Task { await self?.fail(event.error, generation: currentGeneration) }
                }
            )
            try await driver.start()
            lifecycle = .running
            return CaptureHandle(
                generation: currentGeneration,
                device: device,
                recordingPCM: distributor.recordingStream,
                speechPCM: distributor.speechStream,
                events: distributor.eventStream,
                inputSignalStates: signalStates
            )
        } catch let error as CaptureError {
            await rollbackStart(error)
            throw error
        } catch {
            let typed = CaptureError(.engineStartFailed)
            await rollbackStart(typed)
            throw typed
        }
    }

    func stop() async {
        guard lifecycle == .running || lifecycle == .starting else { return }
        lifecycle = .stopping
        distributor?.closeIntake()
        await driver.stop()
        monitor.stop()
        distributor?.finishNormally()
        distributor = nil
        lifecycle = .idle
    }

    private func rollbackStart(_ error: CaptureError) async {
        distributor?.closeIntake()
        await driver.stop()
        monitor.stop()
        distributor?.finish(with: error)
        distributor = nil
        lifecycle = .failed(error.code)
    }

    private func fail(_ error: CaptureError, generation eventGeneration: UInt64) async {
        guard eventGeneration == generation, lifecycle == .running || lifecycle == .starting else { return }
        lifecycle = .stopping
        distributor?.closeIntake()
        await driver.stop()
        monitor.stop()
        distributor?.finish(with: error)
        distributor = nil
        lifecycle = .failed(error.code)
    }
}

private extension CaptureError {
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
    }

    func accept(_ chunk: PCMChunk) -> Bool {
        var terminalError: CaptureError?
        lock.lock()
        guard acceptsInput, !finished else { lock.unlock(); return false }
        switch recording.yield(chunk) {
        case .enqueued: break
        case .dropped, .terminated:
            terminalError = CaptureError(.recordingBackpressure)
            acceptsInput = false
            finished = true
            events.yield(.terminalFailure(.recordingBackpressure))
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
