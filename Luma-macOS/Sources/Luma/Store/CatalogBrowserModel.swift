import Foundation
import LumaContentCore

/// 片单页里打开的详情（nil 表示停留在片单列表）。
enum CatalogPlaylistPage: Equatable {
    case manual(UUID)
    case smart(UUID)
}

/// 网络资源的浏览状态：源列表、当前分类、分页、详情、续看与播放请求。
/// 资源属于「本机配置」而不是某个图库，因此用 UserDefaults 保存，切换图库不受影响。
@MainActor
final class CatalogBrowserModel: ObservableObject {
    @Published private(set) var sources: [CatalogSource] = []
    @Published var selectedSourceID: UUID?
    @Published var section: CatalogSection = .home
    @Published var categories: [CatalogCategory] = []
    /// 站点热门标签：跨分类的额外筛选入口。
    @Published var tags: [CatalogCategory] = []
    @Published var sort: CatalogSort = .latest
    /// 站点不支持服务端排序时，对当前已加载列表做的本页排序。
    @Published var localSort: CatalogLocalSort?

    @Published var items: [CatalogItem] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = false
    @Published var error: String?
    /// 结构化错误：界面优先用它统一展示恢复动作。
    @Published var sourceError: SourceError?
    /// 统一任务中心：健康检测、更新日历补录等跨源任务上报到这里。
    var jobCenter: SourceJobCenter?
    /// 任务进度变化回调；由 LibraryStore 接到 `sourceJobRevision`，触发界面刷新。
    var onJobChange: (() -> Void)?
    /// 任务结束后的归档回调：由 LibraryStore 接到 `archiveSourceJob`，写进任务记录。
    var onJobFinished: ((UUID) -> Void)?
    /// 列表当前展示的是缓存快照而不是最新请求结果时，记录快照时间（离线视图提示用）。
    @Published var listSnapshotAt: Date?
    /// 本次刷新相对上次快照新出现的条目（key = "源 UUID|条目 id"）：
    /// 只在「以前缓存过这个列表」时计算，首次进入不会把整页都标成新上架。
    @Published var freshItemKeys: Set<String> = []
    /// 一次性操作结果（例如保存到图库），几秒后自动消失。
    @Published var notice: String?
    /// 正在下载到图库的条目 id：卡片据此显示转圈。
    @Published var savingItemID: String?

    @Published var detail: CatalogDetail?
    /// 关闭播放器后要在频道页里恢复的内联详情条目。
    @Published var pendingInlineItem: CatalogItem?
    /// 当前在频道页里内联展示的详情条目（nil = 列表）。
    /// 提到模型里是为了让窗口工具栏也能读到：返回按钮与详情标题融进顶栏胶囊。
    /// 写入时顺手落盘：退出应用后再打开，仍停在原来那一页详情。
    @Published var inlineDetailItem: CatalogItem? {
        didSet {
            guard oldValue?.id != inlineDetailItem?.id else { return }
            persistInlineDetail()
        }
    }
    /// 频道详情里叠开的人物 / 片商档案（nil = 停留在详情页）。
    /// 工具栏最左的返回按钮据此先退回详情，而不是直接跳出到频道列表。
    @Published var detailPersonTarget: CatalogDetailPersonTarget?
    /// 关注页里打开的人物 / 片商档案（nil = 停留在关注列表）。
    @Published var followedProfile: CatalogFollowedPerson?
    /// 片单页里打开的片单详情（nil = 停留在片单列表）。
    @Published var openPlaylistPage: CatalogPlaylistPage?
    @Published var isLoadingDetail = false
    @Published var detailError: String?

    @Published var searchText = ""
    /// 侧边栏点「搜索」时自增，频道页据此把焦点移入搜索框。
    @Published var searchFocusToken = 0
    @Published var progress: [String: CatalogProgress] = [:]
    @Published var favorites: [String: CatalogFavorite] = [:]
    /// 手动标记已看的条目键（`sourceID|itemID`）：不写假的播放进度，足迹统计不受影响。
    @Published var watchedKeys: Set<String> = []
    /// 当前展开的一级分类。同一个二级 id 可能挂在多个一级下（例如 XSZAV 的「無碼流出」），
    /// 必须记住用户实际点开的是哪个一级，不能按二级 id 反查（会命中第一个）。
    @Published var activeTopCategoryID: String?
    /// 侧边栏分类图标：每个分类拿该分类第一张卡片封面当缩略图。
    /// key = "源 UUID|分类 id"，值只在 URL 变化时写盘。
    @Published private(set) var categoryThumbs: [String: String] = [:]
    @Published var playback: CatalogPlaybackRequest?
    @Published var showWizard = false
    /// 导入向导当前服务的域：从网络影院进入只接收影视源，从网络资源进入只接收资源站。
    @Published var wizardDomain: CatalogDomain?

    // MARK: 网络资源 2.0：发现 / 关注 / 健康度
    /// 每个源最近一次连通性检测的结果。
    @Published var health: [UUID: CatalogSourceHealth] = [:]
    /// 最近一次检测的耗时（毫秒）与时间。
    @Published var healthLatency: [UUID: Int] = [:]
    @Published var healthCheckedAt: [UUID: Date] = [:]
    /// 置顶的源：在总览卡片墙里排在最前。
    @Published var pinnedSourceIDs: [UUID] = []
    /// 每个源置顶的常用分类（分类面板里排最前）。
    @Published var pinnedCategoryIDs: [UUID: [String]] = [:]
    /// 关注的分类（片商 / 题材）：总览页直接跳转。
    @Published var followedCategories: [CatalogFollowedCategory] = []
    /// 有新内容的源：总览卡片上显示红点，进入后清除。
    @Published var newSourceIDs: Set<UUID> = []
    /// 跨源「今日总榜」：各源第一页混排。按域分别缓存，互不覆盖。
    @Published var spotlightByDomain: [CatalogDomain: [CatalogSpotlightItem]] = [:]
    @Published var isSpotlightLoading = false
    /// 总榜维度：最新 / 各源热榜 / 今天新增。
    @Published var spotlightMode: CatalogSpotlightMode = .latest
    @Published var spotlightHotByDomain: [CatalogDomain: [CatalogSpotlightItem]] = [:]
    @Published var isSpotlightHotLoading = false
    /// 「今天新增」的榜单结果：从更新日历派生，改数据时重算一次，
    /// 不在工具栏角标 / 榜单渲染时反复过滤 2400 条日历。
    @Published var todaySpotlight: [CatalogSpotlightItem] = []
    /// 跨源聚合搜索。
    @Published var globalQuery = ""
    @Published var globalResults: [CatalogGlobalResult] = []
    /// 这批结果对应哪个查询词：输入新词时先不展示旧结果。
    @Published var globalResultsKeyword = ""
    @Published var isGlobalSearching = false
    /// 最近的跨源搜索词：搜索框聚焦且为空时展示。
    @Published var recentSearches: [String] = []
    /// 自然语言搜索的解析结果（展示成条件胶囊）。
    @Published var globalQueryPlan: CatalogQueryPlan?
    /// 更新日历：本机第一次看到某条内容的日期（从开始使用起累积）。
    @Published var calendarItems: [CatalogCalendarItem] = []
    /// 最近一次补录新进来的条目（`sourceID|itemID`）：日历里高亮并排最前。
    @Published var calendarNewIDs: [String] = []
    /// 正在扫描各源首页，把今天新出现的条目补进日历。
    @Published var isCalendarRefreshing = false
    /// 日历上次选中的日期（跨启动还原）。
    @Published var calendarSelectedDay: Date?
    /// 跨源自定义片单。
    @Published var playlists: [CatalogPlaylist] = []
    /// 聚合片单：按关键字跨源动态聚合。
    @Published var smartPlaylists: [CatalogSmartPlaylist] = []
    /// 每个聚合片单最近一次的结果。
    @Published var smartResults: [UUID: [CatalogGlobalResult]] = [:]
    /// 每个聚合片单相对上一次结果新增的条目（`sourceID|itemID`）。
    @Published var smartNewIDs: [UUID: [String]] = [:]
    @Published var smartLoading: Set<UUID> = []
    /// 网络资源区当前分页：浏览 / 片单 / 更新日历。
    @Published var hubTab: CatalogHubTab = .browse
    /// 关注的女优 / 片商。
    @Published var followedPeople: [CatalogFollowedPerson] = []
    /// 关注页封面墙：每个人跨源聚合到的最新封面（最多 4 张），持久化避免每次重查。
    @Published var followPosters: [String: [CatalogFollowPoster]] = [:]
    /// 关注人物的聚合快照：打开档案先铺历史，再在后台刷新并标出新条目。
    @Published var followAggregates: [String: CatalogFollowAggregate] = [:]
    /// 正在查看的人物档案：按名字跨源聚合的结果。
    @Published var personProfile: CatalogPersonProfile?
    @Published var isPersonLoading = false

    // 以下为发现功能的内部缓存（供 +Discovery 扩展使用）。
    var lastSeenTop: [UUID: String] = [:]
    /// 已加载过榜单的域：两个域各自判断缓存是否新鲜。
    var spotlightLoadedDomains: Set<CatalogDomain> = []
    var spotlightHotLoadedDomains: Set<CatalogDomain> = []
    /// 当前正在补录哪个域的更新日历：两个域共用一套日历表，但扫描与节流各自独立。
    var calendarScanDomain: CatalogDomain?
    var healthTask: Task<Void, Never>?
    var globalSearchTask: Task<Void, Never>?
    var previewCache: [String: CatalogPreviewTarget] = [:]
    var previewMissAt: [String: Date] = [:]
    /// 同时只解析一个悬停预览：鼠标扫过网格时不再给站点打一串请求。
    var previewInFlight = 0
    /// 正在请求的首屏 key：快速切换源时不重复发起同一个请求。
    var inFlightKey: String?
    static let discoveryPinsKey = "catalog.pins.v2"
    static let categoryPinsKey = "catalog.categoryPins.v2"
    static let followsKey = "catalog.follows.v2"
    static let lastSeenTopKey = "catalog.lastSeenTop.v2"
    static let newFlagsKey = "catalog.newFlags.v2"
    static let lastViewKey = "catalog.lastView.v2"
    /// 上次浏览的源：重启后直接回到它，而不是永远落到第一个启用的源。
    static let selectedSourceKey = "catalog.selectedSource.v1"
    /// 退出时停在的频道详情：重启后第一次进入对应源时铺开这一页。
    static let inlineDetailKey = "catalog.inlineDetail.v1"
    static let spotlightModeKey = "catalog.spotlightMode.v1"
    static let calendarSelectedDayKey = "catalog.calendar.selectedDay.v1"
    static let calendarScanAtKey = "catalog.calendar.scanAt.v1"
    /// 每个源补录到第几页：下次继续往下翻，慢慢把日历铺满。
    static let calendarCursorKey = "catalog.calendar.cursor.v1"
    /// 是否已用标题 / 备注里的日期回填过旧日历记录。
    static let calendarDateParseKey = "catalog.calendar.dateParse.v1"
    static let recentSearchesKey = "catalog.recentSearches.v1"
    static let playlistsKey = "catalog.playlists.v1"
    static let smartPlaylistsKey = "catalog.smartPlaylists.v1"
    static let smartResultsKey = "catalog.smartResults.v1"
    static let smartNewIDsKey = "catalog.smartPlaylistNew.v1"
    static let calendarNewIDsKey = "catalog.calendar.newIDs.v1"
    static let hubTabKey = "catalog.hubTab.v1"
    static let peopleKey = "catalog.people.v1"
    static let followPostersKey = "catalog.follow.posters.v1"
    static let followAggregatesKey = "catalog.follow.aggregates.v1"

    /// 播放交给宿主（图库查看器）处理；未绑定时退化到内置小窗口。
    var onPlayback: ((CatalogPlaybackRequest) -> Void)?
    /// 片单整单连播：把多个条目拼成同一个查看器会话。
    var onPlaylistPlayback: (([CatalogPlaylistPlaybackItem]) -> Void)?

    func emit(_ request: CatalogPlaybackRequest) {
        if let onPlayback {
            onPlayback(request)
        } else {
            playback = request
        }
    }

    private var page = 1
    private var task: Task<Void, Never>?
    /// 每次重新加载自增：迟到的请求不能覆盖用户已经切走的页面。
    private var requestToken = 0
    /// 详情请求的代次：快速点不同条目时，旧详情不能覆盖新条目、也不能提前清掉转圈。
    private var detailToken = 0
    /// 更新日历的后台扫描任务：手动刷新时可以取消重来，不会卡在「正在补录」。
    var calendarTask: Task<Void, Never>?
    /// 更新日历在统一任务中心的登记 id。
    var calendarJobID: UUID?
    /// 操作提示的自增标记：旧的自动消失任务不能清掉新提示。
    private var noticeToken = 0
    /// 二级标签的请求标记：切换分类时迟到的结果不能覆盖新上下文。
    private var tagsToken = 0
    private var cachedPages: [String: CachedPage] = [:]
    /// 上次成功加载的首屏快照：先铺内容再请求最新，切换源时不会先闪一片骨架。
    var pageSnapshots: [String: CatalogPageSnapshot] = [:]
    var cachedDetails: [String: CatalogDetail] = [:]

    private static let sourcesKey = "catalog.sources.v1"
    private static let favoritesKey = "catalog.favorites.v1"
    private static let watchedKey = "catalog.watched.v1"
    private static let categoryThumbsKey = "catalog.categoryThumbs.v1"
    /// 本次启动已经为哪些源补过分类缩略图，避免反复请求站点。
    private var thumbAttemptedSources: Set<UUID> = []
    private var thumbTask: Task<Void, Never>?

    private struct CachedPage {
        var page: CatalogPage
        var fetchedAt: Date
    }

    init() {}

    // MARK: 退出时记住当前详情

    /// 退出应用时正打开着的频道详情：启动后第一次进入对应源时交给频道页铺开，
    /// 只还原一次，之后切换源或返回列表都不再出现。
    private var launchInlineDetail: (sourceID: UUID, item: CatalogItem)?
    /// 加载图库配置期间不要回写详情：清空旧状态会误删上次保存的那一页。
    private var isLoadingLibraryState = false

    private struct StoredInlineDetail: Codable {
        let sourceID: UUID
        let item: CatalogItem
    }

    /// 频道页进入某个源时调用：返回上次退出时停的详情（只给一次）。
    func consumeLaunchInlineDetail(for sourceID: UUID) -> CatalogItem? {
        defer { launchInlineDetail = nil }
        guard let saved = launchInlineDetail, saved.sourceID == sourceID else { return nil }
        return saved.item
    }

    private static func savedInlineDetail() -> (sourceID: UUID, item: CatalogItem)? {
        guard let data = CatalogStore.data(forKey: Self.inlineDetailKey),
              let saved = try? JSONDecoder().decode(StoredInlineDetail.self, from: data) else { return nil }
        return (saved.sourceID, saved.item)
    }

    private func persistInlineDetail() {
        guard !isLoadingLibraryState else { return }
        guard let item = inlineDetailItem, let sourceID = selectedSourceID,
              let data = try? JSONEncoder().encode(StoredInlineDetail(sourceID: sourceID, item: item)) else {
            CatalogStore.set(nil, forKey: Self.inlineDetailKey)
            return
        }
        CatalogStore.set(data, forKey: Self.inlineDetailKey)
    }

    /// 读取当前图库自己的网络资源配置。
    /// 图库切换后由宿主调用：先清空上一个图库的状态，再加载新图库的数据。
    func loadForCurrentLibrary() {
        let savedInline = Self.savedInlineDetail()
        isLoadingLibraryState = true
        defer { isLoadingLibraryState = false }
        task?.cancel()
        requestToken &+= 1
        sources = []
        selectedSourceID = nil
        section = .home
        categories = []
        tags = []
        activeTopCategoryID = nil
        items = []
        detail = nil
        detailError = nil
        inlineDetailItem = nil
        detailPersonTarget = nil
        followedProfile = nil
        openPlaylistPage = nil
        pendingInlineItem = nil
        error = nil
        sourceError = nil
        isLoading = false
        listSnapshotAt = nil
        freshItemKeys = []
        progress = [:]
        favorites = [:]
        categoryThumbs = [:]
        cachedPages = [:]
        cachedDetails = [:]
        pageSnapshots = [:]
        previewCache = [:]
        previewMissAt = [:]
        pinnedSourceIDs = []
        pinnedCategoryIDs = [:]
        followedCategories = []
        followedPeople = []
        followPosters = [:]
        followAggregates = [:]
        newSourceIDs = []
        lastSeenTop = [:]
        calendarItems = []
        calendarNewIDs = []
        calendarSelectedDay = nil
        isCalendarRefreshing = false
        playlists = []
        smartPlaylists = []
        smartResults = [:]
        smartNewIDs = [:]
        smartLoading = []
        spotlightByDomain = [:]
        spotlightHotByDomain = [:]
        todaySpotlight = []
        spotlightLoadedDomains = []
        spotlightHotLoadedDomains = []
        health = [:]
        healthLatency = [:]
        healthCheckedAt = [:]
        localSort = nil
        sort = .latest
        hubTab = browseTabFromDisk()
        channelRequests = []
        thumbAttemptedSources = []

        load()
        pageSnapshots = CatalogSnapshotStore.load()
        pruneSnapshots()
        if let data = CatalogStore.data(forKey: Self.smartResultsKey),
           let cached = try? JSONDecoder().decode([UUID: [CatalogGlobalResult]].self, from: data) {
            smartResults = cached
        }
        if let data = CatalogStore.data(forKey: Self.smartNewIDsKey),
           let cached = try? JSONDecoder().decode([UUID: [String]].self, from: data) {
            smartNewIDs = cached
        }
        // 总榜按域分别铺上次的结果：网络资源与网络影院各自恢复，不互相覆盖。
        for domain in CatalogDomain.allCases {
            if let data = CatalogStore.data(forKey: Self.spotlightLatestKey(for: domain)),
               let cached = try? JSONDecoder().decode([CatalogSpotlightItem].self, from: data) {
                spotlightByDomain[domain] = cached
            }
            if let data = CatalogStore.data(forKey: Self.spotlightHotKey(for: domain)),
               let cached = try? JSONDecoder().decode([CatalogSpotlightItem].self, from: data) {
                spotlightHotByDomain[domain] = cached
            }
        }
        let storedID = CatalogStore.string(forKey: Self.selectedSourceKey)
            .flatMap(UUID.init(uuidString:))
        // 网络资源只认网页资源站：旧版本可能把影视源存成「当前资源」，这里直接忽略。
        if let storedID,
           let source = sources.first(where: { $0.id == storedID && $0.domain == .networkResource }) {
            selectedSourceID = source.id
            prepare(source: source)
        } else if let first = enabledResourceSources.first ?? resourceSources.first {
            selectedSourceID = first.id
            prepare(source: first)
        }
        CatalogStore.string(forKey: Self.selectedSourceKey, value: selectedSourceID?.uuidString)
        restoreLastView()
        // 上次退出时停在详情页：等频道页第一次进入这个源时再铺开。
        if let savedInline, savedInline.sourceID == selectedSourceID {
            launchInlineDetail = savedInline
        }

        // 后台预热更新日历：避开首屏请求，稍后且用户空闲时逐源补录历史日期。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            self?.refreshCalendarToday()
        }
    }

    private func browseTabFromDisk() -> CatalogHubTab {
        guard let raw = CatalogStore.string(forKey: Self.hubTabKey),
              let tab = CatalogHubTab(rawValue: raw) else { return .browse }
        return tab
    }

    /// 总榜缓存键：两个域各存一份，切模块不会互相覆盖。
    static func spotlightLatestKey(for domain: CatalogDomain) -> String {
        domain == .networkCinema ? "catalog.spotlight.latest.cinema.v1" : "catalog.spotlight.latest.v1"
    }

    static func spotlightHotKey(for domain: CatalogDomain) -> String {
        domain == .networkCinema ? "catalog.spotlight.hot.cinema.v1" : "catalog.spotlight.hot.v1"
    }

    // MARK: - 派生状态

    var selectedSource: CatalogSource? {
        sources.first(where: { $0.id == selectedSourceID })
    }

    /// 用户正在等一份内容：后台补录和悬停预览此时都让路。
    var isUserBusy: Bool {
        isLoading || isLoadingMore || isLoadingDetail || isGlobalSearching
    }

    /// 这次失败更像是站点要求人机验证 / 拦截，而不是单纯网络问题。
    var errorNeedsVerification: Bool {
        guard let error else { return false }
        if let id = selectedSourceID, health[id] == .limited { return true }
        let text = error.lowercased()
        let marks = ["403", "forbidden", "waf", "pow", "challenge",
                     "cloudflare", "captcha", "验证", "拦截"]
        return marks.contains { text.contains($0) }
    }

    /// 显示一条自动消失的操作提示（保存到图库等）。
    func showNotice(_ text: String) {
        notice = text
        noticeToken &+= 1
        let token = noticeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }

    /// 全部已启用的目录源。跨源聚合必须按域再筛一次，不能直接用这一份。
    var enabledSources: [CatalogSource] {
        sources.filter(\.isEnabled)
    }

    /// 指定域的源清单。
    func sources(in domain: CatalogDomain) -> [CatalogSource] {
        sources.filter { $0.domain == domain }
    }

    /// 指定域内已启用的源清单。
    func enabledSources(in domain: CatalogDomain) -> [CatalogSource] {
        sources.filter { $0.isEnabled && $0.domain == domain }
    }

    /// 网络资源（网页资源站）的源：影视源只在网络影院出现。
    var resourceSources: [CatalogSource] { sources(in: .networkResource) }
    var enabledResourceSources: [CatalogSource] { enabledSources(in: .networkResource) }
    /// 网络影院的影视源。
    var cinemaSources: [CatalogSource] { sources(in: .networkCinema) }
    var enabledCinemaSources: [CatalogSource] { enabledSources(in: .networkCinema) }

    var resourceSourceIDs: Set<UUID> { Set(resourceSources.map(\.id)) }
    var cinemaSourceIDs: Set<UUID> { Set(cinemaSources.map(\.id)) }

    func isSource(_ id: UUID, in domain: CatalogDomain) -> Bool {
        sources.first { $0.id == id }?.domain == domain
    }

    /// 网络资源自己的稍后看：只看网页资源站的条目。
    var resourceFavorites: [CatalogFavorite] {
        let ids = resourceSourceIDs
        return favorites.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 网络影院自己的稍后看：只看影视源里的条目。
    var cinemaFavorites: [CatalogFavorite] {
        let ids = cinemaSourceIDs
        return favorites.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 网络资源自己的观看足迹。
    var resourceContinueWatching: [CatalogProgress] {
        let ids = resourceSourceIDs
        return progress.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 网络影院自己的观看足迹。
    var cinemaContinueWatching: [CatalogProgress] {
        let ids = cinemaSourceIDs
        return progress.values
            .filter { ids.contains($0.sourceID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var continueWatching: [CatalogProgress] {
        progress.values
            .filter { $0.sourceID == selectedSourceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var allContinueWatching: [CatalogProgress] {
        progress.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var currentFavorites: [CatalogFavorite] {
        favorites.values
            .filter { $0.sourceID == selectedSourceID }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func favoriteCount(for sourceID: UUID) -> Int {
        favorites.values.filter { $0.sourceID == sourceID }.count
    }

    func isFavorite(sourceID: UUID, itemID: String) -> Bool {
        favorites["\(sourceID.uuidString)|\(itemID)"] != nil
    }

    func toggleFavorite(source: CatalogSource, item: CatalogItem) {
        let key = "\(source.id.uuidString)|\(item.id)"
        if favorites[key] != nil {
            favorites[key] = nil
        } else {
            favorites[key] = CatalogFavorite(sourceID: source.id, itemID: item.id,
                                             title: item.title, coverURL: item.coverURL,
                                             remark: item.remark, addedAt: Date())
        }
        saveFavorites()
    }

    /// 批量加入 / 移出稍后看：只处理状态不同的条目，不会把已在稍后看里的又切回去。
    func setFavorite(_ favorite: Bool, source: CatalogSource, items: [CatalogItem]) {
        var changed = 0
        for item in items {
            let key = "\(source.id.uuidString)|\(item.id)"
            guard (favorites[key] != nil) != favorite else { continue }
            if favorite {
                favorites[key] = CatalogFavorite(sourceID: source.id, itemID: item.id,
                                                 title: item.title, coverURL: item.coverURL,
                                                 remark: item.remark, addedAt: Date())
            } else {
                favorites[key] = nil
            }
            changed += 1
        }
        guard changed > 0 else { return }
        saveFavorites()
        showNotice(favorite ? "已加入稍后看 \(changed) 条" : "已移出稍后看 \(changed) 条")
    }

    // MARK: - 手动标记已看

    func isMarkedWatched(sourceID: UUID, itemID: String) -> Bool {
        watchedKeys.contains("\(sourceID.uuidString)|\(itemID)")
    }

    /// 批量标记已看：只写标记，不伪造播放进度，足迹页的时长与统计保持干净。
    func markWatched(source: CatalogSource, items: [CatalogItem]) {
        let keys = items.map { "\(source.id.uuidString)|\($0.id)" }
        let added = keys.filter { !watchedKeys.contains($0) }
        guard !added.isEmpty else {
            showNotice("选中的条目都已标记为已看")
            return
        }
        watchedKeys.formUnion(added)
        saveWatched()
        showNotice("已标记 \(added.count) 条为已看")
    }

    var currentCategory: CatalogCategory? {
        guard case .category(let id) = section else { return nil }
        return categories.first(where: { $0.id == id })
    }

    /// 当前浏览范围所属的一级分类：二级 tab 与高亮都挂在它下面。
    /// 三级站点的二级分类 id 通常带一级前缀；分组节点（如「午夜影院」）自身没有页面，
    /// 需要再看它的 children 是否包含当前分类。
    var activeTopCategory: CatalogCategory? {
        if let id = activeTopCategoryID,
           let match = categories.first(where: { $0.id == id }) {
            return match
        }
        switch section {
        case .category(let id):
            return categories.first(where: { top in
                if top.id == id || id.hasPrefix(top.id + "/") { return true }
                return top.children?.contains(where: { $0.id == id }) == true
            })
        case .rank:
            return categories.first(where: { $0.isRank })
        default:
            return nil
        }
    }

    /// 当前一级分类的二级分类（站点频道页里的 tab）。
    var subCategories: [CatalogCategory] {
        activeTopCategory?.children ?? []
    }

    /// 侧边栏要显示的菜单项：当前源优先用站点实时分类，其余源仍用随源保存的骨架。
    /// 这样左侧菜单与内容区 chips 永远是同一份分类，不会一边「AI 短剧」一边「短剧」。
    func sidebarCategories(for source: CatalogSource) -> [CatalogCategory] {
        if selectedSourceID == source.id, !categories.isEmpty { return categories }
        return source.categories
    }

    /// 当前源里，某个一级分类是否正处于浏览范围（含它下面的二级分类）。
    func isBrowsing(_ category: CatalogCategory, sourceID: UUID) -> Bool {
        guard selectedSourceID == sourceID else { return false }
        return activeTopCategory?.id == category.id
    }

    // MARK: - 分类缩略图

    /// 侧边栏分类行显示用的缩略图：该分类第一张卡片的封面。
    func thumbURL(for category: CatalogCategory, sourceID: UUID) -> String? {
        categoryThumbs[Self.thumbKey(sourceID: sourceID, categoryID: category.id)]
    }

    private static func thumbKey(sourceID: UUID, categoryID: String) -> String {
        "\(sourceID.uuidString)|\(categoryID)"
    }

    private func storeThumb(_ url: String, categoryID: String, sourceID: UUID) {
        guard !url.isEmpty else { return }
        let key = Self.thumbKey(sourceID: sourceID, categoryID: categoryID)
        guard categoryThumbs[key] != url else { return }
        categoryThumbs[key] = url
        saveCategoryThumbs()
    }

    /// 给还没有缩略图的分类补一张首图：串行、少量，且每个源每次启动只补一次。
    /// 缩略图只是锦上添花，请求失败就跳过，不影响分类本身。
    func prefetchCategoryThumbs(for source: CatalogSource) {
        guard source.isEnabled,
              let provider = CatalogProviders.provider(for: source.kind),
              thumbAttemptedSources.insert(source.id).inserted else { return }

        // 侧边栏只显示一级分类：分组就用它的第一个子项取图，缩略图挂在分组 id 上。
        let pending: [(menu: CatalogCategory, target: CatalogCategory)] = sidebarCategories(for: source)
            .compactMap { menu in
                guard !menu.isRank, !menu.id.isEmpty else { return nil }
                let target = menu.isGroupCategory
                    ? menu.children?.first(where: { !$0.isRank && !$0.id.isEmpty })
                    : menu
                guard let target,
                      thumbURL(for: menu, sourceID: source.id) == nil else { return nil }
                return (menu, target)
            }
        guard !pending.isEmpty else { return }

        thumbTask?.cancel()
        thumbTask = Task { [weak self] in
            for entry in pending {
                if Task.isCancelled { break }
                guard let self, self.selectedSourceID == source.id else { break }
                // 分类之间留间隔：一次二十来个分类也不能把源打到限流。
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let page = try? await provider.category(source: source,
                                                              category: entry.target,
                                                              sort: .latest,
                                                              page: 1),
                      let cover = page.items.first(where: { !$0.coverURL.isEmpty })?.coverURL
                else { continue }
                self.storeThumb(cover, categoryID: entry.menu.id, sourceID: source.id)
            }
        }
    }

    /// 按 id 在任何层级里找分类：优先二级分类，保证标题显示的是具体频道。
    func category(withID id: String) -> CatalogCategory? {
        for top in categories {
            if let child = top.children?.first(where: { $0.id == id }) { return child }
        }
        for top in categories where top.id == id { return top }
        // 标签可能是分组结构（片商 / 衣着 / 身材 / 玩法），叶子项也要能找到。
        for group in tags {
            if let child = group.children?.first(where: { $0.id == id }) { return child }
            if group.id == id { return group }
        }
        return nil
    }

    var sectionTitle: String {
        switch section {
        case .home: return "首页"
        case .category(let id): return category(withID: id)?.title ?? "分类"
        case .rank: return "排行榜"
        case .search(let keyword): return "搜索“\(keyword)”"
        case .continueWatching: return "继续观看"
        case .favorites: return "稍后看"
        }
    }

    // MARK: - 导航

    func selectSource(_ id: UUID?) {
        // 网络资源只接受网页资源站：影视源只在网络影院里浏览。
        guard let id,
              let source = sources.first(where: { $0.id == id && $0.domain == .networkResource })
        else {
            selectedSourceID = nil
            CatalogStore.string(forKey: Self.selectedSourceKey, value: nil)
            items = []
            return
        }
        selectedSourceID = source.id
        CatalogStore.string(forKey: Self.selectedSourceKey, value: source.id.uuidString)
        markSourceViewed(source.id)
        prepare(source: source)
        openHome()
    }

    /// 只切换当前源，不重新加载：侧边栏点分类前先调用，随后由具体动作决定加载哪一页。
    func focus(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id && $0.domain == .networkResource }) else { return }
        markSourceViewed(source.id)
        if selectedSourceID != id {
            selectedSourceID = id
            CatalogStore.string(forKey: Self.selectedSourceKey, value: id.uuidString)
            prepare(source: source)
        }
    }

    func openHome() {
        section = .home
        activeTopCategoryID = nil
        rememberView()
        if let source = selectedSource {
            refreshTags(source: source, category: nil)
        }
        reload()
    }

    func openCategory(_ category: CatalogCategory) {
        // 分组节点（如「午夜影院」）自己没有页面，等价于打开第一个子频道。
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { return }
        section = target.isRank ? .rank : .category(target.id)
        // 记住实际点开的一级：同一个二级 id 可能挂在多个一级下，不能按 id 反查。
        if target.isRank {
            activeTopCategoryID = categories.first(where: { $0.isRank })?.id
        } else if let top = topCategory(for: category) {
            activeTopCategoryID = top.id
        }
        // 标签是当前主分类下的二级筛选：点标签时保持上下文，不退回全局标签。
        if let source = selectedSource, !isKnownTag(target) {
            refreshTags(source: source, category: activeTopCategory)
        }
        // 站点把二级频道挂在分类页里（肉视频的片商）：点开一级时再取。
        if let source = selectedSource, let top = activeTopCategory,
           top.children?.isEmpty ?? true {
            loadChannels(source: source, category: top)
        }
        sort = .latest
        localSort = nil
        rememberView()
        reload()
    }

    func openRank() {
        section = .rank
        activeTopCategoryID = categories.first(where: { $0.isRank })?.id
        rememberView()
        if let source = selectedSource {
            refreshTags(source: source, category: nil)
        }
        reload()
    }

    /// 分类所属的一级分组。二级 id 重复挂在不同一级下时（XSZAV 的「無碼流出」
    /// 既在「日本AV」也在「無碼影片」里），优先沿用正在浏览的一级，再退回第一个匹配。
    private func topCategory(for category: CatalogCategory) -> CatalogCategory? {
        if let direct = categories.first(where: { $0.id == category.id }) { return direct }
        if let current = activeTopCategory,
           current.children?.contains(where: { $0.id == category.id }) == true {
            return current
        }
        return categories.first { top in
            top.children?.contains(where: { $0.id == category.id }) ?? false
        }
    }

    func openContinueWatching() {
        openLocalSection(.continueWatching)
    }

    func openFavorites() {
        openLocalSection(.favorites)
    }

    private func openLocalSection(_ target: CatalogSection) {
        task?.cancel()
        requestToken &+= 1
        section = target
        activeTopCategoryID = nil
        items = []
        hasMore = false
        error = nil
        sourceError = nil
        isLoading = false
        isLoadingMore = false
    }

    func focusSearch() {
        searchFocusToken &+= 1
    }

    func setSort(_ value: CatalogSort) {
        guard sort != value || localSort != nil else { return }
        sort = value
        localSort = nil
        reload()
    }

    /// 站点支持的排序：界面只用这些选项，避免点了没反应。
    var supportedSorts: [CatalogSort] {
        guard let source = selectedSource,
              let provider = CatalogProviders.provider(for: source.kind) else { return [.latest] }
        return provider.supportedSorts
    }

    /// 本页排序：只重排当前已加载的条目，不重新请求站点。
    func setLocalSort(_ value: CatalogLocalSort) {
        localSort = localSort == value ? nil : value
        applyLocalSortIfNeeded()
    }

    func search(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchText = trimmed
        section = .search(trimmed)
        activeTopCategoryID = nil
        reload()
    }

    // MARK: - 列表加载

    func refresh() {
        cachedPages.removeAll()
        reload()
    }

    func reload() {
        task?.cancel()
        requestToken &+= 1
        let token = requestToken
        isLoadingMore = false
        guard let source = selectedSource else {
            items = []
            hasMore = false
            isLoading = false
            inFlightKey = nil
            return
        }
        guard source.isEnabled else {
            items = []
            hasMore = false
            error = nil
            sourceError = nil
            isLoading = false
            inFlightKey = nil
            return
        }

        page = 1
        error = nil
        sourceError = nil
        freshItemKeys = []
        let key = cacheKey(source: source, page: 1)
        // 注意：这里不能「同 key 在途就直接 return」。
        // 上面已经取消旧任务并换了 token，旧任务回来时会被 token 校验丢掉；
        // 如果这里直接返回，isLoading 会永远停在 true，之后整个列表都加载不出来。
        inFlightKey = key
        if let cached = cachedPages[key], Date().timeIntervalSince(cached.fetchedAt) < 120 {
            items = cached.page.items
            hasMore = cached.page.hasMore
            listSnapshotAt = nil
            isLoading = false
            inFlightKey = nil
            applyLocalSortIfNeeded()
            return
        }

        isLoading = true
        // 先用上次的首屏快照铺满，再在后台请求最新；没有快照才显示骨架。
        if let snapshot = pageSnapshots[key] {
            items = snapshot.items
            hasMore = snapshot.hasMore
            listSnapshotAt = snapshot.savedAt
            applyLocalSortIfNeeded()
        } else {
            items = []
            listSnapshotAt = nil
        }
        task = Task { [weak self] in
            await self?.load(page: 1, source: source, token: token)
        }
    }

    func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore, let source = selectedSource else { return }
        isLoadingMore = true
        let next = page + 1
        let token = requestToken
        task = Task { [weak self] in
            await self?.load(page: next, source: source, token: token)
        }
    }

    private func load(page: Int, source: CatalogSource, token: Int) async {
        // 只让「当前这一代」请求收尾：被取消 / 已被替换的请求不能动标志位，
        // 更不能把新请求的 isLoading 提前置 false。
        defer {
            if token == requestToken {
                isLoading = false
                isLoadingMore = false
                inFlightKey = nil
            }
        }
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            error = CatalogError.unsupportedProvider.localizedDescription
            sourceError = .unsupported(error ?? "当前来源不支持这个操作")
            return
        }
        do {
            let result: CatalogPage
            switch section {
            case .home:
                result = try await provider.home(source: source, page: page)
            case .category(let id):
                let category = category(withID: id)
                    ?? CatalogCategory(id: id, title: id)
                result = try await provider.category(source: source, category: category,
                                                     sort: sort, page: page)
            case .rank:
                let category = categories.first(where: { $0.isRank })
                    ?? CatalogCategory(id: "ranks/hot", title: "排行榜", isRank: true)
                result = try await provider.category(source: source, category: category,
                                                     sort: .latest, page: page)
            case .search(let keyword):
                result = try await provider.search(source: source, keyword: keyword, page: page)
            case .continueWatching, .favorites:
                return
            }

            guard !Task.isCancelled, token == requestToken else { return }
            // 浏览过的分类顺手记下首图，侧边栏下次直接用真实缩略图。
            if page == 1, case .category(let id) = section,
               let cover = result.items.first(where: { !$0.coverURL.isEmpty })?.coverURL {
                storeThumb(cover, categoryID: id, sourceID: source.id)
            }
            if page == 1 {
                // 与上次同一列表的快照比较：新出现的条目打「刚上架」。
                let listKey = cacheKey(source: source, page: 1)
                let previousIDs = Set((pageSnapshots[listKey]?.items ?? []).map(\.id))
                if previousIDs.isEmpty {
                    freshItemKeys = []
                } else {
                    freshItemKeys = Set(result.items
                        .filter { !previousIDs.contains($0.id) }
                        .map { "\(source.id.uuidString)|\($0.id)" })
                }
                items = result.items
                if case .home = section, let top = result.items.first {
                    recordTopItem(top.id, sourceID: source.id)
                }
                // 首页与分类页都算「今天看到过」：日历会随着浏览慢慢补齐。
                switch section {
                case .home, .category:
                    recordCalendar(items: Array(result.items.prefix(24)), sourceID: source.id)
                default:
                    break
                }
            } else {
                items.append(contentsOf: result.items.filter { item in
                    !items.contains(where: { $0.id == item.id })
                })
            }
            hasMore = result.hasMore
            self.page = page
            error = nil
            sourceError = nil
            if page == 1 { listSnapshotAt = nil }
            applyLocalSortIfNeeded()
            let key = cacheKey(source: source, page: page)
            cachedPages[key] = CachedPage(page: result, fetchedAt: Date())
            if page == 1 {
                storeSnapshot(result, for: key)
            }
        } catch {
            guard token == requestToken, !Task.isCancelled else { return }
            // 有快照就继续显示快照（页面顶部会提示离线视图），没有才退回空态。
            if page == 1, listSnapshotAt == nil { items = [] }
            self.error = error.localizedDescription
            self.sourceError = SourceErrorMapper.map(error)
            Diagnostics.record("影视源加载失败 \(source.name) \(sectionTitle)：\(error.localizedDescription)")
        }
    }

    // MARK: - 本页排序

    /// 首屏快照：每个列表最多 60 条；15 天未更新的按 LRU 淘汰，整体最多留 80 个。
    private func storeSnapshot(_ page: CatalogPage, for key: String) {
        guard !page.items.isEmpty else { return }
        let snapshot = CatalogPageSnapshot(items: Array(page.items.prefix(60)),
                                           page: page.page,
                                           hasMore: page.hasMore,
                                           savedAt: Date())
        pageSnapshots[key] = snapshot
        CatalogSnapshotStore.save(snapshot, forKey: key)
        pruneSnapshots()
    }

    /// 快照的 LRU 收敛：先丢 15 天没碰过的，再按最近更新时间保留 80 个（数据库里同样执行）。
    private func pruneSnapshots() {
        let cutoff = Date().addingTimeInterval(-15 * 24 * 60 * 60)
        pageSnapshots = pageSnapshots.filter { $0.value.savedAt >= cutoff }
        if pageSnapshots.count > 80 {
            let kept = pageSnapshots.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(80)
            pageSnapshots = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        CatalogSnapshotStore.prune(cutoff: cutoff, limit: 80)
    }

    /// 站点不支持排序时的兜底：只重排已经拿到的这一批条目。
    private func applyLocalSortIfNeeded() {
        guard let localSort else { return }
        items = Self.sorted(items, by: localSort, firstSeen: calendarFirstSeen)
    }

    private var calendarFirstSeen: [String: Date] {
        guard let sourceID = selectedSourceID else { return [:] }
        var map: [String: Date] = [:]
        for entry in calendarItems where entry.sourceID == sourceID {
            map[entry.itemID] = entry.firstSeen
        }
        return map
    }

    static func sorted(_ items: [CatalogItem], by sort: CatalogLocalSort,
                       firstSeen: [String: Date]) -> [CatalogItem] {
        switch sort {
        case .title:
            return items.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .year:
            return items.sorted {
                let left = CatalogQueryPlan.year(in: $0.title + " " + $0.remark) ?? 0
                let right = CatalogQueryPlan.year(in: $1.title + " " + $1.remark) ?? 0
                return left > right
            }
        case .duration:
            return items.sorted {
                durationSeconds($0.remark) > durationSeconds($1.remark)
            }
        case .firstSeen:
            return items.sorted {
                (firstSeen[$0.id] ?? .distantPast) > (firstSeen[$1.id] ?? .distantPast)
            }
        }
    }

    /// 从备注里读 `12:34` / `1:02:03` 这类时长。
    static func durationSeconds(_ text: String) -> Int {
        guard let range = text.range(of: #"\d{1,2}(:\d{2}){1,2}"#,
                                     options: .regularExpression) else { return 0 }
        let parts = text[range].split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    // MARK: - 详情

    func loadDetail(item: CatalogItem, force: Bool = false) {
        guard let source = selectedSource else { return }
        let key = detailKey(source: source, itemID: item.id)
        detailToken &+= 1
        let token = detailToken
        if !force, let cached = cachedDetails[key] {
            detail = cached
            detailError = nil
            isLoadingDetail = false
            // 详情里的女优字段顺手补进识别词典：以后标题里也能认出她。
            CatalogNameParser.learn(from: cached)
            return
        }
        isLoadingDetail = true
        detail = nil
        detailError = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                if token == self.detailToken { self.isLoadingDetail = false }
            }
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                self.detailError = CatalogError.unsupportedProvider.localizedDescription
                return
            }
            do {
                var result = try await provider.detail(source: source, itemID: item.id)
                guard token == self.detailToken, !Task.isCancelled else { return }
                if result.item.coverURL.isEmpty { result.item.coverURL = item.coverURL }
                if result.item.title.isEmpty { result.item.title = item.title }
                self.cachedDetails[key] = result
                self.detail = result
                CatalogNameParser.learn(from: result)
            } catch {
                guard token == self.detailToken, !Task.isCancelled else { return }
                self.detailError = error.localizedDescription
            }
        }
    }

    func closeDetail() {
        detail = nil
        detailError = nil
        isLoadingDetail = false
        inlineDetailItem = nil
        detailPersonTarget = nil
    }

    // MARK: - 播放

    /// 从详情页点播放时记下的返回目标：关闭播放器后回到那一页详情。
    private var playbackReturnItem: CatalogItem?

    /// 取走并清空返回目标（只在接住这一次播放时有效）。
    func takePlaybackReturnItem() -> CatalogItem? {
        defer { playbackReturnItem = nil }
        return playbackReturnItem
    }

    func play(item: CatalogItem, episode: CatalogEpisode, seconds: Double = 0) {
        guard let source = selectedSource else { return }
        playbackReturnItem = item
        let request = CatalogPlaybackRequest(source: source, item: item,
                                             episodes: detail?.episodes ?? [episode],
                                             startEpisode: episode.index,
                                             startSeconds: seconds)
        emit(request)
    }

    func play(item: CatalogItem, detail: CatalogDetail, episode: CatalogEpisode, seconds: Double) {
        guard let source = selectedSource else { return }
        playbackReturnItem = item
        emit(CatalogPlaybackRequest(source: source, item: item, episodes: detail.episodes,
                                    startEpisode: episode.index, startSeconds: seconds))
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            throw CatalogError.unsupportedProvider
        }
        return try await provider.stream(source: source, episode: episode)
    }

    func closePlayer() {
        playback = nil
    }

    /// 从「继续观看」恢复：先补齐分集，再以保存的秒数起播。
    func resume(_ record: CatalogProgress) {
        guard let source = sources.first(where: { $0.id == record.sourceID }),
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await provider.detail(source: source, itemID: record.itemID)
                guard let episode = detail.episodes.first(where: { $0.index == record.episode })
                        ?? detail.episodes.first else { return }
                self.cachedDetails[self.detailKey(source: source, itemID: record.itemID)] = detail
                self.selectedSourceID = source.id
                self.emit(CatalogPlaybackRequest(
                    source: source, item: detail.item, episodes: detail.episodes,
                    startEpisode: episode.index, startSeconds: record.seconds))
            } catch {
                self.error = error.localizedDescription
                self.sourceError = SourceErrorMapper.map(error)
            }
        }
    }

    /// 从头播放：忽略已保存的秒数，仍按记录的集数起播。
    func restart(_ record: CatalogProgress) {
        var fresh = record
        fresh.seconds = 0
        resume(fresh)
    }

    func progress(sourceID: UUID, itemID: String) -> CatalogProgress? {
        progress[CatalogProgress.key(sourceID: sourceID, itemID: itemID)]
    }

    /// 把一条记录移出观看足迹。
    func removeProgress(_ record: CatalogProgress) {
        progress[record.key] = nil
        CatalogStore.deleteProgress(keys: [record.key])
    }

    /// 清空观看足迹。传 `sourceIDs` 时只清这个范围内的记录（网络影院的足迹页只清影视源）。
    func clearProgress(sourceIDs: Set<UUID>? = nil) {
        let keys: [String] = progress.compactMap { key, record -> String? in
            guard sourceIDs?.contains(record.sourceID) ?? true else { return nil }
            return key
        }
        guard !keys.isEmpty else { return }
        for key in keys { progress[key] = nil }
        CatalogStore.deleteProgress(keys: keys)
    }

    /// 本次刷新才出现、上次快照里没有的条目。
    func isFresh(sourceID: UUID, itemID: String) -> Bool {
        freshItemKeys.contains("\(sourceID.uuidString)|\(itemID)")
    }

    // MARK: - 源管理

    func addSource(_ source: CatalogSource) {
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        saveSources()
        CatalogTrust.sync(sources: sources)
        // 只有网页资源站会切换「网络资源」的当前源；影视源只进网络影院。
        if source.domain == .networkResource {
            selectSource(source.id)
        }
        rebuildTodaySpotlight()
    }

    // MARK: - 配置导入导出

    /// 导出某个域的来源配置：只装这一域的源，导入时不会跨域混入。
    func exportSourceBundle(domain: CatalogDomain) -> Data? {
        let list = sources(in: domain)
        guard !list.isEmpty else { return nil }
        return SourceTransferJSON.encode(domain.transferScope, items: list)
    }

    /// 侧边栏拖拽排序：顺序同时决定跨源搜索、聚合与榜单的先后。
    /// 只在同域内移动：网络资源的排序不会把影视源的位置挤乱，反之亦然。
    func moveSource(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let item = sources.first(where: { $0.id == id }),
              let target = sources.first(where: { $0.id == targetID }),
              item.domain == target.domain else { return }
        var list = sources(in: item.domain)
        guard let from = list.firstIndex(where: { $0.id == id }),
              let targetIndex = list.firstIndex(where: { $0.id == targetID }) else { return }
        list.remove(at: from)
        let to = from < targetIndex ? targetIndex - 1 : targetIndex
        list.insert(item, at: max(0, min(to, list.count)))
        applyDomainOrder(list, domain: item.domain)
    }

    /// 拖到列表末尾：只在本域内排到最后。
    func moveSourceToEnd(_ id: UUID) {
        guard let item = sources.first(where: { $0.id == id }) else { return }
        var list = sources(in: item.domain)
        guard let from = list.firstIndex(where: { $0.id == id }),
              from < list.count - 1 else { return }
        list.append(list.remove(at: from))
        applyDomainOrder(list, domain: item.domain)
    }

    /// 右键菜单上移 / 下移：-1 上移，+1 下移，只在本域内交换。
    func moveSource(_ id: UUID, by offset: Int) {
        guard let item = sources.first(where: { $0.id == id }) else { return }
        var list = sources(in: item.domain)
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard list.indices.contains(to) else { return }
        list.swapAt(from, to)
        applyDomainOrder(list, domain: item.domain)
    }

    /// 把重排后的本域清单写回完整源列表：另一个域的源保持原有位置不动。
    private func applyDomainOrder(_ ordered: [CatalogSource], domain: CatalogDomain) {
        var next = ordered.makeIterator()
        let merged = sources.map { current -> CatalogSource in
            guard current.domain == domain, let replacement = next.next() else { return current }
            return replacement
        }
        guard merged != sources else { return }
        sources = merged
        saveSources()
    }

    func updateSource(_ source: CatalogSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        saveSources()
        CatalogTrust.sync(sources: sources)
        if selectedSourceID == source.id {
            categories = source.categories
            refreshCategories(source: source)
            if !source.isEnabled { reload() }
        }
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = enabled
        saveSources()
        if selectedSourceID == id {
            categories = sources[index].categories
            refreshCategories(source: sources[index])
            reload()
        }
    }

    /// 用户对该源显式放行证书校验；只影响这一个主机，且下次启动仍按源配置生效。
    func setInsecureTLS(_ id: UUID, _ enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].allowsInsecureTLS = enabled
        saveSources()
        CatalogTrust.sync(sources: sources)
        if selectedSourceID == id { refresh() }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = trimmed
        saveSources()
        rebuildTodaySpotlight()
    }

    func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
        CatalogTrust.sync(sources: sources)
        progress = progress.filter { $0.value.sourceID != id }
        favorites = favorites.filter { $0.value.sourceID != id }
        watchedKeys = watchedKeys.filter { !$0.hasPrefix(id.uuidString + "|") }
        cachedPages = cachedPages.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        cachedDetails = cachedDetails.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        pageSnapshots = pageSnapshots.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        CatalogSnapshotStore.remove(prefix: id.uuidString + "|")
        // 网络影院的列表快照与网络资源同源：移除源后一并清掉该源的条目。
        NetworkCinemaSnapshotStore.remove(sourceID: id)
        categoryThumbs = categoryThumbs.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        saveCategoryThumbs()
        saveSources()
        CatalogStore.deleteProgress(sourceID: id)
        CatalogStore.deleteCalendar(sourceID: id)
        calendarItems = calendarItems.filter { $0.sourceID != id }
        saveFavorites()
        saveWatched()
        rebuildTodaySpotlight()
        if selectedSourceID == id {
            // 只在网络资源里挑替补：影视源不会成为资源页的当前源。
            selectedSourceID = enabledResourceSources.first?.id ?? resourceSources.first?.id
            if let source = selectedSource {
                prepare(source: source)
                openHome()
            } else {
                items = []
                categories = []
            }
        }
        Task { await CatalogArtworkCache.shared.clear(sourceID: id) }
    }

    func clearArtwork(_ id: UUID) {
        CatalogArtworkMemory.shared.removeAll()
        Task { await CatalogArtworkCache.shared.clear(sourceID: id) }
    }

    func clearAllArtwork() {
        CatalogArtworkMemory.shared.removeAll()
        Task { await CatalogArtworkCache.shared.clear(sourceID: nil) }
    }

    // MARK: - 内部

    private func prepare(source: CatalogSource) {
        categories = source.categories
        activeTopCategoryID = nil
        tags = []
        // 换源后旧源的排序可能不受支持：退回站点默认顺序，避免界面显示「热播」但结果没变。
        if let provider = CatalogProviders.provider(for: source.kind),
           !provider.supportedSorts.contains(sort) {
            sort = .latest
        }
        localSort = nil
        cachedPages = cachedPages.filter { $0.key.hasPrefix(source.id.uuidString + "|") }
        cachedDetails = cachedDetails.filter { $0.key.hasPrefix(source.id.uuidString + "|") }
        refreshCategories(source: source)
    }

    /// 分类以站点导航为准：先渲染本地骨架，再用站点实时分类覆盖；标签按当前一级分类取。
    private func refreshCategories(source: CatalogSource) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task { [weak self] in
            let live = try? await provider.categories(source: source)
            guard let self, self.selectedSourceID == source.id else { return }
            if let live, !live.isEmpty {
                // 已经按需补齐的二级频道不能被实时分类覆盖掉。
                let merged = live.map { fresh in
                    guard fresh.children?.isEmpty ?? true,
                          let local = self.categories.first(where: { $0.id == fresh.id }),
                          let children = local.children, !children.isEmpty else { return fresh }
                    var updated = fresh
                    updated.children = children
                    return updated
                }
                self.categories = merged
                // 写回源配置：下次进来第一眼看到的就是最新的一、二级，而不是导入时的旧骨架。
                self.persistCategories(merged, for: source.id)
            }
            self.refreshTags(source: source, category: self.activeTopCategory)
        }
    }

    /// 实时分类持久化到源上；内容没变就不重复写盘。
    private func persistCategories(_ categories: [CatalogCategory], for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              sources[index].categories != categories else { return }
        sources[index].categories = categories
        saveSources()
    }

    /// 二级标签跟随当前一级分类：肉视频这类站点把片商 / 题材挂在主分类下面。
    private func refreshTags(source: CatalogSource, category: CatalogCategory?) {
        guard let provider = CatalogProviders.provider(for: source.kind) else { return }
        tagsToken &+= 1
        let token = tagsToken
        Task { [weak self] in
            let live = try? await provider.tags(source: source, category: category)
            guard let self, self.tagsToken == token, self.selectedSourceID == source.id else { return }
            self.tags = live ?? []
        }
    }

    /// 已拉取过二级频道的分类：避免重复点一级时反复请求。
    private var channelRequests: Set<String> = []

    /// 二级频道按需拉取：拉到后挂回分类树，频道行随即出现。
    private func loadChannels(source: CatalogSource, category: CatalogCategory) {
        let key = "\(source.id.uuidString)|\(category.id)"
        guard channelRequests.insert(key).inserted,
              let provider = CatalogProviders.provider(for: source.kind) else { return }
        Task { [weak self] in
            let live = try? await provider.channels(source: source, category: category)
            guard let self, self.selectedSourceID == source.id,
                  let live, !live.isEmpty,
                  let index = self.categories.firstIndex(where: { $0.id == category.id })
            else { return }
            self.categories[index].children = live
            self.persistCategories(self.categories, for: source.id)
        }
    }

    /// 点的是不是已经展示出来的标签（说明它在二级层，不需要重新取上下文）。
    private func isKnownTag(_ category: CatalogCategory) -> Bool {
        tags.contains { tag in
            tag.id == category.id
                || (tag.children?.contains(where: { $0.id == category.id }) ?? false)
        }
    }

    private func cacheKey(source: CatalogSource, page: Int) -> String {
        "\(source.id.uuidString)|\(sectionKey)|\(sort.rawValue)|\(page)"
    }

    func detailKey(source: CatalogSource, itemID: String) -> String {
        "\(source.id.uuidString)|detail|\(itemID)"
    }

    private var sectionKey: String {
        switch section {
        case .home: return "home"
        case .category(let id): return "cat-\(id)"
        case .rank: return "rank"
        case .search(let keyword): return "search-\(keyword)"
        case .continueWatching: return "continue"
        case .favorites: return "favorites"
        }
    }

    // MARK: - 持久化

    private func load() {
        if let data = CatalogStore.data(forKey: Self.sourcesKey),
           let decoded = try? JSONDecoder().decode([CatalogSource].self, from: data) {
            // 站点换了官方域名：旧的爱壹帆地址迁移到 kubb.tv（同一套接口）。
            let hasKubb = decoded.contains {
                (URL(string: $0.baseURL)?.host ?? "").lowercased().contains("kubb.tv")
            }
            let normalized = hasKubb ? decoded : decoded.map(Self.migratedEndpoint)
            // 旧配置里只有一级：按适配器最新的站点骨架补齐二级分类，并写回。
            let enriched = normalized.map { CatalogProviders.enrich($0) }
            sources = enriched
            if enriched != decoded { saveSources() }
        }
        progress = CatalogStore.loadProgress()
        if let data = CatalogStore.data(forKey: Self.favoritesKey),
           let decoded = try? JSONDecoder().decode([String: CatalogFavorite].self, from: data) {
            favorites = decoded
        }
        if let data = CatalogStore.data(forKey: Self.watchedKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            watchedKeys = Set(decoded)
        }
        if let data = CatalogStore.data(forKey: Self.categoryThumbsKey),
           let thumbs = try? JSONDecoder().decode([String: String].self, from: data) {
            categoryThumbs = thumbs
        }
        loadDiscovery()
        CatalogTrust.sync(sources: sources)
    }

    /// 爱壹帆换成了 kubb.tv 同一套接口：旧源就地换域名，保留启用状态与排序。
    private static func migratedEndpoint(_ source: CatalogSource) -> CatalogSource {
        guard source.kind == .iyf,
              (URL(string: source.baseURL)?.host ?? "").lowercased().hasSuffix("iyf.tv") else {
            return source
        }
        var updated = source
        updated.baseURL = "https://www.kubb.tv"
        updated.referer = "https://www.kubb.tv/"
        updated.configURL = "https://www.kubb.tv/"
        if updated.name.contains("爱壹帆") { updated.name = "Kubb" }
        return updated
    }

    private func saveSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        CatalogStore.set(data, forKey: Self.sourcesKey)
    }

    /// 播放中每次进度变化只写一行；超出上限时再按更新时间清掉最旧的行。
    /// 写入方只有 `SourcePlaybackProgressStore`，这里负责落盘与容量兜底。
    func persistProgress(_ record: CatalogProgress) {
        CatalogStore.saveProgress(record)
        guard progress.count > 200 else { return }
        let kept = progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(200)
        let keptKeys = Set(kept.map(\.key))
        let evicted = progress.keys.filter { !keptKeys.contains($0) }
        progress = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
        CatalogStore.deleteProgress(keys: evicted)
    }

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        CatalogStore.set(data, forKey: Self.favoritesKey)
    }

    private func saveWatched() {
        guard let data = try? JSONEncoder().encode(Array(watchedKeys)) else { return }
        CatalogStore.set(data, forKey: Self.watchedKey)
    }

    private func saveCategoryThumbs() {
        guard let data = try? JSONEncoder().encode(categoryThumbs) else { return }
        CatalogStore.set(data, forKey: Self.categoryThumbsKey)
    }
}
