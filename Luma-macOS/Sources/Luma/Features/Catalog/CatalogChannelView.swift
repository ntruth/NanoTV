import AppKit
import SwiftUI
import LumaContentCore

/// 列表滚动进度：只上报内容偏移与总高度，用于 60% 提前预取下一页。
struct CatalogScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

struct CatalogScrollMetricsKey: PreferenceKey {
    static var defaultValue = CatalogScrollMetrics()

    static func reduce(value: inout CatalogScrollMetrics,
                       nextValue: () -> CatalogScrollMetrics) {
        let next = nextValue()
        if next.contentHeight > 0 { value = next }
    }
}

enum CatalogScrollSpace {
    static let name = "catalog-channel-scroll"
}

/// 框选用的命名坐标系：网格单元格把自身矩形上报到这里，鼠标位置也按它换算。
enum CatalogMarqueeSpace {
    static let name = "catalog-channel-marquee"
}

struct CatalogCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 网格空白处拖动框选；从卡片内部按下时让位给卡片自己的点击 / 预览。
struct CatalogMarqueeModifier: ViewModifier {
    @Binding var selection: Set<String>

    @State private var frames: [String: CGRect] = [:]
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var base: Set<String> = []
    @State private var blockedStart: CGPoint?

    var marqueeRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x),
                      y: min(start.y, current.y),
                      width: abs(current.x - start.x),
                      height: abs(current.y - start.y))
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .coordinateSpace(name: CatalogMarqueeSpace.name)
            .onPreferenceChange(CatalogCardFrameKey.self) { frames = $0 }
            .overlay(alignment: .topLeading) { marqueeOverlay }
            .simultaneousGesture(blankTapGesture)
            .simultaneousGesture(marqueeGesture)
    }

    /// 点空白处取消选择；点卡片仍走卡片自己的手势。
    var blankTapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(CatalogMarqueeSpace.name))
            .onEnded { value in
                guard !frames.values.contains(where: { $0.contains(value.location) }) else { return }
                selection.removeAll()
            }
    }

    @ViewBuilder
    var marqueeOverlay: some View {
        if let rect = marqueeRect, rect.width > 2, rect.height > 2 {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(CatalogMarqueeSpace.name))
            .onChanged { value in
                if let blocked = blockedStart {
                    if blocked == value.startLocation { return }
                    blockedStart = nil
                }
                if start == nil {
                    if frames.values.contains(where: { $0.contains(value.startLocation) }) {
                        blockedStart = value.startLocation
                        return
                    }
                    start = value.startLocation
                    let flags = NSEvent.modifierFlags
                    let additive = flags.contains(.command) || flags.contains(.shift)
                    base = additive ? selection : []
                    if !additive { selection.removeAll() }
                }
                current = value.location
                guard let rect = marqueeRect else { return }
                let hits = frames.filter { $0.value.intersects(rect) }.map(\.key)
                selection = base.union(hits)
            }
            .onEnded { _ in
                start = nil
                current = nil
                base = []
                blockedStart = nil
            }
    }
}

extension View {
    func catalogMarqueeSelection(_ selection: Binding<Set<String>>) -> some View {
        modifier(CatalogMarqueeModifier(selection: selection))
    }
}

// MARK: - 网络资源频道页

struct CatalogChannelView: View {
    let sourceID: UUID

    @EnvironmentObject private var catalog: CatalogBrowserModel
    /// 顶栏的放大 / 缩小滑杆写的是这个 thumbSize，内容区必须跟着它一起缩放。
    @EnvironmentObject private var store: LibraryStore

    /// 批量操作：⌘ 点选中的条目 id，底部浮出操作条。
    @State private var selectedIDs: Set<String> = []
    /// 键盘导航的光标：鼠标悬停到哪张卡，方向键就从哪张继续走。
    @State private var cursorID: String?
    @FocusState private var listFocused: Bool
    /// 一级范围的高亮胶囊与二级频道的下划线在这两个命名空间里滑动。
    @Namespace private var chipNamespace

    var source: CatalogSource? {
        // 频道页只服务网络资源；影视源由网络影院自己的浏览页承载。
        catalog.resourceSources.first(where: { $0.id == sourceID })
    }

    var body: some View {
        Group {
            if let activeItem = catalog.inlineDetailItem {
                // 详情不再弹窗：直接占据内容区，返回入口融进窗口工具栏。
                CatalogDetailView(item: activeItem) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        catalog.inlineDetailItem = nil
                    }
                }
                .environmentObject(catalog)
                .transition(.opacity)
            } else {
                channelList
            }
        }
        .task(id: sourceID) {
            // 影视源不在这里浏览，直接跳过，不把它的分类装进资源页状态。
            guard source != nil else { return }
            // 关闭播放器后回到详情：有代打开条目就直接铺开；
            // 否则若上次退出时停在详情页，这次进入同一个源也直接还原；都没有才回列表。
            if let pending = catalog.pendingInlineItem {
                catalog.pendingInlineItem = nil
                catalog.inlineDetailItem = pending
            } else if let restored = catalog.consumeLaunchInlineDetail(for: sourceID) {
                catalog.inlineDetailItem = restored
            } else {
                catalog.inlineDetailItem = nil
            }
            catalog.focus(sourceID)
            applyDefaultCardSizeIfNeeded()
            if let source {
                // 侧边栏分类图标用分类首图：先读缓存，缺的再后台补一次。
                catalog.prefetchCategoryThumbs(for: source)
            }
            if (source?.isEnabled ?? false), catalog.items.isEmpty, !catalog.isLoading {
                // 还原到上次的分类时列表也是空的，这里要补一次加载。
                switch catalog.section {
                case .continueWatching, .favorites:
                    break
                default:
                    catalog.reload()
                }
            }
        }
        // 工具栏的分类菜单 / 侧边栏切分类时，详情页跟着退出，避免停在上一页内容上。
        .onChange(of: catalog.section) { _, _ in
            catalog.inlineDetailItem = nil
            selectedIDs.removeAll()
        }
    }

    var channelList: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let source {
                        if source.isEnabled {
                            body(source)
                        } else {
                            gate(source)
                        }
                    } else {
                        missing
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, selectedIDs.isEmpty ? 60 : 96)
                .background {
                    // 只看滚动量：滚到当前内容 60% 时提前取下一页，不等最后几张卡出现。
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CatalogScrollMetricsKey.self,
                            value: CatalogScrollMetrics(
                                offset: proxy.frame(in: .named(CatalogScrollSpace.name)).minY,
                                contentHeight: proxy.size.height))
                    }
                }
            }
            .coordinateSpace(name: CatalogScrollSpace.name)
            .onPreferenceChange(CatalogScrollMetricsKey.self) { metrics in
                prefetchNextPageIfNeeded(metrics, viewportHeight: viewport.size.height)
            }
            .scrollIndicators(.automatic)
            .background(LumaAmbientBackground(intensity: 0.55))
            .overlay(alignment: .bottom) { selectionBar }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.leftArrow) { moveCursor(by: -1); return .handled }
            .onKeyPress(.rightArrow) { moveCursor(by: 1); return .handled }
            .onKeyPress(.upArrow) { moveCursor(by: -currentColumns); return .handled }
            .onKeyPress(.downArrow) { moveCursor(by: currentColumns); return .handled }
            .onKeyPress(.return) { openCursorItem(); return .handled }
            .onKeyPress(.space) { openCursorItem(); return .handled }
            .onKeyPress(keys: ["a"], phases: .down) { press in
                // ⌘A 全选当前已加载的条目；框选则由网格空白处拖动完成。
                guard press.modifiers.contains(.command), !catalog.items.isEmpty else {
                    return .ignored
                }
                selectedIDs = Set(catalog.items.map(\.id))
                return .handled
            }
            .onKeyPress(.escape) {
                if !selectedIDs.isEmpty {
                    selectedIDs.removeAll()
                    return .handled
                }
                cursorID = nil
                return .ignored
            }
            .onDisappear {
                selectedIDs.removeAll()
                cursorID = nil
            }
        }
    }

    /// 滚动到当前内容 60% 时预取下一页；取完新页后内容变长，阈值自然后移，不会连环拉取。
    func prefetchNextPageIfNeeded(_ metrics: CatalogScrollMetrics,
                                          viewportHeight: CGFloat) {
        guard catalog.hasMore, !catalog.isLoadingMore,
              metrics.contentHeight > viewportHeight else { return }
        let maxOffset = max(1, metrics.contentHeight - viewportHeight)
        let scrolled = max(0, -metrics.offset)
        guard scrolled >= maxOffset * 0.6 else { return }
        catalog.loadMore()
    }

    // MARK: - 键盘导航 / 批量操作

    var currentColumns: Int {
        guard let source else { return 4 }
        return source.kind.isWebSite ? webColumnCount : posterColumnCount
    }

    /// 悬停时接管键盘焦点，让方向键能继续导航；
    /// 但如果用户正在输入（源内搜索 / 顶栏搜索），不要抢走焦点。
    func adoptListFocus() {
        if NSApp.keyWindow?.firstResponder is NSTextView { return }
        listFocused = true
    }

    func moveCursor(by delta: Int) {
        let items = catalog.items
        guard !items.isEmpty else { return }
        adoptListFocus()
        guard let cursorID, let index = items.firstIndex(where: { $0.id == cursorID }) else {
            self.cursorID = items.first?.id
            return
        }
        let next = min(max(index + delta, 0), items.count - 1)
        self.cursorID = items[next].id
    }

    func openCursorItem() {
        guard let cursorID,
              let item = catalog.items.first(where: { $0.id == cursorID }) else { return }
        openInline(item)
    }

    /// 打开条目详情：状态提到模型里，工具栏才能同步显示返回入口与标题。
    func openInline(_ item: CatalogItem) {
        withAnimation(.easeOut(duration: 0.16)) {
            catalog.inlineDetailItem = item
        }
    }

    /// 批量操作条：只在有选中项时浮出，不占列表高度。
    @ViewBuilder
    var selectionBar: some View {
        if !selectedIDs.isEmpty, let source {
            let selected = catalog.items.filter { selectedIDs.contains($0.id) }
            HStack(spacing: 10) {
                Text("已选 \(selectedIDs.count) 条")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("⌘ 点击加选 · 空白处拖动框选 · ⌘A 全选")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                // 全都已在稍后看里时按钮变成「移出」，否则只补加还没加入的条目。
                let allFavorites = !selected.isEmpty && selected.allSatisfy {
                    catalog.isFavorite(sourceID: source.id, itemID: $0.id)
                }
                Button {
                    catalog.setFavorite(!allFavorites, source: source, items: selected)
                    selectedIDs.removeAll()
                } label: {
                    barButton(allFavorites ? "移出稍后看" : "稍后看",
                              symbol: allFavorites ? "bookmark.slash" : "bookmark.fill")
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(catalog.playlists) { playlist in
                        Button(playlist.name) {
                            catalog.addToPlaylist(playlist.id, source: source, items: selected)
                            selectedIDs.removeAll()
                        }
                    }
                    if !catalog.playlists.isEmpty { Divider() }
                    Button("新建片单并加入") {
                        let id = catalog.createPlaylist(name: "片单 \(catalog.playlists.count + 1)")
                        catalog.addToPlaylist(id, source: source, items: selected)
                        selectedIDs.removeAll()
                    }
                } label: {
                    barButton("加入片单", symbol: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    catalog.markWatched(source: source, items: selected)
                    selectedIDs.removeAll()
                } label: {
                    barButton("标记已看", symbol: "checkmark.circle")
                }
                .buttonStyle(.plain)

                if let first = selected.first {
                    Button {
                        store.openCatalogItemInBrowser(source: source, item: first)
                    } label: {
                        barButton("打开原始页", symbol: "safari")
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    selectedIDs.removeAll()
                } label: {
                    barButton("清空", symbol: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    func barButton(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.accentColor.opacity(0.13), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.7)
        }
    }

    /// 网络资源第一次打开时给一次更大的默认卡片：竖版海报 5 列、横版网页源 4 列。
    /// 之后拖动顶栏滑杆的位置会按源记住，不再重置。
    func applyDefaultCardSizeIfNeeded() {
        guard let source else { return }
        let key = "catalog.defaultCardSize.v2.\(source.id.uuidString)"
        // 旧版写在 UserDefaults：迁到图库级存储，避免换库后又重置一次。
        if UserDefaults.standard.bool(forKey: key) {
            CatalogStore.string(forKey: key, value: "1")
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard CatalogStore.string(forKey: key) == nil else { return }
        CatalogStore.string(forKey: key, value: "1")
        store.thumbSize = store.defaultGridThumbSize
    }

    // MARK: - 正文

    @ViewBuilder
    func body(_ source: CatalogSource) -> some View {
        // 外部源不再单独铺「继续观看」：续看统一收进网络资源总览的「足迹」页。
        chips
        // 断网降级：有本地快照就继续看，只在上方提示「这是什么时候的内容」。
        if let snapshot = catalog.listSnapshotAt, !catalog.items.isEmpty, catalog.error != nil {
            snapshotBanner(snapshot)
            if catalog.errorNeedsVerification {
                verificationBanner(source: source)
            }
        } else if let error = catalog.error {
            // 403 / WAF / PoW：把「在浏览器打开」直接放到页面里，不用先去健康面板。
            if catalog.errorNeedsVerification {
                verificationBanner(source: source)
            } else {
                SourceErrorView(error: catalog.sourceError
                                    ?? SourceError(kind: .unavailable,
                                                   message: error,
                                                   recovery: [.retry])) { action in
                    handleSourceRecovery(action, source: source)
                }
            }
        }
        if let notice = catalog.notice {
            banner(text: notice, isError: false)
        }
        if case .favorites = catalog.section {
            if catalog.currentFavorites.isEmpty {
                emptyState
            } else {
                favoritesList(source)
            }
        } else {
            content(source)
        }
    }

    var chips: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                categoryTray
                // 随便挑一部：从当前列表里随机打开详情，给浏览加一点意外性。
                if catalog.items.count > 3 {
                    surpriseButton.fixedSize()
                }
            }
            // 二级目录与网络影院站点页同一套：点开一级后，把站点挂在它下面的地区 / 题材铺开。
            if catalog.activeTopCategory != nil, !secondLevelCategories.isEmpty {
                subCategoryPanel
            }
        }
    }

    /// 二级目录：优先站点给当前一级挂的子分类；没有子分类的站点退回它的二级标签。
    var secondLevelCategories: [CatalogCategory] {
        if !catalog.subCategories.isEmpty { return catalog.subCategories }
        return catalog.tags.flatMap { tag in
            if let children = tag.children, !children.isEmpty { return children }
            return [tag]
        }
    }

    /// 二级目录面板：换行胶囊 + 「全部」，一级胶囊已经表明当前分类，不再重复标题。
    var subCategoryPanel: some View {
        CatalogFlowLayout(spacing: 6, lineSpacing: 7) {
            if let parent = catalog.activeTopCategory {
                CatalogDirectoryChip(title: "全部",
                                     active: currentCategoryID == parent.id) {
                    catalog.openCategory(parent)
                }
            }
            ForEach(secondLevelCategories) { sub in
                CatalogDirectoryChip(title: sub.title,
                                     active: currentCategoryID == sub.id) {
                    catalog.openCategory(sub)
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

    /// 一级范围做成一条连体舱体：选中块在舱内滑动，比一排独立灰胶囊更像导航。
    var categoryTray: some View {
        CatalogFlowLayout(spacing: 3, lineSpacing: 3) {
            CatalogChip(title: "首页",
                        active: catalog.section == .home,
                        namespace: chipNamespace) {
                catalog.openHome()
            }
            ForEach(catalog.categories) { category in
                CatalogChip(title: category.title,
                            active: catalog.activeTopCategory?.id == category.id,
                            namespace: chipNamespace) {
                    if category.isRank {
                        catalog.openRank()
                    } else {
                        catalog.openCategory(category)
                    }
                }
                .contextMenu {
                    Button(catalog.isFollowed(category) ? "取消关注" : "关注此分类") {
                        catalog.toggleFollow(category)
                    }
                }
            }
            // 与左侧菜单的「稍后看」一一对应，出现条件也一致。
            if !catalog.currentFavorites.isEmpty {
                CatalogChip(title: "稍后看",
                            active: catalog.section == .favorites,
                            namespace: chipNamespace) {
                    catalog.openFavorites()
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

    /// 随便挑一部：当前列表随机打开详情。
    var surpriseButton: some View {
        Button {
            guard let pick = catalog.items.randomElement() else { return }
            openInline(pick)
        } label: {
            Image(systemName: "dice.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.13), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
        .help("从当前列表随便挑一部")
    }

    var currentCategoryID: String? {
        switch catalog.section {
        case .category(let id): return id
        case .rank: return catalog.categories.first(where: { $0.isRank })?.id
        default: return nil
        }
    }

    /// 网页源默认列数：4。顶栏滑杆以 4 列为基准做缩放（3…6 列）。
    var webColumnCount: Int {
        let side = max(56, CGFloat(store.thumbSize))
        let base = max(56, store.defaultGridThumbSize)
        let ratio = Double(base) / Double(side)
        return min(6, max(3, Int((4 * ratio).rounded())))
    }

    /// 卡片间距：列与列之间始终留出明显空隙，不随卡片变大被吃掉。
    var webGap: CGFloat {
        let side = CGFloat(store.thumbSize)
        return min(36, max(26, side * 0.12))
    }

    /// 非网页源（竖版海报）每行张数：以 5 列为基准，顶栏滑杆在此基础上缩放。
    var posterColumnCount: Int {
        let side = max(56, CGFloat(store.thumbSize))
        let base = max(56, store.defaultGridThumbSize)
        let ratio = Double(base) / Double(side)
        return min(8, max(3, Int((5 * ratio).rounded())))
    }

    @ViewBuilder
    func content(_ source: CatalogSource) -> some View {
        if catalog.isLoading, catalog.items.isEmpty {
            skeleton(source)
        } else if catalog.items.isEmpty {
            emptyState
        } else {
            if isCollectionIndexSection {
                collectionIndexBanner
            }
            if isRankSection, catalog.items.count >= 3 {
                rankPodium(source, items: Array(catalog.items.prefix(3)))
            }
            let rest = isRankSection ? Array(catalog.items.dropFirst(3)) : catalog.items
            if !rest.isEmpty {
                if !catalog.freshItemKeys.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(LumaBrand.amber)
                        Text("本次刷新新增 \(catalog.freshItemKeys.count) 条")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("完结剧标「已完结」、连载剧标「更新中」、单片标「刚上架」")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 2)
                }
                cardGrid(source, items: rest,
                         columns: source.kind.isWebSite ? webColumnCount : posterColumnCount)
            }
            // 本页排序只在已加载的条目里生效，明确标出来，避免误以为是全站排序。
            if let localSort = catalog.localSort, !catalog.items.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 8.5))
                    Text("按\(localSort.title)排序 · 仅当前已加载 \(catalog.items.count) 条")
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.tertiary)
            }
            if catalog.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                        .opacity(catalog.isLoadingMore ? 1 : 0)
                    Spacer()
                }
                .frame(height: 24)
                .padding(.top, 2)
            }
        }
    }

    /// 排行榜前三名单独做成大卡：名次是最重要的信息，不该埋在网格里。
    var isRankSection: Bool {
        if case .rank = catalog.section { return true }
        guard let id = currentCategoryID else { return false }
        return catalog.category(withID: id)?.isRank == true
    }

    /// 精选合集索引页（`set|…`）：列表里每一项是一个合集，而不是单个视频。
    var isCollectionIndexSection: Bool {
        currentCategoryID?.hasPrefix("set|") == true
    }

    var collectionIndexBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("精选合集")
                        .font(.system(size: 14, weight: .semibold))
                    Text(catalog.sectionTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Text("\(catalog.items.count) 个合集 · 点开后是该合集的全部视频")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.28))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 0.7)
        }
    }

    func rankPodium(_ source: CatalogSource, items: [CatalogItem]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                RankPodiumCard(source: source,
                               item: item,
                               rank: index + 1,
                               progress: catalog.progress(sourceID: source.id, itemID: item.id),
                               durationText: durationLabel(source: source, item: item),
                               isMarkedWatched: catalog.isMarkedWatched(sourceID: source.id,
                                                                        itemID: item.id)) {
                    openInline(item)
                }
            }
        }
    }

    /// 等宽列 + 独立列间距：网格列宽由列数统一决定，
    /// 卡片内容（长标题、不同比例的封面）不会再影响列宽，间距也就不会忽大忽小。
    func cardGrid(_ source: CatalogSource, items: [CatalogItem], columns: Int) -> some View {
        let gap = webGap
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                        count: max(1, columns)),
                         alignment: .leading,
                         spacing: 30) {
            ForEach(items) { item in
                posterCell(source, item: item)
            }
        }
        .catalogMarqueeSelection($selectedIDs)
    }

    func posterCell(_ source: CatalogSource, item: CatalogItem) -> some View {
        CatalogPosterCell(
            source: source,
            item: item,
            progress: catalog.progress(sourceID: source.id, itemID: item.id),
            isSaving: catalog.savingItemID == item.id,
            isFresh: catalog.isFresh(sourceID: source.id, itemID: item.id),
            isFavorite: catalog.isFavorite(sourceID: source.id, itemID: item.id),
            isMarkedWatched: catalog.isMarkedWatched(sourceID: source.id, itemID: item.id),
            isSelected: selectedIDs.contains(item.id),
            onOpen: { openInline(item) },
            onOpenInBrowser: { store.openCatalogItemInBrowser(source: source, item: item) },
            onSaveVideo: { store.saveCatalogVideoToLibrary(source: source, item: item) },
            onToggleSelect: {
                if selectedIDs.contains(item.id) {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            },
            onHoverChange: { inside in
                guard inside else { return }
                cursorID = item.id
                adoptListFocus()
            },
            durationText: durationLabel(source: source, item: item),
            previewTarget: { await catalog.previewTarget(for: item) }
        )
        .background {
            // 把卡片矩形上报给框选：滚出屏幕的卡片会重新上报，框选始终按当前布局算。
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CatalogCardFrameKey.self,
                    value: [item.id: proxy.frame(in: .named(CatalogMarqueeSpace.name))])
            }
        }
        .onAppear {
            // 滚动到接近末尾时自动续页，不再需要「加载更多」按钮。
            guard catalog.hasMore, !catalog.isLoadingMore,
                  catalog.items.suffix(6).contains(where: { $0.id == item.id })
            else { return }
            catalog.loadMore()
        }
    }

    /// 已经播放过的条目：用进度里的时长回填卡片，站点没给时长的源也能看到片长。
    func durationLabel(source: CatalogSource, item: CatalogItem) -> String? {
        guard let progress = catalog.progress(sourceID: source.id, itemID: item.id),
              progress.duration.isFinite, progress.duration > 20 else { return nil }
        return Self.formattedDuration(progress.duration)
    }

    static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, total % 60)
        }
        return "\(minutes):" + String(format: "%02d", total % 60)
    }

    // MARK: - 稍后看

    func favoritesList(_ source: CatalogSource) -> some View {
        LazyVStack(spacing: 9) {
            ForEach(catalog.currentFavorites) { favorite in
                CatalogFavoriteRow(
                    source: source,
                    favorite: favorite,
                    onOpen: {
                        openInline(CatalogItem(id: favorite.itemID, title: favorite.title,
                                               coverURL: favorite.coverURL,
                                               remark: favorite.remark, categoryID: nil))
                    },
                    onRemove: {
                        catalog.toggleFavorite(
                            source: source,
                            item: CatalogItem(id: favorite.itemID, title: favorite.title,
                                              coverURL: favorite.coverURL,
                                              remark: favorite.remark, categoryID: nil))
                    }
                )
            }
        }
    }

    // MARK: - 状态

    func skeleton(_ source: CatalogSource) -> some View {
        let columns = source.kind.isWebSite ? webColumnCount : posterColumnCount
        let gap = webGap
        return LumaSkeletonGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap),
                                               count: max(1, columns)),
                                count: 12,
                                aspectRatio: CGFloat(source.posterRatio),
                                footerLines: 1,
                                spacing: 30)
    }

    var emptyState: some View {
        LumaEmptyState(symbol: catalog.error == nil
                       ? "rectangle.on.rectangle.slash"
                       : (catalog.errorNeedsVerification ? "lock.shield" : "wifi.exclamationmark"),
                       title: emptyTitle,
                       message: emptyHint,
                       actions: emptyActions)
    }

    /// 失败态也复用同一套按钮：能在浏览器完成验证的给浏览器入口，其余给重试。
    var emptyActions: [LumaEmptyAction] {
        var actions: [LumaEmptyAction] = []
        if catalog.errorNeedsVerification, let source {
            actions.append(LumaEmptyAction(title: "在浏览器打开",
                                           symbol: "safari",
                                           tint: LumaBrand.amber) {
                store.openCatalogSourceInBrowser(source)
            })
        }
        if catalog.error != nil {
            actions.append(LumaEmptyAction(title: "重试", symbol: "arrow.clockwise") {
                catalog.refresh()
            })
        }
        return actions
    }

    var emptyTitle: String {
        if catalog.error != nil {
            return catalog.errorNeedsVerification ? "站点要求先完成验证" : "内容没有加载出来"
        }
        switch catalog.section {
        case .search(_): return "没有找到相关条目"
        case .continueWatching: return "还没有续看记录"
        case .favorites: return "稍后看还是空的"
        default: return "这一页没有内容"
        }
    }

    var emptyHint: String {
        if catalog.error != nil {
            return catalog.errorNeedsVerification
                ? "403 / 人机验证拦截了请求：先在浏览器打开站点完成验证，再回来点「重试」。"
                : "站点暂时不可达或需要验证，点「重试」再试一次。"
        }
        switch catalog.section {
        case .search(_): return "换一个关键词，或到首页看看推荐。"
        case .continueWatching: return "播放任意一集后，这里会记住上次看到的位置。"
        case .favorites: return "在详情页点「稍后看」，条目就会收在这里。"
        default: return "可以换一个分类，或点右上角刷新重试。"
        }
    }

    func handleSourceRecovery(_ action: RecoveryAction, source: CatalogSource) {
        switch action {
        case .retry:
            catalog.reload()
        case .reauthorize, .reconfigureSource:
            store.openCatalogSourceInBrowser(source)
        case .openInBrowser(let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        case .openSystemSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        case .allowInsecureTLS:
            // 站点证书问题在「设置 › 网络资源」里单独处理，页面内不直接放宽。
            break
        }
    }

    func banner(text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .padding(10)
        .background(Color.red.opacity(isError ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 离线降级提示：列表来自本地快照，标出更新时间，并给一个直接重试的入口。
    func snapshotBanner(_ date: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("站点暂时连不上，正在显示本地快照")
                    .font(.system(size: 11.5, weight: .medium))
                Text("更新于 \(date.formatted(.dateTime.month().day().hour().minute())) · 仍可浏览与续看")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                catalog.refresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(LumaBrand.amber)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(LumaBrand.amber.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LumaBrand.amber.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.7)
        }
    }

    /// 403 / WAF / PoW 拦截：页面里直接给「在浏览器打开」，
    /// 用户先在系统浏览器完成人机验证，回来点重试即可。
    func verificationBanner(source: CatalogSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("站点要求先完成验证")
                    .font(.system(size: 11.5, weight: .medium))
                Text("403 / 人机验证拦截了请求：在浏览器打开站点完成验证后，回来点「重试」。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                store.openCatalogSourceInBrowser(source)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "safari")
                        .font(.system(size: 9, weight: .semibold))
                    Text("在浏览器打开")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(LumaBrand.amber)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(LumaBrand.amber.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                catalog.refresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.accentColor.opacity(0.13), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LumaBrand.amber.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 0.7)
        }
    }

    var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("这个资源已不存在")
                .font(.system(size: 14, weight: .medium))
            Text("可能已在侧边栏移除，可从「网络资源」重新导入。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    func gate(_ source: CatalogSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26))
                    .foregroundStyle(LumaBrand.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("「\(source.name)」尚未启用")
                        .font(.system(size: 15, weight: .semibold))
                    Text("资源内容由第三方站点提供，Luma 不内置、不托管内容与解析参数。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text("启用后只在本机展示与播放，不会把条目写入照片图库索引，也不会参与人物、地图与场景分析。请自行确认来源合规与内容分级。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("启用资源") {
                    catalog.setEnabled(source.id, enabled: true)
                }
                .buttonStyle(.borderedProminent)
                Button("打开源页面") {
                    if let url = URL(string: source.baseURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("移除资源", role: .destructive) {
                    catalog.remove(source.id)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(20)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.top, 24)
    }
}

// MARK: - 分类胶囊 / 频道 tab

/// 一级范围：舱体里的滑动高亮胶囊，切换时高亮块在舱内滑过去。
/// 二级频道：文字 + 渐变下划线，和上面的胶囊拉开视觉差异，不会两排长得一样。
