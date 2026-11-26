import AVFoundation
import Foundation

actor FileSpeechRecoveryStore: SpeechRecoveryRecording, SpeechGapRepairing {
    typealias EngineFactory = @Sendable (STTModelConfiguration) throws -> any STTEngine
    typealias AudioReader = @Sendable (FinalizationFileAccess, FinalizationFileEvidence, SpeechRecoveryRange, AudioFinalizationControl) async throws -> [Float]
    private let roots: StorageRootManager
    private let makeEngine: EngineFactory
    private let readAudio: AudioReader
    private let requestTimeout: Duration
    private var active = Set<SessionID>()

    init(roots: StorageRootManager, makeEngine: @escaping EngineFactory,
         readAudio: @escaping AudioReader = FileSpeechRecoveryStore.decode,
         requestTimeout: Duration = .seconds(60)) {
        self.roots = roots; self.makeEngine = makeEngine; self.readAudio = readAudio; self.requestTimeout = requestTimeout
    }

    func initialize(_ session: STTSessionConfiguration, at location: SessionLocation) async throws {
        let lease = try await roots.acquireWriteLease(to: location.rootID)
        do {
            let files = try FinalizationFileAccess(root: lease.rootURL, location: location)
            if try files.identity(SpeechRecoveryDocument.path) != nil {
                let old = try files.readJSON(SpeechRecoveryDocument.self, SpeechRecoveryDocument.path)
                try old.validate(sessionID: location.sessionID)
                guard old.session == session else { throw STTEngineError(.sessionMismatch) }
            } else {
                let language: LanguageCode? = switch session.languageMode {
                case .korean: try .init("ko"); case .english: try .init("en"); case .automatic: nil
                }
                try files.writeJSON(SpeechRecoveryDocument(session: session, language: language), SpeechRecoveryDocument.path)
            }
            await lease.release()
        } catch { await lease.release(); throw error }
    }

    private func update<T: Sendable>(_ location: SessionLocation,
        _ mutation: @Sendable (inout SpeechRecoveryDocument) throws -> T) async throws -> T {
        guard !active.contains(location.sessionID) else { throw TranscriptFailure(code: .busy) }
        let lease = try await roots.acquireWriteLease(to: location.rootID)
        do {
            guard !active.contains(location.sessionID) else { throw TranscriptFailure(code: .busy) }
            let files = try FinalizationFileAccess(root: lease.rootURL, location: location)
            var document = try files.readJSON(SpeechRecoveryDocument.self, SpeechRecoveryDocument.path)
            try document.validate(sessionID: location.sessionID)
            let result = try mutation(&document)
            try document.validate(sessionID: location.sessionID)
            try files.writeJSON(document, SpeechRecoveryDocument.path)
            await lease.release(); return result
        } catch { await lease.release(); throw error }
    }

    func observe(windows: [SpeechRecoveryRange], missing: [SpeechRecoveryRange], through: Int64,
                 ended: Bool, at location: SessionLocation) async throws -> SpeechRecoverySummary {
        try await update(location) { document in
            guard !document.captureEnded, through >= document.scannedThrough else { throw STTEngineError(.invalidInput) }
            for range in windows { document.register(range) }
            for range in missing { try document.addMissing(range) }
            document.scannedThrough = through
            // Capture completion is sealed only against verified audio during finalization.
            return document.summary
        }
    }

    func prepare(_ segments: [TranscriptSegment], range: SpeechRecoveryRange, language: LanguageCode?,
                 at location: SessionLocation) async throws {
        try await update(location) { document in
            guard let index = document.entries.firstIndex(where: { $0.range == range }),
                  document.entries[index].state == .pending else { throw STTEngineError(.invalidLifecycle) }
            if let language {
                guard document.language == nil || document.language == language else { throw STTEngineError(.invalidResponse) }
                document.language = language
            }
            document.entries[index].segments = segments
            document.entries[index].state = .prepared
        }
    }
    func pinLanguage(_ language: LanguageCode, at location: SessionLocation) async throws {
        try await update(location) { document in
            guard document.language == nil || document.language == language else { throw STTEngineError(.invalidResponse) }
            document.language = language
        }
    }
    func complete(_ range: SpeechRecoveryRange, at location: SessionLocation) async throws -> SpeechRecoverySummary {
        try await update(location) { document in
            guard let index = document.entries.firstIndex(where: { $0.range == range }),
                  document.entries[index].state == .prepared else { throw STTEngineError(.invalidLifecycle) }
            document.entries[index].state = .complete
            return document.summary
        }
    }

    func repair(at location: SessionLocation, audio: AudioFinalizationResult,
                control: AudioFinalizationControl) async throws -> SpeechRecoverySummary? {
        guard active.insert(location.sessionID).inserted else { throw TranscriptFailure(code: .busy) }
        defer { active.remove(location.sessionID) }
        let readLease = try await roots.acquireReadLease(to: location.rootID)
        do {
            let files = try FinalizationFileAccess(root: readLease.rootURL, location: location, allowMissingRecovery: true)
            guard try files.identity(SpeechRecoveryDocument.path) != nil else {
                let metadata = try files.readJSON(SessionMetadataDocument.self, "metadata.json")
                guard metadata.transcript.recovery == nil else { throw TranscriptFailure(code: .missingCanonical) }
                await readLease.release(); return nil
            }
            let original = try files.readJSON(SpeechRecoveryDocument.self, SpeechRecoveryDocument.path)
            try original.validate(metadata: files.readJSON(SessionMetadataDocument.self, "metadata.json"))
            if original.captureEnded && !original.summary.requiresWork {
                await readLease.release(); return original.summary
            }
            guard audio.location == location, audio.failure == nil, let final = audio.final else {
                throw AudioFinalizationCode.completionEvidence
            }
            let writeLease = try await roots.acquireWriteLease(to: location.rootID)
            do {
                try files.validateDirectories()
                guard writeLease.rootURL.standardizedFileURL == readLease.rootURL.standardizedFileURL else {
                    throw AudioFinalizationCode.identityChanged
                }
                let duration = metadataDuration(audio, original: try files.readJSON(SessionMetadataDocument.self, "metadata.json"))
                let run = try SpeechRepairTransaction(files: files, document: original, audio: final, duration: duration, control: control)
                let factory = makeEngine, reader = readAudio, timeout = requestTimeout
                let work = Task { try await run.repair(makeEngine: factory, readAudio: reader, timeout: timeout) }
                let cancellation = Task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(50)); try control.check() }
                        catch { work.cancel(); return }
                    }
                }
                defer { cancellation.cancel() }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                await writeLease.release(); await readLease.release(); return result
            } catch { await writeLease.release(); throw error }
        } catch { await readLease.release(); throw error }
    }

    private func metadataDuration(_ audio: AudioFinalizationResult, original: SessionMetadataDocument) -> Int64 {
        if original.captureOutcome == .interrupted, let media = audio.media,
           media.durationSeconds.isFinite, media.durationSeconds >= 0, media.durationSeconds < Double(Int64.max) / 1000 {
            return Int64((media.durationSeconds * 1000).rounded(.up))
        }
        return original.activeDurationMs.rawValue
    }

    static func decode(_ files: FinalizationFileAccess, _ audio: FinalizationFileEvidence,
                       _ range: SpeechRecoveryRange, _ control: AudioFinalizationControl) async throws -> [Float] {
        try control.check(); try Task.checkCancellation(); try files.verify(audio)
        let asset = AVURLAsset(url: try files.url(audio.relativePath))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try control.check(); try Task.checkCancellation(); try files.verify(audio)
        guard tracks.count == 1 else { throw AudioFinalizationCode.invalidTracks }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = .init(start: .init(value: range.start, timescale: 1000),
                                 duration: .init(value: range.end - range.start, timescale: 1000))
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw AudioFinalizationCode.decode }
        reader.add(output)
        guard reader.startReading() else { throw AudioFinalizationCode.decode }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try control.check(); try Task.checkCancellation(); try files.verify(audio)
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw AudioFinalizationCode.decode }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes % 4 == 0, samples.count + bytes / 4 <= 480_000 else { throw AudioFinalizationCode.decode }
            var chunk = [Float](repeating: 0, count: bytes / 4)
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw AudioFinalizationCode.decode }
            samples += chunk
        }
        guard reader.status == .completed, !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw AudioFinalizationCode.decode }
        try files.verify(audio)
        // Decoder alignment/padding cannot advance the session clock.
        return Array(samples.prefix(Int((range.end - range.start) * 16)))
    }
}

private final class SpeechRepairTransaction: @unchecked Sendable {
    let files: FinalizationFileAccess
    let audio: FinalizationFileEvidence
    let control: AudioFinalizationControl
    let metadata: SessionMetadataDocument
    let duration: Int64
    private let metadataStamp: FinalizationFileEvidence
    private var stamp: FinalizationFileEvidence
    private var document: SpeechRecoveryDocument

    init(files: FinalizationFileAccess, document: SpeechRecoveryDocument, audio: FinalizationFileEvidence, duration: Int64,
         control: AudioFinalizationControl) throws {
        self.files = files; self.document = document; self.audio = audio; self.control = control
        self.duration = duration
        metadata = try files.readJSON(SessionMetadataDocument.self, "metadata.json")
        guard let meta = try files.identity("metadata.json"), let stamp = try files.identity(SpeechRecoveryDocument.path),
              metadata.sessionId == document.session.sessionID, metadata.engine == document.session.model.engine,
              metadata.model == document.session.model.model,
              metadata.modelSettings?.inference == document.session.model.options else { throw STTEngineError(.sessionMismatch) }
        metadataStamp = meta; self.stamp = stamp
        guard try files.readJSON(SpeechRecoveryDocument.self, SpeechRecoveryDocument.path) == document else {
            throw AudioFinalizationCode.identityChanged
        }
    }
    private func check() throws {
        try control.check(); try Task.checkCancellation()
        try files.verify(metadataStamp); try files.verify(stamp); try files.verify(audio)
    }
    private func save(cancellationCheckpoint: Bool = false) throws {
        if cancellationCheckpoint {
            try files.verify(metadataStamp); try files.verify(stamp); try files.verify(audio)
        } else { try check() }
        try document.validate(sessionID: files.location.sessionID)
        try files.writeJSON(document, SpeechRecoveryDocument.path)
        guard let next = try files.identity(SpeechRecoveryDocument.path) else { throw AudioFinalizationCode.persistence }
        stamp = next
    }
    private func infer(_ engine: any STTEngine, request: STTInferenceRequest, timeout: Duration) async throws -> STTResponse {
        let deadline = SpeechRecoveryDeadline()
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard deadline.expire() else { return }
            try? await engine.cancel()
        }
        let outcome: Result<STTResponse, Error>
        do {
            let feed = try await engine.infer(request)
            var final: STTResponse?
            var revision: Int64 = 0
            for await response in try feed.events() {
                try check()
                guard response.context == request.context, response.revision > revision else { throw STTEngineError(.invalidResponse) }
                revision = response.revision
                if let failure = response.failure { throw failure }
                if response.kind == .final { final = response }
            }
            guard let final else { throw STTEngineError(.invalidResponse) }
            outcome = .success(final)
        } catch { outcome = .failure(error) }
        // A timeout belongs to this attempt, not the control used to publish
        // partial transcripts. Once expiry wins, never cancel its cleanup task.
        let timedOut = deadline.disarm()
        if !timedOut { watchdog.cancel() }
        await watchdog.value
        if timedOut { throw SpeechRecoveryTimeout() }
        try check()
        return try outcome.get()
    }
    func repair(makeEngine: FileSpeechRecoveryStore.EngineFactory, readAudio: FileSpeechRecoveryStore.AudioReader, timeout: Duration) async throws -> SpeechRecoverySummary {
        try check()
        if !document.captureEnded {
            if let selected = metadata.detectedLanguage {
                guard document.language == nil || document.language == selected else { throw STTEngineError(.invalidResponse) }
                document.language = selected
            }
            for i in document.entries.indices where document.entries[i].state == .prepared { document.entries[i].state = .complete }
            let missing = document.entries.filter { $0.state == .pending }.map(\.range)
            document.entries.removeAll { $0.state == .pending }
            for span in missing where span.start < duration {
                try document.addMissing(.init(span.start, min(span.end, duration)))
            }
            if document.scannedThrough < duration { try document.addMissing(.init(document.scannedThrough, duration)) }
            document.captureEnded = true
            try save()
        }
        // A crash or an older build may have persisted the final attempt but
        // not its terminal state. Exhaustion must not require a model to load.
        var normalized = false
        for i in document.entries.indices where document.entries[i].state == .pending && document.entries[i].attempts == 2 {
            document.entries[i].state = .exhausted
            normalized = true
        }
        if normalized { try save() }
        guard document.summary.requiresWork else { return document.summary }
        let engine = try makeEngine(document.session.model)
        do {
            do { try await engine.load(document.session.model) }
            catch {
                try check() // Cancellation is not a model failure.
                await engine.unload()
                return document.summary // Same pinned model must be restored by the user.
            }
            var sequence: Int64 = 0
            let languageMode: LanguageMode = document.language.map { $0.rawValue == "ko" ? .korean : .english } ?? document.session.languageMode
            let session = STTSessionConfiguration(sessionID: document.session.sessionID, operationID: .init(UUID()),
                model: document.session.model, languageMode: languageMode)
            try await engine.start(session)
            var timedOut = false
            repairWindows: for i in document.entries.indices where document.entries[i].state == .pending {
                while document.entries[i].attempts < 2 && document.entries[i].state == .pending {
                    try check()
                    document.entries[i].attempts += 1; try save()
                    do {
                        let entry = document.entries[i]
                        guard entry.range.end <= duration else { throw STTEngineError(.invalidInput) }
                        let pcm = try await readAudio(files, audio, entry.range, control)
                        try check()
                        let request = try STTInferenceRequest(session: session, requestID: .init(UUID()), sequence: sequence,
                            mediaStart: .init(entry.range.start), audio: .init(format: STTInputFormat(), frameCount: pcm.count, samples: pcm))
                        sequence += 1
                        let final = try await infer(engine, request: request, timeout: timeout)
                        if let language = final.detectedLanguage {
                            guard document.language == nil || document.language == language else { throw STTEngineError(.invalidResponse) }
                            document.language = language
                        }
                        guard final.segments.isEmpty || document.language != nil else { throw STTEngineError(.invalidResponse) }
                        document.entries[i].segments = try final.segments.enumerated().compactMap { index, value in
                            let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return nil }
                            return try TranscriptSegment(id: .init(UUID()), sequence: .init(Int64(index)), startMs: value.start,
                                endMs: value.end, originalText: text, text: text, language: document.language!)
                        }
                        document.entries[i].state = .complete
                        document.entries[i].recovered = true
                        document.entries[i].failure = nil
                        try save()
                    } catch {
                        let expired = error is SpeechRecoveryTimeout
                        let cancelled = control.outcome().0 == .cancelled || (Task.isCancelled && control.outcome().0 == nil)
                        if cancelled && !expired {
                            document.entries[i].attempts -= 1
                            try save(cancellationCheckpoint: true)
                            throw AudioFinalizationCode.cancelled
                        }
                        // A cancellation arriving during timeout cleanup must
                        // retain that consumed attempt, while ordinary cancel refunds it.
                        if !cancelled { try check() }
                        guard expired || error is STTEngineError else { throw error }
                        document.entries[i].failure = (error as? STTEngineError)?.code ?? .inferenceFailed
                        if document.entries[i].attempts >= 2 { document.entries[i].state = .exhausted }
                        try save(cancellationCheckpoint: cancelled)
                        if cancelled { throw AudioFinalizationCode.cancelled }
                        if expired { timedOut = true; break repairWindows }
                    }
                }
                if document.entries[i].state == .pending { document.entries[i].state = .exhausted; try save() }
            }
            if !timedOut { try await engine.end() }
        } catch {
            try? await engine.cancel(); await engine.unload(); throw error
        }
        await engine.unload(); try check()
        return document.summary
    }
}

private struct SpeechRecoveryTimeout: Error {}

/// Atomically choose completion or expiry, then join an expired timer's cleanup.
private final class SpeechRecoveryDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var expired = false
    func expire() -> Bool { lock.withLock { guard active else { return false }; active = false; expired = true; return true } }
    func disarm() -> Bool { lock.withLock { active = false; return expired } }
}
