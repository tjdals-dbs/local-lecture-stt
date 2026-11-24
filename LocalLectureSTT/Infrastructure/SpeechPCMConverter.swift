import Foundation

/// Stateful conversion; output positions share the recorder's first captured
/// frame. A missing speech chunk leaves a time gap, never compresses the clock.
actor SpeechPCMConverter: SpeechPCMConverting {
    private var converter: AVAudioPCMConverter?
    private var format: PCMFormatDescription?
    private var expectedSource: Int64?
    private var outputFrame: Int64 = 0
    private var sourceEndFrame: Int64 = 0

    func convert(_ chunk: PCMChunk, origin: Int64) async throws -> [SpeechAudioBlock] {
        guard chunk.format.sampleRate <= 384_000, chunk.format.channelCount <= 32,
              chunk.frameCount <= Int(chunk.format.sampleRate * 30),
              chunk.sourceSampleTime >= origin,
              !chunk.sourceSampleTime.addingReportingOverflow(Int64(chunk.frameCount)).overflow else {
            throw STTEngineError(.invalidInput)
        }
        let start = Double(chunk.sourceSampleTime - origin) * 16_000 / chunk.format.sampleRate
        let end = start + Double(chunk.frameCount) * 16_000 / chunk.format.sampleRate
        guard end < Double(Int64.max), start.isFinite else { throw STTEngineError(.invalidInput) }
        // Device format changes belong to capture's terminal path.
        guard format == nil || format == chunk.format else { throw STTEngineError(.invalidInput) }
        guard expectedSource == nil || chunk.sourceSampleTime >= expectedSource! else {
            throw STTEngineError(.invalidInput)
        }
        var result: [SpeechAudioBlock] = []
        if converter == nil || expectedSource != chunk.sourceSampleTime {
            result += try await drain()
            converter = try AVAudioPCMConverter(source: chunk.format, outputSampleRate: 16_000)
            outputFrame = Int64(start.rounded())
        }
        format = chunk.format
        expectedSource = chunk.sourceSampleTime + Int64(chunk.frameCount)
        sourceEndFrame = Int64(end.rounded())
        if let converter {
            result += block(try await converter.convert(chunk))
        }
        return result
    }

    func drain() async throws -> [SpeechAudioBlock] {
        guard let previous = converter else { return [] }
        converter = nil
        return block(try await previous.drain())
    }

    private func block(_ samples: [Float]) -> [SpeechAudioBlock] {
        // A converter's final padding must not extend past captured media.
        let count = min(samples.count, Int(max(0, sourceEndFrame - outputFrame)))
        guard count > 0 else { return [] }
        let result = SpeechAudioBlock(samples: Array(samples.prefix(count)), startFrame: outputFrame)
        outputFrame += Int64(count)
        return [result]
    }
}
