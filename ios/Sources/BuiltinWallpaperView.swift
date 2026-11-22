// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BuiltinWallpaper: Identifiable {
    let index: Int
    var id: String { "Builtin\(index)" }
    var title: String { "壁纸 \(index + 1)" }
    var previewName: String { "\(id)Preview" }
    static let all = (0..<9).map { BuiltinWallpaper(index: $0) }

    func originalURL(in bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: id, withExtension: "jpg", subdirectory: "BuiltinWallpapers") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return url
    }
}

struct BuiltinWallpaperPreview: View {
    let wallpaper: BuiltinWallpaper

    var body: some View {
        Image(wallpaper.previewName).resizable().scaledToFit()
    }
}
