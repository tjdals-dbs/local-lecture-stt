import Foundation
import Combine

/// An explicit, finite input check. PCM is drained and discarded; no session or
/// recording files are created. Recording start joins stop before taking capture.
@MainActor
final class MicrophonePreviewViewModel: ObservableObject, LifecycleAuxiliaryWorking {
    @Published private(set) var active = false
    @Published private(set) var level: Double = 0
    @Published private(set) var name = "기본 마이크"
    @Published private(set) var status = "입력 확인을 누르면 30초 동안 마이크 상태를 확인합니다."
    @Published private(set) var noInput = false {
        didSet { if noInput && !oldValue { diagnostics.issue(.init(code: .noInput), source: .recording) } }
    }
    @Published private(set) var failureCode: CaptureErrorCode?
    private let permission: any MicrophonePermissionAuthorizing
    private let capture: any MicrophoneCapturing
    private let authority: LifecycleWorkAuthority?
    private var lease: UUID?
    private var generation = 0
    private var startTask: Task<CaptureHandle, Error>?
    private var stopTask: Task<Void, Never>?
    private var consumers: [Task<Void, Never>] = []
    private var observers: [UUID: AsyncStream<LifecycleAuxiliarySnapshot>.Continuation] = [:]
    private let duration: Duration
    private let diagnostics: any DiagnosticRecording

    init(permission: any MicrophonePermissionAuthorizing, capture: any MicrophoneCapturing,
         authority: LifecycleWorkAuthority? = nil, duration: Duration = .seconds(30),
         diagnostics: any DiagnosticRecording = NoopDiagnosticRecorder()) {
        self.permission = permission; self.capture = capture; self.authority = authority; self.duration = duration
        self.diagnostics = diagnostics
    }
    func start() async {
        guard !active, stopTask == nil else { return }
        generation += 1; let token = generation
        lease = authority?.admit(); failureCode = nil; active = true; publish()
        status = "마이크 입력 준비 중…"; noInput = false
        let task = Task { [permission, capture] in
            var value = await permission.authorizationStatus()
            if value == .notDetermined { value = await permission.requestAuthorization() }
            try Task.checkCancellation()
            guard value == .authorized else { throw CaptureError.permissionError(for: value) }
            return try await capture.start()
        }
        startTask = task
        do {
            let handle = try await task.value
            guard generation == token, !task.isCancelled else { return }
            startTask = nil; name = handle.device.displayName; status = "마이크 입력 확인 중 · 오디오는 저장하지 않습니다."
            consumers = [
                Task { for await sample in handle.inputSignalStates {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.level = Double(sample.normalizedLevel); self.noInput = sample.state == .noInput
                } },
                Task { do { for try await _ in handle.recordingPCM {} } catch {} },
                Task { do { for try await _ in handle.speechInputs {} } catch {} },
                Task { for await event in handle.events {
                    guard self.generation == token, !Task.isCancelled else { return }
                    if case let .terminalFailure(code) = event {
                        self.reportFailure(code)
                        await self.stop()
                        return
                    }
                } },
                Task {
                    do { try await Task.sleep(for: self.duration) } catch { return }
                    guard self.generation == token else { return }; await self.stop()
                }
            ]
        } catch {
            guard generation == token else { return }
            startTask = nil
            reportFailure((error as? CaptureError)?.code ?? .runtimeFailure)
            await stop()
        }
    }
    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard active else { return }
        generation += 1
        let pending = startTask; pending?.cancel(); startTask = nil
        let cleanup = Task { [capture] in
            await capture.stop()
            _ = try? await pending?.value
            await capture.stop()
        }
        stopTask = cleanup
        await cleanup.value
        consumers.forEach { $0.cancel() }; consumers = []
        stopTask = nil; level = 0; noInput = false; active = false
        if failureCode == nil { status = "입력 확인이 끝났습니다." }
        if let lease { authority?.release(lease); self.lease = nil }
        publish()
    }
    func quiesce() async { await stop() }
    func currentWork() -> LifecycleAuxiliarySnapshot { .init(active: active, requiresAttention: failureCode != nil) }
    private func reportFailure(_ code: CaptureErrorCode) {
        if let authority {
            let invalidation = authority.admit(); authority.release(invalidation)
        }
        failureCode = code
        status = UserIssues.capture(code).message + " (\(code.rawValue))"
        diagnostics.issue(UserIssues.capture(code), source: .recording)
        publish()
    }
    func workSnapshots() -> AsyncStream<LifecycleAuxiliarySnapshot> {
        let id = UUID(); let pair = AsyncStream<LifecycleAuxiliarySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(currentWork())
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return pair.stream
    }
    private func publish() { observers.values.forEach { $0.yield(currentWork()) } }
}

/// Combines app-owned auxiliary work without exposing feature or framework types
/// to the lifecycle policy. Each owner retains its own authority lease.
actor LifecycleAuxiliaryGroup: LifecycleAuxiliaryWorking {
    private let owners: [any LifecycleAuxiliaryWorking]
    init(_ owners: [any LifecycleAuxiliaryWorking]) { self.owners = owners }
    func currentWork() async -> LifecycleAuxiliarySnapshot {
        var active = false; var attention = false
        for owner in owners {
            let value = await owner.currentWork(); active = active || value.active; attention = attention || value.requiresAttention
        }
        return .init(active: active, requiresAttention: attention)
    }
    func quiesce() async { for owner in owners { await owner.quiesce() } }
    func workSnapshots() -> AsyncStream<LifecycleAuxiliarySnapshot> {
        let pair = AsyncStream<LifecycleAuxiliarySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let tasks = owners.map { owner in Task {
            for await _ in await owner.workSnapshots() {
                guard !Task.isCancelled else { return }
                pair.continuation.yield(await self.currentWork())
            }
        } }
        pair.continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        return pair.stream
    }
}
