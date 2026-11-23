import XCTest
@testable import CarVista

final class CarPlayCompatibilityTests: XCTestCase {
    func testSupportedRanges() {
        XCTAssertTrue(CarPlayCompatibility.supported(version: "26.0", build: ""))
        XCTAssertTrue(CarPlayCompatibility.supported(version: "27.2.1", build: "24B156"))
        XCTAssertTrue(CarPlayCompatibility.supported(version: "27.3", build: "24C5037i"))
    }
    func testLaterBuildsAreNotMisidentifiedAsBetaOne() {
        XCTAssertFalse(CarPlayCompatibility.supported(version: "27.3", build: "24C5049d"))
        XCTAssertFalse(CarPlayCompatibility.supported(version: "27.3", build: ""))
        XCTAssertFalse(CarPlayCompatibility.supported(version: "27.4", build: "24C5037i"))
        XCTAssertFalse(CarPlayCompatibility.supported(version: "18.6", build: ""))
        XCTAssertFalse(CarPlayCompatibility.supported(version: "28.0", build: ""))
    }
}
