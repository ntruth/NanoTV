import Foundation
import CoreImage
import CoreGraphics
import SwiftUI

// MARK: - 镜头配置

enum EditLensProfile: String, Codable, CaseIterable, Identifiable {
    case none
    case wide
    case ultraWide
    case fisheye
    case tele

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "关闭"
        case .wide: return "广角"
        case .ultraWide: return "超广角"
        case .fisheye: return "鱼眼"
        case .tele: return "长焦"
        }
    }

    var distortion: Double {
        switch self {
        case .none: return 0
        case .wide: return 0.35
        case .ultraWide: return 0.7
        case .fisheye: return 1
        case .tele: return -0.25
        }
    }

    var vignetteFix: Double {
        switch self {
        case .none: return 0
        case .wide: return 0.3
        case .ultraWide: return 0.5
        case .fisheye: return 0.45
        case .tele: return 0.2
        }
    }

    var hint: String {
        switch self {
        case .none: return "不做镜头校正"
        case .wide: return "修正 24–35mm 的轻微桶形与暗角"
        case .ultraWide: return "修正 14–20mm 的超广角桶形"
        case .fisheye: return "修正鱼眼画面边缘的强烈弯曲"
        case .tele: return "长焦常见的轻微枕形"
        }
    }

    /// 从 EXIF 镜头名粗略推断，只做方向性建议，不当作精确镜头库。
    static func detect(from lens: String?) -> EditLensProfile {
        guard let lens, !lens.isEmpty else { return .none }
        let lower = lens.lowercased()
        if lower.contains("fisheye") || lower.contains("鱼眼") { return .fisheye }
        if lower.contains("超广") { return .ultraWide }
        if lower.contains("广角") { return .wide }
        if lower.contains("长焦") || lower.contains("tele") { return .tele }
        var digits = ""
        var numbers: [Int] = []
        for character in lens {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                if let value = Int(digits) { numbers.append(value) }
                digits = ""
            }
        }
        if !digits.isEmpty, let value = Int(digits) { numbers.append(value) }
        guard let focal = numbers.first else { return .none }
        if focal <= 16 { return .ultraWide }
        if focal <= 28 { return .wide }
        if focal >= 70 { return .tele }
        return .none
    }
}

// MARK: - 范围蒙版

enum EditRangeMask {
    static let dimension = 16

    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]

    static func mask(for mask: EditMask, from image: CIImage, extent: CGRect) -> CIImage? {
        guard let data = data(for: mask) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
            "inputColorSpace": space
        ]).cropped(to: extent)
    }

    private static func data(for mask: EditMask) -> Data? {
        let key = String(format: "%@|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f",
                         mask.kind.rawValue,
                         mask.rangeHue, mask.rangeWidth, mask.rangeSaturationMin,
                         mask.lumaMin, mask.lumaMax, mask.lumaFeather)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let built = build(mask)
        lock.lock()
        cache[key] = built
        if cache.count > 8 { cache.removeAll() }
        lock.unlock()
        return built
    }

    private static func build(_ mask: EditMask) -> Data {
        let dimension = Self.dimension
        let isColor = mask.kind == .colorRange
        let centerHue = mask.rangeHue * 360
        let width = max(1, mask.rangeWidth * 360)
        let satMin = min(0.95, max(0, mask.rangeSaturationMin))
        let lumaMin = min(mask.lumaMin, mask.lumaMax)
        let lumaMax = max(mask.lumaMin, mask.lumaMax)
        let feather = max(0.005, mask.lumaFeather)

        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blueStep in 0..<dimension {
            let blue = Double(blueStep) / Double(dimension - 1)
            for greenStep in 0..<dimension {
                let green = Double(greenStep) / Double(dimension - 1)
                for redStep in 0..<dimension {
                    let red = Double(redStep) / Double(dimension - 1)
                    let weight: Double
                    if isColor {
                        let hsl = EditColorCube.rgbToHSL(red, green, blue)
                        var distance = abs(hsl.0 - centerHue)
                        distance = min(distance, 360 - distance)
                        let hueWeight = 1 - smoothstep(0, width, distance)
                        let saturationWeight = smoothstep(satMin, satMin + 0.15, hsl.1)
                        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                        let lumaWeight = smoothstep(0.02, 0.08, luma)
                            * (1 - smoothstep(0.9, 0.99, luma))
                        weight = hueWeight * saturationWeight * lumaWeight
                    } else {
                        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                        let low = smoothstep(lumaMin - feather, lumaMin + feather, luma)
                        let high = 1 - smoothstep(lumaMax - feather, lumaMax + feather, luma)
                        weight = low * high
                    }
                    let value = Float(min(1, max(0, weight)))
                    values.append(contentsOf: [value, value, value, 1])
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - 画笔蒙版

enum EditBrushMask {
    private static let lock = NSLock()
    private static var cache: [String: CIImage] = [:]

    static func image(mask: EditMask, extent: CGRect) -> CIImage? {
        guard !mask.brushDabs.isEmpty, extent.width > 1, extent.height > 1 else { return nil }
        let maxSide = 1024.0
        let scale = min(1, maxSide / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale))
        let height = max(1, Int(extent.height * scale))

        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(mask.brushDabs.count)
        for dab in mask.brushDabs {
            hasher.combine(Int(dab.x * 4096))
            hasher.combine(Int(dab.y * 4096))
            hasher.combine(Int(dab.radius * 4096))
            hasher.combine(Int(dab.softness * 100))
            hasher.combine(dab.erase)
        }
        let key = String(hasher.finalize())
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for dab in mask.brushDabs {
            let radius = max(1, CGFloat(dab.radius) * CGFloat(min(width, height)))
            let center = CGPoint(x: CGFloat(dab.x) * CGFloat(width),
                                 y: (1 - CGFloat(dab.y)) * CGFloat(height))
            let inner = max(0, min(0.98, 1 - CGFloat(dab.softness)))
            let base: CGColor = dab.erase
                ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            guard let gradient = CGGradient(colorsSpace: colorSpace,
                                            colors: [base, base.copy(alpha: 0)!] as CFArray,
                                            locations: [inner, 1]) else { continue }
            context.drawRadialGradient(gradient,
                                       startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius,
                                       options: [])
        }

        guard let cgImage = context.makeImage() else { return nil }
        var image = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                               y: extent.height / CGFloat(height)))
        image = image.transformed(by: CGAffineTransform(translationX: extent.minX,
                                                        y: extent.minY))
            .cropped(to: extent)

        lock.lock()
        cache[key] = image
        if cache.count > 6 { cache.removeAll() }
        lock.unlock()
        return image
    }
}

// MARK: - 镜头暗角校正

extension PhotoRenderer {
    /// 提亮四角，抵消广角镜头的自然暗角。
    static func applyLensVignetteFix(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, amount > 0.001 else { return image }
        let minDimension = min(extent.width, extent.height)
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: extent.midX, y: extent.midY),
            "inputRadius0": minDimension * 0.3,
            "inputRadius1": maxDimension(extent) * 0.72,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ])?.outputImage?.cropped(to: extent) else { return image }
        let screened = gradient.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])
        let alpha = CGFloat(min(0.7, max(0, amount * 0.5)))
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha))
            .cropped(to: extent)
        return screened.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ])
    }

    private static func maxDimension(_ extent: CGRect) -> CGFloat {
        max(extent.width, extent.height)
    }
}

// MARK: - 场景推荐

struct SceneRecommendation: Identifiable, Equatable {
    var id: String { presetID }
    let scene: String
    let presetID: String
    let reason: String
}

enum ScenePresetAdvisor {
    static func recommend(from sample: EditSampleImage) -> [SceneRecommendation] {
        let bytes = sample.bytes
        guard sample.width > 4, sample.height > 4, bytes.count >= 16 else { return [] }
        var lumaSum = 0.0
        var lumaSquare = 0.0
        var saturationSum = 0.0
        var warm = 0
        var greenish = 0
        var bluish = 0
        var skin = 0
        var count = 0

        for index in stride(from: 0, to: bytes.count - 3, by: 4) {
            let red = Double(bytes[index]) / 255
            let green = Double(bytes[index + 1]) / 255
            let blue = Double(bytes[index + 2]) / 255
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let maximum = max(red, max(green, blue))
            let minimum = min(red, min(green, blue))
            let saturation = maximum > 0.001 ? (maximum - minimum) / maximum : 0

            lumaSum += luma
            lumaSquare += luma * luma
            saturationSum += saturation
            if red > green + 0.04 && green > blue + 0.02 && saturation > 0.12 { warm += 1 }
            if green > red + 0.03 && green > blue + 0.02 { greenish += 1 }
            if blue > red + 0.04 && blue > green + 0.02 { bluish += 1 }
            if red > green && green > blue && saturation > 0.14
                && red - blue > 0.1 && luma > 0.22 && luma < 0.9 { skin += 1 }
            count += 1
        }

        guard count > 0 else { return [] }
        let brightness = lumaSum / Double(count)
        let saturation = saturationSum / Double(count)
        _ = lumaSquare
        let warmRatio = Double(warm) / Double(count)
        let greenRatio = Double(greenish) / Double(count)
        let blueRatio = Double(bluish) / Double(count)
        let skinRatio = Double(skin) / Double(count)

        if skinRatio > 0.1 && brightness > 0.28 {
            return [
                SceneRecommendation(scene: "人像", presetID: "builtin.cream",
                                    reason: "检测到较多肤色，奶油风格更柔和，不会把皮肤推得发红"),
                SceneRecommendation(scene: "人像", presetID: "builtin.clear",
                                    reason: "如果想保持通透，清透风格保留肤色亮度")
            ]
        }
        if brightness < 0.24 {
            return [
                SceneRecommendation(scene: "夜景", presetID: "builtin.citycool",
                                    reason: "画面偏暗，冷调都市能压住噪点感并保留霓虹层次"),
                SceneRecommendation(scene: "夜景", presetID: "builtin.cinematic",
                                    reason: "电影青橙让灯光与阴影更容易分开")
            ]
        }
        if greenRatio + blueRatio > 0.5 {
            return [
                SceneRecommendation(scene: "风光", presetID: "builtin.airy",
                                    reason: "大面积绿色与蓝色，日系青能拉开天空和植被"),
                SceneRecommendation(scene: "风光", presetID: "builtin.clear",
                                    reason: "清透适合保留自然色彩，不做重风格化")
            ]
        }
        if warmRatio > 0.42 && saturation > 0.28 {
            return [
                SceneRecommendation(scene: "美食/暖光", presetID: "builtin.warmfilm",
                                    reason: "暖色占比高，暖调胶片能强化食欲感与质感"),
                SceneRecommendation(scene: "美食/暖光", presetID: "builtin.cream",
                                    reason: "奶油风格让人造光更柔和")
            ]
        }
        return [
            SceneRecommendation(scene: "通用", presetID: "builtin.clear",
                                reason: "没有明显场景特征，清透是最稳妥的起点"),
            SceneRecommendation(scene: "通用", presetID: "builtin.faded",
                                reason: "如果想要更松弛的回忆感，可以试褪色记忆")
        ]
    }
}
