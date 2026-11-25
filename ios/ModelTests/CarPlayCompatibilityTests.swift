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
    func testKernelCandidateRequiresHardwareModel() {
        XCTAssertEqual(CarPlayCompatibility.candidateBackend(version: "17.7.2", build: "", machine: "iPhone15,3"), .kernelDirect)
        XCTAssertFalse(CarPlayCompatibility.supported(version: "17.7.2", build: ""))
        XCTAssertNil(CarPlayCompatibility.candidateBackend(version: "17.8", build: "", machine: "iPhone15,3"))
        XCTAssertNil(CarPlayCompatibility.candidateBackend(version: "17.6", build: "", machine: "iPad13,1"))
        XCTAssertNil(CarPlayCompatibility.candidateBackend(version: "17.6", build: "", machine: "iPhone18,1"))
    }
    func testIOS18KernelVersionBoundaries() {
        for version in ["17.0", "17.7.99", "18.0", "18.6.2", "18.7", "18.7.1"] {
            XCTAssertEqual(CarPlayCompatibility.candidateBackend(version: version, build: "", machine: "iPhone15,3"), .kernelDirect)
        }
        for version in ["17.8", "18.7.2", "18.8", "19.0", "25.0"] {
            XCTAssertNil(CarPlayCompatibility.candidateBackend(version: version, build: "", machine: "iPhone15,3"))
        }
        XCTAssertNil(CarPlayCompatibility.candidateBackend(version: "18.7.1", build: "", machine: "iPad13,1"))
        XCTAssertNil(CarPlayCompatibility.candidateBackend(version: "18.7.1", build: "", machine: "iPhone18,1"))
    }
    func testMalformedVersionsAreRejected() {
        for version in ["", "26.bad", "26..1", "26.-1", "27.3.0.1"] {
            XCTAssertFalse(CarPlayCompatibility.supported(version: version, build: "24C5037i"))
        }
    }
    func testExistingSystemsAlwaysKeepContainerBackend() {
        for machine in ["iPhone15,3", "iPhone18,1", "iPad13,1"] {
            for version in ["26.0", "26.7.3", "27.0", "27.2"] {
                XCTAssertEqual(CarPlayCompatibility.candidateBackend(version: version, build: "", machine: machine), .containerAccess)
            }
            XCTAssertEqual(CarPlayCompatibility.candidateBackend(version: "27.3", build: "24C5037i", machine: machine), .containerAccess)
            XCTAssertNil(CarPlayCompatibility.candidateBackend(version: "27.3", build: "24C5049d", machine: machine))
        }
    }
}
