import Foundation

actor SessionCatalogReconciler: SessionCataloging {
    private let scanner: any SessionFileScanning
    private let store: any SessionCatalogStore
    private let now: @Sendable () -> AbsoluteTime

    init(scanner: any SessionFileScanning, store: any SessionCatalogStore, now: @escaping @Sendable () -> AbsoluteTime = { AbsoluteTime(Date()) }) {
        self.scanner = scanner
        self.store = store
        self.now = now
    }

    func reconcile() async throws -> CatalogReconciliationReport {
        let scanned: [RootScanResult]
        do {
            scanned = try await scanner.scan()
        } catch let error as StorageError {
            switch error.code {
            case .registryCorrupt, .registryUnsupported:
                throw CatalogError(.storageRootRegistryFailed)
            default:
                throw CatalogError(.filesystemScanFailed)
            }
        }
        let results = try await withConflictIssues(scanned)
        let issues = results.flatMap(\.issues)
        let recovered = await store.recoveredFromCorruption()
        try await store.apply(results, catalogUpdatedAt: now())
        return CatalogReconciliationReport(rootResults: results, issues: issues, recoveredFromCorruption: recovered)
    }

    func orderedItems() async throws -> [SessionCatalogItem] { try await store.orderedItems() }

    /// A file catalog is authoritative only when a single scan gives each session one
    /// unambiguous location.  Keep prior catalog rows unreadable rather than replacing
    /// or sweeping them when folders conflict.
    private func withConflictIssues(_ scanned: [RootScanResult]) async throws -> [RootScanResult] {
        var idCounts: [SessionID: Int] = [:]
        var locationCounts: [String: Int] = [:]
        for result in scanned {
            for projection in result.projections {
                idCounts[projection.location.sessionID, default: 0] += 1
                let location = "\(projection.location.rootID.rawValue.uuidString)/\(projection.location.folderName.rawValue)"
                locationCounts[location, default: 0] += 1
            }
        }
        var results: [RootScanResult] = []
        for result in scanned {
            var projections: [CatalogProjection] = []
            var unreadable = Set(result.unreadableFolderNames)
            var issues = result.issues
            for projection in result.projections {
                let location = "\(projection.location.rootID.rawValue.uuidString)/\(projection.location.folderName.rawValue)"
                let code: CatalogIssueCode?
                if idCounts[projection.location.sessionID, default: 0] > 1 { code = .duplicateSessionID }
                else if locationCounts[location, default: 0] > 1 { code = .locationConflict }
                else { code = nil }
                if let code {
                    let issue = CatalogIssue(code: code, rootID: result.rootID, folderName: projection.location.folderName.rawValue)
                    issues.append(issue)
                    unreadable.insert(projection.location.folderName.rawValue)
                } else {
                    if let existing = try await store.sessionID(at: projection.location.rootID, folderName: projection.location.folderName), existing != projection.location.sessionID {
                        // Preserve the last known row and mark it error; never let the
                        // file projection overwrite a different identity at this location.
                        issues.append(CatalogIssue(code: .locationConflict, rootID: result.rootID, folderName: projection.location.folderName.rawValue))
                        unreadable.insert(projection.location.folderName.rawValue)
                    } else {
                        projections.append(projection)
                    }
                }
            }
            results.append(RootScanResult(rootID: result.rootID, outcome: result.outcome, projections: projections, unreadableFolderNames: unreadable.sorted(), missingFolderNames: result.missingFolderNames, issues: issues))
        }
        return results
    }
}

actor UnavailableSessionCatalog: SessionCataloging {
    private let error: CatalogErrorCode
    init(error: CatalogErrorCode) { self.error = error }
    func reconcile() async throws -> CatalogReconciliationReport { throw CatalogError(error) }
    func orderedItems() async throws -> [SessionCatalogItem] { throw CatalogError(error) }
}
