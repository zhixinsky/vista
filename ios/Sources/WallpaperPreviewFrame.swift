import SwiftUI

struct WallpaperPreviewFrame: View {
    let image: UIImage?
    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .blur(radius: 18).overlay(.black.opacity(0.1))
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else { ProgressView().frame(width: geometry.size.width, height: geometry.size.height) }
                }
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .allowsHitTesting(false)
    }
}

struct RemoteWallpaperPreview: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false
    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(CatalogLibrary.savedImage))
    }
    var body: some View {
        WallpaperPreviewFrame(image: image)
            .overlay { if failed { Button("重新加载") { Task { await load() } }.buttonStyle(.bordered) } }
            .task(id: url) { await load() }
    }
    private func load() async {
        failed = false
        guard let url else { failed = true; return }
        let loaded = await CatalogLibrary.cachedImage(url)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

struct CatalogWallpaperPreview: View {
    let item: CatalogItem
    @State private var image: UIImage?
    var body: some View {
        WallpaperPreviewFrame(image: image)
            .task(id: item.id) { image = await CatalogLibrary.thumbnail(item) }
    }
}

// Preview-only magnification: the exported wallpaper and crop remain unchanged.
struct ZoomableWallpaperPreview: View {
    let image: UIImage?
    let resetID: UUID?
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    private var visibleScale: CGFloat { min(5, max(1, scale * magnification)) }
    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        let ratio = image.size.width / max(image.size.height, 1)
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .blur(radius: 18).overlay(.black.opacity(0.1))
                            Image(uiImage: image).resizable()
                                .frame(width: geometry.size.width, height: geometry.size.width / ratio)
                                .scaleEffect(visibleScale)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    } else { ProgressView().frame(width: geometry.size.width, height: geometry.size.height) }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if image != nil {
                    Label("捏合缩放", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.18), in: Capsule())
                        .padding(10).allowsHitTesting(false)
                }
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
            .simultaneousGesture(MagnificationGesture()
                .updating($magnification) { value, state, _ in state = value }
                .onEnded { value in scale = min(5, max(1, scale * value)) })
            .onChange(of: resetID) { _, _ in scale = 1 }
    }
}
