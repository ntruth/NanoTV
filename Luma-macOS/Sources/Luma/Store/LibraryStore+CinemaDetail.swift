import Foundation
import AppKit
import Combine
import LumaContentCore

/// 影院的详情与辅助面板：详情补全、推荐、通知、搜索、任务与家长控制。

extension LibraryStore {
    // MARK: 详情补全（合集 / 演职员 / 预告 / 分级）

    /// 从 TMDB 拉一次详情并写回索引；豆瓣条目没有详情接口，直接跳过。
    /// 已有详情时默认不重复请求，`force` 用于详情页的「刷新」。
    @discardableResult
    func enrichCinemaEntry(_ entry: CinemaEntry, force: Bool = false) async -> CinemaEntry? {
        guard entry.matched, let tmdbID = entry.tmdbID else { return nil }
        // 只有 TMDB 条目能按这个 ID 补详情；TVDB / 豆瓣的 ID 不是 TMDB 的。
        guard entry.provider == .tmdb else { return nil }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        guard var current = cinemaIndexes[scope]?[entry.id] else { return nil }
        let hasOverviewFacts = current.runtime != nil || current.status != nil || current.releaseDate != nil
        if !force,
           hasOverviewFacts,
           current.cast != nil,
           current.recommendations != nil {
            return current
        }
        for source in metadataSources() where source.provider == .tmdb {
            guard let details = try? await source.details(id: tmdbID, isTV: entry.kind == .tv) else {
                continue
            }
            current.collectionID = details.collectionID
            current.collectionName = details.collectionName
            if !details.cast.isEmpty { current.cast = details.cast }
            if !details.directors.isEmpty { current.directors = details.directors }
            if let value = details.certification { current.certification = value }
            if let key = details.trailerKey { current.trailerKey = key }
            if let value = details.tagline { current.tagline = value }
            if let value = details.runtime, value > 0 { current.runtime = value }
            if let value = details.status, !value.isEmpty { current.status = value }
            if let value = details.releaseDate, !value.isEmpty { current.releaseDate = value }
            if let value = details.originalLanguage, !value.isEmpty { current.originalLanguage = value }
            if !details.countries.isEmpty { current.countries = details.countries }
            if !details.companies.isEmpty { current.companies = details.companies }
            if !details.networks.isEmpty { current.networks = details.networks }
            if let value = details.seasonCount, value > 0 { current.seasonCount = value }
            if let value = details.episodeCount, value > 0 { current.episodeTotal = value }
            if let value = details.voteCount, value > 0 { current.voteCount = value }
            if let value = details.budget, value > 0 { current.budget = value }
            if let value = details.revenue, value > 0 { current.revenue = value }
            if current.recommendations == nil,
               let tmdb = source as? TMDBClient,
               let recs = try? await tmdb.recommendations(id: tmdbID, isTV: entry.kind == .tv) {
                current.recommendations = recs
            }
            cinemaIndexes[scope, default: [:]][current.id] = current
            persistCinemaIndex(for: scope)
            return current
        }
        return nil
    }

    /// 智能助手用：按 tmdbID 取详情（季数 / 集数 / 分级等），用于挑选候选。
    func cinemaDetails(id: Int, isTV: Bool) async -> CinemaDetails? {
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let details = try? await tmdb.details(id: id, isTV: isTV) {
                return details
            }
        }
        return nil
    }

    /// 单集标题 / 简介 / 剧照的本地缓存：按 tmdbID + 季存进图库设置库。
    /// 打开详情先读它，12 小时内不再请求网络。
    struct CinemaEpisodeInfoCache: Codable {
        var fetchedAt: Date
        var episodes: [Int: CinemaEpisodeInfo]
    }

    static func cinemaEpisodeInfoKey(tvID: Int, season: Int) -> String {
        "cinema_episode_infos_\(tvID)_\(season)"
    }

    /// 读缓存：返回单集信息与是否足够新。没有缓存时返回 nil。
    func cachedCinemaEpisodeInfos(tvID: Int,
                                  season: Int) -> (infos: [Int: CinemaEpisodeInfo], fresh: Bool)? {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaEpisodeInfoKey(tvID: tvID, season: season)),
              let data = json.data(using: .utf8),
              let cache = try? JSONDecoder().decode(CinemaEpisodeInfoCache.self, from: data),
              !cache.episodes.isEmpty else { return nil }
        let fresh = Date().timeIntervalSince(cache.fetchedAt) < 12 * 3600
        return (cache.episodes, fresh)
    }

    /// 剧集详情按季拉取单集标题 / 简介 / 剧照；成功后写回本地缓存。
    /// 没有 TMDB 源或请求失败返回 nil，调用方继续用缓存。
    func refreshCinemaEpisodeInfos(tvID: Int, season: Int) async -> [Int: CinemaEpisodeInfo]? {
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            guard let map = try? await tmdb.seasonDetails(tvID: tvID, season: season),
                  !map.isEmpty else { continue }
            if let metadataStore,
               let data = try? JSONEncoder().encode(CinemaEpisodeInfoCache(fetchedAt: Date(), episodes: map)),
               let json = String(data: data, encoding: .utf8) {
                metadataStore.setSetting(Self.cinemaEpisodeInfoKey(tvID: tvID, season: season), json)
            }
            return map
        }
        return nil
    }

    /// 同一合集里的其他影片：按版本键去重、按年份排序。
    func cinemaCollection(collectionID: Int) -> [CinemaEntry] {
        var best: [String: CinemaEntry] = [:]
        for entry in cinemaEntries.values where entry.matched && entry.collectionID == collectionID {
            guard !cinemaIsRestricted(entry) else { continue }
            let key = cinemaVersionKey(for: entry)
            if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
            best[key] = entry
        }
        return best.values.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    // MARK: 人物页 / 合集页

    /// 人物页「本库已有」：按演员 / 导演命中，电影去多版本、剧集按剧聚合。
    func cinemaPersonWorks(named name: String) -> [CinemaEntry] {
        let scope = cinemaActiveScope
        var best: [String: CinemaEntry] = [:]
        for entry in (cinemaIndexes[scope] ?? [:]).values where entry.matched {
            guard !cinemaIsRestricted(entry) else { continue }
            let hit = (entry.cast ?? []).contains { $0.name == name }
                || (entry.directors ?? []).contains(name)
            guard hit else { continue }
            let key = entry.kind == .tv ? seriesKey(entry) : cinemaVersionKey(for: entry)
            if let existing = best[key] {
                if entry.kind == .tv {
                    if (entry.episode ?? 0) < (existing.episode ?? 0) { best[key] = entry }
                } else if cinemaIsBetterVersion(entry, existing) {
                    best[key] = entry
                }
            } else {
                best[key] = entry
            }
        }
        return best.values.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) > ($1.year ?? 0) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 人物页「全部作品」里的一条如果本库有文件，直接对应到可播放条目。
    func cinemaEntry(forCredit credit: CinemaPersonCredit) -> CinemaEntry? {
        let scope = cinemaActiveScope
        let candidates = (cinemaIndexes[scope] ?? [:]).values.filter {
            $0.matched && $0.tmdbID == credit.tmdbID && $0.kind == (credit.isTV ? .tv : .movie)
        }
        guard var pick = candidates.first else { return nil }
        for entry in candidates where cinemaIsBetterVersion(entry, pick) { pick = entry }
        return pick
    }

    func cinemaPersonProfile(for member: CinemaCastMember) async -> CinemaPersonProfile? {
        guard let id = member.tmdbID else { return nil }
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let profile = try? await tmdb.person(id: id) { return profile }
        }
        return nil
    }

    func cinemaCollectionInfo(collectionID: Int) async -> CinemaCollectionInfo? {
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let info = try? await tmdb.collection(id: collectionID) { return info }
        }
        return nil
    }

    /// 外部打开豆瓣条目：豆瓣推荐没有 TMDB ID，只能跳网页。
    func openDoubanPage(doubanID: String) {
        guard let url = URL(string: "https://movie.douban.com/subject/\(doubanID)/") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 推荐分组（详情页 tab）

    /// 详情页推荐分组：TMDB（猜你喜欢）/ 豆瓣 / 同系列 / 同导演 / 同演员。
    /// 首次打开详情时并发补齐并写回条目缓存，之后直接读缓存；旧缓存按天刷新一次。
    func cinemaRecommendationGroups(for entry: CinemaEntry,
                                    force: Bool = false) async -> [CinemaRecommendationGroup] {
        if !force, let cached = entry.recommendationGroups, !cached.isEmpty,
           let fetchedAt = entry.recommendationGroupsAt,
           Date().timeIntervalSince(fetchedAt) < Self.cinemaRecommendationCacheLifetime {
            return cached
        }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let current = cinemaIndexes[scope]?[entry.id] ?? entry
        guard current.matched else { return [] }

        var tmdbClient: TMDBClient?
        var doubanClient: DoubanClient?
        for source in metadataSources() {
            if let tmdb = source as? TMDBClient { tmdbClient = tmdb }
            if let douban = source as? DoubanClient { doubanClient = douban }
        }

        let tmdbID = current.tmdbID
        let usableTMDB = tmdbClient != nil && tmdbID != nil
            && (current.provider == .tmdb || current.provider == nil)
        var collected: [CinemaRecommendationGroup] = []
        var jobs: [() async -> CinemaRecommendationGroup?] = []

        if usableTMDB, let tmdb = tmdbClient, let tmdbID {
            let isTV = current.kind == .tv
            jobs.append {
                guard let items = try? await tmdb.recommendations(id: tmdbID, isTV: isTV),
                      !items.isEmpty else { return nil }
                return CinemaRecommendationGroup(source: .tmdb,
                                                 title: "TMDB",
                                                 items: Array(items.prefix(12)))
            }
            if let collectionID = current.collectionID {
                jobs.append {
                    guard let items = try? await tmdb.collectionRecommendations(id: collectionID,
                                                                                excluding: tmdbID),
                          !items.isEmpty else { return nil }
                    return CinemaRecommendationGroup(source: .collection,
                                                     title: "同系列",
                                                     items: Array(items.prefix(12)))
                }
            }
            if let director = current.directors?.first(where: { !$0.isEmpty }) {
                jobs.append {
                    guard let personID = try? await tmdb.searchPersonID(name: director),
                          let profile = try? await tmdb.person(id: personID) else { return nil }
                    let items = profile.credits
                        .filter { $0.tmdbID != tmdbID }
                        .prefix(12)
                        .map { credit in
                            CinemaRecommendation(tmdbID: credit.tmdbID,
                                                 kind: credit.isTV ? .tv : .movie,
                                                 title: credit.title,
                                                 year: credit.year,
                                                 posterURL: credit.posterURL,
                                                 rating: nil)
                        }
                    guard !items.isEmpty else { return nil }
                    return CinemaRecommendationGroup(source: .director,
                                                     title: "同导演",
                                                     items: Array(items))
                }
            }
            for castID in (current.cast ?? []).compactMap(\.tmdbID).prefix(2) {
                jobs.append {
                    guard let profile = try? await tmdb.person(id: castID) else { return nil }
                    let items = profile.credits
                        .filter { $0.tmdbID != tmdbID }
                        .prefix(12)
                        .map { credit in
                            CinemaRecommendation(tmdbID: credit.tmdbID,
                                                 kind: credit.isTV ? .tv : .movie,
                                                 title: credit.title,
                                                 year: credit.year,
                                                 posterURL: credit.posterURL,
                                                 rating: nil)
                        }
                    guard !items.isEmpty else { return nil }
                    return CinemaRecommendationGroup(source: .cast,
                                                     title: "同演员",
                                                     items: Array(items))
                }
            }
        }
        if let douban = doubanClient {
            let title = current.title
            let originalTitle = current.originalTitle
            let year = current.year
            let isTV = current.kind == .tv
            jobs.append {
                // 豆瓣即使没结果也保留 tab：用户至少知道「豆瓣源在看，只是没命中」。
                guard let items = try? await douban.recommendations(title: title,
                                                                    originalTitle: originalTitle,
                                                                    year: year,
                                                                    isTV: isTV) else {
                    return CinemaRecommendationGroup(source: .douban, title: "豆瓣", items: [])
                }
                return CinemaRecommendationGroup(source: .douban,
                                                 title: "豆瓣",
                                                 items: Array(items.prefix(12)))
            }
        }
        // 弱网下 8 个请求会占满连接：最多 3 路并发，单路 12s 超时，其余排队。
        let maxConcurrent = 3
        var jobIndex = 0
        while jobIndex < jobs.count {
            let end = min(jobs.count, jobIndex + maxConcurrent)
            let slice = Array(jobs[jobIndex..<end])
            let results = await withTaskGroup(of: CinemaRecommendationGroup?.self) { group in
                for job in slice {
                    group.addTask {
                        await Self.cinemaRequestWithTimeout(12) { await job() }
                    }
                }
                var output: [CinemaRecommendationGroup] = []
                for await result in group {
                    if let result { output.append(result) }
                }
                return output
            }
            collected.append(contentsOf: results)
            jobIndex = end
        }

        // 同演员会并行拉两三个人：按来源合并去重，同一个 tab 只出现一次。
        var merged: [CinemaRecommendationGroup] = []
        for source in [CinemaRecommendationGroup.Source.tmdb,
                       .douban, .collection, .director, .cast] {
            let same = collected.filter { $0.source == source }
            guard !same.isEmpty else { continue }
            var seenTMDB = Set<Int>()
            var seenDouban = Set<String>()
            var items: [CinemaRecommendation] = []
            for item in same.flatMap(\.items) {
                if let doubanID = item.doubanID {
                    guard seenDouban.insert(doubanID).inserted else { continue }
                    items.append(item)
                } else {
                    guard item.tmdbID != tmdbID, seenTMDB.insert(item.tmdbID).inserted else { continue }
                    items.append(item)
                }
            }
            // 豆瓣即使 0 条也保留：tab 常驻，里面给「没找到」的说明。
            if items.isEmpty, source != .douban { continue }
            merged.append(CinemaRecommendationGroup(source: source,
                                                    title: same[0].title,
                                                    items: Array(items.prefix(12))))
        }

        if !merged.isEmpty, var stored = cinemaIndexes[scope]?[entry.id] {
            stored.recommendationGroups = merged
            stored.recommendationGroupsAt = Date()
            cinemaIndexes[scope]?[stored.id] = stored
            persistCinemaIndex(for: scope)
        }
        return merged
    }

    /// 推荐分组缓存有效期：一天。旧版本只存过 TMDB 列表，过期重拉才能补上豆瓣。
    static var cinemaRecommendationCacheLifetime: TimeInterval { 24 * 3600 }

    /// 单路请求超时：超时按「没有结果」处理，不拖住其它分组。
    nonisolated private static func cinemaRequestWithTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 三源评分牌：主源是 TMDB 时按需补一次豆瓣评分，写回条目后下次直接读缓存。
    func hydrateCinemaDoubanRating(for entry: CinemaEntry) async {
        guard entry.matched, entry.doubanRating == nil, entry.provider != .douban else { return }
        guard let douban = metadataSources().first(where: { $0.provider == .douban }) as? DoubanClient else { return }
        guard let matches = try? await douban.search(query: entry.title,
                                                     isTV: entry.kind == .tv,
                                                     year: entry.year) else { return }
        let rating = matches.first { $0.year == nil || entry.year == nil || $0.year == entry.year }?.rating
        guard let rating, rating > 0 else { return }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        guard var stored = cinemaIndexes[scope]?[entry.id] else { return }
        stored.doubanRating = rating
        cinemaIndexes[scope]?[stored.id] = stored
        persistCinemaIndex(for: scope)
    }

    /// 影院右键「在访达中显示」：本地直接用源文件；SMB 先确保挂载，其它网盘给出明确提示。
    func revealCinemaEntryInFinder(_ entry: CinemaEntry) {
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        if photo.isCloud {
            Task {
                guard let url = await cloudLocalFileURL(photo) else {
                    showToast("这个网盘暂不能直接在访达中显示，请用「导出」保存到本地")
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        let url = LibraryPaths.sourceURL(for: photo)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            showToast("源文件不在本地：\(photo.displayFilename)")
        }
    }

    // MARK: 通知中心 / Toast
    func loadCinemaNotifications() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaNotificationsSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaNotification].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let kept = list.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
        cinemaNotifications = kept
        if kept.count != list.count { persistCinemaNotifications() }
    }

    func persistCinemaNotifications() {
        guard let metadataStore else { return }
        if cinemaNotifications.count > 200 {
            cinemaNotifications = Array(cinemaNotifications.prefix(200))
        }
        guard let data = try? JSONEncoder().encode(cinemaNotifications),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaNotificationsSettingKey, json)
    }

    var cinemaUnreadNotificationCount: Int {
        cinemaNotifications.filter { !$0.read }.count
    }

    /// 任务结果归档：同一任务 60 秒内重复写入时合并，避免刷屏。
    func recordCinemaNotification(_ kind: CinemaNotificationKind,
                                  title: String,
                                  detail: String = "",
                                  action: String? = nil,
                                  scopeKey: String? = nil) {
        if let index = cinemaNotifications.firstIndex(where: {
            $0.title == title && $0.scopeKey == scopeKey && Date().timeIntervalSince($0.date) < 60
        }) {
            cinemaNotifications[index].date = Date()
            cinemaNotifications[index].detail = detail
            cinemaNotifications[index].kind = kind
            cinemaNotifications[index].action = action
            cinemaNotifications[index].read = false
        } else {
            cinemaNotifications.insert(CinemaNotification(kind: kind,
                                                          title: title,
                                                          detail: detail,
                                                          action: action,
                                                          scopeKey: scopeKey),
                                       at: 0)
        }
        persistCinemaNotifications()
    }

    func markAllCinemaNotificationsRead() {
        for index in cinemaNotifications.indices { cinemaNotifications[index].read = true }
        persistCinemaNotifications()
    }

    func clearCinemaNotifications() {
        cinemaNotifications = []
        persistCinemaNotifications()
    }

    /// 右上角 Toast：成功 4 秒自动消失；失败与进度常驻直到手动关闭。
    func postCinemaToast(_ kind: CinemaToastKind,
                         title: String,
                         detail: String? = nil,
                         actionTitle: String? = nil,
                         action: (() -> Void)? = nil) {
        if cinemaToasts.count >= 3 {
            let victim = cinemaToasts.first { $0.kind != .failure } ?? cinemaToasts[0]
            dismissCinemaToast(victim.id)
        }
        let toast = CinemaToast(kind: kind,
                                title: title,
                                detail: detail,
                                actionTitle: actionTitle,
                                action: action)
        cinemaToasts.append(toast)
        guard kind == .success || kind == .info else { return }
        let id = toast.id
        cinemaToastTasks[id]?.cancel()
        cinemaToastTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissCinemaToast(id)
        }
    }

    func dismissCinemaToast(_ id: UUID) {
        cinemaToastTasks[id]?.cancel()
        cinemaToastTasks[id] = nil
        cinemaToasts.removeAll { $0.id == id }
    }

    // MARK: 影院内搜索

    /// 在当前影院内检索：片名 / 原名 / 文件名 / 类型 / 演员 / 导演。
    /// `includeUnmatched` 为 true 时把未识别视频的文件名也纳入结果（默认只看已入库）。
    func cinemaSearchResults(_ query: String,
                             includeUnmatched: Bool = false)
        -> (entries: [CinemaEntry], series: [CinemaSeries], people: [CinemaCastMember]) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard keyword.count >= 1 else { return ([], [], []) }
        let scope = cinemaActiveScope
        var best: [String: CinemaEntry] = [:]
        for entry in (cinemaIndexes[scope] ?? [:]).values {
            guard !cinemaIsRestricted(entry) else { continue }
            guard entry.matched || includeUnmatched else { continue }
            guard entry.matched ? cinemaMatches(entry, keyword)
                                : entry.file.filename.lowercased().contains(keyword) else { continue }
            if entry.kind == .tv { continue }
            let key = cinemaVersionKey(for: entry)
            if let existing = best[key], !cinemaIsBetterVersion(entry, existing) { continue }
            best[key] = entry
        }
        var seriesPool = cinemaSeries(for: scope)
        if includeUnmatched {
            seriesPool += cinemaSeries(for: scope, matched: false)
        }
        let shows = seriesPool.filter { item in
            guard item.episodes.contains(where: { !cinemaIsRestricted($0) }) else { return false }
            if let first = item.episodes.first, !first.matched {
                guard includeUnmatched else { return false }
                return item.episodes.contains { $0.file.filename.lowercased().contains(keyword) }
            }
            if item.title.lowercased().contains(keyword) { return true }
            if (item.overview ?? "").lowercased().contains(keyword) { return true }
            return item.episodes.contains { cinemaMatches($0, keyword) }
        }
        // 人物：从已刮削条目的演员 / 导演里按名字匹配，并按名字去重。
        var people: [CinemaCastMember] = []
        var seenNames = Set<String>()
        for entry in (cinemaIndexes[scope] ?? [:]).values where entry.matched {
            guard !cinemaIsRestricted(entry) else { continue }
            for member in entry.cast ?? [] where member.name.lowercased().contains(keyword) {
                guard seenNames.insert(member.name).inserted else { continue }
                people.append(member)
            }
            for director in entry.directors ?? [] where director.lowercased().contains(keyword) {
                guard seenNames.insert(director).inserted else { continue }
                let profile = (cinemaIndexes[scope] ?? [:]).values
                    .compactMap { $0.cast?.first { $0.name == director } }
                    .first
                people.append(CinemaCastMember(name: director,
                                               character: "导演",
                                               profileURL: profile?.profileURL,
                                               tmdbID: profile?.tmdbID))
            }
        }
        let movies = best.values.sorted { $0.file.capturedAt > $1.file.capturedAt }
        return (movies, shows, Array(people.prefix(20)))
    }

    func cinemaMatches(_ entry: CinemaEntry, _ keyword: String) -> Bool {
        if entry.title.lowercased().contains(keyword) { return true }
        if (entry.originalTitle ?? "").lowercased().contains(keyword) { return true }
        if entry.file.filename.lowercased().contains(keyword) { return true }
        if (entry.genres ?? []).contains(where: { $0.lowercased().contains(keyword) }) { return true }
        if (entry.cast ?? []).contains(where: { $0.name.lowercased().contains(keyword) }) { return true }
        if (entry.directors ?? []).contains(where: { $0.lowercased().contains(keyword) }) { return true }
        return false
    }

    // MARK: 观看记录

    /// 当前作用域的全部观看记录（含已看完），按最近观看排序。
    func cinemaHistory(for scope: CinemaScope) -> [CinemaProgressRecord] {
        let mountID: UUID?
        switch scope {
        case .local: mountID = nil
        case .mount(let id): mountID = id
        }
        return cinemaProgress.values
            .filter { record in
                guard record.mountID == mountID else { return false }
                if let entry = cinemaIndexes[scope]?[record.photoID], cinemaIsRestricted(entry) {
                    return false
                }
                return true
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func removeCinemaProgress(_ id: UUID) {
        cinemaProgress.removeValue(forKey: id)
        persistCinemaProgress()
        showToast("已从观看记录中移除")
    }

    /// 右键「标记为已看 / 未看」：已看写成 100% 记录，未看直接移除续播记录。
    func setCinemaWatched(_ entry: CinemaEntry, watched: Bool) {
        if watched {
            let total = max(1, entry.file.duration ?? 0)
            cinemaProgress[entry.id] = CinemaProgressRecord(photoID: entry.id,
                                                           mountID: entry.file.cloudMountID,
                                                           title: entry.title,
                                                           subtitle: entry.subtitle,
                                                           artworkURL: entry.artworkURL,
                                                           position: total,
                                                           duration: total,
                                                           updatedAt: Date())
            persistCinemaProgress()
            showToast("已标记为已看「\(entry.title)」")
        } else {
            cinemaProgress.removeValue(forKey: entry.id)
            persistCinemaProgress()
            showToast("已标记为未看「\(entry.title)」")
        }
    }

    // MARK: 任务中心

    static func cinemaScopeKey(_ scope: CinemaScope) -> String {
        switch scope {
        case .local: return "local"
        case .mount(let id): return id.uuidString
        }
    }

    func cinemaScope(forKey key: String) -> CinemaScope? {
        if key == "local" { return .local }
        guard let id = UUID(uuidString: key) else { return nil }
        return .mount(id)
    }

    func cinemaScopeName(_ scope: CinemaScope) -> String {
        switch scope {
        case .local: return "本地图库"
        case .mount(let id): return cloudMounts.first { $0.id == id }?.name ?? "网络存储"
        }
    }

    /// 影院任务按统一源 ID 反查作用域名（AI 工具与任务条共用）。
    func cinemaScopeName(forSource source: SourceID) -> String {
        if source == .localCinema { return cinemaScopeName(.local) }
        if let mountID = source.uuidValue { return cinemaScopeName(.mount(mountID)) }
        return "影院"
    }

    @discardableResult
    func beginCinemaTask(for scope: CinemaScope, total: Int) -> UUID {
        let jobID = beginSourceJob(SourceJob(sourceID: sourceID(for: scope),
                                             kind: .scrape,
                                             title: "\(cinemaScopeName(scope)) · 刮削"),
                                   cancel: { [weak self] in
                                       Task { @MainActor in self?.cancelCinemaScrape() }
                                   })
        updateSourceJob(jobID, total: total, message: "共 \(total) 个视频")
        return jobID
    }

    func finishCinemaTask(_ id: UUID,
                          matched: Int,
                          succeeded: Bool,
                          skipped: Int = 0,
                          message: String,
                          notify: Bool = true) {
        var detail = "识别 \(matched) 个"
        if skipped > 0 { detail += " · 跳过 \(skipped) 个" }
        if !message.isEmpty { detail += " · \(message)" }
        let scopeKey = cinemaScopeKey(forJob: id)
        let scopeName = scopeKey.flatMap(cinemaScope(forKey:)).map(cinemaScopeName) ?? "影院"
        if succeeded {
            finishSourceJob(id, message: detail)
        } else {
            failSourceJob(id, message: detail)
        }
        guard notify else { return }
        // 任务结果同时归档到通知中心：同一任务 1 分钟内合并，不刷屏。
        recordCinemaNotification(succeeded ? .success : .failure,
                                 title: succeeded ? "刮削完成" : "刮削中断",
                                 detail: "\(scopeName) · \(detail)",
                                 action: succeeded ? nil : "重试",
                                 scopeKey: scopeKey)
    }

    /// 统一任务中心里的刮削任务 → 影院作用域键（local / 网盘 UUID）。
    /// 先看本次运行的进度，再看持久化历史：重启后失败记录仍能重试。
    func cinemaScopeKey(forJob id: UUID) -> String? {
        let source = sourceJobCenter.progress[id]?.sourceID
            ?? sourceJobHistory.first(where: { $0.jobID == id })?.sourceID
        guard let source else { return nil }
        if source == .localCinema { return "local" }
        guard source.rawValue.hasPrefix("cinema:mount:"),
              let mountID = source.uuidValue else { return nil }
        return mountID.uuidString
    }

    /// 失败任务的「重试」：重跑对应影院的刮削。
    func retryCinemaTask(_ job: JobProgress) async {
        guard let key = cinemaScopeKey(forJob: job.jobID),
              let scope = cinemaScope(forKey: key) else {
            showToast("来源已移除，无法重试")
            return
        }
        startCinemaScrape(for: scope, force: true)
    }

    /// 通知中心里的「重试」只带作用域键，从这里还原成影院并重跑。
    func retryCinemaScope(key: String) async {
        guard let scope = cinemaScope(forKey: key) else {
            postCinemaToast(.failure, title: "来源已移除，无法重试")
            return
        }
        startCinemaScrape(for: scope, force: true)
    }

    // MARK: 相簿内的影院操作

    /// 相簿 / 网格里的视频所属影院作用域。
    func cinemaScope(for photo: PhotoItem) -> CinemaScope {
        photo.cloudMountID.map { .mount($0) } ?? .local
    }

    func cinemaEntry(for photo: PhotoItem) -> CinemaEntry? {
        cinemaIndexes[cinemaScope(for: photo)]?[photo.id]
    }

    /// 相簿里直接应用手动匹配：没有刮削过的视频也能先匹配，再回影院查看。
    @discardableResult
    func applyCinemaMatch(_ match: CinemaMatch, to photo: PhotoItem) -> CinemaEntry? {
        let scope = cinemaScope(for: photo)
        let folderHint = cinemaIndexes[scope]?[photo.id]?.folderHint
        let parsed = CinemaScraper.parse(filename: photo.displayFilename, folderHint: folderHint)
        let updated = CinemaScraper.manualEntry(photo: photo,
                                                parsed: parsed,
                                                folderHint: folderHint,
                                                match: match)
        cinemaIndexes[scope, default: [:]][updated.id] = updated
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已匹配「\(updated.title)」")
        return updated
    }

    /// 视频所在目录：同目录判断用。网盘取 cloudPath 的上级，本地取源文件目录。
    func cinemaDirectoryKey(for photo: PhotoItem) -> String {
        if let cloudPath = photo.cloudPath, !cloudPath.isEmpty {
            return (cloudPath as NSString).deletingLastPathComponent
        }
        return LibraryPaths.sourceURL(for: photo).deletingLastPathComponent().path
    }

    /// 同目录、同解析片名（必要时同年代）且仍未识别的视频。
    /// 手动匹配一部片时顺带套用到它们，4K / 1080p 这类同名版本不用逐个点。
    func cinemaMatchSiblings(of photo: PhotoItem) -> [PhotoItem] {
        let scope = cinemaScope(for: photo)
        let folderHint = cinemaIndexes[scope]?[photo.id]?.folderHint
        let parsed = CinemaScraper.parse(filename: photo.displayFilename, folderHint: folderHint)
        let directory = cinemaDirectoryKey(for: photo)
        var siblings: [PhotoItem] = []
        for entry in cinemaEntries(for: scope).values {
            guard entry.id != photo.id, !entry.matched else { continue }
            guard cinemaDirectoryKey(for: entry.file.photoItem) == directory else { continue }
            let sibling = CinemaScraper.parse(filename: entry.file.filename, folderHint: entry.folderHint)
            guard sibling.title == parsed.title else { continue }
            if let year = parsed.year, let siblingYear = sibling.year, year != siblingYear { continue }
            siblings.append(anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem)
        }
        return siblings
    }

    /// 批量匹配剧集：同一部剧一次写给多个视频，季与每集集号由匹配面板确认。
    /// 文件名里解析不到的季集也能用这里的映射补上，避免所有集挤成一条。
    @discardableResult
    func applyCinemaMatch(_ match: CinemaMatch,
                          to photos: [PhotoItem],
                          season: Int?,
                          episodes: [UUID: Int],
                          folderHints: [UUID: String] = [:]) -> Int {
        var scopes: Set<CinemaScope> = []
        var applied = 0
        for photo in photos {
            let scope = cinemaScope(for: photo)
            let folderHint = folderHints[photo.id] ?? cinemaIndexes[scope]?[photo.id]?.folderHint
            var parsed = CinemaScraper.parse(filename: photo.displayFilename, folderHint: folderHint)
            if match.isTV {
                if let season { parsed.season = season }
                if let episode = episodes[photo.id] {
                    parsed.episode = episode
                    parsed.episodeEnd = nil
                }
            }
            let updated = CinemaScraper.manualEntry(photo: photo,
                                                    parsed: parsed,
                                                    folderHint: folderHint,
                                                    match: match)
            cinemaIndexes[scope, default: [:]][updated.id] = updated
            scopes.insert(scope)
            applied += 1
        }
        for scope in scopes {
            persistCinemaIndex(for: scope)
        }
        cinemaFolderRefreshToken &+= 1
        if match.isTV {
            showToast("已匹配「\(match.title)」· 第 \(season ?? 1) 季 · \(applied) 集")
        } else {
            showToast("已匹配「\(match.title)」· \(applied) 个视频")
        }
        return applied
    }

    /// 相簿多选右键「刮削所选」：只处理选中的视频，结果写回各自影院。
    func scrapeCinemaPhotos(_ photos: [PhotoItem]) async {
        let sources = metadataSources()
        guard !sources.isEmpty else {
            showToast("没有可用的刮削源，请检查设置 › 影院")
            return
        }
        let videos = photos.filter { CinemaScraper.isCandidate($0) }
        guard !videos.isEmpty else {
            showToast("所选项目里没有可刮削的视频")
            return
        }

        let scopes = Set(videos.map { cinemaScope(for: $0) })
        var taskIDs: [CinemaScope: UUID] = [:]
        for scope in scopes {
            taskIDs[scope] = beginCinemaTask(for: scope, total: videos.count)
        }
        let cache = CinemaSearchCache()
        let detailsCache = CinemaDetailsCache()
        var matched = 0

        for photo in videos {
            if Task.isCancelled { break }
            let scope = cinemaScope(for: photo)
            let outcome = await CinemaScraper.scrape(photo: photo,
                                                     folderHint: cinemaIndexes[scope]?[photo.id]?.folderHint,
                                                     sources: sources,
                                                     cache: cache,
                                                     detailsCache: detailsCache)
            if let entry = outcome.entry {
                cinemaIndexes[scope, default: [:]][entry.id] = entry
                if entry.matched { matched += 1 }
            }
        }

        for scope in scopes {
            persistCinemaIndex(for: scope)
            let scopeMatched = (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
            if let taskID = taskIDs[scope] {
                finishCinemaTask(taskID,
                                 matched: scopeMatched,
                                 succeeded: true,
                                 message: "相簿内快速刮削：识别 \(matched)/\(videos.count)")
            }
        }
        cinemaFolderRefreshToken &+= 1
        showToast("影院刮削完成：识别 \(matched)/\(videos.count)")
    }

    func setCinemaFavorite(_ value: Bool, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            var state = cinemaUserState(for: id)
            guard state.favorite != value else { continue }
            state.favorite = value
            state.updatedAt = Date()
            cinemaUserStates[id] = state
        }
        persistCinemaUserState()
        showToast(value ? "已加入影院收藏" : "已取消影院收藏")
    }

    func setCinemaWatchlist(_ value: Bool, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            var state = cinemaUserState(for: id)
            guard state.watchlist != value else { continue }
            state.watchlist = value
            state.updatedAt = Date()
            cinemaUserStates[id] = state
        }
        persistCinemaUserState()
        showToast(value ? "已加入想看" : "已移出想看")
    }

    // MARK: 家长控制

    var cinemaParentalEnabled: Bool {
        AppSettings.shared.cinemaParentalLevel != .off
    }

    /// 本次会话未解锁时按分级隐藏；未识别分级的条目默认放行。
    var cinemaParentalLocked: Bool {
        cinemaParentalEnabled && !cinemaParentalUnlocked
    }

    func cinemaIsRestricted(_ entry: CinemaEntry) -> Bool {
        guard cinemaParentalLocked else { return false }
        return !AppSettings.shared.cinemaParentalLevel.allows(certification: entry.certification)
    }

    func cinemaRestrictedCount(for scope: CinemaScope) -> Int {
        guard cinemaParentalLocked else { return 0 }
        return (cinemaIndexes[scope] ?? [:]).values.filter {
            $0.matched && !AppSettings.shared.cinemaParentalLevel.allows(certification: $0.certification)
        }.count
    }

    @discardableResult
    func unlockCinemaParental(pin: String) -> Bool {
        guard CinemaKeychain.verifyPIN(pin) else { return false }
        cinemaParentalUnlocked = true
        return true
    }

    func lockCinemaParental() {
        cinemaParentalUnlocked = false
    }

    // MARK: 智能季集映射（大模型 + 工具）

    /// 把剧名、季、文件列表和用户要求交给已配置的大模型。
    /// 模型可调用三个工具：切换模式、设置偏移、提交最终映射；这里执行工具并回填结果。
    func aiPlanEpisodeMapping(_ request: CinemaAIMatchRequest) async throws -> CinemaAIMatchPlan {
        guard aiConfigurationReady else {
            throw AIError.server("请先在设置 › 助手中填写接口地址与模型")
        }
        guard aiHasAPIKey else { throw AIError.missingKey }

        let modeTool = AIRequestTool(
            name: "set_episode_mode",
            description: "切换集号来源。fileName = 优先用文件名里的数字；sequential = 按文件顺序编号。可选。",
            parameters: [
                "type": "object",
                "properties": ["mode": ["type": "string", "enum": ["fileName", "sequential"]]],
                "required": ["mode"]
            ])
        let offsetTool = AIRequestTool(
            name: "set_episode_offset",
            description: "设置集号偏移：最终集号 = 文件名数字 + offset。例如把 11 当作第 1 集时 offset = -10。可选。",
            parameters: [
                "type": "object",
                "properties": ["offset": ["type": "integer"]],
                "required": ["offset"]
            ])
        let applyTool = AIRequestTool(
            name: "apply_episode_mapping",
            description: "提交每个文件的最终集号。必须覆盖全部文件；同一内容的不同版本共用一个集号。",
            parameters: [
                "type": "object",
                "properties": [
                    "assignments": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer", "description": "文件序号，从 1 开始，对应输入列表"],
                                "episode": ["type": "integer", "description": "集号，>= 1"]
                            ],
                            "required": ["index", "episode"]
                        ]
                    ],
                    "note": ["type": "string", "description": "一句话说明你的排法"]
                ],
                "required": ["assignments"]
            ])

        let systemPrompt = """
        你是影院的季集匹配助手。用户给出一部剧的季号与文件列表，你要为每个文件决定集号。
        规则：
        1. 优先采用文件名里的集号；先剥离 4K/2160p/1080p/HDR/DV/编码/音轨/字幕/高码版等版本标记，再取数字。
        2. 同一内容的不同版本（如 13.mkv 与 13 4K.mkv）必须使用同一个集号。
        3. 缺失集号的文件按相邻集号补齐，保持连续；不要无故重排已有集号。
        4. 用户给了补充要求时优先满足（例如「11 当作第 1 集」→ offset = -10）。
        5. 只处理第 \(request.season) 季，不要输出季号。
        6. 最终必须调用 apply_episode_mapping，一次给出全部 index → episode；不要只回复解释。
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let filesJSON = (try? encoder.encode(request.files))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var userText = """
        剧目：\(request.title)
        年份：\(request.year.map(String.init) ?? "未知")
        季：\(request.season)
        文件数：\(request.files.count)
        """
        if let note = request.note, !note.isEmpty {
            userText += "\n补充要求：\(note)"
        }
        userText += "\n文件列表（index 从 1 开始）：\n\(filesJSON)"

        var messages: [AIRequestMessage] = [
            AIRequestMessage(role: "system", text: systemPrompt),
            AIRequestMessage(role: "user", text: userText)
        ]
        var config = aiConfig
        // 几十条映射的 JSON 会超过默认额度，给足空间。
        config.maxTokens = max(config.maxTokens, 4096)

        var mode: String?
        var offset: Int?
        var plan: CinemaAIMatchPlan?

        for _ in 0..<3 {
            let completion = try await AIProviderClient.complete(config: config,
                                                                 apiKey: aiAPIKey,
                                                                 messages: messages,
                                                                 tools: [modeTool, offsetTool, applyTool])

            if completion.toolCalls.isEmpty {
                if let parsed = Self.cinemaAIPlan(from: completion.content, mode: mode, offset: offset) {
                    plan = parsed
                    break
                }
                throw AIError.server("助手没有给出集号映射：\(completion.content.prefix(120))")
            }

            var toolResults: [AIRequestMessage] = []
            var finished = false
            for call in completion.toolCalls {
                let args = Self.cinemaAIArguments(call.arguments)
                switch call.name {
                case "set_episode_mode":
                    mode = args["mode"] as? String
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "已记录模式：\(mode ?? "未识别")",
                                                        toolCallID: call.id))
                case "set_episode_offset":
                    offset = (args["offset"] as? NSNumber)?.intValue
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "已记录偏移：\(offset.map(String.init) ?? "未识别")",
                                                        toolCallID: call.id))
                case "apply_episode_mapping":
                    let assignments = Self.cinemaAIAssignments(from: args)
                    guard !assignments.isEmpty else {
                        toolResults.append(AIRequestMessage(role: "tool",
                                                            text: "assignments 为空或格式不正确，请重新调用并覆盖全部文件",
                                                            toolCallID: call.id))
                        continue
                    }
                    plan = CinemaAIMatchPlan(assignments: assignments,
                                             mode: mode,
                                             offset: offset,
                                             note: args["note"] as? String)
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "已收到 \(assignments.count) 条映射",
                                                        toolCallID: call.id))
                    finished = true
                default:
                    toolResults.append(AIRequestMessage(role: "tool",
                                                        text: "未知工具：\(call.name)",
                                                        toolCallID: call.id))
                }
            }
            if finished, plan != nil { break }
            messages.append(AIRequestMessage(role: "assistant",
                                             text: completion.content,
                                             toolCalls: completion.toolCalls))
            messages.append(contentsOf: toolResults)
        }

        guard var result = plan else {
            throw AIError.server("助手没有给出可用的集号映射，请重试或换一个模型")
        }
        if result.mode == nil { result.mode = mode }
        if result.offset == nil { result.offset = offset }
        return result
    }

    static func cinemaAIArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func cinemaAIAssignments(from object: [String: Any]) -> [Int: Int] {
        guard let list = object["assignments"] as? [[String: Any]] else { return [:] }
        var result: [Int: Int] = [:]
        for item in list {
            guard let index = (item["index"] as? NSNumber)?.intValue,
                  let episode = (item["episode"] as? NSNumber)?.intValue,
                  index >= 1, episode >= 1 else { continue }
            result[index] = episode
        }
        return result
    }

    /// 模型有时不调工具，直接在正文里回 JSON；这里兜底解析。
    static func cinemaAIPlan(from content: String,
                                     mode: String?,
                                     offset: Int?) -> CinemaAIMatchPlan? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else { return nil }
        let object = cinemaAIArguments(String(content[start...end]))
        let assignments = cinemaAIAssignments(from: object)
        guard !assignments.isEmpty else { return nil }
        return CinemaAIMatchPlan(assignments: assignments,
                                 mode: mode,
                                 offset: offset,
                                 note: object["note"] as? String)
    }
}
