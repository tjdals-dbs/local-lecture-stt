import CryptoKit
import Foundation

enum ModelRepositoryCode: String, Error, Codable, Sendable, Equatable {
    case invalidDescriptor, unsupportedSchema, descriptorRequired, storageUnavailable, unsafeLayout
    case integrityMismatch, incompatible, validationUnavailable, sourceUnavailable, scopeDenied
    case collision, busy, staleAssessment, confirmationRequired, acknowledgmentRequired
    case cancelled, copyFailed, hashFailed, manifestWriteFailed, flushFailed, publishFailed
    case cleanupFailed, deletionFailed, incompleteRemoval, identityChanged
}

/// Values are logical identities, never pathname fragments.
struct InstalledModelKey: Codable, Sendable, Equatable, Hashable {
    let engineID: EngineID
    let modelID: ModelID
    let revision: String

    init(engineID: EngineID, modelID: ModelID, revision: String) throws {
        for value in [engineID.rawValue, modelID.rawValue, revision] { try ModelPackageRules.text(value) }
        self.engineID = engineID; self.modelID = modelID; self.revision = revision
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(engineID: c.decode(EngineID.self, forKey: .engineID),
                      modelID: c.decode(ModelID.self, forKey: .modelID), revision: c.decode(String.self, forKey: .revision))
    }
}

enum ModelPackageRules {
    static func text(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 1024, !text.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw ModelRepositoryCode.invalidDescriptor
        }
    }
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ModelRepositoryCode.invalidDescriptor
        }
    }
    static func path(_ path: String) throws {
        guard path.utf8.count <= 2048, !path.contains("\\"), !path.contains(":"),
              path.utf8.elementsEqual(path.precomposedStringWithCanonicalMapping.utf8) else { throw ModelRepositoryCode.unsafeLayout }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 32 else { throw ModelRepositoryCode.unsafeLayout }
        for part in parts {
            let name = String(part)
            try text(name)
            guard name != ".", name != "..", !name.isEmpty, name.utf8.count <= 240,
                  !name.hasPrefix("."), name.lowercased() != "manifest.json" else { throw ModelRepositoryCode.unsafeLayout }
        }
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Length-framed UTF-8 records avoid delimiter ambiguity; payload order and relocation are irrelevant.
    static func packageDigest(_ files: [ModelPayloadFile]) -> String {
        var data = Data("LocalLectureSTT.payload.v1\n".utf8)
        for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            for value in [file.path, String(file.byteCount), file.sha256] {
                data.append(Data("\(value.utf8.count):".utf8)); data.append(Data(value.utf8))
            }
        }
        return sha256(data)
    }
}

struct ModelPayloadFile: Codable, Sendable, Equatable {
    let path: String
    let byteCount: Int64
    let sha256: String
    init(path: String, byteCount: Int64, sha256: String) throws {
        try ModelPackageRules.path(path); try ModelPackageRules.digest(sha256)
        guard byteCount >= 0 else { throw ModelRepositoryCode.invalidDescriptor }
        self.path = path; self.byteCount = byteCount; self.sha256 = sha256
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(path: c.decode(String.self, forKey: .path), byteCount: c.decode(Int64.self, forKey: .byteCount),
                      sha256: c.decode(String.self, forKey: .sha256))
    }
}

struct ModelPackageDescriptor: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let engine: EngineIdentity
    let model: ModelIdentity
    let format: String
    let variant: String
    let quantization: String
    let compute: String
    let licenseIdentifier: String
    let licenseTextOrReference: String
    let licenseProvenance: String
    let files: [ModelPayloadFile]
    var key: InstalledModelKey { // All fields were validated at construction/decoding.
        try! InstalledModelKey(engineID: engine.id, modelID: model.id, revision: model.revision)
    }
    init(schemaVersion: Int = 1, engine: EngineIdentity, modelID: ModelID, revision: String,
         format: String, variant: String, quantization: String, compute: String,
         licenseIdentifier: String, licenseTextOrReference: String, licenseProvenance: String,
         files: [ModelPayloadFile], checksum: String? = nil) throws {
        guard schemaVersion == 1 else { throw ModelRepositoryCode.unsupportedSchema }
        _ = try InstalledModelKey(engineID: engine.id, modelID: modelID, revision: revision)
        for value in [engine.version, format, variant, quantization, compute, licenseIdentifier, licenseProvenance] {
            try ModelPackageRules.text(value)
        }
        guard !licenseTextOrReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              licenseTextOrReference.utf8.count <= 65_536, !files.isEmpty, files.count <= 4096 else {
            throw ModelRepositoryCode.invalidDescriptor
        }
        var nodes = [String: String](); var leaves = Set<String>(); var total: Int64 = 0
        for file in files {
            let sum = total.addingReportingOverflow(file.byteCount)
            guard !sum.overflow else { throw ModelRepositoryCode.invalidDescriptor }; total = sum.partialValue
            let parts = file.path.split(separator: "/").map(String.init)
            var path = ""
            for (i, part) in parts.enumerated() {
                path = path.isEmpty ? part : path + "/" + part
                let folded = path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if let previous = nodes[folded], previous != path { throw ModelRepositoryCode.unsafeLayout }
                nodes[folded] = path
                if i < parts.count - 1, leaves.contains(folded) { throw ModelRepositoryCode.unsafeLayout }
                if i == parts.count - 1 {
                    guard !leaves.contains(folded), !nodes.keys.contains(where: { $0.hasPrefix(folded + "/") }) else {
                        throw ModelRepositoryCode.unsafeLayout
                    }
                    leaves.insert(folded)
                }
            }
        }
        let digest = ModelPackageRules.packageDigest(files)
        if let checksum { try ModelPackageRules.digest(checksum); guard checksum == digest else { throw ModelRepositoryCode.invalidDescriptor } }
        self.schemaVersion = schemaVersion; self.engine = engine
        model = try ModelIdentity(id: modelID, revision: revision, checksum: digest)
        self.format = format; self.variant = variant; self.quantization = quantization; self.compute = compute
        self.licenseIdentifier = licenseIdentifier; self.licenseTextOrReference = licenseTextOrReference
        self.licenseProvenance = licenseProvenance; self.files = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ModelRepositoryCode.unsupportedSchema }
        let model = try c.decode(ModelIdentity.self, forKey: .model)
        try self.init(schemaVersion: version, engine: c.decode(EngineIdentity.self, forKey: .engine),
                      modelID: model.id, revision: model.revision, format: c.decode(String.self, forKey: .format),
                      variant: c.decode(String.self, forKey: .variant), quantization: c.decode(String.self, forKey: .quantization),
                      compute: c.decode(String.self, forKey: .compute), licenseIdentifier: c.decode(String.self, forKey: .licenseIdentifier),
                      licenseTextOrReference: c.decode(String.self, forKey: .licenseTextOrReference),
                      licenseProvenance: c.decode(String.self, forKey: .licenseProvenance),
                      files: c.decode([ModelPayloadFile].self, forKey: .files), checksum: model.checksum)
    }
}

struct BundledModelCatalog: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let entries: [ModelPackageDescriptor]
    /// Optional v1 extension; excluded from installed identities and manifests.
    let deliveries: [ModelDelivery]
    init(schemaVersion: Int = 1, entries: [ModelPackageDescriptor], deliveries: [ModelDelivery] = []) throws {
        guard schemaVersion == 1 else { throw ModelRepositoryCode.unsupportedSchema }
        guard entries.count <= 4096, Set(entries.map(\.key)).count == entries.count else { throw ModelRepositoryCode.invalidDescriptor }
        guard deliveries.count <= entries.count, Set(deliveries.map(\.key)).count == deliveries.count else {
            throw ModelRepositoryCode.invalidDescriptor
        }
        for delivery in deliveries {
            guard let descriptor = entries.first(where: { $0.key == delivery.key }),
                  delivery.locations.map(\.path).sorted() == descriptor.files.map(\.path).sorted() else {
                throw ModelRepositoryCode.invalidDescriptor
            }
        }
        self.schemaVersion = schemaVersion; self.entries = entries; self.deliveries = deliveries
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ModelRepositoryCode.unsupportedSchema }
        try self.init(schemaVersion: version, entries: c.decode([ModelPackageDescriptor].self, forKey: .entries),
                      deliveries: c.decodeIfPresent([ModelDelivery].self, forKey: .deliveries) ?? [])
    }
}

enum ModelPackageOrigin: String, Codable, Sendable { case suppliedLocal, bundledCatalog }
struct ModelInstallationManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let descriptor: ModelPackageDescriptor
    let origin: ModelPackageOrigin
    let installedAt: AbsoluteTime
    init(schemaVersion: Int = 1, descriptor: ModelPackageDescriptor, origin: ModelPackageOrigin, installedAt: AbsoluteTime) throws {
        guard schemaVersion == 1 else { throw ModelRepositoryCode.unsupportedSchema }
        self.schemaVersion = schemaVersion; self.descriptor = descriptor; self.origin = origin; self.installedAt = installedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ModelRepositoryCode.unsupportedSchema }
        try self.init(schemaVersion: version, descriptor: c.decode(ModelPackageDescriptor.self, forKey: .descriptor),
                      origin: c.decode(ModelPackageOrigin.self, forKey: .origin), installedAt: c.decode(AbsoluteTime.self, forKey: .installedAt))
    }
}
