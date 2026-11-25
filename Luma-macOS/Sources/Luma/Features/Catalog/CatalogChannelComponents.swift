import AppKit
import SwiftUI
import LumaContentCore

/// 列表滚动进度：只上报内容偏移与总高度，用于 60% 提前预取下一页。

/// 网络资源频道的卡片与小组件。

struct CatalogChip: View {
    enum Style {
        case tray
        case underline
    }

    let title: String
    var active: Bool = false
    var style: Style = .tray
    var namespace: Namespace.ID?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            switch style {
            case .tray: tray
            case .underline: underline
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.20), value: active)
        .help(title)
    }

    // MARK: 一级

    var tray: some View {
        Text(title)
            .font(.system(size: 12, weight: active ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 6.5)
            .background {
                if active {
                    activePill
                } else if hovering {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Capsule(style: .continuous))
    }

    /// 选中块：强调色渐变 + 顶部高光 + 光晕，靠 matchedGeometry 在舱内滑动。
    var activePill: some View {
        let pill = Capsule(style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor,
                                          Color.accentColor.opacity(0.72)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
            }
            .shadow(color: Color.accentColor.opacity(0.42), radius: 10, y: 3)
        return Group {
            if let namespace {
                pill.matchedGeometryEffect(id: "catalog.chip.tray", in: namespace)
            } else {
                pill
            }
        }
    }

    // MARK: 二级

    var underline: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? Color.primary
                                        : (hovering ? Color.primary.opacity(0.9)
                                                    : Color.secondary.opacity(0.72)))
            underlineBar
        }
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    var underlineBar: some View {
        if active {
            let bar = Capsule(style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor,
                                              Color.accentColor.opacity(0.12)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 2.5)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
            if let namespace {
                bar.matchedGeometryEffect(id: "catalog.chip.underline", in: namespace)
            } else {
                bar
            }
        } else {
            Color.clear.frame(height: 2.5)
        }
    }
}

/// 热门标签面板的一级分组：标题 + 标签数，选中项用强调色，下方只显示这一组的标签。
struct CatalogTagGroupChip: View {
    let title: String
    let count: Int
    let active: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .opacity(active ? 0.85 : 0.6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.secondary))
            .background {
                Capsule(style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Color.accentColor,
                                         Color.accentColor.opacity(0.82)],
                                startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.22)
                                         : Color.primary.opacity(0.07),
                                  lineWidth: 0.7)
            }
            .shadow(color: active ? Color.accentColor.opacity(0.30) : .clear,
                    radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(title)（\(count) 个标签）")
    }
}

/// 平铺用的标签胶囊：宽度随文字，放不下自动换行；字号比分组标签更大，一眼看清。
struct CatalogTagPill: View {
    let title: String
    let active: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("#")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(active ? Color.white.opacity(0.70)
                                            : Color.accentColor.opacity(0.80))
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.primary.opacity(0.92)))
            .background {
                Capsule(style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                  Color.accentColor.opacity(0.82)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.11 : 0.06)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.22)
                                         : Color.primary.opacity(0.07),
                                  lineWidth: 0.7)
            }
            .shadow(color: active ? Color.accentColor.opacity(0.28) : .clear, radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
    }
}

/// 二级频道数量很多时的紧凑胶囊：放不下自动换行，一屏看全。
struct CatalogChannelPill: View {
    let title: String
    let active: Bool
    /// 常用分类：标题前加一枚小图钉。
    var pinned: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(active ? Color.white.opacity(0.9)
                                                : Color.accentColor.opacity(0.75))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .foregroundStyle(active ? Color.white
                                        : (hovering ? Color.primary : Color.primary.opacity(0.78)))
                .background {
                    Capsule(style: .continuous)
                        .fill(active
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [Color.accentColor,
                                             Color.accentColor.opacity(0.82)],
                                    startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(active ? Color.white.opacity(0.22)
                                             : Color.primary.opacity(0.07),
                                      lineWidth: 0.7)
                }
                .shadow(color: active ? Color.accentColor.opacity(0.30) : .clear,
                        radius: 6, y: 2)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
    }
}

/// 左对齐的流式布局：一行放不下就换到下一行。
struct CatalogFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + lineSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 稍后看 列表行

/// 稍后看行：整行点开详情，右侧移除按钮在悬停时更明显。
struct CatalogFavoriteRow: View {
    let source: CatalogSource
    let favorite: CatalogFavorite
    var onOpen: () -> Void
    var onRemove: () -> Void

    @State private var hovering = false
    @StateObject private var coverTint = CatalogCoverTint()

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    CatalogArtworkImage(source: source, urlString: favorite.coverURL, cornerRadius: 9)
                        .frame(width: 58, height: 86)
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(favorite.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        if !favorite.remark.isEmpty {
                            Text(favorite.remark)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("加入于 \(favorite.addedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "bookmark.slash")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.6))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("从稍后看移除")
            .accessibilityLabel("从稍后看移除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background { card }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
            if inside { coverTint.load(source: source, urlString: favorite.coverURL) }
        }
    }

    var card: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(hovering ? (coverTint.color.map { $0.opacity(0.55) }
                                            ?? Color.primary.opacity(0.16))
                                           : Color.primary.opacity(0.05),
                                  lineWidth: hovering ? 1.0 : 0.7)
            }
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 12, y: 4)
    }
}

// MARK: - 顶栏控制台
//
// 页面头部的「首页 / 黄果短剧 · huangguoai.io / 刷新 / 在本资源内搜索」整体并入窗口工具栏，
// 与返回、标题、缩放共用同一层 chrome；内容区只保留 chips 与网格（AGENTS.md §17）。

/// 工具栏最左的返回：带文字的强调色胶囊，悬停整体点亮，
/// 尺寸与顶栏其它舱体同一档，避免只留一个孤立的小箭头。
struct CatalogToolbarBackButton: View {
    var title: String = "返回"
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(hovering ? Color.white : Color.accentColor)
            .padding(.leading, 10)
            .padding(.trailing, 13)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(hovering
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor,
                                                                  Color.accentColor.opacity(0.84)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [Color.accentColor.opacity(0.20),
                                                                  Color.accentColor.opacity(0.08)],
                                                         startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                // 顶部高光：和一级分类的选中胶囊同一套质感。
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(hovering ? 0.24 : 0.16), .clear],
                                         startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(hovering ? Color.white.opacity(0.30)
                                           : Color.accentColor.opacity(0.34),
                                  lineWidth: 0.8)
            }
            .shadow(color: Color.accentColor.opacity(hovering ? 0.38 : 0.16),
                    radius: hovering ? 9 : 4, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) { hovering = inside }
        }
        .keyboardShortcut(.cancelAction)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 中区信息：当前分类可点开菜单直接跳转（与左侧菜单同一份分类），右侧是刷新。
struct CatalogToolbarConsole: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    @State private var text = ""
    @FocusState private var focused: Bool

    /// 清空搜索时原地恢复的位置。
    private enum SearchReturn {
        case home
        case category(CatalogCategory)
        case rank
        case favorites
    }

    /// 进入搜索前所在的位置：清空关键词后回到这里，而不是退回首页。
    @State private var searchReturn: SearchReturn?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let item = catalog.inlineDetailItem {
                // 详情页的返回直接融进同一枚胶囊：返回 · 条目标题 · 站点 · 播放，
                // 内容区不再单独浮一个「返回」按钮（顶栏融合 §17）。
                detailConsole(item)
            } else {
                browseConsole
            }
        }
        .onChange(of: catalog.searchFocusToken) { _, _ in
            focused = true
        }
        .onChange(of: catalog.section) { _, newValue in
            if case .search(let keyword) = newValue {
                if text != keyword { text = keyword }
            } else if !text.isEmpty {
                // 从菜单 / 侧边栏切走：搜索框跟着清空，避免残留关键词。
                text = ""
            }
        }
        // 与网络影院站点页同一套搜索逻辑：边输入边搜站点，不再等回车。
        .onChange(of: text) { _, value in
            scheduleLiveSearch(value)
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
        .onAppear {
            if case .search(let keyword) = catalog.section { text = keyword }
        }
    }

    private var isSearchSection: Bool {
        if case .search = catalog.section { return true }
        return false
    }

    private var isSearching: Bool {
        isSearchSection && catalog.isLoading
    }

    /// 输入防抖 420ms：连续打字只发最后一次站点搜索。
    private func scheduleLiveSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            restoreAfterClearingSearch()
            return
        }
        // 已经停在同一关键词的结果上（例如重新进入页面）：不重复打接口。
        if case .search(let keyword) = catalog.section, keyword == trimmed,
           !catalog.isLoading, !catalog.items.isEmpty {
            return
        }
        if !isSearchSection {
            searchReturn = makeSearchReturn()
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            catalog.search(trimmed)
        }
    }

    /// 清空搜索：回到进入搜索前的分类 / 首页。
    private func restoreAfterClearingSearch() {
        guard isSearchSection else {
            searchReturn = nil
            return
        }
        let target = searchReturn ?? .home
        searchReturn = nil
        switch target {
        case .home: catalog.openHome()
        case .category(let category): catalog.openCategory(category)
        case .rank: catalog.openRank()
        case .favorites: catalog.openFavorites()
        }
    }

    private func makeSearchReturn() -> SearchReturn {
        switch catalog.section {
        case .category(let id):
            if let category = catalog.category(withID: id) { return .category(category) }
            if let top = catalog.activeTopCategory { return .category(top) }
            return .home
        case .rank: return .rank
        case .favorites: return .favorites
        default: return .home
        }
    }


    /// 胶囊舱体的统一外壳：两种模式共用同一层材质与描边，切换时不会「换了个控件」。
    func consoleChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 5.5)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
    }

    /// 详情模式：返回在窗口工具栏最左侧（与视频播放器一致），
    /// 这枚胶囊只承担「当前条目 · 站点 · 播放」。
    func detailConsole(_ item: CatalogItem) -> some View {
        let tint = catalog.selectedSource?.kind.sidebarTint ?? Color.accentColor
        return consoleChrome {
            HStack(spacing: 10) {
                Image(systemName: catalog.selectedSource?.kind.sidebarSymbol ?? "play.rectangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)

                if let host = catalog.selectedSource?.host, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let episode = firstEpisode(of: item) {
                    divider
                    Button {
                        catalog.play(item: item, episode: episode, seconds: 0)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(episode.index > 1 ? "第 \(episode.index) 集" : "播放")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.accentColor, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("从第 \(episode.index) 集开始播放")
                }
            }
        }
    }

    /// 详情已加载且是同一个条目时，工具栏才有「播放」入口。
    func firstEpisode(of item: CatalogItem) -> CatalogEpisode? {
        guard catalog.detail?.item.id == item.id else { return nil }
        return catalog.detail?.episodes.first
    }

    /// 浏览模式：分类 · 站点 · 排序 · 站内搜索 · 刷新。
    var browseConsole: some View {
        consoleChrome {
            HStack(spacing: 11) {
                Menu {
                    menu
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sectionIcon)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(catalog.sectionTitle)
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
                .help("切换分类（与左侧菜单同步）")

                if let host = catalog.selectedSource?.host, !host.isEmpty {
                    Text(host)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                divider
                sortMenu
                divider
                searchField
                divider

                Button {
                    catalog.refresh()
                } label: {
                    if catalog.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .disabled(catalog.isLoading)
                .help("刷新当前分类")
                .accessibilityLabel("刷新")
            }
        }
    }

    /// 排序放在窗口工具栏：站点支持的排序 + 本页排序，符合顶栏融合规范（§17）。
    var sortMenu: some View {
        Menu {
            Section("站点排序") {
                ForEach(catalog.supportedSorts) { option in
                    Button {
                        catalog.setSort(option)
                    } label: {
                        if catalog.sort == option, catalog.localSort == nil {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
            Section("本页排序") {
                ForEach(CatalogLocalSort.allCases) { option in
                    Button {
                        catalog.setLocalSort(option)
                    } label: {
                        if catalog.localSort == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(shortSortTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(catalog.localSort == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(catalog.localSort == nil
              ? "排序：\(catalog.sort.title)"
              : "本页按\(catalog.localSort?.title ?? "")排序，仅作用于已加载的 \(catalog.items.count) 条")
    }

    var shortSortTitle: String {
        if let localSort = catalog.localSort { return "本页·\(localSort.title)" }
        switch catalog.sort {
        case .latest: return "最新"
        case .hot: return "热播"
        case .newest: return "上架"
        case .collect: return "收藏"
        }
    }

    /// 站内搜索：只搜当前这个资源，提示语直接带上源名，避免和图库搜索混淆。
    /// 与网络影院站点页一致：边输入边打站点搜索接口，清空后原地回到分类。
    var searchField: some View {
        HStack(spacing: 5) {
            if isSearching {
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
                .help(searchPlaceholder)
            }

            TextField(searchPlaceholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit {
                    focused = false
                }
                .onExitCommand {
                    if text.isEmpty {
                        focused = false
                    } else {
                        text = ""
                    }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
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

    var searchPlaceholder: String {
        "搜索\(catalog.selectedSource?.name ?? "本资源")"
    }

    var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
    }

    var sectionIcon: String {
        switch catalog.section {
        case .home: return "house"
        case .rank: return "chart.bar.fill"
        case .search: return "magnifyingglass"
        case .continueWatching: return "clock.arrow.circlepath"
        case .favorites: return "bookmark"
        case .category: return "square.grid.2x2"
        }
    }

    @ViewBuilder
    var menu: some View {
        Button {
            catalog.openHome()
        } label: {
            Label("首页", systemImage: "house")
        }
        if !catalog.categories.isEmpty {
            Divider()
            ForEach(catalog.categories) { category in
                if let children = category.children, !children.isEmpty {
                    Menu(category.title) {
                        Button("全部") { open(category) }
                        ForEach(children) { child in
                            Button(child.title) { catalog.openCategory(child) }
                        }
                    }
                } else {
                    Button {
                        open(category)
                    } label: {
                        Label(category.title,
                              systemImage: category.isRank ? "chart.bar.fill" : "square.grid.2x2")
                    }
                }
            }
        }
        if !catalog.currentFavorites.isEmpty {
            Divider()
            Button {
                catalog.openFavorites()
            } label: {
                Label("稍后看", systemImage: "bookmark")
            }
        }
    }

    func open(_ category: CatalogCategory) {
        if category.isRank {
            catalog.openRank()
        } else {
            catalog.openCategory(category)
        }
    }
}

// MARK: - 二级目录胶囊

/// 站点二级目录（地区 / 题材 / 频道…）的胶囊：网络资源与网络影院站点页共用同一套。
struct CatalogDirectoryChip: View {
    let title: String
    var tint: Color? = nil
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.white
                                    : (hovering ? Color.primary : Color.secondary))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor,
                                                      Color.accentColor.opacity(0.72)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                                .blendMode(.plusLighter)
                        }
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 2)
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0 : 0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - 海报

struct CatalogPosterCell: View {
    let source: CatalogSource
    let item: CatalogItem
    let progress: CatalogProgress?
    /// 正在把这个条目下载到图库。
    var isSaving: Bool = false
    /// 本次刷新才出现（上次缓存里没有）：右下角打「刚上架」。
    var isFresh: Bool = false
    /// 已经在「稍后看」里：左上角挂书签角标。
    var isFavorite: Bool = false
    /// 手动标记已看：没有播放进度也显示「已看」角标。
    var isMarkedWatched: Bool = false
    /// ⌘ 多选中的条目：画品牌色描边 + 勾选角标。
    var isSelected: Bool = false
    var onOpen: () -> Void
    var onOpenInBrowser: () -> Void = {}
    var onSaveVideo: () -> Void = {}
    /// ⌘ 点击切换多选。
    var onToggleSelect: () -> Void = {}
    /// 悬停进出时通知外层（用于把键盘光标跟着鼠标走）。
    var onHoverChange: ((Bool) -> Void)?
    /// 已播放过的条目用进度里的时长回填；站点没给时长时也能显示片长。
    var durationText: String? = nil
    /// 悬停 0.7 秒后才去解析流：避免扫过网格时给站点打一串请求。
    var previewTarget: (() async -> CatalogPreviewTarget?)?

    @State private var isHovering = false
    @State private var previewURL: URL?
    @State private var previewHeaders: [String: String] = [:]
    @State private var previewTask: Task<Void, Never>?
    @State private var previewHandle = VideoPreviewHandle()
    /// 正在解析流地址：悬停后先转圈，避免看起来「什么也没发生」。
    @State private var isPreparingPreview = false
    /// 「刚上架」的呼吸高亮：让新条目在整片网格里第一眼就能被扫到。
    @State private var freshPulse = false
    /// 封面主色：悬停时取一次，描边与光晕跟着封面色系走。
    @StateObject private var coverTint = CatalogCoverTint()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(1.5)
                .foregroundStyle(isHovering ? Color.primary : Color.primary.opacity(0.86))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // 固定两行高度：同一行的标题基线一致，网格不会因为长短标题参差。
                .frame(height: 36, alignment: .topLeading)
                .help(item.title)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
            onHoverChange?(hovering)
            if hovering {
                coverTint.load(source: source, urlString: item.coverURL)
                startPreview()
            } else {
                stopPreview()
            }
        }
        .onDisappear { stopPreview() }
        .onChange(of: item.id) { _, _ in stopPreview() }
        .onTapGesture {
            // ⌘ 点击加入批量选择；普通点击仍然打开详情。
            if NSEvent.modifierFlags.contains(.command) {
                withAnimation(.easeOut(duration: 0.14)) { onToggleSelect() }
            } else {
                onOpen()
            }
        }
        .contextMenu {
            CatalogPlaylistMenu(source: source, item: item)
            Button("在浏览器中打开原始页") { onOpenInBrowser() }
            Button(isSaving ? "正在保存…" : "保存视频到图库") { onSaveVideo() }
                .disabled(isSaving)
        }
    }

    // MARK: - 角标

    /// 左上角角标栈：预览、合集、稍后看、观看状态依次往下排，互不遮挡。
    var leadingBadges: some View {
        VStack(alignment: .leading, spacing: 5) {
            if previewURL != nil {
                HStack(spacing: 3) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 7, weight: .bold))
                    Text("预览")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.5), in: Capsule(style: .continuous))
                .transition(.opacity)
            }
            if isCollectionSet {
                // 精选合集索引里的卡片：和普通视频区分开。
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 7.5, weight: .bold))
                    Text("合集")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor,
                                                      Color.accentColor.opacity(0.78)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.26), lineWidth: 0.5)
                }
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
            }
            if isFavorite {
                CatalogMiniBadge(symbol: "bookmark.fill", title: "稍后看", tint: LumaBrand.cyan)
            }
            // 合集索引本身没有播放进度，不做未看 / 已看标记。
            if !isCollectionSet { watchBadge }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 本地观看状态：没记录 / 看了一半 / 看完，同一时刻只出现一个角标。
    enum WatchState {
        case unseen
        case partial(Double)
        case watched
    }

    var watchState: WatchState {
        guard let progress, progress.fraction > 0.01 else { return .unseen }
        return progress.fraction >= 0.97 ? .watched : .partial(progress.fraction)
    }

    var isWatched: Bool {
        if isMarkedWatched { return true }
        if case .watched = watchState { return true }
        return false
    }

    @ViewBuilder
    var watchBadge: some View {
        if isMarkedWatched {
            CatalogMiniBadge(symbol: "checkmark.circle.fill", title: "已看",
                             tint: LumaBrand.mint)
        } else {
            switch watchState {
            case .unseen:
                CatalogMiniBadge(symbol: "circle.dashed", title: "未看",
                                 tint: .white.opacity(0.6))
            case .partial(let fraction):
                CatalogMiniBadge(symbol: "circle.lefthalf.filled",
                                 title: "看至 \(Int((fraction * 100).rounded()))%",
                                 tint: LumaBrand.amber)
            case .watched:
                CatalogMiniBadge(symbol: "checkmark.circle.fill", title: "已看",
                                 tint: LumaBrand.mint)
            }
        }
    }

    func startPreview() {
        guard previewURL == nil, let previewTarget else { return }
        previewTask?.cancel()
        isPreparingPreview = true
        previewTask = Task { @MainActor in
            // 停留够久再解析：鼠标扫过网格时不该触发请求。
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            // 解析可能撞上并发排队或站点抖动：鼠标还停着就再试两次。
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard !Task.isCancelled else { return }
                }
                if let target = await previewTarget() {
                    guard !Task.isCancelled else { return }
                    isPreparingPreview = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        previewHeaders = target.headers
                        previewURL = target.url
                    }
                    return
                }
                guard !Task.isCancelled else { return }
            }
            isPreparingPreview = false
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
        guard previewURL != nil || !previewHeaders.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            previewURL = nil
            previewHeaders = [:]
        }
    }

    var artwork: some View {
        // 先用 Color.clear 定住 2:3 / 16:9 的版面，再把封面铺进 overlay：
        // 直接把 aspectRatio 压在 scaledToFill 的图片上，图片会按自身像素撑开，
        // 越过网格列宽后相邻卡片就会贴在一起。
        Color.clear
            .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
            .overlay {
                ZStack(alignment: .topTrailing) {
                    // 画面层（封面 / 预览流 / 暗角 / 保存遮罩）单独裁圆角；
                    // 文字与角标画在裁切外层，贴在四角时才不会被圆角吃掉一截。
                    ZStack(alignment: .topLeading) {
                        CatalogArtworkImage(source: source, urlString: item.coverURL, cornerRadius: 14)
                            // 已看过的条目压暗，和「已看」角标一起把二刷列表的噪音降下去。
                            .opacity(isWatched && !isHovering ? 0.62 : 1)

                        // 悬停预览：静音循环播放真实流，移开立即卸载解码器。
                        if let previewURL {
                            HoverVideoSurface(url: previewURL,
                                              headers: previewHeaders,
                                              handle: previewHandle) { _ in }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }

                        // 底部暗角：让集数信息在浅色封面上也读得清。
                        LinearGradient(colors: [.clear, .clear, .black.opacity(0.74)],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)

                        if isSaving {
                            ZStack {
                                Color.black.opacity(0.48)
                                VStack(spacing: 7) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                    Text("保存中")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }

                        // 观看进度条贴着底边，跟画面一起被圆角裁切才自然。
                        // 已看完整条时不再画满格进度条，改由「已看」角标说明状态。
                        if let progress, progress.fraction > 0.01, !isWatched {
                            VStack {
                                Spacer()
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.black.opacity(0.4))
                                        Capsule().fill(LumaBrand.amber)
                                            .frame(width: max(3, proxy.size.width * progress.fraction))
                                    }
                                }
                                .frame(height: 3.5)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // 左上角角标栈：预览、合集、稍后看、观看状态依次往下排，互不遮挡。
                    leadingBadges

            if isSelected {
                // 选中标记放在右上角，替代评分角标，避免两个角标叠在一起。
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 1)
                    .padding(11)
            } else if let score = scoreText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(LumaBrand.amber)
                    Text(score)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.48), in: Capsule(style: .continuous))
                .padding(11)
            }

            if isFresh {
                CatalogFreshBadge(kind: badgeKind)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
            }

            if let info = infoText {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Text(info)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // 右下角有「刚上架」时给文字让出位置，两者不再叠在一起。
                    .padding(.leading, 11)
                    .padding(.trailing, isFresh ? 80 : 11)
                    .padding(.bottom, 10)
                }
            }

            if isHovering, previewURL == nil {
                if isPreparingPreview {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.95), in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.86)))
                }
            }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderStyle,
                                  lineWidth: isHovering ? 1.8 : (isFresh ? 1.2 : 0.8))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .shadow(color: isFresh ? LumaBrand.coral.opacity(freshPulse ? 0.34 : 0.12)
                                   : .black.opacity(isHovering ? 0.28 : 0.12),
                    radius: isFresh ? (freshPulse ? 12 : 6) : (isHovering ? 16 : 8),
                    y: isHovering ? 8 : 3)
            // 悬停再补一层封面主色光晕，让卡片和画面融在一起。
            .shadow(color: isHovering && !isFresh ? hoverTint.opacity(0.28) : .clear,
                    radius: 18, y: 5)
            // 悬停只做很轻的上浮：放大太多会让相邻卡片看起来挤在一起。
            .scaleEffect(isHovering ? 1.008 : 1)
            .onAppear {
                guard isFresh, !freshPulse else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    freshPulse = true
                }
            }
    }

    /// 封面描边：悬停用封面主色 → 刚上架呼吸渐变 → 常态细描边。
    var borderStyle: AnyShapeStyle {
        if isHovering {
            // 主色还没取回来时保持中性描边，不要先闪品牌色再过渡到暗色。
            if let tint = coverTint.color {
                return AnyShapeStyle(tint.opacity(0.95))
            }
            return AnyShapeStyle(Color.primary.opacity(0.22))
        }
        if isFresh {
            return AnyShapeStyle(LumaBrand.gradient.opacity(freshPulse ? 1 : 0.5))
        }
        return AnyShapeStyle(Color.primary.opacity(0.10))
    }

    /// 悬停光晕：只在使用封面主色后才出现，取色前后视觉连续。
    var hoverTint: Color { coverTint.color ?? .clear }

    /// 精选合集索引里的条目：id 以 `set|` 开头。
    var isCollectionSet: Bool {
        item.id.hasPrefix("set|")
    }

    /// 「更新至 86 集 · 8.4 分」拆成两处展示：集数压在海报底部，评分做成右上角小胶囊。
    var remarkParts: [String] {
        item.remark
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var scoreText: String? {
        guard let raw = remarkParts.last(where: { $0.contains("分") }) else { return nil }
        let value = raw.replacingOccurrences(of: "分", with: "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    var infoText: String? {
        switch (remarkParts.first(where: { !$0.contains("分") }), durationText) {
        case let (info?, duration?): return "\(info) · \(duration)"
        case let (info?, nil): return info
        case let (nil, duration?): return duration
        default: return nil
        }
    }

    /// 备注里的集数（`更新至 10 集` / `全 12 集`）；单片返回 0。
    /// 多集条目不叫「刚上架」，改用「更新中」。
    var episodeCount: Int {
        guard let range = item.remark.range(of: "\\d+\\s*集", options: .regularExpression) else {
            return 0
        }
        let digits = item.remark[range].filter(\.isNumber)
        return Int(digits) ?? 0
    }

    /// 备注标明已完结：`全 24 集` / `已完结`。
    var isCompletedSeries: Bool {
        if item.remark.contains("完结") { return true }
        return item.remark.range(of: "全\\s*\\d+\\s*集", options: .regularExpression) != nil
    }

    /// 右下角角标：连载剧「更新中」、完结剧「已完结」、单片「刚上架」。
    var badgeKind: CatalogFreshBadge.Kind {
        guard episodeCount > 1 else { return .new }
        return isCompletedSeries ? .finished : .updating
    }
}

/// 海报小角标：图标 + 短文案，半透明黑底，压在封面上也能读清。
/// 用于「未看 / 看至 N% / 已看 / 稍后看」这些本地状态。
struct CatalogMiniBadge: View {
    let symbol: String
    let title: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2.5)
        .background(.black.opacity(0.5), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
    }
}

/// 「刚上架 / 更新中 / 已完结」角标：本次刷新才出现、上次缓存里没有的条目。
/// 单片叫「刚上架」，连载剧叫「更新中」，备注带「全 N 集」的剧叫「已完结」；黑底 + 品牌渐变描边 + 呼吸小灯。
struct CatalogFreshBadge: View {
    enum Kind {
        case new
        case updating
        case finished

        var title: String {
            switch self {
            case .new: return "刚上架"
            case .updating: return "更新中"
            case .finished: return "已完结"
            }
        }

        var symbol: String {
            switch self {
            case .new: return "sparkles"
            case .updating: return "arrow.triangle.2.circlepath"
            case .finished: return "checkmark.seal.fill"
            }
        }

        var tint: Color {
            switch self {
            case .new: return LumaBrand.amber
            case .updating: return LumaBrand.cyan
            case .finished: return LumaBrand.mint
            }
        }
    }

    var kind: Kind = .new

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(kind.tint)
            Text(kind.title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
            Circle()
                .fill(LumaBrand.mint)
                .frame(width: 3, height: 3)
                .scaleEffect(pulsing ? 1.7 : 0.7)
                .opacity(pulsing ? 0.35 : 1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(.black.opacity(0.58), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(LumaBrand.gradient, lineWidth: 1)
        }
        .shadow(color: LumaBrand.coral.opacity(0.4), radius: 7, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - 排行榜前三

struct RankPodiumCard: View {
    let source: CatalogSource
    let item: CatalogItem
    let rank: Int
    let progress: CatalogProgress?
    var durationText: String? = nil
    var isMarkedWatched: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @StateObject private var coverTint = CatalogCoverTint()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .frame(height: 170)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: item.coverURL, cornerRadius: 14)
                    }
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.66)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        rankBadge
                            .padding(11)
                    }
                    .overlay(alignment: .topTrailing) {
                        // 展台卡片只挂「已看」：名次角标已经占了左上角。
                        if isWatched {
                            CatalogMiniBadge(symbol: "checkmark.circle.fill", title: "已看",
                                             tint: LumaBrand.mint)
                                .padding(9)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress.fraction > 0.01 {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.black.opacity(0.45))
                                    Capsule().fill(LumaBrand.amber)
                                        .frame(width: max(3, proxy.size.width * progress.fraction))
                                }
                            }
                            .frame(height: 3.5)
                            .padding(.horizontal, 9)
                            .padding(.bottom, 7)
                        }
                    }
                    .overlay {
                        if hovering {
                            ZStack {
                                Color.black.opacity(0.16)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.82))
                                    .frame(width: 36, height: 36)
                                    .background(.white.opacity(0.95), in: Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hovering ? (coverTint.color.map { $0.opacity(0.9) }
                                                    ?? Color.primary.opacity(0.22))
                                                  : Color.primary.opacity(0.10),
                                          lineWidth: hovering ? 1.7 : 0.8)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.26 : 0.12),
                            radius: hovering ? 16 : 8, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.008 : 1)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)

                HStack(spacing: 5) {
                    Circle()
                        .fill(source.kind.sidebarTint)
                        .frame(width: 4.5, height: 4.5)
                    Text(source.name)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if let info = podiumInfoText {
                        Text(info)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside { coverTint.load(source: source, urlString: item.coverURL) }
        }
        .help(item.title)
    }

    /// 备注与进度时长拼成一行；两者都没有时整行留空，只显示来源。
    var podiumInfoText: String? {
        let parts = [item.remark, durationText ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isWatched: Bool {
        if isMarkedWatched { return true }
        guard let progress, progress.fraction > 0.01 else { return false }
        return progress.fraction >= 0.97
    }

    var rankBadge: some View {
        Text("\(rank)")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rank == 1
                          ? AnyShapeStyle(LinearGradient(colors: [LumaBrand.amber,
                                                                  LumaBrand.amber.opacity(0.7)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.black.opacity(0.52)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.24), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.24), radius: 4, y: 1)
    }
}

// MARK: - 封面

struct CatalogArtworkImage: View {
    enum Quality {
        /// 网格 / 轨道：只读缓存的 320px 缩略图，不再二次拉全尺寸。
        case thumbnail
        /// 详情页大图：需要全尺寸封面。
        case full
    }

    let source: CatalogSource
    let urlString: String
    var cornerRadius: CGFloat = 10
    /// 预览大图时用 fit（完整显示），网格封面用 fill（铺满裁切）。
    var fit: Bool = false
    var quality: Quality = .thumbnail

    @State private var image: NSImage?

    var quickKey: String {
        CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: true).path
    }

    var fullKey: String {
        CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: false).path
    }

    init(source: CatalogSource, urlString: String,
         cornerRadius: CGFloat = 10, fit: Bool = false,
         quality: Quality = .thumbnail) {
        self.source = source
        self.urlString = urlString
        self.cornerRadius = cornerRadius
        self.fit = fit
        self.quality = quality
        // 同一会话里切来切去直接命中内存，第一帧就是封面，不再闪占位图。
        guard !urlString.isEmpty else {
            _image = State(initialValue: nil)
            return
        }
        let quick = CatalogArtworkMemory.shared.image(
            for: CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: true).path)
        let full = quality == .full
            ? CatalogArtworkMemory.shared.image(
                for: CatalogPaths.artworkURL(sourceID: source.id, urlString: urlString, quick: false).path)
            : nil
        _image = State(initialValue: full ?? quick)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.17),
                                    Color(red: 0.32, green: 0.25, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                if fit {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    // scaledToFill 会按原图比例把自身撑得比卡片还宽；
                    // 直接放进 ZStack 会让整个封面层超出网格列宽（相邻卡片吃掉间距、
                    // 四角角标也被推到卡片外）。用 Color.clear 收住尺寸再画到 overlay 上。
                    Color.clear
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                }
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            guard !urlString.isEmpty else { return }
            // 1) 缩略图：内存 → 磁盘/网络。网格到这一步就够，不再等大图。
            if let cached = CatalogArtworkMemory.shared.image(for: quickKey) {
                image = cached
            } else if let quick = await CatalogArtworkCache.shared.image(source: source,
                                                                         urlString: urlString,
                                                                         quick: true) {
                CatalogArtworkMemory.shared.store(quick, for: quickKey)
                withAnimation(.easeOut(duration: 0.16)) { image = quick }
            }
            // 2) 详情页才补全尺寸；网格保持缩略图，省一次 900px 解码与替换。
            guard quality == .full else { return }
            if let cached = CatalogArtworkMemory.shared.image(for: fullKey) {
                image = cached
            } else if let full = await CatalogArtworkCache.shared.image(source: source,
                                                                        urlString: urlString,
                                                                        quick: false) {
                CatalogArtworkMemory.shared.store(full, for: fullKey)
                withAnimation(.easeOut(duration: 0.16)) { image = full }
            }
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let value = Int(seconds.rounded())
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
