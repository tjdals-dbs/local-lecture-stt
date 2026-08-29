import XCTest
@testable import LocalLectureSTT

final class MainWindowViewTests: XCTestCase {
    func testRootViewCanBeConstructed() {
        let rootView = MainWindowView()

        XCTAssertNotNil(Optional(rootView))
    }
}
