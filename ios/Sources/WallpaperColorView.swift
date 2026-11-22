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
    @State private var showOverallMore = false
    @State private var savedOverall: WallpaperColorAdjustment?
    @State private var showRegionMore = false
    @State private var selectedSection: ColorSection = .region
    var resetToken: Int = 0

    private enum ColorSection: String, CaseIterable {
        case region = "区域调节"
        case overall = "整体调节"
    }

    init(photo: MakerPhoto, embedded: Bool = false, resetToken: Int = 0, save: @escaping (WallpaperColorAdjustment) -> Void) {
        self.resetToken = resetToken
        self.embedded = embedded
        self.photo = photo
        self.save = save
        var initialColor = photo.adjustment.color ?? .init()
        initialColor.leftEdge?.advanced?.local = true
        _adjustment = State(initialValue: initialColor)
        _savedEdge = State(initialValue: photo.adjustment.color?.leftEdge ?? .init())
        _savedMask = State(initialValue: photo.adjustment.color?.mask ?? .init())
        var initialAdvanced = photo.adjustment.color?.leftEdge?.advanced ?? .init()
        initialAdvanced.local = true
        _savedAdvanced = State(initialValue: initialAdvanced)
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
                        ToolbarItemGroup(placement: .confirmationAction) {
                            Button("还原") { resetAll() }.disabled(original == nil)
                            Button("确定") { save(adjustment); dismiss() }.disabled(original == nil)
                        }
                    }
                }
            }
        }
        .onChange(of: resetToken) { _, _ in resetAll() }
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
            VStack(alignment: .leading, spacing: 14) {
                Picker("调节范围", selection: $selectedSection) {
                    ForEach(ColorSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("color.sectionPicker")

                if selectedSection == .region {
                Toggle("区域调节", isOn: Binding(
                    get: { adjustment.leftEdge != nil },
                    set: { enabled in
                        if let edge = adjustment.leftEdge { savedEdge = edge }
                        if enabled {
                            var edge = savedEdge
                            edge.advanced?.local = true
                            adjustment.leftEdge = edge
                        } else {
                            adjustment.leftEdge = nil
                        }
                        showOriginal = false
                    }
                ))
                .font(.headline)
                Text("仅针对图片左侧区域调节，向右自然渐变，不影响其余区域。")
                    .font(.caption).foregroundStyle(.secondary)
                if adjustment.leftEdge != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        slider("亮度", value: edgeValue(\.brightness), range: -0.50...1, neutral: 0, format: "%+.0f%%")
                        slider("曝光", value: regionExposure, range: -1...0.85, neutral: 0,
                               step: 0.05, scale: 1, format: "%+.2f EV")
                        slider("饱和度", value: edgeValue(\.saturation), range: -0.50...1, neutral: 0, format: "%+.0f%%")
                        slider("渐变曲线", value: edgeValue(\.curve), range: 0.75...3, neutral: 0,
                               step: 0.05, scale: 1, format: "%.2f")
                        slider("渐变宽度", value: edgeValue(\.width), range: 0...0.50, neutral: 0, format: "%.0f%%")
                        DisclosureGroup("更多调节", isExpanded: $showRegionMore) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("色阶、RGB 通道及曲线只作用于左侧融合区域。")
                                    .font(.caption).foregroundStyle(.secondary)
                                if adjustment.leftEdge?.advanced != nil {
                                    WallpaperAdvancedControls(
                                        grade: Binding(
                                            get: {
                                                var grade = adjustment.leftEdge?.advanced ?? savedAdvanced
                                                grade.local = true
                                                return grade
                                            },
                                            set: { value in
                                                var grade = value
                                                grade.local = true
                                                adjustment.leftEdge?.advanced = grade
                                                savedAdvanced = grade
                                                showOriginal = false
                                            }
                                        ),
                                        original: original,
                                        seamWidth: adjustment.leftEdge?.width ?? 0
                                    )
                                }
                            }.padding(.top, 8)
                        }
                        .onChange(of: showRegionMore) { _, expanded in
                            guard expanded, adjustment.leftEdge != nil else { return }
                            if adjustment.leftEdge?.advanced == nil {
                                var grade = savedAdvanced
                                grade.local = true
                                adjustment.leftEdge?.advanced = grade
                                showOriginal = false
                            }
                        }
                    }
                }

                } else {
                Toggle("整体调节", isOn: Binding(
                    get: { adjustment.mask != nil },
                    set: { enabled in
                        if enabled {
                            adjustment.mask = savedMask
                            if let previous = savedOverall {
                                adjustment.brightness = previous.brightness
                                adjustment.contrast = previous.contrast
                                adjustment.saturation = previous.saturation
                                adjustment.exposure = previous.exposure
                                adjustment.highlights = previous.highlights
                                adjustment.shadows = previous.shadows
                                adjustment.temperature = previous.temperature
                                adjustment.gamma = previous.gamma
                            }
                        } else {
                            if let mask = adjustment.mask { savedMask = mask }
                            savedOverall = adjustment
                            adjustment.mask = nil
                            adjustment.brightness = 0
                            adjustment.contrast = 1
                            adjustment.saturation = 1
                            adjustment.exposure = nil
                            adjustment.highlights = nil
                            adjustment.shadows = nil
                            adjustment.temperature = nil
                            adjustment.gamma = nil
                        }
                        showOriginal = false
                    }
                ))
                .font(.headline)
                Text("作用于整张图片，可与区域调节叠加。")
                    .font(.caption).foregroundStyle(.secondary)
                if let mask = adjustment.mask {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("CarPlay 蒙版补偿").font(.subheadline.weight(.semibold))
                        slider("蒙版透明度", value: Binding(
                            get: { adjustment.mask?.opacity ?? mask.opacity },
                            set: { adjustment.mask?.opacity = $0; showOriginal = false }
                        ), range: 0...0.50, neutral: 0, format: "%.0f%%")
                        slider("补偿强度", value: Binding(
                            get: { adjustment.mask?.strength ?? 1 },
                            set: { adjustment.mask?.strength = $0; showOriginal = false }
                        ), range: 0...1.50, neutral: 0, format: "%.0f%%")
                        Toggle("水平渐变", isOn: Binding(
                            get: { adjustment.mask?.horizontalGradient ?? false },
                            set: { adjustment.mask?.horizontalGradient = $0; showOriginal = false }
                        ))
                        if mask.horizontalGradient == true {
                            Text("默认从左到右：24% → 20% → 15%。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("高光保护", isOn: Binding(
                            get: { adjustment.mask?.protectHighlights ?? true },
                            set: { adjustment.mask?.protectHighlights = $0; showOriginal = false }
                        ))
                        DisclosureGroup("更多调节", isExpanded: $showOverallMore) {
                            VStack(alignment: .leading, spacing: 14) {
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
                            }.padding(.top, 8)
                        }
                    }
                }

                }

                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .disabled(original == nil)
            .padding(20)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
    }

    private func resetAll() {
        adjustment = .init()
        savedEdge = .init()
        savedMask = .init()
        savedAdvanced = .init()
        savedOverall = nil
        showOverallMore = false
        showRegionMore = false
        showOriginal = false
    }

    private struct PreviewKey: Equatable {
        let ready: Bool
        let color: WallpaperColorAdjustment
    }

    // 区域曝光复用现有左侧高级增益通道，避免影响全图曝光。
    // 三通道等比例缩放；高级 RGB 微调的相对比例会保留。
    private var regionExposure: Binding<Double> {
        Binding(
            get: {
                guard let grade = adjustment.leftEdge?.advanced else { return 0 }
                let geometricMean = pow(max(0.001, grade.gainRed * grade.gainGreen * grade.gainBlue), 1.0 / 3.0)
                return log2(geometricMean)
            },
            set: { ev in
                guard adjustment.leftEdge != nil else { return }
                var grade = adjustment.leftEdge?.advanced ?? savedAdvanced
                grade.local = true
                let oldGain = pow(max(0.001, grade.gainRed * grade.gainGreen * grade.gainBlue), 1.0 / 3.0)
                let factor = pow(2.0, ev) / oldGain
                grade.gainRed *= factor
                grade.gainGreen *= factor
                grade.gainBlue *= factor
                adjustment.leftEdge?.advanced = grade
                savedAdvanced = grade
                showOriginal = false
            }
        )
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
