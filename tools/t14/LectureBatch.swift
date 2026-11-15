import Foundation

/// Each CLI process owns one candidate, one pre-decoded sample, and one engine lifecycle.
struct LecturePlan: Decodable {
    struct Window: Codable, Equatable {
        let startFrame: Int
        let endFrame: Int
        let sha256: String
    }
    let schemaVersion: Int
    let sourceSHA256: String
    let pcmSHA256: String
    let frameCount: Int
    let windows: [Window]
    let languageMode: LanguageMode

    func checkedPCM(at directory: URL) throws -> Data {
        guard schemaVersion == 1, (8...14_400_000).contains(frameCount) else { throw STTEngineError(.invalidInput) }
        let pcm = try Data(contentsOf: directory.appendingPathComponent("audio.f32"))
        guard pcm.count == frameCount * 4, ModelPackageRules.sha256(pcm) == pcmSHA256 else {
            throw STTEngineError(.invalidInput)
        }
        var next = 0
        for window in windows {
            guard window.startFrame == next, window.endFrame <= frameCount,
                  window.endFrame > next, (8...480_000).contains(window.endFrame - next),
                  ModelPackageRules.sha256(pcm[next * 4..<window.endFrame * 4]) == window.sha256 else {
                throw STTEngineError(.invalidInput)
            }
            next = window.endFrame
        }
        guard next == frameCount else { throw STTEngineError(.invalidInput) }
        return pcm
    }
}

private struct LectureWindowResult: Encodable {
    let index: Int
    let window: LecturePlan.Window
    var firstPartialSeconds: Double?
    var terminalSeconds: Double?
    var serviceSeconds: Double?
    var timing: STTBenchmarkRequestTiming?
    var terminal: STTResponse?
    var failure: String?
}

private struct LectureRun: Encodable {
    let schemaVersion = 1
    let model: ModelPackageDescriptor
    let settings: STTSessionConfiguration
    let sourceSHA256: String
    let pcmSHA256: String
    let frameCount: Int
    let hardware = BenchmarkMain.hardware()
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    var loadSeconds: Double = 0
    var loadTiming: STTBenchmarkLoadTiming?
    var effectiveCompute: String?
    var baselinePhysicalFootprint: UInt64?
    var peakPhysicalFootprint: UInt64?
    var completedWindows = 0
    var warnings: [String] = []
    var failure: String?
}

enum LectureBatch {
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    static func measure(engine: any BenchmarkIntervalEngine, descriptor: ModelPackageDescriptor, planURL: URL,
                        options: STTInferenceOptions, output: URL) async throws {
        let plan = try JSONDecoder().decode(LecturePlan.self, from: Data(contentsOf: planURL))
        let pcm = try plan.checkedPCM(at: planURL.deletingLastPathComponent())
        _ = try STTBenchmarkOutput(output)
        let session = STTSessionConfiguration(sessionID: SessionID(), operationID: STTOperationID(UUID()),
            model: STTModelConfiguration(engine: descriptor.engine, model: descriptor.model, options: options),
            languageMode: plan.languageMode)
        let trace = descriptor.engine == WhisperCppProfile.identity ? try NativeBenchmarkTrace(directory: output, repetition: 0) : nil
        let memory = FootprintSampler()
        var report = LectureRun(model: descriptor, settings: session, sourceSHA256: plan.sourceSHA256,
                                pcmSHA256: plan.pcmSHA256, frameCount: plan.frameCount,
                                baselinePhysicalFootprint: memory.baseline)
        let loadStarted = now
        do {
            try await engine.load(session.model)
            report.loadSeconds = now - loadStarted
            report.loadTiming = await engine.loadTiming()
            try await engine.start(session)
            for (index, window) in plan.windows.enumerated() {
                let row = await infer(engine, session, pcm, window, index)
                // Persist each completed attempt even if a later window or process fails.
                try BenchmarkMain.save(BenchmarkMain.json(row), to: output.appendingPathComponent("window-\(index).json"))
                if row.terminal?.kind == .final { report.completedWindows += 1 }
                try Task.checkCancellation()
            }
            try await engine.end()
        } catch {
            if report.loadSeconds == 0 { report.loadSeconds = now - loadStarted }
            report.failure = String(describing: error)
        }
        await engine.unload()
        report.peakPhysicalFootprint = memory.stop()
        report.warnings = await engine.cleanupDiagnostics.map { $0.code.rawValue }
        if memory.baseline == nil || report.peakPhysicalFootprint == nil { report.warnings.append("footprint unavailable") }
        report.effectiveCompute = try trace?.finish()
        try BenchmarkMain.save(BenchmarkMain.json(report), to: output.appendingPathComponent("run.json"))
        if report.failure != nil || report.completedWindows != plan.windows.count { throw STTEngineError(.inferenceFailed) }
    }

    private static func infer(_ engine: any BenchmarkIntervalEngine, _ session: STTSessionConfiguration, _ pcm: Data,
                              _ window: LecturePlan.Window, _ index: Int) async -> LectureWindowResult {
        var row = LectureWindowResult(index: index, window: window)
        do {
            let samples = pcm.withUnsafeBytes { bytes in
                Array(bytes.bindMemory(to: Float.self)[window.startFrame..<window.endFrame])
            }
            let request = try STTInferenceRequest(session: session, requestID: STTRequestID(UUID()), sequence: Int64(index),
                mediaStart: MediaMilliseconds(Int64((window.startFrame + 8) / 16)),
                audio: STTInferenceAudio(format: STTInputFormat(), frameCount: samples.count, samples: samples))
            let submitted = now
            defer { row.serviceSeconds = now - submitted }
            let feed = try await engine.infer(request)
            for await event in try feed.events() {
                if event.kind == .partial && row.firstPartialSeconds == nil { row.firstPartialSeconds = now - submitted }
                if event.isTerminal {
                    row.terminal = event
                    row.terminalSeconds = now - submitted
                }
            }
            if let timing = await engine.lastRequestTiming, timing.sequence == Int64(index) { row.timing = timing }
            if row.terminal?.kind != .final { row.failure = row.terminal?.failure?.code.rawValue ?? "missing final" }
        } catch { row.failure = String(describing: error) }
        return row
    }
}
