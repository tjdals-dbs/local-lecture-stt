import AVFoundation
import Foundation

@MainActor
protocol SessionAudioDriver: AnyObject {
    var duration: Double { get }
    var currentTime: Double { get set }
    var finished: ((Bool) -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class MacSessionAudioDriver: NSObject, SessionAudioDriver, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var finished: ((Bool) -> Void)?
    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }
    var duration: Double { player.duration }
    var currentTime: Double { get { player.currentTime } set { player.currentTime = newValue } }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished?(flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finished?(false) }
    }
}

@MainActor
final class SessionAudioPlayer: SessionPlaybackControlling {
    private let roots: StorageRootManager
    private let activity: SessionActivityRegistry
    private let makeDriver: (URL) throws -> any SessionAudioDriver
    private var driver: (any SessionAudioDriver)?
    private var lease: StorageRootWriteLease?
    private var claim: SessionActivityReservation?
    private var files: FinalizationFileAccess?
    private var evidence: FinalizationFileEvidence?
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var cleanup: Task<Void, Never>?
    private var cleanupID: UUID?
    private var state = SessionPlaybackSnapshot()
    private var observers: [UUID: AsyncStream<SessionPlaybackSnapshot>.Continuation] = [:]

    init(roots: StorageRootManager, activity: SessionActivityRegistry,
         makeDriver: @escaping (URL) throws -> any SessionAudioDriver = { try MacSessionAudioDriver(url: $0) }) {
        self.roots = roots; self.activity = activity; self.makeDriver = makeDriver
    }

    func snapshots() -> AsyncStream<SessionPlaybackSnapshot> {
        let id = UUID(); let pair = AsyncStream<SessionPlaybackSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(state)
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return pair.stream
    }
    private func publish(_ value: SessionPlaybackSnapshot) { state = value; observers.values.forEach { $0.yield(value) } }

    func open(_ location: SessionLocation) async throws {
        generation &+= 1; let token = generation
        await releaseResources()
        try check(token)
        publish(.init(phase: .loading))
        do {
            guard let nextClaim = await activity.claimUserOperation(at: location) else { throw SessionDetailFailure.busy }
            guard generation == token, !Task.isCancelled else {
                await activity.release(nextClaim); throw SessionDetailFailure.cancelled
            }
            claim = nextClaim
            let nextLease = try await roots.acquireReadLease(to: location.rootID)
            guard generation == token, !Task.isCancelled else {
                await nextLease.release(); throw SessionDetailFailure.cancelled
            }
            lease = nextLease
            let nextFiles = try FinalizationFileAccess(root: nextLease.rootURL, location: location, allowMissingRecovery: true)
            if let metadata = try? nextFiles.readJSON(SessionMetadataDocument.self, "metadata.json"), metadata.sessionId != location.sessionID {
                throw SessionDetailFailure.identityChanged
            }
            guard let identity = try nextFiles.identity(SessionDetailFile.audio.rawValue) else { throw SessionDetailFailure.unavailable }
            let next = try makeDriver(nextFiles.url(SessionDetailFile.audio.rawValue))
            guard next.duration.isFinite, next.duration > 0, next.duration < Double(Int64.max) / 1_000 else {
                throw SessionDetailFailure.invalidAudio
            }
            try nextFiles.verify(identity)
            driver = next; files = nextFiles; evidence = identity
            next.finished = { [weak self] success in
                Task { @MainActor in await self?.finished(success, token: token) }
            }
            publish(.init(phase: .paused, durationMilliseconds: Int64(next.duration * 1_000)))
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.tick(token) }
            }
        } catch {
            await fail(token, error: error)
            throw error
        }
    }
    func play() async throws {
        let token = generation
        do {
            try validate()
            guard let driver else { throw SessionDetailFailure.unavailable }
            if state.positionMilliseconds >= state.durationMilliseconds { driver.currentTime = 0 }
            guard driver.play() else { throw SessionDetailFailure.invalidAudio }
            var value = state; value.phase = .playing; value.positionMilliseconds = Int64(driver.currentTime * 1_000); publish(value)
        } catch { await fail(token, error: error); throw error }
    }
    func pause() {
        guard driver != nil else { return }
        driver?.pause(); var value = state; value.phase = .paused; publish(value)
    }
    func seek(to milliseconds: Int64) async throws {
        guard milliseconds >= 0 else { throw SessionDetailFailure.invalidSeek }
        let token = generation
        do {
            try validate()
            guard let driver else { throw SessionDetailFailure.unavailable }
            let target = min(milliseconds, state.durationMilliseconds)
            driver.currentTime = Double(target) / 1_000
            var value = state; value.positionMilliseconds = target; publish(value)
        } catch { await fail(token, error: error); throw error }
    }
    func close() async {
        generation &+= 1
        publish(.init())
        await releaseResources()
    }
    private func check(_ token: UInt64) throws {
        guard token == generation, !Task.isCancelled else { throw SessionDetailFailure.cancelled }
    }
    private func validate() throws {
        guard let files, let evidence else { throw SessionDetailFailure.unavailable }
        try files.verify(evidence)
    }
    private func tick(_ token: UInt64) async {
        guard token == generation, let driver else { return }
        do {
            try validate()
            guard driver.currentTime.isFinite, driver.currentTime >= 0 else { throw SessionDetailFailure.invalidAudio }
            var value = state
            value.positionMilliseconds = Int64(min(driver.currentTime * 1_000, Double(state.durationMilliseconds)))
            if value != state { publish(value) }
        } catch { await fail(token, error: error) }
    }
    private func finished(_ success: Bool, token: UInt64) async {
        guard token == generation else { return }
        if !success { await fail(token, error: SessionDetailFailure.invalidAudio); return }
        let duration = state.durationMilliseconds
        generation &+= 1; let ended = generation
        await releaseResources()
        if generation == ended { publish(.init(positionMilliseconds: duration, durationMilliseconds: duration)) }
    }
    private func fail(_ token: UInt64, error: Error) async {
        guard token == generation else { return }
        generation &+= 1; let failed = generation
        await releaseResources()
        if generation == failed { publish(.init(phase: .failed, failure: error as? SessionDetailFailure ?? .invalidAudio)) }
    }
    private func releaseResources() async {
        timer?.invalidate(); timer = nil
        driver?.finished = nil; driver?.stop(); driver = nil; files = nil; evidence = nil
        let oldLease = lease; lease = nil
        let oldClaim = claim; claim = nil
        let previous = cleanup; let id = UUID(); cleanupID = id
        let activity = activity
        let task = Task {
            await previous?.value
            await oldLease?.release()
            if let oldClaim { await activity.release(oldClaim) }
        }
        cleanup = task
        await task.value
        if cleanupID == id { cleanup = nil; cleanupID = nil }
    }
}
