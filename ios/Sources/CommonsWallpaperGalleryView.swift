// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

private struct CommonsPhoto: Identifiable {
    let id: Int
    let title: String
    let original: URL
    let thumbnail: URL
    let page: URL
    let width: Int
    let height: Int
    let author: String?
    let license: String
    let licenseURL: URL?

    var isUltrawide: Bool { width >= 2560 && Double(width) / Double(height) >= 3.5 }
}

private enum CommonsPhotoAPI {
    private struct Feed: Decodable {
        let query: Results?
        let continuation: Cursor?
        let error: APIError?
        enum CodingKeys: String, CodingKey { case query, error; case continuation = "continue" }
    }
    private struct APIError: Decodable { let code: String }
    struct Cursor: Decodable {
        let offset: Int
        let token: String
        enum CodingKeys: String, CodingKey { case offset = "gsroffset"; case token = "continue" }
    }
    private struct Results: Decodable { let pages: [Page] }
    private struct Page: Decodable {
        let pageid: Int
        let index: Int?
        let title: String
        let imageinfo: [Info]?

        var photo: CommonsPhoto? {
            guard let info = imageinfo?.first, let width = info.width, let height = info.height,
                  width >= 1280, height >= 360, ["image/jpeg", "image/png", "image/webp"].contains(info.mime ?? ""),
                  let original = info.url, original.scheme == "https", original.host == "upload.wikimedia.org",
                  let thumb = info.thumburl, thumb.scheme == "https",
                  ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(thumb.host ?? ""),
                  let source = info.descriptionurl, source.scheme == "https", source.host == "commons.wikimedia.org",
                  let license = info.extmetadata?["LicenseShortName"]?.value, !license.isEmpty else { return nil }
            let author = info.extmetadata?["Artist"]?.value
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let licenseURL = info.extmetadata?["LicenseUrl"].flatMap { URL(string: $0.value) }
            return CommonsPhoto(id: pageid, title: String(title.dropFirst("File:".count)),
                                original: original, thumbnail: thumb, page: source,
                                width: width, height: height, author: author, license: license,
                                licenseURL: licenseURL?.scheme == "https" ? licenseURL : nil)
        }
    }

    private struct Info: Decodable {
        struct Metadata: Decodable { let value: String }
        let width: Int?
        let height: Int?
        let mime: String?
        let url: URL?
        let thumburl: URL?
        let descriptionurl: URL?
        let extmetadata: [String: Metadata]?
    }

    static func search(_ query: String, cursor: Cursor?) async throws -> ([CommonsPhoto], Cursor?) {
        var endpoint = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        endpoint.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "generator", value: "search"),
            .init(name: "gsrnamespace", value: "6"), .init(name: "gsrlimit", value: "24"),
            .init(name: "gsrsearch", value: query + " filetype:bitmap"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|size|mime|extmetadata"),
            .init(name: "iiurlwidth", value: "480"),
            .init(name: "iiextmetadatafilter", value: "Artist|LicenseShortName|LicenseUrl")
        ]
        if let cursor {
            endpoint.queryItems?.append(.init(name: "gsroffset", value: String(cursor.offset)))
            endpoint.queryItems?.append(.init(name: "continue", value: cursor.token))
        }
        guard let url = endpoint.url else { throw URLError(.badURL) }
        let data = try await fetch(url)
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard feed.error == nil else { throw URLError(.badServerResponse) }
        return ((feed.query?.pages ?? []).sorted { ($0.index ?? .max) < ($1.index ?? .max) }.compactMap(\.photo), feed.continuation)
    }

    static func fetch(_ url: URL, image: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("CarVista/1.0 (https://github.com/zhixinsky/CarVista)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty,
              !image || http.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
        return data
    }
}

struct CommonsWallpaperGalleryView: View {
    private static let themes = [
        ("风景", "incategory:\"Featured pictures of landscapes\""),
        ("城市", "city skyline panorama"),
        ("山海", "mountains coast panorama"),
        ("夜空", "Milky Way panorama"),
        ("全景", "landscape panorama")
    ]

    let use: (GalleryPick) -> Void
    @State private var searchText = ""
    @State private var query = CommonsWallpaperGalleryView.themes[0].1
    @State private var ultrawide = false
    @State private var photos: [CommonsPhoto] = []
    @State private var next: CommonsPhotoAPI.Cursor?
    @State private var selection: CommonsPhoto?
    @State private var task: Task<Void, Never>?
    @State private var loading = false
    @State private var failed = false
    @State private var initialRequest = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("使用 Commons 主题找图前，请先开启 VPN。", systemImage: "network")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("搜索主题，例如 雪山 或 Alps", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit(submitSearch)
                    Button("搜索", action: submitSearch)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Self.themes.indices, id: \.self) { index in
                            let theme = Self.themes[index]
                            Button(theme.0) { query = theme.1; load(reset: true) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                Toggle("超宽原图（别克大联屏）", isOn: $ultrawide)
                    .onChange(of: ultrawide) { _, _ in load(reset: true) }
                if ultrawide {
                    Text("筛选宽度 ≥ 2560 像素、宽高比 ≥ 3.5:1 的原图。别克预设仅适用于 6008×934 原图，其他尺寸请使用自由裁剪。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 16) {
                    ForEach(photos) { photo in
                        Button { selection = photo } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                GalleryImage(url: photo.thumbnail, mode: .fill)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(photo.title).font(.subheadline).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                if loading {
                    ProgressView("正在查找…")
                } else if failed {
                    Text("无法连接 Commons，请检查 VPN 是否已开启。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重试") { load(reset: initialRequest) }.buttonStyle(.bordered)
                } else {
                    if photos.isEmpty {
                        Text(next == nil ? "没有符合条件的图片，试试其他主题。" : "这批图片没有符合条件的结果，可以继续查找。")
                            .foregroundStyle(.secondary)
                    }
                    if next != nil { Button("加载更多") { load(reset: false) }.buttonStyle(.bordered) }
                }
            }
            .frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .onAppear { if initialRequest { load(reset: true) } }
        .onDisappear { task?.cancel(); loading = false }
        .sheet(item: $selection) { item in
            CommonsPhotoDetail(photo: item) { pick in
                selection = nil
                use(pick)
            }
        }
    }

    private func submitSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = text
        load(reset: true)
    }

    private func load(reset: Bool) {
        task?.cancel()
        if reset { photos = []; next = nil; initialRequest = true }
        let wide = ultrawide
        let term: String
        if wide && query == Self.themes[0].1 { term = "landscape panorama" }
        else if wide && !query.localizedCaseInsensitiveContains("panorama") { term = query + " panorama" }
        else { term = query }
        let cursor = next
        let limit = wide ? 3 : 1
        loading = true
        failed = false
        task = Task {
            do {
                var position = cursor
                var found: [CommonsPhoto] = []
                var ids = Set(photos.map(\.id))
                for _ in 0..<limit {
                    let (page, continuation) = try await CommonsPhotoAPI.search(term, cursor: position)
                    try Task.checkCancellation()
                    found += page.filter { (!wide || $0.isUltrawide) && ids.insert($0.id).inserted }
                    position = continuation
                    if position == nil || found.count >= 6 { break }
                }
                photos.append(contentsOf: found)
                next = position
                initialRequest = false
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                loading = false
            }
        }
    }
}

private struct CommonsPhotoDetail: View {
    @EnvironmentObject private var model: WorkshopModel
    @Environment(\.dismiss) private var dismiss
    let photo: CommonsPhoto
    let use: (GalleryPick) -> Void
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GalleryImage(url: photo.thumbnail, mode: .fit)
                        .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
                    Text(photo.title).font(.headline)
                    Text("\(photo.width) × \(photo.height) 像素").font(.subheadline).foregroundStyle(.secondary)
                    if let author = photo.author, !author.isEmpty { Text("作者：\(author)").font(.caption) }
                    if let licenseURL = photo.licenseURL {
                        Link("许可：\(photo.license)", destination: licenseURL)
                    } else {
                        Text("许可：\(photo.license)")
                    }
                    Link("Wikimedia Commons 原图页面", destination: photo.page)
                    Button(loading ? "正在下载…" : "用作壁纸") {
                        loading = true
                        failed = false
                        Task {
                            defer { loading = false }
                            do { use(GalleryPick(data: try await CommonsPhotoAPI.fetch(photo.original, image: true), source: "commons")) }
                            catch { failed = true }
                        }
                    }.buttonStyle(.borderedProminent).disabled(loading || model.busy)
                    if failed { Text("下载失败，请重试。").foregroundStyle(.red) }
                }.padding(16)
            }
            .navigationTitle("Commons 壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(loading) }
            .interactiveDismissDisabled(loading)
        }
    }
}
