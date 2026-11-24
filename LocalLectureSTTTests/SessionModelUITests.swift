import AppKit
import SwiftUI
import XCTest
@testable import LocalLectureSTT

@MainActor
final class SessionModelUITests: XCTestCase {
    func testStartupIsLocalOnlyAndBlocksMissingCorruptAndUnsupportedModels() async throws {
        let repo = try UIModelRepository()
        let downloads = UIDownloader()
        let vm = make(repo, downloads)
        XCTAssertFalse(vm.readyToRecord)
        await vm.refresh()
        XCTAssertTrue(vm.loaded); XCTAssertFalse(vm.readyToRecord)
        XCTAssertTrue(vm.blockingReason?.contains("사용 가능한 모델") == true)
        let starts = await downloads.actions
        XCTAssertEqual(starts, [])
        for state in [ModelPackageState.corrupt, .incompatible, .unvalidated, .unsupportedSchema, .inaccessible] {
            await repo.setState(state); await vm.refresh()
            XCTAssertFalse(vm.readyToRecord, "invalid model must not enable recording: \(state)")
        }
        await repo.setState(.usable); await vm.refresh()
        XCTAssertTrue(vm.readyToRecord)
        let reject = ModelManagementViewModel(repository: repo, downloader: downloads, supports: { _ in false })
        await reject.refresh(); XCTAssertFalse(reject.readyToRecord)
        await repo.failInventory(true); await vm.refresh()
        XCTAssertFalse(vm.readyToRecord); XCTAssertNotNil(vm.message)
        XCTAssertEqual(vm.choices.count, 1, "retain visible old inventory without treating it as current")
    }

    func testExplicitDownloadProgressPauseResumeFailureAndRetry() async throws {
        let repo = try UIModelRepository(); let service = UIDownloader()
        let vm = make(repo, service); await vm.refresh()
        let key = await repo.descriptor.key
        await vm.download(key)
        XCTAssertTrue(vm.transferActive); XCTAssertFalse(vm.readyToRecord)
        let id = try XCTUnwrap(vm.downloads.first?.id)
        await vm.controlDownload(id, action: .pause)
        XCTAssertEqual(vm.downloads.first?.phase, .paused); XCTAssertFalse(vm.busy)
        await vm.controlDownload(id, action: .resume)
        XCTAssertTrue(vm.transferActive)
        await service.finish(id, phase: .failed, failure: .init(code: .insufficientCapacity))
        await eventually { vm.downloads.first?.phase == .failed }
        XCTAssertTrue(vm.message?.contains("저장 공간") == true)
        await vm.controlDownload(id, action: .retry)
        await repo.setState(.usable)
        await service.finish(id, phase: .installed)
        await eventually { vm.readyToRecord }
        XCTAssertEqual(vm.selectedKey, key)
        let actions = await service.actions
        XCTAssertEqual(actions, ["start", "pause", "resume", "retry"])
    }

    func testRestartRetainedTransferNeedsExplicitResumeAndFailedResumeDoesNotInventActivity() async throws {
        let repo = try UIModelRepository(); let service = UIDownloader()
        let key = await repo.descriptor.key
        let id = await service.seed(key, phase: .installing)
        let vm = make(repo, service); await vm.refresh()
        XCTAssertEqual(vm.downloads.first?.phase, .paused)
        XCTAssertFalse(vm.transferActive)
        let actions = await service.actions; XCTAssertEqual(actions, [])
        await service.setResumeFailure(true)
        await vm.controlDownload(id, action: .resume)
        XCTAssertFalse(vm.busy); XCTAssertEqual(vm.downloads.first?.phase, .paused)
        XCTAssertNotNil(vm.message)
    }

    func testSecondTransferCannotReplaceObserverAndCancelLeavesExistingModelUsable() async throws {
        let repo = try UIModelRepository(); await repo.setState(.usable)
        let service = UIDownloader(); let key = await repo.descriptor.key
        let old = await service.seed(key, phase: .paused)
        let vm = make(repo, service); await vm.refresh()
        await vm.download(key)
        let current = try XCTUnwrap(vm.downloads.first { $0.phase == .transferring }?.id)
        await vm.controlDownload(old, action: .resume)
        let actions = await service.actions; XCTAssertEqual(actions, ["start"])
        await vm.controlDownload(current, action: .cancel)
        XCTAssertFalse(vm.busy); XCTAssertTrue(vm.readyToRecord)
    }

    func testImportCancellationValidationAndLockedActions() async throws {
        let repo = try UIModelRepository(); let service = UIDownloader()
        var imports = 0
        let vm = ModelManagementViewModel(repository: repo, downloader: service, supports: { _ in true }, importFolder: { _ in
            imports += 1
            if imports == 1 { return nil }
            await repo.setState(.usable)
            return try await .init(disposition: .installed, manifest: repo.manifest(), warning: nil)
        })
        await vm.refresh(); await vm.importModel(nil)
        XCTAssertEqual(imports, 1); XCTAssertFalse(vm.readyToRecord); XCTAssertNil(vm.message)
        await vm.importModel(nil); XCTAssertTrue(vm.readyToRecord)
        let key = await repo.descriptor.key
        vm.recordingLocked = true
        await vm.importModel(nil); await vm.download(key); await vm.prepareDeletion(key); await vm.validate(key)
        XCTAssertEqual(imports, 2); XCTAssertNil(vm.deletion)
        let actions = await service.actions; XCTAssertEqual(actions, [])
        vm.recordingLocked = false
        await repo.setState(.corrupt); await vm.validate(key)
        XCTAssertFalse(vm.readyToRecord); XCTAssertEqual(vm.inventory.first?.state, .corrupt)
    }

    func testDeletionRequiresBothAcknowledgmentsAndRefreshesSelection() async throws {
        let repo = try UIModelRepository(); await repo.setState(.usable)
        await repo.references(.init(sessions: [.init(rootID: StorageRootID(), sessionID: SessionID(), checksumMatches: true)], warnings: ["root unavailable"]))
        let vm = make(repo, UIDownloader()); await vm.refresh()
        let key = await repo.descriptor.key
        await vm.prepareDeletion(key); XCTAssertNotNil(vm.deletion); XCTAssertFalse(vm.readyToRecord)
        await vm.confirmDeletion(acknowledgeReferences: true, acknowledgeIncompleteCoverage: false)
        let before = await repo.deletes; XCTAssertEqual(before, 0)
        await vm.confirmDeletion(acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)
        let after = await repo.deletes; XCTAssertEqual(after, 1)
        XCTAssertNil(vm.deletion); XCTAssertNil(vm.selectedKey); XCTAssertFalse(vm.readyToRecord)
    }

    func testCancelledAndStaleDeletionDoNotClaimRemoval() async throws {
        let repo = try UIModelRepository(); await repo.setState(.usable)
        let vm = make(repo, UIDownloader()); await vm.refresh()
        let key = await repo.descriptor.key
        await vm.prepareDeletion(key); vm.cancelDeletion()
        XCTAssertTrue(vm.readyToRecord)
        await repo.failDelete(true); await vm.prepareDeletion(key)
        await vm.confirmDeletion(acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)
        XCTAssertTrue(vm.message?.contains("staleAssessment") == true)
        XCTAssertTrue(vm.readyToRecord); XCTAssertNil(vm.deletion)
    }

    func testCatalogFailuresPreserveRowsAndNewerReadWins() async throws {
        let catalog = UICatalog()
        let coordinator = CatalogStartupCoordinator(catalog: catalog)
        let first = try item(title: "이전 강의", status: .completed)
        let second = try item(title: "새 강의", status: .interrupted)
        await catalog.set([first]); await coordinator.refreshItems()
        XCTAssertEqual(coordinator.items, [first])
        await catalog.fail(true); await coordinator.refreshItems()
        XCTAssertEqual(coordinator.items, [first]); XCTAssertEqual(coordinator.listFailure, .stepFailed)
        await catalog.fail(false); await catalog.holdNext()
        let slow = Task { await coordinator.refreshItems() }
        await catalog.waitForHeld()
        await catalog.set([second]); await coordinator.refreshItems()
        await catalog.release([first]); await slow.value
        XCTAssertEqual(coordinator.items, [second]); XCTAssertNil(coordinator.listFailure)
    }

    func testSessionLabelsAndModelScreensConstructWithoutNetwork() async throws {
        for status in SessionStatus.allCases { XCTAssertFalse(SessionListRow.status(status).isEmpty) }
        XCTAssertEqual(SessionListRow.duration(7_321_999), "02:02:01")
        let repo = try UIModelRepository(); let downloads = UIDownloader()
        let vm = make(repo, downloads); await vm.refresh()
        let host = NSHostingView(rootView: ModelManagementView(models: vm))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 680)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        let actions = await downloads.actions; XCTAssertEqual(actions, [])
    }

    func testModelWorkOwnsLifecycleUntilPausedAndSupportsExplicitQuit() async throws {
        let repo = try UIModelRepository(); let downloader = UIDownloader(); let authority = LifecycleWorkAuthority()
        let vm = ModelManagementViewModel(repository: repo, downloader: downloader, authority: authority, supports: { _ in true })
        await vm.refresh(); XCTAssertFalse(authority.state().active)
        let key = await repo.descriptor.key
        await vm.download(key); XCTAssertTrue(authority.state().active)
        let termination = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination,
            authority: authority, auxiliary: vm)
        await lifecycle.userWindowCountChanged(0)
        let requests = await termination.count(); XCTAssertEqual(requests, 0)
        let decision = await lifecycle.terminationDecision(); XCTAssertEqual(decision, .terminateLater)
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertTrue(allowed)
        XCTAssertFalse(authority.state().active); XCTAssertFalse(vm.transferActive)
        XCTAssertEqual(vm.downloads.first?.phase, .paused)
        let actions = await downloader.actions; XCTAssertEqual(actions, ["start", "pause"])
    }

    func testClosedWindowWaitsForModelAndErrorSuppressesAutomaticExit() async throws {
        for failure in [false, true] {
            let repo = try UIModelRepository(); let downloader = UIDownloader(); let authority = LifecycleWorkAuthority()
            let vm = ModelManagementViewModel(repository: repo, downloader: downloader, authority: authority, supports: { _ in true })
            await vm.refresh(); await vm.download(await repo.descriptor.key)
            let id = try XCTUnwrap(vm.downloads.first?.id)
            let termination = LifecycleTerminationSpy()
            let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
                recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination,
                authority: authority, auxiliary: vm)
            await lifecycle.start(); await lifecycle.userWindowCountChanged(0)
            await repo.setState(.usable)
            await downloader.finish(id, phase: failure ? .failed : .installed, failure: failure ? .init(code: .transport) : nil)
            await eventually { !vm.busy }
            _ = await lifecycle.terminationDecision()
            let snapshot = await lifecycle.currentSnapshot()
            XCTAssertEqual(snapshot.requiresUserAttention, failure)
            let requests = await termination.count()
            XCTAssertEqual(requests, failure ? 0 : 1)
        }
    }

    func testShutdownCancelsInstallerAndWaitsForCleanup() async throws {
        let repo = try UIModelRepository(); let authority = LifecycleWorkAuthority()
        var entered = false; var cleaned = false
        let vm = ModelManagementViewModel(repository: repo, downloader: UIDownloader(), authority: authority, supports: { _ in true }, importFolder: { _ in
            entered = true
            defer { cleaned = true }
            try await Task.sleep(for: .seconds(60))
            return nil
        })
        await vm.refresh()
        let install = Task { await vm.importModel(nil) }
        await eventually { entered }
        XCTAssertTrue(authority.state().active)
        await vm.quiesce(); await install.value
        XCTAssertTrue(cleaned); XCTAssertFalse(authority.state().active); XCTAssertFalse(vm.busy)
    }

    func testMicrophonePreviewIsExplicitFiniteAndReleasesBeforeRecording() async throws {
        let permission = UIPermission(.authorized); let capture = UIPreviewCapture(); let authority = LifecycleWorkAuthority()
        let preview = MicrophonePreviewViewModel(permission: permission, capture: capture, authority: authority, duration: .milliseconds(150))
        let initialStarts = await capture.starts; XCTAssertEqual(initialStarts, 0)
        await preview.start(); XCTAssertTrue(preview.active); XCTAssertTrue(authority.state().active)
        XCTAssertEqual(preview.name, "Synthetic microphone")
        await capture.level(0.75, noInput: false)
        await eventually { preview.level == 0.75 }
        await capture.level(0, noInput: true)
        await eventually { preview.noInput }
        await eventually { !preview.active }
        XCTAssertFalse(authority.state().active)
        let stopped = await capture.currentLifecycle(); XCTAssertEqual(stopped, .idle)
        await preview.start(); await preview.quiesce()
        XCTAssertFalse(preview.active); XCTAssertFalse(authority.state().active)
    }

    func testDeniedPreviewAndStopDuringPermissionNeverStartCapture() async throws {
        let permission = UIPermission(.denied); let capture = UIPreviewCapture()
        let preview = MicrophonePreviewViewModel(permission: permission, capture: capture)
        await preview.start(); XCTAssertFalse(preview.active)
        XCTAssertTrue(preview.status.contains("permissionDenied"))
        let count = await capture.starts; XCTAssertEqual(count, 0)
        let waiting = UIPermission(.notDetermined, suspend: true)
        let pending = MicrophonePreviewViewModel(permission: waiting, capture: capture)
        let start = Task { await pending.start() }
        await eventually { pending.active }
        await pending.stop(); await start.value
        let stillZero = await capture.starts; XCTAssertEqual(stillZero, 0)
        XCTAssertFalse(pending.active)
    }

    func testPreviewFailureBlocksAutomaticExitButPermitsExplicitQuit() async throws {
        let authority = LifecycleWorkAuthority(); let capture = UIPreviewCapture()
        let preview = MicrophonePreviewViewModel(permission: UIPermission(.authorized), capture: capture, authority: authority)
        let termination = LifecycleTerminationSpy()
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: termination,
            authority: authority, auxiliary: LifecycleAuxiliaryGroup([preview]))
        await lifecycle.start(); await lifecycle.userWindowCountChanged(1)
        await preview.start()
        let before = authority.state().generation
        await lifecycle.userWindowCountChanged(0)
        await capture.holdStop(); await capture.fail()
        await capture.waitForStop()
        XCTAssertTrue(preview.currentWork().requiresAttention, "attention must be set before cleanup releases the last lease")
        XCTAssertTrue(authority.state().active)
        XCTAssertGreaterThan(authority.state().generation, before)
        await capture.releaseStop()
        await eventually { !preview.active }
        _ = await lifecycle.terminationDecision()
        let requests = await termination.count(); XCTAssertEqual(requests, 0)
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertTrue(allowed); XCTAssertFalse(authority.state().active)
    }

    func testFailedTransferPauseCannotReportExplicitQuitCleanupComplete() async throws {
        let repo = try UIModelRepository(); await repo.setState(.corrupt)
        let downloader = UIDownloader(); await downloader.setPauseFailure(true)
        let authority = LifecycleWorkAuthority()
        let vm = ModelManagementViewModel(repository: repo, downloader: downloader, authority: authority, supports: { _ in true })
        await vm.refresh(); await vm.download(await repo.descriptor.key)
        let lifecycle = AppLifecycleCoordinator(recording: LifecycleRecordingStub(), finalization: LifecycleFinalizationStub(),
            recovery: LifecycleRecoveryStub(), activity: LifecycleActivitySpy(), termination: LifecycleTerminationSpy(),
            authority: authority, auxiliary: vm)
        let denied = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertFalse(denied, "an already-visible error must not mask failed transfer cleanup")
        XCTAssertTrue(vm.transferActive); XCTAssertTrue(authority.state().active)
        await downloader.setPauseFailure(false)
        let allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit)
        XCTAssertTrue(allowed); XCTAssertFalse(authority.state().active)
    }

    private func make(_ repo: UIModelRepository, _ downloads: UIDownloader) -> ModelManagementViewModel {
        ModelManagementViewModel(repository: repo, downloader: downloads, supports: { _ in true })
    }
    private func eventually(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("UI state did not settle")
    }
    private func item(title: String, status: SessionStatus) throws -> SessionCatalogItem {
        .init(sessionID: SessionID(), rootID: StorageRootID(), folderName: SessionFolderName(sessionID: SessionID(), createdAt: AbsoluteTime(Date()), timeZone: .gmt), title: title,
            createdAt: AbsoluteTime(Date()), activeDuration: try MediaMilliseconds(5_000), metadataStatus: status,
            captureOutcome: .completed, presence: .present, metadataLastUpdatedAt: AbsoluteTime(Date()), catalogUpdatedAt: AbsoluteTime(Date()))
    }
}

actor UIModelRepository: ModelRepository {
    let descriptor: ModelPackageDescriptor
    var state: ModelPackageState?
    var inventoryFailure = false
    var deletionFailure = false
    var deletes = 0
    var referenceReport = ModelReferenceReport(sessions: [], warnings: [])
    init() throws { descriptor = try BundledModelCatalogLoader().load().entries[0] }
    func setState(_ value: ModelPackageState?) { state = value }
    func failInventory(_ value: Bool) { inventoryFailure = value }
    func failDelete(_ value: Bool) { deletionFailure = value }
    func references(_ value: ModelReferenceReport) { referenceReport = value }
    func manifest() throws -> ModelInstallationManifest { try .init(descriptor: descriptor, origin: .suppliedLocal, installedAt: AbsoluteTime(Date())) }
    func catalog() throws -> BundledModelCatalog { try .init(entries: [descriptor]) }
    func inventory() throws -> [ModelInventoryEntry] {
        if inventoryFailure { throw ModelOperationFailure(.storageUnavailable) }
        guard let state else { return [] }
        return [.init(namespace: "fixture", manifest: try manifest(), state: state, issue: state == .usable ? nil : .integrityMismatch)]
    }
    func validate(_ key: InstalledModelKey) throws -> ModelInventoryEntry { try inventory()[0] }
    func importPackage(from source: ModelImportSourceID, descriptor: ModelPackageDescriptor?, origin: ModelPackageOrigin) throws -> ModelImportResult {
        state = .usable; return try .init(disposition: .installed, manifest: manifest(), warning: nil)
    }
    func prepareDeletion(_ key: InstalledModelKey) -> ModelDeletionAssessment {
        .init(id: UUID(), key: key, packageFingerprint: "fixture", references: referenceReport)
    }
    func delete(_ assessment: ModelDeletionAssessment, confirmation: ModelDeletionConfirmation?) throws -> ModelDeletionResult {
        if deletionFailure { throw ModelOperationFailure(.staleAssessment) }
        deletes += 1; state = nil; return .init(key: assessment.key)
    }
}

actor UIDownloader: ModelDownloading {
    var values: [ModelDownloadID: ModelDownloadSnapshot] = [:]
    var actions: [String] = []
    var resumeFails = false
    var pauseFails = false
    func setPauseFailure(_ value: Bool) { pauseFails = value }
    func seed(_ key: InstalledModelKey, phase: ModelDownloadPhase) -> ModelDownloadID {
        let id = ModelDownloadID(); values[id] = .init(id: id, key: key, generation: 1, phase: phase, completedBytes: 25, totalBytes: 100)
        return id
    }
    func setResumeFailure(_ value: Bool) { resumeFails = value }
    func start(_ key: InstalledModelKey) -> ModelDownloadID { actions.append("start"); return seed(key, phase: .transferring) }
    func retry(_ id: ModelDownloadID) -> ModelDownloadID { actions.append("retry"); values[id]?.phase = .transferring; values[id]?.failure = nil; return id }
    func resume(_ id: ModelDownloadID) throws {
        actions.append("resume"); if resumeFails { throw ModelDownloadFailure(code: .ownership) }; values[id]?.phase = .transferring
    }
    func pause(_ id: ModelDownloadID) throws -> ModelDownloadSnapshot { actions.append("pause"); if pauseFails { throw ModelDownloadFailure(code: .transport) }; values[id]?.phase = .paused; return try snapshot(id) }
    func cancel(_ id: ModelDownloadID) throws -> ModelDownloadSnapshot { actions.append("cancel"); values[id]?.phase = .cancelled; return try snapshot(id) }
    func snapshot(_ id: ModelDownloadID) throws -> ModelDownloadSnapshot { guard let value = values[id] else { throw ModelDownloadFailure(code: .invalidState) }; return value }
    func wait(_ id: ModelDownloadID) throws -> ModelDownloadSnapshot { try snapshot(id) }
    func pending() -> [ModelDownloadPending] { values.values.map { .init(operation: $0.id, snapshot: $0, issue: nil) } }
    func finish(_ id: ModelDownloadID, phase: ModelDownloadPhase, failure: ModelDownloadFailure? = nil) { values[id]?.phase = phase; values[id]?.failure = failure }
}

private actor UICatalog: SessionCataloging {
    var items: [SessionCatalogItem] = []
    var failure = false
    var hold = false
    var held = false
    var continuation: CheckedContinuation<[SessionCatalogItem], Never>?
    func set(_ items: [SessionCatalogItem]) { self.items = items }
    func fail(_ value: Bool) { failure = value }
    func holdNext() { hold = true }
    func waitForHeld() async { while !held { await Task.yield() } }
    func release(_ items: [SessionCatalogItem]) { continuation?.resume(returning: items); continuation = nil }
    func orderedItems() async throws -> [SessionCatalogItem] {
        if failure { throw CatalogError(.stepFailed) }
        if hold { hold = false; held = true; return await withCheckedContinuation { continuation = $0 } }
        return items
    }
    func reconcile() -> CatalogReconciliationReport { .init(rootResults: [], issues: [], recoveredFromCorruption: false) }
}

private actor UIPermission: MicrophonePermissionAuthorizing {
    let value: MicrophonePermissionStatus
    let suspend: Bool
    init(_ value: MicrophonePermissionStatus, suspend: Bool = false) { self.value = value; self.suspend = suspend }
    func authorizationStatus() -> MicrophonePermissionStatus { value }
    func requestAuthorization() async -> MicrophonePermissionStatus {
        if suspend { try? await Task.sleep(for: .seconds(30)) }
        return .authorized
    }
}
private actor UIPreviewCapture: MicrophoneCapturing {
    var starts = 0
    var shouldHoldStop = false
    var stopEntered = false
    var stopWaiter: CheckedContinuation<Void, Never>?
    func holdStop() { shouldHoldStop = true }
    func waitForStop() async { while !stopEntered { await Task.yield() } }
    func releaseStop() { stopWaiter?.resume(); stopWaiter = nil }
    func fail() { events?.yield(.terminalFailure(.activeDeviceDisconnected)) }
    var running = false
    var inputs: AsyncStream<InputSignalSample>.Continuation?
    var recording: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    var speech: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    var events: AsyncStream<CaptureEvent>.Continuation?
    func currentLifecycle() -> CaptureLifecycle { running ? .running : .idle }
    func start() -> CaptureHandle {
        starts += 1; running = true
        let r = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let s = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let e = AsyncStream<CaptureEvent>.makeStream()
        let i = AsyncStream<InputSignalSample>.makeStream()
        recording = r.continuation; speech = s.continuation; events = e.continuation; inputs = i.continuation
        return .init(generation: 1, device: .init(identity: "fixture", displayName: "Synthetic microphone"),
            recordingPCM: r.stream, speechPCM: s.stream, events: e.stream, inputSignalStates: i.stream)
    }
    func stop() async {
        if shouldHoldStop {
            shouldHoldStop = false; stopEntered = true
            await withCheckedContinuation { stopWaiter = $0 }
        }
        running = false; recording?.finish(); speech?.finish(); events?.finish(); inputs?.finish()
    }
    func level(_ value: Float, noInput: Bool) {
        inputs?.yield(.init(generation: 1, sequence: 0, monotonicSeconds: 1, normalizedLevel: value,
            rmsDBFS: -10, peakDBFS: -5, state: noInput ? .noInput : .active))
    }
}
