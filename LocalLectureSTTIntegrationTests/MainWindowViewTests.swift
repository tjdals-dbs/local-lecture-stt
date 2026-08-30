import XCTest
@testable import LocalLectureSTT

@MainActor
final class MainWindowViewTests: XCTestCase {
    func testRootViewCanBeConstructed() {
        let rootView = MainWindowView()

        XCTAssertNotNil(Optional(rootView))
    }
}
