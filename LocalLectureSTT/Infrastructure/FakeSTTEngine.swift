import Foundation

/// Millisecond logical delays are processing-relative. Equal times preserve array order.
struct FakeSTTStep: Sendable, Equatable {
    let after: Int64
    let kind: STTResponseKind
    let text: String
    let detectedLanguage: LanguageCode?
    let failure: STTEngineError?

    init(after: Int64, kind: STTResponseKind, text: String = "", detectedLanguage: LanguageCode? = nil,
         failure: STTEngineError? = nil) {
        self.after = after
        self.kind = kind
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.failure = failure
    }
}

struct FakeSTTPreparation: Sendable {
    var delay: Int64 = 0
    var failure: STTEngineError? = nil
}

struct FakeSTTScenario: Sendable {
    var loads: [FakeSTTPreparation] = []
    var starts: [FakeSTTPreparation] = []
    var requests: [[FakeSTTStep]] = []
    var cleanupDelay: Int64 = 0
}

enum FakeSTTPhase: String, Sendable { case unloaded, ready, loading, starting, running, draining, cancelling, unloading }
struct FakeSTTSnapshot: Sendable, Equatable {
    let phase: FakeSTTPhase
    let model: STTModelConfiguration?
    let session: STTSessionConfiguration?
    let activeSequence: Int64?
    let queuedSequences: [Int64]
    let logicalTime: Int64
    let ownedContinuations: Int
}

enum FakeSTTCondition: Sendable {
    case phase(FakeSTTPhase)
    case active(Int64)
    case queued(Int)
    case cancellingRequest(Int64)
    case settlementWaiters(Int)
}

/// A callback lease, deliberately not a serialized payload. Old generations cannot publish.
struct FakeSTTCallbackLease: Sendable, Equatable {
    fileprivate let generation: UInt64
    fileprivate let context: STTRequestContext
}

/// One logical FIFO worker, driven synchronously by advance(). No timers, I/O or implicit work.
actor FakeSTTEngine: STTEngine {
    nonisolated let capabilities: STTCapabilities
    private let engine: EngineIdentity
    private let pendingCapacity: Int
    private var scenario: FakeSTTScenario
    private var phase: FakeSTTPhase = .unloaded
    private var model: STTModelConfiguration?
    private var session: STTSessionConfiguration?
    private var generation: UInt64 = 0
    private var now: Int64 = 0
    private var lastSequence: Int64 = -1
    private var detectedLanguage: LanguageCode?

    private struct Work {
        let request: STTInferenceRequest
        let lease: FakeSTTCallbackLease
        let feed: STTEventFeed
        let steps: [FakeSTTStep]
        var origin: Int64 = 0
        var stepIndex = 0
        var revision: Int64 = 0
        var cancellationDue: Int64?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private var active: Work?
    private var queue: [Work] = []
    private enum PreparationKind { case load(STTModelConfiguration), start(STTSessionConfiguration) }
    private struct Preparation {
        let token: UInt64
        let kind: PreparationKind
        var due: Int64
        var cause: STTEngineError?
        var cancelled = false
        let continuation: CheckedContinuation<Void, Error>
    }
    private var preparation: Preparation?
    private var settlementDue: Int64?
    private var unloadRequested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var probes: [(FakeSTTCondition, CheckedContinuation<Void, Never>)] = []

    init(engine: EngineIdentity, capabilities: STTCapabilities, pendingCapacity: Int = 2,
         scenario: FakeSTTScenario = .init()) throws {
        guard (1...16).contains(pendingCapacity), scenario.cleanupDelay >= 0,
              scenario.cleanupDelay <= 60_000,
              (scenario.loads + scenario.starts).allSatisfy({ (0...60_000).contains($0.delay) }),
              scenario.requests.count <= 1_024 else { throw STTEngineError(.invalidConfiguration) }
        for steps in scenario.requests {
            guard !steps.isEmpty, steps.count <= 256, steps.last?.kind != .partial else {
                throw STTEngineError(.invalidConfiguration)
            }
            var last: Int64 = 0
            for (index, step) in steps.enumerated() {
                guard step.after >= last, step.after <= 60_000, step.text.utf8.count <= 16_384,
                      index == steps.count - 1 || step.kind == .partial else { throw STTEngineError(.invalidConfiguration) }
                last = step.after
            }
        }
        self.engine = engine
        self.capabilities = capabilities
        self.pendingCapacity = pendingCapacity
        self.scenario = scenario
    }

    func snapshot() -> FakeSTTSnapshot {
        .init(phase: phase, model: model, session: session, activeSequence: active?.request.context.sequence,
              queuedSequences: queue.map { $0.request.context.sequence }, logicalTime: now,
              ownedContinuations: waiters.count + (preparation == nil ? 0 : 1) + (active?.waiters.count ?? 0))
    }

    /// Test barrier: acknowledges registration, without sleeping/yield polling.
    func waitUntil(_ condition: FakeSTTCondition) async {
        if matches(condition) { return }
        await withCheckedContinuation { probes.append((condition, $0)) }
    }

    private func matches(_ condition: FakeSTTCondition) -> Bool {
        switch condition {
        case .phase(let value): phase == value
        case .active(let sequence): active?.request.context.sequence == sequence
        case .queued(let count): queue.count == count
        case .settlementWaiters(let count): waiters.count == count
        case .cancellingRequest(let sequence): active?.request.context.sequence == sequence && active?.cancellationDue != nil
        }
    }

    private func notify() {
        let ready = probes.filter { matches($0.0) }
        probes.removeAll { matches($0.0) }
        ready.forEach { $0.1.resume() }
    }

    func load(_ configuration: STTModelConfiguration) async throws {
        guard phase == .unloaded || phase == .ready else { throw STTEngineError(.busy) }
        guard configuration.engine == engine else { throw STTEngineError(.unsupportedModel) }
        try validate(options: configuration.options)
        try Task.checkCancellationAsSTT()
        let step = scenario.loads.first ?? FakeSTTPreparation()
        try requireClockRoom(for: [step.delay, scenario.cleanupDelay])
        generation += 1
        let token = generation
        if !scenario.loads.isEmpty { scenario.loads.removeFirst() }
        phase = .loading
        // Replacing an idle model unloads the previous descriptor; failure settles unloaded.
        model = nil
        try await prepare(.load(configuration), step: step, token: token)
    }

    func start(_ configuration: STTSessionConfiguration) async throws {
        guard phase == .ready else { throw STTEngineError(phase == .unloaded ? .invalidLifecycle : .busy) }
        guard configuration.model == model else { throw STTEngineError(.invalidConfiguration) }
        guard capabilities.languageModes.contains(configuration.languageMode) else { throw STTEngineError(.unsupportedCapability) }
        if configuration.languageMode != .automatic {
            let code = configuration.languageMode == .korean ? "ko" : "en"
            guard capabilities.languages.contains(where: { $0.rawValue == code }) else { throw STTEngineError(.unsupportedCapability) }
        }
        try Task.checkCancellationAsSTT()
        let step = scenario.starts.first ?? FakeSTTPreparation()
        try requireClockRoom(for: [step.delay, scenario.cleanupDelay])
        generation += 1
        let token = generation
        if !scenario.starts.isEmpty { scenario.starts.removeFirst() }
        phase = .starting
        try await prepare(.start(configuration), step: step, token: token)
    }

    private func prepare(_ kind: PreparationKind, step: FakeSTTPreparation, token: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparation = .init(token: token, kind: kind, due: deadline(after: step.delay, from: now), cause: step.failure, continuation: continuation)
                drive()
            }
        } onCancel: { Task { await self.cancelPreparation(token) } }
    }

    private func cancelPreparation(_ token: UInt64) {
        guard var owned = preparation, owned.token == token, !owned.cancelled else { return }
        owned.cancelled = true
        // An operational cause selected earlier survives later cancellation/cleanup.
        if owned.cause == nil { owned.cause = STTEngineError(.cancelled) }
        owned.due = deadline(after: scenario.cleanupDelay, from: now)
        preparation = owned
        phase = unloadRequested ? .unloading : .cancelling
        drive()
    }

    func infer(_ request: STTInferenceRequest) throws -> STTEventFeed {
        guard phase == .running, let session else { throw STTEngineError(.invalidLifecycle) }
        guard request.context.session == session else { throw STTEngineError(.sessionMismatch) }
        guard request.context.sequence > lastSequence else { throw STTEngineError(.invalidInput) }
        guard capabilities.inputFormats.contains(request.audio.format) else { throw STTEngineError(.unsupportedCapability) }
        guard active == nil || queue.count < pendingCapacity else { throw STTEngineError(.backlogFull) }
        try Task.checkCancellationAsSTT()
        guard !scenario.requests.isEmpty else { throw STTEngineError(.inferenceFailed) }
        let steps = scenario.requests[0]
        // Reserve all accepted FIFO delays plus possible active cleanup, before mutating admission.
        var intervals: [Int64] = []
        if let active {
            if let due = active.cancellationDue { intervals.append(max(0, due - now)) }
            else {
                intervals += [max(0, deadline(after: active.steps.last!.after, from: active.origin) - now), scenario.cleanupDelay]
            }
        }
        for work in queue { intervals += [work.steps.last!.after, scenario.cleanupDelay] }
        intervals += [steps.last!.after, scenario.cleanupDelay]
        try requireClockRoom(for: intervals)
        scenario.requests.removeFirst()
        let lease = FakeSTTCallbackLease(generation: generation, context: request.context)
        let feed = STTEventFeed { [weak self] in await self?.cancelRequest(lease) }
        let work = Work(request: request, lease: lease, feed: feed, steps: steps)
        lastSequence = request.context.sequence
        // Only the driver activates work, always from the accepted FIFO head.
        queue.append(work)
        drive()
        return feed
    }

    func end() async throws {
        guard session != nil, [.running, .draining, .cancelling, .unloading].contains(phase) else {
            throw STTEngineError(.invalidLifecycle)
        }
        if phase == .running { phase = .draining }
        await joinSettlement()
    }

    func cancel() async throws {
        guard session != nil else { throw STTEngineError(.invalidLifecycle) }
        beginCancellation(unload: false)
        await joinSettlement()
    }

    func unload() async {
        if phase == .unloaded { return }
        unloadRequested = true
        if let preparation {
            cancelPreparation(preparation.token)
            phase = .unloading
        } else {
            beginCancellation(unload: true)
        }
        await joinSettlement()
    }

    private func joinSettlement() async {
        drive()
        if phase == .ready || phase == .unloaded { return }
        // Cancellation of a control caller never abandons engine-owned settlement.
        await withCheckedContinuation { waiters.append($0); notify() }
    }

    private func beginCancellation(unload: Bool) {
        if unload { unloadRequested = true }
        phase = unloadRequested ? .unloading : .cancelling
        let pending = queue
        queue.removeAll()
        for work in pending { publishCancellation(work) }
        if active != nil, active?.cancellationDue == nil { active?.cancellationDue = deadline(after: scenario.cleanupDelay, from: now) }
        if settlementDue == nil { settlementDue = deadline(after: scenario.cleanupDelay, from: now) }
        drive()
    }

    private func cancelRequest(_ lease: FakeSTTCallbackLease) async {
        if let index = queue.firstIndex(where: { $0.lease == lease }) {
            publishCancellation(queue.remove(at: index))
        } else if active?.lease == lease, active?.cancellationDue == nil {
            active?.cancellationDue = deadline(after: scenario.cleanupDelay, from: now)
        }
        drive()
        if active?.lease == lease {
            await withCheckedContinuation { active?.waiters.append($0); notify() }
        }
    }

    private func publishCancellation(_ work: Work) {
        // Revisions are small and internally bounded by the script limit.
        let response = try! STTResponse(context: work.request.context, revision: work.revision + 1,
                                        kind: .cancelled, failure: STTEngineError(.cancelled))
        work.feed.publish(response)
        work.waiters.forEach { $0.resume() }
    }

    /// Simulates an adapter callback; stale callbacks and invalid revision/finality are rejected.
    @discardableResult
    func deliver(_ response: STTResponse, lease: FakeSTTCallbackLease) -> Bool {
        guard accept(response, lease: lease) else { return false }
        // External callbacks acknowledge FIFO promotion and control settlement too.
        drive()
        return true
    }

    /// Publication alone never re-enters the driver while it holds a local Work copy.
    private func accept(_ response: STTResponse, lease: FakeSTTCallbackLease) -> Bool {
        guard var work = active, work.lease == lease, lease.generation == generation,
              work.cancellationDue == nil, response.context == work.request.context,
              response.revision == work.revision + 1, response.revision <= 257,
              response.revision < 257 || response.isTerminal else { return false }
        guard acceptDetectedLanguage(response.detectedLanguage, for: response.context.session) else { return false }
        work.revision = response.revision
        active = work
        work.feed.publish(response)
        if response.isTerminal { active = nil; work.waiters.forEach { $0.resume() } }
        return true
    }

    /// Narrow fault seam: captures ownership only, never exposes worker/continuation objects.
    func callbackLease() -> FakeSTTCallbackLease? { active?.lease }

    /// All due events are observable before returning. No clock sleeps or scheduler luck.
    func advance(by milliseconds: Int64) throws {
        let target = now.addingReportingOverflow(milliseconds)
        guard milliseconds >= 0, !target.overflow else {
            throw STTEngineError(.invalidInput)
        }
        drive()
        while let deadline = nextDeadline(), deadline <= target.partialValue {
            now = deadline
            drive()
        }
        now = target.partialValue
        drive()
    }

    private func nextDeadline() -> Int64? {
        var values: [Int64] = []
        if let preparation { values.append(preparation.due) }
        if let active {
            if let due = active.cancellationDue { values.append(due) }
            else { values.append(deadline(after: active.steps[active.stepIndex].after, from: active.origin)) }
        }
        if active == nil, let settlementDue { values.append(settlementDue) }
        return values.min()
    }

    private func drive() {
        if let owned = preparation, owned.due <= now {
            preparation = nil
            if let cause = owned.cause {
                switch owned.kind { case .load: model = nil; case .start: break }
                phase = model == nil ? .unloaded : .ready
                owned.continuation.resume(throwing: cause)
            } else {
                switch owned.kind {
                case .load(let value): model = value; phase = .ready
                case .start(let value):
                    session = value; lastSequence = -1; detectedLanguage = nil; phase = .running
                }
                owned.continuation.resume()
            }
            if unloadRequested { model = nil; session = nil; phase = .unloaded; unloadRequested = false }
        }
        while preparation == nil {
            if active == nil, !queue.isEmpty {
                active = queue.removeFirst()
                active?.origin = now
            }
            guard var work = active else { break }
            if let due = work.cancellationDue {
                guard due <= now else { break }
                publishCancellation(work)
                active = nil
                continue
            }
            let step = work.steps[work.stepIndex]
            guard deadline(after: step.after, from: work.origin) <= now else { break }
            work.stepIndex += 1
            active = work
            do {
                if step.kind == .partial, !work.request.context.session.model.options.partialResults {
                    // The script's logical detection still occurs; only its partial publication is disabled.
                    guard acceptDetectedLanguage(step.detectedLanguage, for: work.request.context.session) else {
                        throw STTEngineError(.invalidResponse)
                    }
                    continue
                }
                let segments: [STTHypothesisSegment] = step.kind == .partial || step.kind == .final
                    ? [try STTHypothesisSegment(start: work.request.context.mediaStart,
                                               end: work.request.context.mediaEnd, text: step.text)] : []
                let response = try STTResponse(context: work.request.context, revision: work.revision + 1,
                                               kind: step.kind, segments: segments,
                                               detectedLanguage: step.detectedLanguage ?? detectedLanguage, failure: step.failure)
                guard accept(response, lease: work.lease) else { throw STTEngineError(.invalidResponse) }
            } catch {
                let response = try! STTResponse(context: work.request.context, revision: work.revision + 1,
                                                kind: .failed, failure: STTEngineError(.invalidResponse))
                _ = accept(response, lease: work.lease)
            }
        }
        if preparation == nil, active == nil, queue.isEmpty,
           [.draining, .cancelling, .unloading].contains(phase), (settlementDue ?? now) <= now {
            session = nil
            detectedLanguage = nil
            settlementDue = nil
            if unloadRequested { model = nil; unloadRequested = false }
            phase = model == nil ? .unloaded : .ready
        }
        if phase == .ready || phase == .unloaded {
            let joined = waiters; waiters.removeAll()
            joined.forEach { $0.resume() }
        }
        notify()
    }

    /// Bounded test-watchdog/teardown escape hatch. Uses the same cancellation and worker paths.
    /// Unmet probes are released only here so a failed assertion cannot strand test tasks.
    func releaseScenario() {
        unloadRequested = true
        if let preparation { cancelPreparation(preparation.token) }
        else { beginCancellation(unload: true) }
        try? advance(by: min(120_000, Int64.max - now))
        let abandoned = probes
        probes.removeAll()
        abandoned.forEach { $0.1.resume() }
    }

    private func acceptDetectedLanguage(_ language: LanguageCode?, for session: STTSessionConfiguration) -> Bool {
        guard let language else { return true }
        let expected: String? = switch session.languageMode {
        case .korean: "ko"
        case .english: "en"
        case .automatic: nil
        }
        guard expected == nil || language.rawValue == expected,
              capabilities.languages.contains(language), detectedLanguage == nil || detectedLanguage == language else { return false }
        detectedLanguage = language
        return true
    }

    /// New work must fit its whole FIFO horizon, including cancellation, before admission.
    private func requireClockRoom(for intervals: [Int64]) throws {
        var remaining = Int64.max - now
        for interval in intervals {
            guard interval >= 0, interval <= remaining else { throw STTEngineError(.invalidInput) }
            remaining -= interval
        }
    }

    /// Nonthrowing cleanup must remain settleable even at the finite clock's last tick.
    private func deadline(after delay: Int64, from origin: Int64) -> Int64 {
        let sum = origin.addingReportingOverflow(delay)
        return sum.overflow ? Int64.max : sum.partialValue
    }

    private func validate(options: STTInferenceOptions) throws {
        guard (!options.partialResults || capabilities.partialResults),
              (!options.timestamps || capabilities.timestamps) else { throw STTEngineError(.unsupportedCapability) }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func checkCancellationAsSTT() throws {
        if isCancelled { throw STTEngineError(.cancelled) }
    }
}
