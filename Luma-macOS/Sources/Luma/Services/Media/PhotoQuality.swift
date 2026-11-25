import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 照片质量评估：用缩略图计算拉普拉斯方差来估计清晰度，不读取原图。
enum PhotoQuality {
    /// 低于该值视为「可能模糊」（256px 灰度拉普拉斯方差，实测清晰照片通常 > 100）。
    static let blurryThreshold: Double = 55

    /// 清晰度分数；视频返回 nil。网盘照片请先用缩略图解码再调用 `sharpness(cgImage:)`。
    static func sharpness(for photo: PhotoItem) -> Double? {
        guard !photo.isVideo, !photo.isCloud, !photo.isSystem else { return nil }
        let fm = FileManager.default
        let quick = LibraryPaths.quickThumbnailURL(for: photo)
        let main = LibraryPaths.thumbnailURL(for: photo)
        let url = fm.fileExists(atPath: quick.path) ? quick : main
        guard fm.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return laplacianVariance(image, side: 256)
    }

    /// 对已解码的图像（网盘缩略图）计算清晰度。
    static func sharpness(cgImage: CGImage) -> Double? {
        laplacianVariance(cgImage, side: 256)
    }

    /// 把图像缩到 `side` 见方灰度后计算 3×3 拉普拉斯的方差。
    private static func laplacianVariance(_ image: CGImage, side: Int) -> Double? {
        var buffer = [UInt8](repeating: 0, count: side * side)
        var drawn = false
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            drawn = true
        }
        guard drawn else { return nil }

        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = Double(buffer[y * side + x])
                let value = -(Double(buffer[(y - 1) * side + x])
                              + Double(buffer[(y + 1) * side + x])
                              + Double(buffer[y * side + x - 1])
                              + Double(buffer[y * side + x + 1])) + 4 * center
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        return max(0, sumSquares / Double(count) - mean * mean)
    }
}
