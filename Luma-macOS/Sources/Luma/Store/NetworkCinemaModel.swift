import Foundation
import Combine
import LumaContentCore

/// 网络影院的数据：把已启用的影视源（苹果CMS）聚合到电影 / 电视剧 / 最近更新三页，
/// 再用 TMDB 补齐海报、评分与简介。只读网络源，不改动「网络存储」的影院数据。
@MainActor
final class NetworkCinemaModel: ObservableObject {
    @Published private(set) var items: [NetworkCinemaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedAt: Date?
    /// TMDB 补全进度：nil 表示没在补全。
    @Published private(set) var enrichmentProgress: (done: Int, total: Int)?
    /// key = 归一化标题 + 电影/剧集，跨分页、跨来源共用。
    @Published private(set) var enrichments: [String: NetworkCinemaEnrichment] = [:]
    /// TMDB 详情（演职员 / 片长 / 分级）缓存，按 tmdbID + 类型。
    @Published private(set) var cinemaDetails: [String: CinemaDetails] = [:]
    /// 豆瓣评分缓存，按条目缓存键。
    @Published private(set) var doubanRatings: [String: Double] = [:]
    /// 搜索结果：与当前分页独立，页面上用关键词结果替换主列表。
    @Published private(set) var searchItems: [NetworkCinemaItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    /// 下滑翻页：当前分页还有没有下一页、以及正在补页的状态。
    @Published private(set) var canLoadMore = false
    @Published private(set) var isLoadingMore = false
    /// 本次刷新新出现的条目：与上次同一列表比对，卡片上打「刚上架 / 更新中」。
    @Published private(set) var freshItemKeys: Set<String> = []

    /// 统一任务中心：列表探测、资料补全、跨源搜索都登记在这里，左下角任务条可见。
    var jobCenter: SourceJobCenter?
    /// 任务进度变化时通知外层刷新任务条。
    var onJobChange: (() -> Void)?
    /// 任务结束时把记录写进持久化历史，由 `LibraryStore` 注入。
    var onJobFinished: ((UUID) -> Void)?

    /// 同名影片的全部来源：主列表按标题只留一条，但播放源切换需要别的源上的同一部片。
    /// key = 归一化标题 + 电影/剧集。
    @Published private(set) var variants: [String: [NetworkCinemaItem]] = [:]

    private var misses = Set<String>()
    private var loadToken = 0
    private var searchToken = 0
    /// 资料补全单独一套令牌：取消补全不影响已经加载好的列表。
    private var enrichToken = 0
    private var reloadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadJobID: UUID?
    private var searchJobID: UUID?
    private var enrichJobID: UUID?
    /// 下滑翻页：每个分页保留「哪些源的哪个分类翻到第几页」，滚动到底时接着往下拉。
    private struct FeedStream {
        var source: CatalogSource
        /// nil 表示站点没有电影 / 电视剧分类，退回首页按页翻。
        var category: CatalogCategory?
        var nextPage: Int
        var exhausted: Bool
    }
    private var streams: [NetworkCinemaTab: [FeedStream]] = [:]
    /// 点开具体源后按站点原始分类浏览：列表来自这一条分类流，不再走聚合快照。
    private(set) var focusedSourceID: UUID?
    private(set) var focusedCategoryID: String?
    private var focusedStream: FeedStream?
    private var focusedCacheKey: String?
    /// 具体源各分类上次见过的条目 id：用来判断这次刷新哪些是新增。
    private var focusedSeenIDs: [String: Set<String>] = [:]
    /// 源内真实搜索：关键词非 nil 时列表展示站点搜索结果，而不是分类页。
    @Published private(set) var sourceSearchKeyword: String?
    @Published private(set) var isSourceSearching = false
    @Published private(set) var sourceSearchError: String?
    private var sourceSearchSource: CatalogSource?
    private var sourceSearchPage = 1
    private var sourceSearchHasMore = false
    private var sourceSearchTask: Task<Void, Never>?
    private var sourceSearchToken = 0
    /// 进入搜索前的分类列表：清空搜索后原样恢复，不重复打接口。
    private var savedFocusedItems: [NetworkCinemaItem] = []
    private var savedFocusedCanLoadMore = false
    private var savedFocusedStream: FeedStream?
    private var loadMoreTask: Task<Void, Never>?
    private var loadMoreToken = 0
    private var detailLoading = Set<String>()
    private var doubanLoading = Set<String>()
    /// 每个分页最近一次的快照：重新进入或切换分页时立刻有内容，再后台刷新。
    private var snapshots: [NetworkCinemaTab: NetworkCinemaListSnapshot] = [:]
    /// 快照多久算新：这个时间内直接用缓存，不重复打网络。
    private static let refreshInterval: TimeInterval = 10 * 60
    private static let cacheKey = "networkCinema.enrich.v1"
    /// 一次最多补全多少条：首页之外的条目等滚动 / 再次进入时补，避免一次打几百个 TMDB 请求。
    private static let enrichmentLimit = 48

    init() {
        loadCache()
        for tab in NetworkCinemaTab.allCases where tab.browsesContent {
            snapshots[tab] = NetworkCinemaSnapshotStore.load(tab: tab)
        }
    }

    func enrichment(for item: NetworkCinemaItem) -> NetworkCinemaEnrichment? {
        enrichments[item.enrichmentKey]
    }

    /// 这条是不是本次刷新才出现的：卡片据此打「刚上架 / 更新中」。
    func isFresh(_ entry: NetworkCinemaItem) -> Bool {
        freshItemKeys.contains(Self.freshKey(sourceID: entry.source.id, itemID: entry.item.id))
    }

    private static func freshKey(sourceID: UUID, itemID: String) -> String {
        "\(sourceID.uuidString)|\(itemID)"
    }

    /// 当前列表是不是站点搜索结果（非分类浏览）。
    var isSourceSearchActive: Bool { sourceSearchKeyword != nil }

    /// 同一部片在哪些源上有：详情页据此给出「播放源 / 线路」。
    /// 顺序保持加载顺序，当前条目一定在第一位。
    func sources(for item: NetworkCinemaItem) -> [NetworkCinemaItem] {
        let key = item.enrichmentKey
        guard let list = variants[key], !list.isEmpty else { return [item] }
        var ordered = list
        if let index = ordered.firstIndex(where: {
            $0.source.id == item.source.id && $0.item.id == item.item.id
        }) {
            ordered.swapAt(0, index)
        }
        return ordered
    }

    /// 按详情页引用（`sourceUUID|itemID`）找回条目：资料补全与详情页共用同一键。
    func item(refID: String) -> NetworkCinemaItem? {
        if let hit = (items + searchItems).first(where: { $0.id == refID }) { return hit }
        for list in variants.values {
            if let hit = list.first(where: { $0.id == refID }) { return hit }
        }
        return nil
    }

    /// 同名条目合并后的来源数量：卡片据此标「N 源」。
    func sourceCount(for item: NetworkCinemaItem) -> Int {
        max(1, variants[item.enrichmentKey]?.count ?? 1)
    }

    /// 同一部片在哪些源上有（去重后的源名），用于卡片提示。
    func sourceNames(for item: NetworkCinemaItem) -> [String] {
        guard let list = variants[item.enrichmentKey], list.count > 1 else {
            return [item.source.name]
        }
        var names: [String] = []
        for entry in list where !names.contains(entry.source.name) {
            names.append(entry.source.name)
        }
        return names
    }

    /// 已合并的同名条目组数：电影 / 电视剧页据此说明聚合结果。
    var mergedTitleCount: Int {
        variants.values.filter { $0.count > 1 }.count
    }

    /// 已缓存的豆瓣评分：资料补全器只读缓存，不在详情页额外发请求。
    func cachedDoubanRating(for item: NetworkCinemaItem) -> Double? {
        doubanRatings[item.enrichmentKey]
    }

    /// 把一轮加载到的条目登记进 variants：同名只保留主列表一条，但其他源全部留档。
    private func indexVariants(_ items: [NetworkCinemaItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            var list = variants[item.enrichmentKey] ?? []
            guard !list.contains(where: {
                $0.source.id == item.source.id && $0.item.id == item.item.id
            }) else { continue }
            list.append(item)
            variants[item.enrichmentKey] = list
        }
    }

    /// 重新聚合并按需补全 TMDB 资料。
    /// 任务在模型里跑，离开页面不会中断，进度会出现在左下角任务条。
    /// - Parameter force: 用户点「刷新」时传 true；页面进入 / 切分页走缓存优先。
    func reload(sources: [CatalogSource],
                tab: NetworkCinemaTab,
                tmdb: TMDBClient?,
                force: Bool = false) {
        // 回到聚合页：具体源的原始分类浏览状态作废。
        focusedSourceID = nil
        focusedCategoryID = nil
        focusedStream = nil
        focusedCacheKey = nil
        discardFocusedSearch()
        freshItemKeys = []
        // 管理 / 榜单 / 日历 / 足迹 / 关注 不拉列表，避免切分页时白打一轮网络。
        guard tab.browsesContent else {
            isLoading = false
            return
        }
        let usable = sources.filter { $0.isEnabled && $0.kind.supportsNetworkCinema }
        let signature = Self.sourceSignature(usable)

        // 1) 先用快照铺满：切分页 / 重新进入立刻有内容，不再白屏等网络。
        var snapshotIsFresh = false
        if let snapshot = snapshots[tab], snapshot.sourceSignature == signature {
            if items != snapshot.items { items = snapshot.items }
            variants.removeAll()
            // 快照里带了同名来源就还原：否则从去重后的列表反推，聚合徽标会整片消失。
            if let saved = snapshot.variants, !saved.isEmpty {
                variants = saved
            } else {
                indexVariants(snapshot.items)
            }
            loadedAt = snapshot.savedAt
            snapshotIsFresh = Date().timeIntervalSince(snapshot.savedAt) < Self.refreshInterval
        } else {
            items = []
            variants.removeAll()
            loadedAt = nil
        }

        // 2) 缓存还新且不是主动刷新：直接用缓存，不重复请求。
        guard force || !snapshotIsFresh else {
            error = nil
            isLoading = false
            // 列表直接来自快照，翻页游标仍要就位：下滑到底能接着从第 2 页拉。
            preparePagination(sources: usable, tab: tab)
            return
        }

        cancelLoadMore()
        reloadTask?.cancel()
        cancelJob(loadJobID)
        loadJobID = nil
        cancelJob(enrichJobID)
        enrichJobID = nil
        enrichToken &+= 1
        loadToken &+= 1
        let token = loadToken
        // 有快照时不要整页转圈：只在完全没有内容时显示载入中。
        isLoading = items.isEmpty
        reloadTask = Task { [weak self] in
            await self?.performReload(sources: sources, tab: tab, tmdb: tmdb, token: token)
        }
    }

    /// 具体源内按站点原始分类浏览：`category` 为 nil 时读该源首页。
    /// 与聚合页分开：不写聚合快照，翻页游标也只属于这一条分类流。
    func reloadFocused(source: CatalogSource,
                       category: CatalogCategory?,
                       tmdb: TMDBClient?,
                       force: Bool = false) {
        guard source.isEnabled, source.kind.supportsNetworkCinema else {
            items = []
            canLoadMore = false
            isLoading = false
            freshItemKeys = []
            return
        }
        let key = "\(source.id.uuidString)|\(category?.id ?? "-")"
        if !force, focusedSourceID == source.id, focusedCacheKey == key, let loadedAt,
           Date().timeIntervalSince(loadedAt) < Self.refreshInterval {
            return
        }
        // 换分类 / 刷新：退出源内搜索，回到分类浏览。
        discardFocusedSearch()

        focusedSourceID = source.id
        focusedCategoryID = category?.id
        if focusedCacheKey != key {
            // 换源 / 换分类：上一份「新增」标记不再适用。
            freshItemKeys = []
        }
        cancelLoadMore()
        reloadTask?.cancel()
        cancelJob(loadJobID)
        loadJobID = nil
        cancelJob(enrichJobID)
        enrichJobID = nil
        enrichToken &+= 1
        loadToken &+= 1
        let token = loadToken
        isLoading = items.isEmpty
        error = nil
        reloadTask = Task { [weak self] in
            await self?.performFocusedReload(source: source, category: category,
                                             key: key, tmdb: tmdb, token: token)
        }
    }

    private func performFocusedReload(source: CatalogSource,
                                      category: CatalogCategory?,
                                      key: String,
                                      tmdb: TMDBClient?,
                                      token: Int) async {
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            if token == loadToken {
                items = []
                error = "这个源暂不支持分类浏览"
                isLoading = false
                canLoadMore = false
            }
            return
        }
        isLoading = items.isEmpty
        error = nil
        let jobID = beginJob(kind: .probe,
                             title: "读取 \(source.name) · \(category?.title ?? "首页")") { [weak self] in
            Task { @MainActor in
                self?.loadToken &+= 1
                self?.isLoading = false
            }
        }
        loadJobID = jobID
        updateJob(jobID, completed: 0, total: 1, message: source.name)

        let page: CatalogPage?
        do {
            if let category {
                page = try await provider.category(source: source, category: category,
                                                   sort: .latest, page: 1)
            } else {
                page = try await provider.home(source: source)
            }
        } catch {
            if token == loadToken {
                items = []
                self.error = error.localizedDescription
                isLoading = false
                canLoadMore = false
                finishJob(jobID, message: "读取失败")
            }
            if loadJobID == jobID { loadJobID = nil }
            return
        }

        guard token == loadToken else {
            cancelJob(jobID)
            return
        }
        guard let page else {
            isLoading = false
            canLoadMore = false
            finishJob(jobID, message: "没有取到内容")
            if loadJobID == jobID { loadJobID = nil }
            return
        }

        let list = page.items.map {
            NetworkCinemaItem(source: source, item: $0, isTV: Self.guessIsTV($0))
        }
        items = list
        variants.removeAll()
        indexVariants(list)
        // 同一源同一分类的上次结果：这次新出现的条目打「刚上架 / 更新中」。
        let previousIDs = focusedSeenIDs[key] ?? []
        freshItemKeys = previousIDs.isEmpty
            ? []
            : Set(list.filter { !previousIDs.contains($0.item.id) }
                .map { Self.freshKey(sourceID: $0.source.id, itemID: $0.item.id) })
        focusedSeenIDs[key] = Set(list.map(\.item.id))
        loadedAt = Date()
        error = nil
        isLoading = false
        canLoadMore = page.hasMore
        focusedCacheKey = key
        focusedStream = FeedStream(source: source, category: category,
                                   nextPage: 2, exhausted: !page.hasMore)
        finishJob(jobID, message: "读取 \(list.count) 部")
        if loadJobID == jobID { loadJobID = nil }
        await enrich(items: Array(list.prefix(Self.enrichmentLimit)), tmdb: tmdb, token: token)
    }

    /// 具体源分类浏览的下滑翻页：只沿当前分类流往后拉。
    func loadMoreFocused(tmdb: TMDBClient?) {
        if isSourceSearchActive {
            loadMoreFocusedSearch(tmdb: tmdb)
            return
        }
        guard focusedSourceID != nil, !isLoadingMore, let stream = focusedStream else { return }
        guard !stream.exhausted else {
            canLoadMore = false
            return
        }
        isLoadingMore = true
        loadMoreToken &+= 1
        let token = loadMoreToken
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            guard let provider = CatalogProviders.provider(for: stream.source.kind) else {
                self.isLoadingMore = false
                return
            }
            let pageNumber = stream.nextPage
            let page: CatalogPage?
            if let category = stream.category {
                page = try? await provider.category(source: stream.source, category: category,
                                                    sort: .latest, page: pageNumber)
            } else {
                page = try? await provider.home(source: stream.source, page: pageNumber)
            }
            guard !Task.isCancelled, token == self.loadMoreToken else { return }
            guard let page, !page.items.isEmpty else {
                self.focusedStream?.exhausted = true
                self.canLoadMore = false
                self.isLoadingMore = false
                return
            }
            let list = page.items.map {
                NetworkCinemaItem(source: stream.source, item: $0, isTV: Self.guessIsTV($0))
            }
            self.items = Self.mergeNew(list, into: self.items)
            self.indexVariants(list)
            self.loadedAt = Date()
            self.focusedStream?.nextPage = pageNumber + 1
            self.focusedStream?.exhausted = !page.hasMore
            self.canLoadMore = page.hasMore
            self.isLoadingMore = false
            await self.enrich(items: Array(list.prefix(24)), tmdb: tmdb, token: self.loadToken)
        }
    }

    // MARK: - 源内真实搜索

    /// 站点页顶栏搜索：调用站点自己的搜索接口，而不是过滤已加载的缓存页。
    /// 输入防抖 420ms；清空关键词时恢复搜索前的分类列表。
    func searchFocused(source: CatalogSource,
                       keyword: String,
                       tmdb: TMDBClient?,
                       force: Bool = false) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearFocusedSearch()
            return
        }
        guard source.isEnabled, source.kind.supportsNetworkCinema else { return }
        if !force, sourceSearchKeyword == trimmed, sourceSearchSource?.id == source.id,
           !items.isEmpty {
            return
        }
        // 第一次进入搜索：先存下分类浏览现场，清空搜索后原样恢复。
        if sourceSearchKeyword == nil {
            savedFocusedItems = items
            savedFocusedCanLoadMore = canLoadMore
            savedFocusedStream = focusedStream
        }
        sourceSearchTask?.cancel()
        sourceSearchToken &+= 1
        let token = sourceSearchToken
        sourceSearchSource = source
        sourceSearchKeyword = trimmed
        sourceSearchPage = 1
        sourceSearchHasMore = false
        isSourceSearching = true
        sourceSearchError = nil
        sourceSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            await self?.performFocusedSearch(source: source, keyword: trimmed,
                                             page: 1, append: false,
                                             tmdb: tmdb, token: token)
        }
    }

    /// 清空搜索：恢复进入搜索前的分类列表，不重复打接口。
    func clearFocusedSearch() {
        guard sourceSearchKeyword != nil else { return }
        sourceSearchTask?.cancel()
        sourceSearchTask = nil
        sourceSearchToken &+= 1
        isSourceSearching = false
        sourceSearchError = nil
        sourceSearchKeyword = nil
        sourceSearchSource = nil
        sourceSearchPage = 1
        sourceSearchHasMore = false
        items = savedFocusedItems
        variants.removeAll()
        indexVariants(items)
        focusedStream = savedFocusedStream
        canLoadMore = savedFocusedCanLoadMore
        isLoadingMore = false
        freshItemKeys = []
        savedFocusedItems = []
        savedFocusedStream = nil
        savedFocusedCanLoadMore = false
    }

    /// 退出搜索但保留即将重新加载的列表（换分类 / 刷新时用）。
    private func discardFocusedSearch() {
        guard sourceSearchKeyword != nil else { return }
        sourceSearchTask?.cancel()
        sourceSearchTask = nil
        sourceSearchToken &+= 1
        sourceSearchKeyword = nil
        sourceSearchSource = nil
        sourceSearchError = nil
        isSourceSearching = false
        sourceSearchPage = 1
        sourceSearchHasMore = false
        savedFocusedItems = []
        savedFocusedStream = nil
        savedFocusedCanLoadMore = false
        isLoadingMore = false
    }

    private func performFocusedSearch(source: CatalogSource,
                                      keyword: String,
                                      page: Int,
                                      append: Bool,
                                      tmdb: TMDBClient?,
                                      token: Int) async {
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            if token == sourceSearchToken {
                sourceSearchError = "这个源暂不支持搜索"
                isSourceSearching = false
                isLoadingMore = false
            }
            return
        }
        if append {
            isLoadingMore = true
        } else {
            isSourceSearching = true
        }
        sourceSearchError = nil
        let jobID = beginJob(kind: .search, title: "搜索 \(source.name)「\(keyword)」") { [weak self] in
            Task { @MainActor in
                self?.sourceSearchToken &+= 1
                self?.isSourceSearching = false
                self?.isLoadingMore = false
            }
        }
        updateJob(jobID, completed: 0, total: 1, message: source.name)

        let result: CatalogPage?
        do {
            result = try await provider.search(source: source, keyword: keyword, page: page)
        } catch {
            guard token == sourceSearchToken else {
                cancelJob(jobID)
                return
            }
            if !append { items = [] }
            sourceSearchError = error.localizedDescription
            isSourceSearching = false
            isLoadingMore = false
            finishJob(jobID, message: "搜索失败")
            return
        }
        guard token == sourceSearchToken else {
            cancelJob(jobID)
            return
        }
        guard let result else {
            if !append { items = [] }
            sourceSearchHasMore = false
            canLoadMore = false
            isSourceSearching = false
            isLoadingMore = false
            finishJob(jobID, message: "没有搜到内容")
            return
        }

        let list = result.items.map {
            NetworkCinemaItem(source: source, item: $0, isTV: Self.guessIsTV($0))
        }
        if append {
            items = Self.mergeNew(list, into: items)
        } else {
            items = list
            variants.removeAll()
        }
        indexVariants(list)
        sourceSearchPage = result.page
        sourceSearchHasMore = result.hasMore
        canLoadMore = result.hasMore
        isSourceSearching = false
        isLoadingMore = false
        freshItemKeys = []
        finishJob(jobID, message: "搜到 \(items.count) 部")
        await enrich(items: Array(list.prefix(Self.enrichmentLimit)),
                     tmdb: tmdb, token: loadToken)
    }

    /// 搜索结果的下一页：沿同一关键词继续拉。
    func loadMoreFocusedSearch(tmdb: TMDBClient?) {
        guard let source = sourceSearchSource, let keyword = sourceSearchKeyword,
              sourceSearchHasMore, !isLoadingMore, !isSourceSearching else { return }
        sourceSearchToken &+= 1
        let token = sourceSearchToken
        let next = sourceSearchPage + 1
        isLoadingMore = true
        sourceSearchTask = Task { [weak self] in
            await self?.performFocusedSearch(source: source, keyword: keyword,
                                             page: next, append: true,
                                             tmdb: tmdb, token: token)
        }
    }

    private func performReload(sources: [CatalogSource],
                               tab: NetworkCinemaTab,
                               tmdb: TMDBClient?,
                               token: Int) async {
        let usable = sources.filter { $0.isEnabled && $0.kind.supportsNetworkCinema }
        guard !usable.isEmpty else {
            if token == loadToken {
                items = []
                error = nil
                loadedAt = nil
            }
            return
        }

        isLoading = items.isEmpty
        error = nil
        let jobID = beginJob(kind: .probe, title: "探测影视源 · \(tab.title)") { [weak self] in
            Task { @MainActor in
                self?.loadToken &+= 1
                self?.isLoading = false
            }
        }
        loadJobID = jobID

        var lists: [[NetworkCinemaItem]] = []
        var failure: String?
        for (index, source) in usable.enumerated() {
            if Task.isCancelled || token != loadToken {
                cancelJob(jobID)
                return
            }
            updateJob(jobID, completed: index, total: usable.count, message: source.name)
            let result = await Self.load(source: source, tab: tab)
            if !result.items.isEmpty { lists.append(result.items) }
            if let message = result.failure { failure = message }
        }
        guard token == loadToken else {
            cancelJob(jobID)
            return
        }

        let merged = Self.merge(lists)
        if merged.isEmpty {
            // 网络失败：保留快照内容，只在完全没有内容时展示错误。
            if items.isEmpty, let failure { error = failure }
            isLoading = false
            finishJob(jobID, message: "没有取到内容")
            if loadJobID == jobID { loadJobID = nil }
            return
        }

        items = merged
        variants.removeAll()
        indexVariants(lists.flatMap { $0 })
        // 与上次同一分页的快照比对：新出现的条目打「刚上架 / 更新中」。
        let previousIDs = Set((snapshots[tab]?.items ?? []).map(\.item.id))
        freshItemKeys = previousIDs.isEmpty
            ? []
            : Set(merged.filter { !previousIDs.contains($0.item.id) }
                .map { Self.freshKey(sourceID: $0.source.id, itemID: $0.item.id) })
        let savedAt = Date()
        loadedAt = savedAt
        error = nil
        isLoading = false
        // 快照落库：下次进入先用这一份铺满，再后台刷新。
        let snapshot = NetworkCinemaListSnapshot(items: Array(merged.prefix(NetworkCinemaSnapshotStore.itemLimit)),
                                                 savedAt: savedAt,
                                                 sourceSignature: Self.sourceSignature(usable),
                                                 variants: variants)
        snapshots[tab] = snapshot
        NetworkCinemaSnapshotStore.save(snapshot, tab: tab)

        finishJob(jobID, message: "聚合 \(merged.count) 部")
        if loadJobID == jobID { loadJobID = nil }

        // 首屏就位后准备翻页游标：下滑到底自动接着拉第 2 页起的内容。
        preparePagination(sources: usable, tab: tab)

        await enrich(items: Array(merged.prefix(Self.enrichmentLimit)), tmdb: tmdb, token: token)
    }

    /// 源集合签名：源增删 / 换选后，旧快照自动失效。
    private static func sourceSignature(_ sources: [CatalogSource]) -> String {
        sources.map(\.id.uuidString).sorted().joined(separator: ",")
    }

    // MARK: - 下滑翻页

    /// 为某个分页准备翻页游标：每个源取自己的电影 / 电视剧分类，各自从第 2 页开始。
    /// 用源里随源保存的分类骨架，不额外发请求。
    private func preparePagination(sources: [CatalogSource], tab: NetworkCinemaTab) {
        let usable = sources.filter { $0.isEnabled && $0.kind.supportsNetworkCinema }
        let plan = Self.feedStreams(sources: usable, tab: tab)
        streams[tab] = plan
        canLoadMore = !plan.isEmpty
    }

    private static func feedStreams(sources: [CatalogSource], tab: NetworkCinemaTab) -> [FeedStream] {
        var result: [FeedStream] = []
        for source in sources {
            let picked = pickCategories(source.categories, wantTV: tab == .shows)
            if picked.isEmpty {
                // 站点没有电影 / 电视剧分类：退回首页按页翻，类型靠标题 / 备注判断。
                result.append(FeedStream(source: source, category: nil, nextPage: 2, exhausted: false))
            } else {
                for category in picked.prefix(2) {
                    result.append(FeedStream(source: source, category: category,
                                             nextPage: 2, exhausted: false))
                }
            }
        }
        return result
    }

    private func cancelLoadMore() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadMoreToken &+= 1
        isLoadingMore = false
    }

    /// 下滑到底：各源各分类各补一页，按标题去重后追加到列表。
    /// 翻页是前台动作，不再单独登记任务，只在网格底部显示「正在加载更多」。
    func loadMore(sources: [CatalogSource], tab: NetworkCinemaTab, tmdb: TMDBClient?) {
        guard tab.browsesContent, !isLoadingMore, !isSearching else { return }
        if streams[tab] == nil {
            preparePagination(sources: sources, tab: tab)
        }
        guard var plan = streams[tab], plan.contains(where: { !$0.exhausted }) else {
            canLoadMore = false
            return
        }

        isLoadingMore = true
        loadMoreToken &+= 1
        let token = loadMoreToken
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            var added: [NetworkCinemaItem] = []
            let wantTV = tab == .shows

            for index in plan.indices {
                guard !Task.isCancelled, token == self.loadMoreToken else { return }
                guard !plan[index].exhausted else { continue }
                let stream = plan[index]
                guard let provider = CatalogProviders.provider(for: stream.source.kind) else {
                    plan[index].exhausted = true
                    continue
                }
                let pageNumber = stream.nextPage
                let page: CatalogPage?
                if let category = stream.category {
                    page = try? await provider.category(source: stream.source,
                                                        category: category,
                                                        sort: .latest,
                                                        page: pageNumber)
                } else {
                    page = try? await provider.home(source: stream.source, page: pageNumber)
                }
                guard !Task.isCancelled, token == self.loadMoreToken else { return }
                guard let page, !page.items.isEmpty else {
                    plan[index].exhausted = true
                    continue
                }
                var list = page.items.map {
                    NetworkCinemaItem(source: stream.source, item: $0, isTV: wantTV)
                }
                // 首页兜底流是混排的：按类型过滤一次，过滤后为空就保留原样。
                if stream.category == nil {
                    let filtered = list.filter { $0.isTV == wantTV }
                    if !filtered.isEmpty { list = filtered }
                }
                added += list
                plan[index].nextPage = pageNumber + 1
                plan[index].exhausted = !page.hasMore
            }

            guard !Task.isCancelled, token == self.loadMoreToken else { return }
            self.streams[tab] = plan
            self.canLoadMore = plan.contains { !$0.exhausted }
            self.isLoadingMore = false
            guard !added.isEmpty else { return }

            let merged = Self.mergeNew(added, into: self.items)
            self.items = merged
            self.indexVariants(added)
            let savedAt = Date()
            self.loadedAt = savedAt
            let usable = sources.filter { $0.isEnabled && $0.kind.supportsNetworkCinema }
            let snapshot = NetworkCinemaListSnapshot(
                items: Array(merged.prefix(NetworkCinemaSnapshotStore.itemLimit)),
                savedAt: savedAt,
                sourceSignature: Self.sourceSignature(usable),
                variants: self.variants
            )
            self.snapshots[tab] = snapshot
            NetworkCinemaSnapshotStore.save(snapshot, tab: tab)

            // 新补进来的一批顺手补全资料；不登记任务，避免滚动时任务记录被刷屏。
            await self.enrich(items: Array(added.prefix(24)),
                              tmdb: tmdb,
                              token: self.loadToken,
                              registersJob: false)
        }
    }

    /// 追加去重：同名条目只留先出现的一条，避免不同页重复铺同一部片。
    private static func mergeNew(_ newItems: [NetworkCinemaItem],
                                 into existing: [NetworkCinemaItem]) -> [NetworkCinemaItem] {
        var seen = Set(existing.map { NetworkCinemaEnrichment.normalized($0.item.title) })
        var result = existing
        for entry in newItems {
            let key = NetworkCinemaEnrichment.normalized(entry.item.title)
            guard seen.insert(key).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    /// 详情：直接问该条所属的源，分集与正文都按站点原始数据来。
    func detail(for item: NetworkCinemaItem) async throws -> CatalogDetail {
        guard let provider = CatalogProviders.provider(for: item.source.kind) else {
            throw CatalogError.unsupportedProvider
        }
        return try await provider.detail(source: item.source, itemID: item.item.id)
    }

    /// 换图库：列表、搜索、TMDB 资料与分页快照都只属于上一个图库，
    /// 全部作废后按新图库自己的 SQLite 重新读一份缓存，避免旧库内容残留在内存里。
    func resetForLibrarySwitch() {
        reloadTask?.cancel()
        reloadTask = nil
        searchTask?.cancel()
        searchTask = nil
        cancelLoadMore()
        cancelJob(loadJobID)
        cancelJob(searchJobID)
        cancelJob(enrichJobID)
        loadJobID = nil
        searchJobID = nil
        enrichJobID = nil
        loadToken &+= 1
        searchToken &+= 1
        enrichToken &+= 1
        items = []
        searchItems = []
        variants = [:]
        isLoading = false
        isSearching = false
        error = nil
        searchError = nil
        loadedAt = nil
        enrichmentProgress = nil
        enrichments = [:]
        misses = []
        detailLoading.removeAll()
        doubanLoading.removeAll()
        cinemaDetails = [:]
        doubanRatings = [:]
        snapshots = [:]
        streams = [:]
        focusedSourceID = nil
        focusedCategoryID = nil
        focusedStream = nil
        focusedCacheKey = nil
        focusedSeenIDs = [:]
        discardFocusedSearch()
        freshItemKeys = []
        canLoadMore = false
        loadCache()
        for tab in NetworkCinemaTab.allCases where tab.browsesContent {
            snapshots[tab] = NetworkCinemaSnapshotStore.load(tab: tab)
        }
    }

    // MARK: - 搜索

    func clearSearch() {
        searchTask?.cancel()
        cancelJob(searchJobID)
        searchJobID = nil
        searchToken &+= 1
        searchItems = []
        isSearching = false
        searchError = nil
        // 回到列表：如果翻页游标还有下一页，恢复下滑翻页。
        canLoadMore = streams.values.contains { plan in
            plan.contains { !$0.exhausted }
        }
    }

    /// 跨源搜索：每个已启用影视源各取第一页，交错合并后按标题去重。
    /// 同样在模型里跑，切页不会中断；左下角能看到「搜索「关键词」」的进度。
    func search(sources: [CatalogSource], query: String, tmdb: TMDBClient?) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            clearSearch()
            return
        }
        searchTask?.cancel()
        cancelJob(searchJobID)
        searchJobID = nil
        searchToken &+= 1
        let token = searchToken
        // 搜索替换列表：翻页游标与进行中的补页都停掉。
        cancelLoadMore()
        canLoadMore = false
        searchTask = Task { [weak self] in
            await self?.performSearch(sources: sources,
                                      keyword: keyword,
                                      tmdb: tmdb,
                                      token: token)
        }
    }

    private func performSearch(sources: [CatalogSource],
                               keyword: String,
                               tmdb: TMDBClient?,
                               token: Int) async {
        isSearching = true
        searchError = nil

        let jobID = beginJob(kind: .search, title: "搜索「\(keyword)」") { [weak self] in
            Task { @MainActor in
                self?.searchToken &+= 1
                self?.isSearching = false
            }
        }
        searchJobID = jobID

        let usable = sources.filter { $0.isEnabled && $0.kind.supportsNetworkCinema }
        var lists: [[NetworkCinemaItem]] = []
        var failure: String?
        for (index, source) in usable.enumerated() {
            if Task.isCancelled || token != searchToken {
                cancelJob(jobID)
                return
            }
            updateJob(jobID, completed: index, total: usable.count, message: source.name)
            guard let provider = CatalogProviders.provider(for: source.kind) else { continue }
            do {
                let page = try await provider.search(source: source, keyword: keyword, page: 1)
                guard !page.items.isEmpty else { continue }
                lists.append(page.items.map {
                    NetworkCinemaItem(source: source,
                                      item: $0,
                                      isTV: Self.guessIsTV($0))
                })
            } catch {
                failure = error.localizedDescription
            }
        }
        guard token == searchToken else {
            cancelJob(jobID)
            return
        }

        let merged = Self.merge(lists)
        variants.removeAll()
        indexVariants(lists.flatMap { $0 })
        searchItems = merged
        isSearching = false
        if merged.isEmpty, let failure { searchError = failure }
        await enrichSearch(items: Array(merged.prefix(Self.enrichmentLimit)),
                           tmdb: tmdb,
                           token: token,
                           jobID: jobID)
        guard token == searchToken else {
            cancelJob(jobID)
            return
        }
        finishJob(jobID, message: merged.isEmpty ? "没有结果" : "找到 \(merged.count) 条")
        if searchJobID == jobID { searchJobID = nil }
    }

    private func enrichSearch(items: [NetworkCinemaItem],
                              tmdb: TMDBClient?,
                              token: Int,
                              jobID: UUID?) async {
        guard let tmdb, !items.isEmpty else { return }
        let pending = items.filter {
            enrichments[$0.enrichmentKey] == nil && !misses.contains($0.enrichmentKey)
        }
        for (index, entry) in pending.enumerated() {
            if Task.isCancelled || token != searchToken { return }
            if let match = await Self.match(tmdb: tmdb, item: entry) {
                enrichments[entry.enrichmentKey] = match
            } else {
                misses.insert(entry.enrichmentKey)
            }
            updateJob(jobID,
                      completed: index + 1,
                      total: pending.count,
                      message: "补全结果资料")
        }
        saveCache()
        Self.prefetchPosters(pending.compactMap { enrichments[$0.enrichmentKey] })
    }

    // MARK: - 详情补全

    /// 用已匹配到的 TMDB ID 再取一次完整资料：演职员、片长、分级。
    func details(for item: NetworkCinemaItem, tmdb: TMDBClient?) async -> CinemaDetails? {
        guard let tmdb,
              let enrichment = enrichment(for: item),
              enrichment.tmdbID > 0 else { return nil }
        let key = "\(enrichment.tmdbID)|\(enrichment.isTV ? "tv" : "movie")"
        if let cached = cinemaDetails[key] { return cached }
        if detailLoading.contains(key) { return nil }
        detailLoading.insert(key)
        defer { detailLoading.remove(key) }
        guard let details = try? await tmdb.details(id: enrichment.tmdbID,
                                                    isTV: enrichment.isTV) else {
            return nil
        }
        cinemaDetails[key] = details
        return details
    }

    /// 豆瓣评分：按片名 / 年份匹配一次，命中后缓存。
    func doubanRating(for item: NetworkCinemaItem, client: DoubanClient?) async -> Double? {
        guard let client else { return nil }
        let key = item.enrichmentKey
        if let cached = doubanRatings[key] { return cached }
        if doubanLoading.contains(key) { return nil }
        doubanLoading.insert(key)
        defer { doubanLoading.remove(key) }

        let title = NetworkCinemaEnrichment.cleanedTitle(item.item.title)
        guard !title.isEmpty else { return nil }
        let year = NetworkCinemaEnrichment.year(in: item.item.title)
        guard let matches = try? await client.search(query: title,
                                                     isTV: item.isTV,
                                                     year: year) else { return nil }
        let pick = matches.first { match in
            guard let matchYear = match.year, let year else { return true }
            return abs(matchYear - year) <= 1
        }
        guard let rating = pick?.rating, rating > 0 else { return nil }
        doubanRatings[key] = rating
        return rating
    }

    /// 当前列表出现过的 TMDB 类型，按出现次数排序，给页面做类型筛选。
    func genres(for items: [NetworkCinemaItem]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in enrichment(for: item)?.genres ?? [] {
                counts[genre, default: 0] += 1
            }
        }
        return counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map(\.key)
    }

    // MARK: - 聚合

    private static func load(source: CatalogSource,
                             tab: NetworkCinemaTab) async
        -> (items: [NetworkCinemaItem], failure: String?) {
        guard tab.browsesContent else { return ([], nil) }
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            return ([], "该源没有对应的解析器")
        }
        let wantTV = tab == .shows
        do {
            let categories = (try? await provider.categories(source: source)) ?? source.categories
            let picked = pickCategories(categories, wantTV: wantTV)
            var items: [NetworkCinemaItem] = []
            for category in picked.prefix(2) {
                guard let page = try? await provider.category(source: source,
                                                              category: category,
                                                              sort: .latest,
                                                              page: 1) else { continue }
                items += page.items.map {
                    NetworkCinemaItem(source: source, item: $0, isTV: wantTV)
                }
            }
            if !items.isEmpty { return (items, nil) }

            // 站点没有「电影 / 电视剧」这类分类：退回首页，再按标题 / 备注过滤。
            let page = try await provider.home(source: source)
            let filtered = page.items.filter { guessIsTV($0) == wantTV }
            let base = filtered.isEmpty ? page.items : filtered
            return (base.map {
                NetworkCinemaItem(source: source, item: $0, isTV: wantTV)
            }, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    /// 从站点的分类树里挑出「电影」或「电视剧」相关分类：强匹配优先，其次按后缀兜底。
    private static func pickCategories(_ categories: [CatalogCategory],
                                       wantTV: Bool) -> [CatalogCategory] {
        var flat: [CatalogCategory] = []
        for category in categories {
            if category.isGroupCategory {
                flat.append(contentsOf: category.children ?? [])
                continue
            }
            flat.append(category)
            if let children = category.children { flat.append(contentsOf: children) }
        }

        let tvStrong = ["电视剧", "连续剧", "剧集", "美剧", "韩剧", "日剧", "英剧",
                        "国产剧", "港剧", "台剧", "泰剧"]
        let movieStrong = ["电影"]
        var strong: [CatalogCategory] = []
        var weak: [CatalogCategory] = []
        for category in flat {
            let title = category.title
            if wantTV {
                if tvStrong.contains(where: { title.contains($0) }) {
                    strong.append(category)
                } else if title.hasSuffix("剧"), !title.contains("综艺") {
                    weak.append(category)
                }
            } else {
                if movieStrong.contains(where: { title.contains($0) }) {
                    strong.append(category)
                } else if title.hasSuffix("片"), !title.contains("片单"), !title.contains("专题") {
                    weak.append(category)
                }
            }
        }
        return Array((strong + weak).prefix(3))
    }

    /// 列表里没有统一类型字段：按标题 / 备注里的「集 / 更新 / 季」等字样猜电影还是剧集。
    static func guessIsTV(_ item: CatalogItem) -> Bool {
        let text = item.title + " " + item.remark
        let marks = ["集", "更新", "连载", "季", "更至", "全"]
        return marks.contains { text.contains($0) }
    }

    /// 交错合并各源：苹果CMS 的列表没有统一时间字段，轮转能保证每个源都露头，
    /// 同时按归一化标题去重，同名条目只留先出现的那条。
    private static func merge(_ lists: [[NetworkCinemaItem]]) -> [NetworkCinemaItem] {
        var seen = Set<String>()
        var result: [NetworkCinemaItem] = []
        var index = 0
        while true {
            var appended = false
            for list in lists where index < list.count {
                appended = true
                let entry = list[index]
                let key = NetworkCinemaEnrichment.normalized(entry.item.title)
                if seen.insert(key).inserted { result.append(entry) }
            }
            if !appended { break }
            index += 1
        }
        return result
    }

    // MARK: - TMDB 补全

    /// - Parameter registersJob: 首屏补全登记成任务；下滑翻页补全不登记，免得任务记录被刷屏。
    private func enrich(items: [NetworkCinemaItem],
                        tmdb: TMDBClient?,
                        token: Int,
                        registersJob: Bool = true) async {
        guard let tmdb, !items.isEmpty else {
            enrichmentProgress = nil
            return
        }
        let pending = items.filter {
            enrichments[$0.enrichmentKey] == nil && !misses.contains($0.enrichmentKey)
        }
        guard !pending.isEmpty else {
            enrichmentProgress = nil
            return
        }

        enrichToken &+= 1
        let etoken = enrichToken
        enrichmentProgress = (0, pending.count)
        let jobID: UUID? = registersJob
            ? beginJob(kind: .metadata, title: "补全 TMDB 资料") { [weak self] in
                Task { @MainActor in self?.enrichToken &+= 1 }
            }
            : nil
        if registersJob { enrichJobID = jobID }

        var done = 0
        var matched = 0
        for entry in pending {
            if Task.isCancelled || token != loadToken || etoken != enrichToken {
                enrichmentProgress = nil
                cancelJob(jobID)
                if enrichJobID == jobID { enrichJobID = nil }
                return
            }
            if let match = await Self.match(tmdb: tmdb, item: entry) {
                enrichments[entry.enrichmentKey] = match
                matched += 1
            } else {
                misses.insert(entry.enrichmentKey)
            }
            done += 1
            enrichmentProgress = (done, pending.count)
            updateJob(jobID,
                      completed: done,
                      total: pending.count,
                      message: "已匹配 \(matched) 部")
            if done % 8 == 0 { saveCache() }
        }
        saveCache()
        // 海报预取：与网络资源一致，首屏海报先落进内存 / 磁盘缓存，滚动不再等网络。
        Self.prefetchPosters(pending.compactMap { enrichments[$0.enrichmentKey] })
        enrichmentProgress = nil
        finishJob(jobID, message: "匹配 \(matched) / \(pending.count) 部")
        if enrichJobID == jobID { enrichJobID = nil }
    }

    /// 海报预取：只预取前若干张，避免一次打几百个图片请求。
    private static func prefetchPosters(_ matches: [NetworkCinemaEnrichment]) {
        let urls = Array(matches.compactMap(\.posterURL).prefix(40))
        guard !urls.isEmpty else { return }
        CinemaArtworkCache.shared.prefetch(urls, maxPixelSize: 500)
    }

    /// 详情页专用的 TMDB 补试：列表补全失败后被记进 `misses` 的条目，按当前条目的标题 / 年份再来一次。
    func retryEnrichment(for item: NetworkCinemaItem, tmdb: TMDBClient) async {
        let key = item.enrichmentKey
        guard enrichments[key] == nil else { return }
        misses.remove(key)
        guard let match = await Self.match(tmdb: tmdb, item: item) else {
            misses.insert(key)
            return
        }
        enrichments[key] = match
        saveCache()
    }

    /// 详情页的资料补全：TMDB 详情 + 豆瓣评分，同样登记成一条任务。
    func loadMetadata(for item: NetworkCinemaItem,
                      tmdb: TMDBClient?,
                      douban: DoubanClient?) async -> (details: CinemaDetails?, douban: Double?) {
        let displayTitle = enrichment(for: item)?.title ?? item.item.title
        let jobID = beginJob(kind: .metadata,
                             title: "补全《\(displayTitle)》资料",
                             cancellable: false)

        if tmdb != nil {
            updateJob(jobID, message: "等待 TMDB 匹配")
            // 列表补全可能还没轮到这一条：短暂等一下，拿到 TMDB ID 后再取完整资料。
            var waited = 0
            while enrichment(for: item) == nil, waited < 10, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                waited += 1
            }
        }

        // 列表里没匹配上（或已被记成 miss）时，详情页按当前条目的标题 / 年份再试一次：
        // 拿不到 TMDB ID 就缺片长、语言、演职员和预告片入口。
        if let tmdb, enrichment(for: item) == nil {
            updateJob(jobID, message: "重试 TMDB 匹配")
            await retryEnrichment(for: item, tmdb: tmdb)
        }

        var details: CinemaDetails?
        if let tmdb, enrichment(for: item) != nil {
            updateJob(jobID, message: "读取 TMDB 详情")
            details = await self.details(for: item, tmdb: tmdb)
        }

        var rating: Double?
        if let douban {
            updateJob(jobID, message: "匹配豆瓣评分")
            rating = await doubanRating(for: item, client: douban)
        }

        finishJob(jobID, message: details == nil && rating == nil ? "未匹配到资料" : "资料已补全")
        return (details, rating)
    }

    // MARK: - 任务中心

    @discardableResult
    private func beginJob(kind: SourceJobKind,
                          title: String,
                          cancellable: Bool = true,
                          cancel: (() -> Void)? = nil) -> UUID? {
        guard let jobCenter else { return nil }
        let id = jobCenter.begin(SourceJob(sourceID: .networkCinema,
                                           kind: kind,
                                           title: title,
                                           isCancellable: cancellable),
                                 cancel: cancel)
        onJobChange?()
        return id
    }

    private func updateJob(_ id: UUID?,
                           completed: Int? = nil,
                           total: Int? = nil,
                           message: String? = nil) {
        guard let jobCenter, let id else { return }
        jobCenter.update(id, completed: completed, total: total, message: message)
        onJobChange?()
    }

    private func finishJob(_ id: UUID?, message: String? = nil) {
        guard let jobCenter, let id else { return }
        jobCenter.finish(id, message: message)
        onJobFinished?(id)
        onJobChange?()
    }

    private func cancelJob(_ id: UUID?) {
        guard let jobCenter, let id else { return }
        jobCenter.cancel(id)
        onJobChange?()
    }

    private static func match(tmdb: TMDBClient,
                              item: NetworkCinemaItem) async -> NetworkCinemaEnrichment? {
        let query = NetworkCinemaEnrichment.cleanedTitle(item.item.title)
        guard !query.isEmpty else { return nil }
        let year = NetworkCinemaEnrichment.year(in: item.item.title)
        guard let results = try? await tmdb.search(query: query,
                                                   isTV: item.isTV,
                                                   year: year),
              !results.isEmpty else { return nil }

        let wanted = NetworkCinemaEnrichment.normalized(query)
        let exact = results.filter {
            NetworkCinemaEnrichment.normalized($0.title) == wanted
                || NetworkCinemaEnrichment.normalized($0.originalTitle ?? "") == wanted
        }
        let pool = exact.isEmpty ? results : exact
        guard let best = pool.max(by: { ($0.voteCount ?? 0) < ($1.voteCount ?? 0) }) else {
            return nil
        }
        if exact.isEmpty {
            // 没有精确同名时，要求标题互相包含，避免给「沙丘」配上「沙丘2」之外的路人片。
            let candidate = NetworkCinemaEnrichment.normalized(best.title)
            guard candidate.contains(wanted) || wanted.contains(candidate) else { return nil }
        }
        return NetworkCinemaEnrichment(tmdbID: Int(best.id) ?? 0,
                                       isTV: best.isTV,
                                       title: best.title,
                                       originalTitle: best.originalTitle,
                                       year: best.year,
                                       posterURL: best.posterURL,
                                       backdropURL: best.backdropURL,
                                       overview: best.overview,
                                       rating: best.rating,
                                       voteCount: best.voteCount,
                                       genres: best.genres)
    }

    // MARK: - 缓存

    /// 网络影院落在 `catalog_kv` 里的键前缀：三页列表快照 + TMDB 补全匹配 + 结构版本号。
    private static let cacheKeyPrefix = "networkCinema."

    /// 资源页展示：列表快照与 TMDB 补全的落盘体积。
    nonisolated static func cacheBytes() -> Int64 {
        CatalogDatabase.shared.keyValueBytes(prefix: cacheKeyPrefix)
    }

    /// 资源页「清理」：丢掉三页列表快照与 TMDB 补全，下次进入重新聚合。
    /// 播放进度、刮削结果与源配置都不是这类缓存，不会被清。
    func clearCaches() {
        reloadTask?.cancel()
        reloadTask = nil
        cancelLoadMore()
        cancelJob(loadJobID)
        loadJobID = nil
        cancelJob(enrichJobID)
        enrichJobID = nil
        loadToken &+= 1
        enrichToken &+= 1
        NetworkCinemaSnapshotStore.removeAll()
        CatalogDatabase.shared.clearKeyValues(prefix: Self.cacheKeyPrefix)
        snapshots = [:]
        streams = [:]
        focusedSourceID = nil
        focusedCategoryID = nil
        focusedStream = nil
        focusedCacheKey = nil
        focusedSeenIDs = [:]
        discardFocusedSearch()
        freshItemKeys = []
        canLoadMore = false
        items = []
        searchItems = []
        loadedAt = nil
        error = nil
        enrichmentProgress = nil
        isLoading = false
        enrichments = [:]
        misses = []
        cinemaDetails = [:]
        doubanRatings = [:]
    }

    private struct CachePayload: Codable {
        var matches: [String: NetworkCinemaEnrichment] = [:]
        var misses: [String] = []
    }

    private func loadCache() {
        guard let data = CatalogStore.data(forKey: Self.cacheKey),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return
        }
        enrichments = payload.matches
        misses = Set(payload.misses)
    }

    private func saveCache() {
        let payload = CachePayload(matches: enrichments, misses: Array(misses))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        CatalogStore.set(data, forKey: Self.cacheKey)
    }
}
