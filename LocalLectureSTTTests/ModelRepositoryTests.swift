import CryptoKit
import Darwin
import XCTest
@testable import LocalLectureSTT

private struct TestFormatValidator: OfflineModelFormatValidating {
    let code: ModelRepositoryCode?
    init(_ code: ModelRepositoryCode? = nil) { self.code = code }
    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        if let code { throw code }
        guard descriptor.format == "generated-test-v1" else { throw ModelRepositoryCode.incompatible }
        // Real format recognizer seam: tests use a known generated header, not an always-true validator.
        let (parent, leaf) = try directory.parent(descriptor.files[0].path)
        let bytes = try parent.readMetadata(leaf)
        guard bytes.starts(with: Data("STT-TEST".utf8)) else { throw ModelRepositoryCode.incompatible }
    }
}
private struct TestReferences: ModelReferenceChecking {
    let report: ModelReferenceReport
    init(_ report: ModelReferenceReport = .init(sessions: [], warnings: [])) { self.report = report }
    func references(to descriptor: ModelPackageDescriptor) async -> ModelReferenceReport { report }
}
private actor ScopeCounts {
    var starts = 0; var stops = 0
    func start() -> Bool { starts += 1; return true }
    func stop() { stops += 1 }
    func counts() -> [Int] { [starts, stops] }
}
/// One acknowledged suspension, reusable by all filesystem race/cancel tests.
private actor ModelGate {
    private let expectation = XCTestExpectation(description: "model operation acknowledged gate")
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        if entered { return }; entered = true; expectation.fulfill()
        if !released { await withCheckedContinuation { releaseContinuation = $0 } }
    }
    func waitForEntry<T: Sendable>(of task: Task<T, Error>) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        guard result == .completed else {
            release(); task.cancel(); _ = try? await task.value
            throw ModelRepositoryCode.sourceUnavailable
        }
    }
    /// Failure cleanup is awaited so no held worker outlives its fixture.
    func withHeld<T: Sendable>(_ task: Task<T, Error>, operation: () async throws -> Void) async throws {
        do { try await waitForEntry(of: task); try await operation(); release() }
        catch { release(); task.cancel(); _ = try? await task.value; throw error }
    }
    func release() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}
private final class ModelFixture: @unchecked Sendable {
    let root: URL
    let source: URL
    let store: URL
    let sources = ModelImportSources()
    let scope = ScopeCounts()
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/stt-t12-test-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func descriptor(revision: String = "r/1", bytes: Data = Data("STT-TEST abc".utf8), path: String = "Native/weights.bin",
                    engine: String = "test/engine", model: String = "test/model") throws -> ModelPackageDescriptor {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return try .init(engine: EngineIdentity(id: EngineID(engine), version: "test-1"), modelID: ModelID(model), revision: revision,
                         format: "generated-test-v1", variant: "fixture", quantization: "none", compute: "test",
                         licenseIdentifier: "LicenseRef-Test", licenseTextOrReference: "Generated test data; redistribution permitted.",
                         licenseProvenance: "This test generated the payload.",
                         files: [ModelPayloadFile(path: path, byteCount: Int64(bytes.count), sha256: ModelPackageRules.sha256(bytes))])
    }
    func register() async -> ModelImportSourceID {
        await sources.register(source, start: { [scope] in await scope.start() }, stop: { [scope] in await scope.stop() })
    }
    func repository(validator: any OfflineModelFormatValidating = TestFormatValidator(),
                    references: any ModelReferenceChecking = TestReferences(), hooks: ModelRepositoryHooks = .init(),
                    catalog: BundledModelCatalogLoader = .init(), capacity: ModelStorageCapacityProvider = .init()) -> FileModelRepository {
        FileModelRepository(storeURL: { [store] in store }, sources: sources, validator: validator,
                            references: references, catalogLoader: catalog, hooks: hooks, capacity: capacity)
    }
    func installed(_ key: InstalledModelKey) -> URL {
        FileModelRepository.namespace(key).reduce(store) { $0.appendingPathComponent($1) }
    }
}

final class ModelRepositoryTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 30 }
    private func roundTrip<T: Codable & Sendable & Equatable>(_ value: T) throws {
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
    }
    private func mutate<T: Codable>(_ value: T, _ block: (inout [String: Any]) -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        block(&json)
        XCTAssertThrowsError(try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    private func expect(_ code: ModelRepositoryCode, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)") }
        catch let error as ModelOperationFailure { XCTAssertEqual(error.cause, code) }
        catch let error as ModelRepositoryCode { XCTAssertEqual(error, code) }
        catch { XCTFail("Unexpected \(error)") }
    }
    func testValidatedSchemasDecodeAndBoundaryRoundTrips() throws {
        let f = try ModelFixture(); let d = try f.descriptor()
        try roundTrip(d); try roundTrip(d.key)
        try roundTrip(BundledModelCatalog(entries: [d]))
        let m = try ModelInstallationManifest(descriptor: d, origin: .suppliedLocal, installedAt: AbsoluteTime(Date()))
        try roundTrip(m); try roundTrip(ModelImportSourceID())
        try roundTrip(ModelInventoryEntry(namespace: "opaque", manifest: m, state: .usable, issue: nil))
        try roundTrip(ModelImportResult(disposition: .installed, manifest: m, warning: .cancelled))
        try roundTrip(ModelOperationFailure(.copyFailed, cleanupIssue: .cleanupFailed, retainedOperation: UUID()))
        let a = ModelDeletionAssessment(id: UUID(), key: d.key, packageFingerprint: "evidence", references: .init(sessions: [.init(rootID: StorageRootID(), sessionID: SessionID(), checksumMatches: false)], warnings: ["unavailable"]))
        try roundTrip(a); try roundTrip(ModelDeletionConfirmation(assessmentID: a.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true))
        try roundTrip(ModelDeletionResult(key: d.key))
        try mutate(d) { $0["schemaVersion"] = 2 }
        try mutate(d) { $0["files"] = [] }
        try mutate(d) { var model = $0["model"] as! [String: Any]; model["checksum"] = String(repeating: "0", count: 64); $0["model"] = model }
        for path in ["/escape", "a//b", "a/../b", "./a", "manifest.json", ".operation-x/a", "a/Manifest.JSON", "a\\b", "e\u{301}/weights"] {
            XCTAssertThrowsError(try ModelPayloadFile(path: path, byteCount: 1, sha256: String(repeating: "a", count: 64)))
            try mutate(d.files[0]) { $0["path"] = path }
        }
        try mutate(d.files[0]) { $0["byteCount"] = -1 }
        try mutate(d.files[0]) { $0["sha256"] = "bad" }
        try mutate(d) { $0["licenseIdentifier"] = " " }
        try mutate(d) { $0["files"] = [$0["files"] as! [[String: Any]]].flatMap { $0 + $0 } }
        try mutate(BundledModelCatalog(entries: [d])) { $0["schemaVersion"] = 99 }
        XCTAssertThrowsError(try BundledModelCatalog(entries: [d,d]))
        try mutate(m) { $0["schemaVersion"] = 2 }
        try mutate(d.key) { $0["revision"] = "" }
    }
    func testBundleCatalogPinsTheProductModelOfflineAndConstructionIsInert() async throws {
        let f = try ModelFixture()
        let repository = f.repository()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.path))
        let catalog = try await repository.catalog()
        XCTAssertEqual(catalog.entries.map(\.engine), [WhisperCppProfile.identity])
        XCTAssertEqual(catalog.entries.first?.variant, "large-v3")
        XCTAssertEqual(catalog.schemaVersion, 1)
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [0,0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.path))
    }
    func testNamespacePreservesLogicalSlashesCaseAndManifestIdentity() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        let key = d.key
        let names = FileModelRepository.namespace(key)
        XCTAssertEqual(names.count, 3); XCTAssertTrue(names.allSatisfy { $0.count == 64 && !$0.contains("/") })
        XCTAssertNotEqual(names, FileModelRepository.namespace(try .init(engineID: key.engineID, modelID: ModelID("TEST/model"), revision: key.revision)))
        _ = try await r.importPackage(from: source, descriptor: d)
        let wrong = try InstalledModelKey(engineID: key.engineID, modelID: key.modelID, revision: "other")
        let target = f.installed(wrong); try FileManager.default.moveItem(at: f.installed(key), to: target)
        let result = try await r.validate(wrong); XCTAssertEqual(result.state, .corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testImportNestedIndependentCopyAndExactlyOnceScope() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        let result = try await r.importPackage(from: source, descriptor: d)
        XCTAssertEqual(result.disposition, .installed); XCTAssertEqual(result.manifest.origin, .suppliedLocal)
        await f.sources.unregister(source)
        try FileManager.default.removeItem(at: f.source)
        let fresh = f.repository(); let entry = try await fresh.validate(d.key)
        XCTAssertEqual(entry.state, .usable)
        let resolved = try await fresh.withResolvedPackage(d.key) { directory, descriptor in
            let (parent, leaf) = try directory.parent(descriptor.files[0].path)
            return try parent.readMetadata(leaf)
        }
        XCTAssertEqual(resolved, Data("STT-TEST abc".utf8))
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
    }
    func testIdempotenceConflictRevisionAndCatalogProvenanceCoexist() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
        let r = f.repository(catalog: .init(load: { try BundledModelCatalog(entries: [d]) }))
        let first = try await r.importPackage(from: source, descriptor: d, origin: .bundledCatalog)
        let second = try await r.importPackage(from: source, descriptor: d)
        XCTAssertEqual(second.disposition, .alreadyInstalled); XCTAssertEqual(first.manifest, second.manifest)
        let changed = try f.descriptor(bytes: Data("STT-TEST changed".utf8))
        await expect(.collision) { _ = try await r.importPackage(from: source, descriptor: changed) }
        let newer = try f.descriptor(revision: "r/2")
        _ = try await r.importPackage(from: source, descriptor: newer)
        let inventory = try await r.inventory(); XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(Set(inventory.compactMap { $0.manifest?.origin.rawValue }), ["suppliedLocal", "bundledCatalog"])
        XCTAssertEqual(try Data(contentsOf: f.installed(d.key).appendingPathComponent(d.files[0].path)), Data("STT-TEST abc".utf8))
    }
    func testInventoryDistinguishesCorruptUnavailableIncompatibleAndUnsupported() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        let empty = try await r.inventory(); XCTAssertTrue(empty.isEmpty)
        _ = try await r.importPackage(from: source, descriptor: d)
        let unavailable = try await f.repository(validator: UnavailableModelFormatValidator()).validate(d.key)
        XCTAssertEqual(unavailable.state, .unvalidated)
        let incompatible = try await f.repository(validator: TestFormatValidator(.incompatible)).validate(d.key)
        XCTAssertEqual(incompatible.state, .incompatible)
        try Data("STT-TEST BAD".utf8).write(to: f.installed(d.key).appendingPathComponent(d.files[0].path))
        let corrupt = try await r.validate(d.key); XCTAssertEqual(corrupt.state, .corrupt)
        await expect(.collision) { _ = try await r.importPackage(from: source, descriptor: d) }
        let manifest = f.installed(d.key).appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["schemaVersion"] = 999; try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let unsupported = try await r.inventory(); XCTAssertEqual(unsupported.first?.state, .unsupportedSchema)
        try FileManager.default.createDirectory(at: f.store.appendingPathComponent(".operation-unknown"), withIntermediateDirectories: false)
        let inventory = try await r.inventory(); XCTAssertEqual(inventory.count, 1)
        let sentinel = f.root.appendingPathComponent("sentinel"); try Data("x".utf8).write(to: sentinel)
        let bad = FileModelRepository(storeURL: { sentinel }, sources: f.sources, references: TestReferences())
        await expect(.storageUnavailable) { _ = try await bad.inventory() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }
}

extension ModelRepositoryTests {
    func testKnownAnswerChunkedHashesAndStablePackageDigest() async throws {
        let f = try ModelFixture()
        try Data("abc".utf8).write(to: f.source.appendingPathComponent("abc"))
        let directory = try ModelPackageDirectory(url: f.source)
        let known = try await directory.hash("abc", chunk: {})
        XCTAssertEqual(known.0, 3)
        XCTAssertEqual(known.1, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("abc"))
        var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 0x61, count: 200_000))
        let d = try f.descriptor(bytes: bytes); let source = await f.register()
        let counter = ScopeCounts()
        let r = f.repository(hooks: .init(visit: { point in if point == .hashChunk { _ = await counter.start() } }))
        _ = try await r.importPackage(from: source, descriptor: d)
        let counts = await counter.counts(); XCTAssertGreaterThan(counts[0], 3)
        let data = try Data(contentsOf: f.installed(d.key).appendingPathComponent(d.files[0].path))
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(d.files[0].sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let second = try ModelPayloadFile(path: "other", byteCount: 0, sha256: ModelPackageRules.sha256(Data()))
        XCTAssertEqual(ModelPackageRules.packageDigest([d.files[0], second]), ModelPackageRules.packageDigest([second, d.files[0]]))
        XCTAssertEqual(ModelPackageRules.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
    func testMissingLengthHashAndFormatFaultsRejectDestinationBytes() async throws {
        for fault in ["missing", "length", "hash", "format"] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
            let r = f.repository(hooks: .init(visit: { point in
                if point == .formatValidation, fault == "format" { throw ModelRepositoryCode.incompatible }
                if point == .hashChunk, fault != "format" {
                    let stages = try FileManager.default.contentsOfDirectory(at: f.store, includingPropertiesForKeys: nil)
                    if let stage = stages.first(where: { $0.lastPathComponent.hasPrefix(".operation-") }) {
                        let file = stage.appendingPathComponent(d.files[0].path)
                        if fault == "missing" { try? FileManager.default.removeItem(at: file) }
                        else { try Data((fault == "length" ? "x" : "STT-TEST xyz").utf8).write(to: file) }
                    }
                }
            }))
            do { _ = try await r.importPackage(from: source, descriptor: d); XCTFail("Accepted \(fault)") } catch {}
            let inventory = try await f.repository().inventory(); XCTAssertTrue(inventory.isEmpty)
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.appendingPathComponent(d.files[0].path).path))
        }
    }
    func testUnsafeLayoutsSymlinksSpecialFilesAndCaseCollisions() async throws {
        for kind in ["rootLink", "nestedLink", "fileLink", "fifo", "extra", "case"] {
            let f = try ModelFixture(); let d = try f.descriptor()
            let sentinel = f.root.appendingPathComponent("sentinel"); try Data("sentinel".utf8).write(to: sentinel)
            let file = f.source.appendingPathComponent(d.files[0].path)
            if kind == "rootLink" {
                try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("original"))
                try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: f.root.appendingPathComponent("original"))
            } else if kind == "nestedLink" {
                try FileManager.default.moveItem(at: f.source.appendingPathComponent("Native"), to: f.root.appendingPathComponent("Native"))
                try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("Native"), withDestinationURL: f.root.appendingPathComponent("Native"))
            } else if kind == "fileLink" || kind == "fifo" {
                try FileManager.default.removeItem(at: file)
                if kind == "fileLink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel) }
                else { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
            } else if kind == "case" { XCTAssertEqual(rename(file.path, f.source.appendingPathComponent("Native/WEIGHTS.BIN").path), 0) }
            else { try Data("extra".utf8).write(to: f.source.appendingPathComponent("extra")) }
            let source = await f.register()
            do { _ = try await f.repository().importPackage(from: source, descriptor: d); XCTFail("Accepted \(kind)") } catch {}
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
        }
        let file = try ModelPayloadFile(path: "A/file", byteCount: 0, sha256: ModelPackageRules.sha256(Data()))
        let other = try ModelPayloadFile(path: "a/other", byteCount: 0, sha256: ModelPackageRules.sha256(Data()))
        let f = try ModelFixture(); let d = try f.descriptor()
        XCTAssertThrowsError(try ModelPackageDescriptor(engine: d.engine, modelID: d.model.id, revision: d.model.revision,
            format: d.format, variant: d.variant, quantization: d.quantization, compute: d.compute,
            licenseIdentifier: d.licenseIdentifier, licenseTextOrReference: d.licenseTextOrReference, licenseProvenance: d.licenseProvenance,
            files: [file, other]))
    }
    func testInjectedFailuresRetainFirstCauseAndPermitRetry() async throws {
        let faults: [(ModelRepositoryPoint, ModelRepositoryCode)] = [(.copyChunk,.copyFailed),(.hashChunk,.hashFailed),(.manifestWrite,.manifestWriteFailed),(.flush,.flushFailed),(.beforePublish,.publishFailed)]
        for (point, code) in faults {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
            let r = f.repository(hooks: .init(visit: { if $0 == point { throw code } }))
            await expect(code) { _ = try await r.importPackage(from: source, descriptor: d) }
            let entries = try await f.repository().inventory(); XCTAssertTrue(entries.isEmpty)
            let retry = try await f.repository().importPackage(from: source, descriptor: d); XCTAssertEqual(retry.disposition, .installed)
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [2,2])
        }
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
        let broken = f.repository(hooks: .init(visit: { point in
            if point == .copyChunk { throw ModelRepositoryCode.copyFailed }
            if point == .cleanup { throw ModelRepositoryCode.cleanupFailed }
        }))
        do { _ = try await broken.importPackage(from: source, descriptor: d); XCTFail() }
        catch let e as ModelOperationFailure {
            XCTAssertEqual(e.cause, .copyFailed); XCTAssertEqual(e.cleanupIssue, .cleanupFailed); XCTAssertNotNil(e.retainedOperation)
        }
        let inventory = try await f.repository().inventory(); XCTAssertTrue(inventory.isEmpty)
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
        let denied = await f.sources.register(f.source, start: { false }, stop: { XCTFail("No acquired scope") })
        await expect(.scopeDenied) { _ = try await f.repository().importPackage(from: denied, descriptor: d) }
    }
    func testCancellationBeforeDuringAndAtPublicationIsTruthful() async throws {
        for point in [ModelRepositoryPoint.sourceAcquired, .copyChunk, .hashChunk, .beforePublish, .afterPublish] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
            let r = f.repository(hooks: .init(visit: { if $0 == point { await gate.hold() } }))
            let task = Task { try await r.importPackage(from: source, descriptor: d) }
            try await gate.waitForEntry(of: task); task.cancel(); await gate.release()
            if point == .afterPublish {
                let result = try await task.value; XCTAssertEqual(result.disposition, .installed); XCTAssertEqual(result.warning, .cancelled)
                let entry = try await f.repository().validate(d.key); XCTAssertEqual(entry.state, .usable)
            } else {
                await expect(.cancelled) { _ = try await task.value }
                let inventory = try await f.repository().inventory(); XCTAssertTrue(inventory.isEmpty)
            }
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
        }
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let task = Task { await gate.hold(); return try await f.repository().importPackage(from: source, descriptor: d) }
        try await gate.waitForEntry(of: task); task.cancel(); await gate.release()
        await expect(.cancelled) { _ = try await task.value }
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [0,0])
    }
    func testSourceAndStoreReplacementCannotReadOrCleanUnrelatedFiles() async throws {
        for point in [ModelRepositoryPoint.copyChunk, .beforePublish] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
            let r = f.repository(hooks: .init(visit: { if $0 == point { await gate.hold() } }))
            let task = Task { try await r.importPackage(from: source, descriptor: d) }
            try await gate.withHeld(task) {
                let victim = point == .copyChunk ? f.source : f.store
                let saved = f.root.appendingPathComponent("saved")
                try FileManager.default.moveItem(at: victim, to: saved)
                try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
                let sentinel = victim.appendingPathComponent("sentinel"); try Data("unrelated".utf8).write(to: sentinel)
            }
            do { _ = try await task.value; XCTFail("Replacement accepted") } catch {}
            let sentinel = (point == .copyChunk ? f.source : f.store).appendingPathComponent("sentinel")
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("unrelated".utf8))
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
        }
    }
    func testSameKeyClaimsAcrossInstancesAndImportDeleteRace() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { if $0 == .copyChunk { await gate.hold() } }))
        let first = Task { try await r.importPackage(from: source, descriptor: d) }
        try await gate.waitForEntry(of: first)
        await expect(.busy) { _ = try await f.repository().importPackage(from: source, descriptor: d) }
        await expect(.busy) { _ = try await r.prepareDeletion(d.key) }
        await gate.release(); _ = try await first.value
        let assessment = try await r.prepareDeletion(d.key)
        let secondGate = ModelGate()
        let idempotent = f.repository(hooks: .init(visit: { if $0 == .hashChunk { await secondGate.hold() } }))
        let pending = Task { try await idempotent.importPackage(from: source, descriptor: d) }
        try await secondGate.waitForEntry(of: pending)
        await expect(.busy) { _ = try await r.delete(assessment, confirmation: .init(assessmentID: assessment.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)) }
        await secondGate.release(); _ = try await pending.value
        let inventory = try await r.inventory(); XCTAssertEqual(inventory.filter { $0.state == .usable }.count, 1)
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [2,2])
    }
    func testDestinationNoClobberAtPublishAndCommittedFaultWarning() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { if $0 == .beforePublish { await gate.hold() } }))
        let task = Task { try await r.importPackage(from: source, descriptor: d) }
        let target = f.installed(d.key)
        try await gate.withHeld(task) {
             try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("other".utf8).write(to: target.appendingPathComponent("sentinel"))
        }
        await expect(.collision) { _ = try await task.value }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("sentinel")), Data("other".utf8))
        let f2 = try ModelFixture(); let d2 = try f2.descriptor(); let source2 = await f2.register()
        let committed = f2.repository(hooks: .init(visit: { if $0 == .afterPublish { throw ModelRepositoryCode.flushFailed } }))
        let result = try await committed.importPackage(from: source2, descriptor: d2)
        XCTAssertEqual(result.disposition, .installed); XCTAssertEqual(result.warning, .flushFailed)
        let entry = try await f2.repository().validate(d2.key); XCTAssertEqual(entry.state, .usable)
    }
}

private actor ModelTestBookmarks: SecurityScopedBookmarkCodec {
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: false) }
    func startAccessing(_ url: URL) async -> Bool { true }
    func stopAccessing(_ url: URL) async {}
}
private extension ModelFixture {
    func session(in root: URL, descriptor: ModelPackageDescriptor?, revision: String? = nil) throws -> (URL, SessionID) {
        let id = SessionID(); let now = AbsoluteTime(Date())
        let folder = SessionFolderName(sessionID: id, createdAt: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let directory = root.appendingPathComponent(folder.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try descriptor.map { try ModelIdentity(id: $0.model.id, revision: revision ?? $0.model.revision, checksum: $0.model.checksum) }
        let metadata = try SessionMetadataDocument(sessionId: id, title: "Generated session", status: .completed, captureOutcome: .completed,
            createdAt: now, activeDurationMs: MediaMilliseconds(0), languageMode: .korean, engine: descriptor?.engine,
            model: model, transcript: TranscriptSummary(segmentCount: TranscriptSegmentCount(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: now)
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        for file in ["audio.m4a", "transcript.json", "events.jsonl"] { try Data("generated sentinel \(file)".utf8).write(to: directory.appendingPathComponent(file)) }
        return (directory, id)
    }
}
extension ModelRepositoryTests {
    func testReadOnlyReferencesAcrossActiveHistoricalMissingAndCorruptRoots() async throws {
        let f = try ModelFixture(); let d = try f.descriptor()
        let rootA = f.root.appendingPathComponent("sessionsA"); let rootB = f.root.appendingPathComponent("sessionsB")
        let (a, aID) = try f.session(in: rootA, descriptor: d)
        let (_, bID) = try f.session(in: rootB, descriptor: d)
        _ = try f.session(in: rootB, descriptor: nil)
        _ = try f.session(in: rootB, descriptor: d, revision: "other")
        let roots = StorageRootManager(applicationSupportDirectory: f.root.appendingPathComponent("support"), bookmarkCodec: ModelTestBookmarks())
        let aRoot = try await roots.registerSelectedDirectory(rootA)
        let bRoot = try await roots.registerSelectedDirectory(rootB)
        let before = try Data(contentsOf: a.appendingPathComponent("metadata.json"))
        let checker = SessionModelReferenceChecker(roots: roots)
        let report = await checker.references(to: d)
        XCTAssertEqual(Set(report.sessions.map(\.sessionID)), [aID, bID]); XCTAssertTrue(report.isComplete)
        XCTAssertEqual(Set(report.sessions.map(\.rootID)), [aRoot.id, bRoot.id])
        XCTAssertTrue(report.sessions.allSatisfy(\.checksumMatches))
        let (bad, _) = try f.session(in: rootB, descriptor: nil)
        try Data("broken".utf8).write(to: bad.appendingPathComponent("metadata.json"))
        try FileManager.default.moveItem(at: rootA, to: f.root.appendingPathComponent("unavailable-root"))
        let incomplete = await checker.references(to: d)
        XCTAssertFalse(incomplete.isComplete); XCTAssertEqual(incomplete.sessions.map(\.sessionID), [bID]); XCTAssertEqual(incomplete.warnings.count, 2)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("unavailable-root").appendingPathComponent(a.lastPathComponent).appendingPathComponent("metadata.json")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("support/LocalLectureSTT/catalog.sqlite").path))
    }
    func testDeletionRequiresExactConfirmationAcknowledgmentsAndPreservesSessionsAndSibling() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
        let (session, sessionID) = try f.session(in: f.root.appendingPathComponent("sessions"), descriptor: d)
        let before = try FileManager.default.contentsOfDirectory(atPath: session.path).sorted().map { try Data(contentsOf: session.appendingPathComponent($0)) }
        let references = TestReferences(.init(sessions: [.init(rootID: StorageRootID(), sessionID: sessionID, checksumMatches: true)], warnings: ["Historical root unavailable"]))
        let r = f.repository(references: references)
        _ = try await r.importPackage(from: source, descriptor: d)
        let sibling = try f.descriptor(revision: "next"); _ = try await r.importPackage(from: source, descriptor: sibling)
        let assessment = try await r.prepareDeletion(d.key)
        XCTAssertEqual(assessment.references.sessions.count, 1); XCTAssertFalse(assessment.references.isComplete)
        await expect(.confirmationRequired) { _ = try await r.delete(assessment, confirmation: nil) }
        await expect(.confirmationRequired) { _ = try await r.delete(assessment, confirmation: .init(assessmentID: UUID(), acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)) }
        for ack in [(false,true),(true,false)] {
            await expect(.acknowledgmentRequired) { _ = try await r.delete(assessment, confirmation: .init(assessmentID: assessment.id, acknowledgeReferences: ack.0, acknowledgeIncompleteCoverage: ack.1)) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.installed(d.key).path))
        let result = try await r.delete(assessment, confirmation: .init(assessmentID: assessment.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true))
        XCTAssertEqual(result.key, d.key); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed(d.key).path))
        let siblingEntry = try await r.validate(sibling.key); XCTAssertEqual(siblingEntry.state, .usable)
        let after = try FileManager.default.contentsOfDirectory(atPath: session.path).sorted().map { try Data(contentsOf: session.appendingPathComponent($0)) }
        XCTAssertEqual(before, after)
        _ = try await r.importPackage(from: source, descriptor: d)
        await expect(.staleAssessment) { _ = try await r.delete(assessment, confirmation: .init(assessmentID: assessment.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)) }
    }
    func testStaleReplacedAndSymlinkDeletionCannotTouchSentinel() async throws {
        for link in [false,true] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
            let r = f.repository(hooks: .init(visit: { if $0 == .beforeDelete { await gate.hold() } }))
            _ = try await r.importPackage(from: source, descriptor: d)
            let a = try await r.prepareDeletion(d.key)
            let pending = Task { try await r.delete(a, confirmation: .init(assessmentID: a.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)) }
            let unrelated = f.root.appendingPathComponent("unrelated")
            try await gate.withHeld(pending) {
                let target = f.installed(d.key); try FileManager.default.moveItem(at: target, to: f.root.appendingPathComponent("old"))
                try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
                try Data("safe".utf8).write(to: unrelated.appendingPathComponent("sentinel"))
                if link { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: unrelated) }
                else { try FileManager.default.copyItem(at: unrelated, to: target) }
            }
            do { _ = try await pending.value; XCTFail() } catch {}
            XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("sentinel")), Data("safe".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("old/manifest.json").path))
        }
    }
    func testDeletionCancellationFailureAndPartialRemovalAreHonest() async throws {
        for point in [ModelRepositoryPoint.beforeDelete, .removing] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
            let r = f.repository(hooks: .init(visit: { if $0 == point { throw ModelRepositoryCode.deletionFailed } }))
            _ = try await r.importPackage(from: source, descriptor: d); let a = try await r.prepareDeletion(d.key)
            do { _ = try await r.delete(a, confirmation: .init(assessmentID: a.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)); XCTFail() }
            catch let e as ModelOperationFailure {
                XCTAssertEqual(e.cause, point == .beforeDelete ? .deletionFailed : .incompleteRemoval)
                if point == .removing { XCTAssertNotNil(e.retainedOperation); XCTAssertEqual(e.cleanupIssue, .deletionFailed) }
            }
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.installed(d.key).path), point == .beforeDelete)
            let names = try FileManager.default.contentsOfDirectory(atPath: f.store.path)
            if point == .removing { XCTAssertTrue(names.contains { $0.hasPrefix(".operation-") }) }
        }
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { if $0 == .beforeDelete { await gate.hold() } }))
        _ = try await r.importPackage(from: source, descriptor: d); let a = try await r.prepareDeletion(d.key)
        let task = Task { try await r.delete(a, confirmation: .init(assessmentID: a.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)) }
        try await gate.waitForEntry(of: task); task.cancel(); await gate.release()
        await expect(.cancelled) { _ = try await task.value }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.installed(d.key).path))
    }
}

private final class RemovalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func beforeRemove(_ path: String) throws {
        try lock.withLock { count += 1; if count == 2 { throw ModelRepositoryCode.deletionFailed } }
    }
    var calls: Int { lock.withLock { count } }
}
extension ModelRepositoryTests {
    func testActualPartialDeletionRetainsRemnantsAndReportsFailure() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let fault = RemovalFault()
        let r = f.repository(hooks: .init(beforeRemove: { try fault.beforeRemove($0) }))
        _ = try await r.importPackage(from: source, descriptor: d); let a = try await r.prepareDeletion(d.key)
        do { _ = try await r.delete(a, confirmation: .init(assessmentID: a.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)); XCTFail() }
        catch let error as ModelOperationFailure {
            XCTAssertEqual(error.cause, .incompleteRemoval); XCTAssertEqual(error.cleanupIssue, .deletionFailed)
            let id = try XCTUnwrap(error.retainedOperation)
            let remnants = f.store.appendingPathComponent(".operation-" + id.uuidString.lowercased())
            XCTAssertTrue(FileManager.default.fileExists(atPath: remnants.appendingPathComponent("manifest.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: remnants.appendingPathComponent(d.files[0].path).path))
        }
        XCTAssertEqual(fault.calls, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.appendingPathComponent(d.files[0].path).path))
    }
    func testOldCleanupClaimBlocksRetryAndCannotTouchNextInstall() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { point in
            if point == .copyChunk { throw ModelRepositoryCode.copyFailed }
            if point == .cleanup { await gate.hold() }
        }))
        let old = Task { try await r.importPackage(from: source, descriptor: d) }
        try await gate.waitForEntry(of: old)
        await expect(.busy) { _ = try await f.repository().importPackage(from: source, descriptor: d) }
        await gate.release(); await expect(.copyFailed) { _ = try await old.value }
        let retry = try await f.repository().importPackage(from: source, descriptor: d)
        XCTAssertEqual(retry.disposition, .installed)
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [2,2])
    }
    func testNestedDirectoryAndPublicationParentReplacementAreRejected() async throws {
        for point in [ModelRepositoryPoint.copyChunk, .beforePublish] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
            let r = f.repository(hooks: .init(visit: { if $0 == point { await gate.hold() } }))
            let task = Task { try await r.importPackage(from: source, descriptor: d) }
            let target = point == .copyChunk ? f.source.appendingPathComponent("Native") : f.installed(d.key).deletingLastPathComponent()
            try await gate.withHeld(task) {
                try FileManager.default.moveItem(at: target, to: f.root.appendingPathComponent("original-directory"))
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let sentinel = target.appendingPathComponent("sentinel"); try Data("unrelated".utf8).write(to: sentinel)
            }
            do { _ = try await task.value; XCTFail() } catch {}
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("sentinel")), Data("unrelated".utf8))
        }
    }
    func testHardLinkSourceCopiesIntoAnIndependentRegularFile() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
        let original = f.source.appendingPathComponent(d.files[0].path)
        let external = f.root.appendingPathComponent("external-link")
        XCTAssertEqual(link(original.path, external.path), 0)
        _ = try await f.repository().importPackage(from: source, descriptor: d)
        var sourceStat = stat(); var installedStat = stat()
        XCTAssertEqual(lstat(original.path, &sourceStat), 0)
        XCTAssertEqual(lstat(f.installed(d.key).appendingPathComponent(d.files[0].path).path, &installedStat), 0)
        XCTAssertNotEqual(sourceStat.st_ino, installedStat.st_ino); XCTAssertEqual(installedStat.st_nlink, 1)
        try Data("STT-TEST changed".utf8).write(to: external)
        let result = try await f.repository().validate(d.key); XCTAssertEqual(result.state, .usable)
    }
}

extension ModelRepositoryTests {
    private func writeImportManifest(_ f: ModelFixture, _ descriptor: ModelPackageDescriptor) throws {
        let value = try ModelInstallationManifest(descriptor: descriptor, origin: .suppliedLocal, installedAt: AbsoluteTime(Date()))
        try JSONEncoder().encode(value).write(to: f.source.appendingPathComponent("manifest.json"))
    }
    @MainActor private func realModelUI(_ f: ModelFixture, _ repository: FileModelRepository,
                                       select: (@MainActor () async -> ModelImportSourceID?)? = nil) -> ModelManagementViewModel {
        let importer = ModelFolderImporter(repository: repository, sources: f.sources, selectSource: select ?? { await f.register() })
        return ModelManagementViewModel(repository: repository,
            downloader: ModelDownloadService(repository: repository, storage: .init(rootURL: { f.root.appendingPathComponent("downloads") })),
            supports: { $0.format == "generated-test-v1" }, importFolder: { try await importer.importFolder($0) })
    }
    @MainActor func testG3GenericImportUsesProductionUIAdapterAndRepository() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); try writeImportManifest(f, d)
        let r = f.repository(catalog: .init { try .init(entries: [d]) })
        let source = await f.register()
        let vm = realModelUI(f, r, select: { source })
        await vm.refresh(); XCTAssertFalse(vm.readyToRecord)
        await vm.importModel(nil)
        XCTAssertTrue(vm.readyToRecord); XCTAssertEqual(vm.selectedDescriptor, d)
        XCTAssertEqual(vm.inventory.first?.manifest?.origin, .suppliedLocal)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(d.files[0].path)),
                       try Data(contentsOf: f.installed(d.key).appendingPathComponent(d.files[0].path)))
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [1, 1])
        do { _ = try await f.sources.acquire(source); XCTFail("Selection was not unregistered") }
        catch { XCTAssertEqual(error as? ModelRepositoryCode, .sourceUnavailable) }
        try FileManager.default.removeItem(at: f.source)
        let verified = try await r.validate(d.key); XCTAssertEqual(verified.state, .usable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("downloads").path))
    }
    @MainActor func testG3ImportCancellationBadManifestAndTamperedPayloadRemainUnavailable() async throws {
        let f = try ModelFixture(); let d = try f.descriptor()
        let r = f.repository(catalog: .init { try .init(entries: [d]) })
        let cancelled = realModelUI(f, r, select: { nil }); await cancelled.refresh(); await cancelled.importModel(nil)
        XCTAssertNil(cancelled.message); XCTAssertFalse(cancelled.readyToRecord)
        let source = await f.register(); let vm = realModelUI(f, r, select: { source }); await vm.refresh()
        try Data("broken manifest".utf8).write(to: f.source.appendingPathComponent("manifest.json"))
        await vm.importModel(nil)
        XCTAssertTrue(vm.message?.contains("invalidDescriptor") == true); XCTAssertFalse(vm.readyToRecord)
        do { _ = try await f.sources.acquire(source); XCTFail("Selection was not unregistered") }
        catch { XCTAssertEqual(error as? ModelRepositoryCode, .sourceUnavailable) }
        try writeImportManifest(f, d)
        try Data("STT-TEST xyz".utf8).write(to: f.source.appendingPathComponent(d.files[0].path))
        let other = realModelUI(f, r); await other.refresh(); await other.importModel(nil)
        XCTAssertTrue(other.message?.contains("integrityMismatch") == true); XCTAssertFalse(other.readyToRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed(d.key).path))
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(d.files[0].path)), Data("STT-TEST xyz".utf8))
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [2, 2])
    }
    func testG3ImportCapacityExactBoundaryUnknownAndOverflow() throws {
        let needed = ModelImportCapacity.safetyBytes + 10
        let exact = try ModelImportCapacity.assess(lengths: [4, 6], available: needed)
        XCTAssertEqual(exact.requiredBytes, needed)
        for (lengths, available, code): ([Int64], Int64?, ModelRepositoryCode) in [
            ([10], needed - 1, .insufficientCapacity), ([10], nil, .capacityUnknown), ([10], -1, .capacityUnknown),
            ([Int64.max], Int64.max, .capacityOverflow), ([-1], needed, .capacityOverflow)
        ] {
            XCTAssertThrowsError(try ModelImportCapacity.assess(lengths: lengths, available: available)) { XCTAssertEqual($0 as? ModelRepositoryCode, code) }
        }
    }
    @MainActor func testG3CatalogFolderImportAndFutureManifestUseRealUIRepository() async throws {
        let f = try ModelFixture(); let d = try f.descriptor()
        let r = f.repository(catalog: .init { try .init(entries: [d]) }); let vm = realModelUI(f, r)
        await vm.refresh(); await vm.importModel(d)
        XCTAssertTrue(vm.readyToRecord); XCTAssertEqual(vm.selectedDescriptor, d)
        let before = try Data(contentsOf: f.installed(d.key).appendingPathComponent("manifest.json"))
        try Data("{\"schemaVersion\":2}".utf8).write(to: f.source.appendingPathComponent("manifest.json"))
        await vm.importModel(nil)
        XCTAssertTrue(vm.message?.contains("unsupportedSchema") == true)
        XCTAssertEqual(try Data(contentsOf: f.installed(d.key).appendingPathComponent("manifest.json")), before)
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [2, 2])
    }
    @MainActor func testG3FolderAdapterCancellationAfterSelectionUnregistersWithoutOpeningScope() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); try writeImportManifest(f, d)
        let source = await f.register(); let gate = ModelGate()
        let importer = ModelFolderImporter(repository: f.repository(), sources: f.sources, selectSource: {
            await gate.hold(); return source
        })
        let task = Task { try await importer.importFolder(nil) }
        try await gate.waitForEntry(of: task)
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled selection was imported") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await f.sources.acquire(source); XCTFail("Selection was retained") }
        catch { XCTAssertEqual(error as? ModelRepositoryCode, .sourceUnavailable) }
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [0, 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.path))
    }
    @MainActor func testG3CapacityRejectsBeforeCopyAndPreservesSourceAndExistingRevision() async throws {
        for available: Int64? in [0, nil, -1] {
            let f = try ModelFixture(); let old = try f.descriptor(revision: "old"); let source = await f.register()
            _ = try await f.repository().importPackage(from: source, descriptor: old)
            let original = try Data(contentsOf: f.installed(old.key).appendingPathComponent(old.files[0].path))
            let d = try f.descriptor(revision: "new"); try writeImportManifest(f, d)
            let r = f.repository(hooks: .init(visit: { if $0 == .copyChunk { XCTFail("Capacity denial reached payload copy") } }),
                                 catalog: .init { try .init(entries: [d]) }, capacity: .init(available: { _ in available }))
            let vm = realModelUI(f, r); await vm.refresh(); await vm.importModel(nil)
            XCTAssertTrue(vm.message?.contains(available == 0 ? "insufficientCapacity" : "capacityUnknown") == true)
            XCTAssertEqual(try Data(contentsOf: f.installed(old.key).appendingPathComponent(old.files[0].path)), original)
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(d.files[0].path)), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed(d.key).path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.store.path).contains { $0.hasPrefix(".operation-") })
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [2, 2])
        }
    }
    func testG3CapacityQueryFailureAndAlreadyInstalledLowSpace() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
        let bad = f.repository(capacity: .init(available: { _ in throw ModelRepositoryCode.storageUnavailable }))
        await expect(.capacityUnknown) { _ = try await bad.importPackage(from: source, descriptor: d) }
        let required = ModelImportCapacity.safetyBytes + d.files[0].byteCount
        let r = f.repository(capacity: .init(available: { _ in required }))
        _ = try await r.importPackage(from: source, descriptor: d)
        let low = f.repository(capacity: .init(available: { _ in XCTFail("Idempotent import needs no copy space"); return 0 }))
        let result = try await low.importPackage(from: source, descriptor: d)
        XCTAssertEqual(result.disposition, .alreadyInstalled)
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [3, 3])
    }
    @MainActor func testG3ManifestRecoveryUIRequiresConfirmationPreservesBytesAndAllowsReinstall() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); try writeImportManifest(f, d)
        let r = f.repository(catalog: .init { try .init(entries: [d]) })
        let vm = realModelUI(f, r); await vm.refresh(); await vm.importModel(nil)
        let sibling = try f.descriptor(revision: "sibling"); let source = await f.register()
        _ = try await r.importPackage(from: source, descriptor: sibling)
        let session = f.root.appendingPathComponent("session-sentinel"); try Data("audio and transcript".utf8).write(to: session)
        let installed = f.installed(d.key); let bad = Data("invalid json".utf8)
        try bad.write(to: installed.appendingPathComponent("manifest.json"))
        await vm.refresh()
        let entry = try XCTUnwrap(vm.inventory.first { $0.manifest == nil })
        XCTAssertEqual(entry.state, .corrupt)
        vm.recordingLocked = true; await vm.prepareRecovery(entry.namespace); XCTAssertNil(vm.recovery)
        vm.recordingLocked = false; await vm.prepareRecovery(entry.namespace)
        XCTAssertNotNil(vm.recovery); XCTAssertTrue(vm.busy); XCTAssertTrue(vm.currentWork().requiresAttention)
        vm.cancelRecovery(); XCTAssertNil(vm.recovery); XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        await vm.prepareRecovery(entry.namespace); await vm.confirmRecovery(acknowledgeUnidentifiedReferences: false)
        XCTAssertNotNil(vm.recovery); XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        await vm.confirmRecovery(acknowledgeUnidentifiedReferences: true)
        XCTAssertNil(vm.recovery); XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        let retained = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.store, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".preserved-") })
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("manifest.json")), bad)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(d.files[0].path)), Data("STT-TEST abc".utf8))
        await vm.importModel(nil); XCTAssertEqual(vm.selectedDescriptor, d); XCTAssertTrue(vm.readyToRecord)
        let verifiedSibling = try await r.validate(sibling.key); XCTAssertEqual(verifiedSibling.state, .usable)
        XCTAssertEqual(try Data(contentsOf: session), Data("audio and transcript".utf8))
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("manifest.json")), bad)
        XCTAssertTrue(vm.inventory.allSatisfy { $0.state == .usable })
    }
    func testG3RecoveryMissingManifestAndStaleOrAbsentConfirmation() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let r = f.repository(); let source = await f.register()
        _ = try await r.importPackage(from: source, descriptor: d)
        let dir = f.installed(d.key); try FileManager.default.removeItem(at: dir.appendingPathComponent("manifest.json"))
        let ns = FileModelRepository.namespace(d.key).joined(separator: "/")
        let a = try await r.prepareRecovery(namespace: ns)
        await expect(.confirmationRequired) { _ = try await r.preserveForRecovery(a, confirmation: nil) }
        await expect(.acknowledgmentRequired) { _ = try await r.preserveForRecovery(a, confirmation: .init(assessmentID: a.id, acknowledgeUnidentifiedReferences: false)) }
        try Data("new file".utf8).write(to: dir.appendingPathComponent("sentinel"))
        await expect(.staleAssessment) { _ = try await r.preserveForRecovery(a, confirmation: .init(assessmentID: a.id, acknowledgeUnidentifiedReferences: true)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let fresh = try await r.prepareRecovery(namespace: ns)
        let result = try await r.preserveForRecovery(fresh, confirmation: .init(assessmentID: fresh.id, acknowledgeUnidentifiedReferences: true))
        let retained = f.store.appendingPathComponent(".preserved-" + result.retainedID.uuidString.lowercased())
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("sentinel")), Data("new file".utf8))
        await expect(.staleAssessment) { _ = try await r.preserveForRecovery(fresh, confirmation: .init(assessmentID: fresh.id, acknowledgeUnidentifiedReferences: true)) }
    }
    @MainActor func testG3WrongManifestIdentityCannotTargetHealthySiblingFromUI() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let other = try f.descriptor(model: "other")
        let r = f.repository(catalog: .init { try .init(entries: [d, other]) }); let source = await f.register()
        _ = try await r.importPackage(from: source, descriptor: d)
        _ = try await r.importPackage(from: source, descriptor: other)
        let healthyBytes = try Data(contentsOf: f.installed(other.key).appendingPathComponent("manifest.json"))
        try healthyBytes.write(to: f.installed(d.key).appendingPathComponent("manifest.json"))
        let vm = realModelUI(f, r); await vm.refresh()
        let ns = FileModelRepository.namespace(d.key).joined(separator: "/")
        let row = try XCTUnwrap(vm.inventory.first { $0.namespace == ns })
        XCTAssertEqual(row.state, .corrupt); XCTAssertNil(row.manifest)
        await vm.prepareRecovery(row.namespace); XCTAssertNotNil(vm.recovery)
        await vm.confirmRecovery(acknowledgeUnidentifiedReferences: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed(d.key).path))
        XCTAssertEqual(try Data(contentsOf: f.installed(other.key).appendingPathComponent("manifest.json")), healthyBytes)
        let valid = try await r.validate(other.key); XCTAssertEqual(valid.state, .usable)
        XCTAssertEqual(vm.selectedDescriptor, other)
        let retained = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.store, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".preserved-") })
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("manifest.json")), healthyBytes)
        await vm.importModel(d); XCTAssertEqual(vm.selectedDescriptor, d)
    }
    func testG3RecoveryRejectsHealthyFutureSchemaAndPathOrSymlinkEscape() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let r = f.repository(); let source = await f.register()
        _ = try await r.importPackage(from: source, descriptor: d)
        let ns = FileModelRepository.namespace(d.key).joined(separator: "/")
        await expect(.invalidDescriptor) { _ = try await r.prepareRecovery(namespace: ns) }
        for unsafe in ["../source", ns + "/..", "/" + ns] { await expect(.unsafeLayout) { _ = try await r.prepareRecovery(namespace: unsafe) } }
        let manifest = f.installed(d.key).appendingPathComponent("manifest.json")
        try Data("{\"schemaVersion\":2}".utf8).write(to: manifest)
        await expect(.unsupportedSchema) { _ = try await r.prepareRecovery(namespace: ns) }
        try Data("bad".utf8).write(to: manifest)
        let external = f.root.appendingPathComponent("external"); try Data("untouched".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: f.installed(d.key).appendingPathComponent("link"), withDestinationURL: external)
        await expect(.unsafeLayout) { _ = try await r.prepareRecovery(namespace: ns) }
        XCTAssertEqual(try Data(contentsOf: external), Data("untouched".utf8))
    }
    func testG3RecoveryClaimAndCancellationCannotMoveOrDeletePackage() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
        _ = try await f.repository().importPackage(from: source, descriptor: d)
        try Data("bad".utf8).write(to: f.installed(d.key).appendingPathComponent("manifest.json"))
        let gate = ModelGate(); let r = f.repository(hooks: .init(visit: { if $0 == .beforeRecovery { await gate.hold() } }))
        let ns = FileModelRepository.namespace(d.key).joined(separator: "/"); let a = try await r.prepareRecovery(namespace: ns)
        let task = Task { try await r.preserveForRecovery(a, confirmation: .init(assessmentID: a.id, acknowledgeUnidentifiedReferences: true)) }
        try await gate.withHeld(task) {
            let other = f.repository()
            do { _ = try await other.prepareRecovery(namespace: ns); XCTFail("Missing recovery claim") }
            catch { XCTAssertEqual((error as? ModelOperationFailure)?.cause, .busy) }
            do { _ = try await other.importPackage(from: source, descriptor: d); XCTFail("Missing import claim") }
            catch { XCTAssertEqual((error as? ModelOperationFailure)?.cause, .busy) }
            task.cancel()
        }
        await expect(.cancelled) { _ = try await task.value }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.installed(d.key).path))
        _ = try await f.repository().prepareRecovery(namespace: ns)
    }
    func testG3RecoveryRechecksReplacementAtPublicationAndReportsCommittedWarning() async throws {
        for replacement in [true, false] {
            let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register()
            _ = try await f.repository().importPackage(from: source, descriptor: d)
            let dir = f.installed(d.key); try Data("bad".utf8).write(to: dir.appendingPathComponent("manifest.json"))
            let moved = f.root.appendingPathComponent("original")
            let r = f.repository(hooks: .init(visit: { point in
                if replacement, point == .beforeRecovery {
                    try FileManager.default.moveItem(at: dir, to: moved)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                    try Data("replacement".utf8).write(to: dir.appendingPathComponent("sentinel"))
                }
                if !replacement, point == .afterRecovery { throw ModelRepositoryCode.flushFailed }
            }))
            let a = try await r.prepareRecovery(namespace: FileModelRepository.namespace(d.key).joined(separator: "/"))
            if replacement {
                await expect(.identityChanged) { _ = try await r.preserveForRecovery(a, confirmation: .init(assessmentID: a.id, acknowledgeUnidentifiedReferences: true)) }
                XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("sentinel")), Data("replacement".utf8))
                XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("manifest.json")), Data("bad".utf8))
            } else {
                let result = try await r.preserveForRecovery(a, confirmation: .init(assessmentID: a.id, acknowledgeUnidentifiedReferences: true))
                XCTAssertEqual(result.warning, .flushFailed)
                let retained = f.store.appendingPathComponent(".preserved-" + result.retainedID.uuidString.lowercased())
                XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("manifest.json")), Data("bad".utf8))
                _ = try await r.importPackage(from: source, descriptor: d)
                XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
            }
        }
    }
    func testMissingFilesUnrecognizedMetadataAndUnreadableStoreAreNotUsable() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        await expect(.descriptorRequired) { _ = try await r.importPackage(from: source, descriptor: nil) }
        await expect(.invalidDescriptor) { _ = try await r.importPackage(from: source, descriptor: d, origin: .bundledCatalog) }
        _ = try await r.importPackage(from: source, descriptor: d)
        try FileManager.default.removeItem(at: f.installed(d.key).appendingPathComponent(d.files[0].path))
        let missing = try await r.validate(d.key); XCTAssertEqual(missing.state, .corrupt)
        let manifest = f.installed(d.key).appendingPathComponent("manifest.json")
        try Data("bad json".utf8).write(to: manifest)
        let corrupt = try await r.inventory(); XCTAssertEqual(corrupt.first?.state, .corrupt)
        await expect(.collision) { _ = try await r.importPackage(from: source, descriptor: d) }
        XCTAssertEqual(chmod(f.store.path, 0), 0)
        defer { _ = chmod(f.store.path, 0o700) }
        await expect(.storageUnavailable) { _ = try await r.inventory() }
        XCTAssertEqual(chmod(f.store.path, 0o700), 0)
        XCTAssertEqual(try Data(contentsOf: manifest), Data("bad json".utf8))
    }
    func testDistinctEngineModelAndRevisionNamespacesCoexist() async throws {
        let f = try ModelFixture(); let source = await f.register(); let r = f.repository()
        var descriptors = [ModelPackageDescriptor]()
        for (engine, model, revision) in [("engine/A","model/A","r/1"),("engine/a","model/A","r/1"),("engine/A","model/a","r/1"),("engine/A","model/A","R/1")] {
            let d = try f.descriptor(revision: revision, engine: engine, model: model)
            descriptors.append(d); _ = try await r.importPackage(from: source, descriptor: d)
        }
        let entries = try await r.inventory()
        XCTAssertEqual(entries.count, 4); XCTAssertTrue(entries.allSatisfy { $0.state == .usable })
        XCTAssertEqual(Set(entries.compactMap { $0.manifest?.descriptor.key }), Set(descriptors.map(\.key)))
    }
    func testManifestBoundsOverflowFileDirectoryCollisionAndClaimedSuccessCannotBypassValidation() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        try mutate(d) { json in
            var files = json["files"] as! [[String: Any]]; files.append(files[0]); files[1]["path"] = "other"
            files[0]["byteCount"] = Int64.max; files[1]["byteCount"] = Int64.max; json["files"] = files
        }
        try mutate(d) { json in
            var files = json["files"] as! [[String: Any]]; files.append(files[0]); files[1]["path"] = "Native"; json["files"] = files
        }
        try mutate(d) { $0["licenseTextOrReference"] = String(repeating: "x", count: 65_537) }
        try mutate(d) { $0["files"] = Array(repeating: ($0["files"] as! [[String: Any]])[0], count: 4097) }
        _ = try await r.importPackage(from: source, descriptor: d)
        let manifest = f.installed(d.key).appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["verified"] = true; try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        try Data("STT-TEST xyz".utf8).write(to: f.installed(d.key).appendingPathComponent(d.files[0].path))
        let entry = try await r.validate(d.key); XCTAssertEqual(entry.state, .corrupt)
        try Data(repeating: 32, count: ModelPackageDirectory.metadataLimit + 1).write(to: manifest)
        let oversized = try await r.validate(d.key); XCTAssertEqual(oversized.state, .corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }
}

extension ModelRepositoryTests {
    func testResolverRechecksCompatibilityIntegrityAndCatalogTrust() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        _ = try await r.importPackage(from: source, descriptor: d)
        await expect(.validationUnavailable) {
            _ = try await f.repository(validator: UnavailableModelFormatValidator()).withResolvedPackage(d.key) { _, _ in XCTFail("Unvalidated model resolved"); return true }
        }
        let path = f.installed(d.key).appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        json["origin"] = "bundledCatalog"; try JSONSerialization.data(withJSONObject: json).write(to: path)
        await expect(.invalidDescriptor) {
            _ = try await r.withResolvedPackage(d.key) { _, _ in XCTFail("Forged provenance resolved"); return true }
        }
        let forged = try await r.validate(d.key); XCTAssertEqual(forged.state, .corrupt)
    }
}

extension ModelRepositoryTests {
    func testSourceReplacementDuringScopeAcquisitionIsRejectedAndReleased() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let gate = ModelGate()
        let source = await f.sources.register(f.source, start: { _ = await f.scope.start(); await gate.hold(); return true }, stop: { await f.scope.stop() })
        let task = Task { try await f.repository().importPackage(from: source, descriptor: d) }
        try await gate.withHeld(task) {
            try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("original"))
            try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: false)
            try Data("unrelated".utf8).write(to: f.source.appendingPathComponent("sentinel"))
        }
        await expect(.identityChanged) { _ = try await task.value }
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("sentinel")), Data("unrelated".utf8))
    }
    func testPostPublicationReplacementReportsCommittedInstallWithWarning() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { if $0 == .afterPublish { await gate.hold() } }))
        let task = Task { try await r.importPackage(from: source, descriptor: d) }
        try await gate.withHeld(task) {
            try FileManager.default.moveItem(at: f.store, to: f.root.appendingPathComponent("committed-original-store"))
            try FileManager.default.createDirectory(at: f.store, withIntermediateDirectories: false)
            try Data("unrelated".utf8).write(to: f.store.appendingPathComponent("sentinel"))
        }
        let result = try await task.value
        XCTAssertEqual(result.disposition, .installed); XCTAssertEqual(result.warning, .identityChanged)
        let original = FileModelRepository.namespace(d.key).reduce(f.root.appendingPathComponent("committed-original-store")) { $0.appendingPathComponent($1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: f.store.appendingPathComponent("sentinel")), Data("unrelated".utf8))
    }
}

extension ModelRepositoryTests {
    func testImportRejectsValidatorAndDeclaredLengthHashMismatches() async throws {
        for fault in ["unavailable", "incompatible", "length", "hash"] {
            let f = try ModelFixture(); let original = try f.descriptor(); let source = await f.register()
            let file = original.files[0]
            let payload = try ModelPayloadFile(path: file.path, byteCount: file.byteCount + (fault == "length" ? 1 : 0),
                sha256: fault == "hash" ? String(repeating: "0", count: 64) : file.sha256)
            let descriptor = try ModelPackageDescriptor(engine: original.engine, modelID: original.model.id, revision: original.model.revision,
                format: original.format, variant: original.variant, quantization: original.quantization, compute: original.compute,
                licenseIdentifier: original.licenseIdentifier, licenseTextOrReference: original.licenseTextOrReference,
                licenseProvenance: original.licenseProvenance, files: [payload])
            let validator: any OfflineModelFormatValidating = fault == "unavailable" ? UnavailableModelFormatValidator() : TestFormatValidator(fault == "incompatible" ? .incompatible : nil)
            let r = f.repository(validator: validator)
            let code: ModelRepositoryCode = fault == "unavailable" ? .validationUnavailable : fault == "incompatible" ? .incompatible : .integrityMismatch
            await expect(code) { _ = try await r.importPackage(from: source, descriptor: descriptor) }
            let inventory = try await f.repository().inventory(); XCTAssertTrue(inventory.isEmpty)
            let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(file.path)), Data("STT-TEST abc".utf8))
        }
    }
}

extension ModelRepositoryTests {
    func testDetachedDeletionRechecksContentsAfterSuspension() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { if $0 == .removing { await gate.hold() } }))
        _ = try await r.importPackage(from: source, descriptor: d); let assessment = try await r.prepareDeletion(d.key)
        let task = Task { try await r.delete(assessment, confirmation: .init(assessmentID: assessment.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true)) }
        var sentinel: URL?
        try await gate.withHeld(task) {
            let names = try FileManager.default.contentsOfDirectory(at: f.store, includingPropertiesForKeys: nil)
            let detached = try XCTUnwrap(names.first { $0.lastPathComponent.hasPrefix(".operation-") })
            let file = detached.appendingPathComponent("unrelated-sentinel")
            try Data("unrelated".utf8).write(to: file); sentinel = file
        }
        do { _ = try await task.value; XCTFail() }
        catch let error as ModelOperationFailure {
            XCTAssertEqual(error.cause, .incompleteRemoval); XCTAssertEqual(error.cleanupIssue, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(sentinel)), Data("unrelated".utf8))
    }
}

extension ModelRepositoryTests {
    func testReviewPayloadMutationAfterVerificationMustNotPublishSuccess() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let gate = ModelGate()
        let r = f.repository(hooks: .init(visit: { if $0 == .manifestWrite { await gate.hold() } }))
        let task = Task { try await r.importPackage(from: source, descriptor: d) }
        try await gate.withHeld(task) {
            let paths = try FileManager.default.contentsOfDirectory(at: f.store, includingPropertiesForKeys: nil)
            let stage = try XCTUnwrap(paths.first { $0.lastPathComponent.hasPrefix(".operation-") })
            try Data("STT-TEST xyz".utf8).write(to: stage.appendingPathComponent(d.files[0].path))
        }
        await expect(.identityChanged) { _ = try await task.value }
        let inventory = try await f.repository().inventory(); XCTAssertTrue(inventory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed(d.key).path))
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(d.files[0].path)), Data("STT-TEST abc".utf8))
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [1,1])
    }
    func testReviewIdempotentResultMustRevalidateAfterScopeRelease() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        _ = try await r.importPackage(from: source, descriptor: d)
        let gate = ModelGate()
        let second = await f.sources.register(f.source, start: { await f.scope.start() }, stop: { await gate.hold(); await f.scope.stop() })
        let task = Task { try await r.importPackage(from: second, descriptor: d) }
        try await gate.withHeld(task) {
            try FileManager.default.moveItem(at: f.installed(d.key), to: f.root.appendingPathComponent("preserved-original"))
            try FileManager.default.createDirectory(at: f.installed(d.key), withIntermediateDirectories: false)
            try Data("unrelated".utf8).write(to: f.installed(d.key).appendingPathComponent("sentinel"))
        }
        await expect(.identityChanged) { _ = try await task.value }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("preserved-original").appendingPathComponent(d.files[0].path)), Data("STT-TEST abc".utf8))
        XCTAssertEqual(try Data(contentsOf: f.installed(d.key).appendingPathComponent("sentinel")), Data("unrelated".utf8))
        let counts = await f.scope.counts(); XCTAssertEqual(counts, [2,2])
    }
}

extension ModelRepositoryTests {
    func testReviewFutureManifestSchemaMustBeReportedWithoutV1Fields() async throws {
        let f = try ModelFixture(); let d = try f.descriptor(); let source = await f.register(); let r = f.repository()
        _ = try await r.importPackage(from: source, descriptor: d)
        let manifest = f.installed(d.key).appendingPathComponent("manifest.json")
        let future = Data("{\"schemaVersion\":2,\"payloadV2\":[]}".utf8)
        try future.write(to: manifest)
        // An unknown future layout must not be interpreted using v1 payload rules.
        let futureLink = f.installed(d.key).appendingPathComponent("future-format-link")
        try FileManager.default.createSymbolicLink(at: futureLink, withDestinationURL: f.source.appendingPathComponent(d.files[0].path))
        let inventory = try await r.inventory()
        XCTAssertEqual(inventory.first?.state, .unsupportedSchema)
        let direct = try await r.validate(d.key); XCTAssertEqual(direct.state, .unsupportedSchema)
        XCTAssertEqual(try Data(contentsOf: manifest), future)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: futureLink.path), f.source.appendingPathComponent(d.files[0].path).path)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(d.files[0].path)), Data("STT-TEST abc".utf8))
        // No v1 fields are assumed for any unsupported package/catalog schema.
        for data in [Data("{\"schemaVersion\":2}".utf8), Data("{\"schemaVersion\":2,\"entries\":null}".utf8)] {
            for decode in [
                { _ = try JSONDecoder().decode(ModelPackageDescriptor.self, from: data) },
                { _ = try JSONDecoder().decode(BundledModelCatalog.self, from: data) },
                { _ = try JSONDecoder().decode(ModelInstallationManifest.self, from: data) }
            ] {
                XCTAssertThrowsError(try decode()) { XCTAssertEqual($0 as? ModelRepositoryCode, .unsupportedSchema) }
            }
        }
    }
}
