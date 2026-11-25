import Foundation
import AppKit
import Combine
import LumaContentCore

/// 影院的浏览侧逻辑：观看状态、筛选、聚合缓存与多版本。

extension LibraryStore {
    // MARK: 观看状态

    /// 单条的观看状态：没有进度=未看；有进度未到 95%=进行中；到 95%=已看完。
    func cinemaWatchState(for entry: CinemaEntry) -> CinemaWatchFilter {
        guard let record = cinemaProgress[entry.id], record.fraction > 0.01 else {
            return .unwatched
        }
        return record.isFinished ? .finished : .inProgress
    }

    /// 剧集取聚合状态：全部看完=已看完；任意进度或部分看完=进行中；否则未看。
    func cinemaWatchState(for series: CinemaSeries) -> CinemaWatchFilter {
        let states = series.episodes.map { cinemaWatchState(for: $0) }
        guard !states.isEmpty else { return .unwatched }
        if states.allSatisfy({ $0 == .finished }) { return .finished }
        if states.contains(where: { $0 != .unwatched }) { return .inProgress }
        return .unwatched
    }

    func cinemaEntry(for id: UUID) -> CinemaEntry? {
        cinemaEntries[id]
    }

    // MARK: 筛选

    /// 除收藏 / 清单外的条目级筛选是否启用：分类行与空态用它判断「是否在筛」。
    var cinemaHasAttributeFilters: Bool {
        !cinemaYears.isEmpty
            || !cinemaGenres.isEmpty
            || cinemaTypeFilterID != nil
            || !cinemaKindFilters.isEmpty
            || !cinemaCountries.isEmpty
            || !cinemaLanguages.isEmpty
            || !cinemaRuntimeFilters.isEmpty
            || !cinemaRatingFilters.isEmpty
            || !cinemaResolutions.isEmpty
            || !cinemaSpecFilters.isEmpty
            || !cinemaWatchFilters.isEmpty
            || cinemaSmartHighRated
            || cinemaSmartRecent
    }

    /// 影院筛选的单一判定：年代 / 类型 / 分辨率 / 观看状态可多选，组内 OR、组间 AND。
    func cinemaPassesFilters(_ entry: CinemaEntry) -> Bool {
        guard entry.matched else { return false }
        if cinemaIsRestricted(entry) { return false }
        if !cinemaYears.isEmpty,
           !(entry.year.map { cinemaYears.contains($0) } ?? false) { return false }
        if !cinemaGenres.isEmpty,
           Set(entry.genres ?? []).isDisjoint(with: cinemaGenres) { return false }
        if let typeID = cinemaTypeFilterID,
           !CinemaContentType.descriptor(id: typeID).matches(entry.genres) { return false }
        if !cinemaKindFilters.isEmpty, !cinemaKindFilters.contains(entry.kind) { return false }
        if !cinemaCountries.isEmpty,
           Set(entry.countries ?? []).isDisjoint(with: cinemaCountries) { return false }
        if !cinemaLanguages.isEmpty,
           !(entry.originalLanguage.map { cinemaLanguages.contains($0) } ?? false) { return false }
        if !cinemaRuntimeFilters.isEmpty,
           !cinemaRuntimeFilters.contains(where: { $0.matches(entry.runtime) }) { return false }
        if !cinemaRatingFilters.isEmpty,
           !cinemaRatingFilters.contains(where: { $0.matches(entry.rating) }) { return false }
        if !cinemaResolutions.isEmpty,
           !cinemaResolutions.contains(where: { $0.matches(entry.file) }) { return false }
        if !cinemaSpecFilters.isEmpty,
           !cinemaSpecFilters.contains(where: { $0.matches(entry.file) }) { return false }
        if !cinemaWatchFilters.isEmpty,
           !cinemaWatchFilters.contains(cinemaWatchState(for: entry)) { return false }
        if cinemaSmartHighRated, (entry.rating ?? 0) < 8 { return false }
        if cinemaSmartRecent, entry.file.capturedAt < Date().addingTimeInterval(-30 * 86400) {
            return false
        }
        if cinemaFavoritesOnly, !cinemaUserState(for: entry.id).favorite { return false }
        if let list = cinemaList(cinemaActiveListID), !list.itemIDs.contains(entry.id) {
            return false
        }
        return true
    }

    func cinemaPassesFilters(_ series: CinemaSeries) -> Bool {
        if !series.episodes.contains(where: { !cinemaIsRestricted($0) }) { return false }
        if !cinemaYears.isEmpty,
           !series.episodes.contains(where: { $0.year.map { cinemaYears.contains($0) } ?? false }) {
            return false
        }
        if !cinemaGenres.isEmpty,
           !series.episodes.contains(where: { !Set($0.genres ?? []).isDisjoint(with: cinemaGenres) }) {
            return false
        }
        if let typeID = cinemaTypeFilterID,
           !CinemaContentType.descriptor(id: typeID).matches(series.genres) { return false }
        if !cinemaKindFilters.isEmpty, !cinemaKindFilters.contains(.tv) { return false }
        if !cinemaCountries.isEmpty,
           !series.episodes.contains(where: { !Set($0.countries ?? []).isDisjoint(with: cinemaCountries) }) {
            return false
        }
        if !cinemaLanguages.isEmpty,
           !series.episodes.contains(where: { $0.originalLanguage.map { cinemaLanguages.contains($0) } ?? false }) {
            return false
        }
        if !cinemaRuntimeFilters.isEmpty,
           !series.episodes.contains(where: { episode in
               cinemaRuntimeFilters.contains { $0.matches(episode.runtime) }
           }) {
            return false
        }
        if !cinemaRatingFilters.isEmpty,
           !cinemaRatingFilters.contains(where: { $0.matches(series.rating) }) { return false }
        if !cinemaResolutions.isEmpty,
           !series.episodes.contains(where: { episode in
               cinemaResolutions.contains { $0.matches(episode.file) }
           }) {
            return false
        }
        if !cinemaSpecFilters.isEmpty,
           !series.episodes.contains(where: { episode in
               cinemaSpecFilters.contains { $0.matches(episode.file) }
           }) {
            return false
        }
        if !cinemaWatchFilters.isEmpty,
           !cinemaWatchFilters.contains(cinemaWatchState(for: series)) { return false }
        if cinemaSmartHighRated, (series.rating ?? 0) < 8 { return false }
        if cinemaSmartRecent {
            let latest = series.episodes.map(\.file.capturedAt).max() ?? .distantPast
            if latest < Date().addingTimeInterval(-30 * 86400) { return false }
        }
        if cinemaFavoritesOnly,
           !series.episodes.contains(where: { cinemaUserState(for: $0.id).favorite }) {
            return false
        }
        if let list = cinemaList(cinemaActiveListID),
           !series.episodes.contains(where: { list.itemIDs.contains($0.id) }) {
            return false
        }
        return true
    }

    var cinemaScrapeProgress: Double {
        guard cinemaScrapeTotal > 0 else { return 0 }
        return min(1, Double(cinemaScrapeDone) / Double(cinemaScrapeTotal))
    }

    /// 网格里的视频优先显示刮削背景图：按视频所属网盘取对应作用域的条目。
    func cinemaGridArtwork(for photo: PhotoItem) -> String? {
        guard photo.isVideo else { return nil }
        if let mountID = photo.cloudMountID {
            return cinemaIndexes[.mount(mountID)]?[photo.id]?.gridArtworkURL
        }
        return cinemaIndexes[.local]?[photo.id]?.gridArtworkURL
    }

    // MARK: 聚合

    /// 跨所有影院的收藏 / 想看条目：网络资源页与影院共用同一份用户状态。
    /// 同一部剧只留一条（按版本键去重），按最近刮削排序。
    func cinemaUserStateEntries(favorite: Bool, limit: Int = 12) -> [CinemaEntry] {
        var seen = Set<String>()
        var result: [CinemaEntry] = []
        for (_, entries) in cinemaIndexes {
            for (id, entry) in entries where entry.matched {
                let state = cinemaUserStates[id]
                guard (favorite ? state?.favorite == true : state?.watchlist == true) else { continue }
                guard !cinemaIsRestricted(entry) else { continue }
                guard seen.insert(cinemaVersionKey(for: entry)).inserted else { continue }
                result.append(entry)
            }
        }
        return Array(result.sorted {
            ($0.scrapedAt) > ($1.scrapedAt)
        }.prefix(limit))
    }

    var cinemaMatchedEntries: [CinemaEntry] {
        cinemaEntries.values
            .filter { $0.matched }
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
    }

    var cinemaMovies: [CinemaEntry] {
        cinemaMatchedEntries.filter { $0.kind == .movie }
    }

    var cinemaTVEpisodes: [CinemaEntry] {
        cinemaMatchedEntries.filter { $0.kind == .tv }
    }

    /// 当前作用域的剧集聚合：同一部剧的多集合成一张卡片。
    var cinemaSeries: [CinemaSeries] {
        cinemaSeries(for: cinemaActiveScope)
    }

    func cinemaSeries(for scope: CinemaScope, matched: Bool = true) -> [CinemaSeries] {
        if let cached = cinemaSeriesCache[scope], cached.revision == cinemaDataRevision {
            return matched ? cached.matched : cached.unmatched
        }
        // 一次算两套（已识别 / 未识别）：搜索与统计会交替取，不做两次全量分组。
        let matchList = buildCinemaSeries(for: scope, matched: true)
        let unmatchedList = buildCinemaSeries(for: scope, matched: false)
        cinemaSeriesCache[scope] = CinemaSeriesCacheEntry(revision: cinemaDataRevision,
                                                          matched: matchList,
                                                          unmatched: unmatchedList)
        return matched ? matchList : unmatchedList
    }

    func buildCinemaSeries(for scope: CinemaScope, matched: Bool) -> [CinemaSeries] {
        let episodes = (cinemaIndexes[scope] ?? [:]).values
            .filter { $0.kind == .tv && $0.matched == matched }
        var groups: [String: [CinemaEntry]] = [:]
        for entry in episodes {
            groups[seriesKey(entry), default: []].append(entry)
        }
        return groups.compactMap { key, items in
            // 同一集的多版本只留画质最好的一条；版本选择在详情页完成。
            var bestByEpisode: [String: CinemaEntry] = [:]
            for entry in items {
                let episodeKey = "\(entry.season ?? 0)-\(entry.episode ?? 0)"
                if let existing = bestByEpisode[episodeKey] {
                    let versionKey = cinemaVersionKey(for: entry)
                    if let preferredID = cinemaDefaultVersions[versionKey] {
                        if entry.id == preferredID { bestByEpisode[episodeKey] = entry }
                        continue
                    }
                    if !cinemaIsBetterVersion(entry, existing) { continue }
                }
                bestByEpisode[episodeKey] = entry
            }
            let sorted = bestByEpisode.values.sorted { lhs, rhs in
                if lhs.season != rhs.season { return (lhs.season ?? 0) < (rhs.season ?? 0) }
                if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
                return lhs.file.capturedAt < rhs.file.capturedAt
            }
            guard !sorted.isEmpty else { return nil }
            // 海报 / 简介取信息最全的一集。
            let sample = sorted.first(where: { $0.backdropURL != nil })
                ?? sorted.first(where: { $0.posterURL != nil })
                ?? sorted[0]
            return CinemaSeries(id: key,
                                title: sample.title,
                                year: sample.year,
                                overview: sample.overview,
                                rating: sample.rating,
                                posterURL: sample.posterURL,
                                backdropURL: sample.backdropURL,
                                episodes: sorted)
        }
        .sorted { lhs, rhs in
            (lhs.latestEpisode?.file.capturedAt ?? .distantPast)
                > (rhs.latestEpisode?.file.capturedAt ?? .distantPast)
        }
    }

    // MARK: 聚合缓存

    /// 页面用的一次性聚合结果：签名不变时直接复用上次结果。
    /// 参考图库 `cachedSystemQuery`：数据版本 + 筛选 + 排序拼成签名，变化才重算。
    func cinemaAggregate(for scope: CinemaScope) -> CinemaAggregate {
        let signature = cinemaAggregateSignature(for: scope)
        if signature == cinemaAggregateCacheKey, let cached = cinemaAggregateCacheValue {
            return cached
        }
        let value = buildCinemaAggregate(for: scope)
        cinemaAggregateCacheKey = signature
        cinemaAggregateCacheValue = value
        return value
    }

    func cinemaAggregateSignature(for scope: CinemaScope) -> String {
        // 数据版本 + 筛选项版本 + 跨天标记：三个整数就能判断缓存是否失效。
        // 筛选条件本身不再每次 join 成字符串，body 重算的开销降到常量级。
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        return "\(Self.cinemaScopeKey(scope))|\(cinemaDataRevision)|\(cinemaFilterRevision)|\(day)"
            + "|\(cinemaParentalLocked)|\(AppSettings.shared.cinemaParentalLevel.rawValue)"
            + "|\(cinemaShuffleSeed)"
    }

    func buildCinemaAggregate(for scope: CinemaScope) -> CinemaAggregate {
        var result = CinemaAggregate()
        result.allEntries = cinemaEntries(for: scope).values
            .sorted { $0.file.capturedAt > $1.file.capturedAt }
        result.entries = result.allEntries.filter { cinemaPassesFilters($0) }
        result.unmatched = result.allEntries.filter { !$0.matched }

        // 电影按版本去重：同一部片只留一条；用户设过默认版本就优先用它。
        var bestMovies: [String: CinemaEntry] = [:]
        for entry in result.entries where entry.kind == .movie {
            let key = cinemaVersionKey(for: entry)
            if let existing = bestMovies[key] {
                if let preferredID = cinemaDefaultVersions[key] {
                    if entry.id == preferredID { bestMovies[key] = entry }
                    continue
                }
                if !cinemaIsBetterVersion(entry, existing) { continue }
            }
            bestMovies[key] = entry
        }
        result.movies = sortedCinemaEntries(Array(bestMovies.values))
        result.series = sortedCinemaSeries(cinemaSeries(for: scope).filter { cinemaPassesFilters($0) })
        result.unmatchedSeries = cinemaSeries(for: scope, matched: false)
        result.unmatchedMovies = result.unmatched.filter { $0.kind == .movie }
        result.collections = cinemaCollections(from: result.entries)
        result.letters = cinemaLetters(movies: result.movies, series: result.series)
        result.wallItemCount = result.movies.count + result.series.count
        result.stats = cinemaStats(entries: result.entries)
        result.types = cinemaTypeBuckets(for: scope)

        // 版本数一次算完：卡片渲染时直接查表。
        var versionCounts: [String: Int] = [:]
        for entry in (cinemaIndexes[scope] ?? [:]).values {
            versionCounts[cinemaVersionKey(for: entry), default: 0] += 1
        }
        result.versionCounts = versionCounts

        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for entry in result.allEntries {
            if cinemaUserState(for: entry.id).favorite { result.favoriteCount += 1 }
            if entry.file.capturedAt >= cutoff { result.recentCount += 1 }
            if (entry.rating ?? 0) >= 8 { result.highRatedCount += 1 }
        }
        return result
    }

    /// 类型分布：只统计已识别内容，电影按版本去重、剧集按整部计。
    /// 不受其它筛选影响，保证顶栏固定类型的数量不会随筛选跳动。
    func cinemaTypeBuckets(for scope: CinemaScope) -> [CinemaTypeBucket] {
        var counts: [String: Int] = [:]
        var seenMovies = Set<String>()
        for entry in cinemaEntries(for: scope).values where entry.matched && entry.kind == .movie {
            guard !cinemaIsRestricted(entry) else { continue }
            guard seenMovies.insert(cinemaVersionKey(for: entry)).inserted else { continue }
            for id in CinemaContentType.ids(matching: entry.genres ?? []) {
                counts[id, default: 0] += 1
            }
        }
        for series in cinemaSeries(for: scope) {
            guard series.episodes.contains(where: { !cinemaIsRestricted($0) }) else { continue }
            for id in CinemaContentType.ids(matching: series.genres) {
                counts[id, default: 0] += 1
            }
        }
        let builtInOrder = CinemaContentType.builtIns.map(\.id)
        return counts
            .map { CinemaTypeBucket(type: .descriptor(id: $0.key), count: $0.value) }
            .sorted { lhs, rhs in
                let lIndex = builtInOrder.firstIndex(of: lhs.id) ?? Int.max
                let rIndex = builtInOrder.firstIndex(of: rhs.id) ?? Int.max
                if lIndex != rIndex { return lIndex < rIndex }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.type.title.localizedStandardCompare(rhs.type.title) == .orderedAscending
            }
    }

    func cinemaStats(entries: [CinemaEntry]) -> CinemaAggregateStats {
        var stats = CinemaAggregateStats()
        for entry in entries {
            stats.matched += 1
            let width = entry.file.pixelWidth
            if width >= 3000 {
                stats.uhd += 1
            } else if width >= 1800 {
                stats.hd += 1
            } else if width > 0 {
                stats.sd += 1
            }
            if cinemaProgress[entry.id]?.isFinished == true { stats.watched += 1 }
        }
        return stats
    }

    func cinemaCollections(from entries: [CinemaEntry]) -> [CinemaCollectionGroup] {
        var groups: [Int: [CinemaEntry]] = [:]
        for entry in entries where entry.kind == .movie {
            guard let id = entry.collectionID else { continue }
            groups[id, default: []].append(entry)
        }
        return groups.compactMap { id, list in
            var best: [String: CinemaEntry] = [:]
            for entry in list {
                let key = cinemaVersionKey(for: entry)
                if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
                best[key] = entry
            }
            let unique = Array(best.values)
            guard unique.count >= 2 else { return nil }
            return CinemaCollectionGroup(
                id: id,
                name: list.first?.collectionName ?? "合集",
                entries: unique.sorted {
                    if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func cinemaLetters(movies: [CinemaEntry], series: [CinemaSeries]) -> [CinemaLetterEntry] {
        var seen = Set<String>()
        var list: [CinemaLetterEntry] = []
        for entry in movies {
            let letter = cinemaLetter(entry.title)
            guard seen.insert(letter).inserted else { continue }
            list.append(CinemaLetterEntry(letter: letter, target: entry.id.uuidString))
        }
        for item in series {
            let letter = cinemaLetter(item.title)
            guard seen.insert(letter).inserted else { continue }
            list.append(CinemaLetterEntry(letter: letter, target: "series-\(item.id)"))
        }
        return list.sorted { $0.letter.localizedStandardCompare($1.letter) == .orderedAscending }
    }

    /// 每部作品取首字符作为索引字母；中文片名直接用首字。
    func cinemaLetter(_ title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let upper = String(first).uppercased()
        if upper.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil { return upper }
        if first.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) { return String(first) }
        return "#"
    }

    func sortedCinemaEntries(_ list: [CinemaEntry]) -> [CinemaEntry] {
        switch cinemaSort {
        case .recent:
            return list.sorted { $0.file.capturedAt > $1.file.capturedAt }
        case .rating:
            return list.sorted { lhs, rhs in
                let left = lhs.rating ?? 0
                let right = rhs.rating ?? 0
                if left == right {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .year:
            return list.sorted { lhs, rhs in
                let left = lhs.year ?? 0
                let right = rhs.year ?? 0
                if left == right {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .title:
            return list.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted {
                ($0.file.duration ?? 0) > ($1.file.duration ?? 0)
            }
        case .random:
            return list.sorted {
                cinemaShuffleRank($0.id.uuidString) < cinemaShuffleRank($1.id.uuidString)
            }
        }
    }

    /// 进入影院 / 切到随机排序时重新洗一次；同一次浏览内顺序稳定。
    func refreshCinemaShuffle() {
        guard cinemaSort == .random else { return }
        cinemaShuffleSeed = UInt64.random(in: 1...UInt64.max)
        bumpCinemaFilters()
    }

    func cinemaShuffleRank(_ key: String) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(cinemaShuffleSeed)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func sortedCinemaSeries(_ list: [CinemaSeries]) -> [CinemaSeries] {
        switch cinemaSort {
        case .recent:
            return list.sorted { latestDate($0) > latestDate($1) }
        case .rating:
            return list.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .year:
            return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .title:
            return list.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .duration:
            return list.sorted { totalDuration($0) > totalDuration($1) }
        case .random:
            return list.sorted {
                cinemaShuffleRank($0.id) < cinemaShuffleRank($1.id)
            }
        }
    }

    func latestDate(_ series: CinemaSeries) -> Date {
        series.episodes.map(\.file.capturedAt).max() ?? .distantPast
    }

    func totalDuration(_ series: CinemaSeries) -> Double {
        series.episodes.reduce(0) { $0 + ($1.file.duration ?? 0) }
    }

    func seriesKey(_ entry: CinemaEntry) -> String {
        if let providerID = entry.tmdbID {
            // TMDB 键保持原样，避免老库的片头设置与观看状态失效；
            // 其它源的数字 ID 可能和 TMDB 撞号，必须带上前缀分开。
            if entry.provider == .tmdb { return "tv-\(providerID)" }
            return "tv-\(entry.provider?.rawValue ?? "other")-\(providerID)"
        }
        let normalized = entry.title.lowercased().filter { $0.isLetter || $0.isNumber }
        // 未识别时年份只是从文件名猜的：同一部剧有的集能猜到、有的猜不到，
        // 一旦把年份放进 key 就会被拆成好几张卡，所以未识别只按剧名分桶。
        guard entry.matched, let year = entry.year else { return "tv-\(normalized)" }
        return "tv-\(normalized)-\(year)"
    }

    // MARK: 多版本

    /// 同 tmdbID + 剧集号的多个文件共用一个版本键；未识别条目按 photoID 各自独立。
    func cinemaVersionKey(for entry: CinemaEntry) -> String {
        guard let tmdbID = entry.tmdbID else { return entry.id.uuidString }
        return "\(tmdbID)|\(entry.kind.rawValue)|\(entry.season ?? 0)|\(entry.episode ?? 0)"
    }

    /// 画质优先：分辨率更高的版本排前面；同分辨率比文件大小。
    func cinemaIsBetterVersion(_ lhs: CinemaEntry, _ rhs: CinemaEntry) -> Bool {
        if lhs.file.pixelWidth != rhs.file.pixelWidth {
            return lhs.file.pixelWidth > rhs.file.pixelWidth
        }
        return lhs.file.fileSize > rhs.file.fileSize
    }

    func cinemaVersions(for entry: CinemaEntry) -> [CinemaEntry] {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let key = cinemaVersionKey(for: entry)
        return (cinemaIndexes[scope] ?? [:]).values
            .filter { cinemaVersionKey(for: $0) == key }
            .sorted { cinemaIsBetterVersion($0, $1) }
    }

    func cinemaVersionCount(for entry: CinemaEntry) -> Int {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let key = cinemaVersionKey(for: entry)
        return (cinemaIndexes[scope] ?? [:]).values.reduce(0) {
            $0 + (cinemaVersionKey(for: $1) == key ? 1 : 0)
        }
    }

    /// 可刮削的视频：本地图库只取本地；网盘取这个链接的扫描清单，并带上所在目录链。
    func cinemaCandidates(for scope: CinemaScope) -> [CinemaCandidate] {
        var skipped = 0
        return cinemaCandidates(for: scope, skipped: &skipped)
    }

    /// 同上，并统计被跳过的视频数（录屏 / 极短片段 / 手动忽略），任务中心单独标「跳过」。
    func cinemaCandidates(for scope: CinemaScope, skipped: inout Int) -> [CinemaCandidate] {
        var byID: [UUID: CinemaCandidate] = [:]

        func merge(_ photo: PhotoItem, hint: String?, folderPath: String?) {
            guard CinemaScraper.isCandidate(photo) else {
                skipped += 1
                return
            }
            // 手动忽略的视频以后都不再刮削。
            if cinemaIgnoredIDs[scope]?.contains(photo.id) == true {
                skipped += 1
                return
            }
            if let existing = byID[photo.id] {
                // 已经有目录线索的不要被后来的「无线索」覆盖。
                let resolvedHint = existing.folderHint ?? hint
                let resolvedPath = existing.folderPath ?? folderPath
                if resolvedHint != existing.folderHint || resolvedPath != existing.folderPath {
                    byID[photo.id] = CinemaCandidate(photo: photo,
                                                     folderHint: resolvedHint,
                                                     folderPath: resolvedPath)
                }
            } else {
                byID[photo.id] = CinemaCandidate(photo: photo,
                                                 folderHint: hint,
                                                 folderPath: folderPath)
            }
        }

        switch scope {
        case .local:
            for photo in photos { merge(photo, hint: nil, folderPath: nil) }
        case .mount(let mountID):
            guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { break }
            let rootPath = cloudRootPath(for: mount)

            /// 根目录本身不当作文件夹，它的直属视频统一落在「根目录」节点里。
            func directory(_ path: String?) -> String? {
                guard let path, !path.isEmpty, path != rootPath else { return nil }
                return path
            }

            // 目录名 → 父目录，用来还原「剧名 / 季」链条。
            var names: [String: String] = [:]
            var parents: [String: String] = [:]
            let snapshot = cloudAlbumSnapshot(mountID: mountID)
            if let folders = snapshot?.folders {
                for folder in folders {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
            if cloudModel.scanMountID == mountID {
                for folder in cloudModel.scanFolders {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }

            if cloudModel.scanMountID == mountID {
                for photo in cloudModel.scanPhotos {
                    let folder = directory(photo.cloudPath.flatMap { cloudModel.scanMediaFolder[$0] })
                    merge(photo,
                          hint: folderChain(folder, names: names, parents: parents),
                          folderPath: folder)
                }
            }

            // 上次扫描的快照：即使当前没有打开这个网盘，也能拿到完整清单与目录名。
            if let snapshot {
                for record in snapshot.records where record.isVideo {
                    let photo = cloudAlbumPhoto(record: record, mount: mount)
                    let folder = directory(record.folderPath)
                    merge(photo,
                          hint: folderChain(folder, names: names, parents: parents),
                          folderPath: folder)
                }
            }

            for photo in cloudPhotos where photo.cloudMountID == mountID {
                let folder = directory(photo.cloudPath.flatMap { cloudModel.scanMediaFolder[$0] })
                merge(photo,
                      hint: folderChain(folder, names: names, parents: parents),
                      folderPath: folder)
            }
        }
        return Array(byID.values)
    }

    // MARK: 目录 NFO

    // MARK: 本地目录监听 / 片头尾自动识别

    /// 只监听本机真实目录：云盘没有文件系统事件，仍由扫描 / 刷新目录触发。
    func startLocalCinemaWatcher() {
        guard localCinemaWatcher == nil else { return }
        let paths = [LibraryPaths.originals.path]
        localCinemaWatcher = LocalCinemaWatcher(paths: paths) { [weak self] in
            Task { @MainActor in
                await self?.handleLocalCinemaDirectoryChange()
            }
        }
    }

    /// 目录有变化：重新读一次图库清单，必要时自动刮削本地影院的新视频。
    func handleLocalCinemaDirectoryChange() async {
        // 这是一次完整重载：先停掉启动分片，避免它把旧分片追加到新结果后面。
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexComplete = true
        if let data = metadataStore?.loadLibrary() {
            photos = data.photos
        }
        contentRevision &+= 1
        guard AppSettings.shared.cinemaAutoScrape else { return }
        startCinemaScrape(for: .local)
    }

    /// 片头尾识别结果：`online` 为 true 表示来自 TheIntroDB 社区库。
    struct CinemaIntroDetection {
        var mark: CinemaIntroMark
        var online: Bool
    }

    /// 片头尾识别：先查在线库（网盘片源也能识别），没有再退回本地静音检测。
    func detectCinemaIntro(for series: CinemaSeries) async -> CinemaIntroDetection? {
        if let mark = await onlineCinemaIntroMark(for: series) {
            return CinemaIntroDetection(mark: mark, online: true)
        }
        guard let episode = series.episodes.first(where: { $0.file.cloudMountID == nil }),
              let photo = anyPhoto(id: episode.file.photoID) else { return nil }
        let url = LibraryPaths.originalURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let mark = await CinemaIntroDetector.detect(url: url,
                                                          duration: episode.file.duration ?? 0) else {
            return nil
        }
        return CinemaIntroDetection(mark: mark, online: false)
    }

    /// 单集识别：用于详情页「本集」范围；在线优先，本地静音检测兜底。
    func detectCinemaIntro(for entry: CinemaEntry) async -> CinemaIntroDetection? {
        if let mark = await onlineCinemaIntroMark(for: entry) {
            return CinemaIntroDetection(mark: mark, online: true)
        }
        guard entry.file.cloudMountID == nil,
              let photo = anyPhoto(id: entry.file.photoID) else { return nil }
        let url = LibraryPaths.originalURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let mark = await CinemaIntroDetector.detect(url: url,
                                                          duration: entry.file.duration ?? 0) else {
            return nil
        }
        return CinemaIntroDetection(mark: mark, online: false)
    }

    /// 起播后补一次「本集」在线片头：如果这一集和整部剧的默认值不同，
    /// 拿到结果时还没过片头就直接跳到正确位置，并写成单集覆盖。
    func refineCinemaIntroOnPlayback(for entry: CinemaEntry) async {
        guard entry.kind == .tv,
              entry.provider == .tmdb,
              !hasCinemaEpisodeIntroMark(for: entry),
              !cinemaEpisodeIntroTried.contains(entry.id.uuidString) else { return }
        cinemaEpisodeIntroTried.insert(entry.id.uuidString)
        guard let mark = await onlineCinemaIntroMark(for: entry), mark.isEnabled else { return }
        // 期间可能已经翻到别的视频：结果仍然缓存下来，但不要动当前播放位置。
        setCinemaIntroMark(mark, for: entry)
        guard cinemaPlaybackEntry?.id == entry.id,
              !viewerModel.playbackSession.resumeApplied,
              mark.introSeconds > 0 else { return }
        let current = viewerModel.videoPlayer.currentTime
        guard current > 1,
              current < 60,
              current < Double(mark.introSeconds) - 2 else { return }
        viewerModel.playbackSession.requestIntroSkip(seconds: Double(mark.introSeconds))
    }

    func onlineCinemaIntroMark(for entry: CinemaEntry) async -> CinemaIntroMark? {
        guard entry.kind == .tv,
              entry.provider == .tmdb,
              let tmdbID = entry.tmdbID,
              let season = entry.season,
              let episode = entry.episode else { return nil }
        return await onlineCinemaIntroMark(tmdbID: tmdbID,
                                           season: season,
                                           episode: episode,
                                           duration: entry.file.duration ?? 0)
    }

    /// 详情页打开时补一次在线片头：已有设置或已经查过的不再请求。
    func ensureCinemaIntroMark(for series: CinemaSeries) async {
        guard !cinemaIntroMark(forSeriesKey: series.id).isEnabled,
              !cinemaIntroAutoTried.contains(series.id) else { return }
        cinemaIntroAutoTried.insert(series.id)
        guard let mark = await onlineCinemaIntroMark(for: series),
              !cinemaIntroMark(forSeriesKey: series.id).isEnabled else { return }
        setCinemaIntroMark(mark, forSeriesKey: series.id)
    }

    /// 刮削完成后兜底：给这个影院里所有还没设置的剧集补在线片头片尾。
    func autoFillCinemaIntros(for scope: CinemaScope) async {
        let entries = (cinemaIndexes[scope] ?? [:]).values.filter {
            $0.kind == .tv && $0.tmdbID != nil && $0.provider == .tmdb
        }
        guard !entries.isEmpty else { return }
        var groups: [String: [CinemaEntry]] = [:]
        for entry in entries {
            groups[cinemaSeriesKey(for: entry), default: []].append(entry)
        }
        for (key, list) in groups {
            if Task.isCancelled { return }
            guard !cinemaIntroMark(forSeriesKey: key).isEnabled,
                  !cinemaIntroAutoTried.contains(key) else { continue }
            cinemaIntroAutoTried.insert(key)
            let first = list.min {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
            guard let first, let tmdbID = first.tmdbID else { continue }
            guard let mark = await onlineCinemaIntroMark(tmdbID: tmdbID,
                                                         season: first.season ?? 1,
                                                         episode: first.episode ?? 1,
                                                         duration: first.file.duration ?? 0),
                  !cinemaIntroMark(forSeriesKey: key).isEnabled else { continue }
            setCinemaIntroMark(mark, forSeriesKey: key)
            await Task.yield()
        }
    }

    func onlineCinemaIntroMark(for series: CinemaSeries) async -> CinemaIntroMark? {
        let first = series.episodes
            .filter { $0.kind == .tv && $0.provider == .tmdb }
            .min { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard let first, let tmdbID = first.tmdbID else { return nil }
        return await onlineCinemaIntroMark(tmdbID: tmdbID,
                                           season: first.season ?? 1,
                                           episode: first.episode ?? 1,
                                           duration: first.file.duration ?? 0)
    }

    func onlineCinemaIntroMark(tmdbID: Int,
                                       season: Int,
                                       episode: Int,
                                       duration: Double) async -> CinemaIntroMark? {
        guard let tmdb = tmdbClient() else { return nil }
        return await CinemaIntroOnline.mark(tmdb: tmdb,
                                            tmdbID: tmdbID,
                                            season: season,
                                            episode: episode,
                                            duration: duration)
    }

    /// 从当前刮削源里挑出配置了 Key 的 TMDB 客户端（在线片头库需要它换 IMDb ID）。
    func tmdbClient() -> TMDBClient? {
        for source in metadataSources() {
            if let client = source as? TMDBClient { return client }
        }
        return nil
    }

    /// 刮削前先看目录里的 .nfo：命中就直接用 NFO 的标题 / 年份 / 季集，不再请求网络。
    /// 本地目录读文件；网盘先列一次目录（按文件缓存），再用统一下载链路读小文件。
    func cinemaNFOEntry(for candidate: CinemaCandidate,
                                scope: CinemaScope) async -> CinemaEntry? {
        guard let nfo = await cinemaNFO(for: candidate, scope: scope) else { return nil }
        guard let title = nfo.title, !title.isEmpty else { return nil }

        let match = CinemaMatch(
            id: nfo.tmdbID.map(String.init) ?? "nfo-\(candidate.photo.id.uuidString)",
            isTV: nfo.isTV,
            title: title,
            originalTitle: nfo.originalTitle,
            year: nfo.year,
            posterURL: nfo.posterURL?.hasPrefix("http") == true ? nfo.posterURL : nil,
            backdropURL: nfo.backdropURL?.hasPrefix("http") == true ? nfo.backdropURL : nil,
            overview: nfo.overview,
            rating: nfo.rating,
            genres: nfo.genres,
            provider: .tmdb)

        var parsed = CinemaScraper.parse(filename: candidate.photo.displayFilename,
                                         folderHint: candidate.folderHint)
        if nfo.isTV { parsed.isTV = true }
        if let season = nfo.season { parsed.season = season }
        if let episode = nfo.episode { parsed.episode = episode }
        var entry = CinemaScraper.manualEntry(photo: candidate.photo,
                                              parsed: parsed,
                                              folderHint: candidate.folderHint,
                                              match: match)
        entry.runtime = nfo.runtime
        return entry
    }

    func cinemaNFO(for candidate: CinemaCandidate,
                           scope: CinemaScope) async -> CinemaNFO? {
        let base = (candidate.photo.originalName as NSString).deletingPathExtension.lowercased()
        let folderKey = (candidate.folderPath ?? "local") + "|" + base
        if let cached = cinemaNFOByFolder[folderKey] { return cached }
        if cinemaNFOEmptyFolders.contains(folderKey) { return nil }

        let data: Data?
        switch scope {
        case .local:
            data = localNFOData(for: candidate.photo)
        case .mount(let id):
            data = await cloudNFOData(for: candidate, mountID: id)
        }
        guard let data, let parsed = CinemaNFO.parse(data: data) else {
            cinemaNFOEmptyFolders.insert(folderKey)
            return nil
        }
        cinemaNFOByFolder[folderKey] = parsed
        return parsed
    }

    func localNFOData(for photo: PhotoItem) -> Data? {
        let file = LibraryPaths.originalURL(for: photo)
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent.lowercased()
        let names = [base + ".nfo", "movie.nfo", "tvshow.nfo", "season.nfo"]
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), data.count < 512_000 { return data }
        }
        return nil
    }

    func cloudNFOData(for candidate: CinemaCandidate, mountID: UUID) async -> Data? {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }),
              let folder = candidate.folderPath,
              let entries = try? await CloudService.list(mount: mount, containerID: folder) else {
            return nil
        }
        let base = (candidate.photo.originalName as NSString).deletingPathExtension.lowercased()
        let preferred = [base + ".nfo", "movie.nfo", "tvshow.nfo", "season.nfo"]
        let nfo = entries.first { !$0.isDirectory && preferred.contains($0.name.lowercased()) }
            ?? entries.first { !$0.isDirectory && $0.name.lowercased().hasSuffix(".nfo") }
        guard let nfo else { return nil }

        var photo = PhotoItem(id: UUID(),
                              filename: nfo.name,
                              editedFilename: nil,
                              originalName: nfo.name,
                              capturedAt: Date(),
                              pixelWidth: 0,
                              pixelHeight: 0,
                              fileSize: nfo.size,
                              kind: .photo)
        photo.source = .cloud
        photo.cloudMountID = mount.id
        photo.cloudPath = nfo.path
        photo.cloudRemoteID = nfo.remoteID
        photo.cloudRestricted = nfo.isRestricted
        guard let resource = try? await CloudService.stream(mount: mount, photo: photo) else { return nil }
        // 网盘直链也要带源要求的 Cookie / Referer 与自签证书策略：
        // 和其它源一样走统一传输，超时 / 重试只在一处维护。
        guard let response = try? await HTTPSourceTransport.shared.send(
            HTTPTransportRequest(url: resource.url, timeout: 20),
            profile: RequestProfile(headers: resource.headers,
                                    trustSelfSigned: mount.trustSelfSigned)
        ), response.data.count < 512_000 else { return nil }
        return response.data
    }

    /// 拼出「剧名 / Season 01」这类目录链，最多向上三级；未知目录返回 nil。
    func folderChain(_ path: String?,
                             names: [String: String],
                             parents: [String: String],
                             limit: Int = 3) -> String? {
        guard var cursor = path, !cursor.isEmpty else { return nil }
        var parts: [String] = []
        var hops = 0
        while hops < limit {
            guard let name = names[cursor], !name.isEmpty else { break }
            parts.append(name)
            guard let parent = parents[cursor], !parent.isEmpty else { break }
            cursor = parent
            hops += 1
        }
        return parts.isEmpty ? nil : parts.reversed().joined(separator: "/")
    }
}
