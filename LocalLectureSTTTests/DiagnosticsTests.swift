import Darwin
import Foundation
import XCTest
@testable import LocalLectureSTT

final class DiagnosticsTests: XCTestCase {
    func testEveryIssueSeparatesCauseActionAndRecoveryWithoutRawErrors() throws {
        for code in UserIssueCode.allCases {
            let issue = UserIssue(code: code)
            XCTAssertFalse(issue.title.isEmpty); XCTAssertFalse(issue.cause.isEmpty); XCTAssertFalse(issue.action.isEmpty)
            XCTAssertTrue(issue.message.contains("원인:")); XCTAssertTrue(issue.message.contains("조치:"))
            XCTAssertTrue(issue.message.contains(issue.recovery.label))
        }
        let cases: [(Error, UserIssueCode)] = [
            (CaptureError(.permissionDenied), .microphonePermission),
            (CaptureError(.permissionRestricted), .microphoneRestricted),
            (CaptureError(.activeDeviceDisconnected), .microphoneDisconnected),
            (StorageError(.securityScopeAccessFailed), .storagePermission),
            (StorageError(.rootMissing), .storageMissing),
            (StorageError(.temporaryWriteFailed), .storageWrite),
            (AudioRecorderError(.diskFull), .diskFull),
            (ModelRepositoryCode.integrityMismatch, .modelCorrupt),
            (ModelRepositoryCode.incompatible, .modelIncompatible),
            (ModelRepositoryCode.sourceUnavailable, .modelMissing),
            (ModelRepositoryCode.scopeDenied, .modelAccess),
            (STTEngineError(.startFailed), .engineInitialization),
            (STTEngineError(.inferenceFailed), .engineInference),
            (AudioFinalizationCode.exportFinish, .audioFinalization),
            (AudioFinalizationCode.sourceMissing, .sessionMissing),
            (TranscriptFailure(code: .repairRequired), .transcriptRepair)
        ]
        for (error, code) in cases { XCTAssertEqual(UserIssues.error(error).code, code) }
        let privateError = NSError(domain: "PRIVATE-LECTURE", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "SECRET-TRANSCRIPT /Users/private/recording.m4a"])
        let message = UserIssues.error(privateError).message
        XCTAssertFalse(message.contains("SECRET")); XCTAssertFalse(message.contains("/Users/"))
        XCTAssertEqual(UserIssues.error(privateError).code, .unknown)
        XCTAssertTrue(UserIssues.model(.scopeDenied).action.contains("모델 관리"))
        XCTAssertFalse(UserIssues.model(.scopeDenied).action.contains("저장 폴더 재승인"))
    }

    func testSessionEventProjectionOmitsDetailsTitleAndTranscriptAndExportsValidJSONL() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let log = f.log()
        let event = try SessionEventRecord(sessionId: SessionID(), eventId: SessionEventID(), occurredAt: .init(Date()),
            kind: .sttError, detail: .init(code: "SECRET-CODE", message: "SECRET-TRANSCRIPT /Users/private"))
        log.sessionEvent(event)
        log.issue(.init(code: .engineInference), source: .speech, sessionID: event.sessionId)
        let summary = try await log.summary()
        XCTAssertEqual(summary.droppedEntries, 0); XCTAssertNil(summary.lastFailure)
        let destination = f.base.appendingPathComponent("export.jsonl")
        try await log.export(to: destination)
        let data = try Data(contentsOf: destination)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("/Users/"))
        let entries = try f.decode(data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].signal, .sessionEvent(.sttError))
        XCTAssertEqual(entries[0].sessionID, event.sessionId.rawValue)
        XCTAssertEqual(entries[1].signal, .issue(.engineInference))
    }

    func testByteRotationClearAndExportPreserveSessionAndUnmanagedFiles() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let policy = try DiagnosticRetentionPolicy(maximumBytes: 1_400, fileBytes: 350)
        let log = f.log(policy: policy)
        let sentinels = try f.sentinels()
        for _ in 0..<80 { log.record(.init(source: .app, signal: .appStarted)) }
        let summary = try await log.summary()
        XCTAssertGreaterThan(summary.fileCount, 0); XCTAssertLessThanOrEqual(summary.bytes, 1_400)
        for file in try f.ownedFiles() { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 350) }
        let destination = f.base.appendingPathComponent("retained.jsonl")
        try await log.export(to: destination)
        XCTAssertFalse(try f.decode(Data(contentsOf: destination)).isEmpty)
        try f.assertUnchanged(sentinels)
        try await log.clear()
        let empty = try await log.summary()
        XCTAssertEqual(empty.bytes, 0); XCTAssertEqual(empty.fileCount, 0)
        try f.assertUnchanged(sentinels)
        log.record(.init(source: .app, signal: .appStarted))
        let restarted = try await log.summary(); XCTAssertEqual(restarted.fileCount, 1)
    }

    func testThirtyDayBoundaryAndRestartPruneOnlyOwnedLogs() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let clock = DiagnosticTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let first = f.log(now: { clock.value })
        let sentinels = try f.sentinels()
        first.record(.init(source: .app, signal: .appStarted))
        _ = try await first.summary()
        clock.advance(30 * 86_400 - 1)
        let stillPresent = try await f.log(now: { clock.value }).summary()
        XCTAssertEqual(stillPresent.fileCount, 1)
        clock.advance(1)
        let expired = try await f.log(now: { clock.value }).summary()
        XCTAssertEqual(expired.fileCount, 0)
        try f.assertUnchanged(sentinels)
    }

    func testQueueAdmissionIsBoundedAndDiskFailureNeverThrowsToProducer() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let gate = DiagnosticBlockingWrite()
        let log = LocalDiagnosticLog(directory: f.logs,
            policy: try .init(pendingLimit: 2), beforeWrite: { try gate.blockThenFail() })
        log.record(.init(source: .app, signal: .appStarted))
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<99 { log.record(.init(source: .recording, signal: .issue(.noInput))) }
        gate.release.signal()
        let summary = try await log.summary()
        XCTAssertEqual(summary.droppedEntries, 100)
        XCTAssertEqual(summary.lastFailure, .storage)
        XCTAssertEqual(summary.bytes, 0)
        try await log.clear()
        let cleared = try await log.summary(); XCTAssertNil(cleared.lastFailure)
    }

    func testExportNeverOverwritesReservedExistingOrRacedFiles() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let destination = f.base.appendingPathComponent("export.jsonl")
        let original = Data("original session or user data".utf8)
        try original.write(to: destination)
        let log = f.log(); log.record(.init(source: .app, signal: .appStarted))
        await expect(.destinationExists) { try await log.export(to: destination) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        for name in ["events.jsonl", "Events.jsonl", "transcript.journal.jsonl", "audio.m4a"] {
            let reserved = f.base.appendingPathComponent(name)
            await expect(.exportFailed) { try await log.export(to: reserved) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: reserved.path))
        }
        let raced = f.base.appendingPathComponent("raced.jsonl")
        let racer = LocalDiagnosticLog(directory: f.logs, beforeExportPublish: { try original.write(to: raced) })
        await expect(.destinationExists) { try await racer.export(to: raced) }
        XCTAssertEqual(try Data(contentsOf: raced), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.base.path).contains { $0.hasSuffix(".partial") })
    }

    func testCancelledOrFailedExportLeavesNoDestinationOrPartialFile() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let initial = f.log(); initial.record(.init(source: .app, signal: .appStarted)); _ = try await initial.summary()
        let control = DiagnosticCancellation()
        let log = LocalDiagnosticLog(directory: f.logs, beforeExportPublish: { control.cancel() })
        let destination = f.base.appendingPathComponent("cancelled.jsonl")
        await expect(.cancelled) { try await log.export(to: destination, cancellation: control) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let failure = LocalDiagnosticLog(directory: f.logs, beforeExportPublish: { throw DiagnosticFailure.exportFailed })
        await expect(.exportFailed) { try await failure.export(to: destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.base.path).contains { $0.hasSuffix(".partial") })
        let preserved = try await initial.summary(); XCTAssertGreaterThan(preserved.bytes, 0)
    }

    func testDirectoryAndManagedFileSymlinksHardlinksAndFIFOAreNeverFollowed() async throws {
        for mode in 0..<4 {
            let f = try DiagnosticFixture(); defer { f.clean() }
            let secret = f.base.appendingPathComponent("session-transcript.json")
            let original = Data("PRIVATE-TRANSCRIPT".utf8); try original.write(to: secret)
            if mode == 0 {
                try FileManager.default.createSymbolicLink(at: f.logs, withDestinationURL: f.base)
            } else {
                try FileManager.default.createDirectory(at: f.logs, withIntermediateDirectories: true)
                let name = "log-\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).jsonl"
                let file = f.logs.appendingPathComponent(name)
                if mode == 1 { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret) }
                else if mode == 2 { XCTAssertEqual(link(secret.path, file.path), 0) }
                else { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
            }
            let log = f.log()
            await expect(.unsafeLayout) { _ = try await log.summary() }
            await expect(.unsafeLayout) { try await log.clear() }
            await expect(.unsafeLayout) { try await log.export(to: f.base.appendingPathComponent("export.jsonl")) }
            XCTAssertEqual(try Data(contentsOf: secret), original)
        }
    }

    func testExportReencodesClosedSchemaAndRejectsTruncatedRecords() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let log = f.log(); log.record(.init(source: .app, signal: .appStarted)); _ = try await log.summary()
        let file = try XCTUnwrap(f.ownedFiles().first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["transcript"] = "PRIVATE-EXTRA-FIELD"
        var line = try JSONSerialization.data(withJSONObject: object); line.append(0x0A)
        try line.write(to: file)
        let exported = f.base.appendingPathComponent("clean.jsonl")
        try await log.export(to: exported)
        XCTAssertFalse(try String(contentsOf: exported, encoding: .utf8).contains("PRIVATE"))
        try Data("{\"schemaVersion\":".utf8).write(to: file)
        let rejected = f.base.appendingPathComponent("truncated.jsonl")
        await expect(.corruptLog) { try await log.export(to: rejected) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }

    func testConcurrentAppendExportAndClearRemainSerializedAndProtectSessions() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let log = f.log(); let sentinels = try f.sentinels()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    log.record(.init(source: .app, signal: .appStarted))
                    if index % 3 == 0 { try await log.clear() }
                    else { try await log.export(to: f.base.appendingPathComponent("export-\(index).jsonl")) }
                }
            }
            try await group.waitForAll()
        }
        for file in try FileManager.default.contentsOfDirectory(at: f.base, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("export-") { _ = try f.decode(Data(contentsOf: file)) }
        try f.assertUnchanged(sentinels)
    }

    func testIssueTrackerDeduplicatesSnapshotsButRecordsNewEpisodesAndSessions() {
        let sink = DiagnosticMemorySink(); var tracker = DiagnosticIssueTracker()
        let issue = UserIssue(code: .noInput); let id = SessionID()
        for _ in 0..<50 { tracker.update([issue, issue], source: .recording, sessionID: id, recorder: sink) }
        XCTAssertEqual(sink.entries.count, 1)
        tracker.update([], source: .recording, sessionID: id, recorder: sink)
        tracker.update([issue], source: .recording, sessionID: id, recorder: sink)
        XCTAssertEqual(sink.entries.count, 2)
    }

    @MainActor func testSettingsCancellationJoinsOperationAndReleasesLifecycleAdmission() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let gate = DiagnosticAsyncGate(); let entered = expectation(description: "export admitted")
        let authority = LifecycleWorkAuthority()
        var control: DiagnosticCancellation?
        let model = DiagnosticSettingsViewModel(manager: f.log(), authority: authority, exportLogs: { value in
            control = value; entered.fulfill(); await gate.wait(); try value.check(); return true
        })
        let exporting = Task { await model.export() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.busy); XCTAssertTrue(model.currentWork().active)
        XCTAssertTrue(authority.state().active)
        let quitting = Task { await model.quiesce() }
        for _ in 0..<100 {
            if let control, (try? control.check()) == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertThrowsError(try XCTUnwrap(control).check())
        await gate.release(); await quitting.value; await exporting.value
        XCTAssertFalse(model.currentWork().active); XCTAssertFalse(model.currentWork().requiresAttention)
        XCTAssertFalse(authority.state().active)
        XCTAssertNil(model.issue); XCTAssertNil(model.message)
    }

    @MainActor func testSettingsFailureCanBeInspectedAndDoesNotBlockExplicitQuit() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let model = DiagnosticSettingsViewModel(manager: f.log(), exportLogs: { _ in throw DiagnosticFailure.exportFailed })
        await model.export()
        XCTAssertEqual(model.issue?.code, .diagnosticExport)
        XCTAssertTrue(model.currentWork().requiresAttention)
        await model.quiesce()
        XCTAssertFalse(model.currentWork().requiresAttention)
        XCTAssertFalse(model.currentWork().active)
        await model.clear(); XCTAssertNil(model.issue)
    }

    func testRetentionPolicyCannotExceedSpecification() {
        XCTAssertThrowsError(try DiagnosticRetentionPolicy(maximumBytes: 100_000_001))
        XCTAssertThrowsError(try DiagnosticRetentionPolicy(maximumAge: 30 * 86_400 + 1))
        XCTAssertThrowsError(try DiagnosticRetentionPolicy(fileBytes: 100_000_001))
        XCTAssertThrowsError(try DiagnosticRetentionPolicy(pendingLimit: 257))
    }

    private func expect(_ code: DiagnosticFailure, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(code)", file: file, line: line) }
        catch { XCTAssertEqual(error as? DiagnosticFailure, code, file: file, line: line) }
    }
}

private struct DiagnosticFixture: Sendable {
    let base: URL
    var logs: URL { base.appendingPathComponent("Diagnostics", isDirectory: true) }
    init() throws {
        base = try LocalDiagnosticLog.canonicalDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("T25-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func log(policy: DiagnosticRetentionPolicy = try! .init(), now: @escaping @Sendable () -> Date = { Date() }) -> LocalDiagnosticLog {
        .init(directory: logs, policy: policy, now: now)
    }
    func ownedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("log-") }
    }
    func decode(_ data: Data) throws -> [DiagnosticEntry] {
        try data.split(separator: 0x0A).map { try JSONDecoder().decode(DiagnosticEntry.self, from: Data($0)) }
    }
    func sentinels() throws -> [URL: Data] {
        let session = base.appendingPathComponent("Sessions/active/recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var values: [URL: Data] = [:]
        for directory in [session, logs] {
            for name in ["audio.m4a", "transcript.json", "events.jsonl", "audio.recovery.mov"] {
                let url = directory.appendingPathComponent(name); let data = Data("PRIVATE-\(name)".utf8)
                try data.write(to: url); values[url] = data
            }
        }
        return values
    }
    func assertUnchanged(_ values: [URL: Data], file: StaticString = #filePath, line: UInt = #line) throws {
        for (url, data) in values { XCTAssertEqual(try Data(contentsOf: url), data, file: file, line: line) }
    }
}
private final class DiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}
private final class DiagnosticBlockingWrite: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0); let release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var first = true
    func blockThenFail() throws {
        let block = lock.withLock { let result = first; first = false; return result }
        if block { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        throw DiagnosticFailure.storage
    }
}
private final class DiagnosticMemorySink: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock(); private var values: [DiagnosticEntry] = []
    var entries: [DiagnosticEntry] { lock.withLock { values } }
    func record(_ entry: DiagnosticEntry) { lock.withLock { values.append(entry) } }
}
private actor DiagnosticAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}
