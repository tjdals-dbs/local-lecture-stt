import Foundation

actor SessionCatalogReconciler: SessionCataloging {
    private let scanner: any SessionFileScanning
    private let store: any SessionCatalogStore
    private let now: @Sendable () -> AbsoluteTime
    private var mutationGeneration: UInt64 = 0
    private var publishing = false
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []

    init(scanner: any SessionFileScanning, store: any SessionCatalogStore, now: @escaping @Sendable () -> AbsoluteTime = { AbsoluteTime(Date()) }) {
        self.scanner = scanner
        self.store = store
        self.now = now
    }

    func reconcile() async throws -> CatalogReconciliationReport {
        let generation = mutationGeneration
        let scanned: [RootScanResult]
        do {
            scanned = try await scanner.scan()
        } catch let error as StorageError {
            switch error.code {
            case .registryCorrupt, .registryUnsupported:
                throw CatalogError(.storageRootRegistryFailed)
            default:
                throw CatalogError(.filesystemScanFailed)
            }
        }
        let results = try await withConflictIssues(scanned)
        let issues = results.flatMap(\.issues)
        let recovered = await store.recoveredFromCorruption()
        await acquirePublication()
        guard generation == mutationGeneration else {
            releasePublication()
            return try await reconcile()
        }
        // Every publication supersedes older scans, including scans of a title
        // from before an edit. Serialize the store await with explicit deletion.
        mutationGeneration &+= 1
        do { try await store.apply(results, catalogUpdatedAt: now()) }
        catch { releasePublication(); throw error }
        releasePublication()
        return CatalogReconciliationReport(rootResults: results, issues: issues, recoveredFromCorruption: recovered)
    }

    func orderedItems() async throws -> [SessionCatalogItem] { try await store.orderedItems() }

    func removeTrashedSession(at location: SessionLocation) async throws {
        mutationGeneration &+= 1
        await acquirePublication()
        defer { mutationGeneration &+= 1; releasePublication() }
        try await store.removeTrashedSession(at: location)
    }

    private func acquirePublication() async {
        if publishing { await withCheckedContinuation { publicationWaiters.append($0) } }
        else { publishing = true }
    }
    private func releasePublication() {
        if publicationWaiters.isEmpty { publishing = false }
        else { publicationWaiters.removeFirst().resume() }
    }

    /// A file catalog is authoritative only when a single scan gives each session one
    /// unambiguous location.  Keep prior catalog rows unreadable rather than replacing
    /// or sweeping them when folders conflict.
    private func withConflictIssues(_ scanned: [RootScanResult]) async throws -> [RootScanResult] {
        var idCounts: [SessionID: Int] = [:]
        var locationCounts: [String: Int] = [:]
        for result in scanned {
            for projection in result.projections {
                idCounts[projection.location.sessionID, default: 0] += 1
                let location = "\(projection.location.rootID.rawValue.uuidString)/\(projection.location.folderName.rawValue)"
                locationCounts[location, default: 0] += 1
            }
        }
        var results: [RootScanResult] = []
        for result in scanned {
            var projections: [CatalogProjection] = []
            var unreadable = Set(result.unreadableFolderNames)
            var issues = result.issues
            for projection in result.projections {
                let location = "\(projection.location.rootID.rawValue.uuidString)/\(projection.location.folderName.rawValue)"
                let code: CatalogIssueCode?
                if idCounts[projection.location.sessionID, default: 0] > 1 { code = .duplicateSessionID }
                else if locationCounts[location, default: 0] > 1 { code = .locationConflict }
                else { code = nil }
                if let code {
                    let issue = CatalogIssue(code: code, rootID: result.rootID, folderName: projection.location.folderName.rawValue)
                    issues.append(issue)
                    unreadable.insert(projection.location.folderName.rawValue)
                } else {
                    if let existing = try await store.sessionID(at: projection.location.rootID, folderName: projection.location.folderName), existing != projection.location.sessionID {
                        // Preserve the last known row and mark it error; never let the
                        // file projection overwrite a different identity at this location.
                        issues.append(CatalogIssue(code: .locationConflict, rootID: result.rootID, folderName: projection.location.folderName.rawValue))
                        unreadable.insert(projection.location.folderName.rawValue)
                    } else {
                        projections.append(projection)
                    }
                }
            }
            results.append(RootScanResult(rootID: result.rootID, outcome: result.outcome, projections: projections, unreadableFolderNames: unreadable.sorted(), missingFolderNames: result.missingFolderNames, issues: issues))
        }
        return results
    }
}

actor UnavailableSessionCatalog: SessionCataloging {
    private let error: CatalogErrorCode
    init(error: CatalogErrorCode) { self.error = error }
    func reconcile() async throws -> CatalogReconciliationReport { throw CatalogError(error) }
    func orderedItems() async throws -> [SessionCatalogItem] { throw CatalogError(error) }
}

/// App-lifetime owner for startup and root-change recovery.  Discovery is
/// short-lived and file-only; slow media work is submitted to the one existing
/// T08 coordinator.  Cancelling a view observation never cancels this owner.
actor SessionRecoveryCoordinator {
    private let authority: LifecycleWorkAuthority?
    private let scanner: any SessionRecoveryScanning
    private let persistence: any SessionRecoveryPersisting
    private let finalization: AudioFinalizationCoordinator
    private let catalog: any SessionCataloging
    private let activity: SessionActivityRegistry?
    private let now: @Sendable () -> AbsoluteTime

    private var generation: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var refreshPending = false
    private var snapshot = SessionRecoverySnapshot(generation: 0, phase: .idle, report: nil)
    private var observers: [UUID: AsyncStream<SessionRecoverySnapshot>.Continuation] = [:]
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelling = false
    private var lifecycleQuiescing = false
    private var ownedFinalizations: [SessionLocation] = []
    private var cancellationIssues: [SessionRecoveryIssue] = []

    init(
        scanner: any SessionRecoveryScanning,
        persistence: any SessionRecoveryPersisting,
        finalization: AudioFinalizationCoordinator,
        catalog: any SessionCataloging,
        activity: SessionActivityRegistry? = nil,
        authority: LifecycleWorkAuthority? = nil,
        now: @escaping @Sendable () -> AbsoluteTime = { AbsoluteTime(Date()) }
    ) {
        self.scanner = scanner
        self.persistence = persistence
        self.finalization = finalization
        self.catalog = catalog
        self.activity = activity
        self.authority = authority
        self.now = now
    }

    func snapshots() -> AsyncStream<SessionRecoverySnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func currentSnapshot() -> SessionRecoverySnapshot { snapshot }

    func start() {
        guard operation == nil else { return }
        launch(explicitRetry: false)
    }

    func refresh() {
        if cancelling { refreshPending = true }
        else if operation == nil { launch(explicitRetry: false) }
        else { refreshPending = true }
    }

    /// A retry is meaningful only after a settled result.  While a pass owns a
    /// T08 job this joins it; it must not queue a second worker behind it.
    func retry() {
        guard !cancelling else { refreshPending = true; return }
        guard operation == nil else { return }
        launch(explicitRetry: true)
    }

    /// Recording start may await this only for candidate discovery, never for
    /// export/verification.  That keeps a blocked recovery media gate from
    /// delaying a new essential recording.
    func waitForInitialDiscovery() async {
        if snapshot.phase != .idle && snapshot.phase != .discovering { return }
        if operation == nil { launch(explicitRetry: false) }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    /// Testable/app-level settlement boundary: unlike discovery this waits for
    /// the owned recovery pass (including its T08 job) to release resources.
    func waitForCurrentPassSettlement() async {
        if operation == nil && !cancelling { return }
        await withCheckedContinuation { settlementWaiters.append($0) }
    }

    func quiesceOwnedRecovery() async {
        lifecycleQuiescing = true
        await cancelOwnedRecovery()
        refreshPending = false // wake or a later explicit refresh will discover durable work
        lifecycleQuiescing = false
    }

    func cancelOwnedRecovery() async {
        if cancelling { await waitForCurrentPassSettlement(); return }
        cancelling = true
        generation &+= 1 // invalidates every stale continuation before cleanup begins
        let task = operation
        operation?.cancel()
        for location in ownedFinalizations { _ = await finalization.cancel(at: location) }
        await task?.value
        ownedFinalizations.removeAll()
        operation = nil
        let retained = mergedCancellationReport(snapshot.report, additions: cancellationIssues)
        snapshot = .init(generation: generation, phase: .cancelled, report: retained)
        publish()
        resumeDiscoveryWaiters()
        resumeSettlementWaiters()
        cancelling = false
        if refreshPending && !lifecycleQuiescing { refreshPending = false; launch(explicitRetry: false) }
    }

    private func launch(explicitRetry: Bool) {
        let incremented = generation.addingReportingOverflow(1)
        guard !incremented.overflow else { return }
        generation = incremented.partialValue
        cancellationIssues.removeAll()
        let pass = generation
        snapshot = .init(generation: pass, phase: .discovering, report: nil)
        // Existing observers must see that this pass has begun before its scan
        // can suspend.  Late observers still receive this same snapshot from
        // `snapshots()`; neither path depends on scanner timing.
        let lease = authority?.admit()
        publish()
        let authority = authority
        operation = Task { [weak self] in
            await self?.run(pass: pass, explicitRetry: explicitRetry)
            if let lease { authority?.release(lease) }
            await self?.publish()
        }
    }

    private func run(pass: UInt64, explicitRetry: Bool) async {
        var issues: [SessionRecoveryIssue] = []
        var catalogWarning: CatalogErrorCode?
        var discoveryWarning: String?
        do {
            let roots = try await scanner.scanForRecovery()
            guard isCurrent(pass) else { return }
            snapshot = .init(generation: pass, phase: .recovering, report: nil)
            publish()
            resumeDiscoveryWaiters()

            let candidates = roots.flatMap(\.candidates)
            issues.append(contentsOf: roots.flatMap(\.issues))
            let identifiedLocations = roots.flatMap { result in
                result.identifiedLocations.isEmpty ? result.candidates.map(\.location) : result.identifiedLocations
            }
            let duplicateIDs = Set(identifiedLocations.map(\.sessionID).filter { id in
                identifiedLocations.filter { $0.sessionID == id }.count > 1
            })
            for location in identifiedLocations where duplicateIDs.contains(location.sessionID) && !candidates.contains(where: { $0.location == location }) {
                issues.append(.init(rootID: location.rootID, folderName: location.folderName.rawValue,
                                    sessionID: location.sessionID, code: .duplicateSession,
                                    preserved: true, retryable: false, warning: nil))
            }
            for candidate in candidates {
                guard isCurrent(pass) else { return }
                if duplicateIDs.contains(candidate.location.sessionID) {
                    issues.append(issue(for: candidate, code: .duplicateSession, retryable: false))
                    continue
                }
                let candidateIssues = await recover(candidate, pass: pass, explicitRetry: explicitRetry)
                issues.append(contentsOf: candidateIssues)
            }
        } catch {
            discoveryWarning = "registryFailed"
            resumeDiscoveryWaiters()
        }

        // Reconcile after file mutations.  Failure is a warning only: audio
        // and metadata bytes remain authoritative and are never rolled back.
        guard isCurrent(pass) else { return }
        do { _ = try await catalog.reconcile() }
        catch let error as CatalogError { catalogWarning = error.code }
        catch { catalogWarning = .filesystemScanFailed }
        guard isCurrent(pass) else { return }
        if let catalogWarning {
            discoveryWarning = discoveryWarning ?? "catalog.\(catalogWarning.rawValue)"
        }
        snapshot = .init(generation: pass, phase: .ready,
                         report: .init(items: issues.sorted { $0.id < $1.id }, catalogWarning: catalogWarning,
                                       discoveryWarning: discoveryWarning))
        operation = nil
        publish()
        resumeDiscoveryWaiters()
        if refreshPending {
            refreshPending = false
            launch(explicitRetry: false)
        } else {
            resumeSettlementWaiters()
        }
    }

    private func recover(_ candidate: SessionRecoveryCandidate, pass: UInt64, explicitRetry: Bool) async -> [SessionRecoveryIssue] {
        guard isCurrent(pass) else { return [] }
        guard let activity else { return await recoverClaimed(candidate, pass: pass, explicitRetry: explicitRetry) }
        guard let claim = await activity.claimRecovery(at: candidate.location) else {
            return [issue(for: candidate, code: .currentProcessActive, retryable: true)]
        }
        let outcome = await recoverClaimed(candidate, pass: pass, explicitRetry: explicitRetry)
        await activity.release(claim)
        return outcome
    }

    private func recoverClaimed(_ candidate: SessionRecoveryCandidate, pass: UInt64, explicitRetry: Bool) async -> [SessionRecoveryIssue] {
        var metadata = candidate.metadata
        // Terminal audio verification is read-only.  It must not be suppressed
        // merely because this historical root is no longer writable, and it
        // must not append a recovery event before proving the terminal bytes.
        if metadata.status == .completed {
            return await recoverTerminal(candidate, metadata: metadata, pass: pass)
        }
        guard candidate.rootWritable else { return [issue(for: candidate, code: .rootReadOnly, retryable: true)] }
        let startedWarning = await persistence.appendRecoveryEventIfSafe(
            at: candidate.location, kind: .recoveryStarted, code: recoveryEpisodeCode(candidate, metadata: metadata, result: nil),
            message: nil, occurredAt: now())
        guard isCurrent(pass) else { return [] }
        switch metadata.status {
        case .preparing:
            do {
                _ = try await persistence.markPreparationAbandonedForRecovery(at: candidate.location, expected: metadata, updatedAt: now())
                guard isCurrent(pass) else { return [] }
                return [issue(for: candidate, code: .preparationAbandoned, retryable: false, warning: startedWarning)]
            } catch {
                return [issue(for: candidate, code: .finalizationFailed, retryable: true, warning: "metadataWrite")]
            }
        case .recording, .paused:
            do {
                metadata = try await persistence.markInterruptedForRecovery(at: candidate.location, expected: metadata, updatedAt: now())
                guard isCurrent(pass) else { return [] }
            } catch {
                // A failed durable state transition must never be followed by a
                // T08 enqueue; otherwise recovery could falsely claim success.
                return [issue(for: candidate, code: .finalizationFailed, retryable: true, warning: "interruptedWrite")]
            }
        case .securing, .finalizing, .interrupted:
            break
        case .completed:
            // Handled before any mutating recovery diagnostic is emitted.
            return []
        case .missing:
            return []
        case .error:
            guard candidate.sourcePresent else { return [] }
        }

        guard candidate.sourcePresent else {
            if candidate.checkpoint?.completedSteps.contains(.recoveryDataRemoved) == true,
               metadata.status == .completed || metadata.status == .interrupted { return [] }
            return [issue(for: candidate, code: .missingRecoverySource, retryable: true)]
        }
        ownedFinalizations.append(candidate.location)
        let result = await finalization.finalize(.init(location: candidate.location), retry: explicitRetry)
        ownedFinalizations.removeAll { $0 == candidate.location }
        guard isCurrent(pass) else {
            if cancelling { retainCancelledResult(for: candidate, metadata: metadata, result: result, startedWarning: startedWarning) }
            return []
        }
        let eventCode = recoveryEpisodeCode(candidate, metadata: metadata, result: result)
        let diagnosticWarning = await persistence.appendRecoveryEventIfSafe(
            at: candidate.location, kind: .recoveryCompleted, code: eventCode,
            message: result.phase == .audioReadyAwaitingRemainingFinalization ? "audioReady; remainingFinalizationRequired" : result.failure?.rawValue,
            occurredAt: now()
        )
        return [issueFromFinalization(candidate, metadata: metadata, result: result,
                                      startedWarning: startedWarning, diagnosticWarning: diagnosticWarning)]
    }

    private func recoverTerminal(_ candidate: SessionRecoveryCandidate, metadata: SessionMetadataDocument,
                                 pass: UInt64) async -> [SessionRecoveryIssue] {
        // Metadata publication and its checkpoint are separate atomic writes.
        // T20 can recover a completed metadata document at prefix 5 after a
        // crash in between; the worker must still revalidate audio/transcript.
        guard candidate.checkpoint?.completedSteps.contains(.derivedFilesGenerated) == true else {
            return [issue(for: candidate, captureOutcome: metadata.captureOutcome,
                          code: .terminalInconsistent, retryable: false)]
        }
        // Recovery source may be absent only after the durable cleanup step.
        // Prefixes 6/7 have no authority to turn a missing source into an
        // unverifiable canonical-only success.
        if !candidate.sourcePresent,
           candidate.checkpoint?.completedSteps.contains(.recoveryDataRemoved) != true {
            return [issue(for: candidate, captureOutcome: metadata.captureOutcome,
                          code: .missingRecoverySource, retryable: false)]
        }
        guard candidate.canonicalIntegrity != .missing else {
            return [issue(for: candidate, captureOutcome: metadata.captureOutcome,
                          code: .terminalInconsistent, retryable: false, warning: "canonicalMissing")]
        }
        ownedFinalizations.append(candidate.location)
        let request = AudioFinalizationRequest(location: candidate.location, operation: .verifyExistingCanonical)
        // A discovery pass is new filesystem evidence.  `retry: true` joins
        // an in-flight verification but replaces a settled verification result
        // so a later pass cannot certify bytes it did not inspect.
        let result = await finalization.finalize(request, retry: true)
        ownedFinalizations.removeAll { $0 == candidate.location }
        guard isCurrent(pass) else {
            if cancelling { retainCancelledResult(for: candidate, metadata: metadata, result: result, startedWarning: nil) }
            return []
        }
        if result.failure == nil {
            return [issueFromFinalization(candidate, metadata: metadata, result: result, startedWarning: nil)]
        }
        if result.failure == .cancelled {
            return [issueFromFinalization(candidate, metadata: metadata, result: result, startedWarning: nil)]
        }
        if result.transcriptFailure != nil {
            return [issueFromFinalization(candidate, metadata: metadata, result: result, startedWarning: nil)]
        }
        return [issue(for: candidate, captureOutcome: metadata.captureOutcome,
                      code: .terminalInconsistent, retryable: false, warning: result.failure?.rawValue,
                      warnings: deduplicated(([result.failure?.rawValue] + result.warnings).compactMap { $0 }))]
    }

    /// This ID contains only durable observed state, never an in-memory pass
    /// number.  It is stable across refreshes and process relaunches, but a
    /// changed metadata/checkpoint/file layout becomes a new diagnostic episode.
    private func recoveryEpisodeCode(
        _ candidate: SessionRecoveryCandidate,
        metadata: SessionMetadataDocument,
        result: AudioFinalizationResult?
    ) -> String {
        let checkpoint = candidate.checkpoint
        let checkpointStamp = checkpoint.map { Int($0.updatedAt.value.timeIntervalSince1970 * 1_000) } ?? -1
        let steps = checkpoint?.completedSteps.map(\.rawValue).joined(separator: ",") ?? "none"
        let metadataStamp = Int(metadata.lastUpdatedAt.value.timeIntervalSince1970 * 1_000)
        let layout = "\(candidate.sourcePresent ? 1 : 0)\(candidate.stagingPresent ? 1 : 0)\(candidate.canonicalPresent ? 1 : 0)"
        let prefix = "recovery.\(metadata.status.rawValue).\(metadata.captureOutcome.rawValue).\(metadataStamp).\(checkpointStamp).\(steps).\(layout)"
        guard let result else { return "\(prefix).started" }
        return "\(prefix).\(result.phase.rawValue).\(result.completedSteps.map(\.rawValue).joined(separator: ","))"
    }

    private func issue(for candidate: SessionRecoveryCandidate, captureOutcome: CaptureOutcome? = nil,
                       code: SessionRecoveryCode, retryable: Bool, warning: String? = nil,
                       warnings: [String] = []) -> SessionRecoveryIssue {
        .init(rootID: candidate.location.rootID, folderName: candidate.location.folderName.rawValue,
              sessionID: candidate.location.sessionID, code: code, preserved: true,
              retryable: retryable, warning: warning, warnings: warnings,
              captureOutcome: captureOutcome ?? candidate.metadata.captureOutcome)
    }

    private func issueFromFinalization(_ candidate: SessionRecoveryCandidate, metadata: SessionMetadataDocument,
                                       result: AudioFinalizationResult, startedWarning: String?,
                                       diagnosticWarning: String? = nil) -> SessionRecoveryIssue {
        let code: SessionRecoveryCode
        if let failure = result.failure {
            code = result.permitsEssentialQuitAfterTranscriptFailure ? .transcriptFinalizationFailed :
                (failure == .cancelled ? .cancelled : .finalizationFailed)
        } else {
            switch result.phase {
            case .sessionReady: code = .sessionReady
            case .audioReadyAwaitingRemainingFinalization:
                code = metadata.captureOutcome == .interrupted ? .interruptedRecordingRecovered : .audioReadyAwaitingRemainingFinalization
            case .audioRevalidated: code = .audioRevalidated
            default: code = .queued
            }
        }
        let first = result.transcriptFailure.map { "transcript.\($0.code.rawValue)" } ?? result.failure?.rawValue
        return issue(for: candidate, captureOutcome: metadata.captureOutcome, code: code, retryable: result.canRetry,
                     warning: first,
                     warnings: deduplicated(([first, diagnosticWarning, startedWarning] + result.warnings).compactMap { $0 }))
    }

    private func retainCancelledResult(for candidate: SessionRecoveryCandidate, metadata: SessionMetadataDocument,
                                       result: AudioFinalizationResult, startedWarning: String?) {
        let retained = issueFromFinalization(candidate, metadata: metadata, result: result, startedWarning: startedWarning)
        if let index = cancellationIssues.firstIndex(where: { $0.id == retained.id }) {
            cancellationIssues[index] = retained
        } else {
            cancellationIssues.append(retained)
        }
    }

    private func deduplicated(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    private func mergedCancellationReport(_ report: SessionRecoveryReport?, additions: [SessionRecoveryIssue]) -> SessionRecoveryReport? {
        guard report != nil || !additions.isEmpty else { return nil }
        var byID: [String: SessionRecoveryIssue] = [:]
        for issue in report?.items ?? [] { byID[issue.id] = issue }
        for issue in additions { byID[issue.id] = issue }
        return .init(items: byID.values.sorted { $0.id < $1.id }, catalogWarning: report?.catalogWarning,
                     discoveryWarning: report?.discoveryWarning)
    }

    private func publish() { for observer in observers.values { observer.yield(snapshot) } }
    private func isCurrent(_ pass: UInt64) -> Bool { generation == pass && !cancelling && !Task.isCancelled }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func resumeDiscoveryWaiters() {
        let waiting = discoveryWaiters
        discoveryWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }
    private func resumeSettlementWaiters() {
        let waiting = settlementWaiters
        settlementWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
