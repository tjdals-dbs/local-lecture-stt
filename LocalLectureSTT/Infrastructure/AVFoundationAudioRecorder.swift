@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia
import Foundation

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var source: AVAudioPCMBuffer?

    init(_ source: AVAudioPCMBuffer) { self.source = source }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { source = nil }
            return source
        }
    }
}

/// The concrete recovery sink. This actor is the only owner of AVFoundation
/// writer/converter objects, sequence validation, and the scoped write lease.
actor AVFoundationAudioRecorder: AudioRecorder {
    private let roots: StorageRootManager
    private var state: AudioRecorderState = .idle
    private var eventContinuation: AsyncStream<AudioRecorderEvent>.Continuation?
    private var eventStream: AsyncStream<AudioRecorderEvent>?
    private var lease: StorageRootWriteLease?
    private var location: SessionLocation?
    private var expectedGeneration: UInt64 = 0
    private var expectedSequence: UInt64 = 0
    private var sourceFormat: PCMFormatDescription?
    private var converter: AVAudioConverter?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var linearPCMFormat: CMAudioFormatDescription?
    private var writtenFrames: UInt64 = 0
    private var terminalError: AudioRecorderError?
    private var didEmitTerminalEvent = false
    private var didMarkInputFinished = false

    init(roots: StorageRootManager) { self.roots = roots }

    func currentState() -> AudioRecorderState { state }

    func events() -> AsyncStream<AudioRecorderEvent> {
        if let eventStream { return eventStream }
        var continuation: AsyncStream<AudioRecorderEvent>.Continuation!
        let stream = AsyncStream<AudioRecorderEvent>(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        eventContinuation = continuation
        eventStream = stream
        return stream
    }

    func start(at location: SessionLocation, expectedCaptureGeneration: UInt64) async throws {
        switch state {
        case .idle, .completed, .failed: break
        case .starting, .recording, .stopping: throw AudioRecorderError(.alreadyStarted)
        }
        resetForStart(location: location, generation: expectedCaptureGeneration)
        state = .starting
        do {
            let acquiredLease = try await roots.acquireWriteLease(to: location.rootID)
            lease = acquiredLease
            let outputURL = try validatedRecoveryURL(for: location, rootURL: acquiredLease.rootURL)
            let configured = try makeWriter(outputURL: outputURL)
            writer = configured.writer
            input = configured.input
            guard configured.writer.startWriting(), configured.writer.status == .writing else {
                throw AudioRecorderError(.writerStartFailed)
            }
            configured.writer.startSession(atSourceTime: .zero)
            state = .recording
        } catch let error as AudioRecorderError {
            await failStart(error)
            throw error
        } catch is StorageError {
            let typed = AudioRecorderError(.storageAccess)
            await failStart(typed)
            throw typed
        } catch {
            let typed = AudioRecorderError(.writerConfigurationFailed)
            await failStart(typed)
            throw typed
        }
    }

    func append(_ chunk: PCMChunk) async throws {
        try ensureRecording()
        guard chunk.generation == expectedGeneration else { throw await fail(AudioRecorderError(.inputGenerationMismatch)) }
        guard chunk.sequence == expectedSequence else { throw await fail(AudioRecorderError(.sequenceDiscontinuity)) }
        guard let sourceFormat else {
            self.sourceFormat = chunk.format
            converter = try makeConverter(source: chunk.format)
            linearPCMFormat = try makeLinearPCMFormat()
            return try await appendConverted(chunk)
        }
        guard sourceFormat == chunk.format else { throw await fail(AudioRecorderError(.inputFormatChanged)) }
        try await appendConverted(chunk)
    }

    /// A conversion/append barrier. It intentionally does not claim fragment
    /// durability and never uses AVAssetWriter.flushSegment().
    func flush() async throws {
        try ensureRecording()
        guard writer?.status == .writing else { throw await fail(AudioRecorderError(.flushFailed)) }
    }

    func stop() async throws -> AudioRecorderSummary {
        if case let .completed(summary) = state { return summary }
        if case let .failed(code) = state { throw terminalError ?? AudioRecorderError(code) }
        guard case .recording = state else { throw AudioRecorderError(.invalidLifecycle) }
        state = .stopping
        do {
            guard writtenFrames > 0 else { throw AudioRecorderError(.noAudioSamples) }
            try await appendConverterTail()
            try await finishWriter()
            guard let location else { throw AudioRecorderError(.invalidLifecycle) }
            let summary = AudioRecorderSummary(
                location: location,
                artifact: .recoveryAudio,
                writtenFrameCount: writtenFrames,
                mediaDurationMilliseconds: writtenFrames.multipliedReportingOverflow(by: 1_000).partialValue / 48_000,
                outputFormat: .recoveryAAC
            )
            state = .completed(summary)
            await releaseLease()
            return summary
        } catch let error as AudioRecorderError {
            throw await fail(error)
        } catch {
            throw await fail(AudioRecorderError(.writerFinishFailed))
        }
    }

    private func resetForStart(location: SessionLocation, generation: UInt64) {
        self.location = location
        expectedGeneration = generation
        expectedSequence = 0
        sourceFormat = nil
        converter = nil
        writer = nil
        input = nil
        linearPCMFormat = nil
        writtenFrames = 0
        terminalError = nil
        didEmitTerminalEvent = false
        didMarkInputFinished = false
    }

    private func ensureRecording() throws {
        guard case .recording = state else { throw terminalError ?? AudioRecorderError(.invalidLifecycle) }
    }

    private func validatedRecoveryURL(for location: SessionLocation, rootURL: URL) throws -> URL {
        let manager = FileManager.default
        let session = rootURL.appendingPathComponent(location.folderName.rawValue, isDirectory: true)
        let recovery = session.appendingPathComponent("recovery", isDirectory: true)
        for directory in [session, recovery] {
            guard manager.fileExists(atPath: directory.path),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw AudioRecorderError(.unsafeSessionLayout)
            }
        }
        let destination = recovery.appendingPathComponent(SessionArtifact.recoveryAudio.relativePath.split(separator: "/").last.map(String.init) ?? "audio.recovery.mov")
        guard !manager.fileExists(atPath: destination.path) else { throw AudioRecorderError(.recoveryArtifactExists) }
        return destination
    }

    private func makeWriter(outputURL: URL) throws -> (writer: AVAssetWriter, input: AVAssetWriterInput) {
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov) }
        catch { throw AudioRecorderError(.writerConfigurationFailed) }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 48_000)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 48_000)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AudioRecorderError(.writerConfigurationFailed) }
        writer.add(input)
        return (writer, input)
    }

    private func makeConverter(source: PCMFormatDescription) throws -> AVAudioConverter {
        guard source.channelCount <= 32 else { throw AudioRecorderError(.inputFormatUnsupported) }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: AVAudioChannelCount(source.channelCount), interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError(.inputFormatUnsupported)
        }
        return converter
    }

    private func makeLinearPCMFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw AudioRecorderError(.conversionFailed) }
        return description
    }

    private func appendConverted(_ chunk: PCMChunk) async throws {
        guard let converter else { throw AudioRecorderError(.conversionFailed) }
        let converted = try convert(chunk, with: converter)
        expectedSequence = expectedSequence &+ 1
        try await appendOutputSamples(converted)
    }

    private func convert(_ chunk: PCMChunk, with converter: AVAudioConverter) throws -> [Float] {
        guard let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount)) else {
            throw AudioRecorderError(.conversionFailed)
        }
        source.frameLength = AVAudioFrameCount(chunk.frameCount)
        guard let destination = source.audioBufferList.pointee.mBuffers.mData else { throw AudioRecorderError(.conversionFailed) }
        _ = chunk.samples.withUnsafeBytes { bytes in memcpy(destination, bytes.baseAddress!, bytes.count) }
        let capacityDouble = (Double(chunk.frameCount) * 48_000 / chunk.format.sampleRate).rounded(.up) + 4_096
        guard capacityDouble.isFinite, capacityDouble > 0, capacityDouble <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(capacityDouble)) else {
            throw AudioRecorderError(.conversionFailed)
        }
        let inputBox = ConverterInputBox(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let next = inputBox.take() else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            return next
        }
        guard (status == .haveData || status == .inputRanDry || status == .endOfStream), conversionError == nil else {
            throw AudioRecorderError(.conversionFailed)
        }
        return copiedSamples(from: output)
    }

    private func appendConverterTail() async throws {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096) else { return }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard (status == .haveData || status == .endOfStream || status == .inputRanDry), conversionError == nil else {
            throw AudioRecorderError(.conversionFailed)
        }
        let tail = copiedSamples(from: output)
        if !tail.isEmpty { try await appendOutputSamples(tail) }
    }

    private func copiedSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let pointer = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self), count: Int(buffer.frameLength)))
    }

    private func appendOutputSamples(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let input, let writer, let linearPCMFormat else { throw AudioRecorderError(.writerAppendFailed) }
        try await waitUntilReady(input: input, writer: writer)
        let sample = try makeSampleBuffer(samples: samples, format: linearPCMFormat, presentationFrame: writtenFrames)
        guard input.append(sample) else { throw AudioRecorderError(mapWriterFailure(writer, fallback: .writerAppendFailed)) }
        let result = writtenFrames.addingReportingOverflow(UInt64(samples.count))
        guard !result.overflow else { throw AudioRecorderError(.writerAppendFailed) }
        writtenFrames = result.partialValue
    }

    private func waitUntilReady(input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        for _ in 0..<5_000 {
            if input.isReadyForMoreMediaData { return }
            guard writer.status == .writing else { throw AudioRecorderError(mapWriterFailure(writer, fallback: .writerAppendFailed)) }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AudioRecorderError(.writerAppendFailed)
    }

    private func makeSampleBuffer(samples: [Float], format: CMAudioFormatDescription, presentationFrame: UInt64) throws -> CMSampleBuffer {
        let byteCount = samples.count.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !byteCount.overflow, presentationFrame <= UInt64(Int64.max) else { throw AudioRecorderError(.conversionFailed) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount.partialValue, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount.partialValue, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw AudioRecorderError(.conversionFailed) }
        let replacement = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount.partialValue)
        }
        guard replacement == kCMBlockBufferNoErr else { throw AudioRecorderError(.conversionFailed) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(presentationFrame), timescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample else { throw AudioRecorderError(.conversionFailed) }
        return sample
    }

    private func finishWriter() async throws {
        guard let writer, let input else { throw AudioRecorderError(.writerFinishFailed) }
        if !didMarkInputFinished { input.markAsFinished(); didMarkInputFinished = true }
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw AudioRecorderError(mapWriterFailure(writer, fallback: .writerFinishFailed)) }
    }

    private func mapWriterFailure(_ writer: AVAssetWriter, fallback: AudioRecorderErrorCode) -> AudioRecorderErrorCode {
        if let error = writer.error as NSError?, error.domain == NSPOSIXErrorDomain, error.code == ENOSPC { return .diskFull }
        return fallback
    }

    private func failStart(_ error: AudioRecorderError) async {
        terminalError = error
        state = .failed(error.code)
        emitTerminal(error)
        await releaseLease()
    }

    private func fail(_ error: AudioRecorderError) async -> AudioRecorderError {
        if let terminalError { return terminalError }
        terminalError = error
        state = .failed(error.code)
        emitTerminal(error)
        if let input, !didMarkInputFinished { input.markAsFinished(); didMarkInputFinished = true }
        if let writer, writer.status == .writing { await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } } }
        await releaseLease()
        return error
    }

    private func emitTerminal(_ error: AudioRecorderError) {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        let kind: SessionEventKind = error.code == .storageAccess || error.code == .unsafeSessionLayout || error.code == .recoveryArtifactExists ? .storageAccessError : .fileWriteError
        let milliseconds = writtenFrames.multipliedReportingOverflow(by: 1_000).partialValue / 48_000
        eventContinuation?.yield(.terminalFailure(kind: kind, code: error.code, mediaPositionMilliseconds: milliseconds))
    }

    private func releaseLease() async {
        let oldLease = lease
        lease = nil
        await oldLease?.release()
    }
}
