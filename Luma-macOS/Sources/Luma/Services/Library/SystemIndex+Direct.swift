import Foundation

/// 官方相簿的「关键照片」关系（`Z_33KEYASSETS` 一类的 Core Data 联接表）。
/// Apple 已经为每个相簿挑好封面与候选封面，按 `Z_FOK_*` 顺序读出即可。
struct SystemAlbumKeyAssetJoin: Sendable {
    let table: String
    let albumColumn: String
    let assetColumn: String
    let orderColumn: String?
}

/// 「索引直连」模式：不再把整库元数据复制一份，而是直接分页查询系统 `Photos.sqlite`。
/// 只缓存极小的派生数据（侧边栏计数快照），网格、相簿、人物都按需查询。
struct SystemDirectSource: Sendable {
    let derivativesRoot: String?
    let hasExtended: Bool
    let albumTable: String?
    let albumColumn: String?
    let assetColumn: String?
    let albumOrderColumn: String?
    /// `ZGENERICALBUM` 实际存在的列：不同系统版本的相簿表并不完全一致。
    let albumColumns: Set<String>
    /// `Z_33KEYASSETS` 联接表（官方相簿封面 / 关键照片），旧版图库没有时为 nil。
    let keyAssetJoin: SystemAlbumKeyAssetJoin?
    /// `ZPHOTOSHIGHLIGHT` 与 ZASSET 上的反向关键照片列（年 / 月总览封面）。
    let hasHighlightKeyAssets: Bool
    /// ZASSET 是否带官方美学评分（人物高光、最佳照片排序用）。
    let hasAestheticScore: Bool
    /// ZASSET 是否有 UTI 列（RAW 识别走 `Z_Asset_byUniformTypeIdentifierIndex`）。
    let hasUniformTypeIdentifier: Bool
    /// ZASSET 是否有空间媒体列（旧版图库没有 ZSPATIALTYPE）。
    let hasSpatialType: Bool
}

/// 官方 `ZMOMENT` 里的一个「时刻」：起止时间（Unix 秒）与项目数。
struct SystemTimelineBucket: Sendable {
    let start: Double
    let end: Double
    let count: Int
}

/// 侧边栏计数快照：直连模式下精确计数要扫全库，先落盘缓存，首次在后台补。
struct SystemDirectCounts: Codable {
    /// 快照版本：计数口径变化时递增，旧快照直接忽略并在后台重算。
    /// v4：连拍快照改为按组计数（DISTINCT ZAVALANCHEUUID）。
    static let currentVersion = 4
    var version: Int? = nil
    var active = 0
    var hidden = 0
    var trash = 0
    var duplicate = 0
    var recentlySaved = 0
    var imports = 0
    var portrait = 0
    var screenshots = 0
    var totalBytes: Int64 = 0
    var earliest: TimeInterval?
    var latest: TimeInterval?
    // 媒体类型计数：与 mediaTypeSummary 一一对应，避免逐类单独扫全库。
    var videos = 0
    var selfies = 0
    var livePhotos = 0
    var panoramas = 0
    var timelapse = 0
    var slowMotion = 0
    var cinematic = 0
    var spatial = 0
    var bursts = 0
    var screenRecordings = 0
    var animated = 0
    var raws = 0
    // 版本 2 新增：更多项目入口的精确计数（旧快照缺字段时按 0 处理）
    var favorites: Int? = nil
    var edited: Int? = nil
    var recentlyViewed: Int? = nil
    var revisit: Int? = nil
    var located: Int? = nil
    /// 媒体类型封面：`MediaTypeKey.rawValue` → 资产 UUID（后台补，旧快照可能没有）
    var covers: [String: String]? = nil
    /// 年 / 月总览：按月统计的有效数量（"yyyy-MM" → count）
    var monthCounts: [String: Int]? = nil
    var monthVideos: [String: Int]? = nil
    var monthFavorites: [String: Int]? = nil
    /// 年 / 月总览卡片样本（"yyyy-MM" / "yyyy" → 最多 4 个 UUID）
    var monthSamples: [String: [String]]? = nil
    var yearSamples: [String: [String]]? = nil
    /// 年 / 月总览封面：`ZPHOTOSHIGHLIGHT` 里 Apple 已挑好的关键照片（"yyyy-MM" / "yyyy" → UUID）
    var monthCovers: [String: String]? = nil
    var yearCovers: [String: String]? = nil
    /// 生成快照时 Photos.sqlite / -wal 的大小与修改时间；未变化时启动直接复用，完全不扫库。
    var fingerprint: String? = nil
}

extension SystemIndex {

    /// 与拾光「最近保存 / 最近查看」保持一致的 30 天窗口。
    static var directSavedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }
    static var directViewedCutoff: Date { directSavedCutoff }

    // MARK: - 打开

    /// 直连打开系统图库：只读 Photos.sqlite，不建索引。
    static func openDirect(libraryURL: URL) -> SystemIndex? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            NSLog("LumaDirect: Photos.sqlite missing at %@", dbURL.path)
            return nil
        }
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else {
            NSLog("LumaDirect: cannot open Photos.sqlite")
            return nil
        }
        let assetColumns = Set((try? db.query("PRAGMA table_info(ZASSET)"))?
            .compactMap { $0["name"]?.string } ?? [])
        guard assetColumns.contains("ZUUID"), assetColumns.contains("ZDATECREATED") else {
            NSLog("LumaDirect: ZASSET columns missing, count=%d", assetColumns.count)
            return nil
        }
        let additional = Set((try? db.query("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)"))?
            .compactMap { $0["name"]?.string } ?? [])
        let extended = ((try? db.query("PRAGMA table_info(ZEXTENDEDATTRIBUTES)"))?.isEmpty == false)
        let join = detectAlbumJoin(db)
        let albumColumns = Set((try? db.query("PRAGMA table_info(ZGENERICALBUM)"))?
            .compactMap { $0["name"]?.string } ?? [])
        let derivatives = LibraryPaths.systemDerivatives(libraryURL: libraryURL).path
        let hasDerivatives = FileManager.default.fileExists(atPath: derivatives)
        let assetIndexes = Set((try? db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZASSET'"))?
            .compactMap { $0["name"]?.string } ?? [])
        let source = SystemDirectSource(
            derivativesRoot: hasDerivatives ? derivatives : nil,
            hasExtended: extended,
            albumTable: join?.table,
            albumColumn: join?.albumColumn,
            assetColumn: join?.assetColumn,
            albumOrderColumn: join?.orderColumn,
            albumColumns: albumColumns,
            keyAssetJoin: detectKeyAssetJoin(db),
            // 反向关键照片列必须带索引，否则联接会退化成整表扫描。
            hasHighlightKeyAssets: assetIndexes.contains("ZASSET_ZYEARHIGHLIGHTBEINGKEYASSETPRIVATE_INDEX")
                && assetIndexes.contains("ZASSET_ZMONTHHIGHLIGHTBEINGKEYASSETPRIVATE_INDEX"),
            hasAestheticScore: assetColumns.contains("ZOVERALLAESTHETICSCORE"),
            hasUniformTypeIdentifier: assetColumns.contains("ZUNIFORMTYPEIDENTIFIER"),
            hasSpatialType: assetColumns.contains("ZSPATIALTYPE"))
        let total = ((try? db.query("SELECT SUM(ZCACHEDCOUNT) AS c FROM ZMOMENT WHERE ZSTARTDATE IS NOT NULL"))
            .flatMap { $0.first?["c"]?.int })
            // 兜底：极老的库没有 ZMOMENT 缓存计数时才退回整表计数（百万级要几秒）。
            ?? ((try? db.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)"))
                .flatMap { $0.first?["c"]?.int }) ?? 0
        let index = SystemIndex(database: db,
                                libraryURL: libraryURL,
                                name: libraryURL.deletingPathExtension().lastPathComponent,
                                total: total,
                                trueTotal: total,
                                direct: source)
        index.loadDirectCountsSnapshot()
        index.startDirectCountWarmup()
        index.startDirectGeoWarmup()
        return index
    }

    /// 探测相簿与资产的关联表（不同系统版本表名不同）。
    static func detectAlbumJoin(_ db: SQLiteDatabase)
        -> (table: String, albumColumn: String, assetColumn: String, orderColumn: String?)? {
        guard let tables = try? db.query("SELECT name FROM sqlite_master WHERE type = 'table'") else { return nil }
        for row in tables {
            guard let table = row["name"]?.string, table.hasPrefix("Z_") else { continue }
            let names = (try? db.query("PRAGMA table_info(\"\(table)\")"))?.compactMap { $0["name"]?.string } ?? []
            guard let asset = names.first(where: { $0 == "Z_3ASSETS" }),
                  let album = names.first(where: { name in
                      guard name.hasPrefix("Z_"), name.hasSuffix("ALBUMS") else { return false }
                      let middle = name.dropFirst(2).dropLast(6)
                      return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
                  }) else { continue }
            return (table, album, asset, names.first(where: { $0 == "Z_FOK_3ASSETS" }))
        }
        return nil
    }

    /// 探测官方相簿「关键照片」联接表（不同系统版本表名不同，列名也从实体编号派生）。
    static func detectKeyAssetJoin(_ db: SQLiteDatabase) -> SystemAlbumKeyAssetJoin? {
        guard let tables = try? db.query("SELECT name FROM sqlite_master WHERE type = 'table'") else { return nil }
        for row in tables {
            guard let table = row["name"]?.string, table.hasPrefix("Z_") else { continue }
            let names = (try? db.query("PRAGMA table_info(\"\(table)\")"))?.compactMap { $0["name"]?.string } ?? []
            guard names.contains("Z_3KEYASSETS"),
                  let album = names.first(where: { name in
                      guard name.hasPrefix("Z_"), name.hasSuffix("ALBUMSBEINGKEYASSETS") else { return false }
                      let middle = name.dropFirst(2).dropLast("ALBUMSBEINGKEYASSETS".count)
                      return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
                  }) else { continue }
            return SystemAlbumKeyAssetJoin(table: table,
                                           albumColumn: album,
                                           assetColumn: "Z_3KEYASSETS",
                                           orderColumn: names.first(where: { $0 == "Z_FOK_3KEYASSETS" }))
        }
        return nil
    }

    /// 图库文件的轻量指纹：主库与 WAL 的大小 + 修改时间。未变化就不必重新扫库。
    static func libraryFingerprint(_ libraryURL: URL) -> String {
        func part(_ url: URL) -> String {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)-\(Int(modified))"
        }
        let db = libraryURL.appendingPathComponent("database/Photos.sqlite")
        let wal = URL(fileURLWithPath: db.path + "-wal")
        return part(db) + "|" + part(wal)
    }

    /// 后台补齐计数。
    ///
    /// 冷启动不再一上来就扫 26GB 主表：
    /// 1. 先用 `ZMOMENT` 里 Apple 自己维护的每月数量 + 部分索引，几秒内出全部可见数字；
    /// 2. 再补封面与年 / 月样本；
    /// 3. 最后才跑一次全库精确扫描（只用于截屏 / RAW / 最近保存等没有索引的项）。
    /// 图库文件未变化时（指纹一致）整套流程直接跳过，启动只读磁盘快照。
    func startDirectCountWarmup() {
        guard let direct else { return }
        let fingerprint = Self.libraryFingerprint(libraryURL)
        // 图库没有被「照片」修改过：上次的完整快照就是最新的。
        if let snapshot = directCounts,
           snapshot.version == SystemDirectCounts.currentVersion,
           snapshot.fingerprint == fingerprint,
           snapshot.monthCounts != nil,
           snapshot.monthSamples != nil,
           snapshot.monthCovers != nil {
            return
        }
        guard directCountsWarmupTask == nil else { return }
        let libraryPath = libraryURL.path
        let previous = directCounts
        directCountsWarmupTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // 只有全库精确扫描完成后才写入指纹，避免中途退出导致下次跳过未补完的项。
            func publish(_ snapshot: SystemDirectCounts) async {
                var snapshot = snapshot
                snapshot.version = SystemDirectCounts.currentVersion
                Self.storeDirectCountsSnapshot(snapshot, libraryPath: libraryPath)
                await MainActor.run {
                    self.directCounts = snapshot
                    self.onDirectCountsReady?()
                }
            }

            var snapshot = Self.computeDirectQuickCounts(libraryURL: self.libraryURL,
                                                         previous: previous,
                                                         direct: direct)
                ?? previous
            if var value = snapshot {
                value.fingerprint = nil
                snapshot = value
                await publish(value)
            }
            // 封面：最近 4 万项扫一遍，稀有类型缺封面就显示图标。
            if var value = snapshot,
               let covers = Self.computeDirectCovers(libraryURL: self.libraryURL, counts: value) {
                value.covers = covers
                snapshot = value
                await publish(value)
            }
            // 年 / 月总览卡片样本：每个月 / 年各取最多 4 张。
            if var value = snapshot,
               let samples = Self.computeDirectOverviewSamples(libraryURL: self.libraryURL,
                                                               monthCounts: value.monthCounts ?? [:]) {
                value.monthSamples = samples.months
                value.yearSamples = samples.years
                snapshot = value
                await publish(value)
            }
            // 截屏 / 导入 / 最近查看 / 存储统计这几项没有可用的轻量索引：
            // 已有历史快照时沿用上次结果，只更新指纹；否则每次图库变动后的启动
            // 都要把 26GB 主表扫一遍（实测几十秒到几分钟），期间翻页 / 相簿全被拖慢。
            if var value = snapshot {
                if previous == nil,
                   var slow = Self.computeDirectCounts(libraryURL: self.libraryURL, direct: direct) {
                    // 第一次打开这个图库（还没有任何历史快照）：只跑一次全库精确扫描补齐。
                    slow.monthCounts = value.monthCounts
                    slow.monthVideos = value.monthVideos
                    slow.monthFavorites = value.monthFavorites
                    slow.monthSamples = value.monthSamples
                    slow.yearSamples = value.yearSamples
                    slow.monthCovers = value.monthCovers
                    slow.yearCovers = value.yearCovers
                    slow.covers = value.covers
                    slow.fingerprint = fingerprint
                    await publish(slow)
                } else {
                    value.fingerprint = fingerprint
                    snapshot = value
                    await publish(value)
                }
            }
            await MainActor.run { self.directCountsWarmupTask = nil }
        }
    }

    /// 快速计数：`ZMOMENT` 提供月 / 年数量与总数，媒体类型走 Apple 自己的部分索引，
    /// 全程只扫几万条索引项，不碰 26GB 主表。
    static func computeDirectQuickCounts(libraryURL: URL,
                                                previous: SystemDirectCounts?,
                                                direct: SystemDirectSource) -> SystemDirectCounts? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        var counts = previous ?? SystemDirectCounts()
        // 月 / 年数量与视频数直接取 ZMOMENT 的缓存计数（与官方「照片」同源）。
        guard let monthRows = try? db.query("""
            SELECT strftime('%Y-%m', ZSTARTDATE + 978307200, 'unixepoch', 'localtime') AS period,
                   SUM(ZCACHEDCOUNT) AS c, SUM(ZCACHEDVIDEOSCOUNT) AS v
            FROM ZMOMENT
            WHERE ZSTARTDATE IS NOT NULL
            GROUP BY period
            """), !monthRows.isEmpty else { return nil }
        var monthCounts: [String: Int] = [:]
        var monthVideos: [String: Int] = [:]
        var active = 0
        var videos = 0
        for row in monthRows {
            guard let period = row["period"]?.string else { continue }
            let count = row["c"]?.int ?? 0
            let videoCount = row["v"]?.int ?? 0
            monthCounts[period] = count
            monthVideos[period] = videoCount
            active += count
            videos += videoCount
        }
        counts.active = active
        counts.videos = videos
        counts.monthCounts = monthCounts
        counts.monthVideos = monthVideos
        // 收藏按月：收藏部分索引只有一万多条，顺带得到总数。
        if let rows = try? db.query("""
            SELECT strftime('%Y-%m', ZDATECREATED + 978307200, 'unixepoch', 'localtime') AS period,
                   COUNT(*) AS c
            FROM ZASSET INDEXED BY Z_Asset_forFavoritesAlbum
            WHERE ZFAVORITE = 1 AND ZTRASHEDSTATE = 0 AND ZHIDDEN = 0
            GROUP BY period
            """) {
            var monthFavorites: [String: Int] = [:]
            var total = 0
            for row in rows {
                guard let period = row["period"]?.string else { continue }
                let count = row["c"]?.int ?? 0
                monthFavorites[period] = count
                total += count
            }
            counts.monthFavorites = monthFavorites
            counts.favorites = total
        }
        // 其余媒体类型逐个走 Apple 的部分索引；索引不存在时保留上次的数值。
        func count(_ sql: String) -> Int? {
            try? db.query(sql).first?["c"]?.int
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forPortraitAlbum WHERE ZDEPTHTYPE<>0 AND ZDEPTHTYPE>0 AND ZKIND=0 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.portrait = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forSelfiesAlbum WHERE ZDERIVEDCAMERACAPTUREDEVICE=1 AND ZKIND=0 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.selfies = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forKindSubtypeAlbums WHERE ZKINDSUBTYPE<>0 AND ZKINDSUBTYPE=1 AND ZKIND=0 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.panoramas = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forKindSubtypeAlbums WHERE ZKINDSUBTYPE<>0 AND ZKINDSUBTYPE IN (2,3) AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.livePhotos = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forKindSubtypeAlbums WHERE ZKINDSUBTYPE<>0 AND ZKINDSUBTYPE=102 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.timelapse = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forSpatialAlbum WHERE ZSPATIALTYPE<>0 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.spatial = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forKindSubtypeAlbums WHERE ZKINDSUBTYPE<>0 AND ZKINDSUBTYPE=101 AND ZKIND=1 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.slowMotion = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_byPlaybackStyleIndex WHERE ZPLAYBACKSTYLE=2 AND ZKIND=0 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.animated = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_forAllPhotosPartOfDuplicatedSet WHERE ZDUPLICATEASSETVISIBILITYSTATE<>0 AND ZDUPLICATEASSETVISIBILITYSTATE>0 AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.duplicate = value
        }
        // RAW / 连拍没有对应的部分索引，但各自有一条只覆盖命中行的索引，先算出来。
        // 连拍按组计数（DISTINCT ZAVALANCHEUUID），与「连拍快照」按组展示口径一致。
        if direct.hasUniformTypeIdentifier,
           let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_byUniformTypeIdentifierIndex WHERE ZUNIFORMTYPEIDENTIFIER LIKE '%raw%' AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.raws = value
        }
        if let value = count("SELECT COUNT(DISTINCT ZAVALANCHEUUID) AS c FROM ZASSET INDEXED BY Z_Asset_byAvalancheUUIDIndex WHERE ZAVALANCHEUUID IS NOT NULL AND ZAVALANCHEUUID<>'' AND ZTRASHEDSTATE=0 AND ZHIDDEN=0") {
            counts.bursts = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_compoundIndex4 WHERE ZHIDDEN=1 AND ZTRASHEDSTATE=0") {
            counts.hidden = value
        }
        if let value = count("SELECT COUNT(*) AS c FROM ZASSET INDEXED BY Z_Asset_compoundIndex5 WHERE ZTRASHEDSTATE>=1") {
            counts.trash = value
        }
        if let row = try? db.query("SELECT MIN(ZSTARTDATE + 978307200) AS lo, MAX(ZENDDATE + 978307200) AS hi FROM ZMOMENT").first {
            counts.earliest = row["lo"]?.double
            counts.latest = row["hi"]?.double
        }
        // 年 / 月总览封面：Apple 在 ZPHOTOSHIGHLIGHT 里已经为每个周期挑好一张关键照片，
        // 直接按反向关系（ZASSET.Z*HIGHLIGHTBEINGKEYASSETPRIVATE 上的索引）取出来即可。
        if direct.hasHighlightKeyAssets {
            // 必须显式指定 ZASSET 上的反向关系索引：否则优化器会反过来扫整张 ZASSET
            // （26GB 主表上实测 51 秒）。
            func covers(kind: Int, column: String, periodFormat: String, index: String) -> [String: String] {
                guard let rows = try? db.query("""
                    SELECT strftime('\(periodFormat)', h.ZENDDATE + 978307200, 'unixepoch', 'localtime') AS period,
                           a.ZUUID AS uuid
                    FROM ZPHOTOSHIGHLIGHT h
                    JOIN ZASSET a INDEXED BY \(index) ON a.\(column) = h.Z_PK
                    WHERE h.ZKIND = \(kind) AND h.ZENDDATE IS NOT NULL
                      AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                    """) else { return [:] }
                var result: [String: String] = [:]
                for row in rows {
                    guard let period = row["period"]?.string,
                          let uuid = row["uuid"]?.string else { continue }
                    result[period] = uuid
                }
                return result
            }
            counts.monthCovers = covers(kind: 1,
                                       column: "ZMONTHHIGHLIGHTBEINGKEYASSETPRIVATE",
                                       periodFormat: "%Y-%m",
                                       index: "ZASSET_ZMONTHHIGHLIGHTBEINGKEYASSETPRIVATE_INDEX")
            counts.yearCovers = covers(kind: 2,
                                      column: "ZYEARHIGHLIGHTBEINGKEYASSETPRIVATE",
                                      periodFormat: "%Y",
                                      index: "ZASSET_ZYEARHIGHLIGHTBEINGKEYASSETPRIVATE_INDEX")
        }
        return counts
    }

    static func computeDirectCounts(libraryURL: URL, direct: SystemDirectSource) -> SystemDirectCounts? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        let cutoff = Self.directSavedCutoff.timeIntervalSince1970
        // Apple 的 RAW UTI 都含 raw（如 com.nikon.raw-image / com.adobe.dng-raw-image），
        // 比逐行拼接文件名 LIKE 快且与系统相簿一致；旧库缺列时退回扩展名。
        let rawClause = direct.hasUniformTypeIdentifier
            ? "a.ZUNIFORMTYPEIDENTIFIER LIKE '%raw%'"
            : "(lower(a.ZFILENAME) LIKE '%.dng' OR lower(a.ZFILENAME) LIKE '%.cr2' OR lower(a.ZFILENAME) LIKE '%.cr3'"
                + " OR lower(a.ZFILENAME) LIKE '%.nef' OR lower(a.ZFILENAME) LIKE '%.arw' OR lower(a.ZFILENAME) LIKE '%.raf'"
                + " OR lower(a.ZFILENAME) LIKE '%.orf' OR lower(a.ZFILENAME) LIKE '%.rw2' OR lower(a.ZFILENAME) LIKE '%.pef'"
                + " OR lower(a.ZFILENAME) LIKE '%.srw')"
        let spatialClause = direct.hasSpatialType ? "a.ZSPATIALTYPE <> 0" : "0"
        let sql = """
            SELECT
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 THEN 1 ELSE 0 END) AS active,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 1 THEN 1 ELSE 0 END) AS hidden,
              SUM(CASE WHEN a.ZTRASHEDSTATE <> 0 THEN 1 ELSE 0 END) AS trash,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZDUPLICATEASSETVISIBILITYSTATE > 0 THEN 1 ELSE 0 END) AS duplicate,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND (a.ZADDEDDATE + 978307200) >= ? THEN 1 ELSE 0 END) AS recentlySaved,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                        AND aa.ZIMPORTEDBYBUNDLEIDENTIFIER IS NOT NULL
                        AND aa.ZIMPORTEDBYBUNDLEIDENTIFIER NOT IN ('com.apple.Photos', 'com.apple.mobileslideshow')
                       THEN 1 ELSE 0 END) AS imports,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 0 AND a.ZDEPTHTYPE > 0 THEN 1 ELSE 0 END) AS portrait,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 0
                        AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10)) THEN 1 ELSE 0 END) AS screenshots,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 1 THEN 1 ELSE 0 END) AS videos,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 0 AND a.ZDERIVEDCAMERACAPTUREDEVICE = 1 THEN 1 ELSE 0 END) AS selfies,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND (a.ZKINDSUBTYPE IN (2, 3) OR a.ZPLAYBACKSTYLE = 3) THEN 1 ELSE 0 END) AS livePhotos,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 0 AND a.ZKINDSUBTYPE = 1 THEN 1 ELSE 0 END) AS panoramas,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKINDSUBTYPE = 102 THEN 1 ELSE 0 END) AS timelapse,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND 0 THEN 1 ELSE 0 END) AS cinematic,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND \(spatialClause) THEN 1 ELSE 0 END) AS spatial,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 1 AND a.ZKINDSUBTYPE = 101 THEN 1 ELSE 0 END) AS slowMotion,
              COUNT(DISTINCT CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND IFNULL(a.ZAVALANCHEUUID, '') <> '' THEN a.ZAVALANCHEUUID END) AS bursts,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 1
                        AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE = 103) THEN 1 ELSE 0 END) AS screenRecordings,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZKIND = 0 AND a.ZPLAYBACKSTYLE = 2 THEN 1 ELSE 0 END) AS animated,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                        AND \(rawClause) THEN 1 ELSE 0 END) AS raws,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZFAVORITE = 1 THEN 1 ELSE 0 END) AS favorites,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND a.ZADJUSTMENTTIMESTAMP IS NOT NULL THEN 1 ELSE 0 END) AS edited,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND (aa.ZLASTVIEWEDDATE + 978307200) >= ? THEN 1 ELSE 0 END) AS recentlyViewed,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                        AND (a.ZDATECREATED + 978307200) <= ?
                        AND (aa.ZLASTVIEWEDDATE IS NULL OR (aa.ZLASTVIEWEDDATE + 978307200) < ?)
                       THEN 1 ELSE 0 END) AS revisit,
              SUM(CASE WHEN a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                        AND a.ZLATITUDE IS NOT NULL AND a.ZLONGITUDE IS NOT NULL
                        AND ABS(a.ZLATITUDE) <= 90 AND ABS(a.ZLONGITUDE) <= 180
                        AND NOT (a.ZLATITUDE = 0 AND a.ZLONGITUDE = 0)
                        AND NOT (a.ZLATITUDE = -180.0 AND a.ZLONGITUDE = -180.0)
                       THEN 1 ELSE 0 END) AS located,
              SUM(aa.ZORIGINALFILESIZE) AS bytes,
              MIN(a.ZDATECREATED + 978307200) AS earliest,
              MAX(a.ZDATECREATED + 978307200) AS latest
            FROM ZASSET a
            LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            WHERE a.ZKIND IN (0, 1)
            """
        let viewedCutoff = Self.directViewedCutoff.timeIntervalSince1970
        let captureCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge).timeIntervalSince1970
        let viewCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitViewAge).timeIntervalSince1970
        guard let row = try? db.query(sql, [cutoff, viewedCutoff, captureCutoff, viewCutoff]).first else { return nil }
        var counts = SystemDirectCounts()
        counts.active = row["active"]?.int ?? 0
        counts.hidden = row["hidden"]?.int ?? 0
        counts.trash = row["trash"]?.int ?? 0
        counts.duplicate = row["duplicate"]?.int ?? 0
        counts.recentlySaved = row["recentlySaved"]?.int ?? 0
        counts.imports = row["imports"]?.int ?? 0
        counts.portrait = row["portrait"]?.int ?? 0
        counts.screenshots = row["screenshots"]?.int ?? 0
        counts.videos = row["videos"]?.int ?? 0
        counts.selfies = row["selfies"]?.int ?? 0
        counts.livePhotos = row["livePhotos"]?.int ?? 0
        counts.panoramas = row["panoramas"]?.int ?? 0
        counts.timelapse = row["timelapse"]?.int ?? 0
        counts.cinematic = row["cinematic"]?.int ?? 0
        counts.spatial = row["spatial"]?.int ?? 0
        counts.slowMotion = row["slowMotion"]?.int ?? 0
        counts.bursts = row["bursts"]?.int ?? 0
        counts.screenRecordings = row["screenRecordings"]?.int ?? 0
        counts.animated = row["animated"]?.int ?? 0
        counts.raws = row["raws"]?.int ?? 0
        counts.favorites = row["favorites"]?.int ?? 0
        counts.edited = row["edited"]?.int ?? 0
        counts.recentlyViewed = row["recentlyViewed"]?.int ?? 0
        counts.revisit = row["revisit"]?.int ?? 0
        counts.located = row["located"]?.int ?? 0
        counts.totalBytes = row["bytes"]?.int64 ?? 0
        counts.earliest = row["earliest"]?.double
        counts.latest = row["latest"]?.double
        return counts
    }

    /// 媒体类型卡片封面：沿 Apple 为各系统相簿维护的专用索引，各取最新一张。
    /// 只读命中行的索引项，稀有类型（全景 / 延时 / 连拍）也不会退化成扫全库。
    static func computeDirectCovers(libraryURL: URL, counts: SystemDirectCounts) -> [String: String]? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        var wanted: Set<MediaTypeKey> = []
        for key in MediaTypeKey.allCases where key != .longExposure {
            if directCount(for: key, in: counts) > 0 { wanted.insert(key) }
        }
        guard !wanted.isEmpty else { return [:] }
        // (类型, 索引名, 条件)：条件需要与部分索引的 WHERE 一致，SQLite 才肯使用索引。
        let probes: [(MediaTypeKey, String, String)] = [
            (.videos, "Z_Asset_forVideosAlbum", "a.ZPLAYBACKSTYLE = 4"),
            (.selfies, "Z_Asset_forSelfiesAlbum", "a.ZDERIVEDCAMERACAPTUREDEVICE = 1 AND a.ZKIND = 0"),
            (.livePhotos, "Z_Asset_forKindSubtypeAlbums", "a.ZKINDSUBTYPE IN (2, 3) AND a.ZKINDSUBTYPE <> 0"),
            (.portraits, "Z_Asset_forPortraitAlbum", "a.ZDEPTHTYPE <> 0"),
            (.panoramas, "Z_Asset_forKindSubtypeAlbums", "a.ZKINDSUBTYPE = 1 AND a.ZKINDSUBTYPE <> 0"),
            (.timelapse, "Z_Asset_forKindSubtypeAlbums", "a.ZKINDSUBTYPE = 102 AND a.ZKINDSUBTYPE <> 0"),
            (.spatial, "Z_Asset_forSpatialAlbum", "a.ZSPATIALTYPE <> 0"),
            (.slowMotion, "Z_Asset_forKindSubtypeAlbums", "a.ZKINDSUBTYPE = 101 AND a.ZKIND = 1 AND a.ZKINDSUBTYPE <> 0"),
            (.bursts, "Z_Asset_byAvalancheUUIDIndex", "a.ZAVALANCHEUUID IS NOT NULL AND a.ZAVALANCHEUUID <> ''"),
            (.screenshots, "Z_Asset_forAllPhotosFilteredBySavedAssetType", "a.ZKIND = 0 AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10))"),
            (.screenRecordings, "Z_Asset_forAllPhotosFilteredBySavedAssetType", "a.ZKIND = 1 AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE = 103)"),
            (.animated, "Z_Asset_byPlaybackStyleIndex", "a.ZKIND = 0 AND a.ZPLAYBACKSTYLE = 2")
        ]
        var covers: [String: String] = [:]
        for (key, index, condition) in probes where wanted.contains(key) {
            guard let row = try? db.query("""
                SELECT a.ZUUID AS uuid FROM ZASSET a INDEXED BY \(index)
                WHERE a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND \(condition)
                ORDER BY a.ZDATECREATED DESC, a.Z_PK DESC LIMIT 1
                """).first, let uuid = row["uuid"]?.string else { continue }
            covers[key.rawValue] = uuid
        }
        // RAW 没有独立的部分索引，沿 UTI 索引找最新一张（Apple 的 RAW UTI 都含 raw，如 com.nikon.raw-image）。
        if wanted.contains(.raws) {
            if let row = try? db.query("""
                SELECT a.ZUUID AS uuid FROM ZASSET a INDEXED BY Z_Asset_byUniformTypeIdentifierIndex
                WHERE a.ZUNIFORMTYPEIDENTIFIER LIKE '%raw%'
                  AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                ORDER BY a.ZDATECREATED DESC LIMIT 1
                """).first, let uuid = row["uuid"]?.string {
                covers[MediaTypeKey.raws.rawValue] = uuid
            }
        }
        return covers
    }

    /// 快照里某项媒体类型的数量（长曝光 / 电影效果来自 PhotoKit，不在这里）。
    static func directCount(for key: MediaTypeKey, in counts: SystemDirectCounts) -> Int {
        switch key {
        case .videos: return counts.videos
        case .selfies: return counts.selfies
        case .livePhotos: return counts.livePhotos
        case .portraits: return counts.portrait
        case .panoramas: return counts.panoramas
        case .timelapse: return counts.timelapse
        case .slowMotion: return counts.slowMotion
        case .bursts: return counts.bursts
        case .screenshots: return counts.screenshots
        case .screenRecordings: return counts.screenRecordings
        case .animated: return counts.animated
        case .raws: return counts.raws
        case .cinematic: return counts.cinematic
        case .spatial: return counts.spatial
        case .longExposure: return 0
        }
    }

    /// 年 / 月总览的卡片样本：每个周期最多 4 张，按日期索引做范围查询，成本只与周期数相关。
    static func computeDirectOverviewSamples(libraryURL: URL,
                                                     monthCounts: [String: Int])
        -> (months: [String: [String]], years: [String: [String]])? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func sampleUUIDs(start: Date, end: Date) -> [String] {
            let binds: [Any?] = [start.timeIntervalSince1970 - 978307200,
                                 end.timeIntervalSince1970 - 978307200]
            guard let rows = try? db.query("""
                SELECT a.ZUUID AS uuid FROM ZASSET a INDEXED BY Z_Asset_byDateCreatedIndex
                WHERE a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
                  AND a.ZDATECREATED >= ? AND a.ZDATECREATED < ?
                ORDER BY a.ZDATECREATED DESC, a.Z_PK DESC LIMIT 4
                """, binds) else { return [] }
            return rows.compactMap { $0["uuid"]?.string }
        }
        var months: [String: [String]] = [:]
        var years: [String: [String]] = [:]
        var yearKeys: Set<String> = []
        for key in monthCounts.keys {
            let parts = key.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]), let month = Int(parts[1]),
                  let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            months[key] = sampleUUIDs(start: start, end: end)
            yearKeys.insert(String(year))
        }
        for key in yearKeys {
            guard let year = Int(key),
                  let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else { continue }
            years[key] = sampleUUIDs(start: start, end: end)
        }
        return (months, years)
    }

    static func directCountsFile(libraryPath: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in libraryPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return LibraryPaths.systemIndexCacheDir
            .appendingPathComponent("DirectCounts-\(String(hash, radix: 16)).json")
    }

    func loadDirectCountsSnapshot() {
        guard let direct else { return }
        let file = Self.directCountsFile(libraryPath: libraryURL.path)
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(SystemDirectCounts.self, from: data),
              snapshot.version == SystemDirectCounts.currentVersion else { return }
        directCounts = snapshot
        _ = direct
    }

    static func storeDirectCountsSnapshot(_ snapshot: SystemDirectCounts, libraryPath: String) {
        let file = directCountsFile(libraryPath: libraryPath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - 地图数据快照

    /// 带定位照片的快照：图库没变时直接复用，跳过每次启动都要扫一遍地点索引（外接盘约数秒）。
    struct SystemDirectGeoSnapshot: Codable {
        static let currentVersion = 1
        var version: Int
        var fingerprint: String
        var photos: [PhotoItem]
    }

    static func directGeoFile(libraryPath: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in libraryPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return LibraryPaths.systemIndexCacheDir
            .appendingPathComponent("DirectGeo-\(String(hash, radix: 16)).json")
    }

    static func loadDirectGeoSnapshot(libraryPath: String,
                                              fingerprint: String) -> [PhotoItem]? {
        let file = directGeoFile(libraryPath: libraryPath)
        // 快照只适合「带定位照片不多」的图库：文件过大时不读也不写，免得解码更慢、占内存。
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.intValue < 24 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(SystemDirectGeoSnapshot.self, from: data),
              snapshot.version == SystemDirectGeoSnapshot.currentVersion,
              snapshot.fingerprint == fingerprint,
              !snapshot.photos.isEmpty else { return nil }
        return snapshot.photos
    }

    static func storeDirectGeoSnapshot(_ photos: [PhotoItem],
                                               libraryPath: String,
                                               fingerprint: String) {
        // 带定位照片很多的图库不落盘：快照会非常大，解码反而比重新扫索引更慢。
        guard photos.count <= 60_000 else { return }
        let snapshot = SystemDirectGeoSnapshot(version: SystemDirectGeoSnapshot.currentVersion,
                                               fingerprint: fingerprint,
                                               photos: photos)
        let file = directGeoFile(libraryPath: libraryPath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - SQL 片段

    var directFrom: String {
        "FROM ZASSET a LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK"
    }

    var directExtendedPrefix: String { "e." }

    /// 选中列的别名与索引库完全一致，`photo(from:)` 不需要改。
    var directSelect: String {
        let ext = directExtendedPrefix
        // 旧版图库没有 ZSPATIALTYPE：用常量 0 顶替，避免整条查询失败。
        let spatialSelect = direct?.hasSpatialType == true
            ? "CASE WHEN a.ZSPATIALTYPE <> 0 THEN 1 ELSE 0 END AS isspatial,"
            : "0 AS isspatial,"
        return """
            a.Z_PK AS pk, a.ZUUID AS uuid, a.ZFILENAME AS filename,
            CASE WHEN a.ZKIND = 1 THEN 'video'
                 WHEN a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10) THEN 'screenshot'
                 WHEN a.ZKINDSUBTYPE = 1 THEN 'panorama'
                 WHEN a.ZDERIVEDCAMERACAPTUREDEVICE = 1 THEN 'selfie'
                 WHEN COALESCE(aa.ZORIGINALWIDTH, a.ZWIDTH) > 0
                      AND COALESCE(aa.ZORIGINALHEIGHT, a.ZHEIGHT) > 0
                      AND CAST(COALESCE(aa.ZORIGINALWIDTH, a.ZWIDTH) AS REAL)
                          / COALESCE(aa.ZORIGINALHEIGHT, a.ZHEIGHT) >= 2.2 THEN 'panorama'
                 ELSE 'photo' END AS mediakind,
            (a.ZDATECREATED + 978307200) AS created,
            (COALESCE(a.ZADDEDDATE, a.ZDATECREATED) + 978307200) AS added,
            CASE WHEN a.ZTRASHEDSTATE = 0 THEN NULL ELSE (COALESCE(a.ZTRASHEDDATE, a.ZDATECREATED) + 978307200) END AS trashed,
            CASE WHEN a.ZDATECREATED IS NOT NULL THEN 0 ELSE (COALESCE(a.ZTRASHEDDATE, 0) + 978307200) END AS trasheddate,
            a.ZFAVORITE AS favorite, a.ZHIDDEN AS hidden, a.ZISDETECTEDSCREENSHOT AS screenshot,
            a.ZDEPTHTYPE AS depth, a.ZDUPLICATEASSETVISIBILITYSTATE AS duplicate,
            a.ZKINDSUBTYPE AS subtype, a.ZPLAYBACKSTYLE AS playbackstyle,
            a.ZDERIVEDCAMERACAPTUREDEVICE AS cameradevice,
            COALESCE(aa.ZORIGINALWIDTH, a.ZWIDTH) AS width,
            COALESCE(aa.ZORIGINALHEIGHT, a.ZHEIGHT) AS height,
            aa.ZORIGINALWIDTH AS originalwidth, aa.ZORIGINALHEIGHT AS originalheight,
            a.ZLATITUDE AS latitude, a.ZLONGITUDE AS longitude, a.ZDURATION AS duration,
            aa.ZORIGINALFILESIZE AS filesize,
            COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME) AS originalname,
            aa.ZTITLE AS title, aa.ZIMPORTEDBYBUNDLEIDENTIFIER AS importedby,
            aa.ZEXIFTIMESTAMPSTRING AS exifdate, aa.ZREVERSELOCATIONDATA AS placedata,
            \(ext)ZCAMERAMAKE AS make, \(ext)ZCAMERAMODEL AS model, \(ext)ZLENSMODEL AS lens,
            \(ext)ZAPERTURE AS aperture, \(ext)ZFOCALLENGTH AS focal,
            \(ext)ZSHUTTERSPEED AS shutter, \(ext)ZISO AS iso,
            CASE WHEN a.ZKIND = 1 THEN 1 ELSE 0 END AS isvideo,
            CASE WHEN a.ZKINDSUBTYPE IN (2, 3) OR a.ZPLAYBACKSTYLE = 3 THEN 1 ELSE 0 END AS islive,
            CASE WHEN IFNULL(a.ZAVALANCHEUUID, '') <> '' THEN 1 ELSE 0 END AS isburst,
            NULLIF(a.ZAVALANCHEUUID, '') AS burstuuid,
            CASE WHEN (a.ZAVALANCHEPICKTYPE & 16) <> 0 THEN 1 ELSE 0 END AS burstpick,
            CASE WHEN a.ZKIND = 1 AND a.ZKINDSUBTYPE = 101 THEN 1 ELSE 0 END AS isslow,
            CASE WHEN a.ZKIND = 1 AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE = 103) THEN 1 ELSE 0 END AS isscreenrec,
            CASE WHEN a.ZKIND = 0 AND a.ZPLAYBACKSTYLE = 2 THEN 1 ELSE 0 END AS isanimated,
            CASE WHEN a.ZKINDSUBTYPE = 102 THEN 1 ELSE 0 END AS istimelapse,
            CASE WHEN 0 THEN 1 ELSE 0 END AS iscinematic,
            \(spatialSelect)
            CASE WHEN aa.ZIMPORTEDBYBUNDLEIDENTIFIER IS NOT NULL
                      AND aa.ZIMPORTEDBYBUNDLEIDENTIFIER NOT IN ('com.apple.Photos', 'com.apple.mobileslideshow')
                 THEN 1 ELSE 0 END AS isdeviceimport,
            CASE WHEN a.ZLATITUDE IS NOT NULL AND a.ZLONGITUDE IS NOT NULL
                      AND ABS(a.ZLATITUDE) <= 90 AND ABS(a.ZLONGITUDE) <= 180
                      AND NOT (a.ZLATITUDE = 0 AND a.ZLONGITUDE = 0)
                 THEN 1 ELSE 0 END AS haslocation,
            CASE WHEN lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.dng'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.cr2'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.cr3'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.nef'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.arw'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.raf'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.orf'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.rw2'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.pef'
                   OR lower(COALESCE(NULLIF(aa.ZORIGINALFILENAME, ''), a.ZFILENAME)) LIKE '%.srw'
                 THEN 1 ELSE 0 END AS israw,
            CASE WHEN a.ZADJUSTMENTTIMESTAMP IS NOT NULL THEN 1 ELSE 0 END AS isedited,
            (aa.ZLASTVIEWEDDATE + 978307200) AS viewedat,
            (a.ZADJUSTMENTTIMESTAMP + 978307200) AS editedat,
            a.ZDIRECTORY AS directory
            """
    }

    // MARK: - 查询

    /// 每个展示范围的索引选择。
    /// Apple 在 `ZASSET` 上为各类系统相簿建了部分索引（收藏 / 人像 / 自拍 / 编辑 / 重复 / 截屏…），
    /// 这些索引只覆盖很少的行；强行走日期索引要扫过整库才能凑够一页（截屏 6 秒、重复项目 1 分半）。
    /// 返回的 `extraConditions` 用来补齐部分索引的 WHERE 条件，否则 SQLite 会报 `no query solution`。
    /// `index` 为 nil 表示交给 SQLite 自行决定（成员集合较小时比日期索引快两个数量级）。
    func directIndexPlan(for query: SystemQuery,
                                dateIndex: String) -> (index: String?, extraConditions: [String]) {
        // 「所有照片」上的筛选（工具栏的 照片 / 视频 / 截屏 / 收藏…）同样命中对应索引。
        if query.scope == .all {
            switch query.filter {
            case .screenshots:
                return ("Z_Asset_forAllPhotosFilteredBySavedAssetType", [])
            case .videos:
                return ("Z_Asset_forVideosAlbum", ["a.ZPLAYBACKSTYLE = 4"])
            case .edited:
                return ("Z_Asset_forRecentlyEdited", [])
            case .favorites where query.favoriteAdds.isEmpty && query.favoriteRemoves.isEmpty:
                return ("Z_Asset_forFavoritesAlbum", [])
            default:
                break
            }
        }
        switch query.scope {
        case .favorites:
            // 拾光里单独收藏 / 取消收藏的叠加项让条件变成 OR，部分索引无法命中，退回日期索引保证正确。
            if query.favoriteAdds.isEmpty && query.favoriteRemoves.isEmpty {
                return ("Z_Asset_forFavoritesAlbum", [])
            }
            return (dateIndex, [])
        case .videos:
            // 该部分索引以 ZPLAYBACKSTYLE = 4 为条件；实测与本库 ZKIND = 1 的集合完全一致。
            return ("Z_Asset_forVideosAlbum", ["a.ZPLAYBACKSTYLE = 4"])
        case .screenshots, .screenRecordings:
            // 这个覆盖索引带 ZKIND / ZISDETECTEDSCREENSHOT，按拍摄时间顺序流式过滤，
            // 不命中时连主表都不用回查（截屏没有单独的部分索引）。
            return ("Z_Asset_forAllPhotosFilteredBySavedAssetType", [])
        case .portraits:
            return ("Z_Asset_forPortraitAlbum", ["a.ZDEPTHTYPE <> 0"])
        case .selfies:
            return ("Z_Asset_forSelfiesAlbum", [])
        case .panoramas, .livePhotos, .timelapses, .slowMotion:
            // 部分索引只覆盖 ZKINDSUBTYPE <> 0 的少量行（全景 / 实况 / 延时 / 慢动作），
            // 比在整库日期索引上过滤快两个数量级。
            return ("Z_Asset_forKindSubtypeAlbums", ["a.ZKINDSUBTYPE <> 0"])
        case .animated:
            return ("Z_Asset_byPlaybackStyleIndex", [])
        case .cinematics:
            // 电影效果没有稳定的库字段，集合由 PhotoKit 智能相簿的 includeIDs 提供。
            return (dateIndex, [])
        case .bursts:
            // 连拍集合很小，直接命中 ZAVALANCHEUUID 索引，避免退化成扫全库后显示全部照片。
            return ("Z_Asset_byAvalancheUUIDIndex",
                    ["a.ZAVALANCHEUUID IS NOT NULL", "a.ZAVALANCHEUUID <> ''"])
        case .spatial:
            return ("Z_Asset_forSpatialAlbum", [])
        case .raws:
            return direct?.hasUniformTypeIdentifier == true
                ? ("Z_Asset_byUniformTypeIdentifierIndex", [])
                : (dateIndex, [])
        case .duplicates:
            return ("Z_Asset_forAllPhotosPartOfDuplicatedSet",
                    ["a.ZDUPLICATEASSETVISIBILITYSTATE <> 0"])
        case .edited:
            return ("Z_Asset_forRecentlyEdited", [])
        case .hidden:
            if query.hiddenAdds.isEmpty && query.hiddenRemoves.isEmpty {
                return ("Z_Asset_compoundIndex4", [])
            }
            return (dateIndex, [])
        case .trash:
            return ("Z_Asset_compoundIndex5", [])
        case .recentlySaved:
            // 覆盖索引里带 ZADDEDDATE，流式跳过不在时间窗内的照片；
            // 不能走 byAddedDate 索引：整库同一批导入时它命中几乎全部行，还要额外排序。
            return ("Z_Asset_forAllPhotos", [])
        case .withLocation:
            // 覆盖索引自带经纬度，流式跳过没有定位的照片。
            return ("Z_Asset_forPlacesAlbum", [])
        case .importSession:
            // 官方导入会话索引以 ZIMPORTSESSION 开头，只扫这个批次的成员。
            return ("Z_Asset_forAllPhotosHavingImportSession", ["a.ZIMPORTSESSION IS NOT NULL"])
        case .album, .folder, .person:
            // 人物地图只要带定位的照片：直接命中地点相簿的覆盖索引，流式跳过没有 GPS 的行。
            if query.onlyLocated { return ("Z_Asset_forPlacesAlbum", []) }
            // 小集合已在 directSQLPlan 里走成员驱动；这里只剩较大的集合，用日期索引流式取页。
            return (dateIndex, [])
        default:
            return (dateIndex, [])
        }
    }

    /// 一次分页查询的 SQL 拼装结果。
    struct DirectSQLPlan {
        var from: String
        var whereSQL: String
        var binds: [Any?]
        var extraConditions: [String]
        /// 自定义排序（相簿手动顺序等）；为空时按拍摄 / 添加时间排。
        var orderSQL: String? = nil
    }

    /// 成员集合（相簿 / 文件夹 / 人物）小于这个规模时，从成员表驱动查询。
    /// 再大就让日期索引流式取页：成员驱动要按日期排一次全部成员，几千行以上反而更慢。
    static let directMemberDrivenLimit = 5_000

    func directMemberLimit(for query: SystemQuery) -> Int? {
        switch query.scope {
        case .album(let id):
            let count = directAlbumAssetCount(id)
            return count <= Self.directMemberDrivenLimit ? count : nil
        case .folder, .person:
            let count = directSummary(query).total
            return count <= Self.directMemberDrivenLimit ? count : nil
        default:
            return nil
        }
    }

    /// 成员集合较小时从成员表驱动：SQLite 先拿到几十到几万个成员主键再回主表取一页，
    /// 否则它会在整库上挑错索引（30 张的相簿实测 16 秒）。大集合仍走日期索引游标。
    func directMemberDrivenFrom(_ query: SystemQuery) -> (from: String, binds: [Any?])? {
        let joins = """
            LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            \(direct?.hasExtended == true ? "LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK" : "")
            """
        switch query.scope {
        case .album(let id):
            guard let albumTable = direct?.albumTable,
                  let albumColumn = direct?.albumColumn else { return nil }
            let from = """
                FROM (SELECT DISTINCT j.\(direct?.assetColumn ?? "_none") AS member
                      FROM \(albumTable) j WHERE j.\(albumColumn) = ?) m
                JOIN ZASSET a ON a.Z_PK = m.member
                \(joins)
                """
            return (from, [id])
        case .folder(let id):
            let albums = directAlbumIDs(inFolder: id)
            guard !albums.isEmpty,
                  let albumTable = direct?.albumTable,
                  let albumColumn = direct?.albumColumn else { return nil }
            // 一张照片可能同时在文件夹的多个相簿里，先去重再回主表，翻页才不会重复。
            let list = albums.map(String.init).joined(separator: ",")
            let from = """
                FROM (SELECT DISTINCT j.\(direct?.assetColumn ?? "_none") AS member
                      FROM \(albumTable) j WHERE j.\(albumColumn) IN (\(list))) m
                JOIN ZASSET a ON a.Z_PK = m.member
                \(joins)
                """
            return (from, [])
        case .person(let id):
            let from = """
                FROM (SELECT DISTINCT f.ZASSETFORFACE AS member
                      FROM ZDETECTEDFACE f WHERE f.ZPERSONFORFACE = ?) m
                JOIN ZASSET a ON a.Z_PK = m.member
                \(joins)
                """
            return (from, [id])
        default:
            return nil
        }
    }

    /// 相簿的手动顺序：官方图库把用户拖拽后的顺序保存在关联表的 `Z_FOK_3ASSETS`。
    /// 即使在「照片」里按日期 / 标题排序，这个顺序也会保留，切回「自定义顺序」时原样还原。
    func directManualAlbumFrom() -> String? {
        guard let albumTable = direct?.albumTable,
              let albumColumn = direct?.albumColumn else { return nil }
        let asset = direct?.assetColumn ?? "_none"
        let order = direct?.albumOrderColumn ?? asset
        return """
            FROM (SELECT j.\(asset) AS member, j.\(order) AS manualorder
                  FROM \(albumTable) j WHERE j.\(albumColumn) = ?) m
            JOIN ZASSET a ON a.Z_PK = m.member
            LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            \(direct?.hasExtended == true ? "LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK" : "")
            """
    }

    /// 统一拼装：相簿手动顺序优先，其次成员集合驱动，其余按范围命中 Apple 的部分索引。
    func directSQLPlan(for query: SystemQuery, dateIndex: String) -> DirectSQLPlan {
        if query.manualOrder, case .album(let id) = query.scope, let from = directManualAlbumFrom() {
            let (whereSQL, binds, _) = directWhere(query, omitMemberSet: true)
            return DirectSQLPlan(from: from,
                                 whereSQL: whereSQL,
                                 binds: [id] + binds,
                                 extraConditions: [],
                                 orderSQL: "m.manualorder ASC, a.Z_PK ASC")
        }
        if directMemberLimit(for: query) != nil, let member = directMemberDrivenFrom(query) {
            let (whereSQL, binds, _) = directWhere(query, omitMemberSet: true)
            return DirectSQLPlan(from: member.from,
                                 whereSQL: whereSQL,
                                 binds: member.binds + binds,
                                 extraConditions: [])
        }
        let (whereSQL, binds, from) = directWhere(query)
        let plan = directIndexPlan(for: query, dateIndex: dateIndex)
        let hintedFrom = plan.index.map {
            from.replacingOccurrences(of: "FROM ZASSET a", with: "FROM ZASSET a INDEXED BY \($0)")
        } ?? from
        return DirectSQLPlan(from: hintedFrom,
                             whereSQL: whereSQL,
                             binds: binds,
                             extraConditions: plan.extraConditions)
    }

    /// 有效定位条件。官方图库对没有 GPS 的照片写 `(-180, -180)` 哨兵值，
    /// 只排除 `(0, 0)` 会把整库照片都当成带定位，地图中心与地点聚类全部失效。
    static let directLocationClause = """
        a.ZLATITUDE IS NOT NULL AND a.ZLONGITUDE IS NOT NULL
        AND ABS(a.ZLATITUDE) <= 90 AND ABS(a.ZLONGITUDE) <= 180
        AND NOT (a.ZLATITUDE = 0 AND a.ZLONGITUDE = 0)
        AND NOT (a.ZLATITUDE = -180.0 AND a.ZLONGITUDE = -180.0)
        """

    /// 直连模式的分页：按拍摄时间做游标分页，避免大 OFFSET 全表回扫。
    func directPage(_ query: SystemQuery, offset: Int, limit: Int) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        // 全库精确计数完成（带指纹）后，空集合直接返回：导入项目 / RAW 这类没有索引的范围
        // 一旦为空，再查一次就要扫完整个 26GB 主表。
        if let snapshot = directCounts, snapshot.fingerprint != nil {
            let empty: Bool
            switch query.scope {
            case .imports: empty = snapshot.imports == 0
            case .raws: empty = snapshot.raws == 0
            case .recentlyViewed: empty = snapshot.recentlyViewed == 0
            case .revisit: empty = snapshot.revisit == 0
            default: empty = false
            }
            if empty { return [] }
        }
        let sortExpression = query.sortKey == .addedAt ? "a.ZADDEDDATE" : "a.ZDATECREATED"
        let valueKey = query.sortKey == .addedAt ? "added" : "created"
        let direction = query.ascending ? "ASC" : "DESC"
        let comparison = query.ascending ? ">" : "<"
        let hint = query.sortKey == .addedAt ? "Z_Asset_byAddedDateIndex" : "Z_Asset_byDateCreatedIndex"
        // 成员集合小 → 从成员表驱动；其余范围命中 Apple 自己的系统相簿部分索引
        // （截屏 6 秒 → 4 毫秒，重复项目 1 分半 → 2 毫秒）。
        let plan = directSQLPlan(for: query, dateIndex: hint)
        var conditions = plan.whereSQL
        // 部分索引要求查询里出现与索引 WHERE 完全一致的条件，否则 SQLite 直接报 no query solution。
        for extra in plan.extraConditions {
            conditions += " AND \(extra)"
        }
        var allBinds = plan.binds
        // 相簿的原始顺序 / 标题排序不能按拍摄时间做游标，退回 OFFSET 分页。
        let customOrder = plan.orderSQL != nil
        let titleOrder = !customOrder && query.sortKey == .title
        var cursor: (value: Double, pk: Int64)?
        if !customOrder, !titleOrder,
           query.sortKey == .capturedAt || query.sortKey == .addedAt {
            cursor = directPageCursor(queryKey: query.key, offset: offset)
        }
        if let cursor {
            conditions += " AND ((\(sortExpression) \(comparison) ?) OR (\(sortExpression) = ? AND a.Z_PK \(comparison) ?))"
            allBinds += [cursor.value, cursor.value, cursor.pk]
        }
        allBinds += [limit, cursor == nil ? max(0, offset) : 0]
        let orderSQL: String
        if let custom = plan.orderSQL {
            orderSQL = custom
        } else if titleOrder {
            orderSQL = "lower(COALESCE(NULLIF(aa.ZTITLE, ''), a.ZFILENAME)) \(direction), a.Z_PK \(direction)"
        } else {
            orderSQL = "\(sortExpression) \(direction), a.Z_PK \(direction)"
        }
        func run(_ from: String) -> [[String: SQLiteValue]]? {
            let sql = """
                SELECT \(directSelect)
                \(from)
                WHERE \(conditions)
                ORDER BY \(orderSQL)
                LIMIT ? OFFSET ?
                """
            return try? database.query(sql, allBinds)
        }
        var rows = run(plan.from)
        if rows == nil, plan.from.contains("INDEXED BY ") {
            // 旧版 / 第三方图库缺少某个专用索引时，去掉 INDEXED BY 再试一次，保证仍能出图。
            let fallback = plan.from.replacingOccurrences(of: " INDEXED BY [A-Za-z0-9_]+",
                                                          with: "",
                                                          options: .regularExpression)
            rows = run(fallback)
        }
        guard let rows else { return [] }
        let photos = rows.compactMap { directPhoto(from: $0) }
        if let lastRow = rows.last, let value = lastRow[valueKey]?.double {
            rememberDirectPageCursor(queryKey: query.key,
                                     offset: offset + photos.count,
                                     value: value - 978307200,
                                     pk: lastRow["pk"]?.int64 ?? 0)
        }
        return photos
    }

    /// 直连模式的总数：只用快照 / 系统自带计数，绝不在主线程扫全库。
    func directSummary(_ query: SystemQuery) -> PhotoQuerySummary {
        let snapshot = directCounts
        // 带搜索词、筛选或时间区间时快照回答不了：直接数 Photos.sqlite。
        // 调用方（窗口 / 总览加载）都在后台线程，不会卡住主线程。
        if !query.tokens.isEmpty || query.filter != .all
            || query.startDate != nil || query.endDate != nil {
            return directSQLSummary(query)
        }
        switch query.scope {
        case .all where query.filter == .all && query.tokens.isEmpty:
            return PhotoQuerySummary(total: snapshot?.active ?? trueTotal, videos: snapshot?.videos ?? 0)
        case .favorites:
            return PhotoQuerySummary(total: snapshot?.favorites ?? snapshot?.active ?? 0, videos: 0)
        case .edited:
            return PhotoQuerySummary(total: snapshot?.edited ?? 0, videos: 0)
        case .recentlySaved:
            return PhotoQuerySummary(total: snapshot?.recentlySaved ?? 0, videos: 0)
        case .recentlyViewed:
            return PhotoQuerySummary(total: snapshot?.recentlyViewed ?? 0, videos: 0)
        case .revisit:
            return PhotoQuerySummary(total: snapshot?.revisit ?? 0, videos: 0)
        case .imports:
            return PhotoQuerySummary(total: snapshot?.imports ?? 0, videos: 0)
        case .importSession(let id):
            // 官方已缓存每个导入会话的项目数，主键查询即可。
            let count = (try? database.query("SELECT ZCACHEDCOUNT AS c FROM ZGENERICALBUM WHERE Z_PK = ?", [id])
                .first?["c"]?.int) ?? 0
            return PhotoQuerySummary(total: count, videos: 0)
        case .duplicates:
            return PhotoQuerySummary(total: snapshot?.duplicate ?? 0, videos: 0)
        case .withLocation:
            return PhotoQuerySummary(total: snapshot?.located ?? 0, videos: 0)
        case .videos:
            return PhotoQuerySummary(total: snapshot?.videos ?? 0, videos: snapshot?.videos ?? 0)
        case .screenshots:
            return PhotoQuerySummary(total: snapshot?.screenshots ?? 0, videos: 0)
        case .selfies:
            return PhotoQuerySummary(total: snapshot?.selfies ?? 0, videos: 0)
        case .livePhotos:
            return PhotoQuerySummary(total: snapshot?.livePhotos ?? 0, videos: 0)
        case .panoramas:
            return PhotoQuerySummary(total: snapshot?.panoramas ?? 0, videos: 0)
        case .timelapses:
            return PhotoQuerySummary(total: snapshot?.timelapse ?? 0, videos: 0)
        case .slowMotion:
            return PhotoQuerySummary(total: snapshot?.slowMotion ?? 0, videos: 0)
        case .cinematics:
            // 电影效果没有稳定的库字段，数量取 PhotoKit 智能相簿的 ID 集合。
            return PhotoQuerySummary(total: query.includeIDs?.count ?? 0, videos: 0)
        case .spatial:
            return PhotoQuerySummary(total: snapshot?.spatial ?? 0, videos: 0)
        case .longExposures:
            // 长曝光仍由 PhotoKit 智能相簿提供 ID 集合；数量取 ID 数量，避免返回占位值。
            return PhotoQuerySummary(total: query.includeIDs?.count ?? 0, videos: 0)
        case .bursts:
            // 连拍快照按组计数（v4 快照起 bursts 即组数，与官方「照片」一致）。
            return PhotoQuerySummary(total: snapshot?.bursts ?? 0, videos: 0)
        case .screenRecordings:
            return PhotoQuerySummary(total: snapshot?.screenRecordings ?? 0, videos: 0)
        case .animated:
            return PhotoQuerySummary(total: snapshot?.animated ?? 0, videos: 0)
        case .raws:
            return PhotoQuerySummary(total: snapshot?.raws ?? 0, videos: 0)
        case .portraits:
            return PhotoQuerySummary(total: snapshot?.portrait ?? 0, videos: 0)
        case .hidden:
            return PhotoQuerySummary(total: snapshot?.hidden ?? 0, videos: 0)
        case .trash:
            return PhotoQuerySummary(total: snapshot?.trash ?? 0, videos: 0)
        case .album(let id):
            return PhotoQuerySummary(total: directAlbumAssetCount(id), videos: 0)
        case .folder(let id):
            let total = directAlbumIDs(inFolder: id).reduce(0) { $0 + directAlbumAssetCount($1) }
            return PhotoQuerySummary(total: total, videos: 0)
        case .person(let id):
            // 逐张统计要扫这个人的全部照片；人物表自带的面部计数是主键查询，够用来分页。
            let count = (try? database.query("SELECT ZFACECOUNT AS c FROM ZPERSON WHERE Z_PK = ?", [id])
                .first?["c"]?.int) ?? 0
            return PhotoQuerySummary(total: count, videos: 0)
        default:
            // 其它范围等后台计数快照到达（占位值让网格先能翻页，不阻塞主线程）。
            return PhotoQuerySummary(total: 10_001, videos: 0)
        }
    }

    /// 搜索 / 筛选条件下的真实总数与视频数（快照只覆盖固定范围）。
    func directSQLSummary(_ query: SystemQuery) -> PhotoQuerySummary {
        // 这里不走 `directSQLPlan`：它为了分页会先探成员集合，而成员数量又回到 `directSummary`，
        // 带搜索词时会互相递归。计数只关心 WHERE，直接用基础 FROM 即可。
        let (whereSQL, binds, from) = directWhere(query)
        let sql = """
            SELECT COUNT(*) AS c,
                   SUM(CASE WHEN a.ZKIND = 1 THEN 1 ELSE 0 END) AS v
            \(from) WHERE \(whereSQL)
            """
        guard let row = try? database.query(sql, binds).first else {
            return PhotoQuerySummary(total: 10_001, videos: 0)
        }
        return PhotoQuerySummary(total: row["c"]?.int ?? 0, videos: row["v"]?.int ?? 0)
    }

    /// 媒体类型总览：数量与封面都取后台快照，不在主线程逐类扫库。
    func directMediaTypeSummary() -> MediaTypeSummary {
        var summary = MediaTypeSummary()
        guard let s = directCounts else { return summary }
        summary.counts[.videos] = s.videos
        summary.counts[.screenshots] = s.screenshots
        summary.counts[.selfies] = s.selfies
        summary.counts[.livePhotos] = s.livePhotos
        summary.counts[.panoramas] = s.panoramas
        summary.counts[.timelapse] = s.timelapse
        summary.counts[.slowMotion] = s.slowMotion
        summary.counts[.bursts] = s.bursts
        summary.counts[.screenRecordings] = s.screenRecordings
        summary.counts[.animated] = s.animated
        summary.counts[.raws] = s.raws
        summary.counts[.portraits] = s.portrait
        summary.counts[.cinematic] = s.cinematic
        summary.counts[.spatial] = s.spatial
        if let covers = s.covers, !covers.isEmpty {
            let ids = covers.values.compactMap(UUID.init(uuidString:))
            let photos = directPhotos(ids: ids)
            let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
            for (key, uuidString) in covers {
                guard let type = MediaTypeKey(rawValue: key),
                      let id = UUID(uuidString: uuidString),
                      let photo = byID[id] else { continue }
                summary.covers[type] = photo
            }
        }
        return summary
    }

    func directSidebarCounts() -> SystemIndexCounts {
        var counts = SystemIndexCounts()
        guard let snapshot = directCounts else { return counts }
        counts.active = snapshot.active
        counts.hidden = snapshot.hidden
        counts.trash = snapshot.trash
        counts.duplicate = snapshot.duplicate
        counts.recentlySaved = snapshot.recentlySaved
        counts.imports = snapshot.imports
        counts.portrait = snapshot.portrait
        counts.screenshots = snapshot.screenshots
        counts.totalBytes = snapshot.totalBytes
        counts.earliest = snapshot.earliest.map { Date(timeIntervalSince1970: $0) }
        counts.latest = snapshot.latest.map { Date(timeIntervalSince1970: $0) }
        return counts
    }

    func directPhoto(id: UUID) -> PhotoItem? {
        guard let rows = try? database.query("SELECT \(directSelect) \(directFrom) WHERE a.ZUUID = ? LIMIT 1",
                                             [id.uuidString]), let row = rows.first else { return nil }
        return directPhoto(from: row)
    }

    func directPhotos(ids: [UUID]) -> [PhotoItem] {
        guard !ids.isEmpty else { return [] }
        let list = inList(ids.map(\.uuidString))
        guard let rows = try? database.query("SELECT \(directSelect) \(directFrom) WHERE a.ZUUID IN (\(list))") else {
            return []
        }
        let byID = Dictionary(rows.compactMap { row -> (UUID, PhotoItem)? in
            guard let item = directPhoto(from: row) else { return nil }
            return (item.id, item)
        }, uniquingKeysWith: { first, _ in first })
        // 输入 ID 可能重复（例如多个场景共用同一张封面），这里逐项取值但去重。
        var seen: Set<UUID> = []
        return ids.compactMap { byID[$0] }.filter { seen.insert($0.id).inserted }
    }
}
