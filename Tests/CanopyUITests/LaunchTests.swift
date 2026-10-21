import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAllFourTabsAreReachable() {
        let app = XCUIApplication()
        app.launch()
        for name in ["Map", "Census", "Tag", "Me"] {
            let tab = app.buttons[name].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "missing tab \(name)")
            tab.tap()
        }
    }
}
