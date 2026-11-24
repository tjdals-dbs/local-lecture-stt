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

// MARK: - Startup recovery

/// URL-free description of one on-disk recovery candidate.  The scanner does
/// not mutate while producing this value; the coordinator re-checks ownership
/// immediately before it asks the repository to write anything.
struct SessionRecoveryCandidate: Codable, Sendable, Equatable {
    let location: SessionLocation
    let metadata: SessionMetadataDocument
    let checkpoint: FinalizationCheckpointDocument?
    let sourcePresent: Bool
    let stagingPresent: Bool
    let canonicalPresent: Bool
    /// A bounded structural inspection of the final M4A.  Presence and byte
    /// count alone are deliberately not completion evidence.
    let canonicalIntegrity: FinalAudioIntegrity
    let rootWritable: Bool

    init(location: SessionLocation, metadata: SessionMetadataDocument, checkpoint: FinalizationCheckpointDocument?,
         sourcePresent: Bool, stagingPresent: Bool, canonicalPresent: Bool,
         canonicalIntegrity: FinalAudioIntegrity = .uninspected, rootWritable: Bool) {
        self.location = location
        self.metadata = metadata
        self.checkpoint = checkpoint
        self.sourcePresent = sourcePresent
        self.stagingPresent = stagingPresent
        self.canonicalPresent = canonicalPresent
        self.canonicalIntegrity = canonicalIntegrity
        self.rootWritable = rootWritable
    }

    private enum CodingKeys: String, CodingKey {
        case location, metadata, checkpoint, sourcePresent, stagingPresent, canonicalPresent, canonicalIntegrity, rootWritable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decode(SessionLocation.self, forKey: .location)
        metadata = try container.decode(SessionMetadataDocument.self, forKey: .metadata)
        checkpoint = try container.decodeIfPresent(FinalizationCheckpointDocument.self, forKey: .checkpoint)
        sourcePresent = try container.decode(Bool.self, forKey: .sourcePresent)
        stagingPresent = try container.decode(Bool.self, forKey: .stagingPresent)
        canonicalPresent = try container.decode(Bool.self, forKey: .canonicalPresent)
        canonicalIntegrity = try container.decodeIfPresent(FinalAudioIntegrity.self, forKey: .canonicalIntegrity) ?? .uninspected
        rootWritable = try container.decode(Bool.self, forKey: .rootWritable)
    }
}

enum FinalAudioIntegrity: String, Codable, Sendable, Equatable {
    case uninspected
    case missing
    case empty
    case malformed
    case valid
}

enum SessionRecoveryCode: String, Codable, Sendable, Equatable, CaseIterable {
    case queued
    case audioReadyAwaitingRemainingFinalization
    case sessionReady
    case transcriptFinalizationFailed
    case audioRevalidated
    case interruptedRecordingRecovered
    case preparationAbandoned
    case rootUnavailable
    case rootReadOnly
    case metadataMissing
    case metadataCorrupt
    case metadataUnsupported
    case checkpointCorrupt
    case checkpointUnsupported
    case checkpointSessionMismatch
    case checkpointInconsistent
    case sessionIDMismatch
    case duplicateSession
    case unsafeLayout
    case missingRecoverySource
    case terminalInconsistent
    case finalizationFailed
    case currentProcessActive
    case catalogRefreshFailed
    case cancelled
}

struct SessionRecoveryIssue: Codable, Sendable, Equatable, Identifiable {
    let rootID: StorageRootID
    let folderName: String?
    let sessionID: SessionID?
    let code: SessionRecoveryCode
    let preserved: Bool
    let retryable: Bool
    let warning: String?
    /// The first failure remains `warning` for concise existing UI, while all
    /// later diagnostic/cleanup observations stay independently reviewable.
    let warnings: [String]
    /// UI wording must not infer a normal recording from a revalidation result
    /// without the durable capture outcome that produced it.
    let captureOutcome: CaptureOutcome?

    init(rootID: StorageRootID,
         folderName: String?,
         sessionID: SessionID?,
         code: SessionRecoveryCode,
         preserved: Bool,
         retryable: Bool,
         warning: String?,
         warnings: [String] = [],
         captureOutcome: CaptureOutcome? = nil) {
        self.rootID = rootID
        self.folderName = folderName
        self.sessionID = sessionID
        self.code = code
        self.preserved = preserved
        self.retryable = retryable
        self.warning = warning
        self.warnings = warnings
        self.captureOutcome = captureOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case rootID, folderName, sessionID, code, preserved, retryable, warning, warnings, captureOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootID = try container.decode(StorageRootID.self, forKey: .rootID)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName)
        sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
        code = try container.decode(SessionRecoveryCode.self, forKey: .code)
        preserved = try container.decode(Bool.self, forKey: .preserved)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
            ?? warning.map { [$0] }
            ?? []
        captureOutcome = try container.decodeIfPresent(CaptureOutcome.self, forKey: .captureOutcome)
    }

    var id: String {
        "\(rootID.rawValue.uuidString)/\(folderName ?? "-")/\(sessionID?.rawValue.uuidString ?? "-")/\(code.rawValue)"
    }
}

struct RootRecoveryScanResult: Codable, Sendable, Equatable {
    let rootID: StorageRootID
    let candidates: [SessionRecoveryCandidate]
    let issues: [SessionRecoveryIssue]
    /// Metadata identity is usable for collision detection even when another
    /// artifact later makes the folder unsafe to execute.
    let identifiedLocations: [SessionLocation]

    init(rootID: StorageRootID, candidates: [SessionRecoveryCandidate], issues: [SessionRecoveryIssue],
         identifiedLocations: [SessionLocation] = []) {
        self.rootID = rootID
        self.candidates = candidates
        self.issues = issues
        self.identifiedLocations = identifiedLocations
    }

    private enum CodingKeys: String, CodingKey { case rootID, candidates, issues, identifiedLocations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootID = try container.decode(StorageRootID.self, forKey: .rootID)
        candidates = try container.decode([SessionRecoveryCandidate].self, forKey: .candidates)
        issues = try container.decode([SessionRecoveryIssue].self, forKey: .issues)
        identifiedLocations = try container.decodeIfPresent([SessionLocation].self, forKey: .identifiedLocations)
            ?? candidates.map(\.location)
    }
}

struct SessionRecoveryReport: Codable, Sendable, Equatable {
    let items: [SessionRecoveryIssue]
    let catalogWarning: CatalogErrorCode?
    let discoveryWarning: String?
}

enum SessionRecoveryPhase: String, Codable, Sendable, Equatable {
    case idle
    case discovering
    case recovering
    case ready
    case cancelled
}

struct SessionRecoverySnapshot: Codable, Sendable, Equatable {
    let generation: UInt64
    let phase: SessionRecoveryPhase
    let report: SessionRecoveryReport?
}

protocol SessionRecoveryScanning: Sendable {
    func scanForRecovery() async throws -> [RootRecoveryScanResult]
}

/// A deliberately narrow writer boundary.  It owns the pinned metadata write
/// and conservative diagnostic append; the coordinator never receives URLs or
/// file handles.
protocol SessionRecoveryPersisting: Sendable {
    func markInterruptedForRecovery(at location: SessionLocation, expected: SessionMetadataDocument,
                                    updatedAt: AbsoluteTime) async throws -> SessionMetadataDocument
    func markPreparationAbandonedForRecovery(at location: SessionLocation, expected: SessionMetadataDocument,
                                             updatedAt: AbsoluteTime) async throws -> SessionMetadataDocument
    func appendRecoveryEventIfSafe(at location: SessionLocation, kind: SessionEventKind, code: String,
                                   message: String?, occurredAt: AbsoluteTime) async -> String?
}

// MARK: - Live session ownership

/// App-lifetime, actor-isolated ownership for files that may also be observed
/// by startup recovery.  A root reservation starts *before* T07 creates the
/// session directory; once the location is known it becomes a per-session
/// reservation and remains held until T08 has settled its worker resources.
/// Recovery receives a distinct claim only when neither form is live.
struct SessionActivityReservation: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let rootID: StorageRootID
}

actor SessionActivityRegistry {
    private enum Owner { case recordingCreation, recordingOrFinalization, recovery }
    private struct Entry { let rootID: StorageRootID; var locationKey: String?; let owner: Owner }
    private var entries: [UUID: Entry] = [:]

    func reserveRecordingCreation(rootID: StorageRootID) -> SessionActivityReservation {
        let reservation = SessionActivityReservation(id: UUID(), rootID: rootID)
        entries[reservation.id] = .init(rootID: rootID, locationKey: nil, owner: .recordingCreation)
        return reservation
    }

    /// This promotion is atomic with recovery claims: after the session folder
    /// exists, recovery can never win a stale scan against this process.
    func promoteRecording(_ reservation: SessionActivityReservation, at location: SessionLocation) -> Bool {
        guard var entry = entries[reservation.id], entry.rootID == location.rootID else { return false }
        entry.locationKey = key(location)
        entries[reservation.id] = entry
        return true
    }

    /// Called by T07 before dropping its active session, so T08 is protected
    /// during queueing and while its detached worker owns file descriptors.
    func promoteToFinalization(_ reservation: SessionActivityReservation) -> Bool {
        guard let entry = entries[reservation.id], entry.locationKey != nil else { return false }
        return entry.owner != .recovery
    }

    func release(_ reservation: SessionActivityReservation) { entries[reservation.id] = nil }

    func releaseRecordingOrFinalization(at location: SessionLocation) {
        let locationKey = key(location)
        for (id, entry) in entries where entry.locationKey == locationKey && entry.owner != .recovery {
            entries[id] = nil
        }
    }

    func claimRecovery(at location: SessionLocation) -> SessionActivityReservation? {
        // A creation reservation intentionally blocks all candidates at that
        // root.  It is short lived and prevents a scan racing folder creation.
        guard !entries.values.contains(where: { $0.rootID == location.rootID &&
            ($0.locationKey == nil || $0.locationKey == key(location)) }) else { return nil }
        let reservation = SessionActivityReservation(id: UUID(), rootID: location.rootID)
        entries[reservation.id] = .init(rootID: location.rootID, locationKey: key(location), owner: .recovery)
        return reservation
    }

    private func key(_ location: SessionLocation) -> String {
        "\(location.rootID.rawValue.uuidString)/\(location.sessionID.rawValue.uuidString)/\(location.folderName.rawValue)"
    }
}
