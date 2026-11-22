import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @State private var picking = false
    @State private var busy = false
    @State private var root: URL?
    @State private var baseline: ScanReport?
    @State private var report: ScanReport?
    @State private var changes: [String] = []
    @State private var exportURL: URL?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section("当前能力") {
                    Text("此版本只读扫描用户选定的目录或导出的缓存副本。尚未接入系统容器访问后端，不能直接读取或修改 CarPlay 系统缓存。")
                    Text("系统：\(UIDevice.current.systemVersion)")
                }
                Section("缓存诊断") {
                    Button("选择目录") { picking = true }.disabled(busy)
                    if let root { Text(root.lastPathComponent) }
                    Button("记录基线") { run(asBaseline: true) }.disabled(root == nil || busy)
                    Button("再次扫描并对比") { run(asBaseline: false) }.disabled(root == nil || baseline == nil || busy)
                    if busy { ProgressView("正在扫描") }
                    Text("对比只依据文件名、大小和修改时间；不是内容哈希验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let report {
                    Section("结果") {
                        Text(report.status)
                        Text("\(report.files.count) 个文件，\(report.errors.count) 个错误")
                        if let exportURL { ShareLink("导出 JSON 报告", item: exportURL) }
                        ForEach(Array(report.errors.prefix(20).enumerated()), id: \.offset) { _, error in Text(error) }
                    }
                    Section("壁纸候选文件（最多显示 100 项）") {
                        ForEach(Array(report.files.filter {
                            $0.path.lowercased().contains("wallpaper") || $0.path.lowercased().hasSuffix(".cpbitmap")
                        }.prefix(100))) { item in
                            VStack(alignment: .leading) {
                                Text(item.path)
                                Text("\(item.bytes) bytes").font(.caption)
                            }
                        }
                    }
                }
                if !changes.isEmpty {
                    Section("变化（最多显示 100 项）") {
                        ForEach(Array(changes.prefix(100).enumerated()), id: \.offset) { _, item in Text(item) }
                    }
                }
                if let message { Section("提示") { Text(message) } }
            }
            .navigationTitle("CarVista 诊断")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    root = url; baseline = nil; report = nil; changes = []; exportURL = nil; message = nil
                case .failure(let error): message = Diagnostics.describe(error)
                }
            }
        }
    }

    private func run(asBaseline: Bool) {
        guard let root else { return }
        busy = true
        exportURL = nil
        message = nil
        let system = UIDevice.current.systemVersion
        Task {
            let next = await Task.detached(priority: .userInitiated) {
                Diagnostics.scan(root: root, system: system)
            }.value
            report = next
            if asBaseline { baseline = next; changes = [] }
            else if let baseline {
                changes = Diagnostics.changes(before: baseline, after: next)
                if changes.isEmpty { message = "未发现文件名、大小或时间变化；不代表内容一定未变化。" }
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarVista-\(UUID().uuidString).json")
                let bundle = ReportBundle(baseline: baseline, current: next, changes: changes)
                try encoder.encode(bundle).write(to: url, options: .atomic)
                exportURL = url
            } catch { message = Diagnostics.describe(error) }
            busy = false
        }
    }
}

private struct ReportBundle: Encodable {
    let baseline: ScanReport?
    let current: ScanReport
    let changes: [String]
}
