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
