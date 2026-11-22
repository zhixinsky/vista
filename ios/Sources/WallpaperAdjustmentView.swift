// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperAdjustmentView: View {
    private enum Ratio: String, CaseIterable {
        case free = "自由裁剪", standard = "标准 4:3", wide = "宽屏 16:9", ultrawide = "超宽屏", buick = "别克大联屏"

        var allowsCornerResize: Bool { self != .free && self != .buick }

        var units: (width: Int, height: Int)? {
            switch self {
            case .free: return nil
            case .wide: return (16, 9)
            case .ultrawide: return (87, 23)
            case .standard: return (4, 3)
            case .buick: return (3083, 815)
            }
        }
    }

    private enum Edge: String, CaseIterable {
        case left = "左边", right = "右边", top = "上边", bottom = "下边"
        var vertical: Bool { self == .left || self == .right }
        var coordinate: WritableKeyPath<WallpaperPixelCrop, Int> {
            switch self {
            case .left: return \.left
            case .right: return \.right
            case .top: return \.top
            case .bottom: return \.bottom
            }
        }
    }

    private enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var left: Bool { self == .topLeft || self == .bottomLeft }
        var top: Bool { self == .topLeft || self == .topRight }
    }

    @Environment(\.dismiss) private var dismiss
    let photo: MakerPhoto
    let save: (WallpaperPixelCrop, WallpaperColorAdjustment) -> Void
    @State private var colorEditing: Bool
    @State private var color: WallpaperColorAdjustment
    @State private var preview: UIImage?
    @State private var pixels = CGSize.zero
    @State private var crop: WallpaperPixelCrop?
    @State private var selected: Edge = .left
    @State private var dragStart: Int?
    @State private var failed = false
    @State private var zoom = 1.0
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var panStart: CGPoint?
    @State private var cropLocked = false
    @State private var ratio: Ratio = .free
    @State private var showsRatios = false
    @State private var showsBuickSizeWarning = false
    @State private var frameDragStart: WallpaperPixelCrop?
    @State private var cornerDragStart: WallpaperPixelCrop?

    init(photo: MakerPhoto, startWithColor: Bool = false,
         save: @escaping (WallpaperPixelCrop, WallpaperColorAdjustment) -> Void) {
        self.photo = photo
        self.save = save
        _colorEditing = State(initialValue: startWithColor)
        _color = State(initialValue: photo.adjustment.color ?? .init())
    }

    private var croppedPhoto: MakerPhoto {
        var result = photo
        result.adjustment.pixelCrop = crop
        result.adjustment.color = color
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if colorEditing, crop != nil {
                    WallpaperColorView(photo: croppedPhoto, embedded: true) { color = $0 }
                } else {
                    VStack(spacing: 4) {
                        GeometryReader { geometry in
                            if let preview, let crop {
                                viewport(preview, crop: crop, viewportSize: geometry.size)
                            } else if failed {
                                Text("无法读取原图").frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        if crop != nil {
                            HStack {
                                Button {
                                    cropLocked.toggle()
                                    panStart = nil
                                    dragStart = nil
                                    frameDragStart = nil
                                    cornerDragStart = nil
                                } label: {
                                    Label(cropLocked ? "已锁定 · 解锁" : "锁定裁剪",
                                          systemImage: cropLocked ? "lock.fill" : "lock.open")
                                }
                                .buttonStyle(.bordered)
                                .tint(cropLocked ? .orange : CanvasTheme.accent)
                                .fixedSize()
                                Slider(value: $zoom, in: 1...6).accessibilityLabel("预览缩放")
                                Button("全图") { zoom = 1 }.disabled(zoom == 1)
                            }.font(.subheadline)
                            HStack(spacing: 6) {
                                Picker("微调边线", selection: Binding(get: { selected }, set: { edge in
                                    selected = edge
                                    if zoom > 1 { focusSelectedEdge() }
                                })) {
                                    ForEach(Edge.allCases, id: \.self) { edge in Text(edge.rawValue).tag(edge) }
                                }.pickerStyle(.segmented)
                                triangle(-1)
                                triangle(1)
                                if zoom > 1 {
                                    Button { withAnimation(.easeInOut(duration: 0.2)) { focusSelectedEdge() } } label: {
                                        Label("定位边线", systemImage: "scope").labelStyle(.iconOnly)
                                            .frame(width: 44, height: 44)
                                    }.buttonStyle(.borderless).accessibilityLabel("定位选中边线")
                                }
                                Label("微调", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 34)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .disabled(ratio != .free)
                            .accessibilityIdentifier("crop.fineControls")
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(alignment: .topTrailing) {
                        if showsRatios { ratioOverlay }
                    }
                }
            }
            .navigationTitle("裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if let crop {
                            Text("\(Int(crop.rect.width)) × \(Int(crop.rect.height)) 像素")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .accessibilityLabel("裁剪尺寸 \(Int(crop.rect.width)) 乘 \(Int(crop.rect.height)) 像素")
                        }
                        Picker("编辑工具", selection: $colorEditing) {
                            Text("裁剪").tag(false)
                            Text("调色").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .disabled(crop == nil)
                        .onChange(of: colorEditing) { _, _ in showsRatios = false }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .offset(x: -16)
                }
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if !colorEditing {
                        Button { showsRatios.toggle() } label: {
                            Label(ratio == .free ? "比例" : ratio.rawValue, systemImage: "aspectratio")
                        }.disabled(crop == nil || cropLocked).accessibilityIdentifier("crop.ratio")
                        Button("还原") { showsRatios = false; ratio = .free; crop = .full(pixels); zoom = 1 }.disabled(crop == nil || cropLocked)
                    }
                    Button("确定") {
                        guard let crop else { return }
                        save(crop, color)
                        dismiss()
                    }.disabled(crop == nil)
                }
            }
            .onChange(of: zoom) { previous, current in
                if current == 1 {
                    center = CGPoint(x: 0.5, y: 0.5)
                } else if previous == 1 {
                    focusSelectedEdge()
                }
            }
            .task {
                do {
                    let url = photo.url
                    let (image, size) = try await Task.detached {
                        (try WallpaperRenderer.load(url, maximum: 4096), try WallpaperRenderer.pixelSize(url))
                    }.value
                    try Task.checkCancellation()
                    pixels = size
                    crop = photo.adjustment.pixelCrop.flatMap { $0.fits(size) ? $0 : nil } ?? .full(size)
                    preview = image
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                }
            }
        }
        .accessibilityHidden(showsBuickSizeWarning)
        .overlay {
            if showsBuickSizeWarning {
                ZStack {
                    Color.black.opacity(0.32).ignoresSafeArea()
                        .onTapGesture { showsBuickSizeWarning = false }
                        .accessibilityHidden(true)
                    VStack(spacing: 12) {
                        Text("原图尺寸不符").font(.headline)
                        Text("别克大联屏仅适用于 6008 × 934 像素的原图。当前原图为 \(Int(pixels.width)) × \(Int(pixels.height)) 像素，请使用自由裁剪。")
                            .font(.subheadline).multilineTextAlignment(.center)
                        Button("知道了") { showsBuickSizeWarning = false }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .frame(maxWidth: 360)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(16)
                    .accessibilityAction(.escape) { showsBuickSizeWarning = false }
                }
            }
        }
        .tint(CanvasTheme.accent)
    }

    private var ratioOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { showsRatios = false }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(Ratio.allCases, id: \.self) { option in
                    Button {
                        selectRatio(option)
                        showsRatios = false
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            Spacer()
                            if ratio == option { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(ratio == option ? .isSelected : [])
                    .disabled(option != .buick && !canSelect(option))
                    .accessibilityHint(option == .buick ? "仅适用于 6008×934 像素原图，其他尺寸请用自由裁剪" : option == .ultrawide ? "约 3.783 比 1，可拖动四角缩放" : "")
                    if option != Ratio.allCases.last { Divider() }
                }
            }
            .frame(width: 200)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8)
            .padding(8)
            .accessibilityAction(.escape) { showsRatios = false }
        }
    }

    private func canSelect(_ option: Ratio) -> Bool {
        if option == .buick { return pixels == CGSize(width: 6008, height: 934) }
        guard let units = option.units else { return true }
        return Int(pixels.width) >= units.width && Int(pixels.height) >= units.height
    }

    private func selectRatio(_ option: Ratio) {
        guard !cropLocked, let current = crop else { return }
        guard canSelect(option) else {
            if option == .buick { showsBuickSizeWarning = true }
            return
        }
        guard let units = option.units else { ratio = .free; return }
        let scale = option == .buick ? 1 : min(Int(pixels.width) / units.width, Int(pixels.height) / units.height)
        guard scale > 0 else { return }
        let width = units.width * scale
        let height = units.height * scale
        let left = option == .buick ? Int(pixels.width) - width
            : min(Int(pixels.width) - width, max(0, Int((current.rect.midX - CGFloat(width) / 2).rounded())))
        let top = option == .buick ? Int(pixels.height) - height - 119
            : min(Int(pixels.height) - height, max(0, Int((current.rect.midY - CGFloat(height) / 2).rounded())))
        crop = WallpaperPixelCrop(left: left, top: top, right: left + width, bottom: top + height)
        ratio = option
        zoom = 1
    }

    private func translate(_ original: WallpaperPixelCrop, x: Int, y: Int) {
        guard !cropLocked else { return }
        let dx = min(Int(pixels.width) - original.right, max(-original.left, x))
        let dy = min(Int(pixels.height) - original.bottom, max(-original.top, y))
        crop = WallpaperPixelCrop(left: original.left + dx, top: original.top + dy,
                                  right: original.right + dx, bottom: original.bottom + dy)
    }

    private func viewport(_ image: UIImage, crop: WallpaperPixelCrop, viewportSize: CGSize) -> some View {
        let fit = CropGeometry.fit(source: pixels, target: viewportSize).size
        let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        let focus = zoom > 1 ? clampedCenter(center) : CGPoint(x: 0.5, y: 0.5)
        return Color.clear
            .frame(width: viewportSize.width, height: viewportSize.height)
            .overlay(alignment: .topLeading) {
                if size.width > 0, size.height > 0 {
                    editor(image, crop: crop, size: size)
                        .frame(width: size.width, height: size.height)
                        .offset(x: viewportSize.width / 2 - focus.x * size.width,
                                y: viewportSize.height / 2 - focus.y * size.height)
                        .allowsHitTesting(!cropLocked)
                }
            }
            .overlay {
                if cropLocked && zoom > 1 {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            guard size.width > 0, size.height > 0 else { return }
                            if panStart == nil { panStart = focus }
                            guard let start = panStart else { return }
                            center = clampedCenter(CGPoint(x: start.x - value.translation.width / size.width,
                                                           y: start.y - value.translation.height / size.height))
                        }.onEnded { _ in panStart = nil })
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
    private func clampedCenter(_ point: CGPoint) -> CGPoint {
        // Let even the outermost image edges reach the center of the viewport.
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    private func focusSelectedEdge() {
        guard let crop else { return }
        let axis = CGFloat(crop[keyPath: selected.coordinate])
        center = selected.vertical
            ? CGPoint(x: axis / pixels.width, y: crop.rect.midY / pixels.height)
            : CGPoint(x: crop.rect.midX / pixels.width, y: axis / pixels.height)
    }

    private func editor(_ image: UIImage, crop: WallpaperPixelCrop, size: CGSize) -> some View {
        let xScale = size.width / pixels.width
        let yScale = size.height / pixels.height
        let rect = CGRect(x: CGFloat(crop.left) * xScale, y: CGFloat(crop.top) * yScale,
                          width: crop.rect.width * xScale, height: crop.rect.height * yScale)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }.fill(.black.opacity(0.30), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            if rect.width > 0, rect.height > 0 {
                Color.clear
                    .overlay {
                        if ratio != .free {
                            Rectangle()
                                .strokeBorder(.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                                .shadow(color: .black.opacity(0.6), radius: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("crop")).onChanged { value in
                        guard !cropLocked else { return }
                        if frameDragStart == nil { frameDragStart = self.crop }
                        guard let start = frameDragStart else { return }
                        translate(start, x: Int((value.translation.width / xScale).rounded()),
                                  y: Int((value.translation.height / yScale).rounded()))
                    }.onEnded { _ in frameDragStart = nil })
            }
            if ratio == .free {
                ForEach(Edge.allCases, id: \.self) { edge in
                    let scale = edge.vertical ? xScale : yScale
                    let limit = edge.vertical ? size.width : size.height
                    let position = CGFloat(crop[keyPath: edge.coordinate]) * scale
                    let hitInset = min(12, limit / 2)
                    let hitCenter = min(max(position, hitInset), limit - hitInset)
                    Path { path in
                        if edge.vertical {
                            path.move(to: CGPoint(x: position, y: 0))
                            path.addLine(to: CGPoint(x: position, y: size.height))
                        } else {
                            path.move(to: CGPoint(x: 0, y: position))
                            path.addLine(to: CGPoint(x: size.width, y: position))
                        }
                    }
                        .stroke(edge == selected ? Color.yellow : .white, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(width: edge.vertical ? 24 : size.width, height: edge.vertical ? size.height : 24)
                        .contentShape(Rectangle())
                        .position(x: edge.vertical ? hitCenter : size.width / 2, y: edge.vertical ? size.height / 2 : hitCenter)
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("crop")).onChanged { value in
                            guard scale > 0, !cropLocked else { return }
                            if dragStart == nil {
                                selected = edge
                                dragStart = self.crop?[keyPath: edge.coordinate]
                            }
                            guard selected == edge, let dragStart else { return }
                            let delta = edge.vertical ? value.translation.width : value.translation.height
                            move(edge, to: dragStart + Int((delta / scale).rounded()))
                        }.onEnded { _ in dragStart = nil })
                        .onTapGesture { selected = edge }
                        .accessibilityHidden(true)
                }
            }
            if !cropLocked, ratio.allowsCornerResize, let units = ratio.units {
                ForEach(Corner.allCases, id: \.self) { corner in
                    let x = corner.left ? rect.minX : rect.maxX
                    let y = corner.top ? rect.minY : rect.maxY
                    Circle().fill(.yellow)
                        .overlay { Circle().strokeBorder(.black.opacity(0.65), lineWidth: 1) }
                        .frame(width: 12, height: 12)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(x: x, y: y)
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("crop")).onChanged { value in
                            guard !cropLocked, xScale > 0, yScale > 0 else { return }
                            if cornerDragStart == nil { cornerDragStart = self.crop }
                            guard let start = cornerDragStart else { return }
                            resize(start, corner: corner, units: units,
                                   dx: value.translation.width / xScale, dy: value.translation.height / yScale)
                        }.onEnded { _ in cornerDragStart = nil })
                        .accessibilityHidden(true)
                }
            }
        }
        .coordinateSpace(name: "crop")
    }

    private func resize(_ start: WallpaperPixelCrop, corner: Corner, units: (width: Int, height: Int), dx: CGFloat, dy: CGFloat) {
        let anchorX = corner.left ? start.right : start.left
        let anchorY = corner.top ? start.bottom : start.top
        let availableWidth = corner.left ? anchorX : Int(pixels.width) - anchorX
        let availableHeight = corner.top ? anchorY : Int(pixels.height) - anchorY
        let largest = min(availableWidth / units.width, availableHeight / units.height)
        guard largest >= 1 else { return }
        let desiredWidth = start.rect.width + (corner.left ? -dx : dx)
        let desiredHeight = start.rect.height + (corner.top ? -dy : dy)
        let unitWidth = CGFloat(units.width)
        let unitHeight = CGFloat(units.height)
        let projected = (desiredWidth * unitWidth + desiredHeight * unitHeight) / (unitWidth * unitWidth + unitHeight * unitHeight)
        let count = Int(min(CGFloat(largest), max(1, projected)).rounded())
        let width = units.width * count
        let height = units.height * count
        crop = WallpaperPixelCrop(left: corner.left ? anchorX - width : anchorX,
                                  top: corner.top ? anchorY - height : anchorY,
                                  right: corner.left ? anchorX : anchorX + width,
                                  bottom: corner.top ? anchorY : anchorY + height)
    }

    private func triangle(_ delta: Int) -> some View {
        let direction = selected.vertical ? (delta < 0 ? "左" : "右") : (delta < 0 ? "上" : "下")
        return Button {
            guard let crop else { return }
            guard ratio == .free else { return }
            move(selected, to: crop[keyPath: selected.coordinate] + delta)
        } label: {
            Image(systemName: "triangle.fill")
                .rotationEffect(.degrees(selected.vertical ? Double(delta) * 90 : (delta < 0 ? 0 : 180)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(cropLocked)
        .accessibilityLabel("\(selected.rawValue)向\(direction)移动 1 像素")
    }

    private func move(_ edge: Edge, to value: Int) {
        guard !cropLocked, var crop else { return }
        let bounds: ClosedRange<Int>
        switch edge {
        case .left: bounds = 0...(crop.right - 1)
        case .right: bounds = (crop.left + 1)...Int(pixels.width)
        case .top: bounds = 0...(crop.bottom - 1)
        case .bottom: bounds = (crop.top + 1)...Int(pixels.height)
        }
        crop[keyPath: edge.coordinate] = min(bounds.upperBound, max(bounds.lowerBound, value))
        self.crop = crop
    }
}
