import Foundation

struct ModelImportSourceID: Codable, Sendable, Equatable, Hashable { let rawValue: UUID; init() { rawValue = UUID() } }
enum ModelPackageState: String, Codable, Sendable { case usable, corrupt, incompatible, unvalidated, unsupportedSchema, inaccessible }
struct ModelInventoryEntry: Codable, Sendable, Equatable {
    /// Opaque namespace identifier, never a path that callers may mutate.
    let namespace: String
    let manifest: ModelInstallationManifest?
    let state: ModelPackageState
    let issue: ModelRepositoryCode?
}
struct ModelImportResult: Codable, Sendable, Equatable {
    enum Disposition: String, Codable, Sendable { case installed, alreadyInstalled }
    let disposition: Disposition
    let manifest: ModelInstallationManifest
    /// Publication is committed even if cancellation or a durability/access warning arrives afterward.
    let warning: ModelRepositoryCode?
}
struct ModelOperationFailure: Error, Codable, Sendable, Equatable {
    let cause: ModelRepositoryCode
    let cleanupIssue: ModelRepositoryCode?
    let retainedOperation: UUID?
    init(_ cause: ModelRepositoryCode, cleanupIssue: ModelRepositoryCode? = nil, retainedOperation: UUID? = nil) {
        self.cause = cause; self.cleanupIssue = cleanupIssue; self.retainedOperation = retainedOperation
    }
}
struct ModelSessionReference: Codable, Sendable, Equatable {
    let rootID: StorageRootID
    let sessionID: SessionID
    let checksumMatches: Bool
}
struct ModelReferenceReport: Codable, Sendable, Equatable {
    let sessions: [ModelSessionReference]
    let warnings: [String]
    var isComplete: Bool { warnings.isEmpty }
}
struct ModelDeletionAssessment: Codable, Sendable, Equatable {
    let id: UUID
    let key: InstalledModelKey
    let packageFingerprint: String
    let references: ModelReferenceReport
}
struct ModelDeletionConfirmation: Codable, Sendable, Equatable {
    let assessmentID: UUID
    let acknowledgeReferences: Bool
    let acknowledgeIncompleteCoverage: Bool
}
struct ModelDeletionResult: Codable, Sendable, Equatable { let key: InstalledModelKey }

/// A corrupt manifest cannot supply a trusted model identity. Recovery addresses
/// an opaque inventory namespace and preserves the entire directory, never deletes it.
struct ModelRecoveryAssessment: Codable, Sendable, Equatable {
    let id: UUID
    let namespace: String
    let fingerprint: String
}
struct ModelRecoveryConfirmation: Codable, Sendable, Equatable {
    let assessmentID: UUID
    let acknowledgeUnidentifiedReferences: Bool
}
struct ModelRecoveryResult: Codable, Sendable, Equatable {
    let retainedID: UUID
    let warning: ModelRepositoryCode?
}
struct ModelImportCapacity: Codable, Sendable, Equatable {
    static let safetyBytes: Int64 = 16 * 1024 * 1024
    let requiredBytes: Int64
    let availableBytes: Int64
    static func assess(lengths: [Int64], available: Int64?) throws -> Self {
        var required = safetyBytes // One independent payload copy plus metadata/filesystem reserve.
        for length in lengths {
            let next = required.addingReportingOverflow(length)
            guard length >= 0, !next.overflow else { throw ModelRepositoryCode.capacityOverflow }
            required = next.partialValue
        }
        guard let available, available >= 0 else { throw ModelRepositoryCode.capacityUnknown }
        guard available >= required else { throw ModelRepositoryCode.insufficientCapacity }
        return .init(requiredBytes: required, availableBytes: available)
    }
}

protocol ModelReferenceChecking: Sendable {
    func references(to descriptor: ModelPackageDescriptor) async -> ModelReferenceReport
}
protocol ModelRepository: Sendable {
    func catalog() async throws -> BundledModelCatalog
    func inventory() async throws -> [ModelInventoryEntry]
    func validate(_ key: InstalledModelKey) async throws -> ModelInventoryEntry
    func importPackage(from source: ModelImportSourceID, descriptor: ModelPackageDescriptor?, origin: ModelPackageOrigin) async throws -> ModelImportResult
    func prepareDeletion(_ key: InstalledModelKey) async throws -> ModelDeletionAssessment
    func delete(_ assessment: ModelDeletionAssessment, confirmation: ModelDeletionConfirmation?) async throws -> ModelDeletionResult
    func prepareRecovery(namespace: String) async throws -> ModelRecoveryAssessment
    func preserveForRecovery(_ assessment: ModelRecoveryAssessment, confirmation: ModelRecoveryConfirmation?) async throws -> ModelRecoveryResult
}

extension ModelRepository {
    func prepareRecovery(namespace: String) async throws -> ModelRecoveryAssessment { throw ModelOperationFailure(.invalidDescriptor) }
    func preserveForRecovery(_ assessment: ModelRecoveryAssessment, confirmation: ModelRecoveryConfirmation?) async throws -> ModelRecoveryResult {
        throw ModelOperationFailure(.invalidDescriptor)
    }
}
