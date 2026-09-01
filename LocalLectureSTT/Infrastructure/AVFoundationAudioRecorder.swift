@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreMedia
import Foundation

// MARK: - Infrastructure-only seams

struct RecoveryAudioWriterConfiguration: Sendable, Equatable {
    let sampleRate: Int
    let channelCount: Int
    let targetBitRate: Int
    let initialFragmentSeconds: Double
    let subsequentFragmentSeconds: Double

    static let production = RecoveryAudioWriterConfiguration(
        sampleRate: 48_000,
        channelCount: 1,
        targetBitRate: 96_000,
        initialFragmentSeconds: 1,
        subsequentFragmentSeconds: 10
    )
}

protocol RecoveryAudioOutputLease: Sendable {
    var outputURL: URL { get }
    func release() async
}

protocol RecoveryAudioOutputLeaseProviding: Sendable {
    func acquire(for location: SessionLocation) async throws -> any RecoveryAudioOutputLease
}

protocol RecoveryAudioWriterBackend: Sendable {
    func startWriting() async throws
    func startSession() async throws
    func append(samples: [Float], presentationFrame: UInt64) async throws
    func flushBarrier() async throws
    func markInputFinished() async
    func finishWriting() async throws
}

protocol RecoveryAudioWriterBackendFactory: Sendable {
    func makeWriter(
        outputURL: URL,
        configuration: RecoveryAudioWriterConfiguration
    ) throws -> any RecoveryAudioWriterBackend
}

protocol RecoveryAudioPCMConverting: Sendable {
    func convert(_ chunk: PCMChunk) async throws -> [Float]
    func drain() async throws -> [Float]
}

protocol RecoveryAudioPCMConverterFactory: Sendable {
    func makeConverter(source: PCMFormatDescription) throws -> any RecoveryAudioPCMConverting
}

private final class ScopedRecoveryAudioOutputLease: RecoveryAudioOutputLease, @unchecked Sendable {
    let outputURL: URL
    private let rootLease: StorageRootWriteLease

    init(outputURL: URL, rootLease: StorageRootWriteLease) {
        self.outputURL = outputURL
        self.rootLease = rootLease
    }

    func release() async {
        await rootLease.release()
    }
}

struct StorageRecoveryAudioOutputLeaseProvider: RecoveryAudioOutputLeaseProviding {
    let roots: StorageRootManager

    func acquire(for location: SessionLocation) async throws -> any RecoveryAudioOutputLease {
        let rootLease = try await roots.acquireWriteLease(to: location.rootID)
        do {
            let outputURL = try Self.validatedRecoveryURL(for: location, rootURL: rootLease.rootURL)
            return ScopedRecoveryAudioOutputLease(outputURL: outputURL, rootLease: rootLease)
        } catch {
            await rootLease.release()
            throw error
        }
    }

    private static func validatedRecoveryURL(for location: SessionLocation, rootURL: URL) throws -> URL {
        let manager = FileManager.default
        let session = rootURL.appendingPathComponent(location.folderName.rawValue, isDirectory: true)
        let recovery = session.appendingPathComponent("recovery", isDirectory: true)

        for directory in [session, recovery] {
            guard manager.fileExists(atPath: directory.path) else {
                throw AudioRecorderError(.unsafeSessionLayout)
            }
            let values: URLResourceValues
            do {
                values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw AudioRecorderError(.unsafeSessionLayout)
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AudioRecorderError(.unsafeSessionLayout)
            }
        }

        let destination = recovery.appendingPathComponent("audio.recovery.mov", isDirectory: false)
        if (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            throw AudioRecorderError(.unsafeSessionLayout)
        }
        guard !manager.fileExists(atPath: destination.path) else {
            throw AudioRecorderError(.recoveryArtifactExists)
        }
        return destination
    }
}

// MARK: - AVAudioConverter adapter

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var source: AVAudioPCMBuffer?

    init(_ source: AVAudioPCMBuffer?) {
        self.source = source
    }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { source = nil }
            return source
        }
    }
}

struct AVAudioPCMConverterFactory: RecoveryAudioPCMConverterFactory {
    func makeConverter(source: PCMFormatDescription) throws -> any RecoveryAudioPCMConverting {
        try AVAudioPCMConverter(source: source)
    }
}

actor AVAudioPCMConverter: RecoveryAudioPCMConverting {
    private let converter: AVAudioConverter
    private let sourceDescription: PCMFormatDescription
    private var drained = false

    init(source: PCMFormatDescription) throws {
        guard source.layout == .float32Interleaved, source.channelCount <= 32 else {
            throw AudioRecorderError(.inputFormatUnsupported)
        }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.sampleRate,
            channels: 1,
            interleaved: true
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError(.inputFormatUnsupported)
        }
        sourceDescription = source
        self.converter = converter
    }

    func convert(_ chunk: PCMChunk) throws -> [Float] {
        guard !drained else { throw AudioRecorderError(.conversionFailed) }
        guard chunk.format == sourceDescription,
              let source = AVAudioPCMBuffer(
                  pcmFormat: converter.inputFormat,
                  frameCapacity: AVAudioFrameCount(chunk.frameCount)
              ) else {
            throw AudioRecorderError(.conversionFailed)
        }
        source.frameLength = AVAudioFrameCount(chunk.frameCount)
        guard let destination = source.audioBufferList.pointee.mBuffers.mData else {
            throw AudioRecorderError(.conversionFailed)
        }
        let mono = destination.assumingMemoryBound(to: Float.self)
        let channelCount = sourceDescription.channelCount
        for frame in 0..<chunk.frameCount {
            let offset = frame * channelCount
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += chunk.samples[offset + channel]
            }
            mono[frame] = sum / Float(channelCount)
        }

        let estimatedFrames = (Double(chunk.frameCount) * 48_000 / chunk.format.sampleRate).rounded(.up)
        let capacity = estimatedFrames + 4_096
        guard capacity.isFinite, capacity > 0, capacity <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: converter.outputFormat,
                  frameCapacity: AVAudioFrameCount(capacity)
              ) else {
            throw AudioRecorderError(.conversionFailed)
        }

        let input = ConverterInputBox(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let buffer = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil else { throw AudioRecorderError(.conversionFailed) }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return Self.samples(from: output)
        case .error:
            throw AudioRecorderError(.conversionFailed)
        @unknown default:
            throw AudioRecorderError(.conversionFailed)
        }
    }

    func drain() throws -> [Float] {
        guard !drained else { return [] }
        drained = true
        var result: [Float] = []

        for _ in 0..<256 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: 4_096
            ) else {
                throw AudioRecorderError(.conversionFailed)
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil else { throw AudioRecorderError(.conversionFailed) }
            let samples = Self.samples(from: output)
            result.append(contentsOf: samples)

            switch status {
            case .endOfStream:
                return result
            case .inputRanDry where samples.isEmpty:
                return result
            case .haveData, .inputRanDry:
                continue
            case .error:
                throw AudioRecorderError(.conversionFailed)
            @unknown default:
                throw AudioRecorderError(.conversionFailed)
            }
        }
        throw AudioRecorderError(.conversionFailed)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0,
              let pointer = buffer.audioBufferList.pointee.mBuffers.mData else {
            return []
        }
        return Array(UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: Float.self),
            count: Int(buffer.frameLength)
        ))
    }
}

// MARK: - AVAssetWriter adapter

struct AVAssetWriterBackendFactory: RecoveryAudioWriterBackendFactory {
    func makeWriter(
        outputURL: URL,
        configuration: RecoveryAudioWriterConfiguration
    ) throws -> any RecoveryAudioWriterBackend {
        try AVAssetWriterBackend(outputURL: outputURL, configuration: configuration)
    }
}

actor AVAssetWriterBackend: RecoveryAudioWriterBackend {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(outputURL: URL, configuration: RecoveryAudioWriterConfiguration) throws {
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw AudioRecorderError(.writerCreationFailed)
        }

        writer.movieFragmentInterval = CMTime(
            seconds: configuration.subsequentFragmentSeconds,
            preferredTimescale: 48_000
        )
        writer.initialMovieFragmentInterval = CMTime(
            seconds: configuration.initialFragmentSeconds,
            preferredTimescale: 48_000
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channelCount,
            AVEncoderBitRateKey: configuration.targetBitRate
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw AudioRecorderError(.writerConfigurationFailed)
        }
        writer.add(input)
    }

    func startWriting() throws {
        try Task.checkCancellation()
        guard writer.startWriting(), writer.status == .writing else {
            throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .writerStartFailed))
        }
    }

    func startSession() throws {
        try Task.checkCancellation()
        writer.startSession(atSourceTime: .zero)
        guard writer.status == .writing else {
            throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .writerSessionStartFailed))
        }
    }

    func append(samples: [Float], presentationFrame: UInt64) async throws {
        try await waitUntilReady()
        try Task.checkCancellation()
        let sampleBuffer = try Self.makeSampleBuffer(
            samples: samples,
            presentationFrame: presentationFrame
        )
        guard input.append(sampleBuffer) else {
            throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .writerAppendFailed))
        }
    }

    func flushBarrier() throws {
        try Task.checkCancellation()
        guard writer.status == .writing else {
            throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .flushFailed))
        }
    }

    func markInputFinished() {
        guard writer.status == .writing else { return }
        input.markAsFinished()
    }

    func finishWriting() async throws {
        switch writer.status {
        case .completed:
            return
        case .writing:
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .writerFinishFailed))
            }
        case .failed, .cancelled, .unknown:
            throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .writerFinishFailed))
        @unknown default:
            throw AudioRecorderError(.writerFinishFailed)
        }
    }

    private func waitUntilReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw AudioRecorderError(Self.mapWriterFailure(writer, fallback: .writerReadinessFailed))
            }
            guard clock.now < deadline else {
                throw AudioRecorderError(.writerReadinessFailed)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func makeSampleBuffer(
        samples: [Float],
        presentationFrame: UInt64
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !byteCount.overflow, presentationFrame <= UInt64(Int64.max) else {
            throw AudioRecorderError(.sampleBufferCreationFailed)
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            throw AudioRecorderError(.sampleBufferCreationFailed)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount.partialValue,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount.partialValue,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else {
            throw AudioRecorderError(.sampleBufferCreationFailed)
        }

        let replacement = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount.partialValue
            )
        }
        guard replacement == kCMBlockBufferNoErr else {
            throw AudioRecorderError(.sampleBufferCreationFailed)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(presentationFrame), timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw AudioRecorderError(.sampleBufferCreationFailed)
        }
        return sample
    }

    private static func mapWriterFailure(
        _ writer: AVAssetWriter,
        fallback: AudioRecorderErrorCode
    ) -> AudioRecorderErrorCode {
        mapWriterError(writer.error as NSError?, fallback: fallback)
    }

    static func mapWriterError(
        _ error: NSError?,
        fallback: AudioRecorderErrorCode
    ) -> AudioRecorderErrorCode {
        guard let error else { return fallback }
        if isDiskFull(error) { return .diskFull }
        return fallback
    }

    private static func isDiskFull(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, error.code == ENOSPC { return true }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isDiskFull(underlying)
        }
        return false
    }
}

// MARK: - Recorder lifecycle

private actor AudioRecorderOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Serial lifecycle owner for the recoverable sink. Every await is guarded by
/// an operation ownership token; the operation gate keeps append/flush/stop in
/// call order even though the actor can otherwise re-enter at framework awaits.
actor AVFoundationAudioRecorder: AudioRecorder {
    private let outputLeases: any RecoveryAudioOutputLeaseProviding
    private let writerFactory: any RecoveryAudioWriterBackendFactory
    private let converterFactory: any RecoveryAudioPCMConverterFactory
    private let operationGate = AudioRecorderOperationGate()
    private let eventStream: AsyncStream<AudioRecorderEvent>
    private let eventContinuation: AsyncStream<AudioRecorderEvent>.Continuation

    private var state: AudioRecorderState = .idle
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var lastTerminalOperationID: UInt64?
    private var lastTerminalError: AudioRecorderError?

    private var lease: (any RecoveryAudioOutputLease)?
    private var location: SessionLocation?
    private var expectedGeneration: UInt64 = 0
    private var expectedSequence: UInt64 = 0
    private var sourceFormat: PCMFormatDescription?
    private var converter: (any RecoveryAudioPCMConverting)?
    private var writer: (any RecoveryAudioWriterBackend)?
    private var writtenFrames: UInt64 = 0
    private var terminalError: AudioRecorderError?
    private var didEmitTerminalEvent = false
    private var didDrainConverterTail = false
    private var didMarkInputFinished = false
    private var didRequestWriterFinish = false

    init(roots: StorageRootManager) {
        self.init(
            outputLeases: StorageRecoveryAudioOutputLeaseProvider(roots: roots),
            writerFactory: AVAssetWriterBackendFactory(),
            converterFactory: AVAudioPCMConverterFactory()
        )
    }

    init(
        outputLeases: any RecoveryAudioOutputLeaseProviding,
        writerFactory: any RecoveryAudioWriterBackendFactory,
        converterFactory: any RecoveryAudioPCMConverterFactory
    ) {
        self.outputLeases = outputLeases
        self.writerFactory = writerFactory
        self.converterFactory = converterFactory
        let pair = AsyncStream<AudioRecorderEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func currentState() -> AudioRecorderState { state }

    func events() -> AsyncStream<AudioRecorderEvent> { eventStream }

    func start(at location: SessionLocation, expectedCaptureGeneration: UInt64) async throws {
        await operationGate.acquire()
        do {
            try await startLocked(at: location, expectedCaptureGeneration: expectedCaptureGeneration)
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    func append(_ chunk: PCMChunk) async throws {
        await operationGate.acquire()
        do {
            try await appendLocked(chunk)
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    /// Application-level conversion/append barrier. It never calls
    /// AVAssetWriter.flushSegment() and makes no fsync/fragment durability claim.
    func flush() async throws {
        await operationGate.acquire()
        do {
            try await flushLocked()
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    func stop() async throws -> AudioRecorderSummary {
        await operationGate.acquire()
        do {
            let summary = try await stopLocked()
            await operationGate.release()
            return summary
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func startLocked(
        at location: SessionLocation,
        expectedCaptureGeneration: UInt64
    ) async throws {
        switch state {
        case .idle, .completed, .failed:
            break
        case .starting, .recording, .stopping:
            throw AudioRecorderError(.alreadyStarted)
        }

        let operationID = try beginOperation(
            location: location,
            expectedCaptureGeneration: expectedCaptureGeneration
        )
        state = .starting

        do {
            try Task.checkCancellation()
            let acquiredLease = try await outputLeases.acquire(for: location)
            guard activeOperationID == operationID else {
                await acquiredLease.release()
                throw ownershipError(for: operationID)
            }
            lease = acquiredLease
            try Task.checkCancellation()

            let configuredWriter = try writerFactory.makeWriter(
                outputURL: acquiredLease.outputURL,
                configuration: .production
            )
            writer = configuredWriter
            try await configuredWriter.startWriting()
            try ensureOwnership(operationID)
            try Task.checkCancellation()
            try await configuredWriter.startSession()
            try ensureOwnership(operationID)
            try Task.checkCancellation()
            state = .recording
        } catch {
            let typed = normalize(error, fallback: .writerConfigurationFailed)
            throw await transitionToTerminal(typed, operationID: operationID)
        }
    }

    private func appendLocked(_ chunk: PCMChunk) async throws {
        let operationID = try recordingOperationID()
        do {
            try Task.checkCancellation()
            guard chunk.generation == expectedGeneration else {
                throw AudioRecorderError(.inputGenerationMismatch)
            }
            guard chunk.sequence == expectedSequence else {
                throw AudioRecorderError(.sequenceDiscontinuity)
            }
            let sequenceResult = expectedSequence.addingReportingOverflow(1)
            guard !sequenceResult.overflow else {
                throw AudioRecorderError(.sequenceDiscontinuity)
            }

            let activeConverter: any RecoveryAudioPCMConverting
            if let sourceFormat {
                guard sourceFormat == chunk.format else {
                    throw AudioRecorderError(.inputFormatChanged)
                }
                guard let converter else { throw AudioRecorderError(.conversionFailed) }
                activeConverter = converter
            } else {
                let created = try converterFactory.makeConverter(source: chunk.format)
                sourceFormat = chunk.format
                converter = created
                activeConverter = created
            }

            let samples = try await activeConverter.convert(chunk)
            try ensureOwnership(operationID)
            try Task.checkCancellation()
            try await appendOutputSamples(samples, operationID: operationID)
            try ensureOwnership(operationID)
            expectedSequence = sequenceResult.partialValue
        } catch {
            let typed = normalize(error, fallback: .conversionFailed)
            throw await transitionToTerminal(typed, operationID: operationID)
        }
    }

    private func flushLocked() async throws {
        let operationID = try recordingOperationID()
        do {
            try Task.checkCancellation()
            guard let writer else { throw AudioRecorderError(.flushFailed) }
            try await writer.flushBarrier()
            try ensureOwnership(operationID)
            try Task.checkCancellation()
        } catch {
            let typed = normalize(error, fallback: .flushFailed)
            throw await transitionToTerminal(typed, operationID: operationID)
        }
    }

    private func stopLocked() async throws -> AudioRecorderSummary {
        if case let .completed(summary) = state { return summary }
        if case let .failed(code) = state {
            throw terminalError ?? lastTerminalError ?? AudioRecorderError(code)
        }
        let operationID = try recordingOperationID()
        state = .stopping

        do {
            try Task.checkCancellation()
            guard expectedSequence > 0 else { throw AudioRecorderError(.noAudioSamples) }
            if !didDrainConverterTail {
                didDrainConverterTail = true
                if let converter {
                    let tail = try await converter.drain()
                    try ensureOwnership(operationID)
                    try await appendOutputSamples(tail, operationID: operationID)
                }
            }
            guard writtenFrames > 0 else { throw AudioRecorderError(.noAudioSamples) }

            if let finishError = await finishBackendOnce() {
                throw finishError
            }
            try ensureOwnership(operationID)
            try Task.checkCancellation()

            guard let location else { throw AudioRecorderError(.invalidLifecycle) }
            let duration = try mediaDurationMilliseconds()
            let summary = AudioRecorderSummary(
                location: location,
                artifact: .recoveryAudio,
                writtenFrameCount: writtenFrames,
                mediaDurationMilliseconds: duration,
                outputFormat: .recoveryAAC
            )
            await releaseLeaseOnce()
            try ensureOwnership(operationID)
            try Task.checkCancellation()
            state = .completed(summary)
            activeOperationID = nil
            return summary
        } catch {
            let typed = normalize(error, fallback: .writerFinishFailed)
            throw await transitionToTerminal(typed, operationID: operationID)
        }
    }

    private func beginOperation(
        location: SessionLocation,
        expectedCaptureGeneration: UInt64
    ) throws -> UInt64 {
        let next = nextOperationID.addingReportingOverflow(1)
        guard !next.overflow else { throw AudioRecorderError(.invalidLifecycle) }
        nextOperationID = next.partialValue
        activeOperationID = next.partialValue
        self.location = location
        expectedGeneration = expectedCaptureGeneration
        expectedSequence = 0
        sourceFormat = nil
        converter = nil
        writer = nil
        lease = nil
        writtenFrames = 0
        terminalError = nil
        didEmitTerminalEvent = false
        didDrainConverterTail = false
        didMarkInputFinished = false
        didRequestWriterFinish = false
        return next.partialValue
    }

    private func recordingOperationID() throws -> UInt64 {
        guard case .recording = state, let activeOperationID else {
            if case let .failed(code) = state {
                throw terminalError ?? lastTerminalError ?? AudioRecorderError(code)
            }
            throw AudioRecorderError(.invalidLifecycle)
        }
        return activeOperationID
    }

    private func ensureOwnership(_ operationID: UInt64) throws {
        guard activeOperationID == operationID else {
            throw ownershipError(for: operationID)
        }
    }

    private func ownershipError(for operationID: UInt64) -> AudioRecorderError {
        if lastTerminalOperationID == operationID, let lastTerminalError {
            return lastTerminalError
        }
        return AudioRecorderError(.invalidLifecycle)
    }

    private func appendOutputSamples(
        _ samples: [Float],
        operationID: UInt64
    ) async throws {
        guard !samples.isEmpty else { return }
        try ensureOwnership(operationID)
        guard let writer else { throw AudioRecorderError(.writerAppendFailed) }
        let frameResult = writtenFrames.addingReportingOverflow(UInt64(samples.count))
        guard !frameResult.overflow,
              frameResult.partialValue <= UInt64(Int64.max),
              !frameResult.partialValue.multipliedReportingOverflow(by: 1_000).overflow else {
            throw AudioRecorderError(.writerAppendFailed)
        }
        try await writer.append(samples: samples, presentationFrame: writtenFrames)
        try ensureOwnership(operationID)
        writtenFrames = frameResult.partialValue
    }

    private func transitionToTerminal(
        _ proposedError: AudioRecorderError,
        operationID: UInt64
    ) async -> AudioRecorderError {
        guard activeOperationID == operationID else {
            return ownershipError(for: operationID)
        }
        let firstError = terminalError ?? proposedError
        terminalError = firstError
        state = .stopping
        emitTerminalEventOnce(firstError)

        _ = await finishBackendOnce()
        await releaseLeaseOnce()

        guard activeOperationID == operationID else {
            return ownershipError(for: operationID)
        }
        lastTerminalOperationID = operationID
        lastTerminalError = firstError
        state = .failed(firstError.code)
        activeOperationID = nil
        return firstError
    }

    private func finishBackendOnce() async -> AudioRecorderError? {
        guard let writer else { return nil }
        let shouldMark = !didMarkInputFinished
        let shouldFinish = !didRequestWriterFinish
        didMarkInputFinished = true
        didRequestWriterFinish = true
        guard shouldMark || shouldFinish else { return nil }

        let task = Task.detached { () -> AudioRecorderError? in
            if shouldMark { await writer.markInputFinished() }
            guard shouldFinish else { return nil }
            do {
                try await writer.finishWriting()
                return nil
            } catch let error as AudioRecorderError {
                return error
            } catch is CancellationError {
                return AudioRecorderError(.cancelled)
            } catch {
                return AudioRecorderError(.writerFinishFailed)
            }
        }
        return await task.value
    }

    private func releaseLeaseOnce() async {
        guard let oldLease = lease else { return }
        lease = nil
        let task = Task.detached {
            await oldLease.release()
        }
        await task.value
    }

    private func emitTerminalEventOnce(_ error: AudioRecorderError) {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        let storageCodes: Set<AudioRecorderErrorCode> = [
            .storageAccess,
            .storageRootUnavailable,
            .storageReauthorizationRequired,
            .storageRootMissing,
            .storageRootNotWritable,
            .unsafeSessionLayout,
            .recoveryArtifactExists
        ]
        let kind: SessionEventKind = storageCodes.contains(error.code)
            ? .storageAccessError
            : .fileWriteError
        eventContinuation.yield(.terminalFailure(
            kind: kind,
            code: error.code,
            mediaPositionMilliseconds: try? mediaDurationMilliseconds()
        ))
    }

    private func mediaDurationMilliseconds() throws -> UInt64 {
        let product = writtenFrames.multipliedReportingOverflow(by: 1_000)
        guard !product.overflow else { throw AudioRecorderError(.writerFinishFailed) }
        return product.partialValue / 48_000
    }

    private func normalize(
        _ error: Error,
        fallback: AudioRecorderErrorCode
    ) -> AudioRecorderError {
        if let error = error as? AudioRecorderError { return error }
        if error is CancellationError { return AudioRecorderError(.cancelled) }
        if let error = error as? StorageError {
            return AudioRecorderError(Self.mapStorageError(error.code))
        }
        return AudioRecorderError(fallback)
    }

    private static func mapStorageError(_ code: StorageErrorCode) -> AudioRecorderErrorCode {
        switch code {
        case .noActiveRoot, .registryMissing:
            return .storageRootUnavailable
        case .reauthorizationRequired, .bookmarkCreateFailed, .bookmarkResolveFailed,
             .bookmarkRefreshFailed, .securityScopeAccessFailed:
            return .storageReauthorizationRequired
        case .rootMissing:
            return .storageRootMissing
        case .rootNotWritable:
            return .storageRootNotWritable
        default:
            return .storageAccess
        }
    }
}
