import Foundation
import LumaContentCore

// MARK: - 网络资源 2.0：置顶 / 关注 / 健康度 / 跨源发现

extension CatalogBrowserModel {

    // MARK: - 排序与置顶

    /// 卡片墙顺序：置顶的源在前，其余保持原顺序。
    var orderedSources: [CatalogSource] {
        let pinned = pinnedSourceIDs.compactMap { id in
            sources.first(where: { $0.id == id })
        }
        let rest = sources.filter { !pinnedSourceIDs.contains($0.id) }
        return pinned + rest
    }

    /// 指定域的卡片墙顺序：网络资源与网络影院各自排序，不会把对方的源带进来。
    func orderedSources(in domain: CatalogDomain) -> [CatalogSource] {
        let scoped = sources(in: domain)
        let ids = Set(scoped.map(\.id))
        let pinned = pinnedSourceIDs.compactMap { id in
            ids.contains(id) ? scoped.first(where: { $0.id == id }) : nil
        }
        let rest = scoped.filter { !pinnedSourceIDs.contains($0.id) }
        return pinned + rest
    }

    /// 网络资源自己的卡片墙顺序。
    var orderedResourceSources: [CatalogSource] { orderedSources(in: .networkResource) }

    func isPinned(sourceID: UUID) -> Bool {
        pinnedSourceIDs.contains(sourceID)
    }

    func togglePin(sourceID: UUID) {
        if let index = pinnedSourceIDs.firstIndex(of: sourceID) {
            pinnedSourceIDs.remove(at: index)
        } else {
            pinnedSourceIDs.append(sourceID)
        }
        savePins()
    }

    /// 分类面板顺序：常用（置顶）的分类排在前面，其余保持站点顺序。
    func orderedCategories(_ list: [CatalogCategory]) -> [CatalogCategory] {
        guard let sourceID = selectedSourceID,
              let pins = pinnedCategoryIDs[sourceID], !pins.isEmpty else { return list }
        let pinned = pins.compactMap { id in list.first(where: { $0.id == id }) }
        let rest = list.filter { !pins.contains($0.id) }
        return pinned + rest
    }

    func isPinnedCategory(_ id: String) -> Bool {
        guard let sourceID = selectedSourceID else { return false }
        return pinnedCategoryIDs[sourceID]?.contains(id) ?? false
    }

    func togglePinnedCategory(_ category: CatalogCategory) {
        guard let sourceID = selectedSourceID else { return }
        var pins = pinnedCategoryIDs[sourceID] ?? []
        if let index = pins.firstIndex(of: category.id) {
            pins.remove(at: index)
        } else {
            pins.append(category.id)
        }
        pinnedCategoryIDs[sourceID] = pins
        saveCategoryPins()
    }

    // MARK: - 关注

    func isFollowed(_ category: CatalogCategory) -> Bool {
        guard let sourceID = selectedSourceID else { return false }
        return followedCategories.contains { $0.sourceID == sourceID && $0.categoryID == category.id }
    }

    func toggleFollow(_ category: CatalogCategory) {
        guard let source = selectedSource else { return }
        if let index = followedCategories.firstIndex(where: {
            $0.sourceID == source.id && $0.categoryID == category.id
        }) {
            followedCategories.remove(at: index)
        } else {
            followedCategories.append(CatalogFollowedCategory(sourceID: source.id,
                                                              categoryID: category.id,
                                                              title: category.title,
                                                              sourceName: source.name,
                                                              addedAt: Date()))
        }
        saveFollows()
    }

    func removeFollow(_ followed: CatalogFollowedCategory) {
        followedCategories.removeAll { $0.id == followed.id }
        saveFollows()
    }

    // MARK: - 新内容标记

    func hasNewContent(_ sourceID: UUID) -> Bool {
        newSourceIDs.contains(sourceID)
    }

    /// 首页第一页回来后比对首条：和上次不同就认为源有新内容。
    func recordTopItem(_ itemID: String, sourceID: UUID) {
        defer {
            lastSeenTop[sourceID] = itemID
            saveLastSeen()
        }
        guard let previous = lastSeenTop[sourceID], !previous.isEmpty else { return }
        guard previous != itemID else { return }
        // 正在浏览这个源时不算「新内容」：用户已经看到了。
        if selectedSourceID != sourceID {
            newSourceIDs.insert(sourceID)
            saveNewFlags()
        }
    }

    /// 进入源就把红点清掉。
    func markSourceViewed(_ sourceID: UUID) {
        guard newSourceIDs.remove(sourceID) != nil else { return }
        saveNewFlags()
    }

    // MARK: - 健康度

    /// 依次探测每个源的首页：在线 / 需验证（WAF、PoW 未通过）/ 离线。
    /// 只探测指定域：网络资源的「检测全部」不会连带请求影视源，反之亦然。
    func checkHealth(force: Bool = false, domain: CatalogDomain = .networkResource) {
        let targets = enabledSources(in: domain).filter {
            force || (health[$0.id] ?? .unknown) == .unknown
        }
        guard !targets.isEmpty else { return }
        for source in targets { health[source.id] = .checking }

        healthTask?.cancel()
        let jobSourceID: SourceID = domain == .networkCinema ? .networkCinema : .catalogHub
        let jobID = jobCenter?.begin(
            SourceJob(sourceID: jobSourceID,
                      kind: .healthCheck,
                      title: "检测 \(targets.count) 个\(domain.title)源"),
            cancel: { [weak self] in
                Task { @MainActor in self?.healthTask?.cancel() }
            }
        )
        onJobChange?()

        healthTask = Task { [weak self] in
            var online = 0
            var limited = 0
            var offline = 0
            await CatalogRequestScope.$isBackground.withValue(true) {
                for (index, source) in targets.enumerated() {
                    guard let self, !Task.isCancelled else { return }
                    if let jobID {
                        self.jobCenter?.update(jobID,
                                               completed: index,
                                               total: targets.count,
                                               message: source.name)
                        self.onJobChange?()
                    }
                    let started = Date()
                    let state = await Self.probe(source: source)
                    self.health[source.id] = state
                    self.healthLatency[source.id] = Int(Date().timeIntervalSince(started) * 1000)
                    self.healthCheckedAt[source.id] = Date()
                    switch state {
                    case .online: online += 1
                    case .limited: limited += 1
                    case .offline: offline += 1
                    default: break
                    }
                }
            }
            guard let self else { return }
            guard let jobID else { return }
            if Task.isCancelled {
                self.jobCenter?.cancel(jobID)
            } else {
                self.jobCenter?.finish(jobID,
                                       message: "在线 \(online) · 需验证 \(limited) · 离线 \(offline)")
            }
            self.onJobChange?()
        }
    }

    /// 供 `SourceSession` 使用的单源健康探测：结果与总览页的健康徽章同源。
    func probeHealth(_ source: CatalogSource) async -> SourceHealth {
        let started = Date()
        let result = await Self.probe(source: source)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .online:
            return SourceHealth(state: .healthy, checkedAt: Date(), latencyMilliseconds: latency)
        case .limited:
            return SourceHealth(state: .degraded, checkedAt: Date(),
                                latencyMilliseconds: latency, message: "站点要求先完成验证")
        case .offline:
            return SourceHealth(state: .offline, checkedAt: Date(),
                                latencyMilliseconds: latency, message: "站点暂时连不上")
        case .checking, .unknown:
            return SourceHealth(state: .unknown, checkedAt: Date())
        }
    }

    /// 健康探测统一走 `ContentRepository`：站点适配器怎么换都不影响这里，
    /// 电视接入后也能复用同一份探测逻辑。
    private static func probe(source: CatalogSource) async -> CatalogSourceHealth {
        await withTaskGroup(of: CatalogSourceHealth?.self) { group in
            group.addTask {
                do {
                    let repository = CatalogContentRepository(source: source)
                    let page = try await repository.page(ContentQuery(cursor: PageCursor(page: 1),
                                                                      limit: 1))
                    return page.items.isEmpty ? .limited : .online
                } catch let error as SourceError {
                    switch error.kind {
                    case .unsupported:
                        return .offline
                    case .http:
                        if let code = error.statusCode, code == 492 || code == 403 { return .limited }
                        return .offline
                    case .parse, .blocked:
                        return .limited
                    default:
                        return .offline
                    }
                } catch {
                    return .offline
                }
            }
            group.addTask {
                // 首次探测可能先换一次地址（黄果这类被 DNS 拦的源），给足时间再判离线。
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .limited
        }
    }

    // MARK: - 跨源总榜

    /// 指定域的当前榜单：网络资源与网络影院各读自己的缓存，绝不互相串数据。
    func currentSpotlight(in domain: CatalogDomain) -> [CatalogSpotlightItem] {
        let ids = Set(sources(in: domain).map(\.id))
        switch spotlightMode {
        case .latest:
            return (spotlightByDomain[domain] ?? []).filter { ids.contains($0.sourceID) }
        case .hot:
            return (spotlightHotByDomain[domain] ?? []).filter { ids.contains($0.sourceID) }
        case .todayNew:
            return todaySpotlight.filter { ids.contains($0.sourceID) }
        }
    }

    /// 网络资源自己的当前榜单。
    var currentSpotlight: [CatalogSpotlightItem] { currentSpotlight(in: .networkResource) }

    /// 重算「今天新增」：只在日历 / 源变化时调用一次，
    /// 避免工具栏角标和榜单每次重绘都过滤一遍 2400 条日历。
    func rebuildTodaySpotlight() {
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        // 逐条 `isDateInToday` 会反复创建 Calendar；直接算今天的起止时间。
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        todaySpotlight = calendarItems
            .filter { $0.firstSeen >= todayStart && $0.firstSeen < todayEnd }
            .sorted { $0.firstSeen > $1.firstSeen }
            .prefix(24)
            .compactMap { entry in
                guard let source = sourcesByID[entry.sourceID] else { return nil }
                return CatalogSpotlightItem(sourceID: entry.sourceID,
                                            sourceName: source.name,
                                            item: entry.item)
            }
    }

    func loadSpotlight(mode: CatalogSpotlightMode? = nil,
                       force: Bool = false,
                       domain: CatalogDomain = .networkResource) {
        if let mode {
            spotlightMode = mode
            CatalogStore.string(forKey: Self.spotlightModeKey, value: mode.rawValue)
        }
        switch spotlightMode {
        case .todayNew:
            // 本地数据，即时可用。
            return
        case .latest:
            loadLatestSpotlight(force: force, domain: domain)
        case .hot:
            loadHotSpotlight(force: force, domain: domain)
        }
    }

    private func loadLatestSpotlight(force: Bool = false, domain: CatalogDomain) {
        guard !isSpotlightLoading else { return }
        if spotlightLoadedDomains.contains(domain), !force { return }
        let targets = enabledSources(in: domain)
        guard !targets.isEmpty else {
            spotlightByDomain[domain] = []
            return
        }
        isSpotlightLoading = true
        Task { [weak self] in
            await CatalogRequestScope.$isBackground.withValue(true) {
                var groups: [[CatalogSpotlightItem]] = []
                for source in targets {
                    guard let provider = CatalogProviders.provider(for: source.kind) else { continue }
                    guard let page = try? await provider.home(source: source, page: 1),
                          !page.items.isEmpty else { continue }
                    groups.append(page.items.prefix(4).map {
                        CatalogSpotlightItem(sourceID: source.id, sourceName: source.name, item: $0)
                    })
                }
                guard let self else { return }
                let items = Self.interleave(groups)
                self.spotlightByDomain[domain] = items
                self.isSpotlightLoading = false
                self.spotlightLoadedDomains.insert(domain)
                self.persistSpotlight(items, domain: domain)
            }
        }
    }

    /// 各源热榜：优先用源自己的「排行榜 / 今日热门」分类，没有就跳过。
    private func loadHotSpotlight(force: Bool = false, domain: CatalogDomain) {
        guard !isSpotlightHotLoading else { return }
        if spotlightHotLoadedDomains.contains(domain), !force { return }
        let targets = enabledSources(in: domain)
        guard !targets.isEmpty else {
            spotlightHotByDomain[domain] = []
            return
        }
        isSpotlightHotLoading = true
        Task { [weak self] in
            await CatalogRequestScope.$isBackground.withValue(true) {
                var groups: [[CatalogSpotlightItem]] = []
                for source in targets {
                    guard let provider = CatalogProviders.provider(for: source.kind),
                          let hot = self?.hotCategory(for: source) else { continue }
                    guard let page = try? await provider.category(source: source, category: hot,
                                                                  sort: .hot, page: 1),
                          !page.items.isEmpty else { continue }
                    groups.append(page.items.prefix(4).map {
                        CatalogSpotlightItem(sourceID: source.id, sourceName: source.name, item: $0)
                    })
                }
                guard let self else { return }
                let items = Self.interleave(groups)
                self.spotlightHotByDomain[domain] = items
                self.isSpotlightHotLoading = false
                self.spotlightHotLoadedDomains.insert(domain)
                if let data = try? JSONEncoder().encode(items) {
                    CatalogStore.set(data, forKey: Self.spotlightHotKey(for: domain))
                }
            }
        }
    }

    private func persistSpotlight(_ items: [CatalogSpotlightItem], domain: CatalogDomain) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        CatalogStore.set(data, forKey: Self.spotlightLatestKey(for: domain))
    }

    /// 找源的热榜分类：排行标记优先，其次标题里带「热 / 排行 / 榜」。
    private func hotCategory(for source: CatalogSource) -> CatalogCategory? {
        let list = (selectedSourceID == source.id && !categories.isEmpty) ? categories : source.categories
        let flat = list + list.flatMap { $0.children ?? [] }
        if let rank = flat.first(where: { $0.isRank }) { return rank }
        let words = ["热", "熱", "排行", "榜"]
        return flat.first { category in
            !category.isGroupCategory && !category.id.isEmpty
                && words.contains { category.title.contains($0) }
        }
    }

    /// 各源轮流取一条，避免总榜前三都被同一个源占满。
    private static func interleave(_ groups: [[CatalogSpotlightItem]]) -> [CatalogSpotlightItem] {
        var result: [CatalogSpotlightItem] = []
        var index = 0
        while result.count < 24 {
            var appended = false
            for group in groups where index < group.count {
                result.append(group[index])
                appended = true
                if result.count >= 24 { break }
            }
            if !appended { break }
            index += 1
        }
        return result
    }

    // MARK: - 跨源搜索

    func searchAllSources() {
        let keyword = globalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        globalSearchTask?.cancel()
        guard !keyword.isEmpty else {
            globalResults = []
            globalQueryPlan = nil
            isGlobalSearching = false
            return
        }
        let plan = CatalogQueryPlan.parse(keyword)
        globalQueryPlan = plan
        recordRecentSearch(keyword)
        // 只输入了「中文字幕」「90 年代」这类条件时，仍拿原词去搜。
        let siteKeyword = plan.keyword.isEmpty ? keyword : plan.keyword
        // 即时命中：先把本地快照里的结果铺出来，网络结果回来再替换。
        let local = localSearchHits(siteKeyword)
        globalResults = local
        globalResultsKeyword = keyword
        isGlobalSearching = true
        globalSearchTask = Task { [weak self] in
            let results = await self?.crossSourceSearch(keyword: siteKeyword, plan: plan) ?? []
            guard let self, !Task.isCancelled else { return }
            // 站点全部失败时保留本地命中，不要退回空态。
            self.globalResults = results.isEmpty ? local : results
            self.globalResultsKeyword = keyword
            self.isGlobalSearching = false
        }
    }

    /// 记住最近搜索词：搜索框聚焦且为空时以胶囊展示，最多 8 条。
    func recordRecentSearch(_ raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyword.count >= 2 else { return }
        var list = recentSearches.filter { $0 != keyword }
        list.insert(keyword, at: 0)
        recentSearches = Array(list.prefix(8))
        guard let data = try? JSONEncoder().encode(recentSearches) else { return }
        CatalogStore.set(data, forKey: Self.recentSearchesKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        CatalogStore.set(nil, forKey: Self.recentSearchesKey)
    }

    /// 本地快照里的即时命中：不请求任何站点，输入时先把已缓存的内容铺出来。
    func localSearchHits(_ keyword: String, limitPerSource: Int = 12) -> [CatalogGlobalResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var seen = Set<String>()
        var grouped: [UUID: [CatalogItem]] = [:]
        for (key, snapshot) in pageSnapshots {
            guard let rawID = key.split(separator: "|").first,
                  let sourceID = UUID(uuidString: String(rawID)) else { continue }
            for item in snapshot.items {
                let text = item.title + " " + item.remark
                guard text.localizedCaseInsensitiveContains(trimmed) else { continue }
                let id = "\(sourceID.uuidString)|\(item.id)"
                guard seen.insert(id).inserted else { continue }
                guard (grouped[sourceID]?.count ?? 0) < limitPerSource else { continue }
                grouped[sourceID, default: []].append(item)
            }
        }
        // 结果按侧边栏里源的上下顺序输出，改排序后本地即时命中也跟着变。
        // 只输出网络资源的源：影视源属于网络影院，不能混进资源检索。
        return resourceSources.compactMap { source -> CatalogGlobalResult? in
            guard let items = grouped[source.id], !items.isEmpty else { return nil }
            return CatalogGlobalResult(sourceID: source.id,
                                       sourceName: source.name,
                                       items: items)
        }
    }

    /// 统一搜索入口：一次调用完成「本地快照 + 跨站检索」，并把结果同步进频道页的搜索状态。
    /// 与 `searchAllSources()` 的区别是不自己起后台任务，方便上层（如 SearchCenter）等待结果。
    /// - Parameter updatesUI: 全局搜索只借用这轮检索，不写网络资源页的搜索框、结果与最近搜索。
    func searchUnified(keyword: String, updatesUI: Bool = true) async -> [CatalogGlobalResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let plan = CatalogQueryPlan.parse(trimmed)
        if updatesUI {
            globalQuery = trimmed
            globalQueryPlan = plan
            recordRecentSearch(trimmed)
        }
        let siteKeyword = plan.keyword.isEmpty ? trimmed : plan.keyword
        let local = localSearchHits(siteKeyword)
        if updatesUI {
            globalResults = local
            globalResultsKeyword = trimmed
            isGlobalSearching = true
        }
        globalSearchTask?.cancel()
        let results = await crossSourceSearch(keyword: siteKeyword, plan: plan)
        guard !Task.isCancelled else { return local }
        if updatesUI {
            globalResults = results.isEmpty ? local : results
            isGlobalSearching = false
        }
        return results.isEmpty ? local : results
    }

    /// 跨源检索：并发问所有启用的源，单个源超时 / 失败直接跳过，
    /// 再按自然语言条件排序和过滤。
    func crossSourceSearch(keyword: String,
                           plan: CatalogQueryPlan) async -> [CatalogGlobalResult] {
        // 网络资源的跨源检索只问网页资源站，影视源由「网络影院」自己检索。
        let targets = enabledResourceSources
        guard !targets.isEmpty else { return [] }
        var collected: [(index: Int, source: CatalogSource, items: [CatalogItem])] = []
        await withTaskGroup(of: (Int, [CatalogItem]).self) { group in
            for (index, source) in targets.enumerated() {
                group.addTask {
                    let items = await CatalogSearchSupport.search(source, keyword: keyword)
                    return (index, items)
                }
            }
            for await (index, items) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                guard !items.isEmpty else { continue }
                collected.append((index, targets[index], items))
            }
        }
        guard !Task.isCancelled else { return [] }
        // 结果按侧边栏里源的顺序输出，排序不随请求完成顺序变化。
        return collected.sorted { $0.index < $1.index }.compactMap { entry in
            let ranked = entry.items
                .map { (item: $0, score: plan.score($0)) }
                .sorted { $0.score > $1.score }
                .map(\.item)
            let filtered = plan.chineseOnly || plan.yearFrom != nil
                ? ranked.filter { plan.score($0) >= 0 }
                : ranked
            let items = Array((filtered.isEmpty ? ranked : filtered).prefix(12))
            guard !items.isEmpty else { return nil }
            return CatalogGlobalResult(sourceID: entry.source.id,
                                       sourceName: entry.source.name,
                                       items: items)
        }
    }

    func clearGlobalSearch() {
        globalSearchTask?.cancel()
        globalResults = []
        globalResultsKeyword = ""
        globalQueryPlan = nil
        isGlobalSearching = false
    }

    // MARK: - 跨源直接播放

    /// 从总览页直接播：先补详情，再交给查看器，不改变当前浏览的分类。
    func playRemote(sourceID: UUID, item: CatalogItem, seconds: Double = 0) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            showNotice(CatalogError.unsupportedProvider.localizedDescription)
            return
        }
        // 解析过的条目直接起播：弱网时不再为一次点击多等一个详情请求。
        let key = detailKey(source: source, itemID: item.id)
        if let cached = cachedDetails[key], let first = cached.episodes.first {
            emit(CatalogPlaybackRequest(source: source, item: cached.item,
                                        episodes: cached.episodes,
                                        startEpisode: first.index,
                                        startSeconds: seconds))
            return
        }
        Task { [weak self] in
            do {
                var detail = try await provider.detail(source: source, itemID: item.id)
                if detail.item.title.isEmpty { detail.item.title = item.title }
                if detail.item.coverURL.isEmpty { detail.item.coverURL = item.coverURL }
                guard let episode = detail.episodes.first else {
                    self?.showNotice("该条目没有可播放的视频")
                    return
                }
                guard let self else { return }
                self.cachedDetails[self.detailKey(source: source, itemID: item.id)] = detail
                self.emit(CatalogPlaybackRequest(source: source,
                                                 item: detail.item,
                                                 episodes: detail.episodes,
                                                 startEpisode: episode.index,
                                                 startSeconds: seconds))
            } catch {
                self?.showNotice("打开失败：\(error.localizedDescription)")
            }
        }
    }

    func playFavorite(_ favorite: CatalogFavorite) {
        let item = CatalogItem(id: favorite.itemID,
                               title: favorite.title,
                               coverURL: favorite.coverURL,
                               remark: favorite.remark,
                               categoryID: nil)
        playRemote(sourceID: favorite.sourceID, item: item)
    }

    /// 跨源「稍后看」：所有源合并，按加入时间倒序。
    var allFavorites: [CatalogFavorite] {
        favorites.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// 随便看看：从网络资源当前的榜单维度里随机挑一条。
    func randomSpotlightItem() -> CatalogSpotlightItem? {
        let ids = resourceSourceIDs
        return currentSpotlight.filter { ids.contains($0.sourceID) }.randomElement()
    }

    // MARK: - 悬停预览

    /// 卡片悬停时的静音预览：解析一次流地址后缓存，失败 15 秒内不重试。
    func previewTarget(for item: CatalogItem) async -> CatalogPreviewTarget? {
        guard let source = selectedSource else { return nil }
        return await previewTarget(sourceID: source.id, item: item)
    }

    /// 跨源卡片（总览轨道）也能预览：显式指定源，不依赖当前浏览上下文。
    func previewTarget(sourceID: UUID, item: CatalogItem) async -> CatalogPreviewTarget? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let key = "\(source.id.uuidString)|\(item.id)"
        if let cached = previewCache[key] { return cached }
        if let missedAt = previewMissAt[key], Date().timeIntervalSince(missedAt) < 15 {
            return nil
        }
        // 并发满了短暂排队，而不是直接失败：鼠标扫得快时不再有「有的能预览、有的不行」。
        guard await acquirePreviewSlot() else { return nil }
        previewInFlight += 1
        defer { previewInFlight -= 1 }
        guard let provider = CatalogProviders.provider(for: source.kind) else { return nil }
        do {
            let detail = try await provider.detail(source: source, itemID: item.id)
            guard let episode = detail.episodes.first else {
                previewMissAt[key] = Date()
                return nil
            }
            let stream = try await provider.stream(source: source, episode: episode)
            if previewCache.count >= 40 { previewCache.removeAll() }
            let target = CatalogPreviewTarget(url: stream.url, headers: stream.headers)
            previewCache[key] = target
            return target
        } catch {
            previewMissAt[key] = Date()
            Diagnostics.record("悬停预览解析失败 \(source.name) \(item.id)：\(error.localizedDescription)")
            return nil
        }
    }

    /// 选集卡的悬停预览：直接解析指定剧集的流，不用再拉一次详情。
    /// 与卡片预览共用缓存 / 失败冷却 / 并发限制，扫过一整屏选集也不会打爆站点。
    func previewTarget(sourceID: UUID, itemID: String,
                       episode: CatalogEpisode) async -> CatalogPreviewTarget? {
        guard let source = sources.first(where: { $0.id == sourceID }),
              let provider = CatalogProviders.provider(for: source.kind) else { return nil }
        let key = "\(source.id.uuidString)|\(itemID)|\(episode.pageURL)"
        if let cached = previewCache[key] { return cached }
        if let missedAt = previewMissAt[key], Date().timeIntervalSince(missedAt) < 15 {
            return nil
        }
        guard await acquirePreviewSlot() else { return nil }
        previewInFlight += 1
        defer { previewInFlight -= 1 }
        do {
            let stream = try await provider.stream(source: source, episode: episode)
            if previewCache.count >= 40 { previewCache.removeAll() }
            let target = CatalogPreviewTarget(url: stream.url, headers: stream.headers)
            previewCache[key] = target
            return target
        } catch {
            previewMissAt[key] = Date()
            Diagnostics.record("选集预览解析失败 \(source.name) 第 \(episode.index) 集：\(error.localizedDescription)")
            return nil
        }
    }

    /// 预览并发名额：同时最多两份（详情解析 + 流解析各占一份），
    /// 名额满了就短暂排队——以前直接返回 nil，表现就是「有些卡片悬停没反应」。
    /// 不看 isUserBusy：翻页 / 搜索在跑的时候悬停也该有反应，否则一换分类整屏都没预览。
    private func acquirePreviewSlot() async -> Bool {
        let deadline = Date().addingTimeInterval(2.4)
        while !Task.isCancelled {
            if previewInFlight < 2 { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return false
    }

    // MARK: - 筛选记忆

    /// 记住当前源停在哪一页、用什么排序：下次启动直接还原。
    func rememberView() {
        guard let sourceID = selectedSourceID else { return }
        let marker: String
        switch section {
        case .home: marker = "home"
        case .rank: marker = "rank"
        case .category(let id): marker = "cat-\(id)"
        default: return
        }
        var all: [String: [String: String]] = [:]
        if let data = CatalogStore.data(forKey: Self.lastViewKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            all = decoded
        }
        all[sourceID.uuidString] = ["section": marker, "sort": sort.rawValue,
                                    "localSort": localSort?.rawValue ?? ""]
        if let data = try? JSONEncoder().encode(all) {
            CatalogStore.set(data, forKey: Self.lastViewKey)
        }
    }

    /// 启动时还原上次浏览的分类与排序；找不到就保持首页。
    func restoreLastView() {
        guard let sourceID = selectedSourceID,
              let data = CatalogStore.data(forKey: Self.lastViewKey),
              let all = try? JSONDecoder().decode([String: [String: String]].self, from: data),
              let entry = all[sourceID.uuidString] else { return }
        if let raw = entry["sort"], let value = CatalogSort(rawValue: raw),
           supportedSorts.contains(value) {
            sort = value
        }
        if let raw = entry["localSort"], !raw.isEmpty {
            localSort = CatalogLocalSort(rawValue: raw)
        }
        guard let marker = entry["section"] else { return }
        if marker == "rank" {
            section = .rank
            activeTopCategoryID = categories.first(where: { $0.isRank })?.id
            reload()
            return
        }
        guard marker.hasPrefix("cat-") else { return }
        let categoryID = String(marker.dropFirst(4))
        section = .category(categoryID)
        activeTopCategoryID = categories.first { top in
            top.id == categoryID
                || (top.children?.contains(where: { $0.id == categoryID }) ?? false)
        }?.id
        reload()
    }

    // MARK: - 更新日历

    /// 每次首页第一页加载时记录「第一次见到」的条目，按月汇总就是更新热度。
    /// 返回本次真正新增的条数：后台补录用它上报任务进度。
    @discardableResult
    func recordCalendar(items: [CatalogItem], sourceID: UUID) -> Int {
        guard !items.isEmpty else { return 0 }
        let existing = Set(calendarItems.map(\.id))
        var added: [CatalogCalendarItem] = []
        var corrected = false
        let calendar = Calendar.current
        let now = Date()
        for item in items {
            let key = "\(sourceID.uuidString)|\(item.id)"
            if existing.contains(key) {
                // 已有记录也校正一次：站点给了真实上架日期时，把旧的「看到的时间」改成上架日。
                guard let published = item.publishedAt,
                      let index = calendarItems.firstIndex(where: { $0.id == key }),
                      !calendar.isDate(calendarItems[index].firstSeen, inSameDayAs: published)
                else { continue }
                calendarItems[index].firstSeen = published
                corrected = true
                continue
            }
            added.append(CatalogCalendarItem(sourceID: sourceID,
                                             itemID: item.id,
                                             title: item.title,
                                             coverURL: item.coverURL,
                                             remark: item.remark,
                                             firstSeen: item.publishedAt
                                                ?? parsedPublishDate(title: item.title,
                                                                     remark: item.remark)
                                                ?? now))
        }
        if corrected { CatalogStore.replaceCalendar(calendarItems) }
        guard !added.isEmpty else {
            if corrected { rebuildTodaySpotlight() }
            return 0
        }
        calendarItems.append(contentsOf: added)
        CatalogStore.insertCalendar(added)
        // 新补录的条目记下来：日历里排最前并高亮。
        markCalendarNew(added.map(\.id))
        // 只保留最近 2400 条，避免长期使用无限增长（数据库按插入顺序淘汰）。
        if calendarItems.count > 2400 {
            calendarItems = Array(calendarItems.suffix(2400))
        }
        CatalogStore.pruneCalendar(limit: 2400)
        rebuildTodaySpotlight()
        return added.count
    }

    private func markCalendarNew(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var list = calendarNewIDs
        for id in ids where !list.contains(id) { list.append(id) }
        calendarNewIDs = Array(list.suffix(80))
        persistCalendarNewIDs()
    }

    private func persistCalendarNewIDs() {
        guard let data = try? JSONEncoder().encode(calendarNewIDs) else { return }
        CatalogStore.set(data, forKey: Self.calendarNewIDsKey)
    }

    /// 从标题 / 备注里解析站点写的日期（「2026-11-14」「10月26日」「11-16」），
    /// 让后台翻页补录时能落到真正的历史日期，而不是全部堆在今天。
    func parsedPublishDate(title: String, remark: String) -> Date? {
        let text = title + " " + remark
        let calendar = Calendar.current
        let now = Date()
        let upperBound = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let lowerBound = calendar.date(byAdding: .year, value: -3, to: now) ?? now

        if let range = text.range(of: catalogFullDatePattern, options: .regularExpression) {
            let parts = String(text[range])
                .components(separatedBy: CharacterSet(charactersIn: "-/.年月"))
            if parts.count == 3,
               let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
               let date = calendar.date(from: DateComponents(year: year, month: month,
                                                             day: day, hour: 12)),
               date <= upperBound, date >= lowerBound {
                return date
            }
        }

        if let range = text.range(of: catalogMonthDayPattern, options: .regularExpression) {
            // 「11-16 集」这种分集区间不算日期。
            let suffix = text[range.upperBound...].prefix(1)
            guard suffix != "集" else { return nil }
            let parts = String(text[range])
                .components(separatedBy: CharacterSet(charactersIn: "-/月"))
            if parts.count == 2,
               let month = Int(parts[0]), let day = Int(parts[1]),
               (1...12).contains(month), (1...31).contains(day) {
                let year = calendar.component(.year, from: now)
                if var date = calendar.date(from: DateComponents(year: year, month: month,
                                                                 day: day, hour: 12)) {
                    if date > upperBound {
                        date = calendar.date(byAdding: .year, value: -1, to: date) ?? date
                    }
                    if date >= lowerBound { return date }
                }
            }
        }
        return nil
    }

    func calendarCounts(in month: Date) -> [Date: Int] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [:] }
        var counts: [Date: Int] = [:]
        for entry in calendarItems where interval.contains(entry.firstSeen) {
            let day = calendar.startOfDay(for: entry.firstSeen)
            counts[day, default: 0] += 1
        }
        return counts
    }

    func calendarItems(on day: Date) -> [CatalogCalendarItem] {
        let calendar = Calendar.current
        return calendarItems
            .filter { calendar.isDate($0.firstSeen, inSameDayAs: day) }
            .sorted { $0.firstSeen > $1.firstSeen }
    }

    /// 记住日历选中了哪一天：下次进来直接回到这一天。
    func selectCalendarDay(_ day: Date?) {
        let value = day.map { Calendar.current.startOfDay(for: $0) }
        calendarSelectedDay = value
        if let value {
            CatalogStore.string(forKey: Self.calendarSelectedDayKey,
                                value: String(value.timeIntervalSince1970))
        } else {
            CatalogStore.string(forKey: Self.calendarSelectedDayKey, value: nil)
        }
    }

    /// 在后台慢慢补录：每轮逐源往下翻几页，走低优先通道，用户一加载就让路。
    /// 任务登记在统一任务中心：侧边栏任务条能看到进度、可取消，结束后进任务记录。
    /// 15 分钟内只跑一次，也可以手动强制刷新。
    /// - Parameter domain: 只补录这个域的源：网络资源与网络影院的日历各自抓取、各自节流。
    func refreshCalendarToday(force: Bool = false, domain: CatalogDomain = .networkResource) {
        if isCalendarRefreshing {
            if calendarScanDomain == domain, !force { return }
            // 手动刷新或换域扫描都不能被上一轮卡住：取消旧扫描，重新来一轮。
            calendarTask?.cancel()
            calendarTask = nil
            if let calendarJobID { jobCenter?.cancel(calendarJobID) }
            if let calendarJobID { onJobFinished?(calendarJobID) }
            isCalendarRefreshing = false
            calendarScanDomain = nil
        }
        let scanAtKey = Self.calendarScanStampKey(for: domain)
        let cursorBaseKey = Self.calendarCursorBaseKey(for: domain)
        if !force,
           let raw = CatalogStore.string(forKey: scanAtKey),
           let stamp = Double(raw),
           Date().timeIntervalSince1970 - stamp < 900 {
            return
        }
        let targets = enabledSources(in: domain)
        guard !targets.isEmpty, !isUserBusy else { return }
        // 新一轮补录：先清掉上一批高亮，稍后按本次真正补进来的条目重新标记。
        calendarNewIDs = []
        persistCalendarNewIDs()
        isCalendarRefreshing = true
        calendarScanDomain = domain
        // 日历要铺满历史：一轮每源最多翻 4 页（约 96 条），进度也才看得出推进。
        let pagesPerSource = 4
        let totalSteps = max(1, targets.count * pagesPerSource)
        let jobID = jobCenter?.begin(
            SourceJob(sourceID: domain == .networkCinema ? .networkCinema : .catalogHub,
                      kind: .sync,
                      title: domain == .networkCinema ? "补录影院日历" : "补录更新日历"),
            cancel: { [weak self] in
                Task { @MainActor in self?.calendarTask?.cancel() }
            }
        )
        calendarJobID = jobID
        onJobChange?()
        calendarTask = Task { [weak self] in
            var recorded = 0
            var step = 0
            var scannedSources = 0
            await CatalogRequestScope.$isBackground.withValue(true) {
                for (index, source) in targets.enumerated() {
                    guard let self, !Task.isCancelled else { return }
                    guard let provider = CatalogProviders.provider(for: source.kind) else {
                        step = (index + 1) * pagesPerSource
                        continue
                    }
                    // 每个源记住翻到第几页：下次接着往下翻，慢慢把历史补满。
                    let cursorKey = cursorBaseKey + "." + source.id.uuidString
                    var pageNumber = max(1, Int(CatalogStore.string(forKey: cursorKey) ?? "") ?? 1)
                    var sourceAdded = 0
                    var pagesRead = 0
                    for _ in 0..<pagesPerSource {
                        // 用户在等页面 / 搜索时让路：这一轮先停，下次从当前游标继续。
                        guard !Task.isCancelled, !self.isUserBusy else { break }
                        if let jobID {
                            self.jobCenter?.update(jobID,
                                                   completed: min(step, totalSteps),
                                                   total: totalSteps,
                                                   message: "\(source.name) · 第 \(pageNumber) 页")
                            self.onJobChange?()
                        }
                        guard let page = try? await provider.home(source: source, page: pageNumber),
                              !page.items.isEmpty else { break }
                        let added = self.recordCalendar(items: Array(page.items.prefix(24)),
                                                        sourceID: source.id)
                        recorded += added
                        sourceAdded += added
                        pagesRead += 1
                        step += 1
                        guard !Task.isCancelled else { return }
                        if page.hasMore {
                            pageNumber += 1
                            CatalogStore.string(forKey: cursorKey, value: String(pageNumber))
                        } else {
                            pageNumber = 1
                            CatalogStore.string(forKey: cursorKey, value: "1")
                            break
                        }
                        // 源内翻页留一点间隔，别和用户的操作抢连接。
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    if pagesRead == 0 {
                        CatalogStore.string(forKey: cursorKey, value: "1")
                    }
                    scannedSources += 1
                    step = (index + 1) * pagesPerSource
                    if let jobID {
                        self.jobCenter?.update(jobID,
                                               completed: min(step, totalSteps),
                                               total: totalSteps,
                                               message: sourceAdded > 0
                                                   ? "\(source.name) · 新增 \(sourceAdded) 条"
                                                   : "\(source.name) · 无新增")
                        self.onJobChange?()
                    }
                    // 源与源之间留一点间隔，别和用户的操作抢连接。
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            guard let self else { return }
            self.isCalendarRefreshing = false
            self.calendarScanDomain = nil
            if let jobID {
                if Task.isCancelled {
                    self.jobCenter?.cancel(jobID)
                } else {
                    self.jobCenter?.finish(jobID,
                                           message: "\(scannedSources) 个源 · 补录 \(recorded) 条")
                }
                self.onJobFinished?(jobID)
                self.onJobChange?()
            }
            guard !Task.isCancelled else { return }
            CatalogStore.string(forKey: scanAtKey,
                                value: String(Date().timeIntervalSince1970))
        }
    }

    /// 日历扫描的节流时间戳：两个域各自独立，互不影响。
    static func calendarScanStampKey(for domain: CatalogDomain) -> String {
        domain == .networkCinema
            ? "catalog.calendar.scanAt.cinema.v2"
            : calendarScanAtKey
    }

    /// 日历翻页游标前缀：两个域各自往后翻，互不覆盖。
    static func calendarCursorBaseKey(for domain: CatalogDomain) -> String {
        domain == .networkCinema
            ? "catalog.calendar.cursor.cinema.v2"
            : calendarCursorKey
    }

    // MARK: - 自定义片单

    @discardableResult
    func createPlaylist(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = CatalogPlaylist(id: UUID(),
                                       name: trimmed.isEmpty ? "未命名片单" : trimmed,
                                       entries: [],
                                       createdAt: Date())
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist.id
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id })
        else { return }
        playlists[index].name = trimmed
        savePlaylists()
    }

    func addToPlaylist(_ id: UUID, source: CatalogSource, item: CatalogItem) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let entryID = "\(source.id.uuidString)|\(item.id)"
        guard !playlists[index].entries.contains(where: { $0.id == entryID }) else {
            showNotice("已经在片单里了")
            return
        }
        playlists[index].entries.append(CatalogPlaylistEntry(sourceID: source.id,
                                                            itemID: item.id,
                                                            title: item.title,
                                                            coverURL: item.coverURL,
                                                            remark: item.remark,
                                                            addedAt: Date()))
        savePlaylists()
        showNotice("已加入「\(playlists[index].name)」")
    }

    /// 批量加入片单：跳过已经在片单里的条目，只弹一次提示。
    func addToPlaylist(_ id: UUID, source: CatalogSource, items: [CatalogItem]) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var existing = Set(playlists[index].entries.map(\.id))
        var added = 0
        for item in items {
            let entryID = "\(source.id.uuidString)|\(item.id)"
            guard existing.insert(entryID).inserted else { continue }
            playlists[index].entries.append(CatalogPlaylistEntry(sourceID: source.id,
                                                                itemID: item.id,
                                                                title: item.title,
                                                                coverURL: item.coverURL,
                                                                remark: item.remark,
                                                                addedAt: Date()))
            added += 1
        }
        guard added > 0 else {
            showNotice("这些条目已经在片单里了")
            return
        }
        savePlaylists()
        showNotice("已把 \(added) 条加入「\(playlists[index].name)」")
    }

    func isInPlaylist(_ id: UUID, sourceID: UUID, itemID: String) -> Bool {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return false }
        return playlist.entries.contains { $0.sourceID == sourceID && $0.itemID == itemID }
    }

    func removePlaylistEntry(playlistID: UUID, entryID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].entries.removeAll { $0.id == entryID }
        savePlaylists()
    }

    func movePlaylistEntry(playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].entries.move(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }

    /// 整单连播：把片单里每部的第一集拼进同一个查看器会话。
    func playPlaylist(_ id: UUID) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        guard !playlist.entries.isEmpty else {
            showNotice("片单还是空的")
            return
        }
        let pairs: [(source: CatalogSource, item: CatalogItem)] = playlist.entries
            .prefix(12)
            .compactMap { entry in
                guard let source = sources.first(where: { $0.id == entry.sourceID }) else { return nil }
                return (source, entry.item)
            }
        enqueuePlayback(pairs, emptyMessage: "片单里的内容暂时都解析失败")
    }

    /// 把一组条目逐条补详情后交给查看器；聚合片单与手动片单共用。
    private func enqueuePlayback(_ pairs: [(source: CatalogSource, item: CatalogItem)],
                                 emptyMessage: String) {
        guard let handler = onPlaylistPlayback else { return }
        guard !pairs.isEmpty else {
            showNotice(emptyMessage)
            return
        }
        showNotice("正在准备 \(pairs.count) 部…")
        Task { [weak self] in
            var queue: [CatalogPlaylistPlaybackItem] = []
            for pair in pairs {
                guard let provider = CatalogProviders.provider(for: pair.source.kind) else { continue }
                guard let detail = try? await provider.detail(source: pair.source,
                                                              itemID: pair.item.id),
                      let episode = detail.episodes.first else { continue }
                var item = detail.item
                if item.title.isEmpty { item.title = pair.item.title }
                if item.coverURL.isEmpty { item.coverURL = pair.item.coverURL }
                queue.append(CatalogPlaylistPlaybackItem(source: pair.source,
                                                         item: item,
                                                         episode: episode))
            }
            guard let self else { return }
            guard !queue.isEmpty else {
                self.showNotice(emptyMessage)
                return
            }
            handler(queue)
        }
    }

    func setPlaylistCover(playlistID: UUID, coverURL: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].coverURL = coverURL
        savePlaylists()
    }

    /// 片单封面的有效地址：优先手选，其次第一条。
    func playlistCover(_ playlist: CatalogPlaylist) -> String {
        playlist.coverURL ?? playlist.entries.first?.coverURL ?? ""
    }

    // MARK: - 网络资源分页

    func setHubTab(_ tab: CatalogHubTab) {
        guard hubTab != tab else { return }
        hubTab = tab
        CatalogStore.string(forKey: Self.hubTabKey, value: tab.rawValue)
    }

    // MARK: - 聚合片单

    @discardableResult
    func createSmartPlaylist(name: String, query: String) -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = CatalogSmartPlaylist(
            id: UUID(),
            name: trimmedName.isEmpty ? trimmedQuery : trimmedName,
            query: trimmedQuery,
            createdAt: Date())
        smartPlaylists.insert(playlist, at: 0)
        saveSmartPlaylists()
        refreshSmartPlaylist(playlist.id)
        return playlist.id
    }

    func deleteSmartPlaylist(_ id: UUID) {
        smartPlaylists.removeAll { $0.id == id }
        smartResults[id] = nil
        smartNewIDs[id] = nil
        smartLoading.remove(id)
        saveSmartPlaylists()
        saveSmartResults()
        saveSmartNewIDs()
    }

    func renameSmartPlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = smartPlaylists.firstIndex(where: { $0.id == id }) else { return }
        smartPlaylists[index].name = trimmed
        saveSmartPlaylists()
    }

    /// 重新聚合：解析查询里的关键字与条件，跨源检索后按匹配度排序。
    func refreshSmartPlaylist(_ id: UUID) {
        guard let playlist = smartPlaylists.first(where: { $0.id == id }),
              !smartLoading.contains(id) else { return }
        let query = playlist.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            smartResults[id] = []
            return
        }
        let plan = CatalogQueryPlan.parse(query)
        let keyword = plan.keyword.isEmpty ? query : plan.keyword
        // 默认展示历史：先拿上一次结果当基线，刷新后再对比出新增。
        let previousKeys = Set(smartResults[id]?.flatMap { group in
            group.items.map { "\(group.sourceID.uuidString)|\($0.id)" }
        } ?? [])
        smartLoading.insert(id)
        // 聚合也算一次后台检索：登记到统一任务记录，刷新时左下角能看到进度与结果。
        let jobCenter = self.jobCenter
        let jobID = jobCenter?.begin(
            SourceJob(sourceID: .catalogHub,
                      kind: .search,
                      title: "聚合片单「\(playlist.name)」",
                      isCancellable: false)
        )
        onJobChange?()
        Task { [weak self] in
            let results = await self?.crossSourceSearch(keyword: keyword, plan: plan) ?? []
            guard let self else {
                if let jobID { jobCenter?.finish(jobID) }
                return
            }
            let keys = results.flatMap { group in
                group.items.map { "\(group.sourceID.uuidString)|\($0.id)" }
            }
            let newIDs = previousKeys.isEmpty ? [] : keys.filter { !previousKeys.contains($0) }
            self.smartResults[id] = Self.orderedGroups(results, newIDs: Set(newIDs))
            self.smartNewIDs[id] = newIDs
            self.smartLoading.remove(id)
            self.saveSmartResults()
            self.saveSmartNewIDs()
            if let jobID {
                jobCenter?.finish(jobID,
                                  message: keys.isEmpty ? "没有匹配结果" : "聚合到 \(keys.count) 条")
                self.onJobChange?()
            }
        }
    }

    func smartPlaylistCount(_ id: UUID) -> Int {
        smartResults[id]?.reduce(0) { $0 + $1.items.count } ?? 0
    }

    /// 聚合片单整单连播：各源结果交替取，最多 12 部。
    func playSmartPlaylist(_ id: UUID) {
        guard let groups = smartResults[id], !groups.isEmpty else {
            showNotice("这个聚合片单还没有结果")
            return
        }
        var pairs: [(source: CatalogSource, item: CatalogItem)] = []
        var index = 0
        while pairs.count < 12 {
            var appended = false
            for group in groups {
                guard index < group.items.count else { continue }
                guard let source = sources.first(where: { $0.id == group.sourceID }) else { continue }
                pairs.append((source, group.items[index]))
                appended = true
                if pairs.count >= 12 { break }
            }
            if !appended { break }
            index += 1
        }
        enqueuePlayback(pairs, emptyMessage: "聚合片单里的内容暂时都解析失败")
    }

    // MARK: - 人物档案

    func isFollowingPerson(name: String, role: String) -> Bool {
        !followPersonIndices(name: name, role: role).isEmpty
    }

    /// 关注记录的匹配键：只取括号外的主名再归一化。
    /// 历史记录里可能存成「高宫菜菜子 (高宫菜々子)」，直接比整串会永远匹配不上。
    private func followPersonKey(_ name: String) -> String {
        CatalogNameParser.normalize(CatalogNameParser.splitAliases(name).primary)
    }

    private func followPersonIndices(name: String, role: String) -> [Int] {
        let key = followPersonKey(name)
        let sameName = followedPeople.indices.filter { followPersonKey(followedPeople[$0].name) == key }
        let sameRole = sameName.filter { followedPeople[$0].role == role }
        return sameRole.isEmpty ? sameName : sameRole
    }

    private func followPersonIndex(name: String, role: String) -> Int? {
        followPersonIndices(name: name, role: role).first
    }

    /// 关注页与工具栏角标用：所有关注人物累计的新增条数。
    var newFollowCount: Int {
        followedPeople.reduce(0) { $0 + max(0, $1.newCount) }
    }

    /// 关注分类的封面：复用侧边栏已经补好的分类缩略图。
    func categoryThumb(sourceID: UUID, categoryID: String) -> String? {
        categoryThumbs["\(sourceID.uuidString)|\(categoryID)"]
    }

    func toggleFollowPerson(name: String, role: String, sourceID: UUID) {
        // 取消关注：按主名匹配并一次清掉所有重复记录，
        // 这样历史库里「带别名 / 不带别名」的两条也能被同一个按钮清干净。
        let indices = followPersonIndices(name: name, role: role)
        if !indices.isEmpty {
            let removedIDs = Set(indices.map { followedPeople[$0].id })
            let removedKey = followPersonKey(name)
            followedPeople.removeAll { removedIDs.contains($0.id) }
            for id in removedIDs {
                followPosters[id] = nil
            }
            followAggregates = followAggregates.filter {
                followPersonKey($0.value.name) != removedKey
            }
            persistFollowPosters()
            persistFollowAggregates()
            savePeople()
            return
        }

        // 新增：关注时落到资料库里的标准名：括号别名、々 / 繁简写法先归一，
        // 以后刷新、查新、打开档案都能命中同一条记录。
        let split = CatalogNameParser.splitAliases(name)
        let canonical: String
        if role.contains("片商") {
            canonical = CatalogNameDictionary.studio(matching: split.primary)?.name ?? split.primary
        } else {
            canonical = CatalogNameDictionary.actress(matching: split.primary)?.name ?? split.primary
        }
        let keys = personProfile?.groups.flatMap { group in
            group.items.map { "\(group.sourceID.uuidString)|\($0.id)" }
        } ?? []
        followedPeople.append(CatalogFollowedPerson(name: canonical, role: role,
                                                    sourceID: sourceID,
                                                    seenIDs: keys, newCount: 0,
                                                    addedAt: Date()))
        // 关注的人名（连同括号里的别名）进识别词典：之后标题里出现也能标出来。
        CatalogNameParser.learn(names: [canonical] + split.aliases)
        savePeople()
    }

    /// 关注人物的聚合快照键：只按「角色 + 归一化名字」区分，从详情页 / 关注页进来都能命中同一份。
    private func followAggregateKey(name: String, role: String) -> String {
        "\(role)|\(CatalogNameParser.normalize(name))"
    }

    /// 打开人物档案：先铺上次聚合的历史，再跨源刷新；新条目排最前并高亮。
    func openPersonProfile(name: String, role: String, sourceID: UUID) {
        // 「高宫菜菜子 (高宫菜々子)」这类写法只用主名去搜，括号里的别名当补充关键词。
        let split = CatalogNameParser.splitAliases(name)
        let trimmed = split.primary
        guard !trimmed.isEmpty else { return }
        let aliasTerms = split.aliases
        let normalizeKey = CatalogNameParser.normalize(trimmed)
        let aggregateKey = followAggregateKey(name: trimmed, role: role)
        let cached = followAggregates[aggregateKey]

        // 1. 默认展示历史：有快照立刻铺开，不再先给一块空白等网络。
        if let cached, !cached.groups.isEmpty {
            personProfile = CatalogPersonProfile(name: trimmed, role: role, sourceID: sourceID,
                                                 groups: cached.groups,
                                                 timeline: Self.timeline(from: cached.groups),
                                                 newCount: 0,
                                                 newItemIDs: [],
                                                 fetchedAt: cached.updatedAt)
        } else {
            personProfile = CatalogPersonProfile(name: trimmed, role: role, sourceID: sourceID,
                                                 groups: [], timeline: [], newCount: 0,
                                                 fetchedAt: Date())
        }
        isPersonLoading = true

        Task { [weak self] in
            var groups: [CatalogGlobalResult] = []
            // 人物资料库属于网络资源：只在网页资源站里聚合，影视源不参与。
            for source in (self?.enabledResourceSources ?? []) {
                guard let provider = CatalogProviders.provider(for: source.kind) else { continue }
                guard let page = try? await provider.search(source: source,
                                                           keyword: trimmed, page: 1),
                      !page.items.isEmpty else { continue }
                // 搜索常常是模糊匹配：名字（或括号里的别名）没出现在标题里的先剔掉。
                let hits = page.items.filter { item in
                    let text = item.title + " " + item.remark
                    if text.localizedCaseInsensitiveContains(trimmed) { return true }
                    let key = CatalogNameParser.normalize(text)
                    return key.contains(normalizeKey)
                        || aliasTerms.contains {
                            !$0.isEmpty && text.localizedCaseInsensitiveContains($0)
                        }
                }
                let items = Array((hits.isEmpty ? page.items : hits).prefix(18))
                guard !items.isEmpty else { continue }
                groups.append(CatalogGlobalResult(sourceID: source.id,
                                                  sourceName: source.name,
                                                  items: items))
            }
            guard let self else { return }

            // 新条目基线：上一份快照优先；没有快照时退回已读集合。
            // 第一次完全没有基线就只当基线，不把整页都标成「新」。
            let cachedKeys = Set(cached?.groups.flatMap { group in
                group.items.map { "\(group.sourceID.uuidString)|\($0.id)" }
            } ?? [])
            let seenKeys = Set(self.followPersonIndex(name: trimmed, role: role)
                .map { self.followedPeople[$0].seenIDs } ?? [])
            let baseline = cachedKeys.isEmpty ? seenKeys : cachedKeys
            let keys = groups.flatMap { group in
                group.items.map { "\(group.sourceID.uuidString)|\($0.id)" }
            }
            let newIDs = baseline.isEmpty ? [] : keys.filter { !baseline.contains($0) }

            // 2. 新条目排最前：组内新片在前，有新增的来源整体也靠前。
            let ordered = Self.orderedGroups(groups, newIDs: Set(newIDs))

            if let index = self.followPersonIndex(name: trimmed, role: role) {
                self.followedPeople[index].seenIDs = Array(Set(self.followedPeople[index].seenIDs)
                    .union(keys))
                self.followedPeople[index].newCount = 0
                self.savePeople()

                // 聚合一完成就把封面墙存下来：返回关注页仍然是 4 宫格。
                var covers: [CatalogFollowPoster] = []
                for group in ordered {
                    for item in group.items where !item.coverURL.isEmpty {
                        covers.append(CatalogFollowPoster(sourceID: group.sourceID,
                                                          coverURL: item.coverURL,
                                                          title: item.title))
                        if covers.count >= 4 { break }
                    }
                    if covers.count >= 4 { break }
                }
                if !covers.isEmpty {
                    self.followPosters[self.followedPeople[index].id] = covers
                    self.persistFollowPosters()
                }
            }

            // 3. 聚合结果入库：下次进来先看历史，不用等网络。
            self.followAggregates[aggregateKey] = CatalogFollowAggregate(personKey: aggregateKey,
                                                                         name: trimmed,
                                                                         role: role,
                                                                         groups: groups,
                                                                         newIDs: newIDs,
                                                                         updatedAt: Date())
            self.persistFollowAggregates()

            self.personProfile = CatalogPersonProfile(name: trimmed, role: role,
                                                      sourceID: sourceID, groups: ordered,
                                                      timeline: Self.timeline(from: ordered),
                                                      newCount: newIDs.count,
                                                      newItemIDs: newIDs,
                                                      fetchedAt: Date())
            self.isPersonLoading = false
        }
    }

    private static func timeline(from groups: [CatalogGlobalResult]) -> [CatalogSpotlightItem] {
        groups.flatMap { group in
            group.items.map {
                CatalogSpotlightItem(sourceID: group.sourceID,
                                     sourceName: group.sourceName,
                                     item: $0)
            }
        }
        .sorted { year(of: $1.item) > year(of: $0.item) }
    }

    /// 组的先后保持各源在侧边栏里的上下顺序，只把组内新条目提到最前。
    private static func orderedGroups(_ groups: [CatalogGlobalResult],
                                      newIDs: Set<String>) -> [CatalogGlobalResult] {
        groups.map { group in
            let isNew = { (item: CatalogItem) in
                newIDs.contains("\(group.sourceID.uuidString)|\(item.id)")
            }
            let fresh = group.items.filter(isNew)
            let old = group.items.filter { !isNew($0) }
            return CatalogGlobalResult(sourceID: group.sourceID,
                                       sourceName: group.sourceName,
                                       items: fresh + old)
        }
    }

    func closePersonProfile() {
        personProfile = nil
        isPersonLoading = false
    }

    /// 总览页刷新时顺带查关注的人有没有新片：只打关注时所在的那个源，最多 8 个。
    func refreshFollowedPeople() {
        guard !followedPeople.isEmpty else { return }
        Task { [weak self] in
            for person in (self?.followedPeople.prefix(8) ?? []) {
                // 没有已读基线（例如刚从资料库关注、还没打开过档案）就先不提醒，
                // 否则第一次刷新会把已有作品全算成「新片」。
                guard !person.seenIDs.isEmpty else { continue }
                guard let self,
                      let source = self.resourceSources.first(where: { $0.id == person.sourceID }),
                      let provider = CatalogProviders.provider(for: source.kind) else { continue }
                guard let page = try? await provider.search(source: source,
                                                           keyword: person.name, page: 1)
                else { continue }
                let fresh = page.items.filter {
                    ($0.title + " " + $0.remark).localizedCaseInsensitiveContains(person.name)
                }
                let seen = Set(person.seenIDs)
                let newCount = fresh.filter { !seen.contains("\(source.id.uuidString)|\($0.id)") }.count
                guard let index = self.followedPeople.firstIndex(where: { $0.id == person.id }),
                      self.followedPeople[index].newCount != newCount else { continue }
                self.followedPeople[index].newCount = newCount
                self.savePeople()
            }
        }
    }

    /// 关注页封面墙：跨源聚合每个人最新的 4 张封面，结果缓存并持久化。
    /// 打开过档案的人直接复用档案里的分组，不再重复请求。
    func refreshFollowPosters(force: Bool = false) {
        guard !followedPeople.isEmpty else { return }
        let pending = followedPeople.filter {
            // 查过就记一条（哪怕是空数组），下次进关注页不再重复打站点。
            force || followPosters[$0.id] == nil
        }
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for person in pending.prefix(8) {
                guard let self, !Task.isCancelled else { return }
                var covers: [CatalogFollowPoster] = []
                var seen = Set<String>()

                // 1. 已经有聚合快照（或正开着这个人的档案）：直接借用封面。
                let aggregate = self.followAggregates.values.first {
                    $0.role == person.role
                        && CatalogNameParser.normalize($0.name)
                        == CatalogNameParser.normalize(person.name)
                }
                let cachedGroups: [CatalogGlobalResult] = aggregate?.groups
                    ?? (self.personProfile.flatMap { profile in
                        CatalogNameParser.normalize(profile.name)
                            == CatalogNameParser.normalize(person.name) ? profile.groups : nil
                    } ?? [])
                for group in cachedGroups {
                    for item in group.items where !item.coverURL.isEmpty {
                        guard seen.insert(item.coverURL).inserted else { continue }
                        covers.append(CatalogFollowPoster(sourceID: group.sourceID,
                                                          coverURL: item.coverURL,
                                                          title: item.title))
                        if covers.count >= 4 { break }
                    }
                    if covers.count >= 4 { break }
                }

                // 2. 没有档案就跨源搜一次，名字 / 括号别名命中且带封面的才算。
                if covers.count < 4 {
                    let aliases = CatalogNameParser.splitAliases(person.name).aliases
                    for source in self.enabledResourceSources {
                        guard let provider = CatalogProviders.provider(for: source.kind),
                              let page = try? await provider.search(source: source,
                                                                    keyword: person.name,
                                                                    page: 1),
                              !page.items.isEmpty else { continue }
                        for item in page.items where !item.coverURL.isEmpty {
                            guard Self.personPosterMatches(item: item,
                                                           name: person.name,
                                                           aliases: aliases) else { continue }
                            guard seen.insert(item.coverURL).inserted else { continue }
                            covers.append(CatalogFollowPoster(sourceID: source.id,
                                                              coverURL: item.coverURL,
                                                              title: item.title))
                            if covers.count >= 4 { break }
                        }
                        if covers.count >= 4 { break }
                    }
                }

                guard !Task.isCancelled else { return }
                self.followPosters[person.id] = covers
            }
            self?.persistFollowPosters()
        }
    }

    private static func personPosterMatches(item: CatalogItem,
                                            name: String,
                                            aliases: [String]) -> Bool {
        let text = item.title + " " + item.remark
        if text.localizedCaseInsensitiveContains(name) { return true }
        if aliases.contains(where: { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let key = CatalogNameParser.normalize(text)
        let target = CatalogNameParser.normalize(name)
        return !target.isEmpty && key.contains(target)
    }

    private func persistFollowPosters() {
        guard let data = try? JSONEncoder().encode(followPosters) else { return }
        CatalogStore.set(data, forKey: Self.followPostersKey)
    }

    private func persistFollowAggregates() {
        guard let data = try? JSONEncoder().encode(followAggregates) else { return }
        CatalogStore.set(data, forKey: Self.followAggregatesKey)
    }

    private static func year(of item: CatalogItem) -> Int {
        CatalogQueryPlan.year(in: item.title + " " + item.remark) ?? 0
    }

    // MARK: - 持久化

    func loadDiscovery() {
        if let raw = CatalogStore.string(forKey: Self.spotlightModeKey),
           let mode = CatalogSpotlightMode(rawValue: raw) {
            spotlightMode = mode
        }
        if let data = CatalogStore.data(forKey: Self.discoveryPinsKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            pinnedSourceIDs = ids
        }
        if let data = CatalogStore.data(forKey: Self.categoryPinsKey),
           let pins = try? JSONDecoder().decode([UUID: [String]].self, from: data) {
            pinnedCategoryIDs = pins
        }
        if let data = CatalogStore.data(forKey: Self.followsKey),
           let items = try? JSONDecoder().decode([CatalogFollowedCategory].self, from: data) {
            followedCategories = items
        }
        if let data = CatalogStore.data(forKey: Self.lastSeenTopKey),
           let seen = try? JSONDecoder().decode([UUID: String].self, from: data) {
            lastSeenTop = seen
        }
        if let data = CatalogStore.data(forKey: Self.newFlagsKey),
           let flags = try? JSONDecoder().decode([UUID].self, from: data) {
            newSourceIDs = Set(flags)
        }
        calendarItems = CatalogStore.loadCalendar()
        if let data = CatalogStore.data(forKey: Self.calendarNewIDsKey),
           let cached = try? JSONDecoder().decode([String].self, from: data) {
            calendarNewIDs = cached
        }
        if CatalogStore.string(forKey: Self.calendarDateParseKey) == nil {
            // 旧版都把条目记成「看到的那一刻」；用标题 / 备注里的日期回填一次。
            var changed = false
            calendarItems = calendarItems.map { entry in
                guard let date = parsedPublishDate(title: entry.title, remark: entry.remark),
                      !Calendar.current.isDate(date, inSameDayAs: entry.firstSeen) else {
                    return entry
                }
                var copy = entry
                copy.firstSeen = date
                changed = true
                return copy
            }
            if changed { CatalogStore.replaceCalendar(calendarItems) }
            CatalogStore.string(forKey: Self.calendarDateParseKey, value: "1")
        }
        rebuildTodaySpotlight()
        if let raw = CatalogStore.string(forKey: Self.calendarSelectedDayKey),
           let stamp = Double(raw) {
            calendarSelectedDay = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: stamp))
        }
        if let data = CatalogStore.data(forKey: Self.playlistsKey),
           let items = try? JSONDecoder().decode([CatalogPlaylist].self, from: data) {
            playlists = items
        }
        if let data = CatalogStore.data(forKey: Self.smartPlaylistsKey),
           let items = try? JSONDecoder().decode([CatalogSmartPlaylist].self, from: data) {
            smartPlaylists = items
        }
        if let data = CatalogStore.data(forKey: Self.peopleKey),
           let items = try? JSONDecoder().decode([CatalogFollowedPerson].self, from: data) {
            // 旧版本取消关注会漏删、再点一次就多出一条重复记录；
            // 加载时按「主名」合并，关注页不再出现两个同名人物。
            var merged: [CatalogFollowedPerson] = []
            var indexByKey: [String: Int] = [:]
            for person in items {
                let key = followPersonKey(person.name) + "|" + person.role
                if let index = indexByKey[key] {
                    var kept = merged[index]
                    kept.seenIDs = Array(Set(kept.seenIDs).union(person.seenIDs))
                    kept.newCount = max(kept.newCount, person.newCount)
                    if person.name.count > kept.name.count { kept.name = person.name }
                    merged[index] = kept
                } else {
                    indexByKey[key] = merged.count
                    merged.append(person)
                }
            }
            followedPeople = merged
            if merged.count != items.count { savePeople() }
        }
        if let data = CatalogStore.data(forKey: Self.followPostersKey),
           let map = try? JSONDecoder().decode([String: [CatalogFollowPoster]].self, from: data) {
            followPosters = map
        }
        if let data = CatalogStore.data(forKey: Self.followAggregatesKey),
           let map = try? JSONDecoder().decode([String: CatalogFollowAggregate].self, from: data) {
            followAggregates = map
        }
        if let data = CatalogStore.data(forKey: Self.recentSearchesKey),
           let items = try? JSONDecoder().decode([String].self, from: data) {
            recentSearches = items
        }
    }

    private func savePins() {
        guard let data = try? JSONEncoder().encode(pinnedSourceIDs) else { return }
        CatalogStore.set(data, forKey: Self.discoveryPinsKey)
    }

    private func saveCategoryPins() {
        guard let data = try? JSONEncoder().encode(pinnedCategoryIDs) else { return }
        CatalogStore.set(data, forKey: Self.categoryPinsKey)
    }

    private func saveFollows() {
        guard let data = try? JSONEncoder().encode(followedCategories) else { return }
        CatalogStore.set(data, forKey: Self.followsKey)
    }

    private func saveLastSeen() {
        guard let data = try? JSONEncoder().encode(lastSeenTop) else { return }
        CatalogStore.set(data, forKey: Self.lastSeenTopKey)
    }

    private func saveNewFlags() {
        guard let data = try? JSONEncoder().encode(Array(newSourceIDs)) else { return }
        CatalogStore.set(data, forKey: Self.newFlagsKey)
    }

    private func savePlaylists() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        CatalogStore.set(data, forKey: Self.playlistsKey)
    }

    private func savePeople() {
        guard let data = try? JSONEncoder().encode(followedPeople) else { return }
        CatalogStore.set(data, forKey: Self.peopleKey)
    }

    private func saveSmartPlaylists() {
        guard let data = try? JSONEncoder().encode(smartPlaylists) else { return }
        CatalogStore.set(data, forKey: Self.smartPlaylistsKey)
    }

    private func saveSmartResults() {
        guard let data = try? JSONEncoder().encode(smartResults) else { return }
        CatalogStore.set(data, forKey: Self.smartResultsKey)
    }

    private func saveSmartNewIDs() {
        guard let data = try? JSONEncoder().encode(smartNewIDs) else { return }
        CatalogStore.set(data, forKey: Self.smartNewIDsKey)
    }
}

/// 完整日期：2026-11-14 / 2026.11.14 / 2026年11月14日。
private let catalogFullDatePattern = #"\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}"#
/// 月日：11-16 / 10/26 / 10月26（排除 7.9 这类评分）。
private let catalogMonthDayPattern = #"(?<![\d.])\d{1,2}[-/月]\d{1,2}(?![\d.])"#
