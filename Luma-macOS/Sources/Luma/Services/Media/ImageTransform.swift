import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 非破坏性旋转与带旋转的导出。
enum ImageTransform {
    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let angle = ((degrees % 360) + 360) % 360
        guard angle != 0 else { return image }
        let radians = CGFloat(angle) * .pi / 180
        let width = image.width
        let height = image.height
        let rotatedWidth = angle == 90 || angle == 270 ? height : width
        let rotatedHeight = angle == 90 || angle == 270 ? width : height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: rotatedWidth,
                                      height: rotatedHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.translateBy(x: CGFloat(rotatedWidth) / 2, y: CGFloat(rotatedHeight) / 2)
        context.rotate(by: radians)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 等比缩小到长边不超过 `maxPixel`（用于生成网格快速层缩略图）。
    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard maxPixel > 0, longest > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 读取当前显示文件（含编辑渲染），校正 EXIF 方向后再应用用户旋转。
    static func uprightImage(for photo: PhotoItem, maxPixel: CGFloat? = nil) -> CGImage? {
        let sourceURL = LibraryPaths.sourceURL(for: photo)
        if !photo.hasEdits, RawFormats.isRaw(sourceURL),
           let decoded = RawFormats.decode(url: sourceURL, maxPixel: maxPixel) {
            return rotate(decoded, degrees: photo.rotationAngle) ?? decoded
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        var maxSide = max(width, height)

        if let maxPixel {
            maxSide = min(maxSide > 0 ? maxSide : Int(maxPixel), Int(maxPixel))
        } else if maxSide <= 0 {
            maxSide = 12000
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if maxSide > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxSide
        }
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return rotate(upright, degrees: photo.rotationAngle) ?? upright
    }

    static func export(photo: PhotoItem, to url: URL) throws {
        if photo.rotationAngle == 0 {
            let source = LibraryPaths.exportURL(for: photo)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
            return
        }
        guard let image = uprightImage(for: photo) else {
            throw NSError(domain: "ImageTransform", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法渲染旋转后的照片"])
        }
        let ext = url.pathExtension.lowercased()
        let type: UTType
        switch ext {
        case "png": type = .png
        case "heic", "heif": type = .heic
        case "tif", "tiff": type = .tiff
        default: type = .jpeg
        }
        try write(image, to: url, type: type)
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.95) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                               type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ImageTransform", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入图片"])
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageTransform", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "图片写入失败"])
        }
    }
}
