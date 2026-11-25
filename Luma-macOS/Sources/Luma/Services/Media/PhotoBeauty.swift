import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LumaCore

/// 端侧「智能美化」：把缩略图缩到 256×256 采样亮度、色彩与清晰度，交给 `BeautyAdvisor` 给出调整建议。
/// 只读缩略图、不写任何数据、不上传，因此可以放心地按整库批量分析。
enum PhotoBeauty {
    /// 采样边长：与 `PhotoQuality` 的清晰度评估保持一致，阈值可以直接复用。
    static let sampleSide = 256

    /// 从照片的缩略图（优先快速层）计算美化建议；视频与只读来源返回 nil。
    static func advice(for photo: PhotoItem) -> BeautyAdvice? {
        guard !photo.isVideo, !photo.isCloud, !photo.isSystem else { return nil }
        guard let image = thumbnailImage(for: photo) else { return nil }
        return advice(image: image)
    }

    /// 直接对一张已经解码的图（编辑器里的预览层）给建议。
    static func advice(image: CGImage) -> BeautyAdvice? {
        stats(image: image).map(BeautyAdvisor.advise)
    }

    // MARK: - 采样

    static func stats(image: CGImage) -> BeautyStats? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var drawn = false
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            drawn = true
        }
        guard drawn else { return nil }

        var lumaValues = [Double](repeating: 0, count: side * side)
        var sumLuma = 0.0
        var sumLumaSquares = 0.0
        var sumSaturation = 0.0
        var sumRed = 0.0
        var sumGreen = 0.0
        var sumBlue = 0.0
        var highlightPixels = 0
        var shadowPixels = 0

        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let red = Double(pixels[offset]) / 255
                let green = Double(pixels[offset + 1]) / 255
                let blue = Double(pixels[offset + 2]) / 255
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                lumaValues[y * side + x] = luma

                sumLuma += luma
                sumLumaSquares += luma * luma
                sumRed += red
                sumGreen += green
                sumBlue += blue

                let maxChannel = max(red, green, blue)
                let minChannel = min(red, green, blue)
                if maxChannel > 0.001 {
                    sumSaturation += (maxChannel - minChannel) / maxChannel
                }
                if luma > 0.985 { highlightPixels += 1 }
                if luma < 0.015 { shadowPixels += 1 }
            }
        }

        let count = Double(side * side)
        let mean = sumLuma / count
        let variance = max(0, sumLumaSquares / count - mean * mean)
        return BeautyStats(luma: mean,
                           lumaSpread: sqrt(variance),
                           saturation: sumSaturation / count,
                           red: sumRed / count,
                           green: sumGreen / count,
                           blue: sumBlue / count,
                           highlightClip: Double(highlightPixels) / count,
                           shadowClip: Double(shadowPixels) / count,
                           sharpness: laplacianVariance(lumaValues, side: side))
    }

    /// 与 `PhotoQuality` 相同的 3×3 拉普拉斯方差，只是复用已经采样好的亮度数组。
    private static func laplacianVariance(_ values: [Double], side: Int) -> Double {
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = values[y * side + x] * 255
                let neighbors = values[(y - 1) * side + x]
                    + values[(y + 1) * side + x]
                    + values[y * side + x - 1]
                    + values[y * side + x + 1]
                let value = 4 * center - neighbors * 255
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        return max(0, sumSquares / Double(count) - mean * mean)
    }

    // MARK: - 取缩略图

    private static func thumbnailImage(for photo: PhotoItem) -> CGImage? {
        let manager = FileManager.default
        let quick = LibraryPaths.quickThumbnailURL(for: photo)
        let main = LibraryPaths.thumbnailURL(for: photo)
        var candidates: [URL] = []
        if manager.fileExists(atPath: quick.path) { candidates.append(quick) }
        if manager.fileExists(atPath: main.path) { candidates.append(main) }
        candidates.append(LibraryPaths.sourceURL(for: photo))

        for url in candidates {
            guard manager.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: sampleSide,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return image
            }
        }
        return nil
    }
}
