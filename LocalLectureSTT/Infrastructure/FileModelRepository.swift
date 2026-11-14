import Darwin
import Foundation

protocol OfflineModelFormatValidating: Sendable {
    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws
}
struct UnavailableModelFormatValidator: OfflineModelFormatValidating {
    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        throw ModelRepositoryCode.validationUnavailable
    }
}
enum ModelRepositoryPoint: String, Sendable {
    case sourceAcquired, copyChunk, hashChunk, formatValidation, manifestWrite, flush, beforePublish, afterPublish, cleanup
    case referenceScan, beforeDelete, removing
}
struct ModelRepositoryHooks: Sendable {
    var visit: @Sendable (ModelRepositoryPoint) async throws -> Void = { _ in }
    var beforeRemove: @Sendable (String) throws -> Void = { _ in }
}
struct BundledModelCatalogLoader: Sendable {
    let load: @Sendable () throws -> BundledModelCatalog
    init(bundle: Bundle = .main) {
        load = {
            guard let url = bundle.url(forResource: "model-catalog", withExtension: "json") else { throw ModelRepositoryCode.storageUnavailable }
            guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { throw ModelRepositoryCode.storageUnavailable }
            defer { free(resolved) }
            let directory = try ModelPackageDirectory(url: URL(fileURLWithPath: String(cString: resolved)))
            return try JSONDecoder().decode(BundledModelCatalog.self, from: directory.readMetadata(url.lastPathComponent))
        }
    }
    init(load: @escaping @Sendable () throws -> BundledModelCatalog) { self.load = load }
}

/// Process-wide arbitration also covers multiple repository instances over one store.
final class ModelStoreClaim: @unchecked Sendable {
    let value: String
    private let nonce: UUID
    private let lock = NSLock()
    private var held = true
    fileprivate init(value: String, nonce: UUID) { self.value = value; self.nonce = nonce }
    func matches(_ value: String) -> Bool { lock.withLock { held && self.value == value } }
    func release() {
        lock.withLock {
            if held { held = false; ModelOperationClaims.shared.release(value, nonce: nonce) }
        }
    }
    deinit { release() }
}
private final class ModelOperationClaims: @unchecked Sendable {
    static let shared = ModelOperationClaims()
    private let lock = NSLock()
    private var claims = [String: UUID]()
    func acquire(_ value: String) throws -> ModelStoreClaim {
        try lock.withLock {
            guard claims[value] == nil else { throw ModelRepositoryCode.busy }
            let nonce = UUID(); claims[value] = nonce
            return ModelStoreClaim(value: value, nonce: nonce)
        }
    }
    func release(_ value: String, nonce: UUID) {
        lock.withLock { if claims[value] == nonce { claims[value] = nil } }
    }
}

/// Original installation evidence travels through download cleanup without recapture.
final class ModelInstallEvidence: @unchecked Sendable {
    private var directory: ModelPackageDirectory?
    private var fingerprint: [String]?
    func record(_ directory: ModelPackageDirectory, tree: [String]) { self.directory = directory; fingerprint = tree }
    func check() throws {
        if let directory, let fingerprint {
            guard try directory.treeStamps() == fingerprint else { throw ModelRepositoryCode.identityChanged }
        }
    }
}

actor FileModelRepository: ModelRepository {
    private let storeURL: @Sendable () throws -> URL
    private let sources: ModelImportSources
    private let validator: any OfflineModelFormatValidating
    private let references: any ModelReferenceChecking
    private let catalogLoader: BundledModelCatalogLoader
    private let hooks: ModelRepositoryHooks
    private var assessments = [UUID: ModelDeletionAssessment]()

    init(storeURL: @escaping @Sendable () throws -> URL = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ModelRepositoryCode.storageUnavailable
        }
        return support.appendingPathComponent("LocalLectureSTT/Models", isDirectory: true)
    }, sources: ModelImportSources, validator: any OfflineModelFormatValidating = UnavailableModelFormatValidator(),
         references: any ModelReferenceChecking, catalogLoader: BundledModelCatalogLoader = .init(), hooks: ModelRepositoryHooks = .init()) {
        self.storeURL = storeURL; self.sources = sources; self.validator = validator; self.references = references
        self.catalogLoader = catalogLoader; self.hooks = hooks
    }
    static func namespace(_ key: InstalledModelKey) -> [String] {
        [key.engineID.rawValue, key.modelID.rawValue, key.revision].map { ModelPackageRules.sha256(Data($0.utf8)) }
    }
    private func claimValue(_ key: InstalledModelKey) throws -> String {
        try storeURL().path + "/" + Self.namespace(key).joined(separator: "/")
    }
    func acquireDownloadClaim(_ key: InstalledModelKey) throws -> ModelStoreClaim {
        try claim(key)
    }
    func destinationForCapacity() throws -> URL { try storeURL() }
    private func claim(_ key: InstalledModelKey) throws -> ModelStoreClaim {
        try ModelOperationClaims.shared.acquire(claimValue(key))
    }
    private func parent(_ key: InstalledModelKey, store: ModelPackageDirectory, create: Bool) throws -> ModelPackageDirectory {
        var current = store
        for name in Self.namespace(key).dropLast() { current = try current.child(name, create: create) }
        return current
    }
    private func package(_ key: InstalledModelKey, store: ModelPackageDirectory) throws -> ModelPackageDirectory {
        try parent(key, store: store, create: false).child(Self.namespace(key).last!)
    }
    private func failure(_ error: Error) -> ModelRepositoryCode {
        if error is CancellationError { return .cancelled }
        return (error as? ModelRepositoryCode) ?? (error as? ModelOperationFailure)?.cause ?? .storageUnavailable
    }
    func catalog() async throws -> BundledModelCatalog {
        do { return try catalogLoader.load() } catch { throw ModelOperationFailure(failure(error)) }
    }
    private func manifest(_ directory: ModelPackageDirectory, key: InstalledModelKey? = nil) throws -> ModelInstallationManifest {
        let value = try JSONDecoder().decode(ModelInstallationManifest.self, from: directory.readMetadata("manifest.json"))
        if let key, value.descriptor.key != key { throw ModelRepositoryCode.identityChanged }
        return value
    }
    private func checkCatalogOrigin(_ value: ModelInstallationManifest) throws {
        if value.origin == .bundledCatalog {
            guard try catalogLoader.load().entries.contains(value.descriptor) else { throw ModelRepositoryCode.invalidDescriptor }
        }
    }
    private func snapshot(_ directory: ModelPackageDirectory) throws -> String {
        var records = try directory.treeStamps()
        // Metadata is included in the fingerprint, not in the stable model checksum.
        records.append(ModelPackageRules.sha256(try directory.readMetadata("manifest.json")))
        return ModelPackageRules.sha256(Data(records.joined(separator: "\n").utf8))
    }
    @discardableResult
    private func verify(_ directory: ModelPackageDirectory, descriptor: ModelPackageDescriptor, installed: Bool) async throws -> [String] {
        try Task.checkCancellation()
        let tree = try directory.treeStamps()
        let paths = try directory.payloadPaths(allowManifest: installed)
        guard paths == descriptor.files.map(\.path) else { throw ModelRepositoryCode.integrityMismatch }
        var stamps = [String: ModelFileStamp]()
        for file in descriptor.files {
            let (parent, name) = try directory.parent(file.path)
            stamps[file.path] = ModelFileStamp(try parent.info(name))
            let (size, digest) = try await directory.hash(file.path) { [hooks] in try await hooks.visit(.hashChunk) }
            guard size == file.byteCount, digest == file.sha256 else { throw ModelRepositoryCode.integrityMismatch }
        }
        try await hooks.visit(.formatValidation)
        try directory.check()
        try await validator.validate(descriptor, directory: directory)
        try Task.checkCancellation(); try directory.check()
        guard try directory.treeStamps() == tree else { throw ModelRepositoryCode.identityChanged }
        guard try directory.payloadPaths(allowManifest: installed) == paths else { throw ModelRepositoryCode.identityChanged }
        for (path, before) in stamps {
            let (parent, name) = try directory.parent(path)
            guard ModelFileStamp(try parent.info(name)) == before else { throw ModelRepositoryCode.identityChanged }
        }
        return tree
    }
    private func entry(_ directory: ModelPackageDirectory, namespace: String, key: InstalledModelKey? = nil) async throws -> ModelInventoryEntry {
        var value: ModelInstallationManifest?
        do {
            // Reject unknown schemas before interpreting their payload layout.
            let decoded = try manifest(directory, key: key); value = decoded
            let before = try snapshot(directory)
            guard try manifest(directory, key: key) == decoded else { throw ModelRepositoryCode.identityChanged }
            guard Self.namespace(decoded.descriptor.key).joined(separator: "/") == namespace else { throw ModelRepositoryCode.identityChanged }
            try checkCatalogOrigin(decoded)
            try await verify(directory, descriptor: decoded.descriptor, installed: true)
            guard try snapshot(directory) == before else { throw ModelRepositoryCode.identityChanged }
            return .init(namespace: namespace, manifest: value, state: .usable, issue: nil)
        } catch {
            let code = failure(error)
            if code == .cancelled { throw ModelOperationFailure(code) }
            let state: ModelPackageState
            switch code {
            case .unsupportedSchema: state = .unsupportedSchema
            case .validationUnavailable: state = .unvalidated
            case .incompatible: state = .incompatible
            case .storageUnavailable, .sourceUnavailable: state = .inaccessible
            default: state = .corrupt
            }
            return .init(namespace: namespace, manifest: value, state: state, issue: code)
        }
    }
    func inventory() async throws -> [ModelInventoryEntry] {
        do {
            let url = try storeURL()
            let store: ModelPackageDirectory
            do { store = try ModelPackageDirectory(url: url) }
            catch ModelRepositoryCode.sourceUnavailable { return [] }
            var entries = [ModelInventoryEntry]()
            for engine in try store.names() where !engine.hasPrefix(".operation-") {
                do {
                    let engineDir = try store.child(engine)
                    for model in try engineDir.names() {
                        let modelDir = try engineDir.child(model)
                        for revision in try modelDir.names() {
                            let ns = [engine, model, revision].joined(separator: "/")
                            do {
                                let dir = try modelDir.child(revision)
                                let decoded = try manifest(dir)
                                let claim = try claim(decoded.descriptor.key)
                                defer { claim.release() }
                                let result = try await entry(dir, namespace: ns)
                                entries.append(result)
                            } catch {
                                let code = failure(error)
                                if code == .busy || code == .cancelled { throw ModelOperationFailure(code) }
                                entries.append(.init(namespace: ns, manifest: nil,
                                                     state: code == .unsupportedSchema ? .unsupportedSchema : .corrupt, issue: code))
                            }
                        }
                    }
                } catch {
                    if failure(error) == .busy || failure(error) == .cancelled { throw error }
                    entries.append(.init(namespace: engine, manifest: nil, state: .inaccessible, issue: failure(error)))
                }
            }
            try store.check(); return entries
        } catch { throw ModelOperationFailure(failure(error)) }
    }
    func validate(_ key: InstalledModelKey) async throws -> ModelInventoryEntry {
        do {
            let claim = try claim(key); defer { claim.release() }
            let store = try ModelPackageDirectory(url: storeURL())
            return try await entry(try package(key, store: store), namespace: Self.namespace(key).joined(separator: "/"), key: key)
        } catch { throw ModelOperationFailure(failure(error)) }
    }
    /// Infrastructure-only adapter seam. Callers must use the pinned directory,
    /// not retain a URL after this operation; no engine is loaded by T12.
    func withResolvedPackage<T: Sendable>(_ key: InstalledModelKey,
        operation: @Sendable (ModelPackageDirectory, ModelPackageDescriptor) async throws -> T) async throws -> T {
        do {
            let claim = try claim(key); defer { claim.release() }
            let dir = try package(key, store: ModelPackageDirectory(url: storeURL()))
            let before = try snapshot(dir); let value = try manifest(dir, key: key)
            try checkCatalogOrigin(value)
            try await verify(dir, descriptor: value.descriptor, installed: true)
            guard try snapshot(dir) == before else { throw ModelRepositoryCode.identityChanged }
            let result = try await operation(dir, value.descriptor)
            guard try snapshot(dir) == before else { throw ModelRepositoryCode.identityChanged }
            return result
        } catch { throw ModelOperationFailure(failure(error)) }
    }
    /// Transfers the exclusive claim to an engine until its backend has actually stopped.
    func acquireUseLease(_ key: InstalledModelKey) async throws -> ModelUseLease {
        let claim: ModelStoreClaim
        do { claim = try self.claim(key) } catch { throw ModelOperationFailure(failure(error)) }
        do {
            let dir = try package(key, store: ModelPackageDirectory(url: storeURL()))
            let before = try snapshot(dir); let value = try manifest(dir, key: key)
            try checkCatalogOrigin(value)
            try await verify(dir, descriptor: value.descriptor, installed: true)
            guard try snapshot(dir) == before else { throw ModelRepositoryCode.identityChanged }
            return try ModelUseLease(directory: dir, descriptor: value.descriptor, claim: claim)
        } catch { claim.release(); throw ModelOperationFailure(failure(error)) }
    }

    func importPackage(from source: ModelImportSourceID, descriptor: ModelPackageDescriptor?, origin: ModelPackageOrigin = .suppliedLocal) async throws -> ModelImportResult {
        guard let descriptor else { throw ModelOperationFailure(.descriptorRequired) }
        let claim: ModelStoreClaim
        do { claim = try self.claim(descriptor.key) } catch { throw ModelOperationFailure(failure(error)) }
        defer { claim.release() }
        return try await install(descriptor: descriptor, origin: origin, acquire: { [sources] in try await sources.acquire(source) })
    }
    /// Internal owned-source entry: no security-scope registration or recursive claim.
    /// The caller keeps this exact claim through transport, install and download cleanup.
    func installDownloaded(_ directory: ModelPackageDirectory, descriptor: ModelPackageDescriptor,
                           claim: ModelStoreClaim, evidence: ModelInstallEvidence) async throws -> ModelImportResult {
        guard try claim.matches(claimValue(descriptor.key)) else { throw ModelOperationFailure(.busy) }
        return try await install(descriptor: descriptor, origin: .bundledCatalog,
                                 evidence: evidence, acquire: { try directory.check(); return ModelImportLease(directory: directory, stop: {}) })
    }
    func existingDownload(_ descriptor: ModelPackageDescriptor, claim: ModelStoreClaim, evidence: ModelInstallEvidence) async throws -> ModelImportResult? {
        guard try claim.matches(claimValue(descriptor.key)) else { throw ModelOperationFailure(.busy) }
        let store: ModelPackageDirectory
        do { store = try ModelPackageDirectory(url: storeURL()) }
        catch ModelRepositoryCode.sourceUnavailable { return nil }
        let finalParent: ModelPackageDirectory
        do { finalParent = try parent(descriptor.key, store: store, create: false) }
        catch ModelRepositoryCode.sourceUnavailable { return nil }
        guard try finalParent.names().contains(Self.namespace(descriptor.key).last!) else { return nil }
        let dir = try package(descriptor.key, store: store)
        let old = try manifest(dir, key: descriptor.key); let before = try snapshot(dir)
        guard old.descriptor == descriptor else { throw ModelOperationFailure(.collision) }
        try checkCatalogOrigin(old)
        try await verify(dir, descriptor: descriptor, installed: true)
        guard try snapshot(dir) == before else { throw ModelOperationFailure(.identityChanged) }
        evidence.record(dir, tree: try dir.treeStamps())
        return .init(disposition: .alreadyInstalled, manifest: old, warning: nil)
    }
    private func install(descriptor: ModelPackageDescriptor, origin: ModelPackageOrigin,
                         evidence: ModelInstallEvidence? = nil, acquire: @Sendable () async throws -> ModelImportLease) async throws -> ModelImportResult {
        let operation = UUID(); let stageName = ".operation-" + operation.uuidString.lowercased()
        var store: ModelPackageDirectory?; var stage: ModelPackageDirectory?; var lease: ModelImportLease?
        var stageCreated = false
        var committed: ModelInstallationManifest?
        do {
            try Task.checkCancellation()
            if origin == .bundledCatalog {
                guard try catalogLoader.load().entries.contains(descriptor) else { throw ModelRepositoryCode.invalidDescriptor }
            }
            let acquired = try await acquire(); lease = acquired
            try await hooks.visit(.sourceAcquired); try acquired.directory.check()
            let destinationURL = try storeURL()
            let sourcePath = acquired.directory.url.path
            guard destinationURL.path != sourcePath, !destinationURL.path.hasPrefix(sourcePath + "/"),
                  !sourcePath.hasPrefix(destinationURL.path + "/") else { throw ModelRepositoryCode.unsafeLayout }
            let destination = try ModelPackageDirectory(url: destinationURL, create: true); store = destination
            let finalParent = try parent(descriptor.key, store: destination, create: true)
            let finalName = Self.namespace(descriptor.key).last!
            if try finalParent.names().contains(finalName) {
                let old: ModelPackageDirectory
                let oldManifest: ModelInstallationManifest
                let oldSnapshot: String
                do {
                    old = try finalParent.child(finalName)
                    oldManifest = try manifest(old, key: descriptor.key)
                    try checkCatalogOrigin(oldManifest)
                    oldSnapshot = try snapshot(old)
                    guard oldManifest.descriptor == descriptor else { throw ModelRepositoryCode.collision }
                    try await verify(old, descriptor: descriptor, installed: true)
                    guard try snapshot(old) == oldSnapshot else { throw ModelRepositoryCode.collision }
                } catch is CancellationError { throw CancellationError() }
                catch { throw ModelRepositoryCode.collision }
                await acquired.release(); lease = nil
                guard try snapshot(old) == oldSnapshot else { throw ModelRepositoryCode.identityChanged }
                evidence?.record(old, tree: try old.treeStamps())
                return .init(disposition: .alreadyInstalled, manifest: oldManifest, warning: nil)
            }
            guard mkdirat(destination.fd, stageName, 0o700) == 0 else { throw ModelRepositoryCode.copyFailed }
            stageCreated = true
            let staging = try destination.child(stageName); stage = staging
            // Only the complete described payload is copied; optional source metadata is not runtime input.
            guard try acquired.directory.payloadPaths(allowManifest: true) == descriptor.files.map(\.path) else { throw ModelRepositoryCode.unsafeLayout }
            for file in descriptor.files {
                try await acquired.directory.copy(file.path, to: staging) { [hooks] in try await hooks.visit(.copyChunk) }
            }
            let verifiedPayload = try await verify(staging, descriptor: descriptor, installed: false)
            let value = try ModelInstallationManifest(descriptor: descriptor, origin: origin, installedAt: AbsoluteTime(Date()))
            try await hooks.visit(.manifestWrite)
            try Task.checkCancellation()
            guard try staging.treeStamps() == verifiedPayload else { throw ModelRepositoryCode.identityChanged }
            try staging.writeManifest(value)
            let verified = try snapshot(staging)
            try await hooks.visit(.flush); try staging.sync(); try destination.sync(); try finalParent.sync()
            try await hooks.visit(.beforePublish); try Task.checkCancellation()
            try acquired.directory.check(); try destination.check(); try finalParent.check()
            guard try snapshot(staging) == verified else { throw ModelRepositoryCode.identityChanged }
            try destination.publish(name: stageName, to: finalParent, finalName: finalName, owned: staging)
            committed = value // Irreversible local commit boundary. Never clean up this revision on cancellation.
            try finalParent.sync(); try destination.sync()
            let published = try finalParent.child(finalName)
            guard published.stamp.sameObject(staging.stamp) else { throw ModelRepositoryCode.identityChanged }
            let committedFingerprint = try snapshot(published)
            try await hooks.visit(.afterPublish)
            guard try snapshot(published) == committedFingerprint else { throw ModelRepositoryCode.identityChanged }
            await acquired.release(); lease = nil
            guard try snapshot(published) == committedFingerprint else { throw ModelRepositoryCode.identityChanged }
            evidence?.record(published, tree: try published.treeStamps())
            return .init(disposition: .installed, manifest: value, warning: Task.isCancelled ? .cancelled : nil)
        } catch {
            let first = failure(error)
            if let committed {
                if let lease { await lease.release() }
                return .init(disposition: .installed, manifest: committed, warning: first)
            }
            var cleanup: ModelRepositoryCode?
            if let stage, let store {
                do { try await hooks.visit(.cleanup); try store.removeOwned(stageName, expected: stage.stamp, beforeRemove: hooks.beforeRemove) }
                catch { cleanup = failure(error) }
            }
            if stageCreated, stage == nil { cleanup = .identityChanged }
            if let lease { await lease.release() }
            throw ModelOperationFailure(first, cleanupIssue: cleanup, retainedOperation: cleanup == nil ? nil : operation)
        }
    }
    func prepareDeletion(_ key: InstalledModelKey) async throws -> ModelDeletionAssessment {
        do {
            let claim = try claim(key); defer { claim.release() }
            let directory = try package(key, store: ModelPackageDirectory(url: storeURL()))
            let value = try manifest(directory, key: key); let fingerprint = try snapshot(directory)
            try await hooks.visit(.referenceScan)
            let report = await references.references(to: value.descriptor)
            guard try snapshot(directory) == fingerprint else { throw ModelRepositoryCode.staleAssessment }
            let result = ModelDeletionAssessment(id: UUID(), key: key, packageFingerprint: fingerprint, references: report)
            guard assessments.count < 128 else { throw ModelRepositoryCode.busy }
            assessments[result.id] = result; return result
        } catch { throw ModelOperationFailure(failure(error)) }
    }
    func delete(_ assessment: ModelDeletionAssessment, confirmation: ModelDeletionConfirmation?) async throws -> ModelDeletionResult {
        do {
            guard let confirmation, confirmation.assessmentID == assessment.id else { throw ModelRepositoryCode.confirmationRequired }
            guard assessments[assessment.id] == assessment else { throw ModelRepositoryCode.staleAssessment }
            guard assessment.references.sessions.isEmpty || confirmation.acknowledgeReferences,
                  assessment.references.isComplete || confirmation.acknowledgeIncompleteCoverage else { throw ModelRepositoryCode.acknowledgmentRequired }
            let claim = try claim(assessment.key); defer { claim.release() }
            let store = try ModelPackageDirectory(url: storeURL())
            let parent = try parent(assessment.key, store: store, create: false)
            let name = Self.namespace(assessment.key).last!
            let directory = try parent.child(name)
            guard try snapshot(directory) == assessment.packageFingerprint else { throw ModelRepositoryCode.staleAssessment }
            let value = try manifest(directory, key: assessment.key)
            // A newly discovered reference or warning requires a new assessment and confirmation.
            let current = await references.references(to: value.descriptor)
            guard current == assessment.references else { throw ModelRepositoryCode.staleAssessment }
            try await hooks.visit(.beforeDelete); try Task.checkCancellation()
            guard try snapshot(directory) == assessment.packageFingerprint else { throw ModelRepositoryCode.staleAssessment }
            try store.check(); try parent.check()
            let operation = UUID(); let trash = ".operation-" + operation.uuidString.lowercased()
            try parent.publish(name: name, to: store, finalName: trash, owned: directory)
            assessments[assessment.id] = nil
            do {
                let detached = try store.child(trash)
                guard detached.stamp.sameObject(directory.stamp) else { throw ModelRepositoryCode.identityChanged }
                let detachedFingerprint = try snapshot(detached)
                try await hooks.visit(.removing)
                guard try snapshot(detached) == detachedFingerprint else { throw ModelRepositoryCode.identityChanged }
                try store.removeOwned(trash, expected: directory.stamp, beforeRemove: hooks.beforeRemove)
            } catch { throw ModelOperationFailure(.incompleteRemoval, cleanupIssue: failure(error), retainedOperation: operation) }
            return .init(key: assessment.key)
        } catch let error as ModelOperationFailure { throw error }
        catch { throw ModelOperationFailure(failure(error)) }
    }
}
