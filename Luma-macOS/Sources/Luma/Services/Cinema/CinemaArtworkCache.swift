import AppKit
import CryptoKit

/// 刮削海报 / 背景图的内存缓存。
/// 统一走 `ArtworkCache`，与电视 Logo、人物头像共用同一套内存层与并发合并。
/// 另外再落一份磁盘缓存：冷启动时海报不必重新下载，也能离线显示。
final class CinemaArtworkCache {
    static let shared = CinemaArtworkCache()

    /// 按 URL 与目标尺寸取图：同一张海报在小卡片和详情页会解出两种尺寸，互不挤占。
    nonisolated func image(for urlString: String, maxPixelSize: Int = 800) async -> NSImage? {
        let key = "cinema:\(urlString)|\(maxPixelSize)"
        let diskURL = Self.diskURL(for: urlString)
        let image = await ArtworkCache.shared.image(for: key,
                                                    diskURL: diskURL,
                                                    maxPixelSize: maxPixelSize) {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            // 豆瓣图片 CDN 会校验 Referer，缺失时直接返回 418。
            if url.host?.contains("douban") == true {
                request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            }
            guard let (data, response) = try? await Self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 0 == 200 else { return nil }
            return data
        }
        // 写入磁盘后顺带检查容量：超过 6 GB 就按最久未用淘汰。
        if image != nil { Self.scheduleDiskTrim() }
        return image
    }

    /// 预取一批海报：低优先级，只写内存 / 磁盘缓存。滚动时提前把下一屏解好，不再追帧。
    nonisolated func prefetch(_ urlStrings: [String], maxPixelSize: Int = 800) {
        guard !urlStrings.isEmpty else { return }
        Task(priority: .utility) {
            for url in urlStrings {
                if Task.isCancelled { return }
                _ = await image(for: url, maxPixelSize: maxPixelSize)
            }
        }
    }

    /// 海报磁盘缓存目录：URL 的 SHA256 前两位分桶，避免单目录堆积过多文件。
    private static let diskRoot = LibraryPaths.applicationRoot
        .appendingPathComponent("resources/artwork-cache", isDirectory: true)

    private static func diskURL(for urlString: String) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskRoot
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(hex + ".img")
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// 磁盘缓存上限：长期只写不删会无限增长，这里按最久未用淘汰到 6 GB 以下。
    private static let diskLimitBytes: Int64 = 6 * 1024 * 1024 * 1024
    private static let trimQueue = DispatchQueue(label: "luma.cinema.artwork.trim", qos: .utility)
    private static let trimLock = NSLock()
    private static var lastTrimAt = Date.distantPast

    /// 设置页「清理海报缓存」：删掉整个磁盘缓存目录，下次按需重新下载。
    nonisolated static func clearDiskCache() {
        trimQueue.async {
            try? FileManager.default.removeItem(at: diskRoot)
        }
    }

    /// 统计磁盘缓存占用（设置页展示用）。
    nonisolated static func diskCacheSize() -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: diskRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// 每 5 分钟最多检查一次，避免每张海报都扫目录。
    private static func scheduleDiskTrim() {
        trimLock.lock()
        let now = Date()
        let shouldTrim = now.timeIntervalSince(lastTrimAt) > 300
        if shouldTrim { lastTrimAt = now }
        trimLock.unlock()
        guard shouldTrim else { return }
        trimQueue.async { trimDiskCache() }
    }

    /// 统计所有缓存文件，超过上限时按修改时间从旧到新删除（近似 LRU）。
    private static func trimDiskCache() {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: diskRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                                 .fileSizeKey,
                                                                 .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > diskLimitBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > diskLimitBytes else { break }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
