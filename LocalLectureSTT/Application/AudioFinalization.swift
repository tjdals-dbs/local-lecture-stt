import Foundation

/// A request kind is part of finalization identity.  In particular, a settled
/// export result must never satisfy a later evidence-only verification request.
enum AudioFinalizationOperation: String, Codable, Sendable, Equatable {
    case resume
    case verifyExistingCanonical
}

/// Only explicit, settled locations enter this boundary. No root discovery occurs here.
struct AudioFinalizationRequest: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    let location: SessionLocation
    var operation: AudioFinalizationOperation = .resume
    /// Required to revalidate after the full pipeline has already removed recovery.
    var completionEvidence: FinalizationCompletionEvidence? = nil

    init(location: SessionLocation, operation: AudioFinalizationOperation = .resume,
         completionEvidence: FinalizationCompletionEvidence? = nil) {
        self.location = location
        self.operation = operation
        self.completionEvidence = completionEvidence
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, location, operation, completionEvidence }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        location = try container.decode(SessionLocation.self, forKey: .location)
        operation = try container.decodeIfPresent(AudioFinalizationOperation.self, forKey: .operation) ?? .resume
        completionEvidence = try container.decodeIfPresent(FinalizationCompletionEvidence.self, forKey: .completionEvidence)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(location, forKey: .location)
        try container.encode(operation, forKey: .operation)
        try container.encodeIfPresent(completionEvidence, forKey: .completionEvidence)
    }
}

enum AudioFinalizationCode: String, Codable, Sendable, Error, CaseIterable {
    case invalidRequest, identityChanged, unsafeLayout, unsupportedSchema, corruptDocument
    case rootMissing, rootNotWritable, reauthorizationRequired, storageAccess
    case captureNotSettled, sourceMissing, sourceUnreadable, checkpointInconsistent
    case canonicalConflict, invalidContainer, invalidTracks, invalidFormat, invalidDuration
    case discontinuousTimeline, exportCreate, exportStart, exportRead, exportWrite, exportFinish
    case decode, publication, flush, persistence, diskFull, cancelled, completionEvidence, transcript
}

enum AudioFinalizationPhase: String, Codable, Sendable {
    case queued, securing, exporting, verifying, publishing, projecting, cleaning, cancelling
    case audioReadyAwaitingRemainingFinalization, audioRevalidated, recoveryAudioRemoved, failed
    case compactingTranscript, sessionReady
}

struct AudioEndpointReport: Codable, Sendable, Equatable {
    let sampleCount: Int
    let byteCount: Int
    let startSeconds: Double
    let endSeconds: Double
    let rms: Double
    let zeroCrossings: Int
}

struct AudioMediaReport: Codable, Sendable, Equatable {
    let durationSeconds: Double
    let sampleRate: Int
    let channels: Int
    let codec: String
    let packetCount: Int
    let compressedBytes: Int64
    let payloadSHA256: String
    let timelineStartSeconds: Double
    let timelineEndSeconds: Double
    let maximumGapSeconds: Double
    let bufferHighWaterBytes: Int
    let first: AudioEndpointReport
    let last: AudioEndpointReport

    var averageBitRate: Double { Double(compressedBytes) * 8 / durationSeconds }
}

/// File identity AND streaming content hash, not container equality between MOV and M4A.
struct FinalizationFileEvidence: Codable, Sendable, Equatable {
    let relativePath: String
    let device: Int64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let sha256: String
}

struct AudioFinalizationResult: Codable, Sendable, Equatable {
    let location: SessionLocation
    let phase: AudioFinalizationPhase
    let failure: AudioFinalizationCode?
    let warnings: [String]
    let media: AudioMediaReport?
    let source: FinalizationFileEvidence?
    let final: FinalizationFileEvidence?
    let completedSteps: [FinalizationStep]
    let retainedPaths: [String]
    /// Observed disk locations, including publication followed by checkpoint failure.
    /// Presence is not a claim that validation or directory synchronization succeeded.
    let presentPaths: [String]
    let recoveryWasRemoved: Bool
    var transcriptFailure: TranscriptFailure? = nil

    var canRetry: Bool { failure != nil }
    var permitsEssentialQuitAfterTranscriptFailure: Bool {
        transcriptFailure != nil && final != nil && completedSteps.contains(.finalM4AVerified) &&
            failure.map { [.transcript, .persistence, .flush, .diskFull].contains($0) } == true
    }
}

struct AudioFinalizationSnapshot: Codable, Sendable, Equatable {
    let location: SessionLocation
    let generation: UInt64
    let operation: AudioFinalizationOperation
    let phase: AudioFinalizationPhase
    let result: AudioFinalizationResult?

    private enum CodingKeys: String, CodingKey { case location, generation, operation, phase, result }

    /// Snapshots are diagnostic state, but an older queued snapshot may still be
    /// present when the app is upgraded.  Its only historical meaning was a
    /// resumable finalization, never evidence-only verification.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decode(SessionLocation.self, forKey: .location)
        generation = try container.decode(UInt64.self, forKey: .generation)
        operation = try container.decodeIfPresent(AudioFinalizationOperation.self, forKey: .operation) ?? .resume
        phase = try container.decode(AudioFinalizationPhase.self, forKey: .phase)
        result = try container.decodeIfPresent(AudioFinalizationResult.self, forKey: .result)
    }

    init(location: SessionLocation, generation: UInt64, operation: AudioFinalizationOperation,
         phase: AudioFinalizationPhase, result: AudioFinalizationResult?) {
        self.location = location
        self.generation = generation
        self.operation = operation
        self.phase = phase
        self.result = result
    }
}

/// Issued only after a trusted remaining-pipeline verifier checks these exact bytes.
/// The opaque seal prevents changing a proof after issuance. It is scoped to its issuer.
struct FinalizationCompletionEvidence: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    let location: SessionLocation
    let files: [FinalizationFileEvidence]
    let audio: AudioMediaReport
    let catalogProjection: CatalogProjection
    let seal: String
}

/// T20 supplies this verifier; T08 does not implement transcript generation or fake it.
/// Return the successfully committed/read-back catalog projection after validating
/// canonical transcript semantics and both derived files against the supplied hashes.
protocol RemainingFinalizationVerifying: Sendable {
    func verify(location: SessionLocation, files: [FinalizationFileEvidence]) async throws -> CatalogProjection
}

protocol AudioFinalizationWorking: Sendable {
    func finalize(_ request: AudioFinalizationRequest, control: AudioFinalizationControl,
                  progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult
    func removeRecovery(_ evidence: FinalizationCompletionEvidence, control: AudioFinalizationControl,
                        progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult
}

/// Synchronous arbitration also covers failures arriving while an async write is pending.
/// Caller task cancellation is intentionally unrelated to explicit operation cancellation.
final class AudioFinalizationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var first: AudioFinalizationCode?
    private var secondary: [String] = []
    private var deletionCommitted = false

    func fail(_ code: AudioFinalizationCode) {
        lock.withLock {
            if first == nil { first = code }
            else if first != code { secondary.append(code.rawValue) }
        }
    }
    func cancel() { lock.withLock { if !deletionCommitted && first == nil { first = .cancelled } } }
    func check() throws { try lock.withLock { if let first { throw first } } }
    func warning(_ code: String) { lock.withLock { secondary.append(code) } }
    func outcome() -> (AudioFinalizationCode?, [String]) { lock.withLock { (first, secondary) } }
    func commitDeletion(_ body: () throws -> Void) throws {
        try lock.withLock {
            if let first { throw first }
            try body()
            deletionCommitted = true
        }
    }
}

enum AudioFinalizationPolicy {
    static let durationToleranceSeconds = 0.150
    static func validateDuration(_ duration: Double, against expected: Double) throws {
        guard duration.isFinite, expected.isFinite, duration > 0, expected > 0,
              abs(duration - expected) <= durationToleranceSeconds + 1e-9 else {
            throw AudioFinalizationCode.invalidDuration
        }
    }
}
