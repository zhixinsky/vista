// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import ImageIO
import CoreImage

enum WallpaperRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let leftEdgeKernel = CIKernel(source: """
        kernel vec4 blendLeft(sampler image, float width, float range, float brightness,
                              float saturation, float curve) {
            vec4 source = sample(image, samplerCoord(image));
            float x = max(0.0, (destCoord().x - 0.5) / max(width - 1.0, 1.0));
            if (x >= range) { return source; }
            float weight = pow(1.0 - smoothstep(0.0, range, x), curve);
            vec4 pixel = unpremultiply(source);
            vec3 rgb = pixel.rgb * (1.0 + brightness * weight);
            float gray = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            rgb = vec3(gray) + (rgb - vec3(gray)) * (1.0 + saturation * weight);
            return premultiply(vec4(rgb, pixel.a));
        }
        """)
    private static let maskKernel = CIKernel(source: """
        kernel vec4 compensate(sampler image, float width, float opacity, float strength,
                               float gradient, float protect) {
            vec4 pixel = unpremultiply(sample(image, samplerCoord(image)));
            float x = clamp((destCoord().x - 0.5) / max(width - 1.0, 1.0), 0.0, 1.0);
            float offset = x < 0.5 ? mix(0.04, 0.0, x * 2.0) : mix(0.0, -0.05, (x - 0.5) * 2.0);
            float alpha = clamp(opacity + gradient * offset * min(1.0, opacity * 5.0), 0.0, 0.5);
            float gain = mix(1.0, 1.0 / (1.0 - alpha), strength);
            vec3 rgb = pixel.rgb * gain;
            if (protect > 0.5) {
                float peak = max(max(pixel.r, pixel.g), pixel.b);
                float knee = 0.72;
                float start = knee / gain;
                if (peak > start) {
                    float t = clamp((peak - start) / (1.0 - start), 0.0, 1.0);
                    float slope = gain * (1.0 - start) / (1.0 - knee);
                    float safePeak = knee + (1.0 - knee) * t * slope / (1.0 + t * (slope - 1.0));
                    rgb = pixel.rgb * (safePeak / max(peak, 0.0001));
                }
            }
            return premultiply(vec4(rgb, pixel.a));
        }
        """)
    private static let advancedKernel = CIKernel(source: """
        kernel vec4 advancedSeam(sampler image, sampler lut, float width, float range, float curve,
                                 float local, float protect, float black, float white, float gamma,
                                 float gainR, float gainG, float gainB, float offR, float offG, float offB,
                                 float useCurves) {
            vec4 source = sample(image, samplerCoord(image));
            float x = max(0.0, (destCoord().x - 0.5) / max(width - 1.0, 1.0));
            if (local > 0.5 && x >= range) { return source; }
            float weight = local > 0.5 ? pow(1.0 - smoothstep(0.0, range, x), curve) : 1.0;
            if (weight <= 0.0001) { return source; }
            vec4 pixel = unpremultiply(source);
            float span = max(white - black, 0.0001);
            vec3 rgb = (pixel.rgb - vec3(black)) / vec3(span);
            rgb = pow(max(rgb, vec3(0.0)), vec3(max(gamma, 0.05)));
            rgb = rgb * vec3(gainR, gainG, gainB) + vec3(offR, offG, offB);
            float inR = rgb.r;
            float inG = rgb.g;
            float inB = rgb.b;
            vec4 masterR = sample(lut, samplerTransform(lut, vec2(clamp(inR, 0.0, 1.0) * 255.0 + 0.5, 0.5)));
            vec4 masterG = sample(lut, samplerTransform(lut, vec2(clamp(inG, 0.0, 1.0) * 255.0 + 0.5, 0.5)));
            vec4 masterB = sample(lut, samplerTransform(lut, vec2(clamp(inB, 0.0, 1.0) * 255.0 + 0.5, 0.5)));
            float mr = masterR.r;
            float mg = masterG.r;
            float mb = masterB.r;
            if (inR > 1.0) mr += inR - 1.0;
            if (inR < 0.0) mr += inR;
            if (inG > 1.0) mg += inG - 1.0;
            if (inG < 0.0) mg += inG;
            if (inB > 1.0) mb += inB - 1.0;
            if (inB < 0.0) mb += inB;
            vec4 toneR = sample(lut, samplerTransform(lut, vec2(clamp(mr, 0.0, 1.0) * 255.0 + 0.5, 0.5)));
            vec4 toneG = sample(lut, samplerTransform(lut, vec2(clamp(mg, 0.0, 1.0) * 255.0 + 0.5, 0.5)));
            vec4 toneB = sample(lut, samplerTransform(lut, vec2(clamp(mb, 0.0, 1.0) * 255.0 + 0.5, 0.5)));
            float rr = toneR.g;
            float gg = toneG.b;
            float bb = toneB.a;
            if (mr > 1.0) rr += mr - 1.0;
            if (mr < 0.0) rr += mr;
            if (mg > 1.0) gg += mg - 1.0;
            if (mg < 0.0) gg += mg;
            if (mb > 1.0) bb += mb - 1.0;
            if (mb < 0.0) bb += mb;
            if (useCurves > 0.5) rgb = vec3(rr, gg, bb);
            if (protect > 0.5) {
                float peak = max(rgb.r, max(rgb.g, rgb.b));
                float knee = 0.78;
                if (peak > knee) {
                    float over = peak - knee;
                    float safePeak = knee + (1.0 - knee) * over / (over + 0.35);
                    rgb *= safePeak / max(peak, 0.0001);
                }
            }
            vec3 mixed = mix(clamp(pixel.rgb, vec3(0.0), vec3(1.0)), clamp(rgb, vec3(0.0), vec3(1.0)), weight);
            return premultiply(vec4(mixed, pixel.a));
        }
        """)
    static func format() -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; f.preferredRange = .standard
        return f
    }
    static func pixelSize(_ url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }),
              width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
    static func load(_ url: URL, maximum: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximum),
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return UIImage(cgImage: cg)
    }
    static func transformed(_ image: UIImage, adjustment: WallpaperAdjustment) -> UIImage {
        let turns = ((adjustment.turns % 4) + 4) % 4
        guard turns != 0 || adjustment.flipX || adjustment.flipY else { return image }
        let size = turns % 2 == 0 ? image.size : CGSize(width: image.size.height, height: image.size.width)
        return UIGraphicsImageRenderer(size: size, format: format()).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            let c = renderer.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: adjustment.flipX ? -1 : 1, y: adjustment.flipY ? -1 : 1)
            c.rotate(by: CGFloat(turns) * .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
    static func render(url: URL, preset: WallpaperPreset, size: CGSize, adjustment: WallpaperAdjustment) throws -> UIImage {
        if let crop = adjustment.pixelCrop {
            let pixels = try pixelSize(url)
            guard crop.fits(pixels) else { throw CocoaError(.fileReadCorruptFile) }
            let original = try load(url, maximum: Int(max(pixels.width, pixels.height)))
            guard original.size == pixels, let result = original.cgImage?.cropping(to: crop.rect) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try colorCorrect(UIImage(cgImage: result), adjustment: adjustment.color)
        }
        let pixels = preset.preservesSourceSize ? try pixelSize(url) : size
        let maximum = Int(ceil(max(pixels.width, pixels.height) * (preset.crops ? max(1, min(4, adjustment.zoom)) : 1)))
        let image = try load(url, maximum: maximum)
        let rendered = try render(image: image, preset: preset, size: preset.preservesSourceSize ? image.size : size, adjustment: adjustment)
        return try colorCorrect(rendered, adjustment: adjustment.color)
    }

    static func colorCorrect(_ image: UIImage, adjustment: WallpaperColorAdjustment?) throws -> UIImage {
        guard let adjustment, adjustment != .init() else { return image }
        guard let cg = image.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let input = CIImage(cgImage: cg)
        var output = input
        if let mask = adjustment.mask, mask.opacity > 0, (mask.strength ?? 1) > 0 {
            guard let corrected = maskKernel?.apply(extent: input.extent, roiCallback: { _, rect in rect }, arguments: [
                input, input.extent.width, min(0.50, mask.opacity), min(1.50, mask.strength ?? 1),
                mask.horizontalGradient == true ? 1.0 : 0.0, mask.protectHighlights == false ? 0.0 : 1.0
            ]) else { throw CocoaError(.fileWriteUnknown) }
            output = corrected
        }
        if let exposure = adjustment.exposure, exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
        }
        if (adjustment.highlights ?? 0) != 0 || (adjustment.shadows ?? 0) != 0 {
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + (adjustment.highlights ?? 0),
                "inputShadowAmount": adjustment.shadows ?? 0
            ])
        }
        if let temperature = adjustment.temperature, temperature != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 + temperature), y: 0)
            ])
        }
        if let gamma = adjustment.gamma, gamma != 1 {
            output = output.applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma])
        }
        if adjustment.brightness != 0 || adjustment.contrast != 1 || adjustment.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustment.brightness,
                kCIInputContrastKey: adjustment.contrast,
                kCIInputSaturationKey: adjustment.saturation
            ])
        }
        if let edge = adjustment.leftEdge, edge.width > 0, edge.brightness != 0 || edge.saturation != 0 {
            guard let blended = leftEdgeKernel?.apply(
                extent: input.extent, roiCallback: { _, rect in rect }, arguments: [
                    output, input.extent.width, min(0.5, edge.width),
                    max(-0.5, min(1, edge.brightness)), max(-0.5, min(1, edge.saturation)),
                    max(0.75, min(3, edge.curve))
                ]
            ) else { throw CocoaError(.fileWriteUnknown) }
            output = blended
        }
        if let grade = adjustment.leftEdge?.advanced, grade.needsBlend {
            let width = min(0.5, max(0, adjustment.leftEdge?.width ?? 0))
            if !(grade.local && width <= 0) {
                let levels = grade.levelInputs
                let useCurves = !WallpaperAdvancedGrade.linear(grade.master) || !WallpaperAdvancedGrade.linear(grade.red)
                    || !WallpaperAdvancedGrade.linear(grade.green) || !WallpaperAdvancedGrade.linear(grade.blue)
                guard let lut = curveLUT(grade),
                      let graded = advancedKernel?.apply(
                        extent: input.extent,
                        roiCallback: { index, rect in index == 0 ? rect : CGRect(x: 0, y: 0, width: 256, height: 1) },
                        arguments: [
                            output, lut, input.extent.width, grade.local ? width : 1, max(0.75, min(3, adjustment.leftEdge?.curve ?? 1)),
                            grade.local ? 1.0 : 0.0, grade.protectHighlights ? 1.0 : 0.0,
                            levels.black, levels.white, min(4, max(0.05, levels.gamma)),
                            min(2.5, max(0.25, grade.gainRed)), min(2.5, max(0.25, grade.gainGreen)), min(2.5, max(0.25, grade.gainBlue)),
                            min(0.5, max(-0.5, grade.offsetRed)), min(0.5, max(-0.5, grade.offsetGreen)), min(0.5, max(-0.5, grade.offsetBlue)),
                            useCurves ? 1.0 : 0.0
                        ]
                      ) else { throw CocoaError(.fileWriteUnknown) }
                output = graded
            }
        }
        guard let result = context.createCGImage(output, from: input.extent) else { throw CocoaError(.fileWriteUnknown) }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }
    static func render(image: UIImage, preset: WallpaperPreset, size: CGSize, adjustment: WallpaperAdjustment = .init()) throws -> UIImage {
        let source = transformed(image, adjustment: adjustment)
        let canvas = preset.preservesSourceSize ? source.size : size
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { throw CocoaError(.fileWriteUnknown) }
        if preset.preservesSourceSize {
            return UIGraphicsImageRenderer(size: canvas, format: format()).image { _ in
                source.draw(in: CGRect(origin: .zero, size: canvas))
            }
        }
        let bounds = CGRect(origin: .zero, size: canvas)
        if preset.crops {
            return UIGraphicsImageRenderer(size: canvas, format: format()).image { c in
                UIColor.white.setFill(); c.fill(bounds)
                source.draw(in: CropGeometry.rect(source: source.size, target: canvas, zoom: adjustment.zoom, x: adjustment.x, y: adjustment.y))
            }
        }
        let background = UIGraphicsImageRenderer(size: canvas, format: format()).image { c in
            UIColor.white.setFill(); c.fill(bounds)
            source.draw(in: CropGeometry.rect(source: source.size, target: canvas, zoom: 1, x: 0.5, y: 0.5))
        }
        guard let cg = background.cgImage else { throw CocoaError(.fileWriteUnknown) }
        // Clamp before blurring, then crop: Gaussian blur cannot introduce transparent/black edges.
        let blurred = CIImage(cgImage: cg).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(canvas.width, canvas.height) * 0.025])
            .cropped(to: bounds)
        guard let blurredCG = context.createCGImage(blurred, from: bounds) else { throw CocoaError(.fileWriteUnknown) }
        return UIGraphicsImageRenderer(size: canvas, format: format()).image { _ in
            UIImage(cgImage: blurredCG).draw(in: bounds)
            source.draw(in: CropGeometry.fit(source: source.size, target: canvas))
        }
    }

    static func histogram(_ image: UIImage, leftFraction: Double) -> WallpaperHistogram {
        let bins = WallpaperHistogram.bins
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return .empty }
        let fraction = min(1, max(0.02, leftFraction))
        let columns = max(1, Int((Double(cg.width) * fraction).rounded(.up)))
        let height = cg.height
        let bytesPerRow = columns * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base, width: columns, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: height))
            return true
        }
        guard drawn else { return .empty }
        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)
        let stepX = max(1, columns / 240)
        let stepY = max(1, height / 240)
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < columns {
                let offset = (y * columns + x) * 4
                let alpha = Int(pixels[offset + 3])
                if alpha > 8 {
                    let scale = 255.0 / Double(alpha)
                    func bin(_ byte: UInt8) -> Int {
                        min(bins - 1, Int(min(1, Double(byte) * scale / 255) * Double(bins)))
                    }
                    red[bin(pixels[offset])] += 1
                    green[bin(pixels[offset + 1])] += 1
                    blue[bin(pixels[offset + 2])] += 1
                    count += 1
                }
                x += stepX
            }
            y += stepY
        }
        guard count > 0 else { return .empty }
        func normalize(_ values: [Int]) -> [Float] {
            let peak = Float(max(1, values.max() ?? 1))
            return values.map { Float($0) / peak }
        }
        return WallpaperHistogram(red: normalize(red), green: normalize(green), blue: normalize(blue))
    }

    private static func evaluateCurve(_ points: [WallpaperCurvePoint], at x: Double) -> Double {
        let ordered = WallpaperAdvancedGrade.ordered(points)
        if x <= ordered[0].x { return ordered[0].y }
        if x >= ordered[ordered.count - 1].x { return ordered[ordered.count - 1].y }
        for index in 1..<ordered.count where x <= ordered[index].x {
            let left = ordered[index - 1]
            let right = ordered[index]
            let span = right.x - left.x
            let t = span <= 0.0001 ? 0 : (x - left.x) / span
            return min(1, max(0, left.y + (right.y - left.y) * t))
        }
        return ordered[ordered.count - 1].y
    }

    private static func curveLUT(_ grade: WallpaperAdvancedGrade) -> CIImage? {
        let count = 256
        var samples = [Float](repeating: 0, count: count * 4)
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            samples[index * 4] = Float(evaluateCurve(grade.master, at: x))
            samples[index * 4 + 1] = Float(evaluateCurve(grade.red, at: x))
            samples[index * 4 + 2] = Float(evaluateCurve(grade.green, at: x))
            samples[index * 4 + 3] = Float(evaluateCurve(grade.blue, at: x))
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: count * MemoryLayout<Float>.size * 4,
            size: CGSize(width: count, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
    }
}

struct WallpaperHistogram: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    static let bins = 64
    static let empty = WallpaperHistogram(
        red: Array(repeating: 0, count: bins),
        green: Array(repeating: 0, count: bins),
        blue: Array(repeating: 0, count: bins)
    )
}
