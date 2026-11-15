import CryptoKit
import Darwin
import Foundation

/// Named side-effect boundaries permit actual-file crash-window and gated race tests.
enum FinalizationPoint: String, Sendable, CaseIterable {
    case opened, sourceValidated, beforeSecuredCheckpoint, afterSecuredCheckpoint
    case beforeFinalizingMetadata, afterFinalizingMetadata, beforeExport, afterExport, beforeFlush, afterFlush
    case beforeCreatedCheckpoint, afterCreatedCheckpoint, beforeValidation, afterValidation
    case beforePublication, afterPublication, beforeVerifiedCheckpoint, afterVerifiedCheckpoint
    case beforeProjection, afterProjection, beforeCatalog, beforeDiagnostic, beforeRelease
    case beforeDelete, afterDelete, beforeRemovedCheckpoint, afterRemovedCheckpoint
}

struct FileAudioFinalizer: AudioFinalizationWorking {
    let roots: StorageRootManager
    let catalog: any RecordingCatalogRefreshing
    var media: any FinalizationMediaProcessing = AVFoundationFinalizationMedia()
    var hook: @Sendable (FinalizationPoint) async throws -> Void = { _ in }
    var authority = CompletionEvidenceAuthority.shared

    func finalize(_ request: AudioFinalizationRequest, control: AudioFinalizationControl,
                  progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        if request.operation == .verifyExistingCanonical {
            return await verifyExistingCanonical(request, control: control, progress: progress)
        }
        return await execute(request, evidence: nil, control: control, progress: progress)
    }
    func removeRecovery(_ evidence: FinalizationCompletionEvidence, control: AudioFinalizationControl,
                        progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        await execute(.init(location: evidence.location), evidence: evidence, control: control, progress: progress)
    }

    private func execute(_ request: AudioFinalizationRequest, evidence: FinalizationCompletionEvidence?,
                         control: AudioFinalizationControl,
                         progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        var run: FinalizationRun?
        var lease: StorageRootWriteLease?
        var revalidatedCompletion = false
        do {
            guard request.schemaVersion == 1 else { throw AudioFinalizationCode.unsupportedSchema }
            guard request.location.folderName.matches(request.location.sessionID) else { throw AudioFinalizationCode.invalidRequest }
            try control.check()
            lease = try await roots.acquireWriteLease(to: request.location.rootID)
            try control.check()
            guard let lease else { throw AudioFinalizationCode.storageAccess }
            let access = try FinalizationFileAccess(root: lease.rootURL, location: request.location)
            let operation = try FinalizationRun(access: access, worker: self, control: control, progress: progress)
            run = operation
            if let evidence { try await operation.cleanup(evidence) }
            else if let proof = request.completionEvidence,
                    try access.identity(FinalizationFileAccess.source) == nil {
                try await operation.cleanup(proof, removeSource: false)
                revalidatedCompletion = true
            }
            else {
                try await operation.finalize()
                revalidatedCompletion = operation.isCompletedSession
            }
        } catch {
            control.fail(Self.code(error))
            // Diagnostics are secondary, never a required write masquerading as success.
            if let run { await run.diagnosticFailure() }
        }
        do {
            try await hook(.beforeRelease)
            try run?.validate()
        } catch {
            if Self.code(error) == .identityChanged { control.fail(.identityChanged) }
            else { control.warning("cleanup.\(Self.code(error).rawValue)") }
        }
        let presentPaths = run?.presentPaths() ?? []
        await lease?.release()
        let (failure, warnings) = control.outcome()
        return AudioFinalizationResult(location: request.location,
            phase: failure != nil ? .failed : (evidence != nil ? .recoveryAudioRemoved :
                (revalidatedCompletion ? .audioRevalidated : .audioReadyAwaitingRemainingFinalization)),
            failure: failure, warnings: warnings, media: run?.report, source: run?.source,
            final: run?.final, completedSteps: run?.checkpoint.completedSteps ?? [],
            retainedPaths: run?.retained ?? [], presentPaths: presentPaths, recoveryWasRemoved: run?.removed ?? false)
    }

    /// T09 terminal recovery uses the production T08 inspection and provenance
    /// path, but it deliberately obtains only read access and never enters the
    /// remux/checkpoint/projection/cleanup path.
    private func verifyExistingCanonical(_ request: AudioFinalizationRequest,
                                         control: AudioFinalizationControl,
                                         progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        var run: FinalizationRun?
        var lease: StorageRootWriteLease?
        do {
            guard request.schemaVersion == 1 else { throw AudioFinalizationCode.unsupportedSchema }
            guard request.location.folderName.matches(request.location.sessionID) else { throw AudioFinalizationCode.invalidRequest }
            try control.check()
            lease = try await roots.acquireReadLease(to: request.location.rootID)
            try control.check()
            guard let lease else { throw AudioFinalizationCode.storageAccess }
            let access = try FinalizationFileAccess(root: lease.rootURL, location: request.location)
            let operation = try FinalizationRun(access: access, worker: self, control: control, progress: progress)
            run = operation
            try await operation.verifyExistingCanonical()
        } catch {
            control.fail(Self.code(error))
        }
        do {
            try await hook(.beforeRelease)
            try run?.validate()
        } catch {
            if Self.code(error) == .identityChanged { control.fail(.identityChanged) }
            else { control.warning("cleanup.\(Self.code(error).rawValue)") }
        }
        let presentPaths = run?.presentPaths() ?? []
        await lease?.release()
        let (failure, warnings) = control.outcome()
        return AudioFinalizationResult(location: request.location,
            phase: failure == nil ? .audioRevalidated : .failed,
            failure: failure, warnings: warnings, media: run?.report, source: run?.source,
            final: run?.final, completedSteps: run?.checkpoint.completedSteps ?? [], retainedPaths: [],
            presentPaths: presentPaths, recoveryWasRemoved: false)
    }

    static func code(_ error: Error) -> AudioFinalizationCode {
        if let error = error as? StorageError {
            switch error.code {
            case .rootMissing: return .rootMissing
            case .rootNotWritable: return .rootNotWritable
            case .rootNotDirectory: return .unsafeLayout
            case .reauthorizationRequired, .securityScopeAccessFailed, .bookmarkResolveFailed: return .reauthorizationRequired
            case .documentUnsupported: return .unsupportedSchema
            default: return .storageAccess
            }
        }
        return FinalizationFileAccess.errorCode(error, fallback: .persistence)
    }
}

private final class FinalizationRun {
    private enum SourceObservation {
        case absent
        case present(FinalizationFileEvidence)
    }
    private enum TerminalSourceState {
        case absent
        case present(FinalizationFileEvidence)
        case removedAfterPresent
    }
    let files: FinalizationFileAccess
    let worker: FileAudioFinalizer
    let control: AudioFinalizationControl
    let progress: @Sendable (AudioFinalizationPhase) async -> Void
    var metadata: SessionMetadataDocument
    var checkpoint: FinalizationCheckpointDocument
    var metadataIdentity: FinalizationFileEvidence?
    var checkpointIdentity: FinalizationFileEvidence?
    var source: FinalizationFileEvidence?
    var final: FinalizationFileEvidence?
    var report: AudioMediaReport?
    var retained: [String] = []
    var removed = false
    private let initialSourceObservation: SourceObservation
    private var terminalSourceState: TerminalSourceState?
    private var terminalPermitsSourceRemoval = false
    var isCompletedSession: Bool {
        checkpoint.completedSteps.contains(.catalogUpdated) &&
            ((metadata.status == .completed && metadata.captureOutcome == .completed) ||
             (metadata.status == .interrupted && metadata.captureOutcome == .interrupted))
    }

    init(access: FinalizationFileAccess, worker: FileAudioFinalizer, control: AudioFinalizationControl,
         progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) throws {
        files = access; self.worker = worker; self.control = control; self.progress = progress
        metadata = try files.readJSON(SessionMetadataDocument.self, "metadata.json")
        metadataIdentity = try files.identity("metadata.json")
        if try files.identity(FinalizationFileAccess.checkpoint) != nil {
            checkpoint = try files.readJSON(FinalizationCheckpointDocument.self, FinalizationFileAccess.checkpoint)
            checkpointIdentity = try files.identity(FinalizationFileAccess.checkpoint)
        } else {
            checkpoint = try .init(sessionId: access.location.sessionID, updatedAt: AbsoluteTime(Date()))
        }
        guard metadata.sessionId == files.location.sessionID, checkpoint.sessionId == files.location.sessionID else {
            throw AudioFinalizationCode.invalidRequest
        }
        // Validate optional paths too: dangling symlinks are collisions, never absence.
        for path in [FinalizationFileAccess.staging, FinalizationFileAccess.canonical, FinalizationFileAccess.source, "events.jsonl"] {
            _ = try files.identity(path)
        }
        if try files.identity(FinalizationFileAccess.source) == nil {
            initialSourceObservation = .absent
        } else {
            initialSourceObservation = .present(try files.fingerprint(FinalizationFileAccess.source))
        }
    }

    func validate() throws {
        try files.validateDirectories()
        guard try files.identity("metadata.json") == metadataIdentity,
              try files.identity(FinalizationFileAccess.checkpoint) == checkpointIdentity else {
            throw AudioFinalizationCode.identityChanged
        }
        if terminalSourceState != nil { try validateTerminalSourceState() }
        else if let source, !removed { try files.verify(source) }
        if let final { try files.verify(final) }
    }
    func presentPaths() -> [String] {
        [FinalizationFileAccess.source, FinalizationFileAccess.staging, FinalizationFileAccess.canonical,
         "metadata.json", FinalizationFileAccess.checkpoint].filter { (try? files.identity($0)) != nil }
    }
    func reach(_ point: FinalizationPoint, checkCancellation: Bool = true) async throws {
        try await worker.hook(point)
        try validate()
        if checkCancellation { try control.check() }
    }
    func phase(_ phase: AudioFinalizationPhase) async throws {
        await progress(phase)
        try validate(); try control.check()
    }

    /// Terminal verification has no mutation that could justify silently
    /// changing its source contract.  Prefix 8 may observe a present source
    /// disappear, but the resulting absence must remain stable through lease
    /// release; an initially absent source may never reappear.
    func beginTerminalSourceObservation() throws {
        guard terminalSourceState == nil else { return }
        terminalPermitsSourceRemoval = checkpoint.completedSteps.contains(.recoveryDataRemoved)
        switch initialSourceObservation {
        case .absent:
            guard terminalPermitsSourceRemoval else { throw AudioFinalizationCode.sourceMissing }
            terminalSourceState = .absent
        case let .present(evidence):
            terminalSourceState = .present(evidence)
        }
        try validate()
    }

    private var terminalSourceEvidence: FinalizationFileEvidence? {
        guard case let .some(.present(evidence)) = terminalSourceState else { return nil }
        return evidence
    }

    private func validateTerminalSourceState() throws {
        guard let terminalSourceState else { return }
        let current = try files.identity(FinalizationFileAccess.source)
        switch terminalSourceState {
        case .absent, .removedAfterPresent:
            guard current == nil else { throw AudioFinalizationCode.identityChanged }
        case let .present(expected):
            guard current != nil else {
                guard terminalPermitsSourceRemoval else { throw AudioFinalizationCode.sourceMissing }
                self.terminalSourceState = .removedAfterPresent
                return
            }
            try files.verify(expected, contents: true)
        }
    }

    func mark(_ step: FinalizationStep, before: FinalizationPoint, after: FinalizationPoint) async throws {
        guard !checkpoint.completedSteps.contains(step) else { return }
        try await reach(before)
        let next = try checkpoint.markingCompleted(step, at: AbsoluteTime(Date()))
        try files.writeJSON(next, FinalizationFileAccess.checkpoint)
        checkpoint = next
        checkpointIdentity = try files.identity(FinalizationFileAccess.checkpoint)
        try await reach(after)
        do {
            try await worker.hook(.beforeDiagnostic)
            try validate()
            let event = try SessionEventRecord(sessionId: files.location.sessionID, eventId: SessionEventID(),
                occurredAt: AbsoluteTime(Date()), kind: .finalizationStepTransition,
                detail: SessionEventDetail(code: step.rawValue))
            try SafeSessionEventAppender.append(event, access: files)
        } catch { control.warning("diagnostic.\(FileAudioFinalizer.code(error).rawValue)") }
        try control.check()
    }

    func finalize() async throws {
        try await reach(.opened)
        guard [.securing, .finalizing, .interrupted, .completed].contains(metadata.status),
              [.completed, .interrupted].contains(metadata.captureOutcome) else { throw AudioFinalizationCode.captureNotSettled }
        if metadata.status == .completed && !checkpoint.completedSteps.contains(.metadataCompleted) {
            throw AudioFinalizationCode.checkpointInconsistent
        }
        guard try files.identity(FinalizationFileAccess.source) != nil else { throw AudioFinalizationCode.sourceMissing }
        source = try files.fingerprint(FinalizationFileAccess.source)
        try await phase(.securing)
        let sourceReport = try await worker.media.inspect(files.url(FinalizationFileAccess.source), requiresM4A: false, control: control)
        try await reach(.sourceValidated)
        if metadata.captureOutcome == .completed {
            try AudioFinalizationPolicy.validateDuration(sourceReport.durationSeconds, against: Double(metadata.activeDurationMs.rawValue) / 1_000)
        }
        try await mark(.workingAudioSecured, before: .beforeSecuredCheckpoint, after: .afterSecuredCheckpoint)
        let downstream = checkpoint.completedSteps.count > 3
        if !downstream && metadata.status != .finalizing {
            try await reach(.beforeFinalizingMetadata)
            metadata = try project(status: .finalizing, audio: metadata.audio)
            try writeMetadata()
            try await reach(.afterFinalizingMetadata)
        }
        if let canonical = try files.identity(FinalizationFileAccess.canonical) {
            do {
                let inspected = try await worker.media.inspect(files.url(FinalizationFileAccess.canonical), requiresM4A: true, control: control)
                try validate(); try files.verify(canonical)
                try match(inspected, sourceReport)
                report = inspected
            } catch {
                if let code = error as? AudioFinalizationCode, [.cancelled, .identityChanged].contains(code) { throw code }
                throw checkpoint.completedSteps.contains(.finalM4AVerified) ? AudioFinalizationCode.checkpointInconsistent : .canonicalConflict
            }
            try files.sync(FinalizationFileAccess.canonical)
            try await mark(.finalM4ACreated, before: .beforeCreatedCheckpoint, after: .afterCreatedCheckpoint)
        } else {
            guard !checkpoint.completedSteps.contains(.finalM4AVerified) else { throw AudioFinalizationCode.checkpointInconsistent }
            var reusable = false
            if let staging = try files.identity(FinalizationFileAccess.staging) {
                do {
                    let inspected = try await worker.media.inspect(files.url(FinalizationFileAccess.staging), requiresM4A: true, control: control)
                    try validate(); try files.verify(staging)
                    try match(inspected, sourceReport)
                    reusable = true
                } catch {
                    try validate(); try control.check(); try files.verify(staging)
                    let retainedPath = "audio.retained-\(UUID().uuidString).m4a"
                    try files.moveExclusive(FinalizationFileAccess.staging, to: retainedPath, expected: staging)
                    retained.append(retainedPath)
                }
            }
            if !reusable {
                try await phase(.exporting)
                try await reach(.beforeExport)
                try await worker.media.remux(FinalizationMediaFiles(source: files, destination: files, expectedSource: source), control: control)
                try await reach(.afterExport)
            }
            try await reach(.beforeFlush)
            try files.sync(FinalizationFileAccess.staging)
            try await reach(.afterFlush)
            try await mark(.finalM4ACreated, before: .beforeCreatedCheckpoint, after: .afterCreatedCheckpoint)
            try await phase(.verifying)
            try await reach(.beforeValidation)
            let staged = try files.fingerprint(FinalizationFileAccess.staging)
            let inspected = try await worker.media.inspect(files.url(FinalizationFileAccess.staging), requiresM4A: true, control: control)
            try await reach(.afterValidation)
            try files.verify(staged, contents: true)
            try match(inspected, sourceReport)
            try await phase(.publishing)
            try await reach(.beforePublication)
            if let source { try files.verify(source, contents: true) }
            try files.moveExclusive(FinalizationFileAccess.staging, to: FinalizationFileAccess.canonical, expected: staged)
            try await reach(.afterPublication)
            let published = try files.fingerprint(FinalizationFileAccess.canonical)
            guard published.inode == staged.inode, published.device == staged.device,
                  published.sha256 == staged.sha256 else { throw AudioFinalizationCode.identityChanged }
            report = inspected
        }
        // Open the actual canonical file again after publication, including independent endpoint decode.
        let canonical = try files.fingerprint(FinalizationFileAccess.canonical)
        let verified = try await worker.media.inspect(files.url(FinalizationFileAccess.canonical), requiresM4A: true, control: control)
        try validate(); try files.verify(canonical, contents: true); try match(verified, sourceReport)
        final = canonical; report = verified
        try await mark(.finalM4AVerified, before: .beforeVerifiedCheckpoint, after: .afterVerifiedCheckpoint)
        try await phase(.projecting)
        if !downstream {
            let audio = try AudioDescription(format: "AAC-LC M4A", sampleRate: 48_000, channels: 1, bitRate: 96_000)
            if metadata.audio != audio {
                try await reach(.beforeProjection)
                metadata = try project(status: .finalizing, audio: audio)
                try writeMetadata()
                try await reach(.afterProjection)
            }
        }
        do {
            try await reach(.beforeCatalog)
            let refresh = try await worker.catalog.reconcile()
            try validate()
            if !refresh.issues.isEmpty { control.warning("catalog.issues") }
        } catch {
            let code = FileAudioFinalizer.code(error)
            if code == .identityChanged || code == .cancelled { throw code }
            control.warning("catalog.\(code.rawValue)")
        }
        try validate(); try control.check()
    }

    /// This is intentionally separate from `finalize()`: it may inspect a
    /// terminal canonical file but it cannot create a staging file, publish,
    /// write metadata/checkpoints, refresh the catalog, issue a proof, or
    /// remove recovery audio.
    func verifyExistingCanonical() async throws {
        try beginTerminalSourceObservation()
        try await phase(.verifying)
        let canonical = try files.fingerprint(FinalizationFileAccess.canonical)
        let inspected = try await worker.media.inspect(files.url(FinalizationFileAccess.canonical), requiresM4A: true, control: control)
        try validate(); try files.verify(canonical, contents: true)
        final = canonical
        report = inspected
        if let expectedSource = terminalSourceEvidence {
            let sourceReport = try await worker.media.inspect(files.url(FinalizationFileAccess.source), requiresM4A: false, control: control)
            try validate(); try files.verify(canonical, contents: true)
            if let confirmedSource = terminalSourceEvidence {
                try match(inspected, sourceReport)
                source = confirmedSource
            }
        }
    }

    private func match(_ candidate: AudioMediaReport, _ source: AudioMediaReport) throws {
        try AudioFinalizationPolicy.validateDuration(candidate.durationSeconds, against: source.durationSeconds)
        guard candidate.payloadSHA256 == source.payloadSHA256, candidate.packetCount == source.packetCount,
              candidate.compressedBytes == source.compressedBytes else { throw AudioFinalizationCode.canonicalConflict }
    }
    private func writeMetadata() throws {
        try files.writeJSON(metadata, "metadata.json")
        metadataIdentity = try files.identity("metadata.json")
    }
    private func project(status: SessionStatus, audio: AudioDescription?) throws -> SessionMetadataDocument {
        let m = metadata
        return try .init(sessionId: m.sessionId, title: m.title, status: status, captureOutcome: m.captureOutcome,
            createdAt: m.createdAt, recordingStartedAt: m.recordingStartedAt, recordingEndedAt: m.recordingEndedAt,
            activeDurationMs: m.activeDurationMs, languageMode: m.languageMode, detectedLanguage: m.detectedLanguage,
            engine: m.engine, model: m.model, modelSettings: m.modelSettings, audio: audio, transcript: m.transcript, appVersion: m.appVersion,
            osVersion: m.osVersion, lastUpdatedAt: AbsoluteTime(Date()))
    }
    func diagnosticFailure() async {
        do { try await worker.hook(.beforeDiagnostic); try validate() }
        catch { control.warning("diagnostic.\(FileAudioFinalizer.code(error).rawValue)") }
    }

    func cleanup(_ evidence: FinalizationCompletionEvidence, removeSource: Bool = true) async throws {
        try worker.authority.validate(evidence)
        guard evidence.location == files.location, checkpoint.completedSteps.contains(.catalogUpdated),
              CatalogProjection(metadata: metadata, location: files.location) == evidence.catalogProjection,
              (metadata.status == .completed && metadata.captureOutcome == .completed) ||
              (metadata.status == .interrupted && metadata.captureOutcome == .interrupted) else {
            throw AudioFinalizationCode.completionEvidence
        }
        await progress(.cleaning)
        try validate(); try control.check()
        let actualSource = try files.identity(FinalizationFileAccess.source)
        for file in evidence.files where file.relativePath != FinalizationFileAccess.source {
            try files.verify(file, contents: true)
        }
        guard let sourceProof = evidence.files.first(where: { $0.relativePath == FinalizationFileAccess.source }) else {
            throw AudioFinalizationCode.completionEvidence
        }
        source = actualSource == nil ? nil : sourceProof
        if actualSource != nil { try files.verify(sourceProof, contents: true) }
        let canonical = try files.fingerprint(FinalizationFileAccess.canonical)
        let media = try await worker.media.inspect(files.url(FinalizationFileAccess.canonical), requiresM4A: true, control: control)
        try validate(); try files.verify(canonical, contents: true)
        try match(media, evidence.audio)
        report = media; final = canonical
        if !removeSource { return }
        try await reach(.beforeDelete)
        // Recheck every required byte after awaits and immediately before the delete commit point.
        for file in evidence.files where file.relativePath != FinalizationFileAccess.source {
            try files.verify(file, contents: true)
        }
        if actualSource != nil {
            try control.commitDeletion { try files.removeSource(expected: sourceProof) }
            removed = true
            source = nil
            try files.syncRecoveryDirectory()
            try await reach(.afterDelete)
        } else {
            // Signed full-completion evidence supports unlink -> checkpoint crash recovery.
            try control.commitDeletion {}
            removed = true
        }
        try await mark(.recoveryDataRemoved, before: .beforeRemovedCheckpoint, after: .afterRemovedCheckpoint)
    }
}

/// Diagnostics must never "repair" a damaged authoritative event journal by
/// appending after an incomplete/corrupt line.  Media/checkpoint work may
/// continue, but the original bytes remain evidence for recovery and review.
enum SafeSessionEventAppender {
    static func append(_ event: SessionEventRecord, access: FinalizationFileAccess) throws {
        let path = SessionArtifact.events.relativePath
        if try access.identity(path) != nil {
            let handle = try FileHandle(forReadingFrom: access.url(path))
            defer { try? handle.close() }
            var pending = Data()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                pending.append(chunk)
                guard pending.count <= 262_144 else { throw AudioFinalizationCode.corruptDocument }
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    guard !line.isEmpty else { continue }
                    let existing = try JSONDecoder().decode(SessionEventRecord.self, from: line)
                    guard existing.sessionId == event.sessionId else { throw AudioFinalizationCode.corruptDocument }
                }
            }
            guard pending.isEmpty else { throw AudioFinalizationCode.corruptDocument }
        }
        try JSONLWriter().append(event, to: access.url(path))
        try access.validateDirectories()
    }
}

/// Attestation survives restart when backed by the app-private key file. Construction
/// is inert; only explicit proof issuance creates the key. A missing/corrupt key on
/// validation fails closed and never rotates an existing key or deletes audio.
/// No unauthenticated caller-supplied booleans or hashes authorize deletion.
final class CompletionEvidenceAuthority: @unchecked Sendable {
    static let shared = CompletionEvidenceAuthority(persistentKeyURL:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLectureSTT/Storage/finalization-proof.key"))
    private let lock = NSLock()
    private let persistentKeyURL: URL?
    private var cachedKey: SymmetricKey?

    init(persistentKeyURL: URL? = nil) {
        self.persistentKeyURL = persistentKeyURL
        cachedKey = persistentKeyURL == nil ? SymmetricKey(size: .bits256) : nil
    }

    private func signingKey(create: Bool) throws -> SymmetricKey {
        try lock.withLock {
            if let cachedKey { return cachedKey }
            guard let url = persistentKeyURL else { throw AudioFinalizationCode.completionEvidence }
            if create {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                if fd >= 0 {
                    let key = SymmetricKey(size: .bits256)
                    let data = key.withUnsafeBytes { Data($0) }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                    let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard directory >= 0 else { throw AudioFinalizationCode.completionEvidence }
                    defer { Darwin.close(directory) }
                    guard fsync(directory) == 0 else { throw AudioFinalizationCode.completionEvidence }
                } else if errno != EEXIST { throw AudioFinalizationCode.completionEvidence }
            }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw AudioFinalizationCode.completionEvidence }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_size == 32, info.st_mode & 0o077 == 0,
                  let bytes = try handle.read(upToCount: 32), bytes.count == 32 else {
                throw AudioFinalizationCode.completionEvidence
            }
            let key = SymmetricKey(data: bytes)
            cachedKey = key
            return key
        }
    }
    private struct Payload: Codable { let version: Int; let location: SessionLocation; let files: [FinalizationFileEvidence]; let audio: AudioMediaReport; let catalog: CatalogProjection }
    private func signature(location: SessionLocation, files: [FinalizationFileEvidence], audio: AudioMediaReport, catalog: CatalogProjection, createKey: Bool = false) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(version: 1, location: location, files: files, audio: audio, catalog: catalog))
        return try HMAC<SHA256>.authenticationCode(for: data, using: signingKey(create: createKey)).map { String(format: "%02x", $0) }.joined()
    }
    func validate(_ proof: FinalizationCompletionEvidence) throws {
        let required = ["metadata.json", "audio.m4a", "transcript.json", "transcript.txt", "transcript.md", FinalizationFileAccess.source]
        guard proof.schemaVersion == 1, proof.files.map(\.relativePath).sorted() == required.sorted(),
              proof.location == proof.catalogProjection.location,
              try proof.seal == signature(location: proof.location, files: proof.files, audio: proof.audio, catalog: proof.catalogProjection) else {
            throw AudioFinalizationCode.completionEvidence
        }
    }

    func issue(location: SessionLocation, roots: StorageRootManager, verifier: any RemainingFinalizationVerifying,
               media: any FinalizationMediaProcessing = AVFoundationFinalizationMedia()) async throws -> FinalizationCompletionEvidence {
        let lease = try await roots.acquireWriteLease(to: location.rootID)
        do {
            let files = try FinalizationFileAccess(root: lease.rootURL, location: location)
            let cp = try files.readJSON(FinalizationCheckpointDocument.self, FinalizationFileAccess.checkpoint)
            let m = try files.readJSON(SessionMetadataDocument.self, "metadata.json")
            let transcript = try files.readJSON(TranscriptDocument.self, "transcript.json")
            guard cp.sessionId == location.sessionID, cp.completedSteps.contains(.catalogUpdated),
                  m.sessionId == location.sessionID, transcript.sessionId == location.sessionID,
                  (m.status == .completed && m.captureOutcome == .completed) ||
                  (m.status == .interrupted && m.captureOutcome == .interrupted) else { throw AudioFinalizationCode.completionEvidence }
            let paths = ["metadata.json", "audio.m4a", "transcript.json", "transcript.txt", "transcript.md", FinalizationFileAccess.source]
            let bindings = try paths.map { try files.fingerprint($0) }
            let control = AudioFinalizationControl()
            let sourceReport = try await media.inspect(files.url(FinalizationFileAccess.source), requiresM4A: false, control: control)
            let finalReport = try await media.inspect(files.url(FinalizationFileAccess.canonical), requiresM4A: true, control: control)
            try AudioFinalizationPolicy.validateDuration(finalReport.durationSeconds, against: sourceReport.durationSeconds)
            guard finalReport.payloadSHA256 == sourceReport.payloadSHA256 else { throw AudioFinalizationCode.completionEvidence }
            let catalog = try await verifier.verify(location: location, files: bindings)
            guard catalog == CatalogProjection(metadata: m, location: location) else { throw AudioFinalizationCode.completionEvidence }
            for binding in bindings { try files.verify(binding, contents: true) }
            guard try files.readJSON(FinalizationCheckpointDocument.self, FinalizationFileAccess.checkpoint) == cp else {
                throw AudioFinalizationCode.identityChanged
            }
            let seal = try signature(location: location, files: bindings, audio: finalReport, catalog: catalog, createKey: true)
            await lease.release()
            return .init(location: location, files: bindings, audio: finalReport, catalogProjection: catalog, seal: seal)
        } catch { await lease.release(); throw error }
    }
}
