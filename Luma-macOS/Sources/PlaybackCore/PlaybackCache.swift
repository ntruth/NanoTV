import Foundation

/// 视频转码 / 边下边播缓存的容量管理。
/// 目录结构：`<root>/<photoID>-<策略签名>.hls/`（分片）与 `<photoID>.mp4`（旧版整片转码，启动时清理）。
/// 策略签名让不同播放策略的缓存互不覆盖；旧版本的无签名 `<photoID>.hls` 不再命中。
/// 超过上限后按最近最少使用淘汰，避免 4K 影片把图库磁盘吃满。
public struct PlaybackCache {
    public let root: URL
    /// 0 表示不限制。由 App 注入（读取用户设置），内核不直接读 UserDefaults。
    private let limitProvider: () -> Int64

    public init(root: URL, limitBytes: @escaping () -> Int64) {
        self.root = root
        self.limitProvider = limitBytes
    }

    public var limitBytes: Int64 {
        max(0, limitProvider())
    }

    public func totalSize() -> Int64 {
        entries().reduce(Int64(0)) { $0 + $1.size }
    }

    public func formattedTotalSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalSize(), countStyle: .file)
    }

    /// 按修改时间从旧到新删除，直到总量回到上限以内。
    /// 留 10% 余量：一次预热 / 一部新片不会立刻又触发清理。
    public func trimIfNeeded() {
        let limit = limitBytes
        guard limit > 0 else { return }
        let target = Int64(Double(limit) * 0.9)
        // 正在播放 / 预热的会话目录不能删，交给 cleanupOrphans 处理。
        // 正在播放的完整缓存目录也不能删：删掉会让 AVPlayer 接下来的分片请求 404。
        let items = entries()
            .filter { !$0.url.lastPathComponent.contains("-session-") }
            .filter { !Self.activity.contains($0.url) }
            .sorted { $0.date < $1.date }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        var index = 0
        while total > target, index < items.count {
            try? FileManager.default.removeItem(at: items[index].url)
            total -= items[index].size
            index += 1
        }
    }

    /// 标记 / 取消标记正在播放的缓存目录：容量清理与手动清空都会跳过它。
    public func markActive(_ url: URL) { Self.activity.mark(url) }
    public func markInactive(_ url: URL) { Self.activity.unmark(url) }

    private static let activity = CacheActivityRegistry()

    /// 启动时清理异常退出留下的会话目录（`*-session-*.hls` 不会成为可复用缓存）。
    /// 同时删掉旧版本遗留的缓存：无策略签名的 `<photoID>.hls` 与整片转码 `<photoID>.mp4`。
    /// 新缓存键不会再命中它们，留着只会占磁盘，容量不设上限时也永远不会被 LRU 淘汰。
    public func cleanupOrphans(maxAge: TimeInterval = 6 * 3600) {
        let now = Date()
        for entry in entries() {
            let name = entry.url.lastPathComponent
            if name.contains("-session-") {
                guard now.timeIntervalSince(entry.date) > maxAge else { continue }
                try? FileManager.default.removeItem(at: entry.url)
            } else if isLegacyCacheName(name) {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
        trimIfNeeded()
    }

    /// 旧缓存条目直接用资源 ID 命名：`<photoID>.hls`（分片）或 `<photoID>.mp4`（整片转码）。
    private func isLegacyCacheName(_ name: String) -> Bool {
        if name.hasSuffix(".hls") {
            return UUID(uuidString: String(name.dropLast(4))) != nil
        }
        if name.hasSuffix(".mp4") {
            return UUID(uuidString: String(name.dropLast(4))) != nil
        }
        return false
    }

    /// 命中缓存时更新修改时间：LRU 按「最后一次播放」而不是「第一次生成」淘汰。
    public func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    public func clear() {
        for entry in entries() where !Self.activity.contains(entry.url) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let date: Date
    }

    private func entries() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return []
        }
        return items.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".hls") || name.hasSuffix(".mp4") else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return Entry(url: url, size: size(of: url), date: date)
        }
    }

    private func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

/// 正在播放的缓存目录集合：容量清理与手动清空都要跳过它们。
private final class CacheActivityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func mark(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        paths.insert(key)
        lock.unlock()
    }

    func unmark(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        paths.remove(key)
        lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(key)
    }
}
