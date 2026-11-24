import AVFoundation
import Darwin
import XCTest
@testable import LocalLectureSTT

final class SessionDetailTests: XCTestCase {
    func testReadOnlyDetailAndMissingCorruptFilesNeverRewriteOrDeleteData() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); chmod(f.audio.root.path, 0o755); f.audio.clean() }
        let original = try f.bytes()
        let loaded = try await f.store.load(f.audio.location)
        XCTAssertTrue(loaded.editable); XCTAssertEqual(loaded.transcript?.segments.count, 2)
        XCTAssertEqual(try f.bytes(), original)
        XCTAssertEqual(chmod(f.audio.root.path, 0o555), 0)
        _ = try await f.store.load(f.audio.location)
        do { try await f.store.updateText(f.audio.location, segment: loaded.transcript!.segments[0].id, expected: "한국어 API", text: "수정"); XCTFail() }
        catch { XCTAssertEqual((error as? StorageError)?.code, .rootNotWritable) }
        XCTAssertEqual(chmod(f.audio.root.path, 0o755), 0)
        XCTAssertEqual(try f.bytes(), original)
        try Data("broken".utf8).write(to: f.audio.url("transcript.json"))
        let damaged = try await f.store.load(f.audio.location)
        XCTAssertFalse(damaged.editable); XCTAssertNil(damaged.transcript); XCTAssertFalse(damaged.issues.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.json")), Data("broken".utf8))
        try FileManager.default.removeItem(at: f.audio.url("recovery"))
        let missing = try await f.store.load(f.audio.location)
        XCTAssertFalse(missing.editable); XCTAssertTrue(missing.availableFiles.contains(.audio))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.audio.url("audio.m4a").path))
    }

    func testTextEditRenameAndRegenerationPreserveEveryImmutableFieldAndFolder() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let before = try await f.store.load(f.audio.location)
        let original = before.transcript!
        let first = original.segments[0]
        let audioBytes = try Data(contentsOf: f.audio.url("audio.m4a"))
        try await f.store.updateText(f.audio.location, segment: first.id, expected: first.text, text: "수정한 GPU\n두 번째 줄")
        let changed = try await f.store.load(f.audio.location)
        var expected = original.segments; expected[0].text = "수정한 GPU\n두 번째 줄"
        XCTAssertEqual(changed.transcript?.segments, expected)
        XCTAssertEqual(changed.transcript?.segments[0].originalText, first.originalText)
        try await f.store.updateTitle(f.audio.location, expected: before.metadata!.title, title: "강의: \"선형대수\"")
        let renamed = try await f.store.load(f.audio.location)
        XCTAssertEqual(renamed.metadata?.title, "강의: \"선형대수\"")
        XCTAssertEqual(renamed.transcript, changed.transcript)
        XCTAssertEqual(renamed.location.folderName, f.audio.location.folderName)
        XCTAssertEqual(renamed.metadata?.modelSettings, before.metadata?.modelSettings)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("audio.m4a")), audioBytes)
        let rendered = try TranscriptRenderer.render(renamed.transcript!, metadata: renamed.metadata!)
        try Data("외부 수정은 원본이 아님".utf8).write(to: f.audio.url("transcript.md"))
        try await f.store.regenerate(f.audio.location)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.md")), rendered.markdown)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.txt")), rendered.text)
        let items = try await f.catalog.orderedItems(); XCTAssertEqual(items.first?.title, renamed.metadata?.title)
        do { try await f.store.updateText(f.audio.location, segment: first.id, expected: first.text, text: "stale"); XCTFail() }
        catch { XCTAssertEqual((error as? TranscriptFailure)?.code, .editConflict) }
    }

    func testRenameDerivedFailureKeepsAuthoritativeTitleAndSupportsRetry() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let fail = DetailOneShotFailure()
        let repository = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: {
            if $0 == .beforeMarkdown { try await fail.hit() }
        })
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: repository, catalog: f.catalog,
            activity: f.activity, actions: f.actions)
        let before = try await store.load(f.audio.location)
        do { try await store.updateTitle(f.audio.location, expected: before.metadata!.title, title: "새 제목"); XCTFail() } catch {}
        let partial = try await store.load(f.audio.location)
        XCTAssertEqual(partial.metadata?.title, "새 제목"); XCTAssertEqual(partial.transcript, before.transcript)
        try await store.updateTitle(f.audio.location, expected: before.metadata!.title, title: "새 제목")
        let rendered = try TranscriptRenderer.render(partial.transcript!, metadata: partial.metadata!)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.md")), rendered.markdown)
    }

    func testActivityAdmissionProtectsEditsTrashAndRecoveryIncludingCreationReservation() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let creation = await f.activity.reserveRecordingCreation(rootID: f.audio.location.rootID)
        do { _ = try await f.store.trash(f.audio.location); XCTFail() }
        catch { XCTAssertEqual(error as? SessionDetailFailure, .busy) }
        await f.activity.release(creation)
        let claim = await f.activity.claimUserOperation(at: f.audio.location)!
        await f.activity.releaseRecordingOrFinalization(at: f.audio.location)
        let recovery = await f.activity.claimRecovery(at: f.audio.location)
        let promoted = await f.activity.promoteToFinalization(claim)
        XCTAssertNil(recovery); XCTAssertFalse(promoted)
        do { try await f.store.regenerate(f.audio.location); XCTFail() }
        catch { XCTAssertEqual(error as? SessionDetailFailure, .busy) }
        await f.activity.release(claim)
        try await f.store.regenerate(f.audio.location)
        XCTAssertEqual(f.actions.trashCount, 0)
    }

    func testTrashMovesWholeSessionOnlyAfterSuccessAndRestoredFilesRebuildCatalog() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let bytes = try f.bytes()
        f.actions.failTrash = true
        do { _ = try await f.store.trash(f.audio.location); XCTFail() } catch {}
        XCTAssertEqual(try f.bytes(), bytes)
        var items = try await f.catalog.orderedItems(); XCTAssertEqual(items.count, 1)
        f.actions.failTrash = false
        let result = try await f.store.trash(f.audio.location)
        XCTAssertFalse(result.catalogWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.audio.url("metadata.json").path))
        items = try await f.catalog.orderedItems(); XCTAssertTrue(items.isEmpty)
        try FileManager.default.moveItem(at: f.actions.destination, to: f.audio.url(""))
        _ = try await f.catalog.reconcile()
        items = try await f.catalog.orderedItems(); XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try f.bytes(), bytes)
    }

    func testUnsafeSymlinkAndDirectoryReplacementNeverRevealOrTrashAnotherTarget() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let external = f.audio.base.appendingPathComponent("external.md")
        try Data("must remain".utf8).write(to: external)
        try FileManager.default.removeItem(at: f.audio.url("transcript.md"))
        try FileManager.default.createSymbolicLink(at: f.audio.url("transcript.md"), withDestinationURL: external)
        do { try await f.store.reveal(.markdown, at: f.audio.location); XCTFail() } catch {}
        XCTAssertEqual(f.actions.reveals.count, 0)
        XCTAssertEqual(try Data(contentsOf: external), Data("must remain".utf8))
        let original = f.audio.url(""); let parked = f.audio.base.appendingPathComponent("parked")
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: f.transcripts, catalog: f.catalog,
            activity: f.activity, actions: f.actions, beforeAction: {
                try FileManager.default.moveItem(at: original, to: parked)
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            })
        do { _ = try await store.trash(f.audio.location); XCTFail() } catch {}
        XCTAssertEqual(f.actions.trashCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.appendingPathComponent("audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRevealUsesRequestedArtifactAndBalancedRootLease() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        for file in SessionDetailFile.allCases { try await f.store.reveal(file, at: f.audio.location) }
        XCTAssertEqual(f.actions.reveals.map(\.lastPathComponent), SessionDetailFile.allCases.map(\.rawValue))
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
    }

    func testScanStartedBeforeTrashCannotReinsertDeletedCatalogRow() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let gate = T14Gate()
        let scanner = DetailHeldScanner(scanner: SessionFileScanner(roots: f.audio.roots), gate: gate)
        let database = try SQLiteSessionCatalogStore(applicationSupportDirectory: f.audio.base.appendingPathComponent("race-catalog"))
        addTeardownBlock { try await database.close() }
        let catalog = SessionCatalogReconciler(scanner: scanner, store: database)
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: f.transcripts, catalog: catalog,
            activity: f.activity, actions: f.actions)
        let scan = Task { try await catalog.reconcile() }
        try await gate.wait()
        let moved = try await store.trash(f.audio.location)
        XCTAssertFalse(moved.catalogWarning)
        await gate.release()
        _ = try await scan.value
        let items = try await catalog.orderedItems(); XCTAssertTrue(items.isEmpty)
        let scans = await scanner.calls; XCTAssertEqual(scans, 2, "stale scan must be discarded and read again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.actions.destination.appendingPathComponent("audio.m4a").path))
    }

    func testCatalogRemovalFailureAfterTrashIsWarningAndNeverRetriesOrRollsBackMove() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: f.transcripts,
            catalog: UnavailableSessionCatalog(error: .stepFailed), activity: f.activity, actions: f.actions)
        let result = try await store.trash(f.audio.location)
        XCTAssertTrue(result.catalogWarning); XCTAssertEqual(f.actions.trashCount, 1)
        do { _ = try await store.trash(f.audio.location); XCTFail() } catch {}
        XCTAssertEqual(f.actions.trashCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.actions.destination.appendingPathComponent("transcript.json").path))
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
    }

    func testOlderScanCannotRevertTitleAfterSuccessfulRename() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let gate = T14Gate()
        let scanner = DetailHeldScanner(scanner: SessionFileScanner(roots: f.audio.roots), gate: gate)
        let database = try SQLiteSessionCatalogStore(applicationSupportDirectory: f.audio.base.appendingPathComponent("rename-catalog"))
        addTeardownBlock { try await database.close() }
        let catalog = SessionCatalogReconciler(scanner: scanner, store: database)
        let repository = FileTranscriptRepository(roots: f.audio.roots, catalog: catalog)
        let metadata = try await f.audio.repository.readMetadata(at: f.audio.location)
        let oldScan = Task { try await catalog.reconcile() }
        try await gate.wait()
        try await repository.updateTitle(at: f.audio.location, expectedTitle: metadata.title, title: "최신 제목")
        var items = try await catalog.orderedItems(); XCTAssertEqual(items.first?.title, "최신 제목")
        await gate.release(); _ = try await oldScan.value
        items = try await catalog.orderedItems(); XCTAssertEqual(items.first?.title, "최신 제목")
        let saved = try await f.audio.repository.readMetadata(at: f.audio.location)
        XCTAssertEqual(saved.title, "최신 제목")
    }

    func testMetadataReplacementAndRecoveryOwnershipRejectTrashWithoutMovingFiles() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let claim = await f.activity.claimRecovery(at: f.audio.location)!
        do { _ = try await f.store.trash(f.audio.location); XCTFail() }
        catch { XCTAssertEqual(error as? SessionDetailFailure, .busy) }
        await f.activity.release(claim)
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: f.transcripts, catalog: f.catalog,
            activity: f.activity, actions: f.actions, beforeAction: {
                try Data("changed after confirmation".utf8).write(to: f.audio.url("metadata.json"), options: .atomic)
            })
        do { _ = try await store.trash(f.audio.location); XCTFail() }
        catch { XCTAssertEqual(error as? SessionDetailFailure, .identityChanged) }
        XCTAssertEqual(f.actions.trashCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.audio.url("audio.m4a").path))
    }
}

private actor DetailHeldScanner: SessionFileScanning {
    let scanner: SessionFileScanner
    let gate: T14Gate
    var calls = 0
    init(scanner: SessionFileScanner, gate: T14Gate) { self.scanner = scanner; self.gate = gate }
    func scan() async throws -> [RootScanResult] {
        calls += 1
        let result = try await scanner.scan()
        if calls == 1 { await gate.hold() }
        return result
    }
}

private actor DetailOneShotFailure {
    var armed = true
    func hit() throws { if armed { armed = false; throw AudioFinalizationCode.diskFull } }
}

struct DetailFixture: Sendable {
    let database: SQLiteSessionCatalogStore
    let audio: FinalizationFixture
    let catalog: SessionCatalogReconciler
    let transcripts: FileTranscriptRepository
    let store: FileSessionDetailStore
    let activity: SessionActivityRegistry
    let actions: DetailFileActions
    static func make() async throws -> Self {
        let audio = try await FinalizationFixture.make()
        let db = try SQLiteSessionCatalogStore(applicationSupportDirectory: audio.base.appendingPathComponent("catalog"))
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: audio.roots), store: db)
        let transcripts = FileTranscriptRepository(roots: audio.roots, catalog: catalog)
        for (index, start, end, text) in [(0, 0, 1_000, "한국어 API"), (1, 500, 1_500, "겹친 문장")] {
            let segment = try TranscriptSegment(id: .init(), sequence: .init(Int64(index)), startMs: .init(Int64(start)),
                endMs: .init(Int64(end)), originalText: text, text: text, language: .init("ko"))
            try await audio.repository.appendTranscriptJournal(.init(sessionId: audio.location.sessionID, segment: segment), at: audio.location)
        }
        let ready = await audio.worker().finalize(.init(location: audio.location), control: .init(), progress: { _ in })
        guard ready.failure == nil else { throw ready.failure! }
        _ = try await transcripts.finalize(at: audio.location, audio: ready, control: .init())
        let activity = SessionActivityRegistry()
        let actions = DetailFileActions(destination: audio.base.appendingPathComponent("trash"))
        return .init(database: db, audio: audio, catalog: catalog, transcripts: transcripts,
            store: FileSessionDetailStore(roots: audio.roots, transcripts: transcripts, catalog: catalog, activity: activity, actions: actions),
            activity: activity, actions: actions)
    }
    func bytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["metadata.json", "audio.m4a", "transcript.json", "transcript.txt", "transcript.md"].map {
            ($0, try Data(contentsOf: audio.url($0)))
        })
    }
}
final class DetailFileActions: SessionFileActions, @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var moves = 0
    private var fails = false
    var failTrash: Bool { get { lock.withLock { fails } } set { lock.withLock { fails = newValue } } }
    var reveals: [URL] { lock.withLock { recorded } }
    var trashCount: Int { lock.withLock { moves } }
    init(destination: URL) { self.destination = destination }
    func reveal(_ url: URL) async throws { lock.withLock { recorded.append(url) } }
    func trash(_ url: URL) throws {
        if failTrash { throw SessionDetailFailure.unavailable }
        try FileManager.default.moveItem(at: url, to: destination)
        lock.withLock { moves += 1 }
    }
}

@MainActor
final class SessionDetailInteractionTests: XCTestCase {
    func testTimestampSeekAndTextSaveUseRealRepositoryWithoutChangingImmutableFields() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let player = DetailTestPlayback()
        let model = SessionDetailViewModel(store: f.store, player: player)
        let item = try await f.catalog.orderedItems()[0]
        let selected = await model.select(item); XCTAssertTrue(selected)
        let original = model.document!.transcript!.segments[1]
        await model.seek(original.startMs.rawValue)
        XCTAssertEqual(player.seeks, [500]); XCTAssertEqual(player.opened, [f.audio.location])
        model.edit(original); model.draft = "교정한 텍스트"
        let refused = await model.select(item); XCTAssertFalse(refused)
        await model.save()
        var expected = original; expected.text = "교정한 텍스트"
        XCTAssertEqual(model.document?.transcript?.segments[1], expected)
        XCTAssertFalse(model.hasDraft); XCTAssertNil(model.message)
        XCTAssertEqual(player.value.phase, .idle)
        await model.quiesce()
    }

    func testFailedSaveRetainsDraftAndQuiesceRetriesItWithoutInvalidatingQuitAdmission() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let fail = DetailOneShotFailure()
        let repository = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: {
            if $0 == .afterCanonical { try await fail.hit() }
        })
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: repository, catalog: f.catalog,
            activity: f.activity, actions: f.actions)
        let authority = LifecycleWorkAuthority()
        let model = SessionDetailViewModel(store: store, player: DetailTestPlayback(), authority: authority)
        let item = try await f.catalog.orderedItems()[0]
        await model.select(item)
        model.edit(model.document!.transcript!.segments[0]); model.draft = "초안 보존"
        await model.save()
        XCTAssertTrue(model.hasDraft); XCTAssertEqual(model.draft, "초안 보존")
        XCTAssertTrue(model.currentWork().active); XCTAssertTrue(model.currentWork().requiresAttention)
        let generation = authority.state().generation
        await model.quiesce()
        XCTAssertFalse(model.hasDraft); XCTAssertFalse(model.currentWork().active)
        XCTAssertFalse(authority.state().active); XCTAssertEqual(authority.state().generation, generation)
        XCTAssertEqual(model.document?.transcript?.segments[0].text, "초안 보존")
        await model.quiesce()
        XCTAssertEqual(authority.state().generation, generation, "idle cleanup must not invalidate a quit attempt")
    }

    func testDeleteRequiresCurrentSelectionAndSuccessfulMoveDoesNotLeaveFailureAttention() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let other = try await DetailFixture.make()
        addTeardownBlock { try await other.database.close(); other.audio.clean() }
        let authority = LifecycleWorkAuthority()
        let model = SessionDetailViewModel(store: f.store, player: DetailTestPlayback(), authority: authority)
        let item = try await f.catalog.orderedItems()[0]
        await model.select(item); model.requestDeletion(); let target = model.deletion!
        model.deletion = nil
        XCTAssertEqual(f.actions.trashCount, 0, "cancel has no file side effects")
        let another = try await other.catalog.orderedItems()[0]
        await model.select(another)
        await model.confirmDeletion(target)
        XCTAssertEqual(f.actions.trashCount, 0, "stale confirmation cannot delete the previous session")
        await model.select(item); model.requestDeletion(); await model.confirmDeletion(target)
        XCTAssertEqual(f.actions.trashCount, 1); XCTAssertNil(model.item)
        XCTAssertFalse(model.currentWork().requiresAttention)
        XCTAssertFalse(authority.state().active)
    }

    func testPlayerReadsActualAACAndSeeksWhilePausedWithBalancedScopes() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let player = SessionAudioPlayer(roots: f.audio.roots, activity: f.activity)
        var latest = SessionPlaybackSnapshot()
        let observer = Task { for await value in player.snapshots() { latest = value } }
        defer { observer.cancel() }
        try await player.open(f.audio.location)
        try await player.seek(to: 500)
        await eventually { latest.positionMilliseconds == 500 }
        XCTAssertEqual(latest.phase, .paused)
        XCTAssertEqual(Double(latest.durationMilliseconds), 2_000, accuracy: 50)
        try await player.seek(to: 99_000)
        await eventually { latest.positionMilliseconds == latest.durationMilliseconds }
        do { try await player.seek(to: -1); XCTFail() }
        catch { XCTAssertEqual(error as? SessionDetailFailure, .invalidSeek) }
        await player.close()
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
        let claim = await f.activity.claimRecovery(at: f.audio.location); XCTAssertNotNil(claim)
        if let claim { await f.activity.release(claim) }
    }

    func testTransportRejectsOldCallbacksAndReleasesResourcesOnPlayFailure() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        var drivers: [DetailAudioDriver] = []
        let player = SessionAudioPlayer(roots: f.audio.roots, activity: f.activity, makeDriver: { _ in
            let driver = DetailAudioDriver(); drivers.append(driver); return driver
        })
        var latest = SessionPlaybackSnapshot()
        let observer = Task { for await value in player.snapshots() { latest = value } }
        defer { observer.cancel() }
        try await player.open(f.audio.location); try await player.play()
        await eventually { latest.phase == .playing }
        let oldCallback = drivers[0].finished
        player.pause(); try await player.seek(to: 700)
        XCTAssertEqual(drivers[0].currentTime, 0.7)
        await player.close(); try await player.open(f.audio.location)
        oldCallback?(false)
        await eventually { latest.phase == .paused }
        XCTAssertEqual(drivers[1].stops, 0)
        drivers[1].playAllowed = false
        do { try await player.play(); XCTFail() } catch {}
        await eventually { latest.phase == .failed }
        XCTAssertEqual(drivers[1].stops, 1)
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
        await player.close()
        XCTAssertEqual(drivers[1].stops, 1, "repeated close must not stop/release an old owner again")
    }

    func testPlaybackFileReplacementFailsSafelyAndDoesNotDeleteEitherCopy() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let driver = DetailAudioDriver()
        let player = SessionAudioPlayer(roots: f.audio.roots, activity: f.activity, makeDriver: { _ in driver })
        try await player.open(f.audio.location)
        let parked = f.audio.base.appendingPathComponent("original.m4a")
        try FileManager.default.moveItem(at: f.audio.url("audio.m4a"), to: parked)
        try Data("replacement".utf8).write(to: f.audio.url("audio.m4a"))
        do { try await player.seek(to: 500); XCTFail() } catch {}
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("audio.m4a")), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
        await player.close()
    }

    func testPersistentSaveFailurePreventsQuitAndKeepsDraftAndOriginalBytes() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let before = try f.bytes()
        let repository = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: {
            if $0 == .beforeCanonical { throw AudioFinalizationCode.diskFull }
        })
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: repository, catalog: f.catalog,
            activity: f.activity, actions: f.actions)
        let authority = LifecycleWorkAuthority()
        let model = SessionDetailViewModel(store: store, player: DetailTestPlayback(), authority: authority)
        await model.select(try await f.catalog.orderedItems()[0])
        model.edit(model.document!.transcript!.segments[0]); model.draft = "잃으면 안 되는 초안"
        await model.quiesce()
        XCTAssertTrue(model.hasDraft); XCTAssertEqual(model.draft, "잃으면 안 되는 초안")
        XCTAssertTrue(model.currentWork().active); XCTAssertTrue(model.currentWork().requiresAttention)
        XCTAssertTrue(authority.state().active); XCTAssertEqual(try f.bytes(), before)
        await model.cancelEdit(); XCTAssertFalse(authority.state().active)
    }

    func testCancellingDraftAfterPartialSaveDisplaysDurableCanonicalText() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let fail = DetailOneShotFailure()
        let repository = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: {
            if $0 == .afterCanonical { try await fail.hit() }
        })
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: repository, catalog: f.catalog,
            activity: f.activity, actions: f.actions)
        let model = SessionDetailViewModel(store: store, player: DetailTestPlayback())
        await model.select(try await f.catalog.orderedItems()[0])
        let original = model.document!.transcript!.segments[0]
        model.edit(original); model.draft = "이미 JSON에 저장된 내용"
        await model.save()
        XCTAssertTrue(model.hasDraft)
        await model.cancelEdit()
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.document?.transcript?.segments[0].text, "이미 JSON에 저장된 내용")
        XCTAssertEqual(model.document?.transcript?.segments[0].originalText, original.originalText)
        XCTAssertTrue(model.currentWork().requiresAttention)
        await model.regenerate()
        XCTAssertFalse(model.currentWork().requiresAttention)
        let canonical = try await store.load(f.audio.location)
        let rendered = try TranscriptRenderer.render(canonical.transcript!, metadata: canonical.metadata!)
        XCTAssertEqual(try Data(contentsOf: f.audio.url("transcript.md")), rendered.markdown)
    }

    func testQuiesceJoinsSavingAndDuplicateActionsCannotTrashOrSelect() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let gate = T14Gate()
        let repository = FileTranscriptRepository(roots: f.audio.roots, catalog: f.catalog, hook: {
            if $0 == .beforeCanonical { await gate.hold() }
        })
        let store = FileSessionDetailStore(roots: f.audio.roots, transcripts: repository, catalog: f.catalog,
            activity: f.activity, actions: f.actions)
        let model = SessionDetailViewModel(store: store, player: DetailTestPlayback())
        let item = try await f.catalog.orderedItems()[0]
        await model.select(item); model.edit(model.document!.transcript!.segments[0]); model.draft = "저장 대기"
        let saving = Task { await model.save() }
        try await gate.wait()
        XCTAssertTrue(model.busy)
        model.requestDeletion(); XCTAssertNil(model.deletion)
        let selected = await model.select(item); XCTAssertFalse(selected)
        await model.save()
        let quitting = Task { await model.quiesce() }
        await Task.yield(); XCTAssertTrue(model.currentWork().active)
        await gate.release(); await saving.value; await quitting.value
        XCTAssertFalse(model.hasDraft); XCTAssertFalse(model.currentWork().active)
        XCTAssertEqual(model.document?.transcript?.segments[0].text, "저장 대기")
        XCTAssertEqual(f.actions.trashCount, 0)
    }

    func testCorruptAndMissingAudioFailWithoutDeletionOrLeakedClaims() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let player = SessionAudioPlayer(roots: f.audio.roots, activity: f.activity)
        try Data("invalid audio".utf8).write(to: f.audio.url("audio.m4a"))
        do { try await player.open(f.audio.location); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: f.audio.url("audio.m4a")), Data("invalid audio".utf8))
        try FileManager.default.removeItem(at: f.audio.url("audio.m4a"))
        do { try await player.open(f.audio.location); XCTFail() } catch {}
        let claim = await f.activity.claimRecovery(at: f.audio.location); XCTAssertNotNil(claim)
        if let claim { await f.activity.release(claim) }
        let counts = await f.audio.bookmarks.counts(); XCTAssertEqual(counts[0], counts[1])
        await player.close()
    }

    func testLateOpenAfterCloseCannotReleaseNewPlaybackClaimOrSecurityScope() async throws {
        let f = try await DetailFixture.make()
        addTeardownBlock { try await f.database.close(); f.audio.clean() }
        let gate = T14Gate()
        let bookmarks = DetailHeldBookmarks(gate: gate)
        let roots = StorageRootManager(applicationSupportDirectory: f.audio.base.appendingPathComponent("support"), bookmarkCodec: bookmarks)
        let driver = DetailAudioDriver()
        let player = SessionAudioPlayer(roots: roots, activity: f.activity, makeDriver: { _ in driver })
        let old = Task { try await player.open(f.audio.location) }
        try await gate.wait()
        await player.close()
        try await player.open(f.audio.location)
        await gate.release()
        do { try await old.value; XCTFail() }
        catch { XCTAssertEqual(error as? SessionDetailFailure, .cancelled) }
        XCTAssertEqual(driver.stops, 0)
        var counts = await bookmarks.counts(); XCTAssertEqual(counts, [2, 1])
        let blocked = await f.activity.claimRecovery(at: f.audio.location); XCTAssertNil(blocked)
        try await player.seek(to: 700); XCTAssertEqual(driver.currentTime, 0.7)
        await player.close()
        counts = await bookmarks.counts(); XCTAssertEqual(counts, [2, 2])
        let released = await f.activity.claimRecovery(at: f.audio.location); XCTAssertNotNil(released)
        if let released { await f.activity.release(released) }
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<5_000 { if predicate() { return }; await Task.yield() }
        XCTFail("State did not settle")
    }
}

private actor DetailHeldBookmarks: SecurityScopedBookmarkCodec {
    let gate: T14Gate
    var held = false
    var starts = 0, stops = 0
    init(gate: T14Gate) { self.gate = gate }
    func makeBookmark(for directory: URL) async throws -> Data { Data(directory.path.utf8) }
    func resolve(_ bookmark: Data) async throws -> ResolvedBookmark {
        if !held { held = true; await gate.hold() }
        return .init(url: URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) async -> Bool { starts += 1; return true }
    func stopAccessing(_ url: URL) async { stops += 1 }
    func counts() -> [Int] { [starts, stops] }
}

@MainActor private final class DetailAudioDriver: SessionAudioDriver {
    var duration: Double = 2
    var currentTime: Double = 0
    var finished: ((Bool) -> Void)?
    var playAllowed = true
    var stops = 0
    func play() -> Bool { playAllowed }
    func pause() {}
    func stop() { stops += 1 }
}
@MainActor private final class DetailTestPlayback: SessionPlaybackControlling {
    var value = SessionPlaybackSnapshot()
    var opened: [SessionLocation] = []
    var seeks: [Int64] = []
    private var observer: AsyncStream<SessionPlaybackSnapshot>.Continuation?
    func snapshots() -> AsyncStream<SessionPlaybackSnapshot> { AsyncStream { observer = $0; $0.yield(value) } }
    func open(_ location: SessionLocation) async throws { opened.append(location); emit(.init(phase: .paused, durationMilliseconds: 2_000)) }
    func play() async throws { value.phase = .playing; emit(value) }
    func pause() { value.phase = .paused; emit(value) }
    func seek(to milliseconds: Int64) async throws { seeks.append(milliseconds); value.positionMilliseconds = milliseconds; emit(value) }
    func close() async { emit(.init()) }
    private func emit(_ value: SessionPlaybackSnapshot) { self.value = value; observer?.yield(value) }
}
