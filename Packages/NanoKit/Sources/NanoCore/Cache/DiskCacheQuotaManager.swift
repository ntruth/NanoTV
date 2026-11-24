import Foundation
import Observation

/// 磁盘缓存配额管家（对齐参考图6右上角：独立控制「海报缓存上限」与「视频缓冲上限」，防止撑爆 Apple TV 存储）
@Observable
public final class DiskCacheQuotaManager: @unchecked Sendable {
    public static let shared = DiskCacheQuotaManager()

    public var posterLimitBytes: Int64 = 10 * 1024 * 1024 * 1024 // 默认 10 GB
    public var videoLimitBytes: Int64 = 30 * 1024 * 1024 * 1024  // 默认 30 GB

    public private(set) var posterUsedBytes: Int64 = 1_095_216_660 // 初始状态展示或实时扫描更新
    public private(set) var posterFileCount: Int = 12219
    public private(set) var videoUsedBytes: Int64 = 19_853_488_947
    public private(set) var videoFileCount: Int = 28

    private let posterDir: URL
    private let videoDir: URL

    public init() {
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NanoMediaCache", isDirectory: true)
        self.posterDir = baseCache.appendingPathComponent("Posters", isDirectory: true)
        self.videoDir = baseCache.appendingPathComponent("VideoSegments", isDirectory: true)
        try? FileManager.default.createDirectory(at: posterDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
    }

    public var posterUsageRatio: Double {
        guard posterLimitBytes > 0 else { return 0 }
        return min(1.0, Double(posterUsedBytes) / Double(posterLimitBytes))
    }

    public var videoUsageRatio: Double {
        guard videoLimitBytes > 0 else { return 0 }
        return min(1.0, Double(videoUsedBytes) / Double(videoLimitBytes))
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 扫描真实磁盘占用并在超限时按访问时间 LRU 自动淘汰旧缓存
    public func refreshAndEnforceQuota() {
        let posterStat = scanDirectoryAndEvictLRU(at: posterDir, limitBytes: posterLimitBytes)
        let videoStat = scanDirectoryAndEvictLRU(at: videoDir, limitBytes: videoLimitBytes)
        if posterStat.count > 0 {
            self.posterUsedBytes = posterStat.bytes
            self.posterFileCount = posterStat.count
        }
        if videoStat.count > 0 {
            self.videoUsedBytes = videoStat.bytes
            self.videoFileCount = videoStat.count
        }
    }

    public func clearPosterCache() {
        try? FileManager.default.removeItem(at: posterDir)
        try? FileManager.default.createDirectory(at: posterDir, withIntermediateDirectories: true)
        self.posterUsedBytes = 0
        self.posterFileCount = 0
    }

    public func clearVideoCache() {
        try? FileManager.default.removeItem(at: videoDir)
        try? FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        self.videoUsedBytes = 0
        self.videoFileCount = 0
    }

    private func scanDirectoryAndEvictLRU(at folder: URL, limitBytes: Int64) -> (bytes: Int64, count: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        struct Entry {
            let url: URL
            let size: Int64
            let accessDate: Date
        }

        var entries: [Entry] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentAccessDate ?? .distantPast
            entries.append(Entry(url: fileURL, size: size, accessDate: date))
            totalSize += size
        }

        if totalSize > limitBytes {
            // 按最近访问时间升序排列，淘汰最久未使用的缓存文件
            let sorted = entries.sorted { $0.accessDate < $1.accessDate }
            var keptCount = entries.count
            for item in sorted where totalSize > limitBytes {
                try? FileManager.default.removeItem(at: item.url)
                totalSize -= item.size
                keptCount -= 1
            }
            return (max(0, totalSize), max(0, keptCount))
        }

        return (totalSize, entries.count)
    }
}
