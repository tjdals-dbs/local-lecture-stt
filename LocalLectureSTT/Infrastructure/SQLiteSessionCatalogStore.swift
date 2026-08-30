import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Kept small so recovery can be fault-injected without ever touching a user root.
protocol CatalogFileMoving: Sendable {
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func move(_ source: URL, _ destination: URL) throws
}

struct FoundationCatalogFileMover: CatalogFileMoving {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func createDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func move(_ source: URL, _ destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }
}

actor SQLiteSessionCatalogStore: SessionCatalogStore {
    static let schemaVersion: Int32 = 1
    let databaseURL: URL
    private let didRecoverFromCorruption: Bool
    private var database: OpaquePointer?

    init(applicationSupportDirectory: URL, fileMover: any CatalogFileMoving = FoundationCatalogFileMover()) throws {
        databaseURL = applicationSupportDirectory
            .appendingPathComponent("LocalLectureSTT", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("session-catalog.sqlite3", isDirectory: false)
        try Self.prepareDirectory(databaseURL.deletingLastPathComponent())
        var recovered = false
        do {
            recovered = try Self.validateOrRecoverExistingDatabase(at: databaseURL, fileMover: fileMover)
            database = try Self.openDatabase(at: databaseURL)
            try Self.configure(database)
            try Self.createOrValidateSchema(database)
            didRecoverFromCorruption = recovered
        } catch let error as CatalogError where error.code == .schemaInvalid || error.code == .schemaCorrupt {
            sqlite3_close(database)
            database = nil
            try Self.quarantine(databaseURL, sidecars: Self.sidecars(for: databaseURL), fileMover: fileMover)
            recovered = true
            database = try Self.openDatabase(at: databaseURL)
            try Self.configure(database)
            try Self.createOrValidateSchema(database)
            didRecoverFromCorruption = recovered
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    func close() throws {
        guard let database else { return }
        guard sqlite3_close(database) == SQLITE_OK else { throw CatalogError(.stepFailed) }
        self.database = nil
    }

    func orderedItems() throws -> [SessionCatalogItem] {
        let sql = "SELECT session_id, root_id, folder_name, title, created_at_ms, active_duration_ms, metadata_status, capture_outcome, presence, metadata_updated_at_ms, catalog_updated_at_ms FROM sessions ORDER BY created_at_ms DESC, session_id ASC"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var items: [SessionCatalogItem] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return items }
            guard result == SQLITE_ROW else { throw CatalogError(.stepFailed) }
            items.append(try Self.item(from: statement))
        }
    }

    func recoveredFromCorruption() -> Bool { didRecoverFromCorruption }

    func apply(_ results: [RootScanResult], catalogUpdatedAt: AbsoluteTime) throws {
        var allIDs = Set<SessionID>()
        var allLocations = Set<String>()
        for result in results {
            for projection in result.projections {
                guard allIDs.insert(projection.location.sessionID).inserted else { throw CatalogError(.reconciliationConflict) }
                let location = "\(projection.location.rootID.rawValue.uuidString)/\(projection.location.folderName.rawValue)"
                guard allLocations.insert(location).inserted else { throw CatalogError(.reconciliationConflict) }
            }
        }
        try execute("BEGIN IMMEDIATE", failure: .transactionBeginFailed)
        do {
            for result in results {
                for projection in result.projections { try upsert(projection, at: catalogUpdatedAt) }
                guard result.outcome == .complete else { continue }
                for folder in result.unreadableFolderNames { try updatePresence(.unreadable, rootID: result.rootID, folderName: folder, at: catalogUpdatedAt) }
                for folder in result.missingFolderNames { try updatePresence(.missing, rootID: result.rootID, folderName: folder, at: catalogUpdatedAt) }
                let presentFolders = Set(result.projections.map(\.location.folderName.rawValue))
                let excluded = presentFolders.union(result.unreadableFolderNames).union(result.missingFolderNames)
                try markUnseenRowsMissing(rootID: result.rootID, excluding: excluded, at: catalogUpdatedAt)
            }
            try execute("COMMIT", failure: .transactionCommitFailed)
        } catch {
            do { try execute("ROLLBACK", failure: .transactionRollbackFailed) } catch { throw CatalogError(.transactionRollbackFailed) }
            throw error
        }
    }

    private func upsert(_ projection: CatalogProjection, at timestamp: AbsoluteTime) throws {
        let sql = """
        INSERT INTO sessions (session_id, root_id, folder_name, title, created_at_ms, active_duration_ms, metadata_status, capture_outcome, presence, metadata_updated_at_ms, catalog_updated_at_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'present', ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET root_id=excluded.root_id, folder_name=excluded.folder_name, title=excluded.title, created_at_ms=excluded.created_at_ms, active_duration_ms=excluded.active_duration_ms, metadata_status=excluded.metadata_status, capture_outcome=excluded.capture_outcome, presence='present', metadata_updated_at_ms=excluded.metadata_updated_at_ms, catalog_updated_at_ms=excluded.catalog_updated_at_ms
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(projection.location.sessionID.rawValue.uuidString.lowercased(), to: statement, index: 1)
        try bindText(projection.location.rootID.rawValue.uuidString.lowercased(), to: statement, index: 2)
        try bindText(projection.location.folderName.rawValue, to: statement, index: 3)
        try bindText(projection.title, to: statement, index: 4)
        try bindInt64(try Self.milliseconds(projection.createdAt), to: statement, index: 5)
        try bindInt64(projection.activeDuration.rawValue, to: statement, index: 6)
        try bindText(projection.metadataStatus.rawValue, to: statement, index: 7)
        try bindText(projection.captureOutcome.rawValue, to: statement, index: 8)
        try bindInt64(try Self.milliseconds(projection.metadataLastUpdatedAt), to: statement, index: 9)
        try bindInt64(try Self.milliseconds(timestamp), to: statement, index: 10)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_CONSTRAINT { throw CatalogError(.reconciliationConflict) }
            throw CatalogError(.stepFailed)
        }
    }

    private func updatePresence(_ presence: CatalogPresence, rootID: StorageRootID, folderName: String, at timestamp: AbsoluteTime) throws {
        let statement = try prepare("UPDATE sessions SET presence=?, catalog_updated_at_ms=? WHERE root_id=? AND folder_name=?")
        defer { sqlite3_finalize(statement) }
        try bindText(presence.rawValue, to: statement, index: 1)
        try bindInt64(try Self.milliseconds(timestamp), to: statement, index: 2)
        try bindText(rootID.rawValue.uuidString.lowercased(), to: statement, index: 3)
        try bindText(folderName, to: statement, index: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CatalogError(.stepFailed) }
    }

    private func markUnseenRowsMissing(rootID: StorageRootID, excluding folders: Set<String>, at timestamp: AbsoluteTime) throws {
        let select = try prepare("SELECT folder_name FROM sessions WHERE root_id=?")
        defer { sqlite3_finalize(select) }
        try bindText(rootID.rawValue.uuidString.lowercased(), to: select, index: 1)
        var unseen: [String] = []
        while true {
            let result = sqlite3_step(select)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw CatalogError(.stepFailed) }
            guard let text = sqlite3_column_text(select, 0) else { throw CatalogError(.invalidStoredValue) }
            let folder = String(cString: text)
            if !folders.contains(folder) { unseen.append(folder) }
        }
        for folder in unseen { try updatePresence(.missing, rootID: rootID, folderName: folder, at: timestamp) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, statement != nil else { throw CatalogError(.prepareFailed) }
        return statement
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else { throw CatalogError(.bindFailed) }
    }
    private func bindInt64(_ value: Int64, to statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw CatalogError(.bindFailed) }
    }
    private func execute(_ sql: String, failure: CatalogErrorCode) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CatalogError(failure) }
    }

    private static func milliseconds(_ time: AbsoluteTime) throws -> Int64 {
        let milliseconds = time.value.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds <= Double(Int64.max) else { throw CatalogError(.invalidStoredValue) }
        return Int64(milliseconds.rounded())
    }
    private static func time(_ milliseconds: Int64) -> AbsoluteTime { AbsoluteTime(Date(timeIntervalSince1970: Double(milliseconds) / 1_000)) }

    private static func item(from statement: OpaquePointer?) throws -> SessionCatalogItem {
        func text(_ index: Int32) throws -> String {
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let value = sqlite3_column_text(statement, index) else { throw CatalogError(.invalidStoredValue) }
            return String(cString: value)
        }
        func integer(_ index: Int32) throws -> Int64 {
            guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { throw CatalogError(.invalidStoredValue) }
            return sqlite3_column_int64(statement, index)
        }
        guard let sessionUUID = UUID(uuidString: try text(0)), let rootUUID = UUID(uuidString: try text(1)),
              let status = SessionStatus(rawValue: try text(6)), let outcome = CaptureOutcome(rawValue: try text(7)), let presence = CatalogPresence(rawValue: try text(8)) else { throw CatalogError(.invalidStoredValue) }
        let duration = try MediaMilliseconds(try integer(5))
        return SessionCatalogItem(sessionID: SessionID(sessionUUID), rootID: StorageRootID(rootUUID), folderName: try SessionFolderName(validating: text(2)), title: try text(3), createdAt: time(try integer(4)), activeDuration: duration, metadataStatus: status, captureOutcome: outcome, presence: presence, metadataLastUpdatedAt: time(try integer(9)), catalogUpdatedAt: time(try integer(10)))
    }

    private static func prepareDirectory(_ directory: URL) throws {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw CatalogError(.catalogDirectoryCreateFailed) }
    }
    private static func sidecars(for url: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: url.path + $0) }
    }

    private static func validateOrRecoverExistingDatabase(at url: URL, fileMover: any CatalogFileMoving) throws -> Bool {
        let sidecars = sidecars(for: url)
        guard !fileMover.exists(url) else {
            return try inspectExistingDatabase(at: url, sidecars: sidecars, fileMover: fileMover)
        }
        if sidecars.contains(where: fileMover.exists) {
            try quarantine(url, sidecars: sidecars, fileMover: fileMover)
            return true
        }
        return false
    }

    private static func inspectExistingDatabase(at url: URL, sidecars: [URL], fileMover: any CatalogFileMoving) throws -> Bool {
        var readOnly: OpaquePointer?
        // immutable prevents SQLite from checkpointing, deleting, or otherwise altering
        // WAL/SHM bytes while deciding whether those bytes must be quarantined.
        let immutableURL = "file:\(url.path)?immutable=1"
        let code = sqlite3_open_v2(immutableURL, &readOnly, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI, nil)
        guard code == SQLITE_OK, readOnly != nil else {
            sqlite3_close(readOnly)
            try quarantine(url, sidecars: sidecars, fileMover: fileMover)
            return true
        }
        var healthy = false
        var isFutureSchema = false
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(readOnly, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            let version = sqlite3_column_int(statement, 0)
            isFutureSchema = version > schemaVersion
            if version == schemaVersion {
                var check: OpaquePointer?
                if sqlite3_prepare_v2(readOnly, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
                   sqlite3_step(check) == SQLITE_ROW,
                   let result = sqlite3_column_text(check, 0), String(cString: result) == "ok" {
                    healthy = true
                }
                sqlite3_finalize(check)
            }
        }
        sqlite3_finalize(statement)
        sqlite3_close(readOnly)
        if isFutureSchema { throw CatalogError(.schemaUnsupported) }
        if !healthy {
            try quarantine(url, sidecars: sidecars, fileMover: fileMover)
            return true
        }
        return false
    }
    private static func openDatabase(at url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, database != nil else { sqlite3_close(database); throw CatalogError(.openFailed) }
        return database
    }
    private static func configure(_ database: OpaquePointer?) throws {
        sqlite3_busy_timeout(database, 2_000)
        for pragma in ["PRAGMA foreign_keys = ON", "PRAGMA trusted_schema = OFF", "PRAGMA synchronous = FULL"] {
            guard sqlite3_exec(database, pragma, nil, nil, nil) == SQLITE_OK else { throw CatalogError(.configureFailed) }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode = WAL", -1, &statement, nil) == SQLITE_OK else { throw CatalogError(.configureFailed) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let mode = sqlite3_column_text(statement, 0), String(cString: mode).lowercased() == "wal" else { throw CatalogError(.configureFailed) }
    }
    private static func createOrValidateSchema(_ database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw CatalogError(.schemaInvalid) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CatalogError(.schemaInvalid) }
        let version = sqlite3_column_int(statement, 0)
        if version > schemaVersion { throw CatalogError(.schemaUnsupported) }
        if version == 0 {
            let schema = "CREATE TABLE sessions (session_id TEXT PRIMARY KEY NOT NULL, root_id TEXT NOT NULL, folder_name TEXT NOT NULL, title TEXT NOT NULL, created_at_ms INTEGER NOT NULL, active_duration_ms INTEGER NOT NULL CHECK(active_duration_ms >= 0), metadata_status TEXT NOT NULL, capture_outcome TEXT NOT NULL, presence TEXT NOT NULL CHECK(presence IN ('present','missing','unreadable')), metadata_updated_at_ms INTEGER NOT NULL, catalog_updated_at_ms INTEGER NOT NULL, UNIQUE(root_id, folder_name)); CREATE INDEX sessions_order ON sessions(created_at_ms DESC, session_id ASC); PRAGMA user_version = 1;"
            guard sqlite3_exec(database, "BEGIN IMMEDIATE; \(schema) COMMIT;", nil, nil, nil) == SQLITE_OK else { throw CatalogError(.schemaCreateFailed) }
        } else if version == schemaVersion {
            let required: [String: String] = ["session_id": "TEXT", "root_id": "TEXT", "folder_name": "TEXT", "title": "TEXT", "created_at_ms": "INTEGER", "active_duration_ms": "INTEGER", "metadata_status": "TEXT", "capture_outcome": "TEXT", "presence": "TEXT", "metadata_updated_at_ms": "INTEGER", "catalog_updated_at_ms": "INTEGER"]
            var columns: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(sessions)", -1, &columns, nil) == SQLITE_OK else { throw CatalogError(.schemaInvalid) }
            defer { sqlite3_finalize(columns) }
            var validated: [String: (type: String, notNull: Int32, primaryKey: Int32)] = [:]
            while true {
                let result = sqlite3_step(columns)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, let name = sqlite3_column_text(columns, 1), let type = sqlite3_column_text(columns, 2) else { throw CatalogError(.schemaInvalid) }
                validated[String(cString: name)] = (String(cString: type).uppercased(), sqlite3_column_int(columns, 3), sqlite3_column_int(columns, 5))
            }
            guard Set(validated.keys) == Set(required.keys),
                  required.allSatisfy({ name, type in validated[name]?.type == type && validated[name]?.notNull == 1 }),
                  validated["session_id"]?.primaryKey == 1,
                  try hasUniqueLocationConstraint(database),
                  try hasOrderingIndex(database),
                  try hasPresenceConstraint(database) else { throw CatalogError(.schemaInvalid) }
        }
    }
    private static func hasUniqueLocationConstraint(_ database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA index_list(sessions)", -1, &statement, nil) == SQLITE_OK else { throw CatalogError(.schemaInvalid) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_int(statement, 2) == 1, let name = sqlite3_column_text(statement, 1) else { continue }
            var info: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA index_info('\(String(cString: name))')", -1, &info, nil) == SQLITE_OK else { throw CatalogError(.schemaInvalid) }
            var columns: [String] = []
            while sqlite3_step(info) == SQLITE_ROW, let column = sqlite3_column_text(info, 2) { columns.append(String(cString: column)) }
            sqlite3_finalize(info)
            if columns == ["root_id", "folder_name"] { return true }
        }
        return false
    }
    private static func hasOrderingIndex(_ database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT sql FROM sqlite_master WHERE type='index' AND name='sessions_order'", -1, &statement, nil) == SQLITE_OK else { throw CatalogError(.schemaInvalid) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: value).uppercased().contains("CREATE INDEX SESSIONS_ORDER ON SESSIONS(CREATED_AT_MS DESC, SESSION_ID ASC)")
    }
    private static func hasPresenceConstraint(_ database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT sql FROM sqlite_master WHERE type='table' AND name='sessions'", -1, &statement, nil) == SQLITE_OK else { throw CatalogError(.schemaInvalid) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return false }
        let sql = String(cString: value).uppercased().replacingOccurrences(of: " ", with: "")
        return sql.contains("CHECK(PRESENCEIN('PRESENT','MISSING','UNREADABLE'))") && sql.contains("CHECK(ACTIVE_DURATION_MS>=0)")
    }
    private static func quarantine(_ url: URL, sidecars: [URL], fileMover: any CatalogFileMoving) throws {
        let token = UUID().uuidString.lowercased()
        let directory = url.deletingLastPathComponent().appendingPathComponent("Corrupt", isDirectory: true).appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1_000))-\(token)", isDirectory: true)
        do {
            try fileMover.createDirectory(directory)
            // Sidecars first, main last: a failure never permits replacing the main bytes.
            for sidecar in sidecars where fileMover.exists(sidecar) { try fileMover.move(sidecar, directory.appendingPathComponent(sidecar.lastPathComponent)) }
            if fileMover.exists(url) { try fileMover.move(url, directory.appendingPathComponent(url.lastPathComponent)) }
        } catch { throw CatalogError(.quarantineFailed) }
    }
}
