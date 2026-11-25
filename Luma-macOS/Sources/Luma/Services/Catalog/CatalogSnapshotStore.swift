import Foundation

/// 列表首屏快照：进入源或分类时先用上次的内容铺满，再在后台请求最新数据。
struct CatalogPageSnapshot: Codable {
    var items: [CatalogItem]
    var page: Int
    var hasMore: Bool
    var savedAt: Date
}

/// 快照存在图库数据库里，一页一行；读取时一次取回内存，LRU 交给 SQL 淘汰。
enum CatalogSnapshotStore {
    /// 快照结构一旦变更就加一：旧行整体丢弃，而不是解码失败后静默空列表。
    private static let schemaVersion = 2
    private static let versionKey = "catalog.snapshots.schema"

    static func load() -> [String: CatalogPageSnapshot] {
        if let raw = CatalogStore.string(forKey: versionKey), let version = Int(raw) {
            guard version == schemaVersion else {
                CatalogDatabase.shared.clearSnapshots()
                CatalogStore.string(forKey: versionKey, value: String(schemaVersion))
                return [:]
            }
            return CatalogDatabase.shared.loadSnapshots()
        }
        // 从旧 JSON 迁移过来的行已经是当前结构。
        CatalogStore.string(forKey: versionKey, value: String(schemaVersion))
        return CatalogDatabase.shared.loadSnapshots()
    }

    static func save(_ snapshot: CatalogPageSnapshot, forKey key: String) {
        CatalogDatabase.shared.saveSnapshot(snapshot, forKey: key)
    }

    static func prune(cutoff: Date, limit: Int) {
        CatalogDatabase.shared.pruneSnapshots(cutoff: cutoff, limit: limit)
    }

    static func remove(prefix: String) {
        CatalogDatabase.shared.deleteSnapshots(prefix: prefix)
    }
}
