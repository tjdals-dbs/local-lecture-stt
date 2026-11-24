import Foundation

/// All hooks are infrastructure-only side-effect boundaries for crash-window tests.
enum TranscriptWritePoint: String, Sendable, CaseIterable {
    case opened, beforeCanonical, afterCanonical, beforeText, afterText, beforeMarkdown, afterMarkdown
    case beforeMetadata, afterMetadata, beforeCatalog, afterCatalog, beforeCheckpoint
}

actor FileTranscriptRepository: TranscriptFinalizing, TranscriptEditing, RemainingFinalizationVerifying {
    private let roots: StorageRootManager
    private let catalog: any RecordingCatalogRefreshing
    private let hook: @Sendable (TranscriptWritePoint) async throws -> Void
    private var active = Set<String>()

    init(roots: StorageRootManager, catalog: any RecordingCatalogRefreshing,
         hook: @escaping @Sendable (TranscriptWritePoint) async throws -> Void = { _ in }) {
        self.roots = roots; self.catalog = catalog; self.hook = hook
    }

    func finalize(at location: SessionLocation, audio: AudioFinalizationResult,
                  control: AudioFinalizationControl) async throws -> [FinalizationStep] {
        try await transaction(at: location, control: control, requiresWrite: false) { [roots] run in
            guard audio.location == location, audio.failure == nil, let final = audio.final,
                  let report = audio.media else { throw AudioFinalizationCode.completionEvidence }
            try run.files.verify(final, contents: true)
            if let source = audio.source { try run.files.verify(source, contents: true) }
            guard run.checkpoint.completedSteps.contains(.finalM4AVerified),
                  [.finalizing, .completed, .interrupted].contains(run.metadata.status),
                  [.completed, .interrupted].contains(run.metadata.captureOutcome) else {
                throw TranscriptFailure(code: .notFinalized)
            }
            let duration = run.metadata.captureOutcome == .interrupted
                ? try MediaMilliseconds(Int64((report.durationSeconds * 1_000).rounded(.up)))
                : run.metadata.activeDurationMs
            let existing = try run.canonical()
            if run.checkpoint.completedSteps.contains(.transcriptCompacted), existing == nil {
                throw TranscriptFailure(code: .missingCanonical)
            }
            let journal = try run.journal()
            if existing == nil, journal.isEmpty, run.metadata.transcript.segmentCount.rawValue > 0 {
                throw TranscriptFailure(code: .missingCanonical)
            }
            let document = try TranscriptCanonical.compact(sessionID: location.sessionID, journal: journal,
                                                           existing: existing, duration: duration)
            let metadata = try run.completedMetadata(count: document.segments.count, duration: duration)
            if document == existing, metadata == run.metadata,
               run.checkpoint.completedSteps.contains(.catalogUpdated),
               try run.derivedFilesMatch(document, metadata: metadata) {
                // A healthy terminal session needs no session-file writes,
                // even if its historical root is now read-only.
                try await run.refreshCatalog()
                return run.checkpoint.completedSteps
            }
            // Keep the read scope, operation ownership and observations pinned
            // during permission acquisition. Never mutate based on stale reads.
            let writeLease: StorageRootWriteLease
            do { writeLease = try await roots.acquireWriteLease(to: location.rootID) }
            catch let error as StorageError where error.code == .rootNotWritable {
                throw TranscriptFailure(code: .repairRequired)
            }
            do {
                try run.validate()
                guard writeLease.rootURL.standardizedFileURL == run.files.directory.deletingLastPathComponent().standardizedFileURL else {
                    throw AudioFinalizationCode.identityChanged
                }
                if document != existing { try await run.writeCanonical(document) }
                try await run.mark(.transcriptCompacted)
                try await run.publish(document, metadata: metadata)
                try run.validate()
                await writeLease.release()
                return run.checkpoint.completedSteps
            } catch {
                await writeLease.release()
                throw error
            }
        }
    }

    func regenerate(at location: SessionLocation) async throws -> TranscriptDocument {
        try await edit(at: location, mutation: { $0 })
    }

    func updateText(at location: SessionLocation, segmentID: TranscriptSegmentID,
                    expectedText: String, text: String) async throws -> TranscriptDocument {
        try await edit(at: location) { document in
            var segments = document.segments
            guard let index = segments.firstIndex(where: { $0.id == segmentID }) else {
                throw TranscriptFailure(code: .segmentMissing)
            }
            // Repeating a saved edit after derived-file failure is safe.
            guard segments[index].text == expectedText || segments[index].text == text else {
                throw TranscriptFailure(code: .editConflict)
            }
            segments[index].text = text
            return try TranscriptDocument(sessionId: document.sessionId, segments: segments)
        }
    }

    private func edit(at location: SessionLocation,
                      mutation: @Sendable (TranscriptDocument) throws -> TranscriptDocument) async throws -> TranscriptDocument {
        try await transaction(at: location, control: .init()) { run in
            guard run.checkpoint.completedSteps.contains(.metadataCompleted),
                  (run.metadata.status == .completed && run.metadata.captureOutcome == .completed) ||
                  (run.metadata.status == .interrupted && run.metadata.captureOutcome == .interrupted) else {
                throw TranscriptFailure(code: .notFinalized)
            }
            guard let original = try run.canonical() else { throw TranscriptFailure(code: .missingCanonical) }
            try TranscriptCanonical.validate(original, sessionID: location.sessionID, duration: run.metadata.activeDurationMs)
            let changed = try mutation(original)
            if changed != original { try await run.writeCanonical(changed) }
            let metadata = try run.completedMetadata(count: changed.segments.count, duration: run.metadata.activeDurationMs,
                                                     edited: changed != original)
            try await run.publish(changed, metadata: metadata)
            return changed
        }
    }

    /// T08 proof issuance can use this independent read-back verifier. It does
    /// not infer completion from checkpoint booleans or caller-supplied hashes.
    func verify(location: SessionLocation, files expected: [FinalizationFileEvidence]) async throws -> CatalogProjection {
        try await transaction(at: location, control: .init(), requiresWrite: false) { run in
            for file in expected { try run.files.verify(file, contents: true) }
            guard run.checkpoint.completedSteps.contains(.catalogUpdated),
                  let document = try run.canonical() else { throw AudioFinalizationCode.completionEvidence }
            let rendered = try TranscriptRenderer.render(document, metadata: run.metadata)
            guard document.segments.count == run.metadata.transcript.segmentCount.rawValue,
                  try run.files.readData("transcript.txt", control: run.control) == rendered.text,
                  try run.files.readData("transcript.md", control: run.control) == rendered.markdown else {
                throw AudioFinalizationCode.completionEvidence
            }
            try await run.refreshCatalog()
            for file in expected { try run.files.verify(file, contents: true) }
            return CatalogProjection(metadata: run.metadata, location: location)
        }
    }

    private func transaction<T: Sendable>(at location: SessionLocation, control: AudioFinalizationControl,
                                          requiresWrite: Bool = true,
                                          body: (TranscriptFileTransaction) async throws -> T) async throws -> T {
        let key = "\(location.rootID.rawValue)/\(location.sessionID.rawValue)"
        guard active.insert(key).inserted else { throw TranscriptFailure(code: .busy) }
        defer { active.remove(key) }
        try control.check()
        let lease: StorageRootWriteLease
        if requiresWrite { lease = try await roots.acquireWriteLease(to: location.rootID) }
        else { lease = try await roots.acquireReadLease(to: location.rootID) }
        do {
            try control.check()
            let run = try TranscriptFileTransaction(files: FinalizationFileAccess(root: lease.rootURL, location: location),
                                                     control: control, catalog: catalog, hook: hook)
            try await run.reach(.opened)
            let result = try await body(run)
            try run.validate()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
}

private final class TranscriptFileTransaction {
    let files: FinalizationFileAccess
    let control: AudioFinalizationControl
    let catalog: any RecordingCatalogRefreshing
    let hook: @Sendable (TranscriptWritePoint) async throws -> Void
    var metadata: SessionMetadataDocument
    var checkpoint: FinalizationCheckpointDocument
    private enum Observation { case absent, present(FinalizationFileEvidence) }
    private var observations: [String: Observation] = [:]

    init(files: FinalizationFileAccess, control: AudioFinalizationControl, catalog: any RecordingCatalogRefreshing,
         hook: @escaping @Sendable (TranscriptWritePoint) async throws -> Void) throws {
        self.files = files; self.control = control; self.catalog = catalog; self.hook = hook
        let metadataBefore = try files.identity("metadata.json")
        let checkpointBefore = try files.identity(FinalizationFileAccess.checkpoint)
        metadata = try files.readJSON(SessionMetadataDocument.self, "metadata.json")
        checkpoint = try files.readJSON(FinalizationCheckpointDocument.self, FinalizationFileAccess.checkpoint)
        guard metadata.sessionId == files.location.sessionID, checkpoint.sessionId == files.location.sessionID else {
            throw TranscriptFailure(code: .sessionMismatch)
        }
        for path in ["metadata.json", FinalizationFileAccess.checkpoint, "transcript.json", "transcript.txt", "transcript.md",
                     SessionArtifact.transcriptJournal.relativePath, FinalizationFileAccess.source, FinalizationFileAccess.canonical] {
            try observe(path)
        }
        guard try files.identity("metadata.json") == metadataBefore,
              try files.identity(FinalizationFileAccess.checkpoint) == checkpointBefore else {
            throw AudioFinalizationCode.identityChanged
        }
    }

    private func observe(_ path: String) throws {
        observations[path] = try files.identity(path).map(Observation.present) ?? .absent
    }
    func validate() throws {
        try control.check()
        try files.validateDirectories()
        for (path, observation) in observations {
            switch observation {
            case .absent: guard try files.identity(path) == nil else { throw AudioFinalizationCode.identityChanged }
            case .present(let expected): try files.verify(expected)
            }
        }
    }
    func reach(_ point: TranscriptWritePoint) async throws { try await hook(point); try validate() }
    private func write<T: Encodable>(_ value: T, path: String) throws {
        try validate(); try files.writeJSON(value, path); try observe(path)
    }
    func canonical() throws -> TranscriptDocument? {
        guard try files.identity("transcript.json") != nil else { return nil }
        do {
            let bytes = try files.readData("transcript.json", control: control)
            guard String(data: bytes, encoding: .utf8) != nil, !bytes.contains(0) else {
                throw TranscriptFailure(code: .canonicalConflict)
            }
            return try JSONDecoder().decode(TranscriptDocument.self, from: bytes)
        }
        catch DomainValidationError.unsupportedSchemaVersion { throw TranscriptFailure(code: .unsupportedSchema) }
        catch let error as AudioFinalizationCode { throw error }
        catch { throw TranscriptFailure(code: .canonicalConflict) }
    }
    func journal() throws -> [TranscriptSegment] {
        let path = SessionArtifact.transcriptJournal.relativePath
        guard try files.identity(path) != nil else { return [] }
        var pending = Data(), replay = TranscriptJournalReplay(sessionID: files.location.sessionID)
        var line = 1
        try files.readChunks(path) { chunk in
            try control.check()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                let data = Data(pending.prefix(upTo: newline))
                guard data.count <= 4 * 1_024 * 1_024 else { throw TranscriptFailure(code: .invalidJournal, line: line) }
                try replay.append(data)
                pending.removeSubrange(...newline)
                line += 1
            }
            guard pending.count <= 4 * 1_024 * 1_024 else { throw TranscriptFailure(code: .invalidJournal, line: line) }
        }
        guard pending.isEmpty else { throw TranscriptFailure(code: .invalidJournal, line: line) }
        return replay.segments
    }
    func writeCanonical(_ document: TranscriptDocument) async throws {
        try await reach(.beforeCanonical)
        try write(document, path: "transcript.json")
        guard try canonical() == document else { throw TranscriptFailure(code: .storage) }
        try await reach(.afterCanonical)
    }
    func mark(_ step: FinalizationStep) async throws {
        guard !checkpoint.completedSteps.contains(step) else { return }
        try await reach(.beforeCheckpoint)
        let next = try checkpoint.markingCompleted(step, at: AbsoluteTime(Date()))
        try write(next, path: FinalizationFileAccess.checkpoint)
        checkpoint = next
    }
    func completedMetadata(count: Int, duration: MediaMilliseconds, edited: Bool = false) throws -> SessionMetadataDocument {
        let m = metadata
        let status: SessionStatus = m.captureOutcome == .completed ? .completed : .interrupted
        if !edited, m.status == status, m.transcript.segmentCount.rawValue == count, m.activeDurationMs == duration { return m }
        return try .init(sessionId: m.sessionId, title: m.title, status: status, captureOutcome: m.captureOutcome,
            createdAt: m.createdAt, recordingStartedAt: m.recordingStartedAt, recordingEndedAt: m.recordingEndedAt,
            activeDurationMs: duration, languageMode: m.languageMode, detectedLanguage: m.detectedLanguage,
            engine: m.engine, model: m.model, modelSettings: m.modelSettings, audio: m.audio,
            transcript: .init(segmentCount: .init(Int64(count))), appVersion: m.appVersion, osVersion: m.osVersion,
            lastUpdatedAt: AbsoluteTime(Date()))
    }
    func derivedFilesMatch(_ document: TranscriptDocument, metadata: SessionMetadataDocument) throws -> Bool {
        let rendered = try TranscriptRenderer.render(document, metadata: metadata)
        for (path, expected) in [("transcript.txt", rendered.text), ("transcript.md", rendered.markdown)] {
            guard try files.identity(path) != nil,
                  try files.readData(path, control: control) == expected else { return false }
        }
        return true
    }
    func publish(_ document: TranscriptDocument, metadata completed: SessionMetadataDocument) async throws {
        let rendered = try TranscriptRenderer.render(document, metadata: completed)
        for (path, data, before, after) in [("transcript.txt", rendered.text, TranscriptWritePoint.beforeText, TranscriptWritePoint.afterText),
                                           ("transcript.md", rendered.markdown, .beforeMarkdown, .afterMarkdown)] {
            try await reach(before)
            // Regeneration never parses or imports the previous derived bytes.
            try files.writeData(data, path); try observe(path)
            guard try files.readData(path, control: control) == data else { throw TranscriptFailure(code: .storage) }
            try await reach(after)
        }
        try await mark(.derivedFilesGenerated)
        if metadata != completed {
            try await reach(.beforeMetadata)
            try write(completed, path: "metadata.json")
            metadata = completed
            try await reach(.afterMetadata)
        }
        try await mark(.metadataCompleted)
        try await refreshCatalog()
        try await mark(.catalogUpdated)
    }
    func refreshCatalog() async throws {
        try await reach(.beforeCatalog)
        let report: CatalogReconciliationReport
        do { report = try await catalog.reconcile() }
        catch { throw TranscriptFailure(code: .catalog) }
        try await reach(.afterCatalog)
        let expected = CatalogProjection(metadata: metadata, location: files.location)
        guard report.rootResults.contains(where: { $0.projections.contains(expected) }),
              !report.issues.contains(where: {
                  $0.rootID == files.location.rootID && ($0.folderName == nil || $0.folderName == files.location.folderName.rawValue)
              }) else { throw TranscriptFailure(code: .catalog) }
    }
}
