import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 剧集详情页。

struct CinemaSeriesDetailView: View {
    let series: CinemaSeries
    let onPlay: (CinemaEntry) -> Void
    /// 演职员页里点开另一部作品：交给上层替换详情目标。
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    /// 顶栏「返回」：没有二级页时关闭整个详情。
    var onClose: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @State private var hoveredEpisode: UUID?
    /// 键盘方向键游标：只服务键盘切集，鼠标点击不再有「选中」这一步。
    @State private var keyboardEpisodeID: UUID?
    @State private var enriched: CinemaEntry?
    /// 推荐分组：猜你喜欢 / 豆瓣 / 同系列 / 同导演 / 同演员。
    @State private var recommendationGroups: [CinemaRecommendationGroup] = []
    /// 手动挑过封面后先在本页覆盖，不必等上层快照刷新。
    @State private var artworkPosterOverride: String?
    @State private var artworkBackdropOverride: String?
    @State private var artworkRequest: CinemaArtworkPickerRequest?
    /// 恢复上次查看的季时，不要顺手清掉选中集。
    @State private var suppressSeasonReset = false
    /// 滚动偏移：滚过档案卡后浮出紧凑标题条。
    @State private var scrollOffset: CGFloat = 0
    /// 各季的单集标题 / 简介 / 剧照（TMDB 按季拉取，季 → 集号 → 信息）。
    @State private var episodeInfos: [Int: [Int: CinemaEpisodeInfo]] = [:]
    /// 当前查看的季；nil 时默认落在最新一季（标签栏最左）。
    @State private var selectedSeason: Int?
    /// 演职员 → 人物页。
    @State private var personTarget: CinemaCastMember?
    /// 预告片：页面内播放层，不打开浏览器。
    @State private var showTrailer = false
    /// 档案卡里的长简介：默认收 5 行。
    @State private var dossierExpanded = false
    /// 片头尾自动识别进行中。
    @State private var detectingIntro = false
    /// 片头设置范围：整部剧默认值，或只覆盖某一集。
    @State private var introScope: IntroScope = .series
    /// 跳过片头尾的调节面板。
    @State private var showIntroPanel = false
    /// 剧集网格的键盘焦点：方向键选择、空格播放，和图库网格一致。
    @FocusState private var episodeGridFocus: Bool
    /// 当前内容列宽度：网格列数与键盘跨行都按它推导，窗口变化时同步更新。
    @State private var contentWidth: CGFloat = 0
    /// 悬停档案实际高度：贴到底部时把面板整体上移，内容不会被裁掉。
    @State private var hoverPanelHeight: CGFloat = 340
    /// 悬停档案的延迟关闭：鼠标在卡片之间快速移动时不会闪一下。
    @State private var hoverDismissTask: DispatchWorkItem?

    enum IntroScope: Hashable {
        case series
        case episode
    }

    /// 集卡列数：完全由外面量到的可视宽度决定，列数确定后卡片只在这条宽度里均分。
    /// 不用 `.adaptive`：它在某些测量阶段会按「所有卡片排成一行」反推理想宽度，
    /// 结果反过来把整页 / 窗口的最小宽度撑大。
    func episodeColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 16
        let count = max(1, GridLayout.columns(contentWidth: max(1, width),
                                              targetSize: 210,
                                              spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 140, maximum: 340), spacing: spacing),
                     count: count)
    }

    /// 资料项列数：按档案卡右列的实际宽度算，窗口变宽就多排一列。
    func factsColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 12
        let width = width > 0 ? width : 620
        let count = max(1, GridLayout.columns(contentWidth: width, targetSize: 210, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 120), spacing: spacing), count: count)
    }

    var body: some View {
        ZStack {
            pageContent
                .opacity(personTarget == nil ? 1 : 0)
                .allowsHitTesting(personTarget == nil)
            if let member = personTarget {
                // 演职员改成页面内二级页：不弹窗，顶栏「返回」逐层后退。
                CinemaPersonDetailView(
                    member: member,
                    onOpenEntry: { entry in
                        personTarget = nil
                        onOpenEntry(entry)
                    },
                    onPlay: onPlay
                )
                .id(member.id)
                .transition(.opacity)
            }
            if showTrailer, let request = trailerRequest {
                // 预告片在页面内播放：不打开浏览器。
                CinemaTrailerOverlay(request: request) {
                    showTrailer = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: personTarget?.id)
        .animation(.easeOut(duration: 0.16), value: showTrailer)
        // 悬停档案挂在整个详情页最上层（在 ScrollView 之外）：贴着集卡显示，
        // 但会被收进窗口可视范围，卡片在边缘时也不会被裁掉。
        .overlayPreferenceValue(CinemaEpisodeAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if personTarget == nil, !showTrailer,
                   // 窄窗口下浮层会盖住大半网格：直接不显示，信息仍在卡片与档案里。
                   proxy.size.width >= 820,
                   let episode = hoverPanelEpisode,
                   let anchor = anchors[episode.id] {
                    let rect = proxy[anchor]
                    let margin: CGFloat = 12
                    let gap: CGFloat = 14
                    let width = min(380, max(260, proxy.size.width * 0.36))
                    let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                    let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                    let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                    let y = min(max(margin, rect.minY),
                                max(margin, proxy.size.height - hoverPanelHeight - margin))
                    episodeHoverCard(episode)
                        .frame(width: width)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { hoverPanelHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, height in
                                        hoverPanelHeight = height
                                    }
                            }
                        }
                        .offset(x: x, y: y)
                        // 换集时换成新的身份：面板就地淡入淡出，不会从上一张卡横着滑过来。
                        .id(episode.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity))
                        // 面板不吃鼠标事件：鼠标可以直接穿过它去选别的集卡，不会被挡住。
                        // 需要读完简介时，停在那一集上不动即可（停住不会触发别的卡片）。
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: hoverPanelEpisode?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaDetailTone.page)
        .task {
            // 推荐 / 详情以「最有资料的一集」为种子：优先 TMDB 已匹配、其次有背景图。
            // 只看 backdrop 会挑到未匹配分集，导致推荐区整块不出现。
            let sample = series.episodes.first(where: {
                $0.matched && $0.tmdbID != nil && $0.provider == .tmdb
            }) ?? series.episodes.first(where: { $0.backdropURL != nil })
                ?? series.episodes.first
            guard let sample else { return }
            enriched = await store.enrichCinemaEntry(sample)
            recommendationGroups = await store.cinemaRecommendationGroups(for: enriched ?? sample)
            // 分集缓存里如果有现成的多源推荐（与电影详情同一套分组），直接补上。
            if recommendationGroups.isEmpty {
                recommendationGroups = series.episodes
                    .compactMap(\.recommendationGroups)
                    .first(where: { !$0.isEmpty }) ?? []
            }
            // 打开详情时顺手补一次在线片头片尾：没设置过的剧集自动填上。
            await store.ensureCinemaIntroMark(for: series)
        }
        .task(id: seasonInfoKey) {
            // 切季 / 换剧后旧的键盘游标已经不在当前列表里；恢复上次位置时保留。
            if suppressSeasonReset {
                suppressSeasonReset = false
            } else {
                keyboardEpisodeID = nil
                hoveredEpisode = nil
            }
            await loadEpisodeInfos()
        }
        // 顶栏返回：先关预告片，再退演职员页，最后退剧集详情。
        .onChange(of: store.cinemaDetailCloseTick) { _, _ in
            if showTrailer {
                showTrailer = false
            } else if personTarget != nil {
                personTarget = nil
            } else {
                onClose()
            }
        }
        // 进播放器时把键盘交出去，回来后还给剧集网格。
        .onChange(of: store.viewerID) { _, viewing in
            episodeGridFocus = viewing == nil
        }
        .onChange(of: showTrailer) { _, showing in
            if !showing { episodeGridFocus = true }
        }
        .onChange(of: personTarget?.id) { _, current in
            if current == nil { episodeGridFocus = true }
        }
    }

    var pageTopAnchor: String { "cinema-series-detail-top" }

    /// 详情页默认从顶部开始：不沿用上一部剧 / 上次浏览留下的滚动位置。
    func scrollToPageTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(pageTopAnchor, anchor: .top)
        }
    }

    var pageContent: some View {
        // 底图只能挂 background：它是 aspect-fill 的远程剧照，只锁了高度，
        // 图片加载完会带出「自然宽度」（760pt 高约等于 1350pt 宽）。
        // 一旦作为 ZStack 兄弟节点参与布局，整页就会被撑得比窗口更宽，
        // 表现为「先是占满，图片一出来就超过 100%，拖窗口也缩不回去」。
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // 顶部锚点：进入详情 / 切换到另一部剧时回到这里。
                        Color.clear
                            .frame(height: 0)
                            .id(pageTopAnchor)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(key: CinemaScrollOffsetKey.self,
                                                           value: geo.frame(in: .named("cinemaSeriesScroll")).minY)
                                }
                            }
                        dossierSection(width: width)
                        episodesSection(width: width)
                        let recommendGroups = visibleRecommendationGroups
                        if !recommendGroups.isEmpty {
                            CinemaRecommendationShelf(
                                groups: recommendGroups,
                                isLocal: { store.cinemaEntry(tmdbID: $0.tmdbID, kind: $0.kind) != nil },
                                onOpen: { recom in
                                    if let doubanID = recom.doubanID {
                                        store.openDoubanPage(doubanID: doubanID)
                                    } else if let local = store.cinemaEntry(tmdbID: recom.tmdbID,
                                                                           kind: recom.kind) {
                                        onOpenEntry(local)
                                    } else {
                                        searchOnlineCinema(recom)
                                    }
                                },
                                onSearchOnline: { searchOnlineCinema($0) },
                                onOpenExternal: { recom in
                                    if let doubanID = recom.doubanID {
                                        store.openDoubanPage(doubanID: doubanID)
                                    } else {
                                        searchOnlineCinema(recom)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, horizontal)
                    .padding(.bottom, 36)
                    // 只填满可视宽度，不能用固定 width：固定宽度会变成窗口的最小宽度，
                    // 窗口一缩就由「上一次的宽度」反推回来，拖到多大就再也缩不回去。
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .coordinateSpace(name: "cinemaSeriesScroll")
                .onPreferenceChange(CinemaScrollOffsetKey.self) { scrollOffset = $0 }
                // 键盘上下跨行要知道当前列数：跟着容器宽度一起更新。
                .onAppear {
                    contentWidth = width
                    restoreDetailState(scrollProxy)
                }
                .onChange(of: width) { _, newValue in contentWidth = newValue }
                .onChange(of: series.id) { _, _ in restoreDetailState(scrollProxy) }
                .onChange(of: currentSeason) { _, _ in saveDetailMemory() }
                .onChange(of: keyboardEpisodeID) { _, _ in saveDetailMemory() }
            }
        }
        .background(alignment: .top) { ambientBackground }
        .overlay(alignment: .top) { compactHeader }
        .animation(.easeOut(duration: 0.18), value: scrollOffset < -140)
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
                if request.kind == .poster {
                    artworkPosterOverride = url
                } else {
                    artworkBackdropOverride = url
                }
            }
        }
    }

    /// 剧集详情用剧照虚化铺底：贴着 Hero 往下渐隐到页面底色，
    /// 不再用固定高度硬切，避免中间出现一条突兀的亮色横带。
    var ambientBackground: some View {
        ZStack(alignment: .top) {
            CinemaDetailTone.page
            CinemaArtwork(urlString: artworkBackdropOverride ?? series.backdropURL ?? series.posterURL,
                          contentMode: .fill,
                          maxPixelSize: 1100)
                .frame(height: 760)
                .blur(radius: 90, opaque: true)
                .opacity(0.20)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.80), location: 0.38),
                        .init(color: .black.opacity(0.28), location: 0.72),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// 滚过档案卡后浮出的紧凑标题条：片名 / 年份 / 评分，一直跟着滚动。
    @ViewBuilder
    var compactHeader: some View {
        if scrollOffset < -140 {
            HStack(spacing: 8) {
                Text(series.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineLimit(1)
                if let year = series.year {
                    Text(String(year))
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                Spacer(minLength: 0)
                if let rating = seriesRating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.10))
                    .frame(height: 0.5)
            }
            .transition(.opacity)
        }
    }

    /// 换封面用的样本条目：优先已补全的那一集，其次任意已匹配的剧集。
    var artworkSample: CinemaEntry? {
        enriched ?? series.episodes.first(where: { $0.matched && $0.tmdbID != nil })
    }

    /// 推荐分组：优先本次拉到的，其次条目缓存；旧数据只有 TMDB 列表时兜底成一个 tab。
    var visibleRecommendationGroups: [CinemaRecommendationGroup] {
        if !recommendationGroups.isEmpty { return recommendationGroups }
        if let cached = enriched?.recommendationGroups, !cached.isEmpty { return cached }
        if let recs = enriched?.recommendations, !recs.isEmpty {
            return [CinemaRecommendationGroup(source: .tmdb, title: "TMDB", items: recs)]
        }
        return []
    }

    /// 推荐条目本库没有时：网络影院还没上线，先给占位提示。
    func searchOnlineCinema(_ recom: CinemaRecommendation) {
        store.searchOnlineCinema(recom.title)
    }

    func loadArtwork(_ kind: CinemaArtworkKind) {
        guard let sample = artworkSample else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        // 候选由面板自己拉，这里只负责把请求递过去。
        artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
    }

    /// 返回详情时恢复上次看的季与选中集；没有记忆就回到顶部。
    func restoreDetailState(_ proxy: ScrollViewProxy) {
        guard let memory = store.cinemaSeriesMemory[series.id] else {
            scrollToPageTop(proxy)
            return
        }
        if let season = memory.season, season != currentSeason {
            suppressSeasonReset = true
            selectedSeason = season
        }
        keyboardEpisodeID = memory.episodeID
        hoveredEpisode = memory.episodeID
        guard let id = memory.episodeID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    func saveDetailMemory() {
        store.cinemaSeriesMemory[series.id] = CinemaSeriesMemory(season: currentSeason,
                                                                 episodeID: keyboardEpisodeID)
    }

    var seasonInfoKey: String {
        guard currentSeason > 0,
              let tvID = series.episodes.first(where: { $0.tmdbID != nil && $0.provider == .tmdb })?.tmdbID else { return "" }
        return "\(tvID)-\(currentSeason)"
    }

    /// 每集标题 / 简介 / 剧照：按当前标签页的季读取，切回其他季时直接用已缓存结果。
    func loadEpisodeInfos() async {
        guard currentSeason > 0,
              let tvID = series.episodes.first(where: { $0.tmdbID != nil && $0.provider == .tmdb })?.tmdbID else { return }
        let season = currentSeason
        if let cached = store.cachedCinemaEpisodeInfos(tvID: tvID, season: season) {
            episodeInfos[season] = cached.infos
            if cached.fresh { return }
        }
        guard let refreshed = await store.refreshCinemaEpisodeInfos(tvID: tvID, season: season) else { return }
        guard !Task.isCancelled else { return }
        episodeInfos[season] = refreshed
    }

    // MARK: 季与下一集

    var orderedEpisodes: [CinemaEntry] {
        series.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
    }

    /// 季标签：最新一季在最左（降序），打开页面默认就是它。
    var seasons: [Int] {
        Array(Set(orderedEpisodes.map { $0.season ?? 0 })).sorted(by: >)
    }

    var currentSeason: Int {
        selectedSeason ?? seasons.first ?? 0
    }

    var visibleEpisodes: [CinemaEntry] {
        guard seasons.count > 1 else { return orderedEpisodes }
        return orderedEpisodes.filter { ($0.season ?? 0) == currentSeason }
    }

    /// 单集信息按「季 + 集号」取，切换季标签时不会串到别的季。
    func episodeInfo(_ episode: CinemaEntry) -> CinemaEpisodeInfo? {
        guard let number = episode.episode else { return nil }
        return episodeInfos[episode.season ?? 0]?[number]
    }

    /// 悬停档案跟随哪一集：鼠标悬停和键盘选中共用同一个状态，
    /// 键盘切换时由 moveEpisodeCursor 把悬停集同步过来，档案才会跟着焦点走。
    var hoverPanelEpisode: CinemaEntry? {
        guard let id = hoveredEpisode else { return nil }
        return visibleEpisodes.first(where: { $0.id == id })
    }

    /// 鼠标进入集卡或档案面板：取消待关闭，并把档案锁到这一集。
    func holdHoverPanel(_ id: UUID) {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        if hoveredEpisode != id {
            hoveredEpisode = id
        }
    }

    /// 离开集卡：留一小段时间再收起，避免鼠标划过间隙时面板闪烁。
    func scheduleHoverDismiss() {
        hoverDismissTask?.cancel()
        let work = DispatchWorkItem {
            hoveredEpisode = nil
        }
        hoverDismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 优先正在看的一集；否则接在最后看完的一集后面；全部看完返回 nil。
    var nextEpisode: CinemaEntry? {
        let ordered = orderedEpisodes
        guard !ordered.isEmpty else { return nil }
        if let inProgress = ordered.first(where: { store.cinemaWatchState(for: $0) == .inProgress }) {
            return inProgress
        }
        if let lastFinished = ordered.lastIndex(where: { store.cinemaWatchState(for: $0) == .finished }) {
            let next = lastFinished + 1
            guard next < ordered.count else { return nil }
            return ordered[next]
        }
        return ordered.first
    }

    /// 跳过片头尾：和「继续播放 / 预告片」同高的胶囊，点开是滑杆面板。
    var introSkipControl: some View {
        let mark = activeIntroMark
        return Button {
            showIntroPanel.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "scissors")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(LumaBrand.amber.opacity(mark.isEnabled ? 1 : 0.55))

                Text("跳过片头尾")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))

                Text(introSummaryText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(mark.isEnabled ? LumaBrand.amber.opacity(0.95)
                                                    : CinemaDetailTone.ink.opacity(0.45))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 170)
            .background {
                Capsule()
                    .fill(mark.isEnabled ? LumaBrand.amber.opacity(0.16)
                                         : CinemaDetailTone.ink.opacity(0.14))
            }
            .overlay {
                Capsule()
                    .strokeBorder(mark.isEnabled ? LumaBrand.amber.opacity(0.42)
                                                 : CinemaDetailTone.ink.opacity(0.10),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showIntroPanel, arrowEdge: .bottom) {
            introSkipPanel
        }
        .help("设置片头 / 片尾跳过的秒数；可以按整部剧或只对当前集生效")
    }

    var introSummaryText: String {
        let mark = activeIntroMark
        guard mark.isEnabled else { return "未设置" }
        var parts: [String] = []
        if mark.introSeconds > 0 { parts.append("片头 \(mark.introSeconds)s") }
        if mark.outroSeconds > 0 { parts.append("片尾 \(mark.outroSeconds)s") }
        return parts.joined(separator: " · ")
    }

    /// 调节面板：滑杆直接改秒数，自动识别、范围与清除都在这一处。
    var introSkipPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "scissors")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LumaBrand.amber)
                Text("跳过片头片尾")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Circle()
                    .fill(activeIntroMark.isEnabled ? LumaBrand.mint : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(activeIntroMark.isEnabled ? "已启用" : "已关闭")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text("开播时自动跳到片头结束；进入片尾区间时直接跳到结尾。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            introSliderRow(title: "片头", seconds: introSecondsBinding)
            introSliderRow(title: "片尾", seconds: outroSecondsBinding)

            HStack(spacing: 8) {
                Text("作用范围")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $introScope) {
                    Text("整部剧").tag(IntroScope.series)
                    Text(introTargetEpisode.map { "本集 \(episodeLabel($0))" } ?? "本集")
                        .tag(IntroScope.episode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Spacer(minLength: 0)
            }
            if introScope == .episode {
                Text(activeIntroIsOverride
                     ? "本集使用单独设置，修改只影响这一集。"
                     : "本集尚未单独设置，修改后自动成为本集设置。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Button {
                    Task { await runIntroAutoDetect() }
                } label: {
                    Label(detectingIntro ? "识别中…" : "自动识别", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(detectingIntro)

                if canClearIntro {
                    Button("清除") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if introScope == .episode, let episode = introTargetEpisode {
                                store.clearCinemaEpisodeIntroMark(for: episode)
                            } else {
                                store.setCinemaIntroMark(CinemaIntroMark(), forSeriesKey: series.id)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    func introSliderRow(title: String, seconds: Binding<Int>) -> some View {
        let value = Binding<Double>(
            get: { Double(seconds.wrappedValue) },
            set: { seconds.wrappedValue = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 0)
                Text(seconds.wrappedValue > 0 ? "\(seconds.wrappedValue) 秒" : "关闭")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(seconds.wrappedValue > 0 ? LumaBrand.amber : Color.secondary)
            }
            Slider(value: value, in: 0...300, step: 15)
                .tint(LumaBrand.amber)
                .controlSize(.small)
        }
    }

    /// 单集覆盖的目标：优先「当前集（下一集）」，否则第一集。
    var introTargetEpisode: CinemaEntry? {
        nextEpisode ?? orderedEpisodes.first
    }

    var activeIntroMark: CinemaIntroMark {
        if introScope == .episode, let episode = introTargetEpisode {
            return store.cinemaIntroMark(for: episode)
        }
        return store.cinemaIntroMark(forSeriesKey: series.id)
    }

    var activeIntroIsOverride: Bool {
        guard introScope == .episode, let episode = introTargetEpisode else { return false }
        return store.hasCinemaEpisodeIntroMark(for: episode)
    }

    var canClearIntro: Bool {
        if introScope == .episode, let episode = introTargetEpisode {
            return store.hasCinemaEpisodeIntroMark(for: episode)
        }
        return store.cinemaIntroMark(forSeriesKey: series.id).isEnabled
    }

    func applyIntroMark(_ mark: CinemaIntroMark) {
        if introScope == .episode, let episode = introTargetEpisode {
            store.setCinemaIntroMark(mark, for: episode)
        } else {
            store.setCinemaIntroMark(mark, forSeriesKey: series.id)
        }
    }

    /// 自动识别：整部剧取第一集，本集取当前这一集；在线库优先，本地静音检测兜底。
    func runIntroAutoDetect() async {
        guard !detectingIntro else { return }
        detectingIntro = true
        // 本地静音检测要跑几十秒：登记进任务中心，切换页面后仍能看到进度。
        let jobID = store.beginSourceJob(
            SourceJob(sourceID: store.sourceID(for: store.cinemaActiveScope),
                      kind: .analyze,
                      title: "片头自动识别",
                      isCancellable: false)
        )
        defer {
            detectingIntro = false
            store.finishSourceJob(jobID, message: "片头识别完成")
        }
        let episode = introScope == .episode ? introTargetEpisode : nil
        let detection: LibraryStore.CinemaIntroDetection?
        if let episode {
            detection = await store.detectCinemaIntro(for: episode)
        } else {
            detection = await store.detectCinemaIntro(for: series)
        }
        guard let detection else {
            store.showToast(episode == nil
                            ? "在线库没有这部剧的记录，且没有可分析的本地分集；可手动设置"
                            : "在线库没有这一集的记录，且不是可分析的本地文件；可手动设置")
            return
        }
        let mark = detection.mark
        if let episode {
            store.setCinemaIntroMark(mark, for: episode)
        } else {
            store.setCinemaIntroMark(mark, forSeriesKey: series.id)
        }
        let intro = mark.introSeconds > 0 ? "片头 \(mark.introSeconds) 秒" : "片头未识别"
        let outro = mark.outroSeconds > 0 ? "片尾 \(mark.outroSeconds) 秒" : "片尾未识别"
        let source = detection.online ? "在线库" : "本地静音检测"
        let scope = episode.map { " · \(episodeLabel($0))" } ?? ""
        store.showToast("自动识别完成（\(source)\(scope)）：\(intro) · \(outro)")
    }

    var introSecondsBinding: Binding<Int> {
        Binding(
            get: { activeIntroMark.introSeconds },
            set: { value in
                var mark = activeIntroMark
                mark.introSeconds = value
                applyIntroMark(mark)
            }
        )
    }

    var outroSecondsBinding: Binding<Int> {
        Binding(
            get: { activeIntroMark.outroSeconds },
            set: { value in
                var mark = activeIntroMark
                mark.outroSeconds = value
                applyIntroMark(mark)
            }
        )
    }

    /// 预告片按整部剧找：用详情补全后的条目，没有就退回本剧第一条已识别分集。
    var trailerRequest: CinemaTrailerRequest? {
        let sample = enriched
            ?? series.episodes.first(where: { $0.backdropURL != nil })
            ?? series.episodes.first
        guard let sample, sample.matched else { return nil }
        return CinemaTrailerRequest(title: sample.title,
                                    originalTitle: sample.originalTitle,
                                    year: sample.year ?? series.year,
                                    isTV: sample.kind == .tv)
    }

    func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                if let directors = enriched?.directors, !directors.isEmpty {
                    Text("导演 " + directors.prefix(2).joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        CinemaCastTile(member: member,
                                       onOpen: { personTarget = member },
                                       onSearchOnline: { store.searchOnlineCinema(member.name) })
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    var actions: some View {
        // 一行放不下时自动换行：窄窗口下「跳过片头尾」不会和「预告片」叠在一起。
        CinemaBadgeFlow(spacing: 9, lineSpacing: 9) {
            if let next = nextEpisode {
                Button {
                    onPlay(next)
                } label: {
                    Label(playLabel(for: next), systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(LumaBrand.amber, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if let first = orderedEpisodes.first, first.id != nextEpisode?.id {
                Button {
                    onPlay(first)
                } label: {
                    Label("从第 1 集开始", systemImage: "backward.end.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.16), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if trailerRequest != nil {
                Button {
                    showTrailer = true
                } label: {
                    Label("预告片", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.14), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if !orderedEpisodes.isEmpty {
                // 跳过片头尾和预告片同一行：点开就是滑杆面板，不需要记菜单层级。
                introSkipControl
            }
        }
    }

    func playLabel(for episode: CinemaEntry) -> String {
        if let progress = store.cinemaProgress[episode.id],
           progress.fraction > 0.01, !progress.isFinished {
            return "继续播放 \(episodeLabel(episode))"
        }
        return "开始观看 \(episodeLabel(episode))"
    }

    /// 季标签栏：最新一季在最左；每枚标签带集数与观看进度，横排可滚动。
    var seasonTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { season in
                    seasonTab(season)
                }
            }
            .padding(.vertical, 1)
        }
    }

    func seasonTab(_ season: Int) -> some View {
        let episodes = orderedEpisodes.filter { ($0.season ?? 0) == season }
        let watched = episodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
        let fraction = episodes.isEmpty ? 0 : Double(watched) / Double(episodes.count)
        let active = season == currentSeason
        let isLatest = season == seasons.first
        return Button {
            // 不带动画切换：季卡内容会整体换一批，动画会让网格高度插值、页面跟着上下抖。
            selectedSeason = season
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(season == 0 ? "未标季" : "第 \(season) 季")
                        .font(.system(size: 12, weight: .semibold))
                    if isLatest, season > 0 {
                        Text("最新")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.black.opacity(0.78))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(LumaBrand.amber, in: Capsule())
                    }
                    Text("\(episodes.count) 集")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(active ? LumaBrand.amber.opacity(0.95) : .secondary)
                }
                // 细进度线：一眼看出哪一季看到哪。
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(CinemaDetailTone.ink.opacity(0.12))
                        if fraction > 0 {
                            Capsule()
                                .fill(LumaBrand.amber.opacity(active ? 1 : 0.6))
                                .frame(width: max(2, geo.size.width * fraction))
                        }
                    }
                }
                .frame(height: 2.5)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(active ? LumaBrand.amber.opacity(0.16) : CinemaDetailTone.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(active ? LumaBrand.amber.opacity(0.55)
                                         : CinemaDetailTone.ink.opacity(0.07),
                                  lineWidth: active ? 1 : 0.6)
            }
            .foregroundStyle(active ? LumaBrand.amber : CinemaDetailTone.ink.opacity(0.86))
        }
        .buttonStyle(.plain)
        .help(season == 0 ? "未标季" : "切换到第 \(season) 季")
    }

    func episodesSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题与季标签同一行：最新一季在最左，切换只影响下方网格。
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("剧集")
                    .font(.system(size: 15, weight: .semibold))
                if seasons.count > 1 {
                    seasonTabBar
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let season = seasons.first {
                    Text(season == 0 ? "未标季" : "第 \(season) 季")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                    Text("\(visibleEpisodes.count) 集")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                }
                if hoveredEpisode == nil, contentWidth >= 760 {
                    Text("方向键切集 · 空格播放")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            ScrollViewReader { scrollProxy in
                LazyVGrid(columns: episodeColumns(width: width), alignment: .leading, spacing: 18) {
                    ForEach(visibleEpisodes) { episode in
                        episodeCard(episode)
                            .anchorPreference(key: CinemaEpisodeAnchorKey.self, value: .bounds) {
                                [episode.id: $0]
                            }
                            .id(episode.id)
                    }
                }
                // 和图库网格一致的键盘操作：← → 逐集，↑ ↓ 跨一行，空格 / 回车播放。
                .focusable()
                .focused($episodeGridFocus)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    moveEpisodeCursor(-1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    moveEpisodeCursor(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveEpisodeCursor(-episodeColumnCount)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveEpisodeCursor(episodeColumnCount)
                    return .handled
                }
                .onKeyPress(.space) {
                    playFocusedEpisode()
                    return .handled
                }
                .onKeyPress(.return) {
                    playFocusedEpisode()
                    return .handled
                }
                .onChange(of: keyboardEpisodeID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async { episodeGridFocus = true }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            Diagnostics.record("影院剧集网格 width=\(Int(width)) "
                               + "列数=\(episodeColumns(width: width).count) "
                               + "集=\(visibleEpisodes.count)")
        }
    }

    /// 方向键跨一行要跳几列：和外层量到的宽度保持同一套列数规则。
    var episodeColumnCount: Int {
        episodeColumns(width: contentWidth).count
    }

    func moveEpisodeCursor(_ delta: Int) {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        let list = visibleEpisodes
        guard !list.isEmpty else { return }
        guard let id = keyboardEpisodeID,
              let current = list.firstIndex(where: { $0.id == id }) else {
            // 还没有游标：先从「下一集」开始。
            let target = nextEpisode ?? list[0]
            keyboardEpisodeID = target.id
            hoveredEpisode = target.id
            return
        }
        let next = min(max(current + delta, 0), list.count - 1)
        keyboardEpisodeID = list[next].id
        // 键盘切换时把悬停指针一起挪过去，档案面板跟着焦点走而不是停在鼠标下面。
        hoveredEpisode = list[next].id
    }

    func playFocusedEpisode() {
        guard store.viewerID == nil else { return }
        let list = visibleEpisodes
        guard !list.isEmpty else { return }
        if let id = keyboardEpisodeID, let episode = list.first(where: { $0.id == id }) {
            onPlay(episode)
        } else if let target = nextEpisode ?? list.first {
            onPlay(target)
        }
    }

    // MARK: 剧集档案

    /// 剧集档案：把海报、简介、资料与演职员收进同一张卡片。
    /// 海报作视觉锚点，右侧按「原名 / 宣传语 → 简介 → 带图标的资料网格」排，
    /// 底部接演职员，不再让三块内容各占一整行。
    func dossierSection(width: CGFloat) -> some View {
        let posterWidth = cinemaDetailPosterWidth(for: width)
        return VStack(alignment: .leading, spacing: 0) {
            // 窄窗口把海报与资料改成上下排列，文字列不会被压成一条缝。
            if width < 760 {
                VStack(alignment: .leading, spacing: 18) {
                    dossierPosterColumn(posterWidth: posterWidth)
                    dossierInfoColumn(width: max(280, width - 44))
                }
                .padding(22)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    dossierPosterColumn(posterWidth: posterWidth)
                    dossierInfoColumn(width: width - 22 * 2 - posterWidth - 24)
                }
                .padding(22)
            }

            if let cast = enriched?.cast, !cast.isEmpty {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                castStrip(cast)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .background { dossierPlate }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            CinemaDetailTone.ink.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 档案卡右侧信息列：标题、简介与资料网格共用，窄窗口时也可单独铺满整行。
    func dossierInfoColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            dossierKicker
            dossierTitleBlock
            dossierSynopsis
            dossierFactsGrid(width: width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 档案卡底板：玻璃底 + 左上角一层很淡的琥珀光，和海报的暖色调衔接。
    var dossierPlate: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.062),
                                          CinemaDetailTone.ink.opacity(0.022)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
    }

    /// 海报 + 评分牌 + 整剧观看进度：三者共用一列，宽度和海报对齐。
    func dossierPosterColumn(posterWidth: CGFloat) -> some View {
        VStack(spacing: 9) {
            CinemaPosterDeck(
                width: posterWidth,
                posterURL: artworkPosterOverride ?? series.posterURL,
                fallbackPhoto: series.episodes.first?.file.photoItem,
                canLoadMore: artworkSample?.provider == .tmdb && artworkSample?.tmdbID != nil,
                loadCandidates: {
                    guard let sample = artworkSample else { return [] }
                    let result = await store.cinemaArtworkCandidates(for: sample)
                    return result.posters
                        .sorted { ($0.languageRank, -($0.rating ?? 0))
                            < ($1.languageRank, -($1.rating ?? 0)) }
                        .map(\.url)
                },
                onApply: { url in
                    guard let sample = artworkSample else { return }
                    store.applyCinemaArtwork(sample, posterURL: url, backdropURL: nil)
                    artworkPosterOverride = url
                }
            )
            .contextMenu {
                Button("选择海报…") { loadArtwork(.poster) }
                Button("选择背景…") { loadArtwork(.backdrop) }
            }

            if watchedCount > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: Double(watchedCount),
                                 total: Double(max(1, orderedEpisodes.count)))
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text("已看 \(watchedCount) / \(orderedEpisodes.count) 集")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                .frame(width: posterWidth)
            }
        }
        .frame(width: posterWidth, alignment: .top)
    }

    /// 档案抬头：琥珀刻字标签 + 年份 / 季 / 集 + 播出状态。
    var dossierKicker: some View {
        HStack(spacing: 8) {
            Text("剧集档案")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(CinemaDetailTone.accent.opacity(0.92))
            Rectangle()
                .fill(LumaBrand.amber.opacity(0.35))
                .frame(width: 24, height: 0.8)
            Text(dossierMetaLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            dossierRatingPill
            dossierStatusPill
        }
    }

    /// 三源评分：TMDB / 豆瓣 / 我的，有值的才列出，缺的整段不占位；末尾补评分人数。
    @ViewBuilder
    var dossierRatingPill: some View {
        let badges = seriesRatingBadges()
        let votes = enriched?.voteCount ?? series.episodes.first?.voteCount
        if !badges.items.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(badges.items.enumerated()), id: \.element.id) { pair in
                    if pair.offset > 0 {
                        Rectangle()
                            .fill(CinemaDetailTone.ink.opacity(0.12))
                            .frame(width: 0.6, height: 12)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: pair.element.icon)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(pair.element.tint)
                        Text(pair.element.label)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.50))
                        Text(pair.element.text)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(CinemaDetailTone.ink)
                    }
                }
                if let votes, votes > 0 {
                    Rectangle()
                        .fill(CinemaDetailTone.ink.opacity(0.12))
                        .frame(width: 0.6, height: 12)
                    Text(voteCountText(votes))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
            .help(badges.help)
        }
    }

    /// 收集三源评分：主源是豆瓣时 rating 实际是豆瓣分，TMDB 段要留空。
    func seriesRatingBadges() -> (items: [(id: String, icon: String, label: String,
                                                   text: String, tint: Color)],
                                          help: String) {
        let entry = enriched ?? series.episodes.first
        let provider = entry?.provider
        let primary = seriesRating
        let tmdb = provider == .douban ? nil : primary
        let douban = entry?.doubanRating ?? (provider == .douban ? primary : nil)
        let mine = entry.flatMap { store.cinemaUserState(for: $0.id).rating }

        var items: [(id: String, icon: String, label: String, text: String, tint: Color)] = []
        var help: [String] = []
        if let tmdb {
            items.append(("tmdb", "film.fill", "TMDB", String(format: "%.1f", tmdb), LumaBrand.violet))
            help.append("TMDB \(String(format: "%.1f", tmdb))")
        }
        if let douban {
            items.append(("douban", "leaf.fill", "豆瓣", String(format: "%.1f", douban), LumaBrand.mint))
            help.append("豆瓣 \(String(format: "%.1f", douban))")
        }
        if let mine {
            items.append(("mine", "star.fill", "我的", "\(mine)", LumaBrand.amber))
            help.append("我的 \(mine) 星")
        }
        if let votes = enriched?.voteCount, votes > 0 {
            help.append(voteCountText(votes))
        }
        return (items, help.joined(separator: " · "))
    }

    /// 片名 / 原名 / 宣传语 / 播放动作：去掉大幅剧照后，这一块承担页面标题。
    var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(series.title)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(CinemaDetailTone.ink)
                .lineLimit(2)
                .textSelection(.enabled)

            if let original = enriched?.originalTitle,
               !original.isEmpty,
               original.caseInsensitiveCompare(series.title) != .orderedSame {
                Text(original.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = enriched?.tagline, !tagline.isEmpty {
                Text("「\(tagline)」")
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                    .lineLimit(2)
            }

            actions
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    var dossierStatusPill: some View {
        if let status = cinemaStatusText(enriched?.status) {
            let running = enriched?.status == "Returning Series"
                || enriched?.status == "In Production"
                || enriched?.status == "Planned"
            HStack(spacing: 5) {
                Circle()
                    .fill(running ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(running ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CinemaDetailTone.ink.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
    }

    /// 简介：默认收 5 行，长简介可展开；没有简介时提示换数据源。
    @ViewBuilder
    var dossierSynopsis: some View {
        let overview = enriched?.overview ?? series.overview ?? ""
        if overview.isEmpty {
            Text("暂无剧情简介。可以在顶栏面板里「重新匹配」换一个数据源，通常会补全简介与演职员。")
                .font(.system(size: 12))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview)
                    .font(.system(size: 12.8))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
                    .lineSpacing(6)
                    .lineLimit(dossierExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if overview.count > 180 {
                    Button(dossierExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dossierExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        }
    }

    /// 资料网格：每项一枚琥珀小图标 + 标签 / 值，和海报卡同一张底板上。
    func dossierFactsGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: factsColumns(width: width),
                  alignment: .leading, spacing: 12) {
            ForEach(dossierFacts) { fact in
                HStack(spacing: 9) {
                    Image(systemName: fact.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.accent.opacity(0.90))
                        .frame(width: 24, height: 24)
                        .background(LumaBrand.amber.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.38))
                        Text(fact.value)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.82))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
        // 资料网格跟随可用宽度重排列数：宽窗口多排几列，不会只挤在左边。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct DossierFact: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label + "|" + value }
    }

    /// 本地与 TMDB 能拿到的资料项都在这里，缺哪项就不占位。
    var dossierFacts: [DossierFact] {
        var items: [DossierFact] = []
        if let value = cinemaDateText(enriched?.releaseDate) ?? series.year.map({ "\($0) 年" }) {
            items.append(DossierFact(icon: "calendar", label: "首播", value: value))
        }
        if let value = seasonCountText {
            items.append(DossierFact(icon: "rectangle.stack", label: "季数", value: value))
        }
        if let value = episodeCountText {
            items.append(DossierFact(icon: "list.number", label: "集数", value: value))
        }
        if let value = cinemaMinutesText(enriched?.runtime) {
            items.append(DossierFact(icon: "clock", label: "单集", value: value))
        }
        let sampleFile = enriched?.file ?? series.episodes.first?.file
        if let value = sampleFile?.displayTags.first(where: { $0 == "DV" || $0.hasPrefix("HDR") }) {
            items.append(DossierFact(icon: "sparkles.tv",
                                     label: "HDR",
                                     value: value == "DV" ? "Dolby Vision" : value))
        }
        if sampleFile?.displayTags.contains("Atmos") == true {
            items.append(DossierFact(icon: "hifispeaker.2", label: "音轨", value: "Dolby Atmos"))
        }
        if let fps = sampleFile?.parsedFrameRate {
            items.append(DossierFact(icon: "speedometer", label: "帧率", value: "\(fps) fps"))
        }
        if let value = enriched?.genres?.prefix(4).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "theatermasks", label: "类型", value: value))
        }
        if let value = enriched?.certification, !value.isEmpty {
            items.append(DossierFact(icon: "shield.lefthalf.filled", label: "分级", value: value))
        }
        if let value = cinemaLanguageName(enriched?.originalLanguage) {
            items.append(DossierFact(icon: "character.bubble", label: "语言", value: value))
        }
        if let countries = enriched?.countries, !countries.isEmpty {
            let value = countries.prefix(2).map(cinemaCountryName).joined(separator: " / ")
            items.append(DossierFact(icon: "globe.asia.australia", label: "国家", value: value))
        }
        if let value = enriched?.networks?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "antenna.radiowaves.left.and.right", label: "平台", value: value))
        }
        if let value = enriched?.companies?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "building.2", label: "制作", value: value))
        }
        if let value = enriched?.collectionName, !value.isEmpty {
            items.append(DossierFact(icon: "square.stack.3d.up", label: "合集", value: value))
        }
        if let id = enriched?.tmdbID {
            let label = enriched?.provider == .tvdb ? "TVDB" : "TMDB"
            items.append(DossierFact(icon: "number", label: label, value: "\(id)"))
        }
        return items
    }

    var dossierMetaLine: String {
        var parts: [String] = []
        if let year = enriched?.year ?? series.year, year > 0 {
            parts.append("\(year)")
        }
        if let seasons = seasonCountText {
            parts.append(seasons)
        }
        if let episodes = episodeCountText {
            parts.append(episodes)
        }
        return parts.joined(separator: " · ")
    }

    var seriesRating: Double? {
        let rating = enriched?.rating ?? series.rating
        guard let rating, rating > 0 else { return nil }
        return rating
    }

    var watchedCount: Int {
        orderedEpisodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
    }

    func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    var seasonCountText: String? {
        let count = enriched?.seasonCount ?? (seasons.filter { $0 > 0 }.isEmpty ? nil : seasons.filter { $0 > 0 }.count)
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 季" : "\(count) 季"
    }

    var episodeCountText: String? {
        let total = enriched?.episodeTotal ?? series.episodeCount
        return total > 0 ? "\(total) 集" : nil
    }

    func minutesText(_ duration: Double?) -> String? {
        guard let duration, duration > 0 else { return nil }
        let minutes = Int((duration / 60).rounded())
        return minutes > 0 ? "\(minutes) 分钟" : nil
    }

    func episodeCard(_ episode: CinemaEntry) -> some View {
        let watchState = store.cinemaWatchState(for: episode)
        let progress = store.cinemaProgress[episode.id]
        let hovered = hoveredEpisode == episode.id
        // 文档约定：当前集用琥珀描边标出，不靠 hover 才看得出「接着看哪一集」。
        let isCurrent = nextEpisode?.id == episode.id
        let info = episodeInfo(episode)
        // 单集剧照优先：TMDB 季接口给的 still 比整部剧的 backdrop 更能区分每一集。
        let artworkURL = info?.stillURL ?? episode.gridArtworkURL
        // 观看状态压在画面里，卡片下面不再重复一行「集号 + 未看」。
        let statusText: String = {
            if watchState == .finished { return "已看完" }
            if let progress, progress.fraction > 0.01 { return "上次看到 \(Int(progress.fraction * 100))%" }
            return isCurrent ? "当前集" : "未看"
        }()
        return Button {
            // 悬停即出现播放按钮，单击直接开播。
            onPlay(episode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            Group {
                                if let artworkURL {
                                    CinemaArtwork(urlString: artworkURL, contentMode: .fill)
                                } else {
                                    PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(300))
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(watchState == .finished ? 0.70 : 1)

                    Text(episodeShortLabel(episode))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                }
                .overlay(alignment: .topLeading) {
                    // 状态标记从卡片下方挪进画面：未看 / 上次看到 N% / 已看完 / 当前集。
                    Text(statusText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(watchState == .finished ? LumaBrand.mint
                                         : (isCurrent || (progress?.fraction ?? 0) > 0.01
                                            ? LumaBrand.amber : Color.white.opacity(0.88)))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            if let progress, progress.fraction > 0.01 {
                                Rectangle()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(2.0, geo.size.width * progress.fraction))
                            }
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                }
                .overlay(alignment: .center) {
                    if hovered {
                        episodePlayBadge()
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            hovered ? LumaBrand.amber.opacity(0.7)
                                : (isCurrent ? LumaBrand.amber.opacity(0.85)
                                             : Color.primary.opacity(0.08)),
                            lineWidth: hovered ? 1.2 : (isCurrent ? 1.6 : 0.6))
                }
                .shadow(color: hovered ? LumaBrand.amber.opacity(0.25) : .clear,
                        radius: 10, y: 2)

                Text(episodeTitleText(episode, info: info))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovering in
            if hovering {
                holdHoverPanel(episode.id)
            } else if hoveredEpisode == episode.id {
                scheduleHoverDismiss()
            }
        }
        .help("播放 \(episodeLabel(episode))")
        .modifier(CinemaFocusRing(active: keyboardEpisodeID == episode.id))
        .contextMenu {
            Button("播放") { onPlay(episode) }
            Button(store.cinemaProgress[episode.id]?.isFinished == true ? "标记为未看" : "标记为已看") {
                let watched = store.cinemaProgress[episode.id]?.isFinished != true
                store.setCinemaWatched(episode, watched: watched)
            }
            Button("忽略（以后不刮削）") { store.ignoreCinemaEntry(episode) }
            Divider()
            Button("删除视频文件…", role: .destructive) {
                store.confirmDeleteCinemaEntries([episode], title: episodeLabel(episode))
            }
        }
    }

    /// 集卡中央的播放按钮：悬停时出现，单击直接开播。
    func episodePlayBadge() -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.44))
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: 1)
        }
        .frame(width: 42, height: 42)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    func episodeTitleText(_ episode: CinemaEntry, info: CinemaEpisodeInfo?) -> String {
        if let title = info?.title, !title.isEmpty { return title }
        if let number = episode.episode { return "第 \(number) 集" }
        return "未命名单集"
    }

    func episodeLabel(_ episode: CinemaEntry) -> String {
        if let season = episode.season, let number = episode.episode {
            if let end = episode.episodeEnd, end > number {
                return String(format: "S%02dE%02d-E%02d", season, number, end)
            }
            return String(format: "S%02dE%02d", season, number)
        }
        if let number = episode.episode { return String(format: "EP%02d", number) }
        return "EP"
    }

    /// 集卡角标：季已经由标签栏标明，卡片上只写「第 N 集」。
    func episodeShortLabel(_ episode: CinemaEntry) -> String {
        guard let number = episode.episode else { return "EP" }
        if let end = episode.episodeEnd, end > number {
            return "第 \(number)–\(end) 集"
        }
        return "第 \(number) 集"
    }

    // MARK: 悬停档案

    /// 悬停集卡时弹出的完整档案：剧照、完整简介、进度、规格与文件名一次看全。
    /// 宽度固定、浮在卡片侧边，鼠标本身仍在集卡上，所以不做交互（避免遮挡点击）。
    func episodeHoverCard(_ episode: CinemaEntry) -> some View {
        let info = episodeInfo(episode)
        let progress = store.cinemaProgress[episode.id]
        let artworkURL = info?.stillURL ?? episode.gridArtworkURL
        let tags = cinemaBadgeTags(episode.file, limit: 4)
        let overview = info?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            // 剧照上只留标签，不再压标题：标题挪到正文区，靠深底提升可读性。
            Group {
                if let artworkURL {
                    CinemaArtwork(urlString: artworkURL, contentMode: .fill)
                } else {
                    PhotoThumbnailView(photo: episode.file.photoItem, purpose: .cover(480))
                }
            }
            .frame(height: 158)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 62)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(episodeShortLabel(episode))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(LumaBrand.amber, in: Capsule())
                    if let progress, progress.isFinished {
                        hoverChip("已看完", tint: LumaBrand.mint, darkText: true)
                    } else if let progress, progress.fraction > 0.01 {
                        hoverChip("上次看到 \(Int(progress.fraction * 100))%")
                    } else {
                        hoverChip("未看")
                    }
                }
                .padding(11)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(episodeTitleText(episode, info: info))
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress, progress.fraction > 0.01 {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(CinemaDetailTone.ink.opacity(0.14))
                                Capsule()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(3, geo.size.width * progress.fraction))
                            }
                        }
                        .frame(height: 3)
                        HStack(spacing: 6) {
                            Text(progress.isFinished ? "已看完整集" : "已看 \(Int(progress.fraction * 100))%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LumaBrand.amber)
                            Spacer(minLength: 0)
                            if !progress.isFinished,
                               let remaining = minutesText(progress.remainingSeconds) {
                                Text("剩余 \(remaining)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
                            }
                        }
                    }
                }

                if overview.isEmpty {
                    Text("暂无单集简介")
                        .font(.system(size: 12.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                } else {
                    // 正文按阅读习惯排版：字号 12.5、行距 6.5、颜色更亮，长段落更好读。
                    Text(overview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                        .lineSpacing(6.5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tags.isEmpty {
                    CinemaSpecBadges(tags: tags, fontSize: 9, tint: CinemaDetailTone.ink,
                                     background: CinemaDetailTone.ink.opacity(0.10))
                }

                HStack(spacing: 12) {
                    if let minutes = minutesText(episode.file.duration) {
                        hoverFact("clock", minutes)
                    }
                    if episode.file.fileSize > 0 {
                        hoverFact("internaldrive",
                                  ByteCountFormatter.string(fromByteCount: episode.file.fileSize,
                                                            countStyle: .file))
                    }
                    hoverFact(episode.file.isCloud ? "cloud" : "folder",
                              episode.file.isCloud ? "网盘" : "本地")
                    Spacer(minLength: 0)
                }

                let techFacts = hoverTechFacts(episode.file)
                if !techFacts.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(techFacts, id: \.text) { fact in
                            hoverFact(fact.icon, fact.text)
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 路径用「来源胶囊 + 目录链」展示：中间省略，可选中复制。
                if let location = hoverFileLocation(episode) {
                    HStack(spacing: 6) {
                        Image(systemName: location.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber.opacity(0.82))
                        Text(location.source)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(CinemaDetailTone.ink.opacity(0.10), in: Capsule())
                        Text(location.path)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.58))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(CinemaDetailTone.ink.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.6)
                    .padding(.top, 1)

                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 9, weight: .semibold))
                    Text("点一下选中 · 再点一下播放")
                        .font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))

                Text(episode.file.filename)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.28))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 14)
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(CinemaDetailTone.plate)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.06),
                                                      CinemaDetailTone.ink.opacity(0.015)],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: CinemaDetailTone.shadow(0.58), radius: 26, y: 13)
    }

    func hoverChip(_ text: String, tint: Color = .white, darkText: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(darkText ? Color.black : tint.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(darkText ? 1 : 0.18), in: Capsule())
    }

    func hoverFact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(LumaBrand.amber.opacity(0.75))
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
        }
    }

    /// 悬停档案的技术信息：分辨率 / 编码 / 码率（按文件大小与时长估算）。
    func hoverTechFacts(_ file: CinemaFile) -> [(icon: String, text: String)] {
        var facts: [(icon: String, text: String)] = []
        if file.pixelWidth > 0, file.pixelHeight > 0 {
            facts.append(("rectangle.inset.filled", "\(file.pixelWidth)×\(file.pixelHeight)"))
        }
        if let codec = file.videoCodec, !codec.isEmpty {
            facts.append(("film", codec.uppercased()))
        }
        if let duration = file.duration, duration > 1, file.fileSize > 0 {
            let mbps = Double(file.fileSize) * 8 / duration / 1_000_000
            facts.append(("speedometer", String(format: "≈ %.0f Mbps", mbps)))
        }
        return facts
    }

    /// 悬停档案的存放位置：网盘名 + 目录链；本地用刮削时的目录提示。
    func hoverFileLocation(_ episode: CinemaEntry) -> (icon: String, source: String, path: String)? {
        let file = episode.file
        if let mountID = file.cloudMountID {
            let name = store.cloudMounts.first(where: { $0.id == mountID })?.name ?? "网盘"
            let raw = file.cloudPath ?? ""
            let folder = (raw as NSString).deletingLastPathComponent
            let path = folder.isEmpty ? (episode.folderHint ?? raw) : folder
            return ("cloud", name, path.isEmpty ? "/" : path)
        }
        if let hint = episode.folderHint, !hint.isEmpty {
            return ("folder", "本地", hint)
        }
        return ("folder", "本地", "图库")
    }
}
