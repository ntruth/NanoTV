import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把照片压成长边约 1024 的 JPEG data URL，供支持视觉的模型使用。
/// 只在用户开启「发送压缩图片」时调用；原始 RAW、视频与云端照片不会走这里。
enum AIImageEncoder {
    static func jpegDataURL(for photo: PhotoItem,
                            maxPixel: CGFloat = 1024,
                            quality: CGFloat = 0.72) -> String? {
        guard !photo.isVideo, !photo.isCloud else { return nil }
        guard let image = ImageLoader.thumbnail(for: photo),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxPixel / max(width, height))
        let target = CGSize(width: max(1, (width * scale).rounded()),
                            height: max(1, (height * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: Int(target.width),
                                      height: Int(target.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: target))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, scaled, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }

    /// 从候选照片里挑出可发送的图片：选中优先，跳过视频与云端照片。
    static func dataURLs(for photos: [PhotoItem], limit: Int) -> [(UUID, String)] {
        guard limit > 0 else { return [] }
        var results: [(UUID, String)] = []
        for photo in photos {
            guard results.count < limit else { break }
            guard let url = jpegDataURL(for: photo) else { continue }
            results.append((photo.id, url))
        }
        return results
    }
}
