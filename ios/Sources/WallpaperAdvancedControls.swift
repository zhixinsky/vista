// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum SeamCurveChannel: String, CaseIterable, Identifiable {
    case master, red, green, blue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .master: return "RGB"
        case .red: return "红"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }
    var tint: Color {
        switch self {
        case .master: return .primary
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
    var keyPath: WritableKeyPath<WallpaperAdvancedGrade, [WallpaperCurvePoint]> {
        switch self {
        case .master: return \.master
        case .red: return \.red
        case .green: return \.green
        case .blue: return \.blue
        }
    }
}

struct WallpaperAdvancedControls: View {
    @Binding var grade: WallpaperAdvancedGrade
    var original: UIImage?
    var seamWidth: Double
    @State private var histogram = WallpaperHistogram.empty
    @State private var channel = SeamCurveChannel.master

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("接在基础调色和左侧亮度之后，沿同一条渐变混合。默认参数不会再乘一次亮度。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("仅作用于左侧融合区域", isOn: $grade.local)
            Toggle("接缝高光保护", isOn: $grade.protectHighlights)
            Text(grade.protectHighlights
                 ? "亮部超过约 78% 后按比例压回，避免浅色壁纸发白、偏色和亮部细节被裁掉。"
                 : "高光保护已关闭，超出范围的亮部会被直接裁切。")
                .font(.caption).foregroundStyle(.secondary)
            if grade.local && seamWidth <= 0 {
                Text("渐变宽度为 0，左侧区域不会发生变化。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !grade.local {
                Text("当前作用于整张图片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(grade.local ? "原图左侧直方图" : "原图直方图")
                .font(.subheadline)
            SeamHistogramView(histogram: histogram)
            Text("拖动色阶时直方图保持为原图，方便对照黑场、灰场和白场。")
                .font(.caption).foregroundStyle(.secondary)
            levelSlider("黑场", value: black, range: 0...0.40)
            levelSlider("灰场", value: gray, range: 0.05...0.95)
            levelSlider("白场", value: white, range: 0.60...1)
            Text("灰场是被映射到 50% 亮度的输入值。")
                .font(.caption).foregroundStyle(.secondary)
            Text("RGB 通道").font(.subheadline)
            slider("红色增益", value: $grade.gainRed, range: 0.50...1.80, neutral: 0, scale: 1, format: "%.2f")
            slider("绿色增益", value: $grade.gainGreen, range: 0.50...1.80, neutral: 0, scale: 1, format: "%.2f")
            slider("蓝色增益", value: $grade.gainBlue, range: 0.50...1.80, neutral: 0, scale: 1, format: "%.2f")
            slider("红色偏移", value: $grade.offsetRed, range: -0.25...0.25, neutral: 0, format: "%+.0f")
            slider("绿色偏移", value: $grade.offsetGreen, range: -0.25...0.25, neutral: 0, format: "%+.0f")
            slider("蓝色偏移", value: $grade.offsetBlue, range: -0.25...0.25, neutral: 0, format: "%+.0f")
            Text("增益 1.00、偏移 0 为不变。偏移按百分比显示。")
                .font(.caption).foregroundStyle(.secondary)
            Text("曲线").font(.subheadline)
            Picker("曲线", selection: $channel) {
                ForEach(SeamCurveChannel.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            SeamCurveEditor(points: curvePoints, tint: channel.tint)
                .id(channel)
            Button("恢复高级调色默认值") { grade = .init() }
        }
        .task(id: "\(original != nil)-\(grade.local)-\(seamWidth)") { await reloadHistogram() }
    }

    private var curvePoints: Binding<[WallpaperCurvePoint]> {
        Binding(get: { grade[keyPath: channel.keyPath] }, set: { grade[keyPath: channel.keyPath] = $0 })
    }

    private var black: Binding<Double> {
        Binding(get: { grade.black }, set: { value in
            var next = grade
            next.black = min(max(value, 0), 0.98)
            next.white = min(1, max(next.white, next.black + 0.02))
            next.gray = min(max(next.gray, next.black + 0.01), next.white - 0.01)
            grade = next
        })
    }

    private var white: Binding<Double> {
        Binding(get: { grade.white }, set: { value in
            var next = grade
            next.white = min(1, max(value, 0.02))
            next.black = min(next.black, next.white - 0.02)
            next.gray = min(max(next.gray, next.black + 0.01), next.white - 0.01)
            grade = next
        })
    }

    private var gray: Binding<Double> {
        Binding(get: { grade.gray }, set: { value in
            var next = grade
            next.gray = min(max(value, next.black + 0.01), next.white - 0.01)
            grade = next
        })
    }

    private func reloadHistogram() async {
        guard let original else { histogram = .empty; return }
        let fraction = grade.local ? max(0.02, seamWidth) : 1
        let image = original
        let next = await Task.detached { WallpaperRenderer.histogram(image, leftFraction: fraction) }.value
        if !Task.isCancelled { histogram = next }
    }

    private func levelSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        slider(title, value: value, range: range, neutral: 0, format: "%.0f%%")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double,
                        step: Double = 0.01, scale: Double = 100, format: String = "%+.0f") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, (value.wrappedValue - neutral) * scale)).monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

private struct SeamHistogramView: View {
    var histogram: WallpaperHistogram

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                stroke(histogram.red, .red.opacity(0.85), &context, size)
                stroke(histogram.green, .green.opacity(0.8), &context, size)
                stroke(histogram.blue, .blue.opacity(0.8), &context, size)
            }
            .frame(height: 78)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                legend("红", .red)
                legend("绿", .green)
                legend("蓝", .blue)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }

    private func stroke(_ values: [Float], _ color: Color, _ context: inout GraphicsContext, _ size: CGSize) {
        guard values.count > 1 else { return }
        var path = Path()
        for index in values.indices {
            let x = CGFloat(index) / CGFloat(values.count - 1) * size.width
            let y = size.height - 4 - CGFloat(values[index]) * (size.height - 8)
            let point = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.2)
    }
}

private struct SeamCurveEditor: View {
    @Binding var points: [WallpaperCurvePoint]
    var tint: Color
    @State private var selected = 0
    @State private var dragIndex: Int?

    var body: some View {
        let ordered = WallpaperAdvancedGrade.ordered(points)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let rect = plotRect(geo.size)
                Canvas { context, size in
                    let plot = plotRect(size)
                    var grid = Path()
                    for step in 1...3 {
                        let x = plot.minX + plot.width * CGFloat(step) / 4
                        let y = plot.minY + plot.height * CGFloat(step) / 4
                        grid.move(to: CGPoint(x: x, y: plot.minY))
                        grid.addLine(to: CGPoint(x: x, y: plot.maxY))
                        grid.move(to: CGPoint(x: plot.minX, y: y))
                        grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                    var guide = Path()
                    guide.move(to: location(WallpaperCurvePoint(x: 0, y: 0), in: plot))
                    guide.addLine(to: location(WallpaperCurvePoint(x: 1, y: 1), in: plot))
                    context.stroke(guide, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    var curve = Path()
                    for (index, point) in ordered.enumerated() {
                        let place = location(point, in: plot)
                        if index == 0 { curve.move(to: place) } else { curve.addLine(to: place) }
                    }
                    context.stroke(curve, with: .color(tint), lineWidth: 2)
                    for (index, point) in ordered.enumerated() {
                        let place = location(point, in: plot)
                        let radius: CGFloat = index == selected ? 7 : 5
                        let dot = Path(ellipseIn: CGRect(x: place.x - radius, y: place.y - radius, width: radius * 2, height: radius * 2))
                        context.fill(dot, with: .color(tint))
                        context.stroke(dot, with: .color(.white), lineWidth: index == selected ? 2 : 1)
                    }
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in edit(value, in: rect) }
                        .onEnded { _ in dragIndex = nil }
                )
            }
            .frame(height: 168)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            if ordered.indices.contains(selected) {
                let point = ordered[selected]
                Text("输入 \(Int((point.x * 100).rounded()))% → 输出 \(Int((point.y * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("点击添加控制点，拖动调整。最多 8 个。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("删除") { removeSelected() }
                    .font(.caption)
                    .disabled(selected == 0 || selected >= ordered.count - 1 || ordered.count <= 2)
            }
        }
        .onChange(of: ordered.count) { _, count in selected = min(selected, max(0, count - 1)) }
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 12, y: 12, width: max(1, size.width - 24), height: max(1, size.height - 24))
    }

    private func location(_ point: WallpaperCurvePoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(point.x) * rect.width, y: rect.maxY - CGFloat(point.y) * rect.height)
    }

    private func curvePoint(_ location: CGPoint, in rect: CGRect) -> WallpaperCurvePoint {
        WallpaperCurvePoint(
            x: min(1, max(0, Double((location.x - rect.minX) / rect.width))),
            y: min(1, max(0, Double((rect.maxY - location.y) / rect.height)))
        )
    }

    private func edit(_ value: DragGesture.Value, in rect: CGRect) {
        let current = WallpaperAdvancedGrade.ordered(points)
        if dragIndex == nil {
            if let hit = hitIndex(value.startLocation, points: current, rect: rect) {
                dragIndex = hit
                selected = hit
            } else if current.count < 8 {
                let index = insert(curvePoint(value.startLocation, in: rect))
                dragIndex = index
                selected = index
            } else if let nearest = nearestIndex(curvePoint(value.startLocation, in: rect), points: current) {
                dragIndex = nearest
                selected = nearest
            }
        }
        if let dragIndex { move(dragIndex, to: curvePoint(value.location, in: rect)) }
    }

    private func hitIndex(_ location: CGPoint, points: [WallpaperCurvePoint], rect: CGRect) -> Int? {
        let nearest = points.enumerated().min { left, right in
            distance(self.location(left.element, in: rect), location) < distance(self.location(right.element, in: rect), location)
        }
        guard let nearest, distance(self.location(nearest.element, in: rect), location) <= 18 else { return nil }
        return nearest.offset
    }

    private func nearestIndex(_ point: WallpaperCurvePoint, points: [WallpaperCurvePoint]) -> Int? {
        points.enumerated().min { abs($0.element.x - point.x) < abs($1.element.x - point.x) }?.offset
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func insert(_ point: WallpaperCurvePoint) -> Int {
        var next = WallpaperAdvancedGrade.ordered(points)
        if point.x <= 0.02 { return 0 }
        if point.x >= 0.98 { return next.count - 1 }
        if let existing = nearestIndex(point, points: next), abs(next[existing].x - point.x) < 0.02 { return existing }
        next.append(point)
        next = WallpaperAdvancedGrade.ordered(next)
        points = next
        return next.firstIndex { abs($0.x - point.x) < 0.0001 && abs($0.y - point.y) < 0.0001 } ?? min(1, next.count - 1)
    }

    private func move(_ index: Int, to point: WallpaperCurvePoint) {
        var next = WallpaperAdvancedGrade.ordered(points)
        guard next.indices.contains(index) else { return }
        let y = min(1, max(0, point.y))
        if index == 0 {
            next[0].y = y
        } else if index == next.count - 1 {
            next[next.count - 1].y = y
        } else {
            let lower = next[index - 1].x + 0.02
            let upper = next[index + 1].x - 0.02
            next[index].y = y
            if lower <= upper { next[index].x = min(upper, max(lower, point.x)) }
        }
        points = next
    }

    private func removeSelected() {
        var next = WallpaperAdvancedGrade.ordered(points)
        guard next.count > 2, selected > 0, selected < next.count - 1 else { return }
        next.remove(at: selected)
        points = next
        selected = min(selected, next.count - 1)
    }
}
