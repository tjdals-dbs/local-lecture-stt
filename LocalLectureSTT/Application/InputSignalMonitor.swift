import Foundation

enum InputSignalState: Sendable, Equatable {
    case observing
    case active
    case noInput
    case stopped
}

struct InputSignalSample: Sendable, Equatable {
    let generation: UInt64
    let sequence: UInt64?
    let monotonicSeconds: TimeInterval
    let normalizedLevel: Float
    let rmsDBFS: Float
    let peakDBFS: Float
    let state: InputSignalState
}

struct InputSignalMonitorConfiguration: Sendable, Equatable {
    let noInputAfter: TimeInterval
    let inactiveThresholdDBFS: Float
    let recoveryThresholdDBFS: Float
    let publicationInterval: TimeInterval
    let floorDBFS: Float

    static let production = InputSignalMonitorConfiguration()

    init(noInputAfter: TimeInterval = 5, inactiveThresholdDBFS: Float = -60, recoveryThresholdDBFS: Float = -55, publicationInterval: TimeInterval = 1.0 / 20.0, floorDBFS: Float = -120) {
        self.noInputAfter = max(0, noInputAfter)
        self.inactiveThresholdDBFS = inactiveThresholdDBFS
        self.recoveryThresholdDBFS = max(recoveryThresholdDBFS, inactiveThresholdDBFS)
        self.publicationInterval = max(0, publicationInterval)
        self.floorDBFS = min(floorDBFS, 0)
    }
}

protocol MonotonicClock: Sendable { func now() -> TimeInterval }

struct SystemMonotonicClock: MonotonicClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

protocol InputSignalScheduling: Sendable {
    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void)
    func stop()
}

final class DispatchInputSignalScheduler: InputSignalScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: max(interval, 0.01))
        timer.setEventHandler(handler: tick)
        lock.lock(); self.timer = timer; lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock(); let timer = self.timer; self.timer = nil; lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }
}

/// A bounded, synchronous meter bridge. It does not publish to the main actor from an audio callback;
/// SwiftUI can consume its state stream on the main actor in T07.
final class InputSignalMonitor: @unchecked Sendable {
    private let clock: any MonotonicClock
    private let scheduler: any InputSignalScheduling
    private let configuration: InputSignalMonitorConfiguration
    private let lock = NSLock()
    private var continuation: AsyncStream<InputSignalSample>.Continuation?
    private var generation: UInt64?
    private var signalState: InputSignalState = .stopped
    private var lastActiveAt: TimeInterval = 0
    private var lastPublicationAt: TimeInterval?

    init(clock: any MonotonicClock = SystemMonotonicClock(), scheduler: any InputSignalScheduling = DispatchInputSignalScheduler(), configuration: InputSignalMonitorConfiguration = .production) {
        self.clock = clock
        self.scheduler = scheduler
        self.configuration = configuration
    }

    func start(generation: UInt64) -> AsyncStream<InputSignalSample> {
        scheduler.stop()
        var streamContinuation: AsyncStream<InputSignalSample>.Continuation!
        let stream = AsyncStream<InputSignalSample>(bufferingPolicy: .bufferingNewest(32)) { streamContinuation = $0 }
        let now = clock.now()
        lock.lock()
        continuation?.finish()
        continuation = streamContinuation
        self.generation = generation
        signalState = .observing
        lastActiveAt = now
        lastPublicationAt = now
        streamContinuation.yield(InputSignalSample(generation: generation, sequence: nil, monotonicSeconds: now, normalizedLevel: 0, rmsDBFS: configuration.floorDBFS, peakDBFS: configuration.floorDBFS, state: .observing))
        lock.unlock()
        scheduler.start(interval: min(configuration.publicationInterval, configuration.noInputAfter)) { [weak self] in self?.tick() }
        return stream
    }

    func receive(_ chunk: PCMChunk) {
        let stats = Self.levels(for: chunk.samples, floor: configuration.floorDBFS)
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        guard generation == chunk.generation, signalState != .stopped else { return }
        let isRecovery = stats.rmsDBFS >= configuration.recoveryThresholdDBFS
        let isSignificant = stats.rmsDBFS >= configuration.inactiveThresholdDBFS
        if isSignificant { lastActiveAt = now }
        let previousState = signalState
        if signalState == .noInput && isRecovery { signalState = .active }
        else if signalState == .observing && isSignificant { signalState = .active }
        // A transition must be visible immediately; otherwise normal active frames remain throttled.
        publishIfNeeded(sequence: chunk.sequence, now: now, stats: stats, force: signalState != previousState)
    }

    func stop() {
        scheduler.stop()
        lock.lock()
        defer { lock.unlock() }
        guard let generation, signalState != .stopped else { return }
        let now = clock.now()
        continuation?.yield(InputSignalSample(generation: generation, sequence: nil, monotonicSeconds: now, normalizedLevel: 0, rmsDBFS: configuration.floorDBFS, peakDBFS: configuration.floorDBFS, state: .stopped))
        continuation?.finish()
        continuation = nil
        self.generation = nil
        signalState = .stopped
        lastPublicationAt = nil
    }

    private func tick() {
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        guard let generation, signalState != .stopped, now - lastActiveAt >= configuration.noInputAfter else { return }
        guard signalState != .noInput else { return }
        signalState = .noInput
        publishIfNeeded(sequence: nil, now: now, stats: LevelStatistics.silence(floor: configuration.floorDBFS), force: true, generation: generation)
    }

    private func publishIfNeeded(sequence: UInt64?, now: TimeInterval, stats: LevelStatistics, force: Bool, generation explicitGeneration: UInt64? = nil) {
        guard force || lastPublicationAt.map({ now - $0 >= configuration.publicationInterval }) ?? true else { return }
        let value = InputSignalSample(generation: explicitGeneration ?? generation!, sequence: sequence, monotonicSeconds: now, normalizedLevel: stats.normalized, rmsDBFS: stats.rmsDBFS, peakDBFS: stats.peakDBFS, state: signalState)
        continuation?.yield(value)
        lastPublicationAt = now
    }

    static func levels(for samples: [Float], floor: Float = -120) -> LevelStatistics {
        guard !samples.isEmpty else { return .silence(floor: floor) }
        var peak: Float = 0
        var squares: Double = 0
        for sample in samples where sample.isFinite {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            squares += Double(sample) * Double(sample)
        }
        let rms = Float(sqrt(squares / Double(samples.count)))
        let rmsDB = max(floor, 20 * log10(max(rms, Float.leastNonzeroMagnitude)))
        let peakDB = max(floor, 20 * log10(max(peak, Float.leastNonzeroMagnitude)))
        return LevelStatistics(normalized: min(1, max(0, peak)), rmsDBFS: rmsDB.isFinite ? rmsDB : floor, peakDBFS: peakDB.isFinite ? peakDB : floor)
    }
}

struct LevelStatistics: Sendable, Equatable {
    let normalized: Float
    let rmsDBFS: Float
    let peakDBFS: Float

    static func silence(floor: Float) -> LevelStatistics { LevelStatistics(normalized: 0, rmsDBFS: floor, peakDBFS: floor) }
}
