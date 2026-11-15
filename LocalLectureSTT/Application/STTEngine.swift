import Foundation

/// Control-plane handles are Sendable, never serialized. Accepted requests terminate by value only.
protocol STTEngine: Sendable {
    var capabilities: STTCapabilities { get }
    func load(_ model: STTModelConfiguration) async throws
    func start(_ session: STTSessionConfiguration) async throws
    func infer(_ request: STTInferenceRequest) async throws -> STTEventFeed
    func end() async throws
    func cancel() async throws
    func unload() async
}

/// An immutable model choice and a fresh engine for one recording attempt.
struct RecordingSpeechModel: Sendable {
    let engine: any STTEngine
    let configuration: STTModelConfiguration
    let settings: SessionModelSettings
}

/// One subscriber per request; two retained values coalesce partials and retain the terminal.
/// The engine owns work, not the lifetime of the handle. Withdrawal cancels only this request.
final class STTEventFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var latest: STTResponse?
    private var published = 0
    private var terminals = 0
    private let stream: AsyncStream<STTResponse>
    private let continuation: AsyncStream<STTResponse>.Continuation
    private let withdrawAction: @Sendable () async -> Void

    init(withdraw: @escaping @Sendable () async -> Void) {
        let pair = AsyncStream<STTResponse>.makeStream(bufferingPolicy: .bufferingNewest(2))
        stream = pair.stream
        continuation = pair.continuation
        withdrawAction = withdraw
        continuation.onTermination = { reason in
            if case .cancelled = reason { Task { await withdraw() } }
        }
    }

    func events() throws -> AsyncStream<STTResponse> {
        try lock.withLock {
            guard !claimed else { throw STTEngineError(.consumerAlreadyClaimed) }
            claimed = true
            return stream
        }
    }

    func withdraw() async { await withdrawAction() }

    // Only the owning engine publishes. Its ownership/revision checks precede this call.
    func publish(_ response: STTResponse) {
        lock.withLock {
            guard terminals == 0 else { return }
            latest = response
            published += 1
            if response.isTerminal { terminals += 1 }
            continuation.yield(response)
            if response.isTerminal { continuation.finish() }
        }
    }

    /// Bounded observation for deterministic test barriers; contains no response history.
    func observation() -> (latest: STTResponse?, published: Int, terminals: Int) {
        lock.withLock { (latest, published, terminals) }
    }
}
