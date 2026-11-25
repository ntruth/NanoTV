import AppKit
import Foundation
import ImageIO

/// 进程内解码图片的统一内存池：网格缩略图、头像、拖动预览帧、导入预览共用一套回收规则，
/// 不再各自 `NSCache` 一份。只做内存（按像素成本计费），远程图仍走 `ArtworkCache`。
/// 接口刻意与 `NSCache<NSString, NSImage>` 对齐，调用方只换声明、不改用法。
final class MemoryImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    init(totalCostLimit: Int, countLimit: Int = 0) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func object(forKey key: NSString) -> NSImage? {
        cache.object(forKey: key)
    }

    func setObject(_ image: NSImage, forKey key: NSString, cost: Int = 0) {
        cache.setObject(image, forKey: key, cost: cost)
    }

    func removeObject(forKey key: NSString) {
        cache.removeObject(forKey: key)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

/// 统一的远程图片缓存：海报、台标、频道 Logo、直播截帧、人物头像共用一套规则。
///
/// - 内存层：`NSCache`，按 key 复用解码后的 `NSImage`；key 里包含目标尺寸。
/// - 磁盘层：可选 `diskURL`，命中直接读文件；`maxDiskAge` 控制保鲜期，过期后重新拉取，
///   拉取失败时回退到过期文件，离线仍能显示。
/// - 并发合并：同一个 key 同时只发一次请求。
/// - 解码：统一按 `maxPixelSize` 下行采样，避免整张位图常驻内存。
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for key: String,
               diskURL: URL? = nil,
               maxPixelSize: Int? = nil,
               maxDiskAge: TimeInterval? = nil,
               loader: @escaping @Sendable () async -> Data?) async -> NSImage? {
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<NSImage?, Never> {
            var stale: NSImage?
            if let diskURL, let data = try? Data(contentsOf: diskURL) {
                let fresh = maxDiskAge.map { Self.isFresh(diskURL, maxAge: $0) } ?? true
                let image = Self.decode(data, maxPixelSize: maxPixelSize)
                if fresh, let image { return image }
                stale = image
            }
            guard let data = await loader() else { return stale }
            if let diskURL {
                try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: diskURL, options: .atomic)
            }
            return Self.decode(data, maxPixelSize: maxPixelSize) ?? stale
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if let image {
            storeMemory(image, for: key)
        }
        return image
    }

    /// 主动写入：直播截帧等已经拿到 `NSImage` 的场景，直接落盘并放进内存，不再重复编码解码。
    func store(_ image: NSImage,
               for key: String,
               diskURL: URL? = nil,
               maxWidth: CGFloat = 480,
               jpegQuality: CGFloat = 0.72) {
        if let diskURL, let data = Self.jpegData(image, maxWidth: maxWidth, quality: jpegQuality) {
            try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
        }
        storeMemory(image, for: key)
    }

    /// 磁盘文件是否还在保鲜期内：电视预览据此决定要不要重新抓帧。
    func isDiskFresh(_ url: URL, maxAge: TimeInterval) -> Bool {
        Self.isFresh(url, maxAge: maxAge)
    }

    func removeAll() {
        memory.removeAllObjects()
    }

    // MARK: - 磁盘规则

    /// 统计目录占用（目录是平的，按文件累加即可）。
    nonisolated static func diskSize(at directory: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    nonisolated static func clearDisk(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static func isFresh(_ url: URL, maxAge: TimeInterval) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < maxAge
    }

    /// 按宽度缩放后编码 JPEG：台标 / 截帧体积小，适合落盘复用。
    nonisolated static func jpegData(_ image: NSImage,
                                    maxWidth: CGFloat,
                                    quality: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxWidth / CGFloat(max(1, cg.width)))
        let width = max(1, Int(CGFloat(cg.width) * scale))
        let height = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: - 内存与解码

    private func storeMemory(_ image: NSImage, for key: String) {
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// 按显示尺寸下行采样：海报原图常有 1000px 以上，网格里只需要几百像素。
    /// 不采样的话每张卡都要保留整张位图，滚动与内存都会明显变重。
    private static func decode(_ data: Data, maxPixelSize: Int?) -> NSImage? {
        guard let maxPixelSize, maxPixelSize > 0 else { return NSImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
