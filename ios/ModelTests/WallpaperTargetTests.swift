// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CarVista

final class WallpaperTargetTests: XCTestCase {
    func testMissingLightRetainsIdentityButCannotBeWrittenAsExistingFile() {
        let target = WallpaperTarget(raw: ["path": "/cache/Blue-Light.cpbitmap", "mode": "浅色",
            "width": 1440, "height": 810, "missing": true, "repairable": true])
        XCTAssertEqual(target.id, "/cache/Blue-Light.cpbitmap")
        XCTAssertEqual(target.mode, "浅色")
        XCTAssertFalse(target.editable)
        XCTAssertTrue(target.repairable)
    }

    func testUnreadableExistingFileCannotUseMissingFileRepair() {
        let target = WallpaperTarget(raw: ["path": "/cache/Blue-Light.cpbitmap", "mode": "浅色",
            "width": 0, "height": 0, "repairable": true])
        XCTAssertFalse(target.editable)
        XCTAssertFalse(target.repairable)
        XCTAssertFalse(target.status.isEmpty)
    }

    func testMissingFileWithoutValidatedCopyCannotBeRepaired() {
        let target = WallpaperTarget(raw: ["missing": true, "repairable": false])
        XCTAssertFalse(target.editable)
        XCTAssertFalse(target.repairable)
    }

    func testLegacyValidScanRemainsEditable() {
        let target = WallpaperTarget(raw: ["width": 1440, "height": 810, "mode": "浅色"])
        XCTAssertTrue(target.editable)
        XCTAssertFalse(target.repairable)
    }
}
