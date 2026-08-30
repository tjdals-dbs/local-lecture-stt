import Foundation

enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case preparing
    case recording
    case paused
    case securing
    case finalizing
    case completed
    case interrupted
    case error
    case missing
}

enum CaptureOutcome: String, Codable, Sendable, CaseIterable {
    case notStarted
    case inProgress
    case completed
    case interrupted
}

/// A synchronous lifecycle rule. Applying the current status is an explicit no-op.
struct SessionLifecycle: Codable, Sendable, Equatable {
    let status: SessionStatus
    let captureOutcome: CaptureOutcome

    init(status: SessionStatus, captureOutcome: CaptureOutcome) throws {
        guard Self.isValid(status: status, captureOutcome: captureOutcome) else {
            throw DomainValidationError.invalidLifecycleCombination(status: status, outcome: captureOutcome)
        }
        self.status = status
        self.captureOutcome = captureOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            status: container.decode(SessionStatus.self, forKey: .status),
            captureOutcome: container.decode(CaptureOutcome.self, forKey: .captureOutcome)
        )
    }

    func transition(to target: SessionStatus) throws -> SessionLifecycle {
        if target == status {
            return self
        }

        switch (status, target) {
        case (.preparing, .recording):
            return try SessionLifecycle(status: .recording, captureOutcome: .inProgress)
        case (.recording, .paused), (.paused, .recording):
            return try SessionLifecycle(status: target, captureOutcome: .inProgress)
        case (.recording, .securing), (.paused, .securing):
            return try SessionLifecycle(status: .securing, captureOutcome: .completed)
        case (.recording, .interrupted), (.paused, .interrupted):
            return try SessionLifecycle(status: .interrupted, captureOutcome: .interrupted)
        case (.securing, .finalizing):
            return try SessionLifecycle(status: .finalizing, captureOutcome: captureOutcome)
        case (.finalizing, .completed) where captureOutcome == .completed:
            return try SessionLifecycle(status: .completed, captureOutcome: .completed)
        case (.interrupted, .securing), (.interrupted, .finalizing):
            return try SessionLifecycle(status: target, captureOutcome: .interrupted)
        case (.securing, .interrupted) where captureOutcome == .interrupted:
            return try SessionLifecycle(status: .interrupted, captureOutcome: .interrupted)
        case (.finalizing, .interrupted) where captureOutcome == .interrupted:
            return try SessionLifecycle(status: .interrupted, captureOutcome: .interrupted)
        case (_, .error) where Self.isProcessing(status):
            return try SessionLifecycle(status: .error, captureOutcome: captureOutcome)
        case (_, .missing) where Self.isProcessing(status):
            return try SessionLifecycle(status: .missing, captureOutcome: captureOutcome)
        default:
            throw DomainValidationError.invalidTransition(from: status, to: target, outcome: captureOutcome)
        }
    }

    private static func isProcessing(_ status: SessionStatus) -> Bool {
        switch status {
        case .preparing, .recording, .paused, .securing, .finalizing, .interrupted:
            true
        case .completed, .error, .missing:
            false
        }
    }

    private static func isValid(status: SessionStatus, captureOutcome: CaptureOutcome) -> Bool {
        switch status {
        case .preparing:
            captureOutcome == .notStarted
        case .recording, .paused:
            captureOutcome == .inProgress
        case .securing, .finalizing:
            captureOutcome == .completed || captureOutcome == .interrupted
        case .completed:
            captureOutcome == .completed
        case .interrupted:
            captureOutcome == .interrupted
        case .error, .missing:
            true
        }
    }
}
