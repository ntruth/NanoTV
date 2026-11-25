import Foundation

/// 网络资源的图库级存储入口：数据实际写在当前图库的 SQLite 主库
/// （`<library>/database/Luma.sqlite` 的 `catalog_*` 表），不再散落成 json 文件。
///
/// - 进度 / 更新日历 / 列表快照：按行存储，播放与后台补录只写一行。
/// - 其余零散配置（源、关注、片单、光标等）：`catalog_kv` 键值表。
///
/// 旧版本把这些放在 UserDefaults 或 `resources/catalog/*.json`：
/// 首次打开数据库时 JSON 会整体导入并删除，UserDefaults 里的旧键在读取时兜底迁移。
enum CatalogStore {
    // MARK: - 键值

    static func data(forKey key: String) -> Data? {
        if let data = CatalogDatabase.shared.data(forKey: key) { return data }
        guard let legacy = UserDefaults.standard.data(forKey: key) else { return nil }
        CatalogDatabase.shared.set(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    static func set(_ data: Data?, forKey key: String) {
        CatalogDatabase.shared.set(data, forKey: key)
    }

    static func string(forKey key: String) -> String? {
        if let data = CatalogDatabase.shared.data(forKey: key) {
            return String(data: data, encoding: .utf8)
        }
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        CatalogDatabase.shared.set(legacy.data(using: .utf8), forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    static func string(forKey key: String, value: String?) {
        set(value?.data(using: .utf8), forKey: key)
    }

    // MARK: - 播放进度

    static func loadProgress() -> [String: CatalogProgress] {
        CatalogDatabase.shared.loadProgress()
    }

    static func saveProgress(_ record: CatalogProgress) {
        CatalogDatabase.shared.saveProgress(record)
    }

    static func deleteProgress(keys: [String]) {
        CatalogDatabase.shared.deleteProgress(keys: keys)
    }

    static func deleteProgress(sourceID: UUID) {
        CatalogDatabase.shared.deleteProgress(sourceID: sourceID)
    }

    // MARK: - 更新日历

    static func loadCalendar() -> [CatalogCalendarItem] {
        CatalogDatabase.shared.loadCalendar()
    }

    static func insertCalendar(_ items: [CatalogCalendarItem]) {
        CatalogDatabase.shared.insertCalendar(items)
    }

    static func replaceCalendar(_ items: [CatalogCalendarItem]) {
        CatalogDatabase.shared.replaceCalendar(items)
    }

    static func pruneCalendar(limit: Int) {
        CatalogDatabase.shared.pruneCalendar(limit: limit)
    }

    static func deleteCalendar(sourceID: UUID) {
        CatalogDatabase.shared.deleteCalendar(sourceID: sourceID)
    }
}
