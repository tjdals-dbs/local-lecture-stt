import Foundation

struct SessionID: Codable, Sendable, Hashable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct StorageRootID: Codable, Sendable, Hashable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct TranscriptSegmentID: Codable, Sendable, Hashable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SessionEventID: Codable, Sendable, Hashable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct EngineID: Codable, Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        try DomainValidation.requireNonEmpty(rawValue, field: "engine id")
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ModelID: Codable, Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        try DomainValidation.requireNonEmpty(rawValue, field: "model id")
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct LanguageCode: Codable, Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) throws {
        try DomainValidation.requireNonEmpty(rawValue, field: "language code")
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct EngineIdentity: Codable, Sendable, Equatable {
    let id: EngineID
    let version: String

    init(id: EngineID, version: String) throws {
        try DomainValidation.requireNonEmpty(version, field: "engine version")
        self.id = id
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(EngineID.self, forKey: .id),
            version: container.decode(String.self, forKey: .version)
        )
    }
}

struct ModelIdentity: Codable, Sendable, Equatable {
    let id: ModelID
    let revision: String
    let checksum: String

    init(id: ModelID, revision: String, checksum: String) throws {
        try DomainValidation.requireNonEmpty(revision, field: "model revision")
        try DomainValidation.requireNonEmpty(checksum, field: "model checksum")
        self.id = id
        self.revision = revision
        self.checksum = checksum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ModelID.self, forKey: .id),
            revision: container.decode(String.self, forKey: .revision),
            checksum: container.decode(String.self, forKey: .checksum)
        )
    }
}

enum LanguageMode: String, Codable, Sendable, CaseIterable {
    case korean
    case english
    case automatic
}
