import Foundation

/// 网盘索引：把扫描结果存成普通的 SQLite 表（目录表 + 媒体表 + 状态表），
/// 目录数量 / 封面在媒体表上聚合，打开网盘时不再解析整份 JSON 快照。
///
/// 设计目标与系统「照片」的 `Photos.sqlite` 一致：
/// - `cloud_index_folders` 只存目录结构与聚合计数（media_count / video_count / cover_path）；
/// - `cloud_index_assets` 存每条媒体的轻量字段，按 (mount_id, folder_path, captured_at) 建索引；
/// - `cloud_index_state` 记录这轮扫描是否完整、接入范围签名、保存时间。
///
/// 真实文件内容不落库；EXIF / 识别结果仍在 `cloud_assets` 里按需回填。
extension MetadataStore {
    // MARK: - 结构

    struct CloudIndexState {
        var folderCount: Int
        var mediaCount: Int
        var truncated: Bool
        var complete: Bool
        var pathVersion: Int
        var scopeSignature: String
        var updatedAt: Date
    }

    struct CloudIndexFolderRow {
        var path: String
        var name: String
        var parentPath: String
        var modifiedAt: Date?
        var mediaCount: Int
        var videoCount: Int
        var coverRecord: CloudScanRecord?
    }

    func migrateCloudIndexSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS cloud_index_folders (
                mount_id TEXT NOT NULL,
                path TEXT NOT NULL,
                parent_path TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL,
                modified_at REAL,
                media_count INTEGER NOT NULL DEFAULT 0,
                video_count INTEGER NOT NULL DEFAULT 0,
                cover_path TEXT,
                updated_at REAL NOT NULL,
                seen_generation INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (mount_id, path)
            );
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_cloud_index_folders_parent
            ON cloud_index_folders(mount_id, parent_path);
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS cloud_index_assets (
                mount_id TEXT NOT NULL,
                path TEXT NOT NULL,
                folder_path TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                modified_at REAL,
                width INTEGER,
                height INTEGER,
                duration REAL,
                is_video INTEGER NOT NULL DEFAULT 0,
                thumbnail_url TEXT,
                remote_id TEXT,
                codec TEXT,
                captured_at REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                seen_generation INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (mount_id, path)
            );
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_cloud_index_assets_folder
            ON cloud_index_assets(mount_id, folder_path, captured_at DESC, path);
            """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_cloud_index_assets_captured
            ON cloud_index_assets(mount_id, captured_at DESC, path);
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS cloud_index_state (
                mount_id TEXT PRIMARY KEY NOT NULL,
                folder_count INTEGER NOT NULL DEFAULT 0,
                media_count INTEGER NOT NULL DEFAULT 0,
                truncated INTEGER NOT NULL DEFAULT 0,
                complete INTEGER NOT NULL DEFAULT 0,
                path_version INTEGER NOT NULL DEFAULT 0,
                scope_signature TEXT NOT NULL DEFAULT '',
                updated_at REAL NOT NULL
            );
            """)
        // 旧表补列（IF NOT EXISTS 不会给已存在的表加新列）。
        for table in ["cloud_index_folders", "cloud_index_assets"] {
            let columns = (try? db.query("PRAGMA table_info(\(table))"))?
                .compactMap { $0["name"]?.string } ?? []
            if !columns.contains("seen_generation") {
                try? db.execute("ALTER TABLE \(table) ADD COLUMN seen_generation INTEGER NOT NULL DEFAULT 0;")
            }
        }
    }

    // MARK: - 扫描代次

    /// 开始一轮扫描：返回本轮代次。
    /// - Parameter keepExisting: 增量扫描要把未重新回调的旧行也标记为「本轮见过」，否则会被误删。
    func beginCloudIndexScan(mountID: UUID, keepExisting: Bool) -> Int64 {
        let generation = Int64(Date().timeIntervalSince1970 * 1000)
        guard keepExisting else { return generation }
        queue.sync {
            try? db.execute("UPDATE cloud_index_folders SET seen_generation = ? WHERE mount_id = ?",
                            [generation, mountID.uuidString])
            try? db.execute("UPDATE cloud_index_assets SET seen_generation = ? WHERE mount_id = ?",
                            [generation, mountID.uuidString])
        }
        return generation
    }

    /// 完整扫完后删掉本轮没见到的旧行；增量 / 中断的扫描不调用。
    func pruneCloudIndex(mountID: UUID, generation: Int64) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("DELETE FROM cloud_index_assets WHERE mount_id = ? AND seen_generation <> ?",
                                 [mountID.uuidString, generation])
            try? self.db.execute("DELETE FROM cloud_index_folders WHERE mount_id = ? AND seen_generation <> ?",
                                 [mountID.uuidString, generation])
        }
    }

    // MARK: - 状态

    func loadCloudIndexState(mountID: UUID) -> CloudIndexState? {
        queue.sync {
            guard let row = (try? db.query("SELECT * FROM cloud_index_state WHERE mount_id = ?",
                                           [mountID.uuidString]))?.first else { return nil }
            return CloudIndexState(folderCount: row["folder_count"]?.int ?? 0,
                                   mediaCount: row["media_count"]?.int ?? 0,
                                   truncated: (row["truncated"]?.int ?? 0) != 0,
                                   complete: (row["complete"]?.int ?? 0) != 0,
                                   pathVersion: row["path_version"]?.int ?? 0,
                                   scopeSignature: row["scope_signature"]?.string ?? "",
                                   updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
    }

    /// 扫描结束：重算聚合列并落状态。全部在同一个串行队列里完成，回调在主线程。
    func finalizeCloudIndex(mountID: UUID,
                            state: CloudIndexState,
                            completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                try self.recomputeAggregatesLocked(mountID: mountID)
                try self.db.execute("""
                    INSERT OR REPLACE INTO cloud_index_state
                    (mount_id, folder_count, media_count, truncated, complete,
                     path_version, scope_signature, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        mountID.uuidString,
                        state.folderCount,
                        state.mediaCount,
                        state.truncated,
                        state.complete,
                        state.pathVersion,
                        state.scopeSignature,
                        state.updatedAt.timeIntervalSince1970
                    ])
            }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func recomputeAggregatesLocked(mountID: UUID) throws {
        try db.execute("""
            UPDATE cloud_index_folders AS f
            SET media_count = (
                    SELECT COUNT(*) FROM cloud_index_assets a
                    WHERE a.mount_id = f.mount_id AND a.folder_path = f.path
                ),
                video_count = (
                    SELECT COUNT(*) FROM cloud_index_assets a
                    WHERE a.mount_id = f.mount_id AND a.folder_path = f.path AND a.is_video = 1
                ),
                cover_path = (
                    SELECT a.path FROM cloud_index_assets a
                    WHERE a.mount_id = f.mount_id AND a.folder_path = f.path
                    ORDER BY a.captured_at DESC, a.path DESC
                    LIMIT 1
                ),
                updated_at = ?
            WHERE f.mount_id = ?
            """, [Date().timeIntervalSince1970, mountID.uuidString])
    }

    // MARK: - 写入

    /// 扫描过程中按批 upsert：目录与媒体分开写，预编译语句只准备一次。
    func saveCloudIndexBatch(mountID: UUID,
                             generation: Int64,
                             folders: [CloudScanFolder],
                             assets: [CloudScanRecord]) {
        guard !folders.isEmpty || !assets.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let folderRows: [[Any?]] = folders.map {
            [mountID.uuidString, $0.path, $0.parentPath, $0.name,
             $0.modifiedAt?.timeIntervalSince1970, now, generation]
        }
        let assetRows: [[Any?]] = assets.map { record in
            let captured = (record.capturedAt ?? record.modifiedAt ?? record.addedAt ?? Date.distantPast)
                .timeIntervalSince1970
            return [mountID.uuidString,
                    record.path,
                    record.folderPath ?? "",
                    record.name,
                    record.size,
                    record.modifiedAt?.timeIntervalSince1970,
                    record.width,
                    record.height,
                    record.duration,
                    record.isVideo,
                    record.thumbnailURL,
                    record.remoteID,
                    record.codec,
                    captured,
                    now,
                    generation]
        }
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                if !folderRows.isEmpty {
                    try self.db.executeMany("""
                        INSERT INTO cloud_index_folders
                        (mount_id, path, parent_path, name, modified_at, updated_at, seen_generation)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(mount_id, path) DO UPDATE SET
                            parent_path = excluded.parent_path,
                            name = excluded.name,
                            modified_at = excluded.modified_at,
                            updated_at = excluded.updated_at,
                            seen_generation = excluded.seen_generation
                        """, rows: folderRows)
                }
                if !assetRows.isEmpty {
                    try self.db.executeMany("""
                        INSERT INTO cloud_index_assets
                        (mount_id, path, folder_path, name, size, modified_at, width, height,
                         duration, is_video, thumbnail_url, remote_id, codec, captured_at, updated_at,
                         seen_generation)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(mount_id, path) DO UPDATE SET
                            folder_path = excluded.folder_path,
                            name = excluded.name,
                            size = excluded.size,
                            modified_at = excluded.modified_at,
                            width = COALESCE(excluded.width, cloud_index_assets.width),
                            height = COALESCE(excluded.height, cloud_index_assets.height),
                            duration = COALESCE(excluded.duration, cloud_index_assets.duration),
                            is_video = excluded.is_video,
                            thumbnail_url = COALESCE(excluded.thumbnail_url, cloud_index_assets.thumbnail_url),
                            remote_id = COALESCE(excluded.remote_id, cloud_index_assets.remote_id),
                            codec = COALESCE(excluded.codec, cloud_index_assets.codec),
                            -- 远端文件没变时保留 EXIF 拍摄时间；文件被替换（mtime 变了）才回退到新的修改时间。
                            captured_at = CASE
                                WHEN cloud_index_assets.modified_at IS NOT NULL
                                 AND excluded.modified_at IS NOT NULL
                                 AND cloud_index_assets.modified_at = excluded.modified_at
                                 AND cloud_index_assets.captured_at <> cloud_index_assets.modified_at
                                THEN cloud_index_assets.captured_at
                                ELSE excluded.captured_at
                            END,
                            updated_at = excluded.updated_at,
                            seen_generation = excluded.seen_generation
                        """, rows: assetRows)
                }
            }
        }
    }

    /// EXIF 读到拍摄时间 / 尺寸后回写索引，下次打开时间轴仍然正确。
    func updateCloudIndexAsset(mountID: UUID,
                               path: String,
                               capturedAt: Date?,
                               width: Int?,
                               height: Int?) {
        guard capturedAt != nil || width != nil || height != nil else { return }
        queue.async { [weak self] in
            try? self?.db.execute("""
                UPDATE cloud_index_assets
                SET captured_at = COALESCE(?, captured_at),
                    width = COALESCE(?, width),
                    height = COALESCE(?, height),
                    updated_at = ?
                WHERE mount_id = ? AND path = ?
                """, [capturedAt?.timeIntervalSince1970,
                      width,
                      height,
                      Date().timeIntervalSince1970,
                      mountID.uuidString,
                      path])
        }
    }

    func deleteCloudIndexAssets(mountID: UUID, paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                for path in paths {
                    try self.db.execute("DELETE FROM cloud_index_assets WHERE mount_id = ? AND path = ?",
                                        [mountID.uuidString, path])
                }
            }
        }
    }

    func deleteCloudIndexFolders(mountID: UUID, paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                for path in paths {
                    let prefix = Self.escapedLikePrefix(path + "/")
                    try self.db.execute("""
                        DELETE FROM cloud_index_folders
                        WHERE mount_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')
                        """, [mountID.uuidString, path, prefix])
                    try self.db.execute("""
                        DELETE FROM cloud_index_assets
                        WHERE mount_id = ? AND (folder_path = ? OR folder_path LIKE ? ESCAPE '\\')
                        """, [mountID.uuidString, path, prefix])
                }
            }
        }
    }

    func purgeCloudIndex(mountID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("DELETE FROM cloud_index_assets WHERE mount_id = ?", [mountID.uuidString])
            try? self.db.execute("DELETE FROM cloud_index_folders WHERE mount_id = ?", [mountID.uuidString])
            try? self.db.execute("DELETE FROM cloud_index_state WHERE mount_id = ?", [mountID.uuidString])
        }
    }

    // MARK: - 读取

    /// 目录树 + 聚合数量 + 封面：一条 JOIN 查询完成，不再遍历整份照片清单。
    func loadCloudIndexFolders(mountID: UUID) -> [CloudIndexFolderRow] {
        queue.sync {
            guard let rows = try? db.query("""
                SELECT f.path, f.name, f.parent_path, f.modified_at,
                       f.media_count, f.video_count,
                       a.path AS cover_path, a.name AS cover_name, a.folder_path AS cover_folder,
                       a.size AS cover_size, a.modified_at AS cover_mtime,
                       a.width AS cover_width, a.height AS cover_height,
                       a.duration AS cover_duration, a.is_video AS cover_is_video,
                       a.thumbnail_url AS cover_thumb, a.remote_id AS cover_remote,
                       a.codec AS cover_codec, a.captured_at AS cover_captured
                FROM cloud_index_folders f
                LEFT JOIN cloud_index_assets a
                       ON a.mount_id = f.mount_id AND a.path = f.cover_path
                WHERE f.mount_id = ?
                """, [mountID.uuidString]) else { return [] }
            return rows.map { row in
                let cover: CloudScanRecord? = row["cover_path"]?.string.map { path in
                    CloudScanRecord(path: path,
                                    name: row["cover_name"]?.string ?? (path as NSString).lastPathComponent,
                                    size: row["cover_size"]?.int64 ?? 0,
                                    modifiedAt: row["cover_mtime"]?.double.map { Date(timeIntervalSince1970: $0) },
                                    width: row["cover_width"]?.int,
                                    height: row["cover_height"]?.int,
                                    duration: row["cover_duration"]?.double,
                                    remoteID: row["cover_remote"]?.string,
                                    thumbnailURL: row["cover_thumb"]?.string,
                                    isVideo: (row["cover_is_video"]?.int ?? 0) != 0,
                                    folderPath: row["cover_folder"]?.string,
                                    codec: row["cover_codec"]?.string,
                                    capturedAt: row["cover_captured"]?.double.map { Date(timeIntervalSince1970: $0) },
                                    addedAt: row["cover_mtime"]?.double.map { Date(timeIntervalSince1970: $0) })
                }
                return CloudIndexFolderRow(path: row["path"]?.string ?? "",
                                           name: row["name"]?.string ?? "文件夹",
                                           parentPath: row["parent_path"]?.string ?? "",
                                           modifiedAt: row["modified_at"]?.double.map { Date(timeIntervalSince1970: $0) },
                                           mediaCount: row["media_count"]?.int ?? 0,
                                           videoCount: row["video_count"]?.int ?? 0,
                                           coverRecord: cover)
            }
        }
    }

    /// 扫描结果清单（按拍摄时间倒序）：打开网盘时一次性灌回内存列表。
    func loadCloudIndexAssets(mountID: UUID) -> [CloudScanRecord] {
        queue.sync {
            guard let rows = try? db.query("""
                SELECT path, folder_path, name, size, modified_at, width, height, duration,
                       is_video, thumbnail_url, remote_id, codec, captured_at
                FROM cloud_index_assets
                WHERE mount_id = ?
                ORDER BY captured_at DESC, path ASC
                """, [mountID.uuidString]) else { return [] }
            var records: [CloudScanRecord] = []
            records.reserveCapacity(rows.count)
            for row in rows {
                guard let path = row["path"]?.string else { continue }
                let modified = row["modified_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                let captured = row["captured_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                records.append(CloudScanRecord(path: path,
                                               name: row["name"]?.string
                                                   ?? (path as NSString).lastPathComponent,
                                               size: row["size"]?.int64 ?? 0,
                                               modifiedAt: modified,
                                               width: row["width"]?.int,
                                               height: row["height"]?.int,
                                               duration: row["duration"]?.double,
                                               remoteID: row["remote_id"]?.string,
                                               thumbnailURL: row["thumbnail_url"]?.string,
                                               isVideo: (row["is_video"]?.int ?? 0) != 0,
                                               folderPath: row["folder_path"]?.string,
                                               codec: row["codec"]?.string,
                                               capturedAt: captured,
                                               addedAt: modified))
            }
            return records
        }
    }

    /// 统一搜索用：跨所有网盘索引按文件名模糊匹配。
    /// 走 LIKE，数据量是索引条数级别；`limit == 0` 表示不限制条数。
    func searchCloudIndexAssets(keyword: String, limit: Int = 80)
        -> [(mountID: UUID, record: CloudScanRecord)] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let pattern = "%" + Self.escapedLikeFragment(trimmed) + "%"
        return queue.sync {
            guard let rows = try? db.query("""
                SELECT mount_id, path, folder_path, name, size, modified_at, width, height,
                       duration, is_video, thumbnail_url, remote_id, codec, captured_at
                FROM cloud_index_assets
                WHERE name LIKE ? ESCAPE '\\'
                ORDER BY captured_at DESC, path ASC
                \(limit > 0 ? "LIMIT \(limit)" : "");
                """, [pattern]) else { return [] }
            return rows.compactMap { row in
                guard let mountID = row["mount_id"]?.string.flatMap(UUID.init(uuidString:)),
                      let path = row["path"]?.string else { return nil }
                let modified = row["modified_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                let captured = row["captured_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                let record = CloudScanRecord(path: path,
                                             name: row["name"]?.string
                                                 ?? (path as NSString).lastPathComponent,
                                             size: row["size"]?.int64 ?? 0,
                                             modifiedAt: modified,
                                             width: row["width"]?.int,
                                             height: row["height"]?.int,
                                             duration: row["duration"]?.double,
                                             remoteID: row["remote_id"]?.string,
                                             thumbnailURL: row["thumbnail_url"]?.string,
                                             isVideo: (row["is_video"]?.int ?? 0) != 0,
                                             folderPath: row["folder_path"]?.string,
                                             codec: row["codec"]?.string,
                                             capturedAt: captured,
                                             addedAt: modified)
                return (mountID, record)
            }
        }
    }

    /// 统一搜索用：跨所有网盘索引按目录名模糊匹配。`limit == 0` 表示不限制条数。
    func searchCloudIndexFolders(keyword: String, limit: Int = 40)
        -> [(mountID: UUID, path: String, name: String, mediaCount: Int)] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let pattern = "%" + Self.escapedLikeFragment(trimmed) + "%"
        return queue.sync {
            guard let rows = try? db.query("""
                SELECT mount_id, path, name, media_count
                FROM cloud_index_folders
                WHERE name LIKE ? ESCAPE '\\'
                ORDER BY media_count DESC, path ASC
                \(limit > 0 ? "LIMIT \(limit)" : "");
                """, [pattern]) else { return [] }
            return rows.compactMap { row in
                guard let mountID = row["mount_id"]?.string.flatMap(UUID.init(uuidString:)),
                      let path = row["path"]?.string else { return nil }
                return (mountID,
                        path,
                        row["name"]?.string ?? (path as NSString).lastPathComponent,
                        row["media_count"]?.int ?? 0)
            }
        }
    }

    /// LIKE 片段转义：把用户输入里的通配符当成普通字符。
    private static func escapedLikeFragment(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func escapedLikePrefix(_ prefix: String) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }
}
