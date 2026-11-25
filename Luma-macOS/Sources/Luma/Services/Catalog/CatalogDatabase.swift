import Foundation

/// 单个源的海报缓存占用（统计面板用）。
struct CatalogArtworkSummary: Identifiable {
    var sourceID: UUID
    var bytes: Int64
    var files: Int
    var lastUsed: Date?

    var id: UUID { sourceID }
}

/// 网络资源的图库级存储：与拾光主库共用 `<library>/database/Luma.sqlite`。
///
/// 进度、更新日历、列表快照按行保存：播放时只更新一行进度，后台补录只插入一条日历记录，
/// 快照按页存、LRU 用 SQL 淘汰，不再整块重写 JSON。
/// 源列表、关注、片单等零散配置留在 `catalog_kv`，键名沿用 JSON 时期的 key，
/// 首次启动会把 `resources/catalog/*.json` 全量导入后删除。
final class CatalogDatabase {
    static let shared = CatalogDatabase()

    private let lock = NSRecursiveLock()
    private var connection: SQLiteDatabase?
    private var connectionPath: String?

    private init() {}

    // MARK: - 连接

    private func database() -> SQLiteDatabase? {
        let url = LibraryPaths.metadataFile
        lock.lock()
        defer { lock.unlock() }
        if let connection, connectionPath == url.path { return connection }
        connection = nil
        connectionPath = nil
        try? FileManager.default.createDirectory(at: LibraryPaths.databaseDir,
                                                 withIntermediateDirectories: true)
        guard let opened = try? SQLiteDatabase(path: url.path, readonly: false) else {
            Diagnostics.record("网络资源存储：无法打开 \(url.lastPathComponent)")
            return nil
        }
        // 先挂上连接再迁移：迁移过程本身要写表，不能再递归打开一份连接。
        connection = opened
        connectionPath = url.path
        do {
            try createSchema(opened)
            try importLegacyJSONIfNeeded(opened)
            reindexArtworkIfNeeded(opened)
        } catch {
            Diagnostics.record("网络资源存储初始化失败：\(error.localizedDescription)")
        }
        return opened
    }

    private func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS catalog_kv (
                key TEXT PRIMARY KEY,
                value BLOB,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS catalog_progress (
                key TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                item_id TEXT NOT NULL,
                episode INTEGER NOT NULL,
                seconds REAL NOT NULL,
                duration REAL NOT NULL,
                title TEXT NOT NULL,
                cover_url TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_progress_seen ON catalog_progress(updated_at DESC);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_progress_source ON catalog_progress(source_id);")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS catalog_calendar (
                key TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                item_id TEXT NOT NULL,
                first_seen REAL NOT NULL,
                payload BLOB NOT NULL
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_calendar_seen ON catalog_calendar(first_seen);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_calendar_source ON catalog_calendar(source_id);")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS catalog_snapshots (
                page_key TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                saved_at REAL NOT NULL
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_snapshots_saved ON catalog_snapshots(saved_at);")
        // 海报缓存索引：图片仍然以文件保存，这里只记归属、大小与最近使用时间，用于统计和 LRU 淘汰。
        try db.execute("""
            CREATE TABLE IF NOT EXISTS catalog_artwork (
                path TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                last_used REAL NOT NULL
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_artwork_used ON catalog_artwork(last_used);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_catalog_artwork_source ON catalog_artwork(source_id);")
    }

    // MARK: - 键值（零散配置）

    func data(forKey key: String) -> Data? {
        guard let db = database() else { return nil }
        let rows = try? db.query("SELECT value FROM catalog_kv WHERE key = ? LIMIT 1", [key])
        return rows?.first?["value"]?.data
    }

    func set(_ data: Data?, forKey key: String) {
        guard let db = database() else { return }
        guard let data else {
            try? db.execute("DELETE FROM catalog_kv WHERE key = ?", [key])
            return
        }
        try? db.execute("""
            INSERT INTO catalog_kv(key, value, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [key, data, Date().timeIntervalSince1970])
    }

    /// 某个前缀下的键值占用（字节）：影院列表快照 / TMDB 补全这类可再生缓存展示用。
    func keyValueBytes(prefix: String) -> Int64 {
        guard let db = database() else { return 0 }
        let rows = try? db.query("""
            SELECT COALESCE(SUM(LENGTH(value)), 0) AS total FROM catalog_kv WHERE key LIKE ?
            """, [prefix + "%"])
        return Int64(rows?.first?["total"]?.int ?? 0)
    }

    /// 删掉某个前缀下的键值：清理影院列表快照与 TMDB 补全，下次进入重新聚合。
    func clearKeyValues(prefix: String) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_kv WHERE key LIKE ?", [prefix + "%"])
    }

    // MARK: - 播放进度

    func loadProgress() -> [String: CatalogProgress] {
        guard let db = database() else { return [:] }
        var result: [String: CatalogProgress] = [:]
        try? db.forEachRow("""
            SELECT key, source_id, item_id, episode, seconds, duration, title, cover_url, updated_at
            FROM catalog_progress
            """) { row in
            guard let record = Self.progress(from: row) else { return }
            result[record.key] = record
        }
        return result
    }

    func saveProgress(_ record: CatalogProgress) {
        guard let db = database() else { return }
        try? db.execute("""
            INSERT INTO catalog_progress(key, source_id, item_id, episode, seconds, duration, title, cover_url, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                episode = excluded.episode,
                seconds = excluded.seconds,
                duration = excluded.duration,
                title = excluded.title,
                cover_url = excluded.cover_url,
                updated_at = excluded.updated_at
            """,
            [record.key, record.sourceID.uuidString, record.itemID, record.episode,
             record.seconds, record.duration, record.title, record.coverURL,
             record.updatedAt.timeIntervalSince1970])
    }

    func deleteProgress(keys: [String]) {
        guard !keys.isEmpty, let db = database() else { return }
        try? db.executeMany("DELETE FROM catalog_progress WHERE key = ?", rows: keys.map { [$0] })
    }

    func deleteProgress(sourceID: UUID) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_progress WHERE source_id = ?", [sourceID.uuidString])
    }

    private static func progress(from row: [String: SQLiteValue]) -> CatalogProgress? {
        guard let sourceText = row["source_id"]?.string,
              let sourceID = UUID(uuidString: sourceText),
              let itemID = row["item_id"]?.string,
              let episode = row["episode"]?.int,
              let seconds = row["seconds"]?.double,
              let duration = row["duration"]?.double,
              let title = row["title"]?.string,
              let cover = row["cover_url"]?.string,
              let stamp = row["updated_at"]?.double else { return nil }
        return CatalogProgress(sourceID: sourceID, itemID: itemID, episode: episode,
                               seconds: seconds, duration: duration,
                               title: title, coverURL: cover,
                               updatedAt: Date(timeIntervalSince1970: stamp))
    }

    // MARK: - 更新日历

    func loadCalendar() -> [CatalogCalendarItem] {
        guard let db = database() else { return [] }
        let decoder = JSONDecoder()
        var result: [CatalogCalendarItem] = []
        try? db.forEachRow("""
            SELECT payload FROM catalog_calendar ORDER BY first_seen ASC
            """) { row in
            guard let data = row["payload"]?.data,
                  let item = try? decoder.decode(CatalogCalendarItem.self, from: data) else { return }
            result.append(item)
        }
        return result
    }

    /// 新看到的条目：同一条只插一次，站点重复出现不会覆盖已有日期。
    func insertCalendar(_ items: [CatalogCalendarItem]) {
        guard !items.isEmpty, let db = database() else { return }
        let encoder = JSONEncoder()
        let rows: [[Any?]] = items.compactMap { item in
            guard let payload = try? encoder.encode(item) else { return nil }
            return [item.id, item.sourceID.uuidString, item.itemID,
                    item.firstSeen.timeIntervalSince1970, payload]
        }
        guard !rows.isEmpty else { return }
        try? db.transaction {
            try db.executeMany("""
                INSERT OR IGNORE INTO catalog_calendar(key, source_id, item_id, first_seen, payload)
                VALUES(?, ?, ?, ?, ?)
                """, rows: rows)
        }
    }

    /// 整表替换：只用于一次性回填 / 迁移。
    func replaceCalendar(_ items: [CatalogCalendarItem]) {
        guard let db = database() else { return }
        let encoder = JSONEncoder()
        let rows: [[Any?]] = items.compactMap { item in
            guard let payload = try? encoder.encode(item) else { return nil }
            return [item.id, item.sourceID.uuidString, item.itemID,
                    item.firstSeen.timeIntervalSince1970, payload]
        }
        try? db.transaction {
            try db.execute("DELETE FROM catalog_calendar;")
            guard !rows.isEmpty else { return }
            try db.executeMany("""
                INSERT OR REPLACE INTO catalog_calendar(key, source_id, item_id, first_seen, payload)
                VALUES(?, ?, ?, ?, ?)
                """, rows: rows)
        }
    }

    /// 按录入顺序保留最近若干条（rowid 就是插入顺序）。
    func pruneCalendar(limit: Int) {
        guard let db = database() else { return }
        try? db.execute("""
            DELETE FROM catalog_calendar WHERE rowid NOT IN (
                SELECT rowid FROM catalog_calendar ORDER BY rowid DESC LIMIT ?
            )
            """, [limit])
    }

    func deleteCalendar(sourceID: UUID) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_calendar WHERE source_id = ?", [sourceID.uuidString])
    }

    // MARK: - 列表快照

    func loadSnapshots() -> [String: CatalogPageSnapshot] {
        guard let db = database() else { return [:] }
        let decoder = JSONDecoder()
        var result: [String: CatalogPageSnapshot] = [:]
        try? db.forEachRow("SELECT page_key, payload FROM catalog_snapshots") { row in
            guard let key = row["page_key"]?.string,
                  let data = row["payload"]?.data,
                  let snapshot = try? decoder.decode(CatalogPageSnapshot.self, from: data) else { return }
            result[key] = snapshot
        }
        return result
    }

    func saveSnapshot(_ snapshot: CatalogPageSnapshot, forKey key: String) {
        guard let db = database(),
              let payload = try? JSONEncoder().encode(snapshot) else { return }
        saveSnapshotData(payload, savedAt: snapshot.savedAt, forKey: key)
    }

    /// 通用快照写入：网络影院的列表快照也落在这张表里，与资源页共用同一套淘汰与清理。
    func saveSnapshotData(_ payload: Data, savedAt: Date, forKey key: String) {
        guard let db = database() else { return }
        try? db.execute("""
            INSERT INTO catalog_snapshots(page_key, payload, saved_at) VALUES(?, ?, ?)
            ON CONFLICT(page_key) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at
            """, [key, payload, savedAt.timeIntervalSince1970])
    }

    func snapshotData(forKey key: String) -> Data? {
        guard let db = database() else { return nil }
        var result: Data?
        try? db.forEachRow("SELECT payload FROM catalog_snapshots WHERE page_key = ?", [key]) { row in
            result = row["payload"]?.data
        }
        return result
    }

    func deleteSnapshots(prefix: String) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_snapshots WHERE page_key LIKE ?", [prefix + "%"])
    }

    /// 先丢过期快照，再按最近保存保留若干个。
    func pruneSnapshots(cutoff: Date, limit: Int) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_snapshots WHERE saved_at < ?",
                        [cutoff.timeIntervalSince1970])
        try? db.execute("""
            DELETE FROM catalog_snapshots WHERE page_key NOT IN (
                SELECT page_key FROM catalog_snapshots ORDER BY saved_at DESC LIMIT ?
            )
            """, [limit])
    }

    func clearSnapshots() {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_snapshots;")
    }

    // MARK: - 海报缓存索引

    /// 海报文件本身留在磁盘上，这张表只负责「谁占了多少、多久没用」，用于统计与 LRU。
    func recordArtwork(path: String, sourceID: UUID, bytes: Int64) {
        guard let db = database() else { return }
        try? db.execute("""
            INSERT INTO catalog_artwork(path, source_id, bytes, last_used) VALUES(?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET bytes = excluded.bytes, last_used = excluded.last_used
            """, [path, sourceID.uuidString, bytes, Date().timeIntervalSince1970])
    }

    /// 批量刷新最近使用时间：网格滚动时先在内存里攒，隔一段时间合并成一次写入。
    func touchArtwork(paths: [String]) {
        guard !paths.isEmpty, let db = database() else { return }
        let now = Date().timeIntervalSince1970
        try? db.executeMany("UPDATE catalog_artwork SET last_used = ? WHERE path = ?",
                            rows: paths.map { [now, $0] })
    }

    func artworkSummaries() -> [CatalogArtworkSummary] {
        guard let db = database() else { return [] }
        reindexArtworkIfNeeded(db)
        let rows = (try? db.query("""
            SELECT source_id, SUM(bytes) AS bytes, COUNT(*) AS files, MAX(last_used) AS used
            FROM catalog_artwork GROUP BY source_id ORDER BY bytes DESC
            """)) ?? []
        return rows.compactMap { row in
            guard let text = row["source_id"]?.string, let sourceID = UUID(uuidString: text) else {
                return nil
            }
            let used = row["used"]?.double
            return CatalogArtworkSummary(sourceID: sourceID,
                                         bytes: Int64(row["bytes"]?.int64 ?? 0),
                                         files: row["files"]?.int ?? 0,
                                         lastUsed: used.map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// 超出容量时按最久未使用删除文件与索引，降到目标的 90% 以下。
    @discardableResult
    func evictArtwork(targetBytes: Int64) -> Int {
        guard let db = database() else { return 0 }
        reindexArtworkIfNeeded(db)
        let total = Int64(artworkTotalBytes())
        guard total > targetBytes else { return 0 }
        let goal = targetBytes * 9 / 10
        var excess = total - goal
        let rows = (try? db.query("""
            SELECT path, bytes FROM catalog_artwork ORDER BY last_used ASC
            """)) ?? []
        var removed = 0
        for row in rows {
            guard excess > 0, let path = row["path"]?.string else { break }
            let bytes = Int64(row["bytes"]?.int64 ?? 0)
            try? FileManager.default.removeItem(atPath: path)
            try? db.execute("DELETE FROM catalog_artwork WHERE path = ?", [path])
            excess -= bytes
            removed += 1
        }
        return removed
    }

    func artworkTotalBytes() -> Int64 {
        guard let db = database() else { return 0 }
        let rows = try? db.query("SELECT COALESCE(SUM(bytes), 0) AS total FROM catalog_artwork")
        return Int64(rows?.first?["total"]?.int64 ?? 0)
    }

    func deleteArtwork(sourceID: UUID) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_artwork WHERE source_id = ?", [sourceID.uuidString])
    }

    func deleteAllArtwork() {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM catalog_artwork;")
    }

    /// 旧版本只写了图片文件没有索引：首次查询时扫一遍目录补上。
    private func reindexArtworkIfNeeded(_ db: SQLiteDatabase) {
        let count = (try? db.query("SELECT COUNT(*) AS total FROM catalog_artwork"))?
            .first?["total"]?.int ?? 0
        guard count == 0 else { return }
        let fm = FileManager.default
        let root = CatalogPaths.root.appendingPathComponent("artwork", isDirectory: true)
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        var rows: [[Any?]] = []
        let now = Date().timeIntervalSince1970
        for folder in folders {
            guard let sourceID = UUID(uuidString: folder.lastPathComponent) else { continue }
            let files = (try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let used = values?.contentModificationDate?.timeIntervalSince1970 ?? now
                rows.append([file.path, sourceID.uuidString, Int64(values?.fileSize ?? 0), used])
            }
        }
        guard !rows.isEmpty else { return }
        try? db.transaction {
            try db.executeMany("""
                INSERT OR IGNORE INTO catalog_artwork(path, source_id, bytes, last_used)
                VALUES(?, ?, ?, ?)
                """, rows: rows)
        }
    }

    // MARK: - 旧 JSON 迁移

    /// 旧版把每份数据写成一个 json 文件；这里逐个导入后删除文件。
    /// 幂等：中途失败下次继续，表里用 INSERT OR IGNORE / OR REPLACE 兜住重复。
    private func importLegacyJSONIfNeeded(_ db: SQLiteDatabase) throws {
        let marker = "catalog.storage.jsonImported"
        let rows = try db.query("SELECT value FROM catalog_kv WHERE key = ? LIMIT 1", [marker])
        if rows.first?["value"] != nil { return }

        let fm = FileManager.default
        let directory = LibraryPaths.catalogDir
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()

        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file) else { continue }
            switch key {
            case "catalog.progress.v1":
                if let map = try? decoder.decode([String: CatalogProgress].self, from: data) {
                    for record in map.values { saveProgress(record) }
                }
            case "catalog.calendar.v1":
                if let items = try? decoder.decode([CatalogCalendarItem].self, from: data) {
                    replaceCalendar(items)
                }
            case "catalog.listSnapshots.v2":
                if let envelope = try? decoder.decode(LegacySnapshotEnvelope.self, from: data),
                   envelope.version >= 2 {
                    for (pageKey, snapshot) in envelope.snapshots {
                        saveSnapshot(snapshot, forKey: pageKey)
                    }
                }
            case "catalog.listSnapshots.v1":
                break
            default:
                try db.execute("""
                    INSERT INTO catalog_kv(key, value, updated_at) VALUES(?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """, [key, data, Date().timeIntervalSince1970])
            }
            try? fm.removeItem(at: file)
        }

        try db.execute("INSERT OR REPLACE INTO catalog_kv(key, value, updated_at) VALUES(?, ?, ?)",
                       [marker, Data("1".utf8), Date().timeIntervalSince1970])
    }

    private struct LegacySnapshotEnvelope: Decodable {
        var version: Int
        var snapshots: [String: CatalogPageSnapshot]
    }
}
