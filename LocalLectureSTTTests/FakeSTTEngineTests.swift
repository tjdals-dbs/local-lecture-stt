import XCTest
@testable import LocalLectureSTT

final class FakeSTTEngineTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 20 }

    private func expect(_ code: STTErrorCode, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch { XCTAssertEqual(error as? STTEngineError, STTEngineError(code), file: file, line: line) }
    }
    private func settled(_ fake: FakeSTTEngine, phase: FakeSTTPhase = .ready,
                         file: StaticString = #filePath, line: UInt = #line) async {
        let state = await fake.snapshot()
        XCTAssertEqual(state.phase, phase, file: file, line: line)
        XCTAssertNil(state.activeSequence, file: file, line: line)
        XCTAssertTrue(state.queuedSequences.isEmpty, file: file, line: line)
        XCTAssertEqual(state.ownedContinuations, 0, file: file, line: line)
        XCTAssertNil(state.session, file: file, line: line)
    }
    private func makeFake(_ scenario: FakeSTTScenario = .init(), capacity: Int = 2,
                          capabilities: STTCapabilities? = nil) throws -> FakeSTTEngine {
        let fake = try STTTestFixture.fake(scenario, capacity: capacity, capabilities: capabilities)
        // Wall time is only a failure watchdog; scenario timing never depends on this timer.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            XCTFail("Fake scenario exceeded its watchdog")
            await fake.releaseScenario()
        }
        addTeardownBlock { watchdog.cancel(); await watchdog.value; await fake.releaseScenario() }
        return fake
    }

    func testIndependentEarlyCallbackCannotLetNewAdmissionOvertakeQueuedWork() async throws {
        let fake = try makeFake(.init(requests: [
            STTTestFixture.final("first", at: 100),
            STTTestFixture.final("queued second", at: 10),
            STTTestFixture.final("new third", at: 10)
        ]))
        try await STTTestFixture.ready(fake)
        let firstRequest = try STTTestFixture.request(0)
        let first = try await fake.infer(firstRequest)
        let second = try await fake.infer(STTTestFixture.request(1))
        let captured = await fake.callbackLease()
        let lease = try XCTUnwrap(captured)
        let early = try STTResponse(context: firstRequest.context, revision: 1, kind: .final)
        let accepted = await fake.deliver(early, lease: lease)
        XCTAssertTrue(accepted)
        XCTAssertEqual(first.observation().terminals, 1)
        let third = try await fake.infer(STTTestFixture.request(2))
        let afterAdmission = await fake.snapshot()
        try await fake.advance(by: 10)
        let secondAtTen = second.observation().latest
        let thirdAtTen = third.observation().latest
        try await fake.advance(by: 10)
        try await fake.end()
        await settled(fake)
        XCTAssertEqual(afterAdmission.activeSequence, 1, "Previously queued work must remain first")
        XCTAssertEqual(afterAdmission.queuedSequences, [2])
        XCTAssertEqual(secondAtTen?.kind, .final)
        XCTAssertEqual(secondAtTen?.segments.first?.text, "queued second")
        XCTAssertNil(thirdAtTen, "New admission must not overtake already accepted FIFO work")
    }

    func testEarlyFailedCallbackPreservesFIFOOriginsCapacityAndTerminalOwnership() async throws {
        let fake = try makeFake(.init(requests: [
            STTTestFixture.final("must not run", at: 100),
            STTTestFixture.final("B", at: 10),
            STTTestFixture.final("C", at: 10)
        ]), capacity: 1)
        try await STTTestFixture.ready(fake)
        let request = try STTTestFixture.request(0)
        let first = try await fake.infer(request)
        let second = try await fake.infer(STTTestFixture.request(1))
        await expect(.backlogFull) { _ = try await fake.infer(STTTestFixture.request(2)) }
        let captured = await fake.callbackLease(); let lease = try XCTUnwrap(captured)
        try await fake.advance(by: 7)
        let failure = try STTResponse(context: request.context, revision: 1, kind: .failed,
                                      failure: STTEngineError(.inferenceFailed))
        let accepted = await fake.deliver(failure, lease: lease); XCTAssertTrue(accepted)
        // Promotion occurs inside callback acknowledgment, before any new admission/advance.
        let promoted = await fake.snapshot()
        XCTAssertEqual(promoted.activeSequence, 1); XCTAssertTrue(promoted.queuedSequences.isEmpty)
        let third = try await fake.infer(STTTestFixture.request(2))
        let beforeStale = await fake.snapshot()
        let repeated = await fake.deliver(failure, lease: lease); XCTAssertFalse(repeated)
        let latePartial = try STTResponse(context: request.context, revision: 2, kind: .partial)
        let late = await fake.deliver(latePartial, lease: lease); XCTAssertFalse(late)
        let afterStale = await fake.snapshot(); XCTAssertEqual(beforeStale, afterStale)
        try await fake.advance(by: 9)
        XCTAssertNil(second.observation().latest); XCTAssertNil(third.observation().latest)
        try await fake.advance(by: 1) // B's 10 ms begin at callback time 7, not admission time 0.
        XCTAssertEqual(second.observation().latest?.context.sequence, 1)
        XCTAssertEqual(second.observation().latest?.segments.first?.text, "B")
        XCTAssertNil(third.observation().latest)
        let middle = await fake.snapshot()
        XCTAssertEqual(middle.activeSequence, 2); XCTAssertTrue(middle.queuedSequences.isEmpty)
        try await fake.advance(by: 9); XCTAssertNil(third.observation().latest)
        try await fake.advance(by: 1)
        XCTAssertEqual(third.observation().latest?.context.sequence, 2)
        XCTAssertEqual(third.observation().latest?.segments.first?.text, "C")
        try await fake.advance(by: 100) // A's old scripted deadline cannot publish again.
        for feed in [first, second, third] {
            let events = try await STTTestFixture.collect(feed)
            XCTAssertEqual(events.count, 1); XCTAssertEqual(feed.observation().terminals, 1)
        }
        XCTAssertEqual(first.observation().latest?.failure?.code, .inferenceFailed)
        try await fake.end(); await settled(fake)
    }

    func testEarlyTerminalCallbackSettlesWaitingEndWithAndWithoutPendingFIFO() async throws {
        for kind: STTResponseKind in [.final, .failed] {
            for pending in [false, true] {
                let fake = try makeFake(.init(requests: [STTTestFixture.final(at: 100),
                    STTTestFixture.final("B", at: 10), STTTestFixture.final("C", at: 10)]))
                try await STTTestFixture.ready(fake)
                let request = try STTTestFixture.request(0)
                let first = try await fake.infer(request)
                var feeds = [first]
                if pending {
                    feeds.append(try await fake.infer(STTTestFixture.request(1)))
                    feeds.append(try await fake.infer(STTTestFixture.request(2)))
                }
                let captured = await fake.callbackLease(); let lease = try XCTUnwrap(captured)
                let ending = Task { try await fake.end() }
                await fake.waitUntil(.settlementWaiters(1))
                let duplicate = Task { try await fake.end() }
                await fake.waitUntil(.settlementWaiters(2))
                let response = try STTResponse(context: request.context, revision: 1, kind: kind,
                    failure: kind == .failed ? STTEngineError(.inferenceFailed) : nil)
                let accepted = await fake.deliver(response, lease: lease); XCTAssertTrue(accepted)
                let afterCallback = await fake.snapshot()
                if pending {
                    XCTAssertEqual(afterCallback.phase, .draining)
                    XCTAssertEqual(afterCallback.activeSequence, 1)
                    XCTAssertEqual(afterCallback.queuedSequences, [2])
                    XCTAssertEqual(afterCallback.ownedContinuations, 2)
                    try await fake.advance(by: 9)
                    XCTAssertNil(feeds[1].observation().latest); XCTAssertNil(feeds[2].observation().latest)
                    try await fake.advance(by: 1)
                    XCTAssertEqual(feeds[1].observation().latest?.segments.first?.text, "B")
                    XCTAssertNil(feeds[2].observation().latest)
                    let middle = await fake.snapshot()
                    XCTAssertEqual(middle.phase, .draining); XCTAssertEqual(middle.activeSequence, 2)
                    try await fake.advance(by: 10)
                    XCTAssertEqual(feeds[2].observation().latest?.segments.first?.text, "C")
                } else {
                    // No extra advance, admission or control call may be needed to release end.
                    XCTAssertEqual(afterCallback.phase, .ready)
                    XCTAssertEqual(afterCallback.ownedContinuations, 0)
                }
                try await ending.value; try await duplicate.value
                await settled(fake)
                let repeated = await fake.deliver(response, lease: lease); XCTAssertFalse(repeated)
                for feed in feeds {
                    let events = try await STTTestFixture.collect(feed)
                    XCTAssertEqual(events.count, 1); XCTAssertEqual(feed.observation().terminals, 1)
                }
                XCTAssertEqual(first.observation().latest?.kind, kind)
            }
        }
    }

    func testEarlyCallbackPumpsEqualDeadlineSnapshotsAndNextWorkerWithoutReentry() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final(at: 100), [
            .init(after: 0, kind: .partial, text: "B partial"),
            .init(after: 0, kind: .final, text: "B final")
        ], STTTestFixture.final("C", at: 10)]))
        try await STTTestFixture.ready(fake)
        let request = try STTTestFixture.request(0)
        let first = try await fake.infer(request)
        let second = try await fake.infer(STTTestFixture.request(1))
        let third = try await fake.infer(STTTestFixture.request(2))
        let captured = await fake.callbackLease(); let lease = try XCTUnwrap(captured)
        let response = try STTResponse(context: request.context, revision: 1, kind: .final)
        let accepted = await fake.deliver(response, lease: lease); XCTAssertTrue(accepted)
        let events = try await STTTestFixture.collect(second)
        XCTAssertEqual(events.map(\.kind), [.partial, .final])
        XCTAssertEqual(events.map(\.revision), [1, 2])
        XCTAssertEqual(events.map { $0.segments.first?.text }, ["B partial", "B final"])
        let state = await fake.snapshot()
        XCTAssertEqual(state.activeSequence, 2); XCTAssertTrue(state.queuedSequences.isEmpty)
        XCTAssertNil(third.observation().latest)
        let repeated = await fake.deliver(response, lease: lease); XCTAssertFalse(repeated)
        try await fake.advance(by: 10)
        XCTAssertEqual(third.observation().latest?.segments.first?.text, "C")
        for feed in [first, second, third] { XCTAssertEqual(feed.observation().terminals, 1) }
        try await fake.end(); await settled(fake)
    }

    func testConstructionAndProtocolLifecycleRejectUnpreparedAndDuplicateOperations() async throws {
        let fake = try makeFake()
        let engine: any STTEngine = fake
        await settled(fake, phase: .unloaded)
        await expect(.invalidLifecycle) { try await engine.start(STTTestFixture.session()) }
        await expect(.invalidLifecycle) { _ = try await engine.infer(STTTestFixture.request()) }
        await expect(.invalidLifecycle) { try await engine.end() }
        await expect(.invalidLifecycle) { try await engine.cancel() }
        await engine.unload(); await engine.unload()
        try await engine.load(STTTestFixture.model())
        try await engine.start(STTTestFixture.session())
        await expect(.busy) { try await engine.start(STTTestFixture.session(2)) }
        await expect(.busy) { try await engine.load(STTTestFixture.model("r2")) }
        try await engine.end()
        await settled(fake)
        await expect(.invalidLifecycle) { try await engine.end() }
        await engine.unload()
        await settled(fake, phase: .unloaded)
    }

    func testFailedLoadAndStartRetryOnSameInstanceAndRepeatedCycles() async throws {
        let fake = try makeFake(.init(loads: [.init(failure: STTEngineError(.loadFailed))],
                                                starts: [.init(failure: STTEngineError(.startFailed))],
                                                requests: (0..<3).map { STTTestFixture.final("cycle \($0)") }))
        let engine: any STTEngine = fake
        await expect(.loadFailed) { try await engine.load(STTTestFixture.model()) }
        await settled(fake, phase: .unloaded)
        try await engine.load(STTTestFixture.model())
        await expect(.startFailed) { try await engine.start(STTTestFixture.session()) }
        await settled(fake)
        for cycle in 0..<3 {
            let session = try STTTestFixture.session(cycle + 1)
            if cycle > 0 { try await engine.load(session.model) }
            try await engine.start(session)
            let feed = try await engine.infer(STTTestFixture.request(session: session))
            let events = try await STTTestFixture.collect(feed)
            XCTAssertEqual(events.map(\.kind), [.final])
            XCTAssertEqual(events.first?.segments.first?.text, "cycle \(cycle)")
            try await engine.end(); await settled(fake)
            await engine.unload(); await settled(fake, phase: .unloaded)
        }
    }

    func testConcurrentStartAndLoadRejectWhilePreparationIsHeld() async throws {
        let fake = try makeFake(.init(loads: [.init(delay: 10)], starts: [.init(delay: 20)]))
        let engine: any STTEngine = fake
        let loading = Task { try await engine.load(STTTestFixture.model()) }
        await fake.waitUntil(.phase(.loading))
        await expect(.busy) { try await engine.load(STTTestFixture.model()) }
        await expect(.busy) { try await engine.start(STTTestFixture.session()) }
        try await fake.advance(by: 9)
        let held = await fake.snapshot(); XCTAssertEqual(held.phase, .loading)
        try await fake.advance(by: 1); try await loading.value
        let starting = Task { try await engine.start(STTTestFixture.session()) }
        await fake.waitUntil(.phase(.starting))
        await expect(.busy) { try await engine.start(STTTestFixture.session(2)) }
        await expect(.busy) { try await engine.load(STTTestFixture.model()) }
        try await fake.advance(by: 20); try await starting.value
        try await engine.cancel(); await settled(fake)
    }

    func testModelPinningRejectsIDRevisionChecksumEngineOptionsAndLanguageMutation() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final(), STTTestFixture.final("new model")]))
        try await STTTestFixture.ready(fake)
        let pinned = try STTTestFixture.session()
        var models = [try STTTestFixture.model("r2")]
        models.append(try .init(engine: pinned.model.engine,
                                model: ModelIdentity(id: ModelID("different"), revision: "r1", checksum: "sha256-r1"), options: pinned.model.options))
        models.append(try .init(engine: pinned.model.engine,
                                model: ModelIdentity(id: ModelID("synthetic"), revision: "r1", checksum: "different"), options: pinned.model.options))
        models.append(try STTTestFixture.model(options: STTInferenceOptions(temperature: 0.5)))
        models.append(try .init(engine: EngineIdentity(id: EngineID("fake"), version: "2"), model: pinned.model.model, options: pinned.model.options))
        for model in models {
            await expect(.busy) { try await fake.load(model) }
            let changed = try STTTestFixture.session(model: model)
            await expect(.sessionMismatch) { _ = try await fake.infer(STTTestFixture.request(session: changed)) }
            let state = await fake.snapshot(); XCTAssertEqual(state.session, pinned)
        }
        await expect(.sessionMismatch) { _ = try await fake.infer(STTTestFixture.request(session: STTTestFixture.session(mode: .english))) }
        let original = try await fake.infer(STTTestFixture.request())
        XCTAssertEqual(original.observation().latest?.context.session, pinned)
        try await fake.end()
        let next = try STTTestFixture.session(2, model: STTTestFixture.model("r2"))
        try await fake.load(next.model); try await fake.start(next)
        let feed = try await fake.infer(STTTestFixture.request(session: next))
        XCTAssertEqual(feed.observation().latest?.context.session.model.model.revision, "r2")
        try await fake.end(); await settled(fake)
    }

    func testCapabilitiesRejectUnsupportedFormatLanguageOptionsAndEngineWithoutStateMutation() async throws {
        let caps = try STTTestFixture.capabilities(modes: [.korean], partials: false, timestamps: false)
        let fake = try makeFake(capabilities: caps)
        await expect(.unsupportedCapability) { try await fake.load(STTTestFixture.model()) }
        await settled(fake, phase: .unloaded)
        let options = try STTInferenceOptions(partialResults: false, timestamps: false)
        let model = try STTTestFixture.model(options: options)
        let other = try STTModelConfiguration(engine: EngineIdentity(id: EngineID("other"), version: "1"), model: model.model, options: options)
        await expect(.unsupportedModel) { try await fake.load(other) }
        try await fake.load(model)
        await expect(.unsupportedCapability) { try await fake.start(STTTestFixture.session(model: model, mode: .automatic)) }
        let session = try STTTestFixture.session(model: model)
        try await fake.start(session)
        let wrong = try STTInferenceAudio(format: STTInputFormat(sampleRate: 8_000), frameCount: 160, samples: Array(repeating: 0, count: 160))
        let request = try STTInferenceRequest(session: session, requestID: STTRequestID(STTTestFixture.uuid(300)), sequence: 0,
                                              mediaStart: MediaMilliseconds(0), audio: wrong)
        let before = await fake.snapshot()
        await expect(.unsupportedCapability) { _ = try await fake.infer(request) }
        let after = await fake.snapshot(); XCTAssertEqual(before, after)
        try await fake.end()
    }

    func testPartialsReplaceInOrderFinalOnceAndRejectLateOrReversedCallbacks() async throws {
        let fake = try makeFake(.init(requests: [[
            .init(after: 10, kind: .partial, text: "한국"),
            .init(after: 20, kind: .partial, text: "한국어 Swift"),
            .init(after: 30, kind: .final, text: "한국어 Swift concurrency", detectedLanguage: LanguageCode("ko"))
        ]]))
        try await STTTestFixture.ready(fake)
        let feed = try await fake.infer(STTTestFixture.request())
        let stream = try feed.events(); var iterator = stream.makeAsyncIterator()
        let leaseValue = await fake.callbackLease()
        let lease = try XCTUnwrap(leaseValue)
        XCTAssertNil(feed.observation().latest)
        try await fake.advance(by: 9); XCTAssertNil(feed.observation().latest)
        try await fake.advance(by: 1)
        let first = await iterator.next(); XCTAssertEqual(first?.revision, 1); XCTAssertEqual(first?.segments.first?.text, "한국")
        let stale = try STTResponse(context: STTTestFixture.request().context, revision: 1, kind: .partial)
        let acceptedStale = await fake.deliver(stale, lease: lease); XCTAssertFalse(acceptedStale)
        try await fake.advance(by: 10)
        let second = await iterator.next(); XCTAssertEqual(second?.revision, 2); XCTAssertEqual(second?.segments.first?.text, "한국어 Swift")
        try await fake.advance(by: 10)
        let final = await iterator.next(); XCTAssertEqual(final?.revision, 3); XCTAssertEqual(final?.kind, .final)
        XCTAssertEqual(final?.segments.first?.start.rawValue, 5_000); XCTAssertEqual(final?.segments.first?.end.rawValue, 5_010)
        XCTAssertEqual(final?.segments.first?.text, "한국어 Swift concurrency")
        let after = await iterator.next(); XCTAssertNil(after)
        let acceptedLate = await fake.deliver(stale, lease: lease); XCTAssertFalse(acceptedLate)
        XCTAssertEqual(feed.observation().published, 3); XCTAssertEqual(feed.observation().terminals, 1)
        try await fake.end(); await settled(fake)
    }

    func testAutomaticLanguageInitiallyUnknownThenPinnedAcrossRequestsAndMixedTextPreserved() async throws {
        let session = try STTTestFixture.session(mode: .automatic)
        let fake = try makeFake(.init(requests: [[
            .init(after: 0, kind: .partial, text: "처음"),
            .init(after: 1, kind: .final, text: "한국어와 English", detectedLanguage: LanguageCode("ko"))
        ], STTTestFixture.final("detected stays"), [
            .init(after: 0, kind: .final, text: "illegal change", detectedLanguage: LanguageCode("en"))
        ]]))
        try await STTTestFixture.ready(fake, session: session)
        let first = try await fake.infer(STTTestFixture.request(session: session))
        XCTAssertNil(first.observation().latest?.detectedLanguage)
        try await fake.advance(by: 1)
        let events = try await STTTestFixture.collect(first)
        XCTAssertEqual(events.map(\.kind), [.partial, .final])
        XCTAssertEqual(events.last?.detectedLanguage?.rawValue, "ko")
        XCTAssertEqual(events.last?.segments.first?.text, "한국어와 English")
        let second = try await fake.infer(STTTestFixture.request(1, session: session))
        XCTAssertEqual(second.observation().latest?.detectedLanguage?.rawValue, "ko")
        let third = try await fake.infer(STTTestFixture.request(2, session: session))
        XCTAssertEqual(third.observation().latest?.failure?.code, .invalidResponse)
        try await fake.end(); await settled(fake)
    }

    func testSameScriptIDsAndClockAdvancesProduceEqualEventsIncludingEqualDeadlines() async throws {
        let scenario = FakeSTTScenario(requests: [[.init(after: 5, kind: .partial, text: "one"),
                                                  .init(after: 5, kind: .final, text: "two")]])
        var runs: [[STTResponse]] = []
        for _ in 0..<2 {
            let fake = try makeFake(scenario)
            try await STTTestFixture.ready(fake)
            let feed = try await fake.infer(STTTestFixture.request())
            try await fake.advance(by: 4); XCTAssertNil(feed.observation().latest)
            try await fake.advance(by: 1)
            runs.append(try await STTTestFixture.collect(feed))
            try await fake.end(); await settled(fake)
        }
        XCTAssertEqual(runs[0], runs[1]); XCTAssertEqual(runs[0].map(\.revision), [1, 2])
        XCTAssertEqual(runs[0].map(\.kind), [.partial, .final])
    }

    func testBoundedFIFOExcludesActiveRejectsOnlyNewAndQueuedCancellationFreesSlot() async throws {
        let fake = try makeFake(.init(requests: (0..<4).map { STTTestFixture.final("script \($0)", at: 10) }), capacity: 2)
        try await STTTestFixture.ready(fake)
        let first = try await fake.infer(STTTestFixture.request(0))
        let second = try await fake.infer(STTTestFixture.request(1))
        let third = try await fake.infer(STTTestFixture.request(2))
        let full = await fake.snapshot(); XCTAssertEqual(full.activeSequence, 0); XCTAssertEqual(full.queuedSequences, [1, 2])
        await expect(.backlogFull) { _ = try await fake.infer(STTTestFixture.request(3)) }
        await second.withdraw()
        XCTAssertEqual(second.observation().latest?.kind, .cancelled)
        let fourth = try await fake.infer(STTTestFixture.request(3))
        try await fake.advance(by: 10)
        XCTAssertEqual(first.observation().latest?.segments.first?.text, "script 0")
        XCTAssertNil(third.observation().latest); XCTAssertNil(fourth.observation().latest)
        let middle = await fake.snapshot(); XCTAssertEqual(middle.activeSequence, 2); XCTAssertEqual(middle.queuedSequences, [3])
        try await fake.advance(by: 9); XCTAssertNil(third.observation().latest)
        try await fake.advance(by: 1)
        XCTAssertEqual(third.observation().latest?.segments.first?.text, "script 2")
        XCTAssertEqual(third.observation().latest?.context.sequence, 2)
        XCTAssertNil(fourth.observation().latest)
        try await fake.advance(by: 10)
        XCTAssertEqual(fourth.observation().latest?.segments.first?.text, "script 3")
        XCTAssertEqual(fourth.observation().latest?.context.sequence, 3)
        try await fake.end(); await settled(fake)
        XCTAssertEqual(first.observation().terminals, 1); XCTAssertEqual(second.observation().terminals, 1)
        XCTAssertEqual(third.observation().terminals, 1); XCTAssertEqual(fourth.observation().terminals, 1)
    }

    func testEndDrainsHeldWorkRejectsAdmissionsAndDuplicateEndJoins() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final("A", at: 10), STTTestFixture.final("B", at: 10)]))
        try await STTTestFixture.ready(fake)
        let first = try await fake.infer(STTTestFixture.request())
        let second = try await fake.infer(STTTestFixture.request(1))
        let ending = Task { try await fake.end() }
        await fake.waitUntil(.phase(.draining))
        let duplicate = Task { try await fake.end() }
        await fake.waitUntil(.settlementWaiters(2))
        await expect(.invalidLifecycle) { _ = try await fake.infer(STTTestFixture.request(2)) }
        await expect(.busy) { try await fake.start(STTTestFixture.session(2)) }
        try await fake.advance(by: 10)
        let draining = await fake.snapshot(); XCTAssertEqual(draining.phase, .draining)
        XCTAssertEqual(first.observation().latest?.kind, .final); XCTAssertNil(second.observation().latest)
        try await fake.advance(by: 10); try await ending.value; try await duplicate.value
        await settled(fake)
        XCTAssertEqual(second.observation().latest?.kind, .final)
    }

    func testSessionCancellationAndUnloadJoinCleanupBeforeNewAdmission() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final(at: 20), STTTestFixture.final(at: 20), STTTestFixture.final()], cleanupDelay: 10))
        try await STTTestFixture.ready(fake)
        let first = try await fake.infer(STTTestFixture.request())
        let second = try await fake.infer(STTTestFixture.request(1))
        let cancelling = Task { try await fake.cancel() }
        await fake.waitUntil(.phase(.cancelling))
        XCTAssertNil(first.observation().latest); XCTAssertEqual(second.observation().latest?.kind, .cancelled)
        let duplicate = Task { try await fake.cancel() }
        await fake.waitUntil(.settlementWaiters(2))
        await expect(.busy) { try await fake.start(STTTestFixture.session(2)) }
        await expect(.busy) { try await fake.load(STTTestFixture.model("r2")) }
        let unloading = Task { await fake.unload() }
        await fake.waitUntil(.phase(.unloading))
        let duplicateUnload = Task { await fake.unload() }
        await fake.waitUntil(.settlementWaiters(4))
        try await fake.advance(by: 9)
        let held = await fake.snapshot(); XCTAssertEqual(held.phase, .unloading); XCTAssertNotNil(held.model)
        try await fake.advance(by: 1)
        try await cancelling.value; try await duplicate.value; await unloading.value; await duplicateUnload.value
        await settled(fake, phase: .unloaded)
        XCTAssertEqual(first.observation().latest?.kind, .cancelled)
        XCTAssertEqual(first.observation().terminals, 1); XCTAssertEqual(second.observation().terminals, 1)
        try await STTTestFixture.ready(fake, session: STTTestFixture.session(2))
        let fresh = try await fake.infer(STTTestFixture.request(session: STTTestFixture.session(2)))
        XCTAssertEqual(fresh.observation().latest?.kind, .final)
        try await fake.end(); await settled(fake)
    }

    func testActiveWithdrawalWaitsForCleanupThenOtherQueuedRequestContinues() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final("cancel me", at: 20), STTTestFixture.final("keep me", at: 5)], cleanupDelay: 10))
        try await STTTestFixture.ready(fake)
        let first = try await fake.infer(STTTestFixture.request())
        let second = try await fake.infer(STTTestFixture.request(1))
        let withdraw = Task { await first.withdraw() }
        await fake.waitUntil(.cancellingRequest(0))
        try await fake.advance(by: 9); XCTAssertNil(first.observation().latest); XCTAssertNil(second.observation().latest)
        try await fake.advance(by: 1); await withdraw.value
        XCTAssertEqual(first.observation().latest?.kind, .cancelled)
        try await fake.advance(by: 5)
        XCTAssertEqual(second.observation().latest?.segments.first?.text, "keep me")
        await first.withdraw() // Documented terminal no-op, cannot touch the next request.
        XCTAssertEqual(first.observation().terminals, 1)
        try await fake.end(); await settled(fake)
    }

    func testConsumerTaskCancellationWithdrawsOnlyItsRequestAndSingleConsumerIsEnforced() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final(at: 20), STTTestFixture.final("keep", at: 1)], cleanupDelay: 5))
        try await STTTestFixture.ready(fake)
        let first = try await fake.infer(STTTestFixture.request())
        let second = try await fake.infer(STTTestFixture.request(1))
        let stream = try first.events()
        XCTAssertThrowsError(try first.events()) { XCTAssertEqual($0 as? STTEngineError, STTEngineError(.consumerAlreadyClaimed)) }
        let consumer = Task { for await _ in stream {} }
        consumer.cancel(); await consumer.value
        await fake.waitUntil(.cancellingRequest(0))
        try await fake.advance(by: 5)
        XCTAssertEqual(first.observation().latest?.kind, .cancelled)
        try await fake.advance(by: 1)
        XCTAssertEqual(second.observation().latest?.kind, .final)
        XCTAssertEqual(second.observation().latest?.segments.first?.text, "keep")
        try await fake.end(); await settled(fake)
    }

    func testCallerCancellationDuringLoadAndCleanupKeepsAdmissionClosedUntilSettlement() async throws {
        let fake = try makeFake(.init(loads: [.init(delay: 20)], cleanupDelay: 10))
        let loading = Task { try await fake.load(STTTestFixture.model()) }
        await fake.waitUntil(.phase(.loading)); loading.cancel()
        await fake.waitUntil(.phase(.cancelling))
        await expect(.busy) { try await fake.load(STTTestFixture.model()) }
        let unloading = Task { await fake.unload() }
        await fake.waitUntil(.phase(.unloading)); unloading.cancel()
        try await fake.advance(by: 9)
        let held = await fake.snapshot(); XCTAssertEqual(held.phase, .unloading)
        try await fake.advance(by: 1)
        await expect(.cancelled) { try await loading.value }
        await unloading.value; await settled(fake, phase: .unloaded)
        try await STTTestFixture.ready(fake)
        try await fake.end(); await settled(fake)
    }

    func testCancellationDuringStartRetriesAndFirstPreparationFailureSurvivesUnload() async throws {
        let fake = try makeFake(.init(loads: [.init(delay: 20, failure: STTEngineError(.loadFailed))],
                                                starts: [.init(delay: 20)], cleanupDelay: 10))
        let loading = Task { try await fake.load(STTTestFixture.model()) }
        await fake.waitUntil(.phase(.loading))
        let unload = Task { await fake.unload() }
        await fake.waitUntil(.phase(.unloading)); try await fake.advance(by: 10)
        await expect(.loadFailed) { try await loading.value }; await unload.value
        await settled(fake, phase: .unloaded)
        try await fake.load(STTTestFixture.model())
        let starting = Task { try await fake.start(STTTestFixture.session()) }
        await fake.waitUntil(.phase(.starting)); starting.cancel()
        await fake.waitUntil(.phase(.cancelling)); try await fake.advance(by: 10)
        await expect(.cancelled) { try await starting.value }; await settled(fake)
        try await fake.start(STTTestFixture.session())
        try await fake.end(); await settled(fake)
    }

    func testStaleCompletionAfterCancellationAndNewModelCannotPublishOrClearNewOwnership() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final("old", at: 20), STTTestFixture.final("new", at: 20)], cleanupDelay: 5))
        try await STTTestFixture.ready(fake)
        let old = try await fake.infer(STTTestFixture.request())
        let oldLeaseValue = await fake.callbackLease(); let oldLease = try XCTUnwrap(oldLeaseValue)
        let oldCompletion = try STTResponse(context: STTTestFixture.request().context, revision: 1, kind: .final)
        let unload = Task { await fake.unload() }; await fake.waitUntil(.phase(.unloading))
        try await fake.advance(by: 5); await unload.value
        let session = try STTTestFixture.session(2, model: STTTestFixture.model("r2"))
        try await STTTestFixture.ready(fake, session: session)
        let fresh = try await fake.infer(STTTestFixture.request(session: session))
        let before = await fake.snapshot()
        let accepted = await fake.deliver(oldCompletion, lease: oldLease)
        XCTAssertFalse(accepted)
        let after = await fake.snapshot(); XCTAssertEqual(before, after)
        XCTAssertNil(fresh.observation().latest); XCTAssertEqual(old.observation().latest?.kind, .cancelled)
        try await fake.advance(by: 20)
        XCTAssertEqual(fresh.observation().latest?.segments.first?.text, "new")
        XCTAssertEqual(fresh.observation().latest?.context.session, session)
        XCTAssertEqual(old.observation().terminals, 1)
        let acceptedAgain = await fake.deliver(oldCompletion, lease: oldLease); XCTAssertFalse(acceptedAgain)
        try await fake.end(); await settled(fake)
    }

    func testOldGenerationIsRejectedEvenWhenAllSerializedIdentitiesAreReused() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final(at: 10), STTTestFixture.final("retry", at: 10)]))
        try await STTTestFixture.ready(fake)
        let request = try STTTestFixture.request()
        let old = try await fake.infer(request)
        let captured = await fake.callbackLease(); let lease = try XCTUnwrap(captured)
        try await fake.cancel()
        try await fake.start(request.context.session)
        let fresh = try await fake.infer(request)
        let response = try STTResponse(context: request.context, revision: 1, kind: .final)
        let rejected = await fake.deliver(response, lease: lease); XCTAssertFalse(rejected)
        XCTAssertNil(fresh.observation().latest)
        try await fake.advance(by: 10)
        XCTAssertEqual(fresh.observation().latest?.segments.first?.text, "retry")
        XCTAssertEqual(old.observation().latest?.kind, .cancelled)
        try await fake.end(); await settled(fake)
    }

    func testMalformedInputAndInvalidCallbackCannotChangeActiveWorkOrConsumeCapacity() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final("valid", at: 10)]))
        try await STTTestFixture.ready(fake)
        let feed = try await fake.infer(STTTestFixture.request())
        let before = await fake.snapshot()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(STTTestFixture.request(1))) as! [String: Any]
        var audio = json["audio"] as! [String: Any]; audio["frameCount"] = Int.max; json["audio"] = audio
        XCTAssertThrowsError(try JSONDecoder().decode(STTInferenceRequest.self, from: JSONSerialization.data(withJSONObject: json)))
        let captured = await fake.callbackLease(); let lease = try XCTUnwrap(captured)
        let jumped = try STTResponse(context: STTTestFixture.request().context, revision: 5, kind: .partial)
        let accepted = await fake.deliver(jumped, lease: lease); XCTAssertFalse(accepted)
        let after = await fake.snapshot(); XCTAssertEqual(before, after); XCTAssertNil(feed.observation().latest)
        await expect(.invalidInput) { _ = try await fake.infer(STTTestFixture.request()) }
        try await fake.advance(by: 10)
        XCTAssertEqual(feed.observation().latest?.segments.first?.text, "valid")
        try await fake.end(); await settled(fake)
    }

    func testCancellationVersusFinalAndFailureKeepsExactlyOneTerminal() async throws {
        for failureWins in [false, true] {
            let script: [FakeSTTStep] = failureWins
                ? [.init(after: 10, kind: .failed, failure: STTEngineError(.inferenceFailed))]
                : STTTestFixture.final(at: 10)
            for cancellationWins in [false, true] {
                let fake = try makeFake(.init(requests: [script], cleanupDelay: 5))
                try await STTTestFixture.ready(fake)
                let feed = try await fake.infer(STTTestFixture.request())
                if cancellationWins {
                    let withdrawal = Task { await feed.withdraw() }
                    await fake.waitUntil(.cancellingRequest(0)); try await fake.advance(by: 10); await withdrawal.value
                } else {
                    try await fake.advance(by: 10); await feed.withdraw()
                }
                let events = try await STTTestFixture.collect(feed)
                XCTAssertEqual(events.count, 1)
                XCTAssertEqual(events[0].kind, cancellationWins ? .cancelled : failureWins ? .failed : .final)
                XCTAssertEqual(events[0].failure?.code, cancellationWins ? .cancelled : failureWins ? .inferenceFailed : nil)
                XCTAssertEqual(feed.observation().terminals, 1)
                try await fake.end(); await settled(fake)
            }
        }
    }

    func testEagerLateSubscriberAndBoundedPartialRetentionPreserveFirstFailure() async throws {
        let partials = (0..<200).map { FakeSTTStep(after: 0, kind: .partial, text: "snapshot \($0)") }
        let fake = try makeFake(.init(requests: [STTTestFixture.final("eager"),
                                                          partials + [.init(after: 0, kind: .failed, failure: STTEngineError(.inferenceFailed))]]))
        try await STTTestFixture.ready(fake)
        let eager = try await fake.infer(STTTestFixture.request())
        XCTAssertEqual(eager.observation().terminals, 1)
        let lateEvents = try await STTTestFixture.collect(eager)
        XCTAssertEqual(lateEvents.map(\.kind), [.final]); XCTAssertEqual(lateEvents[0].segments.first?.text, "eager")
        let failed = try await fake.infer(STTTestFixture.request(1))
        await failed.withdraw()
        let events = try await STTTestFixture.collect(failed)
        XCTAssertEqual(events.count, 2); XCTAssertEqual(events[0].segments.first?.text, "snapshot 199")
        XCTAssertEqual(events[1].failure?.code, .inferenceFailed)
        XCTAssertEqual(events[1].revision, 201); XCTAssertEqual(failed.observation().terminals, 1)
        try await fake.end(); await settled(fake)
    }

    func testDisabledPartialsStillDetectLanguageAndDeliverTheFinalSnapshot() async throws {
        let model = try STTTestFixture.model(options: STTInferenceOptions(partialResults: false))
        let session = try STTTestFixture.session(model: model, mode: .automatic)
        let fake = try makeFake(.init(requests: [[
            .init(after: 5, kind: .partial, text: "hidden", detectedLanguage: LanguageCode("ko")),
            .init(after: 10, kind: .final, text: "한국어와 Swift")
        ]]))
        let engine: any STTEngine = fake
        try await engine.load(model); try await engine.start(session)
        let feed = try await engine.infer(STTTestFixture.request(session: session))
        try await fake.advance(by: 5)
        XCTAssertNil(feed.observation().latest)
        try await fake.advance(by: 4); XCTAssertNil(feed.observation().latest)
        try await fake.advance(by: 1)
        let events = try await STTTestFixture.collect(feed)
        XCTAssertEqual(events.map(\.kind), [.final])
        XCTAssertEqual(events.map(\.revision), [1])
        XCTAssertEqual(events.first?.segments.first?.text, "한국어와 Swift")
        XCTAssertEqual(events.first?.detectedLanguage?.rawValue, "ko")
        XCTAssertEqual(events.first?.context.session, session)
        XCTAssertEqual(feed.observation().terminals, 1)
        try await engine.end(); await settled(fake)
    }

    func testLogicalClockNearInt64LimitStillSettlesCancellationAndUnload() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final(at: 60_000)], cleanupDelay: 60_000))
        try await fake.advance(by: Int64.max - 120_000)
        try await STTTestFixture.ready(fake)
        let feed = try await fake.infer(STTTestFixture.request())
        // The old clock guard rejected this advance although the accepted work was due later.
        try await fake.advance(by: 59_999)
        let withdrawal = Task { await feed.withdraw() }
        await fake.waitUntil(.cancellingRequest(0))
        try await fake.advance(by: 59_999); XCTAssertNil(feed.observation().latest)
        try await fake.advance(by: 1); await withdrawal.value
        XCTAssertEqual(feed.observation().latest?.kind, .cancelled)
        let unloading = Task { await fake.unload() }
        await fake.waitUntil(.phase(.unloading))
        try await fake.advance(by: 1); await unloading.value
        await settled(fake, phase: .unloaded)
        let before = await fake.snapshot(); XCTAssertEqual(before.logicalTime, Int64.max)
        await expect(.invalidInput) { try await fake.advance(by: 1) }
        let after = await fake.snapshot(); XCTAssertEqual(before, after)
    }


    func testClockBudgetRejectionPreservesActiveRequestSequenceAndScript() async throws {
        let fake = try makeFake(.init(requests: [STTTestFixture.final("first", at: 60), STTTestFixture.final("second", at: 60)], cleanupDelay: 10))
        try await fake.advance(by: Int64.max - 100)
        try await STTTestFixture.ready(fake)
        let first = try await fake.infer(STTTestFixture.request())
        let before = await fake.snapshot()
        await expect(.invalidInput) { _ = try await fake.infer(STTTestFixture.request(1)) }
        let rejected = await fake.snapshot(); XCTAssertEqual(before, rejected); XCTAssertNil(first.observation().latest)
        // An acknowledged early completion frees reserved time without moving the clock.
        let captured = await fake.callbackLease(); let lease = try XCTUnwrap(captured)
        let response = try STTResponse(context: STTTestFixture.request().context, revision: 1, kind: .final)
        let delivered = await fake.deliver(response, lease: lease); XCTAssertTrue(delivered)
        let retry = try await fake.infer(STTTestFixture.request(1))
        try await fake.advance(by: 59); XCTAssertNil(retry.observation().latest)
        try await fake.advance(by: 1)
        XCTAssertEqual(retry.observation().latest?.segments.first?.text, "second")
        XCTAssertEqual(retry.observation().latest?.context.sequence, 1)
        try await fake.end(); await settled(fake)
    }

    func testClockBudgetRejectsLoadAndStartBeforeMutatingPreparation() async throws {
        let loading = try makeFake(.init(loads: [.init(delay: 20)], cleanupDelay: 10))
        try await loading.advance(by: Int64.max - 25)
        let beforeLoad = await loading.snapshot()
        await expect(.invalidInput) { try await loading.load(STTTestFixture.model()) }
        let afterLoad = await loading.snapshot(); XCTAssertEqual(beforeLoad, afterLoad)
        let starting = try makeFake(.init(starts: [.init(delay: 30)], cleanupDelay: 10))
        try await starting.advance(by: Int64.max - 35)
        try await starting.load(STTTestFixture.model())
        let beforeStart = await starting.snapshot()
        await expect(.invalidInput) { try await starting.start(STTTestFixture.session()) }
        let afterStart = await starting.snapshot(); XCTAssertEqual(beforeStart, afterStart)
    }

    func testDisabledPartialsStillValidateLanguageAndPreserveTheFirstFailure() async throws {
        let model = try STTTestFixture.model(options: STTInferenceOptions(partialResults: false))
        for language in ["fr", "en"] {
            let fake = try makeFake(.init(requests: [[
                .init(after: 5, kind: .partial, text: "hidden", detectedLanguage: LanguageCode(language)),
                .init(after: 10, kind: .final, text: "must not replace failure")
            ]]))
            let session = try STTTestFixture.session(model: model)
            try await STTTestFixture.ready(fake, session: session)
            let feed = try await fake.infer(STTTestFixture.request(session: session))
            try await fake.advance(by: 5)
            await feed.withdraw(); try await fake.advance(by: 5)
            let events = try await STTTestFixture.collect(feed)
            XCTAssertEqual(events.map(\.kind), [.failed])
            XCTAssertEqual(events.first?.failure?.code, .invalidResponse)
            XCTAssertEqual(feed.observation().published, 1); XCTAssertEqual(feed.observation().terminals, 1)
            try await fake.end(); await settled(fake)
        }
    }

    func testUnsupportedLanguageCapabilityDoesNotPinTheSessionOrChangePreparation() async throws {
        let caps = try STTCapabilities(inputFormats: [STTInputFormat()], languageModes: LanguageMode.allCases,
                                       languages: [LanguageCode("en")], partialResults: true, timestamps: true)
        let fake = try makeFake(.init(requests: [[.init(after: 0, kind: .final, text: "unsupported", detectedLanguage: LanguageCode("ko"))],
                                                 [.init(after: 0, kind: .final, text: "English result", detectedLanguage: LanguageCode("en"))]]), capabilities: caps)
        let engine: any STTEngine = fake
        try await engine.load(STTTestFixture.model())
        let before = await fake.snapshot()
        await expect(.unsupportedCapability) { try await engine.start(STTTestFixture.session()) }
        let after = await fake.snapshot(); XCTAssertEqual(before, after)
        let session = try STTTestFixture.session(mode: .automatic)
        try await engine.start(session)
        let failed = try await engine.infer(STTTestFixture.request(session: session))
        XCTAssertEqual(failed.observation().latest?.failure?.code, .invalidResponse)
        let success = try await engine.infer(STTTestFixture.request(1, session: session))
        XCTAssertEqual(success.observation().latest?.kind, .final)
        XCTAssertEqual(success.observation().latest?.detectedLanguage?.rawValue, "en")
        XCTAssertEqual(success.observation().latest?.segments.first?.text, "English result")
        try await engine.end(); await settled(fake)
    }

}
