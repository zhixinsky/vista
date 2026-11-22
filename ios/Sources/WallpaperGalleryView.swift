// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

private struct BingWallpaper: Decodable, Identifiable {
    let url: String
    let urlbase: String?
    let title: String?
    let copyright: String?
    var id: String { urlbase ?? url }
    var name: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "Bing 每日壁纸" }
    /// The gallery imports the UHD file. Current Bing UHD images are 3840×2160;
    /// older entries fall back to the size written in the image URL.
    var resolutionLabel: String? {
        if let urlbase, !urlbase.isEmpty { return "3840 × 2160" }
        guard let match = url.range(of: #"(\d{3,5})x(\d{3,5})"#, options: .regularExpression) else { return nil }
        let parts = url[match].split(separator: "x")
        guard parts.count == 2 else { return nil }
        return "\(parts[0]) × \(parts[1])"
    }

    func imageURL(size: String? = nil) -> URL? {
        let path = size.flatMap { size in urlbase.map { "\($0)_\(size).jpg" } } ?? url
        guard let resolved = URL(string: path, relativeTo: BingGallery.baseURL)?.absoluteURL,
              resolved.scheme == "https", resolved.host == "www.bing.com" else { return nil }
        return resolved
    }
}

private enum BingGallery {
    static let baseURL = URL(string: "https://www.bing.com")!
    private struct Feed: Decodable { let images: [BingWallpaper] }
    private struct ArchiveEntry: Decodable {
        let date: String
        let title: String?
        let copyright: String?
        let bing_url: String

        var wallpaper: BingWallpaper? {
            guard let source = URLComponents(string: bing_url),
                  ["www.bing.com", "bing.com", "cn.bing.com"].contains(source.host ?? ""),
                  let imageID = source.queryItems?.first(where: { $0.name == "id" })?.value,
                  imageID.hasSuffix("_UHD.jpg") else { return nil }
            let base = "/th?id=\(imageID.dropLast("_UHD.jpg".count))"
            return BingWallpaper(url: "\(base)_UHD.jpg", urlbase: base, title: title, copyright: copyright)
        }
    }

    static func recent() async throws -> [BingWallpaper] {
        let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=zh-CN")!
        let data = try await fetch(url)
        let images = try JSONDecoder().decode(Feed.self, from: data).images
        var seen = Set<String>()
        return images.filter { $0.imageURL() != nil && seen.insert($0.id).inserted }
    }

    static func download(_ item: BingWallpaper) async throws -> Data {
        guard let original = item.imageURL() else { throw URLError(.badURL) }
        if let large = item.imageURL(size: "UHD"), large != original {
            do { return try await fetch(large, image: true) }
            catch { try Task.checkCancellation() }
        }
        return try await fetch(original, image: true)
    }

    static func archive() async throws -> [BingWallpaper] {
        let url = URL(string: "https://bing.npanuhin.me/CN-zh.json")!
        let entries = try JSONDecoder().decode([ArchiveEntry].self, from: await fetch(url))
        return entries.sorted { $0.date > $1.date }.compactMap(\.wallpaper)
    }

    private static func fetch(_ url: URL, image: Bool = false) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty,
              !image || response.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
        return data
    }
}

struct WallpaperGalleryView: View {
    typealias Source = GalleryCategory
    let use: (GalleryPick) -> Void
    @Binding var source: Source
    @Binding var focusSeriesGroupID: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var categories = GalleryCategory.cached
    @State private var galleryVisible = false
    @EnvironmentObject private var model: WorkshopModel
    init(use: @escaping (GalleryPick) -> Void, source: Binding<Source>, focusSeriesGroupID: Binding<String?> = .constant(nil)) {
        self.use = use
        _source = source
        _focusSeriesGroupID = focusSeriesGroupID
    }

    private var visibleSources: [Source] {
        categories.filter { $0.published != 0 && ($0.hidden == 0 || model.photoDownloadUnlocked) }
    }

    var body: some View {
        Group {
            if visibleSources.isEmpty {
                ContentUnavailableView("暂无分类", systemImage: "rectangle.stack")
            } else {
                galleryPages
            }
        }
        .navigationTitle("图库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            galleryVisible = true
            if !visibleSources.contains(source) { source = visibleSources.first ?? .stock }
        }
        .onDisappear { galleryVisible = false }
        .task(id: galleryVisible && scenePhase == .active) {
            guard galleryVisible, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refreshCategories()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .onChange(of: model.photoDownloadUnlocked) { _, _ in
            if !visibleSources.contains(source) { source = visibleSources.first ?? .stock }
        }
    }

    private var galleryPages: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleSources) { item in
                            Button { source = item } label: {
                                Text(item.rawValue)
                                    .font(.subheadline.weight(source == item ? .semibold : .regular))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(source == item ? Color.white : Color.primary)
                                    .background(source == item ? CanvasTheme.accent : Color(uiColor: .secondarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("gallery.\(item.key)")
                            .accessibilityAddTraits(source == item ? .isSelected : [])
                            .id(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(.background)
                .onAppear { proxy.scrollTo(source, anchor: .center) }
                .onChange(of: source) { _, value in
                    withAnimation { proxy.scrollTo(value, anchor: .center) }
                }
            }
            TabView(selection: $source) {
                ForEach(visibleSources) { category in
                    categoryPage(category).tag(category)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func categoryPage(_ category: Source) -> some View {
        switch category.kind {
        case "stock": ServerWallpaperGalleryView(category: category, use: use)
        case "share": SharedWallpaperGalleryView(use: use)
        case "bing": BingWallpaperGalleryView(use: use)
        case "commons": CommonsWallpaperGalleryView(use: use)
        case "buick": BuickWallpaperGalleryView(use: use)
        case "test": ServerWallpaperGalleryView(category: category, use: use)
        case "series": SeriesGalleryView(category: category, use: use, focusGroupID: $focusSeriesGroupID)
        default: ServerWallpaperGalleryView(category: category, use: use)
        }
    }

    private func refreshCategories() async {
        guard let remote = await Source.fetch(), !Task.isCancelled else { return }
        categories = remote
        source = visibleSources.first(where: { $0 == source }) ?? visibleSources.first ?? .stock
    }
}

private struct BingWallpaperGalleryView: View {
    @EnvironmentObject private var model: WorkshopModel
    let use: (GalleryPick) -> Void
    @State private var images: [BingWallpaper] = []
    @State private var selection: BingWallpaper?
    @State private var loading = false
    @State private var problem: String?
    @State private var archive: [BingWallpaper]?
    @State private var archiveIndex = 0
    @State private var loadingMore = false
    @State private var archiveFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Bing 每日壁纸", systemImage: "photo.stack").font(.headline)
                if loading && images.isEmpty { ProgressView("正在加载…") }
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                    Button("重试") { Task { await reload() } }.disabled(loading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 16) {
                    ForEach(images) { item in
                        Button { selection = item } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                GalleryImage(url: item.imageURL(size: "640x360"), mode: .fill)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(item.name).font(.subheadline).lineLimit(2)
                                if let resolution = item.resolutionLabel {
                                    Text(resolution).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                if !images.isEmpty || archiveFailed {
                    if loadingMore {
                        ProgressView("正在加载历史壁纸…")
                    } else if archive == nil || archiveIndex < (archive?.count ?? 0) {
                        Button(archiveFailed ? "重试加载历史壁纸" : "加载更多") { Task { await loadMore() } }
                            .buttonStyle(.bordered).disabled(loading)
                    }
                    if archiveFailed { Text("历史壁纸暂时无法加载。").font(.caption).foregroundStyle(.secondary) }
                    if archive != nil { Text("历史目录来自 Bing Wallpaper Archive").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
        .task { if images.isEmpty { await reload() } }
        .sheet(item: $selection) { item in
            BingWallpaperDetail(item: item, busy: model.busy) { pick in
                selection = nil
                use(pick)
            }
        }
    }

    private func reload() async {
        guard !loading, !loadingMore else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            images = try await BingGallery.recent()
            if images.isEmpty { problem = "Bing 暂时没有返回壁纸。" }
        } catch {
            if !Task.isCancelled { problem = "Bing 图库加载失败，请检查网络后重试。" }
        }
        guard !Task.isCancelled else { return }
        archive = nil
        archiveIndex = 0
        await loadMore()
    }

    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        archiveFailed = false
        defer { loadingMore = false }
        do {
            let available: [BingWallpaper]
            if let archive { available = archive }
            else { available = try await BingGallery.archive(); archive = available }
            var seen = Set(images.map(\.id))
            var page: [BingWallpaper] = []
            while archiveIndex < available.count && page.count < 16 {
                let item = available[archiveIndex]
                archiveIndex += 1
                if seen.insert(item.id).inserted { page.append(item) }
            }
            images.append(contentsOf: page)
            if !images.isEmpty { problem = nil }
        } catch {
            if !Task.isCancelled { archiveFailed = true }
        }
    }
}

private struct BingWallpaperDetail: View {
    @Environment(\.dismiss) private var dismiss
    let item: BingWallpaper
    let busy: Bool
    let use: (GalleryPick) -> Void
    @State private var downloading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GalleryImage(url: item.imageURL(), mode: .fit).aspectRatio(16 / 9, contentMode: .fit)
                    Text(item.name).font(.headline)
                    if let credit = item.copyright { Text(credit).font(.caption).foregroundStyle(.secondary) }
                    Button(downloading ? "正在下载…" : "用作壁纸") { download() }
                        .buttonStyle(.borderedProminent).disabled(downloading || busy)
                    if failed { Text("下载失败，请重试。").foregroundStyle(.red) }
                }.padding(16)
            }
            .navigationTitle("Bing 壁纸")
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
            do { use(GalleryPick(data: try await BingGallery.download(item), source: "bing")) }
            catch { failed = true }
        }
    }
}

struct GalleryImage: View {
    let url: URL?
    let mode: ContentMode
    var backed = true
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, mode: ContentMode, backed: Bool = true) {
        self.url = url
        self.mode = mode
        self.backed = backed
        _image = State(initialValue: url.flatMap(CatalogLibrary.savedImage))
    }

    var body: some View {
        let content = Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
            } else if url == nil {
                Label("暂无预览", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else if failed {
                Label("图片加载失败", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        Group {
            if backed {
                Rectangle().fill(.quaternary).overlay { content }.clipped()
            } else {
                content.frame(maxWidth: .infinity, minHeight: image == nil ? 92 : 0)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let loaded = await CatalogLibrary.cachedImage(url)
            image = loaded ?? image
            failed = loaded == nil && image == nil
        }
    }
}