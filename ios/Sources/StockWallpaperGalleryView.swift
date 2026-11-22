// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum StockGallery {
    static let site = URL(string: "https://carplaymaker.top/")!

    struct Item: Decodable, Identifiable, Equatable {
        let name: String
        let file: String
        let url: String
        let thumb: String?
        let width: Int
        let height: Int
        let group: String
        var id: String { file }
        var previewURL: URL? { StockGallery.resolved(thumb ?? url) }
        var originalURL: URL? { StockGallery.resolved(url) }
    }

    private struct Feed: Decodable { let items: [Item] }

    static func resolved(_ path: String) -> URL? {
        guard let url = URL(string: path, relativeTo: site)?.absoluteURL,
              url.scheme == "https", url.host == site.host else { return nil }
        return url
    }

    static func parse(_ data: Data) throws -> [Item] {
        try JSONDecoder().decode(Feed.self, from: data).items.filter {
            $0.group == "stock" && $0.originalURL != nil
        }
    }

    static func list() async throws -> [Item] {
        let endpoint = URL(string: "https://carplaymaker.top/wallpapers/index.json")!
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try parse(data)
    }

    static func download(_ item: Item) async throws -> Data {
        guard let url = item.originalURL else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, response.mimeType?.hasPrefix("image/") == true else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

struct StockWallpaperGalleryView: View {
    @EnvironmentObject private var model: WorkshopModel
    let use: (GalleryPick) -> Void
    @State private var images: [StockGallery.Item] = []
    @State private var selection: StockGallery.Item?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("iOS 27 车机自带壁纸，每种颜色有浅色和深色。").font(.subheadline).foregroundStyle(.secondary)
                if loading && images.isEmpty { ProgressView("正在加载…") }
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                    Button("重试") { Task { await reload() } }.disabled(loading)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 16) {
                    ForEach(images) { item in
                        Button { selection = item } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                GalleryImage(url: item.previewURL, mode: .fill)
                                    .aspectRatio(CGFloat(item.width) / CGFloat(max(item.height, 1)), contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(item.name).font(.subheadline).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
        .task { if images.isEmpty { await reload() } }
        .sheet(item: $selection) { item in
            StockWallpaperDetail(item: item, busy: model.busy) { pick in
                selection = nil
                use(pick)
            }
        }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            images = try await StockGallery.list()
            if images.isEmpty { problem = "暂时没有默认壁纸。" }
        } catch {
            if !Task.isCancelled { problem = "默认壁纸加载失败，请检查网络后重试。" }
        }
    }
}

private struct StockWallpaperDetail: View {
    @Environment(\.dismiss) private var dismiss
    let item: StockGallery.Item
    let busy: Bool
    let use: (GalleryPick) -> Void
    @State private var downloading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GalleryImage(url: item.originalURL, mode: .fit)
                        .aspectRatio(CGFloat(item.width) / CGFloat(max(item.height, 1)), contentMode: .fit)
                    Text(item.name).font(.headline)
                    Text("\(item.width) × \(item.height)").font(.caption).foregroundStyle(.secondary)
                    Button(downloading ? "正在下载…" : "用作壁纸") { download() }
                        .buttonStyle(.borderedProminent).disabled(downloading || busy)
                    if failed { Text("下载失败，请重试。").foregroundStyle(.red) }
                }.padding(16)
            }
            .navigationTitle("默认壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(downloading) }
            .interactiveDismissDisabled(downloading)
        }
    }

    private func download() {
        downloading = true
        failed = false
        Task {
            defer { downloading = false }
            do { use(GalleryPick(data: try await StockGallery.download(item), source: "stock")) }
            catch { failed = true }
        }
    }
}
