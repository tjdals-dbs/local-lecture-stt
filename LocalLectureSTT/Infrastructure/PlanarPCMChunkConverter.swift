import Foundation

/// Converts an audio tap's planar Float32 channels into the owned, frame-major application payload.
/// Keeping this free of AVFoundation makes the copy order and timestamp contract testable without hardware.
enum PlanarPCMChunkConverter {
    static func makeChunk(
        generation: UInt64,
        sequence: UInt64,
        sampleRate: Double,
        sourceSampleTime: Int64,
        planarSamples: [[Float]]
    ) throws -> PCMChunk {
        guard let frameCount = planarSamples.first?.count,
              frameCount > 0,
              !planarSamples.isEmpty,
              planarSamples.allSatisfy({ $0.count == frameCount }) else {
            throw CaptureError(.invalidPCM)
        }

        let format = try PCMFormatDescription(sampleRate: sampleRate, channelCount: planarSamples.count)
        var interleaved: [Float] = []
        interleaved.reserveCapacity(frameCount * planarSamples.count)
        for frame in 0 ..< frameCount {
            for channel in planarSamples.indices {
                interleaved.append(planarSamples[channel][frame])
            }
        }
        return try PCMChunk(
            generation: generation,
            sequence: sequence,
            format: format,
            frameCount: frameCount,
            sourceSampleTime: sourceSampleTime,
            samples: interleaved
        )
    }
}
