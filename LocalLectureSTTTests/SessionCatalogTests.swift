import Foundation
import XCTest
@testable import LocalLectureSTT

final class SessionCatalogTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLectureSTT-CatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testFolderNameParserAndDisplayStatusPreserveMetadataStatus() throws {
        let id = SessionID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let created = AbsoluteTime(Date(timeIntervalSince1970: 1_725_000_000))
        let folder = SessionFolderName(sessionID: id, createdAt: created, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(try SessionFolderName(validating: folder.rawValue), folder)
        XCTAssertTrue(folder.matches(id))
        XCTAssertThrowsError(try SessionFolderName(validating: "20260230-120000_abcdef12"))
        XCTAssertThrowsError(try SessionFolderName(validating: "20260101-120000_ABCDEF12"))
        let item = try item(presence: .unreadable)
        XCTAssertEqual(item.metadataStatus, .completed)
        XCTAssertEqual(item.displayStatus, .error)
    }

    func testFileAuthoritativeUpsertOrderingMissingAndRecovery() async throws {
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let first = try projection(id: "11111111-2222-3333-4444-555555555555", created: 100, title: "O'Reilly 100% 한국어", status: .completed)
        let second = try projection(id: "22222222-2222-3333-4444-555555555555", created: 200, title: "Second", status: .recording)
        try await store.apply([result(rootID: first.location.rootID, projections: [first, second])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 300)))
        let initialItems = try await store.orderedItems()
        XCTAssertEqual(initialItems.map(\.title), ["Second", "O'Reilly 100% 한국어"])

        let changed = try projection(id: "11111111-2222-3333-4444-555555555555", created: 100, title: "file always wins", status: .interrupted)
        try await store.apply([result(rootID: changed.location.rootID, projections: [changed, second])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 400)))
        let updatedItems = try await store.orderedItems()
        XCTAssertEqual(updatedItems.first { $0.sessionID == changed.location.sessionID }?.title, "file always wins")

        try await store.apply([result(rootID: changed.location.rootID, projections: [second])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 500)))
        let missing = try await store.orderedItems().first { $0.sessionID == changed.location.sessionID }
        XCTAssertEqual(missing?.presence, .missing)
        XCTAssertEqual(missing?.metadataStatus, .interrupted)
        try await store.apply([result(rootID: changed.location.rootID, projections: [changed, second])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 600)))
        let recoveredItems = try await store.orderedItems()
        XCTAssertEqual(recoveredItems.first { $0.sessionID == changed.location.sessionID }?.displayStatus, .interrupted)
        try await store.close()
    }

    func testDeletionAndCorruptionRebuildPreserveFileProjection() async throws {
        let projection = try projection(id: "33333333-2222-3333-4444-555555555555", created: 100, title: "fixture", status: .completed)
        var store: SQLiteSessionCatalogStore? = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let databaseURL = await store!.databaseURL
        try await store!.apply([result(rootID: projection.location.rootID, projections: [projection])], catalogUpdatedAt: AbsoluteTime(Date()))
        try await store!.close()
        store = nil
        try FileManager.default.removeItem(at: databaseURL)
        let rebuilt = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        try await rebuilt.apply([result(rootID: projection.location.rootID, projections: [projection])], catalogUpdatedAt: AbsoluteTime(Date()))
        let rebuiltItems = try await rebuilt.orderedItems()
        XCTAssertEqual(rebuiltItems.map(\.title), ["fixture"])
        try await rebuilt.close()

        try Data("not sqlite".utf8).write(to: databaseURL)
        let recovered = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let corruptDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("Corrupt", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptDirectory.path))
        try await recovered.close()
    }

    func testConflictingBatchDoesNotCommitAnyRow() async throws {
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let original = try projection(id: "44444444-2222-3333-4444-555555555555", created: 100, title: "original", status: .completed)
        try await store.apply([result(rootID: original.location.rootID, projections: [original])], catalogUpdatedAt: AbsoluteTime(Date()))
        let duplicate = try projection(id: "44444444-2222-3333-4444-555555555555", created: 200, title: "conflict", status: .completed, root: StorageRootID())
        do {
            try await store.apply([result(rootID: duplicate.location.rootID, projections: [duplicate, original])], catalogUpdatedAt: AbsoluteTime(Date()))
            XCTFail("Expected reconciliation conflict")
        } catch let error as CatalogError {
            XCTAssertEqual(error.code, .reconciliationConflict)
        }
        let items = try await store.orderedItems()
        XCTAssertEqual(items.map(\.title), ["original"])
        try await store.close()
    }

    func testExistingLocationConflictPreservesLastKnownRowAsUnreadable() async throws {
        let root = StorageRootID()
        let existing = try projection(id: "abababab-2222-3333-4444-555555555555", created: 100, title: "last known", status: .completed, root: root)
        let conflictingID = SessionID(UUID(uuidString: "cdcdcdcd-2222-3333-4444-555555555555")!)
        let metadata = try SessionMetadataDocument(sessionId: conflictingID, title: "must not overwrite", status: .recording, captureOutcome: .inProgress, createdAt: existing.createdAt, activeDurationMs: existing.activeDuration, languageMode: .automatic, transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: existing.metadataLastUpdatedAt)
        let conflict = CatalogProjection(metadata: metadata, location: SessionLocation(rootID: root, sessionID: conflictingID, folderName: existing.location.folderName))
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        try await store.apply([result(rootID: root, projections: [existing])], catalogUpdatedAt: AbsoluteTime(Date()))
        let reconciler = SessionCatalogReconciler(scanner: StaticScanner(results: [result(rootID: root, projections: [conflict])]), store: store)
        let report = try await reconciler.reconcile()
        XCTAssertTrue(report.issues.contains { $0.code == .locationConflict })
        let items = try await reconciler.orderedItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sessionID, existing.location.sessionID)
        XCTAssertEqual(items[0].title, "last known")
        XCTAssertEqual(items[0].presence, .unreadable)
        XCTAssertEqual(items[0].displayStatus, .error)
        try await store.close()
    }

    func testLiveRootScannerReconcilerRebuildsAndPreservesMissingRows() async throws {
        let root = temporaryDirectory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let codec = CatalogBookmarkCodec()
        let roots = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: codec)
        let rootSummary = try await roots.registerSelectedDirectory(root)
        let first = try projection(id: "aaaaaaaa-2222-3333-4444-555555555555", created: 100, title: "first", status: .completed, root: rootSummary.id)
        try write(first, in: root)
        var store: SQLiteSessionCatalogStore? = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store!)
        _ = try await reconciler.reconcile()
        let initial = try await reconciler.orderedItems()
        XCTAssertEqual(initial.map(\.title), ["first"])
        let database = await store!.databaseURL
        try await store!.close(); store = nil
        try FileManager.default.removeItem(at: database)
        let rebuilt = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let rebuiltReconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: rebuilt)
        _ = try await rebuiltReconciler.reconcile()
        let rebuiltItems = try await rebuiltReconciler.orderedItems()
        XCTAssertEqual(rebuiltItems.map(\.title), ["first"])
        try FileManager.default.removeItem(at: root.appendingPathComponent(first.location.folderName.rawValue))
        _ = try await rebuiltReconciler.reconcile()
        let missingItems = try await rebuiltReconciler.orderedItems()
        XCTAssertEqual(missingItems.first?.presence, .missing)
        try await rebuilt.close()
    }

    func testExistingV1StructureAndFutureBytesAreProtected() async throws {
        let catalog = temporaryDirectory.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sqlite("CREATE TABLE sessions (session_id TEXT PRIMARY KEY, root_id TEXT, folder_name TEXT); PRAGMA user_version=1;", database: catalog)
        let rebuilt = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let didRecover = await rebuilt.recoveredFromCorruption()
        XCTAssertTrue(didRecover)
        try await rebuilt.close()
        let corrupt = catalog.deletingLastPathComponent().appendingPathComponent("Corrupt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: corrupt, includingPropertiesForKeys: nil).count, 1)

        try FileManager.default.removeItem(at: catalog)
        // A valid SQLite future DB is deliberately not moved or overwritten.
        try sqlite("CREATE TABLE future(value TEXT); PRAGMA user_version=9;", database: catalog)
        let bytes = try Data(contentsOf: catalog)
        XCTAssertThrowsError(try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)) { error in
            XCTAssertEqual((error as? CatalogError)?.code, .schemaUnsupported)
        }
        XCTAssertEqual(try Data(contentsOf: catalog), bytes)
    }

    func testCorruptSidecarsAndQuarantineFailureDoNotCreateReplacement() async throws {
        let catalog = temporaryDirectory.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let main = Data("not-a-sqlite-db".utf8)
        let wal = Data("wal-bytes".utf8)
        let shm = Data("shm-bytes".utf8)
        try main.write(to: catalog)
        try wal.write(to: URL(fileURLWithPath: catalog.path + "-wal"))
        try shm.write(to: URL(fileURLWithPath: catalog.path + "-shm"))
        let recovered = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let didRecover = await recovered.recoveredFromCorruption()
        XCTAssertTrue(didRecover)
        try await recovered.close()
        let corrupt = catalog.deletingLastPathComponent().appendingPathComponent("Corrupt")
        let payloads = try FileManager.default.contentsOfDirectory(at: corrupt, includingPropertiesForKeys: nil)
        let preserved = try payloads.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        XCTAssertTrue(preserved.contains { (try? Data(contentsOf: $0)) == main })
        XCTAssertTrue(preserved.contains { (try? Data(contentsOf: $0)) == wal })
        XCTAssertTrue(preserved.contains { (try? Data(contentsOf: $0)) == shm })

        let failingSupport = temporaryDirectory.appendingPathComponent("failing", isDirectory: true)
        let failingCatalog = failingSupport.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: failingCatalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: failingCatalog)
        XCTAssertThrowsError(try SQLiteSessionCatalogStore(applicationSupportDirectory: failingSupport, fileMover: FailingCatalogMover())) { error in
            XCTAssertEqual((error as? CatalogError)?.code, .quarantineFailed)
        }
        XCTAssertEqual(try Data(contentsOf: failingCatalog), Data("broken".utf8))
    }

    func testActualScannerPreservesUnavailablePartialAndUnreadableRows() async throws {
        let active = temporaryDirectory.appendingPathComponent("active", isDirectory: true)
        let historical = temporaryDirectory.appendingPathComponent("historical", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: true)
        let codec = CatalogBookmarkCodec()
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: codec)
        let historicalSummary = try await manager.registerSelectedDirectory(historical)
        let activeSummary = try await manager.registerSelectedDirectory(active)
        let old = try projection(id: "bbbbbbbb-2222-3333-4444-555555555555", created: 10, title: "historical", status: .completed, root: historicalSummary.id)
        let current = try projection(id: "cccccccc-2222-3333-4444-555555555555", created: 20, title: "active", status: .recording, root: activeSummary.id)
        try write(old, in: historical); try write(current, in: active)
        // Invalid/hidden/nested folders and metadata failures must never become valid rows.
        try FileManager.default.createDirectory(at: active.appendingPathComponent("20260230-120000_deadbeef"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active.appendingPathComponent("nested/20260101-000000_deadbeef"), withIntermediateDirectories: true)
        let missing = try projection(id: "dddddddd-2222-3333-4444-555555555555", created: 30, title: "missing", status: .completed, root: activeSummary.id)
        try FileManager.default.createDirectory(at: active.appendingPathComponent(missing.location.folderName.rawValue), withIntermediateDirectories: true)
        let corrupt = try projection(id: "eeeeeeee-2222-3333-4444-555555555555", created: 40, title: "corrupt", status: .completed, root: activeSummary.id)
        let corruptFolder = active.appendingPathComponent(corrupt.location.folderName.rawValue); try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true); try Data("{".utf8).write(to: corruptFolder.appendingPathComponent("metadata.json"))
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store)
        let report = try await reconciler.reconcile()
        let firstItems = try await reconciler.orderedItems()
        XCTAssertEqual(Set(firstItems.map(\.title)), Set(["historical", "active"]))
        XCTAssertTrue(report.issues.contains { $0.code == .metadataMissing })
        XCTAssertTrue(report.issues.contains { $0.code == .metadataCorrupt })
        try FileManager.default.removeItem(at: historical)
        let second = try await reconciler.reconcile()
        XCTAssertTrue(second.rootResults.contains { $0.rootID == historicalSummary.id && $0.outcome == .unavailable })
        let secondItems = try await reconciler.orderedItems()
        XCTAssertEqual(secondItems.first { $0.sessionID == old.location.sessionID }?.presence, .present)
        try await store.close()
    }

    @MainActor
    func testStartupFailureCoalescingAndPendingRefresh() async throws {
        let failing = TestCatalog(failure: .openFailed)
        let failed = CatalogStartupCoordinator(catalog: failing)
        failed.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        if case .failed(.openFailed) = failed.state {} else { XCTFail("expected startup failure") }

        let catalog = TestCatalog(delayNanoseconds: 30_000_000)
        let coordinator = CatalogStartupCoordinator(catalog: catalog)
        coordinator.start(); coordinator.start(); coordinator.refreshAfterRootChange()
        for _ in 0..<100 {
            if await catalog.callCount() == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let calls = await catalog.callCount()
        XCTAssertEqual(calls, 2)
        try await Task.sleep(nanoseconds: 40_000_000)
        if case .ready = coordinator.state {} else { XCTFail("expected ready state") }
        coordinator.start(); coordinator.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        let readyCalls = await catalog.callCount()
        XCTAssertEqual(readyCalls, 2, "ready start must reuse the completed report")
        coordinator.refreshAfterRootChange()
        for _ in 0..<100 {
            if await catalog.callCount() == 3 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let refreshedCalls = await catalog.callCount()
        XCTAssertEqual(refreshedCalls, 3)
    }

    private func projection(id: String, created: TimeInterval, title: String, status: SessionStatus, root: StorageRootID = StorageRootID()) throws -> CatalogProjection {
        let sessionID = SessionID(UUID(uuidString: id)!)
        let createdAt = AbsoluteTime(Date(timeIntervalSince1970: created))
        let outcome: CaptureOutcome
        switch status {
        case .completed: outcome = .completed
        case .recording, .paused: outcome = .inProgress
        case .preparing: outcome = .notStarted
        case .securing, .finalizing, .interrupted, .error, .missing: outcome = .interrupted
        }
        let metadata = try SessionMetadataDocument(sessionId: sessionID, title: title, status: status, captureOutcome: outcome, createdAt: createdAt, activeDurationMs: try MediaMilliseconds(9_223_372), languageMode: .automatic, transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: createdAt)
        return CatalogProjection(metadata: metadata, location: SessionLocation(rootID: root, sessionID: sessionID, folderName: SessionFolderName(sessionID: sessionID, createdAt: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!)))
    }

    private func result(rootID: StorageRootID, projections: [CatalogProjection]) -> RootScanResult {
        RootScanResult(rootID: rootID, outcome: .complete, projections: projections, unreadableFolderNames: [], missingFolderNames: [], issues: [])
    }

    private func item(presence: CatalogPresence) throws -> SessionCatalogItem {
        let projection = try projection(id: "99999999-2222-3333-4444-555555555555", created: 1, title: "test", status: .completed)
        return SessionCatalogItem(sessionID: projection.location.sessionID, rootID: projection.location.rootID, folderName: projection.location.folderName, title: projection.title, createdAt: projection.createdAt, activeDuration: projection.activeDuration, metadataStatus: projection.metadataStatus, captureOutcome: projection.captureOutcome, presence: presence, metadataLastUpdatedAt: projection.metadataLastUpdatedAt, catalogUpdatedAt: projection.metadataLastUpdatedAt)
    }

    private func write(_ projection: CatalogProjection, in root: URL) throws {
        let folder = root.appendingPathComponent(projection.location.folderName.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = try SessionMetadataDocument(sessionId: projection.location.sessionID, title: projection.title, status: projection.metadataStatus, captureOutcome: projection.captureOutcome, createdAt: projection.createdAt, activeDurationMs: projection.activeDuration, languageMode: .automatic, transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: projection.metadataLastUpdatedAt)
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
    }

    private func sqlite(_ sql: String, database: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite fixture creation failed")
    }

}

private struct FailingCatalogMover: CatalogFileMoving {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func createDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func move(_ source: URL, _ destination: URL) throws { throw CocoaError(.fileWriteUnknown) }
}

private actor TestCatalog: SessionCataloging {
    let failure: CatalogErrorCode?
    let delayNanoseconds: UInt64
    private var calls = 0
    init(failure: CatalogErrorCode? = nil, delayNanoseconds: UInt64 = 0) { self.failure = failure; self.delayNanoseconds = delayNanoseconds }
    func reconcile() async throws -> CatalogReconciliationReport {
        calls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let failure { throw CatalogError(failure) }
        return CatalogReconciliationReport(rootResults: [], issues: [], recoveredFromCorruption: false)
    }
    func orderedItems() async throws -> [SessionCatalogItem] { [] }
    func callCount() -> Int { calls }
}

private actor StaticScanner: SessionFileScanning {
    let results: [RootScanResult]
    init(results: [RootScanResult]) { self.results = results }
    func scan() async throws -> [RootScanResult] { results }
}

private actor CatalogBookmarkCodec: SecurityScopedBookmarkCodec {
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: false) }
    func startAccessing(_ url: URL) async -> Bool { true }
    func stopAccessing(_ url: URL) async {}
}
