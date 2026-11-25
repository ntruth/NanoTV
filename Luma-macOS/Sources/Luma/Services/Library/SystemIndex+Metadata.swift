import Foundation

/// 系统图库的相簿 / 文件夹 / 人物元数据与计数。

extension SystemIndex {
    // MARK: - 相簿 / 文件夹 / 人物元数据

    /// 只读取相簿 / 文件夹结构（不含照片成员）：系统图库扫描或重建索引期间，
    /// 侧边栏可以先把相簿列表展示出来，不必等整库照片读完。
    static func albumMetadata(libraryURL: URL) -> (albums: [SystemAlbumInfo],
                                                   folders: [SystemFolderInfo]) {
        let sourceURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let source = try? SQLiteDatabase(path: sourceURL.path, readonly: true) else {
            return ([], [])
        }
        let albumColumns = (try? source.query("PRAGMA table_info(ZGENERICALBUM)"))?
            .compactMap { $0["name"]?.string } ?? []
        let sortColumn = albumColumns.contains("Z_FOK_PARENTFOLDER") ? "Z_FOK_PARENTFOLDER" : "Z_PK"
        let userSort = albumColumns.contains("ZCUSTOMSORTKEY") ? "ZCUSTOMSORTKEY" : "NULL"
        let userAsc = albumColumns.contains("ZCUSTOMSORTASCENDING") ? "ZCUSTOMSORTASCENDING" : "NULL"
        guard let rows = try? source.query("""
            SELECT Z_PK AS pk, ZKIND AS kind, ZTITLE AS title, ZPARENTFOLDER AS parent,
                   ZUUID AS uuid, \(sortColumn) AS sortkey,
                   \(userSort) AS usersort, \(userAsc) AS userasc
            FROM ZGENERICALBUM
            WHERE ZKIND IN (2, 4000) AND ZTRASHEDSTATE = 0
            """) else { return ([], []) }

        var folders: [SystemFolderInfo] = []
        var folderPKs: Set<Int64> = []
        var rawAlbums: [(pk: Int64, title: String, parent: Int64?, sortIndex: Int64, uuid: String?,
                        userSort: Int?, userAsc: Bool?)] = []
        for row in rows {
            guard let pk = row["pk"]?.int64 else { continue }
            let sortIndex = row["sortkey"]?.int64 ?? pk
            switch row["kind"]?.int ?? 0 {
            case 4000:
                folderPKs.insert(pk)
                folders.append(SystemFolderInfo(id: pk,
                                                name: row["title"]?.string ?? "未命名文件夹",
                                                parent: row["parent"]?.int64,
                                                sortIndex: sortIndex))
            case 2:
                rawAlbums.append((pk,
                                  row["title"]?.string ?? "未命名相簿",
                                  row["parent"]?.int64,
                                  sortIndex,
                                  row["uuid"]?.string,
                                  row["usersort"]?.int,
                                  row["userasc"]?.int.map { $0 != 0 }))
            default:
                break
            }
        }
        let resolvedFolders = folders.map { folder in
            SystemFolderInfo(id: folder.id,
                             name: folder.name,
                             parent: folder.parent.flatMap { folderPKs.contains($0) ? $0 : nil },
                             sortIndex: folder.sortIndex)
        }
        let resolvedAlbums = rawAlbums.map { item in
            SystemAlbumInfo(id: item.pk,
                            name: item.title,
                            parentFolder: item.parent.flatMap { folderPKs.contains($0) ? $0 : nil },
                            assetIDs: [],
                            sortIndex: item.sortIndex,
                            uuid: item.uuid,
                            customSortKey: item.userSort,
                            customSortAscending: item.userAsc)
        }
        return (resolvedAlbums, resolvedFolders)
    }

    /// 只读取人物结构（姓名 / 人脸数 / 头像裁剪 / 首张照片），
    /// 用于系统图库扫描或重建索引期间先把「人物」页展示出来。
    static func peopleMetadata(libraryURL: URL) -> [SystemPersonInfo] {
        let sourceURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let source = try? SQLiteDatabase(path: sourceURL.path, readonly: true) else {
            return []
        }
        let personColumns = (try? source.query("PRAGMA table_info(ZPERSON)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard personColumns.contains("ZDISPLAYNAME"),
              personColumns.contains("ZFULLNAME"),
              personColumns.contains("ZKEYFACE"),
              personColumns.contains("ZFACECOUNT") else { return [] }
        let faceColumns = (try? source.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard faceColumns.contains("ZPERSONFORFACE"), faceColumns.contains("ZASSETFORFACE") else {
            return []
        }

        // 同一人物可能有多条裁切图，只认与关键照片一致的那条（官方头像口径）。
        var crops: [Int64: Data] = [:]
        let cropColumns = (try? source.query("PRAGMA table_info(ZFACECROP)"))?
            .compactMap { $0["name"]?.string } ?? []
        if cropColumns.contains("ZASSET") {
            try? source.forEachRow("""
                SELECT fc.ZPERSON AS person, fc.ZRESOURCEDATA AS data
                FROM ZFACECROP fc
                JOIN ZPERSON p ON p.Z_PK = fc.ZPERSON
                JOIN ZDETECTEDFACE kf ON kf.Z_PK = p.ZKEYFACE
                WHERE fc.ZRESOURCEDATA IS NOT NULL AND fc.ZASSET = kf.ZASSETFORFACE
                """) { row in
                if let person = row["person"]?.int64,
                   let data = row["data"]?.data,
                   crops[person] == nil {
                    crops[person] = data
                }
            }
        }

        // 只按每个人的关键人脸取一张照片，代价与人物数量成正比，不需要扫全部人脸。
        // 一并读取关键人脸几何（0-1 归一化，与官方「照片」的人物头像裁切口径一致）。
        let hasFaceGeometry = (faceColumns.contains("ZCENTERX")
                               && faceColumns.contains("ZCENTERY")
                               && faceColumns.contains("ZSIZE"))
        let geometryColumns = hasFaceGeometry
            ? "f.ZCENTERX AS fcx, f.ZCENTERY AS fcy, f.ZSIZE AS fsize"
            : "NULL AS fcx, NULL AS fcy, NULL AS fsize"
        var keyAssets: [Int64: String] = [:]
        var keyGeometry: [Int64: (cx: Double, cy: Double, size: Double)] = [:]
        let keyRows = (try? source.query("""
            SELECT p.Z_PK AS person, a.ZUUID AS uuid, \(geometryColumns)
            FROM ZPERSON p
            JOIN ZDETECTEDFACE f ON f.Z_PK = p.ZKEYFACE
            JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
            WHERE p.ZKEYFACE IS NOT NULL
            """)) ?? []
        for row in keyRows {
            if let person = row["person"]?.int64, let uuid = row["uuid"]?.string {
                keyAssets[person] = uuid
            }
            if let person = row["person"]?.int64,
               let fcx = row["fcx"]?.double,
               let fcy = row["fcy"]?.double,
               let fsize = row["fsize"]?.double {
                keyGeometry[person] = (fcx, fcy, fsize)
            }
        }

        let rows = (try? source.query("""
            SELECT Z_PK AS pk, ZDISPLAYNAME AS display, ZFULLNAME AS full,
                   ZFACECOUNT AS faces, ZTYPE AS type
            FROM ZPERSON
            """)) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            let name = trimmed(row["display"]?.string)
                ?? trimmed(row["full"]?.string)
                ?? "未命名"
            return SystemPersonInfo(id: pk,
                                    name: name,
                                    faceCount: row["faces"]?.int ?? 0,
                                    isPet: (row["type"]?.int ?? 0) == 1,
                                    assetIDs: [],
                                    keyAssetID: keyAssets[pk].flatMap(UUID.init(uuidString:)),
                                    cropData: crops[pk],
                                    faceCenterX: keyGeometry[pk]?.cx,
                                    faceCenterY: keyGeometry[pk]?.cy,
                                    faceSize: keyGeometry[pk]?.size)
        }
        .sorted { lhs, rhs in
            if lhs.faceCount != rhs.faceCount { return lhs.faceCount > rhs.faceCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var albums: [SystemAlbumInfo] {
        if direct != nil { return directAlbums() }
        let rows = (try? database.query("SELECT pk, name, folder, sortindex, uuid FROM albums")) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemAlbumInfo(id: pk,
                                   name: row["name"]?.string ?? "未命名相簿",
                                   parentFolder: row["folder"]?.int64,
                                   assetIDs: [],
                                   sortIndex: row["sortindex"]?.int64 ?? pk,
                                   uuid: row["uuid"]?.string)
        }
    }

    var folders: [SystemFolderInfo] {
        if direct != nil { return directFolders() }
        let rows = (try? database.query("SELECT pk, name, parent, sortindex FROM folders")) ?? []
        return rows.compactMap { row in
            guard let pk = row["pk"]?.int64 else { return nil }
            return SystemFolderInfo(id: pk,
                                    name: row["name"]?.string ?? "未命名文件夹",
                                    parent: row["parent"]?.int64,
                                    sortIndex: row["sortindex"]?.int64 ?? pk)
        }
    }

    /// 官方导入会话（按导入时间从新到旧）。
    var importSessions: [SystemImportSession] {
        if direct != nil { return directImportSessions() }
        return []
    }

    func importSessionCover(_ id: Int64) -> PhotoItem? {
        if direct != nil { return directImportSessionCover(id) }
        return nil
    }

    /// 导入批次的拍摄跨度与视频数量。
    func importSessionSummary(_ id: Int64) -> SystemImportSessionSummary? {
        if direct != nil { return directImportSessionSummary(id) }
        return nil
    }

    var people: [SystemPersonInfo] {
        if direct != nil { return directPeople() }
        let rows = (try? database.query("""
            SELECT pk, name, facecount, ispet, keyasset, crop,
                   facecx, facecy, facesize FROM people ORDER BY facecount DESC, name
            """)) ?? []
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

    func albumAssetIDs(_ albumID: Int64) -> [UUID] {
        if direct != nil { return directAlbumAssetIDs(albumID) }
        let rows = (try? database.query(
            "SELECT asset FROM album_assets WHERE album = ? ORDER BY position", [albumID])) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func albumAssetCount(_ albumID: Int64) -> Int {
        if direct != nil { return directAlbumAssetCount(albumID) }
        return (try? database.query("SELECT COUNT(*) AS c FROM album_assets WHERE album = ?", [albumID])
            .first?["c"]?.int) ?? 0
    }

    /// 所有相簿的项目数：一次分组查询，供「空相簿 / 空文件夹清理」这类全库体检使用，
    /// 避免几千个相簿逐个 COUNT。
    func albumAssetCounts() -> [Int64: Int] {
        if let direct {
            guard let table = direct.albumTable, let column = direct.albumColumn else { return [:] }
            let rows = (try? database.query("""
                SELECT j.\(column) AS album, COUNT(*) AS c
                FROM \(table) j GROUP BY j.\(column)
                """)) ?? []
            var result: [Int64: Int] = [:]
            for row in rows {
                guard let id = row["album"]?.int64, let count = row["c"]?.int else { continue }
                result[id] = count
            }
            return result
        }
        let rows = (try? database.query("SELECT album, COUNT(*) AS c FROM album_assets GROUP BY album")) ?? []
        var result: [Int64: Int] = [:]
        for row in rows {
            guard let id = row["album"]?.int64, let count = row["c"]?.int else { continue }
            result[id] = count
        }
        return result
    }

    /// 相簿封面：按官方相簿顺序取第一张。
    func firstAlbumPhoto(_ albumID: Int64) -> PhotoItem? {
        if direct != nil { return directFirstAlbumPhoto(albumID) }
        let rows = try? database.query("""
            SELECT assets.* FROM assets
            JOIN album_assets aa ON aa.asset = assets.uuid AND aa.album = ?
            ORDER BY aa.position LIMIT 1
            """, [albumID])
        return rows?.first.flatMap { photo(from: $0) }
    }

    /// 相簿前若干张可用封面：按官方相簿顺序，跳过已删除与隐藏项目。
    func albumPreviewPhotos(_ albumID: Int64, limit: Int) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        if direct != nil { return directAlbumPreviewPhotos(albumID, limit: limit) }
        let rows = try? database.query("""
            SELECT assets.* FROM assets
            JOIN album_assets aa ON aa.asset = assets.uuid AND aa.album = ?
            WHERE assets.trashed IS NULL AND assets.hidden = 0
            ORDER BY aa.position LIMIT \(limit)
            """, [albumID])
        return rows?.compactMap { photo(from: $0) } ?? []
    }

    /// 文件夹子树下所有相簿里的项目 ID（去重）；用于「拷贝到拾光」。
    func folderAssetIDs(_ folderID: Int64) -> [UUID] {
        if direct != nil { return directFolderAssetIDs(folderID) }
        let albumIDs = albumIDs(inFolder: folderID)
        guard !albumIDs.isEmpty else { return [] }
        let list = inList(albumIDs.map(String.init))
        let rows = (try? database.query("""
            SELECT DISTINCT asset FROM album_assets WHERE album IN (\(list))
            """)) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func folderPreviewAssetIDs(_ folderID: Int64, limit: Int) -> [UUID] {
        guard limit > 0 else { return [] }
        if direct != nil { return directFolderPreviewAssetIDs(folderID, limit: limit) }
        let albumIDs = albumIDs(inFolder: folderID)
        guard !albumIDs.isEmpty else { return [] }
        let list = inList(albumIDs.map(String.init))
        let rows = (try? database.query("""
            SELECT DISTINCT asset FROM album_assets WHERE album IN (\(list)) LIMIT \(limit)
            """)) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func personAssetIDs(_ personID: Int64) -> [UUID] {
        if direct != nil { return directPersonAssetIDs(personID) }
        let rows = (try? database.query(
            "SELECT asset FROM person_assets WHERE person = ?", [personID])) ?? []
        return rows.compactMap { $0["asset"]?.string.flatMap(UUID.init(uuidString:)) }
    }

    func albumIDs(inFolder folderID: Int64) -> [Int64] {
        if direct != nil { return directAlbumIDs(inFolder: folderID) }
        let all = (try? database.query("SELECT pk, folder FROM albums")) ?? []
        var children: [Int64: [Int64]] = [:]
        for row in all {
            guard let pk = row["pk"]?.int64 else { continue }
            if let folder = row["folder"]?.int64 {
                children[folder, default: []].append(pk)
            }
        }
        let folderChildren = (try? database.query("SELECT pk, parent FROM folders")) ?? []
        var folderTree: [Int64: [Int64]] = [:]
        for row in folderChildren {
            guard let pk = row["pk"]?.int64, let parent = row["parent"]?.int64 else { continue }
            folderTree[parent, default: []].append(pk)
        }
        var result: [Int64] = []
        func walk(_ id: Int64) {
            result.append(contentsOf: children[id] ?? [])
            for child in folderTree[id] ?? [] { walk(child) }
        }
        walk(folderID)
        return result
    }

    /// 某张照片所属的相簿名称。
    func albumNames(containing id: UUID) -> [String] {
        if direct != nil { return directAlbumNames(containing: id) }
        let rows = (try? database.query("""
            SELECT a.name AS name FROM album_assets aa JOIN albums a ON a.pk = aa.album
            WHERE aa.asset = ?
            """, [id.uuidString])) ?? []
        return rows.compactMap { $0["name"]?.string }
    }

    // MARK: - 计数

    /// 侧边栏徽标：一次聚合查询算完所有计数。
    func counts(overrides: SystemQuery) -> SystemIndexCounts {
        if direct != nil { return directSidebarCounts() }
        let active = activePredicate(overrides)
        let savedCutoff = (overrides.savedCutoff ?? Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
            .timeIntervalSince1970
        let sql = """
            SELECT
                COUNT(*) AS total,
                COALESCE(SUM(CASE WHEN trashed IS NOT NULL THEN 1 ELSE 0 END), 0) AS trash,
                COALESCE(SUM(CASE WHEN \(active) THEN 1 ELSE 0 END), 0) AS active,
                COALESCE(SUM(CASE WHEN \(active) AND hidden = 1 THEN 1 ELSE 0 END), 0) AS hidden,
                COALESCE(SUM(CASE WHEN \(active) AND duplicate = 1 THEN 1 ELSE 0 END), 0) AS duplicate,
                COALESCE(SUM(CASE WHEN \(active) AND added >= \(savedCutoff) THEN 1 ELSE 0 END), 0) AS recentlySaved,
                COALESCE(SUM(CASE WHEN \(active) AND isdeviceimport = 1 THEN 1 ELSE 0 END), 0) AS imports,
                COALESCE(SUM(CASE WHEN \(active) AND depth > 0 AND isvideo = 0 THEN 1 ELSE 0 END), 0) AS portrait,
                COALESCE(SUM(CASE WHEN \(active) AND mediakind = 'screenshot' THEN 1 ELSE 0 END), 0) AS screenshots,
                COALESCE(SUM(CASE WHEN trashed IS NULL THEN filesize ELSE 0 END), 0) AS bytes,
                MIN(CASE WHEN \(active) THEN created END) AS earliest,
                MAX(CASE WHEN \(active) THEN created END) AS latest
            FROM assets
            """
        guard let row = try? database.query(sql).first else { return SystemIndexCounts() }
        var counts = SystemIndexCounts()
        counts.trash = row["trash"]?.int ?? 0
        counts.active = row["active"]?.int ?? 0
        counts.hidden = row["hidden"]?.int ?? 0
        counts.duplicate = row["duplicate"]?.int ?? 0
        counts.recentlySaved = row["recentlySaved"]?.int ?? 0
        counts.imports = row["imports"]?.int ?? 0
        counts.portrait = row["portrait"]?.int ?? 0
        counts.screenshots = row["screenshots"]?.int ?? 0
        counts.totalBytes = row["bytes"]?.int64 ?? 0
        counts.earliest = row["earliest"]?.double.map { Date(timeIntervalSince1970: $0) }
        counts.latest = row["latest"]?.double.map { Date(timeIntervalSince1970: $0) }
        return counts
    }

    /// 身份卡统计：有效（不含隐藏 / 最近删除）的照片与视频数量，一次聚合查询算完。
    func activeMediaTotals() -> (photos: Int, videos: Int) {
        if direct != nil {
            let summary = directMediaTypeSummary()
            let videos = summary.counts[.videos] ?? 0
            let active = directSidebarCounts().active
            return (max(0, active - videos), videos)
        }
        let active = activePredicate(SystemQuery())
        let sql = """
            SELECT
                COALESCE(SUM(CASE WHEN \(active) AND isvideo = 1 THEN 1 ELSE 0 END), 0) AS videos,
                COALESCE(SUM(CASE WHEN \(active) AND isvideo = 0 THEN 1 ELSE 0 END), 0) AS photos
            FROM assets
            """
        guard let row = try? database.query(sql).first else { return (0, 0) }
        return (row["photos"]?.int ?? 0, row["videos"]?.int ?? 0)
    }

    /// 媒体类型总览：数量 + 每类第一张封面。
    func mediaTypeSummary(overrides: SystemQuery) -> MediaTypeSummary {
        if direct != nil { return directMediaTypeSummary() }
        var summary = MediaTypeSummary()
        for type in MediaTypeKey.allCases {
            var query = overrides
            switch type {
            case .videos: query.scope = .videos
            case .selfies: query.scope = .selfies
            case .livePhotos: query.scope = .livePhotos
            case .portraits: query.scope = .portraits
            case .panoramas: query.scope = .panoramas
            case .timelapse: query.scope = .timelapses
            case .slowMotion: query.scope = .slowMotion
            case .bursts: query.scope = .bursts
            case .screenshots: query.scope = .screenshots
            case .screenRecordings: query.scope = .screenRecordings
            case .animated: query.scope = .animated
            case .raws: query.scope = .raws
            // 长曝光 / 电影效果 / 空间媒体需要 PhotoKit 或直连 Photos.sqlite，本地索引模式跳过。
            case .longExposure, .cinematic, .spatial: continue
            }
            query.filter = .all
            query.tokens = []
            query.overlayKeywordIDs = nil
            let summaryValue = self.summary(query)
            guard summaryValue.total > 0 else { continue }
            summary.counts[type] = summaryValue.total
            summary.covers[type] = page(query, offset: 0, limit: 1).first
        }
        return summary
    }

    /// 重复项目：使用官方 `isDuplicateItem` 标记（拾光的重复页会再按大小/尺寸分组）。
    /// 上限要覆盖官方标出的全部重复项（本机 3.4 万级），否则重复页只显示前 2 万条。
    func duplicatePhotos(limit: Int = 60_000) -> [PhotoItem] {
        if direct != nil { return directDuplicatePhotos(limit: limit) }
        var query = SystemQuery()
        query.scope = .duplicates
        return page(query, offset: 0, limit: limit)
    }

    /// 带位置的照片：地图与足迹回放使用全量，统计与地点数不做任何截断。
    /// 逐行解码，避免先把整表物化成字典再转 `PhotoItem`（大图库内存峰值明显更低）。
    func photosWithLocation() -> [PhotoItem] {
        if direct != nil {
            // 直连模式的后台任务会读入全量带定位照片；就绪前先给最近的一小段，
            // 地图 / 地点页不至于空白。
            if let all = directGeoPhotos { return all }
            var query = SystemQuery()
            query.scope = .withLocation
            return directPage(query, offset: 0, limit: 600)
        }
        var query = SystemQuery()
        query.scope = .withLocation
        query.sortKey = .capturedAt
        query.ascending = false
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let sql = """
            SELECT assets.* FROM \(from) WHERE \(whereSQL)
            ORDER BY \(orderExpression(query)) DESC,
                     assets.uuid DESC
            """
        var photos: [PhotoItem] = []
        photos.reserveCapacity(summary(query).total)
        _ = try? database.forEachRow(sql, fromBinds + binds) { row in
            if let photo = self.photo(from: row) {
                photos.append(photo)
            }
        }
        return photos
    }
}
