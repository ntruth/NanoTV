import AppKit
import Foundation
import ImageIO

/// 海报缓存：下载 → 解密 → 解码 → 落盘两级缩略图。
/// 与网盘缩略图一致，网格滚动只读本地文件，不在主线程做解密或大图解码。
actor CatalogArtworkCache {
    static let shared = CatalogArtworkCache()

    /// 海报缓存上限：图片留在磁盘，索引在数据库里；超出后按最久未使用删到 90%。
    /// 上限在设置里可调，这里每次都读最新值。
    static var maxDiskBytes: Int64 {
        Int64(max(1, AppSettings.shared.posterCacheLimitGB)) * 1_000_000_000
    }

    /// 用户调小上限后立即按最久未使用淘汰一次。
    static func trimToLimit() {
        CatalogDatabase.shared.evictArtwork(targetBytes: maxDiskBytes)
    }
    private static let gate = CloudConcurrencyGate(limit: 4)
    private var failures: [String: Date] = [:]
    private var running: [String: Task<NSImage?, Never>] = [:]
    /// 读取命中先攒着，滚动时不要把每一格都变成一次 UPDATE。
    private var pendingTouches: Set<String> = []
    private var lastTouchFlush = Date.distantPast

    func image(source: CatalogSource, urlString: String, quick: Bool) async -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        let cacheURL = CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: quick)
        if let image = NSImage(contentsOf: cacheURL) {
            markUsed(cacheURL.path)
            return image
        }

        let key = cacheURL.path
        if let failedAt = failures[key], Date().timeIntervalSince(failedAt) < 60 { return nil }
        if let task = running[key] { return await task.value }

        let sourceID = source.id
        let task = Task<NSImage?, Never> {
            await Self.gate.acquire()
            defer { Task { await Self.gate.release() } }

            guard let data = try? await CatalogProviders.provider(for: source.kind)?
                .coverData(source: source, urlString: urlString),
                  let cgImage = Self.decode(data) else { return nil }

            let full = CatalogPaths.artworkURL(sourceID: sourceID, urlString: urlString, quick: false)
            let quickURL = CatalogPaths.artworkURL(sourceID: sourceID, urlString: urlString, quick: true)
            try? FileManager.default.createDirectory(at: full.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            ImportService.writeJPEG(cgImage, to: full, quality: 0.9)
            if let small = ImageTransform.downscale(cgImage, maxPixel: 320) {
                ImportService.writeJPEG(small, to: quickURL, quality: 0.78)
            }
            Self.index(path: full.path, sourceID: sourceID)
            Self.index(path: quickURL.path, sourceID: sourceID)
            CatalogDatabase.shared.evictArtwork(targetBytes: Self.maxDiskBytes)
            return NSImage(contentsOf: quick ? quickURL : full)
        }
        running[key] = task

        let image = await task.value
        running[key] = nil
        if image == nil {
            failures[key] = Date()
        } else {
            failures[key] = nil
        }
        return image
    }

    func clear(sourceID: UUID?) {
        let directory = sourceID.map { CatalogPaths.artwork(scriptSourceID: $0) } ?? CatalogPaths.root
        try? FileManager.default.removeItem(at: directory)
        if let sourceID {
            CatalogDatabase.shared.deleteArtwork(sourceID: sourceID)
        } else {
            CatalogDatabase.shared.deleteAllArtwork()
        }
        pendingTouches.removeAll()
        failures.removeAll()
    }

    /// 最近使用时间合并写入：30 秒或攒够 32 条刷新一次。
    private func markUsed(_ path: String) {
        pendingTouches.insert(path)
        guard pendingTouches.count >= 32
                || Date().timeIntervalSince(lastTouchFlush) > 30 else { return }
        flushTouches()
    }

    private func flushTouches() {
        guard !pendingTouches.isEmpty else { return }
        CatalogDatabase.shared.touchArtwork(paths: Array(pendingTouches))
        pendingTouches.removeAll()
        lastTouchFlush = Date()
    }

    private static func index(path: String, sourceID: UUID) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        CatalogDatabase.shared.recordArtwork(path: path, sourceID: sourceID, bytes: bytes)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
