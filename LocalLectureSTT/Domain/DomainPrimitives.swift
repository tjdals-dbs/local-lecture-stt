import Foundation

enum DomainValidationError: Error, Equatable, Sendable {
    case emptyValue(field: String)
    case negativeMediaMilliseconds(Int64)
    case negativeSequence(Int64)
    case invalidSegmentBounds(start: Int64, end: Int64)
    case negativeSegmentCount(Int64)
    case invalidAudioDescription
    case unsupportedSchemaVersion(Int)
    case invalidLifecycleCombination(status: SessionStatus, outcome: CaptureOutcome)
    case invalidTransition(from: SessionStatus, to: SessionStatus, outcome: CaptureOutcome)
    case checkpointStepSkipped(expected: FinalizationStep, attempted: FinalizationStep)
    case checkpointStepRegression(completed: FinalizationStep, attempted: FinalizationStep)
    case invalidCheckpointProgress
}

enum DomainValidation {
    static func requireNonEmpty(_ value: String, field: String) throws {
        guard !value.isEmpty else {
            throw DomainValidationError.emptyValue(field: field)
        }
    }
}

struct SchemaVersion: Codable, Sendable, Equatable, Hashable {
    static let current = SchemaVersion(rawValue: 1)

    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SchemaVersionPolicy {
    static func validate(_ schemaVersion: SchemaVersion) throws {
        guard schemaVersion == .current else {
            throw DomainValidationError.unsupportedSchemaVersion(schemaVersion.rawValue)
        }
    }
}

struct AbsoluteTime: Codable, Sendable, Equatable, Hashable {
    let value: Date

    init(_ value: Date) {
        let milliseconds = (value.timeIntervalSince1970 * 1_000).rounded()
        self.value = Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) ?? fallbackFormatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 timestamp with a timezone.")
        }
        self.init(date)
    }

    func encode(to encoder: Encoder) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var container = encoder.singleValueContainer()
        try container.encode(formatter.string(from: value))
    }
}

struct MediaMilliseconds: Codable, Sendable, Equatable, Hashable, Comparable {
    let rawValue: Int64

    init(_ rawValue: Int64) throws {
        guard rawValue >= 0 else {
            throw DomainValidationError.negativeMediaMilliseconds(rawValue)
        }
        self.rawValue = rawValue
    }

    static func < (lhs: MediaMilliseconds, rhs: MediaMilliseconds) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(Int64.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TranscriptSegmentSequence: Codable, Sendable, Equatable, Hashable, Comparable {
    let rawValue: Int64

    init(_ rawValue: Int64) throws {
        guard rawValue >= 0 else {
            throw DomainValidationError.negativeSequence(rawValue)
        }
        self.rawValue = rawValue
    }

    static func < (lhs: TranscriptSegmentSequence, rhs: TranscriptSegmentSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(Int64.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TranscriptSegmentCount: Codable, Sendable, Equatable, Hashable {
    let rawValue: Int64

    init(_ rawValue: Int64) throws {
        guard rawValue >= 0 else {
            throw DomainValidationError.negativeSegmentCount(rawValue)
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(Int64.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
