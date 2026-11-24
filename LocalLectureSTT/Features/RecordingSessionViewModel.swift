import Foundation
import SwiftUI

enum RecordingSessionViewDisplayState: Sendable, Equatable {
    case configuration
    case preparing
    case recording
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
}

@MainActor
final class RecordingSessionViewModel: ObservableObject {
    @Published var title = ""
    @Published var languageMode: LanguageMode = .korean
    @Published private(set) var snapshot: RecordingSessionSnapshot = .idle()
    @Published private(set) var finalizations: [AudioFinalizationSnapshot] = []

    let modelName: String?
    private let coordinator: any RecordingSessionCoordinating
    private let timeZone: @MainActor @Sendable () -> TimeZone
    private var observationTask: Task<Void, Never>?
    private let finalization: AudioFinalizationCoordinator?
    private var finalizationObservation: Task<Void, Never>?

    init(
        coordinator: any RecordingSessionCoordinating,
        finalization: AudioFinalizationCoordinator? = nil,
        modelName: String? = nil,
        timeZone: @escaping @MainActor @Sendable () -> TimeZone = { .current }
    ) {
        self.modelName = modelName
        self.coordinator = coordinator
        self.finalization = finalization
        self.timeZone = timeZone
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
        await finalization?.enqueue(.init(location: value.location), retry: true)
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

    func startRecording() async {
        do {
            _ = try await coordinator.start(RecordingStartConfiguration(
                title: title,
                languageMode: languageMode,
                timeZone: timeZone()
            ))
        } catch {
            snapshot = await coordinator.currentSnapshot()
        }
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

    var displayState: RecordingSessionViewDisplayState {
        switch snapshot.phase {
        case .idle: .configuration
        case .preparing: .preparing
        case .recording: .recording
        case .securing: .securing
        case .securedAwaitingFinalization: .secured
        case .interrupted: .interrupted
        case .error: .error
        }
    }

    var actions: RecordingSessionViewActions {
        RecordingSessionViewActions(
            canEditConfiguration: snapshot.canStart,
            canStart: snapshot.canStart,
            canStop: snapshot.canStop,
            canReset: snapshot.canReset
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
