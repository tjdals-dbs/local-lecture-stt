import AVFoundation
import CryptoKit
import Foundation

// Infrastructure-only seams. The same reader/writer/flush path runs in production and fault tests.
enum AudioMediaPoint: Sendable { case create, created, start, started, read, write, finish, decodeStart, decodeEnd, cleanup }
enum AudioMediaAwaitPoint: Sendable { case tracks, duration, formats, ready, finished }
protocol FinalizationMediaProcessing: Sendable {
    func inspect(_ url: URL, requiresM4A: Bool, control: AudioFinalizationControl) async throws -> AudioMediaReport
    func remux(_ files: FinalizationMediaFiles, control: AudioFinalizationControl) async throws
}

struct AVFoundationFinalizationMedia: FinalizationMediaProcessing {
    var fault: @Sendable (AudioMediaPoint, Int) throws -> Void = { _, _ in }
    var suspension: @Sendable (AudioMediaAwaitPoint) async throws -> Void = { _ in }

    func inspect(_ url: URL, requiresM4A: Bool, control: AudioFinalizationControl) async throws -> AudioMediaReport {
        try control.check()
        if requiresM4A { try validateContainer(url) }
        let asset = AVURLAsset(url: url)
        let (track, duration, _) = try await validatedTrack(asset)
        try control.check()
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioFinalizationCode.sourceUnreadable }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioFinalizationCode.invalidFormat }
        reader.add(output)
        guard reader.startReading() else { throw AudioFinalizationCode.sourceUnreadable }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var digest = SHA256()
        var packetCount = 0
        var byteCount: Int64 = 0
        var highWater = 0
        var start: Double?
        var end: Double?
        var maximumGap = 0.0
        // A single sample buffer plus a fixed hash scratch buffer; no duration-sized arrays.
        while true {
            let didRead: Bool = try autoreleasepool {
                try control.check()
                try fault(.read, packetCount)
                guard let sample = output.copyNextSampleBuffer() else { return false }
                if CMSampleBufferGetNumSamples(sample) == 0 {
                    guard CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0 == 0 else { throw AudioFinalizationCode.exportRead }
                    return true // AVAssetReader's payload-free boundary marker, not media.
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let storedLength = CMSampleBufferGetDuration(sample).seconds
                // Compressed AAC reader buffers may omit per-buffer duration. Each
                // validated LC packet contains exactly 1024 frames, independently of PTS.
                let length = storedLength.isFinite && storedLength > 0 ? storedLength : Double(CMSampleBufferGetNumSamples(sample) * 1024) / 48_000
                guard pts.isFinite, length.isFinite, length > 0 else { throw AudioFinalizationCode.invalidDuration }
                let packetDuration = 1024.0 / 48_000
                guard abs(length - Double(CMSampleBufferGetNumSamples(sample)) * packetDuration) <= 1.0 / 48_000 else {
                    throw AudioFinalizationCode.discontinuousTimeline
                }
                // Check inside multi-packet buffers as well as between buffers: a
                // sparse/edit-spliced sample table must not hide a gap in total duration.
                for index in 0..<CMSampleBufferGetNumSamples(sample) {
                    var timing = CMSampleTimingInfo()
                    guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr else {
                        throw AudioFinalizationCode.exportRead
                    }
                    if timing.presentationTimeStamp.isNumeric {
                        guard abs(timing.presentationTimeStamp.seconds - pts - Double(index) * packetDuration) <= 1.0 / 48_000 else {
                            throw AudioFinalizationCode.discontinuousTimeline
                        }
                    }
                    if timing.duration.isNumeric {
                        guard abs(timing.duration.seconds - packetDuration) <= 1.0 / 48_000 else {
                            throw AudioFinalizationCode.discontinuousTimeline
                        }
                    }
                }
                if let end {
                    let gap = pts - end
                    maximumGap = max(maximumGap, abs(gap))
                    guard abs(gap) <= 1.0 / 48_000 + 1e-7 else { throw AudioFinalizationCode.discontinuousTimeline }
                }
                if start == nil { start = pts }
                end = pts + length
                guard let block = CMSampleBufferGetDataBuffer(sample) else { throw AudioFinalizationCode.exportRead }
                let size = CMBlockBufferGetDataLength(block)
                guard size > 0, size <= 1_048_576 else { throw AudioFinalizationCode.invalidFormat }
                highWater = max(highWater, size)
                var offset = 0
                for index in 0..<CMSampleBufferGetNumSamples(sample) {
                    let packetSize = CMSampleBufferGetSampleSize(sample, at: index)
                    guard packetSize > 0, offset + packetSize <= size else { throw AudioFinalizationCode.exportRead }
                    var lengthPrefix = UInt64(packetSize).bigEndian
                    withUnsafeBytes(of: &lengthPrefix) { digest.update(bufferPointer: $0) }
                    var remaining = packetSize
                    var scratch = [UInt8](repeating: 0, count: min(packetSize, FinalizationFileAccess.bufferSize))
                    while remaining > 0 {
                        let count = min(remaining, scratch.count)
                        guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: count, destination: &scratch) == noErr else {
                            throw AudioFinalizationCode.exportRead
                        }
                        scratch.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                        remaining -= count
                        offset += count
                    }
                    packetCount += 1
                }
                guard offset == size else { throw AudioFinalizationCode.exportRead }
                byteCount += Int64(size)
                return true
            }
            if !didRead { break }
        }
        guard reader.status == .completed, reader.error == nil, packetCount > 0, let start, let end else {
            throw AudioFinalizationCode.exportRead
        }
        // AAC priming/padding can extend compressed coverage beyond the edit-list
        // presentation range. Internal continuity is strict; endpoints use 150 ms.
        guard start <= AudioFinalizationPolicy.durationToleranceSeconds,
              start >= -AudioFinalizationPolicy.durationToleranceSeconds,
              abs(end - duration) <= AudioFinalizationPolicy.durationToleranceSeconds else {
            throw AudioFinalizationCode.invalidDuration
        }
        let first = try decodeEndpoint(asset, track: track, duration: duration, isEnd: false, control: control)
        let last = try decodeEndpoint(asset, track: track, duration: duration, isEnd: true, control: control)
        return AudioMediaReport(durationSeconds: duration, sampleRate: 48_000, channels: 1, codec: "AAC-LC",
                                packetCount: packetCount, compressedBytes: byteCount,
                                payloadSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                                timelineStartSeconds: start, timelineEndSeconds: end, maximumGapSeconds: maximumGap,
                                bufferHighWaterBytes: highWater, first: first, last: last)
    }

    private func validatedTrack(_ asset: AVURLAsset, check: () throws -> Void = {},
                                afterLoad: (AudioMediaAwaitPoint) async throws -> Void = { _ in }) async throws -> (AVAssetTrack, Double, CMFormatDescription) {
        let tracks: [AVAssetTrack]
        let duration: Double
        do {
            tracks = try await asset.load(.tracks)
            try await afterLoad(.tracks); try check()
            duration = try await asset.load(.duration).seconds
            try await afterLoad(.duration); try check()
        } catch { throw FinalizationFileAccess.errorCode(error, fallback: .sourceUnreadable) }
        guard tracks.count == 1, let track = tracks.first, track.mediaType == .audio else {
            throw AudioFinalizationCode.invalidTracks
        }
        guard duration.isFinite, duration > 0 else { throw AudioFinalizationCode.invalidDuration }
        let formats: [CMFormatDescription]
        do {
            formats = try await track.load(.formatDescriptions)
            try await afterLoad(.formats); try check()
        } catch { throw FinalizationFileAccess.errorCode(error, fallback: .sourceUnreadable) }
        guard formats.count == 1, let format = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatMPEG4AAC,
              asbd.mFramesPerPacket == 1024,
              asbd.mSampleRate == 48_000, asbd.mChannelsPerFrame == 1 else {
            throw AudioFinalizationCode.invalidFormat
        }
        try validateAACConfiguration(format)
        return (track, duration, format)
    }

    private func decodeEndpoint(_ asset: AVURLAsset, track: AVAssetTrack, duration: Double,
                                isEnd: Bool, control: AudioFinalizationControl) throws -> AudioEndpointReport {
        try control.check()
        try fault(isEnd ? .decodeEnd : .decodeStart, 0)
        let window = min(0.25, duration)
        let requestedStart = isEnd ? duration - window : 0
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioFinalizationCode.decode }
        // A fresh reader with an actual end seek, never a full-file decode disguised as one.
        reader.timeRange = CMTimeRange(start: CMTime(seconds: requestedStart, preferredTimescale: 48_000),
                                      duration: CMTime(seconds: window, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw AudioFinalizationCode.decode }
        reader.add(output)
        guard reader.startReading() else { throw AudioFinalizationCode.decode }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var samples = 0, bytes = 0, crossings = 0
        var squareSum = 0.0
        var previous: Float?
        var start = Double.infinity, end = -Double.infinity
        while true {
            let didRead: Bool = try autoreleasepool {
                try control.check()
                guard let sample = output.copyNextSampleBuffer() else { return false }
                if CMSampleBufferGetNumSamples(sample) == 0 { return true }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { throw AudioFinalizationCode.decode }
                let count = CMBlockBufferGetDataLength(block)
                guard count > 0, count <= 1_048_576, count % 4 == 0 else { throw AudioFinalizationCode.decode }
                var pcm = [Float](repeating: 0, count: count / 4)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &pcm) == noErr else {
                    throw AudioFinalizationCode.decode
                }
                for value in pcm {
                    guard value.isFinite else { throw AudioFinalizationCode.decode }
                    squareSum += Double(value) * Double(value)
                    if let previous, (previous < 0) != (value < 0) { crossings += 1 }
                    previous = value
                }
                samples += CMSampleBufferGetNumSamples(sample)
                bytes += count
                let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
                let storedLength = CMSampleBufferGetOutputDuration(sample).seconds
                let length = storedLength.isFinite && storedLength > 0 ? storedLength : Double(CMSampleBufferGetNumSamples(sample)) / 48_000
                guard pts.isFinite, length.isFinite, length > 0 else { throw AudioFinalizationCode.decode }
                start = min(start, pts); end = max(end, pts + length)
                return true
            }
            if !didRead { break }
        }
        guard reader.status == .completed, reader.error == nil, samples > 0, bytes > 0,
              abs(start - requestedStart) <= 0.150, end >= requestedStart + window - 0.150,
              end <= duration + 0.150 else { throw AudioFinalizationCode.decode }
        return .init(sampleCount: samples, byteCount: bytes, startSeconds: start, endSeconds: end,
                     rms: sqrt(squareSum / Double(bytes / 4)), zeroCrossings: crossings)
    }

    func remux(_ files: FinalizationMediaFiles, control: AudioFinalizationControl) async throws {
        var ownedWriter: AVAssetWriter?
        var ownedReader: AVAssetReader?
        func check() throws { try control.check(); try files.validate() }
        do {
            try check()
            let asset = AVURLAsset(url: files.sourceURL)
            let (track, duration, format) = try await validatedTrack(asset, check: check, afterLoad: suspension)
            try check()
            try fault(.create, 0)
            try check()
            let writer: AVAssetWriter
            do { writer = try AVAssetWriter(outputURL: files.destinationURL, fileType: .m4a) }
            catch { throw FinalizationFileAccess.errorCode(error, fallback: .exportCreate) }
            ownedWriter = writer
            try fault(.created, 0)
            try check()
            // Apple's passthrough contract requires a source hint for non-QuickTime output.
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw AudioFinalizationCode.invalidFormat }
            writer.add(input)
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) } catch { throw AudioFinalizationCode.exportStart }
            ownedReader = reader
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AudioFinalizationCode.exportStart }
            reader.add(output)
            try fault(.start, 0)
            try check()
            guard writer.startWriting() else { throw AudioFinalizationCode.exportStart }
            writer.startSession(atSourceTime: .zero)
            try files.bindOutput()
            try check()
            guard reader.startReading() else { throw AudioFinalizationCode.exportStart }
            try fault(.started, 0)
            try check()
            var count = 0
            while true {
                try check()
                // A deterministic suspension seam also covers immediately-ready writers.
                try await suspension(.ready)
                try check()
                while !input.isReadyForMoreMediaData {
                    try check()
                    guard writer.status == .writing else {
                        throw FinalizationFileAccess.errorCode(writer.error ?? AudioFinalizationCode.exportWrite, fallback: .exportWrite)
                    }
                    try await Task.sleep(for: .milliseconds(2))
                    try check()
                }
                let didRead: Bool = try autoreleasepool {
                    try fault(.read, count)
                    try check()
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    if CMSampleBufferGetNumSamples(sample) == 0 { return true }
                    try fault(.write, count)
                    try check()
                    guard input.append(sample) else {
                        throw FinalizationFileAccess.errorCode(writer.error ?? AudioFinalizationCode.exportWrite, fallback: .exportWrite)
                    }
                    count += 1
                    return true
                }
                if !didRead { break }
            }
            guard reader.status == .completed, reader.error == nil, count > 0 else { throw AudioFinalizationCode.exportRead }
            try fault(.finish, count)
            try check()
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 48_000))
            input.markAsFinished()
            await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
            try await suspension(.finished)
            try check()
            guard writer.status == .completed else {
                throw FinalizationFileAccess.errorCode(writer.error ?? AudioFinalizationCode.exportFinish, fallback: .exportFinish)
            }
        } catch {
            // Fix the first cause before cleanup can suspend or receive cancellation.
            let first = FinalizationFileAccess.errorCode(error, fallback: .exportWrite)
            control.fail(first)
            do { try fault(.cleanup, 0) }
            catch { control.warning("mediaCleanup.\(FinalizationFileAccess.errorCode(error, fallback: .exportFinish).rawValue)") }
            if let reader = ownedReader, reader.status == .reading { reader.cancelReading() }
            if let writer = ownedWriter, writer.status == .writing {
                // cancelWriting deletes by output pathname. Finish the already-open
                // writer instead, preserving partial output and any replacement file.
                await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
                if writer.status == .failed {
                    control.warning("mediaCleanup.\(FinalizationFileAccess.errorCode(writer.error ?? AudioFinalizationCode.exportFinish, fallback: .exportFinish).rawValue)")
                }
            }
            // An unknown writer has not started asynchronous writing. Releasing it
            // closes its resources without a pathname-based cancel/delete operation.
            ownedReader = nil
            ownedWriter = nil
            throw first
        }
    }

    private func validateContainer(_ url: URL) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw AudioFinalizationCode.sourceUnreadable }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 64) ?? Data()
        guard bytes.count >= 16, String(data: bytes[4..<8], encoding: .ascii) == "ftyp",
              String(data: bytes[8..<12], encoding: .ascii) == "M4A " else { throw AudioFinalizationCode.invalidContainer }
    }

    private func validateAACConfiguration(_ format: CMFormatDescription) throws {
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), size > 0, size <= 4096 else {
            throw AudioFinalizationCode.invalidFormat
        }
        let bytes = Array(UnsafeRawBufferPointer(start: cookie, count: size))
        // ISO/IEC 14496-1 ES_Descriptor -> DecoderConfigDescriptor -> DecoderSpecificInfo.
        // Descriptor lengths are up to four 7-bit continuation octets, not fixed offsets.
        func specific(_ lower: Int, _ upper: Int) -> [UInt8]? {
            var cursor = lower
            while cursor < upper {
                let tag = bytes[cursor]; cursor += 1
                var length = 0, terminated = false
                for _ in 0..<4 {
                    guard cursor < upper else { return nil }
                    let byte = bytes[cursor]; cursor += 1
                    length = (length << 7) | Int(byte & 0x7f)
                    if byte & 0x80 == 0 { terminated = true; break }
                }
                guard terminated, cursor + length <= upper else { return nil }
                let end = cursor + length
                if tag == 5 { return Array(bytes[cursor..<end]) }
                if tag == 3 {
                    guard length >= 3 else { return nil }
                    let flags = bytes[cursor + 2]; var nested = cursor + 3
                    if flags & 0x80 != 0 { nested += 2 }
                    if flags & 0x40 != 0 {
                        guard nested < end else { return nil }; nested += 1 + Int(bytes[nested])
                    }
                    if flags & 0x20 != 0 { nested += 2 }
                    if nested <= end, let result = specific(nested, end) { return result }
                } else if tag == 4, length >= 13 {
                    guard bytes[cursor] == 0x40 else { return nil }
                    if let result = specific(cursor + 13, end) { return result }
                }
                cursor = end
            }
            return nil
        }
        guard let config = specific(0, bytes.count), config.count >= 2 else { throw AudioFinalizationCode.invalidFormat }
        let objectType = config[0] >> 3
        let frequencyIndex = ((config[0] & 7) << 1) | (config[1] >> 7)
        let channels = (config[1] >> 3) & 15
        guard objectType == 2, frequencyIndex == 3, channels == 1 else { throw AudioFinalizationCode.invalidFormat }
    }
}
