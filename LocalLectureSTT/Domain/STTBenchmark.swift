import Foundation

/// Portable canonical PCM plan. T15 consumes these exact samples/windows, never another file decoder.
struct STTBenchmarkInput: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let caseID: String
    let provenance: String
    let sourceSHA256: String
    let pcmSHA256: String
    let audio: STTInferenceAudio
    let mediaStart: MediaMilliseconds
    let hints: STTDecodingHints?
    init(caseID: String, provenance: String, sourceSHA256: String, pcmSHA256: String,
         audio: STTInferenceAudio, mediaStart: MediaMilliseconds, hints: STTDecodingHints? = nil) throws {
        try ModelPackageRules.digest(sourceSHA256); try ModelPackageRules.digest(pcmSHA256)
        guard !caseID.isEmpty, caseID.utf8.count <= 128, !provenance.isEmpty, provenance.utf8.count <= 4096,
              audio.format == (try STTInputFormat()), pcmSHA256 == Self.pcmDigest(audio.samples) else { throw STTEngineError(.invalidInput) }
        schemaVersion = 1; self.caseID = caseID; self.provenance = provenance
        self.sourceSHA256 = sourceSHA256; self.pcmSHA256 = pcmSHA256; self.audio = audio
        self.mediaStart = mediaStart; self.hints = hints
    }
    /// SHA256 over little-endian IEEE754 Float32 bit patterns, frame-major mono 16 kHz.
    static func pcmDigest(_ samples: [Float]) -> String {
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return ModelPackageRules.sha256(data)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw STTEngineError(.invalidInput) }
        try self.init(caseID: c.decode(String.self, forKey: .caseID), provenance: c.decode(String.self, forKey: .provenance),
            sourceSHA256: c.decode(String.self, forKey: .sourceSHA256), pcmSHA256: c.decode(String.self, forKey: .pcmSHA256),
            audio: c.decode(STTInferenceAudio.self, forKey: .audio), mediaStart: c.decode(MediaMilliseconds.self, forKey: .mediaStart),
            hints: c.decodeIfPresent(STTDecodingHints.self, forKey: .hints))
    }
}
struct STTBenchmarkMeasurement: Codable, Sendable, Equatable {
    let repetition: Int
    let warmup: Bool
    let loadSeconds: Double
    let prewarmSeconds: Double?
    let modelLoadSeconds: Double?
    let queueSeconds: Double?
    let inferenceSeconds: Double?
    let finalSeconds: Double?
    let firstPartialSeconds: Double?
    let rtf: Double?
    let baselinePhysicalFootprint: UInt64?
    let peakPhysicalFootprint: UInt64?
    let terminal: STTResponse?
    let failure: STTEngineError?
    let warnings: [String]
    static func rtf(processing: Double?, audio: Double) -> Double? {
        guard let processing, processing.isFinite, processing >= 0, audio.isFinite, audio > 0 else { return nil }
        return processing / audio
    }
}
struct STTBenchmarkReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let appVersion: String
    let os: String
    let hardware: String
    let model: ModelPackageDescriptor
    let input: STTBenchmarkInput
    let settings: STTSessionConfiguration
    let policy: String
    let memoryMethod: String
    let measurements: [STTBenchmarkMeasurement]
    let success: Bool
}

struct STTBenchmarkLoadTiming: Codable, Sendable, Equatable {
    let prewarmSeconds: Double?
    let modelSeconds: Double?
}
struct STTBenchmarkRequestTiming: Codable, Sendable, Equatable {
    let sequence: Int64
    let queueSeconds: Double
    let inferenceSeconds: Double
}
