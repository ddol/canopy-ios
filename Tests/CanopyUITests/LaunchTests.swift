import XCTest

final class LaunchTests: XCTestCase {
    /// The first query against the map snapshots all 200 tree annotations, which takes 15 s or more on CI runners.
    let mapTimeout: TimeInterval = 90
    /// The first synthetic candidate in Fixtures/ggp/tree-candidates.geojson.
    let firstTreeID = "tree-17174592-BB4C-47D2-B2B8-FE45CFF2DFB5"

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
        XCTAssertTrue(app.descendants(matching: .any)["summary-bar"].firstMatch.waitForExistence(timeout: mapTimeout))
        XCTAssertTrue(
            app.descendants(matching: .any)["Estimated: 200"].firstMatch.waitForExistence(timeout: mapTimeout))
        XCTAssertTrue(app.descendants(matching: .any)["Confirmed: 0"].firstMatch.exists)
    }

    @MainActor
    func testConfirmingATreeFromItsSheetMakesItProposed() {
        let app = launch()
        let tree = app.buttons[firstTreeID].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: mapTimeout))
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
    func testCensusExplainsWhenThereIsNoLiDAR() {
        // The simulator has no LiDAR, so Census offers the verification list.
        let app = launch()
        app.buttons["Census"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["no-lidar-message"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New tree at my location"].firstMatch.exists)
    }

    @MainActor
    func testTaggingATreeCreatesAProposedTag() {
        let app = launch()
        let tree = app.buttons[firstTreeID].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: mapTimeout))
        tree.tap()
        let tagButton = app.buttons["Tag a limb hazard"].firstMatch
        XCTAssertTrue(tagButton.waitForExistence(timeout: 10))
        tagButton.tap()
        let save = app.navigationBars.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let saved = app.descendants(matching: .any)["tag-saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(saved.label.contains("Proposed"), saved.label)
    }

    @MainActor
    func testMeListsPendingChangesAndTheSimulatedApprovalAppliesThem() {
        let app = launch()
        app.buttons["Census"].firstMatch.tap()
        let confirm = app.buttons["Confirm tree"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        app.buttons["Me"].firstMatch.tap()
        let row = app.descendants(matching: .any)["changeset-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Confirm tree"), row.label)
        XCTAssertTrue(row.label.contains("Pending"), row.label)

        app.buttons["Sync now"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sync-submitted"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, "Pending changes (1)").exists)

        let approve = app.buttons["Simulate trusted approval"].firstMatch
        scroll(app, toReveal: approve)
        approve.tap()
        let applied = app.descendants(matching: .any)["On the map"].firstMatch
        scroll(app, toReveal: applied)
        XCTAssertTrue(applied.waitForExistence(timeout: 10))
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(text(app, "Pending changes (0)").waitForExistence(timeout: 10))
    }

    @MainActor
    func testSettingsChecksTheServerAddressAndTestsTheConnection() {
        let app = launch()
        app.buttons["Me"].firstMatch.tap()
        let settings = app.navigationBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let address = app.textFields["server-address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("http://host/path")
        let testButton = app.buttons["Test connection"].firstMatch
        XCTAssertFalse(testButton.isEnabled)

        // Nothing listens on the discard port, so the test fails fast, and plain http to an IP address passes
        // App Transport Security.
        address.clearText()
        address.typeText("127.0.0.1:9")
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        let status = app.descendants(matching: .any)["connection-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.contains("Not connected"), status.label)
        let error = app.staticTexts["connection-error"].firstMatch
        XCTAssertTrue(error.label.contains("127.0.0.1:9"), error.label)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any)["server-row"].firstMatch
        scroll(app, toReveal: row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("127.0.0.1:9"), row.label)
    }

    /// Against a real Gerardus server, when one is given:
    /// `TEST_RUNNER_CANOPY_GERARDUS_URL=gerardus.local:50061 scripts/test.sh -only-testing:CanopyUITests`.
    @MainActor
    func testConnectingToARealServerShowsItsStatus() throws {
        guard let server = ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"], !server.isEmpty else {
            throw XCTSkip("no Gerardus server given")
        }
        let app = launch()
        app.buttons["Me"].firstMatch.tap()
        let settings = app.navigationBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let address = app.textFields["server-address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(server)
        app.buttons["Test connection"].firstMatch.tap()

        let status = app.descendants(matching: .any)["connection-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Settings connected"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(status.label.contains("Connected"), status.label)
        for label in ["Server version", "Commit", "Uptime", "Round trip"] {
            XCTAssertTrue(text(app, label).exists, "missing \(label)")
        }
    }

    /// A static text matched without regard to case (iOS 18 upper-cases list section headers).
    @MainActor
    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    /// Lists load rows lazily, so swipe until the element exists.
    @MainActor
    private func scroll(_ app: XCUIApplication, toReveal element: XCUIElement, attempts: Int = 6) {
        for _ in 0..<attempts where !element.exists {
            app.swipeUp()
        }
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        return app
    }
}

extension XCUIElement {
    /// Deletes the text in a focused text field.
    func clearText() {
        guard let text = value as? String, !text.isEmpty else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }
}
