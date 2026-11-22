// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperColorView: View {
    @Environment(\.dismiss) private var dismiss
    let embedded: Bool
    let photo: MakerPhoto
    let save: (WallpaperColorAdjustment) -> Void
    @State private var adjustment: WallpaperColorAdjustment
    @State private var original: UIImage?
    @State private var corrected: UIImage?
    @State private var showOriginal = false
    @State private var problem: String?
    @State private var savedEdge: WallpaperLeftEdgeBlend
    @State private var savedMask: WallpaperMaskCompensation
    @State private var savedAdvanced: WallpaperAdvancedGrade
    @State private var usedWidePreset = false
    private static let widePreset = WallpaperLeftEdgeBlend(width: 0.20, brightness: 0.90, saturation: 0.08, curve: 1)

    init(photo: MakerPhoto, embedded: Bool = false, save: @escaping (WallpaperColorAdjustment) -> Void) {
        self.embedded = embedded
        self.photo = photo
        self.save = save
        _adjustment = State(initialValue: photo.adjustment.color ?? .init())
        _savedEdge = State(initialValue: photo.adjustment.color?.leftEdge ?? .init())
        _savedMask = State(initialValue: photo.adjustment.color?.mask ?? .init())
        _savedAdvanced = State(initialValue: photo.adjustment.color?.leftEdge?.advanced ?? .init())
        _usedWidePreset = State(initialValue: Self.matchesWide(photo.adjustment.color?.leftEdge))
    }

    var body: some View {
        Group {
            if embedded {
                HStack(alignment: .top, spacing: 0) {
                    previewPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    controlsPanel.frame(width: 310)
                }
                .onChange(of: adjustment) { _, value in save(value) }
            } else {
                NavigationStack {
                    VStack(spacing: 0) {
                        previewPanel
                        Divider()
                        controlsPanel
                    }
                    .navigationTitle("调色")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("确定") { save(adjustment); dismiss() }.disabled(original == nil)
                        }
                    }
                }
            }
        }
        .tint(CanvasTheme.accent)
        .task { await loadOriginal() }
        .task(id: PreviewKey(ready: original != nil, color: adjustment)) { await updatePreview() }
    }

    private var previewPanel: some View {
        VStack(spacing: 14) {
            if embedded {
                Text("请先裁剪，再调色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if let image = showOriginal ? original : (corrected ?? original) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: embedded ? .infinity : 210)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if problem == nil {
                    ProgressView("正在准备预览…")
                }
            }
            Picker("预览对比", selection: $showOriginal) {
                Text("原图").tag(true)
                Text("调色后").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .disabled(original == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(uiColor: .systemGray6))
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button("大联屏融合补偿") {
                    var preset = Self.widePreset
                    preset.advanced = adjustment.leftEdge?.advanced
                    adjustment.leftEdge = preset
                    usedWidePreset = true
                    showOriginal = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(original == nil)
                if usedWidePreset {
                    Text(adjustment.leftEdge == nil ? "大联屏融合补偿已暂停" :
                         Self.matchesWide(adjustment.leftEdge) ? "大联屏预设已应用" : "大联屏预设已手动修改")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if adjustment.leftEdge != nil && adjustment.mask != nil {
                    Label("已叠加两项补偿，左侧亮度会同时受两项影响。", systemImage: "square.stack")
                        .font(.caption).foregroundStyle(.secondary)
                }
                leftEdgeControls
                Toggle("CarPlay 蒙版补偿", isOn: Binding(
                    get: { adjustment.mask != nil },
                    set: { enabled in
                        if let mask = adjustment.mask { savedMask = mask }
                        adjustment.mask = enabled ? savedMask : nil
                        showOriginal = false
                    }
                )).disabled(original == nil)
                if let mask = adjustment.mask {
                    Text("黑色蒙版 #000000").font(.subheadline).foregroundStyle(.secondary)
                    slider("蒙版透明度", value: Binding(
                        get: { adjustment.mask?.opacity ?? mask.opacity },
                        set: { adjustment.mask?.opacity = $0 }
                    ), range: 0...0.50, neutral: 0, format: "%.0f%%")
                    slider("补偿强度", value: Binding(
                        get: { adjustment.mask?.strength ?? 1 },
                        set: { adjustment.mask?.strength = $0 }
                    ), range: 0...1.50, neutral: 0, format: "%.0f%%")
                    Toggle("水平渐变", isOn: Binding(
                        get: { adjustment.mask?.horizontalGradient ?? false },
                        set: { adjustment.mask?.horizontalGradient = $0 }
                    ))
                    if mask.horizontalGradient == true {
                        Text("默认从左到右：24% → 20% → 15%。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("高光保护", isOn: Binding(
                        get: { adjustment.mask?.protectHighlights ?? true },
                        set: { adjustment.mask?.protectHighlights = $0 }
                    ))
                    Text("20% 蒙版在 100% 强度下对应 1.25 倍 RGB 增益，高光保护会柔和压缩亮部。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("更多调节") {
                    VStack(alignment: .leading, spacing: 18) {
                        slider("亮度", value: $adjustment.brightness, range: -0.15...0.15, neutral: 0)
                        slider("曝光", value: manual(\.exposure, defaultValue: 0), range: -1...1, neutral: 0,
                               scale: 1, format: "%+.2f EV")
                        slider("对比度", value: $adjustment.contrast, range: 0.75...1.35, neutral: 1)
                        slider("饱和度", value: $adjustment.saturation, range: 0.5...1.5, neutral: 1)
                        slider("高光", value: manual(\.highlights, defaultValue: 0), range: -1...0, neutral: 0)
                        slider("阴影", value: manual(\.shadows, defaultValue: 0), range: -1...1, neutral: 0)
                        slider("色温", value: manual(\.temperature, defaultValue: 0), range: -2000...2000, neutral: 0,
                               step: 50, scale: 1, format: "%+.0f K")
                        slider("Gamma", value: manual(\.gamma, defaultValue: 1), range: 0.65...1.5, neutral: 0,
                               scale: 1, format: "%.2f")
                    }
                    .padding(.top, 8)
                }
                Button("重置全部调色") {
                    adjustment = .init()
                    savedEdge = .init()
                    savedMask = .init()
                    savedAdvanced = .init()
                    usedWidePreset = false
                    showOriginal = false
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
    }

    private struct PreviewKey: Equatable {
        let ready: Bool
        let color: WallpaperColorAdjustment
    }

    private var leftEdgeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("CarPlay 左侧边缘融合", isOn: Binding(
                get: { adjustment.leftEdge != nil },
                set: { enabled in
                    if let edge = adjustment.leftEdge { savedEdge = edge }
                    adjustment.leftEdge = enabled ? savedEdge : nil
                    showOriginal = false
                }
            ))
            if adjustment.leftEdge != nil {
                slider("渐变宽度", value: edgeValue(\.width), range: 0...0.50, neutral: 0, format: "%.0f%%")
                slider("左边缘亮度增益", value: edgeValue(\.brightness), range: -0.50...1, neutral: 0, format: "%+.0f%%")
                slider("左边缘饱和度", value: edgeValue(\.saturation), range: -0.50...1, neutral: 0, format: "%+.0f%%")
                slider("渐变曲线", value: edgeValue(\.curve), range: 0.75...3, neutral: 0,
                       step: 0.05, scale: 1, format: "%.2f")
                Text("1.00 为标准 Smoothstep。数值越大，补偿越集中在左边缘。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("高级调色", isOn: Binding(
                    get: { adjustment.leftEdge?.advanced != nil },
                    set: { enabled in
                        if let grade = adjustment.leftEdge?.advanced { savedAdvanced = grade }
                        adjustment.leftEdge?.advanced = enabled ? savedAdvanced : nil
                        showOriginal = false
                    }
                ))
                if adjustment.leftEdge?.advanced == nil {
                    Text("打开后可单独调整接缝附近的色阶、RGB 和曲线。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if adjustment.leftEdge?.advanced != nil {
                    WallpaperAdvancedControls(
                        grade: Binding(
                            get: { adjustment.leftEdge?.advanced ?? savedAdvanced },
                            set: {
                                adjustment.leftEdge?.advanced = $0
                                savedAdvanced = $0
                                showOriginal = false
                            }
                        ),
                        original: original,
                        seamWidth: adjustment.leftEdge?.width ?? 0
                    )
                }
                Button("恢复普通融合默认值") {
                    var edge = WallpaperLeftEdgeBlend()
                    edge.advanced = adjustment.leftEdge?.advanced
                    adjustment.leftEdge = edge
                    savedEdge = edge
                    usedWidePreset = false
                    showOriginal = false
                }
            }
        }.disabled(original == nil)
    }

    private static func matchesWide(_ edge: WallpaperLeftEdgeBlend?) -> Bool {
        guard let edge else { return false }
        return edge.width == widePreset.width && edge.brightness == widePreset.brightness
            && edge.saturation == widePreset.saturation && edge.curve == widePreset.curve
    }

    private func edgeValue(_ field: WritableKeyPath<WallpaperLeftEdgeBlend, Double>) -> Binding<Double> {
        Binding(get: { (adjustment.leftEdge ?? .init())[keyPath: field] }, set: {
            adjustment.leftEdge?[keyPath: field] = $0
            showOriginal = false
        })
    }

    private func manual(_ field: WritableKeyPath<WallpaperColorAdjustment, Double?>, defaultValue: Double) -> Binding<Double> {
        Binding(get: { adjustment[keyPath: field] ?? defaultValue }, set: {
            adjustment[keyPath: field] = $0 == defaultValue ? nil : $0
        })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double,
                        step: Double = 0.01, scale: Double = 100, format: String = "%+.0f") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, (value.wrappedValue - neutral) * scale))
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }.disabled(original == nil)
    }

    private func loadOriginal() async {
        let photo = photo
        do {
            let image = try await Task.detached {
                try autoreleasepool {
                    var adjustment = photo.adjustment
                    adjustment.color = nil
                    let full = try WallpaperRenderer.render(url: photo.url, preset: .original, size: .zero, adjustment: adjustment)
                    let scale = min(1, 1100 / max(full.size.width, full.size.height))
                    let size = CGSize(width: max(1, full.size.width * scale), height: max(1, full.size.height * scale))
                    return UIGraphicsImageRenderer(size: size, format: WallpaperRenderer.format()).image { _ in
                        full.draw(in: CGRect(origin: .zero, size: size))
                    }
                }
            }.value
            if !Task.isCancelled { original = image }
        } catch {
            if !Task.isCancelled { problem = "无法读取校色预览。" }
        }
    }

    private func updatePreview() async {
        guard let original else { return }
        let color = adjustment
        do {
            try await Task.sleep(for: .milliseconds(60))
            let image = try await Task.detached { try WallpaperRenderer.colorCorrect(original, adjustment: color) }.value
            try Task.checkCancellation()
            corrected = image
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { problem = "无法生成校色预览。" }
        }
    }
}
