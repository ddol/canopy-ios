import XCTest

/// Loads real trees from a Gerardus align server through the app. Opt in by passing the server to the test runner:
/// `TEST_RUNNER_CANOPY_GERARDUS_URL=http://gerardus.local:50061 scripts/test.sh -only-testing:CanopyUITests/AerialTreesUITests`.
final class AerialTreesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"] == nil, "no Gerardus server given")
    }

    @MainActor
    func testLoadingRealTreesShowsThemWithAttribution() throws {
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"])
        let app = XCUIApplication()
        // The argument domain overrides the app's server setting for this launch.
        app.launchArguments = ["-ui-testing", "-canopy.gerardusURL", server]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["Estimated: 200"].firstMatch.waitForExistence(timeout: 90))

        app.buttons["Layers"].firstMatch.tap()
        let load = app.buttons["Load real trees here"].firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        load.tap()

        // Preparing a new site on the server can take a few minutes; a prepared one, seconds.
        let result = app.descendants(matching: .any)["aerial-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 600))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(result.label.hasPrefix("Loaded"), result.label)
        let credit = app.staticTexts["aerial-attribution"].firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 30))
        XCTAssertTrue(credit.label.contains("3D Elevation Program"), credit.label)
    }
}
