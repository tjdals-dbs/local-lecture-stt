import Darwin
import Foundation

actor SessionFileScanner: SessionFileScanning, SessionRecoveryScanning {
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

    /// Startup recovery intentionally enumerates the filesystem again rather
    /// than consulting SQLite.  The catalog is derived data and may be empty,
    /// stale, or unavailable while recoverable audio is still present.
    func scanForRecovery() async throws -> [RootRecoveryScanResult] {
        let catalog = try await roots.storageRootCatalog()
        return await withTaskGroup(of: RootRecoveryScanResult.self) { group in
            for reference in catalog.roots {
                group.addTask { [roots] in await Self.scanRecovery(reference: reference, roots: roots) }
            }
            var results: [RootRecoveryScanResult] = []
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

    private static func scanRecovery(reference: StorageRootReference, roots: StorageRootManager) async -> RootRecoveryScanResult {
        do {
            return try await roots.withReadAccess(to: reference.id) { root in
                try scanRecoveryRoot(root, rootID: reference.id)
            }
        } catch let error as StorageError {
            // A root which is present but no longer writable is actionable in a
            // different way from a missing bookmark/scope.  Keep the original
            // storage reason as the first diagnostic too: the recovery report
            // must not turn every root failure into an indistinguishable retry.
            let code: SessionRecoveryCode = error.code == .rootNotWritable ? .rootReadOnly : .rootUnavailable
            return RootRecoveryScanResult(rootID: reference.id, candidates: [], issues: [
                .init(rootID: reference.id, folderName: nil, sessionID: nil, code: code,
                      preserved: true, retryable: true, warning: error.code.rawValue)
            ])
        } catch {
            return RootRecoveryScanResult(rootID: reference.id, candidates: [], issues: [
                .init(rootID: reference.id, folderName: nil, sessionID: nil, code: .rootUnavailable,
                      preserved: true, retryable: true, warning: "readAccessFailed")
            ])
        }
    }

    private static func scanRecoveryRoot(_ root: URL, rootID: StorageRootID) throws -> RootRecoveryScanResult {
        let manager = FileManager.default
        let writable = (try? root.resourceValues(forKeys: [.isWritableKey]).isWritable) != false
        let children: [URL]
        do {
            children = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return RootRecoveryScanResult(rootID: rootID, candidates: [], issues: [
                .init(rootID: rootID, folderName: nil, sessionID: nil, code: .rootUnavailable,
                      preserved: true, retryable: true, warning: "enumerationFailed")
            ])
        }

        var candidates: [SessionRecoveryCandidate] = []
        var issues: [SessionRecoveryIssue] = []
        var identifiedLocations: [SessionLocation] = []
        for child in children {
            let folder = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: nil, code: .unsafeLayout,
                                    preserved: true, retryable: false, warning: "sessionDirectorySymlink"))
                continue
            }
            guard values?.isDirectory == true else { continue }
            guard let folderName = try? SessionFolderName(validating: folder) else { continue }
            let metadataURL = child.appendingPathComponent(SessionArtifact.metadata.relativePath)
            let metadataValues = try? metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard Self.entryExists(metadataURL) else {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: nil, code: .metadataMissing,
                                    preserved: true, retryable: true, warning: nil))
                continue
            }
            guard metadataValues?.isSymbolicLink != true, metadataValues?.isRegularFile == true else {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: nil, code: .unsafeLayout,
                                    preserved: true, retryable: false, warning: "metadataLayout"))
                continue
            }
            let metadata: SessionMetadataDocument
            do {
                metadata = try JSONDecoder().decode(SessionMetadataDocument.self, from: Data(contentsOf: metadataURL))
            } catch DomainValidationError.unsupportedSchemaVersion {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: nil, code: .metadataUnsupported,
                                    preserved: true, retryable: false, warning: nil))
                continue
            } catch {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: nil, code: .metadataCorrupt,
                                    preserved: true, retryable: false, warning: nil))
                continue
            }
            guard folderName.matches(metadata.sessionId) else {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .sessionIDMismatch,
                                    preserved: true, retryable: false, warning: nil))
                continue
            }
            let location = SessionLocation(rootID: rootID, sessionID: metadata.sessionId, folderName: folderName)
            // A valid metadata/folder identity is already sufficient to make a
            // duplicate dangerous.  Keep it even if a later checkpoint or
            // protected artifact inspection quarantines this folder.
            identifiedLocations.append(location)
            let protectedPaths = [SessionArtifact.recoveryAudio.relativePath, "audio.finalizing.m4a", SessionArtifact.finalAudio.relativePath, SessionArtifact.events.relativePath]
            let unsafeArtifact = protectedPaths.first { path in
                let url = child.appendingPathComponent(path)
                guard Self.entryExists(url) else { return false }
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                return values?.isSymbolicLink == true || values?.isRegularFile != true
            }
            if let unsafeArtifact {
                issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .unsafeLayout,
                                    preserved: true, retryable: false, warning: unsafeArtifact))
                continue
            }
            let checkpointURL = child.appendingPathComponent(SessionArtifact.finalizationCheckpoint.relativePath)
            var checkpoint: FinalizationCheckpointDocument?
            if Self.entryExists(checkpointURL) {
                let checkpointValues = try? checkpointURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard checkpointValues?.isSymbolicLink != true, checkpointValues?.isRegularFile == true else {
                    issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .unsafeLayout,
                                        preserved: true, retryable: false, warning: "checkpointLayout"))
                    continue
                }
                do {
                    checkpoint = try JSONDecoder().decode(FinalizationCheckpointDocument.self, from: Data(contentsOf: checkpointURL))
                } catch DomainValidationError.unsupportedSchemaVersion {
                    issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .checkpointUnsupported,
                                        preserved: true, retryable: false, warning: nil))
                    continue
                } catch DomainValidationError.invalidCheckpointProgress {
                    issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .checkpointInconsistent,
                                        preserved: true, retryable: false, warning: nil))
                    continue
                } catch {
                    issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .checkpointCorrupt,
                                        preserved: true, retryable: false, warning: nil))
                    continue
                }
                guard checkpoint?.sessionId == metadata.sessionId else {
                    issues.append(.init(rootID: rootID, folderName: folder, sessionID: metadata.sessionId, code: .checkpointSessionMismatch,
                                        preserved: true, retryable: false, warning: nil))
                    continue
                }
            }
            let canonicalIntegrity = Self.finalAudioIntegrity(
                child.appendingPathComponent(SessionArtifact.finalAudio.relativePath)
            )
            candidates.append(.init(
                location: location, metadata: metadata, checkpoint: checkpoint,
                sourcePresent: Self.entryExists(child.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath)),
                stagingPresent: Self.entryExists(child.appendingPathComponent("audio.finalizing.m4a")),
                // A zero-byte final file is not a usable terminal audio
                // artifact.  Keep its bytes untouched, but do not let its
                // pathname suppress the terminal inconsistency diagnosis.
                canonicalPresent: canonicalIntegrity == .valid,
                canonicalIntegrity: canonicalIntegrity,
                rootWritable: writable
            ))
        }
        return RootRecoveryScanResult(rootID: rootID, candidates: candidates, issues: issues,
                                      identifiedLocations: identifiedLocations)
    }

    /// `FileManager.fileExists` follows symbolic links, so a dangling link is
    /// indistinguishable from absence.  Recovery must instead see the link and
    /// quarantine the layout before it can be mistaken for a missing source or
    /// checkpoint.
    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }

    private static func regularFileByteCount(_ url: URL) -> Int64? {
        var info = stat()
        let exists = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
        guard exists, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    /// Inspect only ISO-BMFF atom headers with bounded reads.  This is neither
    /// a whole-file load nor an attempt to repair media: it prevents a
    /// nonempty arbitrary file from masquerading as a terminal M4A while
    /// retaining every original byte for later diagnosis.
    private static func finalAudioIntegrity(_ url: URL) -> FinalAudioIntegrity {
        guard let byteCount = regularFileByteCount(url) else { return entryExists(url) ? .malformed : .missing }
        guard byteCount > 0 else { return .empty }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .malformed }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        let total = UInt64(byteCount)
        var hasFTYP = false
        var hasMOOV = false
        var hasMDAT = false
        while offset < total {
            guard total - offset >= 8,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { return .malformed }
            let bytes = [UInt8](header)
            let size32 = bytes[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(bytes: bytes[4..<8], encoding: .ascii)
            var atomSize = size32
            var headerSize: UInt64 = 8
            if size32 == 1 {
                guard bytes.count >= 16 else { return .malformed }
                atomSize = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size32 == 0 {
                atomSize = total - offset
            }
            guard atomSize >= headerSize, atomSize <= total - offset else { return .malformed }
            switch type {
            case "ftyp": hasFTYP = true
            case "moov": hasMOOV = true
            case "mdat": hasMDAT = true
            default: break
            }
            offset += atomSize
            try? handle.seek(toOffset: offset)
        }
        return hasFTYP && hasMOOV && hasMDAT ? .valid : .malformed
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
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                issues.append(CatalogIssue(code: .sessionDirectorySymlink, rootID: rootID, folderName: folder))
                continue
            }
            guard values?.isDirectory == true else { continue }
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
