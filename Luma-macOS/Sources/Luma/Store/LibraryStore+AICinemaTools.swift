import Foundation

/// 影院智能助手工具的执行实现：只做解析与编排，所有读写都复用 LibraryStore
/// 现有的影院方法与状态，不直接写文件或数据库。
extension LibraryStore {
    private static let aiCinemaDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 通用解析

    private func aiUniqueCinemaEntries(_ entries: [CinemaEntry]) -> [CinemaEntry] {
        var seen = Set<UUID>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private func aiExpandedCinemaEntries(_ entries: [CinemaEntry],
                                         series: [CinemaSeries]) -> [CinemaEntry] {
        var result = entries
        var seen = Set(entries.map(\.id))
        for item in series {
            for episode in item.episodes where seen.insert(episode.id).inserted {
                result.append(episode)
            }
        }
        return result
    }

    /// 影院条目可能在别的网盘作用域里：清单和续播记录只存 photoID，需要跨作用域找回。
    private func aiCinemaEntryAnyScope(id: UUID) -> CinemaEntry? {
        for index in cinemaIndexes.values {
            if let entry = index[id] { return entry }
        }
        return nil
    }

    private func aiDedupeCinemaMovies(_ entries: [CinemaEntry]) -> [CinemaEntry] {
        var best: [String: CinemaEntry] = [:]
        for entry in entries {
            let key = cinemaVersionKey(for: entry)
            if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
            best[key] = entry
        }
        return Array(best.values)
    }

    private func aiIntArray(_ value: Any?) -> [Int] {
        if let list = value as? [Any] {
            return list.compactMap {
                if let int = $0 as? Int { return int }
                if let number = $0 as? NSNumber { return number.intValue }
                if let text = $0 as? String { return Int(text) }
                return nil
            }
        }
        if let int = value as? Int { return [int] }
        if let number = value as? NSNumber { return [number.intValue] }
        return []
    }

    private func aiCinemaEntryMatchesQuery(_ entry: CinemaEntry, query: String) -> Bool {
        let text = query.lowercased()
        if entry.title.lowercased().contains(text) { return true }
        if (entry.originalTitle ?? "").lowercased().contains(text) { return true }
        if entry.file.filename.lowercased().contains(text) { return true }
        if (entry.genres ?? []).contains(where: { $0.lowercased().contains(text) }) { return true }
        if (entry.cast ?? []).contains(where: { $0.name.lowercased().contains(text) }) { return true }
        if (entry.directors ?? []).contains(where: { $0.lowercased().contains(text) }) { return true }
        return false
    }

    private func aiCinemaSeriesMatchesQuery(_ series: CinemaSeries, query: String) -> Bool {
        let text = query.lowercased()
        if series.title.lowercased().contains(text) { return true }
        if (series.overview ?? "").lowercased().contains(text) { return true }
        return series.episodes.contains { aiCinemaEntryMatchesQuery($0, query: query) }
    }

    private enum AICinemaTargetMatch {
        case entries([CinemaEntry])
        case series(CinemaSeries)
    }

    /// 单条引用解析：视频 id > 文件名 > 剧集 id > TMDB 数字 id > 片名精确 > 片名包含。
    private func aiResolveCinemaTarget(_ raw: String,
                                       in scope: CinemaScope) -> AICinemaTargetMatch? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let entries = Array(cinemaEntries(for: scope).values)
            .filter { !cinemaIsRestricted($0) }
        if let id = UUID(uuidString: text),
           let entry = entries.first(where: { $0.id == id }) {
            return .entries([entry])
        }
        if let entry = entries.first(where: {
            $0.file.filename.caseInsensitiveCompare(text) == .orderedSame
        }) {
            return .entries([entry])
        }
        let seriesPool = cinemaSeries(for: scope) + cinemaSeries(for: scope, matched: false)
        if let series = seriesPool.first(where: { $0.id == text }) {
            return .series(series)
        }
        if let tmdb = Int(text),
           let series = seriesPool.first(where: { item in
               item.episodes.contains { $0.tmdbID == tmdb }
           }) {
            return .series(series)
        }
        let lower = text.lowercased()
        let matchedEntries = entries.filter(\.matched)
        if let entry = matchedEntries.first(where: { $0.title.lowercased() == lower }) {
            return .entries([entry])
        }
        if let series = seriesPool.first(where: { $0.title.lowercased() == lower }) {
            return .series(series)
        }
        if let entry = matchedEntries.first(where: { $0.title.lowercased().contains(lower) }) {
            return .entries([entry])
        }
        if let series = seriesPool.first(where: { $0.title.lowercased().contains(lower) }) {
            return .series(series)
        }
        if let entry = entries.first(where: { $0.file.filename.lowercased().contains(lower) }) {
            return .entries([entry])
        }
        return nil
    }

    private func aiResolveCinemaTargets(_ raws: [String],
                                        in scope: CinemaScope)
        -> (entries: [CinemaEntry], series: [CinemaSeries], missing: [String]) {
        var entries: [CinemaEntry] = []
        var series: [CinemaSeries] = []
        var missing: [String] = []
        var seenEntries = Set<UUID>()
        var seenSeries = Set<String>()
        for raw in raws {
            guard let match = aiResolveCinemaTarget(raw, in: scope) else {
                missing.append(raw)
                continue
            }
            switch match {
            case .entries(let list):
                for entry in list where seenEntries.insert(entry.id).inserted {
                    entries.append(entry)
                }
            case .series(let item):
                if seenSeries.insert(item.id).inserted { series.append(item) }
            }
        }
        return (entries, series, missing)
    }

    private func aiResolveCinemaList(id rawID: String?, name rawName: String?) -> CinemaListRecord? {
        if let rawID {
            if let id = UUID(uuidString: rawID),
               let list = cinemaLists.first(where: { $0.id == id }) {
                return list
            }
            if let list = cinemaLists.first(where: { $0.name == rawID }) { return list }
        }
        guard let rawName else { return nil }
        return cinemaLists.first(where: { $0.name == rawName })
            ?? cinemaLists.first(where: { $0.name.localizedCaseInsensitiveContains(rawName) })
    }

    // MARK: - 输出结构

    private func aiCinemaEntryPayload(_ entry: CinemaEntry) -> [String: Any] {
        let state = cinemaUserState(for: entry.id)
        var item: [String: Any] = [
            "id": entry.id.uuidString,
            "filename": entry.file.filename,
            "title": entry.title,
            "matched": entry.matched,
            "kind": entry.kind == .tv ? "tv" : "movie",
            "favorite": state.favorite,
            "watchlist": state.watchlist,
            "watch_state": cinemaWatchState(for: entry).rawValue
        ]
        if entry.kind == .tv {
            item["series_id"] = cinemaSeriesKey(for: entry)
        }
        if let year = entry.year { item["year"] = year }
        if let season = entry.season { item["season"] = season }
        if let episode = entry.episode { item["episode"] = episode }
        if let rating = entry.rating, rating > 0 { item["rating"] = rating }
        if let myRating = state.rating { item["my_rating"] = myRating }
        if let folder = entry.folderHint, !folder.isEmpty { item["folder"] = folder }
        if entry.file.pixelWidth > 0 {
            item["resolution"] = "\(entry.file.pixelWidth)x\(entry.file.pixelHeight)"
        }
        if let progress = cinemaProgress[entry.id] {
            item["progress_percent"] = Int((progress.fraction * 100).rounded())
            item["progress_seconds"] = Int(progress.position.rounded())
            item["duration_seconds"] = Int(progress.duration.rounded())
        }
        return item
    }

    private func aiCinemaSeriesPayload(_ series: CinemaSeries,
                                       includeEpisodes: Bool) -> [String: Any] {
        let episodes = series.episodes
        let states = episodes.map { cinemaUserState(for: $0.id) }
        let seasons = Array(Set(episodes.compactMap(\.season))).sorted()
        var item: [String: Any] = [
            "series_id": series.id,
            "title": series.title,
            "episode_count": series.episodeCount,
            "season_count": seasons.count,
            "seasons": seasons,
            "matched": series.isMatched,
            "favorite": states.contains(where: { $0.favorite }),
            "watchlist": states.contains(where: { $0.watchlist }),
            "watch_state": cinemaWatchState(for: series).rawValue
        ]
        if let year = series.year { item["year"] = year }
        if let rating = series.rating, rating > 0 { item["rating"] = rating }
        if let myRating = states.compactMap(\.rating).max() { item["my_rating"] = myRating }
        if let latest = series.latestEpisode {
            var value: [String: Any] = [
                "id": latest.id.uuidString,
                "watch_state": cinemaWatchState(for: latest).rawValue
            ]
            if let season = latest.season { value["season"] = season }
            if let episode = latest.episode { value["episode"] = episode }
            item["latest"] = value
        }
        if includeEpisodes {
            item["episodes"] = episodes.map { aiCinemaEntryPayload($0) }
        }
        return item
    }

    private func aiCinemaProgressPayload(_ record: CinemaProgressRecord) -> [String: Any] {
        var item: [String: Any] = [
            "photo_id": record.photoID.uuidString,
            "title": record.title,
            "percent": Int((record.fraction * 100).rounded()),
            "position_seconds": Int(record.position.rounded()),
            "duration_seconds": Int(record.duration.rounded()),
            "remaining_seconds": Int(record.remainingSeconds.rounded()),
            "updated_at": Self.aiCinemaDateFormatter.string(from: record.updatedAt)
        ]
        if let subtitle = record.subtitle, !subtitle.isEmpty { item["subtitle"] = subtitle }
        if record.isFinished { item["finished"] = true }
        return item
    }

    // MARK: - 检索

    func searchCinemaLibraryTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let query = AILibraryTools.string(args["query"])
        let filter = AILibraryTools.string(args["filter"]) ?? "all"
        let genre = AILibraryTools.string(args["genre"])
        let year = AILibraryTools.integer(args["year"], fallback: 0)
        let kind = AILibraryTools.string(args["kind"]) ?? "all"
        let watchState = AILibraryTools.string(args["watch_state"])
        let limit = min(1000, max(1, AILibraryTools.integer(args["limit"], fallback: 200)))

        let allEntries = Array(cinemaEntries(for: scope).values)
            .filter { !cinemaIsRestricted($0) }
        let matchedEntries = allEntries.filter(\.matched)

        func entryPasses(_ entry: CinemaEntry) -> Bool {
            if filter == "unmatched" {
                if entry.matched { return false }
            } else if !entry.matched {
                return false
            }
            if filter == "favorites", !cinemaUserState(for: entry.id).favorite { return false }
            if filter == "watchlist", !cinemaUserState(for: entry.id).watchlist { return false }
            if filter == "rated", cinemaUserState(for: entry.id).rating == nil { return false }
            if let genre,
               !(entry.genres ?? []).contains(where: { $0.localizedCaseInsensitiveContains(genre) }) {
                return false
            }
            if year > 0, entry.year != year { return false }
            if let watchState, cinemaWatchState(for: entry).rawValue != watchState { return false }
            if let query, !query.isEmpty, !aiCinemaEntryMatchesQuery(entry, query: query) {
                return false
            }
            return true
        }

        func seriesPasses(_ series: CinemaSeries) -> Bool {
            if !series.episodes.contains(where: { !cinemaIsRestricted($0) }) {
                return false
            }
            if let query, !query.isEmpty, !aiCinemaSeriesMatchesQuery(series, query: query) {
                return false
            }
            if let genre,
               !series.genres.contains(where: { $0.localizedCaseInsensitiveContains(genre) }) {
                return false
            }
            if year > 0, !series.episodes.contains(where: { $0.year == year }) {
                return false
            }
            if let watchState, cinemaWatchState(for: series).rawValue != watchState {
                return false
            }
            switch filter {
            case "favorites":
                if !series.episodes.contains(where: { cinemaUserState(for: $0.id).favorite }) {
                    return false
                }
            case "watchlist":
                if !series.episodes.contains(where: { cinemaUserState(for: $0.id).watchlist }) {
                    return false
                }
            case "rated":
                if !series.episodes.contains(where: { cinemaUserState(for: $0.id).rating != nil }) {
                    return false
                }
            default:
                break
            }
            return true
        }

        var moviePool: [CinemaEntry] = []
        if kind != "tv" {
            moviePool = filter == "unmatched"
                ? allEntries.filter { !$0.matched && $0.kind == .movie }
                : matchedEntries.filter { $0.kind == .movie }
            moviePool = moviePool.filter(entryPasses)
        }
        let movieResults = aiDedupeCinemaMovies(moviePool)
            .sorted { $0.file.capturedAt > $1.file.capturedAt }

        var seriesResults: [CinemaSeries] = []
        if kind != "movie" {
            let pool = filter == "unmatched"
                ? cinemaSeries(for: scope, matched: false)
                : cinemaSeries(for: scope)
            seriesResults = pool.filter(seriesPasses)
                .sorted { ($0.latestEpisode?.file.capturedAt ?? .distantPast)
                    > ($1.latestEpisode?.file.capturedAt ?? .distantPast) }
        }

        var movieBudget = limit
        var seriesBudget = limit
        if !movieResults.isEmpty, !seriesResults.isEmpty {
            movieBudget = max(1, limit / 2)
            seriesBudget = max(1, limit - movieBudget)
        }
        let movieItems = Array(movieResults.prefix(movieBudget))
            .map { aiCinemaEntryPayload($0) }
        let seriesItems = Array(seriesResults.prefix(seriesBudget))
            .map { aiCinemaSeriesPayload($0, includeEpisodes: false) }

        var people: [[String: Any]] = []
        if let query, !query.isEmpty {
            let lower = query.lowercased()
            var seenNames = Set<String>()
            for entry in matchedEntries {
                for member in entry.cast ?? [] where member.name.lowercased().contains(lower) {
                    guard seenNames.insert(member.name).inserted else { continue }
                    var item: [String: Any] = ["name": member.name, "role": "演员"]
                    if let character = member.character, !character.isEmpty {
                        item["character"] = character
                    }
                    if let tmdb = member.tmdbID { item["tmdb_id"] = tmdb }
                    people.append(item)
                    if people.count >= 12 { break }
                }
                for director in entry.directors ?? [] where director.lowercased().contains(lower) {
                    guard seenNames.insert(director).inserted else { continue }
                    people.append(["name": director, "role": "导演"])
                    if people.count >= 12 { break }
                }
                if people.count >= 12 { break }
            }
        }

        let matched = matchedEntries.count
        let total = allEntries.count
        var summaryParts = ["电影 \(movieItems.count)", "剧集 \(seriesItems.count)"]
        if !people.isEmpty { summaryParts.append("人物 \(people.count)") }
        let summary = query.map { "影院搜索「\($0)」：" } ?? "影院筛选："
        var payload: [String: Any] = [
            "scope": ["id": Self.cinemaScopeKey(scope), "name": cinemaScopeName(scope)],
            "total": total,
            "matched": matched,
            "unmatched": max(0, total - matched),
            "movies": movieItems,
            "series": seriesItems
        ]
        if !people.isEmpty { payload["people"] = people }
        let ids = Array(movieResults.prefix(movieBudget).map(\.id)
            + seriesResults.prefix(seriesBudget).flatMap { $0.episodes.map(\.id) })
        return success(payload,
                       summary: summary + summaryParts.joined(separator: " · "),
                       photoIDs: Array(ids.prefix(5000)))
    }

    func listCinemaSeriesTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let matched = AILibraryTools.string(args["matched"]) ?? "matched"
        let watchState = AILibraryTools.string(args["watch_state"])
        let favoriteOnly = AILibraryTools.bool(args["favorite_only"], fallback: false)
        let includeEpisodes = AILibraryTools.bool(args["include_episodes"], fallback: false)
        let limit = min(1000, max(1, AILibraryTools.integer(args["limit"], fallback: 300)))

        var pool: [CinemaSeries] = []
        switch matched {
        case "unmatched":
            pool = cinemaSeries(for: scope, matched: false)
        case "all":
            pool = cinemaSeries(for: scope)
                + cinemaSeries(for: scope, matched: false)
        default:
            pool = cinemaSeries(for: scope)
        }
        let filtered = pool.filter { series in
            if !series.episodes.contains(where: { !cinemaIsRestricted($0) }) {
                return false
            }
            if let watchState, cinemaWatchState(for: series).rawValue != watchState {
                return false
            }
            if favoriteOnly,
               !series.episodes.contains(where: { cinemaUserState(for: $0.id).favorite }) {
                return false
            }
            return true
        }
        .sorted { ($0.latestEpisode?.file.capturedAt ?? .distantPast)
            > ($1.latestEpisode?.file.capturedAt ?? .distantPast) }

        let items = filtered.prefix(limit).map {
            aiCinemaSeriesPayload($0, includeEpisodes: includeEpisodes)
        }
        return success(["scope": cinemaScopeName(scope),
                        "total": filtered.count,
                        "series": Array(items)],
                       summary: "共 \(filtered.count) 部剧集",
                       photoIDs: [])
    }

    func listCinemaActivityTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let kind = AILibraryTools.string(args["kind"]) ?? "continue"
        let limit = min(1000, max(1, AILibraryTools.integer(args["limit"], fallback: 300)))
        var payload: [String: Any] = ["scope": cinemaScopeName(scope)]
        var summaries: [String] = []

        if kind == "continue" || kind == "all" {
            let records = cinemaContinueRecords(for: scope)
            payload["continue"] = records.prefix(limit).map { aiCinemaProgressPayload($0) }
            summaries.append("继续观看 \(records.count)")
        }
        if kind == "history" || kind == "all" {
            let records = cinemaHistory(for: scope)
            payload["history"] = records.prefix(limit).map { aiCinemaProgressPayload($0) }
            summaries.append("观看记录 \(records.count)")
        }
        if kind == "tasks" || kind == "all" {
            let tasks = sourceJobHistory
                .filter { $0.kind == .scrape }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
                .map { task -> [String: Any] in
                    var item: [String: Any] = [
                        "id": task.jobID.uuidString,
                        "scope": cinemaScopeName(forSource: task.sourceID),
                        "total": task.total ?? 0,
                        "matched": task.completed,
                        "succeeded": task.phase == .finished,
                        "message": task.message ?? "",
                        "started_at": Self.aiCinemaDateFormatter.string(from: task.updatedAt)
                    ]
                    item["finished_at"] = Self.aiCinemaDateFormatter.string(from: task.updatedAt)
                    return item
                }
            payload["tasks"] = Array(tasks)
            summaries.append("任务 \(sourceJobHistory.filter { $0.kind == .scrape }.count)")
        }
        if kind == "notifications" || kind == "all" {
            let notes = cinemaNotifications
                .sorted { $0.date > $1.date }
                .prefix(limit)
                .map { note -> [String: Any] in
                    [
                        "kind": note.kind.rawValue,
                        "title": note.title,
                        "detail": note.detail,
                        "read": note.read,
                        "date": Self.aiCinemaDateFormatter.string(from: note.date)
                    ]
                }
            payload["notifications"] = Array(notes)
            summaries.append("通知 \(cinemaNotifications.count)")
        }
        return success(payload,
                       summary: summaries.joined(separator: " · "),
                       photoIDs: [])
    }

    func listCinemaListsTool(_ args: [String: Any]) -> AIToolExecution {
        let includeItems = AILibraryTools.bool(args["include_items"], fallback: false)
        let limit = min(1000, max(1, AILibraryTools.integer(args["limit"], fallback: 300)))
        let lists = cinemaLists.prefix(limit).map { list -> [String: Any] in
            var item: [String: Any] = [
                "id": list.id.uuidString,
                "name": list.name,
                "count": list.count,
                "created_at": Self.aiCinemaDateFormatter.string(from: list.createdAt)
            ]
            if includeItems {
                item["items"] = list.itemIDs.compactMap { id -> [String: Any]? in
                    guard let entry = aiCinemaEntryAnyScope(id: id),
                          !cinemaIsRestricted(entry) else { return nil }
                    return aiCinemaEntryPayload(entry)
                }
            }
            return item
        }
        return success(["total": cinemaLists.count, "lists": Array(lists)],
                       summary: "共 \(cinemaLists.count) 个影院清单",
                       photoIDs: [])
    }

    // MARK: - 浏览与播放

    func navigateCinemaTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        activateCinemaScope(scope)
        switch scope {
        case .local:
            navigate(to: .cinema)
        case .mount(let id):
            navigate(to: .cloudCinema(id))
        }

        if AILibraryTools.bool(args["reset_filters"], fallback: false) {
            resetCinemaFilters()
        }
        if let raw = AILibraryTools.string(args["tab"]), let tab = CinemaTab(rawValue: raw) {
            // 顶栏类型与频道互斥：显式切频道时清掉类型筛选。
            cinemaTypeFilterID = nil
            cinemaTab = tab
        }
        if let raw = AILibraryTools.string(args["view_mode"]),
           let mode = CinemaViewMode(rawValue: raw) {
            cinemaViewMode = mode
        }
        if let raw = AILibraryTools.string(args["sort"]),
           let sort = CinemaSort(rawValue: raw) {
            cinemaSort = sort
        }
        if let raw = args["years"] ?? args["decades"] {
            cinemaYears = Set(aiIntArray(raw))
        }
        if args["genres"] != nil {
            cinemaGenres = Set(AILibraryTools.stringArray(args["genres"]))
        }
        if args["resolutions"] != nil {
            cinemaResolutions = Set(AILibraryTools.stringArray(args["resolutions"])
                .compactMap { CinemaResolutionFilter(rawValue: $0) })
        }
        if args["watch_states"] != nil {
            cinemaWatchFilters = Set(AILibraryTools.stringArray(args["watch_states"])
                .compactMap { CinemaWatchFilter(rawValue: $0) })
        }
        if args["specs"] != nil {
            cinemaSpecFilters = Set(AILibraryTools.stringArray(args["specs"])
                .compactMap { CinemaSpecFilter(rawValue: $0) })
        }
        if let value = args["high_rated"] as? Bool { cinemaSmartHighRated = value }
        if let value = args["recent"] as? Bool { cinemaSmartRecent = value }
        if let value = args["favorites_only"] as? Bool { cinemaFavoritesOnly = value }
        if let list = aiResolveCinemaList(id: AILibraryTools.string(args["list_id"]),
                                          name: AILibraryTools.string(args["list_name"])) {
            cinemaActiveListID = list.id
        }

        let panel = AILibraryTools.string(args["panel"]) ?? "none"
        if panel != "none" {
            // 影院页要挂载后才消费这些旗标，延后一拍再置位。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                switch panel {
                case "search": self.cinemaSearchVisible = true
                case "history": self.cinemaHistoryVisible = true
                case "notifications": self.cinemaNotificationsVisible = true
                case "new_list": self.cinemaNewListVisible = true
                default: break
                }
            }
        }

        var filters: [String] = []
        if !cinemaYears.isEmpty { filters.append("年份") }
        if !cinemaGenres.isEmpty { filters.append("类型") }
        if !cinemaKindFilters.isEmpty { filters.append("内容") }
        if !cinemaCountries.isEmpty { filters.append("地区") }
        if !cinemaLanguages.isEmpty { filters.append("语言") }
        if !cinemaRuntimeFilters.isEmpty { filters.append("片长") }
        if !cinemaRatingFilters.isEmpty { filters.append("评分") }
        if let typeID = cinemaTypeFilterID {
            filters.append("内容类型：\(CinemaContentType.descriptor(id: typeID).title)")
        }
        if !cinemaResolutions.isEmpty { filters.append("分辨率") }
        if !cinemaWatchFilters.isEmpty { filters.append("观看状态") }
        if !cinemaSpecFilters.isEmpty { filters.append("规格") }
        if cinemaSmartHighRated { filters.append("高分") }
        if cinemaSmartRecent { filters.append("最近") }
        if cinemaFavoritesOnly { filters.append("收藏") }
        if let list = cinemaList(cinemaActiveListID) {
            filters.append("清单：\(list.name)")
        }
        var payload: [String: Any] = [
            "scope": ["id": Self.cinemaScopeKey(scope), "name": cinemaScopeName(scope)],
            "tab": cinemaTab.rawValue,
            "view_mode": cinemaViewMode.rawValue,
            "sort": cinemaSort.rawValue,
            "filters": filters
        ]
        if panel != "none" { payload["panel"] = panel }
        let suffix = filters.isEmpty ? "" : "，筛选：" + filters.joined(separator: "、")
        return success(payload,
                       summary: "已打开影院「\(cinemaScopeName(scope))」\(suffix)",
                       photoIDs: [])
    }

    private func aiNextCinemaEpisode(in series: CinemaSeries,
                                     season: Int?,
                                     episode: Int?) -> CinemaEntry? {
        let episodes = series.episodes
            .filter { !cinemaIsRestricted($0) }
            .sorted { lhs, rhs in
            if lhs.season != rhs.season { return (lhs.season ?? 0) < (rhs.season ?? 0) }
            if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
            return lhs.file.capturedAt < rhs.file.capturedAt
        }
        guard !episodes.isEmpty else { return nil }
        if let season {
            let inSeason = episodes.filter { ($0.season ?? 1) == season }
            guard !inSeason.isEmpty else { return nil }
            if let episode {
                return inSeason.first { $0.episode == episode }
                    ?? inSeason.first
            }
            return inSeason.first
        }
        if let episode {
            return episodes.first { $0.episode == episode } ?? episodes.first
        }
        // 优先接着最近一条未看完的进度播下一集。
        let inProgress = episodes.compactMap { entry -> (CinemaEntry, CinemaProgressRecord)? in
            guard let record = cinemaProgress[entry.id],
                  !record.isFinished,
                  record.position > 3 else { return nil }
            return (entry, record)
        }
        .max { $0.1.updatedAt < $1.1.updatedAt }
        if let (current, _) = inProgress,
           let index = episodes.firstIndex(where: { $0.id == current.id }),
           index + 1 < episodes.count {
            return episodes[index + 1]
        }
        if let unwatched = episodes.first(where: {
            cinemaWatchState(for: $0) == .unwatched
        }) {
            return unwatched
        }
        return episodes.first
    }

    func playCinemaTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let rawSeason = AILibraryTools.integer(args["season"], fallback: 0)
        let rawEpisode = AILibraryTools.integer(args["episode"], fallback: 0)
        let season: Int? = rawSeason > 0 ? rawSeason : nil
        let episode: Int? = rawEpisode > 0 ? rawEpisode : nil

        var entry: CinemaEntry?
        if let target = AILibraryTools.string(args["target"]) {
            switch aiResolveCinemaTarget(target, in: scope) {
            case .series(let series):
                entry = aiNextCinemaEpisode(in: series, season: season, episode: episode)
            case .entries(let list):
                entry = list.first
            case .none:
                entry = nil
            }
            guard entry != nil else {
                return failure("没有找到「\(target)」对应的视频或剧集；可先调用 search_cinema_library")
            }
        } else {
            let record = cinemaContinueRecord(for: scope)
                ?? cinemaContinueRecords(for: scope).first
            if let record {
                entry = cinemaEntry(for: record.photoID) ?? aiCinemaEntryAnyScope(id: record.photoID)
            }
            guard entry != nil else {
                return failure("这个影院没有可继续播放的记录；请用 target 指定影片或剧集")
            }
        }
        guard let entry else { return failure("没有找到可播放的视频") }

        openCinema(entry)
        var name = entry.title
        if entry.kind == .tv, let season = entry.season, let episode = entry.episode {
            name += String(format: " S%02dE%02d", season, episode)
        }
        return success(["playing": entry.id.uuidString,
                        "title": name,
                        "scope": cinemaScopeName(scope)],
                       summary: "播放「\(name)」",
                       photoIDs: [entry.id])
    }

    // MARK: - 收藏 / 想看 / 评分

    func updateCinemaStateTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let raws = AILibraryTools.stringArray(args["targets"])
        guard !raws.isEmpty else { return failure("缺少 targets") }
        guard args["favorite"] != nil || args["watchlist"] != nil || args["rating"] != nil else {
            return failure("至少提供 favorite / watchlist / rating 之一")
        }
        let resolved = aiResolveCinemaTargets(raws, in: scope)
        let entries = aiUniqueCinemaEntries(
            aiExpandedCinemaEntries(resolved.entries, series: resolved.series))
        guard !entries.isEmpty else {
            return failure("没有找到这些影院条目；可先调用 search_cinema_library")
        }
        let ids = Set(entries.map(\.id))

        if args["favorite"] != nil {
            setCinemaFavorite(AILibraryTools.bool(args["favorite"], fallback: true), ids: ids)
        }
        if args["watchlist"] != nil {
            setCinemaWatchlist(AILibraryTools.bool(args["watchlist"], fallback: true), ids: ids)
        }
        if args["rating"] != nil {
            let rating = AILibraryTools.integer(args["rating"], fallback: 0)
            for entry in entries {
                setCinemaRating(rating > 0 ? rating : nil, for: entry.id)
            }
        }

        var items: [[String: Any]] = []
        for entry in entries.prefix(1000) {
            let state = cinemaUserState(for: entry.id)
            var item: [String: Any] = [
                "id": entry.id.uuidString,
                "title": entry.title,
                "favorite": state.favorite,
                "watchlist": state.watchlist
            ]
            if let rating = state.rating { item["my_rating"] = rating }
            items.append(item)
        }
        var payload: [String: Any] = ["scope": cinemaScopeName(scope),
                                      "updated": entries.count,
                                      "items": items]
        if !resolved.missing.isEmpty { payload["missing"] = resolved.missing }
        return success(payload,
                       summary: "已更新影院条目 \(entries.count) 项",
                       photoIDs: Array(entries.prefix(5000).map(\.id)))
    }

    // MARK: - 清单

    func manageCinemaListTool(_ args: [String: Any]) -> AIToolExecution {
        guard let action = AILibraryTools.string(args["action"]) else {
            return failure("缺少 action")
        }
        switch action {
        case "create":
            guard let name = AILibraryTools.string(args["name"]) else {
                return failure("新建清单需要提供 name")
            }
            if cinemaLists.contains(where: { $0.name == name }) {
                return failure("已有同名清单「\(name)」")
            }
            let list = createCinemaList(named: name)
            return success(["id": list.id.uuidString, "name": list.name, "count": 0],
                           summary: "已新建影院清单「\(list.name)」",
                           photoIDs: [])
        default:
            break
        }

        guard let list = aiResolveCinemaList(id: AILibraryTools.string(args["list_id"]),
                                             name: AILibraryTools.string(args["list_name"])) else {
            return failure("没有找到这个清单；可先调用 list_cinema_lists")
        }
        switch action {
        case "delete":
            deleteCinemaList(list.id)
            return success(["deleted": list.name],
                           summary: "已删除影院清单「\(list.name)」（影片未删除）",
                           photoIDs: [])
        case "clear_items":
            let count = list.itemIDs.count
            for id in list.itemIDs {
                removeFromCinemaList(list.id, entryID: id)
            }
            return success(["list": list.name, "removed": count],
                           summary: "已清空影院清单「\(list.name)」的 \(count) 项",
                           photoIDs: [])
        case "add", "remove":
            guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
                return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
            }
            let raws = AILibraryTools.stringArray(args["targets"])
            guard !raws.isEmpty else { return failure("缺少 targets") }
            let resolved = aiResolveCinemaTargets(raws, in: scope)
            let entries = aiUniqueCinemaEntries(
                aiExpandedCinemaEntries(resolved.entries, series: resolved.series))
            guard !entries.isEmpty else {
                return failure("没有找到要加入 / 移出的影片；可先调用 search_cinema_library")
            }
            for entry in entries {
                if action == "add" {
                    addToCinemaList(list.id, entryID: entry.id)
                } else {
                    removeFromCinemaList(list.id, entryID: entry.id)
                }
            }
            let updated = cinemaList(list.id)
            var payload: [String: Any] = [
                "list": list.name,
                "count": updated?.count ?? 0,
                "changed": entries.count
            ]
            if !resolved.missing.isEmpty { payload["missing"] = resolved.missing }
            return success(payload,
                           summary: action == "add"
                               ? "已把 \(entries.count) 项加入清单「\(list.name)」"
                               : "已从清单「\(list.name)」移出 \(entries.count) 项",
                           photoIDs: [])
        default:
            return failure("不支持的动作：\(action)")
        }
    }

    // MARK: - 忽略 / 恢复

    func ignoreCinemaTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let raws = AILibraryTools.stringArray(args["targets"])
        guard !raws.isEmpty else { return failure("缺少 targets") }
        let resolved = aiResolveCinemaTargets(raws, in: scope)
        guard !resolved.entries.isEmpty || !resolved.series.isEmpty else {
            return failure("没有找到要忽略的视频或剧集；可先调用 search_cinema_library")
        }

        var ignored = 0
        var names: [String] = []
        for series in resolved.series {
            ignoreCinemaSeries(series)
            ignored += series.episodeCount
            names.append(series.title)
        }
        let seriesEpisodeIDs = Set(resolved.series.flatMap { $0.episodes.map(\.id) })
        for entry in resolved.entries where !seriesEpisodeIDs.contains(entry.id) {
            ignoreCinemaEntry(entry)
            ignored += 1
            names.append(entry.title)
        }
        var payload: [String: Any] = ["scope": cinemaScopeName(scope),
                                      "ignored": ignored]
        if !resolved.missing.isEmpty { payload["missing"] = resolved.missing }
        let preview = names.prefix(3).joined(separator: "、")
        return success(payload,
                       summary: "已忽略 \(ignored) 个视频（\(preview)）",
                       photoIDs: [])
    }

    func restoreCinemaIgnoredTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let count = cinemaIgnoredIDs[scope]?.count ?? 0
        guard count > 0 else { return failure("「\(cinemaScopeName(scope))」没有被忽略的视频") }
        restoreCinemaIgnored(for: scope)
        return success(["scope": cinemaScopeName(scope), "restored": count],
                       summary: "已恢复 \(count) 个被忽略的视频",
                       photoIDs: [])
    }

    // MARK: - 元数据刷新

    func refreshCinemaMetadataTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let mode = AILibraryTools.string(args["mode"]) ?? "enrich"
        let force = AILibraryTools.bool(args["force"], fallback: false)
        let limit = min(1000, max(1, AILibraryTools.integer(args["limit"], fallback: 100)))
        let raws = AILibraryTools.stringArray(args["targets"])

        var entries: [CinemaEntry]
        if raws.isEmpty {
            entries = Array(cinemaEntries(for: scope).values)
                .filter { $0.matched && !cinemaIsRestricted($0) }
                .sorted { $0.file.capturedAt > $1.file.capturedAt }
        } else {
            let resolved = aiResolveCinemaTargets(raws, in: scope)
            entries = aiExpandedCinemaEntries(resolved.entries, series: resolved.series)
                .filter { !cinemaIsRestricted($0) }
        }
        entries = aiUniqueCinemaEntries(entries)
        guard !entries.isEmpty else {
            return failure("没有找到可刷新的影片；可先调用 search_cinema_library")
        }

        var updated: [[String: Any]] = []
        for entry in entries.prefix(limit) {
            if Task.isCancelled { break }
            if mode == "rescrape" {
                await rescrapeCinema(entry)
            } else {
                _ = await enrichCinemaEntry(entry, force: force)
            }
            guard let current = cinemaIndexes[scope]?[entry.id] else { continue }
            var item: [String: Any] = [
                "id": current.id.uuidString,
                "title": current.title,
                "matched": current.matched
            ]
            if let year = current.year { item["year"] = year }
            if let cast = current.cast, !cast.isEmpty { item["cast_count"] = cast.count }
            if let certification = current.certification, !certification.isEmpty {
                item["certification"] = certification
            }
            updated.append(item)
        }

        let action = mode == "rescrape" ? "重新刮削" : "补全详情"
        if updated.isEmpty {
            return failure("没有可更新的条目；豆瓣条目没有详情接口，可改用 rescrape 重新刮削")
        }
        return success(["scope": cinemaScopeName(scope),
                        "mode": mode,
                        "updated": updated.count,
                        "items": updated],
                       summary: "已\(action) \(updated.count) 项影院元数据",
                       photoIDs: [])
    }

    // MARK: - 跳过片头 / 片尾

    func setCinemaIntroSkipTool(_ args: [String: Any]) -> AIToolExecution {
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let raws = AILibraryTools.stringArray(args["targets"])
        guard !raws.isEmpty else { return failure("缺少 targets") }
        let clear = AILibraryTools.bool(args["clear"], fallback: false)
        let intro = clear ? 0 : min(3600, max(0, AILibraryTools.integer(args["intro_seconds"],
                                                                      fallback: 0)))
        let outro = clear ? 0 : min(3600, max(0, AILibraryTools.integer(args["outro_seconds"],
                                                                      fallback: 0)))
        let perEpisode = AILibraryTools.bool(args["per_episode"], fallback: false)
        let mark = CinemaIntroMark(introSeconds: intro, outroSeconds: outro)

        let resolved = aiResolveCinemaTargets(raws, in: scope)
        guard !resolved.entries.isEmpty || !resolved.series.isEmpty else {
            return failure("没有找到要设置的剧集；可先调用 list_cinema_series")
        }

        var applied = 0
        var skipped: [String] = []
        var appliedSeries = Set<String>()
        for series in resolved.series {
            setCinemaIntroMark(mark, forSeriesKey: series.id)
            appliedSeries.insert(series.id)
            applied += 1
        }
        for entry in resolved.entries {
            guard entry.kind == .tv else {
                skipped.append(entry.title)
                continue
            }
            let key = cinemaSeriesKey(for: entry)
            if perEpisode {
                setCinemaIntroMark(mark, for: entry)
            } else if !appliedSeries.contains(key) {
                setCinemaIntroMark(mark, forSeriesKey: key)
                appliedSeries.insert(key)
            }
            applied += 1
        }

        guard applied > 0 else {
            return failure("跳过片头只对剧集生效，所选视频里没有剧集")
        }
        var payload: [String: Any] = [
            "scope": cinemaScopeName(scope),
            "intro_seconds": intro,
            "outro_seconds": outro,
            "applied": applied
        ]
        if !skipped.isEmpty { payload["skipped_movies"] = skipped }
        let detail = clear
            ? "已清除跳过片头 / 片尾设置"
            : "已设置跳过片头 \(intro) 秒 / 片尾 \(outro) 秒"
        return success(payload,
                       summary: "\(detail)（\(applied) 项）",
                       photoIDs: [])
    }

    // MARK: - 观看记录

    func manageCinemaProgressTool(_ args: [String: Any]) -> AIToolExecution {
        guard let action = AILibraryTools.string(args["action"]) else {
            return failure("缺少 action")
        }
        if action == "clear" {
            clearCinemaProgress()
            return success(["cleared": true],
                           summary: "已清空全部影院的观看记录",
                           photoIDs: [])
        }
        guard let scope = aiResolvedCinemaScope(AILibraryTools.string(args["scope"])) else {
            return failure("没有找到这个影院，请先调用 list_cinema_scopes 确认 scope")
        }
        let raws = AILibraryTools.stringArray(args["targets"])
        guard !raws.isEmpty else { return failure("移除观看进度需要提供 targets") }
        let resolved = aiResolveCinemaTargets(raws, in: scope)
        let entries = aiUniqueCinemaEntries(
            aiExpandedCinemaEntries(resolved.entries, series: resolved.series))
        guard !entries.isEmpty else {
            return failure("没有找到这些影院条目；可先调用 list_cinema_activity 或 search_cinema_library")
        }

        var removed = 0
        for entry in entries where cinemaProgress[entry.id] != nil {
            removeCinemaProgress(entry.id)
            removed += 1
        }
        var payload: [String: Any] = ["scope": cinemaScopeName(scope),
                                      "removed": removed]
        if !resolved.missing.isEmpty { payload["missing"] = resolved.missing }
        return success(payload,
                       summary: "已移除 \(removed) 项观看进度",
                       photoIDs: [])
    }
}
