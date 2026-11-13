import Foundation

struct ModelDownloadID: Codable, Sendable, Equatable, Hashable { let rawValue: UUID; init() { rawValue = UUID() }; init(rawValue: UUID) { self.rawValue = rawValue } }
enum ModelDownloadCode: String, Codable, Sendable, Error {
    case notDownloadable, capacityUnknown, insufficientCapacity, overflow, invalidState, unsupportedState
    case transport, httpStatus, redirectRejected, receiptMissing, byteCount, diskWrite, invalidResume, resourceChanged
    case interrupted, cancelled, ownership, journal, busy, install, cleanup
}
struct ModelDownloadFailure: Error, Codable, Sendable, Equatable {
    let code: ModelDownloadCode
    var transportCode: Int? = nil
    var httpStatus: Int? = nil
    var repository: ModelOperationFailure? = nil
    var cleanup: ModelDownloadCode? = nil
}
struct ModelDownloadCapacity: Codable, Sendable, Equatable {
    let payloadBytes: Int64
    let retainedCompletedBytes: Int64
    let requiredAdditionalBytes: Int64
    let availableBytes: Int64
    /// Three payload copies reserve the OS temporary/resume footprint, owned copy,
    /// and shared installer staging. Completed owned bytes already occupy capacity.
    static let safetyBytes: Int64 = 16 * 1024 * 1024
    static func assess(lengths: [Int64], completed: Int64, available: Int64?) throws -> Self {
        var sum: Int64 = 0
        for n in lengths {
            let next = sum.addingReportingOverflow(n)
            guard n >= 0, !next.overflow else { throw ModelDownloadFailure(code: .overflow) }; sum = next.partialValue
        }
        let triple = sum.multipliedReportingOverflow(by: 3)
        guard !triple.overflow, completed >= 0, completed <= sum else { throw ModelDownloadFailure(code: .overflow) }
        let needed = (triple.partialValue - completed).addingReportingOverflow(safetyBytes)
        guard !needed.overflow else { throw ModelDownloadFailure(code: .overflow) }
        guard let available, available >= 0 else { throw ModelDownloadFailure(code: .capacityUnknown) }
        return .init(payloadBytes: sum, retainedCompletedBytes: completed, requiredAdditionalBytes: needed.partialValue, availableBytes: available)
    }
    var sufficient: Bool { availableBytes >= requiredAdditionalBytes }
}
enum ModelDownloadPhase: String, Codable, Sendable { case transferring, paused, installing, installed, failed, cancelled }
struct ModelDownloadSnapshot: Codable, Sendable, Equatable {
    let id: ModelDownloadID
    let key: InstalledModelKey
    let generation: Int
    var phase: ModelDownloadPhase
    var completedBytes: Int64
    let totalBytes: Int64
    var resumedOffset: Int64 = 0
    var continuedExistingTask: Bool = false
    var restartedFromZero: Bool = false
    var resumeFailure: ModelDownloadFailure? = nil
    var resumable: Bool = false
    var result: ModelImportResult? = nil
    var failure: ModelDownloadFailure? = nil
    var terminal: Bool { phase == .installed || phase == .failed || phase == .cancelled }
}
struct ModelDownloadPending: Codable, Sendable, Equatable {
    let operation: ModelDownloadID?
    let snapshot: ModelDownloadSnapshot?
    let issue: ModelDownloadCode?
}
protocol ModelDownloading: Sendable {
    func start(_ key: InstalledModelKey) async throws -> ModelDownloadID
    func retry(_ id: ModelDownloadID) async throws -> ModelDownloadID
    func resume(_ id: ModelDownloadID) async throws
    func pause(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot
    func cancel(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot
    func snapshot(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot
    func wait(_ id: ModelDownloadID) async throws -> ModelDownloadSnapshot
    func pending() async throws -> [ModelDownloadPending]
}
