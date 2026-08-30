import Foundation

enum FinalizationStep: String, Codable, Sendable, CaseIterable, Comparable {
    case workingAudioSecured
    case finalM4ACreated
    case finalM4AVerified
    case transcriptCompacted
    case derivedFilesGenerated
    case metadataCompleted
    case catalogUpdated
    case recoveryDataRemoved

    static func < (lhs: FinalizationStep, rhs: FinalizationStep) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

struct FinalizationCheckpointDocument: Codable, Sendable, Equatable {
    let schemaVersion: SchemaVersion
    let sessionId: SessionID
    let updatedAt: AbsoluteTime
    let completedSteps: [FinalizationStep]

    init(
        schemaVersion: SchemaVersion = .current,
        sessionId: SessionID,
        updatedAt: AbsoluteTime,
        completedSteps: [FinalizationStep] = []
    ) throws {
        try SchemaVersionPolicy.validate(schemaVersion)
        guard completedSteps == Array(FinalizationStep.allCases.prefix(completedSteps.count)) else {
            throw DomainValidationError.invalidCheckpointProgress
        }
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.completedSteps = completedSteps
    }

    func markingCompleted(_ step: FinalizationStep, at updatedAt: AbsoluteTime) throws -> FinalizationCheckpointDocument {
        if completedSteps.contains(step) {
            return self
        }

        let expected = FinalizationStep.allCases[completedSteps.count]
        guard step == expected else {
            if step < expected {
                throw DomainValidationError.checkpointStepRegression(completed: expected, attempted: step)
            }
            throw DomainValidationError.checkpointStepSkipped(expected: expected, attempted: step)
        }
        return try FinalizationCheckpointDocument(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            updatedAt: updatedAt,
            completedSteps: completedSteps + [step]
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(SchemaVersion.self, forKey: .schemaVersion),
            sessionId: container.decode(SessionID.self, forKey: .sessionId),
            updatedAt: container.decode(AbsoluteTime.self, forKey: .updatedAt),
            completedSteps: container.decode([FinalizationStep].self, forKey: .completedSteps)
        )
    }
}
