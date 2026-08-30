import Darwin
import Foundation

enum AtomicWriteStep: Sendable, Equatable {
    case afterTemporaryCreate(temporaryPath: String)
    case beforeWrite
    case beforeFlush
    case beforeRename
}

struct AtomicFileWriter: Sendable {
    private let fault: @Sendable (AtomicWriteStep) throws -> Void

    init(fault: @escaping @Sendable (AtomicWriteStep) throws -> Void = { _ in }) {
        self.fault = fault
    }

    func writeJSON<Value: Encodable>(_ value: Value, to destination: URL) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw StorageError(.jsonEncodeFailed)
        }
        try write(data, to: destination)
    }

    func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".local-lecture-stt-\(UUID().uuidString).tmp", isDirectory: false)
        var shouldCleanTemporary = false
        defer {
            if shouldCleanTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StorageError(.temporaryCreateFailed) }
        shouldCleanTemporary = true
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try fault(.afterTemporaryCreate(temporaryPath: temporary.path))
            do {
                try fault(.beforeWrite)
                try handle.write(contentsOf: data)
            } catch {
                try? handle.close()
                throw StorageError(.temporaryWriteFailed)
            }
            do {
                try fault(.beforeFlush)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw StorageError(.temporaryFlushFailed)
            }
        } catch let error as StorageError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw StorageError(.temporaryWriteFailed)
        }

        do {
            try fault(.beforeRename)
        } catch {
            throw StorageError(.atomicRenameFailed)
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw StorageError(.atomicRenameFailed)
        }
        shouldCleanTemporary = false
        try synchronizeDirectory(directory)
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw StorageError(.atomicRenameFailed) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw StorageError(.atomicRenameFailed) }
    }
}
