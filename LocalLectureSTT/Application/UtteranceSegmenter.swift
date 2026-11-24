import Foundation

/// Receives contiguous frames of 16 kHz mono PCM (20 ms, or a shorter final frame).
protocol VoiceActivityDetector: Sendable {
    mutating func isSpeech(_ frame: [Float]) -> Bool
    mutating func reset()
}

struct AdaptiveEnergyVAD: VoiceActivityDetector {
    private var noisePower = 0.004 * 0.004
    private var previousBins: [Double] = []
    private var previousFrameWasPeriodic = false

    mutating func isSpeech(_ frame: [Float]) -> Bool {
        guard let first = frame.first else { return false }
        var energy = 0.0
        var differenceEnergy = 0.0
        var previous = Double(first)
        for sample in frame {
            let value = Double(sample)
            energy += value * value
            let difference = value - previous
            differenceEnergy += difference * difference
            previous = value
        }
        let power = energy / Double(frame.count)
        // White noise has about twice its signal power in the first difference.
        // Low-pass noise can have the energy and slope of a vowel, but lacks its periodicity.
        let broadband = differenceEnergy > 1.6 * energy
        let aboveBackground = power > noisePower * 6.25
        let voiced: Bool
        if power > 0.008 * 0.008 && !broadband {
            let threshold = aboveBackground ? 0.76 : 0.82
            // A strong voiced frame can start an utterance immediately. Weaker
            // periodicity needs a second frame because noise can correlate by chance.
            let onsetThreshold = previousFrameWasPeriodic ? threshold : 0.94
            let correlation = voicedCorrelation(frame, stopAt: onsetThreshold)
            voiced = correlation >= onsetThreshold
            previousFrameWasPeriodic = correlation >= threshold
        } else {
            previousBins.removeAll(keepingCapacity: true)
            previousFrameWasPeriodic = false
            voiced = false
        }
        if power < noisePower {
            noisePower = max(0.001 * 0.001, noisePower + 0.12 * (power - noisePower))
        } else if !voiced {
            // Limit adaptation during short unvoiced consonants. A clear periodic signal
            // can still be heard when its energy is close to the estimated background.
            noisePower += 0.06 * (min(power, 2 * noisePower) - noisePower)
        }
        return voiced
    }

    private mutating func voicedCorrelation(_ frame: [Float], stopAt threshold: Double) -> Double {
        // Sum four samples per bin (4 kHz) and remove DC before autocorrelation.
        var bins: [Double] = []
        bins.reserveCapacity(frame.count / 4)
        for i in stride(from: 0, to: frame.count - 3, by: 4) {
            bins.append(Double(frame[i]) + Double(frame[i + 1]) + Double(frame[i + 2]) + Double(frame[i + 3]))
        }
        guard !bins.isEmpty else { return 0 }
        let mean = bins.reduce(0, +) / Double(bins.count)
        for i in bins.indices { bins[i] -= mean }

        let frameStart = previousBins.count
        let signal = previousBins + bins
        previousBins = bins
        // Require a full period of comparison and a meaningful number of samples.
        // History supplies the delayed reference for lower pitches on 20 ms frames.
        let maximumLag = min(62, bins.count, signal.count / 2, signal.count - 32)
        guard maximumLag >= 8, bins.count >= 32 else { return 0 }
        // Look for a return to positive correlation, not just adjacent samples on a slow slope.
        var passedTrough = false
        var best = 0.0
        for lag in 1...maximumLag {
            var cross = 0.0, power = 0.0
            // Prefer the current frame when it contains enough pairs. Voicing/onset
            // and pitch may change at the boundary of the preceding frame.
            let begin = bins.count - lag >= max(32, lag) ? frameStart + lag : max(frameStart, lag)
            for i in begin..<signal.count {
                let a = signal[i - lag], b = signal[i]
                cross += a * b
                power += a * a + b * b
            }
            if cross <= 0 { passedTrough = true }
            guard passedTrough, lag >= 8, cross > 0 else { continue }
            best = max(best, 2 * cross / power)
            if best >= threshold { break }
        }
        return best
    }

    mutating func reset() { self = Self() }
}

enum SpeechWindowBoundary: Sendable {
    case open, silence, maximumDuration, flush, discontinuity
}

struct SpeechWindow: Sendable {
    let startFrame: Int64
    let overlapFrames: Int
    let audio: STTInferenceAudio
    let mediaStart: MediaMilliseconds
    let boundary: SpeechWindowBoundary

    var endFrame: Int64 { startFrame + Int64(audio.frameCount) }

    fileprivate init(samples: [Float], endingAt end: Int64, overlapFrames: Int,
                     boundary: SpeechWindowBoundary) throws {
        self.audio = try STTInferenceAudio(format: STTInputFormat(), frameCount: samples.count, samples: samples)
        self.startFrame = end - Int64(samples.count)
        // Match STTInferenceAudio's nearest millisecond without rounding the running clock.
        self.mediaStart = try MediaMilliseconds(startFrame / 16 + (startFrame % 16 >= 8 ? 1 : 0))
        self.overlapFrames = overlapFrames
        self.boundary = boundary
    }
}

/// One instance per session. Only the speech consumer supplies resampled mono samples.
/// All buffer sizes and offsets are in frames on the recorded media timeline.
struct UtteranceSegmenter: Sendable {
    private static let analysisFrames = 320
    private static let prefixFrames = 4_800
    private static let silenceFrames = 12_800
    private static let maximumFrames = 320_000
    private static let overlapFrames = 16_000

    private var detector: any VoiceActivityDetector
    private var pending: [Float] = []
    private var buffer: [Float] = []  // idle prefix, or the current utterance
    private var analyzedEnd: Int64 = 0
    private var nextFrame: Int64?
    private var lastSpeechEnd: Int64?
    private var overlap = 0

    init(detector: any VoiceActivityDetector = AdaptiveEnergyVAD()) {
        self.detector = detector
    }

    mutating func append(_ samples: [Float], at startFrame: Int64) throws -> [SpeechWindow] {
        let (end, overflow) = startFrame.addingReportingOverflow(Int64(samples.count))
        guard !overflow, startFrame >= 0, startFrame >= (nextFrame ?? 0), !samples.isEmpty,
              samples.allSatisfy(\.isFinite) else { throw STTEngineError(.invalidInput) }

        var windows: [SpeechWindow] = []
        if nextFrame != startFrame {
            if nextFrame != nil { windows = try drain(.discontinuity) }
            analyzedEnd = startFrame
        }
        nextFrame = end
        var offset = 0
        while offset < samples.count {
            let count = min(Self.analysisFrames - pending.count, samples.count - offset)
            pending.append(contentsOf: samples[offset..<(offset + count)])
            offset += count
            if pending.count == Self.analysisFrames {
                try analyzePending(into: &windows)
            }
        }
        return windows
    }

    /// T19 may sample this for partial inference. Reading it never advances the segmenter.
    func openWindow() throws -> SpeechWindow? { try window(.open) }

    /// Stop or pause flushes even a partial analysis frame, without padding recorded time.
    mutating func flush() throws -> [SpeechWindow] { try drain(.flush) }

    private mutating func drain(_ boundary: SpeechWindowBoundary) throws -> [SpeechWindow] {
        var windows: [SpeechWindow] = []
        if !pending.isEmpty { try analyzePending(into: &windows) }
        if let final = try window(boundary) { windows.append(final) }
        lastSpeechEnd = nil
        overlap = 0
        buffer.removeAll(keepingCapacity: false)
        detector.reset()
        return windows
    }

    private func window(_ boundary: SpeechWindowBoundary) throws -> SpeechWindow? {
        let start = analyzedEnd - Int64(buffer.count)
        // Copied overlap alone carries no new speech. T11 requires at least one rounded ms.
        guard let lastSpeechEnd, lastSpeechEnd > start + Int64(overlap), buffer.count >= 8 else { return nil }
        return try SpeechWindow(samples: buffer, endingAt: analyzedEnd, overlapFrames: overlap, boundary: boundary)
    }

    private mutating func analyzePending(into windows: inout [SpeechWindow]) throws {
        analyzedEnd += Int64(pending.count)
        let voiced = detector.isSpeech(pending)
        buffer.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if voiced { lastSpeechEnd = analyzedEnd }
        guard let speechEnd = lastSpeechEnd else {
            if buffer.count > Self.prefixFrames { buffer.removeFirst(buffer.count - Self.prefixFrames) }
            return
        }
        if analyzedEnd - speechEnd >= Self.silenceFrames {
            if let final = try window(.silence) { windows.append(final) }
            buffer = Array(buffer.suffix(Self.prefixFrames))
            lastSpeechEnd = nil
            overlap = 0
        } else if buffer.count == Self.maximumFrames {
            if let final = try window(.maximumDuration) { windows.append(final) }
            buffer = Array(buffer.suffix(Self.overlapFrames))
            overlap = buffer.count
        }
    }
}
