// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
import UIKit

enum CatalogCollection: String {
    case builtin
    case buick
}

struct RemoteAsset: Codable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let previewURL: URL
    let originalURL: URL
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, width, height
        case previewURL = "preview_url"
        case originalURL = "original_url"
        case updatedAt = "updated_at"
    }
}

struct CatalogItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case bundledBuiltin(Int)
        case bundledBuick(Int)
        case remote
    }
    let id: String
    let title: String
    let kind: Kind
    let remote: RemoteAsset?
}

enum CatalogPolicy {
    /// Offline UI tests keep the images shipped in the app. A live app uses the
    /// server list, including when that list is empty. A failed request keeps
    /// the last list that was downloaded.
    static func choose(offline: Bool, remote: [CatalogItem]?, cached: [CatalogItem], bundled: [CatalogItem]) -> [CatalogItem] {
        if offline { return bundled }
        if let remote { return remote }
        return cached
    }
}

enum ServiceGate {
    static var enabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("-CarVistaOfflineCatalog") { return false }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        return true
    }

    static var baseURL: URL {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-CarVistaAPIBase"), index + 1 < args.count, let url = URL(string: args[index + 1]) {
            return url
        }
        return URL(string: "https://carplayv2.dokor.cn")!
    }

    static func join(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, part in
            url.appending(path: String(part))
        }
    }
}

struct CatalogLoad {
    var items: [CatalogItem]
    var note: String
}

enum CatalogLibrary {
    private struct Feed: Decodable { let items: [RemoteAsset] }

    static func bundled(_ collection: CatalogCollection) -> [CatalogItem] {
        switch collection {
        case .builtin:
            return BuiltinWallpaper.all.map { item in
                CatalogItem(id: item.id, title: item.title, kind: .bundledBuiltin(item.index), remote: nil)
            }
        case .buick:
            return (1...16).map { index in
                CatalogItem(id: String(format: "buick-%02d", index), title: "别克壁纸 \(index)", kind: .bundledBuick(index), remote: nil)
            }
        }
    }

    static func initial(_ collection: CatalogCollection) -> CatalogLoad {
        if !ServiceGate.enabled { return CatalogLoad(items: bundled(collection), note: "") }
        let saved = cached(collection)
        return CatalogLoad(items: saved, note: saved.isEmpty ? "正在从后台获取壁纸…" : "")
    }

    static func refresh(_ collection: CatalogCollection) async -> CatalogLoad {
        if !ServiceGate.enabled { return CatalogLoad(items: bundled(collection), note: "") }
        if let remote = await fetch(collection) {
            store(remote, collection)
            let note = remote.isEmpty ? "后台暂时没有已发布的壁纸。" : ""
            return CatalogLoad(items: remote, note: note)
        }
        let saved = cached(collection)
        return CatalogLoad(items: saved, note: saved.isEmpty ? "无法连接后台，请检查网络。" : "")
    }

    static func thumbnail(_ item: CatalogItem) async -> UIImage? {
        switch item.kind {
        case .bundledBuiltin(let index):
            return UIImage(named: BuiltinWallpaper(index: index).previewName)
        case .bundledBuick(let index):
            let stem = String(format: "%02d-preview", index)
            guard let url = Bundle.main.url(forResource: stem, withExtension: "jpg", subdirectory: "BuiltinWallpapers/BuickGallery") else { return nil }
            return UIImage(contentsOfFile: url.path)
        case .remote:
            guard let asset = item.remote else { return nil }
            guard let file = try? await cachedFile(ServiceClient.publicURL(asset.previewURL), name: fileName("preview", asset, "jpg")) else { return nil }
            return UIImage(contentsOfFile: file.path)
        }
    }

    static func originalData(_ item: CatalogItem) async throws -> Data {
        switch item.kind {
        case .bundledBuiltin(let index):
            return try Data(contentsOf: BuiltinWallpaper(index: index).originalURL())
        case .bundledBuick(let index):
            let stem = String(format: "%02d", index)
            guard let url = Bundle.main.url(forResource: stem, withExtension: "jpeg", subdirectory: "BuiltinWallpapers/BuickGallery") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try Data(contentsOf: url)
        case .remote:
            guard let asset = item.remote else { throw CocoaError(.fileReadNoSuchFile) }
            let ext = asset.originalURL.pathExtension.isEmpty ? "jpg" : asset.originalURL.pathExtension
            let file = try await cachedFile(ServiceClient.publicURL(asset.originalURL), name: fileName("original", asset, ext))
            return try Data(contentsOf: file)
        }
    }

    private static func fetch(_ collection: CatalogCollection) async -> [CatalogItem]? {
        let path = collection == .builtin ? "builtin" : "buick"
        let url = ServiceGate.join("v1/catalog/\(path)")
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(Feed.self, from: data).items.map {
                CatalogItem(id: $0.id, title: $0.title, kind: .remote, remote: $0)
            }
        } catch {
            return nil
        }
    }

    static func savedAssets(_ collection: String) -> [CatalogItem] {
        guard let data = savedData("catalog-\(collection)"),
              let items = try? JSONDecoder().decode([RemoteAsset].self, from: data) else { return [] }
        return items.map { CatalogItem(id: $0.id, title: $0.title, kind: .remote, remote: $0) }
    }

    static func rememberAssets(_ items: [CatalogItem], collection: String) {
        let assets = items.compactMap(\.remote)
        guard let data = try? JSONEncoder().encode(assets) else { return }
        rememberData(data, name: "catalog-\(collection)")
    }

    static func savedThumbnail(_ item: CatalogItem) -> UIImage? {
        guard let asset = item.remote,
              let file = try? directory().appendingPathComponent(fileName("preview", asset, "jpg")),
              imageFile(file) else { return nil }
        return UIImage(contentsOfFile: file.path)
    }

    static func savedImage(_ url: URL) -> UIImage? {
        let remote = ServiceClient.publicURL(url)
        guard let file = try? directory().appendingPathComponent(imageName(remote)), imageFile(file) else { return nil }
        return UIImage(contentsOfFile: file.path)
    }

    static func cachedImage(_ url: URL) async -> UIImage? {
        let remote = ServiceClient.publicURL(url)
        guard let file = try? await cachedFile(remote, name: imageName(remote)) else { return nil }
        return UIImage(contentsOfFile: file.path)
    }

    static func rememberData(_ data: Data, name: String) {
        guard let url = listFile(name) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func savedData(_ name: String) -> Data? {
        guard let url = listFile(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func cached(_ collection: CatalogCollection) -> [CatalogItem] {
        savedAssets(collection.rawValue)
    }

    private static func store(_ items: [CatalogItem], _ collection: CatalogCollection) {
        rememberAssets(items, collection: collection.rawValue)
    }

    private static func listFile(_ name: String) -> URL? {
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, let folder = try? directory() else { return nil }
        return folder.appendingPathComponent("\(safe).json")
    }

    private static func imageName(_ url: URL) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in Data(url.absoluteString.utf8) {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "remote-\(String(hash, radix: 16)).img"
    }

    private static func cachedFile(_ remote: URL, name: String) async throws -> URL {
        let destination = try directory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            if imageFile(destination) { return destination }
            try? FileManager.default.removeItem(at: destination)
        }
        let request = URLRequest(url: remote, timeoutInterval: 30)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), imageFile(temporary) else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func imageFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 8), header.count >= 3 else { return false }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        return header.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func fileName(_ prefix: String, _ asset: RemoteAsset, _ ext: String) -> String {
        let stamp = asset.updatedAt.replacingOccurrences(of: ":", with: "-")
        return "\(prefix)-\(asset.id)-\(stamp).\(ext)"
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("CarVistaService", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

struct CatalogThumb: View {
    let item: CatalogItem
    @State private var image: UIImage?
    @State private var failed = false

    init(item: CatalogItem) {
        self.item = item
        _image = State(initialValue: CatalogLibrary.savedThumbnail(item))
    }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed {
                Label("图片加载失败", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(item.id)-\(item.remote?.updatedAt ?? "")") {
            let loaded = await CatalogLibrary.thumbnail(item)
            image = loaded
            failed = loaded == nil
        }
    }
}

@MainActor
final class CatalogStore: ObservableObject {
    let collection: CatalogCollection
    @Published private(set) var items: [CatalogItem]
    @Published private(set) var note: String

    init(collection: CatalogCollection) {
        self.collection = collection
        let load = CatalogLibrary.initial(collection)
        items = load.items
        note = load.note
    }

    func refresh() async {
        let load = await CatalogLibrary.refresh(collection)
        items = load.items
        note = load.note
    }
}
