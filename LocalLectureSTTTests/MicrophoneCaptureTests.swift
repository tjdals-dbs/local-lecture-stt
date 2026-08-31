import AVFoundation
import Foundation
import XCTest
@testable import LocalLectureSTT

final class MicrophoneCaptureTests: XCTestCase {
    func testAVFoundationAuthorizationStatusesMapToStableApplicationStates() {
        XCTAssertEqual(AVFoundationMicrophonePermissionAuthorizer.map(.notDetermined), .notDetermined)
        XCTAssertEqual(AVFoundationMicrophonePermissionAuthorizer.map(.authorized), .authorized)
        XCTAssertEqual(AVFoundationMicrophonePermissionAuthorizer.map(.denied), .denied)
        XCTAssertEqual(AVFoundationMicrophonePermissionAuthorizer.map(.restricted), .restricted)
    }

    func testPermissionStatusAndDeniedStartDoNotTouchDriver() async throws {
        let driver = SyntheticCaptureDriver()
        for status in [MicrophonePermissionStatus.notDetermined, .denied, .restricted, .unavailable] {
            let controller = MicrophoneCaptureController(permission: FakePermission(status: status), driver: driver, monitor: testMonitor())
            do {
                _ = try await controller.start()
                XCTFail("Expected typed permission error")
            } catch let error as CaptureError {
                XCTAssertEqual(error.code, permissionCode(status))
            }
        }
        let counts = await driver.counts
        XCTAssertEqual(counts.prepare, 0)
        XCTAssertEqual(counts.start, 0)
        XCTAssertEqual(counts.stop, 0)
    }

    func testExplicitPermissionRequestDoesNotOccurDuringConstructionOrStatusLookup() async {
        let permission = FakePermission(status: .notDetermined, requestResult: .authorized)
        let driver = SyntheticCaptureDriver()
        _ = MicrophoneCaptureController(permission: permission, driver: driver, monitor: testMonitor())
        let before = await permission.requestCount
        let status = await permission.authorizationStatus()
        let afterStatus = await permission.requestCount
        let requested = await permission.requestAuthorization()
        let afterRequest = await permission.requestCount
        XCTAssertEqual(before, 0)
        XCTAssertEqual(status, .notDetermined)
        XCTAssertEqual(afterStatus, 0)
        XCTAssertEqual(requested, .authorized)
        XCTAssertEqual(afterRequest, 1)
    }

    func testStopWhilePermissionIsAwaitingInvalidatesTheStartAttempt() async {
        let permission = ControlledPermission()
        let driver = ControlledCaptureDriver()
        let controller = MicrophoneCaptureController(permission: permission, driver: driver, monitor: testMonitor())
        let start = Task.detached { await result { try await controller.start() } }

        await permission.waitForAuthorizationStatus()
        await controller.stop()
        await permission.resumeAuthorization(with: .authorized)

        let outcome = await start.value
        XCTAssertEqual(captureErrorCode(outcome), .startInterrupted)
        let lifecycle = await controller.currentLifecycle()
        let counts = await driver.currentCounts()
        XCTAssertEqual(lifecycle, .idle)
        XCTAssertEqual(counts.prepare, 0)
        XCTAssertEqual(counts.stop, 1)
    }

    func testStopWhilePrepareIsAwaitingCannotStartOrReturnAHandle() async {
        let driver = ControlledCaptureDriver(pausePrepare: true)
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        let start = Task.detached { await result { try await controller.start() } }

        await driver.waitForPrepare()
        await controller.stop()
        await driver.resumePrepare()

        let outcome = await start.value
        XCTAssertEqual(captureErrorCode(outcome), .startInterrupted)
        let lifecycle = await controller.currentLifecycle()
        XCTAssertEqual(lifecycle, .idle)
        let counts = await driver.currentCounts()
        XCTAssertEqual(counts.prepare, 1)
        XCTAssertEqual(counts.start, 0)
        XCTAssertEqual(counts.stop, 1)
    }

    func testRuntimeFailureDuringStartingCannotReturnAHandleAndFinishesOnce() async {
        let driver = ControlledCaptureDriver(pauseStart: true)
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        let start = Task.detached { await result { try await controller.start() } }

        await driver.waitForStart()
        await driver.emitRuntime(.runtimeFailure)
        await waitForLifecycle(controller, .failed(.runtimeFailure))
        await driver.resumeStart()

        let outcome = await start.value
        XCTAssertEqual(captureErrorCode(outcome), .runtimeFailure)
        let lifecycle = await controller.currentLifecycle()
        XCTAssertEqual(lifecycle, .failed(.runtimeFailure))
        let counts = await driver.currentCounts()
        XCTAssertEqual(counts.stop, 1)
    }

    func testOwnedPCMValidatesFormatAndCannotBeMutatedThroughSourceArray() throws {
        let format = try PCMFormatDescription(sampleRate: 48_000, channelCount: 2)
        var source: [Float] = [0.1, 0.2, 0.3, 0.4]
        let chunk = try PCMChunk(generation: 1, sequence: 2, format: format, frameCount: 2, sourceSampleTime: 42, samples: source)
        source[0] = 0.9
        XCTAssertEqual(chunk.samples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(chunk.frameCount, 2)
        XCTAssertEqual(chunk.format.sampleRate, 48_000)
        XCTAssertThrowsError(try PCMChunk(generation: 1, sequence: 0, format: format, frameCount: 3, sourceSampleTime: 0, samples: source))
        XCTAssertThrowsError(try PCMFormatDescription(sampleRate: .infinity, channelCount: 1))
        XCTAssertThrowsError(try PCMChunk(generation: 1, sequence: 0, format: format, frameCount: 2, sourceSampleTime: -1, samples: [0, 0, 0, 0]))
    }

    func testPlanarPCMConverterProducesOwnedInterleavedChunksAndValidatesInput() throws {
        let mono = try PlanarPCMChunkConverter.makeChunk(
            generation: 3,
            sequence: 4,
            sampleRate: 48_000,
            sourceSampleTime: 240,
            planarSamples: [[0.1, 0.2]]
        )
        XCTAssertEqual(mono.samples, [0.1, 0.2])
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.sourceSampleTime, 240)

        let stereo = try PlanarPCMChunkConverter.makeChunk(
            generation: 3,
            sequence: 5,
            sampleRate: 48_000,
            sourceSampleTime: 242,
            planarSamples: [[0.1, 0.2], [0.3, 0.4]]
        )
        XCTAssertEqual(stereo.samples, [0.1, 0.3, 0.2, 0.4])
        XCTAssertEqual(stereo.frameCount, 2)
        XCTAssertEqual(stereo.sourceSampleTime, 242)

        XCTAssertThrowsError(try PlanarPCMChunkConverter.makeChunk(generation: 0, sequence: 0, sampleRate: 48_000, sourceSampleTime: 0, planarSamples: []))
        XCTAssertThrowsError(try PlanarPCMChunkConverter.makeChunk(generation: 0, sequence: 0, sampleRate: 48_000, sourceSampleTime: 0, planarSamples: [[0], [0, 1]]))
        XCTAssertThrowsError(try PlanarPCMChunkConverter.makeChunk(generation: 0, sequence: 0, sampleRate: 48_000, sourceSampleTime: -1, planarSamples: [[0]]))
        XCTAssertThrowsError(try PlanarPCMChunkConverter.makeChunk(generation: 0, sequence: 0, sampleRate: 48_000, sourceSampleTime: 0, planarSamples: [[.nan]]))
    }

    func testSlowOrNonConsumingSpeechDoesNotBlockRecordingAndReportsDrops() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(
            permission: FakePermission(status: .authorized),
            driver: driver,
            buffers: CaptureBufferConfiguration(recordingCapacity: 16, speechCapacity: 1),
            monitor: testMonitor()
        )
        let handle = try await controller.start()
        for sequence in 0 ..< 8 { await driver.emit(try chunk(sequence: UInt64(sequence), generation: handle.generation)) }
        await controller.stop()
        let recording = try await collect(handle.recordingPCM)
        let events = await collect(handle.events)
        XCTAssertEqual(recording.map(\.sequence), Array(0 ..< 8).map(UInt64.init))
        XCTAssertTrue(events.contains { if case .speechDiscontinuity = $0 { true } else { false } })
        XCTAssertTrue(events.contains(.stopped))
    }

    func testSpeechCancellationDoesNotStopRecording() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, buffers: CaptureBufferConfiguration(recordingCapacity: 8, speechCapacity: 2), monitor: testMonitor())
        let handle = try await controller.start()
        await driver.emit(try chunk(sequence: 0, generation: handle.generation))
        do {
            var speechIterator = handle.speechPCM.makeAsyncIterator()
            let firstSpeech = try await speechIterator.next()
            XCTAssertNotNil(firstSpeech)
        } // Releasing a speech subscription must not stop the owner or recording stream.
        await driver.emit(try chunk(sequence: 1, generation: handle.generation))
        let lifecycle = await controller.currentLifecycle()
        XCTAssertEqual(lifecycle, .running)
        await controller.stop()
        let recording = try await collect(handle.recordingPCM)
        XCTAssertEqual(recording.map(\.sequence), [0, 1])
    }

    func testRecordingOverflowIsTypedTerminalFailureAndCleansUpOnce() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, buffers: CaptureBufferConfiguration(recordingCapacity: 1, speechCapacity: 1), monitor: testMonitor())
        let handle = try await controller.start()
        await driver.emit(try chunk(sequence: 0, generation: handle.generation))
        await driver.emit(try chunk(sequence: 1, generation: handle.generation))
        let events = await collect(handle.events)
        for _ in 0 ..< 100 where (await driver.counts).stop == 0 { await Task.yield() }
        let lifecycle = await controller.currentLifecycle()
        XCTAssertEqual(lifecycle, .failed(.recordingBackpressure))
        XCTAssertTrue(events.contains(.terminalFailure(.recordingBackpressure)))
        let counts = await driver.counts
        XCTAssertEqual(counts.stop, 1)
    }

    func testRecordingConsumerCancellationIsADistinctTerminalFailure() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        let handle = try await controller.start()
        let reading = AsyncGate()
        let consumer = Task { () -> Error? in
            var iterator = handle.recordingPCM.makeAsyncIterator()
            await reading.open()
            do {
                _ = try await iterator.next()
                return nil
            } catch {
                return error
            }
        }

        await reading.wait()
        consumer.cancel()
        _ = await consumer.value
        guard await waitForDriverStop(driver) else {
            await controller.stop()
            return XCTFail("Recording cancellation did not terminate its owner stream")
        }

        let events = await collect(handle.events)
        XCTAssertEqual(events.filter { $0 == .terminalFailure(.recordingConsumerTerminated) }.count, 1)
        let lifecycle = await controller.currentLifecycle()
        let counts = await driver.counts
        XCTAssertEqual(lifecycle, .failed(.recordingConsumerTerminated))
        XCTAssertEqual(counts.stop, 1)
    }

    func testDeviceDisconnectRouteChangeAndLateEventsAreTerminalOnce() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        let handle = try await controller.start()
        await driver.emitRuntime(.activeDeviceDisconnected)
        await driver.emitRuntime(.inputRouteChanged)
        for _ in 0 ..< 20 where await controller.currentLifecycle() == .running { await Task.yield() }
        let lifecycle = await controller.currentLifecycle()
        let events = await collect(handle.events)
        let counts = await driver.counts
        guard case let .failed(code) = lifecycle else { return XCTFail("Expected a terminal device error") }
        XCTAssertTrue([.activeDeviceDisconnected, .inputRouteChanged].contains(code))
        XCTAssertTrue(events.contains(.terminalFailure(code)))
        XCTAssertEqual(counts.stop, 1)
        await driver.emitRuntime(.engineConfigurationChanged)
        let unchanged = await controller.currentLifecycle()
        XCTAssertEqual(unchanged, lifecycle)
    }

    func testStopAndTerminalFailureRaceFinishesStreamsAndDriverExactlyOnce() async throws {
        let driver = ControlledCaptureDriver(pauseStop: true)
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        let handle = try await controller.start()

        await driver.emitRuntime(.activeDeviceDisconnected)
        await waitForLifecycle(controller, .stopping)
        await controller.stop() // Races the terminal cleanup while it is suspended in driver.stop().
        await driver.waitForStop()
        await driver.resumeStop()
        await waitForLifecycle(controller, .failed(.activeDeviceDisconnected))

        let lifecycle = await controller.currentLifecycle()
        XCTAssertEqual(lifecycle, .failed(.activeDeviceDisconnected))
        let events = await collect(handle.events)
        XCTAssertEqual(events.filter { $0 == .terminalFailure(.activeDeviceDisconnected) }.count, 1)
        XCTAssertEqual(events.count, 1)
        do {
            _ = try await collect(handle.recordingPCM)
            XCTFail("Expected terminal recording failure")
        } catch let error as CaptureError {
            XCTAssertEqual(error.code, .activeDeviceDisconnected)
        }
        let counts = await driver.currentCounts()
        XCTAssertEqual(counts.stop, 1)
    }

    func testStartStopRestartRejectsStaleGenerationAndRollsBackStartFailure() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        let first = try await controller.start()
        let stale = await driver.currentChunkCallback()
        await controller.stop()
        let second = try await controller.start()
        stale?(try chunk(sequence: 99, generation: first.generation))
        await driver.emit(try chunk(sequence: 0, generation: second.generation))
        await controller.stop()
        let secondRecording = try await collect(second.recordingPCM)
        XCTAssertEqual(secondRecording.map(\.sequence), [0])

        let failing = SyntheticCaptureDriver(startError: CaptureError(.engineStartFailed))
        let failingController = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: failing, monitor: testMonitor())
        await XCTAssertThrowsErrorAsync(try await failingController.start()) { error in
            XCTAssertEqual((error as? CaptureError)?.code, .engineStartFailed)
        }
        let failingCounts = await failing.counts
        XCTAssertEqual(failingCounts.stop, 1)
    }

    func testConcurrentStartInstallsOneTapAndOneObserver() async throws {
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: testMonitor())
        async let first: Result<CaptureHandle, Error> = result { try await controller.start() }
        async let second: Result<CaptureHandle, Error> = result { try await controller.start() }
        let results = await [first, second]
        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        let prepareCounts = await driver.counts
        XCTAssertEqual(prepareCounts.prepare, 1)
        await controller.stop()
        let stopCounts = await driver.counts
        XCTAssertEqual(stopCounts.stop, 1)
    }

    func testLevelMathThrottleNoInputAtFiveSecondsAndRecovery() async throws {
        XCTAssertEqual(InputSignalMonitor.levels(for: [0, 0]).rmsDBFS, -120)
        XCTAssertEqual(InputSignalMonitor.levels(for: [1, -1]).peakDBFS, 0, accuracy: 0.0001)
        XCTAssertEqual(InputSignalMonitor.levels(for: [1, 1]).rmsDBFS, 0, accuracy: 0.0001)

        let clock = ManualClock()
        let scheduler = ManualScheduler()
        let monitor = InputSignalMonitor(clock: clock, scheduler: scheduler, configuration: InputSignalMonitorConfiguration(noInputAfter: 5, publicationInterval: 0.05))
        let states = monitor.start(generation: 7)
        clock.advance(by: 4.999); scheduler.tick()
        clock.advance(by: 0.001); scheduler.tick()
        monitor.receive(try chunk(sequence: 1, generation: 7, samples: [1, 1]))
        monitor.stop()
        let collected = await collect(states)
        XCTAssertEqual(collected.map(\.state), [.observing, .noInput, .active, .stopped])
        XCTAssertEqual(collected[1].monotonicSeconds, 5, accuracy: 0.0001)
    }

    func testHighFrequencyActiveFramesRespectTheDefaultTwentyHertzPublicationLimit() async throws {
        let clock = ManualClock()
        let scheduler = ManualScheduler()
        let monitor = InputSignalMonitor(clock: clock, scheduler: scheduler)
        let states = monitor.start(generation: 7)
        for sequence in 0 ..< 200 {
            clock.advance(by: 0.001)
            monitor.receive(try chunk(sequence: UInt64(sequence), generation: 7, samples: [1]))
        }
        monitor.stop()

        let collected = await collect(states)
        let active = collected.filter { $0.state == .active }
        XCTAssertEqual(active.count, 4)
        for (actual, expected) in zip(active.map(\.monotonicSeconds), [0.001, 0.051, 0.101, 0.151]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testNoInputDoesNotStopCaptureAndRepeatedTicksDoNotSpam() async throws {
        let clock = ManualClock()
        let scheduler = ManualScheduler()
        let monitor = InputSignalMonitor(clock: clock, scheduler: scheduler, configuration: InputSignalMonitorConfiguration(noInputAfter: 5, publicationInterval: 0))
        let driver = SyntheticCaptureDriver()
        let controller = MicrophoneCaptureController(permission: FakePermission(status: .authorized), driver: driver, monitor: monitor)
        let handle = try await controller.start()
        clock.advance(by: 5); scheduler.tick(); scheduler.tick()
        let lifecycle = await controller.currentLifecycle()
        XCTAssertEqual(lifecycle, .running)
        await controller.stop()
        let samples = await collect(handle.inputSignalStates)
        XCTAssertEqual(samples.filter { $0.state == .noInput }.count, 1)
    }

    private func testMonitor() -> InputSignalMonitor {
        InputSignalMonitor(clock: ManualClock(), scheduler: ManualScheduler())
    }

    private func chunk(sequence: UInt64, generation: UInt64, samples: [Float] = [0.25]) throws -> PCMChunk {
        try PCMChunk(generation: generation, sequence: sequence, format: PCMFormatDescription(sampleRate: 48_000, channelCount: 1), frameCount: samples.count, sourceSampleTime: Int64(sequence * UInt64(samples.count)), samples: samples)
    }

    private func permissionCode(_ status: MicrophonePermissionStatus) -> CaptureErrorCode {
        switch status {
        case .notDetermined: .permissionNotDetermined
        case .denied: .permissionDenied
        case .restricted: .permissionRestricted
        case .unavailable: .permissionUnavailable
        case .authorized: .permissionUnavailable
        }
    }
}

private actor FakePermission: MicrophonePermissionAuthorizing {
    private let status: MicrophonePermissionStatus
    private let requestResult: MicrophonePermissionStatus
    private(set) var requestCount = 0

    init(status: MicrophonePermissionStatus, requestResult: MicrophonePermissionStatus? = nil) {
        self.status = status
        self.requestResult = requestResult ?? status
    }

    func authorizationStatus() async -> MicrophonePermissionStatus { status }
    func requestAuthorization() async -> MicrophonePermissionStatus { requestCount += 1; return requestResult }
}

private actor ControlledPermission: MicrophonePermissionAuthorizing {
    private var authorizationContinuation: CheckedContinuation<MicrophonePermissionStatus, Never>?
    private var statusWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusWasRequested = false

    func authorizationStatus() async -> MicrophonePermissionStatus {
        statusWasRequested = true
        let waiters = statusWaiters
        statusWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { authorizationContinuation = $0 }
    }

    func requestAuthorization() async -> MicrophonePermissionStatus { .authorized }

    func waitForAuthorizationStatus() async {
        guard !statusWasRequested else { return }
        await withCheckedContinuation { statusWaiters.append($0) }
    }

    func resumeAuthorization(with status: MicrophonePermissionStatus) {
        authorizationContinuation?.resume(returning: status)
        authorizationContinuation = nil
    }
}

private actor SyntheticCaptureDriver: MicrophoneCaptureDriving {
    struct Counts: Sendable, Equatable { var prepare = 0; var start = 0; var stop = 0 }
    private var callback: (@Sendable (PCMChunk) -> Void)?
    private var event: (@Sendable (CaptureRuntimeEvent) -> Void)?
    private(set) var counts = Counts()
    private let startError: CaptureError?

    init(startError: CaptureError? = nil) { self.startError = startError }

    func prepare(generation: UInt64, onChunk: @escaping @Sendable (PCMChunk) -> Void, onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void) async throws -> InputDeviceSnapshot {
        counts.prepare += 1
        callback = onChunk
        event = onRuntimeEvent
        return InputDeviceSnapshot(identity: "test-input", displayName: "Synthetic Input")
    }

    func start() async throws { counts.start += 1; if let startError { throw startError } }
    func stop() async { counts.stop += 1; callback = nil; event = nil }
    func emit(_ chunk: PCMChunk) { callback?(chunk) }
    func emitRuntime(_ runtime: CaptureRuntimeEvent) { event?(runtime) }
    func currentChunkCallback() -> (@Sendable (PCMChunk) -> Void)? { callback }
}

private final class ControlledCaptureDriver: MicrophoneCaptureDriving, @unchecked Sendable {
    struct Counts: Sendable, Equatable { var prepare = 0; var start = 0; var stop = 0 }

    private let lock = NSLock()
    private let prepareGate: ControlledGate?
    private let startGate: ControlledGate?
    private let stopGate: ControlledGate?
    private var counts = Counts()
    private var callback: (@Sendable (PCMChunk) -> Void)?
    private var runtimeEvent: (@Sendable (CaptureRuntimeEvent) -> Void)?

    init(pausePrepare: Bool = false, pauseStart: Bool = false, pauseStop: Bool = false) {
        prepareGate = pausePrepare ? ControlledGate() : nil
        startGate = pauseStart ? ControlledGate() : nil
        stopGate = pauseStop ? ControlledGate() : nil
    }

    func prepare(generation: UInt64, onChunk: @escaping @Sendable (PCMChunk) -> Void, onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void) async throws -> InputDeviceSnapshot {
        lock.withLock {
            counts.prepare += 1
            callback = onChunk
            runtimeEvent = onRuntimeEvent
        }
        await prepareGate?.arriveAndWait()
        return InputDeviceSnapshot(identity: "controlled-input", displayName: "Controlled Input")
    }

    func start() async throws {
        lock.withLock { counts.start += 1 }
        await startGate?.arriveAndWait()
    }

    func stop() async {
        lock.withLock { counts.stop += 1 }
        await stopGate?.arriveAndWait()
        lock.withLock {
            callback = nil
            runtimeEvent = nil
        }
    }

    func emitRuntime(_ event: CaptureRuntimeEvent) async {
        let callback = lock.withLock { runtimeEvent }
        callback?(event)
    }
    func currentCounts() async -> Counts { lock.withLock { counts } }
    func waitForPrepare() async { await prepareGate?.waitForArrival() }
    func waitForStart() async { await startGate?.waitForArrival() }
    func waitForStop() async { await stopGate?.waitForArrival() }
    func resumePrepare() async { await prepareGate?.release() }
    func resumeStart() async { await startGate?.release() }
    func resumeStop() async { await stopGate?.release() }

}

private actor ControlledGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by interval: TimeInterval) { lock.lock(); value += interval; lock.unlock() }
}

private final class ManualScheduler: InputSignalScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void) { lock.lock(); callback = tick; lock.unlock() }
    func stop() { lock.lock(); callback = nil; lock.unlock() }
    func tick() { lock.lock(); let callback = callback; lock.unlock(); callback?() }
}

private func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
    var result: [T] = []
    for await value in stream { result.append(value) }
    return result
}

private func collect<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var result: [T] = []
    for try await value in stream { result.append(value) }
    return result
}

private func result<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ verify: (Error) -> Void) async {
    do { _ = try await expression(); XCTFail("Expected error") } catch { verify(error) }
}

private func captureErrorCode<T>(_ result: Result<T, Error>) -> CaptureErrorCode? {
    guard case let .failure(error) = result else { return nil }
    return (error as? CaptureError)?.code
}

private func waitForLifecycle(_ controller: MicrophoneCaptureController, _ expected: CaptureLifecycle) async {
    for _ in 0 ..< 1_000 {
        if await controller.currentLifecycle() == expected { return }
        await Task.yield()
    }
    XCTFail("Lifecycle did not reach \(expected)")
}

private func waitForDriverStop(_ driver: SyntheticCaptureDriver) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await driver.counts.stop == 1 { return true }
        await Task.yield()
    }
    return false
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
