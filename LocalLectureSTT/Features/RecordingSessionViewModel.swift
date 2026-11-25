import Foundation
import SwiftUI
import Combine

enum RecordingSessionViewDisplayState: Sendable, Equatable {
    case configuration
    case preparing
    case recording
    case paused
    case securing
    case secured
    case interrupted
    case error
}

struct RecordingSessionViewActions: Sendable, Equatable {
    let canEditConfiguration: Bool
    let canStart: Bool
    let canStop: Bool
    let canReset: Bool
    var canPause = false
    var canResume = false
}

@MainActor
final class RecordingSessionViewModel: ObservableObject {
    @Published var title = ""
    @Published var languageMode: LanguageMode = .korean
    @Published private(set) var snapshot: RecordingSessionSnapshot = .idle() {
        didSet { transcript.update(sessionID: snapshot.sessionID, speech: snapshot.speech) }
    }
    @Published private(set) var finalizations: [AudioFinalizationSnapshot] = []
    let transcript = LiveTranscriptPresentation()

    let modelName: String?
    let models: ModelManagementViewModel?
    let microphonePreview: MicrophonePreviewViewModel?
    private var modelObservation: AnyCancellable?
    private var startInFlight = false
    private let coordinator: any RecordingSessionCoordinating
    private let timeZone: @MainActor @Sendable () -> TimeZone
    private var observationTask: Task<Void, Never>?
    private let finalization: AudioFinalizationCoordinator?
    private let sessionActivity: SessionActivityRegistry?
    private var finalizationObservation: Task<Void, Never>?

    init(
        coordinator: any RecordingSessionCoordinating,
        finalization: AudioFinalizationCoordinator? = nil,
        sessionActivity: SessionActivityRegistry? = nil,
        modelName: String? = nil,
        models: ModelManagementViewModel? = nil,
        microphonePreview: MicrophonePreviewViewModel? = nil,
        timeZone: @escaping @MainActor @Sendable () -> TimeZone = { .current }
    ) {
        self.modelName = modelName
        self.models = models
        self.microphonePreview = microphonePreview
        self.coordinator = coordinator
        self.finalization = finalization
        self.sessionActivity = sessionActivity
        self.timeZone = timeZone
        modelObservation = models?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    static var preview: RecordingSessionViewModel {
        RecordingSessionViewModel(coordinator: PreviewRecordingSessionCoordinator())
    }

    func startObserving() {
        guard observationTask == nil else { return }
        if let finalization {
            finalizationObservation = Task { [weak self] in
                let stream = await finalization.snapshots()
                for await values in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.finalizations = values
                }
            }
        }
        observationTask = Task { [weak self, coordinator] in
            let stream = await coordinator.snapshots()
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                self.snapshot = value
                self.models?.recordingLocked = self.startInFlight || (!value.canStart && !value.canReset)
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        finalizationObservation?.cancel()
        finalizationObservation = nil
    }

    func retryFinalization(_ value: AudioFinalizationSnapshot) async {
        guard value.result?.canRetry == true else { return }
        let claim: SessionActivityReservation?
        if let sessionActivity {
            guard let reserved = await sessionActivity.claimRecovery(at: value.location) else { return }
            claim = reserved
        } else { claim = nil }
        await finalization?.enqueue(.init(location: value.location, operation: value.operation), retry: true)
        _ = await finalization?.waitForResult(at: value.location, operation: value.operation)
        if let claim { await sessionActivity?.release(claim) }
    }

    static func finalizationText(_ phase: AudioFinalizationPhase) -> String {
        switch phase {
        case .queued: "오디오 마무리 대기"
        case .securing: "복구 오디오 확인 중"
        case .exporting: "오디오 마무리 중"
        case .verifying: "오디오 검증 중"
        case .publishing: "오디오 파일 확정 중"
        case .projecting: "오디오 정보 저장 중"
        case .cleaning: "검증된 복구 오디오 정리 중"
        case .compactingTranscript: "기록과 문서 저장 중"
        case .sessionReady: "녹음과 기록 저장 완료"
        case .cancelling: "오디오 작업 정리 중"
        case .audioReadyAwaitingRemainingFinalization: "오디오 파일 준비 완료 · 나머지 마무리 대기"
        case .audioRevalidated: "오디오 파일 재검증 완료"
        case .recoveryAudioRemoved: "복구 오디오 정리 완료"
        case .failed: "오디오 마무리 실패 · 자료 보존"
        }
    }

    func refreshPermissionStatus() async {
        await coordinator.refreshPermissionStatus()
    }

    func toggleMicrophonePreview() async {
        guard !startInFlight, snapshot.canStart, models?.recordingLocked != true, let microphonePreview else { return }
        if microphonePreview.active { await microphonePreview.stop() }
        else { await microphonePreview.start() }
        await refreshPermissionStatus()
    }

    func startRecording() async {
        guard actions.canStart else { return }
        let descriptor = models?.selectedDescriptor
        startInFlight = true
        models?.recordingLocked = true
        do {
            _ = try await coordinator.start(RecordingStartConfiguration(
                title: title,
                languageMode: languageMode,
                timeZone: timeZone(),
                modelDescriptor: descriptor
            ))
        } catch {
            snapshot = await coordinator.currentSnapshot()
        }
        snapshot = await coordinator.currentSnapshot()
        startInFlight = false
        models?.recordingLocked = !snapshot.canStart && !snapshot.canReset
    }

    func togglePause() async {
        guard snapshot.canPause || snapshot.canResume else { return }
        do {
            if snapshot.canPause { try await coordinator.pause() }
            else { try await coordinator.resume() }
        } catch {
            // The owner publishes operational failures and joins essential save.
        }
        snapshot = await coordinator.currentSnapshot()
    }

    func stopRecording() async {
        _ = await coordinator.stop()
    }

    func beginAnotherRecording() async {
        await coordinator.reset()
        title = ""
    }

    var permissionText: String {
        switch snapshot.permissionStatus {
        case .notDetermined: "확인되지 않음 — 녹음 시작 시 요청"
        case .authorized: "허용됨"
        case .denied: "거부됨 — 시스템 설정에서 허용하세요"
        case .restricted: "시스템에서 제한됨"
        case .unavailable: "사용할 수 없음"
        case nil: "확인 중"
        }
    }

    var lifecycleMessage: String? {
        if case .speechModel = snapshot.failure { return nil }
        if snapshot.phase == .securing { return "필수 저장 중…" }
        if snapshot.persistenceWarningCode != nil { return "필수 저장에 실패했습니다. 복구 자료를 보존했으며 확인이 필요합니다." }
        if snapshot.failure == .interrupted(.systemSleep) { return "시스템 잠자기로 녹음이 중단되었습니다. 녹음은 자동 재개되지 않습니다." }
        if snapshot.phase == .interrupted, let failure = snapshot.failure,
           case .interrupted = failure { return "복구 가능한 오디오를 저장하고 녹음을 중단했습니다." }
        if snapshot.phase == .interrupted || snapshot.phase == .error { return "저장 상태를 확인하세요. 기존 자료는 보존됩니다." }
        return nil
    }

    var elapsedText: String { Self.formatElapsed(snapshot.elapsedMilliseconds) }

    var backgroundWorkText: String? {
        Self.backgroundWorkText(finalizations, speech: snapshot.speech.phase)
    }

    static func backgroundWorkText(_ values: [AudioFinalizationSnapshot], speech: LiveSTTPhase) -> String? {
        let pending = values.filter { $0.result == nil }.count
        let failed = values.filter { $0.result?.failure != nil || $0.result?.transcriptFailure != nil }.count
        var parts: [String] = []
        if speech == .finishing { parts.append("남은 전사 처리 중") }
        if pending > 0 { parts.append("마무리 작업 \(pending)개") }
        if failed > 0 { parts.append("마무리 확인 필요 \(failed)개") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var displayState: RecordingSessionViewDisplayState {
        if startInFlight && snapshot.canStart { return .preparing }
        return switch snapshot.phase {
        case .idle: .configuration
        case .preparing: .preparing
        case .recording: .recording
        case .paused: .paused
        case .securing: .securing
        case .securedAwaitingFinalization: .secured
        case .interrupted: .interrupted
        case .error: .error
        }
    }

    var actions: RecordingSessionViewActions {
        RecordingSessionViewActions(
            canEditConfiguration: !startInFlight && snapshot.canStart,
            canStart: !startInFlight && snapshot.canStart && (models?.readyToRecord ?? true),
            canStop: snapshot.canStop,
            canReset: snapshot.canReset,
            canPause: snapshot.canPause,
            canResume: snapshot.canResume
        )
    }

    static func formatElapsed(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02llu:%02llu:%02llu", hours, minutes, seconds)
    }
}

private actor PreviewRecordingSessionCoordinator: RecordingSessionCoordinating {
    private var snapshot = RecordingSessionSnapshot.idle(permissionStatus: .notDetermined)

    func snapshots() -> AsyncStream<RecordingSessionSnapshot> {
        AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func currentSnapshot() -> RecordingSessionSnapshot { snapshot }
    func refreshPermissionStatus() async {}
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot { snapshot }
    func stop() async -> RecordingSessionResult { .error(.busy) }
    func interrupt(_ reason: RecordingInterruptionReason) async -> RecordingSessionResult { .error(.busy) }
    func recordSystemWakeIfApplicable() async {}
    func reset() async { snapshot = .idle(permissionStatus: snapshot.permissionStatus) }
}
