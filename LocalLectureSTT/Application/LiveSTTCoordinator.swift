import Foundation

struct SpeechAudioBlock: Sendable {
    let samples: [Float]
    let startFrame: Int64
}

protocol SpeechPCMConverting: Sendable {
    func convert(_ chunk: PCMChunk, origin: Int64) async throws -> [SpeechAudioBlock]
    func drain() async throws -> [SpeechAudioBlock]
}

enum LiveSTTPhase: String, Sendable { case idle, listening, finishing, finished, cancelled, failed }

struct LiveSTTSnapshot: Sendable, Equatable {
    var phase: LiveSTTPhase = .idle
    var cleanupComplete = false
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
    static let idle = LiveSTTSnapshot()
}

/// One owner per recording, independent of the recorder's PCM consumer.
/// At most one inference and four pending final windows hold audio. Partial
/// work has no queue: busy/degraded ticks are skipped. Exhausting final capacity
/// visibly stops STT only; recoverable audio remains the source for later repair.
actor LiveSTTCoordinator {
    // Conservative UTF-8 suffix, below the selected adapter's prompt-token
    // budget even for byte-level tokens. Never forward the entire transcript.
    static let contextUTF8Limit = 96
    private let engine: any STTEngine
    private let session: STTSessionConfiguration
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
         publish: @escaping @Sendable (LiveSTTSnapshot) async -> Void = { _ in }) {
        self.engine = engine; self.session = session; self.repository = repository
        self.location = location; self.converter = converter
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
            try await engine.start(session)
            try checkRunning()
            snapshot.phase = .listening
            await emit()
            var origin: Int64?
            var expectedSequence: UInt64?
            var expectedSample: Int64?
            for try await chunk in handle.speechPCM {
                try checkRunning()
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
                try ingest(blocks)
                await emit()
            }
            try checkRunning()
            let tail = try await converter.drain()
            try checkRunning()
            try ingest(tail, allowsPartial: false)
            for window in try segmenter.flush() { try enqueue(window) }
            snapshot.phase = .finishing
            snapshot.partial = nil
            await emit()
            startWorker()
        } catch {
            if !stopped { fail(error) }
        }
        await worker?.value
        if let abort { await abort.value }
        if !stopped {
            do { try await engine.end() }
            catch { fail(error); await abort?.value }
        }
        // All accepted callbacks and journal appends have settled before unload.
        await engine.unload()
        if !stopped { snapshot.phase = .finished }
        snapshot.partial = nil
        queue.removeAll()
        activeWindow = nil
        if sawDegradation { await diagnostic(.sttBackpressureDegraded, code: "speech.degraded") }
        if let failure = snapshot.failure { await diagnostic(.sttError, code: "speech.\(failure.rawValue)") }
        cleaned = true
        snapshot.cleanupComplete = true
        await emit()
    }

    private func checkRunning() throws {
        guard !stopped, !Task.isCancelled else { throw STTEngineError(.cancelled) }
    }

    private func ingest(_ blocks: [SpeechAudioBlock], allowsPartial: Bool = true) throws {
        for block in blocks {
            let end = block.startFrame.addingReportingOverflow(Int64(block.samples.count))
            guard !end.overflow, block.samples.count <= 480_000 else { throw STTEngineError(.invalidInput) }
            latestFrame = max(latestFrame, end.partialValue)
            for window in try segmenter.append(block.samples, at: block.startFrame) { try enqueue(window) }
        }
        updateMetrics()
        if allowsPartial, worker == nil, queue.isEmpty, !snapshot.degraded,
           latestFrame - lastPartialFrame >= 32_000,
           let open = try segmenter.openWindow(), open.audio.frameCount >= 32_000 {
            lastPartialFrame = latestFrame
            activeWindow = open
            worker = Task { await self.process(open); await self.drainQueue() }
        }
        startWorker()
    }

    private func enqueue(_ window: SpeechWindow) throws {
        guard queue.count < capacity else { throw STTEngineError(.backlogFull) }
        queue.append(window)
        sealedEnd = max(sealedEnd, window.endFrame)
        // An old open-window response may no longer replace the pending final.
        snapshot.partial = nil
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty, !stopped else { return }
        worker = Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        while !stopped, !queue.isEmpty {
            let next = queue.removeFirst()
            activeWindow = next
            await emit()
            await process(next)
        }
        activeWindow = nil
        worker = nil
        await emit()
    }

    private func process(_ window: SpeechWindow) async {
        do {
            try checkRunning()
            sequence += 1
            var context = snapshot.finals.last?.text ?? ""
            while context.utf8.count > Self.contextUTF8Limit { context.removeFirst() }
            let request = try STTInferenceRequest(session: session, requestID: .init(UUID()), sequence: sequence,
                mediaStart: window.mediaStart, audio: window.audio,
                decodingHints: context.isEmpty ? nil : STTDecodingHints(promptText: context))
            let feed = try await engine.infer(request)
            try checkRunning()
            var revision: Int64 = 0
            var terminal = false
            for await response in try feed.events() {
                try checkRunning()
                guard response.context == request.context, response.revision > revision else {
                    throw STTEngineError(.invalidResponse)
                }
                revision = response.revision
                if let language = response.detectedLanguage {
                    guard ["ko", "en"].contains(language.rawValue),
                          snapshot.language == nil || snapshot.language == language else {
                        throw STTEngineError(.invalidResponse)
                    }
                    snapshot.language = language
                }
                switch response.kind {
                case .partial:
                    if window.boundary != .open || window.endFrame > sealedEnd {
                        snapshot.partial = response.segments.map(\.text).joined(separator: " ")
                    }
                case .final:
                    terminal = true
                    if window.boundary == .open {
                        if window.endFrame > sealedEnd {
                            snapshot.partial = response.segments.map(\.text).joined(separator: " ")
                        }
                    } else {
                        // The engine may truthfully return no speech before
                        // automatic detection has chosen a supported language.
                        if response.segments.isEmpty, snapshot.language == nil {
                            snapshot.partial = nil
                            await emit()
                            continue
                        }
                        guard let language = snapshot.language else { throw STTEngineError(.invalidResponse) }
                        let segments = try reconciler.reconcile(response, for: window, language: language)
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
                        snapshot.partial = nil
                    }
                case .failed, .cancelled:
                    throw response.failure ?? STTEngineError(.inferenceFailed)
                }
                await emit()
            }
            guard terminal else { throw STTEngineError(.invalidResponse) }
        } catch {
            if !stopped { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        snapshot.failure = (error as? STTEngineError)?.code ?? .inferenceFailed
        snapshot.phase = .failed
        snapshot.partial = nil
        beginAbort()
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
        await publish(snapshot)
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
