import Foundation

/// 一次查询的总量与视频数，供底部计数胶囊使用，避免为了显示数字而载入全部照片。
struct PhotoQuerySummary: Equatable {
    let total: Int
    let videos: Int
}

/// 把 `PhotoQuery` 编译成 SQL 的分页查询层。
/// 所有方法都会占用 `MetadataStore` 自己的串行队列，调用方可以从后台线程直接调用。
extension MetadataStore {
    private static let rawExtensions = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf",
        "rw2", "pef", "srw", "raw", "3fr", "erf", "mef", "mos", "iiq", "rwl"
    ]

    // MARK: - 公开查询

    func summary(_ query: PhotoQuery) -> PhotoQuerySummary {
        queue.sync {
            let (whereSQL, binds) = whereClause(query)
            let sql = """
                SELECT COUNT(*) AS total,
                       COALESCE(SUM(CASE WHEN kind = 'video' THEN 1 ELSE 0 END), 0) AS videos
                FROM assets WHERE \(whereSQL)
                """
            guard let row = try? db.query(sql, binds).first else {
                return PhotoQuerySummary(total: 0, videos: 0)
            }
            return PhotoQuerySummary(total: row["total"]?.int ?? 0,
                                     videos: row["videos"]?.int ?? 0)
        }
    }

    func page(_ query: PhotoQuery, offset: Int, limit: Int) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        return queue.sync {
            let (whereSQL, binds) = whereClause(query)
            let sql = """
                SELECT * FROM assets\(indexHint(query)) WHERE \(whereSQL)
                ORDER BY \(orderExpression(query)) \(query.ascending ? "ASC" : "DESC"), id \(query.ascending ? "ASC" : "DESC")
                LIMIT ? OFFSET ?
                """
            guard let rows = try? db.query(sql, binds + [limit, max(0, offset)]) else { return [] }
            return rows.compactMap { Self.photo(from: $0) }
        }
    }

    func photos(in query: PhotoQuery, range: Range<Int>) -> [PhotoItem] {
        guard range.lowerBound >= 0, range.count > 0 else { return [] }
        return page(query, offset: range.lowerBound, limit: range.count)
    }

    func photo(atOffset offset: Int, in query: PhotoQuery) -> PhotoItem? {
        page(query, offset: offset, limit: 1).first
    }

    func photo(id: UUID) -> PhotoItem? {
        queue.sync {
            guard let row = try? db.query("SELECT * FROM assets WHERE id = ?", [id.uuidString]).first else {
                return nil
            }
            return Self.photo(from: row)
        }
    }

    /// 当前查询下全部命中项的 ID（用于「全选」，只取 id 列，不解析整行）。
    func allIDs(_ query: PhotoQuery) -> [UUID] {
        queue.sync {
            let (whereSQL, binds) = whereClause(query)
            let sql = """
                SELECT id FROM assets\(indexHint(query)) WHERE \(whereSQL)
                ORDER BY \(orderExpression(query)) \(query.ascending ? "ASC" : "DESC"), id \(query.ascending ? "ASC" : "DESC")
                """
            guard let rows = try? db.query(sql, binds) else { return [] }
            return rows.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
        }
    }

    /// 某张照片在当前查询排序中的下标（0 起）。用 COUNT 比较排序键，O(log n) 级别。
    func index(of id: UUID, in query: PhotoQuery) -> Int? {
        queue.sync {
            let expr = orderExpression(query)
            guard let row = try? db.query("SELECT \(expr) AS k FROM assets WHERE id = ?",
                                          [id.uuidString]).first,
                  let key = row["k"] else { return nil }
            let (whereSQL, binds) = whereClause(query)
            // 并列时按 id 同向打破平局，让 (排序键, id) 复合索引可以直接顺序扫描。
            let comparison = query.ascending ? "<" : ">"
            let idComparison = query.ascending ? "<" : ">"
            let sql = """
                SELECT COUNT(*) AS c FROM assets\(indexHint(query))
                WHERE \(whereSQL) AND ((\(expr) \(comparison) ?) OR (\(expr) = ? AND id \(idComparison) ?))
                """
            let value = bindValue(key)
            guard let countRow = try? db.query(sql, binds + [value, value, id.uuidString]).first else {
                return nil
            }
            return countRow["c"]?.int
        }
    }

    /// 当前查询排序下相邻的一张（delta 只能为 ±1）。
    /// 用「排序键 + id」做 keyset 查询，复杂度是索引 seek，不受照片总量影响。
    func neighbor(of id: UUID, delta: Int, in query: PhotoQuery) -> PhotoItem? {
        guard abs(delta) == 1 else { return nil }
        return queue.sync {
            let expr = orderExpression(query)
            guard let row = try? db.query("SELECT \(expr) AS k FROM assets WHERE id = ?",
                                          [id.uuidString]).first,
                  let key = row["k"] else { return nil }

            let forward = delta > 0
            let descending = !query.ascending
            let comparison = forward
                ? (descending ? "<" : ">")
                : (descending ? ">" : "<")
            let scanDirection = forward
                ? (descending ? "DESC" : "ASC")
                : (descending ? "ASC" : "DESC")
            let (whereSQL, binds) = whereClause(query)
            let hint = indexHint(query)
            let value = bindValue(key)
            let sql = """
                SELECT * FROM assets\(hint) WHERE \(whereSQL)
                  AND ((\(expr) \(comparison) ?) OR (\(expr) = ? AND id \(comparison) ?))
                ORDER BY \(expr) \(scanDirection), id \(scanDirection) LIMIT 1
                """
            if let row = try? db.query(sql, binds + [value, value, id.uuidString]).first,
               let photo = Self.photo(from: row) {
                return photo
            }
            // 到头了：环绕到另一端（与列表循环翻页一致）。
            let wrapDirection = forward
                ? (descending ? "DESC" : "ASC")
                : (descending ? "ASC" : "DESC")
            let wrapSQL = """
                SELECT * FROM assets\(hint) WHERE \(whereSQL)
                ORDER BY \(expr) \(wrapDirection), id \(wrapDirection) LIMIT 1
                """
            return (try? db.query(wrapSQL, binds).first).flatMap { Self.photo(from: $0) }
        }
    }

    /// 「年」总览：按年分区，只取每年最多 4 张样本与真实总数。
    func yearBuckets(_ query: PhotoQuery, sampleLimit: Int = 4) -> [PhotoPeriodBucket] {
        queue.sync {
            let (whereSQL, binds) = whereClause(query)
            let direction = overviewDirection(query)
            let period = "strftime('%Y', captured_at, 'unixepoch', 'localtime')"
            let sql = """
                SELECT * FROM (
                    SELECT assets.*, \(period) AS period_key,
                           COUNT(*) OVER (PARTITION BY \(period)) AS period_count,
                           ROW_NUMBER() OVER (PARTITION BY \(period)
                                              ORDER BY captured_at \(direction), id \(direction)) AS rn
                    FROM assets WHERE \(whereSQL)
                ) WHERE rn <= \(sampleLimit)
                ORDER BY period_key \(direction), captured_at \(direction), id \(direction)
                """
            let rows: [[String: SQLiteValue]]
            do {
                rows = try db.query(sql, binds)
            } catch {
                FileHandle.standardError.write(Data("year buckets failed: \(error)\n".utf8))
                return []
            }
            var order: [String] = []
            var samples: [String: [PhotoItem]] = [:]
            var counts: [String: Int] = [:]
            var firstDates: [String: Date] = [:]
            for row in rows {
                guard let key = row["period_key"]?.string, let photo = Self.photo(from: row) else { continue }
                if samples[key] == nil {
                    order.append(key)
                    counts[key] = row["period_count"]?.int ?? 0
                    firstDates[key] = photo.capturedAt
                }
                samples[key, default: []].append(photo)
            }
            return order.compactMap { key in
                guard let photos = samples[key], let date = firstDates[key] else { return nil }
                return PhotoPeriodBucket(id: key,
                                         title: DateText.yearFormatter.string(from: date),
                                         count: counts[key] ?? photos.count,
                                         photos: photos,
                                         capturedAt: date)
            }
        }
    }

    /// 「月」总览：按月分区，段内按天分组，每天最多 4 张样本。
    func monthGroups(_ query: PhotoQuery, sampleLimit: Int = 4) -> [PhotoMonthGroup] {
        queue.sync {
            let (whereSQL, binds) = whereClause(query)
            let direction = overviewDirection(query)
            let month = "strftime('%Y-%m', captured_at, 'unixepoch', 'localtime')"
            let day = "strftime('%Y-%m-%d', captured_at, 'unixepoch', 'localtime')"
            let sql = """
                SELECT * FROM (
                    SELECT assets.*, \(month) AS month_key, \(day) AS day_key,
                           COUNT(*) OVER (PARTITION BY \(day)) AS day_count,
                           COUNT(*) OVER (PARTITION BY \(month)) AS month_count,
                           ROW_NUMBER() OVER (PARTITION BY \(day)
                                              ORDER BY captured_at \(direction), id \(direction)) AS rn
                    FROM assets WHERE \(whereSQL)
                ) WHERE rn <= \(sampleLimit)
                ORDER BY month_key \(direction), day_key \(direction), captured_at \(direction), id \(direction)
                """
            guard let rows = try? db.query(sql, binds) else { return [] }

            struct MonthDraft {
                var order: [String] = []
                var samples: [String: [PhotoItem]] = [:]
                var counts: [String: Int] = [:]
                var firstDates: [String: Date] = [:]
                var dayCount: Int = 0
            }
            var monthOrder: [String] = []
            var drafts: [String: MonthDraft] = [:]
            var monthCounts: [String: Int] = [:]
            var monthFirstDates: [String: Date] = [:]

            for row in rows {
                guard let monthKey = row["month_key"]?.string,
                      let dayKey = row["day_key"]?.string,
                      let photo = Self.photo(from: row) else { continue }
                if drafts[monthKey] == nil {
                    monthOrder.append(monthKey)
                    drafts[monthKey] = MonthDraft()
                    monthCounts[monthKey] = row["month_count"]?.int ?? 0
                    monthFirstDates[monthKey] = photo.capturedAt
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
                guard let draft = drafts[monthKey],
                      let monthDate = monthFirstDates[monthKey] else { return nil }
                let days = draft.order.compactMap { dayKey -> PhotoDayBucket? in
                    guard let photos = draft.samples[dayKey], let date = draft.firstDates[dayKey] else {
                        return nil
                    }
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
    }

    /// 总览的排列方向：按拍摄日期时跟随升降序，其它排序保持最新在前。
    private func overviewDirection(_ query: PhotoQuery) -> String {
        if query.sortKey == .capturedAt {
            return query.ascending ? "ASC" : "DESC"
        }
        return "DESC"
    }

    // MARK: - SQL 片段

    /// 排序键对应的复合索引。没有统计信息时 SQLite 会误选单列索引并对全表排序，
    /// 这里对「未删除 + 未隐藏 + 常用排序」明确指定索引，保证分页是顺序扫描。
    private func indexHint(_ query: PhotoQuery) -> String {
        guard query.scope != .hidden, query.scope != .trash else { return "" }
        switch query.sortKey {
        case .capturedAt: return " INDEXED BY idx_assets_live_captured_id"
        case .addedAt: return " INDEXED BY idx_assets_live_added_id"
        case .fileSize: return " INDEXED BY idx_assets_live_size_id"
        case .title: return " INDEXED BY idx_assets_live_title_id"
        case .filename: return " INDEXED BY idx_assets_live_filename_id"
        case .kind, .camera, .place, .duration: return ""
        }
    }

    private func whereClause(_ query: PhotoQuery) -> (String, [Any?]) {
        var clauses: [String] = []
        var binds: [Any?] = []

        switch query.scope {
        case .library:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0)")
        case .favorites:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND is_favorite = 1)")
        case .videos:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND kind = 'video')")
        case .screenshots:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND kind = 'screenshot')")
        case .selfies:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND kind = 'selfie')")
        case .panoramas:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND kind = 'panorama')")
        case .livePhotos:
            clauses.append("""
                (deleted_at IS NULL AND is_hidden = 0
                 AND (is_live_photo = 1 OR live_photo_filename IS NOT NULL OR live_photo_video_path IS NOT NULL))
                """)
        case .animated:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND (is_animated = 1 OR lower(original_name) LIKE '%.gif'))")
        case .raws:
            let likes = Self.rawExtensions.map { _ in "lower(original_name) LIKE ?" }.joined(separator: " OR ")
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND (\(likes)))")
            binds.append(contentsOf: Self.rawExtensions.map { "%.\($0)" as Any? })
        case .recentlyEdited:
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND edited_filename IS NOT NULL)")
        case .recentlySaved:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            clauses.append("(deleted_at IS NULL AND is_hidden = 0 AND added_at >= ?)")
            binds.append(cutoff.timeIntervalSince1970)
        case .hidden:
            clauses.append("(deleted_at IS NULL AND is_hidden = 1)")
        case .trash:
            clauses.append("(deleted_at IS NOT NULL)")
        }

        switch query.filter {
        case .all:
            break
        case .favorites:
            clauses.append("is_favorite = 1")
        case .edited:
            clauses.append("edited_filename IS NOT NULL")
        case .photos:
            clauses.append("kind <> 'video'")
        case .videos:
            clauses.append("kind = 'video'")
        case .screenshots:
            clauses.append("kind = 'screenshot'")
        case .mine:
            clauses.append("(make IS NOT NULL OR model IS NOT NULL)")
        case .notInAlbum:
            clauses.append("NOT EXISTS (SELECT 1 FROM album_assets aa WHERE aa.asset_id = assets.id)")
        }

        if let keyword = query.keyword, !keyword.isEmpty {
            // 关键词以 JSON 数组保存，instr 匹配带引号的完整词，避免子串误命中。
            clauses.append("(keywords IS NOT NULL AND instr(keywords, ?) > 0)")
            binds.append("\"\(keyword)\"")
        }

        if query.minRating > 0 {
            clauses.append("COALESCE(rating, 0) >= ?")
            binds.append(query.minRating)
        }
        if let flag = query.flag {
            clauses.append("COALESCE(flag, 'none') = ?")
            binds.append(flag.rawValue)
        }
        if let colorLabel = query.colorLabel {
            clauses.append("COALESCE(color_label, 'none') = ?")
            binds.append(colorLabel.rawValue)
        }

        return (clauses.joined(separator: " AND "), binds)
    }

    private func orderExpression(_ query: PhotoQuery) -> String {
        switch query.sortKey {
        case .capturedAt:
            return "captured_at"
        case .addedAt:
            return "added_at"
        case .title:
            return "COALESCE(NULLIF(title, ''), original_name) COLLATE NOCASE"
        case .filename:
            return "COALESCE(edited_filename, filename) COLLATE NOCASE"
        case .fileSize:
            return "file_size"
        case .kind:
            return "kind COLLATE NOCASE"
        case .camera:
            return "COALESCE(NULLIF(model, ''), NULLIF(make, ''), '') COLLATE NOCASE"
        case .place:
            return "COALESCE(place_city, place_province, place_country, '') COLLATE NOCASE"
        case .duration:
            return "COALESCE(duration, 0)"
        }
    }

    private func bindValue(_ value: SQLiteValue) -> Any? {
        switch value {
        case .null: return nil
        case .integer(let number): return number
        case .real(let number): return number
        case .text(let text): return text
        case .blob(let data): return data
        }
    }
}
