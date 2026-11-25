import Foundation

/// 系统图库直连：连拍、相簿 / 人物与导入会话。

extension SystemIndex {
    /// 直连模式的连拍组成员（按拍摄时间升序）：`ZAVALANCHEUUID = ?` 命中 Apple 的
    /// 连拍部分索引，单组通常几十张、毫秒级；查看器组内浏览与连播放用。
    /// 成员里已含收藏 / 主题等全部字段，选择与处理动作不需要二次回查。
    func directBurstMembers(groupID: String) -> [PhotoItem] {
        guard let rows = try? database.query("""
            SELECT \(directSelect)
            \(directFrom)
            WHERE a.ZAVALANCHEUUID = ?
            ORDER BY a.ZDATECREATED ASC, a.Z_PK ASC
            """, [groupID]) else { return [] }
        return rows.compactMap { directPhoto(from: $0) }
    }

    func directNeighbor(of id: UUID, delta: Int, in query: SystemQuery) -> PhotoItem? {
        guard abs(delta) == 1 else { return nil }
        // 相簿按图库保存的手动顺序展示时，上一个 / 下一个也要沿这个顺序走。
        if query.manualOrder, case .album(let albumID) = query.scope {
            return directManualNeighbor(albumID: albumID, current: id, delta: delta)
        }
        let hint = query.sortKey == .addedAt ? "Z_Asset_byAddedDateIndex" : "Z_Asset_byDateCreatedIndex"
        let plan = directSQLPlan(for: query, dateIndex: hint)
        let extras = plan.extraConditions.isEmpty
            ? "" : " AND " + plan.extraConditions.joined(separator: " AND ")
        // 与分页 SQL 完全一致：排序键 + 主键一起做游标。
        // 只比较拍摄 / 添加时间会漏掉同一时间戳的一批照片（导入的整套图常常时间完全相同），
        // 表现为查看器里左右翻页什么都不发生。
        let sortExpression: String
        let isText: Bool
        switch query.sortKey {
        case .title:
            sortExpression = "lower(COALESCE(NULLIF(aa.ZTITLE, ''), a.ZFILENAME))"
            isText = true
        case .addedAt:
            sortExpression = "a.ZADDEDDATE"
            isText = false
        default:
            sortExpression = "a.ZDATECREATED"
            isText = false
        }
        let direction = query.ascending ? "ASC" : "DESC"
        // delta > 0 表示沿当前排序向前一张：升序取更大的键，降序取更小的键。
        let comparison = (delta > 0) == query.ascending ? ">" : "<"
        // 扫描方向必须跟着「往哪边翻」走：向前沿列表方向扫，向后反向扫。
        // 用列表方向扫会在上一张时跑到列表另一端（比如相簿里从第 3 张向左跳到第 1 张，
        // 已经是第一张时则查不到任何行，表现为向左按钮没反应）。
        let scanDirection = delta > 0 ? direction : (query.ascending ? "DESC" : "ASC")
        let currentSQL = """
            SELECT a.Z_PK AS pk, \(sortExpression) AS v
            \(directFrom)
            WHERE a.ZUUID = ?
            LIMIT 1
            """
        guard let current = (try? database.query(currentSQL, [id.uuidString]))?.first,
              let pk = current["pk"]?.int64,
              let value = current["v"] else { return nil }
        let sql = """
            SELECT \(directSelect) \(plan.from)
            WHERE \(plan.whereSQL)\(extras)
              AND ((\(sortExpression) \(comparison) ?) OR (\(sortExpression) = ? AND a.Z_PK \(comparison) ?))
            ORDER BY \(sortExpression) \(scanDirection), a.Z_PK \(scanDirection)
            LIMIT 1
            """
        let bound: Any? = isText ? value.string : value.double
        guard let row = (try? database.query(sql, plan.binds + [bound, bound, pk]))?.first else {
            return nil
        }
        return directPhoto(from: row)
    }

    /// 直连模式的全选：只取 UUID 列，按当前范围 / 筛选条件一次扫完。
    func directAllIDs(_ query: SystemQuery) -> [UUID] {
        let hint = query.sortKey == .addedAt ? "Z_Asset_byAddedDateIndex" : "Z_Asset_byDateCreatedIndex"
        let plan = directSQLPlan(for: query, dateIndex: hint)
        var conditions = plan.whereSQL
        for extra in plan.extraConditions {
            conditions += " AND \(extra)"
        }
        var ids: [UUID] = []
        try? database.forEachRow("SELECT a.ZUUID AS uuid \(plan.from) WHERE \(conditions)",
                                  plan.binds) { row in
            if let value = row["uuid"]?.string, let id = UUID(uuidString: value) {
                ids.append(id)
            }
        }
        return ids
    }

    /// 相簿手动顺序里的相邻照片：按关联表的 `Z_FOK_3ASSETS` 找当前照片的上一张 / 下一张。
    func directManualNeighbor(albumID: Int64, current id: UUID, delta: Int) -> PhotoItem? {
        guard let albumTable = direct?.albumTable,
              let albumColumn = direct?.albumColumn else { return nil }
        let asset = direct?.assetColumn ?? "_none"
        let order = direct?.albumOrderColumn ?? asset
        guard let pk = (try? database.query("SELECT Z_PK AS pk FROM ZASSET WHERE ZUUID = ?",
                                            [id.uuidString]))?.first?["pk"]?.int64,
              let position = (try? database.query("""
                  SELECT \(order) AS pos FROM \(albumTable)
                  WHERE \(albumColumn) = ? AND \(asset) = ? LIMIT 1
                  """, [albumID, pk]))?.first?["pos"]?.int64 else { return nil }
        let comparison = delta > 0 ? ">" : "<"
        let direction = delta > 0 ? "ASC" : "DESC"
        guard let nextPK = (try? database.query("""
            SELECT \(asset) AS pk FROM \(albumTable)
            WHERE \(albumColumn) = ? AND \(order) \(comparison) ?
            ORDER BY \(order) \(direction) LIMIT 1
            """, [albumID, position]))?.first?["pk"]?.int64,
              let uuidString = (try? database.query("""
                  SELECT ZUUID AS uuid FROM ZASSET
                  WHERE Z_PK = ? AND ZTRASHEDSTATE = 0 AND ZHIDDEN = 0
                  """, [nextPK]))?.first?["uuid"]?.string,
              let uuid = UUID(uuidString: uuidString) else { return nil }
        return directPhoto(id: uuid)
    }

    // MARK: - 相簿 / 人物

    /// 可见文件夹主键集合。`ZGENERICALBUM` 的顶层节点父级都指向虚拟根（通常 `ZPARENTFOLDER = 1`，
    /// 该行并不存在），与索引模式一样把这类无效父级归一成 `nil`，否则根层「相簿」永远是空的。
    func directFolderPKs() -> Set<Int64> {
        let trashed = (direct?.albumColumns ?? []).contains("ZTRASHEDSTATE")
            ? "AND COALESCE(ZTRASHEDSTATE, 0) = 0" : ""
        guard let rows = try? database.query(
            "SELECT Z_PK AS pk FROM ZGENERICALBUM WHERE ZKIND = 4000 \(trashed)") else { return [] }
        return Set(rows.compactMap { $0["pk"]?.int64 })
    }

    func directAlbums() -> [SystemAlbumInfo] {
        let columns = direct?.albumColumns ?? []
        let name = columns.contains("ZTITLE") ? "ZTITLE" : "NULL"
        let parent = columns.contains("ZPARENTFOLDER") ? "ZPARENTFOLDER" : "NULL"
        // 不同系统版本的相簿表没有 ZSORTINDEX / ZUUID，缺列时退回主键，避免整段查询失败。
        // Z_FOK_PARENTFOLDER 是 Core Data 保存的父级排序键，与索引模式、官方侧边栏顺序一致。
        let sort: String
        if columns.contains("Z_FOK_PARENTFOLDER") {
            sort = "Z_FOK_PARENTFOLDER"
        } else if columns.contains("ZSORTINDEX") {
            sort = "ZSORTINDEX"
        } else {
            sort = "Z_PK"
        }
        let uuid = columns.contains("ZUUID") ? "ZUUID" : "NULL"
        // 官方图库为每个相簿保存了自己的排序方式与方向；缺列时按「未设置」处理。
        let userSort = columns.contains("ZCUSTOMSORTKEY") ? "ZCUSTOMSORTKEY" : "NULL"
        let userAsc = columns.contains("ZCUSTOMSORTASCENDING") ? "ZCUSTOMSORTASCENDING" : "NULL"
        let trashed = columns.contains("ZTRASHEDSTATE") ? "AND COALESCE(ZTRASHEDSTATE, 0) = 0" : ""
        let sql = """
            SELECT Z_PK AS pk, \(name) AS name, \(parent) AS folder,
                   \(sort) AS sortindex, \(uuid) AS uuid,
                   \(userSort) AS usersort, \(userAsc) AS userasc
            FROM ZGENERICALBUM WHERE ZKIND = 2 \(trashed)
            """
        do {
            let rows = try database.query(sql)
            let folderPKs = directFolderPKs()
            return rows.compactMap { row in
                guard let pk = row["pk"]?.int64 else { return nil }
                return SystemAlbumInfo(id: pk,
                                       name: row["name"]?.string ?? "未命名相簿",
                                       parentFolder: row["folder"]?.int64.flatMap {
                                           folderPKs.contains($0) ? $0 : nil
                                       },
                                       assetIDs: [],
                                       sortIndex: row["sortindex"]?.int64 ?? pk,
                                       uuid: row["uuid"]?.string,
                                       customSortKey: row["usersort"]?.int,
                                       customSortAscending: row["userasc"]?.int.map { $0 != 0 })
            }
        } catch {
            NSLog("LumaDirect: album list failed: %@", error.localizedDescription)
            return []
        }
    }

    func directFolders() -> [SystemFolderInfo] {
        let columns = direct?.albumColumns ?? []
        let name = columns.contains("ZTITLE") ? "ZTITLE" : "NULL"
        let parent = columns.contains("ZPARENTFOLDER") ? "ZPARENTFOLDER" : "NULL"
        let sort: String
        if columns.contains("Z_FOK_PARENTFOLDER") {
            sort = "Z_FOK_PARENTFOLDER"
        } else if columns.contains("ZSORTINDEX") {
            sort = "ZSORTINDEX"
        } else {
            sort = "Z_PK"
        }
        let trashed = columns.contains("ZTRASHEDSTATE") ? "AND COALESCE(ZTRASHEDSTATE, 0) = 0" : ""
        let sql = """
            SELECT Z_PK AS pk, \(name) AS name, \(parent) AS parent, \(sort) AS sortindex
            FROM ZGENERICALBUM WHERE ZKIND = 4000 \(trashed)
            """
        do {
            let rows = try database.query(sql)
            let folderPKs = directFolderPKs()
            return rows.compactMap { row in
                guard let pk = row["pk"]?.int64 else { return nil }
                return SystemFolderInfo(id: pk,
                                        name: row["name"]?.string ?? "未命名文件夹",
                                        parent: row["parent"]?.int64.flatMap {
                                            folderPKs.contains($0) ? $0 : nil
                                        },
                                        sortIndex: row["sortindex"]?.int64 ?? pk)
            }
        } catch {
            NSLog("LumaDirect: folder list failed: %@", error.localizedDescription)
            return []
        }
    }

    func directPeople() -> [SystemPersonInfo] {
        // 关键人脸几何（0-1 归一化：cx 相对图宽、cy 相对图高且原点在左下、size 相对图对角线），
        // 用于按官方「照片」的口径现算人物头像；旧图库缺几何列时用 NULL 顶替。
        let faceColumns = Set((try? database.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? [])
        let hasFaceGeometry = faceColumns.isSuperset(of: ["ZCENTERX", "ZCENTERY", "ZSIZE"])
        let geometryColumns = hasFaceGeometry
            ? """
                   (SELECT f.ZCENTERX FROM ZDETECTEDFACE f WHERE f.Z_PK = p.ZKEYFACE LIMIT 1) AS facecx,
                   (SELECT f.ZCENTERY FROM ZDETECTEDFACE f WHERE f.Z_PK = p.ZKEYFACE LIMIT 1) AS facecy,
                   (SELECT f.ZSIZE FROM ZDETECTEDFACE f WHERE f.Z_PK = p.ZKEYFACE LIMIT 1) AS facesize
            """
            : "NULL AS facecx, NULL AS facecy, NULL AS facesize"
        // 官方会为同一人物保留多条裁切图（李晓希有 14 条），
        // 只有与关键照片一致的那条才是「照片」App 展示的头像，取第一条会显示成别的照片。
        let cropColumns = Set((try? database.query("PRAGMA table_info(ZFACECROP)"))?
            .compactMap { $0["name"]?.string } ?? [])
        let cropColumn = cropColumns.contains("ZASSET")
            ? """
                   (SELECT fc.ZRESOURCEDATA FROM ZFACECROP fc
                     WHERE fc.ZPERSON = p.Z_PK AND fc.ZRESOURCEDATA IS NOT NULL
                       AND fc.ZASSET = (SELECT f.ZASSETFORFACE FROM ZDETECTEDFACE f
                                         WHERE f.Z_PK = p.ZKEYFACE)
                     LIMIT 1) AS crop
              """
            : "NULL AS crop"
        guard let rows = try? database.query("""
            SELECT p.Z_PK AS pk,
                   COALESCE(NULLIF(p.ZDISPLAYNAME, ''), NULLIF(p.ZFULLNAME, ''), '未命名') AS name,
                   p.ZFACECOUNT AS facecount,
                   CASE WHEN p.ZTYPE = 1 THEN 1 ELSE 0 END AS ispet,
                   (SELECT a.ZUUID FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
                     WHERE f.Z_PK = p.ZKEYFACE LIMIT 1) AS keyasset,
                   \(cropColumn),
                   \(geometryColumns)
            FROM ZPERSON p
            WHERE EXISTS (SELECT 1 FROM ZDETECTEDFACE f WHERE f.ZPERSONFORFACE = p.Z_PK)
            ORDER BY p.ZFACECOUNT DESC, name
            """) else { return [] }
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemPersonInfo(id: pk,
                                    name: row["name"]?.string ?? "未命名",
                                    faceCount: row["facecount"]?.int ?? 0,
                                    isPet: (row["ispet"]?.int ?? 0) == 1,
                                    assetIDs: [],
                                    keyAssetID: row["keyasset"]?.string.flatMap(UUID.init(uuidString:)),
                                    cropData: row["crop"]?.data,
                                    faceCenterX: row["facecx"]?.double,
                                    faceCenterY: row["facecy"]?.double,
                                    faceSize: row["facesize"]?.double)
        }
    }

    func directAlbumAssetIDs(_ albumID: Int64) -> [UUID] {
        guard let albumTable = direct?.albumTable, let albumColumn = direct?.albumColumn else { return [] }
        let order = direct?.albumOrderColumn ?? direct?.assetColumn ?? "rowid"
        guard let rows = try? database.query("""
            SELECT a.ZUUID AS uuid FROM \(albumTable) j JOIN ZASSET a ON a.Z_PK = j.\(direct?.assetColumn ?? "_none")
            WHERE j.\(albumColumn) = ? ORDER BY j.\(order)
            """, [albumID]) else { return [] }
        return rows.compactMap { $0["uuid"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func directAlbumAssetCount(_ albumID: Int64) -> Int {
        guard let albumTable = direct?.albumTable, let albumColumn = direct?.albumColumn else { return 0 }
        directAlbumCacheLock.lock()
        if let cached = directAlbumCountCache[albumID] {
            directAlbumCacheLock.unlock()
            return cached
        }
        directAlbumCacheLock.unlock()
        // 官方相簿把项目数缓存在 ZGENERICALBUM.ZCACHEDCOUNT（预聚合列），
        // 与联接表 COUNT(*) 完全一致，但是一次主键查询，不必扫相簿成员。
        var count: Int?
        if direct?.albumColumns.contains("ZCACHEDCOUNT") == true {
            count = (try? database.query("SELECT ZCACHEDCOUNT AS c FROM ZGENERICALBUM WHERE Z_PK = ?", [albumID])
                .first?["c"]?.int)
        }
        if count == nil {
            count = (try? database.query("SELECT COUNT(*) AS c FROM \(albumTable) WHERE \(albumColumn) = ?", [albumID])
                .first?["c"]?.int) ?? 0
        }
        directAlbumCacheLock.lock()
        directAlbumCountCache[albumID] = count
        directAlbumCacheLock.unlock()
        return count ?? 0
    }

    /// 一次性把全部相簿的项目数读入内存缓存。
    /// 侧边栏 / 相簿墙会逐行读取「是否为空」与数量，直连模式默认是每行一次主键查询；
    /// 这里用一条聚合查询预先填满，滚动时不再反复打 Photos.sqlite。
    func warmDirectAlbumCounts() {
        guard let direct, direct.albumColumns.contains("ZCACHEDCOUNT") else { return }
        let trashed = direct.albumColumns.contains("ZTRASHEDSTATE")
            ? "AND COALESCE(ZTRASHEDSTATE, 0) = 0" : ""
        guard let rows = try? database.query("""
            SELECT Z_PK AS pk, ZCACHEDCOUNT AS c FROM ZGENERICALBUM
            WHERE ZKIND = 2 \(trashed)
            """), !rows.isEmpty else { return }
        directAlbumCacheLock.lock()
        for row in rows {
            guard let pk = row["pk"]?.int64, let count = row["c"]?.int else { continue }
            directAlbumCountCache[pk] = count
        }
        directAlbumCacheLock.unlock()
    }

    func directFirstAlbumPhoto(_ albumID: Int64) -> PhotoItem? {
        directAlbumCacheLock.lock()
        if let cached = directAlbumFirstCache[albumID] {
            directAlbumCacheLock.unlock()
            return cached
        }
        directAlbumCacheLock.unlock()
        let photo = directAlbumPreviewPhotos(albumID, limit: 1).first
        directAlbumCacheLock.lock()
        directAlbumFirstCache[albumID] = photo
        directAlbumCacheLock.unlock()
        return photo
    }

    /// 用户在「照片」里单独设定的相簿封面（`ZCUSTOMKEYASSET`）。
    /// 未单独设定时返回 nil，由调用方按相簿成员顺序回退到第一张。
    func directAlbumCustomCoverPhoto(_ albumID: Int64) -> PhotoItem? {
        guard direct?.albumColumns.contains("ZCUSTOMKEYASSET") == true,
              let rows = try? database.query("""
                  SELECT a.ZUUID AS uuid FROM ZGENERICALBUM b
                  JOIN ZASSET a ON a.Z_PK = b.ZCUSTOMKEYASSET
                  WHERE b.Z_PK = ? AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 LIMIT 1
                  """, [albumID]),
              let uuid = rows.first?["uuid"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
        return directPhoto(id: uuid)
    }

    /// 官方为每个相簿维护的关键照片（`Z_33KEYASSETS`），按 Core Data 的排序键读取。
    func directAlbumKeyAssetIDs(_ albumID: Int64, limit: Int) -> [UUID] {
        guard limit > 0, let join = direct?.keyAssetJoin else { return [] }
        let order = join.orderColumn ?? join.assetColumn
        guard let rows = try? database.query("""
            SELECT a.ZUUID AS uuid FROM \(join.table) k
            JOIN ZASSET a ON a.Z_PK = k.\(join.assetColumn)
            WHERE k.\(join.albumColumn) = ? AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
            ORDER BY k.\(order) LIMIT \(limit)
            """, [albumID]) else { return [] }
        return rows.compactMap { $0["uuid"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    // MARK: - 导入会话

    /// 官方导入会话：`ZGENERICALBUM.ZKIND = 1506`，数量直接取官方缓存的批次大小。
    func directImportSessions() -> [SystemImportSession] {
        if let cached = directImportSessionsCache { return cached }
        guard let rows = try? database.query("""
            SELECT Z_PK AS pk, ZCACHEDCOUNT AS count,
                   (ZCREATIONDATE + 978307200) AS created, ZUUID AS uuid
            FROM ZGENERICALBUM
            WHERE ZKIND = 1506 AND COALESCE(ZTRASHEDSTATE, 0) = 0 AND ZCACHEDCOUNT > 0
            ORDER BY ZCREATIONDATE DESC, Z_PK DESC
            """) else { return [] }
        let sessions = rows.compactMap { row -> SystemImportSession? in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemImportSession(id: pk,
                                       createdAt: Date(timeIntervalSince1970: row["created"]?.double ?? 0),
                                       count: row["count"]?.int ?? 0,
                                       uuid: row["uuid"]?.string)
        }
        directImportSessionsCache = sessions
        return sessions
    }

    /// 导入批次的拍摄跨度与视频数量：一次聚合查询，走官方导入会话索引。
    func directImportSessionSummary(_ id: Int64) -> SystemImportSessionSummary? {
        if let cached = directImportSummaryCache[id] { return cached }
        guard let row = (try? database.query("""
            SELECT MIN(a.ZDATECREATED) AS lo, MAX(a.ZDATECREATED) AS hi,
                   SUM(CASE WHEN a.ZKIND = 1 THEN 1 ELSE 0 END) AS videos,
                   COUNT(*) AS total
            FROM ZASSET a INDEXED BY Z_Asset_forAllPhotosHavingImportSession
            WHERE a.ZIMPORTSESSION = ? AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
            """, [id]))?.first else { return nil }
        func date(_ value: SQLiteValue?) -> Date? {
            guard let seconds = value?.double else { return nil }
            return Date(timeIntervalSince1970: seconds + 978307200)
        }
        let summary = SystemImportSessionSummary(earliest: date(row["lo"]),
                                                 latest: date(row["hi"]),
                                                 videoCount: row["videos"]?.int ?? 0,
                                                 totalCount: row["total"]?.int ?? 0)
        directImportSummaryCache[id] = summary
        return summary
    }

    /// 会话封面：沿官方导入会话索引取批内第一张，索引前缀查询，常数级开销。
    func directImportSessionCover(_ id: Int64) -> PhotoItem? {
        directAlbumCacheLock.lock()
        if let cached = directImportCoverCache[id] {
            directAlbumCacheLock.unlock()
            return cached
        }
        directAlbumCacheLock.unlock()
        let from = directFrom.replacingOccurrences(
            of: "FROM ZASSET a",
            with: "FROM ZASSET a INDEXED BY Z_Asset_forAllPhotosHavingImportSession")
        guard let row = (try? database.query("""
            SELECT \(directSelect) \(from)
            WHERE a.ZIMPORTSESSION IS NOT NULL AND a.ZIMPORTSESSION = ?
              AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
            ORDER BY a.ZDATECREATED ASC
            LIMIT 1
            """, [id]))?.first,
              let photo = directPhoto(from: row) else { return nil }
        directAlbumCacheLock.lock()
        if directImportCoverCache.count > 2_000 { directImportCoverCache.removeAll(keepingCapacity: true) }
        directImportCoverCache[id] = photo
        directAlbumCacheLock.unlock()
        return photo
    }

    func directFolderAssetIDs(_ folderID: Int64) -> [UUID] {
        let albums = directAlbumIDs(inFolder: folderID)
        guard !albums.isEmpty else { return [] }
        guard let albumTable = direct?.albumTable, let albumColumn = direct?.albumColumn else { return [] }
        let list = albums.map(String.init).joined(separator: ",")
        guard let rows = try? database.query("""
            SELECT DISTINCT a.ZUUID AS uuid FROM \(albumTable) j JOIN ZASSET a ON a.Z_PK = j.\(direct?.assetColumn ?? "_none")
            WHERE j.\(albumColumn) IN (\(list))
            """) else { return [] }
        return rows.compactMap { $0["uuid"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func directFolderPreviewAssetIDs(_ folderID: Int64, limit: Int) -> [UUID] {
        guard limit > 0 else { return [] }
        let cacheKey = "\(folderID)#\(limit)"
        directAlbumCacheLock.lock()
        if let cached = directFolderPreviewCache[cacheKey] {
            directAlbumCacheLock.unlock()
            return cached
        }
        directAlbumCacheLock.unlock()
        let ids = Array(directFolderAssetIDs(folderID).prefix(limit))
        directAlbumCacheLock.lock()
        if directFolderPreviewCache.count > 2_000 { directFolderPreviewCache.removeAll(keepingCapacity: true) }
        directFolderPreviewCache[cacheKey] = ids
        directAlbumCacheLock.unlock()
        return ids
    }

    /// 只读缓存：命中时调用方可以立刻出封面，不必等查询。
    func cachedAlbumPreviewPhotos(_ albumID: Int64, limit: Int) -> [PhotoItem]? {
        directAlbumCacheLock.lock()
        defer { directAlbumCacheLock.unlock() }
        return directAlbumPreviewCache["\(albumID)#\(limit)"]
    }

    func directAlbumPreviewPhotos(_ albumID: Int64, limit: Int) -> [PhotoItem] {
        guard limit > 0, let albumTable = direct?.albumTable, let albumColumn = direct?.albumColumn else { return [] }
        let cacheKey = "\(albumID)#\(limit)"
        directAlbumCacheLock.lock()
        if let cached = directAlbumPreviewCache[cacheKey] {
            directAlbumCacheLock.unlock()
            return cached
        }
        directAlbumCacheLock.unlock()
        // 封面优先沿用系统图库自己的封面设置：
        // 1. 用户在「照片」里指定的关键照片；2. Apple 自动挑选的关键照片；
        // 3. 两者都没有时，才取相簿成员顺序的第一张。
        var photos: [PhotoItem] = []
        if let cover = directAlbumCustomCoverPhoto(albumID) { photos.append(cover) }
        if photos.count < limit {
            let existing = Set(photos.map(\.id))
            let keyIDs = directAlbumKeyAssetIDs(albumID, limit: limit).filter { !existing.contains($0) }
            if !keyIDs.isEmpty { photos.append(contentsOf: directPhotos(ids: keyIDs)) }
        }
        if photos.count < limit {
            let assetColumn = direct?.assetColumn ?? "_none"
            let order = direct?.albumOrderColumn ?? assetColumn
            let skip = photos.map { "'\($0.id.uuidString)'" }.joined(separator: ",")
            let skipClause = skip.isEmpty ? "" : "AND a.ZUUID NOT IN (\(skip))"
            if let rows = try? database.query("""
                SELECT \(directSelect) FROM \(albumTable) j
                JOIN ZASSET a ON a.Z_PK = j.\(assetColumn)
                LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
                LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
                WHERE j.\(albumColumn) = ? AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                  \(skipClause)
                ORDER BY j.\(order) LIMIT \(limit - photos.count)
                """, [albumID]) {
                photos.append(contentsOf: rows.compactMap { directPhoto(from: $0) })
            }
        }
        directAlbumCacheLock.lock()
        if directAlbumPreviewCache.count > 4_000 { directAlbumPreviewCache.removeAll(keepingCapacity: true) }
        directAlbumPreviewCache[cacheKey] = photos
        directAlbumCacheLock.unlock()
        return photos
    }

    /// 某一年的收藏封面：沿收藏部分索引按日期范围取前几张，
    /// 用于收藏汇总还没算完时先把年份卡片填上真实照片。
    func favoriteCovers(year: Int, limit: Int) -> [PhotoItem] {
        guard direct != nil, limit > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return []
        }
        let sql = """
            SELECT \(directSelect)
            \(directFrom)
            WHERE a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZFAVORITE = 1
              AND a.ZDATECREATED >= ? AND a.ZDATECREATED < ?
            ORDER BY a.ZDATECREATED DESC
            LIMIT \(limit)
            """
        let binds: [Any?] = [start.timeIntervalSince1970 - 978307200,
                             end.timeIntervalSince1970 - 978307200]
        guard let rows = try? database.query(sql, binds) else { return [] }
        return rows.compactMap { directPhoto(from: $0) }
    }

    func directPersonAssetIDs(_ personID: Int64) -> [UUID] {
        guard let rows = try? database.query("""
            SELECT DISTINCT a.ZUUID AS uuid FROM ZDETECTEDFACE f JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
            WHERE f.ZPERSONFORFACE = ?
            """, [personID]) else { return [] }
        return rows.compactMap { $0["uuid"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func directAlbumIDs(inFolder folderID: Int64) -> [Int64] {
        directAlbumCacheLock.lock()
        if let cached = directFolderAlbumsCache[folderID] {
            directAlbumCacheLock.unlock()
            return cached
        }
        let cachedChildren = directFolderChildrenMap
        let cachedKinds = directFolderKindsMap
        directAlbumCacheLock.unlock()

        let children: [Int64: [Int64]]
        let kinds: [Int64: Int]
        if let cachedChildren, let cachedKinds {
            children = cachedChildren
            kinds = cachedKinds
        } else {
            let parentColumn = (direct?.albumColumns.contains("ZPARENTFOLDER") ?? false) ? "ZPARENTFOLDER" : "NULL"
            guard let rows = try? database.query("SELECT Z_PK AS pk, ZKIND AS kind, \(parentColumn) AS parent FROM ZGENERICALBUM") else {
                return []
            }
            var builtChildren: [Int64: [Int64]] = [:]
            var builtKinds: [Int64: Int] = [:]
            for row in rows {
                guard let pk = row["pk"]?.int64 else { continue }
                builtKinds[pk] = row["kind"]?.int ?? 0
                if let parent = row["parent"]?.int64 {
                    builtChildren[parent, default: []].append(pk)
                }
            }
            directAlbumCacheLock.lock()
            directFolderChildrenMap = builtChildren
            directFolderKindsMap = builtKinds
            directAlbumCacheLock.unlock()
            children = builtChildren
            kinds = builtKinds
        }

        var result: [Int64] = []
        var stack = [folderID]
        var seen: Set<Int64> = []
        while let current = stack.popLast() {
            for child in children[current] ?? [] where seen.insert(child).inserted {
                if kinds[child] == 2 { result.append(child) }
                stack.append(child)
            }
        }
        directAlbumCacheLock.lock()
        directFolderAlbumsCache[folderID] = result
        directAlbumCacheLock.unlock()
        return result
    }

    func directAlbumNames(containing id: UUID) -> [String] {
        guard let albumTable = direct?.albumTable, let albumColumn = direct?.albumColumn else { return [] }
        guard let rows = try? database.query("""
            SELECT DISTINCT b.ZTITLE AS name FROM \(albumTable) j
            JOIN ZASSET a ON a.Z_PK = j.\(direct?.assetColumn ?? "_none")
            JOIN ZGENERICALBUM b ON b.Z_PK = j.\(albumColumn)
            WHERE a.ZUUID = ? AND b.ZKIND = 2
            """, [id.uuidString]) else { return [] }
        return rows.compactMap { $0["name"]?.string }
    }

    // MARK: - 行映射

    func directPhoto(from row: [String: SQLiteValue]) -> PhotoItem? {
        guard var item = photo(from: row) else { return nil }
        let uuid = item.id.uuidString
        item.systemOriginalPath = libraryURL
            .appendingPathComponent("originals")
            .appendingPathComponent(row["directory"]?.string ?? String(uuid.prefix(1)))
            .appendingPathComponent(item.filename)
            .path
        if direct?.derivativesRoot != nil {
            item.systemThumbnailPath = LibraryPaths.systemDerivativePath(
                libraryURL: libraryURL,
                assetID: item.id,
                isVideo: item.isVideo,
                directory: row["directory"]?.string
            )
        }
        if item.placeCity == nil, let data = row["placedata"]?.data,
           let place = ReverseGeoArchive.decode(data) {
            item.placeCountry = place.country
            item.placeProvince = place.province
            item.placeCity = place.city
            item.placeDistrict = place.district
            item.placePOI = place.poi
        }
        return item
    }

    // MARK: - 重复项目

    /// 重复项目只用于分组与推荐保留版本，不需要地点 / 相机等大字段：
    /// 单独走一版轻量 SELECT，避免为三万多条重复项解码整份元数据。
    var directDuplicateSelect: String {
        """
        a.ZUUID AS uuid, a.ZFILENAME AS filename, a.ZDIRECTORY AS directory,
        CASE WHEN a.ZKIND = 1 THEN 'video'
             WHEN a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10) THEN 'screenshot'
             WHEN a.ZKINDSUBTYPE = 1 THEN 'panorama'
             WHEN a.ZDERIVEDCAMERACAPTUREDEVICE = 1 THEN 'selfie'
             ELSE 'photo' END AS mediakind,
        (a.ZDATECREATED + 978307200) AS created,
        (COALESCE(a.ZADDEDDATE, a.ZDATECREATED) + 978307200) AS added,
        a.ZFAVORITE AS favorite, a.ZHIDDEN AS hidden,
        a.ZKINDSUBTYPE AS subtype, a.ZPLAYBACKSTYLE AS playbackstyle,
        COALESCE(aa.ZORIGINALWIDTH, a.ZWIDTH) AS width,
        COALESCE(aa.ZORIGINALHEIGHT, a.ZHEIGHT) AS height,
        aa.ZORIGINALFILESIZE AS filesize,
        COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME) AS originalname,
        aa.ZTITLE AS title,
        (a.ZADJUSTMENTTIMESTAMP + 978307200) AS editedat,
        a.ZDURATION AS duration,
        1 AS duplicate
        """
    }

    /// 直连模式的重复项目：沿 Apple 的重复集合部分索引只读一遍，字段裁剪后交给内存分组。
    /// 实测在 SQL 里提前归组（临时表 + 二次联接）反而比直接扫一遍更慢，
    /// 这里只做流式解码，避免一次性物化三万多行字典。
    func directDuplicatePhotos(limit: Int = 60_000) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        let sql = """
            SELECT \(directDuplicateSelect)
            FROM ZASSET a INDEXED BY Z_Asset_forAllPhotosPartOfDuplicatedSet
            LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            WHERE a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
              AND a.ZDUPLICATEASSETVISIBILITYSTATE > 0
              AND a.ZDUPLICATEASSETVISIBILITYSTATE <> 0
            ORDER BY a.ZDATECREATED DESC, a.Z_PK DESC
            LIMIT \(limit)
            """
        var photos: [PhotoItem] = []
        photos.reserveCapacity(min(limit, 40_000))
        try? database.forEachRow(sql) { row in
            if let item = directPhoto(from: row) {
                photos.append(item)
            }
        }
        return photos
    }
}
