import CryptoKit
import Darwin
import Foundation

struct ModelFileStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let modifiedNS: Int64
    let changed: Int64
    let changedNS: Int64
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; size = s.st_size
        modified = Int64(s.st_mtimespec.tv_sec); modifiedNS = Int64(s.st_mtimespec.tv_nsec)
        changed = Int64(s.st_ctimespec.tv_sec); changedNS = Int64(s.st_ctimespec.tv_nsec)
    }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    var fingerprint: String { "\(device):\(inode):\(size):\(modified):\(modifiedNS):\(changed):\(changedNS)" }
}

/// All traversal uses no-follow descriptors. Paths are re-opened component by
/// component on revalidation; replacing any ancestor cannot redirect an operation.
final class ModelPackageDirectory: @unchecked Sendable {
    static let chunkSize = 65_536
    static let metadataLimit = 2_097_152
    let url: URL
    let fd: Int32
    let stamp: ModelFileStamp
    init(url: URL, create: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ModelRepositoryCode.unsafeLayout }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw ModelRepositoryCode.storageUnavailable }
        do {
            for component in url.path.split(separator: "/").map(String.init) {
                if create {
                    let made = mkdirat(current, component, 0o700)
                    if made != 0, errno != EEXIST { throw ModelRepositoryCode.storageUnavailable }
                    if made == 0, fsync(current) != 0 { throw ModelRepositoryCode.flushFailed }
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw errno == ENOENT ? ModelRepositoryCode.sourceUnavailable : ModelRepositoryCode.storageUnavailable }
                Darwin.close(current); current = next
            }
            var s = stat(); guard fstat(current, &s) == 0 else { throw ModelRepositoryCode.storageUnavailable }
            self.url = url; fd = current; stamp = ModelFileStamp(s)
        } catch { Darwin.close(current); throw error }
    }
    deinit { Darwin.close(fd) }
    func check() throws {
        do {
            let fresh = try ModelPackageDirectory(url: url)
            guard stamp.sameObject(fresh.stamp) else { throw ModelRepositoryCode.identityChanged }
        } catch { throw ModelRepositoryCode.identityChanged }
    }
    func child(_ name: String, create: Bool = false) throws -> ModelPackageDirectory {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw ModelRepositoryCode.unsafeLayout }
        try check()
        if create {
            let made = mkdirat(fd, name, 0o700)
            if made != 0, errno != EEXIST { throw ModelRepositoryCode.storageUnavailable }
            if made == 0 { try sync() }
        }
        let child = try ModelPackageDirectory(url: url.appendingPathComponent(name))
        try check(); return child
    }
    func names() throws -> [String] {
        try check()
        let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard duplicate >= 0, let dir = fdopendir(duplicate) else { if duplicate >= 0 { Darwin.close(duplicate) }; throw ModelRepositoryCode.storageUnavailable }
        defer { closedir(dir) }
        var names = [String](); errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
            guard names.count <= 16_384 else { throw ModelRepositoryCode.unsafeLayout }
            errno = 0
        }
        guard errno == 0 else { throw ModelRepositoryCode.storageUnavailable }
        try check(); return names.sorted()
    }
    func info(_ name: String) throws -> stat {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw ModelRepositoryCode.storageUnavailable }
        return s
    }
    func parent(_ path: String, create: Bool = false) throws -> (ModelPackageDirectory, String) {
        try ModelPackageRules.path(path)
        let parts = path.split(separator: "/").map(String.init)
        var parent = self
        for component in parts.dropLast() { parent = try parent.child(component, create: create) }
        return (parent, parts.last!)
    }
    func regularFD(_ name: String, allowHardLinks: Bool = false) throws -> (Int32, ModelFileStamp) {
        try check()
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw ModelRepositoryCode.integrityMismatch }
        var s = stat()
        guard fstat(file, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
              allowHardLinks || s.st_nlink == 1 else { Darwin.close(file); throw ModelRepositoryCode.unsafeLayout }
        // Source hard links are copied through an independent new regular file.
        return (file, ModelFileStamp(s))
    }
    func readMetadata(_ name: String) throws -> Data {
        let (file, before) = try regularFD(name); defer { Darwin.close(file) }
        guard before.size >= 0, before.size <= Self.metadataLimit else { throw ModelRepositoryCode.invalidDescriptor }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw ModelRepositoryCode.storageUnavailable }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= Self.metadataLimit else { throw ModelRepositoryCode.invalidDescriptor }
        }
        try checkFile(name, fd: file, expected: before)
        return bytes
    }
    func checkFile(_ name: String, fd file: Int32, expected: ModelFileStamp) throws {
        try check(); var s = stat()
        guard fstat(file, &s) == 0, ModelFileStamp(s) == expected,
              ModelFileStamp(try info(name)) == expected else { throw ModelRepositoryCode.identityChanged }
    }
    func payloadPaths(allowManifest: Bool, prefix: String = "", depth: Int = 0) throws -> [String] {
        guard depth <= 32 else { throw ModelRepositoryCode.unsafeLayout }
        var paths = [String]()
        for name in try names() {
            if allowManifest, prefix.isEmpty, name == "manifest.json" {
                guard try info(name).st_mode & S_IFMT == S_IFREG else { throw ModelRepositoryCode.unsafeLayout }
                continue
            }
            let path = prefix + name
            try ModelPackageRules.path(path)
            let s = try info(name)
            if s.st_mode & S_IFMT == S_IFDIR {
                let nested = try child(name).payloadPaths(allowManifest: false, prefix: path + "/", depth: depth + 1)
                guard !nested.isEmpty else { throw ModelRepositoryCode.unsafeLayout }
                paths += nested
            } else if s.st_mode & S_IFMT == S_IFREG { paths.append(path) }
            else { throw ModelRepositoryCode.unsafeLayout }
            guard paths.count <= 4096 else { throw ModelRepositoryCode.unsafeLayout }
        }
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    func treeStamps(prefix: String = "", depth: Int = 0) throws -> [String] {
        guard depth <= 32 else { throw ModelRepositoryCode.unsafeLayout }
        try check(); var current = stat()
        guard fstat(fd, &current) == 0 else { throw ModelRepositoryCode.storageUnavailable }
        var result = [prefix + ":" + ModelFileStamp(current).fingerprint]
        for name in try names() {
            let s = try info(name)
            if s.st_mode & S_IFMT == S_IFDIR {
                result += try child(name).treeStamps(prefix: prefix + name + "/", depth: depth + 1)
            } else if s.st_mode & S_IFMT == S_IFREG {
                result.append(prefix + name + ":" + ModelFileStamp(s).fingerprint)
            } else { throw ModelRepositoryCode.unsafeLayout }
            guard result.count <= 16_384 else { throw ModelRepositoryCode.unsafeLayout }
        }
        return result
    }
    func hash(_ path: String, chunk: @Sendable () async throws -> Void) async throws -> (Int64, String) {
        let (parent, name) = try parent(path)
        let (file, before) = try parent.regularFD(name); defer { Darwin.close(file) }
        var digest = SHA256(); var buffer = [UInt8](repeating: 0, count: Self.chunkSize); var total: Int64 = 0
        while true {
            try Task.checkCancellation(); try await chunk(); try check(); try parent.checkFile(name, fd: file, expected: before)
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw ModelRepositoryCode.hashFailed }; if count == 0 { break }
            digest.update(data: Data(buffer.prefix(count))); total += Int64(count)
        }
        try parent.checkFile(name, fd: file, expected: before)
        return (total, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func copy(_ path: String, to destination: ModelPackageDirectory, chunk: @Sendable () async throws -> Void) async throws {
        let (parent, name) = try parent(path)
        let (input, before) = try parent.regularFD(name, allowHardLinks: true); defer { Darwin.close(input) }
        let (target, leaf) = try destination.parent(path, create: true)
        let output = openat(target.fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw ModelRepositoryCode.copyFailed }; defer { Darwin.close(output) }
        var s = stat(); guard fstat(output, &s) == 0 else { throw ModelRepositoryCode.copyFailed }
        let owned = ModelFileStamp(s)
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            try Task.checkCancellation(); try await chunk()
            try check(); try parent.checkFile(name, fd: input, expected: before)
            try destination.check(); try target.check()
            guard owned.sameObject(ModelFileStamp(try target.info(leaf))) else { throw ModelRepositoryCode.identityChanged }
            let count = Darwin.read(input, &buffer, buffer.count)
            guard count >= 0 else { throw ModelRepositoryCode.copyFailed }; if count == 0 { break }
            try Self.writeAll(Data(buffer.prefix(count)), fd: output)
        }
        try parent.checkFile(name, fd: input, expected: before)
        guard fsync(output) == 0 else { throw ModelRepositoryCode.flushFailed }
        try target.sync()
    }
    static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ModelRepositoryCode.copyFailed }; offset += count
            }
        }
    }
    func writeManifest(_ manifest: ModelInstallationManifest) throws {
        try check()
        let bytes = try JSONEncoder().encode(manifest)
        guard bytes.count <= Self.metadataLimit else { throw ModelRepositoryCode.invalidDescriptor }
        let file = openat(fd, "manifest.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw ModelRepositoryCode.manifestWriteFailed }; defer { Darwin.close(file) }
        try Self.writeAll(bytes, fd: file)
        guard fsync(file) == 0 else { throw ModelRepositoryCode.flushFailed }; try sync()
    }
    func sync() throws { try check(); guard fsync(fd) == 0 else { throw ModelRepositoryCode.flushFailed } }
    func publish(name: String, to parent: ModelPackageDirectory, finalName: String, owned: ModelPackageDirectory) throws {
        try check(); try parent.check(); try owned.check()
        guard renameatx_np(fd, name, parent.fd, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? ModelRepositoryCode.collision : ModelRepositoryCode.publishFailed
        }
    }
    /// Only a pinned operation-owned directory is removable. Never follows a link
    /// or recursively removes a source/store root. Unsafe remnants are retained.
    func removeOwned(_ name: String, expected: ModelFileStamp, beforeRemove: @Sendable (String) throws -> Void = { _ in }) throws {
        try check()
        let target = try child(name)
        guard target.stamp.sameObject(expected) else { throw ModelRepositoryCode.identityChanged }
        for entry in try target.names() {
            let s = try target.info(entry)
            switch s.st_mode & S_IFMT {
            case S_IFDIR: try target.removeOwned(entry, expected: ModelFileStamp(s), beforeRemove: beforeRemove)
            case S_IFREG:
                try beforeRemove(entry)
                try target.check()
                guard ModelFileStamp(try target.info(entry)) == ModelFileStamp(s), unlinkat(target.fd, entry, 0) == 0 else {
                    throw ModelRepositoryCode.deletionFailed
                }
            default: throw ModelRepositoryCode.unsafeLayout
            }
        }
        try beforeRemove(name)
        try check(); try target.check()
        guard target.stamp.sameObject(ModelFileStamp(try info(name))), unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
            throw ModelRepositoryCode.incompleteRemoval
        }
        try sync()
    }
}

/// URL and scope lifetime exist only in Infrastructure. No bookmark is persisted.
actor ModelImportSources {
    struct Selection: Sendable {
        let url: URL
        let selectedIdentity: ModelFileStamp?
        let start: @Sendable () async -> Bool
        let stop: @Sendable () async -> Void
    }
    private var selections = [ModelImportSourceID: Selection]()
    func register(_ url: URL, start: @escaping @Sendable () async -> Bool, stop: @escaping @Sendable () async -> Void) -> ModelImportSourceID {
        var info = stat()
        let identity = lstat(url.path, &info) == 0 ? ModelFileStamp(info) : nil
        let id = ModelImportSourceID()
        selections[id] = Selection(url: url, selectedIdentity: identity, start: start, stop: stop)
        return id
    }
    func registerSelectedDirectory(_ url: URL) -> ModelImportSourceID {
        register(url, start: { url.startAccessingSecurityScopedResource() }, stop: { url.stopAccessingSecurityScopedResource() })
    }
    func acquire(_ id: ModelImportSourceID) async throws -> ModelImportLease {
        guard let selection = selections[id] else { throw ModelRepositoryCode.sourceUnavailable }
        guard await selection.start() else { throw ModelRepositoryCode.scopeDenied }
        do {
            let directory = try ModelPackageDirectory(url: selection.url)
            guard let selected = selection.selectedIdentity, selected.sameObject(directory.stamp) else {
                throw ModelRepositoryCode.identityChanged
            }
            return ModelImportLease(directory: directory, stop: selection.stop)
        }
        catch { await selection.stop(); throw error }
    }
    func unregister(_ id: ModelImportSourceID) { selections[id] = nil }
}
final class ModelImportLease: @unchecked Sendable {
    let directory: ModelPackageDirectory
    private let stop: @Sendable () async -> Void
    private let lock = NSLock()
    private var released = false
    init(directory: ModelPackageDirectory, stop: @escaping @Sendable () async -> Void) { self.directory = directory; self.stop = stop }
    func release() async {
        let release = lock.withLock { if released { return false }; released = true; return true }
        if release { await stop() }
    }
}
