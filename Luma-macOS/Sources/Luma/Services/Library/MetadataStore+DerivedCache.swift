import Foundation

/// 跨范围派生缓存的读写：系统图库识别、体检 / 美化报告、网盘 EXIF 与人物。
/// 全部写当前图库自己的 `Luma.sqlite`，绝不写 Apple 的 `Photos.sqlite`。
extension MetadataStore {
    // MARK: - 系统图库缓存

    func systemAnalysisSignature(_ libraryPath: String) -> String? {
        setting("system_analysis_signature|\(libraryPath)")
    }

    func setSystemAnalysisSignature(_ libraryPath: String, _ signature: String) {
        setSetting("system_analysis_signature|\(libraryPath)", signature)
    }

    /// 系统图库识别停在查询的哪个偏移；重新打开或切换回来后从这里接着跑。
    func systemAnalysisCursor(_ libraryPath: String) -> Int? {
        setting("system_analysis_cursor|\(libraryPath)").flatMap(Int.init)
    }

    func setSystemAnalysisCursor(_ libraryPath: String, _ offset: Int) {
        setSetting("system_analysis_cursor|\(libraryPath)", String(max(0, offset)))
    }

    /// 用户是否希望这个系统图库打开后自动接着识别（关库 / 退出后仍然记住）。
    func systemAnalysisAutoResume(_ libraryPath: String) -> Bool {
        setting("system_analysis_auto_resume|\(libraryPath)") == "1"
    }

    func setSystemAnalysisAutoResume(_ libraryPath: String, _ value: Bool) {
        setSetting("system_analysis_auto_resume|\(libraryPath)", value ? "1" : nil)
    }

    /// 系统图库的标签 / 文字 / 特征（一次取回，调用方按需放进内存）。
    /// `analyzed` 为假表示这行只有特征向量（体检 / 相似检索写入），不算完成内容识别。
    func loadSystemAnalysis(libraryPath: String, includeFeatures: Bool = false)
        -> [(id: UUID, labels: String, text: String, feature: Data?, analyzed: Bool)] {
        queue.sync {
            // 特征向量每张约 8 KB，十万级图库一次全读会吃掉近 1 GB 内存；
            // 只有体检 / 相似检索需要时（includeFeatures）才取这一列。
            let columns = includeFeatures ? "asset_id, labels, text, feature" : "asset_id, labels, text"
            guard let rows = try? db.query("""
                SELECT \(columns) FROM system_analysis WHERE library_path = ?
                """, [libraryPath]) else { return [] }
            return rows.compactMap { row in
                guard let idString = row["asset_id"]?.string,
                      let id = UUID(uuidString: idString) else { return nil }
                return (id,
                        row["labels"]?.string ?? "",
                        row["text"]?.string ?? "",
                        includeFeatures ? row["feature"]?.data : nil,
                        row["labels"] != nil || row["text"] != nil)
            }
        }
    }

    func saveSystemAnalysis(libraryPath: String,
                            entries: [(id: UUID, labels: String, text: String, feature: Data?)]) {
        guard !entries.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            try? self.db.transaction {
                for entry in entries {
                    try self.db.execute("""
                        INSERT INTO system_analysis (library_path, asset_id, labels, text, feature, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(library_path, asset_id) DO UPDATE SET
                            labels = excluded.labels,
                            text = excluded.text,
                            feature = COALESCE(excluded.feature, system_analysis.feature),
                            updated_at = excluded.updated_at
                        """, [libraryPath, entry.id.uuidString, entry.labels, entry.text, entry.feature, now])
                }
            }
        }
    }

    func saveSystemFeatures(libraryPath: String, entries: [(id: UUID, feature: Data)]) {
        guard !entries.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            try? self.db.transaction {
                for entry in entries {
                    try self.db.execute("""
                        INSERT INTO system_analysis (library_path, asset_id, feature, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(library_path, asset_id) DO UPDATE SET
                            feature = excluded.feature,
                            updated_at = excluded.updated_at
                        """, [libraryPath, entry.id.uuidString, entry.feature, now])
                }
            }
        }
    }

    func removeSystemAnalysis(libraryPath: String, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                try? self.db.execute("DELETE FROM system_analysis WHERE library_path = ? AND asset_id = ?",
                                     [libraryPath, id.uuidString])
            }
        }
    }

    /// 系统图库被替换 / 重建索引后清空该库的识别与特征缓存。
    func purgeSystemCache(libraryPath: String) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("DELETE FROM system_analysis WHERE library_path = ?", [libraryPath])
            try? self.db.execute("DELETE FROM settings WHERE key IN (?, ?, ?)",
                                 ["system_analysis_signature|\(libraryPath)",
                                  "system_analysis_cursor|\(libraryPath)",
                                  "system_analysis_auto_resume|\(libraryPath)"])
        }
    }

    // MARK: - 派生报告（体检 / 美化 / 相似）

    func loadDerivedReport(key: String) -> (payload: Data, signature: String?, updatedAt: Date)? {
        queue.sync {
            guard let row = (try? db.query("SELECT * FROM derived_reports WHERE key = ?", [key]))?.first,
                  let text = row["payload"]?.string,
                  let data = text.data(using: .utf8) else { return nil }
            return (data,
                    row["signature"]?.string,
                    Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0))
        }
    }

    func saveDerivedReport(key: String, signature: String?, payload: Data) {
        guard let text = String(data: payload, encoding: .utf8) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("""
                INSERT OR REPLACE INTO derived_reports (key, signature, payload, updated_at)
                VALUES (?, ?, ?, ?)
                """, [key, signature, text, Date().timeIntervalSince1970])
        }
    }

    func removeDerivedReport(key: String) {
        queue.async { [weak self] in
            try? self?.db.execute("DELETE FROM derived_reports WHERE key = ?", [key])
        }
    }

    func removeDerivedReports(prefix: String) {
        queue.async { [weak self] in
            try? self?.db.execute("DELETE FROM derived_reports WHERE key LIKE ? ESCAPE '\\'",
                                  [Self.escapedLikePrefix(prefix)])
        }
    }

    private static func escapedLikePrefix(_ prefix: String) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }

    // MARK: - 网盘照片缓存

    /// 某个网盘已缓存的照片记录（按 `path` 索引）。
    /// 默认不读取 `feature` BLOB：那部分体积最大，按需由 `loadCloudFeatures` 单独加载。
    func loadCloudAssets(mountID: UUID, includingFeatures: Bool = false) -> [String: CloudAssetCacheRow] {
        queue.sync {
            if !includingFeatures, let cached = cloudAssetsRowCache[mountID] { return cached }
            let columns = includingFeatures
                ? "*"
                : "path, size, remote_mtime, exif, labels, text, viewed_at, metadata_at, analyzed_at, people_at"
            guard let rows = try? db.query("SELECT \(columns) FROM cloud_assets WHERE mount_id = ?",
                                           [mountID.uuidString]) else { return [:] }
            var result: [String: CloudAssetCacheRow] = [:]
            for row in rows {
                guard let path = row["path"]?.string else { continue }
                var item = CloudAssetCacheRow(path: path)
                item.size = row["size"]?.int64
                item.remoteModified = row["remote_mtime"]?.double.map { Date(timeIntervalSince1970: $0) }
                if let json = row["exif"]?.string, let data = json.data(using: .utf8) {
                    item.exif = try? JSONDecoder().decode(CloudPhotoEXIF.self, from: data)
                }
                item.labels = row["labels"]?.string
                item.text = row["text"]?.string
                item.feature = row["feature"]?.data
                item.viewedAt = row["viewed_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                item.metadataAt = row["metadata_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                item.analyzedAt = row["analyzed_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                item.peopleAt = row["people_at"]?.double.map { Date(timeIntervalSince1970: $0) }
                result[path] = item
            }
            if !includingFeatures { cloudAssetsRowCache[mountID] = result }
            return result
        }
    }

    /// 某个网盘已落库的特征向量（path → BLOB）：只加载一次，不参与目录切换的热路径。
    func loadCloudFeatures(mountID: UUID) -> [String: Data] {
        queue.sync {
            guard let rows = try? db.query("""
                SELECT path, feature FROM cloud_assets
                WHERE mount_id = ? AND feature IS NOT NULL
                """, [mountID.uuidString]) else { return [:] }
            var result: [String: Data] = [:]
            for row in rows {
                guard let path = row["path"]?.string,
                      let feature = row["feature"]?.data, !feature.isEmpty else { continue }
                result[path] = feature
            }
            return result
        }
    }

    /// 写入 EXIF 探测结果（没有 EXIF 也要记录 `metadata_at`，避免重复请求）。
    func saveCloudEXIF(mountID: UUID, path: String, size: Int64?, modified: Date?, exif: CloudPhotoEXIF?) {
        let json: String?
        if let exif, let data = try? JSONEncoder().encode(exif) {
            json = String(data: data, encoding: .utf8)
        } else {
            json = nil
        }
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("""
                INSERT INTO cloud_assets
                (mount_id, path, size, remote_mtime, exif, metadata_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(mount_id, path) DO UPDATE SET
                    size = excluded.size,
                    remote_mtime = excluded.remote_mtime,
                    exif = excluded.exif,
                    metadata_at = excluded.metadata_at,
                    updated_at = excluded.updated_at
                """, [mountID.uuidString, path, size, modified?.timeIntervalSince1970, json, now, now])
            // 就地更新内存副本：EXIF 扫描期间每张照片都让缓存整体失效，会让目录切换反复重查全表。
            if var cached = self.cloudAssetsRowCache[mountID], var row = cached[path] {
                row.size = size
                row.remoteModified = modified
                row.exif = exif
                row.metadataAt = Date(timeIntervalSince1970: now)
                cached[path] = row
                self.cloudAssetsRowCache[mountID] = cached
            } else {
                self.cloudAssetsRowCache[mountID] = nil
            }
        }
    }

    func saveCloudAnalysis(mountID: UUID, path: String, labels: String, text: String, feature: Data?) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("""
                INSERT INTO cloud_assets
                (mount_id, path, labels, text, feature, analyzed_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(mount_id, path) DO UPDATE SET
                    labels = excluded.labels,
                    text = excluded.text,
                    feature = COALESCE(excluded.feature, cloud_assets.feature),
                    analyzed_at = excluded.analyzed_at,
                    updated_at = excluded.updated_at
                """, [mountID.uuidString, path, labels, text, feature, now, now])
            self.cloudAssetsRowCache[mountID] = nil
        }
    }

    func saveCloudFeature(mountID: UUID, path: String, feature: Data) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("""
                INSERT INTO cloud_assets (mount_id, path, feature, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(mount_id, path) DO UPDATE SET
                    feature = excluded.feature,
                    updated_at = excluded.updated_at
                """, [mountID.uuidString, path, feature, now])
            self.cloudAssetsRowCache[mountID] = nil
        }
    }

    func saveCloudViewedAt(mountID: UUID, path: String, viewedAt: Date) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("""
                INSERT INTO cloud_assets (mount_id, path, viewed_at, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(mount_id, path) DO UPDATE SET
                    viewed_at = excluded.viewed_at,
                    updated_at = excluded.updated_at
                """, [mountID.uuidString, path, viewedAt.timeIntervalSince1970, now])
            self.cloudAssetsRowCache[mountID] = nil
        }
    }

    /// 记录某目录下的人脸聚类已处理过（不写记录内容，只标记已扫描）。
    func markCloudPeopleScanned(mountID: UUID, paths: [String]) {
        guard !paths.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.transaction {
                for path in paths {
                    try self.db.execute("""
                        INSERT INTO cloud_assets (mount_id, path, people_at, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(mount_id, path) DO UPDATE SET
                            people_at = excluded.people_at,
                            updated_at = excluded.updated_at
                        """, [mountID.uuidString, path, now, now])
                }
            }
            self.cloudAssetsRowCache[mountID] = nil
        }
    }

    func purgeCloudAssets(mountID: UUID) {
        queue.async { [weak self] in
            try? self?.db.execute("DELETE FROM cloud_assets WHERE mount_id = ?", [mountID.uuidString])
            self?.cloudAssetsRowCache[mountID] = nil
        }
    }

    // MARK: - 网盘人物

    func loadCloudPeople(mountID: UUID) -> [LocalPerson] {
        queue.sync {
            guard let rows = try? db.query("SELECT * FROM cloud_people WHERE mount_id = ?",
                                           [mountID.uuidString]) else { return [] }
            guard let links = try? db.query("""
                SELECT person_id, asset_id FROM cloud_person_assets WHERE mount_id = ?
                """, [mountID.uuidString]) else { return [] }
            var assetIDs: [String: [UUID]] = [:]
            for link in links {
                guard let personID = link["person_id"]?.string,
                      let assetID = link["asset_id"]?.string.flatMap({ UUID(uuidString: $0) }) else { continue }
                assetIDs[personID, default: []].append(assetID)
            }
            return rows.compactMap { row in
                guard let idString = row["person_id"]?.string,
                      let id = UUID(uuidString: idString),
                      let name = row["name"]?.string else { return nil }
                let centroidData = row["centroid"]?.data ?? Data()
                let centroid = centroidData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return LocalPerson(id: id,
                                   name: name,
                                   assetIDs: assetIDs[idString] ?? [],
                                   coverImageData: row["cover"]?.data,
                                   faceCount: Int(row["face_count"]?.int64 ?? 0),
                                   centroid: centroid)
            }
        }
    }

    func saveCloudPeople(mountID: UUID, people: [LocalPerson]) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            try? self.db.transaction {
                try self.db.execute("DELETE FROM cloud_people WHERE mount_id = ?", [mountID.uuidString])
                try self.db.execute("DELETE FROM cloud_person_assets WHERE mount_id = ?", [mountID.uuidString])
                for person in people {
                    let centroidData = person.centroid.withUnsafeBufferPointer { Data(buffer: $0) }
                    try self.db.execute("""
                        INSERT OR REPLACE INTO cloud_people
                        (mount_id, person_id, name, face_count, cover, centroid, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, [mountID.uuidString, person.id.uuidString, person.name,
                              person.faceCount, person.coverImageData, centroidData, now])
                    for assetID in person.assetIDs {
                        try self.db.execute("""
                            INSERT OR REPLACE INTO cloud_person_assets (mount_id, person_id, asset_id)
                            VALUES (?, ?, ?)
                            """, [mountID.uuidString, person.id.uuidString, assetID.uuidString])
                    }
                }
            }
        }
    }

    func purgeCloudPeople(mountID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.db.execute("DELETE FROM cloud_people WHERE mount_id = ?", [mountID.uuidString])
            try? self.db.execute("DELETE FROM cloud_person_assets WHERE mount_id = ?", [mountID.uuidString])
        }
    }
}
