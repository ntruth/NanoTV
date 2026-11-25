import Foundation

/// 一页内容的本地快照：新源接入后先铺上次内容，再后台刷新。
/// 与具体存储无关，文件 / 数据库实现都只读写这个结构。
public struct ContentPageSnapshot: Codable, Hashable, Sendable {
    public var sourceID: SourceID
    public var containerID: String?
    public var search: String?
    public var page: ContentPage
    public var savedAt: Date

    public init(sourceID: SourceID,
                containerID: String? = nil,
                search: String? = nil,
                page: ContentPage,
                savedAt: Date = Date()) {
        self.sourceID = sourceID
        self.containerID = containerID
        self.search = search
        self.page = page
        self.savedAt = savedAt
    }

    public var key: String {
        Self.key(sourceID: sourceID, containerID: containerID, search: search)
    }

    public static func key(sourceID: SourceID,
                           containerID: String?,
                           search: String?) -> String {
        let keyword = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(sourceID.rawValue)|\(containerID ?? "-")|\(keyword)"
    }

    public func isStale(olderThan seconds: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(savedAt) > seconds
    }
}

/// 快照存储：同步读写，调用方（源会话 / 列表模型）负责决定什么时候铺、什么时候刷新。
public protocol ContentSnapshotStoring: AnyObject {
    func snapshot(sourceID: SourceID, containerID: String?, search: String?) -> ContentPageSnapshot?
    func save(_ snapshot: ContentPageSnapshot)
    func removeAll(sourceID: SourceID)
    /// 先按时间淘汰，再按数量保留最近的快照。
    @discardableResult
    func prune(olderThan seconds: TimeInterval, keeping limit: Int) -> Int
}

/// 文件实现：一个 JSON 文件保存全部源的分页快照。
/// 目录由 App 注入（按图库 / 按用户隔离），Core 不关心具体路径。
public final class FileContentSnapshotStore: ContentSnapshotStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var snapshots: [String: ContentPageSnapshot]

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("snapshots.json", isDirectory: false)
        snapshots = Self.load(from: fileURL)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count
    }

    public func snapshot(sourceID: SourceID,
                         containerID: String?,
                         search: String?) -> ContentPageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[ContentPageSnapshot.key(sourceID: sourceID,
                                                 containerID: containerID,
                                                 search: search)]
    }

    public func save(_ snapshot: ContentPageSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[snapshot.key] = snapshot
        persistLocked()
    }

    public func removeAll(sourceID: SourceID) {
        lock.lock()
        defer { lock.unlock() }
        snapshots = snapshots.filter { $0.value.sourceID != sourceID }
        persistLocked()
    }

    @discardableResult
    public func prune(olderThan seconds: TimeInterval, keeping limit: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = snapshots.count
        let now = Date()
        snapshots = snapshots.filter { !$0.value.isStale(olderThan: seconds, now: now) }
        if snapshots.count > max(0, limit) {
            let kept = snapshots.values
                .sorted { $0.savedAt > $1.savedAt }
                .prefix(max(0, limit))
            snapshots = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
        }
        let removed = before - snapshots.count
        if removed > 0 { persistLocked() }
        return removed
    }

    // MARK: - 落盘

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 快照只是「先铺旧内容」的优化，写失败不影响主流程。
        }
    }

    private static func load(from url: URL) -> [String: ContentPageSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ContentPageSnapshot].self, from: data)
        else { return [:] }
        return decoded
    }
}
