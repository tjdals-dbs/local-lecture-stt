import Foundation

actor FileSessionRepository: SessionRepository {
    private let roots: StorageRootManager
    private let atomicWriter: AtomicFileWriter
    private let jsonlWriter: JSONLWriter
    private let diagnostics: any DiagnosticRecording

    init(roots: StorageRootManager, atomicWriter: AtomicFileWriter = AtomicFileWriter(), jsonlWriter: JSONLWriter = JSONLWriter(),
         diagnostics: any DiagnosticRecording = NoopDiagnosticRecorder()) {
        self.roots = roots
        self.atomicWriter = atomicWriter
        self.jsonlWriter = jsonlWriter
        self.diagnostics = diagnostics
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
        diagnostics.sessionEvent(record)
    }

    func appendTranscriptJournal(_ record: TranscriptJournalRecord, at location: SessionLocation) async throws {
        try verify(record.sessionId, matches: location)
        let writer = jsonlWriter
        try await withArtifact(.transcriptJournal, at: location) { try writer.append(record, to: $0) }
    }

    nonisolated func artifactOwnership(_ artifact: SessionArtifact) -> SessionArtifactOwnership { artifact.ownership }

    private func read<Document: Decodable & Sendable>(at location: SessionLocation, artifact: SessionArtifact, as type: Document.Type) async throws -> Document {
        try await withArtifact(artifact, at: location) { destination in
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw StorageError(.artifactMissing)
            }
            do {
                return try JSONDecoder().decode(Document.self, from: Data(contentsOf: destination))
            } catch DomainValidationError.unsupportedSchemaVersion {
                throw StorageError(.documentUnsupported)
            } catch {
                throw StorageError(.documentCorrupt)
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

extension FileSessionRepository: SessionRecoveryPersisting {
    /// The recovery coordinator supplies the exact document observed during its
    /// read-only pass.  Re-reading through pinned descriptors prevents a late
    /// scan from overwriting a newly created/current-process session.
    func markInterruptedForRecovery(
        at location: SessionLocation,
        expected: SessionMetadataDocument,
        updatedAt: AbsoluteTime
    ) async throws -> SessionMetadataDocument {
        let lifecycle = try SessionLifecycle(status: expected.status, captureOutcome: expected.captureOutcome)
        guard lifecycle.status == .recording || lifecycle.status == .paused else { return expected }
        let target = try lifecycle.transition(to: .interrupted)
        return try await replaceRecoveryMetadata(at: location, expected: expected, status: target.status,
                                                 outcome: target.captureOutcome, updatedAt: updatedAt)
    }

    func markPreparationAbandonedForRecovery(
        at location: SessionLocation,
        expected: SessionMetadataDocument,
        updatedAt: AbsoluteTime
    ) async throws -> SessionMetadataDocument {
        let lifecycle = try SessionLifecycle(status: expected.status, captureOutcome: expected.captureOutcome)
        guard lifecycle.status == .preparing else { return expected }
        let target = try lifecycle.transition(to: .error)
        return try await replaceRecoveryMetadata(at: location, expected: expected, status: target.status,
                                                 outcome: target.captureOutcome, updatedAt: updatedAt)
    }

    func appendRecoveryEventIfSafe(
        at location: SessionLocation, kind: SessionEventKind,
        code: String,
        message: String?,
        occurredAt: AbsoluteTime
    ) async -> String? {
        let lease: StorageRootWriteLease
        do {
            lease = try await roots.acquireWriteLease(to: location.rootID)
        } catch let error as AudioFinalizationCode {
            return "diagnostic.\(error.rawValue)"
        } catch {
            return "diagnostic.persistence"
        }
        do {
            let access = try FinalizationFileAccess(root: lease.rootURL, location: location)
            let eventPath = SessionArtifact.events.relativePath
            if try recoveryEventAlreadyRecorded(access: access, kind: kind, code: code, sessionID: location.sessionID) {
                await lease.release()
                return nil
            }
            let event = try SessionEventRecord(sessionId: location.sessionID, eventId: SessionEventID(),
                                               occurredAt: occurredAt, kind: kind,
                                               detail: SessionEventDetail(code: code, message: message))
            try jsonlWriter.append(event, to: access.url(eventPath))
            try access.validateDirectories()
            await lease.release()
            diagnostics.sessionEvent(event)
            return nil
        } catch let error as AudioFinalizationCode {
            await lease.release()
            return "diagnostic.\(error.rawValue)"
        } catch {
            await lease.release()
            return "diagnostic.persistence"
        }
    }

    private func replaceRecoveryMetadata(
        at location: SessionLocation,
        expected: SessionMetadataDocument,
        status: SessionStatus,
        outcome: CaptureOutcome,
        updatedAt: AbsoluteTime
    ) async throws -> SessionMetadataDocument {
        let lease = try await roots.acquireWriteLease(to: location.rootID)
        do {
        let access = try FinalizationFileAccess(root: lease.rootURL, location: location)
        let current = try access.readJSON(SessionMetadataDocument.self, SessionArtifact.metadata.relativePath)
        guard current == expected else { throw AudioFinalizationCode.identityChanged }
        guard current.sessionId == location.sessionID else { throw AudioFinalizationCode.invalidRequest }
        guard current.status != status || current.captureOutcome != outcome else {
            await lease.release()
            return current
        }
        let replacement = try SessionMetadataDocument(
            schemaVersion: current.schemaVersion,
            sessionId: current.sessionId,
            title: current.title,
            status: status,
            captureOutcome: outcome,
            createdAt: current.createdAt,
            recordingStartedAt: current.recordingStartedAt,
            recordingEndedAt: current.recordingEndedAt,
            activeDurationMs: current.activeDurationMs,
            languageMode: current.languageMode,
            detectedLanguage: current.detectedLanguage,
            engine: current.engine,
            model: current.model,
            modelSettings: current.modelSettings,
            audio: current.audio,
            transcript: current.transcript,
            appVersion: current.appVersion,
            osVersion: current.osVersion,
            lastUpdatedAt: updatedAt
        )
        try access.writeJSON(replacement, SessionArtifact.metadata.relativePath)
        _ = try access.readJSON(SessionMetadataDocument.self, SessionArtifact.metadata.relativePath)
        try access.validateDirectories()
        await lease.release()
        return replacement
        } catch {
            await lease.release()
            throw error
        }
    }

    /// A damaged or exceptionally long JSONL line is deliberately not healed or
    /// appended after.  The caller still resumes audio and reports this warning.
    private func recoveryEventAlreadyRecorded(
        access: FinalizationFileAccess,
        kind: SessionEventKind,
        code: String,
        sessionID: SessionID
    ) throws -> Bool {
        guard try access.identity(SessionArtifact.events.relativePath) != nil else { return false }
        let url = try access.url(SessionArtifact.events.relativePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            guard pending.count <= 262_144 else { throw AudioFinalizationCode.corruptDocument }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let record = try JSONDecoder().decode(SessionEventRecord.self, from: line)
                guard record.sessionId == sessionID else { throw AudioFinalizationCode.corruptDocument }
                if record.kind == kind, record.detail?.code == code { return true }
            }
        }
        guard pending.isEmpty else { throw AudioFinalizationCode.corruptDocument }
        try access.validateDirectories()
        return false
    }
}
