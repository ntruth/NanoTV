import AppKit
import CoreGraphics
import Foundation

/// 「色彩气质」：把人物照片的缩略图缩到极小尺寸求平均色，再挑出彼此差异最大的几档。
/// 只读缩略图、不写数据、不上传；色彩只是观感总结，不作为任何业务判断。
enum PersonPalette {
    struct Swatch: Identifiable {
        let id: Int
        let red: Double
        let green: Double
        let blue: Double
    }

    struct Result {
        var swatches: [Swatch] = []
        var tone: String = ""
        var sampleCount: Int = 0

        var isEmpty: Bool { swatches.isEmpty }
    }

    static func sample(photos: [PhotoItem], limit: Int = 10) -> Result {
        var averages: [(r: Double, g: Double, b: Double)] = []
        for photo in photos.prefix(limit) {
            guard !photo.isVideo,
                  let image = ImageLoader.gridThumbnail(for: photo, maxPixel: 96),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let average = averageColor(cgImage) else { continue }
            averages.append(average)
        }
        guard !averages.isEmpty else { return Result() }

        // 先按色相排序，再挑出与已选项差异足够大的颜色，避免五个色块几乎一样。
        let sorted = averages.sorted {
            hue(red: $0.r, green: $0.g, blue: $0.b) < hue(red: $1.r, green: $1.g, blue: $1.b)
        }
        var picked: [(r: Double, g: Double, b: Double)] = []
        for color in sorted {
            let isDistinct = picked.allSatisfy { distance($0, color) > 0.16 }
            if isDistinct { picked.append(color) }
            if picked.count >= 5 { break }
        }
        if picked.isEmpty { picked = Array(sorted.prefix(3)) }

        let result = Result(swatches: picked.enumerated().map { index, color in
                                Swatch(id: index, red: color.r, green: color.g, blue: color.b)
                            },
                            tone: tone(for: averages),
                            sampleCount: averages.count)
        return result
    }

    // MARK: - 采样

    private static func averageColor(_ image: CGImage) -> (r: Double, g: Double, b: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        var drawn = false
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        pixel.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            drawn = true
        }
        guard drawn else { return nil }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private static func tone(for colors: [(r: Double, g: Double, b: Double)]) -> String {
        guard !colors.isEmpty else { return "" }
        let r = colors.reduce(0) { $0 + $1.r } / Double(colors.count)
        let g = colors.reduce(0) { $0 + $1.g } / Double(colors.count)
        let b = colors.reduce(0) { $0 + $1.b } / Double(colors.count)
        let brightness = 0.299 * r + 0.587 * g + 0.114 * b
        let maxChannel = max(r, g, b)
        let minChannel = min(r, g, b)
        let saturation = maxChannel > 0.001 ? (maxChannel - minChannel) / maxChannel : 0
        let hueValue = hue(red: r, green: g, blue: b)

        if saturation < 0.10 {
            return brightness > 0.68 ? "素净亮调" : "沉静灰调"
        }
        switch hueValue {
        case 0..<0.05, 0.94...1: return "暖红色调"
        case 0.05..<0.16: return "琥珀暖调"
        case 0.16..<0.46: return "自然绿调"
        case 0.46..<0.72: return "清冷蓝调"
        default: return "暮色紫调"
        }
    }

    private static func hue(red: Double, green: Double, blue: Double) -> Double {
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel
        guard delta > 0.0001 else { return 0 }
        let value: Double
        if maxChannel == red {
            value = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxChannel == green {
            value = (blue - red) / delta + 2
        } else {
            value = (red - green) / delta + 4
        }
        let degrees = value * 60
        return (degrees < 0 ? degrees + 360 : degrees) / 360
    }

    private static func distance(_ lhs: (r: Double, g: Double, b: Double),
                                 _ rhs: (r: Double, g: Double, b: Double)) -> Double {
        let dr = lhs.r - rhs.r
        let dg = lhs.g - rhs.g
        let db = lhs.b - rhs.b
        return sqrt(dr * dr + dg * dg + db * db)
    }
}
