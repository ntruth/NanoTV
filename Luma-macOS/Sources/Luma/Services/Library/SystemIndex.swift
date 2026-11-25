import Foundation

enum SystemIndexError: LocalizedError {
    case invalidLibrary
    case buildFailed(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidLibrary: return "不是有效的照片图库（缺少 database/Photos.sqlite）"
        case .buildFailed(let message): return "无法建立系统图库索引：\(message)"
        case .unreadable(let message): return "无法读取系统图库索引：\(message)"
        }
    }
}

/// 系统图库索引的聚合结果。
struct SystemIndexCounts {
    var active = 0
    var hidden = 0
    var trash = 0
    var duplicate = 0
    var recentlySaved = 0
    var imports = 0
    var portrait = 0
    var screenshots = 0
    var totalBytes: Int64 = 0
    var earliest: Date?
    var latest: Date?
}

/// 系统「照片」图库的元数据索引（`resources/system-cache/SystemIndex-<hash>.sqlite`）。
///
/// 百万级图库不再把整库 `[PhotoItem]` 装进内存：网格、计数、年/月总览、相簿与人物
/// 全部按窗口查询这个只读索引，常驻内存只有当前页与相簿名这类小数据。
/// `Photos.sqlite` 始终只读，索引文件写在当前图库自己的 `resources/system-cache/`。
final class SystemIndex {
    /// schema 或字段映射变化时递增，旧索引自动失效。
    /// v2：人物收录未命名聚类（与官方「照片」人物列表对齐），旧索引需要重建。
    /// v4：相簿 / 文件夹改用 Z_FOK_PARENTFOLDER 手动排序键，与官方「照片」侧边栏顺序对齐。
    /// v5：新增延时摄影标记（ZKINDSUBTYPE = 102）。
    /// v6：移除载入上限，索引始终收录整库，旧索引需要重建。
    /// v7：people 表新增关键人脸几何（facecx / facecy / facesize），
    /// 人物头像按官方「照片」的人脸口径现算裁切，旧索引需要重建。
    /// v8：assets 表新增连拍分组（burstuuid / burstpick），
    /// 「连拍快照」改为按组展示代表照片，旧索引需要重建。
    /// v9：人物裁切图改为只取与关键照片一致的那条（官方头像口径），旧索引需要重建。
    /// v10：共享相簿项目的缩略图改取 scopes/cloudsharing 下的封面帧，旧索引需要重建。
    static let version = 10
    /// 低于这个规模继续沿用内存快照（小库启动更快）。
    static let largeLibraryThreshold = 100_000

    let database: SQLiteDatabase
    let libraryURL: URL
    let name: String
    /// 索引里收录的项目数。
    let total: Int
    /// 图库真实总数。
    let trueTotal: Int
    let hasDerivatives: Bool
    /// 非空表示直连模式：database 指向系统 `Photos.sqlite`，不再维护本地索引。
    let direct: SystemDirectSource?
    /// 直连模式的侧边栏计数快照（精确值由后台任务补齐）。
    var directCounts: SystemDirectCounts?
    var directCountsWarmupTask: Task<Void, Never>?
    /// 直连模式的地图 / 位置数据（全量带定位照片），由后台任务填充。
    var directGeoPhotos: [PhotoItem]?
    /// 直连模式的地点名 → 资产 UUID：地名只存在二进制归档里，搜索时按它换算成 SQL 条件。
    var directPlaceTokenIndex: [String: [String]]?
    /// 导入批次概览缓存：一个批次的拍摄跨度不会变，按会话 id 缓存。
    var directImportSummaryCache: [Int64: SystemImportSessionSummary] = [:]
    var directGeoWarmupTask: Task<Void, Never>?
    /// 后台快照就绪时通知界面刷新（侧边栏计数、地图样本共用）。
    var onDirectCountsReady: (() -> Void)?
    var directPageCursors: [String: (offset: Int, value: Double, pk: Int64)] = [:]
    let directCursorLock = NSLock()
    /// 直连模式的时间轴密度（官方 `ZMOMENT` 的每个时刻与项目数），滚动条定位用。
    var directTimelineBuckets: [SystemTimelineBucket]?
    let directTimelineLock = NSLock()
    /// 相簿封面 / 数量的直连缓存：相簿概览会在 SwiftUI body 里逐个读取，
    /// 每次都查库会让上万相簿的滚动持续卡顿。系统库只读，本会话内不会变化。
    var directAlbumPreviewCache: [String: [PhotoItem]] = [:]
    var directImportSessionsCache: [SystemImportSession]?
    var directImportCoverCache: [Int64: PhotoItem] = [:]
    var directAlbumFirstCache: [Int64: PhotoItem] = [:]
    var directAlbumCountCache: [Int64: Int] = [:]
    var directFolderAlbumsCache: [Int64: [Int64]] = [:]
    /// 官方相簿 / 文件夹的父子表：整库只扫一次，侧边栏逐层展开时不再重复读 `ZGENERICALBUM`。
    var directFolderChildrenMap: [Int64: [Int64]]?
    var directFolderKindsMap: [Int64: Int]?
    var directFolderPreviewCache: [String: [UUID]] = [:]
    let directAlbumCacheLock = NSLock()

    init(database: SQLiteDatabase,
         libraryURL: URL,
         name: String,
         total: Int,
         trueTotal: Int,
         direct: SystemDirectSource? = nil) {
        self.database = database
        self.libraryURL = libraryURL
        self.name = name
        self.total = total
        self.trueTotal = trueTotal
        self.direct = direct
        self.hasDerivatives = FileManager.default.fileExists(
            atPath: LibraryPaths.systemDerivatives(libraryURL: libraryURL).path)
    }

    // MARK: - 打开 / 建立

    /// 官方图库的项目总数（含隐藏与最近删除，不含视频外的其它类型）。
    static func assetCount(libraryURL: URL) -> Int? {
        let url = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: url.path, readonly: true) else { return nil }
        return try? db.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)")
            .first?["c"]?.int
    }

    /// 官方「照片」图库自带的关键词：`ZKEYWORD` 通过 `Z_1KEYWORDS` 关联到
    /// `ZADDITIONALASSETATTRIBUTES`，再由 `ZASSET` 得到资产 UUID。
    /// 返回「关键词 → 资产（按拍摄时间从新到旧）」及反查表；Photos.sqlite 只读。
    static func nativeKeywordMap(libraryURL: URL)
        -> (byKeyword: [String: [UUID]], byAsset: [UUID: [String]]) {
        let url = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: url.path, readonly: true) else {
            return ([:], [:])
        }
        let sql = """
            SELECT k.ZTITLE AS title, a.ZUUID AS uuid
            FROM ZKEYWORD k
            JOIN Z_1KEYWORDS j ON j.Z_53KEYWORDS = k.Z_PK
            JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK = j.Z_1ASSETATTRIBUTES
            JOIN ZASSET a ON a.Z_PK = aa.ZASSET
            WHERE a.ZKIND IN (0, 1)
            ORDER BY k.ZTITLE ASC, a.ZDATECREATED DESC
            """
        guard let rows = try? db.query(sql) else { return ([:], [:]) }
        var byKeyword: [String: [UUID]] = [:]
        var byAsset: [UUID: [String]] = [:]
        for row in rows {
            guard let title = row["title"]?.string, !title.isEmpty,
                  let raw = row["uuid"]?.string,
                  let id = UUID(uuidString: raw) else { continue }
            byKeyword[title, default: []].append(id)
            byAsset[id, default: []].append(title)
        }
        return (byKeyword, byAsset)
    }

    /// 只查某一个关键词命中的资产：先在小表 `ZKEYWORD` 里筛，再按 PK 关联，
    /// 避免每次搜索都把整个关键词关联表 join 一遍（百万级图库上要好几秒）。
    /// `limit == 0` 表示不限制条数。
    static func nativeKeywordAssetIDs(libraryURL: URL, keyword: String, limit: Int = 0) -> [UUID] {
        let url = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: url.path, readonly: true) else { return [] }
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let keywordRows = (try? db.query("SELECT Z_PK AS pk FROM ZKEYWORD WHERE ZTITLE LIKE ? ESCAPE '\\'",
                                         ["%\(escaped)%"])) ?? []
        let pks = keywordRows.compactMap { $0["pk"]?.int64 }
        guard !pks.isEmpty else { return [] }
        let list = pks.map(String.init).joined(separator: ",")
        let sql = """
            SELECT a.ZUUID AS uuid FROM Z_1KEYWORDS j
            JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.Z_PK = j.Z_1ASSETATTRIBUTES
            JOIN ZASSET a ON a.Z_PK = aa.ZASSET
            WHERE a.ZKIND IN (0, 1) AND j.Z_53KEYWORDS IN (\(list))
            ORDER BY a.ZDATECREATED DESC
            \(limit > 0 ? "LIMIT \(limit)" : "")
            """
        guard let rows = try? db.query(sql) else { return [] }
        return rows.compactMap { row in
            row["uuid"]?.string.flatMap(UUID.init(uuidString:))
        }
    }

    /// 打开已存在且与当前图库匹配的索引；不匹配返回 nil。
    static func openIfFresh(libraryURL: URL) -> SystemIndex? {
        guard let file = LibraryPaths.systemIndexFile(for: libraryURL),
              FileManager.default.fileExists(atPath: file.path),
              let signature = signature(for: libraryURL),
              let db = try? SQLiteDatabase(path: file.path, readonly: true) else { return nil }
        guard let meta = metaValues(db),
              meta["version"] == String(version),
              meta["signature"] == signature,
              let total = Int(meta["total"] ?? ""),
              let trueTotal = Int(meta["trueTotal"] ?? "") else { return nil }
        return SystemIndex(database: db,
                           libraryURL: libraryURL,
                           name: meta["name"] ?? libraryURL.deletingPathExtension().lastPathComponent,
                           total: total,
                           trueTotal: trueTotal)
    }

    /// 返回可用索引：命中缓存直接打开，否则从 `Photos.sqlite` 重建。
    /// 建立失败时抛错，由调用方回退到内存快照。
    /// `onBatch` 让重建过程也能逐批把照片交给界面，百万级图库不必等索引写完才出图。
    static func prepare(libraryURL: URL,
                        progress: ((Int) -> Void)? = nil,
                        isCancelled: () -> Bool = { false },
                        onBatch: (([PhotoItem]) -> Void)? = nil) throws -> SystemIndex {
        if let fresh = openIfFresh(libraryURL: libraryURL) {
            progress?(fresh.total)
            return fresh
        }
        return try build(libraryURL: libraryURL,
                         progress: progress,
                         isCancelled: isCancelled,
                         onBatch: onBatch)
    }

    static func metaValues(_ db: SQLiteDatabase) -> [String: String]? {
        guard let rows = try? db.query("SELECT key, value FROM meta") else { return nil }
        var meta: [String: String] = [:]
        for row in rows {
            if let key = row["key"]?.string, let value = row["value"]?.string {
                meta[key] = value
            }
        }
        return meta
    }

    /// 以 Photos.sqlite 的大小与修改时间判断图库是否变化。
    static func signature(for libraryURL: URL) -> String? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let values = try? dbURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    static func build(libraryURL: URL,
                              progress: ((Int) -> Void)?,
                              isCancelled: () -> Bool,
                              onBatch: (([PhotoItem]) -> Void)?) throws -> SystemIndex {
        let sourceURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SystemIndexError.invalidLibrary
        }
        guard let destination = LibraryPaths.systemIndexFile(for: libraryURL),
              let signature = signature(for: libraryURL) else {
            throw SystemIndexError.buildFailed("无法定位索引文件")
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let cacheDir = destination.deletingLastPathComponent()
        // 先清掉上一次中断的构建残留（含 -wal / -shm，单个可达数百 MB）。
        if let stale = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for url in stale where url.lastPathComponent.hasPrefix("SystemIndex-build-") {
                try? fm.removeItem(at: url)
            }
        }
        let temp = cacheDir
            .appendingPathComponent("SystemIndex-build-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? fm.removeItem(at: URL(fileURLWithPath: temp.path + suffix))
            }
        }

        let source = try SQLiteDatabase(path: sourceURL.path, readonly: true)
        // 索引建完只做只读打开，临时库不启用 WAL：避免主文件搬走后旁路文件留在原地，
        // 只读连接拿不到 -wal / -shm 时会直接 SQLITE_CANTOPEN（表现为图库永远转圈）。
        let target = try SQLiteDatabase(path: temp.path, readonly: false, wal: false)
        try target.execute("PRAGMA journal_mode=OFF;")
        try target.execute("PRAGMA synchronous=OFF;")
        try target.execute("PRAGMA temp_store=MEMORY;")

        // 逐列探测，兼容旧版图库缺失列。
        let additionalColumns = (try? source.query("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)"))?
            .compactMap { $0["name"]?.string } ?? []
        let assetColumns = (try? source.query("PRAGMA table_info(ZASSET)"))?
            .compactMap { $0["name"]?.string } ?? []
        let placeColumn = additionalColumns.contains("ZREVERSELOCATIONDATA") ? "aa.ZREVERSELOCATIONDATA" : "NULL"
        let titleColumn = additionalColumns.contains("ZTITLE") ? "aa.ZTITLE" : "NULL"
        let subtypeColumn = assetColumns.contains("ZKINDSUBTYPE") ? "a.ZKINDSUBTYPE" : "NULL"
        let avalancheColumn = assetColumns.contains("ZAVALANCHEUUID") ? "a.ZAVALANCHEUUID" : "NULL"
        let avalanchePickColumn = assetColumns.contains("ZAVALANCHEPICKTYPE") ? "a.ZAVALANCHEPICKTYPE" : "NULL"
        let playbackStyleColumn = assetColumns.contains("ZPLAYBACKSTYLE") ? "a.ZPLAYBACKSTYLE" : "NULL"
        let cameraDeviceColumn = assetColumns.contains("ZDERIVEDCAMERACAPTUREDEVICE")
            ? "a.ZDERIVEDCAMERACAPTUREDEVICE" : "NULL"
        let adjustmentColumn = assetColumns.contains("ZADJUSTMENTTIMESTAMP")
            ? "a.ZADJUSTMENTTIMESTAMP" : "NULL"
        let lastViewedColumn = additionalColumns.contains("ZLASTVIEWEDDATE") ? "aa.ZLASTVIEWEDDATE" : "NULL"

        // 与内存快照扫描保持一致：一律按拍摄日期从新到旧读取。
        // 用子查询固定顺序后 CROSS JOIN，避免在 JOIN 结果上直接 ORDER BY
        // （百万级图库会让 SQLite 做几十秒的临时排序），
        // 同时保证边建索引边显示时视频 / 截屏等分类能尽早出图。
        let assetSource: String
        let binds: [Any?] = []
        let orderClause = ""
        if assetColumns.contains("ZDATECREATED") {
            assetSource = """
                FROM (
                    SELECT Z_PK FROM ZASSET
                    WHERE ZDATECREATED IS NOT NULL
                    ORDER BY ZDATECREATED DESC
                    LIMIT -1
                ) picked
                CROSS JOIN ZASSET a ON a.Z_PK = picked.Z_PK
                """
        } else {
            assetSource = "FROM ZASSET a"
        }

        try target.transaction {
            try createSchema(target)
        }

        var inserted = 0
        var rows: [[Any?]] = []
        rows.reserveCapacity(500)
        // 逐批交给界面的照片（建索引期间先显示）。
        var batchItems: [PhotoItem] = []
        batchItems.reserveCapacity(500)
        var liveVideoByStem: [String: String] = [:]
        let trueTotal = (try? source.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)")
            .first?["c"]?.int) ?? 0
        let derivativeCheck = FileManager.default.fileExists(
            atPath: LibraryPaths.systemDerivatives(libraryURL: libraryURL).path)

        let insertSQL = """
            INSERT INTO assets(
                pk, uuid, filename, origpath, thumbpath, mediakind, subtype, playbackstyle,
                cameradevice, favorite, hidden, screenshot, trashed, trasheddate, depth, duplicate,
                created, added, width, height, latitude, longitude, duration,
                filesize, originalwidth, originalheight, originalname, title, importedby, exifdate,
                placedata, placecountry, placeprovince, placecity, placedistrict, placepoi,
                make, model, lens, aperture, focal, shutter, iso,
                isvideo, islive, isburst, isslow, isscreenrec, isanimated, isdeviceimport,
                istimelapse,
                haslocation, israw, isedited, livevideopath, viewedat, editedat, inalbum, stem,
                burstuuid, burstpick
            ) VALUES (\(Array(repeating: "?", count: 61).joined(separator: ",")))
            """

        try target.transaction {
            try source.forEachRow("""
                SELECT a.Z_PK AS pk, a.ZUUID AS uuid, a.ZFILENAME AS filename,
                       a.ZDIRECTORY AS directory, a.ZKIND AS kind,
                       \(subtypeColumn) AS subtype,
                       \(avalancheColumn) AS avalanche,
                       \(avalanchePickColumn) AS avalanchepick,
                       \(playbackStyleColumn) AS playbackstyle,
                       \(cameraDeviceColumn) AS cameradevice,
                       \(adjustmentColumn) AS adjustmentdate,
                       \(lastViewedColumn) AS lastviewed,
                       a.ZFAVORITE AS favorite, a.ZHIDDEN AS hidden,
                       a.ZISDETECTEDSCREENSHOT AS screenshot,
                       a.ZTRASHEDSTATE AS trashed, a.ZTRASHEDDATE AS trasheddate,
                       a.ZDEPTHTYPE AS depth, a.ZDUPLICATEASSETVISIBILITYSTATE AS duplicate,
                       a.ZDATECREATED AS created, a.ZADDEDDATE AS added,
                       a.ZWIDTH AS width, a.ZHEIGHT AS height,
                       a.ZLATITUDE AS latitude, a.ZLONGITUDE AS longitude,
                       a.ZDURATION AS duration,
                       aa.ZORIGINALFILESIZE AS filesize,
                       aa.ZORIGINALWIDTH AS originalwidth, aa.ZORIGINALHEIGHT AS originalheight,
                       aa.ZORIGINALFILENAME AS originalname,
                       \(titleColumn) AS title,
                       aa.ZIMPORTEDBYBUNDLEIDENTIFIER AS importedby,
                       aa.ZEXIFTIMESTAMPSTRING AS exifdate,
                       \(placeColumn) AS placedata,
                       e.ZCAMERAMAKE AS make, e.ZCAMERAMODEL AS model, e.ZLENSMODEL AS lens,
                       e.ZAPERTURE AS aperture, e.ZFOCALLENGTH AS focal,
                       e.ZSHUTTERSPEED AS shutter, e.ZISO AS iso
                \(assetSource)
                LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
                LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK
                WHERE a.ZKIND IN (0, 1)
                \(orderClause)
                """, binds) { row in
                if isCancelled() { throw SystemIndexError.buildFailed("已取消") }
                guard let pk = row["pk"]?.int64,
                      let uuidString = row["uuid"]?.string,
                      let uuid = UUID(uuidString: uuidString),
                      let filename = row["filename"]?.string else { return }
                let directory = row["directory"]?.string ?? String(uuidString.prefix(1))
                let originalURL = libraryURL
                    .appendingPathComponent("originals")
                    .appendingPathComponent(directory)
                    .appendingPathComponent(filename)
                let isVideo = (row["kind"]?.int ?? 0) == 1
                let stem = originalURL.deletingPathExtension().lastPathComponent.lowercased()
                if isVideo {
                    liveVideoByStem[stem] = originalURL.path
                }

                let width = row["originalwidth"]?.int ?? row["width"]?.int ?? 0
                let height = row["originalheight"]?.int ?? row["height"]?.int ?? 0
                let isScreenshot = row["screenshot"]?.bool ?? false
                let subtype = row["subtype"]?.int ?? 0
                let playbackStyle = row["playbackstyle"]?.int ?? 0
                let isSelfie = (row["cameradevice"]?.int ?? 0) == 1

                var kind: MediaKind = isVideo ? .video : .photo
                if !isVideo, isScreenshot || subtype == 6 || subtype == 10 {
                    kind = .screenshot
                } else if !isVideo, subtype == 1 {
                    kind = .panorama
                } else if !isVideo, isSelfie {
                    kind = .selfie
                } else if !isVideo, width > 0, height > 0,
                          CGFloat(width) / CGFloat(height) >= 2.2 {
                    kind = .panorama
                }

                let created = coreDataDate(row["created"])
                let added = coreDataDate(row["added"]) ?? created ?? Date()
                let captured = created ?? parseEXIFDate(row["exifdate"]?.string) ?? added
                let isLive = subtype == 2 || subtype == 3 || playbackStyle == 3
                let placedata = row["placedata"]?.data
                let place = placedata.flatMap { ReverseGeoArchive.decode($0) }
                let latitude = row["latitude"]?.double
                let longitude = row["longitude"]?.double
                let hasLocation = CoordinateValidator.isValid(latitude: latitude, longitude: longitude)
                let originalName = row["originalname"]?.string ?? filename
                let ext = (originalName as NSString).pathExtension.lowercased()
                let isRAW = Self.rawExtensions.contains(ext)
                let importedBy = row["importedby"]?.string
                let isDeviceImport = importedBy != nil
                    && importedBy != "com.apple.Photos"
                    && importedBy != "com.apple.mobileslideshow"
                let trashed = (row["trashed"]?.bool ?? false) ? (coreDataDate(row["trasheddate"]) ?? Date()) : nil
                let editedAt = coreDataDate(row["adjustmentdate"])
                let thumbPath = derivativeCheck
                    ? LibraryPaths.systemDerivativePath(libraryURL: libraryURL,
                                                        assetID: uuid,
                                                        isVideo: isVideo,
                                                        directory: directory)
                    : nil

                // 建索引期间先把这一行变成可显示的照片，交给界面边读边显示。
                if onBatch != nil {
                    var item = PhotoItem(
                        id: uuid,
                        filename: filename,
                        editedFilename: nil,
                        originalName: originalName,
                        capturedAt: captured,
                        addedAt: added,
                        pixelWidth: width,
                        pixelHeight: height,
                        fileSize: row["filesize"]?.int64 ?? 0,
                        kind: kind
                    )
                    item.isFavorite = row["favorite"]?.bool ?? false
                    item.isHidden = row["hidden"]?.bool ?? false
                    item.isPortraitCapture = (row["depth"]?.int ?? 0) > 0
                    item.isDuplicateItem = (row["duplicate"]?.int ?? 0) > 0
                    item.isLivePhoto = isLive
                    item.isBurstItem = (row["avalanche"]?.string).map { !$0.isEmpty } ?? false
                    item.isSlowMotion = isVideo && subtype == 101
                    item.isScreenRecording = isVideo && (isScreenshot || subtype == 103)
                    item.isAnimated = !isVideo && playbackStyle == 2
                    item.isTimelapse = isVideo && subtype == 102
                    item.viewedAt = coreDataDate(row["lastviewed"])
                    item.editedAt = editedAt
                    item.title = trimmed(row["title"]?.string)
                    item.isDeviceImport = isDeviceImport
                    item.deletedAt = trashed
                    item.duration = row["duration"]?.double
                    if hasLocation {
                        item.latitude = latitude
                        item.longitude = longitude
                        if let place {
                            item.placeCountry = place.country
                            item.placeProvince = place.province
                            item.placeCity = place.city
                            item.placeDistrict = place.district
                            item.placePOI = place.poi
                        }
                    }
                    item.make = trimmed(row["make"]?.string)
                    item.model = trimmed(row["model"]?.string)
                    item.lens = trimmed(row["lens"]?.string)
                    if let aperture = row["aperture"]?.double {
                        item.aperture = String(format: "ƒ/%.1f", aperture)
                    }
                    if let focal = row["focal"]?.double {
                        item.focalLength = String(format: "%.0f mm", focal)
                    }
                    if let shutter = row["shutter"]?.double, shutter > 0 {
                        item.shutterSpeed = shutter < 1
                            ? String(format: "1/%d 秒", Int((1 / shutter).rounded()))
                            : String(format: "%.1f 秒", shutter)
                    }
                    if let iso = row["iso"]?.int {
                        item.iso = "\(iso)"
                    }
                    item.source = .system
                    item.systemOriginalPath = originalURL.path
                    item.systemThumbnailPath = thumbPath
                    batchItems.append(item)
                }

                rows.append([
                    pk,
                    uuidString,
                    filename,
                    originalURL.path,
                    thumbPath,
                    kind.rawValue,
                    subtype,
                    playbackStyle,
                    row["cameradevice"]?.int ?? 0,
                    (row["favorite"]?.bool ?? false) ? 1 : 0,
                    (row["hidden"]?.bool ?? false) ? 1 : 0,
                    isScreenshot ? 1 : 0,
                    trashed?.timeIntervalSince1970,
                    trashed == nil ? nil : (row["trasheddate"]?.double ?? 0),
                    row["depth"]?.int ?? 0,
                    (row["duplicate"]?.int ?? 0) > 0 ? 1 : 0,
                    captured.timeIntervalSince1970,
                    added.timeIntervalSince1970,
                    width,
                    height,
                    hasLocation ? latitude : nil,
                    hasLocation ? longitude : nil,
                    row["duration"]?.double,
                    row["filesize"]?.int64 ?? 0,
                    row["originalwidth"]?.int ?? 0,
                    row["originalheight"]?.int ?? 0,
                    originalName,
                    trimmed(row["title"]?.string),
                    importedBy,
                    row["exifdate"]?.string,
                    placedata,
                    place?.country,
                    place?.province,
                    place?.city,
                    place?.district,
                    place?.poi,
                    trimmed(row["make"]?.string),
                    trimmed(row["model"]?.string),
                    trimmed(row["lens"]?.string),
                    row["aperture"]?.double,
                    row["focal"]?.double,
                    row["shutter"]?.double,
                    row["iso"]?.int,
                    isVideo ? 1 : 0,
                    isLive ? 1 : 0,
                    (row["avalanche"]?.string).map { !$0.isEmpty } == true ? 1 : 0,
                    (isVideo && subtype == 101) ? 1 : 0,
                    (isVideo && (isScreenshot || subtype == 103)) ? 1 : 0,
                    (!isVideo && playbackStyle == 2) ? 1 : 0,
                    isDeviceImport ? 1 : 0,
                    (isVideo && subtype == 102) ? 1 : 0,
                    hasLocation ? 1 : 0,
                    isRAW ? 1 : 0,
                    editedAt != nil ? 1 : 0,
                    nil as String?,
                    coreDataDate(row["lastviewed"])?.timeIntervalSince1970,
                    editedAt?.timeIntervalSince1970,
                    0,
                    stem,
                    trimmed(row["avalanche"]?.string),
                    ((row["avalanchepick"]?.int ?? 0) & 16) != 0 ? 1 : 0
                ])
                if rows.count >= 500 {
                    try target.executeMany(insertSQL, rows: rows)
                    inserted += rows.count
                    rows.removeAll(keepingCapacity: true)
                    progress?(inserted)
                    if let onBatch, !batchItems.isEmpty {
                        onBatch(batchItems)
                        batchItems.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !rows.isEmpty {
                try target.executeMany(insertSQL, rows: rows)
                inserted += rows.count
                rows.removeAll(keepingCapacity: true)
            }
            if let onBatch, !batchItems.isEmpty {
                onBatch(batchItems)
                batchItems.removeAll(keepingCapacity: true)
            }
            progress?(inserted)
            try linkLiveVideos(target, byStem: liveVideoByStem)
            try indexAlbums(source: source, target: target, assetCount: inserted)
            try indexPeople(source: source, target: target, isCancelled: isCancelled)
            try target.execute("UPDATE assets SET inalbum = 1 WHERE uuid IN (SELECT asset FROM album_assets)")
            try target.execute("CREATE INDEX idx_sys_created ON assets(created DESC)")
            try target.execute("CREATE INDEX idx_sys_added ON assets(added DESC)")
            try target.execute("CREATE INDEX idx_sys_size ON assets(filesize DESC)")
            try target.execute("CREATE INDEX idx_sys_title ON assets(title COLLATE NOCASE)")
            try target.execute("CREATE INDEX idx_sys_filename ON assets(filename COLLATE NOCASE)")
            try target.execute("CREATE INDEX idx_sys_duration ON assets(duration DESC)")
            try target.execute("CREATE INDEX idx_sys_uuid ON assets(uuid)")
            try target.execute("CREATE INDEX idx_sys_burst ON assets(burstuuid)")
            try target.execute("""
                CREATE INDEX idx_sys_album ON album_assets(album, position)
                """)
            try target.execute("CREATE INDEX idx_sys_album_asset ON album_assets(asset)")
            try target.execute("CREATE INDEX idx_sys_person ON person_assets(person)")
            let meta: [(String, String)] = [
                ("version", String(version)),
                ("signature", signature),
                ("total", String(inserted)),
                ("trueTotal", String(trueTotal)),
                ("name", libraryURL.deletingPathExtension().lastPathComponent),
                ("builtAt", String(Int(Date().timeIntervalSince1970)))
            ]
            for entry in meta {
                try target.execute("INSERT INTO meta(key, value) VALUES (?, ?)", [entry.0, entry.1])
            }
        }

        // 收尾：切回普通回滚日志模式，确保之后只读连接仅凭主文件即可查询。
        try target.execute("PRAGMA journal_mode=DELETE;")

        // 原子替换：先删旧索引（含 WAL/SHM），再把临时文件移到正式位置。
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
        }
        try fm.moveItem(at: temp, to: destination)
        let readonly = try SQLiteDatabase(path: destination.path, readonly: true)
        // 只读打开返回 OK 不代表能读：WAL 旁路文件缺失时要到 prepare 才报 SQLITE_CANTOPEN。
        // 这里先探一次，失败就让调用方回退到快照，避免图库卡在“正在读取图库…”。
        guard (try? readonly.query("SELECT COUNT(*) FROM assets")) != nil else {
            throw SystemIndexError.buildFailed("索引文件不可读")
        }
        return SystemIndex(database: readonly,
                           libraryURL: libraryURL,
                           name: libraryURL.deletingPathExtension().lastPathComponent,
                           total: inserted,
                           trueTotal: trueTotal)
    }

    static func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE assets(
                pk INTEGER PRIMARY KEY, uuid TEXT NOT NULL, filename TEXT NOT NULL,
                directory TEXT, origpath TEXT, thumbpath TEXT,
                kind INTEGER, mediakind TEXT, subtype INTEGER, playbackstyle INTEGER,
                cameradevice INTEGER, favorite INTEGER, hidden INTEGER, screenshot INTEGER,
                trashed REAL, trasheddate REAL, depth INTEGER, duplicate INTEGER,
                created REAL, added REAL, width INTEGER, height INTEGER,
                latitude REAL, longitude REAL, duration REAL,
                filesize INTEGER, originalwidth INTEGER, originalheight INTEGER,
                originalname TEXT NOT NULL, title TEXT, importedby TEXT, exifdate TEXT,
                placedata BLOB, placecountry TEXT, placeprovince TEXT, placecity TEXT,
                placedistrict TEXT, placepoi TEXT,
                make TEXT, model TEXT, lens TEXT,
                aperture REAL, focal REAL, shutter REAL, iso INTEGER,
                isvideo INTEGER, islive INTEGER, isburst INTEGER, isslow INTEGER,
                isscreenrec INTEGER, isanimated INTEGER, isdeviceimport INTEGER,
                istimelapse INTEGER,
                haslocation INTEGER, israw INTEGER, isedited INTEGER,
                livevideopath TEXT, viewedat REAL, editedat REAL,
                inalbum INTEGER, stem TEXT,
                burstuuid TEXT, burstpick INTEGER
            )
            """)
        try db.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
        try db.execute("""
            CREATE TABLE albums(pk INTEGER PRIMARY KEY, name TEXT, folder INTEGER, sortindex INTEGER, uuid TEXT)
            """)
        try db.execute("""
            CREATE TABLE folders(pk INTEGER PRIMARY KEY, name TEXT, parent INTEGER, sortindex INTEGER)
            """)
        try db.execute("CREATE TABLE album_assets(album INTEGER, asset TEXT, position INTEGER)")
        try db.execute("""
            CREATE TABLE people(pk INTEGER PRIMARY KEY, name TEXT, facecount INTEGER,
                                ispet INTEGER, keyasset TEXT, crop BLOB,
                                facecx REAL, facecy REAL, facesize REAL)
            """)
        try db.execute("CREATE TABLE person_assets(person INTEGER, asset TEXT)")
    }

    /// 实况照片的配对视频：同名 MOV 与图片在同一图库中分别存储。
    static func linkLiveVideos(_ db: SQLiteDatabase, byStem: [String: String]) throws {
        guard !byStem.isEmpty else { return }
        guard let rows = try? db.query("SELECT uuid, stem FROM assets WHERE islive = 1") else { return }
        for row in rows {
            guard let uuid = row["uuid"]?.string,
                  let stem = row["stem"]?.string,
                  let path = byStem[stem] else { continue }
            try db.execute("UPDATE assets SET livevideopath = ? WHERE uuid = ?", [path, uuid])
        }
    }

    static func indexAlbums(source: SQLiteDatabase,
                                    target: SQLiteDatabase,
                                    assetCount: Int) throws {
        let albumColumns = (try? source.query("PRAGMA table_info(ZGENERICALBUM)"))?
            .compactMap { $0["name"]?.string } ?? []
        // Z_FOK_PARENTFOLDER 是 Core Data 为「父文件夹」有序关系保存的手动排序键，
        // 与官方「照片」侧边栏的显示顺序一致；旧图库没有该列时退回主键。
        let sortColumn = albumColumns.contains("Z_FOK_PARENTFOLDER") ? "Z_FOK_PARENTFOLDER" : "Z_PK"
        let albumRows = (try? source.query("""
            SELECT Z_PK AS pk, ZKIND AS kind, ZTITLE AS title, ZPARENTFOLDER AS parent,
                   ZUUID AS uuid, \(sortColumn) AS sortkey
            FROM ZGENERICALBUM
            WHERE ZKIND IN (2, 4000) AND ZTRASHEDSTATE = 0
            """)) ?? []
        var folderPKs: Set<Int64> = []
        var folderRows: [[Any?]] = []
        var albumRowsToWrite: [[Any?]] = []
        for row in albumRows {
            guard let pk = row["pk"]?.int64 else { continue }
            if (row["kind"]?.int ?? 0) == 4000 {
                folderPKs.insert(pk)
                folderRows.append([pk, row["title"]?.string ?? "未命名文件夹",
                                   row["parent"]?.int64, row["sortkey"]?.int64 ?? pk])
            }
        }
        for row in albumRows {
            guard let pk = row["pk"]?.int64, (row["kind"]?.int ?? 0) == 2 else { continue }
            let parent = row["parent"]?.int64.flatMap { folderPKs.contains($0) ? $0 : nil }
            albumRowsToWrite.append([pk, row["title"]?.string ?? "未命名相簿", parent,
                                     row["sortkey"]?.int64 ?? pk, row["uuid"]?.string])
        }
        folderRows = folderRows.map { row in
            let parent = (row[2] as? Int64).flatMap { folderPKs.contains($0) ? $0 : nil }
            return [row[0], row[1], parent, row[3]]
        }
        if !folderRows.isEmpty {
            try target.executeMany("INSERT INTO folders VALUES (?,?,?,?)", rows: folderRows)
        }
        if !albumRowsToWrite.isEmpty {
            try target.executeMany("INSERT INTO albums VALUES (?,?,?,?,?)", rows: albumRowsToWrite)
        }

        guard assetCount > 0, let join = findAlbumAssetJoin(source) else { return }
        var pending: [[Any?]] = []
        pending.reserveCapacity(1000)
        var position = 0
        var lastAlbum: Int64 = .min
        try source.forEachRow("""
            SELECT j."\(join.albumColumn)" AS album, a.ZUUID AS uuid,
                   j."\(join.orderColumn ?? join.assetColumn)" AS position
            FROM "\(join.table)" j
            JOIN ZASSET a ON a.Z_PK = j."\(join.assetColumn)"
            ORDER BY album, position
            """) { row in
            guard let album = row["album"]?.int64, let uuid = row["uuid"]?.string else { return }
            if album != lastAlbum {
                lastAlbum = album
                position = 0
            }
            pending.append([album, uuid, position])
            position += 1
            if pending.count >= 1000 {
                try target.executeMany("INSERT INTO album_assets VALUES (?,?,?)", rows: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try target.executeMany("INSERT INTO album_assets VALUES (?,?,?)", rows: pending)
        }
    }

    static func indexPeople(source: SQLiteDatabase,
                                    target: SQLiteDatabase,
                                    isCancelled: () -> Bool) throws {
        let personColumns = (try? source.query("PRAGMA table_info(ZPERSON)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard personColumns.contains("ZDISPLAYNAME"),
              personColumns.contains("ZFULLNAME"),
              personColumns.contains("ZKEYFACE"),
              personColumns.contains("ZFACECOUNT") else { return }
        let faceColumns = (try? source.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard faceColumns.contains("ZPERSONFORFACE"), faceColumns.contains("ZASSETFORFACE") else { return }

        // 官方会为同一人物保留多条人脸裁切图（李晓希有 14 条），
        // 只有与关键照片一致的那条才是「照片」App 展示的头像，不能随便取第一条。
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

        // 官方「照片」的人物列表包含尚未命名的聚类，这里不按名称过滤，
        // 未命名时用「未命名」占位，保证与官方列出的人物数量一致。
        let personRows = (try? source.query("""
            SELECT Z_PK AS pk, ZDISPLAYNAME AS display, ZFULLNAME AS full,
                   ZFACECOUNT AS faces, ZTYPE AS type, ZKEYFACE AS keyface
            FROM ZPERSON
            """)) ?? []

        // 关键人脸几何（0-1 归一化：cx 相对图宽、cy 相对图高且原点在左下、size 相对图对角线），
        // 用于人物头像按官方口径从关键照片现算裁切；旧图库缺几何列时整体置空。
        var keyFaceGeometry: [Int64: (cx: Double, cy: Double, size: Double)] = [:]
        let hasFaceGeometry = (faceColumns.contains("ZCENTERX")
                               && faceColumns.contains("ZCENTERY")
                               && faceColumns.contains("ZSIZE"))
        if hasFaceGeometry {
            let geoRows = (try? source.query("""
                SELECT p.Z_PK AS person, f.ZCENTERX AS fcx, f.ZCENTERY AS fcy, f.ZSIZE AS fsize
                FROM ZPERSON p
                JOIN ZDETECTEDFACE f ON f.Z_PK = p.ZKEYFACE
                WHERE p.ZKEYFACE IS NOT NULL
                """)) ?? []
            for geoRow in geoRows {
                guard let person = geoRow["person"]?.int64,
                      let fcx = geoRow["fcx"]?.double,
                      let fcy = geoRow["fcy"]?.double,
                      let fsize = geoRow["fsize"]?.double else { continue }
                keyFaceGeometry[person] = (fcx, fcy, fsize)
            }
        }

        var keyFaceToPerson: [Int64: Int64] = [:]
        var peopleRows: [[Any?]] = []
        for row in personRows {
            guard let pk = row["pk"]?.int64 else { continue }
            let name = trimmed(row["display"]?.string)
                ?? trimmed(row["full"]?.string)
                ?? "未命名"
            let geometry = keyFaceGeometry[pk]
            peopleRows.append([pk, name, row["faces"]?.int ?? 0,
                               (row["type"]?.int ?? 0) == 1 ? 1 : 0,
                               nil as String?, crops[pk],
                               geometry?.cx, geometry?.cy, geometry?.size])
            if let keyface = row["keyface"]?.int64 {
                keyFaceToPerson[keyface] = pk
            }
        }
        if !peopleRows.isEmpty {
            try target.executeMany("""
                INSERT INTO people(pk, name, facecount, ispet, keyasset, crop, facecx, facecy, facesize)
                VALUES (?,?,?,?,?,?,?,?,?)
                """, rows: peopleRows)
        }

        var pending: [[Any?]] = []
        pending.reserveCapacity(1000)
        var seen: Set<String> = []
        var personCounts: [Int64: Int] = [:]
        try source.forEachRow("""
            SELECT f.ZPERSONFORFACE AS person, a.ZUUID AS uuid, f.Z_PK AS face
            FROM ZDETECTEDFACE f
            JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
            WHERE f.ZPERSONFORFACE IS NOT NULL AND f.ZASSETFORFACE IS NOT NULL
            """) { row in
            if isCancelled() { throw SystemIndexError.buildFailed("已取消") }
            guard let person = row["person"]?.int64, let uuid = row["uuid"]?.string else { return }
            if let face = row["face"]?.int64, let owner = keyFaceToPerson[face] {
                try target.execute("UPDATE people SET keyasset = ? WHERE pk = ?", [uuid, owner])
            }
            let key = "\(person)|\(uuid)"
            guard seen.insert(key).inserted else { return }
            personCounts[person, default: 0] += 1
            pending.append([person, uuid])
            if pending.count >= 1000 {
                try target.executeMany("INSERT INTO person_assets VALUES (?,?)", rows: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try target.executeMany("INSERT INTO person_assets VALUES (?,?)", rows: pending)
        }
        for (person, count) in personCounts {
            try target.execute("UPDATE people SET facecount = ? WHERE pk = ?", [count, person])
        }
        // 没有照片的人物不展示（与内存快照一致）。
        try target.execute("DELETE FROM people WHERE pk NOT IN (SELECT person FROM person_assets)")
    }
}
