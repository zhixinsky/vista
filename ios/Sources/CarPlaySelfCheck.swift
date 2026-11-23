import SwiftUI

enum CarPlayCompatibility {
    static func supported(version: String, build: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        if major == 26 { return true }
        guard major == 27 else { return false }
        let minor = parts.count > 1 ? parts[1] : 0
        if minor < 3 { return true }
        return minor == 3 && build == "24C5037i"
    }
}

struct CarPlayStatusCard: View {
    @EnvironmentObject private var model: WorkshopModel
    @State private var showCheck = false
    private var supported: Bool { CarPlayCompatibility.supported(version: UIDevice.current.systemVersion, build: ServiceClient.systemBuild) }
    private var ready: Bool {
        supported && model.selfCheckResult?["ok"] as? Bool == true && model.targets.count == 12 && model.targets.allSatisfy(\.editable)
    }
    private var status: String {
        if model.selfChecking { return "正在检测" }
        if model.selfCheckDate == nil { return "等待自检" }
        return ready ? "已准备好" : "需要处理"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CarPlay").font(.headline)
                Spacer()
                Label(status, systemImage: ready ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.caption.weight(.semibold)).foregroundStyle(ready ? .green : CanvasTheme.accent)
            }
            Text(model.selfChecking ? "正在检查车机壁纸环境…" : ready ? "已找到 12 张壁纸，可以选择并应用。" : model.selfCheckDate == nil ? "首次使用，请先检查车机壁纸环境。" : "点击自检，查看需要完成的准备。")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button { showCheck = true } label: { Label("CarPlay 自检", systemImage: "waveform.path.ecg") }
                    .buttonStyle(.borderedProminent)
                Spacer(minLength: 8)
                WallpaperRefreshButton(title: "重启系统界面", systemImage: "arrow.clockwise")
                    .buttonStyle(.bordered)
            }.font(.subheadline)
            if let date = model.selfCheckDate {
                Text("上次检查 \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .fullScreenCover(isPresented: $showCheck) { CarPlaySelfCheckView() }
    }
}

struct CarPlaySelfCheckView: View {
    @EnvironmentObject private var model: WorkshopModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    private let cyan = Color(red: 0.2, green: 0.9, blue: 0.95)
    private var supported: Bool { CarPlayCompatibility.supported(version: UIDevice.current.systemVersion, build: ServiceClient.systemBuild) }
    private var result: [String: Any] { model.selfCheckResult ?? [:] }
    private var evidence: [String: Any] { result["evidence"] as? [String: Any] ?? [:] }
    private var mapped: [String: Any] { evidence["mappedCache"] as? [String: Any] ?? [:] }
    private var loose: [[String: Any]] { (evidence["caches"] as? [String: Any])?["files"] as? [[String: Any]] ?? [] }
    private var checked: Bool { model.selfCheckDate != nil && !model.selfChecking }
    private var readable: Bool { mapped["listingSucceeded"] as? Bool == true }
    private var count: Int { model.targets.filter(\.editable).count }
    private var ready: Bool { supported && checked && readable && count == 12 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ZStack {
                        Circle().stroke(cyan.opacity(0.12), lineWidth: 10)
                        Circle().trim(from: 0, to: model.selfChecking ? 0.72 : 1)
                            .stroke(AngularGradient(colors: [cyan.opacity(0.1), cyan], center: .center), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(model.selfChecking && rotating && !reduceMotion ? 360 : 0))
                            .animation(model.selfChecking && !reduceMotion ? .linear(duration: 2).repeatForever(autoreverses: false) : .default, value: rotating)
                        VStack(spacing: 8) {
                            Image(systemName: model.selfChecking ? "waveform.path.ecg" : ready ? "checkmark.shield.fill" : "car.side.fill").font(.system(size: 34)).foregroundStyle(cyan)
                            Text(model.selfChecking ? "正在检索" : ready ? "已准备好" : checked ? "需要处理" : "等待自检").font(.title3.bold())
                            Text(model.selfChecking ? "权限 · 容器 · 壁纸" : "CARPLAY DIAGNOSTICS").font(.system(size: 9, design: .monospaced)).foregroundStyle(cyan.opacity(0.8))
                        }
                    }.frame(width: 190, height: 190).padding(.top, 18)
                    VStack(spacing: 0) {
                        row("设备信息", detail: "\(deviceName) · \(ServiceClient.machine)", good: true)
                        row("系统兼容性", detail: "iOS \(UIDevice.current.systemVersion) · \(ServiceClient.systemBuild)\n支持 iOS 26 至 27.3 beta 1", good: supported)
                        row("App Group", detail: model.appGroupStatus, good: model.group.isEmpty ? false : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: model.group) != nil)
                        row("实际访问权限", detail: checked ? readable ? "目标壁纸目录可列出" : "尚未确认可读取目标壁纸目录" : "等待检索", good: checked ? readable : nil)
                        row("CarPlay 容器", detail: checked ? model.root.isEmpty ? "未定位，请重新检测" : "已定位并确认身份" : "等待检索", good: checked ? !model.root.isEmpty : nil)
                        row("壁纸缓存", detail: checked ? "可用 \(count) 张 · 缺失 \(model.targets.filter(\.missing).count) 张" : "等待检索", good: checked ? count == 12 : nil)
                        let scattered = loose.filter { $0["wallpaper"] as? Bool == true }.count
                        row("备用位置", detail: checked ? "Caches 根目录发现 \(scattered) 张壁纸" : "等待检索", good: checked ? scattered == 0 : nil)
                        let copies = result["validRepairCopies"] as? Int ?? 0
                        row("本机恢复副本", detail: checked ? "已验证 \(copies) 张；缺项恢复时需要默认壁纸" : "等待检索", good: checked ? copies == 12 : nil)
                    }.background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    if checked && !ready {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("下一步", systemImage: "arrow.right.circle").font(.headline)
                            Text(!supported ? "当前系统不在支持范围内。27.3 仅支持 beta 1（24C5037i）。" : model.group.isEmpty ? "当前安装没有提供 App Group，请使用支持 App Group 的方式重新签名安装。" : !readable || count == 0 ? "请连接 CarPlay，在车机设置中切换一次系统壁纸，然后返回重新检测。若仍失败，请导出诊断。" : "部分壁纸缺失或无法读取。可在车机切换其他内置壁纸后重新检测，或进入壁纸缓存页检查。")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            if model.group.isEmpty == false && count == 0 {
                                Button("继续定位容器") { model.scan(deep: true) }.disabled(model.busy)
                                Text("首次完整定位可能需要数分钟，完成后请重新自检。 ").font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    }
                    DisclosureGroup("技术详情") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("App：\(model.appVersion)\nApp Group：\(model.group)\n容器：\(model.root)")
                            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { Text(text) }
                        }.font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.tint(cyan)
                    Text("自检检查手机内的访问与文件状态；车机是否显示新壁纸，需要连接后确认。")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    if model.diagnosing { ProgressView("正在生成诊断…") }
                    if !model.reportNote.isEmpty { Text(model.reportNote).font(.caption) }
                    if let report = model.reportURL { ShareLink("分享诊断文件", item: report) }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(LinearGradient(colors: [Color(red: 0.025, green: 0.065, blue: 0.12), .black], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
            .foregroundStyle(.white).tint(cyan)
            .navigationTitle("CarPlay 自检").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() } }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(model.selfChecking ? "正在检测…" : "重新检测") { start() }.buttonStyle(.borderedProminent).disabled(model.busy)
                    Button("导出诊断") { model.makeReport() }.buttonStyle(.bordered).disabled(model.busy || model.diagnosing)
                }.padding().frame(maxWidth: .infinity).background(.ultraThinMaterial)
            }
            .task { start() }
            .onChange(of: model.selfChecking) { _, running in rotating = running }
            .preferredColorScheme(.dark)
        }
    }
    private var deviceName: String {
        let names = ["iPhone18,2": "iPhone 17 Pro Max", "iPhone18,1": "iPhone 17 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,1": "iPhone 16 Pro"]
        return names[ServiceClient.machine] ?? UIDevice.current.model
    }
    private func start() { model.runSelfCheck(); rotating = model.selfChecking }
    private func row(_ title: String, detail: String, good: Bool?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: good == true ? "checkmark.circle.fill" : good == false ? "exclamationmark.circle.fill" : "circle.dotted")
                .foregroundStyle(good == true ? Color.green : good == false ? Color.orange : cyan)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}
