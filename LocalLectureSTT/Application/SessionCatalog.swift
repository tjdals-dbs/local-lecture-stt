import Foundation

enum CatalogPresence: String, Codable, Sendable, Equatable, CaseIterable {
    case present
    case missing
    case unreadable
}

struct CatalogProjection: Codable, Sendable, Equatable {
    let location: SessionLocation
    let title: String
    let createdAt: AbsoluteTime
    let activeDuration: MediaMilliseconds
    let metadataStatus: SessionStatus
    let captureOutcome: CaptureOutcome
    let metadataLastUpdatedAt: AbsoluteTime

    init(metadata: SessionMetadataDocument, location: SessionLocation) {
        self.location = location
        title = metadata.title
        createdAt = metadata.createdAt
        activeDuration = metadata.activeDurationMs
        metadataStatus = metadata.status
        captureOutcome = metadata.captureOutcome
        metadataLastUpdatedAt = metadata.lastUpdatedAt
    }
}

struct SessionCatalogItem: Codable, Sendable, Equatable, Identifiable {
    let sessionID: SessionID
    let rootID: StorageRootID
    let folderName: SessionFolderName
    let title: String
    let createdAt: AbsoluteTime
    let activeDuration: MediaMilliseconds
    let metadataStatus: SessionStatus
    let captureOutcome: CaptureOutcome
    let presence: CatalogPresence
    let metadataLastUpdatedAt: AbsoluteTime
    let catalogUpdatedAt: AbsoluteTime

    var id: SessionID { sessionID }
    var displayStatus: SessionStatus {
        switch presence {
        case .present: metadataStatus
        case .missing: .missing
        case .unreadable: .error
        }
    }
}

enum CatalogIssueCode: String, Codable, Sendable, Equatable {
    case rootUnavailable
    case rootPartial
    case invalidFolderName
    case sessionDirectorySymlink
    case metadataMissing
    case metadataInvalid
    case metadataCorrupt
    case metadataUnsupported
    case sessionIDMismatch
    case duplicateSessionID
    case locationConflict
    case filesystemScanFailed
    case catalogFailure
    case recoveredCatalog
}

struct CatalogIssue: Codable, Sendable, Equatable {
    let code: CatalogIssueCode
    let rootID: StorageRootID
    let folderName: String?
}

enum RootScanOutcome: String, Codable, Sendable, Equatable {
    case complete
    case partial
    case unavailable
}

struct RootScanResult: Codable, Sendable, Equatable {
    let rootID: StorageRootID
    let outcome: RootScanOutcome
    let projections: [CatalogProjection]
    let unreadableFolderNames: [String]
    let missingFolderNames: [String]
    let issues: [CatalogIssue]
}

struct CatalogReconciliationReport: Codable, Sendable, Equatable {
    let rootResults: [RootScanResult]
    let issues: [CatalogIssue]
    let recoveredFromCorruption: Bool
}

enum CatalogErrorCode: String, Codable, Sendable, Equatable {
    case applicationSupportUnavailable
    case catalogDirectoryCreateFailed
    case openFailed
    case configureFailed
    case schemaCreateFailed
    case schemaCorrupt
    case schemaInvalid
    case schemaUnsupported
    case integrityCheckFailed
    case prepareFailed
    case bindFailed
    case stepFailed
    case invalidStoredValue
    case transactionBeginFailed
    case transactionCommitFailed
    case transactionRollbackFailed
    case quarantineFailed
    case storageRootRegistryFailed
    case filesystemScanFailed
    case reconciliationConflict
}

struct CatalogError: Error, Sendable, Equatable {
    let code: CatalogErrorCode
    init(_ code: CatalogErrorCode) { self.code = code }
}

protocol SessionFileScanning: Sendable {
    func scan() async throws -> [RootScanResult]
}

protocol SessionCatalogStore: Sendable {
    /// The current identity occupying a physical session location, if any.
    func sessionID(at rootID: StorageRootID, folderName: SessionFolderName) async throws -> SessionID?
    func apply(_ results: [RootScanResult], catalogUpdatedAt: AbsoluteTime) async throws
    func orderedItems() async throws -> [SessionCatalogItem]
    func recoveredFromCorruption() async -> Bool
}

protocol SessionCataloging: RecordingCatalogRefreshing {
    func reconcile() async throws -> CatalogReconciliationReport
    func orderedItems() async throws -> [SessionCatalogItem]
}
