import XCTest

final class VectorMapUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func openKirkham(server: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        if let server { app.launchArguments += ["-canopy.gerardusURL", server] }
        app.launch()
        XCTAssertTrue(app.buttons["Layers"].firstMatch.waitForExistence(timeout: 90))
        app.buttons["Layers"].firstMatch.tap()
        let link = app.buttons["Kirkham & 9th in 3D"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        return app
    }

    @MainActor
    func testMissingServerShowsSettingsInsteadOfSyntheticBuildings() {
        let app = openKirkham()
        XCTAssertTrue(app.staticTexts["3D vectors unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Server settings"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["vector-scene"].exists)
    }

    @MainActor
    func testLiveKirkhamCanOrbitToggleLayersAndReset() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"] == nil, "no Gerardus server given")
        let server = try XCTUnwrap(
            ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"], "no Gerardus server given")
        let app = openKirkham(server: server)
        let summary = app.staticTexts["vector-summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 120))
        XCTAssertTrue(summary.label.contains("box walls"), summary.label)
        XCTAssertFalse(summary.label.hasPrefix("0 box walls"), summary.label)
        let scene = app.descendants(matching: .any)["vector-scene"].firstMatch
        XCTAssertTrue(scene.exists)
        scene.swipeLeft()
        app.buttons["3D layers"].firstMatch.tap()
        app.buttons["Ground"].firstMatch.tap()
        app.buttons["Reset view"].firstMatch.tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.descendants(matching: .any)["vector-attribution"].firstMatch.exists)
    }
}
