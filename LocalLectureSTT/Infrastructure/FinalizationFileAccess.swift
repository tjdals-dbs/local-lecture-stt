import CryptoKit
import Darwin
import Foundation

/// Every directory is pinned by an open descriptor. Repository mutations are
/// relative to those descriptors; the media backend validates its own owner at
/// framework suspension and writer I/O boundaries.
final class FinalizationFileAccess: @unchecked Sendable {
    let location: SessionLocation
    let directory: URL
    private let root: URL
    private let rootFD: Int32
    private let sessionFD: Int32
    private let recoveryFD: Int32
    private let directoryIdentities: [(URL, Int64, UInt64)]
    static let staging = "audio.finalizing.m4a"
    static let source = "recovery/audio.recovery.mov"
    static let canonical = "audio.m4a"
    static let checkpoint = "recovery/finalization.checkpoint.json"
    static let bufferSize = 65_536

    init(root: URL, location: SessionLocation) throws {
        guard location.folderName.matches(location.sessionID) else { throw AudioFinalizationCode.invalidRequest }
        self.location = location
        self.root = root
        directory = root.appendingPathComponent(location.folderName.rawValue, isDirectory: true)
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw AudioFinalizationCode.unsafeLayout }
        let sessionFD = openat(rootFD, location.folderName.rawValue, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard sessionFD >= 0 else { Darwin.close(rootFD); throw AudioFinalizationCode.unsafeLayout }
        let recoveryFD = openat(sessionFD, "recovery", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard recoveryFD >= 0 else {
            Darwin.close(sessionFD); Darwin.close(rootFD); throw AudioFinalizationCode.unsafeLayout
        }
        self.rootFD = rootFD
        self.sessionFD = sessionFD
        self.recoveryFD = recoveryFD
        var identities: [(URL, Int64, UInt64)] = []
        for (url, fd) in [(root, rootFD), (directory, sessionFD), (directory.appendingPathComponent("recovery"), recoveryFD)] {
            var info = stat()
            fstat(fd, &info)
            identities.append((url, Int64(info.st_dev), UInt64(info.st_ino)))
        }
        directoryIdentities = identities
        try validateDirectories()
    }

    deinit { Darwin.close(recoveryFD); Darwin.close(sessionFD); Darwin.close(rootFD) }

    func validateDirectories() throws {
        for (url, device, inode) in directoryIdentities {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  Int64(info.st_dev) == device, UInt64(info.st_ino) == inode else {
                throw AudioFinalizationCode.identityChanged
            }
        }
    }

    func url(_ path: String) throws -> URL {
        _ = try parent(path)
        try validateDirectories()
        _ = try identity(path)
        return directory.appendingPathComponent(path)
    }

    fileprivate func parent(_ path: String) throws -> (Int32, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains("") else {
            throw AudioFinalizationCode.unsafeLayout
        }
        if parts.count == 1 { return (sessionFD, String(parts[0])) }
        if parts.count == 2, parts[0] == "recovery" { return (recoveryFD, String(parts[1])) }
        throw AudioFinalizationCode.unsafeLayout
    }

    func identity(_ path: String) throws -> FinalizationFileEvidence? {
        try validateDirectories()
        let (fd, name) = try parent(path)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw AudioFinalizationCode.storageAccess
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AudioFinalizationCode.unsafeLayout }
        return evidence(path, info, sha256: "")
    }

    private func evidence(_ path: String, _ info: stat, sha256: String) -> FinalizationFileEvidence {
        .init(relativePath: path, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
              byteCount: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
              modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), changedSeconds: Int64(info.st_ctimespec.tv_sec),
              changedNanoseconds: Int64(info.st_ctimespec.tv_nsec), sha256: sha256)
    }

    func fingerprint(_ path: String) throws -> FinalizationFileEvidence {
        guard let before = try identity(path) else { throw AudioFinalizationCode.sourceMissing }
        let (parentFD, name) = try parent(path)
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioFinalizationCode.sourceUnreadable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, evidence(path, info, sha256: "") == before else {
            throw AudioFinalizationCode.identityChanged
        }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw AudioFinalizationCode.sourceUnreadable }
            if count == 0 { break }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        }
        guard try identity(path) == before else { throw AudioFinalizationCode.identityChanged }
        return evidence(path, info, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func verify(_ expected: FinalizationFileEvidence, contents: Bool = false) throws {
        let current = try contents ? fingerprint(expected.relativePath) : identity(expected.relativePath)
        guard let current, current.device == expected.device, current.inode == expected.inode,
              current.byteCount == expected.byteCount, current.modifiedSeconds == expected.modifiedSeconds,
              current.modifiedNanoseconds == expected.modifiedNanoseconds,
              current.changedSeconds == expected.changedSeconds, current.changedNanoseconds == expected.changedNanoseconds,
              !contents || current.sha256 == expected.sha256 else { throw AudioFinalizationCode.identityChanged }
    }

    func readJSON<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
        guard let before = try identity(path), before.byteCount <= 16 * 1_024 * 1_024 else {
            throw AudioFinalizationCode.corruptDocument
        }
        let (parentFD, name) = try parent(path)
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioFinalizationCode.storageAccess }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        try verify(before)
        do { return try JSONDecoder().decode(type, from: data) }
        catch DomainValidationError.unsupportedSchemaVersion { throw AudioFinalizationCode.unsupportedSchema }
        catch { throw AudioFinalizationCode.corruptDocument }
    }

    func writeJSON<T: Encodable>(_ value: T, _ path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeData(encoder.encode(value), path)
    }

    /// Descriptor-bound reads also cover JSONL. The callback can check explicit
    /// cancellation between bounded reads, without imposing a session-length cap.
    func readChunks(_ path: String, consume: (Data) throws -> Void) throws {
        guard let before = try identity(path) else { throw AudioFinalizationCode.sourceMissing }
        let (parentFD, name) = try parent(path)
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioFinalizationCode.storageAccess }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, evidence(path, opened, sha256: "") == before else {
            throw AudioFinalizationCode.identityChanged
        }
        while let chunk = try handle.read(upToCount: Self.bufferSize), !chunk.isEmpty { try consume(chunk) }
        try verify(before)
    }

    func readData(_ path: String, control: AudioFinalizationControl) throws -> Data {
        var result = Data()
        try readChunks(path) { chunk in try control.check(); result.append(chunk) }
        return result
    }

    func writeData(_ data: Data, _ path: String) throws {
        try validateDirectories()
        let before = try identity(path)
        let (fd, name) = try parent(path)
        let temp = ".t08-\(UUID().uuidString).tmp"
        let fileFD = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fileFD >= 0 else { throw Self.ioCode(.persistence) }
        var renamed = false
        defer { if !renamed { unlinkat(fd, temp, 0) } }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard try identity(path) == before else { throw AudioFinalizationCode.identityChanged }
            guard renameat(fd, temp, fd, name) == 0 else { throw Self.ioCode(.persistence) }
            renamed = true
            guard fsync(fd) == 0 else { throw Self.ioCode(.flush) }
        } catch {
            try? handle.close()
            if let code = error as? AudioFinalizationCode { throw code }
            throw Self.errorCode(error, fallback: .persistence)
        }
    }

    func sync(_ path: String) throws {
        let before = try identity(path)
        let (fd, name) = try parent(path)
        let fileFD = openat(fd, name, O_RDONLY | O_NOFOLLOW)
        guard fileFD >= 0 else { throw Self.ioCode(.flush) }
        defer { Darwin.close(fileFD) }
        guard fsync(fileFD) == 0, fsync(fd) == 0 else { throw Self.ioCode(.flush) }
        guard try identity(path) == before else { throw AudioFinalizationCode.identityChanged }
    }

    func moveExclusive(_ from: String, to: String, expected: FinalizationFileEvidence) throws {
        try verify(expected)
        guard try identity(to) == nil else { throw AudioFinalizationCode.canonicalConflict }
        let (fromFD, fromName) = try parent(from)
        let (toFD, toName) = try parent(to)
        guard renameatx_np(fromFD, fromName, toFD, toName, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.ioCode(.publication)
        }
        guard fsync(fromFD) == 0, fsync(toFD) == 0 else { throw Self.ioCode(.flush) }
    }

    func removeSource(expected: FinalizationFileEvidence) throws {
        guard expected.relativePath == Self.source else { throw AudioFinalizationCode.completionEvidence }
        try verify(expected, contents: true)
        guard unlinkat(recoveryFD, "audio.recovery.mov", 0) == 0 else { throw Self.ioCode(.persistence) }
    }
    func syncRecoveryDirectory() throws {
        guard fsync(recoveryFD) == 0 else { throw Self.ioCode(.flush) }
    }

    static func ioCode(_ fallback: AudioFinalizationCode) -> AudioFinalizationCode { errno == ENOSPC ? .diskFull : fallback }
    static func errorCode(_ error: Error, fallback: AudioFinalizationCode) -> AudioFinalizationCode {
        if let code = error as? AudioFinalizationCode { return code }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) ||
            (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) { return .diskFull }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return errorCode(underlying, fallback: fallback) }
        return fallback
    }
}

/// Infrastructure-only ownership for a remux. The backend must revalidate this
/// owner after framework awaits and before opening/starting/feeding the writer.
/// Open source/output descriptors keep inode ownership through writer cleanup;
/// URLs alone are never accepted as authorization to continue media I/O.
final class FinalizationMediaFiles: @unchecked Sendable {
    private let sourceAccess: FinalizationFileAccess
    private let destinationAccess: FinalizationFileAccess
    private let sourceEvidence: FinalizationFileEvidence
    private let sourceFD: Int32
    private let destinationParentFD: Int32
    private let destinationName: String
    private var outputFD: Int32 = -1
    let sourceURL: URL
    let destinationURL: URL

    init(source: FinalizationFileAccess, destination: FinalizationFileAccess,
         expectedSource: FinalizationFileEvidence? = nil,
         destinationPath: String = FinalizationFileAccess.staging) throws {
        guard let evidence = try expectedSource ?? source.identity(FinalizationFileAccess.source),
              evidence.relativePath == FinalizationFileAccess.source else {
            throw AudioFinalizationCode.sourceMissing
        }
        let (parent, name) = try source.parent(FinalizationFileAccess.source)
        let (destinationFD, destinationName) = try destination.parent(destinationPath)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioFinalizationCode.sourceUnreadable }
        let inputURL: URL, outputURL: URL
        do {
            inputURL = try source.url(FinalizationFileAccess.source)
            outputURL = try destination.url(destinationPath)
            try source.verify(evidence)
            var opened = stat()
            guard fstat(fd, &opened) == 0, Int64(opened.st_dev) == evidence.device,
                  UInt64(opened.st_ino) == evidence.inode else { throw AudioFinalizationCode.identityChanged }
            guard try destination.identity(destinationPath) == nil else { throw AudioFinalizationCode.canonicalConflict }
        } catch { Darwin.close(fd); throw error }
        sourceAccess = source; destinationAccess = destination; sourceEvidence = evidence
        sourceFD = fd; destinationParentFD = destinationFD; self.destinationName = destinationName
        sourceURL = inputURL; destinationURL = outputURL
    }

    deinit {
        if outputFD >= 0 { Darwin.close(outputFD) }
        Darwin.close(sourceFD)
    }

    /// Called immediately after startWriting creates the output, before any seam/await.
    func bindOutput() throws {
        guard outputFD < 0 else { throw AudioFinalizationCode.identityChanged }
        let fd = openat(destinationParentFD, destinationName, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioFinalizationCode.exportCreate }
        outputFD = fd
        try validate()
    }

    func validate() throws {
        try sourceAccess.verify(sourceEvidence)
        try destinationAccess.validateDirectories()
        var original = stat()
        guard fstat(sourceFD, &original) == 0,
              Int64(original.st_dev) == sourceEvidence.device, UInt64(original.st_ino) == sourceEvidence.inode,
              original.st_size == sourceEvidence.byteCount,
              Int64(original.st_mtimespec.tv_sec) == sourceEvidence.modifiedSeconds,
              Int64(original.st_mtimespec.tv_nsec) == sourceEvidence.modifiedNanoseconds,
              Int64(original.st_ctimespec.tv_sec) == sourceEvidence.changedSeconds,
              Int64(original.st_ctimespec.tv_nsec) == sourceEvidence.changedNanoseconds else {
            throw AudioFinalizationCode.identityChanged
        }
        var current = stat()
        let exists = fstatat(destinationParentFD, destinationName, &current, AT_SYMLINK_NOFOLLOW) == 0
        if outputFD < 0 {
            guard !exists, errno == ENOENT else { throw AudioFinalizationCode.identityChanged }
        } else {
            var pinned = stat()
            guard exists, fstat(outputFD, &pinned) == 0,
                  current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino else {
                throw AudioFinalizationCode.identityChanged
            }
        }
    }
}
