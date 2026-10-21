import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAllFourTabsAreReachable() {
        let app = launch()
        for name in ["Map", "Census", "Tag", "Me"] {
            let tab = app.buttons[name].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "missing tab \(name)")
            tab.tap()
        }
    }

    @MainActor
    func testMapShowsTheSummaryOfTheFixtureCandidates() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["summary-bar"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["Estimated: 200"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["Confirmed: 0"].firstMatch.exists)
    }

    @MainActor
    func testConfirmingATreeFromItsSheetMakesItProposed() {
        let app = launch()
        // The first synthetic candidate in Fixtures/ggp/tree-candidates.geojson.
        let tree = app.descendants(matching: .any)["tree-17174592-BB4C-47D2-B2B8-FE45CFF2DFB5"].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: 15))
        tree.tap()
        let confirm = app.buttons["Confirm tree"].firstMatch
        let opened = confirm.waitForExistence(timeout: 10)
        if !opened {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(opened)
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Proposed"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        let coverage = app.descendants(matching: .any)["Coverage: 0.5\u{202F}%"].firstMatch
        XCTAssertTrue(coverage.waitForExistence(timeout: 10))
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        return app
    }
}
