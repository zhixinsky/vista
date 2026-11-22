// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CarVista

final class StockGalleryTests: XCTestCase {
    func testParseKeepsOnlyHostedStockWallpapers() throws {
        let json = """
        {"items":[
          {"name":"蓝·深色","file":"WallpaperBlue-Dark.jpg","url":"wallpapers/WallpaperBlue-Dark.jpg","thumb":"wallpapers/thumbs/WallpaperBlue-Dark.jpg","width":2420,"height":1668,"group":"stock"},
          {"name":"外部","file":"x.jpg","url":"https://evil.example/x.jpg","width":1,"height":1,"group":"stock"},
          {"name":"用户","file":"user-01.jpg","url":"wallpapers/user-01.jpg","width":1,"height":1,"group":"user"}
        ]}
        """.data(using: .utf8)!
        let items = try StockGallery.parse(json)
        XCTAssertEqual(items.map(\.name), ["蓝·深色"])
        XCTAssertEqual(items.first?.originalURL?.absoluteString, "https://carplaymaker.top/wallpapers/WallpaperBlue-Dark.jpg")
        XCTAssertEqual(items.first?.previewURL?.absoluteString, "https://carplaymaker.top/wallpapers/thumbs/WallpaperBlue-Dark.jpg")
    }
}
