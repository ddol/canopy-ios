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
        XCTAssertTrue(app.otherElements["Estimated: 200"].firstMatch.waitForExistence(timeout: 90))

        // A prepared site loads in seconds. A new one may first fail as still preparing; the server carries on, so
        // the second try finds it ready.
        let result = app.descendants(matching: .any)["aerial-result"].firstMatch
        for attempt in 1...2 {
            app.buttons["Layers"].firstMatch.tap()
            let load = app.buttons["Load real trees in view"].firstMatch
            XCTAssertTrue(load.waitForExistence(timeout: 10))
            load.tap()
            XCTAssertTrue(result.waitForExistence(timeout: 120))
            guard attempt == 1, result.label.contains("still preparing") else { break }
            app.buttons["Dismiss"].firstMatch.tap()
            sleep(20)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(result.label.hasPrefix("Loaded"), result.label)
        let credit = app.staticTexts["aerial-attribution"].firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 30))
        XCTAssertTrue(credit.label.contains("3D Elevation Program"), credit.label)
    }
}
