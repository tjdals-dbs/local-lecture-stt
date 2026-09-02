import Foundation

struct ResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkCodec: Sendable {
    func makeBookmark(for directory: URL) async throws -> Data
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark
    func startAccessing(_ url: URL) async -> Bool
    func stopAccessing(_ url: URL) async
}

/// Infrastructure-only long-lived access token.  The URL never escapes this
/// directory; release is idempotent so writer failure races cannot stop a
/// security scope twice.
final class StorageRootWriteLease: @unchecked Sendable {
    let rootURL: URL
    private let bookmarkCodec: any SecurityScopedBookmarkCodec
    private let lock = NSLock()
    private var released = false

    init(rootURL: URL, bookmarkCodec: any SecurityScopedBookmarkCodec) {
        self.rootURL = rootURL
        self.bookmarkCodec = bookmarkCodec
    }

    func release() async {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return }
        await bookmarkCodec.stopAccessing(rootURL)
    }
}

struct FoundationSecurityScopedBookmarkCodec: SecurityScopedBookmarkCodec {
    func makeBookmark(for directory: URL) async throws -> Data {
        try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedBookmark(url: url, isStale: stale)
    }

    func startAccessing(_ url: URL) async -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) async {
        url.stopAccessingSecurityScopedResource()
    }
}

private struct StorageRootRegistry: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    var activeRootID: StorageRootID?
    var roots: [StorageRootRegistryEntry]

    init(activeRootID: StorageRootID? = nil, roots: [StorageRootRegistryEntry] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.activeRootID = activeRootID
        self.roots = roots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else { throw StorageError(.registryUnsupported) }
        self.schemaVersion = schemaVersion
        activeRootID = try container.decodeIfPresent(StorageRootID.self, forKey: .activeRootID)
        roots = try container.decode([StorageRootRegistryEntry].self, forKey: .roots)
    }
}

private struct StorageRootRegistryEntry: Codable, Sendable {
    let id: StorageRootID
    var bookmark: Data
    var displayName: String
    var displayPath: String
    var createdAt: AbsoluteTime
    var updatedAt: AbsoluteTime

    var summary: StorageRootSummary {
        StorageRootSummary(id: id, displayName: displayName, displayPath: displayPath, updatedAt: updatedAt)
    }
}

actor StorageRootManager: StorageRootControlling, RecordingStorageRootChecking {
    private let registryURL: URL
    private let bookmarkCodec: any SecurityScopedBookmarkCodec
    private let atomicWriter: AtomicFileWriter
    private let now: @Sendable () -> AbsoluteTime

    init(
        applicationSupportDirectory: URL,
        bookmarkCodec: any SecurityScopedBookmarkCodec = FoundationSecurityScopedBookmarkCodec(),
        atomicWriter: AtomicFileWriter = AtomicFileWriter(),
        now: @escaping @Sendable () -> AbsoluteTime = { AbsoluteTime(Date()) }
    ) {
        registryURL = applicationSupportDirectory
            .appendingPathComponent("LocalLectureSTT", isDirectory: true)
            .appendingPathComponent("Storage", isDirectory: true)
            .appendingPathComponent("storage-roots.json", isDirectory: false)
        self.bookmarkCodec = bookmarkCodec
        self.atomicWriter = atomicWriter
        self.now = now
    }

    static func live() -> StorageRootManager {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StorageRootManager(applicationSupportDirectory: applicationSupport)
    }

    func availability() async -> StorageRootAvailability {
        do {
            let registry = try loadRegistry()
            guard let activeID = registry.activeRootID else { return .noRootSelected }
            guard let entry = registry.roots.first(where: { $0.id == activeID }) else { return .failed(.registryCorrupt) }
            let result = try await performWithAccess(to: entry.id) { _ in () }
            return .available(try rootSummary(id: entry.id), refreshedBookmark: result.refreshedBookmark)
        } catch let error as StorageError {
            switch error.code {
            case .bookmarkResolveFailed, .securityScopeAccessFailed, .reauthorizationRequired:
                return .reauthorizationRequired(try? activeRootSummary())
            default:
                return .failed(error.code)
            }
        } catch {
            return .failed(.registryCorrupt)
        }
    }

    func storageRootCatalog() async throws -> StorageRootCatalog {
        let registry = try loadRegistry()
        return StorageRootCatalog(
            activeRootID: registry.activeRootID,
            roots: registry.roots.map { entry in
                StorageRootReference(summary: entry.summary, isActive: entry.id == registry.activeRootID)
            }
        )
    }

    func registerSelectedDirectory(_ url: URL) async throws -> StorageRootSummary {
        guard try isDirectory(url) else { throw StorageError(.rootNotDirectory) }
        var registry = try loadRegistry()
        let timestamp = now()
        let bookmark: Data
        do { bookmark = try await bookmarkCodec.makeBookmark(for: url) }
        catch { throw StorageError(.bookmarkCreateFailed) }
        let normalizedPath = normalizedPath(for: url)

        if let index = registry.roots.firstIndex(where: { $0.displayPath == normalizedPath }) {
            registry.roots[index].bookmark = bookmark
            registry.roots[index].displayName = displayName(for: url)
            registry.roots[index].displayPath = normalizedPath
            registry.roots[index].updatedAt = timestamp
            registry.activeRootID = registry.roots[index].id
            try saveRegistry(registry)
            return registry.roots[index].summary
        }

        let entry = StorageRootRegistryEntry(
            id: StorageRootID(),
            bookmark: bookmark,
            displayName: displayName(for: url),
            displayPath: normalizedPath,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        registry.roots.append(entry)
        registry.activeRootID = entry.id
        try saveRegistry(registry)
        return entry.summary
    }

    func reauthorize(rootID: StorageRootID, with url: URL) async throws -> StorageRootSummary {
        guard try isDirectory(url) else { throw StorageError(.rootNotDirectory) }
        var registry = try loadRegistry()
        guard let index = registry.roots.firstIndex(where: { $0.id == rootID }) else { throw StorageError(.reauthorizationRequired) }
        do { registry.roots[index].bookmark = try await bookmarkCodec.makeBookmark(for: url) }
        catch { throw StorageError(.bookmarkCreateFailed) }
        registry.roots[index].displayName = displayName(for: url)
        registry.roots[index].displayPath = normalizedPath(for: url)
        registry.roots[index].updatedAt = now()
        try saveRegistry(registry)
        return registry.roots[index].summary
    }

    func activeRootID() async throws -> StorageRootID {
        guard let id = try loadRegistry().activeRootID else { throw StorageError(.noActiveRoot) }
        return id
    }

    func withAccess<Value: Sendable>(to rootID: StorageRootID? = nil, operation: @Sendable (URL) throws -> Value) async throws -> Value {
        try await performWithAccess(to: rootID, requireWritable: true, operation: operation).value
    }

    /// Read-only operations such as catalog reconciliation may use roots that are no longer writable.
    func withReadAccess<Value: Sendable>(to rootID: StorageRootID, operation: @Sendable (URL) throws -> Value) async throws -> Value {
        try await performWithAccess(to: rootID, requireWritable: false, operation: operation).value
    }

    /// Acquires a scope for an active writer. Unlike `withAccess`, the caller
    /// must retain this lease until AVAssetWriter has completed finishing.
    func acquireWriteLease(to rootID: StorageRootID) async throws -> StorageRootWriteLease {
        var registry = try loadRegistry()
        guard let index = registry.roots.firstIndex(where: { $0.id == rootID }) else {
            throw StorageError(.reauthorizationRequired)
        }
        let resolved: ResolvedBookmark
        do { resolved = try await bookmarkCodec.resolve(registry.roots[index].bookmark) }
        catch { throw StorageError(.reauthorizationRequired) }
        if resolved.isStale {
            do {
                registry.roots[index].bookmark = try await bookmarkCodec.makeBookmark(for: resolved.url)
                registry.roots[index].displayName = displayName(for: resolved.url)
                registry.roots[index].displayPath = normalizedPath(for: resolved.url)
                registry.roots[index].updatedAt = now()
                try saveRegistry(registry)
            } catch let error as StorageError { throw error }
            catch { throw StorageError(.bookmarkRefreshFailed) }
        }
        guard await bookmarkCodec.startAccessing(resolved.url) else { throw StorageError(.reauthorizationRequired) }
        do {
            guard FileManager.default.fileExists(atPath: resolved.url.path) else { throw StorageError(.rootMissing) }
            let values = try resolved.url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageError(.rootNotDirectory) }
            guard values.isWritable != false else { throw StorageError(.rootNotWritable) }
            return StorageRootWriteLease(rootURL: resolved.url, bookmarkCodec: bookmarkCodec)
        } catch {
            await bookmarkCodec.stopAccessing(resolved.url)
            throw error
        }
    }

    private func performWithAccess<Value: Sendable>(to rootID: StorageRootID? = nil, requireWritable: Bool = true, operation: @Sendable (URL) throws -> Value) async throws -> (value: Value, refreshedBookmark: Bool) {
        var registry = try loadRegistry()
        let resolvedID: StorageRootID
        if let rootID { resolvedID = rootID }
        else if let active = registry.activeRootID { resolvedID = active }
        else { throw StorageError(.noActiveRoot) }
        guard let index = registry.roots.firstIndex(where: { $0.id == resolvedID }) else { throw StorageError(.reauthorizationRequired) }

        let resolved: ResolvedBookmark
        do { resolved = try await bookmarkCodec.resolve(registry.roots[index].bookmark) }
        catch { throw StorageError(.reauthorizationRequired) }
        if resolved.isStale {
            do {
                registry.roots[index].bookmark = try await bookmarkCodec.makeBookmark(for: resolved.url)
                registry.roots[index].displayName = displayName(for: resolved.url)
                registry.roots[index].displayPath = normalizedPath(for: resolved.url)
                registry.roots[index].updatedAt = now()
                try saveRegistry(registry)
            } catch let error as StorageError {
                throw error
            } catch {
                throw StorageError(.bookmarkRefreshFailed)
            }
        }
        guard await bookmarkCodec.startAccessing(resolved.url) else { throw StorageError(.reauthorizationRequired) }
        do {
            guard FileManager.default.fileExists(atPath: resolved.url.path) else { throw StorageError(.rootMissing) }
            let values = try resolved.url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
            guard values.isDirectory == true else { throw StorageError(.rootNotDirectory) }
            if requireWritable, values.isWritable == false { throw StorageError(.rootNotWritable) }
            let value = try operation(resolved.url)
            await bookmarkCodec.stopAccessing(resolved.url)
            return (value, resolved.isStale)
        } catch {
            await bookmarkCodec.stopAccessing(resolved.url)
            throw error
        }
    }

    private func activeRootSummary() throws -> StorageRootSummary? {
        let registry = try loadRegistry()
        guard let id = registry.activeRootID else { return nil }
        return registry.roots.first(where: { $0.id == id })?.summary
    }

    private func rootSummary(id: StorageRootID) throws -> StorageRootSummary {
        let registry = try loadRegistry()
        guard let entry = registry.roots.first(where: { $0.id == id }) else { throw StorageError(.registryCorrupt) }
        return entry.summary
    }

    private func loadRegistry() throws -> StorageRootRegistry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return StorageRootRegistry() }
        do {
            return try JSONDecoder().decode(StorageRootRegistry.self, from: Data(contentsOf: registryURL))
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError(.registryCorrupt)
        }
    }

    private func saveRegistry(_ registry: StorageRootRegistry) throws {
        let directory = registryURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw StorageError(.temporaryCreateFailed) }
        try atomicWriter.writeJSON(registry, to: registryURL)
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    private func displayName(for url: URL) -> String { url.lastPathComponent }
    private func normalizedPath(for url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
