import Combine
import Foundation

/// App-owned presentation state. Loading is local-only; transfer methods are
/// invoked only by explicit user actions. Repository leases remain authoritative.
@MainActor
final class ModelManagementViewModel: ObservableObject, LifecycleAuxiliaryWorking {
    @Published private(set) var catalog: [ModelPackageDescriptor] = []
    @Published private(set) var inventory: [ModelInventoryEntry] = []
    @Published private(set) var selectedKey: InstalledModelKey?
    @Published private(set) var operation: String? { didSet { publishWork() } }
    @Published private(set) var message: String?
    @Published private(set) var loaded = false
    @Published private(set) var inventoryIsCurrent = false
    @Published private(set) var downloads: [ModelDownloadSnapshot] = [] { didSet { publishWork() } }
    @Published private(set) var pendingWarnings: [String] = [] { didSet { publishWork() } }
    @Published private(set) var deletion: ModelDeletionAssessment? { didSet { publishWork() } }
    @Published var recordingLocked = false
    private let repository: any ModelRepository
    private let downloader: any ModelDownloading
    private let importFolder: @MainActor (ModelPackageDescriptor?) async throws -> ModelImportResult?
    private let supports: @Sendable (ModelPackageDescriptor) -> Bool
    private var monitor: Task<Void, Never>?
    private var monitorGeneration = 0
    private var started = false
    private let authority: LifecycleWorkAuthority?
    private var workLease: UUID?
    private var workObservers: [UUID: AsyncStream<LifecycleAuxiliarySnapshot>.Continuation] = [:]
    private var operationCancel: (() -> Void)?
    private var quiescing = false
    private var needsAttention = false { didSet { publishWork() } }
    private var previousAttention = false

    init(repository: any ModelRepository, downloader: any ModelDownloading,
         authority: LifecycleWorkAuthority? = nil,
         supports: @escaping @Sendable (ModelPackageDescriptor) -> Bool,
         importFolder: @escaping @MainActor (ModelPackageDescriptor?) async throws -> ModelImportResult? = { _ in nil }) {
        self.repository = repository; self.downloader = downloader
        self.supports = supports; self.importFolder = importFolder; self.authority = authority
    }

    var choices: [ModelPackageDescriptor] {
        inventory.compactMap { entry in
            guard entry.state == .usable, let value = entry.manifest?.descriptor, supports(value) else { return nil }
            return value
        }
    }
    var selectedDescriptor: ModelPackageDescriptor? { choices.first { $0.key == selectedKey } }
    var transferActive: Bool { downloads.contains { $0.phase == .transferring || $0.phase == .installing } }
    var busy: Bool { quiescing || operation != nil || transferActive || deletion != nil }
    var readyToRecord: Bool { loaded && inventoryIsCurrent && !busy && !recordingLocked && selectedDescriptor != nil }
    var blockingReason: String? {
        if recordingLocked { return "녹음 작업이 끝나면 모델을 변경할 수 있습니다." }
        if let operation { return operation }
        if transferActive { return "모델 다운로드와 검증이 끝날 때까지 기다려 주세요." }
        if deletion != nil { return "모델 삭제 확인을 마쳐 주세요." }
        if !loaded { return "설치된 모델을 확인하는 중…" }
        if !inventoryIsCurrent { return "모델 상태를 확인하지 못했습니다. 모델 관리에서 다시 확인하세요." }
        if selectedDescriptor == nil { return "사용 가능한 모델이 없습니다. 모델 관리에서 다운로드하거나 가져오세요." }
        return nil
    }
    func select(_ key: InstalledModelKey?) {
        guard !busy, !recordingLocked, choices.contains(where: { $0.key == key }) else { return }
        selectedKey = key
    }
    func loadIfNeeded() {
        guard !started else { return }; started = true
        Task { await refresh() }
    }
    func refresh() async {
        guard !busy, !recordingLocked else { return }
        needsAttention = false
        operation = "모델 파일을 검증하는 중…"; message = nil
        defer { operation = nil; loaded = true }
        do {
            catalog = try await cancellable { try await self.repository.catalog().entries }
            let pending = try await cancellable { try await self.downloader.pending() }
            downloads = pending.compactMap { entry in
                guard var value = entry.snapshot else { return nil }
                if value.phase == .transferring || value.phase == .installing {
                    value.phase = .paused; value.resumable = true
                }
                return value
            }
            pendingWarnings = pending.compactMap { $0.issue.map { "보존된 다운로드 확인 필요: \($0.rawValue)" } }
            try await reloadInventory()
            // Persisted transferring work after a restart is NOT auto-resumed.
            // This presentation-only paused state never changes the persisted journal.
        } catch { inventoryIsCurrent = false; needsAttention = !quiescing; message = Self.errorMessage(error) }
    }
    private func reloadInventory() async throws {
        inventoryIsCurrent = false
        inventory = try await cancellable { try await self.repository.inventory() }
        inventoryIsCurrent = true
        if !choices.contains(where: { $0.key == selectedKey }) {
            selectedKey = choices.first(where: { item in catalog.first?.key == item.key })?.key ?? choices.first?.key
        }
    }
    func validate(_ key: InstalledModelKey) async {
        guard !busy, !recordingLocked else { return }
        needsAttention = false
        operation = "모델 파일을 검증하는 중…"; message = nil; inventoryIsCurrent = false
        defer { operation = nil }
        do { _ = try await cancellable { try await self.repository.validate(key) }; try await reloadInventory() }
        catch { needsAttention = !quiescing; message = Self.errorMessage(error) }
    }
    func importModel(_ descriptor: ModelPackageDescriptor?) async {
        guard !busy, !recordingLocked else { return }
        needsAttention = false
        operation = "모델 폴더 선택 · 복사 및 검증 중…"; message = nil
        defer { operation = nil }
        do {
            if let result = try await cancellable({ try await self.importFolder(descriptor) }) {
                try await reloadInventory(); selectInstalled(result.manifest.descriptor.key)
                message = result.warning.map { "설치 완료 · 확인 필요: \($0.rawValue)" } ?? "모델 가져오기 완료"
                needsAttention = result.warning != nil
            }
        } catch { needsAttention = !quiescing; message = Self.errorMessage(error) }
    }
    private func selectInstalled(_ key: InstalledModelKey) {
        if choices.contains(where: { $0.key == key }) { selectedKey = key }
    }
    func download(_ key: InstalledModelKey) async {
        guard !busy, !recordingLocked else { return }
        needsAttention = false
        operation = "다운로드 준비 중…"; message = nil
        defer { operation = nil }
        do {
            let id = try await cancellable { try await self.downloader.start(key) }
            setDownload(try await downloader.snapshot(id)); watch(id)
        } catch { needsAttention = !quiescing; message = Self.errorMessage(error) }
    }
    enum DownloadAction { case pause, resume, retry, cancel }
    func controlDownload(_ id: ModelDownloadID, action: DownloadAction) async {
        guard !quiescing, operation == nil, deletion == nil, !recordingLocked else { return }
        // One transfer observer owns the UI. A second retained operation cannot
        // steal it by resuming/cancelling while the first one is running.
        guard !downloads.contains(where: { $0.id != id && ($0.phase == .transferring || $0.phase == .installing) }) else { return }
        var shouldWatch = downloads.contains { $0.id == id && ($0.phase == .transferring || $0.phase == .installing) }
        needsAttention = false
        operation = "다운로드 상태 변경 중…"; message = nil
        monitorGeneration += 1; monitor?.cancel(); monitor = nil
        defer { operation = nil }
        var currentID = id
        do {
            switch action {
            case .pause: setDownload(try await cancellable { try await self.downloader.pause(id) }); shouldWatch = false
            case .cancel: setDownload(try await cancellable { try await self.downloader.cancel(id) }); shouldWatch = false
            case .resume: try await cancellable { try await self.downloader.resume(id) }; shouldWatch = true; setDownload(try await downloader.snapshot(id))
            case .retry:
                currentID = try await cancellable { try await self.downloader.retry(id) }
                shouldWatch = true
                downloads.removeAll { $0.id == id }
                setDownload(try await downloader.snapshot(currentID))
            }
            if let value = downloads.first(where: { $0.id == currentID }), value.phase == .installed {
                try await reloadInventory(); selectInstalled(value.key)
                needsAttention = value.result?.warning != nil || value.failure != nil
            }
        } catch { needsAttention = !quiescing; message = Self.errorMessage(error) }
        // Even a failed pause/cancel must keep observing the actual transfer.
        if shouldWatch { watch(currentID) }
    }
    private func setDownload(_ snapshot: ModelDownloadSnapshot) {
        downloads.removeAll { $0.id == snapshot.id }; downloads.append(snapshot)
    }
    private func watch(_ id: ModelDownloadID) {
        monitorGeneration += 1; let generation = monitorGeneration
        monitor?.cancel()
        monitor = Task { [weak self, downloader] in
            while !Task.isCancelled {
                do {
                    let value = try await downloader.snapshot(id)
                    guard let self, self.monitorGeneration == generation, !Task.isCancelled else { return }
                    self.setDownload(value)
                    if value.terminal || value.phase == .paused {
                        if value.phase == .installed {
                            self.operation = "모델 상태를 확인하는 중…"
                            defer { self.operation = nil }
                            try await self.reloadInventory(); self.selectInstalled(value.key)
                            self.message = value.result?.warning.map { "설치 완료 · 확인 필요: \($0.rawValue)" } ?? "모델 설치 완료"
                            self.needsAttention = value.result?.warning != nil || value.failure != nil
                        } else if let failure = value.failure { self.needsAttention = true; self.message = Self.errorMessage(failure) }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(350))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.monitorGeneration == generation else { return }
                    self.needsAttention = !self.quiescing; self.message = Self.errorMessage(error); return
                }
            }
        }
    }
    func prepareDeletion(_ key: InstalledModelKey) async {
        guard !busy, !recordingLocked else { return }
        needsAttention = false
        operation = "이 모델을 사용한 세션을 확인하는 중…"; message = nil
        defer { operation = nil }
        do { deletion = try await cancellable { try await self.repository.prepareDeletion(key) } }
        catch { needsAttention = !quiescing; message = Self.errorMessage(error) }
    }
    func cancelDeletion() { guard operation == nil else { return }; deletion = nil }
    func confirmDeletion(acknowledgeReferences: Bool, acknowledgeIncompleteCoverage: Bool) async {
        guard !quiescing, operation == nil, !recordingLocked, let assessment = deletion else { return }
        guard (assessment.references.sessions.isEmpty || acknowledgeReferences),
              (assessment.references.isComplete || acknowledgeIncompleteCoverage) else { return }
        needsAttention = false
        operation = "모델 삭제 중…"; message = nil; inventoryIsCurrent = false
        defer { operation = nil; deletion = nil }
        do {
            _ = try await cancellable { try await self.repository.delete(assessment, confirmation: .init(assessmentID: assessment.id,
                acknowledgeReferences: acknowledgeReferences, acknowledgeIncompleteCoverage: acknowledgeIncompleteCoverage)) }
            try await reloadInventory(); message = "모델을 삭제했습니다. 녹음과 기록은 보존됩니다."
        } catch {
            needsAttention = !quiescing; message = Self.errorMessage(error)
            // A partial delete can invalidate the previously selected package.
            do { try await reloadInventory() } catch { inventoryIsCurrent = false }
        }
    }
    private func cancellable<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        operationCancel = { task.cancel() }
        defer { operationCancel = nil }
        if quiescing { task.cancel() }
        return try await task.value
    }
    func currentWork() -> LifecycleAuxiliarySnapshot {
        .init(active: operation != nil || transferActive || quiescing,
              requiresAttention: needsAttention || deletion != nil || !pendingWarnings.isEmpty ||
                inventory.contains { $0.state != .usable } || downloads.contains {
                    $0.phase == .failed || ($0.phase == .installed && ($0.result?.warning != nil || $0.failure != nil))
                })
    }
    func workSnapshots() -> AsyncStream<LifecycleAuxiliarySnapshot> {
        let id = UUID()
        let pair = AsyncStream<LifecycleAuxiliarySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        workObservers[id] = pair.continuation; pair.continuation.yield(currentWork())
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.workObservers[id] = nil } }
        return pair.stream
    }
    private func publishWork() {
        let value = currentWork()
        if value.requiresAttention, !previousAttention, let authority {
            // Invalidate a cached automatic-exit reply before the async observer
            // can see an error. Attention does not prevent an explicit safe quit.
            let invalidation = authority.admit(); authority.release(invalidation)
        }
        previousAttention = value.requiresAttention
        if value.active, workLease == nil { workLease = authority?.admit() }
        if !value.active, let lease = workLease { authority?.release(lease); workLease = nil }
        workObservers.values.forEach { $0.yield(value) }
    }
    func quiesce() async {
        if quiescing {
            while quiescing { try? await Task.sleep(for: .milliseconds(10)) }
            return
        }
        quiescing = true
        // Existing lease/admission must not be invalidated by shutdown itself.
        operationCancel?()
        while operation != nil {
            operationCancel?()
            try? await Task.sleep(for: .milliseconds(10))
        }
        monitorGeneration += 1; monitor?.cancel(); monitor = nil
        for value in downloads where value.phase == .transferring || value.phase == .installing {
            do { setDownload(try await downloader.pause(value.id)) }
            catch { needsAttention = true; message = Self.errorMessage(error) }
        }
        quiescing = false; publishWork()
    }

    static func errorMessage(_ error: Error) -> String {
        if let value = error as? ModelDownloadFailure {
            let detail: String
            switch value.code {
            case .insufficientCapacity: detail = "모델 설치에 필요한 저장 공간이 부족합니다."
            case .capacityUnknown: detail = "사용 가능한 저장 공간을 확인하지 못했습니다."
            case .transport, .httpStatus: detail = "다운로드에 실패했습니다. 인터넷 연결을 확인하고 다시 시도하세요."
            case .install: detail = "모델 검증 또는 설치에 실패했습니다."
            default: detail = "다운로드 상태를 확인하고 다시 시도하세요."
            }
            return "\(detail) (\(value.code.rawValue))" + (value.repository.map { " · \(errorMessage($0))" } ?? "")
                + (value.cleanup.map { " · 정리 오류: \($0.rawValue)" } ?? "")
        }
        let failure = (error as? ModelOperationFailure) ?? ModelOperationFailure((error as? ModelRepositoryCode) ?? .storageUnavailable)
        let detail = failure.cause == .busy ? "다른 작업에서 모델을 사용 중입니다. 작업이 끝난 뒤 다시 시도하세요." :
            failure.cause == .integrityMismatch ? "모델 파일이 손상되었거나 선택한 모델과 다릅니다." :
            failure.cause == .scopeDenied ? "모델 폴더 접근 권한이 필요합니다. 폴더를 다시 선택하세요." :
            failure.cause == .staleAssessment ? "모델 상태가 바뀌었습니다. 삭제 요청을 다시 확인하세요." : "모델 작업을 완료하지 못했습니다."
        return "\(detail) (\(failure.cause.rawValue))" + (failure.cleanupIssue.map { " · 정리 오류: \($0.rawValue)" } ?? "")
    }
}
