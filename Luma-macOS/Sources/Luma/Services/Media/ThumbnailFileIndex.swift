import Foundation

/// 缩略图文件的轻量索引（路径 → 修改时间）。
///
/// 网格滚动时每个格子原本要做 2～4 次 `fileExists / attributesOfItem`。
/// 在机械盘、外接盘或网络盘上，这些随机 stat 会直接拖慢滚动。
/// 这里在打开图库后后台枚举一次缩略图目录，之后存在性与新旧判断全部走内存；
/// 新写入 / 删除的缩略图会即时更新，未知路径仍会退回一次 stat 并记住结果。
final class ThumbnailFileIndex: @unchecked Sendable {
    static let shared = ThumbnailFileIndex()

    private let lock = NSLock()
    /// 已确认存在的文件：绝对路径 → 修改时间（Unix 秒）。
    private var mtimes: [String: TimeInterval] = [:]
    /// 已确认不存在的路径：避免反复 stat 同一个缺失的缩略图。
    private var missing: Set<String> = []
    /// 已经枚举过的根目录 / 正在枚举的根目录。
    private var warmedRoots: Set<String> = []
    private var warmingRoots: Set<String> = []
    /// 索引上限：超出后不再增加条目，避免超大图库常驻内存过大。
    private let maxEntries = 250_000

    private init() {}

    // MARK: - 查询

    func exists(path: String) -> Bool {
        lock.lock()
        if mtimes[path] != nil {
            lock.unlock()
            return true
        }
        if missing.contains(path) {
            lock.unlock()
            return false
        }
        lock.unlock()

        let date = fileModificationDate(path)
        lock.lock()
        if let date {
            insert(path: path, mtime: date.timeIntervalSince1970)
        } else {
            missing.insert(path)
        }
        lock.unlock()
        return date != nil
    }

    /// 文件修改时间；不存在或读取失败返回 nil。
    func modificationDate(path: String) -> Date? {
        lock.lock()
        if let value = mtimes[path] {
            lock.unlock()
            return Date(timeIntervalSince1970: value)
        }
        if missing.contains(path) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let date = fileModificationDate(path)
        lock.lock()
        if let date {
            insert(path: path, mtime: date.timeIntervalSince1970)
        } else {
            missing.insert(path)
        }
        lock.unlock()
        return date
    }

    // MARK: - 写入 / 删除

    /// 缩略图刚写完时调用：一次 stat 后记录，后续读取不再碰磁盘。
    func recordWrite(url: URL) {
        let path = url.path
        let date = fileModificationDate(path)
        lock.lock()
        if let date {
            insert(path: path, mtime: date.timeIntervalSince1970)
        } else {
            missing.insert(path)
        }
        lock.unlock()
    }

    /// 文件被删除（清理缩略图、永久删除照片）时调用。
    func forget(path: String) {
        lock.lock()
        mtimes.removeValue(forKey: path)
        missing.insert(path)
        lock.unlock()
    }

    // MARK: - 预热

    /// 后台枚举一个缩略图根目录。只索引 JPEG；同一根目录只枚举一次。
    ///
    /// `timeBudget`：外接盘上的系统图库可能有一百多万个 derivative 文件，
    /// 整棵目录树走完要几分钟，期间所有翻页都在抢磁盘；这里只预热一小段时间，
    /// 其余路径仍按需 stat 并把结果记进索引。
    func warm(root: URL, timeBudget: TimeInterval = 1.2) {
        let key = root.path
        guard FileManager.default.fileExists(atPath: key) else { return }
        lock.lock()
        guard !warmedRoots.contains(key), !warmingRoots.contains(key) else {
            lock.unlock()
            return
        }
        warmingRoots.insert(key)
        lock.unlock()

        let limit = maxEntries
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
            let keySet = Set(keys)
            var batch: [String: TimeInterval] = [:]
            batch.reserveCapacity(2_000)
            var total = 0
            let deadline = Date().addingTimeInterval(timeBudget)

            if let enumerator = FileManager.default.enumerator(at: root,
                                                               includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles],
                                                               errorHandler: nil) {
                while let next = enumerator.nextObject() {
                    if Task.isCancelled { break }
                    guard let url = next as? URL else { continue }
                    // 官方图库的 masters 是原图，不是缩略图，没必要进索引。
                    guard !url.path.contains("/masters/") else { continue }
                    let name = url.lastPathComponent.lowercased()
                    guard name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") else { continue }
                    guard let values = try? url.resourceValues(forKeys: keySet),
                          values.isRegularFile == true,
                          let date = values.contentModificationDate else { continue }
                    batch[url.path] = date.timeIntervalSince1970
                    total += 1
                    if batch.count >= 2_000 {
                        self.merge(batch)
                        batch.removeAll(keepingCapacity: true)
                        await Task.yield()
                    }
                    if total >= limit { break }
                    // 每批检查一次时间预算，避免为了预热把磁盘占满。
                    if total % 512 == 0, Date() >= deadline { break }
                }
            }
            if !batch.isEmpty { self.merge(batch) }
            self.finishWarm(key)
        }
    }

    // MARK: - 内部

    private func finishWarm(_ key: String) {
        lock.lock()
        warmingRoots.remove(key)
        warmedRoots.insert(key)
        lock.unlock()
    }

    private func merge(_ batch: [String: TimeInterval]) {
        lock.lock()
        for (path, mtime) in batch {
            insert(path: path, mtime: mtime)
        }
        lock.unlock()
    }

    /// 调用方需持有锁。
    private func insert(path: String, mtime: TimeInterval) {
        guard mtimes.count < maxEntries else { return }
        mtimes[path] = mtime
        missing.remove(path)
    }

    private func fileModificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
