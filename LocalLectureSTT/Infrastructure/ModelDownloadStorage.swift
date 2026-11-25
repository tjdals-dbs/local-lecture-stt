import Darwin
import Foundation

struct ModelDownloadJournal: Codable, Sendable {
    let schemaVersion: Int
    let id: ModelDownloadID
    let descriptor: ModelPackageDescriptor
    let delivery: ModelDelivery
    let catalogFingerprint: String
    let directoryStamp: ModelFileStamp
    let payloadStamp: ModelFileStamp
    var snapshot: ModelDownloadSnapshot
    var completed: [String]
    var ownedNodes: [String: ModelFileStamp]
    var payloadTree: [String]
    var association: String?
    var activePath: String?
    var resumeData: Data?
    func validate(id: ModelDownloadID, directory: ModelPackageDirectory, payload: ModelPackageDirectory? = nil) throws {
        guard schemaVersion == 1 else { throw ModelDownloadFailure(code: .unsupportedState) }
        guard self.id == id, snapshot.id == id, snapshot.key == descriptor.key, delivery.key == descriptor.key,
              directory.stamp.sameObject(directoryStamp),
              snapshot.generation >= 1, snapshot.generation < Int.max,
              snapshot.totalBytes == descriptor.files.reduce(Int64(0), { $0 + $1.byteCount }),
              snapshot.completedBytes >= 0, snapshot.completedBytes <= snapshot.totalBytes,
              ownedNodes.count <= 16_384,
              completed.count <= descriptor.files.count, Set(completed).count == completed.count,
              completed.allSatisfy({ p in descriptor.files.contains { $0.path == p } }),
              resumeData == nil || resumeData!.count <= 1_048_576,
              association == nil || association!.utf8.count <= 512,
              activePath == nil || descriptor.files.contains(where: { $0.path == activePath }),
              payloadTree.count <= 16_384 else { throw ModelDownloadFailure(code: .ownership) }
        if let payload, !payload.stamp.sameObject(payloadStamp) { throw ModelDownloadFailure(code: .ownership) }
    }
}

/// Only explicitly admitted operations create this root. Inspection never creates it.
struct ModelDownloadStorage: Sendable {
    var rootURL: @Sendable () throws -> URL = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ModelDownloadFailure(code: .journal)
        }
        return support.appendingPathComponent("LocalLectureSTT/Downloads", isDirectory: true)
    }
    static func name(_ id: ModelDownloadID) -> String { "operation-" + id.rawValue.uuidString.lowercased() }
    func create(id: ModelDownloadID, descriptor: ModelPackageDescriptor, delivery: ModelDelivery,
                fingerprint: String) throws -> (ModelPackageDirectory, ModelPackageDirectory, ModelDownloadJournal) {
        let root = try ModelPackageDirectory(url: rootURL(), create: true)
        guard mkdirat(root.fd, Self.name(id), 0o700) == 0 else { throw ModelDownloadFailure(code: .journal) }
        let dir = try root.child(Self.name(id)); let payload = try dir.child("payload", create: true)
        let sum = descriptor.files.reduce(Int64(0)) { $0 + $1.byteCount }
        let snapshot = ModelDownloadSnapshot(id: id, key: descriptor.key, generation: 1, phase: .transferring, completedBytes: 0, totalBytes: sum)
        let journal = ModelDownloadJournal(schemaVersion: 1, id: id, descriptor: descriptor, delivery: delivery,
            catalogFingerprint: fingerprint, directoryStamp: dir.stamp, payloadStamp: payload.stamp, snapshot: snapshot,
            completed: [], ownedNodes: [:], payloadTree: try payload.treeStamps(), association: nil, activePath: nil, resumeData: nil)
        _ = try write(journal, directory: dir, expectedState: nil); return (dir, payload, journal)
    }
    /// The durable record identifies the operation independently of disposable
    /// payload remnants. It does not assert that an installed model is usable.
    func readRecord(_ id: ModelDownloadID) throws -> (ModelPackageDirectory, ModelDownloadJournal) {
        let root = try ModelPackageDirectory(url: rootURL())
        let dir = try root.child(Self.name(id))
        let bytes = try dir.readMetadata("state.json")
        struct Header: Decodable { let schemaVersion: Int }
        guard try JSONDecoder().decode(Header.self, from: bytes).schemaVersion == 1 else { throw ModelDownloadFailure(code: .unsupportedState) }
        let value = try JSONDecoder().decode(ModelDownloadJournal.self, from: bytes)
        try value.validate(id: id, directory: dir)
        return (dir, value)
    }
    func ownedPayload(_ directory: ModelPackageDirectory, journal: ModelDownloadJournal) throws -> ModelPackageDirectory {
        let payload = try directory.child("payload")
        try journal.validate(id: journal.id, directory: directory, payload: payload)
        return payload
    }
    func read(_ id: ModelDownloadID) throws -> (ModelPackageDirectory, ModelPackageDirectory, ModelDownloadJournal) {
        let (dir, value) = try readRecord(id)
        return (dir, try ownedPayload(dir, journal: value), value)
    }
    @discardableResult
    func write(_ value: ModelDownloadJournal, directory: ModelPackageDirectory, expectedState: ModelFileStamp?) throws -> ModelFileStamp {
        try directory.check()
        let data = try JSONEncoder().encode(value)
        guard data.count <= ModelPackageDirectory.metadataLimit else { throw ModelDownloadFailure(code: .journal) }
        let currentNames = try directory.names()
        if let expectedState {
            guard currentNames.contains("state.json"), ModelFileStamp(try directory.info("state.json")) == expectedState else {
                throw ModelDownloadFailure(code: .ownership)
            }
        } else if currentNames.contains("state.json") { throw ModelDownloadFailure(code: .ownership) }
        let tmp = "state-" + UUID().uuidString.lowercased()
        let file = openat(directory.fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw ModelDownloadFailure(code: .journal) }; defer { Darwin.close(file) }
        try ModelPackageDirectory.writeAll(data, fd: file)
        guard fsync(file) == 0 else { throw ModelRepositoryCode.flushFailed }
        let names = try directory.names()
        if names.contains("state.json") {
            let (old, stamp) = try directory.regularFD("state.json"); defer { Darwin.close(old) }
            guard stamp == expectedState else { throw ModelDownloadFailure(code: .ownership) }
            try directory.checkFile("state.json", fd: old, expected: stamp)
            guard unlinkat(directory.fd, "state.json", 0) == 0 else { throw ModelDownloadFailure(code: .journal) }
        }
        guard renameatx_np(directory.fd, tmp, directory.fd, "state.json", UInt32(RENAME_EXCL)) == 0 else {
            throw ModelDownloadFailure(code: .journal)
        }
        try directory.sync()
        return ModelFileStamp(try directory.info("state.json"))
    }
    func contains(_ id: ModelDownloadID) throws -> Bool {
        let root: ModelPackageDirectory
        do { root = try ModelPackageDirectory(url: rootURL()) }
        catch ModelRepositoryCode.sourceUnavailable { return false }
        return try root.names().contains(Self.name(id))
    }
    /// Remove only an unchanged, proven owned incomplete file. Completed files,
    /// unknown nodes and replaced identities cannot be adopted as disposable data.
    func resetIncomplete(payload: ModelPackageDirectory, completed: [String], activePath: String?,
                         owned: ModelDownloadOwnedNodes, expectedTree: [String]) throws -> Bool {
        guard try payload.treeStamps() == expectedTree else { throw ModelDownloadFailure(code: .ownership) }
        try owned.check(payload)
        let extra = Set(try payload.payloadPaths(allowManifest: false)).subtracting(completed)
        guard !extra.isEmpty else { return false }
        guard let path = activePath, extra == [path], let ownedFile = owned.values()[path] else {
            throw ModelDownloadFailure(code: .ownership)
        }
        let (parent, name) = try payload.parent(path)
        let (file, before) = try parent.regularFD(name); defer { Darwin.close(file) }
        guard ownedFile.sameObject(before) else { throw ModelDownloadFailure(code: .ownership) }
        try parent.checkFile(name, fd: file, expected: before)
        guard unlinkat(parent.fd, name, 0) == 0 else { throw ModelDownloadFailure(code: .diskWrite) }
        owned.forget(path); try parent.sync()
        // Prune only newly empty owned ancestors so another interruption still
        // has an exact described file set. Never recursively remove a payload root.
        var parts = path.split(separator: "/").map(String.init); parts.removeLast()
        while !parts.isEmpty {
            let relative = parts.joined(separator: "/")
            let (ancestor, leaf) = try payload.parent(relative)
            let directory = try ancestor.child(leaf)
            guard let stamp = owned.values()[relative], stamp.sameObject(directory.stamp) else {
                throw ModelDownloadFailure(code: .ownership)
            }
            if try !directory.names().isEmpty { break }
            try directory.check(); try ancestor.check()
            guard stamp.sameObject(ModelFileStamp(try ancestor.info(leaf))),
                  unlinkat(ancestor.fd, leaf, AT_REMOVEDIR) == 0 else { throw ModelDownloadFailure(code: .ownership) }
            owned.forget(relative); try ancestor.sync(); parts.removeLast()
        }
        return true
    }
    func pending() throws -> [ModelDownloadPending] {
        let root: ModelPackageDirectory
        do { root = try ModelPackageDirectory(url: rootURL()) }
        catch ModelRepositoryCode.sourceUnavailable { return [] }
        return try root.names().map { name in
            guard name.hasPrefix("operation-"), let uuid = UUID(uuidString: String(name.dropFirst(10))) else {
                return .init(operation: nil, snapshot: nil, issue: .unsupportedState)
            }
            // Avoid fabricating a new UUID while reading a retained operation.
            let id = ModelDownloadID(rawValue: uuid)
            do {
                let (dir, j) = try readRecord(id)
                do { _ = try ownedPayload(dir, journal: j); return .init(operation: id, snapshot: j.snapshot, issue: nil) }
                catch { return .init(operation: id, snapshot: j.snapshot, issue: .ownership) }
            }
            catch { return .init(operation: id, snapshot: nil, issue: (error as? ModelDownloadFailure)?.code ?? .journal) }
        }
    }
    func remove(id: ModelDownloadID, directory: ModelPackageDirectory, payload: ModelPackageDirectory,
                allowedPaths: Set<String>, owned: ModelDownloadOwnedNodes, expectedState: ModelFileStamp, before: @Sendable () async throws -> Void) async throws {
        try directory.check(); try payload.check()
        guard try directory.names() == ["payload", "state.json"], ModelFileStamp(try directory.info("state.json")) == expectedState else {
            throw ModelDownloadFailure(code: .ownership)
        }
        try owned.check(payload, allowedFiles: allowedPaths)
        let tree = try directory.treeStamps()
        try await before()
        guard try directory.treeStamps() == tree else { throw ModelDownloadFailure(code: .ownership) }
        let root = try ModelPackageDirectory(url: rootURL())
        try root.removeOwned(Self.name(id), expected: directory.stamp)
    }
}
typealias ModelDownloadCapacityProvider = ModelStorageCapacityProvider
struct ModelStorageCapacityProvider: Sendable {
    var available: @Sendable (URL) throws -> Int64? = { url in
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" { candidate.deleteLastPathComponent() }
        let directory = try ModelPackageDirectory(url: candidate)
        let values = try directory.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        try directory.check(); return values.volumeAvailableCapacityForImportantUsage
    }
}

/// Tracks only nodes created by this operation, or exact nodes in its durable
/// completed-payload evidence. Never adopts an unknown pre-existing directory.
final class ModelDownloadOwnedNodes: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: ModelFileStamp]
    init(_ nodes: [String: ModelFileStamp] = [:]) { self.nodes = nodes }
    func values() -> [String: ModelFileStamp] { lock.withLock { nodes } }
    func parent(for path: String, in payload: ModelPackageDirectory) throws -> (ModelPackageDirectory, String) {
        let parts = path.split(separator: "/").map(String.init)
        var dir = payload; var prefix = ""
        for name in parts.dropLast() {
            prefix = prefix.isEmpty ? name : prefix + "/" + name
            try dir.check()
            if mkdirat(dir.fd, name, 0o700) == 0 {
                let child = try dir.child(name)
                lock.withLock { nodes[prefix] = child.stamp }; try dir.sync(); dir = child
            } else {
                let child = try dir.child(name)
                guard lock.withLock({ nodes[prefix]?.sameObject(child.stamp) == true }) else { throw ModelDownloadFailure(code: .ownership) }
                dir = child
            }
        }
        return (dir, parts.last!)
    }
    func forget(_ path: String) { _ = lock.withLock { nodes.removeValue(forKey: path) } }
    func record(_ path: String, stamp: ModelFileStamp) { lock.withLock { nodes[path] = stamp } }
    func check(_ directory: ModelPackageDirectory, prefix: String = "", allowedFiles: Set<String>? = nil) throws {
        for name in try directory.names() {
            let path = prefix + name; let s = try directory.info(name)
            guard lock.withLock({ nodes[path]?.sameObject(ModelFileStamp(s)) == true }) else { throw ModelDownloadFailure(code: .ownership) }
            if s.st_mode & S_IFMT == S_IFDIR { try check(directory.child(name), prefix: path + "/", allowedFiles: allowedFiles) }
            else if s.st_mode & S_IFMT != S_IFREG || (allowedFiles != nil && !allowedFiles!.contains(path)) {
                throw ModelDownloadFailure(code: .ownership)
            }
        }
    }
}
