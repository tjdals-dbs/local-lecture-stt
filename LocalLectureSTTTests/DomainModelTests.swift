import Foundation
import XCTest
@testable import LocalLectureSTT

final class DomainModelTests: XCTestCase {
    private let sessionID = SessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let timestamp = AbsoluteTime(Date(timeIntervalSince1970: 1_725_000_000.123))

    func testMetadataDocumentsRoundTripForIncompleteAndCompletedSessions() throws {
        let incomplete = try makeMetadata(status: .preparing, outcome: .notStarted, includeCompletionDetails: false)
        let completed = try makeMetadata(status: .completed, outcome: .completed, includeCompletionDetails: true)

        XCTAssertEqual(try roundTrip(incomplete), incomplete)
        XCTAssertEqual(try roundTrip(completed), completed)
        let completedJSON = try encodedString(completed)
        XCTAssertTrue(completedJSON.contains("\"schemaVersion\":1"))
        XCTAssertTrue(completedJSON.contains("\"activeDurationMs\":1234"))
        assertCodableSendable(SessionMetadataDocument.self)
    }

    func testTranscriptDocumentRoundTripPreservesImmutableOriginalAndMediaMilliseconds() throws {
        let document = try TranscriptDocument(
            sessionId: sessionID,
            segments: [
                try makeSegment(id: "00000000-0000-0000-0000-000000000011", sequence: 0, start: 0, end: 1_250),
                try makeSegment(id: "00000000-0000-0000-0000-000000000012", sequence: 1, start: 1_250, end: 2_500)
            ]
        )

        XCTAssertEqual(try roundTrip(document), document)
        let json = try encodedString(document)
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        XCTAssertTrue(json.contains("\"startMs\":0"))
        XCTAssertTrue(json.contains("\"endMs\":1250"))
        assertCodableSendable(TranscriptDocument.self)
        assertCodableSendable(TranscriptSegment.self)
    }

    func testEveryEventKindRoundTripsAsAnIndependentSchemaVersionedRecord() throws {
        for kind in SessionEventKind.allCases {
            let record = try SessionEventRecord(
                sessionId: sessionID,
                eventId: SessionEventID(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!),
                occurredAt: timestamp,
                kind: kind,
                mediaPositionMs: try MediaMilliseconds(5_000),
                detail: try SessionEventDetail(code: "test-event", message: "synthetic")
            )
            XCTAssertEqual(try roundTrip(record), record, "\(kind)")
            XCTAssertTrue(try encodedString(record).contains("\"schemaVersion\":1"))
        }
        assertCodableSendable(SessionEventRecord.self)
    }

    func testFinalizationCheckpointRoundTripsAndHasSchemaVersion() throws {
        let checkpoint = try FinalizationCheckpointDocument(
            sessionId: sessionID,
            updatedAt: timestamp,
            completedSteps: [.workingAudioSecured, .finalM4ACreated]
        )

        XCTAssertEqual(try roundTrip(checkpoint), checkpoint)
        XCTAssertTrue(try encodedString(checkpoint).contains("\"schemaVersion\":1"))
        assertCodableSendable(FinalizationCheckpointDocument.self)
    }

    func testUnsupportedSchemaVersionsAreRejectedOnConstructionAndDecoding() throws {
        XCTAssertThrowsError(try makeMetadata(schemaVersion: SchemaVersion(rawValue: 2)))

        let json = try encodedString(makeMetadata())
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        XCTAssertThrowsError(try JSONDecoder().decode(SessionMetadataDocument.self, from: Data(json.utf8)))
    }

    func testAbsoluteTimeUsesTimezoneISO8601StringWithFixedMillisecondPrecision() throws {
        let json = try encodedString(timestamp)
        XCTAssertTrue(json.contains("T"))
        XCTAssertTrue(json.contains("Z"))
        XCTAssertFalse(json.contains("1725000000"))
        XCTAssertEqual(try roundTrip(timestamp), timestamp)
        XCTAssertEqual(
            try JSONDecoder().decode(AbsoluteTime.self, from: Data("\"2024-01-02T03:04:05Z\"".utf8)),
            AbsoluteTime(Date(timeIntervalSince1970: 1_704_164_645))
        )
    }

    func testIdentifierTypesRemainDistinctAndConformToBoundaryRequirements() throws {
        let engineID = try EngineID("engine-a")
        let modelID = try ModelID("model-a")
        XCTAssertNotEqual(engineID.rawValue, "")
        XCTAssertNotEqual(modelID.rawValue, "")
        assertCodableSendable(SessionID.self)
        assertCodableSendable(TranscriptSegmentID.self)
        assertCodableSendable(EngineID.self)
        assertCodableSendable(ModelID.self)
        assertCodableSendable(LanguageCode.self)
        assertCodableSendable(EngineIdentity.self)
        assertCodableSendable(ModelIdentity.self)
    }

    func testNormalLifecycleTransitionsIncludingPauseAndFinalization() throws {
        let preparing = try SessionLifecycle(status: .preparing, captureOutcome: .notStarted)
        let recording = try preparing.transition(to: .recording)
        let paused = try recording.transition(to: .paused)
        let resumed = try paused.transition(to: .recording)
        let securing = try resumed.transition(to: .securing)
        let finalizing = try securing.transition(to: .finalizing)
        let completed = try finalizing.transition(to: .completed)

        XCTAssertEqual(recording.captureOutcome, .inProgress)
        XCTAssertEqual(paused.captureOutcome, .inProgress)
        XCTAssertEqual(securing.captureOutcome, .completed)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.captureOutcome, .completed)
        XCTAssertEqual(try completed.transition(to: .completed), completed)
    }

    func testInterruptedRecoveryNeverChangesCaptureOutcomeToCompleted() throws {
        let interrupted = try SessionLifecycle(status: .interrupted, captureOutcome: .interrupted)
        let securing = try interrupted.transition(to: .securing)
        let finalizing = try securing.transition(to: .finalizing)
        let recoveredDisplay = try finalizing.transition(to: .interrupted)

        XCTAssertEqual(securing.captureOutcome, .interrupted)
        XCTAssertEqual(finalizing.captureOutcome, .interrupted)
        XCTAssertEqual(recoveredDisplay, interrupted)
        XCTAssertThrowsError(try finalizing.transition(to: .completed))

        let directlyFinalizing = try interrupted.transition(to: .finalizing)
        XCTAssertEqual(directlyFinalizing.captureOutcome, .interrupted)
    }

    func testRecordingAndPausedCanBothBecomeInterrupted() throws {
        let recording = try SessionLifecycle(status: .recording, captureOutcome: .inProgress)
        let paused = try recording.transition(to: .paused)
        let expected = try SessionLifecycle(status: .interrupted, captureOutcome: .interrupted)

        XCTAssertEqual(try recording.transition(to: .interrupted), expected)
        XCTAssertEqual(try paused.transition(to: .interrupted), expected)
    }

    func testInvalidLifecycleCombinationsAndTransitionsAreRejected() throws {
        XCTAssertThrowsError(try SessionLifecycle(status: .recording, captureOutcome: .completed))

        let recording = try SessionLifecycle(status: .recording, captureOutcome: .inProgress)
        let interrupted = try SessionLifecycle(status: .interrupted, captureOutcome: .interrupted)
        let completed = try SessionLifecycle(status: .completed, captureOutcome: .completed)
        let missing = try SessionLifecycle(status: .missing, captureOutcome: .interrupted)

        XCTAssertThrowsError(try recording.transition(to: .completed))
        XCTAssertThrowsError(try interrupted.transition(to: .completed))
        XCTAssertThrowsError(try completed.transition(to: .recording))
        XCTAssertThrowsError(try missing.transition(to: .recording))
    }

    func testResidualInProgressAndInterruptedMetadataDecodeWithoutConflation() throws {
        let residualRecording = try makeMetadata(status: .recording, outcome: .inProgress)
        let residualPaused = try makeMetadata(status: .paused, outcome: .inProgress)
        let interrupted = try makeMetadata(status: .interrupted, outcome: .interrupted)

        XCTAssertEqual(try roundTrip(residualRecording).status, .recording)
        XCTAssertEqual(try roundTrip(residualPaused).status, .paused)
        XCTAssertEqual(try roundTrip(interrupted).status, .interrupted)
        XCTAssertEqual(try roundTrip(interrupted).captureOutcome, .interrupted)
    }

    func testValueInvariantsRejectNegativeAndReversedMediaValues() throws {
        XCTAssertThrowsError(try MediaMilliseconds(-1))
        XCTAssertThrowsError(try TranscriptSegmentSequence(-1))
        XCTAssertThrowsError(try TranscriptSegmentCount(-1))
        XCTAssertThrowsError(try TranscriptSegment(
            id: TranscriptSegmentID(),
            sequence: try TranscriptSegmentSequence(0),
            startMs: try MediaMilliseconds(20),
            endMs: try MediaMilliseconds(10),
            originalText: "original",
            text: "current",
            language: try LanguageCode("ko")
        ))
    }

    func testCheckpointProgressIsSequentialIdempotentAndCannotSkipOrRegress() throws {
        let empty = try FinalizationCheckpointDocument(sessionId: sessionID, updatedAt: timestamp)
        let first = try empty.markingCompleted(.workingAudioSecured, at: timestamp)

        XCTAssertEqual(try first.markingCompleted(.workingAudioSecured, at: AbsoluteTime(Date())), first)
        XCTAssertThrowsError(try empty.markingCompleted(.catalogUpdated, at: timestamp))
        XCTAssertThrowsError(try FinalizationCheckpointDocument(
            sessionId: sessionID,
            updatedAt: timestamp,
            completedSteps: [.workingAudioSecured, .finalM4AVerified]
        ))

        var checkpoint = empty
        for step in FinalizationStep.allCases {
            checkpoint = try checkpoint.markingCompleted(step, at: timestamp)
        }
        XCTAssertEqual(checkpoint.completedSteps, FinalizationStep.allCases)
    }

    private func makeMetadata(
        schemaVersion: SchemaVersion = .current,
        status: SessionStatus = .completed,
        outcome: CaptureOutcome = .completed,
        includeCompletionDetails: Bool = true
    ) throws -> SessionMetadataDocument {
        try SessionMetadataDocument(
            schemaVersion: schemaVersion,
            sessionId: sessionID,
            title: "Synthetic lecture",
            status: status,
            captureOutcome: outcome,
            createdAt: timestamp,
            recordingStartedAt: includeCompletionDetails ? timestamp : nil,
            recordingEndedAt: includeCompletionDetails ? timestamp : nil,
            activeDurationMs: try MediaMilliseconds(1_234),
            languageMode: .korean,
            detectedLanguage: includeCompletionDetails ? try LanguageCode("ko") : nil,
            engine: includeCompletionDetails ? try EngineIdentity(id: EngineID("whisperkit"), version: "1.0") : nil,
            model: includeCompletionDetails ? try ModelIdentity(id: ModelID("large-v3"), revision: "r1", checksum: "abc123") : nil,
            audio: includeCompletionDetails ? try AudioDescription(format: "m4a", sampleRate: 48_000, channels: 1, bitRate: 96_000) : nil,
            transcript: TranscriptSummary(segmentCount: try TranscriptSegmentCount(2)),
            appVersion: "1.0.0",
            osVersion: "macOS 26.6",
            lastUpdatedAt: timestamp
        )
    }

    private func makeSegment(id: String, sequence: Int64, start: Int64, end: Int64) throws -> TranscriptSegment {
        try TranscriptSegment(
            id: TranscriptSegmentID(UUID(uuidString: id)!),
            sequence: try TranscriptSegmentSequence(sequence),
            startMs: try MediaMilliseconds(start),
            endMs: try MediaMilliseconds(end),
            originalText: "original \(sequence)",
            text: "current \(sequence)",
            language: try LanguageCode("ko")
        )
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func encodedString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func assertCodableSendable<T: Codable & Sendable>(_ type: T.Type) {}
}
