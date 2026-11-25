import SwiftUI

/// 资源页的「资源统计 + 资源管理」控制台。
/// 统计用拟物化的刻度盘、读数块与分段缓存条；管理直接内联在页面里，不再需要打开弹窗。
struct CatalogResourceConsole: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore

    @State private var artworkStats: [CatalogArtworkStat] = []
    @State private var videoBytes: Int64 = 0
    @State private var refreshToken = 0
    /// 资源管理默认收起：平时只看统计，需要调源时再展开。
    @State private var managementExpanded = CatalogStore.string(forKey: "catalog.console.managementExpanded.v1") == "1"
    @State private var managementHovering = false
    /// 统计面板也可以整体收起（默认展开），标题栏整行可点。
    @State private var statsExpanded = CatalogStore.string(forKey: "catalog.console.statsExpanded.v1") != "0"
    /// 面板可用宽度：窄窗口下统计区要换行，否则缓存卡会被窗口右缘切掉，
    /// 同时把整页内容宽度撑出可视区（「全部资源」的卡片跟着溢出）。
    @State private var panelWidth: CGFloat = 900
    /// 正在编辑的资源：管理行右键「编辑…」打开。
    @State private var editingSource: CatalogSource?

    private var artworkBytes: Int64 { artworkStats.reduce(0) { $0 + $1.bytes } }
    private var artworkFiles: Int { artworkStats.reduce(0) { $0 + $1.files } }

    /// 资源控制台只统计网络资源的网页资源站；影视源归网络影院。
    private var resourceSources: [CatalogSource] { catalog.resourceSources }
    private var enabledSources: [CatalogSource] { resourceSources.filter(\.isEnabled) }

    private var onlineCount: Int {
        enabledSources.filter {
            let state = catalog.health[$0.id] ?? .unknown
            return state == .online || state == .unknown
        }.count
    }

    private var totalChannels: Int {
        resourceSources.reduce(0) { $0 + channelCount($1) }
    }

    private var totalFollows: Int {
        catalog.followedPeople.count + catalog.followedCategories.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statsPanel
            managementPanel
        }
        .task(id: refreshToken) { await reloadCache() }
        .sheet(item: $editingSource) { source in
            CatalogSourceEditorSheet(source: source) { catalog.updateSource($0) }
        }
    }

    // MARK: - 资源统计

    private var statsPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        statsExpanded.toggle()
                        CatalogStore.string(forKey: "catalog.console.statsExpanded.v1",
                                            value: statsExpanded ? "1" : "0")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("资源统计")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(resourceSources.count) 个资源 · 今日新增 \(catalog.todaySpotlight.filter { catalog.resourceSourceIDs.contains($0.sourceID) }.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Image(systemName: statsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(statsExpanded ? "收起统计" : "展开统计")

                Spacer(minLength: 8)

                ConsoleChipButton(title: "检测全部", symbol: "antenna.radiowaves.left.and.right") {
                    catalog.checkHealth(force: true)
                }
            }

            if statsExpanded {
                statsBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .modifier(ConsolePanelStyle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ConsoleWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(ConsoleWidthKey.self) { width in
            if abs(width - panelWidth) > 1 { panelWidth = width }
        }
    }

    /// 宽窗横排（刻度盘 / 读数 / 缓存），窄窗把缓存卡换到第二行。
    private var statsBody: some View {
        Group {
            if panelWidth < 700 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        gauge
                        readouts
                    }
                    storageCard
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    gauge.frame(width: 138)
                    readouts
                    storageCard
                        .frame(width: min(272, max(212, panelWidth * 0.25)))
                }
            }
        }
    }

    private var gauge: some View {
        ResourceGauge(ratio: onlineRatio,
                      online: onlineCount,
                      total: max(1, enabledSources.count))
            .frame(width: 126)
    }

    private var onlineRatio: Double {
        guard !enabledSources.isEmpty else { return 0 }
        return Double(onlineCount) / Double(enabledSources.count)
    }

    /// 读数块列数跟着面板宽度走：窄窗口排两列，不再把整块内容顶出可视区。
    private var readoutColumns: [GridItem] {
        let count = panelWidth < 700 ? 2 : 3
        return Array(repeating: GridItem(.flexible(minimum: 76), spacing: 8), count: count)
    }

    private var readouts: some View {
        LazyVGrid(columns: readoutColumns, spacing: 8) {
            ResourceReadout(symbol: "square.grid.2x2", tint: .accentColor,
                            title: "频道", value: "\(totalChannels)", detail: "含二级频道")
            ResourceReadout(symbol: "calendar", tint: LumaBrand.violet,
                            title: "更新记录", value: "\(catalog.calendarItems.filter { catalog.resourceSourceIDs.contains($0.sourceID) }.count)", detail: "本机累积")
            ResourceReadout(symbol: "clock.arrow.circlepath", tint: LumaBrand.amber,
                            title: "续看", value: "\(catalog.resourceContinueWatching.count)", detail: "未看完在前")
            ResourceReadout(symbol: "bookmark.fill", tint: LumaBrand.coral,
                            title: "稍后看", value: "\(catalog.resourceFavorites.count)", detail: "跨源收藏")
            ResourceReadout(symbol: "star.circle.fill", tint: LumaBrand.mint,
                            title: "关注", value: "\(totalFollows)", detail: "人物与题材")
            ResourceReadout(symbol: "rectangle.stack.fill", tint: LumaBrand.cyan,
                            title: "片单", value: "\(catalog.playlists.count + catalog.smartPlaylists.count)",
                            detail: "自定义与聚合")
        }
    }

    private var videoRatio: Double {
        let limit = VideoCache.luma.limitBytes
        guard limit > 0 else { return 0 }
        return Double(videoBytes) / Double(limit)
    }

    private var posterLimitBytes: Int64 {
        Int64(max(1, AppSettings.shared.posterCacheLimitGB)) * 1_000_000_000
    }

    private var posterRatio: Double {
        posterLimitBytes > 0 ? Double(artworkBytes) / Double(posterLimitBytes) : 0
    }

    private var posterLimitText: String { "\(max(1, AppSettings.shared.posterCacheLimitGB)) GB" }

    private var videoLimitText: String {
        let gb = AppSettings.shared.videoCacheLimitGB
        return gb <= 0 ? "不限" : "\(gb) GB"
    }

    private func setPosterLimit(_ gb: Int) {
        AppSettings.shared.posterCacheLimitGB = gb
        CatalogArtworkCache.trimToLimit()
        refreshToken += 1
    }

    private func setVideoLimit(_ gb: Int) {
        AppSettings.shared.videoCacheLimitGB = gb
        VideoCache.luma.trimIfNeeded()
        refreshToken += 1
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Text("缓存占用")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Menu {
                    Section("海报缓存上限") {
                        ForEach([1, 2, 5, 10], id: \.self) { gb in
                            Button(AppSettings.shared.posterCacheLimitGB == gb ? "✓ \(gb) GB" : "\(gb) GB") {
                                setPosterLimit(gb)
                            }
                        }
                    }
                    Section("视频缓存上限") {
                        ForEach([0, 5, 10, 20, 50], id: \.self) { gb in
                            Button(AppSettings.shared.videoCacheLimitGB == gb
                                   ? (gb == 0 ? "✓ 不限制" : "✓ \(gb) GB")
                                   : (gb == 0 ? "不限制" : "\(gb) GB")) {
                                setVideoLimit(gb)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .semibold))
                        Text("设置上限")
                            .font(.system(size: 8.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("设置海报 / 视频缓存上限")
            }
            ResourceMeter(title: "海报",
                          value: CatalogMaintenance.formatted(artworkBytes),
                          detail: "\(artworkFiles) 张 · \(posterLimitText) 上限",
                          ratio: posterRatio) {
                clearAllArtwork()
            }
            ResourceMeter(title: "视频",
                          value: CatalogMaintenance.formatted(videoBytes),
                          detail: "转码与边下边播 · \(videoLimitText) 上限",
                          ratio: videoRatio) {
                clearVideo()
            }
            Spacer(minLength: 0)
            Text("超限自动按最久未使用淘汰")
                .font(.system(size: 8.5))
                .foregroundStyle(.quaternary)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(ConsoleWell())
    }

    // MARK: - 资源管理

    private var managementPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    managementExpanded.toggle()
                    CatalogStore.string(forKey: "catalog.console.managementExpanded.v1",
                                        value: managementExpanded ? "1" : "0")
                }
            } label: {
                HStack(spacing: 10) {
                    // 一眼能看懂的展开箭头：整行都能点，箭头跟着状态转。
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(managementHovering ? 0.22 : 0.13))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .rotationEffect(.degrees(managementExpanded ? 90 : 0))
                    }
                    .frame(width: 24, height: 24)

                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("资源管理")
                            .font(.system(size: 14, weight: .semibold))
                        Text(managementSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 8)

                    Text(managementExpanded ? "收起" : "展开")
                        .font(.system(size: 10.5, weight: .medium))
                    Image(systemName: managementExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { managementHovering = hovering }
            }
            .help(managementExpanded ? "收起资源管理" : "展开资源管理：逐个源开关、清缓存、置顶")

            if managementExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ConsoleChipButton(title: "清理海报", symbol: "photo.badge.minus") {
                            clearAllArtwork()
                        }
                        ConsoleChipButton(title: "清理视频", symbol: "film.stack") {
                            clearVideo()
                        }
                        ConsoleChipButton(title: "接入资源", symbol: "plus", primary: true) {
                            store.presentCatalogWizard()
                        }
                        SourceExportButton(scope: .catalogResource,
                                           count: catalog.resourceSources.count,
                                           exportData: { catalog.exportSourceBundle(domain: .networkResource) })
                        Spacer(minLength: 0)
                    }

                    if resourceSources.isEmpty {
                        Text("还没有接入资源，点「接入资源」开始。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(catalog.orderedResourceSources) { source in
                                ResourceSourceRow(source: source,
                                                  health: catalog.health[source.id] ?? .unknown,
                                                  latency: catalog.healthLatency[source.id],
                                                  channels: channelCount(source),
                                                  progressCount: progressCount(source),
                                                  cacheText: cacheText(source.id),
                                                  pinned: catalog.isPinned(sourceID: source.id),
                                                  hasNew: catalog.hasNewContent(source.id),
                                                  onToggle: {
                                                      catalog.setEnabled(source.id, enabled: !source.isEnabled)
                                                  },
                                                  onClearCache: {
                                                      catalog.clearArtwork(source.id)
                                                      refreshToken += 1
                                                  },
                                                  onPin: { catalog.togglePin(sourceID: source.id) },
                                                  onOpen: { store.openCatalogSource(source.id) },
                                                  onEdit: { editingSource = source },
                                                  onRemove: { catalog.remove(source.id) })
                                if source.id != catalog.orderedResourceSources.last?.id {
                                    Divider().opacity(0.35).padding(.leading, 48)
                                }
                            }
                        }
                        .modifier(ConsoleWell(cornerRadius: 13))
                    }
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .modifier(ConsolePanelStyle())
    }

    private var managementSummary: String {
        let total = resourceSources.count
        let online = onlineCount
        let fresh = catalog.newSourceIDs.intersection(catalog.resourceSourceIDs).count
        return "\(total) 个资源 · 在线 \(online)" + (fresh > 0 ? " · \(fresh) 个有新内容" : "")
    }

    // MARK: - 数据

    private func channelCount(_ source: CatalogSource) -> Int {
        catalog.sidebarCategories(for: source).reduce(0) {
            $0 + max(1, $1.children?.count ?? 1)
        }
    }

    private func progressCount(_ source: CatalogSource) -> Int {
        catalog.allContinueWatching.filter { $0.sourceID == source.id }.count
    }

    private func cacheText(_ id: UUID) -> String? {
        guard let stat = artworkStats.first(where: { $0.sourceID == id }) else { return nil }
        return "\(CatalogMaintenance.formatted(stat.bytes)) · \(stat.files) 张"
    }

    private func reloadCache() async {
        artworkStats = await Task.detached(priority: .utility) {
            CatalogMaintenance.artworkStats()
        }.value
        videoBytes = await Task.detached(priority: .utility) {
            CatalogMaintenance.videoCacheBytes()
        }.value
    }

    private func clearAllArtwork() {
        CatalogMaintenance.clearArtwork(sourceID: nil)
        refreshToken += 1
    }

    private func clearVideo() {
        CatalogMaintenance.clearVideoCache()
        refreshToken += 1
    }
}

// MARK: - 面板宽度

/// 统计面板的实际可用宽度，用来决定读数块列数与是否把缓存卡换行。
private struct ConsoleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 刻度盘

/// 拟物化圆盘：一圈刻度按在线比例点亮，中间是读数。
private struct ResourceGauge: View {
    let ratio: Double
    let online: Int
    let total: Int

    private var litCount: Int {
        Int((min(1, max(0, ratio)) * 28).rounded())
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Canvas { context, size in
                    drawTicks(context: context, size: size)
                }
                .frame(width: 126, height: 126)

                Circle()
                    .fill(Color.primary.opacity(0.035))
                    .frame(width: 74, height: 74)
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
                    }
                VStack(spacing: 1) {
                    Text("\(online)/\(total)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("在线源")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 126, height: 126)
            Text("联网状态")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func drawTicks(context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 5
        let gradient = Gradient(colors: [LumaBrand.amber, LumaBrand.coral, LumaBrand.violet])
        for index in 0..<28 {
            let degrees = Double(index) * 9.4 - 127
            let radians = degrees * .pi / 180
            let direction = CGPoint(x: sin(radians), y: -cos(radians))
            let major = index % 4 == 0
            let length: CGFloat = major ? 9 : 5.5
            let inner = radius - length
            let start = CGPoint(x: center.x + direction.x * inner,
                                y: center.y + direction.y * inner)
            let end = CGPoint(x: center.x + direction.x * radius,
                              y: center.y + direction.y * radius)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            if index < litCount {
                context.stroke(path,
                               with: .linearGradient(gradient,
                                                     startPoint: .zero,
                                                     endPoint: CGPoint(x: size.width, y: size.height)),
                               style: StrokeStyle(lineWidth: major ? 2.2 : 1.4, lineCap: .round))
            } else {
                context.stroke(path,
                               with: .color(Color.primary.opacity(0.10)),
                               style: StrokeStyle(lineWidth: major ? 2.0 : 1.2, lineCap: .round))
            }
        }
    }
}

// MARK: - 读数块

private struct ResourceReadout: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .modifier(ConsoleWell())
    }
}

// MARK: - 缓存条

private struct ResourceMeter: View {
    let title: String
    let value: String
    let detail: String
    let ratio: Double
    let action: () -> Void

    private var litCount: Int {
        guard ratio > 0 else { return 0 }
        return max(1, Int((min(1, max(0, ratio)) * 18).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Button("清理", action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 2) {
                ForEach(0..<18, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(segmentStyle(index))
                        .frame(height: 5)
                }
            }
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    }

    private func segmentStyle(_ index: Int) -> AnyShapeStyle {
        index < litCount ? AnyShapeStyle(LumaBrand.gradient)
                         : AnyShapeStyle(Color.primary.opacity(0.09))
    }
}

// MARK: - 管理行

private struct ResourceSourceRow: View {
    let source: CatalogSource
    let health: CatalogSourceHealth
    let latency: Int?
    let channels: Int
    let progressCount: Int
    let cacheText: String?
    let pinned: Bool
    let hasNew: Bool
    let onToggle: () -> Void
    let onClearCache: () -> Void
    let onPin: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var tint: Color { source.kind.sidebarTint }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: source.kind.sidebarSymbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(source.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .lineLimit(1)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.tertiary)
                    }
                    if hasNew {
                        Text("新")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                    }
                }
                Text(source.kind.title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            healthBadge

            Text(latency.map { "\($0) ms" } ?? "— ms")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .trailing)

            Text("\(channels) 频道")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)

            Text("\(progressCount) 续看")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(progressCount > 0 ? Color.secondary : Color.secondary.opacity(0.55))
                .frame(width: 56, alignment: .trailing)

            Text(cacheText ?? "—")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 124, alignment: .trailing)

            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(source.isEnabled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(source.isEnabled ? "启用" : "停用")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(source.isEnabled ? "停用这个资源" : "启用这个资源")

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(hovering ? Color.primary.opacity(0.045) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var healthBadge: some View {
        let color: Color
        let text: String
        if !source.isEnabled {
            color = .orange
            text = "未启用"
        } else {
            switch health {
            case .online: color = .green; text = "在线"
            case .limited: color = .yellow; text = "需验证"
            case .offline: color = .red; text = "离线"
            case .checking: color = .gray; text = "检测中"
            case .unknown: color = .green; text = "已启用"
            }
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5.5, height: 5.5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 62, alignment: .leading)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("打开") { onOpen() }
        Button(pinned ? "取消置顶" : "置顶") { onPin() }
        Button("编辑…") { onEdit() }
        Button("清除海报缓存") { onClearCache() }
        Divider()
        Button("移除资源", role: .destructive) { onRemove() }
    }
}

// MARK: - 控制台按钮

private struct ConsoleChipButton: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(primary ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(primary ? Color.accentColor.opacity(0.35)
                                          : Color.primary.opacity(0.07),
                                  lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 面板样式

/// 金属面板：上下渐变 + 顶底高光描边 + 四角螺钉。
private struct ConsolePanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.07),
                                                  Color.primary.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.16),
                                                          .clear,
                                                          .black.opacity(0.14)],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing),
                                  lineWidth: 1)
            }
            .overlay(alignment: .topLeading) { ConsoleScrew().padding(7) }
            .overlay(alignment: .topTrailing) { ConsoleScrew().padding(7) }
            .overlay(alignment: .bottomLeading) { ConsoleScrew().padding(7) }
            .overlay(alignment: .bottomTrailing) { ConsoleScrew().padding(7) }
            .shadow(color: .black.opacity(0.09), radius: 12, y: 5)
    }
}

/// 内嵌凹槽：底色 + 内阴影，读数块与搜索框共用。
private struct ConsoleWell: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.10), .clear],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
    }
}

private struct ConsoleScrew: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.primary.opacity(0.16),
                                          Color.primary.opacity(0.04)],
                                 center: .topLeading, startRadius: 0, endRadius: 5))
            .frame(width: 7, height: 7)
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 4, height: 0.9)
                    .rotationEffect(.degrees(-35))
            }
    }
}
