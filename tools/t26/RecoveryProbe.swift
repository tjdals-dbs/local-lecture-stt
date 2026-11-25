import Darwin
import Foundation

/// Developer-only process boundary harness. Not compiled into the GUI app.
/// All state (including catalog, bookmarks and cleanup proof) is under a marked
/// disposable directory. No microphone, model, network or user store is opened.
enum RecoveryProbe {
    struct Fixture: Codable {
        let location: SessionLocation
        let frames: Int
    }
    struct Report: Codable {
        let status: SessionStatus
        let outcome: CaptureOutcome
        let checkpoints: [FinalizationStep]
        let recoveryCodes: [String]
        let catalogRows: Int
        let catalogPath: String
        let media: AudioMediaReport?
        let transcript: TranscriptDocument?
    }
    struct Services {
        let roots: StorageRootManager
        let repository: FileSessionRepository
        let store: SQLiteSessionCatalogStore
        let catalog: SessionCatalogReconciler
        let transcripts: FileTranscriptRepository
        let authority: CompletionEvidenceAuthority
        var audio: FileAudioFinalizer {
            var result = FileAudioFinalizer(roots: roots, catalog: catalog)
            result.authority = authority
            return result
        }
    }
    static let marker = "LocalLectureSTT disposable T26 fixture v1\n"

    static func execute(_ args: [String]) async throws {
        guard (3...4).contains(args.count), ["seed", "finalize", "recover", "atomic"].contains(args[0]) else {
            throw STTEngineError(.invalidInput)
        }
        let mode = args[0], base = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        guard base.lastPathComponent.hasPrefix("T26-"),
              base.resolvingSymlinksInPath().path == base.path else { throw STTEngineError(.invalidInput) }
        if mode == "seed" || mode == "atomic" {
            guard try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty else {
                throw STTEngineError(.invalidInput)
            }
            try Data(marker.utf8).write(to: base.appendingPathComponent(".t26-fixture"), options: .withoutOverwriting)
        } else {
            guard try Data(contentsOf: base.appendingPathComponent(".t26-fixture")) == Data(marker.utf8) else {
                throw STTEngineError(.invalidInput)
            }
        }
        if mode == "atomic" { try atomic(base, boundary: args[2]); return }
        if mode == "seed" {
            guard let milliseconds = Int(args.count == 4 ? args[3] : "22500"), (2_000...60_000).contains(milliseconds),
                  ["normal", "recording", "paused"].contains(args[2]) else { throw STTEngineError(.invalidInput) }
            try await seed(base, mode: args[2], milliseconds: milliseconds)
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: base.appendingPathComponent("fixture.json")))
        let services = try await open(base)
        if mode == "finalize" {
            try await finalize(base, fixture: fixture, services: services, boundary: args[2])
        } else {
            guard args[2] == "none" else { throw STTEngineError(.invalidInput) }
            let worker = SessionFinalizationWorker(audio: services.audio, transcripts: services.transcripts)
            let queue = AudioFinalizationCoordinator(worker: worker)
            let recovery = SessionRecoveryCoordinator(scanner: SessionFileScanner(roots: services.roots),
                persistence: services.repository, finalization: queue, catalog: services.catalog, activity: SessionActivityRegistry())
            await recovery.start()
            await recovery.waitForCurrentPassSettlement()
            let snapshot = await recovery.currentSnapshot()
            try await report(base, fixture: fixture, services: services,
                             codes: snapshot.report?.items.map { $0.code.rawValue } ?? [])
        }
        try await services.store.close()
    }

    static func open(_ base: URL, create: Bool = false) async throws -> Services {
        let root = base.appendingPathComponent("root")
        for directory in [root, base.appendingPathComponent("support")] {
            guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
                throw STTEngineError(.invalidInput)
            }
        }
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        let roots = StorageRootManager(applicationSupportDirectory: base.appendingPathComponent("support/roots"),
                                       bookmarkCodec: ProbeBookmarks())
        if create { _ = try await roots.registerSelectedDirectory(root) }
        let repository = FileSessionRepository(roots: roots)
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: base.appendingPathComponent("support/catalog"))
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        return Services(roots: roots, repository: repository, store: store, catalog: catalog,
                        transcripts: FileTranscriptRepository(roots: roots, catalog: catalog),
                        authority: CompletionEvidenceAuthority(persistentKeyURL: base.appendingPathComponent("support/proof.key")))
    }

    static func seed(_ base: URL, mode: String, milliseconds: Int) async throws {
        let services = try await open(base, create: true)
        let now = AbsoluteTime(Date())
        let location = try await services.repository.createSession(sessionID: SessionID(), createdAt: now, timeZone: .gmt)
        let frames = milliseconds * 48
        try JSONEncoder().encode(Fixture(location: location, frames: frames))
            .write(to: base.appendingPathComponent("fixture.json"), options: .withoutOverwriting)
        func metadata(_ status: SessionStatus, _ outcome: CaptureOutcome) throws -> SessionMetadataDocument {
            try .init(sessionId: location.sessionID, title: "T26 synthetic process fixture", status: status,
                captureOutcome: outcome, createdAt: now, recordingStartedAt: now,
                recordingEndedAt: outcome == .completed ? now : nil, activeDurationMs: .init(Int64(milliseconds)),
                languageMode: .english, transcript: .init(segmentCount: .init(0)),
                appVersion: "T26-probe", osVersion: ProcessInfo.processInfo.operatingSystemVersionString, lastUpdatedAt: now)
        }
        try await services.repository.writeMetadata(metadata(.recording, .inProgress), at: location)
        for index in 0..<3 {
            let segment = try TranscriptSegment(id: .init(), sequence: .init(Int64(index)), startMs: .init(Int64(index * 100)),
                endMs: .init(Int64(index * 100 + 90)), originalText: "synthetic \(index)", text: "synthetic \(index)", language: .init("en"))
            try await services.repository.appendTranscriptJournal(.init(sessionId: location.sessionID, segment: segment), at: location)
        }
        let writer = AVFoundationAudioRecorder(roots: services.roots)
        try await writer.start(at: location, expectedCaptureGeneration: 26)
        var offset = 0, sequence: UInt64 = 0
        while offset < frames {
            let count = min(4_800, frames - offset)
            let samples = (0..<count).map { index in
                Float(0.25 * sin(Double(offset + index) * 2 * .pi * (offset < frames / 2 ? 440 : 880) / 48_000))
            }
            try await writer.append(.init(generation: 26, sequence: sequence,
                format: .init(sampleRate: 48_000, channelCount: 1), frameCount: count, sourceSampleTime: Int64(offset), samples: samples))
            offset += count; sequence += 1
            // The writer receives paced PCM, not a completed-file snapshot.
            // Ten times media speed keeps the process tests finite; no postfeed
            // flush, readability polling or finish precedes the kill boundary.
            try await Task.sleep(for: .milliseconds(10))
        }
        if mode != "normal" {
            if mode == "paused" { try await services.repository.writeMetadata(metadata(.paused, .inProgress), at: location) }
            try hold(mode, frames: offset)
            throw STTEngineError(.invalidLifecycle)
        }
        _ = try await writer.stop()
        try await services.repository.writeMetadata(metadata(.securing, .completed), at: location)
        try await services.store.close()
        try emit(["seededFrames": frames])
    }

    static func finalize(_ base: URL, fixture: Fixture, services: Services, boundary: String) async throws {
        guard boundary == "none" || boundary == "export" || boundary == "transcript" ||
                (1...8).map({ "checkpoint:\($0)" }).contains(boundary) else { throw STTEngineError(.invalidInput) }
        let location = fixture.location
        let directory = base.appendingPathComponent("root").appendingPathComponent(location.folderName.rawValue)
        let checkpointURL = directory.appendingPathComponent(SessionArtifact.finalizationCheckpoint.relativePath)
        let checkpoint: @Sendable () throws -> Void = {
            guard boundary.hasPrefix("checkpoint:") else { return }
            let cp = try JSONDecoder().decode(FinalizationCheckpointDocument.self, from: Data(contentsOf: checkpointURL))
            if boundary == "checkpoint:\(cp.completedSteps.count)" { try hold(boundary) }
        }
        var audio = services.audio
        audio.hook = { point in
            if [.afterSecuredCheckpoint, .afterCreatedCheckpoint, .afterVerifiedCheckpoint, .afterRemovedCheckpoint].contains(point) {
                try checkpoint()
            }
        }
        if boundary == "export" {
            audio.media = AVFoundationFinalizationMedia(fault: { point, count in
                if case .finish = point, count > 0 { try hold("export") }
            })
        }
        let transcripts = FileTranscriptRepository(roots: services.roots, catalog: services.catalog, hook: { point in
            if point == .afterCheckpoint { try checkpoint() }
            if boundary == "transcript", point == .afterCanonical { try hold(boundary) }
        })
        let result = await SessionFinalizationWorker(audio: audio, transcripts: transcripts)
            .finalize(.init(location: location), control: .init(), progress: { _ in })
        guard result.failure == nil else { throw result.failure! }
        if boundary == "checkpoint:8" {
            let proof = try await services.authority.issue(location: location, roots: services.roots, verifier: transcripts)
            let removed = await audio.removeRecovery(proof, control: .init(), progress: { _ in })
            guard removed.failure == nil else { throw removed.failure! }
        }
        guard boundary == "none" else { throw STTEngineError(.invalidLifecycle) }
        try await report(base, fixture: fixture, services: services, codes: [])
    }

    static func report(_ base: URL, fixture: Fixture, services: Services, codes: [String]) async throws {
        let location = fixture.location
        let directory = base.appendingPathComponent("root").appendingPathComponent(location.folderName.rawValue)
        // Reporting must itself stay read-only, including a denied write root.
        let metadata = try JSONDecoder().decode(SessionMetadataDocument.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        let cp = try? JSONDecoder().decode(FinalizationCheckpointDocument.self,
            from: Data(contentsOf: directory.appendingPathComponent(SessionArtifact.finalizationCheckpoint.relativePath)))
        let final = directory.appendingPathComponent(SessionArtifact.finalAudio.relativePath)
        let media = try? await AVFoundationFinalizationMedia().inspect(final, requiresM4A: true, control: .init())
        let transcript = try? JSONDecoder().decode(TranscriptDocument.self,
            from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        let rows = try await services.store.orderedItems()
        try emit(Report(status: metadata.status, outcome: metadata.captureOutcome, checkpoints: cp?.completedSteps ?? [],
            recoveryCodes: codes, catalogRows: rows.count, catalogPath: services.store.databaseURL.path,
            media: media, transcript: transcript))
    }

    static func hold(_ boundary: String, frames: Int = 0) throws {
        try emit(["boundary": boundary, "acceptedFrames": String(frames)])
        _ = FileHandle.standardInput.readData(ofLength: 1)
        throw STTEngineError(.invalidLifecycle) // Parent must kill, never finish gracefully.
    }
    static func emit<T: Encodable>(_ value: T) throws {
        var bytes = try JSONEncoder().encode(value); bytes.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
    static func atomic(_ base: URL, boundary: String) throws {
        guard ["beforeWrite", "beforeFlush", "beforeRename", "afterRename"].contains(boundary) else { throw STTEngineError(.invalidInput) }
        let file = base.appendingPathComponent("document.json")
        try Data("{\"version\":1}".utf8).write(to: file, options: .withoutOverwriting)
        try AtomicFileWriter { step in
            switch (boundary, step) {
            case ("beforeWrite", .beforeWrite), ("beforeFlush", .beforeFlush),
                 ("beforeRename", .beforeRename), ("afterRename", .afterRename): try hold(boundary)
            default: break
            }
        }.write(Data("{\"version\":2}".utf8), to: file)
        throw STTEngineError(.invalidLifecycle)
    }
}

private struct ProbeBookmarks: SecurityScopedBookmarkCodec {
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        .init(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) async -> Bool { true }
    func stopAccessing(_ url: URL) async {}
}
