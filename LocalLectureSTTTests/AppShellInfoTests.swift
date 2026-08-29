import XCTest
@testable import LocalLectureSTT

final class AppShellInfoTests: XCTestCase {
    func testInitialShellStatusMessage() {
        XCTAssertEqual(AppShellInfo.statusMessage, "초기 프로젝트 셸입니다.")
    }
}
