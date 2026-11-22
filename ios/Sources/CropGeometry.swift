// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics

enum WallpaperPreset: String, CaseIterable, Codable, Identifiable {
    case automatic, standard, wide, panoramic, original, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .standard: return "标准"
        case .wide: return "宽屏"
        case .panoramic: return "大联屏"
        case .original: return "原尺寸"
        case .custom: return "自由裁剪"
        }
    }
    var crops: Bool { self == .standard || self == .custom }
    var preservesSourceSize: Bool { self == .original }
    func size(detected: CGSize? = nil, source: CGSize? = nil) -> CGSize {
        switch self {
        case .automatic:
            if let detected, detected.width.isFinite, detected.height.isFinite, detected.width > 0, detected.height > 0 { return detected }
            return CGSize(width: 1920, height: 810)
        case .standard: return CGSize(width: 1440, height: 810)
        case .wide: return CGSize(width: 1920, height: 810)
        case .panoramic: return CGSize(width: 2560, height: 810)
        case .custom: return source ?? CGSize(width: 1920, height: 810)
        case .original:
            if let source, source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 { return source }
            return .zero
        }
    }
    var detail: String {
        if preservesSourceSize { return "按每张照片的原始像素输出，不缩放、不裁切，也不用模糊填充。旋转或翻转后宽高会跟着变。" }
        return crops ? "照片铺满画面，多出的部分裁掉。可点“裁剪”移动位置。" : "整张照片居中保留，空余区域用照片自身的模糊画面填满，不留黑边、不拉变形。"
    }
}

struct WallpaperAdjustment: Codable, Equatable {
    var pixelCrop: WallpaperPixelCrop?
    var color: WallpaperColorAdjustment?
    var turns = 0
    var flipX = false
    var flipY = false
    var zoom = 1.0
    var x = 0.5
    var y = 0.5
}

struct WallpaperColorAdjustment: Codable, Equatable {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var exposure: Double?
    var highlights: Double?
    var shadows: Double?
    var temperature: Double?
    var gamma: Double?
    var mask: WallpaperMaskCompensation?
    var leftEdge: WallpaperLeftEdgeBlend?
}

struct WallpaperLeftEdgeBlend: Codable, Equatable {
    var width = 0.20
    var brightness = 0.25
    var saturation = 0.08
    var curve = 1.0
    var advanced: WallpaperAdvancedGrade?
}

struct WallpaperCurvePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct WallpaperAdvancedGrade: Codable, Equatable {
    var local = true
    var protectHighlights = true
    var black = 0.0
    var gray = 0.5
    var white = 1.0
    var gainRed = 1.0
    var gainGreen = 1.0
    var gainBlue = 1.0
    var offsetRed = 0.0
    var offsetGreen = 0.0
    var offsetBlue = 0.0
    var master = WallpaperAdvancedGrade.identityCurve
    var red = WallpaperAdvancedGrade.identityCurve
    var green = WallpaperAdvancedGrade.identityCurve
    var blue = WallpaperAdvancedGrade.identityCurve

    static let identityCurve = [WallpaperCurvePoint(x: 0, y: 0), WallpaperCurvePoint(x: 1, y: 1)]

    var affectsPixels: Bool {
        if black > 0.0001 || white < 0.999 || abs(gray - 0.5) > 0.001 { return true }
        if abs(gainRed - 1) > 0.001 || abs(gainGreen - 1) > 0.001 || abs(gainBlue - 1) > 0.001 { return true }
        if abs(offsetRed) > 0.001 || abs(offsetGreen) > 0.001 || abs(offsetBlue) > 0.001 { return true }
        return !Self.linear(master) || !Self.linear(red) || !Self.linear(green) || !Self.linear(blue)
    }

    var needsBlend: Bool { affectsPixels || protectHighlights }

    var levelInputs: (black: Double, white: Double, gamma: Double) {
        let low = min(max(black, 0), 0.98)
        let high = min(1, max(white, low + 0.02))
        let mid = min(max(gray, low + 0.01), high - 0.01)
        let mapped = (mid - low) / (high - low)
        return (low, high, log(0.5) / log(min(0.99, max(0.01, mapped))))
    }

    static func ordered(_ points: [WallpaperCurvePoint]) -> [WallpaperCurvePoint] {
        var ordered = points.filter { $0.x.isFinite && $0.y.isFinite }.sorted { $0.x < $1.x }
        guard ordered.count >= 2 else { return identityCurve }
        ordered[0].x = 0
        ordered[ordered.count - 1].x = 1
        for index in ordered.indices {
            ordered[index].y = min(1, max(0, ordered[index].y))
        }
        return ordered
    }

    static func linear(_ points: [WallpaperCurvePoint]) -> Bool {
        let ordered = points.sorted { $0.x < $1.x }
        guard ordered.count <= 2, let first = ordered.first, let last = ordered.last else { return ordered.isEmpty }
        return abs(first.x) < 0.001 && abs(first.y) < 0.001 && abs(last.x - 1) < 0.001 && abs(last.y - 1) < 0.001
    }
}

struct WallpaperMaskCompensation: Codable, Equatable {
    var opacity = 0.20
    var strength: Double?
    var horizontalGradient: Bool?
    var protectHighlights: Bool?
}

struct WallpaperPixelCrop: Codable, Equatable {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int

    var rect: CGRect { CGRect(x: left, y: top, width: right - left, height: bottom - top) }

    static func full(_ size: CGSize) -> Self {
        Self(left: 0, top: 0, right: Int(size.width), bottom: Int(size.height))
    }

    func fits(_ size: CGSize) -> Bool {
        left >= 0 && top >= 0 && right > left && bottom > top && right <= Int(size.width) && bottom <= Int(size.height)
    }
}

enum CropGeometry {
    static func fit(source: CGSize, target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .zero }
        let scale = min(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (target.width - size.width) / 2, y: (target.height - size.height) / 2, width: size.width, height: size.height)
    }
    // Position 0 is the left/top edge, 1 the right/bottom edge. Rendering and
    // preview share this calculation, so the saved crop matches the preview.
    static func rect(source: CGSize, target: CGSize, zoom: Double, x: Double, y: Double) -> CGRect {
        guard source.width.isFinite, source.height.isFinite, target.width.isFinite, target.height.isFinite,
              zoom.isFinite, x.isFinite, y.isFinite,
              source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .zero }
        let scale = max(target.width / source.width, target.height / source.height) * CGFloat(max(1, min(4, zoom)))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (target.width - size.width) * CGFloat(min(1, max(0, x))),
                      y: (target.height - size.height) * CGFloat(min(1, max(0, y))),
                      width: size.width, height: size.height)
    }
}
