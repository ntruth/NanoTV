import Foundation
import LumaContentCore

/// 网络电视的持久化：源、频道缓存、开关与当前焦点都写进当前图库的
/// `resources/tv/Television.sqlite`，不再把整块 JSON 写进 UserDefaults。
///
/// 源顺序就是表里的 `position`，侧边栏拖动后只重写这一张表；
/// 频道按源替换写入，刷新或连接检测成功后立即落盘，下次启动可以先用缓存首屏。
final class TVDatabase {
    static let shared = TVDatabase()

    private let lock = NSRecursiveLock()
    private var connection: SQLiteDatabase?
    private var connectionPath: String?

    private init() {}

    // MARK: - 连接与建表

    /// 打开当前图库的电视库；切图库后路径变化会自动换连接。
    private func database() -> SQLiteDatabase? {
        let url = LibraryPaths.tvDatabaseFile
        lock.lock()
        defer { lock.unlock() }
        if let connection, connectionPath == url.path { return connection }
        connection = nil
        connectionPath = nil
        try? FileManager.default.createDirectory(at: LibraryPaths.tvDir,
                                                 withIntermediateDirectories: true)
        guard let opened = try? SQLiteDatabase(path: url.path, readonly: false) else {
            Diagnostics.record("网络电视存储：无法打开 \(url.lastPathComponent)")
            return nil
        }
        connection = opened
        connectionPath = url.path
        do {
            try createSchema(opened)
            // 旧库升级：按省份聚合需要给频道补一列，已有数据读出来仍可按城市名重新归类。
            ensureColumn(opened, table: "tv_channels", column: "province", definition: "TEXT")
            // EPG / 回看相关字段：旧库没有时补列，读出来为 NULL，不影响使用。
            ensureColumn(opened, table: "tv_playlists", column: "epg_url", definition: "TEXT")
            ensureColumn(opened, table: "tv_channels", column: "tvg_id", definition: "TEXT")
            ensureColumn(opened, table: "tv_channels", column: "catchup_source", definition: "TEXT")
            ensureColumn(opened, table: "tv_channels", column: "catchup_days", definition: "INTEGER")
            ensureColumn(opened, table: "tv_channels", column: "alt_stream_urls", definition: "TEXT")
        } catch {
            Diagnostics.record("网络电视存储初始化失败：\(error.localizedDescription)")
        }
        return opened
    }

    private func ensureColumn(_ db: SQLiteDatabase,
                              table: String,
                              column: String,
                              definition: String) {
        let columns = (try? db.query("PRAGMA table_info(\(table));")) ?? []
        guard !columns.contains(where: { $0["name"]?.string == column }) else { return }
        try? db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS tv_playlists (
                id TEXT PRIMARY KEY,
                position INTEGER NOT NULL,
                name TEXT NOT NULL,
                url TEXT NOT NULL,
                region TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                built_in INTEGER NOT NULL,
                last_checked_at REAL,
                last_latency_ms INTEGER,
                last_channel_count INTEGER,
                last_error TEXT,
                epg_url TEXT
            );
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS tv_channels (
                id TEXT PRIMARY KEY,
                playlist_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                name TEXT NOT NULL,
                group_title TEXT NOT NULL,
                logo_url TEXT,
                stream_url TEXT NOT NULL,
                headers_json TEXT,
                is_hls INTEGER NOT NULL,
                quality TEXT,
                region TEXT NOT NULL,
                province TEXT,
                tvg_id TEXT,
                catchup_source TEXT,
                catchup_days INTEGER,
                alt_stream_urls TEXT
            );
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_tv_channels_source ON tv_channels(playlist_id, position);")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS tv_settings (
                key TEXT PRIMARY KEY,
                value TEXT,
                updated_at REAL NOT NULL
            );
            """)
    }

    /// 首次使用时把旧版 UserDefaults 里的源列表搬进 SQLite。
    /// 只在表为空时执行一次，之后以数据库为准。
    private func migrateLegacyPlaylistsIfNeeded(_ db: SQLiteDatabase) {
        let existing = (try? db.query("SELECT COUNT(*) AS count FROM tv_playlists;"))?
            .first?["count"]?.int ?? 0
        guard existing == 0 else { return }

        var migrated: [TVPlaylist] = []
        if let data = UserDefaults.standard.data(forKey: "luma.tv.playlists"),
           let saved = try? JSONDecoder().decode([TVPlaylist].self, from: data),
           !saved.isEmpty {
            migrated = saved
        }
        // 没有历史记录时保持空列表：电视源默认一个都不接入。
        writePlaylists(migrated, to: db)

        // 开关、分页、更新时间一并搬过来，避免升级后状态归零。
        let defaults = UserDefaults.standard
        if let enabled = defaults.object(forKey: "luma.tv.enabled") as? Bool {
            writeSetting(enabled ? "1" : "0", key: "enabled", to: db)
        }
        if let refreshedAt = defaults.object(forKey: "luma.tv.refreshedAt") as? Date {
            writeSetting(String(refreshedAt.timeIntervalSince1970), key: "refreshedAt", to: db)
        }
        if let tab = defaults.string(forKey: "luma.tv.hubTab.v1") {
            writeSetting(tab, key: "hubTab", to: db)
        }
    }

    // MARK: - 源

    func loadPlaylists() -> [TVPlaylist] {
        guard let db = database() else { return [] }
        migrateLegacyPlaylistsIfNeeded(db)
        let rows = (try? db.query("""
            SELECT * FROM tv_playlists ORDER BY position ASC;
            """)) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
                  let name = row["name"]?.string,
                  let url = row["url"]?.string,
                  let region = row["region"]?.string.flatMap(TVRegion.init(rawValue:)) else {
                return nil
            }
            var playlist = TVPlaylist(id: id,
                                      name: name,
                                      urlString: url,
                                      region: region,
                                      isEnabled: row["enabled"]?.bool ?? true)
            playlist.lastCheckedAt = row["last_checked_at"]?.double.map(Date.init(timeIntervalSince1970:))
            playlist.lastLatencyMilliseconds = row["last_latency_ms"]?.int
            playlist.lastChannelCount = row["last_channel_count"]?.int
            playlist.lastError = row["last_error"]?.string
            playlist.epgURLString = row["epg_url"]?.string
            return playlist
        }
    }

    func savePlaylists(_ playlists: [TVPlaylist]) {
        guard let db = database() else { return }
        writePlaylists(playlists, to: db)
    }

    private func writePlaylists(_ playlists: [TVPlaylist], to db: SQLiteDatabase) {
        let rows: [[Any?]] = playlists.enumerated().map { index, playlist in
            [
                playlist.id.uuidString,
                index,
                playlist.name,
                playlist.urlString,
                playlist.region.rawValue,
                playlist.isEnabled,
                false,
                playlist.lastCheckedAt?.timeIntervalSince1970,
                playlist.lastLatencyMilliseconds,
                playlist.lastChannelCount,
                playlist.lastError,
                playlist.epgURLString
            ]
        }
        do {
            try db.transaction {
                try db.execute("DELETE FROM tv_playlists;")
                try db.executeMany("""
                    INSERT INTO tv_playlists
                    (id, position, name, url, region, enabled, built_in,
                     last_checked_at, last_latency_ms, last_channel_count, last_error, epg_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, rows: rows)
            }
        } catch {
            Diagnostics.record("网络电视源保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 频道缓存

    func loadChannels(for playlistID: UUID) -> [TVChannel] {
        guard let db = database() else { return [] }
        let rows = (try? db.query("""
            SELECT * FROM tv_channels WHERE playlist_id = ? ORDER BY position ASC;
            """, [playlistID.uuidString])) ?? []
        return rows.compactMap { row in
            guard let id = row["id"]?.string,
                  let name = row["name"]?.string,
                  let group = row["group_title"]?.string,
                  let stream = row["stream_url"]?.string,
                  let region = row["region"]?.string.flatMap(TVRegion.init(rawValue:)) else {
                return nil
            }
            var headers: [String: String] = [:]
            if let raw = row["headers_json"]?.string, let data = raw.data(using: .utf8) {
                headers = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            }
            var alternates: [String] = []
            if let raw = row["alt_stream_urls"]?.string, let data = raw.data(using: .utf8) {
                alternates = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            }
            return TVChannel(id: id,
                             name: name,
                             group: group,
                             logoURL: row["logo_url"]?.string,
                             streamURL: stream,
                             headers: headers,
                             isHLS: row["is_hls"]?.bool ?? true,
                             qualityLabel: row["quality"]?.string,
                             playlistID: playlistID,
                             region: region,
                             // 旧库还没写 province 时按城市名补一次，避免出现「其他」。
                             province: row["province"]?.string
                                 ?? (region == .mainland ? TVProvinces.province(for: name) : nil),
                             tvgID: row["tvg_id"]?.string,
                             catchUpSource: row["catchup_source"]?.string,
                             catchUpDays: row["catchup_days"]?.int,
                             lineCount: max(1, 1 + alternates.count),
                             alternateStreamURLs: alternates)
        }
    }

    /// 整源替换：刷新成功后一次性写入，旧线路全部作废。
    func replaceChannels(_ channels: [TVChannel], for playlistID: UUID) {
        guard let db = database() else { return }
        let rows: [[Any?]] = channels.enumerated().map { index, channel in
            let headersJSON = (try? JSONEncoder().encode(channel.headers))
                .flatMap { String(data: $0, encoding: .utf8) }
            let alternatesJSON = (try? JSONEncoder().encode(channel.alternateStreamURLs))
                .flatMap { String(data: $0, encoding: .utf8) }
            return [
                channel.id,
                playlistID.uuidString,
                index,
                channel.name,
                channel.group,
                channel.logoURL,
                channel.streamURL,
                headersJSON,
                channel.isHLS,
                channel.qualityLabel,
                channel.region.rawValue,
                channel.province,
                channel.tvgID,
                channel.catchUpSource,
                channel.catchUpDays,
                alternatesJSON
            ]
        }
        do {
            try db.transaction {
                try db.execute("DELETE FROM tv_channels WHERE playlist_id = ?;", [playlistID.uuidString])
                try db.executeMany("""
                    INSERT INTO tv_channels
                    (id, playlist_id, position, name, group_title, logo_url,
                     stream_url, headers_json, is_hls, quality, region, province,
                     tvg_id, catchup_source, catchup_days, alt_stream_urls)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, rows: rows)
            }
        } catch {
            Diagnostics.record("网络电视频道缓存写入失败：\(error.localizedDescription)")
        }
    }

    func deleteChannels(for playlistID: UUID) {
        guard let db = database() else { return }
        try? db.execute("DELETE FROM tv_channels WHERE playlist_id = ?;", [playlistID.uuidString])
    }

    // MARK: - 设置

    func setting(_ key: String) -> String? {
        guard let db = database() else { return nil }
        return (try? db.query("SELECT value FROM tv_settings WHERE key = ?;", [key]))?
            .first?["value"]?.string
    }

    func setSetting(_ key: String, _ value: String?) {
        guard let db = database() else { return }
        if let value {
            writeSetting(value, key: key, to: db)
        } else {
            try? db.execute("DELETE FROM tv_settings WHERE key = ?;", [key])
        }
    }

    private func writeSetting(_ value: String, key: String, to db: SQLiteDatabase) {
        try? db.execute("""
            INSERT INTO tv_settings (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
            """, [key, value, Date().timeIntervalSince1970])
    }
}
