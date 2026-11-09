import XCTest

/// Aligning a tree's rings against a saved scan, with no AR session. A simulator cannot scan, so the app records a
/// synthetic trunk scan, 0.5 m across, on a tree first (`-canopy.seedScan`).
final class ScanAlignmentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheTrunksRingsSnapToASavedScanAndAreSaved() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-canopy.seedScan"]
        app.launch()
        app.buttons["Me"].firstMatch.tap()
        let scans = app.buttons["scans-link"].firstMatch
        XCTAssertTrue(scans.waitForExistence(timeout: 30))
        scans.tap()
        let align = app.buttons["align-scan"].firstMatch
        XCTAssertTrue(align.waitForExistence(timeout: 10))
        align.tap()

        XCTAssertTrue(app.otherElements["align-scene"].firstMatch.waitForExistence(timeout: 30))
        // Nothing was fitted to this scan yet, so its trunk rings start snapped to it: the ground and breast height,
        // and the crown's base when the scan reaches it.
        let note = app.staticTexts["align-note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        XCTAssertTrue(note.label.hasPrefix("Snapped") && note.label.contains("trunk rings"), note.label)
        XCTAssertTrue(app.buttons["align-ring-menu"].firstMatch.label.contains("0.50"))

        app.buttons["align-snap"].firstMatch.tap()
        wait(for: note, toSay: "Fitted to the scan 1.37")
        // The mesh's slices cross some triangles' diagonals, a little inside the trunk: within a millimetre of 0.5 m.
        let diameter = note.label.ranges(of: /\d\.\d{3}/).last.flatMap { Double(note.label[$0]) }
        XCTAssertEqual(diameter ?? 0, 0.5, accuracy: 0.0015, note.label)
        attachScreenshot(app, named: "Rings on a saved scan")

        app.buttons["align-save"].firstMatch.tap()
        wait(for: note, toSay: "Saved on this phone")

        // Opened again, the rings come back as saved.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(align.waitForExistence(timeout: 10))
        align.tap()
        XCTAssertTrue(app.otherElements["align-scene"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["align-ring-menu"].firstMatch.label.contains("(scan)"))
        XCTAssertFalse(app.buttons["align-save"].firstMatch.isEnabled)
        app.buttons["Close"].firstMatch.tap()
    }

    @MainActor
    private func wait(for element: XCUIElement, toSay text: String, timeout: TimeInterval = 30) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, element.label)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
