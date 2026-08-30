import Foundation

enum StorageErrorCode: String, Codable, Sendable, Equatable {
    case noActiveRoot
    case reauthorizationRequired
    case registryMissing
    case registryCorrupt
    case registryUnsupported
    case bookmarkCreateFailed
    case bookmarkResolveFailed
    case bookmarkRefreshFailed
    case securityScopeAccessFailed
    case rootMissing
    case rootNotDirectory
    case rootNotWritable
    case sessionDirectoryCollision
    case sessionLayoutCreationFailed
    case artifactMissing
    case sessionIDMismatch
    case jsonEncodeFailed
    case jsonDecodeFailed
    case temporaryCreateFailed
    case temporaryWriteFailed
    case temporaryFlushFailed
    case atomicRenameFailed
    case jsonlAppendFailed
    case jsonlFlushFailed
}

struct StorageError: Error, Sendable, Equatable {
    let code: StorageErrorCode

    init(_ code: StorageErrorCode) {
        self.code = code
    }
}

struct StorageRootSummary: Codable, Sendable, Equatable, Identifiable {
    let id: StorageRootID
    let displayName: String
    let displayPath: String
    let updatedAt: AbsoluteTime
}

enum StorageRootAvailability: Sendable, Equatable {
    case noRootSelected
    case available(StorageRootSummary, refreshedBookmark: Bool)
    case reauthorizationRequired(StorageRootSummary?)
    case failed(StorageErrorCode)
}

struct SessionLocation: Codable, Sendable, Equatable {
    let rootID: StorageRootID
    let sessionID: SessionID
    let folderName: SessionFolderName
}

protocol SessionRepository: Sendable {
    func createSession(sessionID: SessionID, createdAt: AbsoluteTime, timeZone: TimeZone) async throws -> SessionLocation
    func writeMetadata(_ document: SessionMetadataDocument, at location: SessionLocation) async throws
    func readMetadata(at location: SessionLocation) async throws -> SessionMetadataDocument
    func writeTranscript(_ document: TranscriptDocument, at location: SessionLocation) async throws
    func readTranscript(at location: SessionLocation) async throws -> TranscriptDocument
    func writeFinalizationCheckpoint(_ document: FinalizationCheckpointDocument, at location: SessionLocation) async throws
    func readFinalizationCheckpoint(at location: SessionLocation) async throws -> FinalizationCheckpointDocument
    func appendEvent(_ record: SessionEventRecord, at location: SessionLocation) async throws
    func appendTranscriptJournal(_ record: TranscriptJournalRecord, at location: SessionLocation) async throws
    func artifactOwnership(_ artifact: SessionArtifact) -> SessionArtifactOwnership
}
