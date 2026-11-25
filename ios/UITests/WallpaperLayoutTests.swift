import XCTest

final class WallpaperLayoutTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPreviewKeepsFixedRatioAndButtonsStayBelowIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES", "-MakerUITestFixture", "-CarVistaOfflineCatalog"]
        app.launch()
        let preview = app.descendants(matching: .any)["maker.preview"].firstMatch
        let crop = app.buttons["maker.adjust"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(crop.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(preview.frame.width, 0)
        XCTAssertEqual(preview.frame.width / preview.frame.height, 16.0 / 9.0, accuracy: 0.04)
        XCTAssertGreaterThanOrEqual(crop.frame.minY, preview.frame.maxY)
        XCTAssertTrue(crop.isHittable)
        crop.tap()
        XCTAssertTrue(app.navigationBars["裁剪"].waitForExistence(timeout: 5))
    }

    func testReturningToTopKeepsHeaderAndControlsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES", "-MakerUITestFixture", "-CarVistaOfflineCatalog"]
        app.launch()
        XCTAssertTrue(app.buttons["maker.adjust"].waitForExistence(timeout: 15))
        app.swipeUp()
        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["让你的 CarPlay 焕然一新"].isHittable)
        XCTAssertTrue(app.buttons["maker.adjust"].isHittable)
        app.buttons["maker.adjust"].tap()
        XCTAssertTrue(app.navigationBars["裁剪"].waitForExistence(timeout: 5))
    }
}
