import XCTest

/// Queries name the element type (`app.staticTexts`, `app.otherElements`, `app.buttons`): matching any type
/// snapshots every element on screen, which times out on CI runners while the map shows 200 trees.
final class LaunchTests: XCTestCase {
    /// The first query against the map snapshots all 200 tree annotations, which takes 15 s or more on CI runners.
    let mapTimeout: TimeInterval = 90
    /// The first synthetic candidate in Fixtures/ggp/tree-candidates.geojson.
    let firstTreeID = "tree-17174592-BB4C-47D2-B2B8-FE45CFF2DFB5"
    /// A region round that candidate small enough to be drawn in full: the whole park is only shaded tile by tile.
    let nearFirstTree = ["-canopy.mapStart", "37.77075,-122.48306,150"]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEveryTabIsReachable() {
        let app = launch()
        waitForMap(app)
        for name in ["Map", "Census", "Me"] {
            let tab = app.buttons[name].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "missing tab \(name)")
            tab.tap()
        }
        // Limb tagging is hidden for now (Features.limbTagging).
        XCTAssertFalse(app.buttons["Tag"].exists)
    }

    @MainActor
    func testMapShowsTheSummaryOfTheFixtureCandidates() {
        let app = launch()
        XCTAssertTrue(app.otherElements["summary-bar"].firstMatch.waitForExistence(timeout: mapTimeout))
        XCTAssertTrue(
            app.otherElements["Estimated: 200"].firstMatch.waitForExistence(timeout: mapTimeout))
        XCTAssertTrue(app.otherElements["Confirmed: 0"].firstMatch.exists)
    }

    @MainActor
    func testConfirmingATreeFromItsSheetMakesItProposed() {
        let app = launch(nearFirstTree)
        waitForMap(app)
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
        XCTAssertTrue(app.staticTexts["Proposed"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        let coverage = app.otherElements["Coverage: 0.5\u{202F}%"].firstMatch
        XCTAssertTrue(coverage.waitForExistence(timeout: 10))
    }

    @MainActor
    func testTreesFilterByStatusAndTheMapCanLeaveOutAppleMaps() {
        let app = launch(nearFirstTree)
        waitForMap(app)
        let tree = app.buttons[firstTreeID].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: mapTimeout))
        let detected = app.buttons["status-filter-detected"].firstMatch
        XCTAssertTrue(detected.waitForExistence(timeout: 10))
        XCTAssertEqual(detected.value as? String, "Shown")
        detected.tap()
        XCTAssertEqual(detected.value as? String, "Hidden")
        XCTAssertTrue(tree.waitForNonExistence(timeout: 10))
        detected.tap()
        XCTAssertTrue(tree.waitForExistence(timeout: 30))

        app.buttons["Layers"].firstMatch.tap()
        let gerardus = app.buttons["Gerardus 3D"].firstMatch
        XCTAssertTrue(gerardus.waitForExistence(timeout: 10))
        gerardus.tap()
        // The wireframe map draws trees itself, so there are no marker views to snapshot.
        XCTAssertTrue(app.descendants(matching: .any)["wireframe-map"].firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Gerardus 3D"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Layers"].firstMatch.tap()
        app.buttons["Apple Maps"].firstMatch.tap()
        XCTAssertTrue(tree.waitForExistence(timeout: mapTimeout))

        // Debug builds show the admin flags to everyone; OpenStreetMap is off until turned on.
        app.buttons["Me"].firstMatch.tap()
        app.navigationBars.buttons["Settings"].firstMatch.tap()
        let osm = app.switches["admin-use-osm"].firstMatch
        scroll(app, toReveal: osm)
        XCTAssertTrue(osm.waitForExistence(timeout: 10))
        XCTAssertEqual(osm.value as? String, "0")
    }

    @MainActor
    func testCensusExplainsWhenThereIsNoLiDAR() {
        // The simulator has no LiDAR, so Census offers the verification list.
        let app = launch()
        app.buttons["Census"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["no-lidar-message"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New tree at my location"].firstMatch.exists)
    }

    @MainActor
    func testTaggingATreeCreatesAProposedTag() throws {
        try XCTSkipIf(true, "Limb tagging is hidden for now (Features.limbTagging).")
        let app = launch()
        waitForMap(app)
        let tree = app.buttons[firstTreeID].firstMatch
        XCTAssertTrue(tree.waitForExistence(timeout: mapTimeout))
        tree.tap()
        let tagButton = app.buttons["Tag a limb hazard"].firstMatch
        XCTAssertTrue(tagButton.waitForExistence(timeout: 10))
        tagButton.tap()
        let save = app.navigationBars.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let saved = app.staticTexts["tag-saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
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
        let row = app.buttons["changeset-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Confirm tree"), row.label)
        XCTAssertTrue(row.label.contains("Pending"), row.label)
        // What it still needs, in words.
        XCTAssertTrue(row.label.contains("simulated server"), row.label)
        XCTAssertTrue(app.buttons["scans-link"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["Sync now"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["sync-submitted"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, "Your proposals (1)").exists)

        let approve = app.buttons["Simulate trusted approval"].firstMatch
        scroll(app, toReveal: approve)
        approve.tap()
        let applied = app.staticTexts["On the map"].firstMatch
        scroll(app, toReveal: applied)
        XCTAssertTrue(applied.waitForExistence(timeout: 10))
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(text(app, "Your proposals (0)").waitForExistence(timeout: 10))
    }

    @MainActor
    func testAScanShowsAPictureOfItsMeshAndGoesToItsTreeOnTheMap() {
        // The simulator cannot scan, so Your scans records a synthetic one on the first fixture tree.
        let app = launch(["-canopy.sampleScan", "YES"])
        waitForMap(app)
        // A screen left open over the map, which the Map tab keeps while Me is shown.
        app.buttons["Layers"].firstMatch.tap()
        let surveyed = app.buttons["Surveyed cells (L16)"].firstMatch
        XCTAssertTrue(surveyed.waitForExistence(timeout: 10))
        surveyed.tap()
        XCTAssertTrue(app.navigationBars["Surveyed cells"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Me"].firstMatch.tap()
        let scans = app.buttons["scans-link"].firstMatch
        scroll(app, toReveal: scans)
        XCTAssertTrue(scans.waitForExistence(timeout: 10))
        scans.tap()

        // The picture is drawn from the mesh, off the main thread.
        let picture = app.buttons["scan-preview"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 30))
        let drawn = expectation(for: NSPredicate(format: "value == 'Drawn'"), evaluatedWith: picture)
        wait(for: [drawn], timeout: 60)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Your scans"
        shot.lifetime = .keepAlways
        add(shot)

        // Show on map goes to the Map tab and opens the tree's sheet, with the scan as its evidence.
        app.buttons["scan-show-on-map"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Map"].firstMatch.isSelected)
        XCTAssertTrue(app.staticTexts["Evidence scans"].firstMatch.exists)
        let onMap = XCTAttachment(screenshot: app.screenshot())
        onMap.name = "Show on map"
        onMap.lifetime = .keepAlways
        add(onMap)
        // Under the sheet is the map, not the screen that was open over it.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["summary-bar"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Surveyed cells"].firstMatch.exists)
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
        let status = app.staticTexts["connection-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.contains("Not connected"), status.label)
        let error = app.staticTexts["connection-error"].firstMatch
        XCTAssertTrue(error.label.contains("127.0.0.1:9"), error.label)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["server-row"].firstMatch
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

        let status = app.staticTexts["connection-status"].firstMatch
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

    /// Waits for the map to finish loading the fixtures. Snapshotting it while it is still adding its 200 markers can
    /// time out the accessibility query on CI runners.
    @MainActor
    private func waitForMap(_ app: XCUIApplication) {
        XCTAssertTrue(app.otherElements["Estimated: 200"].firstMatch.waitForExistence(timeout: mapTimeout))
    }

    /// Lists load rows lazily, so swipe until the element exists.
    @MainActor
    private func scroll(_ app: XCUIApplication, toReveal element: XCUIElement, attempts: Int = 6) {
        for _ in 0..<attempts where !element.exists {
            app.swipeUp()
        }
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + arguments
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
