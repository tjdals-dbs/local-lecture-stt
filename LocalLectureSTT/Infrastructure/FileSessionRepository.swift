import Foundation

actor FileSessionRepository: SessionRepository {
    private let roots: StorageRootManager
    private let atomicWriter: AtomicFileWriter
    private let jsonlWriter: JSONLWriter

    init(roots: StorageRootManager, atomicWriter: AtomicFileWriter = AtomicFileWriter(), jsonlWriter: JSONLWriter = JSONLWriter()) {
        self.roots = roots
        self.atomicWriter = atomicWriter
        self.jsonlWriter = jsonlWriter
    }

    func createSession(sessionID: SessionID, createdAt: AbsoluteTime, timeZone: TimeZone) async throws -> SessionLocation {
        let rootID = try await roots.activeRootID()
        let folderName = SessionFolderName(sessionID: sessionID, createdAt: createdAt, timeZone: timeZone)
        let location = SessionLocation(rootID: rootID, sessionID: sessionID, folderName: folderName)
        try await roots.withAccess(to: rootID) { root in
            let directory = root.appendingPathComponent(folderName.rawValue, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw StorageError(.sessionDirectoryCollision) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("recovery", isDirectory: true), withIntermediateDirectories: false)
            } catch let error as StorageError {
                throw error
            } catch {
                throw StorageError(.sessionLayoutCreationFailed)
            }
        }
        return location
    }

    func writeMetadata(_ document: SessionMetadataDocument, at location: SessionLocation) async throws {
        try verify(document.sessionId, matches: location)
        let writer = atomicWriter
        try await withArtifact(.metadata, at: location) { try writer.writeJSON(document, to: $0) }
    }

    func readMetadata(at location: SessionLocation) async throws -> SessionMetadataDocument {
        try await read(at: location, artifact: .metadata, as: SessionMetadataDocument.self)
    }

    func writeTranscript(_ document: TranscriptDocument, at location: SessionLocation) async throws {
        try verify(document.sessionId, matches: location)
        let writer = atomicWriter
        try await withArtifact(.transcript, at: location) { try writer.writeJSON(document, to: $0) }
    }

    func readTranscript(at location: SessionLocation) async throws -> TranscriptDocument {
        try await read(at: location, artifact: .transcript, as: TranscriptDocument.self)
    }

    func writeFinalizationCheckpoint(_ document: FinalizationCheckpointDocument, at location: SessionLocation) async throws {
        try verify(document.sessionId, matches: location)
        let writer = atomicWriter
        try await withArtifact(.finalizationCheckpoint, at: location) { try writer.writeJSON(document, to: $0) }
    }

    func readFinalizationCheckpoint(at location: SessionLocation) async throws -> FinalizationCheckpointDocument {
        try await read(at: location, artifact: .finalizationCheckpoint, as: FinalizationCheckpointDocument.self)
    }

    func appendEvent(_ record: SessionEventRecord, at location: SessionLocation) async throws {
        try verify(record.sessionId, matches: location)
        let writer = jsonlWriter
        try await withArtifact(.events, at: location) { try writer.append(record, to: $0) }
    }

    func appendTranscriptJournal(_ record: TranscriptJournalRecord, at location: SessionLocation) async throws {
        try verify(record.sessionId, matches: location)
        let writer = jsonlWriter
        try await withArtifact(.transcriptJournal, at: location) { try writer.append(record, to: $0) }
    }

    nonisolated func artifactOwnership(_ artifact: SessionArtifact) -> SessionArtifactOwnership { artifact.ownership }

    private func read<Document: Decodable & Sendable>(at location: SessionLocation, artifact: SessionArtifact, as type: Document.Type) async throws -> Document {
        try await withArtifact(artifact, at: location) { destination in
            do {
                return try JSONDecoder().decode(Document.self, from: Data(contentsOf: destination))
            } catch CocoaError.fileNoSuchFile {
                throw StorageError(.artifactMissing)
            } catch {
                throw StorageError(.jsonDecodeFailed)
            }
        }
    }

    private func withArtifact<Value: Sendable>(_ artifact: SessionArtifact, at location: SessionLocation, operation: @Sendable (URL) throws -> Value) async throws -> Value {
        try await roots.withAccess(to: location.rootID) { root in
            let sessionDirectory = root.appendingPathComponent(location.folderName.rawValue, isDirectory: true)
            let candidate = sessionDirectory.appendingPathComponent(artifact.relativePath, isDirectory: false).standardizedFileURL
            guard candidate.path.hasPrefix(sessionDirectory.standardizedFileURL.path + "/") else { throw StorageError(.sessionLayoutCreationFailed) }
            return try operation(candidate)
        }
    }

    private func verify(_ sessionID: SessionID, matches location: SessionLocation) throws {
        guard sessionID == location.sessionID else { throw StorageError(.sessionIDMismatch) }
    }

}
