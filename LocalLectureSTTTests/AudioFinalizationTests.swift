import AVFoundation
import Foundation
import XCTest
@testable import LocalLectureSTT

final class AudioFinalizationTests: XCTestCase {
    func testReviewMediaCreateDoesNotWriteThroughReplacedSessionDirectory() async throws {
        for boundary in [AudioMediaPoint.create, .created, .start, .started, .write, .finish] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let originalSource = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            let originalDirectory = f.url("")
            let retainedDirectory = f.base.appendingPathComponent("retained-session")
            let before = await f.bookmarks.counts()
            let probe = FinalizationMediaProbe()
            let releases = FinalizationTrace()
            var worker = f.worker()
            worker.media = AVFoundationFinalizationMedia(fault: { point, _ in
                probe.record(point)
                guard point == boundary, probe.claimMutation() else { return }
                try FileManager.default.moveItem(at: originalDirectory, to: retainedDirectory)
                try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
            })
            worker.hook = { if $0 == .beforeRelease { await releases.append($0) } }
            let service = AudioFinalizationCoordinator(worker: worker)
            let result = await service.finalize(.init(location: f.location))
            XCTAssertEqual(result.failure, .identityChanged, "\(boundary): \(result)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: originalDirectory.path), [], "\(boundary)")
            XCTAssertEqual(try Data(contentsOf: retainedDirectory.appendingPathComponent(FinalizationFileAccess.source)), originalSource)
            XCTAssertFalse(FileManager.default.fileExists(atPath: retainedDirectory.appendingPathComponent(FinalizationFileAccess.canonical).path))
            XCTAssertEqual(probe.count(.cleanup), 1, "\(boundary)")
            let after = await f.bookmarks.counts()
            let released = await releases.values
            XCTAssertEqual(after, [before[0] + 1, before[1] + 1])
            XCTAssertEqual(released, [.beforeRelease])
            let snapshot = await service.currentSnapshot(at: f.location)
            XCTAssertEqual(snapshot?.result, result)
            XCTAssertFalse(result.recoveryWasRemoved)
        }
    }

    func testMediaAwaitReplacementPreservesExternalFilesAndReleasesOnce() async throws {
        for boundary in [AudioMediaAwaitPoint.tracks, .duration, .formats, .ready, .finished] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let originalSource = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            let gate = FinalizationGate(), probe = FinalizationMediaProbe()
            let before = await f.bookmarks.counts()
            var worker = f.worker()
            worker.media = AVFoundationFinalizationMedia(fault: { point, _ in probe.record(point) }, suspension: { point in
                if point == boundary { await gate.blockOnce() }
            })
            let service = AudioFinalizationCoordinator(worker: worker)
            await service.enqueue(.init(location: f.location))
            await gate.waitEntered()
            let retained = f.base.appendingPathComponent("retained-session")
            try FileManager.default.moveItem(at: f.url(""), to: retained)
            try FileManager.default.createDirectory(at: f.url(""), withIntermediateDirectories: false)
            let marker = Data("External replacement must survive media cleanup".utf8)
            for path in [FinalizationFileAccess.staging, FinalizationFileAccess.canonical] { try marker.write(to: f.url(path)) }
            await gate.open()
            let result = await service.waitForResult(at: f.location)
            XCTAssertEqual(result?.failure, .identityChanged, "\(boundary)")
            for path in [FinalizationFileAccess.staging, FinalizationFileAccess.canonical] { XCTAssertEqual(try Data(contentsOf: f.url(path)), marker) }
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(FinalizationFileAccess.source)), originalSource)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.url("").path).sorted(),
                           [FinalizationFileAccess.staging, FinalizationFileAccess.canonical].sorted())
            XCTAssertEqual(probe.count(.cleanup), 1)
            let after = await f.bookmarks.counts()
            XCTAssertEqual(after, [before[0] + 1, before[1] + 1])
        }
    }

    func testMediaOutputReplacementDuringWritePreservesExternalFilesOnCleanup() async throws {
        for boundary in [AudioMediaPoint.write, .finish] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let originalSource = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            let marker = Data("External staging and canonical".utf8)
            let probe = FinalizationMediaProbe(), control = AudioFinalizationControl()
            let before = await f.bookmarks.counts()
            var worker = f.worker()
            worker.media = AVFoundationFinalizationMedia(fault: { point, _ in
                probe.record(point)
                if point == boundary, probe.claimMutation() {
                    try FileManager.default.moveItem(at: f.url(FinalizationFileAccess.staging), to: f.base.appendingPathComponent("retained-output.m4a"))
                    try marker.write(to: f.url(FinalizationFileAccess.staging))
                    try marker.write(to: f.url(FinalizationFileAccess.canonical))
                }
                if point == .cleanup {
                    control.cancel()
                    throw AudioFinalizationCode.persistence
                }
            })
            let result = await worker.finalize(.init(location: f.location), control: control, progress: { _ in })
            XCTAssertEqual(result.failure, .identityChanged)
            XCTAssertTrue(result.warnings.contains("mediaCleanup.persistence"))
            XCTAssertEqual(probe.count(.cleanup), 1)
            for path in [FinalizationFileAccess.staging, FinalizationFileAccess.canonical] { XCTAssertEqual(try Data(contentsOf: f.url(path)), marker) }
            XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), originalSource)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("retained-output.m4a").path))
            let after = await f.bookmarks.counts()
            XCTAssertEqual(after, [before[0] + 1, before[1] + 1])
        }
    }

    @MainActor
    func testReviewTerminalSessionRevalidationIsNotReportedAsWaitingForRemainingWork() async throws {
        for (status, steps, expected) in [(SessionStatus.completed, 7, AudioFinalizationPhase.audioRevalidated),
                                         (.interrupted, 7, .audioRevalidated),
                                         (.completed, 6, .audioReadyAwaitingRemainingFinalization),
                                         (.finalizing, 3, .audioReadyAwaitingRemainingFinalization)] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let ready = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertNil(ready.failure)
            XCTAssertEqual(ready.phase, .audioReadyAwaitingRemainingFinalization)
            _ = try await f.completionProof(CompletionEvidenceAuthority())
            try await f.checkpoint(steps)
            try f.editJSON("metadata.json") {
                $0["status"] = status.rawValue
                if status == .interrupted { $0["captureOutcome"] = "interrupted" }
            }
            let paths = ["metadata.json", FinalizationFileAccess.checkpoint, FinalizationFileAccess.source,
                         FinalizationFileAccess.canonical, "transcript.json", "transcript.txt", "transcript.md"]
            let contents = try paths.map { try Data(contentsOf: f.url($0)) }
            let service = AudioFinalizationCoordinator(worker: f.worker())
            let result = await service.finalize(.init(location: f.location))
            XCTAssertNil(result.failure)
            XCTAssertEqual(result.phase, expected)
            XCTAssertEqual(result.completedSteps, Array(FinalizationStep.allCases.prefix(steps)))
            XCTAssertFalse(result.recoveryWasRemoved)
            let snapshot = await service.currentSnapshot(at: f.location)
            XCTAssertEqual(snapshot?.phase, expected)
            XCTAssertEqual(snapshot?.result, result)
            let recording = FinalizationRecordingStub(location: f.location, metadata: try await f.repository.readMetadata(at: f.location))
            let vm = RecordingSessionViewModel(coordinator: recording, finalization: service)
            let received = expectation(description: "View receives terminal audio result")
            let observer = vm.$finalizations.sink { values in
                if values.last?.result == result { received.fulfill() }
            }
            vm.startObserving()
            await fulfillment(of: [received], timeout: 2)
            XCTAssertEqual(vm.finalizations.last?.phase, expected)
            XCTAssertEqual(RecordingSessionViewModel.finalizationText(expected), expected == .audioRevalidated
                ? "오디오 파일 재검증 완료" : "오디오 파일 준비 완료 · 나머지 마무리 대기")
            vm.stopObserving(); observer.cancel()
            for (path, original) in zip(paths, contents) { XCTAssertEqual(try Data(contentsOf: f.url(path)), original, path) }
        }
    }

    func testProductionRemuxAndResumePreserveRecoveryAndCheckpointBytes() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure, "\(result)")
        XCTAssertEqual(result.phase, .audioReadyAwaitingRemainingFinalization)
        XCTAssertEqual(result.completedSteps, Array(FinalizationStep.allCases.prefix(3)))
        let report = try XCTUnwrap(result.media)
        XCTAssertEqual(report.durationSeconds, 2, accuracy: 0.15)
        XCTAssertGreaterThan(report.first.byteCount, 0)
        XCTAssertGreaterThan(report.last.byteCount, 0)
        XCTAssertGreaterThan(report.last.zeroCrossings, report.first.zeroCrossings * 2)
        XCTAssertLessThan(report.maximumGapSeconds, 0.0001)
        XCTAssertLessThanOrEqual(report.bufferHighWaterBytes, 1_048_576)
        let checkpoint = try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint))
        let source = try Data(contentsOf: f.url(FinalizationFileAccess.source))
        let final = try Data(contentsOf: f.url(FinalizationFileAccess.canonical))
        let retry = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertNil(retry.failure, "\(retry)")
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), checkpoint)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), source)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.canonical)), final)
        let metadata = try await f.repository.readMetadata(at: f.location)
        XCTAssertEqual(metadata.status, .finalizing)
        XCTAssertEqual(metadata.captureOutcome, .completed)
        XCTAssertEqual(metadata.title, "Synthetic finalization")
        for path in ["transcript.json", "transcript.txt", "transcript.md"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.url(path).path))
        }
    }
}

actor FinalizationBookmarks: SecurityScopedBookmarkCodec {
    var starts = 0, stops = 0
    var allowed = true
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        .init(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) async -> Bool { starts += 1; return allowed }
    func stopAccessing(_ url: URL) async { stops += 1 }
    func counts() -> [Int] { [starts, stops] }
    func deny() { allowed = false }
}
struct FinalizationCatalog: RecordingCatalogRefreshing {
    func reconcile() async throws -> CatalogReconciliationReport {
        .init(rootResults: [], issues: [], recoveredFromCorruption: false)
    }
}
struct FinalizationFixture: Sendable {
    let base: URL
    let root: URL
    let roots: StorageRootManager
    let repository: FileSessionRepository
    let location: SessionLocation
    let bookmarks: FinalizationBookmarks
    func url(_ path: String) -> URL { root.appendingPathComponent(location.folderName.rawValue).appendingPathComponent(path) }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func worker() -> FileAudioFinalizer { .init(roots: roots, catalog: FinalizationCatalog()) }
    func mediaFiles(destination: FinalizationFixture? = nil,
                    destinationPath: String = FinalizationFileAccess.staging) throws -> FinalizationMediaFiles {
        let target = destination ?? self
        return try FinalizationMediaFiles(source: .init(root: root, location: location),
            destination: .init(root: target.root, location: target.location), destinationPath: destinationPath)
    }
    static func make(seconds: Double = 2, frequency: Double = 440) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("T08-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmarks = FinalizationBookmarks()
        let roots = StorageRootManager(applicationSupportDirectory: base.appendingPathComponent("support"), bookmarkCodec: bookmarks)
        _ = try await roots.registerSelectedDirectory(root)
        let repository = FileSessionRepository(roots: roots)
        let now = AbsoluteTime(Date())
        let location = try await repository.createSession(sessionID: SessionID(), createdAt: now, timeZone: .gmt)
        let recorder = AVFoundationAudioRecorder(roots: roots)
        try await recorder.start(at: location, expectedCaptureGeneration: 1)
        var offset = 0
        var sequence: UInt64 = 0
        let frames = Int(seconds * 48_000)
        while offset < frames {
            let count = min(2048, frames - offset)
            var values = [Float]()
            values.reserveCapacity(count)
            for index in 0..<count {
                let frame = offset + index
                let tone: Double = frame < frames / 2 ? frequency : frequency * 3
                let radians: Double = Double(frame) * (2 * Double.pi) * tone / 48_000
                values.append(Float(0.25 * sin(radians)))
            }
            let chunk = try PCMChunk(generation: 1, sequence: sequence, format: .init(sampleRate: 48_000, channelCount: 1),
                                     frameCount: count, sourceSampleTime: Int64(offset), samples: values)
            try await recorder.append(chunk)
            offset += count; sequence += 1
        }
        let summary = try await recorder.stop()
        try await repository.writeMetadata(.init(sessionId: location.sessionID, title: "Synthetic finalization",
            status: .securing, captureOutcome: .completed, createdAt: now, recordingStartedAt: now,
            recordingEndedAt: now, activeDurationMs: .init(Int64(summary.mediaDurationMilliseconds)), languageMode: .english,
            transcript: .init(segmentCount: .init(0)), appVersion: "test", osVersion: "test", lastUpdatedAt: now), at: location)
        return .init(base: base, root: root, roots: roots, repository: repository, location: location, bookmarks: bookmarks)
    }
}

extension AudioFinalizationTests {
    func testContractsRoundTripAndConstructionHasNoSideEffects() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let before = await f.bookmarks.counts()
        let worker = f.worker()
        let coordinator = AudioFinalizationCoordinator(worker: worker)
        let request = AudioFinalizationRequest(location: f.location)
        func roundTrip<T: Codable & Sendable & Equatable>(_ value: T) throws {
            XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value)
        }
        try roundTrip(request)
        var future = request; future.schemaVersion = 99
        let rejected = await coordinator.finalize(future)
        XCTAssertEqual(rejected.failure, .unsupportedSchema)
        try roundTrip(AudioFinalizationCode.identityChanged)
        let result = await worker.finalize(request, control: .init(), progress: { _ in })
        try roundTrip(result)
        try roundTrip(AudioFinalizationSnapshot(location: f.location, generation: 1, phase: result.phase, result: result))
        let snapshot = await coordinator.currentSnapshot(at: f.location)
        XCTAssertNil(snapshot)
        let after = await f.bookmarks.counts()
        XCTAssertEqual(after[0] - before[0], 1)
        XCTAssertEqual(after[1] - before[1], 1)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["AudioFinalization.swift", "AudioFinalizationCoordinator.swift"] {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent("LocalLectureSTT/Application/\(name)"), encoding: .utf8)
            for forbidden in ["import AVFoundation", "import AppKit", ": URL", ": AVAsset", ": CMTime", ": FileHandle"] {
                XCTAssertFalse(source.contains(forbidden), "\(name): \(forbidden)")
            }
        }
    }

    func testEveryDurableWindowResumesWithNewInstanceAndOrderedCheckpointReadback() async throws {
        let points: [FinalizationPoint] = [.opened, .sourceValidated, .beforeSecuredCheckpoint, .afterSecuredCheckpoint,
            .beforeFinalizingMetadata, .afterFinalizingMetadata, .beforeExport, .afterExport, .beforeFlush, .afterFlush,
            .beforeCreatedCheckpoint, .afterCreatedCheckpoint, .beforeValidation, .afterValidation,
            .beforePublication, .afterPublication, .beforeVerifiedCheckpoint, .afterVerifiedCheckpoint,
            .beforeProjection, .afterProjection]
        for point in points {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let original = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            var worker = f.worker()
            let trace = FinalizationTrace()
            worker.hook = { seen in
                await trace.append(seen)
                if seen == point { throw AudioFinalizationCode.persistence }
            }
            let failed = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(failed.failure, .persistence, "\(point): \(failed)")
            XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), original)
            if FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.checkpoint).path) {
                let cp = try await f.repository.readFinalizationCheckpoint(at: f.location)
                XCTAssertEqual(cp.completedSteps, failed.completedSteps, "\(point)")
            }
            let resumed = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertNil(resumed.failure, "\(point): \(resumed)")
            XCTAssertEqual(resumed.completedSteps, Array(FinalizationStep.allCases.prefix(3)))
            XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), original)
            let events = try String(contentsOf: f.url("events.jsonl"), encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(SessionEventRecord.self, from: Data($0.utf8)) }
            XCTAssertEqual(Set(events.compactMap { $0.detail?.code }).count, events.count)
            XCTAssertTrue(events.allSatisfy { $0.kind == .finalizationStepTransition })
        }
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let trace = FinalizationTrace()
        var worker = f.worker()
        worker.hook = { await trace.append($0) }
        _ = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
        let seen = await trace.values
        let pairs: [(FinalizationPoint, FinalizationPoint)] = [(.afterSecuredCheckpoint, .beforeFinalizingMetadata), (.afterExport, .beforeCreatedCheckpoint),
                     (.afterValidation, .beforePublication), (.afterPublication, .beforeVerifiedCheckpoint), (.afterVerifiedCheckpoint, .beforeProjection)]
        for pair in pairs {
            XCTAssertLessThan(try XCTUnwrap(seen.firstIndex(of: pair.0)), try XCTUnwrap(seen.firstIndex(of: pair.1)))
        }
    }

    func testMediaAndPersistenceFaultsPreserveFirstCauseAndOriginalBytes() async throws {
        let mediaFaults: [(AudioMediaPoint, AudioFinalizationCode)] = [(.create,.exportCreate),(.start,.exportStart),
            (.read,.exportRead),(.write,.exportWrite),(.finish,.exportFinish),(.decodeStart,.decode),(.decodeEnd,.decode),(.write,.diskFull)]
        for (point, code) in mediaFaults {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let original = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            var worker = f.worker()
            let control = AudioFinalizationControl()
            worker.media = AVFoundationFinalizationMedia(fault: { seen, count in
                if seen == .cleanup {
                    control.cancel()
                    throw AudioFinalizationCode.persistence
                }
                if seen == point && (seen != .read || count > 4) { throw code }
            })
            worker.hook = { if $0 == .beforeDiagnostic { throw AudioFinalizationCode.persistence } }
            let result = await worker.finalize(.init(location: f.location), control: control, progress: { _ in })
            XCTAssertEqual(result.failure, code, "\(point)")
            XCTAssertTrue(result.warnings.contains("diagnostic.persistence"))
            if [.start, .write, .finish].contains(point) {
                XCTAssertTrue(result.warnings.contains("mediaCleanup.persistence"))
            }
            XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("audio.m4a").path))
        }
        for (point, code) in [(FinalizationPoint.beforeFlush, AudioFinalizationCode.flush), (.beforePublication,.publication),
                              (.beforeProjection,.diskFull), (.beforeVerifiedCheckpoint,.persistence)] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            var worker = f.worker()
            worker.hook = { if $0 == point { throw code } }
            let result = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, code)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.source).path))
            if point == .beforeVerifiedCheckpoint { XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("audio.m4a").path)) }
        }
    }

    func testResumeAdoptsProvenStagingAndCanonicalButRetainsDifferentMedia() async throws {
        for diskCase in 0..<5 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let other = try await FinalizationFixture.make(frequency: 733)
            defer { other.clean() }
            let media = AVFoundationFinalizationMedia()
            let canonical = f.url("audio.m4a"), staged = f.url(FinalizationFileAccess.staging)
            if diskCase < 2 {
                try await media.remux(f.mediaFiles(), control: .init())
                if diskCase == 1 { try await f.checkpoint(2) }
            } else if diskCase < 4 {
                try await media.remux(f.mediaFiles(destinationPath: FinalizationFileAccess.canonical), control: .init())
                if diskCase == 3 { try Data("retained partial staging".utf8).write(to: staged) }
            } else {
                try await media.remux(other.mediaFiles(destination: f, destinationPath: FinalizationFileAccess.canonical), control: .init())
            }
            let originalCanonical = try? Data(contentsOf: canonical)
            var worker = f.worker()
            worker.hook = { if $0 == .beforeExport { throw AudioFinalizationCode.exportCreate } }
            let result = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            if diskCase == 4 { XCTAssertEqual(result.failure, .canonicalConflict) }
            else { XCTAssertNil(result.failure, "case \(diskCase): \(result)") }
            if let originalCanonical { XCTAssertEqual(try Data(contentsOf: canonical), originalCanonical) }
            if diskCase == 3 { XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "retained partial staging") }
        }
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let partial = Data("unfinished staging".utf8)
        try partial.write(to: f.url(FinalizationFileAccess.staging))
        let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.retainedPaths.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.url(try XCTUnwrap(result.retainedPaths.first))), partial)
    }

    func testInvalidIdentitySchemaAndSymlinkLayoutsPreserveActualBytes() async throws {
        for mutation in 0..<10 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let source = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            var expected: AudioFinalizationCode
            switch mutation {
            case 0: try f.editJSON("metadata.json") { $0["sessionId"] = UUID().uuidString }; expected = .invalidRequest
            case 1: try f.editJSON("metadata.json") { $0["schemaVersion"] = 99 }; expected = .unsupportedSchema
            case 2: try await f.checkpoint(1); try f.editJSON(FinalizationFileAccess.checkpoint) { $0["sessionId"] = UUID().uuidString }; expected = .invalidRequest
            case 3: try await f.checkpoint(1); try f.editJSON(FinalizationFileAccess.checkpoint) { $0["schemaVersion"] = 99 }; expected = .unsupportedSchema
            case 4: try Data("bad checkpoint".utf8).write(to: f.url(FinalizationFileAccess.checkpoint)); expected = .corruptDocument
            case 5: try FileManager.default.createSymbolicLink(atPath: f.url("audio.m4a").path, withDestinationPath: f.base.appendingPathComponent("absent").path); expected = .unsafeLayout
            case 6: try FileManager.default.createSymbolicLink(atPath: f.url(FinalizationFileAccess.staging).path, withDestinationPath: f.url(FinalizationFileAccess.source).path); expected = .unsafeLayout
            case 7: try FileManager.default.moveItem(at: f.url("metadata.json"), to: f.base.appendingPathComponent("metadata")); try FileManager.default.createSymbolicLink(at: f.url("metadata.json"), withDestinationURL: f.base.appendingPathComponent("metadata")); expected = .unsafeLayout
            case 8: try FileManager.default.moveItem(at: f.url(FinalizationFileAccess.source), to: f.base.appendingPathComponent("retained.mov")); expected = .sourceMissing
            default: try f.editJSON("metadata.json") { $0["status"] = "recording"; $0["captureOutcome"] = "inProgress" }; expected = .captureNotSettled
            }
            let cpBefore = try? Data(contentsOf: f.url(FinalizationFileAccess.checkpoint))
            let metadataBefore = try Data(contentsOf: f.url("metadata.json"))
            let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, expected, "mutation \(mutation): \(result)")
            XCTAssertEqual(try? Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), cpBefore)
            XCTAssertEqual(try Data(contentsOf: f.url("metadata.json")), metadataBefore)
            if mutation != 8 { XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), source) }
        }
    }

    func testDurationBoundaryInterruptedOutcomeAndTerminalMetadataArePreserved() async throws {
        for delta in [-0.151, 0.151] {
            XCTAssertThrowsError(try AudioFinalizationPolicy.validateDuration(2 + delta, against: 2))
        }
        for delta in [-0.150, 0.150] { XCTAssertNoThrow(try AudioFinalizationPolicy.validateDuration(2 + delta, against: 2)) }
        for status in [SessionStatus.securing, .interrupted] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            try f.editJSON("metadata.json") { json in
                json["activeDurationMs"] = 900_000
                if status == .interrupted { json["status"] = "interrupted"; json["captureOutcome"] = "interrupted" }
            }
            let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, status == .securing ? .invalidDuration : nil)
            if status == .interrupted {
                let m = try await f.repository.readMetadata(at: f.location)
                XCTAssertEqual(m.captureOutcome, .interrupted)
                XCTAssertEqual(m.activeDurationMs.rawValue, 900_000)
                XCTAssertEqual(m.status, .finalizing)
            }
        }
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        _ = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        try await f.checkpoint(7)
        try f.editJSON("metadata.json") { $0["status"] = "completed"; $0["transcript"] = ["segmentCount": 7] }
        let m = try Data(contentsOf: f.url("metadata.json")), cp = try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint))
        let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure)
        XCTAssertEqual(try Data(contentsOf: f.url("metadata.json")), m)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), cp)
        try FileManager.default.moveItem(at: f.url("audio.m4a"), to: f.base.appendingPathComponent("kept.m4a"))
        let missing = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertEqual(missing.failure, .checkpointInconsistent)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), cp)
    }
}

actor FinalizationTrace {
    var values: [FinalizationPoint] = []
    func append(_ point: FinalizationPoint) { values.append(point) }
}
extension FinalizationFixture {
    func checkpoint(_ count: Int) async throws {
        try await repository.writeFinalizationCheckpoint(.init(sessionId: location.sessionID, updatedAt: AbsoluteTime(Date()),
            completedSteps: Array(FinalizationStep.allCases.prefix(count))), at: location)
    }
    func editJSON(_ path: String, _ edit: (inout [String: Any]) -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url(path))) as? [String: Any])
        edit(&json)
        try JSONSerialization.data(withJSONObject: json, options: .sortedKeys).write(to: url(path))
    }
}

extension AudioFinalizationTests {
    func testRootAndFileReplacementDuringAwaitNeverRedirectsPublication() async throws {
        for mutation in 0..<5 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let before = await f.bookmarks.counts()
            let source = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            var worker = f.worker()
            worker.hook = { point in
                guard point == .sourceValidated else { return }
                if mutation == 0 {
                    let otherRoot = f.base.appendingPathComponent("root-b")
                    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
                    _ = try await f.roots.registerSelectedDirectory(otherRoot)
                } else if mutation == 1 {
                    let handle = try FileHandle(forWritingTo: f.url(FinalizationFileAccess.source))
                    try handle.seekToEnd(); try handle.write(contentsOf: Data([1])); try handle.close()
                } else if mutation == 2 {
                    let kept = f.base.appendingPathComponent("kept.mov")
                    try FileManager.default.moveItem(at: f.url(FinalizationFileAccess.source), to: kept)
                    try FileManager.default.copyItem(at: kept, to: f.url(FinalizationFileAccess.source))
                } else if mutation == 3 {
                    let dir = f.url("recovery")
                    let kept = f.base.appendingPathComponent("kept-recovery")
                    try FileManager.default.moveItem(at: dir, to: kept)
                    try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: kept)
                } else {
                    try f.editJSON("metadata.json") { $0["title"] = "external edit" }
                }
            }
            let result = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, mutation == 0 ? nil : .identityChanged)
            let after = await f.bookmarks.counts()
            XCTAssertEqual(after[0] - before[0], 1)
            XCTAssertEqual(after[1] - before[1], 1)
            if mutation == 0 {
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("audio.m4a").path))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.base.appendingPathComponent("root-b").path), [])
                XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), source)
            } else { XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("audio.m4a").path)) }
        }
        for mode in 0..<3 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            if mode == 0 { await f.bookmarks.deny() }
            else if mode == 1 { try FileManager.default.moveItem(at: f.root, to: f.base.appendingPathComponent("retained-root")) }
            else { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path) }
            defer { if mode == 2 { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path) } }
            let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, mode == 0 ? .reauthorizationRequired : (mode == 1 ? .rootMissing : .rootNotWritable))
        }
    }

    func testCleanupRejectsMissingDirtyOrForgedProofAndDeletesOnlyRecoveryAudio() async throws {
        for mutation in 0..<10 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let authority = CompletionEvidenceAuthority()
            var worker = f.worker(); worker.authority = authority
            let deletionTrace = FinalizationTrace()
            worker.hook = { await deletionTrace.append($0) }
            let ready = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertFalse(ready.recoveryWasRemoved)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.source).path))
            var proof = try await f.completionProof(authority)
            let source = try Data(contentsOf: f.url(FinalizationFileAccess.source))
            let preserved = ["transcript.json", "transcript.txt", "transcript.md", "events.jsonl", "recovery/transcript.journal.jsonl", "audio.retained-test.m4a"]
            try Data("journal".utf8).write(to: f.url("recovery/transcript.journal.jsonl"))
            try Data("retained".utf8).write(to: f.url("audio.retained-test.m4a"))
            switch mutation {
            case 0: break
            case 1: try await f.checkpoint(3)
            case 2: try f.editJSON("metadata.json") { $0["status"] = "finalizing" }
            case 3: try Data("changed transcript".utf8).write(to: f.url("transcript.json"))
            case 4: try Data("changed text".utf8).write(to: f.url("transcript.txt"))
            case 5: try FileManager.default.moveItem(at: f.url("transcript.md"), to: f.base.appendingPathComponent("kept.md"))
            case 6: proof.schemaVersion = 99
            case 7:
                proof = .init(location: .init(rootID: StorageRootID(), sessionID: f.location.sessionID, folderName: f.location.folderName),
                              files: proof.files, audio: proof.audio, catalogProjection: proof.catalogProjection, seal: proof.seal)
            case 8:
                proof = .init(location: proof.location, files: proof.files, audio: proof.audio,
                              catalogProjection: proof.catalogProjection, seal: "forged")
            default:
                worker.hook = { point in
                    if point == .beforeDelete { try Data("changed after verification".utf8).write(to: f.url("transcript.md")) }
                }
            }
            let contents = preserved.compactMap { path -> (String, Data)? in (try? Data(contentsOf: f.url(path))).map { (path, $0) } }
            let result = await worker.removeRecovery(proof, control: .init(), progress: { _ in })
            if mutation == 0 {
                XCTAssertNil(result.failure, "\(result)")
                XCTAssertTrue(result.recoveryWasRemoved)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.source).path))
                XCTAssertEqual(result.completedSteps, FinalizationStep.allCases)
                for (path, data) in contents {
                    let current = try Data(contentsOf: f.url(path))
                    if path == "events.jsonl" { XCTAssertTrue(current.starts(with: data)) }
                    else { XCTAssertEqual(current, data) }
                }
                let cp = try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint))
                let again = await worker.removeRecovery(proof, control: .init(), progress: { _ in })
                XCTAssertNil(again.failure)
                XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), cp)
                let deleteEvents = await deletionTrace.values.filter { $0 == .afterDelete }
                XCTAssertEqual(deleteEvents.count, 1)
            } else {
                XCTAssertNotNil(result.failure, "mutation \(mutation)")
                XCTAssertFalse(result.recoveryWasRemoved)
                XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.source)), source)
            }
        }
    }

    func testDeletionCheckpointFailureRetryAndCancellationCommitPoint() async throws {
        for mode in 0..<3 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let authority = CompletionEvidenceAuthority()
            var worker = f.worker(); worker.authority = authority
            _ = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            let proof = try await f.completionProof(authority)
            let control = AudioFinalizationControl()
            worker.hook = { point in
                if mode == 0 && point == .beforeRemovedCheckpoint { throw AudioFinalizationCode.persistence }
                if mode == 1 && point == .beforeDelete { control.cancel() }
                if mode == 2 && point == .afterDelete { control.cancel() }
            }
            let result = await worker.removeRecovery(proof, control: control, progress: { _ in })
            XCTAssertEqual(result.failure, mode == 0 ? .persistence : (mode == 1 ? .cancelled : nil))
            XCTAssertEqual(result.recoveryWasRemoved, mode != 1)
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.source).path), mode == 1)
            worker.hook = { _ in }
            let retry = await worker.removeRecovery(proof, control: .init(), progress: { _ in })
            XCTAssertNil(retry.failure, "\(retry)")
            XCTAssertEqual(retry.completedSteps, FinalizationStep.allCases)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("audio.m4a").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("transcript.json").path))
        }
    }
}

struct SyntheticCompletionVerifier: RemainingFinalizationVerifying {
    let projection: CatalogProjection
    let expected: [FinalizationFileEvidence]
    func verify(location: SessionLocation, files: [FinalizationFileEvidence]) async throws -> CatalogProjection {
        guard location == projection.location, files == expected else { throw AudioFinalizationCode.completionEvidence }
        return projection
    }
}
extension FinalizationFixture {
    func completionProof(_ authority: CompletionEvidenceAuthority) async throws -> FinalizationCompletionEvidence {
        try await checkpoint(7)
        let segment = try TranscriptSegment(id: .init(), sequence: .init(0), startMs: .init(0), endMs: .init(2000),
                                           originalText: "Synthetic", text: "Synthetic", language: .init("en"))
        try await repository.writeTranscript(.init(sessionId: location.sessionID, segments: [segment]), at: location)
        try Data("Synthetic\n".utf8).write(to: url("transcript.txt"))
        try Data("---\ntitle: Synthetic\n---\n[00:00] Synthetic\n".utf8).write(to: url("transcript.md"))
        try editJSON("metadata.json") { $0["status"] = "completed"; $0["transcript"] = ["segmentCount": 1] }
        let access = try FinalizationFileAccess(root: root, location: location)
        let paths = ["metadata.json", "audio.m4a", "transcript.json", "transcript.txt", "transcript.md", FinalizationFileAccess.source]
        let expected = try paths.map { try access.fingerprint($0) }
        let m = try await repository.readMetadata(at: location)
        // Fixture has verified known synthetic canonical and derived bytes plus catalog projection.
        return try await authority.issue(location: location, roots: roots,
            verifier: SyntheticCompletionVerifier(projection: .init(metadata: m, location: location), expected: expected))
    }
}

extension AudioFinalizationTests {
    func testSingleFlightSerialQueueCallerCancellationAndLateSnapshots() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let second = try await f.clone()
        let gate = FinalizationGate()
        let trace = FinalizationTrace()
        var worker = f.worker()
        worker.hook = { point in
            await trace.append(point)
            if point == .beforeExport { await gate.blockOnce() }
        }
        let service = AudioFinalizationCoordinator(worker: worker)
        let first = await service.enqueue(.init(location: f.location))
        let duplicate = await service.enqueue(.init(location: f.location))
        XCTAssertEqual(first.generation, duplicate.generation)
        await gate.waitEntered()
        let secondSnapshot = await service.enqueue(.init(location: second.location))
        XCTAssertEqual(secondSnapshot.phase, .queued)
        let observer = Task {
            let stream = await service.snapshots()
            for await _ in stream { if Task.isCancelled { return } }
        }
        observer.cancel()
        let caller = Task { await service.finalize(.init(location: f.location)) }
        caller.cancel()
        await gate.open()
        let result1 = await caller.value
        let result2 = await service.waitForResult(at: second.location)
        XCTAssertNil(result1.failure)
        XCTAssertNil(result2?.failure)
        let seen = await trace.values
        XCTAssertEqual(seen.filter { $0 == .beforeExport }.count, 2)
        XCTAssertEqual(seen.filter { $0 == .beforeRelease }.count, 2)
        XCTAssertEqual(try XCTUnwrap(seen.firstIndex(of: .beforeRelease)) + 1, try XCTUnwrap(seen.lastIndex(of: .opened)))
        let late = await service.currentSnapshot(at: f.location)
        XCTAssertEqual(late?.result, result1)
        let stream = await service.snapshots()
        var iterator = stream.makeAsyncIterator()
        let delivered = await iterator.next()
        XCTAssertEqual(delivered?.count, 2)
        XCTAssertTrue(delivered?.allSatisfy { $0.result?.failure == nil && $0.result != nil } == true)
    }

    func testCancelledPendingPersistenceRetainsFirstResultAndWaitsForReleaseBeforeRetry() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let writeGate = FinalizationGate(), releaseGate = FinalizationGate()
        var worker = f.worker()
        worker.hook = { point in
            if point == .beforeFinalizingMetadata {
                await writeGate.blockOnce()
                throw AudioFinalizationCode.persistence
            }
            if point == .beforeRelease { await releaseGate.blockOnce() }
        }
        let service = AudioFinalizationCoordinator(worker: worker)
        let first = await service.enqueue(.init(location: f.location))
        await writeGate.waitEntered()
        let stream = await service.snapshots()
        let cancelled = Task { await service.cancel(at: f.location) }
        for await states in stream {
            if states.first?.phase == .cancelling { break }
        }
        await writeGate.open()
        await releaseGate.waitEntered()
        let beforeRelease = await f.bookmarks.counts()
        let duplicate = await service.enqueue(.init(location: f.location), retry: true)
        XCTAssertEqual(duplicate.generation, first.generation)
        XCTAssertNil(duplicate.result)
        await releaseGate.open()
        let cancelledResult = await cancelled.value
        let result = try XCTUnwrap(cancelledResult)
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(result.warnings.contains("persistence"))
        let late = await service.currentSnapshot(at: f.location)
        let query = await service.waitForResult(at: f.location)
        XCTAssertEqual(late?.result, result)
        XCTAssertEqual(query, result)
        let afterRelease = await f.bookmarks.counts()
        XCTAssertEqual(afterRelease[1], beforeRelease[1] + 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.source).path))
    }

    func testOldProgressCallbackCannotMutateNextGeneration() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let probe = ProgressProbe(worker: f.worker())
        let service = AudioFinalizationCoordinator(worker: probe)
        let result = await service.finalize(.init(location: f.location))
        XCTAssertNil(result.failure)
        let firstGeneration = await service.currentSnapshot(at: f.location)?.generation
        let second = await service.finalize(.init(location: f.location), retry: true)
        await probe.emitOldProgress()
        let snapshot = await service.currentSnapshot(at: f.location)
        XCTAssertNotEqual(snapshot?.generation, firstGeneration)
        XCTAssertEqual(snapshot?.phase, .audioReadyAwaitingRemainingFinalization)
        XCTAssertEqual(snapshot?.result, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("audio.m4a").path))

    }

    @MainActor
    func testViewObservationRetryAndBackgroundIdentityMapping() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let gate = FinalizationGate()
        var worker = f.worker()
        worker.hook = { if $0 == .beforeExport { await gate.blockOnce() } }
        let service = AudioFinalizationCoordinator(worker: worker)
        let recording = FinalizationRecordingStub(location: f.location, metadata: try await f.repository.readMetadata(at: f.location))
        let app = RecordingFinalizationCoordinator(recording: recording, finalization: service)
        let vm = RecordingSessionViewModel(coordinator: app, finalization: service)
        vm.startObserving()
        // This must return even while the finalizer blocks at its export gate.
        let stopped = await app.stop()
        guard case .secured = stopped else { return XCTFail("Expected essential save") }
        await gate.waitEntered()
        vm.stopObserving()
        let next = try await app.start(.init(title: "next", timeZone: .gmt))
        XCTAssertEqual(next.phase, .idle)
        let inFlight = await service.currentSnapshot(at: f.location)
        XCTAssertNil(inFlight?.result)
        XCTAssertNotEqual(inFlight?.location.sessionID, next.sessionID)
        await gate.open()
        let result = await service.waitForResult(at: f.location)
        XCTAssertNil(result?.failure)
        vm.startObserving()
        // A deterministic snapshot receipt, without sleeps or UI task ownership.
        let stream = await service.snapshots()
        var iterator = stream.makeAsyncIterator()
        let delivered = await iterator.next()
        XCTAssertNotNil(delivered)
        XCTAssertEqual(RecordingSessionViewModel.finalizationText(.audioReadyAwaitingRemainingFinalization), "오디오 파일 준비 완료 · 나머지 마무리 대기")
        XCTAssertEqual(RecordingSessionViewModel.finalizationText(.failed), "오디오 마무리 실패 · 자료 보존")
        XCTAssertEqual(RecordingSessionViewModel.finalizationText(.exporting), "오디오 마무리 중")
        vm.stopObserving()
    }
}

actor FinalizationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func blockOnce() async {
        guard !entered else { return }
        entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() { released = true; waiter?.resume(); waiter = nil }
}
actor ProgressProbe: AudioFinalizationWorking {
    let worker: FileAudioFinalizer
    private var oldProgress: (@Sendable (AudioFinalizationPhase) async -> Void)?
    init(worker: FileAudioFinalizer) { self.worker = worker }
    func finalize(_ request: AudioFinalizationRequest, control: AudioFinalizationControl,
                  progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        if oldProgress == nil { oldProgress = progress }
        return await worker.finalize(request, control: control, progress: progress)
    }
    func removeRecovery(_ evidence: FinalizationCompletionEvidence, control: AudioFinalizationControl,
                        progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        await worker.removeRecovery(evidence, control: control, progress: progress)
    }
    func emitOldProgress() async { await oldProgress?(.failed) }
}
actor FinalizationRecordingStub: RecordingSessionCoordinating {
    let location: SessionLocation
    let metadata: SessionMetadataDocument
    init(location: SessionLocation, metadata: SessionMetadataDocument) { self.location = location; self.metadata = metadata }
    func snapshots() -> AsyncStream<RecordingSessionSnapshot> { AsyncStream { $0.yield(.idle()); $0.finish() } }
    func currentSnapshot() -> RecordingSessionSnapshot { .idle() }
    func refreshPermissionStatus() {}
    func start(_ configuration: RecordingStartConfiguration) async throws -> RecordingSessionSnapshot { .idle() }
    func stop() -> RecordingSessionResult {
        .secured(.init(location: location, metadata: metadata, recorderSummary: .init(location: location,
            artifact: .recoveryAudio, writtenFrameCount: 96_000, mediaDurationMilliseconds: 2000, outputFormat: .recoveryAAC)))
    }
    func reset() {}
}
extension FinalizationFixture {
    func clone() async throws -> Self {
        let now = AbsoluteTime(Date())
        let next = try await repository.createSession(sessionID: SessionID(), createdAt: now, timeZone: .gmt)
        let fixture = Self(base: base, root: root, roots: roots, repository: repository, location: next, bookmarks: bookmarks)
        try FileManager.default.copyItem(at: url(FinalizationFileAccess.source), to: fixture.url(FinalizationFileAccess.source))
        try FileManager.default.copyItem(at: url("metadata.json"), to: fixture.url("metadata.json"))
        try fixture.editJSON("metadata.json") { $0["sessionId"] = next.sessionID.rawValue.uuidString }
        return fixture
    }
}

final class AudioFinalizationLongMediaTests: XCTestCase {
    func testTwoHourContinuousAACProductionFinalizationAndRevalidation() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let seed = f.base.appendingPathComponent("synthetic-seed.mov")
        try FileManager.default.moveItem(at: f.url(FinalizationFileAccess.source), to: seed)
        let generationStart = ProcessInfo.processInfo.systemUptime
        let packets = try await generateContinuousAAC(seed: seed, destination: f.url(FinalizationFileAccess.source), seconds: 7_200)
        let generationSeconds = ProcessInfo.processInfo.systemUptime - generationStart
        try f.editJSON("metadata.json") { $0["activeDurationMs"] = 7_200_000 }
        let source = try await AVFoundationFinalizationMedia().inspect(f.url(FinalizationFileAccess.source), requiresM4A: false, control: .init())
        XCTAssertEqual(source.packetCount, 337_500)
        XCTAssertEqual(source.packetCount, packets)
        XCTAssertEqual(source.timelineEndSeconds - source.timelineStartSeconds, 7_200, accuracy: 0.0001)
        XCTAssertLessThan(source.maximumGapSeconds, 0.0001)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        let finalizationSeconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertNil(result.failure, "\(result)")
        let report = try XCTUnwrap(result.media)
        XCTAssertEqual(source.durationSeconds, 7_200, accuracy: 0.15)
        XCTAssertEqual(report.durationSeconds, source.durationSeconds, accuracy: 0.15)
        XCTAssertEqual(report.packetCount, source.packetCount)
        XCTAssertEqual(report.payloadSHA256, source.payloadSHA256)
        XCTAssertLessThan(report.maximumGapSeconds, 0.0001)
        XCTAssertGreaterThan(report.first.byteCount, 0)
        XCTAssertGreaterThan(report.last.byteCount, 0)
        XCTAssertLessThan(report.first.startSeconds, 0.15)
        XCTAssertGreaterThan(report.last.startSeconds, 7_199.5)
        XCTAssertGreaterThan(report.last.endSeconds, 7_199.85)
        XCTAssertEqual(result.completedSteps, Array(FinalizationStep.allCases.prefix(3)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url(FinalizationFileAccess.source).path))
        XCTAssertLessThanOrEqual(report.bufferHighWaterBytes, 1_048_576)
        XCTAssertEqual(FinalizationFileAccess.bufferSize, 65_536)
        let cp = try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint))
        let retryStart = ProcessInfo.processInfo.systemUptime
        let retry = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        let retrySeconds = ProcessInfo.processInfo.systemUptime - retryStart
        XCTAssertNil(retry.failure)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), cp)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("T08 L01 source=\(source.durationSeconds)s final=\(report.durationSeconds)s packets=\(packets) gap=\(report.maximumGapSeconds)s firstBytes=\(report.first.byteCount) lastBytes=\(report.last.byteCount) lastRange=\(report.last.startSeconds)...\(report.last.endSeconds) generation=\(generationSeconds)s finalization=\(finalizationSeconds)s revalidation=\(retrySeconds)s bufferHighWater=\(report.bufferHighWaterBytes)B processPeakRSS=\(usage.ru_maxrss)B")
    }
}

/// Repeats actual encoded AAC payloads in bounded groups; every packet is present,
/// not a sparse PTS trick. The count * 1024 / 48000 is exactly 7,200 seconds.
private func generateContinuousAAC(seed: URL, destination: URL, seconds: Int) async throws -> Int {
    let asset = AVURLAsset(url: seed)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    let format = try XCTUnwrap(formats.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    _ = output.copyNextSampleBuffer() // Skip initial encoder priming group.
    let template = try XCTUnwrap(output.copyNextSampleBuffer())
    reader.cancelReading()
    // Build the synthetic MOV sample table explicitly. AVAssetWriter adds an AAC
    // priming packet on this SDK; a fixed table makes the fixture's exact coverage
    // independent of that writer behavior. Production still uses AVFoundation.
    let packetSize = CMSampleBufferGetSampleSize(template, at: 10)
    var packet = Data(count: packetSize)
    let offset = (0..<10).reduce(0) { $0 + CMSampleBufferGetSampleSize(template, at: $1) }
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(template))
    let copied = packet.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: packetSize, destination: $0.baseAddress!)
    }
    guard copied == noErr else { throw AudioFinalizationCode.exportRead }
    let stsd = try fixtureAtom(seed, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"])
    let count = seconds * 48_000 / 1024
    func u32(_ value: Int) -> Data { var big = UInt32(value).bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
    func u16(_ value: Int) -> Data { var big = UInt16(value).bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
    func atom(_ type: String, _ body: Data) -> Data { u32(body.count + 8) + Data(type.utf8) + body }
    func joined(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    let zero = u32(0)
    let matrix = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000].reduce(Data()) { $0 + u32($1) }
    let duration = seconds * 48_000
    let ftyp = atom("ftyp", Data("qt  ".utf8) + zero + Data("qt  ".utf8))
    let mvhd = atom("mvhd", joined([zero, zero, zero, u32(48_000), u32(duration), u32(0x10000), u16(0x100), Data(count: 10), matrix, Data(count: 24), u32(2)]))
    let tkhd = atom("tkhd", joined([u32(7), zero, zero, u32(1), zero, u32(duration), Data(count: 8), u16(0), u16(0), u16(0x100), u16(0), matrix, zero, zero]))
    let mdhd = atom("mdhd", joined([zero, zero, zero, u32(48_000), u32(duration), u16(0x55c4), u16(0)]))
    let hdlr = atom("hdlr", zero + zero + Data("soun".utf8) + Data(count: 12) + Data("SoundHandler\0".utf8))
    let smhd = atom("smhd", Data(count: 8))
    let dinf = atom("dinf", atom("dref", zero + u32(1) + atom("url ", u32(1))))
    let stts = atom("stts", zero + u32(1) + u32(count) + u32(1024))
    let stsc = atom("stsc", zero + u32(1) + u32(1) + u32(count) + u32(1))
    let stsz = atom("stsz", zero + u32(packetSize) + u32(count))
    let stco = atom("stco", zero + u32(1) + u32(ftyp.count + 8))
    let stbl = atom("stbl", stsd + stts + stsc + stsz + stco)
    let moov = atom("moov", mvhd + atom("trak", tkhd + atom("mdia", mdhd + hdlr + atom("minf", smhd + dinf + stbl))))
    XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: nil))
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.write(contentsOf: ftyp)
    try handle.write(contentsOf: u32(8 + count * packetSize) + Data("mdat".utf8))
    let batchCount = max(1, 65_536 / packetSize)
    let batch = (0..<batchCount).reduce(into: Data()) { data, _ in data.append(packet) }
    var written = 0
    while written < count {
        let packets = min(batchCount, count - written)
        try handle.write(contentsOf: batch.prefix(packets * packetSize))
        written += packets
    }
    try handle.write(contentsOf: moov)
    try handle.synchronize()
    return count
}

/// Reads only the requested small atom. Large mdat payload is skipped with seek.
private func fixtureAtom(_ url: URL, path: [String]) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let length = try handle.seekToEnd()
    func locate(_ lower: UInt64, _ upper: UInt64, _ path: ArraySlice<String>) throws -> Data {
        var cursor = lower
        while cursor + 8 <= upper {
            try handle.seek(toOffset: cursor)
            let header = try XCTUnwrap(try handle.read(upToCount: 8))
            let size = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard size >= 8, cursor + size <= upper else { throw AudioFinalizationCode.invalidContainer }
            if String(data: header.suffix(4), encoding: .ascii) == path.first {
                if path.count == 1 {
                    guard size <= 65_536 else { throw AudioFinalizationCode.invalidContainer }
                    return header + (try handle.read(upToCount: Int(size - 8)) ?? Data())
                }
                return try locate(cursor + 8, cursor + size, path.dropFirst())
            }
            cursor += size
        }
        throw AudioFinalizationCode.invalidContainer
    }
    return try locate(0, length, path[...])
}

extension AudioFinalizationTests {
    func testMediaRejectsActualWrongContainerTrackFormatAndDurationOutsideTolerance() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let media = AVFoundationFinalizationMedia()
        do {
            _ = try await media.inspect(f.url(FinalizationFileAccess.source), requiresM4A: true, control: .init())
            XCTFail("MOV renamed as M4A must fail")
        } catch { XCTAssertEqual(error as? AudioFinalizationCode, .invalidContainer) }
        let pcm = f.base.appendingPathComponent("stereo.caf")
        try writeWrongPCM(pcm)
        do {
            _ = try await media.inspect(pcm, requiresM4A: false, control: .init())
            XCTFail("PCM stereo 44.1 kHz must fail")
        } catch { XCTAssertEqual(error as? AudioFinalizationCode, .invalidFormat) }
        let video = f.base.appendingPathComponent("video.mov")
        try await writeVideo(video)
        do {
            _ = try await media.inspect(video, requiresM4A: false, control: .init())
            XCTFail("Video track must fail")
        } catch { XCTAssertEqual(error as? AudioFinalizationCode, .invalidTracks) }
        let empty = f.base.appendingPathComponent("empty.mov")
        try Data().write(to: empty)
        do {
            _ = try await media.inspect(empty, requiresM4A: false, control: .init())
            XCTFail("Empty source must fail")
        } catch { XCTAssertTrue([AudioFinalizationCode.sourceUnreadable, .invalidTracks, .invalidDuration].contains(error as? AudioFinalizationCode)) }
        XCTAssertThrowsError(try AudioFinalizationPolicy.validateDuration(0, against: 2))
        let source = try await media.inspect(f.url(FinalizationFileAccess.source), requiresM4A: false, control: .init())
        for delta in [-151, 151, -149, 149] {
            let copy = try await f.clone()
            try copy.editJSON("metadata.json") { $0["activeDurationMs"] = Int((source.durationSeconds * 1_000).rounded()) + delta }
            let result = await copy.worker().finalize(.init(location: copy.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, abs(delta) > 150 ? .invalidDuration : nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.url(FinalizationFileAccess.source).path))
        }
    }

    func testPublicationCollisionAndPostValidationReplacementPreserveFiles() async throws {
        for mode in 0..<4 {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            var worker = f.worker()
            let marker = Data("External replacement must remain".utf8)
            worker.hook = { point in
                if mode == 0 && point == .beforePublication { try marker.write(to: f.url("audio.m4a")) }
                if mode == 1 && point == .afterValidation { try marker.write(to: f.url(FinalizationFileAccess.staging)) }
                if mode == 2 && point == .beforeVerifiedCheckpoint { try marker.write(to: f.url("audio.m4a")) }
                if mode == 3 && point == .beforeCatalog { try marker.write(to: f.url("audio.m4a")) }
            }
            let result = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
            XCTAssertEqual(result.failure, mode == 0 ? .canonicalConflict : .identityChanged)
            XCTAssertEqual(try Data(contentsOf: f.url(mode == 1 ? FinalizationFileAccess.staging : "audio.m4a")), marker)
            XCTAssertTrue(result.presentPaths.contains(FinalizationFileAccess.source))
            if mode >= 2 { XCTAssertTrue(result.presentPaths.contains("audio.m4a")) }
            XCTAssertFalse(result.recoveryWasRemoved)
        }
    }

    func testPersistentCompletionSealResumesDeletionWithNewAuthorityAndRejectsCatalogFailure() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let keyURL = f.base.appendingPathComponent("private/proof.key")
        let firstAuthority = CompletionEvidenceAuthority(persistentKeyURL: keyURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
        var worker = f.worker(); worker.authority = firstAuthority
        _ = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
        let proof = try await f.completionProof(firstAuthority)
        let bytes = try JSONEncoder().encode(proof)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        do {
            _ = try await firstAuthority.issue(location: f.location, roots: f.roots, verifier: RejectingCompletionVerifier())
            XCTFail("No catalog acknowledgment must reject issuance")
        } catch { XCTAssertEqual(error as? AudioFinalizationCode, .completionEvidence) }
        worker.hook = { if $0 == .beforeRemovedCheckpoint { throw AudioFinalizationCode.persistence } }
        let failed = await worker.removeRecovery(proof, control: .init(), progress: { _ in })
        XCTAssertEqual(failed.failure, .persistence)
        XCTAssertTrue(failed.recoveryWasRemoved)
        let secondAuthority = CompletionEvidenceAuthority(persistentKeyURL: keyURL)
        var resumedWorker = f.worker(); resumedWorker.authority = secondAuthority
        let decodedProof = try JSONDecoder().decode(FinalizationCompletionEvidence.self, from: bytes)
        let resumed = await resumedWorker.removeRecovery(decodedProof, control: .init(), progress: { _ in })
        XCTAssertNil(resumed.failure)
        XCTAssertEqual(resumed.completedSteps, FinalizationStep.allCases)
        let completedCheckpoint = try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint))
        let completedMetadata = try Data(contentsOf: f.url("metadata.json"))
        var revalidation = AudioFinalizationRequest(location: f.location)
        revalidation.completionEvidence = decodedProof
        let checked = await resumedWorker.finalize(revalidation, control: .init(), progress: { _ in })
        XCTAssertNil(checked.failure)
        XCTAssertEqual(checked.phase, .audioRevalidated)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.checkpoint)), completedCheckpoint)
        XCTAssertEqual(try Data(contentsOf: f.url("metadata.json")), completedMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url("audio.m4a").path))
    }

    @MainActor
    func testViewRetryReobservesTheSameSessionAndPreservesFailureCode() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let once = FinalizationFailOnce()
        var worker = f.worker()
        worker.hook = { if $0 == .beforeExport, await once.take() { throw AudioFinalizationCode.exportCreate } }
        let service = AudioFinalizationCoordinator(worker: worker)
        let recording = FinalizationRecordingStub(location: f.location, metadata: try await f.repository.readMetadata(at: f.location))
        let vm = RecordingSessionViewModel(coordinator: recording, finalization: service)
        let failed = await service.finalize(.init(location: f.location))
        XCTAssertEqual(failed.failure, .exportCreate)
        let value = await service.currentSnapshot(at: f.location)
        let snapshot = try XCTUnwrap(value)
        let receivedFailure = expectation(description: "View receives preserved failure")
        let failureObserver = vm.$finalizations.sink { values in
            if values.last?.result?.failure == .exportCreate { receivedFailure.fulfill() }
        }
        vm.startObserving()
        await fulfillment(of: [receivedFailure], timeout: 2)
        failureObserver.cancel()
        vm.stopObserving()
        await vm.retryFinalization(snapshot)
        let retry = await service.waitForResult(at: f.location)
        XCTAssertNil(retry?.failure)
        let receivedReady = expectation(description: "View reattaches to completed work")
        let readyObserver = vm.$finalizations.sink { values in
            if values.last?.phase == .audioReadyAwaitingRemainingFinalization { receivedReady.fulfill() }
        }
        vm.startObserving()
        await fulfillment(of: [receivedReady], timeout: 2)
        XCTAssertEqual(vm.finalizations.last?.location, f.location)
        XCTAssertEqual(vm.finalizations.last?.result, retry)
        vm.stopObserving(); readyObserver.cancel()
    }
}

private struct RejectingCompletionVerifier: RemainingFinalizationVerifying {
    func verify(location: SessionLocation, files: [FinalizationFileEvidence]) async throws -> CatalogProjection {
        throw AudioFinalizationCode.completionEvidence
    }
}
private actor FinalizationFailOnce {
    var available = true
    func take() -> Bool { defer { available = false }; return available }
}
private func writeWrongPCM(_ url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
    pcm.frameLength = 4410
    for channel in 0..<2 { for index in 0..<4410 { pcm.floatChannelData![channel][index] = Float(sin(Double(index) / 20)) } }
    try file.write(from: pcm)
}
private func writeVideo(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
    let pixel = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    memset(CVPixelBufferGetBaseAddress(pixel), 0, CVPixelBufferGetDataSize(pixel))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(adaptor.append(pixel, withPresentationTime: .zero))
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 10))
    input.markAsFinished()
    await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
    XCTAssertEqual(writer.status, .completed)
}

extension AudioFinalizationTests {
    func testActualSparsePacketTimingIsRejectedAndStagingCannotReplaceMissingSource() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let sparse = f.base.appendingPathComponent("sparse.mov")
        _ = try await generateContinuousAAC(seed: f.url(FinalizationFileAccess.source), destination: sparse, seconds: 2)
        let handle = try FileHandle(forUpdating: sparse)
        let size = try handle.seekToEnd()
        let start = size - min(size, 1024)
        try handle.seek(toOffset: start)
        var tail = try XCTUnwrap(try handle.read(upToCount: 1024))
        let tag = try XCTUnwrap(tail.range(of: Data("stts".utf8)))
        let durationOffset = tag.lowerBound + 16
        // A real sample-table gap of 16 frames per packet. Payload remains unchanged.
        tail.replaceSubrange(durationOffset..<(durationOffset + 4), with: [0, 0, 4, 16])
        try handle.seek(toOffset: start); try handle.write(contentsOf: tail); try handle.close()
        do {
            _ = try await AVFoundationFinalizationMedia().inspect(sparse, requiresM4A: false, control: .init())
            XCTFail("Sparse compressed coverage must fail")
        } catch { XCTAssertEqual(error as? AudioFinalizationCode, .discontinuousTimeline) }
        try await AVFoundationFinalizationMedia().remux(f.mediaFiles(), control: .init())
        let staged = try Data(contentsOf: f.url(FinalizationFileAccess.staging))
        try FileManager.default.moveItem(at: f.url(FinalizationFileAccess.source), to: f.base.appendingPathComponent("retained-source.mov"))
        let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertEqual(result.failure, .sourceMissing)
        XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.staging)), staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("audio.m4a").path))
    }

    func testCompletedStagingWithDifferentVoiceIsRetainedAndCanonicalConflictWins() async throws {
        for canonicalExists in [false, true] {
            let f = try await FinalizationFixture.make()
            defer { f.clean() }
            let other = try await FinalizationFixture.make(frequency: 721)
            defer { other.clean() }
            let media = AVFoundationFinalizationMedia()
            try await media.remux(other.mediaFiles(destination: f), control: .init())
            let different = try Data(contentsOf: f.url(FinalizationFileAccess.staging))
            if canonicalExists { try different.write(to: f.url("audio.m4a")) }
            let result = await f.worker().finalize(.init(location: f.location), control: .init(), progress: { _ in })
            if canonicalExists {
                XCTAssertEqual(result.failure, .canonicalConflict)
                XCTAssertEqual(try Data(contentsOf: f.url("audio.m4a")), different)
                XCTAssertEqual(try Data(contentsOf: f.url(FinalizationFileAccess.staging)), different)
            } else {
                XCTAssertNil(result.failure)
                XCTAssertEqual(result.retainedPaths.count, 1)
                XCTAssertEqual(try Data(contentsOf: f.url(try XCTUnwrap(result.retainedPaths.first))), different)
            }
        }
    }

    func testCatalogFailureIsWarningButDoesNotAdvanceWholeCompletionOrDeleteRecovery() async throws {
        let f = try await FinalizationFixture.make()
        defer { f.clean() }
        let worker = FileAudioFinalizer(roots: f.roots, catalog: FailingFinalizationCatalog())
        let result = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix("catalog.") })
        XCTAssertEqual(result.completedSteps, Array(FinalizationStep.allCases.prefix(3)))
        XCTAssertFalse(result.recoveryWasRemoved)
        XCTAssertTrue(result.presentPaths.contains(FinalizationFileAccess.source))
    }
}
private struct FailingFinalizationCatalog: RecordingCatalogRefreshing {
    func reconcile() async throws -> CatalogReconciliationReport { throw AudioFinalizationCode.persistence }
}

private final class FinalizationMediaProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioMediaPoint] = []
    private var mutated = false
    func record(_ point: AudioMediaPoint) { lock.lock(); defer { lock.unlock() }; events.append(point) }
    func count(_ point: AudioMediaPoint) -> Int { lock.lock(); defer { lock.unlock() }; return events.filter { $0 == point }.count }
    func claimMutation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if mutated { return false }
        mutated = true
        return true
    }
}
