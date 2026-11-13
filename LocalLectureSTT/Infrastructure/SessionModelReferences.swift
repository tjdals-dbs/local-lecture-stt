import Foundation

/// Reads active and historical registered roots. No catalog, recovery operation,
/// directory creation or session write participates in reference discovery.
struct SessionModelReferenceChecker: ModelReferenceChecking {
    let roots: StorageRootManager
    func references(to descriptor: ModelPackageDescriptor) async -> ModelReferenceReport {
        do {
            let catalog = try await roots.storageRootCatalog()
            var sessions = [ModelSessionReference](); var warnings = [String]()
            for reference in catalog.roots {
                do {
                    let result = try await roots.withReadAccess(to: reference.id) { url in
                        try Self.scan(url, rootID: reference.id, descriptor: descriptor)
                    }
                    sessions += result.sessions; warnings += result.warnings
                } catch { warnings.append("Root unavailable: \(reference.id.rawValue.uuidString)") }
            }
            return .init(sessions: sessions.sorted { $0.rootID.rawValue.uuidString + $0.sessionID.rawValue.uuidString < $1.rootID.rawValue.uuidString + $1.sessionID.rawValue.uuidString }, warnings: warnings.sorted())
        } catch { return .init(sessions: [], warnings: ["Registered roots unavailable"]) }
    }
    static func scan(_ url: URL, rootID: StorageRootID, descriptor: ModelPackageDescriptor) throws -> ModelReferenceReport {
        let root = try ModelPackageDirectory(url: url)
        var sessions = [ModelSessionReference](); var warnings = [String]()
        for name in try root.names() {
            // A root may contain unrelated files; session candidates use the canonical naming contract.
            guard let folder = try? SessionFolderName(validating: name) else { continue }
            do {
                let directory = try root.child(name)
                let metadata = try JSONDecoder().decode(SessionMetadataDocument.self, from: directory.readMetadata("metadata.json"))
                guard folder.matches(metadata.sessionId) else { throw ModelRepositoryCode.identityChanged }
                if let model = metadata.model {
                    guard let engine = metadata.engine else { throw ModelRepositoryCode.invalidDescriptor }
                    if engine.id == descriptor.engine.id, model.id == descriptor.model.id, model.revision == descriptor.model.revision {
                        // Even conflicting provenance is a reference requiring warning, never a false nonreference.
                        sessions.append(.init(rootID: rootID, sessionID: metadata.sessionId,
                                              checksumMatches: model.checksum == descriptor.model.checksum && engine.version == descriptor.engine.version))
                    }
                }
            } catch { warnings.append("Unreadable session: \(rootID.rawValue.uuidString)/\(name)") }
        }
        try root.check()
        return .init(sessions: sessions, warnings: warnings)
    }
}
