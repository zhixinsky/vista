// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BuickWallpaperGalleryView: View {
    @EnvironmentObject private var model: WorkshopModel
    let use: (GalleryPick) -> Void
    @StateObject private var catalog = CatalogStore(collection: .buick)
    @State private var selection: CatalogItem?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("别克大联屏用户请自行裁剪尺寸", systemImage: "crop")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !catalog.note.isEmpty {
                    Text(catalog.note).font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(catalog.items) { wallpaper in
                        Button { error = nil; selection = wallpaper } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CatalogThumb(item: wallpaper)
                                    .frame(maxWidth: .infinity)
                                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .accessibilityHidden(true)
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(wallpaper.title).font(.subheadline).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let remote = wallpaper.remote, remote.width > 0, remote.height > 0 {
                                        Text("\(remote.width) × \(remote.height)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .task { await catalog.refresh() }
        .sheet(item: $selection) { wallpaper in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        CatalogThumb(item: wallpaper).frame(maxWidth: .infinity)
                        Text("别克大联屏用户请自行裁剪尺寸").font(.subheadline)
                        Text("导入整张原图后，回到壁纸页点「裁剪」。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(loading ? "正在导入…" : "使用原图") { importOriginal(wallpaper) }
                            .buttonStyle(.borderedProminent).disabled(loading || model.busy)
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }.padding(16)
                }
                .navigationTitle(wallpaper.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { selection = nil }.disabled(loading) }
                .interactiveDismissDisabled(loading)
            }
        }
    }

    private func importOriginal(_ wallpaper: CatalogItem) {
        guard !loading, !model.busy else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let data = try await CatalogLibrary.originalData(wallpaper)
                selection = nil
                use(GalleryPick(data: data, source: "buick", assetID: wallpaper.remote?.id))
                await ServiceClient.shared.record(type: "pick_catalog", ok: true, payload: [
                    "collection": "buick", "title": wallpaper.title, "asset_id": wallpaper.remote?.id ?? ""
                ])
            } catch {
                self.error = "无法读取原图，请重试。"
            }
        }
    }
}
