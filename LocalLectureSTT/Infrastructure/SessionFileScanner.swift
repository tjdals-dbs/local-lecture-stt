import Foundation

actor SessionFileScanner: SessionFileScanning {
    private let roots: StorageRootManager

    init(roots: StorageRootManager) {
        self.roots = roots
    }

    func scan() async throws -> [RootScanResult] {
        let catalog = try await roots.storageRootCatalog()
        return await withTaskGroup(of: RootScanResult.self) { group in
            for reference in catalog.roots {
                group.addTask { [roots] in await Self.scan(reference: reference, roots: roots) }
            }
            var results: [RootScanResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.rootID.rawValue.uuidString < $1.rootID.rawValue.uuidString }
        }
    }

    private static func scan(reference: StorageRootReference, roots: StorageRootManager) async -> RootScanResult {
        do {
            return try await roots.withReadAccess(to: reference.id) { root in
                try scanRoot(root, rootID: reference.id)
            }
        } catch {
            return RootScanResult(
                rootID: reference.id,
                outcome: .unavailable,
                projections: [],
                unreadableFolderNames: [],
                missingFolderNames: [],
                issues: [CatalogIssue(code: .rootUnavailable, rootID: reference.id, folderName: nil)]
            )
        }
    }

    private static func scanRoot(_ root: URL, rootID: StorageRootID) throws -> RootScanResult {
        let manager = FileManager.default
        let children: [URL]
        do {
            children = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return RootScanResult(rootID: rootID, outcome: .partial, projections: [], unreadableFolderNames: [], missingFolderNames: [], issues: [CatalogIssue(code: .filesystemScanFailed, rootID: rootID, folderName: nil)])
        }

        var projections: [CatalogProjection] = []
        var unreadable: [String] = []
        var missing: [String] = []
        var issues: [CatalogIssue] = []

        for child in children {
            let folder = child.lastPathComponent
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                issues.append(CatalogIssue(code: .sessionDirectorySymlink, rootID: rootID, folderName: folder))
                continue
            }
            let folderName: SessionFolderName
            do { folderName = try SessionFolderName(validating: folder) }
            catch {
                if folder.range(of: "^[0-9]{8}-", options: .regularExpression) != nil {
                    issues.append(CatalogIssue(code: .invalidFolderName, rootID: rootID, folderName: folder))
                }
                continue
            }

            let metadataURL = child.appendingPathComponent(SessionArtifact.metadata.relativePath, isDirectory: false)
            guard manager.fileExists(atPath: metadataURL.path) else {
                missing.append(folder)
                issues.append(CatalogIssue(code: .metadataMissing, rootID: rootID, folderName: folder))
                continue
            }
            let metadataValues = try? metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard metadataValues?.isSymbolicLink != true, metadataValues?.isRegularFile == true else {
                unreadable.append(folder)
                issues.append(CatalogIssue(code: .metadataInvalid, rootID: rootID, folderName: folder))
                continue
            }
            do {
                let document = try JSONDecoder().decode(SessionMetadataDocument.self, from: Data(contentsOf: metadataURL))
                guard folderName.matches(document.sessionId) else {
                    unreadable.append(folder)
                    issues.append(CatalogIssue(code: .sessionIDMismatch, rootID: rootID, folderName: folder))
                    continue
                }
                projections.append(CatalogProjection(metadata: document, location: SessionLocation(rootID: rootID, sessionID: document.sessionId, folderName: folderName)))
            } catch DomainValidationError.unsupportedSchemaVersion {
                unreadable.append(folder)
                issues.append(CatalogIssue(code: .metadataUnsupported, rootID: rootID, folderName: folder))
            } catch {
                unreadable.append(folder)
                issues.append(CatalogIssue(code: .metadataCorrupt, rootID: rootID, folderName: folder))
            }
        }
        return RootScanResult(rootID: rootID, outcome: .complete, projections: projections, unreadableFolderNames: unreadable, missingFolderNames: missing, issues: issues)
    }
}
