import Foundation

protocol STTBenchmarkMemoryProbe: Sendable {
    var baseline: UInt64? { get }
    func stop() -> UInt64?
}
struct STTBenchmarkRunner: Sendable {
    var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// One explicit load/session/infer/end/unload. Even cancelled control callers join unload/sampler.
    func measure(engine: any STTEngine, input: STTBenchmarkInput, session: STTSessionConfiguration,
                 repetition: Int, warmup: Bool, cancelOnFirstPartial: Bool = false,
                 cancelAtNativeEntry: AsyncStream<Void>? = nil,
                 memory: any STTBenchmarkMemoryProbe,
                 cleanupWarnings: @Sendable () async -> [String] = { [] },
                 observe: @Sendable () async -> (STTBenchmarkLoadTiming, STTBenchmarkRequestTiming?)) async -> STTBenchmarkMeasurement {
        let loadBegan = now()
        var loadSeconds = 0.0, finalSeconds: Double?, partialSeconds: Double?, inferenceBegan: Double?
        var terminal: STTResponse?, failure: STTEngineError?, timing: STTBenchmarkRequestTiming?
        var loadTiming = STTBenchmarkLoadTiming(prewarmSeconds: nil, modelSeconds: nil)
        do {
            try await engine.load(session.model); loadSeconds = max(0, now() - loadBegan)
            try await engine.start(session)
            let request = try STTInferenceRequest(session: session, requestID: STTRequestID(UUID()), sequence: 0,
                mediaStart: input.mediaStart, audio: input.audio, decodingHints: input.hints)
            let began = now(); inferenceBegan = began
            let feed = try await engine.infer(request)
            let events = try feed.events()
            let withdrawal = cancelAtNativeEntry.map { entry in
                Task {
                    for await _ in entry {
                        if !Task.isCancelled { await feed.withdraw() }
                        break
                    }
                }
            }
            for await response in events {
                if response.kind == .partial, partialSeconds == nil {
                    partialSeconds = max(0, now() - began)
                    if cancelOnFirstPartial { await feed.withdraw() }
                }
                if response.isTerminal { terminal = response }
            }
            withdrawal?.cancel()
            await withdrawal?.value
            if Task.isCancelled {
                await feed.withdraw(); terminal = feed.observation().latest
                throw STTEngineError(.cancelled)
            }
            finalSeconds = max(0, now() - began)
            try await engine.end()
            let expectCancellation = cancelOnFirstPartial || cancelAtNativeEntry != nil
            guard let terminal, terminal.kind == (expectCancellation ? .cancelled : .final),
                  expectCancellation || !terminal.segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw terminal?.failure ?? STTEngineError(.invalidResponse)
            }
        } catch {
            failure = (error as? STTEngineError) ?? STTEngineError(error is CancellationError ? .cancelled : .inferenceFailed)
            if let inferenceBegan, finalSeconds == nil { finalSeconds = max(0, now() - inferenceBegan) }
            if loadSeconds == 0 { loadSeconds = max(0, now() - loadBegan) }
        }
        (loadTiming, timing) = await observe()
        await engine.unload()
        let peak = memory.stop()
        let warnings = await cleanupWarnings()
        return .init(repetition: repetition, warmup: warmup, loadSeconds: loadSeconds,
            prewarmSeconds: loadTiming.prewarmSeconds, modelLoadSeconds: loadTiming.modelSeconds,
            queueSeconds: timing?.queueSeconds, inferenceSeconds: timing?.inferenceSeconds,
            finalSeconds: finalSeconds, firstPartialSeconds: partialSeconds,
            rtf: terminal?.kind == .final ? STTBenchmarkMeasurement.rtf(processing: timing?.inferenceSeconds,
                audio: Double(input.audio.duration.rawValue) / 1000) : nil,
            baselinePhysicalFootprint: memory.baseline, peakPhysicalFootprint: peak,
            terminal: terminal, failure: failure, warnings: warnings + (peak == nil ? ["Physical footprint unavailable"] : []))
    }
}
