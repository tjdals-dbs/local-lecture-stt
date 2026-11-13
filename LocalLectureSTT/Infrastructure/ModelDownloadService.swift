import Foundation

enum ModelDownloadPoint: Sendable { case beforeRequest, receipt, copyChunk, beforeInstall, journal, cleanup, afterTransportClose, stopRequested, progressObserved, resumeAdmission }
struct ModelDownloadHooks: Sendable { var visit: @Sendable (ModelDownloadPoint) async throws -> Void = { _ in } }

actor ModelDownloadService: ModelDownloading {
    private enum Stop { case pause, cancel }
    private final class Attempt {
        var journal: ModelDownloadJournal
        let directory: ModelPackageDirectory
        let pinnedPayload: ModelPackageDirectory?
        var payload: ModelPackageDirectory {
            get throws {
                guard let pinnedPayload else { throw ModelDownloadFailure(code: .ownership) }
                return pinnedPayload
            }
        }
        var committed: ModelImportResult?
        var committedEvidence: ModelInstallEvidence?
        var admissionFailure: ModelDownloadFailure?
        let owned: ModelDownloadOwnedNodes
        let claim: ModelStoreClaim
        var stateStamp: ModelFileStamp
        var stop: Stop?
        var task: Task<Void, Never>?
        var transport: (any ModelDownloadTransport)?
        init(journal: ModelDownloadJournal, directory: ModelPackageDirectory, payload: ModelPackageDirectory?, claim: ModelStoreClaim, expectedState: ModelFileStamp? = nil) throws {
            self.journal = journal; self.directory = directory; pinnedPayload = payload; self.claim = claim
            owned = ModelDownloadOwnedNodes(journal.ownedNodes)
            if let expectedState { stateStamp = expectedState }
            else { stateStamp = ModelFileStamp(try directory.info("state.json")) }
        }
    }
    private let repository: FileModelRepository
    private let storage: ModelDownloadStorage
    private let capacity: ModelDownloadCapacityProvider
    private let transportFactory: @Sendable (ModelDownloadID) -> any ModelDownloadTransport
    private let hooks: ModelDownloadHooks
    private var active = [ModelDownloadID: Attempt]()
    private var retained = [ModelDownloadID: ModelDownloadSnapshot]()
    private final class Admission {
        var stop: Stop?
        var waiters = [CheckedContinuation<Void, Never>]()
    }
    private var admitting = [ModelDownloadID: Admission]()

    init(repository: FileModelRepository, storage: ModelDownloadStorage = .init(),
         capacity: ModelDownloadCapacityProvider = .init(), hooks: ModelDownloadHooks = .init(),
         transportFactory: @escaping @Sendable (ModelDownloadID) -> any ModelDownloadTransport = {
             URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: $0))
         }) {
        self.repository = repository; self.storage = storage; self.capacity = capacity
        self.transportFactory = transportFactory; self.hooks = hooks
    }
    private func entry(_ key: InstalledModelKey) async throws -> (ModelPackageDescriptor, ModelDelivery, String) {
        let catalog = try await repository.catalog()
        guard let descriptor = catalog.entries.first(where: { $0.key == key }),
              let delivery = catalog.deliveries.first(where: { $0.key == key }) else { throw ModelDownloadFailure(code: .notDownloadable) }
        let bytes = try JSONEncoder.sorted.encode(DeliveryIdentity(descriptor: descriptor, delivery: delivery))
        return (descriptor, delivery, ModelPackageRules.sha256(bytes))
    }
    private struct DeliveryIdentity: Encodable { let descriptor: ModelPackageDescriptor; let delivery: ModelDelivery }
    private func assess(_ descriptor: ModelPackageDescriptor, completed: Int64) async throws -> ModelDownloadCapacity {
        let destination = try await repository.destinationForCapacity()
        let a: Int64?; let b: Int64?
        do { a = try capacity.available(destination); b = try capacity.available(storage.rootURL()) }
        catch { throw ModelDownloadFailure(code: .capacityUnknown) }
        let available = a.flatMap { first in b.map { min(first, $0) } }
        let assessment = try ModelDownloadCapacity.assess(lengths: descriptor.files.map(\.byteCount), completed: completed, available: available)
        guard assessment.sufficient else { throw ModelDownloadFailure(code: .insufficientCapacity) }
        return assessment
    }
    func start(_ key: InstalledModelKey) async throws -> ModelDownloadID {
        if Task.isCancelled { throw ModelDownloadFailure(code: .cancelled) }
        guard active.count + retained.count < 128 else { throw ModelDownloadFailure(code: .busy) }
        let (descriptor, delivery, fingerprint) = try await entry(key)
        let claim = try await acquireClaim(key)
        do {
            _ = try await assess(descriptor, completed: 0)
            if Task.isCancelled { throw ModelDownloadFailure(code: .cancelled) }
            let id = ModelDownloadID()
            let (dir, payload, journal) = try storage.create(id: id, descriptor: descriptor, delivery: delivery, fingerprint: fingerprint)
            launch(try Attempt(journal: journal, directory: dir, payload: payload, claim: claim)); return id
        } catch { claim.release(); throw failure(error) }
    }
    func retry(_ id: ModelDownloadID) async throws -> ModelDownloadID {
        let s = try snapshot(id)
        guard active[id] == nil, admitting[id] == nil else { throw ModelDownloadFailure(code: .busy) }
        // A durable operation is authoritative even when its in-memory result is
        // installed: cleanup may have failed after the publication commit point.
        let persisted: Bool
        do { persisted = try storage.contains(id) } catch { throw failure(error) }
        if persisted { try await resume(id); return id }
        if s.phase == .paused { throw ModelDownloadFailure(code: .journal) }
        if s.phase == .installed { return id }
        guard s.failure?.cleanup == nil else { throw ModelDownloadFailure(code: .ownership) }
        return try await start(s.key)
    }
    func resume(_ id: ModelDownloadID) async throws {
        if Task.isCancelled { throw ModelDownloadFailure(code: .cancelled) }
        guard active[id] == nil, admitting[id] == nil,
              retained[id] != nil || active.count + retained.count < 128 else { throw ModelDownloadFailure(code: .busy) }
        let admission = Admission(); admitting[id] = admission
        defer { admitting[id] = nil; for waiter in admission.waiters { waiter.resume() } }
        let (dir, old) = try loadRecord(id)
        let originalState = ModelFileStamp(try dir.info("state.json"))
        let (descriptor, delivery, fingerprint) = try await entry(old.descriptor.key)
        guard descriptor == old.descriptor, delivery == old.delivery, fingerprint == old.catalogFingerprint else {
            throw ModelDownloadFailure(code: .resourceChanged)
        }
        let claim = try await acquireClaim(descriptor.key)
        do {
            guard ModelFileStamp(try dir.info("state.json")) == originalState else { throw ModelDownloadFailure(code: .ownership) }
            let evidence = ModelInstallEvidence()
            if let installed = try await repository.existingDownload(descriptor, claim: claim, evidence: evidence) {
                // Final revision authority precedes disposable bytes and download
                // capacity. No weight copy, directory creation or journal write.
                let attempt = try Attempt(journal: old, directory: dir,
                    payload: try? storage.ownedPayload(dir, journal: old), claim: claim, expectedState: originalState)
                attempt.committed = installed; attempt.committedEvidence = evidence
                attempt.journal.snapshot = .init(id: id, key: descriptor.key, generation: old.snapshot.generation + 1,
                    phase: .installing, completedBytes: old.snapshot.totalBytes, totalBytes: old.snapshot.totalBytes)
                do { try await hooks.visit(.resumeAdmission) }
                catch { attempt.admissionFailure = failure(error) }
                attempt.stop = admission.stop ?? (Task.isCancelled ? .cancel : nil)
                retained[id] = nil; launch(attempt); return
            }
            let payload = try storage.ownedPayload(dir, journal: old)
            guard try payload.treeStamps() == old.payloadTree else { throw ModelDownloadFailure(code: .ownership) }
            var completedBytes: Int64 = 0
            for path in old.completed {
                guard let f = descriptor.files.first(where: { $0.path == path }) else { throw ModelDownloadFailure(code: .journal) }
                let hash = try await payload.hash(path, chunk: {})
                guard hash.0 == f.byteCount, hash.1 == f.sha256 else { throw ModelDownloadFailure(code: .resourceChanged) }
                completedBytes += f.byteCount
            }
            guard try payload.treeStamps() == old.payloadTree else { throw ModelDownloadFailure(code: .ownership) }
            _ = try await assess(descriptor, completed: completedBytes)
            try await hooks.visit(.resumeAdmission)
            if Task.isCancelled { throw ModelDownloadFailure(code: .cancelled) }
            var journal = old
            journal.snapshot = .init(id: id, key: descriptor.key, generation: old.snapshot.generation + 1,
                                     phase: .transferring, completedBytes: completedBytes, totalBytes: old.snapshot.totalBytes)
            // Recheck original evidence after capacity/admission awaits. Discard
            // only a pinned incomplete current file; completed files keep their credit.
            guard ModelFileStamp(try dir.info("state.json")) == originalState else { throw ModelDownloadFailure(code: .ownership) }
            let owned = ModelDownloadOwnedNodes(old.ownedNodes)
            if admission.stop == nil {
                if try storage.resetIncomplete(payload: payload, completed: old.completed, activePath: old.activePath,
                                               owned: owned, expectedTree: old.payloadTree) {
                    journal.resumeData = nil
                }
            } else {
                guard try payload.treeStamps() == old.payloadTree else { throw ModelDownloadFailure(code: .ownership) }
            }
            journal.ownedNodes = owned.values(); journal.payloadTree = try payload.treeStamps()
            try storage.write(journal, directory: dir, expectedState: originalState)
            retained[id] = nil
            let attempt = try Attempt(journal: journal, directory: dir, payload: payload, claim: claim)
            attempt.stop = admission.stop; launch(attempt)
        } catch { claim.release(); throw failure(error) }
    }
    private func launch(_ attempt: Attempt) {
        let id = attempt.journal.id; active[id] = attempt
        attempt.task = Task { await self.run(attempt) }
    }
    func snapshot(_ id: ModelDownloadID) throws -> ModelDownloadSnapshot {
        if let a = active[id] { return a.journal.snapshot }
        if let s = retained[id] { return s }
        return try loadRecord(id).1.snapshot
    }
    func wait(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot {
        if let task = active[id]?.task { await task.value }
        return try snapshot(id)
    }
    func pending() throws -> [ModelDownloadPending] {
        do { return try storage.pending() } catch { throw failure(error) }
    }
    private func loadRecord(_ id: ModelDownloadID) throws -> (ModelPackageDirectory, ModelDownloadJournal) {
        do { return try storage.readRecord(id) }
        catch let e as ModelDownloadFailure { throw e }
        catch { throw ModelDownloadFailure(code: .journal) }
    }
    private func acquireClaim(_ key: InstalledModelKey) async throws -> ModelStoreClaim {
        do { return try await repository.acquireDownloadClaim(key) }
        catch { if error as? ModelRepositoryCode == .busy { throw ModelDownloadFailure(code: .busy) }; throw failure(error) }
    }
    func pause(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot {
        if let admission = admitting[id] {
            if admission.stop != .cancel { admission.stop = .pause }
            try? await hooks.visit(.stopRequested)
            await withCheckedContinuation { continuation in
                if admitting[id] === admission { admission.waiters.append(continuation) } else { continuation.resume() }
            }
            return try await pause(id)
        }
        guard let a = active[id] else { return try snapshot(id) }
        if a.stop != .cancel { a.stop = .pause }
        try? await hooks.visit(.stopRequested)
        if let transport = a.transport { await transport.stop(preservingResume: a.stop == .pause) }
        else { a.task?.cancel() }
        await a.task?.value; return try snapshot(id)
    }
    func cancel(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot {
        if let admission = admitting[id] {
            admission.stop = .cancel
            try? await hooks.visit(.stopRequested)
            await withCheckedContinuation { continuation in
                if admitting[id] === admission { admission.waiters.append(continuation) } else { continuation.resume() }
            }
            return try await cancel(id)
        }
        if let a = active[id] {
            a.stop = .cancel; a.task?.cancel()
            try? await hooks.visit(.stopRequested)
            if let transport = a.transport { await transport.stop(preservingResume: false) }
            await a.task?.value; return try snapshot(id)
        }
        if var s = retained[id] {
            if s.phase == .installed { return s }
            if s.phase == .cancelled, s.failure?.cleanup == nil {
                if try !storage.contains(id) { return s }
            }
            if s.phase == .failed, s.failure?.cleanup == nil {
                s.phase = .cancelled; s.failure = .init(code: .cancelled); retained[id] = s; return s
            }
        }
        let (dir, j) = try loadRecord(id)
        let originalState = ModelFileStamp(try dir.info("state.json"))
        let claim = try await acquireClaim(j.descriptor.key)
        defer { claim.release() }
        guard ModelFileStamp(try dir.info("state.json")) == originalState else { throw ModelDownloadFailure(code: .ownership) }
        let a = try Attempt(journal: j, directory: dir, payload: try? storage.ownedPayload(dir, journal: j), claim: claim, expectedState: originalState)
        a.stop = .cancel
        let evidence = ModelInstallEvidence()
        var assessmentFailure: ModelDownloadFailure?
        do {
            if let installed = try await repository.existingDownload(j.descriptor, claim: claim, evidence: evidence) {
                await settleCommitted(a, installed: installed, evidence: evidence)
                retained[id] = a.journal.snapshot; return a.journal.snapshot
            }
        } catch { assessmentFailure = failure(error) }
        var s = j.snapshot; s.phase = .cancelled; s.failure = .init(code: .cancelled); s.resumable = false
        do {
            try await discardRetainedTransfer(a)
            try await remove(a)
        } catch { s.failure?.cleanup = failure(error).code }
        // Unvalidated/corrupt existing targets stay preserved and diagnosed;
        // they are never promoted to installed success by a cancel command.
        if let assessmentFailure { s.failure?.repository = assessmentFailure.repository }
        retained[id] = s; return s
    }
    private func associated(id: ModelDownloadID, generation: Int, path: String, association: String) async throws {
        guard let a = active[id], a.journal.snapshot.generation == generation, a.stop == nil else { throw ModelDownloadFailure(code: .cancelled) }
        a.journal.association = association; a.journal.activePath = path
        try await hooks.visit(.journal); try a.directory.check(); try a.payload.check()
        a.stateStamp = try storage.write(a.journal, directory: a.directory, expectedState: a.stateStamp)
    }
    private func discardRetainedTransfer(_ a: Attempt) async throws {
        guard let association = a.journal.association else { return }
        let transport = transportFactory(a.journal.id); a.transport = transport
        do { try await transport.discard(association: association) }
        catch { await transport.close(); a.transport = nil; throw error }
        await transport.close(); a.transport = nil
        try await hooks.visit(.afterTransportClose)
        // Keep the original journal/payload pins through all transport awaits.
        try a.directory.check(); try a.pinnedPayload?.check()
        guard ModelFileStamp(try a.directory.info("state.json")) == a.stateStamp else { throw ModelDownloadFailure(code: .ownership) }
        a.journal.association = nil; a.journal.activePath = nil; a.journal.resumeData = nil
    }
    private func progress(id: ModelDownloadID, generation: Int, path: String, base: Int64, value: ModelTransferProgress) async {
        if let a = active[id], a.journal.snapshot.generation == generation, a.journal.activePath == path,
           a.journal.snapshot.phase == .transferring, a.stop == nil {
            a.journal.snapshot.completedBytes = max(a.journal.snapshot.completedBytes, min(a.journal.snapshot.totalBytes, base + value.bytes))
            a.journal.snapshot.resumedOffset = max(a.journal.snapshot.resumedOffset, value.resumedOffset)
        }
        try? await hooks.visit(.progressObserved)
    }
    private func check(_ a: Attempt) throws {
        try Task.checkCancellation(); try a.directory.check(); try a.payload.check()
        if a.stop != nil { throw ModelDownloadFailure(code: .interrupted) }
    }
    private func remove(_ a: Attempt) async throws {
        try await storage.remove(id: a.journal.id, directory: a.directory, payload: a.payload,
            allowedPaths: Set(a.journal.descriptor.files.map(\.path)), owned: a.owned, expectedState: a.stateStamp,
            before: { [hooks] in try await hooks.visit(.cleanup) })
    }
    private func failure(_ error: Error) -> ModelDownloadFailure {
        if let f = error as? ModelDownloadFailure { return f }
        if error is CancellationError { return .init(code: .cancelled) }
        if let f = error as? ModelOperationFailure { return .init(code: .install, repository: f) }
        if let code = error as? ModelRepositoryCode { return .init(code: .install, repository: .init(code)) }
        return .init(code: .journal)
    }
    private func settleCommitted(_ a: Attempt, installed: ModelImportResult,
                                 evidence: ModelInstallEvidence, first original: ModelDownloadFailure? = nil) async {
        var first = original
        var warning = installed.warning ?? (original == nil ? nil : .storageUnavailable)
        do {
            try evidence.check()
            try await discardRetainedTransfer(a); try evidence.check()
            try await remove(a); try evidence.check()
        } catch {
            let cleanup = failure(error)
            first = first ?? cleanup; first?.cleanup = cleanup.code
            // Preserve the first cleanup cause even if final model ownership also
            // changed while that failed await was settling.
            var identityChanged = false
            do { try evidence.check() } catch { identityChanged = true }
            if installed.warning == nil {
                warning = identityChanged ? .identityChanged : (error as? ModelRepositoryCode) ?? .cleanupFailed
            }
        }
        a.journal.snapshot.phase = .installed
        a.journal.snapshot.completedBytes = a.journal.snapshot.totalBytes
        a.journal.snapshot.result = .init(disposition: installed.disposition, manifest: installed.manifest,
                                         warning: warning ?? (a.stop != nil ? .cancelled : nil))
        a.journal.snapshot.failure = first; a.journal.snapshot.resumable = false
    }
    private func run(_ a: Attempt) async {
        let evidence = a.committedEvidence ?? ModelInstallEvidence()
        var installed = a.committed
        var first = a.admissionFailure
        let id = a.journal.id; let generation = a.journal.snapshot.generation
        do {
            if installed == nil {
                try check(a)
                installed = try await repository.existingDownload(a.journal.descriptor, claim: a.claim, evidence: evidence)
            }
            if installed == nil {
                for file in a.journal.descriptor.files where !a.journal.completed.contains(file.path) {
                    try check(a); try await hooks.visit(.beforeRequest); try check(a)
                    let location = a.journal.delivery.locations.first { $0.path == file.path }!
                    let base = a.journal.descriptor.files.filter { a.journal.completed.contains($0.path) }.reduce(Int64(0)) { $0 + $1.byteCount }
                    let association = id.rawValue.uuidString + ":" + String(generation) + ":" + ModelPackageRules.sha256(Data(file.path.utf8))
                    let previous = a.journal.activePath == file.path ? a.journal.association : nil
                    var resume = a.journal.activePath == file.path ? a.journal.resumeData : nil
                    var outcome: ModelTransferOutcome
                    var fallback = false
                    repeat {
                        let transport = transportFactory(id); a.transport = transport
                        outcome = await transport.transfer(.init(association: association, previousAssociation: fallback ? nil : previous,
                            url: URL(string: location.httpsURL)!, expectedBytes: file.byteCount, resumeData: resume),
                            associated: { value in try await self.associated(id: id, generation: generation, path: file.path, association: value) },
                            progress: { value in Task { await self.progress(id: id, generation: generation, path: file.path, base: base, value: value) } })
                        await transport.close(); a.transport = nil
                        try await hooks.visit(.afterTransportClose)
                        a.journal.resumeData = outcome.resumeData
                        a.journal.snapshot.resumedOffset = max(a.journal.snapshot.resumedOffset, outcome.resumedOffset)
                        a.journal.snapshot.continuedExistingTask = a.journal.snapshot.continuedExistingTask || outcome.reconnected
                        if a.stop != nil { throw ModelDownloadFailure(code: a.stop == .cancel ? .cancelled : .interrupted) }
                        if resume != nil, outcome.failure != nil, !fallback {
                            // Exactly one byte-zero fallback per explicit command. Never
                            // rewrite or parse Apple's opaque resume token.
                            fallback = true; resume = nil; a.journal.resumeData = nil
                            a.journal.snapshot.resumeFailure = outcome.failure
                            a.journal.snapshot.restartedFromZero = true
                        } else { break }
                    } while true
                    if generation > 1, outcome.resumedOffset == 0, !outcome.reconnected { a.journal.snapshot.restartedFromZero = true }
                    if let f = outcome.failure { throw f }
                    guard let receipt = outcome.receipt else { throw ModelDownloadFailure(code: .receiptMissing) }
                    try await hooks.visit(.receipt); try check(a)
                    try await receipt.copy(to: a.payload, path: file.path, expected: file.byteCount, owned: a.owned,
                                           chunk: { [hooks] in try await hooks.visit(.copyChunk) })
                    let hash = try await a.payload.hash(file.path, chunk: {})
                    guard hash.0 == file.byteCount, hash.1 == file.sha256 else { throw ModelDownloadFailure(code: .install, repository: .init(.integrityMismatch)) }
                    a.journal.completed.append(file.path); a.journal.ownedNodes = a.owned.values()
                    a.journal.payloadTree = try a.payload.treeStamps(); a.journal.resumeData = nil
                    a.journal.association = nil; a.journal.activePath = nil
                    a.journal.snapshot.completedBytes = base + file.byteCount
                    a.stateStamp = try storage.write(a.journal, directory: a.directory, expectedState: a.stateStamp)
                }
                try check(a); a.journal.snapshot.phase = .installing
                try await hooks.visit(.beforeInstall); try check(a)
                installed = try await repository.installDownloaded(a.payload, descriptor: a.journal.descriptor, claim: a.claim, evidence: evidence)
            }
        } catch { first = failure(error) }
        // Close/join every transport before settling, including faults at association.
        if let t = a.transport { await t.stop(preservingResume: a.stop == .pause); await t.close(); a.transport = nil }
        if let installed {
            await settleCommitted(a, installed: installed, evidence: evidence, first: first)
        } else if a.stop == .pause || (first?.code == .transport && a.journal.resumeData != nil) {
            a.journal.snapshot.phase = .paused; a.journal.snapshot.failure = first
            a.journal.snapshot.resumable = a.journal.resumeData != nil || !a.journal.completed.isEmpty
            a.journal.ownedNodes = a.owned.values()
            do {
                try a.owned.check(a.payload); a.journal.payloadTree = try a.payload.treeStamps()
                a.stateStamp = try storage.write(a.journal, directory: a.directory, expectedState: a.stateStamp)
            } catch { a.journal.snapshot.failure = first ?? failure(error); a.journal.snapshot.failure?.cleanup = .journal }
        } else {
            a.journal.snapshot.phase = a.stop == .cancel || first?.code == .cancelled ? .cancelled : .failed
            a.journal.snapshot.failure = first ?? .init(code: .transport); a.journal.snapshot.resumable = false
            do { try await remove(a) }
            catch {
                a.journal.snapshot.failure?.cleanup = failure(error).code
                // Preserve diagnosed resumable/cancellable ownership when cleanup
                // failed, but never adopt replaced state or unknown payload nodes.
                do {
                    try a.owned.check(a.payload)
                    a.journal.ownedNodes = a.owned.values(); a.journal.payloadTree = try a.payload.treeStamps()
                    a.stateStamp = try storage.write(a.journal, directory: a.directory, expectedState: a.stateStamp)
                } catch { /* Remnants remain diagnosed through the retained snapshot. */ }
            }
        }
        retained[id] = a.journal.snapshot
        active[id] = nil; a.claim.release()
    }
}
private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
