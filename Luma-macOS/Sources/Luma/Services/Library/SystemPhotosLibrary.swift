import Foundation

struct SystemLibrarySnapshot {
    let name: String
    let photos: [PhotoItem]
    let albums: [SystemAlbumInfo]
    let folders: [SystemFolderInfo]
    let people: [SystemPersonInfo]
    /// 图库实际可浏览的项目总数；`photos.count` 可能因加载上限而更少。
    var totalAssetCount: Int? = nil
}

/// 官方图库里的人物 / 宠物（读取端侧识别结果，不额外做识别）。
/// 官方「照片」的人物列表包含尚未命名的聚类，这里同样收录，未命名时用「未命名」占位。
struct SystemPersonInfo: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let faceCount: Int
    let isPet: Bool
    let assetIDs: [UUID]
    let keyAssetID: UUID?
    let cropData: Data?
    /// 关键人脸的几何信息（Photos.sqlite `ZDETECTEDFACE`，0-1 归一化）：
    /// `faceCenterX` 相对图宽、`faceCenterY` 相对图高且原点在左下、`faceSize` 相对图对角线。
    /// 官方「照片」的人物头像就是按这组几何从关键照片现算裁切的；缺失时回退整张照片。
    let faceCenterX: Double?
    let faceCenterY: Double?
    let faceSize: Double?

    /// 官方图库里尚未命名的聚类统一叫「未命名」。
    var isUnnamed: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "未命名"
    }
}

enum SystemLibraryError: LocalizedError {
    case invalidLibrary
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidLibrary: return "不是有效的照片图库（缺少 database/Photos.sqlite）"
        case .unsupported(let message): return "无法读取照片图库：\(message)"
        }
    }
}

/// 只读解析 macOS 官方「照片」图库（Photos.sqlite）。
enum SystemPhotosLibrary {
    static func scan(libraryURL: URL,
                     progress: ((Int) -> Void)? = nil,
                     onBatch: (([PhotoItem]) -> Void)? = nil) throws -> SystemLibrarySnapshot {
        let databaseURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SystemLibraryError.invalidLibrary
        }

        let db = try SQLiteDatabase(path: databaseURL.path, readonly: true)

        // 部分旧版图库没有反向地理编码列，缺失时用 NULL 顶替，避免整条查询失败。
        let additionalColumns = (try? db.query("PRAGMA table_info(ZADDITIONALASSETATTRIBUTES)"))?
            .compactMap { $0["name"]?.string } ?? []
        let assetColumns = (try? db.query("PRAGMA table_info(ZASSET)"))?
            .compactMap { $0["name"]?.string } ?? []
        let placeColumn = additionalColumns.contains("ZREVERSELOCATIONDATA")
            ? "aa.ZREVERSELOCATIONDATA"
            : "NULL"
        let titleColumn = additionalColumns.contains("ZTITLE") ? "aa.ZTITLE" : "NULL"
        let subtypeColumn = assetColumns.contains("ZKINDSUBTYPE") ? "a.ZKINDSUBTYPE" : "NULL"
        let spatialColumn = assetColumns.contains("ZSPATIALTYPE") ? "a.ZSPATIALTYPE" : "NULL"
        let avalancheColumn = assetColumns.contains("ZAVALANCHEUUID") ? "a.ZAVALANCHEUUID" : "NULL"
        let avalanchePickColumn = assetColumns.contains("ZAVALANCHEPICKTYPE") ? "a.ZAVALANCHEPICKTYPE" : "NULL"
        let playbackStyleColumn = assetColumns.contains("ZPLAYBACKSTYLE") ? "a.ZPLAYBACKSTYLE" : "NULL"
        let cameraDeviceColumn = assetColumns.contains("ZDERIVEDCAMERACAPTUREDEVICE")
            ? "a.ZDERIVEDCAMERACAPTUREDEVICE"
            : "NULL"
        let adjustmentColumn = assetColumns.contains("ZADJUSTMENTTIMESTAMP")
            ? "a.ZADJUSTMENTTIMESTAMP"
            : "NULL"
        let lastViewedColumn = additionalColumns.contains("ZLASTVIEWEDDATE") ? "aa.ZLASTVIEWEDDATE" : "NULL"
        let albumColumns = (try? db.query("PRAGMA table_info(ZGENERICALBUM)"))?
            .compactMap { $0["name"]?.string } ?? []
        // 与索引模式保持一致：优先用官方「照片」的手动排序键，旧图库退回主键。
        let albumSortColumn = albumColumns.contains("Z_FOK_PARENTFOLDER") ? "Z_FOK_PARENTFOLDER" : "Z_PK"

        // 直接用 ZDATECREATED 覆盖索引取主键顺序后 CROSS JOIN 固定顺序：
        // 在 ZKIND 过滤后排序会让 SQLite 对整库做临时排序（百万级图库要几十秒），
        // 而固定顺序能让边扫边显示时视频 / 截屏等媒体类型尽早出现。
        let assetSource: String
        let binds: [Any?] = []
        let orderClause = ""
        var scanNullDates = false
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
            scanNullDates = true
        } else {
            assetSource = "FROM ZASSET a"
        }

        var photos: [PhotoItem] = []
        photos.reserveCapacity(4096)
        var pendingBatch: [PhotoItem] = []
        pendingBatch.reserveCapacity(4000)
        var assetIDByPK: [Int64: UUID] = [:]
        // 实况照片的配对视频：同名 MOV 与图片在同一图库中分别存储。
        var liveVideoByStem: [String: String] = [:]
        // 官方图库自带 derivative 时，逐项直接记录其路径，边扫描边显示也能用上快速缩略图。
        let hasDerivatives = FileManager.default.fileExists(
            atPath: LibraryPaths.systemDerivatives(libraryURL: libraryURL).path)

        func makeSQL(assetSource: String,
                     extraCondition: String = "",
                     orderClause: String = "") -> String {
            """
                SELECT a.Z_PK AS pk, a.ZUUID AS uuid, a.ZFILENAME AS filename,
                       a.ZDIRECTORY AS directory, a.ZKIND AS kind,
                       \(subtypeColumn) AS subtype,
                       \(spatialColumn) AS spatialtype,
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
                WHERE a.ZKIND IN (0, 1)\(extraCondition)
                \(orderClause)
                """
        }

        func handleRow(_ row: [String: SQLiteValue]) {
            guard let pk = row["pk"]?.int64,
                  let uuidString = row["uuid"]?.string,
                  let uuid = UUID(uuidString: uuidString),
                  let filename = row["filename"]?.string else { return }

            assetIDByPK[pk] = uuid
            let directory = row["directory"]?.string ?? String(uuidString.prefix(1))
            let originalURL = libraryURL
                .appendingPathComponent("originals")
                .appendingPathComponent(directory)
                .appendingPathComponent(filename)

            let width = row["originalwidth"]?.int ?? row["width"]?.int ?? 0
            let height = row["originalheight"]?.int ?? row["height"]?.int ?? 0
            let isVideo = (row["kind"]?.int ?? 0) == 1
            let isScreenshot = row["screenshot"]?.bool ?? false
            let subtype = row["subtype"]?.int ?? 0
            let playbackStyle = row["playbackstyle"]?.int ?? 0
            let isSelfie = (row["cameradevice"]?.int ?? 0) == 1

            if isVideo {
                let stem = originalURL.deletingPathExtension().lastPathComponent.lowercased()
                liveVideoByStem[stem] = originalURL.path
            }

            var kind: MediaKind = isVideo ? .video : .photo
            if !isVideo, isScreenshot || subtype == 6 || subtype == 10 {
                kind = .screenshot
            } else if !isVideo, subtype == 1 {
                kind = .panorama
            } else if !isVideo, isSelfie {
                kind = .selfie
            } else if !isVideo, width > 0, height > 0, CGFloat(width) / CGFloat(height) >= 2.2 {
                kind = .panorama
            }

            let createdAt = coreDataDate(row["created"])
            let addedAt = coreDataDate(row["added"]) ?? createdAt ?? Date()
            let capturedAt = createdAt ?? parseEXIFDate(row["exifdate"]?.string) ?? addedAt

            var item = PhotoItem(
                id: uuid,
                filename: filename,
                editedFilename: nil,
                originalName: row["originalname"]?.string ?? filename,
                capturedAt: capturedAt,
                addedAt: addedAt,
                pixelWidth: width,
                pixelHeight: height,
                fileSize: row["filesize"]?.int64 ?? 0,
                kind: kind
            )
            item.isFavorite = row["favorite"]?.bool ?? false
            item.isHidden = row["hidden"]?.bool ?? false
            item.isPortraitCapture = (row["depth"]?.int ?? 0) > 0
            item.isDuplicateItem = (row["duplicate"]?.int ?? 0) > 0
            // Photos.sqlite 的 ZKINDSUBTYPE：1 = 全景，2/3 = 实况照片，6/10 = 截屏，
            // 101 = 慢动作，102 = 延时摄影，103 = 录屏；ZPLAYBACKSTYLE：2 = 动图，3 = 实况照片。
            // 电影效果没有稳定的库字段，由 PhotoKit 智能相簿提供 ID。
            item.isLivePhoto = subtype == 2 || subtype == 3 || playbackStyle == 3
            item.isBurstItem = (row["avalanche"]?.string).map { !$0.isEmpty } ?? false
            // 连拍组 ID 与键照片标记：同组成员共享 UUID，代表图口径与官方「照片」一致。
            if let group = row["avalanche"]?.string, !group.isEmpty {
                item.burstGroupID = group
            }
            item.isBurstKeyPhoto = ((row["avalanchepick"]?.int ?? 0) & 16) != 0
            item.isSlowMotion = isVideo && subtype == 101
            item.isTimelapse = isVideo && subtype == 102
            item.isCinematic = false
            item.isSpatial = (row["spatialtype"]?.int ?? 0) != 0
            item.isScreenRecording = isVideo && (isScreenshot || subtype == 103)
            item.isAnimated = !isVideo && playbackStyle == 2
            item.viewedAt = coreDataDate(row["lastviewed"])
            item.editedAt = coreDataDate(row["adjustmentdate"])
            if let title = trim(row["title"]?.string) {
                item.title = title
            }
            let importedBy = row["importedby"]?.string
            item.isDeviceImport = importedBy != nil
                && importedBy != "com.apple.Photos"
                && importedBy != "com.apple.mobileslideshow"
            if row["trashed"]?.bool ?? false {
                item.deletedAt = coreDataDate(row["trasheddate"]) ?? Date()
            }
            item.duration = row["duration"]?.double
            item.latitude = row["latitude"]?.double
            item.longitude = row["longitude"]?.double
            if !item.hasLocation {
                item.latitude = nil
                item.longitude = nil
            }
            if item.hasLocation,
               let placeData = row["placedata"]?.data,
               let place = ReverseGeoArchive.decode(placeData) {
                item.placeCountry = place.country
                item.placeProvince = place.province
                item.placeCity = place.city
                item.placeDistrict = place.district
                item.placePOI = place.poi
            }
            item.make = trim(row["make"]?.string)
            item.model = trim(row["model"]?.string)
            item.lens = trim(row["lens"]?.string)
            if let aperture = row["aperture"]?.double {
                item.aperture = String(format: "ƒ/%.1f", aperture)
            }
            if let focal = row["focal"]?.double {
                item.focalLength = String(format: "%.0f mm", focal)
            }
            if let shutter = row["shutter"]?.double, shutter > 0 {
                if shutter < 1 {
                    item.shutterSpeed = String(format: "1/%d 秒", Int((1 / shutter).rounded()))
                } else {
                    item.shutterSpeed = String(format: "%.1f 秒", shutter)
                }
            }
            if let iso = row["iso"]?.int {
                item.iso = "\(iso)"
            }
            if item.fileSize == 0,
               let size = try? originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                item.fileSize = Int64(size)
            }

            item.source = .system
            item.systemOriginalPath = originalURL.path
            if hasDerivatives {
                item.systemThumbnailPath = LibraryPaths.systemDerivativePath(
                    libraryURL: libraryURL,
                    assetID: item.id,
                    isVideo: item.kind == .video,
                    directory: directory
                )
            }
            photos.append(item)
            pendingBatch.append(item)

            if pendingBatch.count >= 500 {
                progress?(photos.count)
                onBatch?(pendingBatch)
                pendingBatch.removeAll(keepingCapacity: true)
            }
        }

        do {
            try db.forEachRow(makeSQL(assetSource: assetSource, orderClause: orderClause),
                              binds) { handleRow($0) }
            if scanNullDates {
                // 极少数缺少拍摄日期的项目排在最后补扫，避免静默漏掉。
                try db.forEachRow(makeSQL(assetSource: "FROM ZASSET a",
                                          extraCondition: " AND a.ZDATECREATED IS NULL",
                                          orderClause: "ORDER BY a.Z_PK"),
                                  []) { handleRow($0) }
            }
            if !pendingBatch.isEmpty {
                onBatch?(pendingBatch)
                pendingBatch.removeAll(keepingCapacity: true)
            }
        } catch {
            throw SystemLibraryError.unsupported(error.localizedDescription)
        }
        progress?(photos.count)

        // 为系统图库的实况照片关联配对视频（同名 MOV）。
        if !liveVideoByStem.isEmpty {
            for index in photos.indices
            where photos[index].isLivePhoto && photos[index].livePhotoVideoPath == nil {
                guard let path = photos[index].systemOriginalPath else { continue }
                let stem = URL(fileURLWithPath: path).deletingPathExtension()
                    .lastPathComponent.lowercased()
                if let video = liveVideoByStem[stem] {
                    photos[index].livePhotoVideoPath = video
                }
            }
        }

        let albumRows = try db.query("""
            SELECT Z_PK AS pk, ZKIND AS kind, ZTITLE AS title, ZPARENTFOLDER AS parent,
                   ZCREATIONDATE AS created, ZUUID AS uuid, \(albumSortColumn) AS sortkey
            FROM ZGENERICALBUM
            WHERE ZKIND IN (2, 4000) AND ZTRASHEDSTATE = 0
            """)

        var folders: [SystemFolderInfo] = []
        var folderPKs: Set<Int64> = []
        for row in albumRows where (row["kind"]?.int ?? 0) == 4000 {
            guard let pk = row["pk"]?.int64 else { continue }
            folderPKs.insert(pk)
            folders.append(SystemFolderInfo(id: pk,
                                            name: row["title"]?.string ?? "未命名文件夹",
                                            parent: row["parent"]?.int64,
                                            sortIndex: row["sortkey"]?.int64 ?? pk))
        }

        var members: [Int64: [UUID]] = [:]
        if let join = try? findAlbumAssetJoin(db) {
            try db.forEachRow("""
                SELECT "\(join.albumColumn)" AS album, "\(join.assetColumn)" AS asset,
                       "\(join.orderColumn ?? join.assetColumn)" AS position
                FROM "\(join.table)"
                ORDER BY album, position
                """) { row in
                guard let albumPK = row["album"]?.int64,
                      let assetPK = row["asset"]?.int64,
                      let uuid = assetIDByPK[assetPK] else { return }
                members[albumPK, default: []].append(uuid)
            }
        }

        var albums: [SystemAlbumInfo] = []
        for row in albumRows where (row["kind"]?.int ?? 0) == 2 {
            guard let pk = row["pk"]?.int64 else { continue }
            let parentPK = row["parent"]?.int64
            let parent = parentPK.flatMap { folderPKs.contains($0) ? $0 : nil }
            albums.append(SystemAlbumInfo(id: pk,
                                          name: row["title"]?.string ?? "未命名相簿",
                                          parentFolder: parent,
                                          assetIDs: members[pk] ?? [],
                                          sortIndex: row["sortkey"]?.int64 ?? pk,
                                          uuid: row["uuid"]?.string))
        }

        // 修正文件夹父子关系（父节点可能尚未遍历到）。
        folders = folders.map { folder in
            let parent = folder.parent.flatMap { folderPKs.contains($0) ? $0 : nil }
            return SystemFolderInfo(id: folder.id, name: folder.name, parent: parent,
                                    sortIndex: folder.sortIndex)
        }

        let name = libraryURL.deletingPathExtension().lastPathComponent
        let totalAssets = (try? db.query("SELECT COUNT(*) AS c FROM ZASSET WHERE ZKIND IN (0, 1)")
            .first?["c"]?.int) ?? photos.count
        let people = (try? scanPeople(db, assetIDByPK: assetIDByPK)) ?? []
        return SystemLibrarySnapshot(name: name, photos: photos, albums: albums,
                                     folders: folders, people: people,
                                     totalAssetCount: totalAssets)
    }

    // MARK: - 人物

    private static func scanPeople(_ db: SQLiteDatabase,
                                   assetIDByPK: [Int64: UUID]) throws -> [SystemPersonInfo] {
        let personColumns = (try? db.query("PRAGMA table_info(ZPERSON)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard personColumns.contains("ZDISPLAYNAME"),
              personColumns.contains("ZFULLNAME"),
              personColumns.contains("ZKEYFACE"),
              personColumns.contains("ZFACECOUNT") else { return [] }

        let faceColumns = (try? db.query("PRAGMA table_info(ZDETECTEDFACE)"))?
            .compactMap { $0["name"]?.string } ?? []
        guard faceColumns.contains("ZPERSONFORFACE"), faceColumns.contains("ZASSETFORFACE") else { return [] }

        var facesByPerson: [Int64: [UUID]] = [:]
        var seen: [Int64: Set<UUID>] = [:]
        try db.forEachRow("""
            SELECT ZPERSONFORFACE AS person, ZASSETFORFACE AS asset
            FROM ZDETECTEDFACE
            WHERE ZPERSONFORFACE IS NOT NULL AND ZASSETFORFACE IS NOT NULL
            """) { row in
            guard let personPK = row["person"]?.int64,
                  let assetPK = row["asset"]?.int64,
                  let uuid = assetIDByPK[assetPK] else { return }
            if seen[personPK, default: []].insert(uuid).inserted {
                facesByPerson[personPK, default: []].append(uuid)
            }
        }

        // 同一人物可能有多条裁切图，只认与关键照片一致的那条（与官方「照片」的头像口径一致）。
        var crops: [Int64: Data] = [:]
        try? db.forEachRow("""
            SELECT fc.ZPERSON AS person, fc.ZRESOURCEDATA AS data
            FROM ZFACECROP fc
            JOIN ZPERSON p ON p.Z_PK = fc.ZPERSON
            JOIN ZDETECTEDFACE kf ON kf.Z_PK = p.ZKEYFACE
            WHERE fc.ZRESOURCEDATA IS NOT NULL AND fc.ZASSET = kf.ZASSETFORFACE
            """) { row in
            if let personPK = row["person"]?.int64,
               let data = row["data"]?.data,
               crops[personPK] == nil {
                crops[personPK] = data
            }
        }

        // 官方「照片」的人物列表不只包含已命名的人，未命名的人脸聚类同样会出现在「人物」里；
        // 这里不按名称过滤，未命名时用「未命名」占位，保证与官方列出的人物数量一致。
        let personRows = try db.query("""
            SELECT Z_PK AS pk, ZDISPLAYNAME AS display, ZFULLNAME AS full,
                   ZFACECOUNT AS faces, ZTYPE AS type, ZKEYFACE AS keyface
            FROM ZPERSON
            """)

        var people: [SystemPersonInfo] = []
        for row in personRows {
            guard let pk = row["pk"]?.int64 else { continue }
            let name = (row["display"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["full"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "未命名"
            let assetIDs = facesByPerson[pk] ?? []
            guard !assetIDs.isEmpty else { continue }

            var keyAssetID: UUID?
            var faceCenterX: Double?
            var faceCenterY: Double?
            var faceSize: Double?
            if let keyfacePK = row["keyface"]?.int64 {
                // 关键人脸的关键照片与几何一次取出；旧图库缺几何列时用 NULL 顶替。
                let geometry = (faceColumns.contains("ZCENTERX")
                                && faceColumns.contains("ZCENTERY")
                                && faceColumns.contains("ZSIZE"))
                    ? "ZCENTERX AS fcx, ZCENTERY AS fcy, ZSIZE AS fsize"
                    : "NULL AS fcx, NULL AS fcy, NULL AS fsize"
                if let keyRow = try? db.query("""
                    SELECT ZASSETFORFACE AS asset, \(geometry)
                    FROM ZDETECTEDFACE WHERE Z_PK = ?
                    """, [keyfacePK]).first,
                   let assetPK = keyRow["asset"]?.int64 {
                    keyAssetID = assetIDByPK[assetPK]
                    faceCenterX = keyRow["fcx"]?.double
                    faceCenterY = keyRow["fcy"]?.double
                    faceSize = keyRow["fsize"]?.double
                }
            }

            people.append(SystemPersonInfo(id: pk,
                                           name: name,
                                           faceCount: row["faces"]?.int ?? assetIDs.count,
                                           isPet: (row["type"]?.int ?? 0) == 1,
                                           assetIDs: assetIDs,
                                           keyAssetID: keyAssetID,
                                           cropData: crops[pk],
                                           faceCenterX: faceCenterX,
                                           faceCenterY: faceCenterY,
                                           faceSize: faceSize))
        }
        return people.sorted {
            if $0.faceCount != $1.faceCount { return $0.faceCount > $1.faceCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Helpers

    private static func coreDataDate(_ value: SQLiteValue?) -> Date? {
        guard let raw = value?.double, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    private static func parseEXIFDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct AlbumAssetJoin {
        let table: String
        let albumColumn: String
        let assetColumn: String
        let orderColumn: String?
    }

    private static func findAlbumAssetJoin(_ db: SQLiteDatabase) throws -> AlbumAssetJoin? {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'")
        for tableRow in tables {
            guard let table = tableRow["name"]?.string, table.hasPrefix("Z_") else { continue }
            let columns = try db.query("PRAGMA table_info(\"\(table)\")")
            let names = columns.compactMap { $0["name"]?.string }
            guard let assetColumn = names.first(where: { $0 == "Z_3ASSETS" }),
                  let albumColumn = names.first(where: { isAlbumColumn($0) }) else { continue }
            let orderColumn = names.first(where: { $0 == "Z_FOK_3ASSETS" })
            return AlbumAssetJoin(table: table,
                                  albumColumn: albumColumn,
                                  assetColumn: assetColumn,
                                  orderColumn: orderColumn)
        }
        return nil
    }

    private static func isAlbumColumn(_ name: String) -> Bool {
        guard name.hasPrefix("Z_"), name.hasSuffix("ALBUMS") else { return false }
        let middle = name.dropFirst(2).dropLast(6)
        return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
    }
}

// MARK: - 扫描结果缓存

/// 系统图库扫描结果缓存：命中时直接展示，避免每次重新解析 Photos.sqlite 与缩略图目录。
/// 只缓存索引与元数据，原图仍然直接从 macOS「照片」图库读取。
enum SystemLibraryCache {
    /// 解析逻辑或快照结构变更时递增，旧缓存会自动失效。
    /// v5：扫描时记录官方 derivative 路径，旧缓存需要重扫一次。
    /// v6：缓存记录载入上限，调整上限后旧快照不再被当成最新缓存。
    /// v7：人物收录未命名聚类（与官方「照片」人物列表对齐），旧缓存需要重扫一次。
    /// v8：相簿 / 文件夹改用 Z_FOK_PARENTFOLDER 手动排序键，旧缓存需要重扫一次。
    /// v9：移除载入上限，旧缓存可能是截断结果，需要重扫一次。
    static let version = 9
    private static let maxCacheFiles = 8
    /// 超大快照不做缓存，避免编码/解码占用过多内存。
    private static let maxCachedPhotos = 250_000

    struct Loaded {
        let snapshot: SystemLibrarySnapshot
        /// Photos.sqlite 未变化，缓存即最新，无需再扫描。
        let isFresh: Bool
    }

    private struct Payload: Codable {
        var version: Int
        var signature: String
        var name: String
        var photos: [PhotoItem]
        var albums: [SystemAlbumInfo]
        var folders: [SystemFolderInfo]
        var people: [SystemPersonInfo]
        var totalAssetCount: Int?
    }

    static func load(for libraryURL: URL) -> Loaded? {
        guard let signature = signature(for: libraryURL),
              let file = cacheFile(for: libraryURL),
              let data = try? Data(contentsOf: file),
              let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
              payload.version == version else { return nil }
        let snapshot = SystemLibrarySnapshot(name: payload.name,
                                             photos: payload.photos,
                                             albums: payload.albums,
                                             folders: payload.folders,
                                             people: payload.people,
                                             totalAssetCount: payload.totalAssetCount)
        let isFresh = payload.signature == signature
        return Loaded(snapshot: snapshot, isFresh: isFresh)
    }

    static func save(_ snapshot: SystemLibrarySnapshot, for libraryURL: URL) {
        guard snapshot.photos.count <= maxCachedPhotos,
              let signature = signature(for: libraryURL),
              let file = cacheFile(for: libraryURL) else { return }
        let payload = Payload(version: version,
                              signature: signature,
                              name: snapshot.name,
                              photos: snapshot.photos,
                              albums: snapshot.albums,
                              folders: snapshot.folders,
                              people: snapshot.people,
                              totalAssetCount: snapshot.totalAssetCount)
        Task.detached(priority: .utility) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(payload) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: LibraryPaths.systemLibraryCacheDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            pruneOldFiles()
        }
    }

    /// 以 Photos.sqlite 的大小与修改时间判断图库是否变化。
    private static func signature(for libraryURL: URL) -> String? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let values = try? dbURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    private static func cacheFile(for libraryURL: URL) -> URL? {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in libraryURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return LibraryPaths.systemLibraryCacheDir
            .appendingPathComponent(String(hash, radix: 16) + ".plist")
    }

    private static func pruneOldFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: LibraryPaths.systemLibraryCacheDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]),
              files.count > maxCacheFiles else { return }
        let sorted = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(maxCacheFiles) {
            try? fm.removeItem(at: file)
        }
    }
}
