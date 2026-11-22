// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

extension WorkshopModel {
    var detectedWallpaperSize: CGSize? {
        let groups = Dictionary(grouping: targets.filter(\.editable), by: { "\($0.width)x\($0.height)" })
        return groups.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }.first?.value.first.map { CGSize(width: $0.width, height: $0.height) } ?? lastDetectedWallpaperSize
    }

    func generatePhotos(_ photos: [MakerPhoto], preset: WallpaperPreset, size: CGSize,
                        completion: @escaping ([[SavedWallpaper]]) -> Void) {
        guard !busy, !photos.isEmpty else { return }
        generationProgress = 0
        message = "正在生成壁纸…"
        work({
            var batches: [[SavedWallpaper]] = []
            var created: [SavedWallpaper] = []
            do {
                for (index, photo) in photos.enumerated() {
                    try autoreleasepool {
                        let rendered = try WallpaperRenderer.render(url: photo.url, preset: preset, size: size, adjustment: photo.adjustment)
                        let carPlayImage = rendered
                        let batchID = UUID()
                        let outputs: [(SavedWallpaper, UIImage)] = ["深色", "浅色"].map { mode in
                            let pixels = carPlayImage.cgImage
                            let entry = SavedWallpaper(id: UUID(), created: Date(), width: pixels?.width ?? Int(carPlayImage.size.width),
                                                       height: pixels?.height ?? Int(carPlayImage.size.height),
                                                       mode: mode, batchID: batchID, outputPreset: preset.title)
                            return (entry, carPlayImage)
                        }
                        let entries = outputs.map(\.0)
                        created += entries
                        for (entry, image) in outputs {
                            let ratio = min(1, 512 / max(image.size.width, image.size.height))
                            let previewSize = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
                            let preview = UIGraphicsImageRenderer(size: previewSize, format: WallpaperRenderer.format()).image { _ in
                                image.draw(in: CGRect(origin: .zero, size: previewSize))
                            }
                            guard let png = image.pngData(), let jpeg = preview.jpegData(compressionQuality: 0.88) else { throw CocoaError(.fileWriteUnknown) }
                            let encoded = CCEngine.encode(image, to: entry.bitmap.path) as? [String: Any] ?? [:]
                            guard encoded["ok"] as? Bool == true else {
                                throw NSError(domain: "LvMu", code: 1, userInfo: [NSLocalizedDescriptionKey: encoded["message"] as? String ?? "生成失败"])
                            }
                            try png.write(to: entry.originalImage, options: .atomic)
                            try jpeg.write(to: entry.preview, options: .atomic)
                            try JSONEncoder().encode(entry).write(to: Self.library.appendingPathComponent("\(entry.id).json"), options: .atomic)
                        }
                        batches.append(entries)
                    }
                    let progress = Double(index + 1) / Double(photos.count)
                    DispatchQueue.main.async { self.generationProgress = progress }
                }
                return ["ok": true, "batches": batches]
            } catch {
                for entry in created {
                    for url in [entry.bitmap, entry.preview, entry.originalImage, Self.library.appendingPathComponent("\(entry.id).json")] {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                return ["ok": false, "message": error.localizedDescription]
            }
        }) { result in
            if let batches = result["batches"] as? [[SavedWallpaper]], result["ok"] as? Bool == true {
                self.history.insert(contentsOf: batches.flatMap { $0 }, at: 0)
                self.message = "已生成 \(batches.count * 2) 个文件，深色与浅色均已保存。"
                for (photo, batch) in zip(photos, batches) {
                    self.reportSaved(batch, source: photo.remoteSource ?? "photo", assetID: photo.remoteAssetID)
                }
                completion(batches)
            } else {
                self.generationProgress = 0
                self.message = result["message"] as? String ?? "生成失败"
                self.report("save_wallpaper", ok: false, ["message": self.message, "stage": "encode"])
                completion([])
            }
        }
    }
}
