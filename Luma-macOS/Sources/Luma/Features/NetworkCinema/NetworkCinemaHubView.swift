import SwiftUI
import AppKit

/// 网络影院的排序：站点默认顺序之外的三种常用排序。
enum NetworkCinemaSort: String, CaseIterable, Identifiable {
    case recent
    case rating
    case year
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "最新"
        case .rating: return "TMDB 评分"
        case .year: return "年份"
        case .title: return "标题"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock.arrow.circlepath"
        case .rating: return "star.fill"
        case .year: return "calendar"
        case .title: return "textformat"
        }
    }
}

/// 工具栏中区的分页胶囊：影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注。
/// 与「网络资源」「网络存储」的工具栏分页同一套样式；页面内容区不再重复一条大胶囊。
struct NetworkCinemaHubTabs: View {
    @EnvironmentObject private var store: LibraryStore
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NetworkCinemaTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        // 工具栏变窄时宁可整体溢出，也不要把标签压成「…」。
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ tab: NetworkCinemaTab) -> some View {
        let active = store.networkCinemaTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                store.networkCinemaTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize()
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "net-cinema-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("网络影院 · \(tab.title)")
    }
}

/// 详情页工具栏中区：只显示正在看的这部片，聚合分页与来源筛选都让位。
struct NetworkCinemaDetailTitleBar: View {
    let entry: NetworkCinemaItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: entry.isTV ? "tv" : "film")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(entry.item.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Text(entry.isTV ? "剧集" : "电影")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
            Text(entry.source.name)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 网络影院：把已启用的通用影视源聚合成一个浏览区。
///
/// 版式对齐「网络资源 / 网络存储」：影院管理、榜单、电影、电视剧、日历、足迹、关注七个分页，
/// 切换入口在窗口工具栏；电影与电视剧是信息更完整的海报墙，点开条目后原地进入影院式详情页。
struct NetworkCinemaHubView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel
    /// 由 `LibraryStore` 持有：切到别的页面，探测与资料补全继续在后台跑。
    @EnvironmentObject private var model: NetworkCinemaModel

    @State private var selectedGenre: String?
    /// 排序与顶栏控制台共用：`store.networkCinemaSort` 一改，列表立即重排。
    private var sort: NetworkCinemaSort {
        get { store.networkCinemaSort }
        nonmutating set { store.networkCinemaSort = newValue }
    }
    /// 站点页每行海报张数：默认 8，顶栏滑杆可调。
    @AppStorage(SettingsKeys.cinemaGridColumns) private var cinemaColumns = 8
    /// 点开具体源后按站点原始分类浏览：一级选中项（nil = 首页）与二级频道。
    /// 一级分类舱里的滑动高亮，与网络资源同一套。
    @Namespace private var focusedChipNamespace

    private var sources: [CatalogSource] {
        catalog.enabledCinemaSources
    }

    /// 「榜单 / 日历 / 足迹」只统计影视源，不把「网络资源」里的站点混进来。
    private var scopeIDs: Set<UUID> {
        catalog.cinemaSourceIDs
    }

    private var sourceFilterID: UUID? { store.networkCinemaSourceID }
    /// 点开某个源后，这一页只服务它：工具栏分页、来源筛选都让位给源内浏览。
    private var focusedSource: CatalogSource? {
        guard let id = sourceFilterID else { return nil }
        return sources.first { $0.id == id }
    }
    private var sourceIDs: String { sources.map(\.id.uuidString).joined(separator: ",") }

    /// 当前选中的一级分类；nil 表示源首页。
    private var focusedTopCategory: CatalogCategory? {
        guard let source = focusedSource, let id = store.networkCinemaTopCategoryID else { return nil }
        return source.categories.first { $0.id == id }
    }
    private var focusedSubCategories: [CatalogCategory] {
        focusedTopCategory?.children ?? []
    }
    /// 真正用于取内容的分类：有二级就落到二级，否则就是一级本身。
    private var focusedSelectedCategory: CatalogCategory? {
        if let id = store.networkCinemaSubCategoryID,
           let hit = focusedSubCategories.first(where: { $0.id == id }) {
            return hit
        }
        return focusedTopCategory
    }
    /// 源内浏览只加载这一家；聚合页只拉网络影院的影视源。
    private var activeSources: [CatalogSource] {
        focusedSource.map { [$0] } ?? catalog.cinemaSources
    }
    private var reloadKey: String {
        if let focused = focusedSource {
            return "focused|\(focused.id.uuidString)|\(focusedSelectedCategory?.id ?? "-")"
        }
        return "\(store.networkCinemaTab.rawValue)|\(sourceIDs)|\(sourceFilterID?.uuidString ?? "-")"
    }

    private var availableGenres: [String] {
        model.genres(for: model.items)
    }

    /// 站点页顶栏搜索词（去掉首尾空白）：只用来过滤当前已加载的条目。
    private var trimmedSourceQuery: String {
        store.networkCinemaSourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 排序用的评分：优先 TMDB 补全值，没有再读备注里的「x.x 分」。
    private func ratingValue(_ entry: NetworkCinemaItem) -> Double {
        if let rating = model.enrichment(for: entry)?.rating { return rating }
        guard let range = entry.item.remark.range(of: #"\d+(\.\d+)?\s*分"#,
                                                 options: .regularExpression) else { return 0 }
        let digits = entry.item.remark[range].prefix { $0.isNumber || $0 == "." }
        return Double(String(digits)) ?? 0
    }

    private var visibleItems: [NetworkCinemaItem] {
        var list = model.items
        // 窗口内搜索：只过滤当前已经展示的这一批条目，不再联网检索。
        if store.searchScope == .currentView {
            let keyword = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyword.isEmpty {
                list = list.filter {
                    SearchFuzzyText.matchesAny([$0.item.title, $0.item.remark], keyword: keyword)
                }
            }
        }
        if let id = sourceFilterID {
            list = list.filter { $0.source.id == id }
        }
        if let genre = selectedGenre {
            list = list.filter { entry in
                model.enrichment(for: entry)?.genres.contains(genre) == true
            }
        }
        switch sort {
        case .recent:
            break
        case .rating:
            list.sort { ratingValue($0) > ratingValue($1) }
        case .year:
            list.sort {
                let lhs = model.enrichment(for: $0)?.year
                    ?? NetworkCinemaEnrichment.year(in: $0.item.title) ?? 0
                let rhs = model.enrichment(for: $1)?.year
                    ?? NetworkCinemaEnrichment.year(in: $1.item.title) ?? 0
                return lhs > rhs
            }
        case .title:
            list.sort {
                let lhs = model.enrichment(for: $0)?.title ?? $0.item.title
                let rhs = model.enrichment(for: $1)?.title ?? $1.item.title
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
        return list
    }

    private var activeFilterCount: Int {
        var count = 0
        if sourceFilterID != nil { count += 1 }
        if selectedGenre != nil { count += 1 }
        if sort != .recent { count += 1 }
        return count
    }

    var body: some View {
        Group {
            if let selected = store.networkCinemaDetail {
                // 返回收起详情由顶栏的返回胶囊统一负责（与网络资源详情同一位置）。
                NetworkCinemaDetailView(entry: selected, model: model)
                    .environmentObject(store)
            } else {
                pageContent
            }
        }
        .background(LumaAmbientBackground(intensity: 0.55))
        .task(id: reloadKey) {
            if let source = focusedSource {
                if trimmedSourceQuery.isEmpty {
                    model.reloadFocused(source: source,
                                        category: focusedSelectedCategory,
                                        tmdb: store.tmdbClient())
                } else {
                    // 站点页搜索走站点自己的搜索接口，不再过滤已加载的缓存页。
                    model.searchFocused(source: source,
                                        keyword: store.networkCinemaSourceQuery,
                                        tmdb: store.tmdbClient())
                }
                return
            }
            guard store.networkCinemaTab.browsesContent else { return }
            model.reload(sources: activeSources,
                         tab: store.networkCinemaTab,
                         tmdb: store.tmdbClient())
        }
        .onChange(of: store.networkCinemaSourceQuery) { _, query in
            guard let source = focusedSource else { return }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let wasSearching = model.isSourceSearchActive
                model.clearFocusedSearch()
                if wasSearching, model.items.isEmpty {
                    reloadFocused(force: true)
                }
            } else {
                model.searchFocused(source: source,
                                    keyword: query,
                                    tmdb: store.tmdbClient())
            }
        }
        // 换一级 / 二级分类等于离开搜索：清空关键词，回到分类浏览。
        .onChange(of: store.networkCinemaTopCategoryID) { _, _ in
            store.networkCinemaSourceQuery = ""
        }
        .onChange(of: store.networkCinemaSubCategoryID) { _, _ in
            store.networkCinemaSourceQuery = ""
        }
        .onChange(of: store.networkCinemaTab) { _, tab in
            // 分页在工具栏切换：回到列表，别停在上一个分页留下的详情页。
            store.networkCinemaDetail = nil
            selectedGenre = nil
            if !tab.browsesContent {
                model.clearSearch()
            }
        }
        .onChange(of: store.networkCinemaSourceID) { _, _ in
            selectedGenre = nil
            store.networkCinemaTopCategoryID = nil
            store.networkCinemaSubCategoryID = nil
            store.networkCinemaSourceQuery = ""
        }
        .onAppear {
            consumePendingItem()
            if let seed = store.networkCinemaSearchSeed {
                store.networkCinemaSearchSeed = nil
                store.searchText = seed
                // 影视源内部发起的搜索只在影院模块里找，不扩散到其他模块。
                store.searchScope = .module
            }
        }
        // 已经在网络影院里时，从影院推荐 / 演职员页再点「搜索」也要直接落到搜索态。
        .onChange(of: store.networkCinemaSearchSeed) { _, seed in
            guard let seed else { return }
            store.networkCinemaSearchSeed = nil
            store.networkCinemaDetail = nil
            store.searchText = seed
            store.searchScope = .module
        }
        .onChange(of: store.networkCinemaPendingItem?.id) { _, _ in
            consumePendingItem()
        }
        .onChange(of: sources.map(\.id)) { _, ids in
            if let id = store.networkCinemaSourceID, !ids.contains(id) {
                store.networkCinemaSourceID = nil
            }
        }
    }

    /// 七个分页的内容：管理 / 榜单 / 日历 / 足迹 / 关注读本机聚合数据，电影与电视剧走海报墙。
    @ViewBuilder
    private var pageContent: some View {
        if focusedSource != nil {
            // 点开具体源：顶部不再有聚合分页 / 统计，页面里只按站点原始一二级分类浏览。
            focusedBrowser
        } else {
            switch store.networkCinemaTab {
            case .manage:
                NetworkCinemaManageView()
            case .ranking:
                CatalogRankingView(sourceScope: scopeIDs, domain: .networkCinema, compact: true) { sourceID, item in
                    openInCinema(sourceID: sourceID, item: item)
                }
            case .calendar:
                CatalogCalendarView(sourceScope: scopeIDs, domain: .networkCinema, compact: true) { entry, source in
                    openInCinema(sourceID: source.id, item: entry.item)
                }
            case .history:
                CatalogHistoryView(sourceScope: scopeIDs, domain: .networkCinema, compact: true)
            case .following:
                NetworkCinemaFollowingView { entry in
                    withAnimation(.easeOut(duration: 0.16)) { store.networkCinemaDetail = entry }
                }
            case .movies, .shows:
                browser
            }
        }
    }

    /// 榜单 / 日历点开条目：按条目所属源进网络影院自己的详情页，而不是直接起播。
    private func openInCinema(sourceID: UUID, item: CatalogItem) {
        guard let source = catalog.cinemaSources.first(where: { $0.id == sourceID }) else { return }
        let entry = NetworkCinemaItem(source: source,
                                      item: item,
                                      isTV: NetworkCinemaModel.guessIsTV(item))
        withAnimation(.easeOut(duration: 0.16)) {
            store.networkCinemaDetail = entry
        }
    }

    /// 全局搜索点开条目：进来后直接停在这一部的详情页。
    private func consumePendingItem() {
        guard let pending = store.networkCinemaPendingItem else { return }
        store.networkCinemaPendingItem = nil
        store.networkCinemaDetail = pending
    }

    // MARK: - 浏览

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sources.isEmpty {
                    emptySourceState
                } else {
                    filterBar
                    statusLine
                    if model.isLoading && model.items.isEmpty {
                        loadingState("正在读取各影视源…")
                    } else if let error = model.error, visibleItems.isEmpty {
                        errorState(error)
                    } else if visibleItems.isEmpty {
                        emptyContentState
                    } else {
                        freshSummary
                        posterGrid
                        if model.canLoadMore || model.isLoadingMore {
                            loadMoreFooter
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 具体源：版式与「网络资源」频道页保持一致：一级目录 + 二级目录 + 海报墙。
    private var focusedBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                focusedCategoryTray
                if !focusedSubCategories.isEmpty {
                    focusedSubCategoryPanel
                }
                statusLine
                if model.isSourceSearching && model.items.isEmpty {
                    focusedSkeleton
                } else if let message = model.sourceSearchError, visibleItems.isEmpty {
                    LumaEmptyState(symbol: "wifi.exclamationmark",
                                   title: "站内搜索没有成功",
                                   message: message,
                                   actions: [LumaEmptyAction(title: "重试",
                                                             symbol: "arrow.clockwise") {
                                       retryFocusedSearch()
                                   }])
                } else if model.isLoading && model.items.isEmpty {
                    focusedSkeleton
                } else if let error = model.error, visibleItems.isEmpty {
                    focusedErrorState(error)
                } else if visibleItems.isEmpty, model.isSourceSearchActive {
                    LumaEmptyState(symbol: "magnifyingglass",
                                   title: "没有搜到「\(model.sourceSearchKeyword ?? trimmedSourceQuery)」",
                                   message: "站点搜索没有返回结果，可以换个关键词再试。",
                                   actions: [LumaEmptyAction(title: "清除搜索",
                                                             symbol: "xmark.circle") {
                                       store.networkCinemaSourceQuery = ""
                                   }])
                } else if visibleItems.isEmpty {
                    LumaEmptyState(symbol: "rectangle.on.rectangle.slash",
                                   title: "这一页没有内容",
                                   message: "可以换一个分类，或点右上角刷新重试。",
                                   actions: [LumaEmptyAction(title: "重试",
                                                             symbol: "arrow.clockwise") {
                                       reloadFocused(force: true)
                                   }])
                } else {
                    freshSummary
                    cinemaGrid(visibleItems)
                    if model.canLoadMore {
                        focusedLoadMoreIndicator
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 一级范围：与网络资源同一套连体舱体，选中块在舱内滑动。
    @ViewBuilder
    private var focusedCategoryTray: some View {
        if let source = focusedSource {
            CatalogFlowLayout(spacing: 3, lineSpacing: 3) {
                CatalogChip(title: "首页",
                            active: store.networkCinemaTopCategoryID == nil,
                            namespace: focusedChipNamespace) {
                    selectFocusedTop(nil)
                }
                ForEach(source.categories) { category in
                    CatalogChip(title: category.title,
                                active: store.networkCinemaTopCategoryID == category.id,
                                namespace: focusedChipNamespace) {
                        selectFocusedTop(category)
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
            }
            .padding(.vertical, 2)
        }
    }

    /// 二级目录：一级分类下面挂着地区 / 题材等站点原始二级分类，按目录胶囊平铺。
    private var focusedSubCategoryPanel: some View {
        CatalogFlowLayout(spacing: 6, lineSpacing: 7) {
            CatalogDirectoryChip(title: "全部",
                                 active: store.networkCinemaSubCategoryID == nil) {
                store.networkCinemaSubCategoryID = nil
            }
            ForEach(focusedSubCategories) { sub in
                CatalogDirectoryChip(title: sub.title,
                                     active: store.networkCinemaSubCategoryID == sub.id) {
                    store.networkCinemaSubCategoryID = sub.id
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
    }

    /// 影院卡片固定横排 8 个：站点页与电影 / 电视剧 tab 共用。
    private var cinemaColumnCount: Int { min(12, max(4, cinemaColumns)) }

    private var cinemaGap: CGFloat { 18 }

    private func cinemaGrid(_ entries: [NetworkCinemaItem]) -> some View {
        let gap = cinemaGap
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                        count: cinemaColumnCount),
                         alignment: .leading,
                         spacing: 24) {
            ForEach(entries) { entry in
                cinemaCard(entry)
            }
        }
    }

    /// 与网络资源一致的「本次刷新新增」提示：卡片同步打「刚上架 / 更新中 / 已完结」。
    @ViewBuilder
    private var freshSummary: some View {
        if !model.freshItemKeys.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("本次刷新新增 \(model.freshItemKeys.count) 条")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("完结剧标「已完结」、连载剧标「更新中」、单片标「刚上架」")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
        }
    }

    /// 底部续页指示：与网络资源一致，只在滚动时露出转圈，不额外占一行文字。
    private var focusedLoadMoreIndicator: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.mini)
                .opacity(model.isLoadingMore ? 1 : 0)
            Spacer()
        }
        .frame(height: 24)
        .padding(.top, 2)
    }

    private var focusedSkeleton: some View {
        let gap = cinemaGap
        return LumaSkeletonGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                               count: cinemaColumnCount),
                                count: 16,
                                aspectRatio: CGFloat(focusedSource?.posterRatio ?? 2.0 / 3.0),
                                footerLines: 1,
                                spacing: 24)
    }

    private func focusedErrorState(_ message: String) -> some View {
        LumaEmptyState(symbol: "wifi.exclamationmark",
                       title: "内容没有加载出来",
                       message: message,
                       actions: [LumaEmptyAction(title: "重试",
                                                 symbol: "arrow.clockwise") {
                           reloadFocused(force: true)
                       }])
    }

    private func reloadFocused(force: Bool) {
        guard let source = focusedSource else { return }
        model.reloadFocused(source: source,
                            category: focusedSelectedCategory,
                            tmdb: store.tmdbClient(),
                            force: force)
    }

    /// 站内搜索失败后重试：强制再打一次站点搜索接口。
    private func retryFocusedSearch() {
        guard let source = focusedSource, !trimmedSourceQuery.isEmpty else { return }
        model.searchFocused(source: source,
                            keyword: store.networkCinemaSourceQuery,
                            tmdb: store.tmdbClient(),
                            force: true)
    }

    private func selectFocusedTop(_ category: CatalogCategory?) {
        store.networkCinemaTopCategoryID = category?.id
        // 分组节点自身没有页面：直接落到它的第一个子分类。
        if let category, category.isGroupCategory,
           let first = category.children?.first(where: { !$0.isRank && !$0.id.isEmpty }) {
            store.networkCinemaSubCategoryID = first.id
        } else {
            store.networkCinemaSubCategoryID = nil
        }
    }

    private var currentError: String? { model.error }

    private var refreshButton: some View {
        Button {
            // 主动刷新：跳过快照新鲜度判断，强制重拉当前范围内的影视源。
            if let source = focusedSource {
                model.reloadFocused(source: source,
                                    category: focusedSelectedCategory,
                                    tmdb: store.tmdbClient(),
                                    force: true)
            } else {
                model.reload(sources: activeSources,
                             tab: store.networkCinemaTab,
                             tmdb: store.tmdbClient(),
                             force: true)
            }
        } label: {
            HStack(spacing: 5) {
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(model.isLoading ? "载入中" : "刷新")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading)
        .help("重新聚合各影视源")
    }

    // MARK: 筛选

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                if sources.count > 1 && sourceFilterID == nil {
                    filterLabel("来源")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            CatalogDirectoryChip(title: "全部来源",
                                                 active: sourceFilterID == nil) {
                                store.networkCinemaSourceID = nil
                            }
                            ForEach(sources) { source in
                                CatalogDirectoryChip(title: source.name,
                                                     tint: source.kind.sidebarTint,
                                                     active: sourceFilterID == source.id) {
                                    store.networkCinemaSourceID = source.id
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                } else {
                    filterLabel("筛选")
                }
                Spacer(minLength: 8)
                Text("\(visibleItems.count) 部")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if sourceFilterID == nil, model.mergedTitleCount > 0 {
                    Text("已合并 \(model.mergedTitleCount) 部同名")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(LumaBrand.amber.opacity(0.12), in: Capsule())
                        .help("同名影片只占一张卡，卡片标「N 源」；点开后可在详情页切换播放源")
                }
                refreshButton
                sortMenu
                if activeFilterCount > 0 {
                    Button("清除筛选") {
                        clearFilters()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            if !availableGenres.isEmpty {
                HStack(spacing: 9) {
                    filterLabel("类型")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            CatalogDirectoryChip(title: "全部",
                                                 active: selectedGenre == nil) {
                                selectedGenre = nil
                            }
                            ForEach(availableGenres.prefix(14), id: \.self) { genre in
                                CatalogDirectoryChip(title: genre,
                                                     active: selectedGenre == genre) {
                                    selectedGenre = selectedGenre == genre ? nil : genre
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
    }

    private func filterLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 26, alignment: .leading)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(NetworkCinemaSort.allCases) { option in
                Button {
                    sort = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sort.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(sort.title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func clearFilters() {
        store.networkCinemaSourceID = nil
        selectedGenre = nil
        sort = .recent
    }

    // MARK: 状态

    @ViewBuilder
    private var statusLine: some View {
        if let progress = model.enrichmentProgress, progress.total > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在补全 TMDB 资料 \(progress.done)/\(progress.total)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if let error = currentError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LumaBrand.coral)
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else if store.tmdbClient() == nil {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("未配置 TMDB API Key：卡片先用源站海报，评分与演职员暂不补全。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 海报墙

    private var posterGrid: some View {
        cinemaGrid(visibleItems)
    }

    /// 影院卡片直接复用网络资源的 `CatalogPosterCell`：
    /// 边框取封面主色、悬停预览与上浮、刚上架 / 更新中角标全部同一套。
    private func cinemaCard(_ entry: NetworkCinemaItem) -> some View {
        let item = displayItem(entry)
        return CatalogPosterCell(
            source: entry.source,
            item: item,
            progress: catalog.progress(sourceID: entry.source.id, itemID: entry.item.id),
            isFresh: model.isFresh(entry),
            isFavorite: catalog.isFavorite(sourceID: entry.source.id, itemID: entry.item.id),
            isMarkedWatched: catalog.isMarkedWatched(sourceID: entry.source.id, itemID: entry.item.id),
            onOpen: {
                withAnimation(.easeOut(duration: 0.16)) {
                    store.networkCinemaDetail = entry
                }
            },
            onOpenInBrowser: {
                store.openCatalogItemInBrowser(source: entry.source, item: entry.item)
            },
            onSaveVideo: {
                store.saveCatalogVideoToLibrary(source: entry.source, item: entry.item)
            },
            durationText: nil,
            previewTarget: {
                await catalog.previewTarget(sourceID: entry.source.id, item: entry.item)
            }
        )
        .onAppear {
            // 最后一张露头就补下一页：LazyVGrid 只在真正滚到时创建它。
            guard entry.id == visibleItems.last?.id else { return }
            loadMoreIfNeeded()
        }
    }

    /// 卡片展示用的条目：优先用 TMDB 片名，并把评分并进备注，
    /// 让 `CatalogPosterCell` 的右上角评分与底部信息跟网络资源完全一致。
    private func displayItem(_ entry: NetworkCinemaItem) -> CatalogItem {
        var item = entry.item
        let enrichment = model.enrichment(for: entry)
        if let title = enrichment?.title, !title.isEmpty {
            item.title = title
        }
        if let rating = enrichment?.rating, !item.remark.contains("分") {
            let score = String(format: "%.1f 分", rating)
            item.remark = item.remark.isEmpty ? score : "\(item.remark)·\(score)"
        }
        return item
    }

    /// 网格底部：加载中显示转圈，否则提示继续下滑。
    private var loadMoreFooter: some View {
        HStack(spacing: 7) {
            if model.isLoadingMore {
                ProgressView().controlSize(.mini)
                Text("正在加载更多…")
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text("继续下滑加载更多")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func loadMoreIfNeeded() {
        guard model.canLoadMore, !model.isLoadingMore else { return }
        if focusedSource != nil {
            model.loadMoreFocused(tmdb: store.tmdbClient())
        } else {
            model.loadMore(sources: activeSources,
                           tab: store.networkCinemaTab,
                           tmdb: store.tmdbClient())
        }
    }

    private var emptySourceState: some View {
        VStack(spacing: 10) {
            Image(systemName: "popcorn")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("还没有影视源")
                .font(.system(size: 16, weight: .semibold))
            Text("接入 FongMi 配置、苹果CMS 接口，或 FoFo / 爱看片片 / 爱壹帆站点地址，电影与电视剧会聚合到这一页。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("接入影视源…") {
                store.presentCatalogWizard(domain: .networkCinema)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private var emptyContentState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("这个分页暂时没有内容")
                .font(.system(size: 15, weight: .semibold))
            Text("换个分页、清除筛选，或到「网络资源」里检查源是否返回了对应分类。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if activeFilterCount > 0 {
                Button("清除筛选") { clearFilters() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func loadingState(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LumaBrand.coral)
            Text("暂时读不到内容")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("重试") {
                if let source = focusedSource {
                    model.reloadFocused(source: source,
                                        category: focusedSelectedCategory,
                                        tmdb: store.tmdbClient(),
                                        force: true)
                } else {
                    model.reload(sources: activeSources,
                                 tab: store.networkCinemaTab,
                                 tmdb: store.tmdbClient(),
                                 force: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - 海报卡

// MARK: - 站点页顶栏

/// 站点页的缩放：与网络资源的顶栏缩放同一套外观，控制海报每行张数（默认 8）。
struct NetworkCinemaZoomControl: View {
    @AppStorage(SettingsKeys.cinemaGridColumns) private var columns = 8

    var body: some View {
        GalleryToolbarPill {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    columns = max(4, columns - 1)
                }
            } label: {
                GalleryToolbarIconLabel(systemName: "minus")
            }
            .buttonStyle(.plain)
            .disabled(columns <= 4)
            .help("减少每行海报数")
            .accessibilityLabel("减少每行海报数")

            Slider(value: Binding(get: { Double(columns) },
                                  set: { columns = Int($0.rounded()) }),
                   in: 4...12, step: 1)
                .frame(width: 74)
                .controlSize(.mini)
                .help("每行 \(columns) 张")
                .accessibilityLabel("每行海报数")

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    columns = min(12, columns + 1)
                }
            } label: {
                GalleryToolbarIconLabel(systemName: "plus")
            }
            .buttonStyle(.plain)
            .disabled(columns >= 12)
            .help("增加每行海报数")
            .accessibilityLabel("增加每行海报数")
        }
        .help("海报每行 \(columns) 张")
    }
}

/// 站点页顶栏中区：与网络资源完全同一枚胶囊舱。
/// 首页 / 分类菜单 · 站点 · 最新 · 站内搜索 · 刷新。
struct NetworkCinemaSourceConsole: View {
    @EnvironmentObject private var store: LibraryStore

    @FocusState private var focused: Bool

    private var source: CatalogSource? {
        guard let id = store.networkCinemaSourceID else { return nil }
        return store.catalogModel.sources.first { $0.id == id }
    }

    private var model: NetworkCinemaModel { store.networkCinemaModel }

    private var topCategory: CatalogCategory? {
        guard let source, let id = store.networkCinemaTopCategoryID else { return nil }
        return source.categories.first { $0.id == id }
    }

    /// 顶栏菜单 / 刷新实际使用的分类：有二级就落到二级。
    private var currentCategory: CatalogCategory? {
        guard let top = topCategory else { return nil }
        if let id = store.networkCinemaSubCategoryID,
           let sub = top.children?.first(where: { $0.id == id }) {
            return sub
        }
        return top
    }

    private var sectionTitle: String {
        guard let top = topCategory else { return "首页" }
        if let sub = currentCategory, sub.id != top.id {
            return sub.title
        }
        return top.title
    }

    var body: some View {
        consoleChrome {
            HStack(spacing: 11) {
                Menu {
                    menu
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: store.networkCinemaTopCategoryID == nil
                              ? "house" : "square.grid.2x2")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(sectionTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换分类")

                if let host = source?.host, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                divider

                // 排序：与页面筛选条共用 store.networkCinemaSort，切换后列表立即重排。
                Menu {
                    ForEach(NetworkCinemaSort.allCases) { option in
                        Button {
                            store.networkCinemaSort = option
                        } label: {
                            Label(option.title, systemImage: option.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.networkCinemaSort.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(store.networkCinemaSort.title)
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("排序方式")

                divider
                searchField
                divider

                Button {
                    guard let source else { return }
                    let query = store.networkCinemaSourceQuery
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if query.isEmpty {
                        model.reloadFocused(source: source,
                                            category: currentCategory,
                                            tmdb: store.tmdbClient(),
                                            force: true)
                    } else {
                        // 正在搜索时刷新 = 重打一次站点搜索。
                        model.searchFocused(source: source,
                                            keyword: query,
                                            tmdb: store.tmdbClient(),
                                            force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(source == nil)
                .help("刷新当前分类")
                .accessibilityLabel("刷新")
            }
        }
    }

    private func consoleChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 5.5)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            select(top: nil, sub: nil)
        } label: {
            Label("首页", systemImage: "house")
        }
        if let source, !source.categories.isEmpty {
            Divider()
            ForEach(source.categories) { category in
                if let children = category.children, !children.isEmpty {
                    Menu(category.title) {
                        Button("全部") { select(top: category.id, sub: nil) }
                        ForEach(children) { child in
                            Button(child.title) { select(top: category.id, sub: child.id) }
                        }
                    }
                } else {
                    Button {
                        select(top: category.id, sub: nil)
                    } label: {
                        Label(category.title,
                              systemImage: category.isRank ? "chart.bar.fill" : "square.grid.2x2")
                    }
                }
            }
        }
    }

    private func select(top: String?, sub: String?) {
        store.networkCinemaTopCategoryID = top
        store.networkCinemaSubCategoryID = sub
    }

    /// 站内搜索：与网络资源一样只搜当前这个源。
    private var searchField: some View {
        HStack(spacing: 5) {
            if model.isSourceSearching {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 13, height: 18)
                    .help("正在搜索站点")
            } else {
                Button {
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(focused ? Color.accentColor : Color.secondary)
                        .frame(width: 13, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            TextField(searchPlaceholder, text: $store.networkCinemaSourceQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit {
                    focused = false
                }
                .onExitCommand {
                    if store.networkCinemaSourceQuery.isEmpty {
                        focused = false
                    } else {
                        store.networkCinemaSourceQuery = ""
                    }
                }

            if !store.networkCinemaSourceQuery.isEmpty {
                Button {
                    store.networkCinemaSourceQuery = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: 24)
        .background(Color.primary.opacity(focused ? 0.09 : 0.055),
                    in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.55)
                                      : Color.primary.opacity(0.06),
                              lineWidth: 0.6)
        }
    }

    private var searchPlaceholder: String {
        "搜索\(source?.name ?? "本影视源")"
    }
}
