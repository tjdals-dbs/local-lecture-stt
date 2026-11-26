import Darwin
import Foundation

struct DiagnosticRetentionPolicy: Sendable {
    let maximumBytes: Int64
    let maximumAge: TimeInterval
    let fileBytes: Int64
    let pendingLimit: Int
    init(maximumBytes: Int64 = 100_000_000, maximumAge: TimeInterval = 30 * 86_400,
         fileBytes: Int64 = 1_000_000, pendingLimit: Int = 256) throws {
        guard maximumBytes > 0, maximumBytes <= 100_000_000, maximumAge > 0, maximumAge <= 30 * 86_400,
              fileBytes > 0, fileBytes <= maximumBytes, pendingLimit > 0, pendingLimit <= 256 else {
            throw DiagnosticFailure.invalidPolicy
        }
        self.maximumBytes = maximumBytes; self.maximumAge = maximumAge
        self.fileBytes = fileBytes; self.pendingLimit = pendingLimit
    }
}

/// All file work and management operations share one utility queue. Audio callers
/// only admit a small enum record to a bounded queue. Failures never escape record().
final class LocalDiagnosticLog: DiagnosticRecording, DiagnosticManaging, @unchecked Sendable {
    private let directory: URL
    private let policy: DiagnosticRetentionPolicy
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "LocalLectureSTT.diagnostics", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    private var dropped: UInt64 = 0
    // The following fields are only accessed on queue.
    private var active: String?
    private var failure: DiagnosticFailure?
    private let beforeWrite: @Sendable () throws -> Void
    private let beforeExportPublish: @Sendable () throws -> Void

    init(directory: URL, policy: DiagnosticRetentionPolicy = try! .init(),
         now: @escaping @Sendable () -> Date = { Date() },
         beforeWrite: @escaping @Sendable () throws -> Void = {},
         beforeExportPublish: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory; self.policy = policy
        self.now = now; self.beforeWrite = beforeWrite
        self.beforeExportPublish = beforeExportPublish
    }
    static func live() -> LocalDiagnosticLog {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support = (try? canonicalDirectory(base)) ?? base
        return .init(directory: support.appendingPathComponent("LocalLectureSTT/Diagnostics", isDirectory: true))
    }
    /// Only for a trusted existing base (OS app support or the user's selected
    /// export folder). Foundation standardization can turn /private/var back
    /// into the /var symlink, so retain realpath's spelling through openat.
    static func canonicalDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, let path = realpath(url.path, nil) else { throw DiagnosticFailure.storage }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    func record(_ entry: DiagnosticEntry) {
        admission.lock()
        guard pending < policy.pendingLimit else { dropped &+= 1; admission.unlock(); return }
        pending += 1
        queue.async { [self] in
            defer { admission.withLock { pending -= 1 } }
            do { try beforeWrite(); try append(entry); failure = nil }
            catch {
                active = nil
                failure = (error as? DiagnosticFailure) ?? .storage
                admission.withLock { dropped &+= 1 }
            }
        }
        admission.unlock()
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    func summary() async throws -> DiagnosticSummary {
        try await perform { [self] in
            let fd = try openDirectory(); defer { close(fd) }
            let files = try prune(fd)
            return .init(fileCount: files.count, bytes: files.reduce(0) { $0 + $1.size },
                         droppedEntries: admission.withLock { dropped }, lastFailure: failure)
        }
    }
    func clear() async throws {
        try await perform { [self] in
            let fd = try openDirectory(); defer { close(fd) }
            for file in try list(fd) { try remove(file, fd) }
            active = nil; failure = nil
            guard fsync(fd) == 0 else { throw DiagnosticFailure.storage }
        }
    }
    /// Returns only the private app-log directory, never a session root.
    func directoryForReveal() async throws -> URL {
        _ = try await summary()
        return directory
    }
    func export(to destination: URL, cancellation: DiagnosticCancellation = .init()) async throws {
        try await perform { [self] in
            try cancellation.check()
            let source = try openDirectory(); defer { close(source) }
            let files = try prune(source)
            let name = destination.lastPathComponent
            guard destination.isFileURL, destination.pathExtension.lowercased() == "jsonl",
                  name.lowercased() != "events.jsonl", !name.lowercased().hasPrefix("transcript") else {
                throw DiagnosticFailure.exportFailed
            }
            let parent = try Self.openPath(destination.deletingLastPathComponent(), create: false)
            defer { close(parent) }
            var a = stat(), b = stat()
            guard fstat(source, &a) == 0, fstat(parent, &b) == 0,
                  a.st_dev != b.st_dev || a.st_ino != b.st_ino else { throw DiagnosticFailure.unsafeLayout }
            var existing = stat()
            guard fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw DiagnosticFailure.destinationExists
            }
            let temporary = ".diagnostic-export-\(UUID().uuidString).partial"
            let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw DiagnosticFailure.exportFailed }
            defer { close(output); unlinkat(parent, temporary, 0) }
            for file in files {
                try cancellation.check()
                let input = try openFile(file, source, flags: O_RDONLY); defer { close(input) }
                var pending = Data(), total: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 8_192)
                while true {
                    try cancellation.check()
                    let count = read(input, &buffer, buffer.count)
                    if count < 0 { if errno == EINTR { continue }; throw DiagnosticFailure.exportFailed }
                    if count == 0 { break }
                    total += Int64(count)
                    guard total <= file.size else { throw DiagnosticFailure.unsafeLayout }
                    pending.append(contentsOf: buffer.prefix(count))
                    while let end = pending.firstIndex(of: 0x0A) {
                        guard end <= 4_096 else { throw DiagnosticFailure.corruptLog }
                        let decoded: DiagnosticEntry
                        do { decoded = try JSONDecoder().decode(DiagnosticEntry.self, from: pending.prefix(upTo: end)) }
                        catch { throw DiagnosticFailure.corruptLog }
                        guard decoded.schemaVersion == 1 else { throw DiagnosticFailure.corruptLog }
                        // Re-encode the closed schema; unknown fields in modified
                        // log files must never be copied into an exported report.
                        var line = try JSONEncoder().encode(decoded); line.append(0x0A)
                        try Self.write(line, output)
                        pending.removeSubrange(...end)
                    }
                    guard pending.count <= 4_096 else { throw DiagnosticFailure.corruptLog }
                }
                guard pending.isEmpty, total == file.size else { throw DiagnosticFailure.corruptLog }
            }
            try cancellation.check()
            guard fsync(output) == 0 else { throw DiagnosticFailure.exportFailed }
            try beforeExportPublish(); try cancellation.check()
            // Exclusive publication also protects a destination created while
            // the export was running. Never overwrite even after a Save dialog.
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? DiagnosticFailure.destinationExists : .exportFailed
            }
            guard fsync(parent) == 0 else { throw DiagnosticFailure.exportFailed }
        }
    }

    private struct File {
        let name: String
        let created: Date
        let size: Int64
        let device: dev_t
        let inode: ino_t
    }
    private func append(_ entry: DiagnosticEntry) throws {
        let fd = try openDirectory(); defer { close(fd) }
        let files = try prune(fd)
        var data = try JSONEncoder().encode(entry); data.append(0x0A)
        guard data.count <= 4_096, data.count <= policy.fileBytes else { throw DiagnosticFailure.storage }
        let current = files.first { $0.name == active && $0.size + Int64(data.count) <= policy.fileBytes }
        let output: Int32
        if let current { output = try openFile(current, fd, flags: O_WRONLY | O_APPEND) }
        else {
            let stamp = Int64(max(0, now().timeIntervalSince1970 * 1_000))
            let name = "log-\(stamp)-\(UUID().uuidString).jsonl"
            output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw DiagnosticFailure.storage }
            active = name
        }
        defer { close(output) }
        try Self.write(data, output)
        guard fsync(output) == 0 else { throw DiagnosticFailure.storage }
        _ = try prune(fd)
    }
    private func openDirectory() throws -> Int32 {
        let fd = try Self.openPath(directory, create: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { close(fd); throw DiagnosticFailure.unsafeLayout }
        return fd
    }
    /// Search ancestors without listing them; Sandbox authorizes the log subtree.
    /// Refuse symlinks at every component and read only the final directory.
    private static func openPath(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw DiagnosticFailure.unsafeLayout }
        let components = url.path.split(separator: "/").map(String.init)
        var fd = open("/", (components.isEmpty ? O_RDONLY | O_DIRECTORY : O_SEARCH) | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DiagnosticFailure.storage }
        do {
            for (index, component) in components.enumerated() {
                guard component != ".", component != ".." else { throw DiagnosticFailure.unsafeLayout }
                let mode = (index == components.count - 1 ? O_RDONLY | O_DIRECTORY : O_SEARCH) | O_NOFOLLOW | O_CLOEXEC
                var next = openat(fd, component, mode)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw DiagnosticFailure.storage }
                    next = openat(fd, component, mode)
                }
                guard next >= 0 else { throw DiagnosticFailure.unsafeLayout }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func list(_ fd: Int32) throws -> [File] {
        let copy = dup(fd)
        guard copy >= 0 else { throw DiagnosticFailure.storage }
        guard let directory = fdopendir(copy) else { close(copy); throw DiagnosticFailure.storage }
        defer { closedir(directory) }
        rewinddir(directory)
        var files: [File] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw DiagnosticFailure.storage }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1_024) { String(cString: $0) }
            }
            guard name.hasPrefix("log-"), name.hasSuffix(".jsonl") else { continue }
            let body = name.dropFirst(4).dropLast(6)
            guard let dash = body.firstIndex(of: "-"),
                  let milliseconds = Int64(body[..<dash]), milliseconds >= 0,
                  UUID(uuidString: String(body[body.index(after: dash)...])) != nil else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  info.st_uid == getuid(), info.st_size >= 0 else { throw DiagnosticFailure.unsafeLayout }
            files.append(.init(name: name, created: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                               size: info.st_size, device: info.st_dev, inode: info.st_ino))
        }
        return files.sorted { $0.created == $1.created ? $0.name < $1.name : $0.created < $1.created }
    }
    private func prune(_ fd: Int32) throws -> [File] {
        let cutoff = now().addingTimeInterval(-policy.maximumAge)
        var retained: [File] = []
        var total: Int64 = 0
        for file in try list(fd) {
            if file.created <= cutoff { try remove(file, fd) }
            else {
                let sum = total.addingReportingOverflow(file.size)
                guard !sum.overflow else { throw DiagnosticFailure.storage }
                total = sum.partialValue; retained.append(file)
            }
        }
        while total > policy.maximumBytes, !retained.isEmpty {
            let file = retained.removeFirst(); try remove(file, fd); total -= file.size
        }
        return retained
    }
    private func remove(_ file: File, _ directory: Int32) throws {
        let fd = try openFile(file, directory, flags: O_RDONLY); defer { close(fd) }
        guard unlinkat(directory, file.name, 0) == 0 else { throw DiagnosticFailure.storage }
        if active == file.name { active = nil }
    }
    private func openFile(_ file: File, _ directory: Int32, flags: Int32) throws -> Int32 {
        let fd = openat(directory, file.name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DiagnosticFailure.unsafeLayout }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_dev == file.device, info.st_ino == file.inode, info.st_size == file.size else {
            close(fd); throw DiagnosticFailure.unsafeLayout
        }
        return fd
    }
    private static func write(_ data: Data, _ fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticFailure.storage }
                offset += count
            }
        }
    }
}
