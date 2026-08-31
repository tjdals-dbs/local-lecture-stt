import Foundation

/// Framework-independent boundary for the recoverable recording sink. T07 owns
/// capture orchestration; this contract only accepts its ordered recording PCM.
protocol AudioRecorder: Sendable {
    func start(at location: SessionLocation, expectedCaptureGeneration: UInt64) async throws
    func append(_ chunk: PCMChunk) async throws
    func flush() async throws
    func stop() async throws -> AudioRecorderSummary
    func currentState() async -> AudioRecorderState
    func events() async -> AsyncStream<AudioRecorderEvent>
}

enum AudioRecorderState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case stopping
    case completed(AudioRecorderSummary)
    case failed(AudioRecorderErrorCode)
}

struct AudioRecorderOutputFormat: Sendable, Equatable {
    let sampleRate: Int
    let channelCount: Int
    let targetBitRate: Int

    static let recoveryAAC = AudioRecorderOutputFormat(sampleRate: 48_000, channelCount: 1, targetBitRate: 96_000)
}

struct AudioRecorderSummary: Sendable, Equatable {
    let location: SessionLocation
    let artifact: SessionArtifact
    let writtenFrameCount: UInt64
    let mediaDurationMilliseconds: UInt64
    let outputFormat: AudioRecorderOutputFormat
}

enum AudioRecorderErrorCode: String, Sendable, Equatable {
    case alreadyStarted
    case invalidLifecycle
    case storageAccess
    case unsafeSessionLayout
    case recoveryArtifactExists
    case inputGenerationMismatch
    case inputFormatUnsupported
    case inputFormatChanged
    case sequenceDiscontinuity
    case conversionFailed
    case writerConfigurationFailed
    case writerStartFailed
    case writerAppendFailed
    case writerFinishFailed
    case diskFull
    case flushFailed
    case noAudioSamples
    case cancelled
}

struct AudioRecorderError: Error, Sendable, Equatable {
    let code: AudioRecorderErrorCode
    init(_ code: AudioRecorderErrorCode) { self.code = code }
}

enum AudioRecorderEvent: Sendable, Equatable {
    case terminalFailure(kind: SessionEventKind, code: AudioRecorderErrorCode, mediaPositionMilliseconds: UInt64?)
}
