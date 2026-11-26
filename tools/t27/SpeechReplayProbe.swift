import Foundation

/// Opt-in, sequential replay of short local 16 kHz mono Float32 audio. Uses the
/// product segmenter, adapter and reconciler, but never writes a user session.
/// Reports contain timings/counts/error codes, not speech text or PCM.
enum SpeechReplayProbe {
    private struct Attempt: Codable {
        let startMs: Int64
        let durationMs: Int64
        let open: Bool
        var stage = "inference"
        var segments = 0
        var failure: String?
    }

    static func run(engine: any STTEngine, session: STTSessionConfiguration, input: URL, output: URL) async throws {
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        guard !data.isEmpty, data.count % 4 == 0, data.count <= 16_000 * 4 * 600 else {
            throw STTEngineError(.invalidInput)
        }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard samples.allSatisfy(\.isFinite) else { throw STTEngineError(.invalidInput) }
        _ = try STTBenchmarkOutput(output)
        var segmenter = UtteranceSegmenter()
        var windows: [SpeechWindow] = []
        var lastPartial: Int64 = 0
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            let end = min(samples.count, start + 1_600)
            windows += try segmenter.append(Array(samples[start..<end]), at: Int64(start))
            if Int64(end) - lastPartial >= 32_000,
               let open = try segmenter.openWindow(), open.audio.frameCount >= 32_000 {
                windows.append(open)
                lastPartial = Int64(end)
            }
        }
        windows += try segmenter.flush()
        var attempts: [Attempt] = []
        var reconciler = TranscriptReconciler(session: session)
        var context = ""
        do {
            try await engine.load(session.model)
            try await engine.start(session)
            for (index, window) in windows.enumerated() {
                var attempt = Attempt(startMs: window.mediaStart.rawValue,
                    durationMs: window.audio.duration.rawValue, open: window.boundary == .open)
                do {
                    while context.utf8.count > LiveSTTCoordinator.contextUTF8Limit { context.removeFirst() }
                    let request = try STTInferenceRequest(session: session, requestID: .init(UUID()),
                        sequence: Int64(index), mediaStart: window.mediaStart, audio: window.audio,
                        decodingHints: context.isEmpty ? nil : .init(promptText: context))
                    let feed = try await engine.infer(request)
                    var terminal = false
                    for await response in try feed.events() {
                        if let failure = response.failure { throw failure }
                        if response.kind == .final {
                            terminal = true
                            if window.boundary != .open, let language = response.detectedLanguage {
                                attempt.stage = "reconciliation"
                                let finals = try reconciler.reconcile(response, for: window, language: language)
                                attempt.segments = finals.count
                                if let last = finals.last { context = last.text }
                            }
                        }
                    }
                    guard terminal else { throw STTEngineError(.invalidResponse) }
                    attempt.stage = "success"
                } catch {
                    attempt.failure = (error as? STTEngineError)?.code.rawValue ?? "unexpected"
                }
                attempts.append(attempt)
                if attempt.failure != nil { break }
            }
            try await engine.end()
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
        try BenchmarkMain.save(BenchmarkMain.json(attempts), to: output.appendingPathComponent("attempts.json"))
        guard !attempts.isEmpty, attempts.allSatisfy({ $0.failure == nil }) else {
            throw STTEngineError(.inferenceFailed)
        }
        print("Speech replay passed: \(attempts.count) windows; sequential only, not a real-time latency test")
    }
}
