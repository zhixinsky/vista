import XCTest
@testable import CarVista

final class CatalogPolicyTests: XCTestCase {
    func testLiveAppUsesTheServerList() {
        let remote = [item("海岸")]
        XCTAssertEqual(CatalogPolicy.choose(offline: false, remote: remote, cached: [], bundled: [item("壁纸 1")]), remote)
    }

    func testEmptyServerListDoesNotFallBackToTheAppBundle() {
        let bundled = [item("壁纸 1")]
        XCTAssertEqual(CatalogPolicy.choose(offline: false, remote: [], cached: [item("缓存")], bundled: bundled), [])
    }

    func testFailedRequestKeepsTheLastDownloadedList() {
        let cached = [item("上次的海岸")]
        XCTAssertEqual(CatalogPolicy.choose(offline: false, remote: nil, cached: cached, bundled: [item("壁纸 1")]), cached)
    }

    func testOfflineCatalogUsesBundledWallpapers() {
        let bundled = [item("壁纸 1")]
        XCTAssertEqual(CatalogPolicy.choose(offline: true, remote: [item("海岸")], cached: [item("缓存")], bundled: bundled), bundled)
    }

    private func item(_ title: String) -> CatalogItem {
        CatalogItem(id: title, title: title, kind: .bundledBuiltin(0), remote: nil)
    }
}
