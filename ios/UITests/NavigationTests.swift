import XCTest

final class NavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testSharedSectionOpensGallery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES", "-CarVistaOfflineCatalog"]
        app.launch()
        let shortcut = app.buttons["wallpaper.shared"]
        for _ in 0..<3 { if shortcut.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        shortcut.tap()
        XCTAssertTrue(app.navigationBars["图库"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["当前无法连接后台。"].waitForExistence(timeout: 5))
        capture(app, "10-Shared-Gallery")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testHomeAndOfflineWorkflow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES", "-CarVistaOfflineCatalog"]
        app.launch()
        XCTAssertTrue(app.navigationBars["壁纸"].waitForExistence(timeout: 15))
        capture(app, "01-Home")
        XCTAssertTrue(app.navigationBars["壁纸"].waitForExistence(timeout: 5))
        capture(app, "02-Wallpaper-NoCarRequired")
        app.tabBars.buttons["历史记录"].tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 5))
        capture(app, "03-History")
        app.tabBars.buttons["壁纸"].tap()
        let tools = app.buttons["wallpaper.tools"]
        tools.tap()
        app.buttons["壁纸缓存"].tap()
        XCTAssertTrue(app.navigationBars["CarPlay 壁纸缓存"].waitForExistence(timeout: 5))
        capture(app, "04-Cache")
        app.tabBars.buttons["图库"].tap()
        XCTAssertTrue(app.navigationBars["图库"].waitForExistence(timeout: 5))
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture(app, "05-Settings")
    }
    func testFirstLaunchGuide() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "NO", "-CarVistaOfflineCatalog"]
        app.launch()
        XCTAssertTrue(app.buttons["guide.done"].waitForExistence(timeout: 15))
        capture(app, "06-FirstLaunchGuide")
        app.buttons["guide.done"].tap()
        XCTAssertTrue(app.navigationBars["壁纸"].waitForExistence(timeout: 5))
    }
    func testMakerPresetsAndAdjustment() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES", "-MakerUITestFixture", "-CarVistaOfflineCatalog"]
        app.launch()
        XCTAssertTrue(app.buttons["maker.adjust"].waitForExistence(timeout: 15))
        capture(app, "07-Maker-Photo")
        app.buttons["maker.adjust"].tap()
        XCTAssertTrue(app.navigationBars["裁剪"].waitForExistence(timeout: 5))
        app.buttons["crop.fineControls"].tap()
        let move = app.buttons["左边向右移动 1 像素"]
        XCTAssertTrue(move.waitForExistence(timeout: 10))
        move.tap()
        capture(app, "09-Adjustment")
        app.buttons["还原"].tap()
        app.buttons["确定"].tap()
        XCTAssertTrue(app.navigationBars["壁纸"].waitForExistence(timeout: 5))
    }
}
