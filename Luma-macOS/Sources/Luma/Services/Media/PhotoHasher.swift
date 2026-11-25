import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import LumaCore

/// 文件内容哈希 + 图像感知哈希。
/// SHA-256 用于导入时精确查重；dHash 用于发现重压缩 / 缩放 / 轻微编辑的相似副本。
enum PhotoHasher {
    struct Result {
        let sha256: String?
        let perceptualHash: Int64?
    }

    static func hashes(for url: URL, includePerceptual: Bool = true) -> Result {
        let sha = try? sha256(of: url)
        let perceptual = includePerceptual && !VideoFormats.isVideo(url) ? dHash(for: url) : nil
        return Result(sha256: sha, perceptualHash: perceptual)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func dHash(for url: URL) -> Int64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: PerceptualHash.width * PerceptualHash.height)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels,
                                      width: PerceptualHash.width,
                                      height: PerceptualHash.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: PerceptualHash.width,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: PerceptualHash.width,
                                       height: PerceptualHash.height))
        return PerceptualHash.dHash(grayscale: pixels)
    }
}
