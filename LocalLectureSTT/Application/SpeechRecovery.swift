import Foundation

protocol SpeechRecoveryRecording: Sendable {
    func initialize(_ session: STTSessionConfiguration, at location: SessionLocation) async throws
    func pinLanguage(_ language: LanguageCode, at location: SessionLocation) async throws
    func observe(windows: [SpeechRecoveryRange], missing: [SpeechRecoveryRange], through: Int64,
                 ended: Bool, at location: SessionLocation) async throws -> SpeechRecoverySummary
    func prepare(_ segments: [TranscriptSegment], range: SpeechRecoveryRange, language: LanguageCode?,
                 at location: SessionLocation) async throws
    func complete(_ range: SpeechRecoveryRange, at location: SessionLocation) async throws -> SpeechRecoverySummary
}

protocol SpeechGapRepairing: Sendable {
    func repair(at location: SessionLocation, audio: AudioFinalizationResult, control: AudioFinalizationControl) async throws -> SpeechRecoverySummary?
}
