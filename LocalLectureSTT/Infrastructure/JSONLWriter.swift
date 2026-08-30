import Foundation

struct JSONLWriter: Sendable {
    func append<Record: Encodable>(_ record: Record, to destination: URL) throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(record)
        } catch {
            throw StorageError(.jsonEncodeFailed)
        }
        guard !encoded.contains(0x0A), !encoded.contains(0x0D) else {
            throw StorageError(.jsonEncodeFailed)
        }
        var line = encoded
        line.append(0x0A)

        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw StorageError(.jsonlAppendFailed)
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                throw StorageError(.jsonlAppendFailed)
            }
            do {
                try handle.synchronize()
            } catch {
                throw StorageError(.jsonlFlushFailed)
            }
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError(.jsonlAppendFailed)
        }
    }
}
