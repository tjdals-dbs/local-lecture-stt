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

    private let coordinator: any RecordingSessionCoordinating
    private let timeZone: @MainActor @Sendable () -> TimeZone
    private var observationTask: Task<Void, Never>?

    init(
        coordinator: any RecordingSessionCoordinating,
        timeZone: @escaping @MainActor @Sendable () -> TimeZone = { .current }
    ) {
        self.coordinator = coordinator
        self.timeZone = timeZone
    }

    static var preview: RecordingSessionViewModel {
        RecordingSessionViewModel(coordinator: PreviewRecordingSessionCoordinator())
    }

    func startObserving() {
        guard observationTask == nil else { return }
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
    func reset() async { snapshot = .idle(permissionStatus: snapshot.permissionStatus) }
}
