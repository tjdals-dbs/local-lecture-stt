import Foundation
import whisper

/// Synchronous entry points. An allocated context transfers exactly once to the
/// queue, including when cancellation races the return of create.
struct NativeWhisperCalls: Sendable {
    var create: @Sendable (ModelUseLease, NativeDecodeControl) throws -> OpaquePointer = { lease, control in
        try WhisperCppModelValidator.withVerifiedWeights(lease, checkCancellation: control.check) { path in
            var options = whisper_context_default_params()
            options.use_gpu = true
            options.flash_attn = true
            // The binary probes a sibling Core ML encoder. /dev/fd has no such asset.
            guard let ctx = whisper_init_from_file_with_params(path, options) else { throw STTEngineError(.loadFailed) }
            return ctx
        }
    }
    var full: @Sendable (OpaquePointer, whisper_full_params, UnsafePointer<Float>?, Int32) -> Int32 = {
        whisper_full($0, $1, $2, $3)
    }
    var free: @Sendable (OpaquePointer) -> Void = { whisper_free($0) }
}

/// One queue owns all context/state reads, calls and frees. Only a locked request
/// control and owned snapshots cross native threads; callbacks never await an actor.
final class NativeWhisperBackend: WhisperIntervalBackend, @unchecked Sendable {
    static let libraryVersion = String(cString: whisper_version())
    private let queue = DispatchQueue(label: "stt.whisper.cpp.native", qos: .userInitiated)
    private let calls: NativeWhisperCalls
    private var context: OpaquePointer?
    private var timing = STTBenchmarkLoadTiming(prewarmSeconds: nil, modelSeconds: nil)
    private let encoderEntered: @Sendable () -> Void
    private let cancellationRequested: @Sendable () -> Void
    private let abortObserved: @Sendable () -> Void

    init(calls: NativeWhisperCalls = .init(), encoderEntered: @escaping @Sendable () -> Void = {}, cancellationRequested: @escaping @Sendable () -> Void = {},
         abortObserved: @escaping @Sendable () -> Void = {}) {
        self.calls = calls
        self.encoderEntered = encoderEntered
        self.cancellationRequested = cancellationRequested
        self.abortObserved = abortObserved
    }
    deinit { if let context { calls.free(context) } }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    func loadTiming() async -> STTBenchmarkLoadTiming {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.timing) } }
    }
    func load(_ lease: ModelUseLease) async throws {
        let control = NativeDecodeControl()
        try await withTaskCancellationHandler {
            try await perform {
                guard self.context == nil else { throw STTEngineError(.busy) }
                let start = ProcessInfo.processInfo.systemUptime
                let ctx = try self.calls.create(lease, control)
                self.context = ctx
                try control.check()
                guard whisper_is_multilingual(ctx) != 0, whisper_model_ftype(ctx) == 1,
                      whisper_n_text_ctx(ctx) == 448, whisper_n_vocab(ctx) == 51866 else {
                    throw STTEngineError(.unsupportedModel)
                }
                self.timing = .init(prewarmSeconds: nil, modelSeconds: ProcessInfo.processInfo.systemUptime - start)
            }
        } onCancel: { control.fail(.cancelled) }
    }
    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let ctx = self.context { self.calls.free(ctx); self.context = nil }
                continuation.resume()
            }
        }
    }
    func decode(_ audio: STTInferenceAudio, settings: WhisperDecodeSettings,
                partial: @escaping @Sendable (WhisperSnapshot) async -> Void) async throws -> WhisperSnapshot {
        try await withNativeCallbacks(partial: partial) { control in
            try self.transcribe(audio, settings, control)
        }
    }

    /// The single consumer serializes owned snapshots; both successful and failed
    /// native returns wait for its last actor hop before the request can settle.
    func withNativeCallbacks(partial: @escaping @Sendable (WhisperSnapshot) async -> Void,
                             operation: @escaping @Sendable (NativeDecodeControl) throws -> WhisperSnapshot) async throws -> WhisperSnapshot {
        let pair = AsyncStream<WhisperSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { for await snapshot in pair.stream { await partial(snapshot) } }
        let control = NativeDecodeControl(entered: encoderEntered, observed: abortObserved,
            publish: { pair.continuation.yield($0) })
        let result: Result<WhisperSnapshot, Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try await perform { try operation(control) }
            } onCancel: { control.fail(.cancelled); self.cancellationRequested() })
        } catch { result = .failure(error) }
        pair.continuation.finish()
        await consumer.value
        return try result.get()
    }

    private func transcribe(_ audio: STTInferenceAudio, _ settings: WhisperDecodeSettings,
                            _ control: NativeDecodeControl) throws -> WhisperSnapshot {
        guard let ctx = context else { throw STTEngineError(.invalidLifecycle) }
        guard audio.format == (try STTInputFormat()), let count = Int32(exactly: audio.samples.count),
              count > 0, count <= 480_000 else { throw STTEngineError(.invalidInput) }
        let tokens = try Self.promptTokens(ctx, settings: settings)
        var params = try Self.parameters(settings, control: control)
        try control.check()
        return try audio.samples.withUnsafeBufferPointer { pcm in
            // Detection-only success has no transcript. Check its own return before
            // using the id (the state initializes lang_id to English).
            let language: String
            if settings.detectLanguage {
                guard settings.language == nil else { throw STTEngineError(.invalidConfiguration) }
                if pcm.allSatisfy({ $0 == 0 }) { return .init(text: "", intervals: [], language: nil) }
                var detection = params
                detection.detect_language = true
                detection.language = nil
                detection.new_segment_callback = nil
                let rc = calls.full(ctx, detection, pcm.baseAddress, count)
                try control.check()
                language = try Self.detectedLanguage(status: rc, id: whisper_full_lang_id(ctx))
            } else {
                guard let selected = settings.language, ["ko", "en"].contains(selected) else { throw STTEngineError(.invalidConfiguration) }
                language = selected
            }
            try control.check()
            control.configure(language: language, timestamps: settings.timestamps, duration: audio.duration.rawValue)
            return try language.withCString { string in
                try tokens.withUnsafeBufferPointer { prompt in
                    params.language = string
                    params.prompt_tokens = prompt.isEmpty ? nil : prompt.baseAddress
                    params.prompt_n_tokens = Int32(prompt.count)
                    let rc = calls.full(ctx, params, pcm.baseAddress, count)
                    try control.check()
                    guard rc == 0 else { throw STTEngineError(.inferenceFailed) }
                    return try control.snapshot(ctx)
                }
            }
        }
    }

    static func detectedLanguage(status: Int32, id: Int32) throws -> String {
        guard status == 0 else { throw STTEngineError(.inferenceFailed) }
        guard (0...whisper_lang_max_id()).contains(id), let ptr = whisper_lang_str(id),
              let language = String(validatingCString: ptr), ["ko","en"].contains(language) else {
            throw STTEngineError(.unsupportedCapability)
        }
        return language
    }

    static func promptTokens(_ ctx: OpaquePointer, settings: WhisperDecodeSettings) throws -> [Int32] {
        guard let text = settings.promptText, !text.isEmpty else { return [] }
        // At this pin temperatures >= 0.5 omit all prompt history.
        guard Float(settings.temperature) < 0.5, !text.utf8.contains(0),
              text.utf8.count <= STTDecodingHints.maximumUTF8Bytes else { throw STTEngineError(.invalidInput) }
        let capacity = whisper_n_text_ctx(ctx) / 2 - 1 // reserve native previous-context marker
        guard (1...4096).contains(capacity) else { throw STTEngineError(.unsupportedModel) }
        var tokens = [Int32](repeating: 0, count: Int(capacity))
        let count = whisper_tokenize(ctx, text, &tokens, capacity)
        guard (1...capacity).contains(count) else { throw STTEngineError(.invalidInput) }
        let accepted = Array(tokens.prefix(Int(count)))
        // Native greedy tokenizer can skip unrecognized bytes. Verify the full UTF-8
        // byte sequence, including tokens that individually split a multibyte scalar.
        var bytes: [UInt8] = []
        for token in accepted {
            guard token >= 0, token < whisper_token_eot(ctx), let ptr = whisper_token_to_str(ctx, token) else {
                throw STTEngineError(.invalidInput)
            }
            bytes += UnsafeRawBufferPointer(start: ptr, count: strlen(ptr))
        }
        guard bytes.elementsEqual(text.utf8) else { throw STTEngineError(.invalidInput) }
        return accepted
    }

    static func parameters(_ settings: WhisperDecodeSettings, control: NativeDecodeControl) throws -> whisper_full_params {
        guard settings.temperature.isFinite, (0...1).contains(settings.temperature) else { throw STTEngineError(.invalidConfiguration) }
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = 4
        p.greedy.best_of = 1
        p.translate = false
        p.detect_language = false
        p.no_context = true
        p.carry_initial_prompt = true
        p.temperature = Float(settings.temperature)
        p.temperature_inc = 0
        p.no_timestamps = !settings.timestamps
        p.token_timestamps = false
        p.print_progress = false
        p.print_realtime = false
        p.print_special = false
        p.print_timestamps = false
        let userdata = Unmanaged.passUnretained(control).toOpaque()
        p.encoder_begin_callback_user_data = userdata
        p.abort_callback_user_data = userdata
        p.new_segment_callback_user_data = userdata
        p.encoder_begin_callback = { _, _, data in
            let op = Unmanaged<NativeDecodeControl>.fromOpaque(data!).takeUnretainedValue()
            op.entered()
            return !op.shouldAbort()
        }
        p.abort_callback = { data in Unmanaged<NativeDecodeControl>.fromOpaque(data!).takeUnretainedValue().shouldAbort() }
        p.new_segment_callback = { ctx, _, _, data in
            let op = Unmanaged<NativeDecodeControl>.fromOpaque(data!).takeUnretainedValue()
            guard let ctx else { op.fail(.invalidResponse); return }
            do {
                let value = try op.snapshot(ctx)
                if !value.text.isEmpty { op.publish(value) }
            } catch { op.fail(.invalidResponse) }
        }
        return p
    }
}

struct NativeWhisperSegment: Sendable {
    let startTick: Int64
    let endTick: Int64
    let text: String
}

final class NativeDecodeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: STTErrorCode?
    private var observedAbort = false
    let entered: @Sendable () -> Void
    private let observed: @Sendable () -> Void
    let publish: @Sendable (WhisperSnapshot) -> Void
    // Only the serial native queue writes these, before whisper_full. Segment
    // callbacks run synchronously on that same calling thread for single-stream full.
    private var language: String?
    private var timestamps = true
    private var duration: Int64 = 0

    init(entered: @escaping @Sendable () -> Void = {}, observed: @escaping @Sendable () -> Void = {},
         publish: @escaping @Sendable (WhisperSnapshot) -> Void = { _ in }) {
        self.entered = entered; self.observed = observed; self.publish = publish
    }
    func configure(language: String, timestamps: Bool, duration: Int64) {
        self.language = language; self.timestamps = timestamps; self.duration = duration
    }
    func fail(_ code: STTErrorCode) { lock.withLock { if failure == nil { failure = code } } }
    func check() throws { if let code = lock.withLock({ failure }) { throw STTEngineError(code) } }
    func shouldAbort() -> Bool {
        let (stop, notify) = lock.withLock {
            let stop = failure != nil
            let notify = stop && !observedAbort
            if stop { observedAbort = true }
            return (stop, notify)
        }
        if notify { observed() }
        return stop
    }
    static func seconds(ticks: Int64, duration: Int64) throws -> Double {
        let ms = ticks.multipliedReportingOverflow(by: 10)
        guard !ms.overflow, ms.partialValue >= 0, ms.partialValue <= duration else { throw STTEngineError(.invalidResponse) }
        return Double(ms.partialValue) / 1000
    }
    func snapshot(_ ctx: OpaquePointer) throws -> WhisperSnapshot {
        let count = whisper_full_n_segments(ctx)
        guard (0...128).contains(count) else { throw STTEngineError(.invalidResponse) }
        var segments: [NativeWhisperSegment] = [], bytes = 0
        for i in 0..<count {
            guard let ptr = whisper_full_get_segment_text(ctx, i),
                  strnlen(ptr, 16385) <= 16384, let part = String(validatingCString: ptr),
                  bytes + part.utf8.count <= 65536 else { throw STTEngineError(.invalidResponse) }
            bytes += part.utf8.count
            segments.append(.init(startTick: timestamps ? whisper_full_get_segment_t0(ctx, i) : 0,
                                  endTick: timestamps ? whisper_full_get_segment_t1(ctx, i) : 0, text: part))
        }
        return try Self.snapshot(segments, language: language, timestamps: timestamps, duration: duration)
    }

    static func snapshot(_ segments: [NativeWhisperSegment], language: String?, timestamps: Bool,
                         duration: Int64) throws -> WhisperSnapshot {
        guard (1...30_000).contains(duration), segments.count <= 128 else { throw STTEngineError(.invalidResponse) }
        var text = "", intervals: [WhisperInterval] = [], bytes = 0
        var previous = 0.0
        for segment in segments {
            bytes += segment.text.utf8.count
            guard segment.text.utf8.count <= 16384, bytes <= 65536 else { throw STTEngineError(.invalidResponse) }
            if timestamps {
                // This pin decodes a padded 30-second native window even for
                // short VAD inputs (e.g. a 2020 ms input can end at tick 3000).
                // Validate raw order/bounds BEFORE intersecting with real media.
                // The shared engine boundary still rejects out-of-input times.
                let start = try seconds(ticks: segment.startTick, duration: 30_000)
                let end = try seconds(ticks: segment.endTick, duration: 30_000)
                guard start >= previous, end >= start else { throw STTEngineError(.invalidResponse) }
                previous = end
                let limit = Double(duration) / 1000
                // Do not manufacture text from padding-only spans. Preserve
                // legitimate zero-duration marks exactly on the media endpoint.
                guard start < limit || (start == limit && end == start) else { continue }
                intervals.append(.init(start: start, end: min(end, limit), text: segment.text))
            }
            text += segment.text
        }
        return .init(text: text, intervals: intervals, language: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : language)
    }
}
