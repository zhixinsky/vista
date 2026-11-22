// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct GalleryCategory: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let hidden: Int
    let published: Int
    var rawValue: String { title }
    var key: String { id == "buick_gallery" ? "buick" : id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let stock = Self(id: "stock", title: "默认壁纸", kind: "stock", hidden: 0)
    static let share = Self(id: "share", title: "精选壁纸", kind: "share", hidden: 0)
    static let bing = Self(id: "bing", title: "必应壁纸", kind: "bing", hidden: 0)
    static let commons = Self(id: "commons", title: "主题搜图", kind: "commons", hidden: 0)
    static let buick = Self(id: "buick_gallery", title: "别克车机壁纸", kind: "buick", hidden: 0)
    static let test = Self(id: "test", title: "测试", kind: "test", hidden: 1, published: 1)
    static let allCases: [Self] = [.stock, .share, .bing, .commons, .buick, .test]

    init(id: String, title: String, kind: String, hidden: Int, published: Int = 1) {
        self.id = id
        self.title = title
        self.kind = kind
        self.hidden = hidden
        self.published = published
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, hidden, published }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        hidden = try container.decodeIfPresent(Int.self, forKey: .hidden) ?? 0
        published = try container.decodeIfPresent(Int.self, forKey: .published) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(published, forKey: .published)
    }

    private struct Feed: Decodable { let items: [GalleryCategory] }
    private struct AssetFeed: Decodable { let items: [RemoteAsset] }
    static func assets(_ id: String) async throws -> [CatalogItem] {
        var request = URLRequest(url: ServiceGate.join("v1/catalog/\(id)"), timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let items = try JSONDecoder().decode(AssetFeed.self, from: data).items.map {
            CatalogItem(id: $0.id, title: $0.title, kind: .remote, remote: $0)
        }
        CatalogLibrary.rememberAssets(items, collection: id)
        return items
    }

    static func savedAssets(_ id: String) -> [CatalogItem] {
        CatalogLibrary.savedAssets(id)
    }
    static var cached: [Self] {
        guard let data = UserDefaults.standard.data(forKey: "CarVistaGalleryCategories"),
              let items = try? JSONDecoder().decode([Self].self, from: data) else { return allCases }
        return items
    }

    static func fetch() async -> [Self]? {
        guard ServiceGate.enabled else { return nil }
        var request = URLRequest(url: ServiceGate.join("v1/gallery/categories"), timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let items = try JSONDecoder().decode(Feed.self, from: data).items
            guard Set(items.map(\.id)).count == items.count else { return nil }
            UserDefaults.standard.set(try JSONEncoder().encode(items), forKey: "CarVistaGalleryCategories")
            return items
        } catch { return nil }
    }

    static func fetchSeriesGroups(_ parentID: String) async -> [SeriesGroup]? {
        guard ServiceGate.enabled else { return nil }
        var request = URLRequest(url: ServiceGate.join("v1/gallery/categories/\(parentID)/groups"), timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return cachedSeriesGroups(parentID) }
            let items = try JSONDecoder().decode(SeriesGroupFeed.self, from: data).items
            CatalogLibrary.rememberData(data, name: "series-\(parentID)")
            return items
        } catch { return cachedSeriesGroups(parentID) }
    }

    private static func cachedSeriesGroups(_ parentID: String) -> [SeriesGroup]? {
        let saved = savedSeriesGroups(parentID)
        return saved.isEmpty ? nil : saved
    }

    static func savedSeriesGroups(_ parentID: String) -> [SeriesGroup] {
        guard let data = CatalogLibrary.savedData("series-\(parentID)"),
              let feed = try? JSONDecoder().decode(SeriesGroupFeed.self, from: data) else { return [] }
        return feed.items
    }

    static func savedSeriesHomeEntries(includeHidden: Bool) -> [SeriesHomeEntry] {
        cached.filter { $0.published != 0 && $0.kind == "series" }.flatMap { parent in
            savedSeriesGroups(parent.id)
                .filter { $0.hidden == 0 || includeHidden }
                .map { SeriesHomeEntry(group: $0, parent: parent) }
        }
    }

    static func fetchSeriesHomeEntries(includeHidden: Bool) async -> [SeriesHomeEntry] {
        guard let categories = await fetch() else { return savedSeriesHomeEntries(includeHidden: includeHidden) }
        let parents = categories.filter { $0.published != 0 && $0.kind == "series" }
        var entries: [SeriesHomeEntry] = []
        for parent in parents where parent.hidden == 0 || includeHidden {
            guard let groups = await fetchSeriesGroups(parent.id) else { continue }
            for group in groups where group.hidden == 0 || includeHidden {
                entries.append(SeriesHomeEntry(group: group, parent: parent))
            }
        }
        return entries
    }
}

struct SeriesHomeEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let cover: URL?
    let count: Int
    let parent: GalleryCategory

    init(group: SeriesGroup, parent: GalleryCategory) {
        id = group.id
        title = group.title
        cover = group.cover
        count = group.count
        self.parent = parent
    }
}

struct ServerWallpaperGalleryView: View {
    let category: GalleryCategory
    let use: (GalleryPick) -> Void
    @EnvironmentObject private var model: WorkshopModel
    @State private var items: [CatalogItem]
    @State private var loading = false
    @State private var importingID: String?
    @State private var problem: String?

    init(category: GalleryCategory, use: @escaping (GalleryPick) -> Void) {
        self.category = category
        self.use = use
        _items = State(initialValue: GalleryCategory.savedAssets(category.id))
    }

    var body: some View {
        ZStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                if loading && items.isEmpty { ProgressView("正在加载…") }
                if !loading && items.isEmpty && problem == nil {
                    ContentUnavailableView("暂无壁纸", systemImage: "photo")
                }
                if category.kind == "stock" {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 16) {
                        ForEach(items) { item in wallpaperButton(item) }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(items) { item in wallpaperButton(item) }
                    }
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .task(id: category.id) { await reload() }
        .refreshable { await reload() }
        if importingID != nil { WallpaperDownloadBanner() }
        }
    }

    private func thumbRatio(_ item: CatalogItem) -> CGFloat? {
        guard let remote = item.remote, remote.width > 0, remote.height > 0 else { return nil }
        return CGFloat(remote.width) / CGFloat(remote.height)
    }

    private func wallpaperButton(_ item: CatalogItem) -> some View {
        Button { select(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                CatalogThumb(item: item)
                    .aspectRatio(thumbRatio(item), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if importingID == item.id { WallpaperDownloadCover(compact: true) }
                    }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    if let remote = item.remote, remote.width > 0, remote.height > 0 {
                        Text("\(remote.width) × \(remote.height)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).disabled(importingID != nil || model.busy)
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await GalleryCategory.assets(category.id)
            problem = nil
        } catch {
            if items.isEmpty { problem = "无法加载壁纸，请下拉重试。" }
        }
    }

    private func select(_ item: CatalogItem) {
        guard importingID == nil, !model.busy else { return }
        importingID = item.id
        Task {
            defer { importingID = nil }
            do {
                let data = try await CatalogLibrary.originalData(item)
                use(GalleryPick(data: data, source: category.id == "test" ? "test" : "catalog", assetID: item.id))
            } catch {
                problem = "无法导入壁纸，请重试。"
            }
        }
    }
}

struct SeriesGroup: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let hidden: Int
    let count: Int
    let previewURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, hidden, count
        case previewURL = "preview_url"
    }

    var cover: URL? {
        guard !previewURL.isEmpty, let url = URL(string: previewURL) else { return nil }
        return ServiceClient.publicURL(url)
    }
}

struct SeriesGalleryView: View {
    let category: GalleryCategory
    let use: (GalleryPick) -> Void
    @Binding var focusGroupID: String?
    @EnvironmentObject private var model: WorkshopModel
    @State private var groups: [SeriesGroup] = []
    @State private var selected: SeriesGroup?
    @State private var loading = false
    @State private var problem: String?

    init(category: GalleryCategory, use: @escaping (GalleryPick) -> Void, focusGroupID: Binding<String?> = .constant(nil)) {
        self.category = category
        self.use = use
        _focusGroupID = focusGroupID
        _groups = State(initialValue: GalleryCategory.savedSeriesGroups(category.id))
    }

    private var visibleGroups: [SeriesGroup] {
        groups.filter { $0.hidden == 0 || model.photoDownloadUnlocked }
    }

    var body: some View {
        Group {
            if let selected {
                VStack(spacing: 0) {
                    HStack {
                        Button { self.selected = nil } label: {
                            Label("全部系列", systemImage: "chevron.left").font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(selected.title).font(.headline).lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    ServerWallpaperGalleryView(
                        category: GalleryCategory(id: selected.id, title: selected.title, kind: "catalog", hidden: 0),
                        use: use
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                        if loading && groups.isEmpty { ProgressView("正在加载…") }
                        if !loading && visibleGroups.isEmpty && problem == nil {
                            ContentUnavailableView("还没有系列", systemImage: "rectangle.stack", description: Text("在后台上传文件夹后，每个子文件夹会显示在这里。"))
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 16) {
                            ForEach(visibleGroups) { group in
                                Button { selected = group } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        GalleryImage(url: group.cover, mode: .fill)
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                        Text(group.title).font(.subheadline).lineLimit(1)
                                        Text("\(group.count) 张").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await reload() }
            }
        }
        .task(id: category.id) { await reload() }
        .onChange(of: focusGroupID) { _, _ in applyFocus() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let items = await GalleryCategory.fetchSeriesGroups(category.id) else {
            problem = groups.isEmpty ? "无法加载系列，请下拉重试。" : problem
            return
        }
        groups = items
        problem = nil
        if let selected, !groups.contains(selected) { self.selected = nil }
        applyFocus()
    }

    private func applyFocus() {
        guard let id = focusGroupID else { return }
        guard let group = groups.first(where: { $0.id == id }) else { return }
        selected = group
        focusGroupID = nil
    }
}

struct WallpaperDownloadBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text("正在下载原图，请稍候").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.82), in: Capsule())
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

struct WallpaperDownloadCover: View {
    var compact = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: compact ? 6 : 8) {
                ProgressView().tint(.white)
                Text(compact ? "下载中" : "正在下载原图…")
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SeriesGroupFeed: Decodable { let items: [SeriesGroup] }
