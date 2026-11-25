import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影片详情页。

// MARK: - 影片详情

enum CinemaDetailSheet: String, Identifiable {
    case match
    case newList

    var id: String { rawValue }
}

struct CinemaDetailView: View {
    let entry: CinemaEntry
    var onOpenEntry: (CinemaEntry) -> Void = { _ in }
    /// 顶栏「返回」：没有二级页时关闭整个详情。
    var onClose: () -> Void = {}

    @EnvironmentObject private var store: LibraryStore
    @State private var activeSheet: CinemaDetailSheet?
    /// TMDB 详情补全后的条目（合集 / 演职员 / 预告 / 分级）。
    @State private var enriched: CinemaEntry?
    /// 推荐分组：猜你喜欢 / 豆瓣 / 同系列 / 同导演 / 同演员。
    @State private var recommendationGroups: [CinemaRecommendationGroup] = []
    /// 演职员 → 人物页；合集 → 独立合集页。
    @State private var personTarget: CinemaCastMember?
    @State private var showCollection = false
    /// 预告片：页面内播放层，不打开浏览器。
    @State private var showTrailer = false
    /// 档案卡里的长简介：默认收 5 行。
    @State private var dossierExpanded = false
    /// 手动换封面：海报 / 背景候选面板。
    @State private var artworkRequest: CinemaArtworkPickerRequest?
    /// 滚动偏移：滚过档案卡后浮出紧凑标题条。
    @State private var scrollOffset: CGFloat = 0

    var current: CinemaEntry {
        enriched ?? store.cinemaEntry(for: entry.id) ?? entry
    }

    var progress: CinemaProgressRecord? {
        store.cinemaProgress[entry.id]
    }

    var userState: CinemaUserState {
        store.cinemaUserState(for: entry.id)
    }

    var versions: [CinemaEntry] {
        store.cinemaVersions(for: entry)
    }

    /// 已识别的影片 / 剧集才去豆瓣找预告片。
    var trailerRequest: CinemaTrailerRequest? {
        guard current.matched else { return nil }
        return CinemaTrailerRequest(title: current.title,
                                    originalTitle: current.originalTitle,
                                    year: current.year,
                                    isTV: current.kind == .tv)
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
                    onOpenEntry: { other in
                        personTarget = nil
                        onOpenEntry(other)
                    },
                    onPlay: { other in store.openCinema(other) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CinemaDetailTone.page)
        .task {
            if let updated = await store.enrichCinemaEntry(entry) {
                enriched = updated
            }
            recommendationGroups = await store.cinemaRecommendationGroups(for: enriched ?? entry)
            await store.hydrateCinemaDoubanRating(for: enriched ?? entry)
        }
        // 顶栏返回：先关预告片，再退演职员页，最后退影片详情。
        .onChange(of: store.cinemaDetailCloseTick) { _, _ in
            if showTrailer {
                showTrailer = false
            } else if personTarget != nil {
                personTarget = nil
            } else {
                onClose()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .match:
                CinemaMatchSheet(entry: entry) {
                    activeSheet = nil
                }
                .environmentObject(store)
                // 面板本身仍是影院暗色底，单独锁深色，避免浅色外观下白字压在深底上。
                .environment(\.colorScheme, .dark)
            case .newList:
                CinemaNewListSheet { name in
                    let list = store.createCinemaList(named: name)
                    store.addToCinemaList(list.id, entryID: entry.id)
                    activeSheet = nil
                } onCancel: {
                    activeSheet = nil
                }
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showCollection) {
            CinemaCollectionSheet(collectionID: current.collectionID ?? 0,
                                  name: current.collectionName ?? "合集") { other in
                showCollection = false
                onOpenEntry(other)
            }
            .environmentObject(store)
            .environment(\.colorScheme, .dark)
        }
    }

    var pageTopAnchor: String { "cinema-movie-detail-top" }

    /// 详情页默认从顶部开始：不沿用上一部片 / 上次浏览留下的滚动位置。
    func scrollToPageTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(pageTopAnchor, anchor: .top)
        }
    }

    var pageContent: some View {
        // 底图只能挂 background：aspect-fill 的远程剧照只锁了高度，
        // 图片加载完会带出自然宽度，作为 ZStack 兄弟节点会把整页撑得比窗口更宽。
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // 顶部锚点：进入详情 / 切换到另一部片时回到这里。
                        Color.clear
                            .frame(height: 0)
                            .id(pageTopAnchor)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(key: CinemaScrollOffsetKey.self,
                                                           value: geo.frame(in: .named("cinemaMovieScroll")).minY)
                                }
                            }
                        dossierSection(width: width)
                        if !collectionEntries.isEmpty {
                            collectionSection
                        }
                        if versions.count > 1 {
                            versionsSection
                        }
                        technicalSection
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
                    // 只填满可视宽度：固定 width 会变成窗口最小宽度，缩下去就回不来。
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .coordinateSpace(name: "cinemaMovieScroll")
                .onPreferenceChange(CinemaScrollOffsetKey.self) { scrollOffset = $0 }
                .onAppear { scrollToPageTop(scrollProxy) }
                .onChange(of: entry.id) { _, _ in scrollToPageTop(scrollProxy) }
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
            }
        }
    }

    /// 滚过档案卡后浮出的紧凑标题条。
    @ViewBuilder
    var compactHeader: some View {
        if scrollOffset < -140 {
            HStack(spacing: 8) {
                Text(current.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineLimit(1)
                if let year = current.year {
                    Text(String(year))
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                Spacer(minLength: 0)
                if let rating = current.rating, rating > 0 {
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

    /// 换封面：候选由面板自己拉，这里只负责把请求递过去。
    func loadArtwork(_ kind: CinemaArtworkKind) {
        guard current.matched, current.tmdbID != nil else {
            store.showToast("先匹配这部片，才能更换封面")
            return
        }
        artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: current)
    }

    /// 推荐条目本库没有时：网络影院还没上线，先给占位提示。
    func searchOnlineCinema(_ recom: CinemaRecommendation) {
        store.searchOnlineCinema(recom.title)
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
    var ambientBackground: some View {
        ZStack(alignment: .top) {
            CinemaDetailTone.page
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL,
                          contentMode: .fill,
                          maxPixelSize: 1100)
                .frame(height: 720)
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

    // MARK: 影片档案

    /// 与剧集详情同一套版式：海报作视觉锚点，右侧按「抬头 / 片名 / 简介 / 资料网格」排，
    /// 底部接演职员，整块收进一张深色玻璃卡，不再拆成几张独立小卡。
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

            if let cast = current.cast, !cast.isEmpty {
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

    /// 海报 + 评分牌 + 个人评分 + 观看进度：共用一列，宽度和海报对齐。
    func dossierPosterColumn(posterWidth: CGFloat) -> some View {
        VStack(spacing: 9) {
            CinemaPosterDeck(
                width: posterWidth,
                posterURL: current.posterURL ?? entry.posterURL,
                fallbackPhoto: entry.file.photoItem,
                canLoadMore: current.matched && current.provider == .tmdb && current.tmdbID != nil,
                loadCandidates: {
                    let result = await store.cinemaArtworkCandidates(for: current)
                    return result.posters
                        .sorted { ($0.languageRank, -($0.rating ?? 0))
                            < ($1.languageRank, -($1.rating ?? 0)) }
                        .map(\.url)
                },
                onApply: { url in
                    store.applyCinemaArtwork(current, posterURL: url, backdropURL: nil)
                }
            )
            .contextMenu {
                Button("选择海报…") { loadArtwork(.poster) }
                Button("选择背景…") { loadArtwork(.backdrop) }
            }

            // 三源评分已经移到档案抬头右侧（与剧集详情同一处），这里只保留观看进度。
            if let progress, progress.fraction > 0.01 {
                VStack(spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text(progress.isFinished ? "已看完" : "已看 \(Int(progress.fraction * 100))%")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                .frame(width: posterWidth)
            }
        }
        .frame(width: posterWidth, alignment: .top)
    }

    var dossierKicker: some View {
        HStack(spacing: 8) {
            Text("影片档案")
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

    /// 三源评分：与剧集详情同一处、同一套胶囊（TMDB / 豆瓣 / 我的 + 评分人数）。
    @ViewBuilder
    var dossierRatingPill: some View {
        let items = ratingItems()
        let votes = current.voteCount
        if !items.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { pair in
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
        }
    }

    func ratingItems() -> [(id: String, icon: String, label: String, text: String, tint: Color)] {
        let provider = current.provider
        let primary = current.rating
        let tmdb = provider == .douban ? nil : primary
        let douban = current.doubanRating ?? (provider == .douban ? primary : nil)
        var items: [(id: String, icon: String, label: String, text: String, tint: Color)] = []
        if let tmdb {
            items.append(("tmdb", "film.fill", "TMDB", String(format: "%.1f", tmdb), LumaBrand.violet))
        }
        if let douban {
            items.append(("douban", "leaf.fill", "豆瓣", String(format: "%.1f", douban), LumaBrand.mint))
        }
        if let mine = userState.rating {
            items.append(("mine", "star.fill", "我的", "\(mine)", LumaBrand.amber))
        }
        return items
    }

    /// 片名 / 原名 / 宣传语 / 播放动作：整页的标题区。
    var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(CinemaDetailTone.ink)
                .lineLimit(2)
                .textSelection(.enabled)

            if let original = current.originalTitle,
               !original.isEmpty,
               original.caseInsensitiveCompare(displayTitle) != .orderedSame {
                Text(original.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = current.tagline, !tagline.isEmpty {
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

    var displayTitle: String {
        let title = current.title
        return title.isEmpty ? entry.title : title
    }

    @ViewBuilder
    var dossierStatusPill: some View {
        if let status = cinemaStatusText(current.status) {
            let released = current.status == "Released"
            HStack(spacing: 5) {
                Circle()
                    .fill(released ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(released ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.72))
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
        let overview = current.overview ?? ""
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

    /// 资料项列数：按档案卡右列的实际宽度算，宽窗口自动多排一列。
    func factsColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 12
        let width = width > 0 ? width : 620
        let count = max(1, GridLayout.columns(contentWidth: width, targetSize: 210, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 120), spacing: spacing), count: count)
    }

    /// 资料网格：每项一枚琥珀小图标 + 标签 / 值，缺哪项就不占位。
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
        if let value = cinemaDateText(current.releaseDate) ?? current.year.map({ "\($0) 年" }) {
            items.append(DossierFact(icon: "calendar", label: "上映", value: value))
        }
        if let value = cinemaMinutesText(current.runtime) {
            items.append(DossierFact(icon: "clock", label: "片长", value: value))
        }
        if let value = current.file.displayTags.first(where: { $0 == "DV" || $0.hasPrefix("HDR") }) {
            items.append(DossierFact(icon: "sparkles.tv",
                                     label: "HDR",
                                     value: value == "DV" ? "Dolby Vision" : value))
        }
        if current.file.displayTags.contains("Atmos") {
            items.append(DossierFact(icon: "hifispeaker.2", label: "音轨", value: "Dolby Atmos"))
        }
        if let fps = current.file.parsedFrameRate {
            items.append(DossierFact(icon: "speedometer", label: "帧率", value: "\(fps) fps"))
        }
        if let value = current.genres?.prefix(4).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "theatermasks", label: "类型", value: value))
        }
        if let value = current.certification, !value.isEmpty {
            items.append(DossierFact(icon: "shield.lefthalf.filled", label: "分级", value: value))
        }
        if let value = cinemaLanguageName(current.originalLanguage) {
            items.append(DossierFact(icon: "character.bubble", label: "语言", value: value))
        }
        if let countries = current.countries, !countries.isEmpty {
            let value = countries.prefix(2).map(cinemaCountryName).joined(separator: " / ")
            items.append(DossierFact(icon: "globe.asia.australia", label: "国家", value: value))
        }
        if let value = current.companies?.prefix(3).joined(separator: " / "), !value.isEmpty {
            items.append(DossierFact(icon: "building.2", label: "制作", value: value))
        }
        if let value = ratingDetailText {
            items.append(DossierFact(icon: "star", label: "评分", value: value))
        }
        if let value = cinemaMoneyText(current.budget) {
            items.append(DossierFact(icon: "banknote", label: "预算", value: value))
        }
        if let value = cinemaMoneyText(current.revenue) {
            items.append(DossierFact(icon: "chart.line.uptrend.xyaxis", label: "票房", value: value))
        }
        if let value = current.collectionName, !value.isEmpty {
            items.append(DossierFact(icon: "square.stack.3d.up", label: "合集", value: value))
        }
        if let id = current.tmdbID {
            let label = current.provider == .tvdb ? "TVDB" : "TMDB"
            items.append(DossierFact(icon: "number", label: label, value: "\(id)"))
        }
        return items
    }

    var dossierMetaLine: String {
        var parts: [String] = []
        if let year = current.year, year > 0 {
            parts.append("\(year)")
        }
        if let runtime = current.runtime, runtime > 0 {
            parts.append("\(runtime) 分钟")
        }
        parts.append(resolutionText)
        return parts.joined(separator: " · ")
    }

    func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    var actions: some View {
        // 与剧集详情一致的播放起点：有进度先「继续播放」，同时留「从头播放」。
        CinemaBadgeFlow(spacing: 9, lineSpacing: 9) {
            Button(action: play) {
                Label(progress == nil ? "开始观看" : "继续播放", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(LumaBrand.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .fixedSize()

            if progress != nil {
                Button {
                    store.openCinemaFromStart(entry)
                } label: {
                    Label("从头播放", systemImage: "backward.end.fill")
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

            Button {
                activeSheet = .match
            } label: {
                Label(entry.matched ? "重新匹配" : "手动匹配", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(CinemaDetailTone.ink.opacity(0.16), in: Capsule())
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))
            }
            .buttonStyle(.plain)
            .fixedSize()

            circleButton(userState.favorite ? "heart.fill" : "heart",
                         active: userState.favorite,
                         help: userState.favorite ? "取消收藏" : "收藏") {
                store.toggleCinemaFavorite(entry.id)
            }

            circleButton(userState.watchlist ? "bookmark.fill" : "bookmark",
                         active: userState.watchlist,
                         activeColor: LumaBrand.amber,
                         help: userState.watchlist ? "移出想看" : "加入想看") {
                store.toggleCinemaWatchlist(entry.id)
            }

            ratingMenu
            listMenu
            moreMenu
        }
    }

    func circleButton(_ icon: String,
                              active: Bool,
                              activeColor: Color = LumaBrand.coral,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? activeColor : CinemaDetailTone.ink.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(CinemaDetailTone.ink.opacity(0.16), in: Circle())
                // 收藏 / 想看切换时 0.2s 轻微收缩回弹，给一个明确的操作反馈。
                .scaleEffect(active ? 1 : 0.92)
                .animation(.spring(response: 0.2, dampingFraction: 0.65), value: active)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var ratingMenu: some View {
        Menu {
            ForEach(1...5, id: \.self) { star in
                Button(String(repeating: "★", count: star)) {
                    store.setCinemaRating(star, for: entry.id)
                }
            }
            Divider()
            Button("清除评分") {
                store.setCinemaRating(nil, for: entry.id)
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                if let rating = userState.rating {
                    Text("\(rating)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(userState.rating == nil ? CinemaDetailTone.ink.opacity(0.90)
                                                     : LumaBrand.amber)
            .frame(width: 34, height: 34)
            .background(CinemaDetailTone.ink.opacity(0.16), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("个人评分")
    }

    var listMenu: some View {
        Menu {
            if store.cinemaLists.isEmpty {
                Button("新建清单…") { activeSheet = .newList }
            } else {
                ForEach(store.cinemaLists) { list in
                    Button(list.name) {
                        store.addToCinemaList(list.id, entryID: entry.id)
                    }
                }
                Divider()
                Button("新建清单…") { activeSheet = .newList }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(CinemaDetailTone.ink.opacity(0.16), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("加入清单")
    }

    var moreMenu: some View {
        Menu {
            Button("按文件名重新刮削") {
                Task { await store.rescrapeCinema(entry) }
            }
            if let mountID = entry.file.cloudMountID {
                Button("在资料库中显示") {
                    store.cinemaDetailCloseTick += 1
                    store.navigate(to: .cloudMount(mountID))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                .frame(width: 34, height: 34)
                .background(CinemaDetailTone.ink.opacity(0.14), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    func play() {
        play(entry)
    }

    func play(_ version: CinemaEntry) {
        // 详情留在页面下层，播放器关掉后回到原位。
        store.openCinema(version)
    }

    // MARK: 合集 / 演职员

    var collectionEntries: [CinemaEntry] {
        guard let id = current.collectionID else { return [] }
        return store.cinemaCollection(collectionID: id).filter { $0.id != entry.id }
    }

    var collectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle(current.collectionName ?? "同一合集",
                             detail: "\(collectionEntries.count + 1) 部")
                Button("查看合集 ›") {
                    showCollection = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
                .help("打开合集详情：按上映顺序播放与合集统计")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(collectionEntries) { other in
                        Button {
                            onOpenEntry(other)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ZStack {
                                    if let url = other.posterURL {
                                        CinemaArtwork(urlString: url, contentMode: .fill)
                                    } else {
                                        PhotoThumbnailView(photo: other.file.photoItem, purpose: .cover(120))
                                    }
                                }
                                .frame(width: 96, height: 144)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(CinemaDetailTone.ink.opacity(0.12),
                                                      lineWidth: 0.6)
                                }
                                Text(other.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                                    .lineLimit(1)
                                    .frame(width: 96, alignment: .leading)
                                Text(other.year.map(String.init) ?? " ")
                                    .font(.system(size: 10))
                                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                                    .frame(width: 96, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(other.title)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(CinemaDetailTone.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.07), lineWidth: 0.6)
        }
    }

    /// 演职员条：和剧集详情同款，收在档案卡底部。
    func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                if let directors = current.directors, !directors.isEmpty {
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

    // MARK: 版本

    var versionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("版本", detail: "\(versions.count) 个文件")
            ForEach(versions) { version in
                versionRow(version)
            }
        }
        .padding(16)
        .background(CinemaDetailTone.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CinemaDetailTone.ink.opacity(0.07), lineWidth: 0.6)
        }
    }

    func versionRow(_ version: CinemaEntry) -> some View {
        let current = version.id == entry.id
        let isDefault = store.isCinemaDefaultVersion(version)
        return Button {
            play(version)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(current ? LumaBrand.amber
                                             : CinemaDetailTone.ink.opacity(0.40))

                VStack(alignment: .leading, spacing: 2) {
                    Text(version.file.filename)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.90))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(resolutionText(version.file)) · \(byteText(version.file)) · \(durationText(version.file))")
                        .font(.system(size: 10))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.50))
                }

                Spacer(minLength: 0)

                Text(isDefault ? "默认" : (current ? "当前" : "播放"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isDefault || current ? LumaBrand.amber
                                                          : CinemaDetailTone.ink.opacity(0.55))
            }
            .padding(8)
            .background(current ? LumaBrand.amber.opacity(0.10)
                                : CinemaDetailTone.ink.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(current ? LumaBrand.amber.opacity(0.35)
                                          : CinemaDetailTone.ink.opacity(0.08),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("播放这个版本") { play(version) }
            if !isDefault {
                Button("设为默认版本") { store.setCinemaDefaultVersion(version) }
            }
            Button("在访达中显示") { store.revealCinemaEntryInFinder(version) }
        }
    }

    // MARK: 进度 / 技术信息

    /// 技术规格 + 文件信息收进同一张卡：上面是规格 chips，下面是可复制的路径与匹配状态。
    var technicalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("文件与技术信息", detail: entry.file.filename)
            // 规格胶囊按实际宽度流式换行：窄窗口不会把最后几枚挤出可视区。
            CinemaBadgeFlow(spacing: 8, lineSpacing: 8) {
                chip(resolutionText)
                if let codec = entry.file.videoCodec, !codec.isEmpty {
                    chip(codec.uppercased())
                }
                chip(fileExtension)
                chip(byteText)
                chip(durationText)
                ForEach(Array(current.file.displayTags.prefix(3)), id: \.self) { tag in
                    chip(tag)
                }
            }
            VStack(spacing: 0) {
                infoRow("文件名", entry.file.filename)
                Divider().opacity(0.4)
                infoRow("路径", filePathText)
                Divider().opacity(0.4)
                infoRow("大小", byteText)
                Divider().opacity(0.4)
                infoRow("时长", durationText)
                Divider().opacity(0.4)
                infoRow("添加时间", entry.file.capturedAt.formatted(date: .numeric, time: .shortened))
                Divider().opacity(0.4)
                infoRow("匹配", entry.matched
                        ? (entry.tmdbID.map { "已匹配 · \(entry.provider?.title ?? "TMDB") \($0)" } ?? "已匹配")
                        : "未识别")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(CinemaDetailTone.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CinemaDetailTone.ink.opacity(0.07), lineWidth: 0.6)
            }
        }
    }

    func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
            .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
    }

    func sectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LumaBrand.amber)
                .frame(width: 3, height: 13)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    var ratingDetailText: String? {
        guard let rating = current.rating, rating > 0 else { return nil }
        var text = String(format: "%.1f", rating)
        if let votes = current.voteCount, votes > 0 {
            text += " · \(votes) 人评分"
        }
        return text
    }

    /// 网盘（尤其夸克）的 cloudPath 是文件 ID，不是人类可读路径：
    /// 有目录链时优先拼成「目录/文件名」，否则再退回原始路径。
    var filePathText: String {
        let name = entry.file.filename
        if let hint = entry.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint.hasSuffix("/") ? hint + name : hint + "/" + name
        }
        if let raw = entry.file.cloudPath,
           !raw.isEmpty,
           !LibraryStore.cinemaPathLooksLikeID(raw) {
            return raw
        }
        return name
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    // MARK: 格式化

    var resolutionText: String {
        resolutionText(entry.file)
    }

    func resolutionText(_ file: CinemaFile) -> String {
        let width = file.pixelWidth
        let height = file.pixelHeight
        if width >= 3000 { return "4K" }
        if width >= 1800 { return "2K" }
        if width >= 1200 { return "1080P" }
        if width > 0, height > 0 { return "\(width)×\(height)" }
        return "分辨率未知"
    }

    var fileExtension: String {
        let ext = (entry.file.filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : ext
    }

    var byteText: String {
        byteText(entry.file)
    }

    func byteText(_ file: CinemaFile) -> String {
        guard file.fileSize > 0 else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
    }

    var durationText: String {
        durationText(entry.file)
    }

    func durationText(_ file: CinemaFile) -> String {
        guard let duration = file.duration, duration > 0 else { return "时长未知" }
        let minutes = Int(duration / 60)
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(minutes) 分钟"
    }
}

// MARK: - 新建清单

struct CinemaNewListSheet: View {
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建清单")
                .font(.system(size: 16, weight: .bold))
            Text("手动选片，只在本机保存，不写回网盘。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("清单名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}
