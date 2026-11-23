import XCTest
import UIKit
@testable import CarVista

final class AutomaticWallpaperDefaultsTests: XCTestCase {
    private func completeSet() -> [String: Data] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.pngData()!
        var result: [String: Data] = [:]
        for group in ["Blue", "Purple", "Grey", "Green", "Brown", "Red"] {
            for mode in ["Dark", "Light"] { result["\(group)-\(mode)"] = image }
        }
        return result
    }
    func testCompleteSixPairsAreAccepted() {
        XCTAssertTrue(AutomaticWallpaperDefaults.validate(completeSet()))
    }
    func testElevenImagesCannotBePublishedForRecovery() {
        var images = completeSet()
        images.removeValue(forKey: "Blue-Light")
        XCTAssertFalse(AutomaticWallpaperDefaults.validate(images))
    }
    func testCorruptDefaultRejectsWholeSet() {
        var images = completeSet()
        images["Blue-Light"] = Data("not an image".utf8)
        XCTAssertFalse(AutomaticWallpaperDefaults.validate(images))
    }
    func testUnknownAppearanceCannotReplaceMissingLight() {
        var images = completeSet()
        images["Blue-Other"] = images.removeValue(forKey: "Blue-Light")
        XCTAssertFalse(AutomaticWallpaperDefaults.validate(images))
    }
    func testTwelveImagesAcrossSevenGroupsAreRejected() {
        var images = completeSet()
        images["Teal-Light"] = images.removeValue(forKey: "Blue-Light")
        XCTAssertFalse(AutomaticWallpaperDefaults.validate(images))
    }
}
