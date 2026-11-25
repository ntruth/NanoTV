import Foundation

/// 系统图库直连：条件 / 排序、时间轴密度与年 / 月总览。

extension SystemIndex {
    // MARK: - 条件 / 排序

    func directWhere(_ query: SystemQuery,
                             omitMemberSet: Bool = false) -> (String, [Any?], String) {
        var clauses: [String] = []
        var binds: [Any?] = []
        let active = "(a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0)"
        let favoriteAdds = inList(query.favoriteAdds)
        let favoriteRemoves = inList(query.favoriteRemoves)
        let hiddenAdds = inList(query.hiddenAdds)
        let hiddenRemoves = inList(query.hiddenRemoves)

        switch query.scope {
        case .all:
            clauses.append(active)
        case .favorites:
            // 没有拾光的收藏叠加时用最简条件，才能命中收藏部分索引。
            if query.favoriteAdds.isEmpty && query.favoriteRemoves.isEmpty {
                clauses.append("\(active) AND a.ZFAVORITE = 1")
            } else {
                clauses.append("\(active) AND ((a.ZFAVORITE = 1 AND a.ZUUID NOT IN (\(favoriteRemoves))) OR a.ZUUID IN (\(favoriteAdds)))")
            }
        case .videos:
            clauses.append("\(active) AND a.ZKIND = 1")
        case .screenshots:
            clauses.append("\(active) AND a.ZKIND = 0 AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10))")
        case .hidden:
            if query.hiddenAdds.isEmpty && query.hiddenRemoves.isEmpty {
                clauses.append("(a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 1)")
            } else {
                clauses.append("(a.ZTRASHEDSTATE = 0 AND ((a.ZHIDDEN = 1 AND a.ZUUID NOT IN (\(hiddenRemoves))) OR a.ZUUID IN (\(hiddenAdds))))")
            }
        case .trash:
            clauses.append("a.ZTRASHEDSTATE <> 0")
        case .portraits:
            clauses.append("\(active) AND a.ZDEPTHTYPE > 0 AND a.ZKIND = 0")
        case .selfies:
            clauses.append("\(active) AND a.ZDERIVEDCAMERACAPTUREDEVICE = 1 AND a.ZKIND = 0")
        case .livePhotos:
            clauses.append("\(active) AND (a.ZKINDSUBTYPE IN (2, 3) OR a.ZPLAYBACKSTYLE = 3)")
        case .panoramas:
            // 与计数 / 系统相簿一致：只认 Apple 标记的全景（ZKINDSUBTYPE = 1），
            // 不再用宽高比兜底——那会让翻页退化成扫全库。
            clauses.append("\(active) AND a.ZKIND = 0 AND a.ZKINDSUBTYPE = 1")
        case .timelapses:
            clauses.append("\(active) AND a.ZKINDSUBTYPE = 102")
        case .cinematics:
            // 电影效果集合由 PhotoKit 智能相簿的 includeIDs 下推，这里只保留有效行。
            clauses.append(active)
        case .spatial:
            if direct?.hasSpatialType == true {
                clauses.append("\(active) AND a.ZSPATIALTYPE <> 0")
            } else {
                clauses.append("0")
            }
        case .slowMotion:
            clauses.append("\(active) AND a.ZKIND = 1 AND a.ZKINDSUBTYPE = 101")
        case .screenRecordings:
            clauses.append("\(active) AND a.ZKIND = 1 AND a.ZISDETECTEDSCREENSHOT = 1")
        case .animated:
            clauses.append("\(active) AND a.ZKIND = 0 AND a.ZPLAYBACKSTYLE = 2")
        case .bursts:
            // 按组展示代表照片：多成员组取键照片（ZAVALANCHEPICKTYPE & 16），
            // 单成员组没有键照片标记、自身即代表（与官方「照片」及索引模式口径一致）。
            // 子查询沿连拍索引只扫一两千行，毫秒级。
            clauses.append("""
                \(active) AND a.ZAVALANCHEUUID IS NOT NULL AND a.ZAVALANCHEUUID <> '' AND (
                  (a.ZAVALANCHEPICKTYPE & 16) <> 0
                  OR a.ZAVALANCHEUUID IN (
                    SELECT s.ZAVALANCHEUUID FROM ZASSET s
                    WHERE s.ZAVALANCHEUUID IS NOT NULL AND s.ZAVALANCHEUUID <> ''
                      AND s.ZTRASHEDSTATE = 0 AND s.ZHIDDEN = 0
                    GROUP BY s.ZAVALANCHEUUID HAVING COUNT(*) = 1))
                """)
        case .raws:
            // 与官方 RAW 相簿一致：用 UTI 命中 `Z_Asset_byUniformTypeIdentifierIndex`，
            // 不必为了找到几十张 RAW 而逐行扫 26GB 主表。
            if direct?.hasUniformTypeIdentifier == true {
                clauses.append("\(active) AND a.ZUNIFORMTYPEIDENTIFIER LIKE '%raw%'")
            } else {
                clauses.append("\(active) AND (lower(a.ZFILENAME) LIKE '%.dng' OR lower(a.ZFILENAME) LIKE '%.cr2' OR lower(a.ZFILENAME) LIKE '%.cr3' OR lower(a.ZFILENAME) LIKE '%.nef' OR lower(a.ZFILENAME) LIKE '%.arw' OR lower(a.ZFILENAME) LIKE '%.raf' OR lower(a.ZFILENAME) LIKE '%.orf' OR lower(a.ZFILENAME) LIKE '%.rw2' OR lower(a.ZFILENAME) LIKE '%.pef' OR lower(a.ZFILENAME) LIKE '%.srw')")
            }
        case .edited:
            clauses.append("\(active) AND a.ZADJUSTMENTTIMESTAMP IS NOT NULL")
        case .recentlyViewed:
            let cutoff = (query.viewedCutoff ?? Self.directViewedCutoff).timeIntervalSince1970
            // 同样直接比较原始列，才能命中 Z_AdditionalAssetAttributes_forRecentlyViewed。
            clauses.append("\(active) AND aa.ZLASTVIEWEDDATE >= \(cutoff - 978307200)")
        case .duplicates:
            clauses.append("\(active) AND a.ZDUPLICATEASSETVISIBILITYSTATE > 0")
        case .recentlySaved:
            let cutoff = (query.savedCutoff ?? Self.directSavedCutoff).timeIntervalSince1970
            // 直接比较 ZADDEDDATE 才能命中 byAddedDate 索引（库内该列没有 NULL）。
            clauses.append("\(active) AND a.ZADDEDDATE >= \(cutoff - 978307200)")
        case .imports:
            clauses.append("\(active) AND aa.ZIMPORTEDBYBUNDLEIDENTIFIER IS NOT NULL AND aa.ZIMPORTEDBYBUNDLEIDENTIFIER NOT IN ('com.apple.Photos', 'com.apple.mobileslideshow')")
        case .importSession(let id):
            // 官方导入会话：ZASSET.ZIMPORTSESSION 指向 ZGENERICALBUM(ZKIND = 1506) 的主键。
            clauses.append("\(active) AND a.ZIMPORTSESSION = \(id)")
        case .revisit:
            let captureCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge).timeIntervalSince1970
            let viewCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitViewAge).timeIntervalSince1970
            clauses.append("\(active) AND a.ZDATECREATED <= \(captureCutoff - 978307200) AND (aa.ZLASTVIEWEDDATE IS NULL OR aa.ZLASTVIEWEDDATE < \(viewCutoff - 978307200))")
        case .withLocation:
            clauses.append("\(active) AND \(Self.directLocationClause)")
        case .album(let id):
            if omitMemberSet {
                clauses.append(active)
            } else if let albumTable = direct?.albumTable, let albumColumn = direct?.albumColumn {
                clauses.append("\(active) AND a.Z_PK IN (SELECT j.\(direct?.assetColumn ?? "_none") FROM \(albumTable) j WHERE j.\(albumColumn) = \(id))")
            } else {
                clauses.append("0")
            }
        case .folder(let id):
            if omitMemberSet {
                clauses.append(active)
            } else {
                let albums = directAlbumIDs(inFolder: id)
                if albums.isEmpty {
                    clauses.append("0")
                } else {
                    let list = albums.map(String.init).joined(separator: ",")
                    clauses.append("\(active) AND a.Z_PK IN (SELECT j.\(direct?.assetColumn ?? "_none") FROM \(direct?.albumTable ?? "_none") j WHERE j.\(direct?.albumColumn ?? "_none") IN (\(list)))")
                }
            }
        case .person(let id):
            if omitMemberSet {
                clauses.append(active)
            } else {
                clauses.append("\(active) AND a.Z_PK IN (SELECT f.ZASSETFORFACE FROM ZDETECTEDFACE f WHERE f.ZPERSONFORFACE = \(id))")
            }
        default:
            clauses.append(active)
        }

        if query.onlyLocated {
            clauses.append(Self.directLocationClause)
        }

        switch query.filter {
        case .all: break
        case .favorites:
            if favoriteAdds.isEmpty && favoriteRemoves.isEmpty {
                clauses.append("a.ZFAVORITE = 1")
            } else {
                clauses.append("((a.ZFAVORITE = 1 AND a.ZUUID NOT IN (\(favoriteRemoves))) OR a.ZUUID IN (\(favoriteAdds)))")
            }
        case .edited: clauses.append("a.ZADJUSTMENTTIMESTAMP IS NOT NULL")
        case .photos: clauses.append("a.ZKIND = 0")
        case .videos: clauses.append("a.ZKIND = 1")
        case .screenshots: clauses.append("a.ZKIND = 0 AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10))")
        case .mine:
            clauses.append("(\(directExtendedPrefix)ZCAMERAMAKE IS NOT NULL OR \(directExtendedPrefix)ZCAMERAMODEL IS NOT NULL)")
        case .notInAlbum:
            if let albumTable = direct?.albumTable {
                clauses.append("NOT EXISTS (SELECT 1 FROM \(albumTable) j WHERE j.\(direct?.assetColumn ?? "_none") = a.Z_PK)")
            }
        }

        // 日期范围必须直接比较 `a.ZDATECREATED`（Core Data 秒），
        // 写成 `(a.ZDATECREATED + 978307200) >= ?` 会让 Apple 的日期索引失效：
        // 同样一条「某年收藏」计数实测从 0.37 秒退化到 66 秒。
        if let start = query.startDate {
            clauses.append("a.ZDATECREATED >= \(start.timeIntervalSince1970 - 978307200)")
        }
        if let end = query.endDate {
            clauses.append("a.ZDATECREATED < \(end.timeIntervalSince1970 - 978307200)")
        }
        if query.onlyFavorites {
            if favoriteAdds.isEmpty && favoriteRemoves.isEmpty {
                clauses.append("a.ZFAVORITE = 1")
            } else {
                clauses.append("((a.ZFAVORITE = 1 AND a.ZUUID NOT IN (\(favoriteRemoves))) OR a.ZUUID IN (\(favoriteAdds)))")
            }
        }
        if query.onlyVideos { clauses.append("a.ZKIND = 1") }
        if query.onlyPhotos { clauses.append("a.ZKIND = 0") }
        if query.onlyScreenshots { clauses.append("a.ZKIND = 0 AND (a.ZISDETECTEDSCREENSHOT = 1 OR a.ZKINDSUBTYPE IN (6, 10))") }
        if query.onlyLivePhotos { clauses.append("(a.ZKINDSUBTYPE IN (2, 3) OR a.ZPLAYBACKSTYLE = 3)") }
        if query.onlyEdited { clauses.append("a.ZADJUSTMENTTIMESTAMP IS NOT NULL") }
        if let keywordIDs = query.overlayKeywordIDs {
            clauses.append("a.ZUUID IN (\(inList(keywordIDs)))")
        }
        if let includeIDs = query.includeIDs {
            clauses.append("a.ZUUID IN (\(inList(includeIDs)))")
        }
        for token in query.tokens where !token.isEmpty {
            let value = "%\(token.lowercased())%"
            // 地名（如「上海」）只存在于 `ZREVERSELOCATIONDATA` 的二进制归档里，SQL 无法比对；
            // 由上层按已解码的地点名换算出命中资产，作为该 token 的 OR 条件并入。
            let placeIDs = query.tokenPlaceIDs?[token] ?? []
            let placeClause = placeIDs.isEmpty ? "" : " OR a.ZUUID IN (\(inList(placeIDs)))"
            // 关键词 / AI 标签 / OCR 命中同样由上层换算成资产 UUID，作为 OR 条件并入。
            let keywordIDs = query.tokenKeywordIDs?[token] ?? []
            let keywordClause = keywordIDs.isEmpty ? "" : " OR a.ZUUID IN (\(inList(keywordIDs)))"
            clauses.append("""
                (lower(a.ZFILENAME) LIKE ? OR lower(COALESCE(aa.ZORIGINALFILENAME, '')) LIKE ?
                 OR lower(COALESCE(aa.ZTITLE, '')) LIKE ?
                 OR lower(COALESCE(\(directExtendedPrefix)ZCAMERAMAKE, '') || ' ' || COALESCE(\(directExtendedPrefix)ZCAMERAMODEL, '') || ' '
                          || COALESCE(\(directExtendedPrefix)ZLENSMODEL, '')) LIKE ?\(placeClause)\(keywordClause))
                """)
            binds.append(contentsOf: [value, value, value, value])
        }
        return (clauses.joined(separator: " AND "), binds, directFrom)
    }

    func directPageCursor(queryKey: String, offset: Int) -> (value: Double, pk: Int64)? {
        directCursorLock.lock()
        defer { directCursorLock.unlock() }
        guard let entry = directPageCursors[queryKey], entry.offset == offset else { return nil }
        return (entry.value, entry.pk)
    }

    func rememberDirectPageCursor(queryKey: String, offset: Int, value: Double, pk: Int64) {
        directCursorLock.lock()
        directPageCursors[queryKey] = (offset, value, pk)
        directCursorLock.unlock()
    }

    // MARK: - 时间轴密度（滚动条定位）

    /// 把「整库第几张」换算成拍摄时间。百万级整库做大 OFFSET 分页要几十秒，
    /// 官方 `ZMOMENT` 已经把每个时刻的起止时间与项目数缓存好（一万多行），直接累加即可。
    func timelineDate(atRank rank: Int) -> Date? {
        let buckets = timelineBuckets()
        guard !buckets.isEmpty else { return nil }
        var remaining = max(0, rank)
        for bucket in buckets {
            if remaining < bucket.count {
                let span = max(bucket.end - bucket.start, 0)
                let ratio = bucket.count > 1 ? Double(remaining) / Double(bucket.count) : 0
                return Date(timeIntervalSince1970: bucket.end - span * ratio)
            }
            remaining -= bucket.count
        }
        return buckets.last.map { Date(timeIntervalSince1970: $0.start) }
    }

    /// 反过来：拍摄时间落在整库的排名（0 = 最新）。
    func timelineRank(of date: Date) -> Int {
        let value = date.timeIntervalSince1970
        var rank = 0
        for bucket in timelineBuckets() {
            if value >= bucket.end { return rank }
            if value <= bucket.start {
                rank += bucket.count
                continue
            }
            let span = max(bucket.end - bucket.start, 1)
            rank += Int(Double(bucket.count) * (bucket.end - value) / span)
            return rank
        }
        return rank
    }

    func timelineBuckets() -> [SystemTimelineBucket] {
        directTimelineLock.lock()
        defer { directTimelineLock.unlock() }
        if let cached = directTimelineBuckets { return cached }
        guard direct != nil else { return [] }
        let rows = (try? database.query("""
            SELECT (ZSTARTDATE + 978307200) AS s,
                   (ZENDDATE + 978307200) AS e,
                   ZCACHEDCOUNT AS c
            FROM ZMOMENT WHERE ZCACHEDCOUNT > 0
            ORDER BY ZENDDATE DESC
            """)) ?? []
        var buckets: [SystemTimelineBucket] = []
        buckets.reserveCapacity(rows.count)
        for row in rows {
            guard let end = row["e"]?.double, let count = row["c"]?.int, count > 0 else { continue }
            let start = row["s"]?.double ?? end
            buckets.append(SystemTimelineBucket(start: min(start, end), end: end, count: count))
        }
        directTimelineBuckets = buckets
        return buckets
    }

    // MARK: - 地图 / 位置样本

    /// 后台准备地图数据，完成后复用侧边栏计数的回调通知界面刷新。
    /// 地图只用到全库里极小一部分带 GPS 的照片，但取这些行仍要扫一遍地点索引；
    /// 图库没变过时直接读上次的快照，变了才延迟一段时间、用 background 优先级重扫，
    /// 避免和首屏 / 翻页抢外接盘的磁盘带宽。
    func startDirectGeoWarmup() {
        guard direct != nil, directGeoWarmupTask == nil, directGeoPhotos == nil else { return }
        let select = directSelect
        let from = directFrom
        let libraryPath = libraryURL.path
        let fingerprint = Self.libraryFingerprint(libraryURL)
        directGeoWarmupTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            if let cached = Self.loadDirectGeoSnapshot(libraryPath: libraryPath,
                                                       fingerprint: fingerprint) {
                await MainActor.run {
                    self.directGeoWarmupTask = nil
                    self.directGeoPhotos = cached
                    self.directPlaceTokenIndex = Self.makePlaceTokenIndex(cached)
                    self.onDirectCountsReady?()
                }
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            let photos = self.computeDirectGeoPhotos(select: select, from: from)
            if let photos {
                Self.storeDirectGeoSnapshot(photos, libraryPath: libraryPath, fingerprint: fingerprint)
            }
            let placeIndex = photos.map(Self.makePlaceTokenIndex)
            await MainActor.run {
                self.directGeoWarmupTask = nil
                guard let photos else { return }
                self.directGeoPhotos = photos
                self.directPlaceTokenIndex = placeIndex
                self.onDirectCountsReady?()
            }
        }
    }

    /// 把每张带定位照片的国家 / 省 / 市 / 区 / POI 名字铺平成「地名 → 资产 UUID」，
    /// 搜索时按子串命中（「上海」也能匹配「上海市」「上海浦东新区」）。
    static func makePlaceTokenIndex(_ photos: [PhotoItem]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for photo in photos {
            let uuid = photo.id.uuidString
            var seen: Set<String> = []
            let parts = [photo.placeCountry, photo.placeProvince, photo.placeCity,
                         photo.placeDistrict, photo.placePOI]
            for part in parts {
                guard let name = part?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(), !name.isEmpty, seen.insert(name).inserted else { continue }
                index[name, default: []].append(uuid)
            }
        }
        return index
    }

    /// 按地名子串匹配资产；地名数据由后台任务准备，未就绪时返回空。
    func directPlaceAssetIDs(matching token: String) -> [String] {
        guard direct != nil, let index = directPlaceTokenIndex else { return [] }
        let needle = token.lowercased()
        guard !needle.isEmpty else { return [] }
        var ids: Set<String> = []
        for (name, assetIDs) in index where name.contains(needle) {
            ids.formUnion(assetIDs)
        }
        return Array(ids)
    }

    /// 全量读取带定位照片，不做任何取样：地图上的地点必须与图库完全一致。
    /// 十几万行放在后台逐行解析（`forEachRow` 复用行字典），避免一次性物化造成内存峰值。
    /// 同时读取官方库里已有的逆地理结果（`ZREVERSELOCATIONDATA`），
    /// 照片一进内存就带上国家 / 市 / 区 / 街道，不必再逐条逆地理编码。
    func computeDirectGeoPhotos(select: String, from: String) -> [PhotoItem]? {
        let dbURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        let gps = "a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0 AND \(Self.directLocationClause)"
        let hintedFrom = from.replacingOccurrences(
            of: "FROM ZASSET a",
            with: "FROM ZASSET a INDEXED BY Z_Asset_forPlacesAlbum")
        let sql = """
            SELECT \(select), aa.ZREVERSELOCATIONDATA AS revgeo \(hintedFrom)
            WHERE \(gps)
            ORDER BY a.ZDATECREATED DESC, a.Z_PK DESC
            """
        var photos: [PhotoItem] = []
        photos.reserveCapacity(150_000)
        _ = try? db.forEachRow(sql) { row in
            guard var item = directPhoto(from: row) else { return }
            // 已经有地名的就不用再解；官方多数照片靠这一份就够了。
            if item.placeCity == nil, item.placeDistrict == nil, item.placeProvince == nil,
               let data = row["revgeo"]?.data,
               let place = Self.placeInfo(fromReverseGeo: data) {
                item.placeCountry = place.country
                item.placeProvince = place.province
                item.placeCity = place.city
                item.placeDistrict = place.district
                item.placePOI = place.poi
            }
            photos.append(item)
        }
        return photos.isEmpty ? nil : photos
    }

    /// 解析官方库里的逆地理结果：`PLRevGeoLocationInfo` 的 NSKeyedArchiver plist。
    /// 只按 keyed archive 的结构取字符串，不去实例化系统私有类。
    static func placeInfo(fromReverseGeo data: Data)
        -> (country: String?, province: String?, city: String?, district: String?, poi: String?)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any],
              let top = root["$top"] as? [String: Any] else { return nil }

        func uid(_ value: Any?) -> Int? {
            // keyed archive 里的引用是 CFKeyedArchiverUID，没有公开取值接口，
            // 这里从它的描述里取 value（"…{value = 12}"），失败就当作没有。
            guard let value else { return nil }
            let text = String(describing: value)
            guard text.contains("CFKeyedArchiverUID"),
                  let range = text.range(of: "value = ") else { return nil }
            return Int(text[range.upperBound...].prefix { $0.isNumber })
        }
        func object(_ value: Any?) -> Any? {
            guard let index = uid(value), index >= 0, index < objects.count else { return nil }
            return objects[index]
        }
        func text(_ key: String, in dictionary: [String: Any]) -> String? {
            guard let value = object(dictionary[key]) as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // 归档里的空值会以 "$null" 占位，别当地名写进去。
            guard !trimmed.isEmpty, trimmed != "$null", trimmed != "null" else { return nil }
            return trimmed
        }

        guard let info = object(top["root"]) as? [String: Any],
              let address = object(info["postalAddress"]) as? [String: Any] else { return nil }
        let country = text("_country", in: address)
        let province = text("_state", in: address) ?? text("_subAdministrativeArea", in: address)
        let city = text("_city", in: address)
        let district = text("_subLocality", in: address)
        let poi = text("_street", in: address)
        guard country != nil || province != nil || city != nil || district != nil else { return nil }
        return (country, province, city, district, poi)
    }

    // MARK: - 人物摘要

    /// 直连模式下的人物摘要：计数 / 年份 / 时段由 SQL 聚合，地名从归档字段解码，
    /// 高光与同框人物各取一次有限查询，不把这个人全部照片读进内存。
    func directPersonInsight(_ query: SystemQuery) -> PersonInsight {
        guard case .person(let personID) = query.scope else { return PersonInsight() }
        let whereSQL = "a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0"
        // 成员驱动：先从人脸表的覆盖索引里取出这个人的照片主键，再按 rowid 逐行回表。
        // 对比 `a.Z_PK IN (SELECT ...)`（优化器会反扫 26GB 主表 + bloom filter），
        // 实测 1.00s → 0.01s，这个人的照片越多差距越明显。
        let members = """
            FROM (SELECT DISTINCT f.ZASSETFORFACE AS member
                  FROM ZDETECTEDFACE f WHERE f.ZPERSONFORFACE = \(personID)) m
            JOIN ZASSET a ON a.Z_PK = m.member
            """
        let membersAttr = "\(members) LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK"
        let membersExt = "\(membersAttr) LEFT JOIN ZEXTENDEDATTRIBUTES e ON e.ZASSET = a.Z_PK"

        var total = 0
        var videos = 0
        var earliest: Date?
        var latest: Date?
        if let row = try? database.query("""
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN a.ZKIND = 1 THEN 1 ELSE 0 END), 0) AS videos,
                   MIN(a.ZDATECREATED + 978307200) AS earliest,
                   MAX(a.ZDATECREATED + 978307200) AS latest
            \(members) WHERE \(whereSQL)
            """).first {
            total = row["total"]?.int ?? 0
            videos = row["videos"]?.int ?? 0
            earliest = row["earliest"]?.double.map { Date(timeIntervalSince1970: $0) }
            latest = row["latest"]?.double.map { Date(timeIntervalSince1970: $0) }
        }

        let yearRows = (try? database.query("""
            SELECT strftime('%Y', a.ZDATECREATED + 978307200, 'unixepoch', 'localtime') AS period,
                   COUNT(*) AS c
            \(members) WHERE \(whereSQL) AND a.ZDATECREATED IS NOT NULL
            GROUP BY period ORDER BY period
            """)) ?? []
        let years = yearRows.compactMap { row -> PersonInsight.YearCount? in
            guard let text = row["period"]?.string, let year = Int(text) else { return nil }
            return PersonInsight.YearCount(year: year, count: row["c"]?.int ?? 0)
        }

        let hourRows = (try? database.query("""
            SELECT strftime('%H', a.ZDATECREATED + 978307200, 'unixepoch', 'localtime') AS hour,
                   COUNT(*) AS c
            \(members) WHERE \(whereSQL) AND a.ZDATECREATED IS NOT NULL
            GROUP BY hour
            """)) ?? []
        var hourCounts: [Int: Int] = [:]
        for row in hourRows {
            guard let text = row["hour"]?.string, let hour = Int(text) else { continue }
            hourCounts[hour] = row["c"]?.int ?? 0
        }

        // 官方地名只保留了归档字段，按这个人的照片取样解码（有地名的是少数）。
        let placeRows = (try? database.query("""
            SELECT aa.ZREVERSELOCATIONDATA AS placedata
            \(membersAttr) WHERE \(whereSQL) AND aa.ZREVERSELOCATIONDATA IS NOT NULL LIMIT 2_000
            """)) ?? []
        var placeCounts: [String: Int] = [:]
        for row in placeRows {
            guard let data = row["placedata"]?.data,
                  let place = ReverseGeoArchive.decode(data) else { continue }
            let name = place.city ?? place.district ?? place.province ?? place.poi
            guard let name, !name.isEmpty else { continue }
            placeCounts[name, default: 0] += 1
        }
        let places = placeCounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        .prefix(4)
        .map { PersonInsight.PlaceCount(name: $0.key, count: $0.value) }

        // 官方已为每张照片算好美学评分，人物高光优先用它挑「最好看」的几张，
        // 评分缺失时再退回收藏 / 像素 / 时间。
        let scoreOrder = direct?.hasAestheticScore == true
            ? "COALESCE(a.ZOVERALLAESTHETICSCORE, 0) DESC,"
            : ""
        let highlightRows = (try? database.query("""
            SELECT \(directSelect) \(membersExt)
            WHERE \(whereSQL) AND a.ZKIND = 0
            ORDER BY (a.ZFAVORITE = 1) DESC,
                     \(scoreOrder)
                     (COALESCE(aa.ZORIGINALWIDTH, a.ZWIDTH) * COALESCE(aa.ZORIGINALHEIGHT, a.ZHEIGHT)) DESC,
                     a.ZDATECREATED DESC
            LIMIT 8
            """)) ?? []
        let highlights = highlightRows.compactMap { directPhoto(from: $0) }

        var companions: [PersonInsight.Companion] = []
        let companionRows = (try? database.query("""
            SELECT f2.ZPERSONFORFACE AS pk, COUNT(DISTINCT f2.ZASSETFORFACE) AS c
            FROM ZDETECTEDFACE f1
            JOIN ZDETECTEDFACE f2 ON f2.ZASSETFORFACE = f1.ZASSETFORFACE
                                 AND f2.ZPERSONFORFACE <> f1.ZPERSONFORFACE
            JOIN ZASSET a ON a.Z_PK = f1.ZASSETFORFACE AND a.ZTRASHEDSTATE = 0 AND a.ZHIDDEN = 0
            WHERE f1.ZPERSONFORFACE = ? AND f2.ZPERSONFORFACE IS NOT NULL
            GROUP BY f2.ZPERSONFORFACE ORDER BY c DESC, pk LIMIT 3
            """, [personID])) ?? []
        let companionIDs = companionRows.compactMap { $0["pk"]?.int64 }
        if !companionIDs.isEmpty {
            let peopleRows = (try? database.query("""
                SELECT p.Z_PK AS pk,
                       COALESCE(NULLIF(p.ZDISPLAYNAME, ''), NULLIF(p.ZFULLNAME, ''), '未命名') AS name,
                       (SELECT a2.ZUUID FROM ZDETECTEDFACE f3
                          JOIN ZASSET a2 ON a2.Z_PK = f3.ZASSETFORFACE
                         WHERE f3.Z_PK = p.ZKEYFACE LIMIT 1) AS keyasset
                FROM ZPERSON p
                WHERE p.Z_PK IN (\(inList(companionIDs.map(String.init))))
                """)) ?? []
            var names: [Int64: String] = [:]
            var keyAssets: [Int64: UUID] = [:]
            for row in peopleRows {
                guard let pk = row["pk"]?.int64 else { continue }
                names[pk] = row["name"]?.string ?? "未命名"
                keyAssets[pk] = row["keyasset"]?.string.flatMap(UUID.init(uuidString:))
            }
            companions = companionRows.compactMap { row in
                guard let pk = row["pk"]?.int64, let name = names[pk] else { return nil }
                return PersonInsight.Companion(id: "system-\(pk)",
                                               name: name,
                                               count: row["c"]?.int ?? 0,
                                               coverPhotoID: keyAssets[pk],
                                               coverData: nil)
            }
        }

        return PersonInsight.make(photoCount: max(0, total - videos),
                                  videoCount: videos,
                                  firstDate: earliest,
                                  lastDate: latest,
                                  years: years,
                                  places: places,
                                  periods: PersonInsight.periods(fromHourCounts: hourCounts),
                                  companions: companions,
                                  highlights: highlights,
                                  palettePhotos: Array(highlights.prefix(10)))
    }

    /// 地点详情「同行人物」：按地点里的照片取样统计同框人物，再补名称与关键照片。
    func directCompanions(for photoIDs: [UUID], limit: Int = 3) -> [PhotoCompanion] {
        guard !photoIDs.isEmpty else { return [] }
        var counts: [Int64: Int] = [:]
        let sample = Array(photoIDs.prefix(600))
        var start = 0
        while start < sample.count {
            let end = min(start + 200, sample.count)
            let list = inList(sample[start..<end].map(\.uuidString))
            if let rows = try? database.query("""
                SELECT f.ZPERSONFORFACE AS pk, COUNT(DISTINCT a.ZUUID) AS c
                FROM ZASSET a JOIN ZDETECTEDFACE f ON f.ZASSETFORFACE = a.Z_PK
                WHERE a.ZUUID IN (\(list)) AND f.ZPERSONFORFACE IS NOT NULL
                GROUP BY f.ZPERSONFORFACE
                """) {
                for row in rows {
                    guard let pk = row["pk"]?.int64 else { continue }
                    counts[pk, default: 0] += row["c"]?.int ?? 0
                }
            }
            start = end
        }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
        guard !top.isEmpty else { return [] }
        let ids = top.map { String($0.key) }
        guard let rows = try? database.query("""
            SELECT p.Z_PK AS pk,
                   COALESCE(NULLIF(p.ZDISPLAYNAME, ''), NULLIF(p.ZFULLNAME, ''), '未命名') AS name,
                   (SELECT a2.ZUUID FROM ZDETECTEDFACE f
                      JOIN ZASSET a2 ON a2.Z_PK = f.ZASSETFORFACE
                     WHERE f.Z_PK = p.ZKEYFACE LIMIT 1) AS keyasset
            FROM ZPERSON p WHERE p.Z_PK IN (\(inList(ids)))
            """) else { return [] }
        var names: [Int64: String] = [:]
        var keyAssets: [Int64: UUID] = [:]
        for row in rows {
            guard let pk = row["pk"]?.int64 else { continue }
            names[pk] = row["name"]?.string ?? "未命名"
            keyAssets[pk] = row["keyasset"]?.string.flatMap(UUID.init(uuidString:))
        }
        return top.compactMap { entry in
            guard let name = names[entry.key] else { return nil }
            return PhotoCompanion(id: "system-\(entry.key)",
                                  name: name,
                                  count: entry.value,
                                  coverPhotoID: keyAssets[entry.key],
                                  coverData: nil)
        }
    }

    // MARK: - 年 / 月总览

    /// 年总览：计数来自后台快照（按月的真实聚合），每 4 张样本也是一次日期范围查询。
    func directYearBuckets(_ query: SystemQuery, sampleLimit: Int) -> [PhotoPeriodBucket] {
        guard let snapshot = directCounts,
              let months = directOverviewMonthCounts(query, snapshot: snapshot) else { return [] }
        var yearCounts: [String: Int] = [:]
        for (key, value) in months {
            yearCounts[String(key.prefix(4)), default: 0] += value
        }
        let ascending = query.ascending
        let keys = yearCounts.keys.sorted { ascending ? $0 < $1 : $0 > $1 }
        let usesSamples = directOverviewUsesSamples(query)
        let samples = usesSamples ? (snapshot.yearSamples ?? [:]) : [:]
        let covers = usesSamples ? (snapshot.yearCovers ?? [:]) : [:]
        let calendar = Calendar.current
        return keys.compactMap { key in
            guard let year = Int(key) else { return nil }
            let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
            let ids = directOverviewSampleIDs(cover: covers[key], samples: samples[key] ?? [])
            let photos = directOverviewPhotos(ids, limit: sampleLimit)
            return PhotoPeriodBucket(id: key,
                                     title: DateText.yearFormatter.string(from: date),
                                     count: yearCounts[key] ?? 0,
                                     photos: photos,
                                     capturedAt: photos.first?.capturedAt ?? date)
        }
    }

    /// 月总览：每个自然月一张卡。直连模式不把每个月的每一天都读进内存，
    /// 因此 `days` 为空，卡片直接用该月样本渲染（由视图按 `isDirectSystemIndex` 分支处理）。
    func directMonthGroups(_ query: SystemQuery, sampleLimit: Int) -> [PhotoMonthGroup] {
        guard let snapshot = directCounts,
              let months = directOverviewMonthCounts(query, snapshot: snapshot) else { return [] }
        let ascending = query.ascending
        let keys = months.keys.sorted { ascending ? $0 < $1 : $0 > $1 }
        let usesSamples = directOverviewUsesSamples(query)
        let samples = usesSamples ? (snapshot.monthSamples ?? [:]) : [:]
        let covers = usesSamples ? (snapshot.monthCovers ?? [:]) : [:]
        let calendar = Calendar.current
        return keys.compactMap { key in
            let parts = key.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
            let ids = directOverviewSampleIDs(cover: covers[key], samples: samples[key] ?? [])
            let photos = directOverviewPhotos(ids, limit: sampleLimit)
            return PhotoMonthGroup(id: key,
                                   title: DateText.monthFormatter.string(from: date),
                                   count: months[key] ?? 0,
                                   days: [],
                                   samples: photos)
        }
    }

    /// 快照里的按月计数能否直接用于当前查询；带搜索 / 时间范围等条件时返回 nil，避免显示错误数字。
    func directOverviewMonthCounts(_ query: SystemQuery,
                                           snapshot: SystemDirectCounts) -> [String: Int]? {
        guard directOverviewIsPlain(query), let active = snapshot.monthCounts else { return nil }
        switch query.filter {
        case .all:
            return active
        case .photos:
            let videos = snapshot.monthVideos ?? [:]
            var result: [String: Int] = [:]
            for (key, value) in active {
                result[key] = max(0, value - (videos[key] ?? 0))
            }
            return result
        case .videos:
            return snapshot.monthVideos
        case .favorites:
            return snapshot.monthFavorites
        default:
            return nil
        }
    }

    /// 是否只受“无搜索词、无时间范围、无类型开关”影响（只有这种查询的样本与快照完全一致）。
    func directOverviewIsPlain(_ query: SystemQuery) -> Bool {
        query.startDate == nil && query.endDate == nil
            && query.tokens.isEmpty
            && !query.onlyFavorites && !query.onlyVideos && !query.onlyPhotos
            && !query.onlyScreenshots && !query.onlyLivePhotos && !query.onlyEdited
            && query.overlayKeywordIDs == nil
    }

    /// 卡片样本只在「全部类型 + 无搜索」时可用；其它筛选只保留正确的计数。
    func directOverviewUsesSamples(_ query: SystemQuery) -> Bool {
        directOverviewIsPlain(query) && query.filter == .all
    }

    /// 官方关键照片排在样本最前面（作为卡片封面），其余样本按原顺序补齐。
    func directOverviewSampleIDs(cover: String?, samples: [String]) -> [String] {
        guard let cover, !cover.isEmpty else { return samples }
        return [cover] + samples.filter { $0 != cover }
    }

    func directOverviewPhotos(_ ids: [String], limit: Int) -> [PhotoItem] {
        guard limit > 0, !ids.isEmpty else { return [] }
        let wanted = ids.prefix(limit).compactMap(UUID.init(uuidString:))
        guard !wanted.isEmpty else { return [] }
        return directPhotos(ids: wanted)
    }
}
