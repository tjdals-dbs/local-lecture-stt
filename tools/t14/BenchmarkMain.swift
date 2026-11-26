import AVFoundation
import CryptoKit
import Darwin
import Foundation

private struct NoSessionRoots: ModelReferenceChecking {
    func references(to descriptor: ModelPackageDescriptor) async -> ModelReferenceReport {
        .init(sessions: [], warnings: ["Disposable developer store; no session roots configured"])
    }
}
final class FootprintSampler: STTBenchmarkMemoryProbe, @unchecked Sendable {
    private let queue = DispatchQueue(label: "stt.benchmark.memory")
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var peak: UInt64?
    let baseline: UInt64?
    static func read() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
    init() {
        baseline = Self.read(); peak = baseline
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let value = Self.read() else { return }
            lock.withLock { peak = max(peak ?? value, value) }
        }
        timer.resume()
    }
    func stop() -> UInt64? {
        timer.cancel(); queue.sync {}
        let current = Self.read()
        return lock.withLock { [peak, current].compactMap { $0 }.max() }
    }
    deinit { timer.cancel() }
}

private final class BenchmarkNativeHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: AsyncStream<Void>.Continuation?
    private var observed = false

    func arm() -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { entry = pair.continuation; observed = false }
        return pair.stream
    }
    func entered() { lock.withLock { _ = entry?.yield(()) } }
    func aborted() { lock.withLock { if entry != nil { observed = true } } }
    func disarm() -> Bool {
        lock.withLock { entry?.finish(); entry = nil; return observed }
    }
}

/// Only the single-job benchmark executable owns stderr. The library exposes no
/// per-context device getter. Keep upstream diagnostics and classify actual load
/// evidence without installing a process-global ggml callback in either adapter.
final class NativeBenchmarkTrace {
    private let url: URL
    private var original: Int32
    init(directory: URL, repetition: Int) throws {
        url = directory.appendingPathComponent("native-\(repetition).log")
        let file = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard file >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(file) }
        original = dup(STDERR_FILENO)
        guard original >= 0 else { throw CocoaError(.fileWriteUnknown) }
        if dup2(file, STDERR_FILENO) < 0 {
            close(original); original = -1; throw CocoaError(.fileWriteUnknown)
        }
    }
    private func restore() {
        guard original >= 0 else { return }
        fflush(nil)
        _ = dup2(original, STDERR_FILENO)
        close(original); original = -1
    }
    deinit { restore() }

    func finish() throws -> String {
        restore()
        let log = try String(contentsOf: url, encoding: .utf8)
        if log.contains("whisper_backend_init_gpu: using MTL0 backend"),
           log.contains("ggml_metal_init: found device:"),
           !log.contains("failed to initialize MTL0 backend") {
            return "Metal (MTL0)" + (log.contains("using BLAS backend") ? " + Accelerate BLAS" : "")
        }
        if log.contains("no GPU found") || log.contains("failed to initialize MTL0 backend") {
            return "CPU fallback"
        }
        return "unavailable"
    }
}

@main
struct BenchmarkMain {
    static func main() async {
        do { try await execute(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8)); exit(1) }
    }
    static func url(_ value: String) -> URL { URL(fileURLWithPath: value) }
    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func save(_ bytes: Data, to path: URL) throws { try bytes.write(to: path, options: .withoutOverwriting) }
    static func hardware() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "; arm64; CPUs=\(ProcessInfo.processInfo.processorCount); physicalMemory=\(ProcessInfo.processInfo.physicalMemory)"
    }
    static func execute(_ args: [String]) async throws {
        guard let command = args.first else { throw STTEngineError(.invalidInput) }
        if command == "model-sandbox-probe" {
            try await ModelSandboxProbe.execute(Array(args.dropFirst()))
            return
        }
        if command == "recovery-probe" {
            try await RecoveryProbe.execute(Array(args.dropFirst()))
            return
        }
        if command == "prepare", args.count == 5 {
            let source = url(args[1]); let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.length > 0, file.length <= 480_000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw STTEngineError(.invalidInput)
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw STTEngineError(.invalidInput) }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let input = try STTBenchmarkInput(caseID: args[3], provenance: args[4],
                sourceSHA256: ModelPackageRules.sha256(Data(contentsOf: source)), pcmSHA256: STTBenchmarkInput.pcmDigest(samples),
                audio: STTInferenceAudio(format: STTInputFormat(), frameCount: samples.count, samples: samples),
                mediaStart: MediaMilliseconds(5000))
            try save(json(input), to: url(args[2])); print("Prepared \(samples.count) frames; \(input.pcmSHA256)"); return
        }
        guard (command == "import" && args.count == 4) || (command == "lecture" && args.count == 5) || ((command == "run" || command == "cancel" || command == "speech-replay") && (5...6).contains(args.count)) else {
            throw STTEngineError(.invalidInput)
        }
        let catalog = try JSONDecoder().decode(BundledModelCatalog.self, from: Data(contentsOf: url(args[1])))
        guard let descriptor = catalog.entries.first, catalog.entries.count == 1 else { throw ModelRepositoryCode.invalidDescriptor }
        let sources = ModelImportSources(); let store = url(command == "import" ? args[3] : args[2])
        let native = descriptor.engine == WhisperCppProfile.identity
        let validator: any OfflineModelFormatValidating
        switch (descriptor.engine, descriptor.format) {
        case (WhisperCppProfile.identity, WhisperCppProfile.format): validator = WhisperCppModelValidator()
        case (WhisperKitProfile.identity, WhisperKitProfile.format): validator = WhisperKitModelValidator()
        default: throw ModelRepositoryCode.incompatible
        }
        let repository = FileModelRepository(storeURL: { store }, sources: sources, validator: validator,
            references: NoSessionRoots(), catalogLoader: .init(load: { catalog }))
        if command == "import" {
            let source = await sources.register(url(args[2]), start: { true }, stop: {})
            let result = try await repository.importPackage(from: source, descriptor: descriptor, origin: .bundledCatalog)
            print(String(decoding: try json(result), as: UTF8.self)); return
        }
        let output = url(args[4])
        let options = try STTInferenceOptions(partialResults: true, timestamps: true, computeMode: descriptor.compute)
        let configuration = STTModelConfiguration(engine: descriptor.engine, model: descriptor.model, options: options)
        // Stream acknowledgements belong to this benchmark. Only the cancelled
        // repetition arms them; use the same engine for all three full lifecycles.
        let hooks = BenchmarkNativeHooks()
        let engine: any BenchmarkIntervalEngine
        if native {
            engine = try WhisperCppSTTEngine(resolve: { try await repository.acquireUseLease($0) }) {
                NativeWhisperBackend(encoderEntered: hooks.entered, abortObserved: hooks.aborted)
            }
        } else {
            engine = try WhisperKitSTTEngine(repository: repository)
        }
        if command == "lecture" {
            try await LectureBatch.measure(engine: engine, descriptor: descriptor, planURL: url(args[3]), options: options, output: output)
            return
        }
        let languageMode: LanguageMode
        if args.count == 5 { languageMode = .english }
        else if let selected = LanguageMode(rawValue: args[5]) { languageMode = selected }
        else { throw STTEngineError(.invalidConfiguration) }
        if command == "speech-replay" {
            try await SpeechReplayProbe.run(engine: engine,
                session: .init(sessionID: .init(), operationID: .init(UUID()), model: configuration, languageMode: languageMode),
                input: url(args[3]), output: output)
            return
        }
        let input = try JSONDecoder().decode(STTBenchmarkInput.self, from: Data(contentsOf: url(args[3])))
        guard STTBenchmarkInput.pcmDigest(input.audio.samples) == input.pcmSHA256 else { throw STTEngineError(.invalidInput) }
        let export = try STTBenchmarkOutput(output)
        var measurements: [STTBenchmarkMeasurement] = []
        var reportSession = STTSessionConfiguration(sessionID: SessionID(), operationID: STTOperationID(UUID()), model: configuration, languageMode: languageMode)
        var effective: [String] = []
        var cancellationVerified = true
        for repetition in 0...2 {
            let session = STTSessionConfiguration(sessionID: SessionID(), operationID: STTOperationID(UUID()), model: configuration, languageMode: languageMode)
            reportSession = session
            let cancelling = command == "cancel" && repetition == 1
            let entry = native && cancelling ? hooks.arm() : nil
            let trace = native ? try NativeBenchmarkTrace(directory: output, repetition: repetition) : nil
            let measurement = await STTBenchmarkRunner().measure(engine: engine, input: input, session: session,
                repetition: repetition, warmup: repetition == 0, cancelOnFirstPartial: !native && cancelling,
                cancelAtNativeEntry: entry,
                memory: FootprintSampler(), cleanupWarnings: { await engine.cleanupDiagnostics.map { "Cleanup: \($0.code.rawValue)" } }, observe: { (await engine.loadTiming(), await engine.lastRequestTiming) })
            if let trace { effective.append(try trace.finish()) }
            if native && cancelling {
                cancellationVerified = hooks.disarm()
                print("Native abort hook observed cancellation: \(cancellationVerified)")
            }
            measurements.append(measurement)
            print("Repetition \(repetition): terminal=\(measurement.terminal?.kind.rawValue ?? "missing") load=\(measurement.loadSeconds) inference=\(measurement.inferenceSeconds?.description ?? "null")")
            if measurement.failure != nil { break }
        }
        let success = cancellationVerified && measurements.count == 3 && measurements.allSatisfy { $0.failure == nil && $0.terminal != nil && $0.warnings.isEmpty }
        let report = STTBenchmarkReport(schemaVersion: 1, appVersion: native ? "0.1.0/T15-developer" : "0.1.0/T14-developer", os: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: hardware(),
            model: descriptor, input: input, settings: reportSession,
            policy: native ? "whisper.cpp v1.9.5/b5454 (ABI \(NativeWhisperBackend.libraryVersion)); GGML mixed F16/F32; embedded Metal, GPU preferred with CPU fallback; effective per repetition=\(effective.joined(separator: ", ")); four threads, flash attention, greedy best_of=1, no temperature fallback; explicit checked detection then transcribe; no implicit context, 223-token prompt cap; first partial is a complete native segment callback. Cancel-mode native abort observed=\(command == "cancel" ? String(cancellationVerified) : "not requested"). One warmup and two measured reloads. RTF=inferenceSeconds/audioSeconds." : "Float16 converted storage, no quantization. transcribe; sampleLength=224; promptLimit=111 tokens; automatic mode uses explicit checked detection, transcribe detectLanguage=false; topK=5; temperatureFallbackCount=0; wordTimestamps=false; no chunking; one decoder worker; prewarm=true. One warm-up excluded from throughput; two measured repetitions. Unload/reload each time. RTF=inferenceSeconds/audioSeconds; excludes load, prewarm, queue, warmup. Per-repetition values only; no aggregate speed/accuracy claim. First partial is buffered window-processing latency, not microphone utterance-end latency.",
            memoryMethod: "TASK_VM_INFO.phys_footprint, process-wide baseline before load and observed peak every 50 ms through unload, plus final sample; short peaks may be missed, OS CoreML caches may survive, GPU/ANE attribution is incomplete. Timer cancelled and queue joined on all paths.",
            measurements: measurements, success: success)
        try export.write(report)
        if !success { throw STTEngineError(.inferenceFailed) }
    }
}
