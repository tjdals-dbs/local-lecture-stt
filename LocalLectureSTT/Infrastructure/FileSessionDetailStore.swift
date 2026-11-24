import AppKit
import Foundation

/// Platform-only file actions. Trash has no permanent-delete fallback.
protocol SessionFileActions: Sendable {
    func reveal(_ url: URL) async throws
    func trash(_ url: URL) throws
}
struct MacSessionFileActions: SessionFileActions {
    func reveal(_ url: URL) async throws {
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

actor FileSessionDetailStore: SessionDetailStoring {
    private let roots: StorageRootManager
    private let transcripts: FileTranscriptRepository
    private let catalog: any SessionCataloging
    private let activity: SessionActivityRegistry
    private let actions: any SessionFileActions
    private let beforeAction: @Sendable () async throws -> Void

    init(roots: StorageRootManager, transcripts: FileTranscriptRepository, catalog: any SessionCataloging,
         activity: SessionActivityRegistry, actions: any SessionFileActions = MacSessionFileActions(),
         beforeAction: @escaping @Sendable () async throws -> Void = {}) {
        self.roots = roots; self.transcripts = transcripts; self.catalog = catalog
        self.activity = activity; self.actions = actions; self.beforeAction = beforeAction
    }

    func load(_ location: SessionLocation) async throws -> SessionDetailDocument {
        let lease = try await roots.acquireReadLease(to: location.rootID)
        do {
            let files = try FinalizationFileAccess(root: lease.rootURL, location: location, allowMissingRecovery: true)
            var issues: [SessionDetailIssue] = []
            func read<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
                do { return try files.readJSON(type, path) }
                catch { issues.append(.init(artifact: path, code: SessionDetailDiagnostics.code(error))); return nil }
            }
            var metadata = read(SessionMetadataDocument.self, "metadata.json")
            if metadata?.sessionId != location.sessionID {
                metadata = nil; issues.append(.init(artifact: "metadata.json", code: "sessionMismatch"))
            }
            var document: TranscriptDocument?
            do { document = try JSONDecoder().decode(TranscriptDocument.self, from: files.readData("transcript.json", control: .init())) }
            catch { issues.append(.init(artifact: "transcript.json", code: SessionDetailDiagnostics.code(error))) }
            if let value = document {
                do {
                    guard value.sessionId == location.sessionID else { throw TranscriptFailure(code: .sessionMismatch) }
                    if let metadata { try TranscriptCanonical.validate(value, sessionID: location.sessionID, duration: metadata.activeDurationMs) }
                } catch { document = nil; issues.append(.init(artifact: "transcript.json", code: SessionDetailDiagnostics.code(error))) }
            }
            let checkpoint = read(FinalizationCheckpointDocument.self, FinalizationFileAccess.checkpoint)
            var available: [SessionDetailFile] = []
            for file in SessionDetailFile.allCases {
                do {
                    if try files.identity(file.rawValue) != nil { available.append(file) }
                    else { issues.append(.init(artifact: file.rawValue, code: "missing")) }
                } catch { issues.append(.init(artifact: file.rawValue, code: SessionDetailDiagnostics.code(error))) }
            }
            let editable = metadata.map { [.completed, .interrupted].contains($0.status) &&
                [.completed, .interrupted].contains($0.captureOutcome) } == true && document != nil &&
                checkpoint?.sessionId == location.sessionID && checkpoint?.completedSteps.contains(.metadataCompleted) == true
            try files.validateDirectories()
            await lease.release()
            return .init(location: location, metadata: metadata, transcript: document, availableFiles: available, editable: editable, issues: issues)
        } catch { await lease.release(); throw error }
    }

    func updateText(_ location: SessionLocation, segment: TranscriptSegmentID, expected: String, text: String) async throws {
        try await exclusively(location) {
            _ = try await self.transcripts.updateText(at: location, segmentID: segment, expectedText: expected, text: text)
        }
    }
    func updateTitle(_ location: SessionLocation, expected: String, title: String) async throws {
        try await exclusively(location) {
            try await self.transcripts.updateTitle(at: location, expectedTitle: expected, title: title)
        }
    }
    func regenerate(_ location: SessionLocation) async throws {
        try await exclusively(location) { _ = try await self.transcripts.regenerate(at: location) }
    }
    func reveal(_ file: SessionDetailFile, at location: SessionLocation) async throws {
        let lease = try await roots.acquireReadLease(to: location.rootID)
        do {
            let files = try FinalizationFileAccess(root: lease.rootURL, location: location, allowMissingRecovery: true)
            guard let identity = try files.identity(file.rawValue) else { throw SessionDetailFailure.unavailable }
            try await beforeAction()
            try files.verify(identity)
            try await actions.reveal(files.url(file.rawValue))
            try files.verify(identity)
            await lease.release()
        } catch { await lease.release(); throw error }
    }
    func trash(_ location: SessionLocation) async throws -> SessionTrashResult {
        try await exclusively(location) {
            let lease = try await self.roots.acquireWriteLease(to: location.rootID)
            do {
                let files = try FinalizationFileAccess(root: lease.rootURL, location: location, allowMissingRecovery: true)
                let metadataIdentity = try files.identity("metadata.json")
                // A valid but foreign metadata document is never a deletion target.
                if let metadata = try? files.readJSON(SessionMetadataDocument.self, "metadata.json"), metadata.sessionId != location.sessionID {
                    throw SessionDetailFailure.identityChanged
                }
                try await self.beforeAction()
                try Task.checkCancellation()
                guard try files.identity("metadata.json") == metadataIdentity else { throw SessionDetailFailure.identityChanged }
                try files.validateDirectories()
                try self.actions.trash(files.directory)
                await lease.release()
            } catch { await lease.release(); throw error }
            // Once moved, catalog failure is a warning, never permission to retry a move.
            do {
                try await self.catalog.removeTrashedSession(at: location)
                return SessionTrashResult(catalogWarning: false)
            } catch { return SessionTrashResult(catalogWarning: true) }
        }
    }
    private func exclusively<T: Sendable>(_ location: SessionLocation, body: () async throws -> T) async throws -> T {
        guard let claim = await activity.claimUserOperation(at: location) else { throw SessionDetailFailure.busy }
        do {
            try Task.checkCancellation()
            let result = try await body()
            await activity.release(claim)
            return result
        } catch { await activity.release(claim); throw error }
    }
}
