// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO

struct MakerPhoto: Identifiable, Codable, Equatable {
    let id: UUID
    var adjustment = WallpaperAdjustment()
    var sourceName: String?
    var remoteSource: String?
    var remoteAssetID: String?
    var url: URL { MakerDraft.directory.appendingPathComponent("\(id).source") }
}

enum MakerDraft {
    static var directory: URL { WallpaperStorage.library.appendingPathComponent("MakerDrafts") }
    static var manifest: URL { directory.appendingPathComponent("photos.json") }
    static func load() -> [MakerPhoto] {
        guard let data = try? Data(contentsOf: manifest), let photos = try? JSONDecoder().decode([MakerPhoto].self, from: data) else { return [] }
        return Array(photos.filter { FileManager.default.fileExists(atPath: $0.url.path) }.prefix(6))
    }
    static func save(_ photos: [MakerPhoto]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(photos).write(to: manifest, options: .atomic)
    }
    static func importPhoto(data: Data) throws -> MakerPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = MakerPhoto(id: UUID())
        try data.write(to: photo.url, options: .atomic)
        return photo
    }
}
