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
    @State private var resetViewID = 0
    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { NativeWallpaperZoom(image: image, resetID: resetID, resetViewID: resetViewID) }
            .overlay(alignment: .bottomTrailing) {
                if image != nil {
                    HStack(spacing: 6) {
                        Button { resetViewID += 1 } label: {
                            Label("复位", systemImage: "arrow.counterclockwise")
                                .padding(.horizontal, 8).frame(minHeight: 32)
                                .background(.black.opacity(0.18), in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("复位预览缩放和位置")
                        Label("捏合缩放", systemImage: "arrow.up.left.and.arrow.down.right")
                            .padding(.horizontal, 8).frame(minHeight: 32)
                            .background(.black.opacity(0.18), in: Capsule())
                            .allowsHitTesting(false)
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct NativeWallpaperZoom: UIViewRepresentable {
    let image: UIImage?
    let resetID: UUID?
    let resetViewID: Int
    func makeUIView(context: Context) -> WallpaperZoomView { WallpaperZoomView() }
    func updateUIView(_ view: WallpaperZoomView, context: Context) { view.configure(image: image, id: resetID, resetViewID: resetViewID) }
    static func dismantleUIView(_ view: WallpaperZoomView, coordinator: ()) { view.restoreScrolling() }
}

private final class WallpaperZoomView: UIView, UIGestureRecognizerDelegate {
    private let picture = UIImageView()
    private let backdrop = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private var identity: UUID?
    private var lastResetViewID = 0
    private var scale: CGFloat = 1
    private var initialScale: CGFloat = 1
    private var offset = CGPoint.zero
    private var panStart = CGPoint.zero
    private lazy var imagePan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
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
        imagePan.maximumNumberOfTouches = 1
        imagePan.delegate = self
        addGestureRecognizer(imagePan)
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
                    scroll.panGestureRecognizer.require(toFail: imagePan)
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
    func configure(image: UIImage?, id: UUID?, resetViewID: Int) {
        if identity != id || lastResetViewID != resetViewID {
            scale = 1
            offset = .zero
            identity = id
            lastResetViewID = resetViewID
            setNeedsLayout()
        }
        if picture.image !== image { picture.image = image; backdrop.image = image; setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        blur.frame = bounds
        guard let image = picture.image, image.size.width > 0 else { return }
        let width = bounds.width * scale
        let height = width * image.size.height / image.size.width
        let maxX = max(0, (width - bounds.width) / 2)
        let maxY = max(0, (height - bounds.height) / 2)
        offset.x = min(maxX, max(-maxX, offset.x))
        offset.y = min(maxY, max(-maxY, offset.y))
        if scale <= 1.001 { offset = .zero }
        picture.frame = CGRect(x: (bounds.width - width) / 2 + offset.x, y: (bounds.height - height) / 2 + offset.y, width: width, height: height)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== imagePan || (scale > 1.001 && picture.image != nil)
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panStart = offset }
        let movement = gesture.translation(in: self)
        offset = CGPoint(x: panStart.x + movement.x, y: panStart.y + movement.y)
        setNeedsLayout()
        layoutIfNeeded()
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard picture.image != nil else { return }
        if gesture.state == .began { initialScale = scale }
        scale = min(5, max(1, initialScale * gesture.scale))
        setNeedsLayout()
    }
}
