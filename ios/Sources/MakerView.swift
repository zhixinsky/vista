// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI
import Photos

struct ComposeWallpaperView: View {
    @EnvironmentObject var model: WorkshopModel
    @Binding var galleryImport: GalleryImport?
    private let openTool: ((WallpaperRoute) -> Void)?
    private let openGallery: (() -> Void)?
    private let openShared: (() -> Void)?
    private let openSeries: ((GalleryCategory) -> Void)?
    private let openSeriesGroup: ((GalleryCategory, SeriesHomeEntry) -> Void)?
    @State private var tool: WallpaperRoute?
    @State private var photos: [MakerPhoto] = []
    @State private var selection: PhotosPickerItem?
    @State private var current = 0
    @State private var loading = false
    @State private var adjusting = false
    @State private var savingPhoto = false
    @State private var savedToPhotos = false
    @State private var shareCollection: WallpaperCollection?
    @AppStorage("CarVistaSharedHistory") private var sharedHistory = ""
    @State private var cropOrientation = CropOrientationSession()
    @State private var applying = false
    @State private var sharedTop = Array(SharedWallpaper.saved.prefix(10))
    @State private var sharedNote = ""
    @State private var sharedBusy: String?
    @State private var sharedComments: SharedWallpaper?
    @State private var seriesEntries = GalleryCategory.savedSeriesHomeEntries(includeHidden: false)
    @State private var seriesNote = ""
    @State private var seriesVisible = !GalleryCategory.savedSeriesHomeEntries(includeHidden: false).isEmpty
    @State private var problem: String?
    @State private var generated: [UUID: [SavedWallpaper]] = [:]
    @State private var preview: UIImage?
    @State private var previewing = false
    @State private var initialized = false
    @State private var sourcePixels: CGSize?
    private var photo: MakerPhoto? { photos.indices.contains(current) ? photos[current] : nil }
    private var outputSize: CGSize {
        if let crop = photo?.adjustment.pixelCrop { return crop.rect.size }
        guard let sourcePixels, sourcePixels.width > 0, sourcePixels.height > 0 else { return .zero }
        let turns = (((photo?.adjustment.turns ?? 0) % 4) + 4) % 4
        return turns % 2 == 0 ? sourcePixels : CGSize(width: sourcePixels.height, height: sourcePixels.width)
    }
    init(
        galleryImport: Binding<GalleryImport?> = .constant(nil),
        openGallery: (() -> Void)? = nil,
        openShared: (() -> Void)? = nil,
        openSeries: ((GalleryCategory) -> Void)? = nil,
        openSeriesGroup: ((GalleryCategory, SeriesHomeEntry) -> Void)? = nil,
        openTool: ((WallpaperRoute) -> Void)? = nil
    ) {
        _galleryImport = galleryImport
        self.openTool = openTool
        self.openGallery = openGallery
        self.openShared = openShared
        self.openSeries = openSeries
        self.openSeriesGroup = openSeriesGroup
    }
    private var outputLabel: String {
        guard outputSize.width > 0, outputSize.height > 0 else { return "读取原图尺寸…" }
        return "\(Int(outputSize.width)) × \(Int(outputSize.height))"
    }
    private var locked: Bool { loading || savingPhoto || model.busy }
    private var renderKey: String { "\(photo?.id.uuidString ?? "empty")-\(String(describing: photo?.adjustment))-\(outputLabel)" }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image("BrandMark").resizable().frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("CarVista").font(.title.bold()); Text("v\(CanvasTheme.version)").font(.caption).foregroundStyle(.secondary) }
                        Text("让你的 CarPlay 焕然一新").foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 14) {
                    Group {
                        if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                        else if photos.isEmpty { Label("选择一张壁纸", systemImage: "photo.on.rectangle.angled").font(.headline).padding(.vertical, 36) }
                        else { ProgressView("正在生成预览…").frame(height: 160) }
                    }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .topTrailing) { if previewing && preview != nil { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) } }
                    if photos.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(photos.enumerated()), id: \.element.id) { index, item in
                                    Button { current = index } label: {
                                        VStack(spacing: 4) {
                                            MakerThumbnail(url: item.url).frame(width: 72, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                                            Text("第 \(index + 1) 张").font(.caption2)
                                        }.padding(5).background(current == index ? CanvasTheme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain).disabled(locked)
                                }
                            }
                        }
                    }
                    if let photo {
                        HStack {
                            Text(photo.sourceName ?? "当前照片").font(.subheadline.bold())
                            Spacer()
                            Text("输出 \(outputLabel)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("maker.output")
                        }
                    }
                    if let photo {
                        let shared = generated[photo.id]?.contains { sharedHistory.split(separator: "|").contains(Substring($0.id.uuidString)) } ?? false
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                PhotosPicker(selection: $selection, matching: .images) {
                                    Text("更换壁纸").font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                                }.buttonStyle(.borderedProminent).disabled(locked).accessibilityIdentifier("maker.select")
                                    .accessibilityLabel("更换壁纸")
                                Button { adjusting = true } label: {
                                    Text("裁剪调色").font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                                }.buttonStyle(.bordered).disabled(locked)
                                    .accessibilityIdentifier("maker.adjust")
                                Button { prepareShare() } label: {
                                    Text(shared ? "已共享" : "分享").font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                                }.buttonStyle(.bordered).disabled(locked || shared)
                                    .accessibilityIdentifier("wallpaper.share")
                                if model.photoDownloadUnlocked {
                                    Button { downloadPhoto() } label: {
                                        if savingPhoto {
                                            ProgressView().accessibilityLabel("正在保存到相册")
                                        } else {
                                            Text("下载").lineLimit(1)
                                        }
                                    }.buttonStyle(.bordered).disabled(locked)
                                        .accessibilityIdentifier("maker.download")
                                        .accessibilityLabel(savingPhoto ? "正在保存到相册" : "下载")
                                        .accessibilityHint("保存调整后的照片到相册")
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                Button(role: .destructive) { removeCurrent() } label: { Image(systemName: "trash") }
                                    .buttonStyle(.bordered).disabled(locked).accessibilityLabel("移除当前照片")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Button { prepareCurrentWallpaper() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "car.side.fill")
                                    Text("应用到 CarPlay").lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(CanvasTheme.accent, in: Capsule())
                                .foregroundStyle(.white)
                                .opacity(locked ? 0.5 : 1)
                            }.buttonStyle(.plain).disabled(locked)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 6) {
                            PhotosPicker(selection: $selection, matching: .images) {
                                Label("相册", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).disabled(locked).accessibilityIdentifier("maker.select")
                                .accessibilityLabel("相册")
                            if let openGallery { Button("在线图库", action: openGallery).buttonStyle(.bordered) }
                        }.controlSize(.small)
                    }
                    if loading { ProgressView("正在导入照片…") }
                    if let problem { Text(problem).font(.subheadline).foregroundStyle(.red) }
                }.padding(16).frame(maxWidth: .infinity)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24))
                    .id("currentWallpaper")

                VStack(alignment: .leading, spacing: 12) {
                    Button { openShared?() } label: {
                        HStack {
                            Text("精选壁纸").font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).disabled(openShared == nil).accessibilityIdentifier("wallpaper.shared")
                    if sharedBusy != nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在下载原图，请稍候").font(.caption.weight(.semibold))
                        }
                    } else if !sharedNote.isEmpty {
                        Text(sharedNote).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(sharedTop) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button { importShared(item) } label: {
                                        GalleryImage(url: item.previewURL, mode: .fill)
                                            .frame(width: 160, height: 90)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay {
                                                if sharedBusy == item.id { WallpaperDownloadCover() }
                                            }
                                    }.buttonStyle(.plain)
                                        .disabled(locked || sharedBusy != nil)
                                        .accessibilityLabel("导入\(item.title)")
                                    Text(item.title).font(.caption).lineLimit(1)
                                    HStack {
                                        Label("\(item.likes)", systemImage: "heart").font(.caption2)
                                        Button { sharedComments = item } label: {
                                            Label("\(item.comments ?? 0)", systemImage: "bubble.left").font(.caption2)
                                        }.buttonStyle(.plain).accessibilityLabel("查看评论")
                                        Spacer(minLength: 0)
                                    }
                                }.frame(width: 160)

                            }
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24))
                if seriesVisible {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { openSeriesHeader() } label: {
                            HStack {
                                Text("系列壁纸").font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).disabled(openSeries == nil).accessibilityIdentifier("wallpaper.series")
                        if !seriesNote.isEmpty {
                            Text(seriesNote).font(.caption).foregroundStyle(.secondary)
                        }
                        if seriesEntries.isEmpty {
                            Text("正在加载系列…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(seriesEntries) { item in
                                        Button { openSeriesGroup?(item.parent, item) } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                GalleryImage(url: item.cover, mode: .fill)
                                                    .frame(width: 160, height: 90)
                                                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                                    .accessibilityHidden(true)
                                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                                    Text(item.title).font(.caption).lineLimit(1)
                                                    Spacer(minLength: 4)
                                                    Text("\(item.count) 张")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }.frame(width: 160, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(locked || openSeriesGroup == nil)
                                    }
                                }
                            }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardColor, in: RoundedRectangle(cornerRadius: 24))
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("CarPlay").font(.headline)
                    if model.group.isEmpty {
                        Label("未检测到签名组，请检查证书", systemImage: "exclamationmark.shield")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(red: 0.78, green: 0.16, blue: 0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Label("签名组已提供", systemImage: "checkmark.shield")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.11, green: 0.13, blue: 0.16), in: Capsule())
                    }
                    HStack {
                        Button("检测车机壁纸") { model.scan(deep: false) }.disabled(locked || model.group.isEmpty)
                        Spacer()
                        WallpaperRefreshButton().buttonStyle(.bordered)
                    }
                    if !model.targets.isEmpty { Text("已找到 \(model.targets.count) 个缓存文件").font(.caption).foregroundStyle(.secondary) }
                    if model.busy { ProgressView("正在处理…") }
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24))
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground)).tint(CanvasTheme.accent)
            .onChange(of: photo?.id) { _, id in
                if id != nil { withAnimation { scroll.scrollTo("currentWallpaper", anchor: .top) } }
            }
        }
            .navigationTitle("壁纸").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showTool(.history) } label: { Label("历史记录", systemImage: "clock") }
                        Button { showTool(.cache) } label: { Label("壁纸缓存", systemImage: "folder") }
                    } label: {
                        Label("壁纸工具", systemImage: "ellipsis.circle")
                    }.accessibilityIdentifier("wallpaper.tools")
                }
            }
            .navigationDestination(item: $tool) { destination in
                switch destination {
                case .history: CanvasHistoryView()
                case .cache: CacheBrowserView()
                }
            }
            .onAppear { initialize() }
            .task { await loadShared() }
            .task { await loadSeries() }
            .onChange(of: model.photoDownloadUnlocked) { _, _ in Task { await loadSeries() } }
            .alert("已保存到相册", isPresented: $savedToPhotos) { Button("好", role: .cancel) {} }
            .task(id: galleryImport?.id) { await importGallerySelection() }
            .task(id: selection) { await importSelection() }
            .task(id: photo?.id) { await loadSourcePixels() }
            .task(id: renderKey) { await refreshPreview() }
            .fullScreenCover(isPresented: $adjusting, onDismiss: { cropOrientation.restore() }) {
                if let photo { WallpaperAdjustmentView(photo: photo) { crop, color in
                    guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                    photos[index].adjustment = WallpaperAdjustment(pixelCrop: crop, color: color == .init() ? nil : color)
                    generated[photo.id] = nil
                    persist()
                }.modifier(CropLandscapeLayout(session: cropOrientation)) }
            }
            .sheet(isPresented: $applying) {
                if let photo, let entries = generated[photo.id] { NavigationStack { ApplyWallpaperView(entries: entries) } }
            }
            .sheet(item: $shareCollection) { collection in
                ShareWallpaperForm(collection: collection)
            }
            .sheet(item: $sharedComments, onDismiss: { Task { await loadShared() } }) { item in
                ShareCommentsView(item: item)
            }
    }

    private func downloadPhoto() {
        guard let photo, !locked else { return }
        savingPhoto = true
        problem = nil
        Task {
            defer { savingPhoto = false }
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                problem = "无法保存到相册。请在系统设置中允许 CarVista 添加照片。"
                return
            }
            do {
                let png = try await Task.detached {
                    try autoreleasepool {
                        let image = try WallpaperRenderer.render(url: photo.url, preset: .original, size: .zero, adjustment: photo.adjustment)
                        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                        return data
                    }
                }.value
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
                }
                savedToPhotos = true
            } catch {
                problem = "保存到相册失败：\(error.localizedDescription)"
            }
        }
    }
    private func showTool(_ destination: WallpaperRoute) {
        if let openTool { openTool(destination) } else { tool = destination }
    }

    private func importGallerySelection() async {
        guard let request = galleryImport else { return }
        while locked {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        loading = true
        problem = nil
        defer {
            loading = false
            if !Task.isCancelled, galleryImport?.id == request.id { galleryImport = nil }
        }
        do {
            var incoming = try await Task.detached { try MakerDraft.importPhoto(data: request.data) }.value
            incoming.sourceName = request.source == "buick" ? "别克大联屏" : request.source == "stock" ? "默认壁纸" : request.source == "share" ? "精选壁纸" : "在线图库"
            incoming.remoteSource = request.source
            incoming.remoteAssetID = request.assetID
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: incoming.url)
                return
            }
            try replaceCurrent(with: incoming)
            await ServiceClient.shared.record(type: "import_source", ok: true, payload: [
                "source": request.source, "asset_id": request.assetID ?? ""
            ])
        } catch {
            problem = "导入图库照片失败：\(error.localizedDescription)"
        }
    }
    private func loadShared() async {
        guard ServiceGate.enabled else {
            sharedNote = "当前无法连接后台。"
            sharedTop = []
            return
        }
        guard let remote = await ServiceClient.shared.fetchShares(sort: .likes) else {
            if !Task.isCancelled { sharedNote = "加载失败，请稍后重试。" }
            return
        }
        guard !Task.isCancelled else { return }
        sharedTop = Array(remote.prefix(10))
        sharedNote = remote.isEmpty ? "还没有人精选壁纸。" : ""
    }

    private func loadSeries() async {
        let categories = await GalleryCategory.fetch() ?? GalleryCategory.cached
        let hasCategory = categories.contains { $0.kind == "series" && $0.published != 0 }
        guard ServiceGate.enabled, hasCategory else {
            seriesVisible = false
            seriesEntries = []
            seriesNote = ""
            return
        }
        seriesVisible = true
        let entries = await GalleryCategory.fetchSeriesHomeEntries(includeHidden: model.photoDownloadUnlocked)
        seriesEntries = entries
        seriesNote = entries.isEmpty ? "还没有系列壁纸。" : ""
    }

    private func openSeriesHeader() {
        if let parent = seriesEntries.first?.parent {
            openSeries?(parent)
            return
        }
        if let parent = GalleryCategory.cached.first(where: { $0.kind == "series" && $0.published != 0 }) {
            openSeries?(parent)
        }
    }

    private func importShared(_ item: SharedWallpaper) {
        guard !locked, sharedBusy == nil else { return }
        sharedBusy = item.id
        problem = nil
        Task {
            defer { sharedBusy = nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: item.originalURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                    problem = "无法下载这张壁纸。"
                    return
                }
                galleryImport = GalleryImport(data: data, source: "share", assetID: item.id)
            } catch {
                problem = "无法下载这张壁纸。"
            }
        }
    }

    private func replaceCurrent(with incoming: MakerPhoto) throws {
        var updated = photos
        let old = photo
        if old == nil { updated.append(incoming) } else { updated[current] = incoming }
        do {
            try MakerDraft.save(updated)
        } catch {
            try? FileManager.default.removeItem(at: incoming.url)
            throw error
        }
        photos = updated
        if let old {
            generated[old.id] = nil
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private func prepareShare() {
        guard let photo, !locked else { return }
        if let entries = generated[photo.id], let first = entries.first {
            shareCollection = WallpaperCollection(id: first.batchID ?? first.id, entries: entries)
            return
        }
        model.generatePhotos([photo], preset: .original, size: outputSize) { batches in
            guard let entries = batches.first, let first = entries.first else {
                problem = model.message
                return
            }
            generated[photo.id] = entries
            shareCollection = WallpaperCollection(id: first.batchID ?? first.id, entries: entries)
        }
    }

    private func prepareCurrentWallpaper() {
        guard let photo, !locked else { return }
        if generated[photo.id] != nil {
            applying = true
            return
        }
        problem = nil
        model.generatePhotos([photo], preset: .original, size: outputSize) { batches in
            guard let entries = batches.first, !entries.isEmpty else {
                problem = model.message
                return
            }
            generated[photo.id] = entries
            applying = true
        }
    }
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        photos = MakerDraft.load()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-MakerUITestFixture"), let data = UIImage(named: "BrandMark")?.pngData(),
           let fixture = try? MakerDraft.importPhoto(data: data) {
            photos = [fixture]
        }
        #endif
    }
    private func persist() {
        do { try MakerDraft.save(photos) } catch { problem = "保存照片选择失败：\(error.localizedDescription)" }
    }
    private func removeCurrent() {
        guard photos.indices.contains(current), !locked else { return }
        let old = photos.remove(at: current); current = min(current, max(0, photos.count - 1))
        generated = [:]; persist(); try? FileManager.default.removeItem(at: old.url)
    }
    private func importSelection() async {
        guard let item = selection, !locked else { return }
        loading = true
        problem = nil
        defer { loading = false; selection = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            var incoming = try await Task.detached(priority: .userInitiated) { try MakerDraft.importPhoto(data: data) }.value
            incoming.sourceName = "相册照片"
            incoming.remoteSource = "photo"
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: incoming.url)
                return
            }
            try replaceCurrent(with: incoming)
        } catch {
            if !(error is CancellationError) { problem = "导入失败：\(error.localizedDescription)" }
        }
    }
    private func loadSourcePixels() async {
        guard let url = photo?.url else { sourcePixels = nil; return }
        sourcePixels = nil
        let pixels = try? await Task.detached { try WallpaperRenderer.pixelSize(url) }.value
        if !Task.isCancelled { sourcePixels = pixels }
    }
    private func refreshPreview() async {
        guard let photo else { preview = nil; return }
        previewing = true
        let size = outputSize
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            let result = try await Task.detached(priority: .userInitiated) {
                try autoreleasepool { try WallpaperRenderer.render(url: photo.url, preset: .original, size: size, adjustment: photo.adjustment) }
            }.value
            try Task.checkCancellation(); preview = result; previewing = false
        } catch { if !Task.isCancelled { preview = nil; previewing = false; problem = "预览失败：\(error.localizedDescription)" } }
    }
}

private struct MakerThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(uiColor: .tertiarySystemFill) } }
            .task(id: url) { image = await Task.detached { try? WallpaperRenderer.load(url, maximum: 160) }.value }
    }
}
                                                                                                                                                                                                    
