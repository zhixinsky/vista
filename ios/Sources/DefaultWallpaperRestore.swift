// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UIKit

@MainActor
extension WorkshopModel {
    func restoreDefaultWallpapers() {
        guard !busy else { return }
        busy = true
        message = "正在读取默认壁纸配置…"
        Task {
            do {
                let request = URLRequest(url: ServiceGate.join("v1/default-wallpapers"), timeoutInterval: 20)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RestoreError.message("无法读取默认壁纸配置，请稍后重试。") }
                struct Config: Decodable { let groups: [String] }
                let groups = try JSONDecoder().decode(Config.self, from: data).groups
                let allowed = Set(["Black", "Blue", "Brown", "DarkBlue", "Green", "Grey", "Hero", "Lilac", "Purple", "Red", "Teal"])
                guard groups.count == 6, Set(groups).count == 6, groups.allSatisfy({ allowed.contains($0) }) else { throw RestoreError.message("默认壁纸尚未配置，请联系管理员。") }
                var images: [String: Data] = [:]
                for group in groups {
                    for mode in ["Dark", "Light"] {
                        message = "正在下载默认壁纸… \(images.count)/12"
                        let request = URLRequest(url: ServiceGate.join("v1/default-wallpapers/\(group)/\(mode)"), timeoutInterval: 40)
                        let (image, response) = try await URLSession.shared.data(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), image.count <= 20_000_000,
                              UIImage(data: image)?.cgImage != nil else { throw RestoreError.message("默认壁纸下载失败，请重试。") }
                        images["\(group)-\(mode)"] = image
                    }
                }
                message = "正在备份并恢复默认壁纸…"
                busy = false
                let downloaded = images
                work({ CCEngine.restoreDefaults(downloaded) as? [String: Any] ?? [:] }) { result in
                    self.message = result["message"] as? String ?? "恢复失败，请重试。"
                    self.targets = []
                    self.makeReport()
                }
            } catch {
                message = (error as? RestoreError)?.text ?? "无法下载默认壁纸，请检查网络后重试。"
                busy = false
            }
        }
    }
}

private enum RestoreError: Error {
    case message(String)
    var text: String { switch self { case .message(let text): return text } }
}

// A complete server-default set is retained outside Caches for offline recovery.
// Publish a new set atomically only after all twelve images have been validated.
enum AutomaticWallpaperDefaults {
    static func validate(_ images: [String: Data]) -> Bool {
        let allowed = Set(["Black", "Blue", "Brown", "DarkBlue", "Green", "Grey", "Hero", "Lilac", "Purple", "Red", "Teal"])
        guard images.count == 12 else { return false }
        var groups = Set<String>()
        for (key, data) in images {
            let parts = key.split(separator: "-").map(String.init)
            guard parts.count == 2, allowed.contains(parts[0]), ["Dark", "Light"].contains(parts[1]),
                  !data.isEmpty, data.count <= 20_000_000, UIImage(data: data)?.cgImage != nil else { return false }
            groups.insert(parts[0])
        }
        return groups.count == 6
    }

    static func load() async throws -> [String: Data] {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperRecovery", isDirectory: true)
        let archive = directory.appendingPathComponent("server-defaults.plist")
        if let data = try? Data(contentsOf: archive),
           let images = try? PropertyListDecoder().decode([String: Data].self, from: data), validate(images) {
            return images
        }
        struct Config: Decodable { let groups: [String] }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: ServiceGate.join("v1/default-wallpapers"), timeoutInterval: 20))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RestoreError.message("自动恢复：无法读取默认壁纸配置。")
        }
        let groups = try JSONDecoder().decode(Config.self, from: data).groups
        let allowed = Set(["Black", "Blue", "Brown", "DarkBlue", "Green", "Grey", "Hero", "Lilac", "Purple", "Red", "Teal"])
        guard groups.count == 6, Set(groups).count == 6, groups.allSatisfy({ allowed.contains($0) }) else {
            throw RestoreError.message("自动恢复：默认配置必须包含六组壁纸。")
        }
        var images: [String: Data] = [:]
        for group in groups {
            for mode in ["Dark", "Light"] {
                let (image, response) = try await URLSession.shared.data(for: URLRequest(
                    url: ServiceGate.join("v1/default-wallpapers/\(group)/\(mode)"), timeoutInterval: 40))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      image.count <= 20_000_000, UIImage(data: image)?.cgImage != nil else {
                    throw RestoreError.message("自动恢复：默认壁纸未下载完整。")
                }
                images["\(group)-\(mode)"] = image
            }
        }
        guard validate(images) else { throw RestoreError.message("自动恢复：默认壁纸校验失败。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(images).write(to: archive, options: .atomic)
        return images
    }
}
