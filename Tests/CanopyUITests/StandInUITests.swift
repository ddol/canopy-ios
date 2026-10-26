import XCTest

/// Loading real trees through the app against the stand-in Gerardus server (`canopy-harness serve`, which
/// `scripts/test.sh` starts), so the whole path from the Layers menu to trees on the map is tested without a real
/// server. Each step keeps a screenshot in the result bundle. Skipped when no stand-in is given:
/// `TEST_RUNNER_CANOPY_STAND_IN_URL=http://127.0.0.1:50099 scripts/test.sh -only-testing:CanopyUITests/StandInUITests`.
final class StandInUITests: XCTestCase {
    let mapTimeout: TimeInterval = 90

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(ProcessInfo.processInfo.environment["CANOPY_STAND_IN_URL"] == nil, "no stand-in server given")
    }

    @MainActor
    func testLoadingTreesTwiceUsesTheSavedPointsAndSettingsCanClearThem() throws {
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["CANOPY_STAND_IN_URL"])
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-canopy.gerardusURL", server]
        app.launch()
        XCTAssertTrue(app.otherElements["Estimated: 200"].firstMatch.waitForExistence(timeout: mapTimeout))
        keep(app, "1 map with the sample")

        let first = try load(app)
        keep(app, "2 first load")
        XCTAssertTrue(first.label.hasPrefix("Loaded"), first.label)
        XCTAssertFalse(first.label.contains("saved on this phone"), first.label)
        let credit = app.staticTexts["aerial-attribution"].firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 30))
        XCTAssertTrue(credit.label.contains("3D Elevation Program"), credit.label)
        XCTAssertFalse(app.otherElements["Estimated: 200"].exists, "the sample should have been replaced")

        app.buttons["Dismiss"].firstMatch.tap()
        let again = try load(app)
        keep(app, "3 second load")
        XCTAssertTrue(again.label.contains("saved on this phone"), again.label)

        app.buttons["Me"].firstMatch.tap()
        app.navigationBars.buttons["Settings"].firstMatch.tap()
        let saved = app.staticTexts["Saved on this phone"].firstMatch
        for _ in 0..<6 where !saved.exists { app.swipeUp() }
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        keep(app, "4 settings with saved data")
        let clear = app.buttons["Clear saved aerial data"].firstMatch
        XCTAssertTrue(clear.isEnabled)
        clear.tap()
        XCTAssertFalse(clear.isEnabled)
        keep(app, "5 settings cleared")
    }

    /// Layers → Load real trees in view, and the result once it shows.
    @MainActor
    private func load(_ app: XCUIApplication) throws -> XCUIElement {
        app.buttons["Layers"].firstMatch.tap()
        let button = app.buttons["Load real trees in view"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let start = Date()
        button.tap()
        let result = app.descendants(matching: .any)["aerial-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 120))
        let note = XCTAttachment(
            string: String(format: "%.1f s: %@", Date().timeIntervalSince(start), result.label))
        note.lifetime = .keepAlways
        add(note)
        return result
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
