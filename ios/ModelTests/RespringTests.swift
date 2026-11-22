// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CarVista

@MainActor
final class RespringTests: XCTestCase {
    func testSimulatorDoesNotLoadRespringPayload() {
        #if targetEnvironment(simulator)
        let controller = RespringController()
        controller.start()
        XCTAssertFalse(controller.active)
        XCTAssertNil(controller.webView)
        XCTAssertTrue(controller.message.contains("模拟器"))
        controller.stop("已取消")
        controller.stop("已取消")
        XCTAssertFalse(controller.active)
        XCTAssertNil(controller.webView)
        #endif
    }
}
