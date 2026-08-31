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

    func testCatalogValueParserProjectionAndConformances() throws {
        let id = SessionID(UUID(uuidString: "01234567-2222-3333-4444-555555555555")!)
        let created = AbsoluteTime(Date(timeIntervalSince1970: 1_725_000_123.456))
        let folder = SessionFolderName(sessionID: id, createdAt: created, timeZone: .gmt)
        XCTAssertEqual(try SessionFolderName(validating: folder.rawValue), folder)
        for invalid in ["20260101-120000_abcdef1", "20260101/120000_abcdef12", "20260230-120000_abcdef12", "20260101-120000_ABCDEF12", "20260101-120000_abcdef1/"] {
            XCTAssertThrowsError(try SessionFolderName(validating: invalid), "Expected invalid folder name: \(invalid)")
        }
        let projection = try projection(id: id.rawValue.uuidString, created: created.value.timeIntervalSince1970, title: "강의 '100%' — Unicode", status: .interrupted)
        XCTAssertEqual(projection.title, "강의 '100%' — Unicode")
        XCTAssertEqual(projection.createdAt, created)
        XCTAssertEqual(projection.activeDuration.rawValue, 9_223_372)
        XCTAssertEqual(projection.metadataStatus, .interrupted)
        XCTAssertEqual(projection.captureOutcome, .interrupted)
        let present = try item(presence: .present)
        let missing = try item(presence: .missing)
        let unreadable = try item(presence: .unreadable)
        XCTAssertEqual(present.displayStatus, .completed)
        XCTAssertEqual(missing.displayStatus, .missing)
        XCTAssertEqual(unreadable.displayStatus, .error)
        XCTAssertEqual(unreadable.metadataStatus, .completed)
        XCTAssertEqual(try JSONDecoder().decode(SessionCatalogItem.self, from: JSONEncoder().encode(unreadable)), unreadable)
        XCTAssertEqual(try JSONDecoder().decode(CatalogReconciliationReport.self, from: JSONEncoder().encode(CatalogReconciliationReport(rootResults: [], issues: [], recoveredFromCorruption: true))), CatalogReconciliationReport(rootResults: [], issues: [], recoveredFromCorruption: true))
        acceptSendable(unreadable); acceptSendable(projection); acceptSendable(CatalogReconciliationReport(rootResults: [], issues: [], recoveredFromCorruption: false))
    }

    func testSQLiteSchemaPathAndRoundTrips() async throws {
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let databaseURL = await store.databaseURL
        XCTAssertEqual(databaseURL.path, temporaryDirectory.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(try sqliteOutput("PRAGMA user_version; SELECT name FROM sqlite_master WHERE type='index' AND name='sessions_order';", database: databaseURL).split(separator: "\n"), ["1", "sessions_order"])
        let schema = try sqliteOutput("SELECT sql FROM sqlite_master WHERE type='table' AND name='sessions';", database: databaseURL)
        for column in ["session_id TEXT PRIMARY KEY NOT NULL", "root_id TEXT NOT NULL", "folder_name TEXT NOT NULL", "created_at_ms INTEGER NOT NULL", "active_duration_ms INTEGER NOT NULL", "metadata_status TEXT NOT NULL", "capture_outcome TEXT NOT NULL", "presence TEXT NOT NULL", "metadata_updated_at_ms INTEGER NOT NULL", "catalog_updated_at_ms INTEGER NOT NULL", "UNIQUE(root_id, folder_name)"] { XCTAssertTrue(schema.contains(column), "Missing expected schema component: \(column)") }
        let root = StorageRootID()
        let olderA = try projection(id: "10000000-2222-3333-4444-555555555555", created: 100, title: "O'Reilly 100% 한국어", status: .completed, root: root)
        let olderB = try projection(id: "00000000-2222-3333-4444-555555555555", created: 100, title: "tie", status: .recording, root: StorageRootID())
        let newer = try projection(id: "20000000-2222-3333-4444-555555555555", created: 200, title: "newer", status: .interrupted, root: StorageRootID())
        try await store.apply([result(rootID: root, projections: [olderA]), result(rootID: olderB.location.rootID, projections: [olderB]), result(rootID: newer.location.rootID, projections: [newer])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 300)))
        var items = try await store.orderedItems()
        XCTAssertEqual(items.map(\.sessionID), [newer.location.sessionID, olderB.location.sessionID, olderA.location.sessionID])
        XCTAssertEqual(items.last?.title, "O'Reilly 100% 한국어")
        XCTAssertEqual(items.last?.activeDuration, olderA.activeDuration)
        XCTAssertEqual(items.last?.metadataStatus, .completed)
        XCTAssertEqual(items.last?.captureOutcome, .completed)
        let updated = try projection(id: "10000000-2222-3333-4444-555555555555", created: 100, title: "file projection wins", status: .paused, root: root)
        try await store.apply([result(rootID: root, projections: [updated])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 400)))
        items = try await store.orderedItems()
        XCTAssertEqual(items.filter { $0.sessionID == updated.location.sessionID }.count, 1)
        XCTAssertEqual(items.first { $0.sessionID == updated.location.sessionID }?.title, "file projection wins")
        XCTAssertEqual(items.first { $0.sessionID == updated.location.sessionID }?.metadataStatus, .paused)
        try await store.close()
    }

    func testPresenceTransitionsPreserveLastKnownMetadataAndRecover() async throws {
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let value = try projection(id: "30000000-2222-3333-4444-555555555555", created: 1, title: "known", status: .interrupted)
        try await store.apply([result(rootID: value.location.rootID, projections: [value])], catalogUpdatedAt: value.createdAt)
        let unreadable = RootScanResult(rootID: value.location.rootID, outcome: .complete, projections: [], unreadableFolderNames: [value.location.folderName.rawValue], missingFolderNames: [], issues: [])
        try await store.apply([unreadable], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 2)))
        var storedItems = try await store.orderedItems()
        var item = try XCTUnwrap(storedItems.first)
        XCTAssertEqual(item.presence, .unreadable); XCTAssertEqual(item.metadataStatus, .interrupted); XCTAssertEqual(item.displayStatus, .error)
        let missing = RootScanResult(rootID: value.location.rootID, outcome: .complete, projections: [], unreadableFolderNames: [], missingFolderNames: [value.location.folderName.rawValue], issues: [])
        try await store.apply([missing], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 3)))
        storedItems = try await store.orderedItems()
        item = try XCTUnwrap(storedItems.first)
        XCTAssertEqual(item.presence, .missing); XCTAssertEqual(item.metadataStatus, .interrupted)
        try await store.apply([result(rootID: value.location.rootID, projections: [value])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 4)))
        storedItems = try await store.orderedItems()
        item = try XCTUnwrap(storedItems.first)
        XCTAssertEqual(item.presence, .present); XCTAssertEqual(item.displayStatus, .interrupted)
        try await store.close()
    }

    func testInvalidDatabaseRowsThrowTypedError() async throws {
        let value = try projection(id: "40000000-2222-3333-4444-555555555555", created: 1, title: "known", status: .completed)
        for sql in ["UPDATE sessions SET metadata_status='bogus'", "UPDATE sessions SET created_at_ms='not-a-time'", "UPDATE sessions SET folder_name='not-a-folder'"] {
            let support = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var store: SQLiteSessionCatalogStore? = try SQLiteSessionCatalogStore(applicationSupportDirectory: support)
            try await store!.apply([result(rootID: value.location.rootID, projections: [value])], catalogUpdatedAt: value.createdAt)
            let database = await store!.databaseURL
            try await store!.close(); store = nil
            try sqlite(sql, database: database)
            let reopened = try SQLiteSessionCatalogStore(applicationSupportDirectory: support)
            do {
                _ = try await reopened.orderedItems()
                XCTFail("Expected invalid stored value")
            } catch let error as CatalogError { XCTAssertEqual(error.code, .invalidStoredValue) }
            try await reopened.close()
        }
    }

    func testReconciliationTransactionRollsBackOnInjectedSQLiteFailure() async throws {
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let database = await store.databaseURL
        let root = StorageRootID()
        let first = try projection(id: "50000000-2222-3333-4444-555555555555", created: 1, title: "must rollback", status: .completed, root: root)
        let failing = try projection(id: "60000000-2222-3333-4444-555555555555", created: 2, title: "fault", status: .completed, root: root)
        try await store.close()
        try sqlite("CREATE TRIGGER reject_fault BEFORE INSERT ON sessions WHEN NEW.session_id='60000000-2222-3333-4444-555555555555' BEGIN SELECT RAISE(ABORT, 'fault'); END;", database: database)
        let reopened = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        do {
            try await reopened.apply([result(rootID: root, projections: [first, failing])], catalogUpdatedAt: AbsoluteTime(Date(timeIntervalSince1970: 3)))
            XCTFail("Expected the injected SQLite failure")
        } catch {}
        let rolledBackItems = try await reopened.orderedItems()
        XCTAssertTrue(rolledBackItems.isEmpty, "The first insert must be rolled back with the injected second-row failure")
        try await reopened.close()
    }

    func testClosedCatalogDatabaseCanBeManipulated() async throws {
        var store: SQLiteSessionCatalogStore? = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let database = await store!.databaseURL
        try await store!.close(); store = nil
        XCTAssertNoThrow(try FileManager.default.removeItem(at: database))
        XCTAssertNoThrow(try Data("replacement".utf8).write(to: database))
    }

    func testActualScannerFiltersDirectChildrenAndPreservesRootBytes() async throws {
        let root = temporaryDirectory.appendingPathComponent("scan-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let summary = try await manager.registerSelectedDirectory(root)
        let valid = try projection(id: "70000000-2222-3333-4444-555555555555", created: 7, title: "valid", status: .completed, root: summary.id)
        try write(valid, in: root)
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".ignored"))
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20260230-120000_deadbeef"), withIntermediateDirectories: true)
        try write(try projection(id: "71000000-2222-3333-4444-555555555555", created: 8, title: "nested", status: .completed, root: summary.id), in: root.appendingPathComponent("container", isDirectory: true))
        let before = try treeSnapshot(root)
        let scanned = try await SessionFileScanner(roots: manager).scan()
        let after = try treeSnapshot(root)
        let result = try XCTUnwrap(scanned.first)
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.projections.map(\.location.sessionID), [valid.location.sessionID])
        XCTAssertTrue(result.issues.contains { $0.code == .invalidFolderName && $0.folderName == "20260230-120000_deadbeef" })
        XCTAssertEqual(after, before, "Scanning must not alter the user root's tree or existing bytes")
    }

    func testActualScannerRejectsSessionAndMetadataSymlinks() async throws {
        let root = temporaryDirectory.appendingPathComponent("symlink-root", isDirectory: true)
        let external = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let summary = try await manager.registerSelectedDirectory(root)
        let directoryLink = try projection(id: "72000000-2222-3333-4444-555555555555", created: 7, title: "linked directory", status: .completed, root: summary.id)
        try write(directoryLink, in: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(directoryLink.location.folderName.rawValue), withDestinationURL: external.appendingPathComponent(directoryLink.location.folderName.rawValue))
        let metadataLink = try projection(id: "73000000-2222-3333-4444-555555555555", created: 8, title: "linked metadata", status: .completed, root: summary.id)
        let metadataFolder = root.appendingPathComponent(metadataLink.location.folderName.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        let externalMetadata = external.appendingPathComponent("metadata-source.json")
        try JSONEncoder().encode(metadataDocument(for: metadataLink)).write(to: externalMetadata)
        try FileManager.default.createSymbolicLink(at: metadataFolder.appendingPathComponent("metadata.json"), withDestinationURL: externalMetadata)
        let scanResults = try await SessionFileScanner(roots: manager).scan()
        let result = try XCTUnwrap(scanResults.first)
        XCTAssertTrue(result.projections.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.code == .sessionDirectorySymlink && $0.folderName == directoryLink.location.folderName.rawValue })
        XCTAssertTrue(result.issues.contains { $0.code == .metadataInvalid && $0.folderName == metadataLink.location.folderName.rawValue })
    }

    func testActualScannerRejectsMismatchedMetadataIDAndDistinctMetadataFailures() async throws {
        let root = temporaryDirectory.appendingPathComponent("metadata-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let summary = try await manager.registerSelectedDirectory(root)
        let missing = try projection(id: "74000000-2222-3333-4444-555555555555", created: 1, title: "missing", status: .completed, root: summary.id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(missing.location.folderName.rawValue), withIntermediateDirectories: true)
        let corrupt = try projection(id: "75000000-2222-3333-4444-555555555555", created: 2, title: "corrupt", status: .completed, root: summary.id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(corrupt.location.folderName.rawValue), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appendingPathComponent(corrupt.location.folderName.rawValue).appendingPathComponent("metadata.json"))
        let unsupported = try projection(id: "76000000-2222-3333-4444-555555555555", created: 3, title: "unsupported", status: .completed, root: summary.id)
        try write(unsupported, in: root)
        let unsupportedURL = root.appendingPathComponent(unsupported.location.folderName.rawValue).appendingPathComponent("metadata.json")
        let unsupportedText = String(decoding: try Data(contentsOf: unsupportedURL), as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        try Data(unsupportedText.utf8).write(to: unsupportedURL)
        let mismatchFolder = try projection(id: "77000000-2222-3333-4444-555555555555", created: 4, title: "mismatch", status: .completed, root: summary.id)
        let mismatchedMetadata = try projection(id: "78000000-2222-3333-4444-555555555555", created: 4, title: "different id", status: .completed, root: summary.id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(mismatchFolder.location.folderName.rawValue), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadataDocument(for: mismatchedMetadata)).write(to: root.appendingPathComponent(mismatchFolder.location.folderName.rawValue).appendingPathComponent("metadata.json"))
        let scanResults = try await SessionFileScanner(roots: manager).scan()
        let result = try XCTUnwrap(scanResults.first)
        XCTAssertTrue(result.projections.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.code == .metadataMissing && $0.folderName == missing.location.folderName.rawValue })
        XCTAssertTrue(result.issues.contains { $0.code == .metadataCorrupt && $0.folderName == corrupt.location.folderName.rawValue })
        XCTAssertTrue(result.issues.contains { $0.code == .metadataUnsupported && $0.folderName == unsupported.location.folderName.rawValue })
        XCTAssertTrue(result.issues.contains { $0.code == .sessionIDMismatch && $0.folderName == mismatchFolder.location.folderName.rawValue })
    }

    func testReadOnlyRootScansButRepositoryWriteIsDenied() async throws {
        let root = temporaryDirectory.appendingPathComponent("readonly-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let summary = try await manager.registerSelectedDirectory(root)
        let projection = try projection(id: "79000000-2222-3333-4444-555555555555", created: 1, title: "readable", status: .completed, root: summary.id)
        try write(projection, in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let scanResults = try await SessionFileScanner(roots: manager).scan()
        let result = try XCTUnwrap(scanResults.first)
        XCTAssertEqual(result.projections.map(\.location.sessionID), [projection.location.sessionID])
        let repository = FileSessionRepository(roots: manager)
        do {
            _ = try await repository.createSession(sessionID: SessionID(), createdAt: AbsoluteTime(Date()), timeZone: .gmt)
            XCTFail("Expected a write to the read-only root to be denied")
        } catch let error as StorageError { XCTAssertEqual(error.code, .rootNotWritable) }
    }

    func testScannerDoesNotEnterDeniedScopeAndBalancesSuccessfulScope() async throws {
        let root = temporaryDirectory.appendingPathComponent("scope-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deniedCodec = CountingCatalogBookmarkCodec(allowAccess: false)
        let deniedManager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: deniedCodec)
        let deniedSummary = try await deniedManager.registerSelectedDirectory(root)
        let deniedScanResults = try await SessionFileScanner(roots: deniedManager).scan()
        let denied = try XCTUnwrap(deniedScanResults.first)
        XCTAssertEqual(denied.rootID, deniedSummary.id)
        XCTAssertEqual(denied.outcome, .unavailable)
        XCTAssertTrue(denied.projections.isEmpty, "Denied scope must not run the scan closure")
        let deniedStarts = await deniedCodec.startCount(); let deniedStops = await deniedCodec.stopCount()
        XCTAssertEqual(deniedStarts, 1); XCTAssertEqual(deniedStops, 0)
        let allowedCodec = CountingCatalogBookmarkCodec(allowAccess: true)
        let allowedManager = StorageRootManager(applicationSupportDirectory: temporaryDirectory.appendingPathComponent("allowed-support"), bookmarkCodec: allowedCodec)
        _ = try await allowedManager.registerSelectedDirectory(root)
        let allowedScanResults = try await SessionFileScanner(roots: allowedManager).scan()
        XCTAssertEqual(try XCTUnwrap(allowedScanResults.first).outcome, .complete)
        let allowedStarts = await allowedCodec.startCount(); let allowedStops = await allowedCodec.stopCount()
        XCTAssertEqual(allowedStarts, 1); XCTAssertEqual(allowedStops, 1)
    }

    func testActualMultiRootReconciliationIsFileAuthoritative() async throws {
        let active = temporaryDirectory.appendingPathComponent("multi-active", isDirectory: true)
        let historical = temporaryDirectory.appendingPathComponent("multi-historical", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historical, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let historicalRoot = try await manager.registerSelectedDirectory(historical)
        let activeRoot = try await manager.registerSelectedDirectory(active)
        let historic = try projection(id: "80000000-2222-3333-4444-555555555555", created: 10, title: "history", status: .completed, root: historicalRoot.id)
        let current = try projection(id: "81000000-2222-3333-4444-555555555555", created: 20, title: "original", status: .recording, root: activeRoot.id)
        try write(historic, in: historical); try write(current, in: active)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store)
        _ = try await reconciler.reconcile()
        let initialItems = try await reconciler.orderedItems()
        XCTAssertEqual(Set(initialItems.map(\.sessionID)), Set([historic.location.sessionID, current.location.sessionID]))
        let changed = try projection(id: "81000000-2222-3333-4444-555555555555", created: 20, title: "file wins", status: .interrupted, root: activeRoot.id)
        try FileManager.default.removeItem(at: active.appendingPathComponent(current.location.folderName.rawValue))
        try write(changed, in: active)
        let database = await store.databaseURL
        try sqlite("UPDATE sessions SET title='database lie', metadata_status='completed', active_duration_ms=1 WHERE session_id='81000000-2222-3333-4444-555555555555'", database: database)
        _ = try await reconciler.reconcile()
        let reconciledItems = try await reconciler.orderedItems()
        let item = try XCTUnwrap(reconciledItems.first { $0.sessionID == changed.location.sessionID })
        XCTAssertEqual(item.title, "file wins"); XCTAssertEqual(item.metadataStatus, .interrupted); XCTAssertEqual(item.activeDuration, changed.activeDuration)
        try await store.close()
    }

    func testActualCompleteScanPreservesDBOnlyAndOrphanMetadataRowsAsMissing() async throws {
        let root = temporaryDirectory.appendingPathComponent("missing-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let rootSummary = try await manager.registerSelectedDirectory(root)
        let dbOnly = try projection(id: "82000000-2222-3333-4444-555555555555", created: 1, title: "db-only", status: .completed, root: rootSummary.id)
        let orphan = try projection(id: "83000000-2222-3333-4444-555555555555", created: 2, title: "orphan", status: .interrupted, root: rootSummary.id)
        try write(orphan, in: root)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        try await store.apply([result(rootID: rootSummary.id, projections: [dbOnly, orphan])], catalogUpdatedAt: AbsoluteTime(Date()))
        try FileManager.default.removeItem(at: root.appendingPathComponent(orphan.location.folderName.rawValue).appendingPathComponent("metadata.json"))
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store)
        let report = try await reconciler.reconcile()
        let items = try await reconciler.orderedItems()
        XCTAssertEqual(items.first { $0.sessionID == dbOnly.location.sessionID }?.presence, .missing)
        XCTAssertEqual(items.first { $0.sessionID == orphan.location.sessionID }?.presence, .missing)
        XCTAssertTrue(report.issues.contains { $0.code == .metadataMissing && $0.folderName == orphan.location.folderName.rawValue })
        try await store.close()
    }

    func testActualUnreadableMetadataPreservesRowAndRecoversWhenRestored() async throws {
        let root = temporaryDirectory.appendingPathComponent("recovery-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let summary = try await manager.registerSelectedDirectory(root)
        let projection = try projection(id: "84000000-2222-3333-4444-555555555555", created: 1, title: "known", status: .completed, root: summary.id)
        try write(projection, in: root)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store)
        _ = try await reconciler.reconcile()
        let metadata = root.appendingPathComponent(projection.location.folderName.rawValue).appendingPathComponent("metadata.json")
        try Data("{".utf8).write(to: metadata)
        let unreadable = try await reconciler.reconcile()
        var reconciledItems = try await reconciler.orderedItems()
        var item = try XCTUnwrap(reconciledItems.first)
        XCTAssertTrue(unreadable.issues.contains { $0.code == .metadataCorrupt })
        XCTAssertEqual(item.presence, .unreadable); XCTAssertEqual(item.title, "known"); XCTAssertEqual(item.metadataStatus, .completed)
        try JSONEncoder().encode(metadataDocument(for: projection)).write(to: metadata)
        _ = try await reconciler.reconcile()
        reconciledItems = try await reconciler.orderedItems()
        item = try XCTUnwrap(reconciledItems.first)
        XCTAssertEqual(item.presence, .present); XCTAssertEqual(item.displayStatus, .completed)
        try await store.close()
    }

    func testActualUnavailableAndPartialRootsDoNotSweepExistingRows() async throws {
        let available = temporaryDirectory.appendingPathComponent("available-root", isDirectory: true)
        let unavailable = temporaryDirectory.appendingPathComponent("unavailable-root", isDirectory: true)
        let partial = temporaryDirectory.appendingPathComponent("partial-root", isDirectory: true)
        try [available, unavailable, partial].forEach { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let unavailableSummary = try await manager.registerSelectedDirectory(unavailable)
        let partialSummary = try await manager.registerSelectedDirectory(partial)
        _ = try await manager.registerSelectedDirectory(available)
        let unavailableProjection = try projection(id: "85000000-2222-3333-4444-555555555555", created: 1, title: "unavailable", status: .completed, root: unavailableSummary.id)
        let partialProjection = try projection(id: "86000000-2222-3333-4444-555555555555", created: 2, title: "partial", status: .completed, root: partialSummary.id)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        try await store.apply([result(rootID: unavailableSummary.id, projections: [unavailableProjection]), result(rootID: partialSummary.id, projections: [partialProjection])], catalogUpdatedAt: AbsoluteTime(Date()))
        try FileManager.default.removeItem(at: unavailable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: partial.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path) }
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store)
        let report = try await reconciler.reconcile()
        let items = try await reconciler.orderedItems()
        XCTAssertEqual(items.first { $0.sessionID == unavailableProjection.location.sessionID }?.presence, .present)
        XCTAssertEqual(items.first { $0.sessionID == partialProjection.location.sessionID }?.presence, .present)
        XCTAssertTrue(report.rootResults.contains { $0.rootID == unavailableSummary.id && $0.outcome == .unavailable })
        XCTAssertTrue(report.rootResults.contains { $0.rootID == partialSummary.id && $0.outcome == .partial })
        try await store.close()
    }

    func testActualPartialAndSuccessfulMultiRootReconcilesSuccessfulRoot() async throws {
        let success = temporaryDirectory.appendingPathComponent("successful-root", isDirectory: true)
        let partial = temporaryDirectory.appendingPathComponent("partial-peer", isDirectory: true)
        try FileManager.default.createDirectory(at: success, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let partialRoot = try await manager.registerSelectedDirectory(partial)
        let successRoot = try await manager.registerSelectedDirectory(success)
        let old = try projection(id: "87000000-2222-3333-4444-555555555555", created: 1, title: "old", status: .completed, root: successRoot.id)
        try write(old, in: success)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store)
        _ = try await reconciler.reconcile()
        let fresh = try projection(id: "87000000-2222-3333-4444-555555555555", created: 1, title: "successful update", status: .interrupted, root: successRoot.id)
        try FileManager.default.removeItem(at: success.appendingPathComponent(old.location.folderName.rawValue)); try write(fresh, in: success)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: partial.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path) }
        let report = try await reconciler.reconcile()
        XCTAssertTrue(report.rootResults.contains { $0.rootID == partialRoot.id && $0.outcome == .partial })
        let reconciledItems = try await reconciler.orderedItems()
        XCTAssertEqual(reconciledItems.first { $0.sessionID == fresh.location.sessionID }?.title, "successful update")
        try await store.close()
    }

    func testDuplicateIDsAndExistingLocationConflictKeepLastKnownRows() async throws {
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let rootA = StorageRootID(); let rootB = StorageRootID(); let rootC = StorageRootID()
        let original = try projection(id: "88000000-2222-3333-4444-555555555555", created: 1, title: "last known", status: .completed, root: rootA)
        try await store.apply([result(rootID: rootA, projections: [original])], catalogUpdatedAt: AbsoluteTime(Date()))
        let duplicate = try projection(id: "88000000-2222-3333-4444-555555555555", created: 2, title: "duplicate", status: .recording, root: rootB)
        let conflictingID = SessionID(UUID(uuidString: "89000000-2222-3333-4444-555555555555")!)
        let conflict = CatalogProjection(metadata: try SessionMetadataDocument(sessionId: conflictingID, title: "must not overwrite", status: .recording, captureOutcome: .inProgress, createdAt: original.createdAt, activeDurationMs: original.activeDuration, languageMode: .automatic, transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: original.metadataLastUpdatedAt), location: SessionLocation(rootID: rootA, sessionID: conflictingID, folderName: original.location.folderName))
        let duplicateAgain = try projection(id: "88000000-2222-3333-4444-555555555555", created: 3, title: "duplicate again", status: .recording, root: rootC)
        let reconciler = SessionCatalogReconciler(scanner: StaticScanner(results: [result(rootID: rootA, projections: [conflict]), result(rootID: rootB, projections: [duplicate]), result(rootID: rootC, projections: [duplicateAgain])]), store: store)
        let report = try await reconciler.reconcile()
        XCTAssertTrue(report.issues.contains { $0.code == .locationConflict })
        XCTAssertTrue(report.issues.contains { $0.code == .duplicateSessionID })
        let items = try await reconciler.orderedItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sessionID, original.location.sessionID); XCTAssertEqual(items[0].title, "last known"); XCTAssertEqual(items[0].presence, .unreadable)
        try await store.close()
    }

    func testNoRootReconciliationReturnsEmptySuccess() async throws {
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let report = try await SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store).reconcile()
        let items = try await store.orderedItems()
        XCTAssertTrue(report.rootResults.isEmpty); XCTAssertTrue(report.issues.isEmpty); XCTAssertTrue(items.isEmpty)
        try await store.close()
    }

    func testActualScannerRebuildsAfterDatabaseBundleRemoval() async throws {
        let root = temporaryDirectory.appendingPathComponent("rebuild-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let rootSummary = try await manager.registerSelectedDirectory(root)
        let older = try projection(id: "90000000-2222-3333-4444-555555555555", created: 1, title: "older", status: .completed, root: rootSummary.id)
        let newer = try projection(id: "91000000-2222-3333-4444-555555555555", created: 2, title: "newer", status: .recording, root: rootSummary.id)
        try write(older, in: root); try write(newer, in: root)
        var store: SQLiteSessionCatalogStore? = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let database = await store!.databaseURL
        let reconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store!)
        _ = try await reconciler.reconcile(); try await store!.close(); store = nil
        for component in [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm"), URL(fileURLWithPath: database.path + "-journal")] where FileManager.default.fileExists(atPath: component.path) { try FileManager.default.removeItem(at: component) }
        let rebuilt = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let rebuiltReconciler = SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: rebuilt)
        _ = try await rebuiltReconciler.reconcile()
        let rebuiltItems = try await rebuiltReconciler.orderedItems()
        XCTAssertEqual(rebuiltItems.map(\.title), ["newer", "older"])
        try await rebuilt.close()
    }

    func testActualScannerRebuildsAfterCorruptDatabaseWithSidecars() async throws {
        let root = temporaryDirectory.appendingPathComponent("corrupt-rebuild-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let rootSummary = try await manager.registerSelectedDirectory(root)
        let projection = try projection(id: "92000000-2222-3333-4444-555555555555", created: 1, title: "recovered from files", status: .completed, root: rootSummary.id)
        try write(projection, in: root)
        let catalogURL = temporaryDirectory.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let main = Data("not-a-database".utf8); let wal = Data("wal-bytes".utf8); let shm = Data("shm-bytes".utf8)
        try main.write(to: catalogURL); try wal.write(to: URL(fileURLWithPath: catalogURL.path + "-wal")); try shm.write(to: URL(fileURLWithPath: catalogURL.path + "-shm"))
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let didRecover = await store.recoveredFromCorruption()
        XCTAssertTrue(didRecover)
        let report = try await SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store).reconcile()
        XCTAssertTrue(report.recoveredFromCorruption)
        let rebuiltItems = try await store.orderedItems()
        XCTAssertEqual(rebuiltItems.map(\.title), ["recovered from files"])
        let corrupt = catalogURL.deletingLastPathComponent().appendingPathComponent("Corrupt")
        let files = try FileManager.default.contentsOfDirectory(at: corrupt, includingPropertiesForKeys: nil).flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        XCTAssertTrue(files.contains { (try? Data(contentsOf: $0)) == main }); XCTAssertTrue(files.contains { (try? Data(contentsOf: $0)) == wal }); XCTAssertTrue(files.contains { (try? Data(contentsOf: $0)) == shm })
        try await store.close()
    }

    func testQuarantineFailurePreservesAllOriginalComponents() throws {
        let support = temporaryDirectory.appendingPathComponent("quarantine-fault", isDirectory: true)
        let database = support.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let components = [(database, Data("bad-main".utf8)), (URL(fileURLWithPath: database.path + "-wal"), Data("bad-wal".utf8)), (URL(fileURLWithPath: database.path + "-shm"), Data("bad-shm".utf8))]
        for (url, bytes) in components { try bytes.write(to: url) }
        XCTAssertThrowsError(try SQLiteSessionCatalogStore(applicationSupportDirectory: support, fileMover: FailingCatalogMover())) { error in XCTAssertEqual((error as? CatalogError)?.code, .quarantineFailed) }
        for (url, bytes) in components { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    func testOrphanSidecarIsQuarantinedAndActualScannerRebuilds() async throws {
        let root = temporaryDirectory.appendingPathComponent("orphan-sidecar-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let summary = try await manager.registerSelectedDirectory(root)
        let projection = try projection(id: "94000000-2222-3333-4444-555555555555", created: 1, title: "sidecar rebuild", status: .completed, root: summary.id)
        try write(projection, in: root)
        let database = temporaryDirectory.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let orphan = Data("orphan-wal".utf8)
        let orphanURL = URL(fileURLWithPath: database.path + "-wal")
        try orphan.write(to: orphanURL)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let didRecover = await store.recoveredFromCorruption()
        XCTAssertTrue(didRecover)
        _ = try await SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store).reconcile()
        let items = try await store.orderedItems()
        XCTAssertEqual(items.map(\.title), ["sidecar rebuild"])
        let corrupt = database.deletingLastPathComponent().appendingPathComponent("Corrupt")
        let quarantined = try FileManager.default.contentsOfDirectory(at: corrupt, includingPropertiesForKeys: nil).flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        XCTAssertTrue(quarantined.contains { (try? Data(contentsOf: $0)) == orphan })
        try await store.close()
    }

    func testFutureSchemaBytesAreUntouched() throws {
        let support = temporaryDirectory.appendingPathComponent("future-schema", isDirectory: true)
        let database = support.appendingPathComponent("LocalLectureSTT/Catalog/session-catalog.sqlite3")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sqlite("CREATE TABLE future(value TEXT); PRAGMA user_version=9;", database: database)
        let before = try Data(contentsOf: database)
        XCTAssertThrowsError(try SQLiteSessionCatalogStore(applicationSupportDirectory: support)) { error in XCTAssertEqual((error as? CatalogError)?.code, .schemaUnsupported) }
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.deletingLastPathComponent().appendingPathComponent("Corrupt").path))
    }

    func testRebuildWithUnavailableRootLeavesUserRootUntouched() async throws {
        let root = temporaryDirectory.appendingPathComponent("untouched-root", isDirectory: true)
        let unavailable = temporaryDirectory.appendingPathComponent("unavailable-on-rebuild", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unavailable, withIntermediateDirectories: true)
        let manager = StorageRootManager(applicationSupportDirectory: temporaryDirectory, bookmarkCodec: CatalogBookmarkCodec())
        let unavailableSummary = try await manager.registerSelectedDirectory(unavailable)
        let summary = try await manager.registerSelectedDirectory(root)
        let projection = try projection(id: "93000000-2222-3333-4444-555555555555", created: 1, title: "unchanged", status: .completed, root: summary.id)
        try write(projection, in: root)
        let before = try treeSnapshot(root)
        try FileManager.default.removeItem(at: unavailable)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: temporaryDirectory)
        let report = try await SessionCatalogReconciler(scanner: SessionFileScanner(roots: manager), store: store).reconcile()
        XCTAssertTrue(report.rootResults.contains { $0.rootID == unavailableSummary.id && $0.outcome == .unavailable })
        XCTAssertEqual(try treeSnapshot(root), before, "A failed peer root must not change the accessible user's root during rebuild")
        let rebuiltItems = try await store.orderedItems()
        XCTAssertEqual(rebuiltItems.map(\.sessionID), [projection.location.sessionID])
        try await store.close()
    }

    @MainActor
    func testStartupIsIdempotentAndQueuesOnePendingRefresh() async throws {
        let catalog = TestCatalog(delayNanoseconds: 20_000_000)
        let coordinator = CatalogStartupCoordinator(catalog: catalog)
        coordinator.start(); coordinator.start(); coordinator.start()
        try await waitUntil { await catalog.callCount() == 1 }
        coordinator.refreshAfterRootChange(); coordinator.refreshAfterRootChange(); coordinator.refreshAfterRootChange()
        try await waitUntil { await catalog.callCount() == 2 }
        try await waitUntil { if case .ready = coordinator.state { return true }; return false }
        coordinator.start(); coordinator.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        let callCount = await catalog.callCount()
        XCTAssertEqual(callCount, 2, "A completed startup report must be reused")
    }

    @MainActor
    func testRootSelectionAndReauthorizationRequestRefreshOnlyOnSuccess() async throws {
        let chooseURL = temporaryDirectory.appendingPathComponent("chosen", isDirectory: true)
        let replacementURL = temporaryDirectory.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: chooseURL, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: replacementURL, withIntermediateDirectories: true)
        var refreshes = 0
        let summary = StorageRootSummary(id: StorageRootID(), displayName: "root", displayPath: chooseURL.path, updatedAt: AbsoluteTime(Date()))
        let chooseController = CallbackRootController(availability: .noRootSelected, summary: summary)
        let chooseSelector = CallbackDirectorySelector(selectedURL: chooseURL)
        let chooseModel = StorageRootViewModel(controller: chooseController, directorySelector: chooseSelector, onRootChanged: { refreshes += 1 })
        await chooseModel.chooseActiveRoot()
        XCTAssertEqual(refreshes, 1)
        let reauthorizeController = CallbackRootController(availability: .reauthorizationRequired(summary), summary: summary)
        let reauthorizeSelector = CallbackDirectorySelector(selectedURL: replacementURL)
        let reauthorizeModel = StorageRootViewModel(controller: reauthorizeController, directorySelector: reauthorizeSelector, onRootChanged: { refreshes += 1 })
        await reauthorizeModel.restore(); await reauthorizeModel.reauthorize()
        XCTAssertEqual(refreshes, 2)
        let cancelled = StorageRootViewModel(controller: CallbackRootController(availability: .noRootSelected, summary: summary), directorySelector: CallbackDirectorySelector(selectedURL: nil), onRootChanged: { refreshes += 1 })
        await cancelled.chooseActiveRoot()
        let failingController = CallbackRootController(availability: .noRootSelected, summary: summary, registrationError: .bookmarkCreateFailed)
        let failing = StorageRootViewModel(controller: failingController, directorySelector: CallbackDirectorySelector(selectedURL: chooseURL), onRootChanged: { refreshes += 1 })
        await failing.chooseActiveRoot()
        let cancelledReauthorization = StorageRootViewModel(controller: CallbackRootController(availability: .reauthorizationRequired(summary), summary: summary), directorySelector: CallbackDirectorySelector(selectedURL: nil), onRootChanged: { refreshes += 1 })
        await cancelledReauthorization.restore(); await cancelledReauthorization.reauthorize()
        let failedReauthorization = StorageRootViewModel(controller: CallbackRootController(availability: .reauthorizationRequired(summary), summary: summary, reauthorizationError: .rootNotDirectory), directorySelector: CallbackDirectorySelector(selectedURL: replacementURL), onRootChanged: { refreshes += 1 })
        await failedReauthorization.restore(); await failedReauthorization.reauthorize()
        XCTAssertEqual(refreshes, 2, "Cancelled and failed selection or reauthorization panels must not request catalog refresh")
    }

    @MainActor
    func testStartupDeliversNoRootPartialAndCatalogFailureStates() async throws {
        let noRoot = CatalogStartupCoordinator(catalog: ReportingCatalog(report: CatalogReconciliationReport(rootResults: [], issues: [], recoveredFromCorruption: false)))
        noRoot.start()
        try await waitUntil { if case .ready = noRoot.state { return true }; return false }
        if case let .ready(report) = noRoot.state { XCTAssertTrue(report.rootResults.isEmpty) } else { XCTFail("Expected no-root ready state") }
        let root = StorageRootID()
        let partialResult = RootScanResult(rootID: root, outcome: .partial, projections: [], unreadableFolderNames: [], missingFolderNames: [], issues: [CatalogIssue(code: .filesystemScanFailed, rootID: root, folderName: nil)])
        let partial = CatalogStartupCoordinator(catalog: ReportingCatalog(report: CatalogReconciliationReport(rootResults: [partialResult], issues: partialResult.issues, recoveredFromCorruption: false)))
        partial.start()
        try await waitUntil { if case .ready = partial.state { return true }; return false }
        if case let .ready(report) = partial.state { XCTAssertEqual(report.rootResults.first?.outcome, .partial) } else { XCTFail("Expected partial ready state") }
        let failed = CatalogStartupCoordinator(catalog: TestCatalog(failure: .openFailed))
        failed.start()
        try await waitUntil { if case .failed = failed.state { return true }; return false }
        XCTAssertEqual(failed.state, .failed(.openFailed))
    }

    @MainActor
    func testMainWindowConstructionWithInjectedCatalogDependenciesHasNoSupportSideEffect() {
        let untouchedSupport = temporaryDirectory.appendingPathComponent("must-not-exist", isDirectory: true)
        let root = StorageRootViewModel(controller: CallbackRootController(availability: .noRootSelected, summary: StorageRootSummary(id: StorageRootID(), displayName: "fixture", displayPath: "/fixture", updatedAt: AbsoluteTime(Date()))), directorySelector: CallbackDirectorySelector(selectedURL: nil))
        let view = MainWindowView(storageRoots: root, catalogStartup: CatalogStartupCoordinator(catalog: UnavailableSessionCatalog(error: .openFailed)))
        XCTAssertNotNil(Optional(view))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouchedSupport.path), "Injected view construction must not create an Application Support catalog")
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
        try JSONEncoder().encode(try metadataDocument(for: projection)).write(to: folder.appendingPathComponent("metadata.json"))
    }

    private func metadataDocument(for projection: CatalogProjection) throws -> SessionMetadataDocument {
        try SessionMetadataDocument(sessionId: projection.location.sessionID, title: projection.title, status: projection.metadataStatus, captureOutcome: projection.captureOutcome, createdAt: projection.createdAt, activeDurationMs: projection.activeDuration, languageMode: .automatic, transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: projection.metadataLastUpdatedAt)
    }

    private func treeSnapshot(_ root: URL) throws -> [String: Data] {
        let manager = FileManager.default
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        var snapshot: [String: Data] = [:]
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { snapshot[relative] = Data("symlink".utf8) }
            else if values.isDirectory == true { snapshot[relative + "/"] = Data() }
            else { snapshot[relative] = try Data(contentsOf: url) }
        }
        return snapshot
    }

    private func acceptSendable<Value: Sendable>(_ value: Value) {}

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }

    private func sqlite(_ sql: String, database: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite fixture creation failed")
    }

    private func sqliteOutput(_ sql: String, database: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.standardOutput = output
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite fixture query failed")
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
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

private actor CountingCatalogBookmarkCodec: SecurityScopedBookmarkCodec {
    private let allowAccess: Bool
    private var starts = 0
    private var stops = 0

    init(allowAccess: Bool) { self.allowAccess = allowAccess }
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: false) }
    func startAccessing(_ url: URL) async -> Bool { starts += 1; return allowAccess }
    func stopAccessing(_ url: URL) async { stops += 1 }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor ReportingCatalog: SessionCataloging {
    let report: CatalogReconciliationReport
    init(report: CatalogReconciliationReport) { self.report = report }
    func reconcile() async throws -> CatalogReconciliationReport { report }
    func orderedItems() async throws -> [SessionCatalogItem] { [] }
}

private actor CallbackRootController: StorageRootControlling {
    let currentAvailability: StorageRootAvailability
    let summary: StorageRootSummary
    let registrationError: StorageErrorCode?
    let reauthorizationError: StorageErrorCode?

    init(availability: StorageRootAvailability, summary: StorageRootSummary, registrationError: StorageErrorCode? = nil, reauthorizationError: StorageErrorCode? = nil) {
        currentAvailability = availability
        self.summary = summary
        self.registrationError = registrationError
        self.reauthorizationError = reauthorizationError
    }
    func availability() async -> StorageRootAvailability { currentAvailability }
    func storageRootCatalog() async throws -> StorageRootCatalog { StorageRootCatalog(activeRootID: summary.id, roots: [StorageRootReference(summary: summary, isActive: true)]) }
    func registerSelectedDirectory(_ url: URL) async throws -> StorageRootSummary {
        if let registrationError { throw StorageError(registrationError) }
        return summary
    }
    func reauthorize(rootID: StorageRootID, with url: URL) async throws -> StorageRootSummary {
        if let reauthorizationError { throw StorageError(reauthorizationError) }
        return summary
    }
}

@MainActor
private final class CallbackDirectorySelector: DirectorySelecting {
    let selectedURL: URL?
    init(selectedURL: URL?) { self.selectedURL = selectedURL }
    func chooseDirectory() -> URL? { selectedURL }
}
