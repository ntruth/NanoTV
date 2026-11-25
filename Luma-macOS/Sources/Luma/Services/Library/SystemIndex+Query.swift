import Foundation

/// 系统图库的查询接口。

extension SystemIndex {
    // MARK: - 查询

    func summary(_ query: SystemQuery) -> PhotoQuerySummary {
        if direct != nil { return directSummary(query) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let sql = """
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN isvideo = 1 THEN 1 ELSE 0 END), 0) AS videos
            FROM \(from) WHERE \(whereSQL)
            """
        guard let row = try? database.query(sql, fromBinds + binds).first else {
            return PhotoQuerySummary(total: 0, videos: 0)
        }
        return PhotoQuerySummary(total: row["total"]?.int ?? 0,
                                 videos: row["videos"]?.int ?? 0)
    }

    func page(_ query: SystemQuery, offset: Int, limit: Int) -> [PhotoItem] {
        if direct != nil { return directPage(query, offset: offset, limit: limit) }
        guard limit > 0 else { return [] }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let sql = """
            SELECT assets.* FROM \(from) WHERE \(whereSQL)
            ORDER BY \(orderExpression(query)) \(query.ascending ? "ASC" : "DESC"),
                     assets.uuid \(query.ascending ? "ASC" : "DESC")
            LIMIT ? OFFSET ?
            """
        guard let rows = try? database.query(sql, fromBinds + binds + [limit, max(0, offset)]) else {
            return []
        }
        return rows.compactMap { photo(from: $0) }
    }

    /// 当前查询下的全部项目 ID（只取 uuid 列）：供 ⌘A 全选当前范围的全部照片，
    /// 不受分页窗口只加载了一页的限制。
    func allIDs(_ query: SystemQuery) -> [UUID] {
        if direct != nil { return directAllIDs(query) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        var ids: [UUID] = []
        try? database.forEachRow("SELECT assets.uuid AS uuid FROM \(from) WHERE \(whereSQL)",
                                  fromBinds + binds) { row in
            if let value = row["uuid"]?.string, let id = UUID(uuidString: value) {
                ids.append(id)
            }
        }
        return ids
    }

    func photos(in query: SystemQuery, range: Range<Int>) -> [PhotoItem] {
        guard range.lowerBound >= 0, range.count > 0 else { return [] }
        return page(query, offset: range.lowerBound, limit: range.count)
    }

    /// 某张照片在当前查询排序中的下标（0 起）。
    func index(of id: UUID, in query: SystemQuery) -> Int? {
        if direct != nil { return nil }
        guard let target = sortValue(of: id, in: query) else { return nil }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let expr = orderExpression(query)
        let comparison = query.ascending ? "<" : ">"
        let sql = """
            SELECT COUNT(*) AS c FROM \(from)
            WHERE \(whereSQL) AND ((\(expr) \(comparison) ?) OR (\(expr) = ? AND assets.uuid \(comparison) ?))
            """
        guard let row = try? database.query(sql, fromBinds + binds + [target.value, target.value, id.uuidString]).first else {
            return nil
        }
        return row["c"]?.int
    }

    /// 当前查询排序下相邻的一张（delta 只能为 ±1），到两端环绕。
    func neighbor(of id: UUID, delta: Int, in query: SystemQuery) -> PhotoItem? {
        if direct != nil { return directNeighbor(of: id, delta: delta, in: query) }
        guard abs(delta) == 1 else { return nil }
        guard let current = index(of: id, in: query) else { return nil }
        let count = summary(query).total
        guard count > 0 else { return nil }
        var next = current + delta
        if next < 0 { next += count }
        if next >= count { next -= count }
        return page(query, offset: next, limit: 1).first
    }

    func photo(id: UUID) -> PhotoItem? {
        if direct != nil { return directPhoto(id: id) }
        guard let row = try? database.query("SELECT * FROM assets WHERE uuid = ?", [id.uuidString]).first else {
            return nil
        }
        return photo(from: row)
    }

    /// 连拍组的全部成员（按拍摄时间升序）：查看器组内浏览与连拍播放用。
    func burstMembers(groupID: String) -> [PhotoItem] {
        if direct != nil { return directBurstMembers(groupID: groupID) }
        guard let rows = try? database.query(
            "SELECT * FROM assets WHERE burstuuid = ? ORDER BY created ASC, pk ASC", [groupID]) else {
            return []
        }
        return rows.compactMap { photo(from: $0) }
    }

    /// 按 ID 批量取照片，保持输入顺序。
    func photos(ids: [UUID]) -> [PhotoItem] {
        if direct != nil { return directPhotos(ids: ids) }
        guard !ids.isEmpty else { return [] }
        var byID: [UUID: PhotoItem] = [:]
        var start = 0
        while start < ids.count {
            let end = min(start + 500, ids.count)
            let chunk = ids[start..<end]
            let list = inList(chunk.map(\.uuidString))
            if let rows = try? database.query("SELECT * FROM assets WHERE uuid IN (\(list))") {
                for row in rows {
                    if let item = photo(from: row) { byID[item.id] = item }
                }
            }
            start = end
        }
        return ids.compactMap { byID[$0] }
    }

    // MARK: - 人物摘要

    /// 某个查询范围内的人物摘要：计数、年度、地点、时段、高光与同框人物全部由 SQLite 聚合，
    /// 不把整库照片读进内存。
    func personInsight(_ query: SystemQuery) -> PersonInsight {
        if direct != nil { return directPersonInsight(query) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let base = fromBinds + binds

        var total = 0
        var videos = 0
        var earliest: Date?
        var latest: Date?
        if let row = try? database.query("""
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(CASE WHEN isvideo = 1 THEN 1 ELSE 0 END), 0) AS videos,
                   MIN(created) AS earliest,
                   MAX(created) AS latest
            FROM \(from) WHERE \(whereSQL)
            """, base).first {
            total = row["total"]?.int ?? 0
            videos = row["videos"]?.int ?? 0
            earliest = row["earliest"]?.double.map { Date(timeIntervalSince1970: $0) }
            latest = row["latest"]?.double.map { Date(timeIntervalSince1970: $0) }
        }

        let yearRows = (try? database.query("""
            SELECT strftime('%Y', created, 'unixepoch', 'localtime') AS period,
                   COUNT(*) AS c
            FROM \(from) WHERE \(whereSQL)
            GROUP BY period ORDER BY period
            """, base)) ?? []
        let years = yearRows.compactMap { row -> PersonInsight.YearCount? in
            guard let text = row["period"]?.string, let year = Int(text) else { return nil }
            return PersonInsight.YearCount(year: year, count: row["c"]?.int ?? 0)
        }

        let placeRows = (try? database.query("""
            SELECT placecity AS name, COUNT(*) AS c
            FROM \(from)
            WHERE \(whereSQL) AND placecity IS NOT NULL AND length(placecity) > 0
            GROUP BY placecity ORDER BY c DESC, name LIMIT 4
            """, base)) ?? []
        let places = placeRows.compactMap { row -> PersonInsight.PlaceCount? in
            guard let name = row["name"]?.string, !name.isEmpty else { return nil }
            return PersonInsight.PlaceCount(name: name, count: row["c"]?.int ?? 0)
        }

        let hourRows = (try? database.query("""
            SELECT strftime('%H', created, 'unixepoch', 'localtime') AS hour,
                   COUNT(*) AS c
            FROM \(from) WHERE \(whereSQL)
            GROUP BY hour
            """, base)) ?? []
        var hourCounts: [Int: Int] = [:]
        for row in hourRows {
            guard let text = row["hour"]?.string, let hour = Int(text) else { continue }
            hourCounts[hour] = row["c"]?.int ?? 0
        }

        let highlightRows = (try? database.query("""
            SELECT assets.* FROM \(from)
            WHERE \(whereSQL) AND isvideo = 0
            ORDER BY (favorite = 1) DESC, (pixelwidth * pixelheight) DESC, created DESC
            LIMIT 8
            """, base)) ?? []
        let highlights = highlightRows.compactMap { photo(from: $0) }

        var companions: [PersonInsight.Companion] = []
        if case .person(let personID) = query.scope {
            let rows = (try? database.query("""
                SELECT pa2.person AS pk, COUNT(DISTINCT pa2.asset) AS c
                FROM person_assets pa
                JOIN person_assets pa2 ON pa2.asset = pa.asset AND pa2.person <> pa.person
                JOIN assets ON assets.uuid = pa2.asset AND assets.trashed IS NULL
                WHERE pa.person = ?
                GROUP BY pa2.person ORDER BY c DESC LIMIT 3
                """, [personID])) ?? []
            let ids = rows.compactMap { $0["pk"]?.int64 }
            if !ids.isEmpty {
                let peopleRows = (try? database.query(
                    "SELECT pk, name, crop FROM people WHERE pk IN (\(inList(ids.map(String.init))))")) ?? []
                var names: [Int64: String] = [:]
                var crops: [Int64: Data] = [:]
                for row in peopleRows {
                    guard let pk = row["pk"]?.int64 else { continue }
                    names[pk] = row["name"]?.string ?? "未命名"
                    if let data = row["crop"]?.data { crops[pk] = data }
                }
                companions = rows.compactMap { row in
                    guard let pk = row["pk"]?.int64, let name = names[pk] else { return nil }
                    return PersonInsight.Companion(id: "system-\(pk)",
                                                   name: name,
                                                   count: row["c"]?.int ?? 0,
                                                   coverPhotoID: nil,
                                                   coverData: crops[pk])
                }
            }
        }

        let palettePhotos = Array(highlights.prefix(10))
        return PersonInsight.make(photoCount: max(0, total - videos),
                                  videoCount: videos,
                                  firstDate: earliest,
                                  lastDate: latest,
                                  years: years,
                                  places: places,
                                  periods: PersonInsight.periods(fromHourCounts: hourCounts),
                                  companions: companions,
                                  highlights: highlights,
                                  palettePhotos: palettePhotos)
    }

    // MARK: - 年 / 月总览

    func yearBuckets(_ query: SystemQuery, sampleLimit: Int = 4) -> [PhotoPeriodBucket] {
        // 直连模式下年份计数来自后台按月聚合的快照，样本按年份范围查询。
        if direct != nil { return directYearBuckets(query, sampleLimit: sampleLimit) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let direction = overviewDirection(query)
        let period = "strftime('%Y', created, 'unixepoch', 'localtime')"
        let sql = """
            SELECT * FROM (
                SELECT assets.*, \(period) AS period_key,
                       COUNT(*) OVER (PARTITION BY \(period)) AS period_count,
                       ROW_NUMBER() OVER (PARTITION BY \(period)
                                          ORDER BY assets.created \(direction), assets.uuid \(direction)) AS rn
                FROM \(from) WHERE \(whereSQL)
            ) WHERE rn <= \(sampleLimit)
            ORDER BY period_key \(direction), created \(direction), uuid \(direction)
            """
        guard let rows = try? database.query(sql, fromBinds + binds) else { return [] }
        var order: [String] = []
        var samples: [String: [PhotoItem]] = [:]
        var counts: [String: Int] = [:]
        var dates: [String: Date] = [:]
        for row in rows {
            guard let key = row["period_key"]?.string, let photo = photo(from: row) else { continue }
            if samples[key] == nil {
                order.append(key)
                counts[key] = row["period_count"]?.int ?? 0
                dates[key] = photo.capturedAt
            }
            samples[key, default: []].append(photo)
        }
        return order.compactMap { key in
            guard let photos = samples[key], let date = dates[key] else { return nil }
            return PhotoPeriodBucket(id: key,
                                     title: DateText.yearFormatter.string(from: date),
                                     count: counts[key] ?? photos.count,
                                     photos: photos,
                                     capturedAt: date)
        }
    }

    func monthGroups(_ query: SystemQuery, sampleLimit: Int = 4) -> [PhotoMonthGroup] {
        if direct != nil { return directMonthGroups(query, sampleLimit: sampleLimit) }
        let (from, fromBinds) = fromFragment(query)
        let (whereSQL, binds) = whereClause(query)
        let direction = overviewDirection(query)
        let month = "strftime('%Y-%m', created, 'unixepoch', 'localtime')"
        let day = "strftime('%Y-%m-%d', created, 'unixepoch', 'localtime')"
        let sql = """
            SELECT * FROM (
                SELECT assets.*, \(month) AS month_key, \(day) AS day_key,
                       COUNT(*) OVER (PARTITION BY \(day)) AS day_count,
                       COUNT(*) OVER (PARTITION BY \(month)) AS month_count,
                       ROW_NUMBER() OVER (PARTITION BY \(day)
                                          ORDER BY assets.created \(direction), assets.uuid \(direction)) AS rn
                FROM \(from) WHERE \(whereSQL)
            ) WHERE rn <= \(sampleLimit)
            ORDER BY month_key \(direction), day_key \(direction), created \(direction), uuid \(direction)
            """
        guard let rows = try? database.query(sql, fromBinds + binds) else { return [] }

        struct MonthDraft {
            var order: [String] = []
            var samples: [String: [PhotoItem]] = [:]
            var counts: [String: Int] = [:]
            var firstDates: [String: Date] = [:]
        }
        var monthOrder: [String] = []
        var drafts: [String: MonthDraft] = [:]
        var monthCounts: [String: Int] = [:]
        var monthDates: [String: Date] = [:]

        for row in rows {
            guard let monthKey = row["month_key"]?.string,
                  let dayKey = row["day_key"]?.string,
                  let photo = photo(from: row) else { continue }
            if drafts[monthKey] == nil {
                monthOrder.append(monthKey)
                drafts[monthKey] = MonthDraft()
                monthCounts[monthKey] = row["month_count"]?.int ?? 0
                monthDates[monthKey] = photo.capturedAt
            }
            if drafts[monthKey]?.samples[dayKey] == nil {
                drafts[monthKey]?.order.append(dayKey)
                drafts[monthKey]?.counts[dayKey] = row["day_count"]?.int ?? 0
                drafts[monthKey]?.firstDates[dayKey] = photo.capturedAt
            }
            drafts[monthKey]?.samples[dayKey, default: []].append(photo)
        }

        let calendar = Calendar.current
        return monthOrder.compactMap { monthKey in
            guard let draft = drafts[monthKey], let monthDate = monthDates[monthKey] else { return nil }
            let days = draft.order.compactMap { dayKey -> PhotoDayBucket? in
                guard let photos = draft.samples[dayKey], let date = draft.firstDates[dayKey] else { return nil }
                let dayNumber = calendar.component(.day, from: date)
                return PhotoDayBucket(id: dayKey,
                                      title: "\(dayNumber)日",
                                      count: draft.counts[dayKey] ?? photos.count,
                                      photos: photos,
                                      capturedAt: date)
            }
            return PhotoMonthGroup(id: monthKey,
                                   title: DateText.monthFormatter.string(from: monthDate),
                                   count: monthCounts[monthKey] ?? days.reduce(0) { $0 + $1.count },
                                   days: days)
        }
    }

    // MARK: - SQL 片段

    func fromFragment(_ query: SystemQuery) -> (String, [Any?]) {
        switch query.scope {
        case .album(let id):
            return ("assets JOIN album_assets aa ON aa.asset = assets.uuid AND aa.album = \(id)", [])
        case .person(let id):
            return ("assets JOIN person_assets pa ON pa.asset = assets.uuid AND pa.person = \(id)", [])
        default:
            return ("assets", [])
        }
    }

    /// 未被隐藏、未被删除（考虑拾光补充元数据对收藏 / 隐藏的覆盖）。
    func activePredicate(_ query: SystemQuery) -> String {
        let hiddenAdds = inList(query.hiddenAdds)
        let hiddenRemoves = inList(query.hiddenRemoves)
        return """
            (trashed IS NULL AND ((hidden = 0 AND assets.uuid NOT IN (\(hiddenAdds)))
             OR (hidden = 1 AND assets.uuid IN (\(hiddenRemoves)))))
            """
    }

    func whereClause(_ query: SystemQuery) -> (String, [Any?]) {
        var clauses: [String] = []
        var binds: [Any?] = []
        let active = activePredicate(query)
        let favoriteAdds = inList(query.favoriteAdds)
        let favoriteRemoves = inList(query.favoriteRemoves)
        let hiddenAdds = inList(query.hiddenAdds)
        let hiddenRemoves = inList(query.hiddenRemoves)

        switch query.scope {
        case .all, .album, .person:
            clauses.append(active)
        case .favorites:
            clauses.append("""
                \(active) AND ((favorite = 1 AND assets.uuid NOT IN (\(favoriteRemoves)))
                 OR assets.uuid IN (\(favoriteAdds)))
                """)
        case .videos:
            clauses.append("\(active) AND isvideo = 1")
        case .screenshots:
            clauses.append("\(active) AND mediakind = 'screenshot'")
        case .hidden:
            clauses.append("""
                (trashed IS NULL AND ((hidden = 1 AND assets.uuid NOT IN (\(hiddenRemoves)))
                 OR assets.uuid IN (\(hiddenAdds))))
                """)
        case .trash:
            clauses.append("trashed IS NOT NULL")
        case .portraits:
            clauses.append("\(active) AND depth > 0 AND isvideo = 0")
        case .selfies:
            clauses.append("\(active) AND mediakind = 'selfie' AND isvideo = 0")
        case .livePhotos:
            clauses.append("\(active) AND islive = 1")
        case .panoramas:
            clauses.append("\(active) AND mediakind = 'panorama'")
        case .longExposures, .cinematics:
            // Photos.sqlite 没有稳定字段，具体集合由 PhotoKit 智能相簿的 includeIDs 提供。
            clauses.append(active)
        case .spatial:
            // 本地索引没有空间媒体字段；空间照片只在系统图库直连模式显示。
            clauses.append("0")
        case .timelapses:
            clauses.append("\(active) AND istimelapse = 1")
        case .bursts:
            // 按组展示代表照片：多成员组取键照片（burstpick），
            // 单成员组没有键照片标记、自身即代表（与官方「照片」口径一致）。
            clauses.append("""
                \(active) AND isburst = 1 AND (burstpick = 1
                 OR burstuuid IN (SELECT s.burstuuid FROM assets s
                                  WHERE s.isburst = 1
                                  GROUP BY s.burstuuid HAVING COUNT(*) = 1))
                """)
        case .slowMotion:
            clauses.append("\(active) AND isslow = 1")
        case .screenRecordings:
            clauses.append("\(active) AND isscreenrec = 1")
        case .animated:
            clauses.append("\(active) AND isanimated = 1")
        case .raws:
            clauses.append("\(active) AND israw = 1")
        case .edited:
            clauses.append("\(active) AND isedited = 1")
        case .recentlyViewed:
            let cutoff = (query.viewedCutoff ?? Self.recentlyViewedCutoff).timeIntervalSince1970
            clauses.append("\(active) AND viewedat >= \(cutoff)")
        case .duplicates:
            clauses.append("\(active) AND duplicate = 1")
        case .recentlySaved:
            let cutoff = (query.savedCutoff ?? Self.recentlySavedCutoff).timeIntervalSince1970
            clauses.append("\(active) AND added >= \(cutoff)")
        case .imports:
            clauses.append("\(active) AND isdeviceimport = 1")
        case .importSession:
            // 本地索引没有官方导入会话编号；只在系统图库直连模式使用。
            clauses.append("0")
        case .revisit:
            let captureCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge).timeIntervalSince1970
            let viewCutoff = Date().addingTimeInterval(-LibraryHealthTuning.revisitViewAge).timeIntervalSince1970
            clauses.append("""
                \(active) AND created <= \(captureCutoff)
                AND (viewedat IS NULL OR viewedat < \(viewCutoff))
                """)
        case .withLocation:
            clauses.append("\(active) AND haslocation = 1")
        case .folder(let id):
            let albumIDs = albumIDs(inFolder: id)
            let list = inList(albumIDs.map(String.init))
            clauses.append("""
                \(active) AND assets.uuid IN (SELECT asset FROM album_assets WHERE album IN (\(list)))
                """)
        }

        if query.onlyLocated {
            clauses.append("haslocation = 1")
        }

        switch query.filter {
        case .all:
            break
        case .favorites:
            clauses.append("""
                ((favorite = 1 AND assets.uuid NOT IN (\(favoriteRemoves)))
                 OR assets.uuid IN (\(favoriteAdds)))
                """)
        case .edited:
            clauses.append("isedited = 1")
        case .photos:
            clauses.append("isvideo = 0")
        case .videos:
            clauses.append("isvideo = 1")
        case .screenshots:
            clauses.append("mediakind = 'screenshot'")
        case .mine:
            clauses.append("(make IS NOT NULL OR model IS NOT NULL)")
        case .notInAlbum:
            clauses.append("inalbum = 0")
        }

        if let start = query.startDate {
            clauses.append("created >= \(start.timeIntervalSince1970)")
        }
        if let end = query.endDate {
            clauses.append("created < \(end.timeIntervalSince1970)")
        }
        if query.onlyFavorites {
            clauses.append("""
                ((favorite = 1 AND assets.uuid NOT IN (\(favoriteRemoves)))
                 OR assets.uuid IN (\(favoriteAdds)))
                """)
        }
        if query.onlyVideos { clauses.append("isvideo = 1") }
        if query.onlyPhotos { clauses.append("isvideo = 0") }
        if query.onlyScreenshots { clauses.append("mediakind = 'screenshot'") }
        if query.onlyLivePhotos { clauses.append("islive = 1") }
        if query.onlyEdited { clauses.append("isedited = 1") }
        if let keywordIDs = query.overlayKeywordIDs {
            clauses.append("assets.uuid IN (\(inList(keywordIDs)))")
        }
        if let includeIDs = query.includeIDs {
            clauses.append("assets.uuid IN (\(inList(includeIDs)))")
        }
        for token in query.tokens where !token.isEmpty {
            let value = "%\(token.lowercased())%"
            // 关键词 / AI 标签 / OCR 命中由上层换算成 UUID，作为该 token 的 OR 条件。
            let keywordIDs = query.tokenKeywordIDs?[token] ?? []
            let keywordClause = keywordIDs.isEmpty ? "" : " OR assets.uuid IN (\(inList(keywordIDs)))"
            clauses.append("""
                (lower(filename) LIKE ? OR lower(originalname) LIKE ?
                 OR lower(COALESCE(title, '')) LIKE ?
                 OR lower(COALESCE(placecountry, '') || ' ' || COALESCE(placeprovince, '') || ' '
                          || COALESCE(placecity, '') || ' ' || COALESCE(placedistrict, '') || ' '
                          || COALESCE(placepoi, '')) LIKE ?
                 OR lower(COALESCE(make, '') || ' ' || COALESCE(model, '') || ' '
                          || COALESCE(lens, '')) LIKE ?\(keywordClause))
                """)
            binds.append(contentsOf: [value, value, value, value, value])
        }
        return (clauses.joined(separator: " AND "), binds)
    }

    /// 官方相簿手动顺序（`ZGENERICALBUM` 关联表的 position）；其它排序字段由用户选择决定。
    func orderExpression(_ query: SystemQuery) -> String {
        if case .album = query.scope, query.manualOrder {
            return "aa.position"
        }
        switch query.sortKey {
        case .capturedAt: return "assets.created"
        case .addedAt: return "assets.added"
        case .title: return "COALESCE(NULLIF(assets.title, ''), assets.originalname) COLLATE NOCASE"
        case .filename: return "assets.filename COLLATE NOCASE"
        case .fileSize: return "assets.filesize"
        case .kind: return "assets.mediakind COLLATE NOCASE"
        case .camera: return "COALESCE(NULLIF(assets.model, ''), NULLIF(assets.make, ''), '') COLLATE NOCASE"
        case .place: return "COALESCE(NULLIF(assets.placecity, ''), NULLIF(assets.placeprovince, ''), NULLIF(assets.placecountry, ''), '') COLLATE NOCASE"
        case .duration: return "COALESCE(assets.duration, 0)"
        }
    }

    func overviewDirection(_ query: SystemQuery) -> String {
        if query.sortKey == .capturedAt {
            return query.ascending ? "ASC" : "DESC"
        }
        return "DESC"
    }

    func sortValue(of id: UUID, in query: SystemQuery) -> (value: Any, isText: Bool)? {
        if case .album = query.scope, query.manualOrder {
            guard let row = try? database.query("""
                SELECT aa.position AS v FROM album_assets aa WHERE aa.asset = ?
                """, [id.uuidString]).first,
                let value = row["v"] else { return nil }
            return (value.int64 ?? 0, false)
        }
        let expr = orderExpression(query)
        guard let row = try? database.query("SELECT \(expr) AS v FROM assets WHERE uuid = ?",
                                            [id.uuidString]).first,
              let value = row["v"] else { return nil }
        switch value {
        case .null: return (0, false)
        case .integer(let number): return (number, false)
        case .real(let number): return (number, false)
        case .text(let text): return (text, true)
        case .blob: return (0, false)
        }
    }

    static var recentlySavedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    static var recentlyViewedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf",
        "rw2", "pef", "srw", "raw", "3fr", "erf", "mef", "mos", "iiq", "rwl"
    ]

    func inList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "''" }
        return values.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
            .joined(separator: ",")
    }

    // MARK: - 行 → PhotoItem

    func photo(from row: [String: SQLiteValue]) -> PhotoItem? {
        guard let uuidString = row["uuid"]?.string,
              let uuid = UUID(uuidString: uuidString),
              let filename = row["filename"]?.string else { return nil }
        let kind = MediaKind(rawValue: row["mediakind"]?.string ?? "photo") ?? .photo
        let originalName = row["originalname"]?.string ?? filename
        var item = PhotoItem(
            id: uuid,
            filename: filename,
            editedFilename: nil,
            originalName: originalName,
            capturedAt: Date(timeIntervalSince1970: row["created"]?.double ?? 0),
            addedAt: Date(timeIntervalSince1970: row["added"]?.double ?? 0),
            pixelWidth: row["width"]?.int ?? 0,
            pixelHeight: row["height"]?.int ?? 0,
            fileSize: row["filesize"]?.int64 ?? 0,
            kind: kind
        )
        item.isFavorite = (row["favorite"]?.int ?? 0) == 1
        item.isHidden = (row["hidden"]?.int ?? 0) == 1
        item.isPortraitCapture = (row["depth"]?.int ?? 0) > 0
        item.isDuplicateItem = (row["duplicate"]?.int ?? 0) == 1
        item.isLivePhoto = (row["islive"]?.int ?? 0) == 1
        item.isBurstItem = (row["isburst"]?.int ?? 0) == 1
        item.burstGroupID = row["burstuuid"]?.string
        item.isBurstKeyPhoto = (row["burstpick"]?.int ?? 0) == 1
        item.isSlowMotion = (row["isslow"]?.int ?? 0) == 1
        item.isTimelapse = (row["istimelapse"]?.int ?? 0) == 1
        item.isCinematic = (row["iscinematic"]?.int ?? 0) == 1
        item.isSpatial = (row["isspatial"]?.int ?? 0) == 1
        item.isScreenRecording = (row["isscreenrec"]?.int ?? 0) == 1
        item.isAnimated = (row["isanimated"]?.int ?? 0) == 1
        item.isDeviceImport = (row["isdeviceimport"]?.int ?? 0) == 1
        item.duration = row["duration"]?.double
        item.latitude = row["latitude"]?.double
        item.longitude = row["longitude"]?.double
        item.placeCountry = row["placecountry"]?.string
        item.placeProvince = row["placeprovince"]?.string
        item.placeCity = row["placecity"]?.string
        item.placeDistrict = row["placedistrict"]?.string
        item.placePOI = row["placepoi"]?.string
        item.make = row["make"]?.string
        item.model = row["model"]?.string
        item.lens = row["lens"]?.string
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
        if let title = row["title"]?.string, !title.isEmpty {
            item.title = title
        }
        if let viewed = row["viewedat"]?.double {
            item.viewedAt = Date(timeIntervalSince1970: viewed)
        }
        if let edited = row["editedat"]?.double {
            item.editedAt = Date(timeIntervalSince1970: edited)
        }
        if let trashed = row["trashed"]?.double {
            item.deletedAt = Date(timeIntervalSince1970: trashed)
        }
        item.source = .system
        item.systemOriginalPath = row["origpath"]?.string
        item.systemThumbnailPath = row["thumbpath"]?.string
        item.livePhotoVideoPath = row["livevideopath"]?.string
        return item
    }

    // MARK: - 辅助

    static func coreDataDate(_ value: SQLiteValue?) -> Date? {
        guard let raw = value?.double, raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    static func parseEXIFDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    struct AlbumAssetJoin {
        let table: String
        let albumColumn: String
        let assetColumn: String
        let orderColumn: String?
    }

    static func findAlbumAssetJoin(_ db: SQLiteDatabase) -> AlbumAssetJoin? {
        guard let tables = try? db.query("SELECT name FROM sqlite_master WHERE type = 'table'") else {
            return nil
        }
        for tableRow in tables {
            guard let table = tableRow["name"]?.string, table.hasPrefix("Z_") else { continue }
            guard let columns = try? db.query("PRAGMA table_info(\"\(table)\")") else { continue }
            let names = columns.compactMap { $0["name"]?.string }
            guard let assetColumn = names.first(where: { $0 == "Z_3ASSETS" }),
                  let albumColumn = names.first(where: { name in
                      guard name.hasPrefix("Z_"), name.hasSuffix("ALBUMS") else { return false }
                      let middle = name.dropFirst(2).dropLast(6)
                      return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
                  }) else { continue }
            let orderColumn = names.first(where: { $0 == "Z_FOK_3ASSETS" })
            return AlbumAssetJoin(table: table,
                                  albumColumn: albumColumn,
                                  assetColumn: assetColumn,
                                  orderColumn: orderColumn)
        }
        return nil
    }
}
