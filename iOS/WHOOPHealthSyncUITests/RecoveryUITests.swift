import XCTest

final class RecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func app(language: String, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", language]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    func testT27SpanishDashboardAndDisabledRecoveryOption() {
        let app = app(language: "spanish")
        XCTAssertTrue(app.staticTexts["HRV de recuperación"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Opciones"].tap()
        let button = app.buttons["recovery.importHistory"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(app.staticTexts["Desactivada"].exists || app.staticTexts["Requiere iOS 27"].exists)
        attach("Spanish recovery options", app)
    }
    func testT27EnglishDashboardAndDisabledRecoveryOption() {
        let app = app(language: "english")
        XCTAssertTrue(app.staticTexts["Recovery HRV"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Options"].tap()
        let button = app.buttons["recovery.importHistory"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(app.staticTexts["Disabled"].exists || app.staticTexts["Requires iOS 27"].exists)
        attach("English recovery options", app)
    }
    func testT27LargeTypeHasAccessibleStateAndActions() {
        let app = app(language: "spanish", largeType: true)
        for _ in 0..<4 {
            if app.staticTexts["recovery.dashboard.status"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["recovery.dashboard.status"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Opciones"].tap()
        XCTAssertTrue(app.staticTexts["recovery.status"].waitForExistence(timeout: 5))
        attach("Large type", app)
    }
    func testT26ExistingSignInStillOpensAndCanBeCancelled() {
        let app = app(language: "english")
        let connect = app.buttons.matching(NSPredicate(format: "label IN %@", ["Connect WHOOP", "Reconnect"])).firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].exists); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Recovery HRV"].exists)
    }
    func testRecoveryReadOnlyComparisonIsAvailableAndLocalized() {
        let app = app(language: "spanish")
        XCTAssertTrue(app.staticTexts["HRV de recuperación"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Opciones"].tap()
        let importButton = app.buttons["recovery.importHistory"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5)); XCTAssertFalse(importButton.isEnabled)
        let diagnostic = app.buttons["recovery.compareValues"]
        for _ in 0..<6 {
            if diagnostic.exists && diagnostic.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        XCTAssertEqual(diagnostic.label, "Comparar valores de recuperación con WHOOP")
        XCTAssertTrue(diagnostic.isEnabled)
        XCTAssertTrue(diagnostic.isHittable)
        attach("Read-only recovery comparison", app)
    }

    func testRecoverySetupRequiresExplicitChecksAndEnablesDedicatedImport() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Recovery setup requires iOS 27") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated recovery QA simulator") }
        let app = XCUIApplication(); app.launchArguments = ["-appLanguage", "spanish", "-whoopRecoveryUITest"]
        app.launch()
        app.tabBars.buttons["Opciones"].tap()
        let configure = app.buttons["recovery.configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10)); XCTAssertTrue(configure.isEnabled); configure.tap()
        let enable = app.buttons["recovery.enable"]
        XCTAssertFalse(enable.exists && enable.isEnabled)
        let authorize = app.buttons["recovery.authorize"]
        for _ in 0..<4 { if authorize.exists && authorize.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(authorize.waitForExistence(timeout: 5)); authorize.tap()
        attach("Recovery setup after authorization", app)
        let native = app.switches["recovery.confirmNoNativeExport"]
        for _ in 0..<4 { if native.exists && native.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(native.waitForExistence(timeout: 5)); native.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(native.value as? String, "1")
        let full = app.switches["recovery.confirmFullReading"]
        for _ in 0..<4 { if full.exists && full.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(full.exists); full.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(full.value as? String, "1")
        for _ in 0..<4 { if enable.isHittable { break }; app.swipeUp() }
        attach("Recovery setup before enabling", app)
        XCTAssertTrue(enable.isEnabled)
        attach("Recovery authorization confirmations", app); enable.tap()
        let importButton = app.buttons["recovery.importHistory"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5)); XCTAssertTrue(importButton.isEnabled); importButton.tap()
        XCTAssertTrue(app.staticTexts["Histórico indicado importado"].waitForExistence(timeout: 5))
        attach("Declared history imported", app)
        app.terminate()
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
