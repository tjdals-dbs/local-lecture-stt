import Foundation

struct SpeechAudioBlock: Sendable {
    let samples: [Float]
    let startFrame: Int64
}

protocol SpeechPCMConverting: Sendable {
    func convert(_ chunk: PCMChunk, origin: Int64) async throws -> [SpeechAudioBlock]
    func drain() async throws -> [SpeechAudioBlock]
}

enum LiveSTTPhase: String, Sendable { case idle, listening, recovering, finishing, finished, cancelled, failed }

struct LiveSTTSnapshot: Sendable, Equatable {
    var phase: LiveSTTPhase = .idle
    var cleanupComplete = false
    var inputPaused = false
    var finals: [TranscriptSegment] = []
    var partial: String?
    var language: LanguageCode?
    var pendingFinals = 0
    var inputMilliseconds: Int64 = 0
    var backlogMilliseconds: Int64 = 0
    var degraded = false
    var inputDiscontinuities = 0
    var failure: STTErrorCode?
    var storageWarning: String?
    var recovery: SpeechRecoverySummary?
    var automaticRestarts = 0
    static let idle = LiveSTTSnapshot()
}

/// One owner per recording, independent of the recorder's PCM consumer.
/// At most one inference and four pending final windows hold audio. Partial
/// work has no queue: busy/degraded ticks are skipped. With a durable recovery
/// ledger, overflowing final windows are deferred to post-stop audio repair.
actor LiveSTTCoordinator {
    // Conservative UTF-8 suffix, below the selected adapter's prompt-token
    // budget even for byte-level tokens. Never forward the entire transcript.
    static let contextUTF8Limit = 96
    private let engine: any STTEngine
    private var session: STTSessionConfiguration
    private let recovery: (any SpeechRecoveryRecording)?
    private var persistedThrough: Int64 = 0
    private var consecutiveFailures = 0
    private var speechUnavailable = false
    private var inputComplete = false
    private let requestTimeout: Duration
    private var inferenceID: UUID?
    private let repository: any SessionRepository
    private let location: SessionLocation
    private let converter: any SpeechPCMConverting
    private let capacity: Int
    private let publish: @Sendable (LiveSTTSnapshot) async -> Void
    private var segmenter: UtteranceSegmenter
    private var reconciler: TranscriptReconciler
    private var snapshot = LiveSTTSnapshot()
    private var owner: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var abort: Task<Void, Never>?
    private var publication: Task<Void, Never>?
    private var publicationSequence: UInt64 = 0
    private var queue: [SpeechWindow] = []
    private var activeWindow: SpeechWindow?
    private var sequence: Int64 = 0
    private var latestFrame: Int64 = 0
    private var sealedEnd: Int64 = 0
    private var lastPartialFrame: Int64 = 0
    private var sawDegradation = false
    private var stopped = false
    private var cleaned = false

    init(engine: any STTEngine, session: STTSessionConfiguration,
         repository: any SessionRepository, location: SessionLocation,
         converter: any SpeechPCMConverting,
         detector: any VoiceActivityDetector = AdaptiveEnergyVAD(),
         maximumPendingFinals: Int = 4,
         recovery: (any SpeechRecoveryRecording)? = nil,
         requestTimeout: Duration = .seconds(60),
         publish: @escaping @Sendable (LiveSTTSnapshot) async -> Void = { _ in }) {
        self.engine = engine; self.session = session; self.repository = repository
        self.location = location; self.converter = converter
        self.recovery = recovery
        self.requestTimeout = requestTimeout
        capacity = max(1, maximumPendingFinals); self.publish = publish
        segmenter = UtteranceSegmenter(detector: detector)
        reconciler = TranscriptReconciler(session: session)
        if session.languageMode != .automatic {
            snapshot.language = try? LanguageCode(session.languageMode == .korean ? "ko" : "en")
        }
    }

    /// Engine loading is already complete. This method never awaits inference.
    func start(_ handle: CaptureHandle) {
        guard owner == nil, !stopped else { return }
        owner = Task { await self.run(handle) }
    }

    func currentSnapshot() -> LiveSTTSnapshot { snapshot }
    func waitUntilSettled() async { await owner?.value }

    func cancel() async {
        if !cleaned, !stopped {
            stopped = true
            snapshot.phase = .cancelled
            snapshot.partial = nil
            beginAbort()
        }
        await owner?.value
    }

    private func run(_ handle: CaptureHandle) async {
        do {
            if let recovery {
                do { try await recovery.initialize(session, at: location) }
                catch { snapshot.storageWarning = "recoveryLedgerWriteFailed"; throw error }
            }
            try await engine.start(session)
            try checkRunning()
            snapshot.phase = .listening
            await emit()
            var origin: Int64?
            var expectedSequence: UInt64?
            var expectedSample: Int64?
            var epoch: UInt64 = 0
            for try await input in handle.speechInputs {
                try checkRunning()
                if case let .pause(boundary) = input {
                    guard boundary.epoch >= epoch else { throw STTEngineError(.invalidInput) }
                    if boundary.epoch > epoch { try await sealPauseBoundary() }
                    epoch = boundary.epoch
                    continue
                }
                guard case let .pcm(chunk) = input, chunk.segmentEpoch >= epoch else { throw STTEngineError(.invalidInput) }
                // A bounded newest stream can drop a marker. Every resumed PCM
                // carries its epoch so old/new speech can never be joined silently.
                if chunk.segmentEpoch > epoch { try await sealPauseBoundary(); epoch = chunk.segmentEpoch }
                snapshot.inputPaused = false
                guard chunk.generation == handle.generation else { throw STTEngineError(.sessionMismatch) }
                var discontinuity = false
                if let expectedSequence, chunk.sequence != expectedSequence {
                    guard chunk.sequence > expectedSequence else { throw STTEngineError(.invalidInput) }
                    discontinuity = true
                } else if expectedSequence == nil, chunk.sequence > 0 {
                    discontinuity = true
                }
                if let expectedSample, chunk.sourceSampleTime != expectedSample { discontinuity = true }
                if discontinuity {
                    snapshot.inputDiscontinuities += 1
                    sawDegradation = true
                }
                guard chunk.sequence < UInt64.max else { throw STTEngineError(.invalidInput) }
                expectedSequence = chunk.sequence + 1
                let next = chunk.sourceSampleTime.addingReportingOverflow(Int64(chunk.frameCount))
                guard !next.overflow else { throw STTEngineError(.invalidInput) }
                expectedSample = next.partialValue
                origin = origin ?? handle.timeline.sourceOrigin() ?? chunk.sourceSampleTime
                let blocks = try await converter.convert(chunk, origin: origin!)
                try checkRunning()
                try await ingest(blocks)
                await emit()
            }
            try checkRunning()
            let tail = try await converter.drain()
            try checkRunning()
            try await ingest(tail, allowsPartial: false)
            let flushed = try segmenter.flush()
            try await observe(flushed, through: latestFrame / 16, ended: true)
            for window in flushed { try enqueue(window) }
            inputComplete = true
            if !speechUnavailable { snapshot.phase = .finishing }
            snapshot.partial = nil
            await emit()
            startWorker()
        } catch {
            if !stopped { fail(error) }
        }
        await worker?.value
        if let abort { await abort.value }
        if !stopped && !speechUnavailable {
            do { try await engine.end() }
            catch { fail(error); await abort?.value }
        }
        // All accepted callbacks and journal appends have settled before unload.
        await engine.unload()
        if !stopped && !speechUnavailable { snapshot.phase = .finished }
        snapshot.partial = nil
        queue.removeAll()
        activeWindow = nil
        if sawDegradation { await diagnostic(.sttBackpressureDegraded, code: "speech.degraded") }
        if let failure = snapshot.failure { await diagnostic(.sttError, code: "speech.\(failure.rawValue)") }
        cleaned = true
        snapshot.cleanupComplete = true
        await emit()
    }

    private func sealPauseBoundary() async throws {
        snapshot.inputPaused = true
        snapshot.partial = nil
        let tail = try await converter.drain()
        try checkRunning()
        try await ingest(tail, allowsPartial: false)
        let flushed = try segmenter.flush()
        try await observe(flushed, through: latestFrame / 16, ended: true)
        for window in flushed { try enqueue(window) }
        sealedEnd = max(sealedEnd, latestFrame)
        startWorker()
        await emit()
    }

    private func checkRunning() throws {
        guard !stopped, !Task.isCancelled else { throw STTEngineError(.cancelled) }
    }

    private func ingest(_ blocks: [SpeechAudioBlock], allowsPartial: Bool = true) async throws {
        for block in blocks {
            let end = block.startFrame.addingReportingOverflow(Int64(block.samples.count))
            guard !end.overflow, block.samples.count <= 480_000 else { throw STTEngineError(.invalidInput) }
            let missing = block.startFrame / 16 > latestFrame / 16 ? [try SpeechRecoveryRange(latestFrame / 16, block.startFrame / 16)] : []
            latestFrame = max(latestFrame, end.partialValue)
            let windows = try segmenter.append(block.samples, at: block.startFrame)
            try await observe(windows, missing: missing, through: segmenter.safeThroughFrame / 16)
            for window in windows { try enqueue(window) }
        }
        updateMetrics()
        if allowsPartial, !speechUnavailable, worker == nil, queue.isEmpty, !snapshot.degraded,
           latestFrame - lastPartialFrame >= 32_000,
           let open = try segmenter.openWindow(), open.audio.frameCount >= 32_000 {
            lastPartialFrame = latestFrame
            activeWindow = open
            worker = Task { await self.process(open); await self.drainQueue() }
        }
        startWorker()
    }

    private func enqueue(_ window: SpeechWindow) throws {
        guard !speechUnavailable else { return } // Durable pending range survives.
        if queue.count >= capacity {
            guard recovery != nil else { throw STTEngineError(.backlogFull) }
            queue.removeFirst() // Prefer current speech; the old range remains pending on disk.
            sawDegradation = true
        }
        queue.append(window)
        sealedEnd = max(sealedEnd, window.endFrame)
        // An old open-window response may no longer replace the pending final.
        snapshot.partial = nil
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty, !stopped, !speechUnavailable else { return }
        worker = Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        while !stopped, !speechUnavailable, !queue.isEmpty {
            let next = queue.removeFirst()
            activeWindow = next
            await emit()
            await process(next)
        }
        activeWindow = nil
        worker = nil
        await emit()
    }

    private func observe(_ windows: [SpeechWindow], missing: [SpeechRecoveryRange] = [],
                         through: Int64, ended: Bool = false) async throws {
        guard let recovery else { return }
        let through = max(persistedThrough, through)
        guard !windows.isEmpty || !missing.isEmpty || ended || through - persistedThrough >= 1000 else { return }
        do {
            let ranges = try windows.map { try SpeechRecoveryRange($0.mediaStart.rawValue, $0.mediaStart.rawValue + $0.audio.duration.rawValue) }
            snapshot.recovery = try await recovery.observe(windows: ranges, missing: missing, through: through, ended: ended, at: location)
            persistedThrough = through
        } catch { snapshot.storageWarning = "recoveryLedgerWriteFailed"; throw error }
    }

    private func process(_ window: SpeechWindow) async {
        guard recovery != nil else {
            do { try await inferOnce(window) } catch { if !stopped { fail(error) } }
            return
        }
        var retry = 0
        while !stopped && !speechUnavailable {
            do {
                try await inferOnce(window)
                if window.boundary != .open { consecutiveFailures = 0 }
                snapshot.phase = inputComplete ? .finishing : .listening
                await emit(); return
            } catch {
                if stopped || Task.isCancelled || speechUnavailable { return }
                let code = (error as? STTEngineError)?.code ?? .inferenceFailed
                if snapshot.storageWarning != nil { fail(error); return }
                guard [.inferenceFailed, .invalidResponse].contains(code) else {
                    speechUnavailable = true; snapshot.failure = code; snapshot.phase = .failed
                    snapshot.partial = nil; queue.removeAll(); await emit(); return
                }
                if window.boundary == .open {
                    snapshot.partial = nil; await emit(); return
                }
                snapshot.phase = .recovering; snapshot.partial = nil; await emit()
                if retry == 0 { retry += 1; continue }
                if retry == 1 && snapshot.automaticRestarts < 2 {
                    retry += 1; snapshot.automaticRestarts += 1
                    do {
                        try await engine.cancel(); try checkRunning()
                        await engine.unload(); try checkRunning()
                        let mode = snapshot.language.map { $0.rawValue == "ko" ? LanguageMode.korean : .english } ?? session.languageMode
                        session = .init(sessionID: session.sessionID, operationID: .init(UUID()), model: session.model, languageMode: mode)
                        try reconciler.rebind(to: session)
                        try await engine.load(session.model); try checkRunning()
                        try await engine.start(session); try checkRunning()
                        sequence = 0
                        continue
                    } catch {
                        if stopped || Task.isCancelled { return }
                        speechUnavailable = true
                        snapshot.failure = (error as? STTEngineError)?.code ?? .loadFailed
                    }
                }
                consecutiveFailures += 1
                if consecutiveFailures >= 3 { speechUnavailable = true; snapshot.failure = code }
                snapshot.phase = speechUnavailable ? .failed : (inputComplete ? .finishing : .listening)
                if speechUnavailable { queue.removeAll() }
                await emit(); return
            }
        }
    }

    private func inferOnce(_ window: SpeechWindow) async throws {
            try checkRunning()
            sequence += 1
            var context = snapshot.finals.last?.text ?? ""
            while context.utf8.count > Self.contextUTF8Limit { context.removeFirst() }
            let request = try STTInferenceRequest(session: session, requestID: .init(UUID()), sequence: sequence,
                mediaStart: window.mediaStart, audio: window.audio,
                decodingHints: context.isEmpty ? nil : STTDecodingHints(promptText: context))
            let id = request.context.requestID.rawValue
            inferenceID = id
            let timeout: Task<Void, Never>? = recovery == nil ? nil : Task { [weak self, requestTimeout] in
                do { try await Task.sleep(for: requestTimeout) } catch { return }
                await self?.inferenceTimedOut(id)
            }
            defer { timeout?.cancel(); if inferenceID == id { inferenceID = nil } }
            let feed = try await engine.infer(request)
            try checkRunning()
            var revision: Int64 = 0
            var terminal = false
            for await response in try feed.events() {
                try checkRunning()
                guard !speechUnavailable else { throw STTEngineError(.inferenceFailed) }
                guard response.context == request.context, response.revision > revision else {
                    throw STTEngineError(.invalidResponse)
                }
                revision = response.revision
                if response.kind == .final {
                    // Inference is complete; a slow durable write is not a native timeout.
                    timeout?.cancel(); if inferenceID == id { inferenceID = nil }
                }
                if let language = response.detectedLanguage {
                    guard ["ko", "en"].contains(language.rawValue),
                          snapshot.language == nil || snapshot.language == language else {
                        throw STTEngineError(.invalidResponse)
                    }
                    if snapshot.language == nil, let recovery {
                        do { try await recovery.pinLanguage(language, at: location) }
                        catch { snapshot.storageWarning = "recoveryLedgerWriteFailed"; throw error }
                    }
                    snapshot.language = language
                }
                switch response.kind {
                case .partial:
                    if !snapshot.inputPaused, window.boundary != .open || window.endFrame > sealedEnd {
                        snapshot.partial = response.segments.map(\.text).joined(separator: " ")
                    }
                case .final:
                    terminal = true
                    if window.boundary == .open {
                        if !snapshot.inputPaused, window.endFrame > sealedEnd {
                            snapshot.partial = response.segments.map(\.text).joined(separator: " ")
                        }
                    } else {
                        // The engine may truthfully return no speech before
                        // automatic detection has chosen a supported language.
                        if response.segments.isEmpty, snapshot.language == nil {
                            if let recovery {
                                let range = try SpeechRecoveryRange(window.mediaStart.rawValue, window.mediaStart.rawValue + window.audio.duration.rawValue)
                                do {
                                    try await recovery.prepare([], range: range, language: nil, at: location)
                                    snapshot.recovery = try await recovery.complete(range, at: location)
                                } catch { snapshot.storageWarning = "recoveryLedgerWriteFailed"; throw error }
                            }
                            snapshot.partial = nil
                            await emit()
                            continue
                        }
                        guard let language = snapshot.language else { throw STTEngineError(.invalidResponse) }
                        let segments = try reconciler.reconcile(response, for: window, language: language)
                        let range = try SpeechRecoveryRange(window.mediaStart.rawValue, window.mediaStart.rawValue + window.audio.duration.rawValue)
                        if let recovery {
                            do { try await recovery.prepare(segments, range: range, language: language, at: location) }
                            catch { snapshot.storageWarning = "recoveryLedgerWriteFailed"; throw error }
                        }
                        for segment in segments {
                            // A completed append is published even if cancellation arrived
                            // while it was syncing. No ambiguous write is retried.
                            do {
                                try await repository.appendTranscriptJournal(
                                    TranscriptJournalRecord(sessionId: session.sessionID, segment: segment), at: location)
                            } catch {
                                snapshot.storageWarning = (error as? StorageError)?.code.rawValue ?? "journalAppendFailed"
                                throw STTEngineError(.inferenceFailed)
                            }
                            snapshot.finals.append(segment)
                            try checkRunning()
                        }
                        if let recovery {
                            do { snapshot.recovery = try await recovery.complete(range, at: location) }
                            catch { snapshot.storageWarning = "recoveryLedgerWriteFailed"; throw error }
                        }
                        snapshot.partial = nil
                    }
                case .failed, .cancelled:
                    throw response.failure ?? STTEngineError(.inferenceFailed)
                }
                await emit()
            }
            guard terminal else { throw STTEngineError(.invalidResponse) }
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        snapshot.failure = (error as? STTEngineError)?.code ?? .inferenceFailed
        snapshot.phase = .failed
        snapshot.partial = nil
        beginAbort()
    }

    private func inferenceTimedOut(_ id: UUID) async {
        guard !Task.isCancelled, inferenceID == id, !stopped, !speechUnavailable else { return }
        speechUnavailable = true; snapshot.phase = .failed; snapshot.failure = .inferenceFailed
        snapshot.partial = nil; queue.removeAll()
        await emit()
        // No replacement context can be created until native cancellation joins.
        // Capture ingestion continues, recording durable pending ranges.
        if abort == nil { abort = Task { try? await engine.cancel() } }
    }

    private func beginAbort() {
        owner?.cancel()
        worker?.cancel()
        queue.removeAll()
        if abort == nil {
            abort = Task {
                do { try await engine.cancel() }
                catch { if snapshot.failure == nil { snapshot.failure = .cleanupFailed } }
            }
        }
    }

    private func updateMetrics() {
        snapshot.inputMilliseconds = latestFrame / 16
        snapshot.pendingFinals = queue.count + (activeWindow?.boundary == .open || activeWindow == nil ? 0 : 1)
        let earliest = activeWindow?.startFrame ?? queue.first?.startFrame
        snapshot.backlogMilliseconds = earliest.map { max(0, latestFrame - $0) / 16 } ?? 0
        snapshot.degraded = snapshot.pendingFinals > 1 || snapshot.backlogMilliseconds >= 5_000
        sawDegradation = sawDegradation || snapshot.degraded
    }

    private func emit() async {
        updateMetrics()
        // PCM ingestion and inference can both emit while this actor is
        // suspended in the consumer. Preserve actor-order delivery so an
        // older healthy snapshot cannot erase a later terminal failure.
        let value = snapshot
        let previous = publication
        publicationSequence &+= 1
        let sequence = publicationSequence
        let next = Task { [publish] in
            await previous?.value
            await publish(value)
        }
        publication = next
        await next.value
        if publicationSequence == sequence { publication = nil }
    }

    private func diagnostic(_ kind: SessionEventKind, code: String) async {
        do {
            let event = try SessionEventRecord(sessionId: session.sessionID, eventId: SessionEventID(),
                occurredAt: AbsoluteTime(Date()), kind: kind, mediaPositionMs: MediaMilliseconds(latestFrame / 16),
                detail: SessionEventDetail(code: code))
            try await repository.appendEvent(event, at: location)
        } catch {
            snapshot.storageWarning = snapshot.storageWarning ?? "speechEventAppendFailed"
        }
    }
}
