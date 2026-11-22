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
    @State private var previewItem: SharedWallpaper?

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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Button { previewItem = item } label: {
                            GalleryImage(url: item.previewURL, mode: .fill)
                            .frame(height: 125)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Text("\(item.width) × \(item.height)")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(.black.opacity(0.58), in: Capsule())
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                            .overlay {
                                if busyID == item.id { WallpaperDownloadCover() }
                            }
                        }
                        .frame(height: 125)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain).disabled(busyID != nil || model.busy)
                            .accessibilityLabel("查看\(item.title)")
                        HStack(alignment: .center, spacing: 3) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).layoutPriority(1)
                            Spacer(minLength: 4)
                            Button { like(item) } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: item.liked ? "heart.fill" : "heart")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(item.liked ? Color.red : Color.secondary)
                                    Text("\(item.likes)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1).fixedSize()
                                }
                                .padding(.horizontal, 2)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busyID != nil || liking)
                            .accessibilityLabel(item.liked ? "取消点赞，目前 \(item.likes) 个赞" : "点赞，目前 \(item.likes) 个赞")
                            Button { commentItem = item } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "bubble.left")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text("\(item.comments ?? 0)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1).fixedSize()
                                }
                                .padding(.horizontal, 2)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看评论，共 \(item.comments ?? 0) 条")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let author = item.author, !author.isEmpty {
                                Text("作者：\(author)").font(.caption).foregroundStyle(.secondary)
                            }
                            if !item.intro.isEmpty {
                                Text(item.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: sort) { await reload() }
        .refreshable { await reload() }
        if busyID != nil { WallpaperDownloadBanner() }
        }
        .fullScreenCover(item: $previewItem) { item in
            SharedWallpaperPreview(item: item, use: use)
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
        note = remote.isEmpty ? "暂无精选壁纸。" : "此处壁纸由车友裁剪调色后分享上传，可点赞评论。"
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


private struct SharedWallpaperPreview: View {
    @Environment(\.dismiss) private var dismiss
    let item: SharedWallpaper
    let use: (GalleryPick) -> Void
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var loading = false
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else if failed {
                            VStack(spacing: 12) {
                                Text("图片加载失败")
                                Button("重试") { Task { await load() } }
                            }.foregroundStyle(.secondary)
                        } else { ProgressView("正在加载图片…") }
                    }
                    .frame(width: geometry.size.width * max(1, min(5, zoom * gestureZoom)),
                           height: geometry.size.height * max(1, min(5, zoom * gestureZoom)))
                }
                .simultaneousGesture(MagnificationGesture()
                    .updating($gestureZoom) { value, state, _ in state = value }
                    .onEnded { zoom = max(1, min(5, zoom * $0)) })
                .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
            }
            .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button("选择壁纸") {
                    guard let imageData else { return }
                    use(GalleryPick(data: imageData, source: "share", assetID: item.id))
                    dismiss()
                }
                .buttonStyle(.borderedProminent).disabled(imageData == nil || loading)
                .padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; failed = false
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: item.originalURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let decoded = UIImage(data: data) else { failed = true; return }
            imageData = data; image = decoded
        } catch { failed = true }
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
    var likes: Int? = nil
    var liked: Bool? = nil
}

struct CommentLikeResult: Decodable { let likes: Int; let liked: Bool }

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
    @State private var likingIDs: Set<String> = []
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
                            HStack {
                                Spacer()
                                Button { Task { await like(comment) } } label: {
                                    Label("\(comment.likes ?? 0)", systemImage: comment.liked == true ? "heart.fill" : "heart")
                                        .font(.caption).foregroundStyle(comment.liked == true ? Color.red : Color.secondary)
                                }.buttonStyle(.plain).disabled(likingIDs.contains(comment.id))
                                    .accessibilityLabel(comment.liked == true ? "取消点赞" : "点赞")
                            }
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
                        .lineLimit(1...4)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .disabled(sending)
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

    private func like(_ comment: ShareComment) async {
        guard !likingIDs.contains(comment.id) else { return }
        likingIDs.insert(comment.id)
        defer { likingIDs.remove(comment.id) }
        do {
            let result = try await ServiceClient.shared.setCommentLike(item.id, commentID: comment.id, liked: comment.liked != true)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[index].likes = result.likes
                comments[index].liked = result.liked
            }
        } catch { note = "点赞失败，请稍后重试。" }
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
