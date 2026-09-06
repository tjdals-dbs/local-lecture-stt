import Foundation

struct RecoveryStatusPresentation: Equatable {
    enum Action: Equatable { case retry, reauthorize(StorageRootID) }
    struct Item: Identifiable, Equatable {
        let issue: SessionRecoveryIssue
        let title: String
        let firstError: String?
        let warnings: [String]
        let action: Action?
        var id: String { issue.id }
    }
    struct RootNotice: Identifiable, Equatable {
        let rootID: StorageRootID
        let error: StorageErrorCode
        var id: StorageRootID { rootID }
    }
    let title: String
    let detail: String
    let items: [Item]
    let rootNotices: [RootNotice]
    let catalogWarning: CatalogErrorCode?
    let discoveryWarning: String?

    static func make(report: SessionRecoveryReport,
                     historicalReauthorizationErrors: [StorageRootID: StorageErrorCode] = [:]) -> Self {
        let items = report.items.map(classify)
        let rootNotices = historicalReauthorizationErrors.map { RootNotice(rootID: $0.key, error: $0.value) }
            .sorted { $0.rootID.rawValue.uuidString < $1.rootID.rawValue.uuidString }
        let hasAttention = !items.isEmpty || !rootNotices.isEmpty || report.catalogWarning != nil || report.discoveryWarning != nil
        return .init(title: hasAttention ? "세션 복구 결과" : "세션 복구 확인 완료",
                     detail: hasAttention ? "각 항목의 원인과 필요한 조치를 확인하세요." : "복구할 미완료 세션이 없습니다.",
                     items: items, rootNotices: rootNotices,
                     catalogWarning: report.catalogWarning, discoveryWarning: report.discoveryWarning)
    }

    private static func classify(_ issue: SessionRecoveryIssue) -> Item {
        let title: String
        let action: Action?
        switch issue.code {
        case .queued: title = "복구 작업 대기"; action = nil
        case .audioReadyAwaitingRemainingFinalization: title = "정상 녹음 오디오 완료 — 나머지 마무리 대기"; action = nil
        case .audioRevalidated:
            switch issue.captureOutcome {
            case .completed: title = "정상 녹음 오디오 재검증 완료"
            case .interrupted: title = "중단된 녹음 오디오 재검증 완료"
            default: title = "오디오 재검증 완료 — 녹음 결과 확인 필요"
            }
            action = nil
        case .interruptedRecordingRecovered: title = "중단된 녹음 오디오 복구 완료 — 나머지 마무리 대기"; action = nil
        case .preparationAbandoned: title = "미완료 준비 세션 정리됨"; action = nil
        case .rootUnavailable: title = "저장 폴더 재승인 필요"; action = .reauthorize(issue.rootID)
        case .rootReadOnly: title = "저장 폴더 쓰기 권한 필요"; action = .reauthorize(issue.rootID)
        case .metadataMissing: title = "metadata 없음 — 원본 보존"; action = nil
        case .metadataCorrupt: title = "metadata 손상 — 원본 보존"; action = nil
        case .metadataUnsupported: title = "지원하지 않는 metadata schema — 원본 보존"; action = nil
        case .checkpointCorrupt: title = "checkpoint 손상 — 원본 보존"; action = nil
        case .checkpointUnsupported: title = "지원하지 않는 checkpoint schema — 원본 보존"; action = nil
        case .checkpointSessionMismatch: title = "checkpoint session ID 불일치 — 원본 보존"; action = nil
        case .checkpointInconsistent: title = "checkpoint 단계 불일치 — 원본 보존"; action = nil
        case .sessionIDMismatch: title = "폴더와 metadata ID 불일치 — 원본 보존"; action = nil
        case .duplicateSession: title = "중복 session ID — 원본 보존"; action = nil
        case .unsafeLayout: title = "안전하지 않은 파일 layout — 원본 보존"; action = nil
        case .missingRecoverySource: title = "recovery 원본 없음 — 확인 필요"; action = issue.retryable ? .retry : nil
        case .terminalInconsistent: title = "완료 상태와 최종 오디오 불일치 — 원본 보존"; action = nil
        case .finalizationFailed: title = "오디오 복구 실패 — 원본 보존"; action = issue.retryable ? .retry : nil
        case .currentProcessActive: title = "현재 녹음/마무리 작업 보호됨"; action = nil
        case .catalogRefreshFailed: title = "카탈로그 갱신 실패"; action = .retry
        case .cancelled: title = "복구 작업 취소됨"; action = issue.retryable ? .retry : nil
        }
        let warnings = issue.warnings.filter { $0 != issue.warning }
        return .init(issue: issue, title: title, firstError: issue.warning, warnings: warnings, action: action)
    }
}

@MainActor
final class CatalogStartupCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case ready(CatalogReconciliationReport)
        case failed(CatalogErrorCode)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var recoverySnapshot: SessionRecoverySnapshot?
    private let catalog: any SessionCataloging
    private let recovery: SessionRecoveryCoordinator?
    private var startupTask: Task<Void, Never>?
    private var recoveryObservation: Task<Void, Never>?
    private var refreshPending = false
    private var recoveryRefreshRequested = false
    private var recoveryRetryRequested = false

    init(catalog: any SessionCataloging, recovery: SessionRecoveryCoordinator? = nil) {
        self.catalog = catalog
        self.recovery = recovery
    }

    func start() {
        if case .ready = state { return }
        beginReconciliation()
    }

    func refreshAfterRootChange() {
        // StorageRootViewModel invokes this after both selection and successful
        // reauthorization.  It reaches the app-lifetime recovery owner, not
        // merely the derived SQLite reconciliation.
        recoveryRefreshRequested = true
        if startupTask != nil { refreshPending = true }
        else { beginReconciliation() }
    }

    func retryRecovery() {
        // This is an operator retry, not a root refresh.  Keep that intent
        // through any reconciliation already in flight so the T08 owner gets
        // its required `retry: true` request once the current pass settles.
        recoveryRetryRequested = true
        if startupTask != nil { refreshPending = true }
        else { beginReconciliation() }
    }

    private func beginReconciliation() {
        if startupTask != nil { return }
        state = .starting
        let refreshRecovery = recoveryRefreshRequested
        let retryRecovery = recoveryRetryRequested
        recoveryRefreshRequested = false
        recoveryRetryRequested = false
        startupTask = Task { [weak self] in
            guard let self else { return }
            if let recovery = self.recovery {
                self.observeRecovery(recovery)
                if retryRecovery { await recovery.retry() }
                if refreshRecovery { await recovery.refresh() }
                else if !retryRecovery { await recovery.start() }
                // Only discovery is a recording-start gate.  Media recovery
                // deliberately continues in the app lifetime after this point.
                await recovery.waitForInitialDiscovery()
            }
            do {
                let report = try await self.catalog.reconcile()
                self.state = .ready(report)
            } catch let error as CatalogError {
                self.state = .failed(error.code)
            } catch {
                self.state = .failed(.filesystemScanFailed)
            }
            self.startupTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.beginReconciliation()
            }
        }
    }

    private func observeRecovery(_ recovery: SessionRecoveryCoordinator) {
        guard recoveryObservation == nil else { return }
        recoveryObservation = Task { [weak self] in
            let stream = await recovery.snapshots()
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                self.recoverySnapshot = value
            }
        }
    }
}
