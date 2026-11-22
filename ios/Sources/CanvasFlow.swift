// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI
import ImageIO
import WebKit

enum CanvasTheme {
    static let accent = Color(red: 0.0, green: 0.55, blue: 0.58)
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

struct WallpaperCollection: Identifiable {
    let id: UUID
    let entries: [SavedWallpaper]
    var first: SavedWallpaper { entries[0] }
    var title: String {
        first.customName ?? "CarVista-\(first.created.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))"
    }
    var mode: String {
        let names = Set(entries.map(\.mode))
        if names.contains("车机") { return "车机整屏与 CarPlay 右半" }
        return names.count > 1 ? "深色与浅色" : first.mode
    }
}

extension WorkshopModel {
    var collections: [WallpaperCollection] {
        Dictionary(grouping: history, by: { $0.batchID ?? $0.id }).map {
            WallpaperCollection(id: $0.key, entries: $0.value.sorted { $0.mode < $1.mode })
        }.sorted { $0.first.created > $1.first.created }
    }
}

enum WallpaperRoute: Hashable {
    case history, cache
}

struct GalleryPick {
    var data: Data
    var source: String
    var assetID: String? = nil
}

struct GalleryImport: Identifiable {
    let id = UUID()
    let data: Data
    var source: String = "gallery"
    var assetID: String? = nil
}

struct CanvasHomeView: View {
    private enum Tab: Hashable { case wallpaper, gallery, history, settings }
    @AppStorage("CCGuideSeen") private var guideSeen = false
    @State private var guide = false
    @State private var tab = Tab.wallpaper
    @State private var gallerySource = WallpaperGalleryView.Source.stock
    @State private var gallerySeriesGroupID: String?
    @State private var wallpaperPath: [WallpaperRoute] = []
    @State private var galleryImport: GalleryImport?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $wallpaperPath) {
                ComposeWallpaperView(
                    galleryImport: $galleryImport,
                    openGallery: { tab = .gallery },
                    openShared: {
                        gallerySource = .share
                        gallerySeriesGroupID = nil
                        tab = .gallery
                    },
                    openSeries: { parent in
                        gallerySource = parent
                        gallerySeriesGroupID = nil
                        tab = .gallery
                    },
                    openSeriesGroup: { parent, entry in
                        gallerySource = parent
                        gallerySeriesGroupID = entry.id
                        tab = .gallery
                    }
                ) { wallpaperPath.append($0) }
                    .navigationDestination(for: WallpaperRoute.self) { destination in
                        switch destination {
                        case .history: CanvasHistoryView()
                        case .cache: CacheBrowserView()
                        }
                    }
            }
            .tabItem { Label("壁纸", systemImage: "photo.on.rectangle") }.tag(Tab.wallpaper)

            NavigationStack {
                WallpaperGalleryView(use: { pick in
                    galleryImport = GalleryImport(data: pick.data, source: pick.source, assetID: pick.assetID)
                    wallpaperPath.removeAll()
                    tab = .wallpaper
                }, source: $gallerySource, focusSeriesGroupID: $gallerySeriesGroupID)
            }
            .tabItem { Label("图库", systemImage: "photo.stack") }.tag(Tab.gallery)

            NavigationStack { CanvasHistoryView() }
                .tabItem { Label("历史记录", systemImage: "clock") }.tag(Tab.history)

            NavigationStack { CanvasSettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .tint(CanvasTheme.accent)
        .task { if !guideSeen { guide = true } }
        .sheet(isPresented: $guide, onDismiss: { guideSeen = true }) { CanvasGuideView() }
    }
}
private enum HistoryShareFilter: String, CaseIterable, Identifiable {
    case all = "全部", shared = "已共享", unshared = "未共享"
    var id: String { rawValue }
}

struct CanvasHistoryView: View {
    @EnvironmentObject var model: WorkshopModel
    @AppStorage("CarVistaSharedHistory") private var sharedHistory = ""
    @State private var clear = false
    @State private var remove: WallpaperCollection?
    @State private var shareTarget: WallpaperCollection?
    @State private var detailTarget: WallpaperCollection?
    @State private var shareText = ""
    @State private var shareTitle = ""
    @State private var shareAuthor = ""
    @State private var sharingID: UUID?
    @State private var shareNotes: [UUID: String] = [:]
    @State private var shareFilter: HistoryShareFilter = .all
    private var sharedIDs: Set<String> { Set(sharedHistory.split(separator: "|").map(String.init)) }
    private var visibleCollections: [WallpaperCollection] {
        model.collections.filter { collection in
            let shared = collection.entries.contains { sharedIDs.contains($0.id.uuidString) }
            switch shareFilter {
            case .all: return true
            case .shared: return shared
            case .unshared: return !shared
            }
        }
    }
    var body: some View {
        List {
            Picker("共享状态", selection: $shareFilter) {
                ForEach(HistoryShareFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.collections.isEmpty {
                ContentUnavailableView("还没有保存的壁纸", systemImage: "photo.stack", description: Text("到“壁纸”选择图片，保存后就会出现在这里。"))
            }
            if !model.collections.isEmpty && visibleCollections.isEmpty {
                ContentUnavailableView(shareFilter == .shared ? "还没有已共享的壁纸" : "没有未共享的壁纸", systemImage: "photo.stack")
            }
            ForEach(visibleCollections) { collection in
                let shared = collection.entries.contains { sharedHistory.split(separator: "|").contains(Substring($0.id.uuidString)) }
                ZStack(alignment: .trailing) {
                    Button { detailTarget = collection } label: {
                        HStack(spacing: 12) {
                            SavedThumbnail(entry: collection.first).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 15))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(collection.title).font(.headline).lineLimit(2)
                                Text(collection.first.created, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                Text("\(collection.mode) · 本地生成").font(.caption).foregroundStyle(.secondary)
                                if let note = shareNotes[collection.id] {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 76)
                        }.padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    Button(sharingID == collection.id ? "正在共享…" : shared ? "已共享" : "共享") {
                        shareText = ""
                        shareTitle = collection.title
                        shareAuthor = ""
                        shareTarget = collection
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CanvasTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(CanvasTheme.accent)
                    .disabled(model.busy || sharingID != nil || shared)
                    .accessibilityLabel("\(shared ? "已共享" : "共享")\(collection.title)")
                }
                .swipeActions { Button("删除", role: .destructive) { remove = collection }.disabled(model.busy) }
            }
        }
            .navigationDestination(isPresented: Binding(
                get: { detailTarget != nil },
                set: { if !$0 { detailTarget = nil } }
            )) {
                if let collection = detailTarget {
                    WallpaperDetailView(collectionID: collection.id)
                }
            }
            .navigationTitle("历史记录").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { Button("全部清空") { clear = true }.disabled(model.history.isEmpty || model.busy) }
            .confirmationDialog("清空所有本地壁纸记录？已应用的车机壁纸和恢复备份会保留。", isPresented: $clear, titleVisibility: .visible) {
                Button("全部清空", role: .destructive) { model.deleteHistory(model.history) }
            }
            .confirmationDialog("删除这条本地记录？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { if let remove { model.deleteHistory(remove.entries) }; remove = nil }
            }
            .sheet(item: $shareTarget) { collection in
                NavigationStack {
                    Form {
                        Section("作者") { TextField("作者，可以留空", text: $shareAuthor) }
                        Section("壁纸名称") { TextField("壁纸名称", text: $shareTitle) }
                        Section {
                            TextField("写一段介绍，可以留空", text: $shareText, axis: .vertical)
                                .lineLimit(3...6)
                        } footer: {
                            Text("介绍会显示在图库的精选壁纸里。")
                        }
                    }
                    .navigationTitle("精选壁纸")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { shareTarget = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("共享") {
                                let intro = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
                                shareTarget = nil
                                share(collection, intro: intro)
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
    }

    private func share(_ collection: WallpaperCollection, intro: String) {
        let shown = collection.entries.first { $0.mode == "车机" } ?? collection.first
        let title = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = shareAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        sharingID = collection.id
        shareNotes[collection.id] = nil
        Task {
            defer { sharingID = nil }
            let ok = await ServiceClient.shared.submitShare(shown, title: title.isEmpty ? collection.title : title, description: intro, author: author)
            shareNotes[collection.id] = ok ? "已共享到图库的「精选壁纸」。" : "共享失败，请检查网络后重试。"
        }
    }
}

private struct SavedThumbnail: View {
    let entry: SavedWallpaper
    var body: some View {
        if let image = UIImage(contentsOfFile: entry.preview.path) { Image(uiImage: image).resizable().scaledToFill() }
        else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
    }
}

struct WallpaperDetailView: View {
    @EnvironmentObject var model: WorkshopModel
    @AppStorage("CarVistaSharedHistory") private var sharedHistory = ""
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID
    var startSharing = false
    @State private var applying = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""
    @State private var sharing = false
    @State private var shareNote: String?
    @State private var shareDraft = false
    @State private var shareText = ""
    @State private var shareTitle = ""
    @State private var shareAuthor = ""
    @State private var editingShare = false
    private var collection: WallpaperCollection? { model.collections.first { $0.id == collectionID } }
    var body: some View {
        Group {
            if let collection {
                List {
                    Section {
                        let shown = collection.entries.first { $0.mode == "车机" } ?? collection.first
                        SavedThumbnail(entry: shown)
                            .aspectRatio(CGFloat(shown.width) / CGFloat(max(shown.height, 1)), contentMode: .fit).clipped()
                        Text(collection.title).font(.headline)
                        Text("\(collection.mode) · \(shown.width) × \(shown.height)").foregroundStyle(.secondary)
                        if let preset = collection.first.outputPreset { Text("\(preset) · 生成后直接写入").font(.caption).foregroundStyle(.secondary) }
                        if collection.first.preservePixels == true { Text("原尺寸直接写入").font(.caption).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button { applying = true } label: { Label("应用到 CarPlay 壁纸", systemImage: "car.side.fill").font(.headline) }.disabled(model.busy)
                        let shared = collection.entries.contains { sharedHistory.split(separator: "|").contains(Substring($0.id.uuidString)) }
                        Button(sharing ? "正在处理…" : shared ? "编辑共享" : "共享到图库") {
                            prepareShare(collection, shared: shared)
                        }
                        .disabled(model.busy || sharing)
                        if let shareNote { Text(shareNote).font(.footnote).foregroundStyle(.secondary) }
                        ShareLink(items: collection.entries.map(\.bitmap)) { Label("分享 CPBitmap 文件", systemImage: "square.and.arrow.up") }
                        if let dashboard = collection.entries.first(where: { $0.mode == "车机" }) {
                            ShareLink(item: dashboard.originalImage) { Label("分享车机整屏图片", systemImage: "photo") }
                        }
                        Button("重命名") { name = collection.title; renaming = true }.disabled(model.busy)
                    }
                    Section { Button("删除记录", role: .destructive) { deleting = true }.disabled(model.busy) }
                }
            } else { ContentUnavailableView("记录已删除", systemImage: "photo") }
        }.navigationTitle("壁纸详情").navigationBarTitleDisplayMode(.inline)
            .task {
                if startSharing, let collection {
                    let shared = collection.entries.contains { sharedHistory.split(separator: "|").contains(Substring($0.id.uuidString)) }
                    prepareShare(collection, shared: shared)
                }
            }
            .sheet(isPresented: $applying) { if let collection { NavigationStack { ApplyWallpaperView(entries: collection.entries) } } }
            .sheet(isPresented: $shareDraft) {
                NavigationStack {
                    Form {
                        Section("作者") { TextField("作者，可以留空", text: $shareAuthor) }
                        Section("壁纸名称") { TextField("壁纸名称", text: $shareTitle) }
                        Section {
                            TextField("写一段介绍，可以留空", text: $shareText, axis: .vertical)
                                .lineLimit(3...6)
                        } footer: {
                            Text("介绍会显示在图库的共享分类里。")
                        }
                    }
                    .navigationTitle(editingShare ? "编辑共享" : "精选壁纸")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { shareDraft = false }.disabled(sharing) }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(editingShare ? "保存" : "共享") {
                                if let collection { share(collection) }
                            }
                            .disabled(sharing || shareTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let shareNote {
                            Text(shareNote).font(.footnote).padding().frame(maxWidth: .infinity)
                                .background(.regularMaterial)
                        }
                    }
                    .interactiveDismissDisabled(sharing)
                }
                .presentationDetents([.medium])
            }
            .alert("重命名", isPresented: $renaming) {
                TextField("壁纸名称", text: $name)
                Button("保存") { if let collection { model.renameHistory(collection.entries, name: name) } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("只删除本地记录，车机壁纸与恢复备份会保留。", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { if let collection { model.deleteHistory(collection.entries); dismiss() } }
            }
    }

    private func prepareShare(_ collection: WallpaperCollection, shared: Bool) {
        editingShare = shared
        shareNote = nil
        shareTitle = collection.title
        shareAuthor = ""
        shareText = ""
        if !shared { shareDraft = true; return }
        sharing = true
        Task {
            defer { sharing = false }
            let shown = collection.entries.first { $0.mode == "车机" } ?? collection.first
            guard let metadata = await ServiceClient.shared.shareMetadata(shown.id) else {
                shareNote = "无法读取共享信息，请确认后台已更新并重试。"
                return
            }
            shareTitle = metadata.title
            shareText = metadata.description
            shareAuthor = metadata.author ?? ""
            shareDraft = true
        }
    }

    private func share(_ collection: WallpaperCollection) {
        let shown = collection.entries.first { $0.mode == "车机" } ?? collection.first
        sharing = true
        shareNote = nil
        let title = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = shareAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
        let editing = editingShare
        Task {
            defer { sharing = false }
            let ok: Bool
            if editing {
                ok = await ServiceClient.shared.updateShare(shown.id, title: title, description: intro, author: author)
            } else {
                ok = await ServiceClient.shared.submitShare(shown, title: title, description: intro, author: author)
            }
            if ok {
                shareDraft = false
                shareNote = editing ? "共享信息已更新。" : "已共享到图库的「精选壁纸」。"
            } else {
                shareNote = "操作失败，请检查网络后重试。"
            }
        }
    }
}

private struct TargetFamily: Identifiable {
    let id: String
    let targets: [WallpaperTarget]
    var title: String {
        let names = ["Blue": "蓝色", "Purple": "紫色", "Gray": "灰色", "Green": "绿色", "Brown": "棕色", "Red": "红色", "Black": "黑色"]
        for (key, value) in names where id.localizedCaseInsensitiveContains(key) { return "\(value)壁纸" }
        return URL(fileURLWithPath: id).lastPathComponent.replacingOccurrences(of: "CARWallpaper", with: "壁纸 ")
    }
}

private func targetFamilies(_ targets: [WallpaperTarget]) -> [TargetFamily] {
    Dictionary(grouping: targets, by: {
        $0.id.replacingOccurrences(of: "-Dark", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-Light", with: "", options: .caseInsensitive)
    }).map { TargetFamily(id: $0.key, targets: $0.value) }.sorted { $0.id < $1.id }
}

struct ApplyWallpaperView: View {
    @EnvironmentObject var model: WorkshopModel
    @Environment(\.dismiss) private var dismiss
    let entries: [SavedWallpaper]
    @State private var selected: [WallpaperTarget] = []
    @State private var repairTargets: [WallpaperTarget] = []
    @State private var confirmRepair = false
    @State private var confirmation = false
    @State private var completed: Int?
    @State private var targetName = ""
    @State private var resultMessage = ""
    private var finished: Bool { completed == selected.count && !selected.isEmpty }
    private var modes: Set<String> { Set(entries.map(\.mode)) }
    var body: some View {
        List {
            Section {
                if let completed {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(finished ? "壁纸已写入，等待车机刷新" : completed == 0 ? "写入失败" : "部分壁纸已写入",
                              systemImage: finished ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(finished ? Color.green : Color.orange)
                        Divider()
                        Text(resultMessage).font(.footnote)
                        if finished {
                            Text("重新连接 CarPlay 后查看新壁纸，建议重启 iPhone。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                } else {
                    Text("选择要替换的车机壁纸。原壁纸会自动备份。")
                }
                if model.busy { ProgressView("正在处理，请保持应用在前台…") }
            }
            if let completed, completed > 0 {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("立即刷新系统界面").font(.subheadline.weight(.semibold))
                        Text("点击下方按钮尝试刷新系统界面，可能短暂黑屏或返回桌面。请在停车状态下操作。")
                            .font(.caption).foregroundStyle(.secondary)
                        ApplyResultLogoutButton()
                        Text("若刷新无效，请手动重启 iPhone 后重新连接 CarPlay。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
            if !finished {
                if !model.targets.isEmpty {
                    Section {
                        Button("重新检查深浅状态") { model.scan(deep: true) }
                            .disabled(model.busy || model.group.isEmpty)
                    }
                }
                if model.targets.filter(\.editable).isEmpty {
                    Section {
                        if !model.targets.isEmpty { Text("找到缓存，但当前格式或尺寸无法替换。请重新查找，或在设置中导出诊断报告。") }
                        Text(model.group.isEmpty ? "当前安装缺少车机访问权限，需重新签名。已保存的壁纸不受影响。" : model.message)
                        Button(completed == nil ? "重新查找" : "重新查找并选择目标") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty)
                        Button("继续查找（首次可能需要几分钟）") { model.scan(deep: true) }.disabled(model.busy || model.group.isEmpty)
                        if model.busy { Button("停止查找") { CCEngine.cancelScan() } }
                    }
                }
                if !model.lastRepairSummary.isEmpty {
                    Section("补回结果") { Text(model.lastRepairSummary).font(.footnote) }
                }
                ForEach(targetFamilies(model.targets)) { family in
                    Section(family.title) {
                        familyCard(family)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }.navigationTitle("应用到 CarPlay").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(finished ? "完成" : "关闭") { dismiss() }.disabled(model.busy) }
            .alert("补回已记录的壁纸？", isPresented: $confirmRepair) {
                Button("暂不处理", role: .cancel) { }
                Button("补回 \(repairTargets.count) 个文件") { model.repairMissing(repairTargets) }
            } message: {
                Text("使用本机副本补回缺失位置。副本可能是原始壁纸，补回后可重新选择图片；已有文件不会被覆盖。")
            }
            .interactiveDismissDisabled(model.busy)
            .task { if model.targets.isEmpty && !model.busy && !model.group.isEmpty { model.scan(deep: false) } }
            .sheet(isPresented: $confirmation) {
                NavigationStack {
                    List {
                        if let entry = entries.first, let image = UIImage(contentsOfFile: entry.preview.path) {
                            Section("新壁纸") { Image(uiImage: image).resizable().scaledToFit() }
                        }
                        Section("将替换「\(targetName)」") {
                            if let target = selected.first { ApplyTargetPreview(target: target) }
                            Text(selected.map(\.mode).joined(separator: "、"))
                            Text("应用前会自动备份原壁纸。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("确认替换").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { confirmation = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("确认替换") {
                                    confirmation = false
                                    completed = nil
                                    model.applyBatch(entries: entries, targets: selected) { count in
                                        completed = count
                                        resultMessage = model.message
                                    }
                            }.disabled(model.busy)
                            }
                        }
                }
            }
    }

    private func choose(_ targets: [WallpaperTarget], name: String) {
        selected = targets
        targetName = name
        confirmation = true
    }

    private func writableTarget(_ mode: String, in family: TargetFamily) -> WallpaperTarget? {
        let candidates = family.targets.filter { $0.mode == mode }
        guard candidates.count == 1, let target = candidates.first, target.editable,
              entries.count == 1 || modes.contains(mode) else { return nil }
        return target
    }

    private func unavailableReason(_ mode: String, in family: TargetFamily) -> String? {
        let candidates = family.targets.filter { $0.mode == mode }
        guard !candidates.isEmpty else { return "尚未找到\(mode)文件，请重新检查深浅状态。" }
        guard candidates.count == 1 else { return "\(mode)位置存在重复记录，请重新查找。" }
        guard let target = candidates.first, target.editable else {
            return "\(mode)：\(candidates.first?.status ?? "暂不可用")"
        }
        guard entries.count == 1 || modes.contains(mode) else { return "当前作品没有\(mode)图片，请先保存对应图片。" }
        return nil
    }

    private func familyCard(_ family: TargetFamily) -> some View {
        let dark = writableTarget("深色", in: family)
        let light = writableTarget("浅色", in: family)
        return VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                modeCard("深色", family: family, writable: dark)
                modeCard("浅色", family: family, writable: light)
            }
            Button {
                if let dark, let light { choose([dark, light], name: family.title) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.on.square")
                    Text("同时写入深色与浅色")
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .foregroundStyle(CanvasTheme.accent)
                .background(CanvasTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || dark == nil || light == nil)
            .opacity(model.busy || dark == nil || light == nil ? 0.45 : 1)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
    }

    private func modeCard(_ mode: String, family: TargetFamily, writable: WallpaperTarget?) -> some View {
        let target = family.targets.first(where: { $0.mode == mode && $0.editable })
            ?? family.targets.first(where: { $0.mode == mode })
        return VStack(spacing: 5) {
            if let target {
                ApplyTargetPreview(target: target)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    .frame(height: 68)
            }
            Button {
                if let writable { choose([writable], name: family.title) }
            } label: {
                Text("写入\(mode)")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .foregroundStyle(CanvasTheme.accent)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || writable == nil)
            .opacity(model.busy || writable == nil ? 0.45 : 1)
            if let reason = unavailableReason(mode, in: family) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let repair = family.targets.first(where: { $0.mode == mode && $0.repairable }) {
                    Button("补回\(mode)") { repairTargets = [repair]; confirmRepair = true }
                        .font(.caption)
                        .disabled(model.busy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

}

private struct ApplyTargetPreview: View {
    let target: WallpaperTarget
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    ZStack {
                        // 用同一张图片的柔化背景填满容器，消除灰边；前景完整保留原图。
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: 9)
                            .overlay(Color.black.opacity(0.10))
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .frame(height: 68)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: target.id) {
            image = nil
            let path = target.id
            let preview = await Task.detached { CCEngine.preview(path) }.value
            if !Task.isCancelled { image = preview }
        }
    }
}

struct CacheBrowserView: View {
    @EnvironmentObject var model: WorkshopModel
    var body: some View {
        List {
            Section {
                if model.busy { ProgressView("正在查找车机壁纸…"); Button("停止查找") { CCEngine.cancelScan() } }
                if model.targets.isEmpty {
                    Text(model.group.isEmpty ? "当前安装无法访问车机壁纸。你仍可在首页制作和保存壁纸。" : model.message)
                    Button("查找车机壁纸") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty)
                    Button("继续查找（首次使用）") { model.scan(deep: true) }.disabled(model.busy || model.group.isEmpty)
                } else { Text("记录 \(model.targets.count) 个位置 · 可替换 \(model.targets.filter(\.editable).count) 个").foregroundStyle(.secondary) }
            }
            ForEach(targetFamilies(model.targets)) { family in
                Section(family.title) {
                    ForEach(family.targets) { target in
                        NavigationLink { CacheDetailView(target: target) } label: {
                            Label("\(target.mode) · \(target.width) × \(target.height)", systemImage: target.mode == "深色" ? "moon.fill" : "sun.max.fill")
                        }.disabled(model.busy)
                    }
                }
            }
            Section { NavigationLink { BackupsView() } label: { Label("备份与恢复", systemImage: "arrow.uturn.backward") } }
        }.navigationTitle("CarPlay 壁纸缓存").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { Button("刷新") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty) }
            .task { if model.targets.isEmpty && !model.busy && !model.group.isEmpty { model.scan(deep: false) } }
    }
}

private struct CacheDetailView: View {
    let target: WallpaperTarget
    @State private var preview: UIImage?
    @State private var loading = true
    var body: some View {
        List {
            Section {
                if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                else if loading { ProgressView("载入预览…") }
                else { ContentUnavailableView("暂时无法预览", systemImage: "photo") }
                Text("\(target.mode) · \(target.width) × \(target.height)")
            }
            Section { NavigationLink("从历史记录选择壁纸") { CanvasHistoryView() }; NavigationLink("制作新壁纸") { ComposeWallpaperView() } }
            Section { DisclosureGroup("文件信息") { Text(target.name).font(.caption); Text(target.id).font(.caption).textSelection(.enabled) } }
        }.navigationTitle("缓存预览").navigationBarTitleDisplayMode(.inline)
            .task { preview = await Task.detached { CCEngine.preview(target.id) }.value; loading = false }
    }
}

struct CanvasGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let steps = [
        ("生成车机壁纸缓存", "停车后，在车机 CarPlay 的“设置 → 壁纸”中切换几张内置图片壁纸。不同系统的排列可能不同。"),
        ("选择照片", "在“壁纸”里选相册照片，或点“精选壁纸”查看大家共享的壁纸。需要裁剪时点“裁剪”。"),
        ("选择目标并应用", "点“应用到 CarPlay”即可生成文件并选择替换目标，原文件会自动备份。历史记录在底部菜单，壁纸缓存位于“壁纸”右上角。"),
        ("重启 CarPlay，让壁纸生效", "替换后点“重启 CarPlay”，尝试重载系统界面。返回桌面后重新连接车机，确认新壁纸是否生效。若仍显示旧图，请手动重启 iPhone。需要还原时，可在设置中打开“备份与恢复”。")]
    var body: some View {
        NavigationStack {
            List {
                Section("只需四步") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 15) {
                            Text("\(index + 1)").font(.title3.bold()).foregroundStyle(CanvasTheme.accent)
                                .frame(width: 38, height: 42).background(CanvasTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 8) { Text(item.0).font(.headline); Text(item.1).font(.subheadline).foregroundStyle(.secondary) }
                        }.padding(.vertical, 10)
                    }
                }
                Text("你可以随时在“设置”里重新打开此指南。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("使用指南").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("知道了") { dismiss() }.fontWeight(.semibold).accessibilityIdentifier("guide.done") }
        }.tint(CanvasTheme.accent)
    }
}

struct CanvasSettingsView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var guide = false
    @State private var logoTaps = 0
    @State private var lastLogoTap = Date.distantPast
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Button(action: registerLogoTap) {
                        Image("BrandMark").resizable().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 15))
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("settings.logo")
                        .accessibilityLabel("CarVista")
                    VStack(alignment: .leading, spacing: 5) { Text("CarVista").font(.headline); Text("v\(CanvasTheme.version)").font(.subheadline).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
            Section {
                Button { guide = true } label: { Label("使用指南", systemImage: "book") }
                NavigationLink { SupportedDevicesView() } label: { Label("支持机型", systemImage: "iphone") }
                NavigationLink { BackupsView() } label: { Label("备份与恢复", systemImage: "arrow.uturn.backward") }
                NavigationLink { HelpView() } label: { Label("安装检查与诊断", systemImage: "stethoscope") }
            }
            Section("关于") {
                NavigationLink { AppUpdateView() } label: { Label("检查 App 更新", systemImage: "arrow.down.circle") }
                Link("项目源码", destination: URL(string: "https://github.com/zhixinsky/CarVista")!)
                Text("基于公开研究实现。感谢 WQFiles 与 worse_query 作者。GPL-3.0-or-later。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("制作记录和 CarPlay 失败信息会发送到服务端，用于改进兼容性。App 内不显示账号。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("iOS 27.2 与实际车机效果仍需设备验证。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $guide) { CanvasGuideView() }
    }

    private func registerLogoTap() {
        let now = Date()
        if now.timeIntervalSince(lastLogoTap) > 1.5 { logoTaps = 0 }
        lastLogoTap = now
        logoTaps += 1
        guard logoTaps >= 5 else { return }
        logoTaps = 0
        model.photoDownloadUnlocked = true
    }
}

struct CompatibilityFeed: Decodable {
    let items: [CompatibleDevice]
}

struct CompatibleDevice: Decodable, Identifiable {
    let id: String
    let machine: String
    let name: String
    let system: String
}

private struct SupportedDevicesView: View {
    @State private var items: [CompatibleDevice] = []
    @State private var loading = false
    @State private var failed = false
    var body: some View {
        List {
            Section {
                Text("理论上支持 iOS 26.0–27.3 Beta 1")
            }
            Section("已有成功记录") {
                ForEach(items) { item in
                    LabeledContent(item.name, value: item.system)
                }
                if loading { ProgressView() }
                if failed {
                    Button("加载失败，点击重试") { Task { await reload() } }
                }
            }
        }
        .navigationTitle("支持机型")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do { items = try await ServiceClient.shared.compatibility().items }
        catch { failed = true }
    }
}
// Only used in the post-apply result sheet. The wallpaper page's existing
// WallpaperRefreshButton remains untouched.
private struct ApplyResultLogoutButton: View {
    @EnvironmentObject private var model: WorkshopModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var controller = RespringController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { controller.start() } label: {
                Text(controller.active ? "正在刷新…" : "注销并刷新")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.black, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || controller.active)

            if controller.active, let webView = controller.webView {
                ApplyResultRespringSurface(webView: webView)
                    .frame(height: 180)
                    .allowsHitTesting(false)
                ProgressView("正在尝试刷新系统界面…").font(.caption)
                Button("停止尝试") { controller.stop("已停止，未确认是否刷新。") }
                    .font(.caption)
            } else if controller.message != "让系统重新加载界面和壁纸，可能短暂黑屏并返回桌面。请停车后操作。" {
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .active && controller.active {
                controller.stop("尝试已结束，请重新连接 CarPlay 检查壁纸效果。")
            }
        }
        .onDisappear {
            if controller.active { controller.stop("已停止。") }
        }
    }
}

private struct ApplyResultRespringSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
