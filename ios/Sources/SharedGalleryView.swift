// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SharedWallpaper: Identifiable, Equatable {
    let id: String
    let title: String
    let intro: String
    let author: String?
    let width: Int
    let height: Int
    let likes: Int
    let liked: Bool
    var comments: Int? = nil
    var createdAt: String? = nil
    let previewURL: URL
    let originalURL: URL

    static var saved: [SharedWallpaper] {
        guard let data = CatalogLibrary.savedData("shares"),
              let feed = try? JSONDecoder().decode(ShareFeed.self, from: data) else { return [] }
        return feed.items.map(SharedWallpaper.init)
    }

    init(_ item: ShareItem) {
        id = item.id
        title = item.title
        intro = item.intro
        author = item.author
        width = item.width
        height = item.height
        likes = item.likes
        liked = item.liked
        comments = item.comments
        createdAt = item.createdAt
        previewURL = ServiceClient.publicURL(item.previewURL)
        originalURL = ServiceClient.publicURL(item.originalURL)
    }
}

struct ShareFeed: Decodable { let items: [ShareItem] }

struct ShareItem: Decodable {
    let id: String
    let title: String
    let intro: String
    let author: String?
    let width: Int
    let height: Int
    let likes: Int
    let liked: Bool
    var comments: Int? = nil
    var createdAt: String? = nil
    let previewURL: URL
    let originalURL: URL

    enum CodingKeys: String, CodingKey {
        case id, title, width, height, likes, liked
        case intro = "description"
        case author, comments
        case createdAt = "created_at"
        case previewURL = "preview_url"
        case originalURL = "original_url"
    }
}

struct SharedWallpaperGalleryView: View {
    @EnvironmentObject private var model: WorkshopModel
    let use: (GalleryPick) -> Void
    @State private var items: [SharedWallpaper]
    @State private var note = ""
    @State private var busyID: String?
    @State private var liking = false
    @State private var sort: ShareSort = .likes
    @State private var commentItem: SharedWallpaper?

    init(use: @escaping (GalleryPick) -> Void) {
        self.use = use
        _items = State(initialValue: SharedWallpaper.saved)
    }

    var body: some View {
        ZStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("排序", selection: $sort) {
                    ForEach(ShareSort.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { select(item) } label: {
                            GalleryImage(url: item.previewURL, mode: .fill)
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                if busyID == item.id { WallpaperDownloadCover() }
                            }
                        }.buttonStyle(.plain).disabled(busyID != nil || model.busy)
                            .accessibilityLabel("选择\(item.title)")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.title).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 8)
                            Button { like(item) } label: {
                                Label("\(item.likes)", systemImage: item.liked ? "heart.fill" : "heart")
                            }.font(.caption2).buttonStyle(.plain).disabled(busyID != nil || liking)
                                .accessibilityLabel(item.liked ? "取消点赞，目前 \(item.likes) 个赞" : "点赞，目前 \(item.likes) 个赞")
                            Button { commentItem = item } label: {
                                Label("\(item.comments ?? 0)", systemImage: "bubble.left")
                            }.font(.caption2).buttonStyle(.plain)
                                .accessibilityLabel("查看评论，共 \(item.comments ?? 0) 条")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let author = item.author, !author.isEmpty {
                                Text("作者：\(author)").font(.caption).foregroundStyle(.secondary)
                            }
                            if !item.intro.isEmpty {
                                Text(item.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text("\(item.width) × \(item.height)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: sort) { await reload() }
        .refreshable { await reload() }
        if busyID != nil { WallpaperDownloadBanner() }
        }
        .sheet(item: $commentItem, onDismiss: { Task { await reload() } }) { item in
            ShareCommentsView(item: item)
        }
    }

    private func reload() async {
        guard ServiceGate.enabled else {
            note = "当前无法连接后台。"
            items = []
            return
        }
        let requested = sort
        guard let remote = await ServiceClient.shared.fetchShares(sort: requested) else {
            if !Task.isCancelled, requested == sort { note = "加载失败，请下拉刷新。" }
            return
        }
        guard !Task.isCancelled, requested == sort else { return }
        items = remote
        note = remote.isEmpty ? "暂无精选壁纸。" : "点图片即可导入。"
    }

    private func like(_ item: SharedWallpaper) {
        guard !liking else { return }
        liking = true
        Task {
            defer { liking = false }
            guard await ServiceClient.shared.toggleLike(item.id) != nil else {
                note = "点赞未成功，请稍后重试。"
                return
            }
            await reload()
        }
    }

    private func select(_ item: SharedWallpaper) {
        guard busyID == nil, !model.busy else { return }
        busyID = item.id
        Task {
            defer { busyID = nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: item.originalURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                    note = "无法下载这张壁纸。"
                    return
                }
                use(GalleryPick(data: data, source: "share", assetID: item.id))
            } catch {
                note = "无法下载这张壁纸。"
            }
        }
    }
}


enum ShareSort: String, CaseIterable, Identifiable {
    case likes, latest, comments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .likes: return "点赞排行"
        case .latest: return "最新上传"
        case .comments: return "评论最多"
        }
    }
}

struct ShareComment: Decodable, Identifiable {
    let id: String
    let author: String
    let body: String
    let created_at: String
}

struct ShareCommentPage: Decodable {
    let items: [ShareComment]
    let has_more: Bool
}

struct ShareCommentsView: View {
    @Environment(\.dismiss) private var dismiss
    let item: SharedWallpaper
    @State private var comments: [ShareComment] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var sending = false
    @State private var draft = ""
    @State private var draftID = UUID()
    @State private var note = ""
    private var bodyText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if comments.isEmpty && !loading && note.isEmpty {
                        Text("还没有评论，聊聊这张壁纸吧。").foregroundStyle(.secondary)
                    }
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.author).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(comment.created_at.replacingOccurrences(of: "T", with: " ").prefix(16))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(comment.body).font(.body).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                    if hasMore { Button("查看更多评论") { Task { await load(reset: false) } }.disabled(loading || sending) }
                    if loading { ProgressView("正在读取评论…") }
                    if !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await load(reset: true) } }.disabled(loading || sending)
                    }
                }
            }
            .navigationTitle("壁纸评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(sending) } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    TextField("写下你的评论…", text: $draft, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(sending)
                    HStack {
                        Text("\(bodyText.count)/500").font(.caption).foregroundStyle(bodyText.count > 500 ? .red : .secondary)
                        Spacer()
                        Button(sending ? "发送中…" : "发送") { Task { await send() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(sending || loading || bodyText.isEmpty || bodyText.count > 500)
                    }
                }.padding().background(.regularMaterial)
            }
            .task { await load(reset: true) }
            .refreshable { await load(reset: true) }
            .onChange(of: draft) { _, _ in draftID = UUID() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(sending)
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await ServiceClient.shared.comments(item.id, offset: reset ? 0 : comments.count)
            if reset { comments = page.items } else { comments.append(contentsOf: page.items) }
            hasMore = page.has_more
            note = ""
        } catch { note = "评论未能加载，请重试。" }
    }

    private func send() async {
        guard !sending, !bodyText.isEmpty, bodyText.count <= 500 else { return }
        sending = true
        defer { sending = false }
        do {
            try await ServiceClient.shared.postComment(item.id, id: draftID, body: bodyText)
            draft = ""
            await load(reset: true)
        } catch { note = error.localizedDescription }
    }
}

struct ShareWallpaperForm: View {
    @Environment(\.dismiss) private var dismiss
    let collection: WallpaperCollection
    @State private var title = ""
    @State private var author = ""
    @State private var intro = ""
    @State private var sending = false
    @State private var note = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("作者") { TextField("作者，可以留空", text: $author) }
                Section("壁纸名称") { TextField("给壁纸起个名字", text: $title) }
                Section("介绍") { TextField("介绍一下这张壁纸，可以留空", text: $intro, axis: .vertical).lineLimit(3...6) }
                if !note.isEmpty { Text(note).foregroundStyle(.red) }
            }.disabled(sending)
            .navigationTitle("分享壁纸").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "正在分享…" : "分享") {
                        sending = true
                        Task {
                            let entry = collection.entries.first { $0.mode == "车机" } ?? collection.first
                            let ok = await ServiceClient.shared.submitShare(entry, title: title.trimmingCharacters(in: .whitespacesAndNewlines), description: intro, author: author)
                            sending = false
                            if ok { dismiss() } else { note = "分享未成功，填写的内容已保留，请重试。" }
                        }
                    }.disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if title.isEmpty { title = collection.title } }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(sending)
    }
}
