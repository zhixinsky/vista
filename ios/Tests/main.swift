import Foundation
import CoreGraphics

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

// Portrait and landscape sources must cover the whole output without gaps,
// including all slider extrema and non-integer aspect ratios.
for source in [CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032), CGSize(width: 1600, height: 400)] {
    for target in [CGSize(width: 1920, height: 720), CGSize(width: 800, height: 480)] {
        for zoom in [1.0, 2.5, 4.0] {
            for x in [0.0, 0.5, 1.0] {
                for y in [0.0, 0.5, 1.0] {
                    let rect = CropGeometry.rect(source: source, target: target, zoom: zoom, x: x, y: y)
                    expect(rect.minX <= 0.001 && rect.minY <= 0.001, "crop leaves top/left gap")
                    expect(rect.maxX >= target.width - 0.001 && rect.maxY >= target.height - 0.001, "crop leaves bottom/right gap")
                    expect(abs(rect.width / rect.height - source.width / source.height) < 0.0001, "crop distorts source")
                }
            }
        }
    }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("CarVistaTests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let a = root.appendingPathComponent("old.cpbitmap")
let b = root.appendingPathComponent("added.cpbitmap")
try Data([1, 2, 3]).write(to: a)
let before = Diagnostics.scan(root: root, system: "fixture")
expect(before.files.count == 1, "baseline incomplete")
try Data([1, 2, 3, 4]).write(to: a)
try Data([5]).write(to: b)
// Symbolic links should not cause data outside the selected directory to be scanned.
try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc")
let after = Diagnostics.scan(root: root, system: "fixture")
expect(after.files.count == 2, "followed symlink or missed file")
let changes = Diagnostics.changes(before: before, after: after)
expect(changes.contains("新增：added.cpbitmap"), "missed addition")
expect(changes.contains("大小或时间变化：old.cpbitmap"), "missed modification")
try FileManager.default.removeItem(at: a)
let removed = Diagnostics.scan(root: root, system: "fixture")
expect(Diagnostics.changes(before: after, after: removed).contains("未再扫描到：old.cpbitmap"), "missed missing file")
let missing = Diagnostics.scan(root: root.appendingPathComponent("missing"), system: "fixture")
expect(!missing.errors.isEmpty && missing.status == "无法读取目录", "missing directory reported as empty success")
print("PASS: 162 crop cases; file additions, changes, missing entries, symlink exclusion and missing-directory errors")

let oldRecord = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "created": 0,
    "width": 1920, "height": 720, "mode": "深色"])
var restoredRecord = try JSONDecoder().decode(SavedWallpaper.self, from: oldRecord)
expect(restoredRecord.batchID == nil && restoredRecord.customName == nil, "old records must remain readable")
expect(restoredRecord.preservePixels == nil, "old records must retain their previous rendering policy")
let group = UUID()
restoredRecord.batchID = group
restoredRecord.customName = "我的海边壁纸"
let roundtrip = try JSONDecoder().decode(SavedWallpaper.self, from: JSONEncoder().encode(restoredRecord))
expect(roundtrip.batchID == group && roundtrip.customName == "我的海边壁纸", "group/name persistence failed")
expect(roundtrip.id == restoredRecord.id && roundtrip.width == 1920, "migration changed original identity")
print("PASS: backward-compatible history decoding and new metadata persistence")

expect(WallpaperStorage.validSize(width: 1920, height: 720), "normal wallpaper rejected")
for (width, height) in [(0, 720), (1920, 0), (-1, 720), (Int.max, Int.max), (Int.max / 4 + 1, 1)] {
    expect(!WallpaperStorage.validSize(width: width, height: height), "unsafe dimensions accepted")
}
for (width, height) in [(8193, 1000), (8192, 8192), (12000, 4000)] {
    expect(WallpaperStorage.validSize(width: width, height: height), "large original image incorrectly rejected")
}
expect(CropGeometry.rect(source: .init(width: 100, height: 100), target: .init(width: 10, height: 10), zoom: .nan, x: 0.5, y: 0.5) == .zero, "NaN reached renderer")
expect(CropGeometry.rect(source: .init(width: CGFloat.infinity, height: 100), target: .init(width: 10, height: 10), zoom: 1, x: 0.5, y: 0.5) == .zero, "infinite size reached renderer")
print("PASS: invalid dimensions, integer overflow and non-finite crop rejection")

expect(WallpaperPreset.standard.size() == CGSize(width: 1440, height: 810), "standard preset wrong")
expect(WallpaperPreset.wide.size() == CGSize(width: 1920, height: 810), "wide preset wrong")
expect(WallpaperPreset.panoramic.size() == CGSize(width: 2560, height: 810), "panoramic preset wrong")
expect(WallpaperPreset.automatic.size() == CGSize(width: 1920, height: 810), "offline automatic fallback wrong")
expect(WallpaperPreset.automatic.size(detected: CGSize(width: 2420, height: 1668)) == CGSize(width: 2420, height: 1668), "automatic ignored detected cache")
expect(WallpaperPreset.original.preservesSourceSize, "original preset should keep source pixels")
expect(WallpaperPreset.original.size(source: CGSize(width: 4032, height: 3024)) == CGSize(width: 4032, height: 3024), "original preset resized source")
expect(!WallpaperPreset.wide.preservesSourceSize, "fixed preset claimed original size")
for preset in WallpaperPreset.allCases where !preset.preservesSourceSize {
    expect(preset.crops == (preset == .standard || preset == .custom), "crop presets changed")
    for source in [CGSize(width: 800, height: 1200), CGSize(width: 1200, height: 800), CGSize(width: 7879, height: 2160)] {
        let target = preset.size()
        let fit = CropGeometry.fit(source: source, target: target)
        expect(fit.minX >= -0.01 && fit.minY >= -0.01 && fit.maxX <= target.width + 0.01 && fit.maxY <= target.height + 0.01, "fit cropped foreground")
        expect(abs(fit.width / fit.height - source.width / source.height) < 0.001, "fit stretched foreground")
    }
}
print("PASS: presets, automatic detection, original size, full-image fit and standard-only crop")

