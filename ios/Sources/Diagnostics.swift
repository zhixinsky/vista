import Foundation

struct FileRecord: Codable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int
    let modified: Date?
}

struct ScanReport: Codable {
    let date: Date
    let system: String
    let root: String
    let status: String
    let files: [FileRecord]
    let errors: [String]
    let truncated: Bool
}

enum Diagnostics {
    static let legacyCache = "Library/Caches/MappedImageCache/com.apple.CarPlayApp.wallpaper-images"

    // Accept only an explicitly selected container/export directory. This does
    // not grant access to protected containers or assume that an empty result
    // means CarPlay has stopped generating caches.
    static func scan(root: URL, system: String) -> ScanReport {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let scanRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var records: [FileRecord] = []
        var errors: [String] = []
        var truncated = false
        let manager = FileManager.default
        do {
            _ = try manager.contentsOfDirectory(at: scanRoot, includingPropertiesForKeys: nil)
        } catch {
            return ScanReport(date: Date(), system: system, root: root.path,
                status: "无法读取目录", files: [], errors: [describe(error)], truncated: false)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(at: scanRoot, includingPropertiesForKeys: keys,
            options: [], errorHandler: { url, error in
                errors.append("\(url.lastPathComponent): \(describe(error))")
                return errors.count < 100
            }) else {
            return ScanReport(date: Date(), system: system, root: root.path,
                status: "无法枚举目录", files: [], errors: [], truncated: false)
        }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20000 { truncated = true; break }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                let prefix = scanRoot.path.hasSuffix("/") ? scanRoot.path : scanRoot.path + "/"
                guard path.hasPrefix(prefix) else { errors.append("文件路径不在选定目录内"); continue }
                let relative = String(path.dropFirst(prefix.count))
                records.append(FileRecord(path: relative, bytes: values.fileSize ?? 0,
                    modified: values.contentModificationDate))
            } catch { errors.append("\(url.lastPathComponent): \(describe(error))") }
            if errors.count >= 100 { truncated = true; break }
        }
        if errors.count >= 100 { truncated = true }
        return ScanReport(date: Date(), system: system, root: root.path,
            status: !errors.isEmpty || truncated ? "扫描不完整" : records.isEmpty ? "目录可读，但没有文件" : "扫描完成",
            files: records.sorted { $0.path < $1.path }, errors: errors, truncated: truncated)
    }

    static func describe(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) / \(value.code): \(value.localizedDescription)"
    }

    static func changes(before: ScanReport, after: ScanReport) -> [String] {
        let old = Dictionary(uniqueKeysWithValues: before.files.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.files.map { ($0.path, $0) })
        var result = after.files.compactMap { item -> String? in
            guard let previous = old[item.path] else { return "新增：\(item.path)" }
            return previous == item ? nil : "大小或时间变化：\(item.path)"
        }
        result += before.files.filter { new[$0.path] == nil }.map { "未再扫描到：\($0.path)" }
        return result.sorted()
    }
}
