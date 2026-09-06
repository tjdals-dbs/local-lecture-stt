import XCTest
@testable import LocalLectureSTT

@MainActor
final class MainWindowViewTests: XCTestCase {
    func testRootViewCanBeConstructed() {
        let rootView = MainWindowView()

        XCTAssertNotNil(Optional(rootView))
    }

    func testReviewSameRootReauthorizationDoesNotReplaceSessionResults() {
        let root = StorageRootID()
        let completed = SessionRecoveryIssue(rootID: root, folderName: "recovered", sessionID: SessionID(),
            code: .interruptedRecordingRecovered, preserved: true, retryable: false, warning: nil, captureOutcome: .interrupted)
        let failure = SessionRecoveryIssue(rootID: root, folderName: "failed", sessionID: SessionID(),
            code: .finalizationFailed, preserved: true, retryable: true, warning: "exportStart", warnings: ["cleanup.persistence"])
        let report = SessionRecoveryReport(items: [completed, failure], catalogWarning: nil, discoveryWarning: nil)
        let plain = RecoveryStatusPresentation.make(report: report)
        let separated = RecoveryStatusPresentation.make(report: report, historicalReauthorizationErrors: [root: .rootNotDirectory])
        XCTAssertEqual(separated.items.first { $0.id == completed.id }?.title, plain.items.first { $0.id == completed.id }?.title)
        XCTAssertEqual(separated.items.first { $0.id == failure.id }?.firstError, "exportStart")
        XCTAssertEqual(separated.items.first { $0.id == failure.id }?.warnings, ["cleanup.persistence"])
        XCTAssertEqual(separated.rootNotices, [.init(rootID: root, error: .rootNotDirectory)])
    }

    func testT09RecoveryPresentationSeparatesSuccessInterruptedWaitingFailureAndReauthorization() {
        let root = StorageRootID()
        let location = SessionRecoveryIssue(rootID: root, folderName: "fixture", sessionID: SessionID(), code: .interruptedRecordingRecovered,
            preserved: true, retryable: false, warning: nil)
        XCTAssertEqual(RecoveryStatusPresentation.make(report: .init(items: [], catalogWarning: nil, discoveryWarning: nil)).title,
                       "세션 복구 확인 완료")
        let interrupted = RecoveryStatusPresentation.make(report: .init(items: [location], catalogWarning: nil, discoveryWarning: nil))
        XCTAssertEqual(interrupted.items.first?.title, "중단된 녹음 오디오 복구 완료 — 나머지 마무리 대기")
        let normal = SessionRecoveryIssue(rootID: root, folderName: "normal", sessionID: SessionID(), code: .audioReadyAwaitingRemainingFinalization,
            preserved: true, retryable: false, warning: nil)
        XCTAssertEqual(RecoveryStatusPresentation.make(report: .init(items: [normal], catalogWarning: nil, discoveryWarning: nil)).items.first?.title,
                       "정상 녹음 오디오 완료 — 나머지 마무리 대기")
        let failure = SessionRecoveryIssue(rootID: root, folderName: "failed", sessionID: SessionID(), code: .finalizationFailed,
            preserved: true, retryable: true, warning: "exportStart", warnings: ["exportStart", "diagnostic.persistence"])
        let failed = RecoveryStatusPresentation.make(report: .init(items: [location, failure], catalogWarning: nil, discoveryWarning: nil))
        let failureItem = try! XCTUnwrap(failed.items.first { $0.issue.code == .finalizationFailed })
        XCTAssertEqual(failureItem.action, .retry)
        XCTAssertEqual(failureItem.firstError, "exportStart")
        XCTAssertEqual(failureItem.warnings, ["diagnostic.persistence"])
        let unavailable = SessionRecoveryIssue(rootID: root, folderName: nil, sessionID: nil, code: .rootUnavailable,
            preserved: true, retryable: true, warning: nil)
        let mixed = RecoveryStatusPresentation.make(report: .init(items: [location, failure, unavailable], catalogWarning: .openFailed, discoveryWarning: "registryFailed"))
        XCTAssertEqual(mixed.items.count, 3, "a recovered item must not hide a failed or unavailable-root item")
        XCTAssertEqual(mixed.items.first { $0.issue.code == .rootUnavailable }?.action, .reauthorize(root))
        XCTAssertEqual(mixed.catalogWarning, .openFailed)
        XCTAssertEqual(mixed.discoveryWarning, "registryFailed")
        let revalidatedInterrupted = SessionRecoveryIssue(rootID: root, folderName: "revalidated-interrupted", sessionID: SessionID(),
            code: .audioRevalidated, preserved: true, retryable: false, warning: nil, captureOutcome: .interrupted)
        XCTAssertEqual(RecoveryStatusPresentation.make(report: .init(items: [revalidatedInterrupted], catalogWarning: nil, discoveryWarning: nil)).items.first?.title,
                       "중단된 녹음 오디오 재검증 완료")
        let unknownRevalidation = SessionRecoveryIssue(rootID: root, folderName: "revalidated-unknown", sessionID: SessionID(),
            code: .audioRevalidated, preserved: true, retryable: false, warning: nil)
        XCTAssertEqual(RecoveryStatusPresentation.make(report: .init(items: [unknownRevalidation], catalogWarning: nil, discoveryWarning: nil)).items.first?.title,
                       "오디오 재검증 완료 — 녹음 결과 확인 필요")
        let historicalRoot = StorageRootID()
        let historicalUnavailable = SessionRecoveryIssue(rootID: historicalRoot, folderName: nil, sessionID: nil,
            code: .rootUnavailable, preserved: true, retryable: true, warning: "reauthorizationRequired")
        let historical = RecoveryStatusPresentation.make(
            report: .init(items: [location, failure, historicalUnavailable], catalogWarning: .openFailed, discoveryWarning: "catalog.openFailed"),
            historicalReauthorizationErrors: [historicalRoot: .rootNotDirectory]
        )
        XCTAssertNotNil(historical.items.first { $0.issue.rootID == historicalRoot && $0.issue.code == .rootUnavailable },
                        "the scanned root issue remains a session/report result rather than being rewritten")
        XCTAssertEqual(historical.rootNotices, [.init(rootID: historicalRoot, error: .rootNotDirectory)])
        XCTAssertNotNil(historical.items.first { $0.issue.code == .interruptedRecordingRecovered },
                        "A historical reauthorization error must not hide active/interrupted recovery status")
        XCTAssertNotNil(historical.items.first { $0.issue.code == .finalizationFailed },
                        "A historical reauthorization error must not hide an independent retryable failure")
        for code in SessionRecoveryCode.allCases {
            let issue = SessionRecoveryIssue(rootID: root, folderName: code.rawValue, sessionID: nil, code: code,
                preserved: true, retryable: false, warning: nil)
            XCTAssertFalse(RecoveryStatusPresentation.make(report: .init(items: [issue], catalogWarning: nil, discoveryWarning: nil)).items[0].title.isEmpty,
                           "missing presentation classification: \(code)")
        }
    }
}
