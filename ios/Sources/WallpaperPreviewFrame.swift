import SwiftUI
import UIKit

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

// The parent scroll view accepts one finger; the preview owns two-finger pinch.
struct ZoomableWallpaperPreview: View {
    let image: UIImage?
    let resetID: UUID?
    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { NativeWallpaperZoom(image: image, resetID: resetID) }
            .overlay(alignment: .bottomTrailing) {
                if image != nil {
                    Label("捏合缩放", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.18), in: Capsule())
                        .padding(10).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct NativeWallpaperZoom: UIViewRepresentable {
    let image: UIImage?
    let resetID: UUID?
    func makeUIView(context: Context) -> WallpaperZoomView { WallpaperZoomView() }
    func updateUIView(_ view: WallpaperZoomView, context: Context) { view.configure(image: image, id: resetID) }
    static func dismantleUIView(_ view: WallpaperZoomView, coordinator: ()) { view.restoreScrolling() }
}

private final class WallpaperZoomView: UIView {
    private let picture = UIImageView()
    private let backdrop = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private var identity: UUID?
    private var scale: CGFloat = 1
    private var initialScale: CGFloat = 1
    private weak var parentScroll: UIScrollView?
    private var originalMaximumTouches: Int?
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .tertiarySystemFill
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        addSubview(blur)
        picture.contentMode = .scaleToFill
        addSubview(picture)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { restoreScrolling(); return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                if parentScroll !== scroll {
                    restoreScrolling()
                    parentScroll = scroll
                    originalMaximumTouches = scroll.panGestureRecognizer.maximumNumberOfTouches
                    scroll.panGestureRecognizer.maximumNumberOfTouches = 1
                }
                break
            }
            ancestor = view.superview
        }
    }
    func restoreScrolling() {
        if let originalMaximumTouches, parentScroll?.panGestureRecognizer.maximumNumberOfTouches == 1 {
            parentScroll?.panGestureRecognizer.maximumNumberOfTouches = originalMaximumTouches
        }
        parentScroll = nil
        originalMaximumTouches = nil
    }
    func configure(image: UIImage?, id: UUID?) {
        if identity != id { scale = 1; identity = id }
        if picture.image !== image { picture.image = image; backdrop.image = image; setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        blur.frame = bounds
        guard let image = picture.image, image.size.width > 0 else { return }
        let width = bounds.width * scale
        let height = width * image.size.height / image.size.width
        picture.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard picture.image != nil else { return }
        if gesture.state == .began { initialScale = scale }
        scale = min(5, max(1, initialScale * gesture.scale))
        setNeedsLayout()
    }
}
