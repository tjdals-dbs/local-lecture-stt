import Foundation

/// The same serial queue owns audio and transcript work for live Stop and T09
/// recovery. Explicit cancellation stops optional transcript work before quit
/// joins the recording owner's essential STT/journal cleanup.
struct SessionFinalizationWorker: AudioFinalizationWorking {
    let audio: any AudioFinalizationWorking
    let transcripts: any TranscriptFinalizing
    var settleSpeech: @Sendable (SessionLocation, AudioFinalizationControl) async throws -> Void = { _, _ in }

    func finalize(_ request: AudioFinalizationRequest, control: AudioFinalizationControl,
                  progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        let result = await audio.finalize(request, control: control, progress: progress)
        guard result.failure == nil else { return result }
        do {
            await progress(.compactingTranscript)
            try await settleSpeech(request.location, control)
            try control.check()
            let steps = try await transcripts.finalize(at: request.location, audio: result, control: control)
            try control.check()
            return replacing(result, phase: .sessionReady, failure: nil, steps: steps)
        } catch {
            let typed = error as? TranscriptFailure
            let code = typed == nil ? ((error as? AudioFinalizationCode) ?? .persistence) : AudioFinalizationCode.transcript
            control.fail(code)
            return replacing(result, phase: .failed, failure: control.outcome().0,
                             steps: result.completedSteps,
                             transcriptFailure: code == .cancelled ? nil : (typed ?? .init(code: .storage)))
        }
    }

    func removeRecovery(_ evidence: FinalizationCompletionEvidence, control: AudioFinalizationControl,
                        progress: @escaping @Sendable (AudioFinalizationPhase) async -> Void) async -> AudioFinalizationResult {
        await audio.removeRecovery(evidence, control: control, progress: progress)
    }

    private func replacing(_ result: AudioFinalizationResult, phase: AudioFinalizationPhase,
                           failure: AudioFinalizationCode?, steps: [FinalizationStep],
                           transcriptFailure: TranscriptFailure? = nil) -> AudioFinalizationResult {
        .init(location: result.location, phase: phase, failure: failure, warnings: result.warnings,
              media: result.media, source: result.source, final: result.final, completedSteps: steps,
              retainedPaths: result.retainedPaths, presentPaths: result.presentPaths,
              recoveryWasRemoved: result.recoveryWasRemoved, transcriptFailure: transcriptFailure)
    }
}
