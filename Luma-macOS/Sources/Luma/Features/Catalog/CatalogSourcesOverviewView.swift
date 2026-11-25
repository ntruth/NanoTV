import SwiftUI

/// 资源页：资源统计 → 资源管理 → 全部资源。
/// 搜索并入统计控制台；搜索结果出现时替换管理区与资源墙。
struct CatalogSourcesOverviewView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore

    @State private var hoveringSource: UUID?
    /// 跨源搜索的结果二次筛选：点来源胶囊只看那个源，空 = 全部。
    @State private var resultSourceFilter: UUID?
    /// 正在编辑的资源：卡片右键「编辑…」打开。
    @State private var editingSource: CatalogSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CatalogResourceConsole()
                if !query.isEmpty {
                    globalSearchSection
                } else {
                    sourceSection
                    favoriteSection
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 16)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.automatic)
        .background(LumaAmbientBackground(intensity: 0.55))
        .task {
            catalog.checkHealth()
            catalog.loadSpotlight()
            catalog.refreshFollowedPeople()
        }
        .task(id: catalog.globalQuery) {
            guard !query.isEmpty else {
                catalog.clearGlobalSearch()
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            catalog.searchAllSources()
        }
        .sheet(item: $editingSource) { source in
            CatalogSourceEditorSheet(source: source) { catalog.updateSource($0) }
        }
    }

    private var query: String {
        catalog.globalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 稍后看

    @ViewBuilder
    private var favoriteSection: some View {
        let favorites = Array(catalog.resourceFavorites.prefix(12))
        if !favorites.isEmpty {
            railSection(title: "稍后看",
                        subtitle: "资源站收藏 · \(catalog.resourceFavorites.count) 条",
                        symbol: "bookmark.fill") {
                ForEach(favorites) { favorite in
                    if let source = source(favorite.sourceID) {
                        CatalogRailCard(source: source,
                                        cover: favorite.coverURL,
                                        title: favorite.title,
                                        caption: source.name,
                                        progress: nil,
                                        badge: favorite.remark.isEmpty ? "直接播放" : favorite.remark,
                                        tint: source.kind.sidebarTint,
                                        previewTarget: {
                                            await catalog.previewTarget(
                                                sourceID: favorite.sourceID,
                                                item: CatalogItem(id: favorite.itemID,
                                                                  title: favorite.title,
                                                                  coverURL: favorite.coverURL,
                                                                  remark: favorite.remark,
                                                                  categoryID: nil))
                                        }) {
                            catalog.playFavorite(favorite)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 跨源搜索

    private var globalSearchSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("“\(query)” 的搜索结果")
                    .font(.system(size: 14, weight: .semibold))
                if catalog.isGlobalSearching {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("\(catalog.globalResults.reduce(0) { $0 + $1.items.count }) 条 · \(catalog.globalResults.count) 个源")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 搜索框已经收进顶栏：结果页保留一个明确的退出入口，避免停在搜索结果里。
                Button {
                    catalog.globalQuery = ""
                } label: {
                    Label("清除搜索", systemImage: "xmark.circle")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // 自然语言解析结果：把「中文字幕 / 90 年代」拆成条件胶囊，让用户知道系统在筛什么。
            if let plan = catalog.globalQueryPlan, !plan.chips.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(plan.chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.11),
                                        in: Capsule(style: .continuous))
                    }
                    Spacer()
                }
            }
            if !catalog.isGlobalSearching, catalog.globalResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("各源都没有找到匹配内容")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color.primary.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if !catalog.globalResults.isEmpty {
                resultFilterBar
            }
            ForEach(visibleResultGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if let source = source(group.sourceID) {
                            sourceDot(source)
                            Text(source.name)
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        Text("\(group.items.count) 条")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)],
                              alignment: .leading, spacing: 16) {
                        ForEach(group.items) { item in
                            if let source = source(group.sourceID) {
                                CatalogSearchCell(source: source, item: item) {
                                    catalog.playRemote(sourceID: group.sourceID, item: item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 结果二次筛选条：每个源一枚胶囊（带条数），点一次只看那个源，再点回到全部。
    private var resultFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                resultFilterChip(nil, title: "全部 \(catalog.globalResults.reduce(0) { $0 + $1.items.count })")
                ForEach(catalog.globalResults) { group in
                    if let source = source(group.sourceID) {
                        resultFilterChip(group.sourceID,
                                         title: "\(source.name) \(group.items.count)")
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private func resultFilterChip(_ id: UUID?, title: String) -> some View {
        let active = resultSourceFilter == id
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                resultSourceFilter = active ? nil : id
            }
        } label: {
            HStack(spacing: 5) {
                if let id, let source = source(id) {
                    Circle()
                        .fill(source.kind.sidebarTint)
                        .frame(width: 4.5, height: 4.5)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(active ? Color.accentColor : Color.primary.opacity(0.05),
                        in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var visibleResultGroups: [CatalogGlobalResult] {
        // 换关键词后旧筛选自然失效：结果里没有这个源就退回全部。
        guard let filter = resultSourceFilter,
              catalog.globalResults.contains(where: { $0.sourceID == filter }) else {
            return catalog.globalResults
        }
        return catalog.globalResults.filter { $0.sourceID == filter }
    }

    // MARK: - 源卡片墙

    /// 影视源归「网络影院」，这里只统计网页资源站。
    private var webSources: [CatalogSource] {
        catalog.orderedResourceSources
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "全部资源",
                          subtitle: "\(webSources.count) 个站点",
                          symbol: "square.grid.2x2.fill") {
                SourceExportButton(scope: .catalogResource,
                                   count: webSources.count,
                                   exportData: { catalog.exportSourceBundle(domain: .networkResource) })
            }
            if webSources.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 232), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(webSources) { source in
                        sourceCard(source)
                    }
                    addCard
                }
            }
        }
    }

    private func sourceCard(_ source: CatalogSource) -> some View {
        let tint = source.kind.sidebarTint
        let hovering = hoveringSource == source.id
        return Button {
            store.openCatalogSource(source.id)
        } label: {
            ZStack(alignment: .topLeading) {
                backdrop(source, tint: tint)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        symbolTile(source.kind, tint: tint)
                        if catalog.isPinned(sourceID: source.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .rotationEffect(.degrees(28))
                        }
                        Spacer(minLength: 0)
                        statusPill(source)
                    }
                    Spacer(minLength: 10)
                    HStack(spacing: 7) {
                        Text(source.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                        if catalog.hasNewContent(source.id) {
                            Text("新")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                                .shadow(color: .red.opacity(0.5), radius: 6, y: 1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(source.kind.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        cardBadge("\(channelCount(source)) 个频道")
                        if progressCount(source) > 0 {
                            cardBadge("\(progressCount(source)) 续看")
                        }
                        if !source.isEnabled {
                            cardBadge("未启用")
                        }
                    }
                    .padding(.top, 10)
                }
                .padding(15)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 172)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.85) : Color.white.opacity(0.12),
                                  lineWidth: hovering ? 1.4 : 0.8)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.34), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.6))
                    .padding(14)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : 4, y: hovering ? 0 : 4)
            }
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.14),
                    radius: hovering ? 18 : 10, y: hovering ? 9 : 4)
            .scaleEffect(hovering ? 1.012 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) {
                hoveringSource = inside ? source.id : (hoveringSource == source.id ? nil : hoveringSource)
            }
        }
        .contextMenu {
            Button("打开") { store.openCatalogSource(source.id) }
            Button(catalog.isPinned(sourceID: source.id) ? "取消置顶" : "置顶") {
                catalog.togglePin(sourceID: source.id)
            }
            Button("编辑…") { editingSource = source }
            Button("检测状态") { catalog.checkHealth(force: true) }
            Button(source.isEnabled ? "停用" : "启用") {
                catalog.setEnabled(source.id, enabled: !source.isEnabled)
            }
            Button("清除海报缓存") { catalog.clearArtwork(source.id) }
            Divider()
            Button("移除资源", role: .destructive) { catalog.remove(source.id) }
        }
        .help(source.name)
    }

    @ViewBuilder
    private func backdrop(_ source: CatalogSource, tint: Color) -> some View {
        // 封面是 scaledToFill：必须先用 Color.clear 兜住卡片尺寸，
        // 否则图片会按自身大小撑开，叠到相邻卡片上。
        Color.clear
            .overlay {
                if let thumb = backdropThumb(source) {
                    CatalogArtworkImage(source: source, urlString: thumb, cornerRadius: 0)
                        .overlay {
                            LinearGradient(colors: [tint.opacity(0.55),
                                                    .black.opacity(0.55),
                                                    .black.opacity(0.88)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                } else {
                    ZStack {
                        LinearGradient(colors: [tint.opacity(0.92), tint.opacity(0.46),
                                                .black.opacity(0.86)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: source.kind.sidebarSymbol)
                            .font(.system(size: 96, weight: .bold))
                            .foregroundStyle(.white.opacity(0.10))
                            .rotationEffect(.degrees(-10))
                            .offset(x: 46, y: 30)
                    }
                }
            }
            .clipped()
    }

    private func symbolTile(_ kind: CatalogProviderKind, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.66)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: kind.sidebarSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.26), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }

    /// 状态徽章：启用状态 + 连通性。
    private func statusPill(_ source: CatalogSource) -> some View {
        let health: CatalogSourceHealth = source.isEnabled
            ? (catalog.health[source.id] ?? .unknown)
            : .unknown
        let color: Color
        let text: String
        if !source.isEnabled {
            color = .orange
            text = "未启用"
        } else {
            switch health {
            case .online:
                color = .green
                text = "在线"
            case .limited:
                color = .yellow
                text = "需验证"
            case .offline:
                color = .red
                text = "离线"
            case .checking:
                color = .gray
                text = "检测中"
            case .unknown:
                color = .green
                text = "已启用"
            }
        }
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.32), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
    }

    private func cardBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.13), in: Capsule(style: .continuous))
    }

    private func sourceDot(_ source: CatalogSource) -> some View {
        ZStack {
            Circle()
                .fill(source.kind.sidebarTint.opacity(0.22))
            Image(systemName: source.kind.sidebarSymbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(source.kind.sidebarTint)
        }
        .frame(width: 18, height: 18)
    }

    private func backdropThumb(_ source: CatalogSource) -> String? {
        for category in catalog.sidebarCategories(for: source) {
            if let url = catalog.thumbURL(for: category, sourceID: source.id) {
                return url
            }
        }
        return nil
    }

    private func channelCount(_ source: CatalogSource) -> Int {
        catalog.sidebarCategories(for: source).reduce(0) {
            $0 + max(1, $1.children?.count ?? 1)
        }
    }

    private func progressCount(_ source: CatalogSource) -> Int {
        catalog.allContinueWatching.filter { $0.sourceID == source.id }.count
    }

    private func source(_ id: UUID) -> CatalogSource? {
        catalog.sources.first(where: { $0.id == id })
    }

    // MARK: - 通用区块头 / 轨道

    private func sectionHeader(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    /// 带右侧动作的标题行：导入 / 导出这类整页级入口放在标题右边。
    private func sectionHeader<Trailing: View>(title: String,
                                                subtitle: String,
                                                symbol: String,
                                                @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func railSection<Content: View>(title: String,
                                            subtitle: String,
                                            symbol: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: title, subtitle: subtitle, symbol: symbol)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content()
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - 添加 / 空态

    private var addCard: some View {
        Button {
            store.presentCatalogWizard()
        } label: {
            VStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
                Text("接入网络资源")
                    .font(.system(size: 13, weight: .semibold))
                Text("粘贴站点地址，或导入配置文件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 172)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18),
                                  style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            }
        }
        .buttonStyle(.plain)
        .help("接入网络资源")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.9))
            Text("还没有网络资源")
                .font(.system(size: 16, weight: .semibold))
            Text("把影视站、短剧源接入后，会像本地图库一样按分类浏览与播放。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("接入网络资源…") {
                store.presentCatalogWizard()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black.opacity(0.86))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(.white, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.24), radius: 12, y: 4)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }
}

// MARK: - 轨道卡片

private struct CatalogRailCard: View {
    let source: CatalogSource
    let cover: String
    let title: String
    let caption: String
    var progress: Double?
    var badge: String?
    var rank: Int?
    var tint: Color
    /// 悬停预览：和频道页卡片一样，解析后静音循环。
    var previewTarget: (() async -> CatalogPreviewTarget?)?
    let action: () -> Void

    @State private var hovering = false
    @State private var previewURL: URL?
    @State private var previewHeaders: [String: String] = [:]
    @State private var previewTask: Task<Void, Never>?
    @State private var previewHandle = VideoPreviewHandle()
    @State private var isPreparingPreview = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .frame(width: 218, height: 123)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: cover, cornerRadius: 12)
                    }
                    .overlay {
                        if let previewURL {
                            HoverVideoSurface(url: previewURL,
                                              headers: previewHeaders,
                                              handle: previewHandle) { _ in }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        if let rank {
                            Text("\(rank)")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7,
                                                                                        style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
                                }
                                .padding(7)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0.01 {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.black.opacity(0.45))
                                    Capsule().fill(Color.accentColor)
                                        .frame(width: max(3, proxy.size.width * progress))
                                }
                            }
                            .frame(height: 3)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                        }
                    }
                    .overlay {
                        if hovering, previewURL == nil {
                            ZStack {
                                Color.black.opacity(0.18)
                                if isPreparingPreview {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                        .frame(width: 32, height: 32)
                                        .background(.black.opacity(0.45), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.3),
                                                                       lineWidth: 0.6))
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.black.opacity(0.82))
                                        .frame(width: 32, height: 32)
                                        .background(.white.opacity(0.95), in: Circle())
                                        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(hovering ? tint.opacity(0.75) : Color.primary.opacity(0.08),
                                          lineWidth: hovering ? 1.1 : 0.6)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.26 : 0.14),
                            radius: hovering ? 12 : 6, y: hovering ? 6 : 3)

                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovering ? 1 : 0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 218, height: 34, alignment: .topLeading)

                HStack(spacing: 5) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4.5, height: 4.5)
                    Text(caption)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 218)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside { startPreview() } else { stopPreview() }
        }
        .onDisappear { stopPreview() }
        .help(title)
    }

    private func startPreview() {
        guard previewURL == nil, let previewTarget else { return }
        previewTask?.cancel()
        isPreparingPreview = true
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let target = await previewTarget()
            guard !Task.isCancelled else { return }
            isPreparingPreview = false
            guard let target else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                previewHeaders = target.headers
                previewURL = target.url
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
        guard previewURL != nil || !previewHeaders.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            previewURL = nil
            previewHeaders = [:]
        }
    }
}

// MARK: - 搜索结果卡片

private struct CatalogSearchCell: View {
    let source: CatalogSource
    let item: CatalogItem
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .frame(height: 104)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: item.coverURL, cornerRadius: 10)
                    }
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.66)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !item.remark.isEmpty {
                            Text(item.remark)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.bottom, 6)
                        }
                    }
                    .overlay {
                        if hovering {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.82))
                                .frame(width: 26, height: 26)
                                .background(.white.opacity(0.94), in: Circle())
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(hovering ? Color.accentColor.opacity(0.55)
                                                  : Color.primary.opacity(0.07),
                                          lineWidth: hovering ? 1 : 0.6)
                    }
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .help(item.title)
    }
}
