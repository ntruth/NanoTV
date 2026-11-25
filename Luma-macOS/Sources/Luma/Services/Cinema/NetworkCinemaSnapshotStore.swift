import Foundation

/// 网络影院的列表快照：与网络资源的 `CatalogSnapshotStore` 同构。
/// 进入页面先用上次内容铺满，再在后台拉最新；按分页（电影 / 剧集 / 最近更新）各存一份。
struct NetworkCinemaListSnapshot: Codable {
    var items: [NetworkCinemaItem]
    var savedAt: Date
    /// 生成快照时的源集合签名：源增删或换源后旧快照自动失效。
    var sourceSignature: String
    /// 同名条目的全部来源：聚合徽标与「切换播放源」靠它，不能只存去重后的列表。
    var variants: [String: [NetworkCinemaItem]]? = nil
}

/// 快照统一落在图库的 `catalog_snapshots` 表里（与网络资源共用一张表、一套淘汰与清理），
/// 不再单独占一层 `catalog_kv` 的 JSON 键。
enum NetworkCinemaSnapshotStore {
    /// 快照结构变更时加一：旧数据整体丢弃，而不是解码失败后静默空列表。
    /// 3：快照附带同名条目的全部来源（聚合徽标 / 切换播放源）。
    private static let schemaVersion = 3
    private static let versionKey = "networkCinema.snapshots.schema"
    /// 单页最多保留的条目：再多的部分是后续刷新覆盖的，占空间没有意义。
    static let itemLimit = 300
    /// 表内键前缀：清理时按这个前缀整段删除。
    private static let keyPrefix = "networkCinema.v2."

    private static func key(_ tab: NetworkCinemaTab) -> String {
        keyPrefix + tab.rawValue
    }

    /// 旧版本把快照写在 `catalog_kv` 里；迁移到快照表后顺手清掉，避免两份缓存并存。
    private static func legacyKey(_ tab: NetworkCinemaTab) -> String {
        "networkCinema.snapshot.v1." + tab.rawValue
    }

    static func load(tab: NetworkCinemaTab) -> NetworkCinemaListSnapshot? {
        migrateIfNeeded()
        guard let data = CatalogDatabase.shared.snapshotData(forKey: key(tab)),
              let snapshot = try? JSONDecoder().decode(NetworkCinemaListSnapshot.self, from: data),
              !snapshot.items.isEmpty else { return nil }
        return snapshot
    }

    static func save(_ snapshot: NetworkCinemaListSnapshot, tab: NetworkCinemaTab) {
        migrateIfNeeded()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        CatalogDatabase.shared.saveSnapshotData(data, savedAt: snapshot.savedAt, forKey: key(tab))
    }

    static func remove(tab: NetworkCinemaTab) {
        CatalogDatabase.shared.deleteSnapshots(prefix: key(tab))
    }

    static func removeAll() {
        CatalogDatabase.shared.deleteSnapshots(prefix: keyPrefix)
    }

    /// 源被移除或换库时清掉快照，避免旧源的条目继续出现。
    static func remove(sourceID: UUID) {
        for tab in NetworkCinemaTab.allCases {
            guard let snapshot = load(tab: tab) else { continue }
            let kept = snapshot.items.filter { $0.source.id != sourceID }
            if kept.isEmpty {
                remove(tab: tab)
            } else if kept.count != snapshot.items.count {
                var updated = snapshot
                updated.items = kept
                // 聚合索引也要同步剔除这个源，否则卡片还会显示已不存在的来源。
                if let variants = updated.variants {
                    var pruned: [String: [NetworkCinemaItem]] = [:]
                    for (key, list) in variants {
                        let remaining = list.filter { $0.source.id != sourceID }
                        if !remaining.isEmpty { pruned[key] = remaining }
                    }
                    updated.variants = pruned
                }
                save(updated, tab: tab)
            }
        }
    }

    private static var didMigrate = false

    private static func migrateIfNeeded() {
        guard !didMigrate else { return }
        didMigrate = true
        let stored = CatalogStore.string(forKey: versionKey).flatMap(Int.init)
        guard stored != schemaVersion else { return }
        removeAll()
        // 清掉旧 KV 键：它们在 catalog_kv 里各自占一整段 JSON。
        for tab in NetworkCinemaTab.allCases {
            CatalogStore.set(nil, forKey: legacyKey(tab))
        }
        CatalogStore.string(forKey: versionKey, value: String(schemaVersion))
    }
}
