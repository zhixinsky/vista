// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CarVista

final class FeaturedWallpaperTests: XCTestCase {
    func testOlderFeedsRemainReadableWithoutComments() throws {
        let data = Data(#"{"items":[{"id":"one","title":"壁纸","description":"","width":20,"height":10000,"likes":2,"liked":false,"preview_url":"https://example.test/p","original_url":"https://example.test/o"}]}"#.utf8)
        let item = try JSONDecoder().decode(ShareFeed.self, from: data).items[0]
        XCTAssertNil(item.comments)
        XCTAssertEqual(item.height, 10000)
    }

    func testCommentCountAndPagingAreDecoded() throws {
        let data = Data(#"{"items":[{"id":"one","author":"车友 12345678","body":"适合夜间","created_at":"2026-11-22T01:00:00Z"}],"has_more":true}"#.utf8)
        let page = try JSONDecoder().decode(ShareCommentPage.self, from: data)
        XCTAssertEqual(page.items[0].body, "适合夜间")
        XCTAssertTrue(page.has_more)
    }

    func testCompatibilityUsesServerLabels() throws {
        let data = Data(#"{"items":[{"id":"a","machine":"iPhone18,2","name":"iPhone 17 Pro Max","system":"iOS 27.3 Beta 1"}]}"#.utf8)
        let feed = try JSONDecoder().decode(CompatibilityFeed.self, from: data)
        XCTAssertEqual(feed.items[0].system, "iOS 27.3 Beta 1")
    }
}
