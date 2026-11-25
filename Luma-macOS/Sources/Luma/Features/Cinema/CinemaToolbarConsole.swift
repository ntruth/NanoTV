import SwiftUI
import AppKit

// MARK: - 影院顶栏控制台（拟物化放映机操作台）

/// 影院页的整条控制台：片盒铭牌、机械选片开关、放映开关与调校钮。
/// 整条装在窗口工具栏的同一行里（和侧边栏开关同一行），铺满内容区宽度的 95%：
/// 左侧是铭牌 / 返回与浏览控件，右侧是搜索与动作键，同一条面板的两端。
/// 深色拉丝金属 + 琥珀指示灯 + 刻字标签，模拟高端放映机的操作面板。
struct CinemaToolbarConsole: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKeys.selectedTab) private var settingsTab: SettingsTab = .general

    @State private var hoveredTab: CinemaTab?
    @State private var hoveredTypeKey = false
    @State private var hoveredScrape = false
    @State private var hoveredMore = false
    @State private var hoveredAssistant = false
    @State private var hoveredAutoMatch = false
    @State private var showStatus = false
    @State private var showFilter = false
    @State private var showTypePanel = false

    private var scope: CinemaScope {
        if case .cloudCinema(let id) = store.sidebarItem { return .mount(id) }
        return .local
    }

    private var scopeEntries: [CinemaEntry] {
        Array(store.cinemaEntries(for: scope).values)
    }

    private var matchedCount: Int {
        scopeEntries.filter { $0.matched }.count
    }

    private var unmatchedCount: Int {
        scopeEntries.count - matchedCount
    }

    private var mountName: String? {
        if case .mount(let id) = scope,
           let name = store.cloudMounts.first(where: { $0.id == id })?.name {
            return name
        }
        return nil
    }

    private var isScraping: Bool {
        store.cinemaScrapeRunning && store.cinemaScrapeScope == scope
    }

    // MARK: 配色（浅色 / 深色）

    /// 深色是放映机黑金面板；浅色换成香槟银面板，避免在白底工具栏上压一块黑砖。
    private var isDark: Bool { scheme == .dark }

    private var titleColor: Color { isDark ? .white : Color(white: 0.14) }
    private var secondaryText: Color { isDark ? Color.white.opacity(0.70) : Color(white: 0.34) }
    private var tertiaryText: Color { isDark ? Color.white.opacity(0.52) : Color(white: 0.46) }
    private var faintText: Color { isDark ? Color.white.opacity(0.32) : Color(white: 0.55) }

    /// 主强调：深色用亮琥珀，浅色用更深的青铜，保证白底上的对比度。
    private var accentText: Color {
        isDark ? LumaBrand.amber : Color(red: 0.62, green: 0.41, blue: 0.08)
    }

    /// 指示灯：浅色下用更深的金，不再发白。
    private var ledColor: Color {
        isDark ? LumaBrand.amber : Color(red: 0.88, green: 0.60, blue: 0.16)
    }

    private var unmatchedColor: Color {
        isDark ? LumaBrand.coral : Color(red: 0.80, green: 0.34, blue: 0.24)
    }

    private var assistantTint: Color {
        isDark ? LumaBrand.violet : Color(red: 0.44, green: 0.31, blue: 0.82)
    }

    private var plateFill: LinearGradient {
        isDark
            ? LinearGradient(colors: [Color(white: 0.20), Color(white: 0.115), Color(white: 0.065)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.99, green: 0.982, blue: 0.965),
                                      Color(red: 0.955, green: 0.945, blue: 0.925),
                                      Color(red: 0.915, green: 0.900, blue: 0.872)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var plateStroke: LinearGradient {
        isDark
            ? LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02), .black.opacity(0.40)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.30), .black.opacity(0.16)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var topHighlight: Color { isDark ? Color.white.opacity(0.14) : Color.white.opacity(0.90) }
    private var plateShadow: Color { isDark ? Color.black.opacity(0.32) : Color.black.opacity(0.12) }

    private var channelFill: Color { isDark ? Color.black.opacity(0.34) : Color.black.opacity(0.05) }

    private var channelStroke: LinearGradient {
        isDark
            ? LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.07)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.black.opacity(0.14), .white.opacity(0.85)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var keyFill: LinearGradient {
        isDark
            ? LinearGradient(colors: [Color(white: 0.24), Color(white: 0.10)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(white: 0.995), Color(white: 0.925)],
                             startPoint: .top, endPoint: .bottom)
    }

    private var keyStroke: LinearGradient {
        isDark
            ? LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.45)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.white.opacity(0.95), .black.opacity(0.16)],
                             startPoint: .top, endPoint: .bottom)
    }

    private func tabIconColor(active: Bool, hovered: Bool) -> Color {
        if active { return accentText }
        return isDark ? Color.white.opacity(hovered ? 0.90 : 0.55)
                      : Color(white: 0.40).opacity(hovered ? 1 : 0.82)
    }

    private func tabTextColor(active: Bool, hovered: Bool) -> Color {
        if active {
            return isDark ? Color.white : Color(red: 0.36, green: 0.25, blue: 0.07)
        }
        return isDark ? Color.white.opacity(hovered ? 0.88 : 0.60)
                      : Color(white: 0.30).opacity(hovered ? 1 : 0.85)
    }

    /// 当前是否启用了年份 / 类型 / 分辨率 / 观看状态 / 智能筛选。
    private var hasFilter: Bool {
        !store.cinemaYears.isEmpty
            || !store.cinemaGenres.isEmpty
            || !store.cinemaKindFilters.isEmpty
            || !store.cinemaCountries.isEmpty
            || !store.cinemaLanguages.isEmpty
            || !store.cinemaRuntimeFilters.isEmpty
            || !store.cinemaRatingFilters.isEmpty
            || !store.cinemaResolutions.isEmpty
            || !store.cinemaSpecFilters.isEmpty
            || !store.cinemaWatchFilters.isEmpty
            || store.cinemaSmartHighRated
            || store.cinemaSmartRecent
            || store.cinemaFavoritesOnly
            || store.cinemaActiveListID != nil
    }

    private var filterCount: Int {
        var count = 0
        if !store.cinemaYears.isEmpty { count += 1 }
        if !store.cinemaGenres.isEmpty { count += 1 }
        if !store.cinemaKindFilters.isEmpty { count += 1 }
        if !store.cinemaCountries.isEmpty { count += 1 }
        if !store.cinemaLanguages.isEmpty { count += 1 }
        if !store.cinemaRuntimeFilters.isEmpty { count += 1 }
        if !store.cinemaRatingFilters.isEmpty { count += 1 }
        if !store.cinemaResolutions.isEmpty { count += 1 }
        if !store.cinemaSpecFilters.isEmpty { count += 1 }
        if !store.cinemaWatchFilters.isEmpty { count += 1 }
        if store.cinemaSmartHighRated { count += 1 }
        if store.cinemaSmartRecent { count += 1 }
        if store.cinemaFavoritesOnly { count += 1 }
        if store.cinemaActiveListID != nil { count += 1 }
        return count
    }

    private var filterTitle: String {
        if filterCount > 1 { return "筛选 \(filterCount)" }
        var parts: [String] = []
        if let first = store.cinemaYears.sorted(by: >).first {
            parts.append(store.cinemaYears.count == 1 ? "\(first) 年" : "\(first) 年+\(store.cinemaYears.count - 1)")
        }
        if let first = store.cinemaGenres.sorted().first {
            parts.append(store.cinemaGenres.count == 1 ? first : "\(first)+\(store.cinemaGenres.count - 1)")
        }
        if let first = store.cinemaKindFilters.map(\.title).sorted().first {
            parts.append(store.cinemaKindFilters.count == 1 ? first : "\(first)+\(store.cinemaKindFilters.count - 1)")
        }
        if let first = store.cinemaCountries.sorted().first {
            parts.append(store.cinemaCountries.count == 1 ? first : "\(first)+\(store.cinemaCountries.count - 1)")
        }
        if let first = store.cinemaLanguages.sorted().first {
            let title = CinemaLanguageCatalog.title(first)
            parts.append(store.cinemaLanguages.count == 1 ? title : "\(title)+\(store.cinemaLanguages.count - 1)")
        }
        if let first = store.cinemaRuntimeFilters.map(\.title).sorted().first {
            parts.append(store.cinemaRuntimeFilters.count == 1 ? first : "\(first)+\(store.cinemaRuntimeFilters.count - 1)")
        }
        if let first = store.cinemaRatingFilters.map(\.title).sorted().first {
            parts.append(store.cinemaRatingFilters.count == 1 ? first : "\(first)+\(store.cinemaRatingFilters.count - 1)")
        }
        if let first = store.cinemaResolutions.map(\.title).sorted().first {
            parts.append(store.cinemaResolutions.count == 1 ? first : "\(first)+\(store.cinemaResolutions.count - 1)")
        }
        if let first = store.cinemaSpecFilters.map(\.title).sorted().first {
            parts.append(store.cinemaSpecFilters.count == 1 ? first : "\(first)+\(store.cinemaSpecFilters.count - 1)")
        }
        if let first = store.cinemaWatchFilters.map(\.title).sorted().first {
            parts.append(store.cinemaWatchFilters.count == 1 ? first : "\(first)+\(store.cinemaWatchFilters.count - 1)")
        }
        if store.cinemaSmartHighRated { parts.append("高分") }
        if store.cinemaSmartRecent { parts.append("最近") }
        if store.cinemaFavoritesOnly { parts.append("收藏") }
        if let list = store.cinemaList(store.cinemaActiveListID) { parts.append(list.name) }
        return parts.joined(separator: "·")
    }

    /// 一整条面板：所有操作都排在同一行里，右侧动作键直接接在浏览控件后面。
    /// 面板宽度由标题栏托管视图给足（能吃多宽就多宽），窗口变窄时内部操作横向滚动。
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                leadingGroup
                engravedSeparator
                trailingGroup
            }
            .padding(.horizontal, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32)
        .padding(.vertical, 3)
        .background { consolePlate }
    }

    /// 标题栏托管时没有 SwiftUI 场景，打开设置要用宿主传进来的动作。
    var openSettingsOverride: (() -> Void)?

    init(openSettingsOverride: (() -> Void)? = nil) {
        self.openSettingsOverride = openSettingsOverride
    }

    private func presentCinemaSettings() {
        settingsTab = .cinema
        if let openSettingsOverride { openSettingsOverride() } else { openSettings() }
    }

    /// 左段：详情页只留一枚「返回」；文件夹钻取时「返回」和分段并存，
    /// 既能退回上一级目录，也能直接切到其它分段离开文件夹视图。
    @ViewBuilder
    private var leadingGroup: some View {
        if store.cinemaDetailOpen {
            detailBackKey
        } else {
            if store.cinemaFolderDepth > 0 {
                detailBackKey
                engravedSeparator
            } else {
                identity
                engravedSeparator
            }
            tabs
            // 文件夹分段按目录组织，视图 / 筛选 / 排序对它不生效，隐藏避免误导。
            if store.cinemaTab != .folder {
                browsingControls
            }
        }
    }

    /// 右段：搜索、家长控制、智能整理、助手、刮削与「更多」。
    @ViewBuilder
    private var trailingGroup: some View {
        searchKey
        if store.cinemaParentalEnabled {
            parentalKey
        }
        autoMatchKey
        assistantKey
        scrapeKey
        moreMenu
    }

    /// 视图 / 筛选 / 排序：平铺在顶栏上，清单与记录类入口收进右侧「更多」。
    @ViewBuilder
    private var browsingControls: some View {
        viewSwitch
        engravedSeparator
        filterMenu
        sortMenu
    }

    /// 详情 / 文件夹顶栏的返回键：和刻字标签同一套金属底，点一下或按 Esc 回上一层。
    private var detailBackKey: some View {
        Button {
            if store.cinemaDetailOpen {
                store.cinemaDetailCloseTick += 1
            } else if store.cinemaFolderDepth > 0 {
                store.cinemaFolderCloseTick += 1
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9.5, weight: .bold))
                Text("返回")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(accentText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(ledColor.opacity(isDark ? 0.12 : 0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(ledColor.opacity(0.36), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .keyboardShortcut(.cancelAction)
        .help(store.cinemaDetailOpen ? "返回影院 (Esc)" : "返回上一级目录 (Esc)")
    }

    // MARK: 片盒铭牌

    /// 铭牌两行排版：第一行「影院 + 网盘名」，第二行「已识别 / 未识别」，宽度随内容自适应。
    private var identity: some View {
        Button {
            showStatus.toggle()
        } label: {
            HStack(spacing: 8) {
                filmBadge

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text("影院")
                            .font(.system(size: 13, weight: .semibold, design: .serif))
                            .foregroundStyle(titleColor)
                        if let mountName {
                            Text(mountName)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(accentText.opacity(0.90))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    statusLine
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(faintText)
                    .rotationEffect(.degrees(showStatus ? 180 : 0))
            }
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 浮层按内容自适应宽度，不再跟铭牌强行同宽。
        .popover(isPresented: $showStatus, arrowEdge: .bottom) {
            statusPopover
        }
        .help("放映室状态与数据源")
    }

    /// 已识别 / 未识别：只留统计，不再重复网盘名（网盘名已独占一行）。
    private var statusLine: some View {
        HStack(spacing: 5) {
            if scopeEntries.isEmpty {
                Text("未刮削")
                    .foregroundStyle(tertiaryText)
            } else {
                statusDot(ledColor)
                Text("\(matchedCount) 已识别")
                    .foregroundStyle(secondaryText)
                if unmatchedCount > 0 {
                    statusDot(unmatchedColor)
                    Text("\(unmatchedCount) 未识别")
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: 196, alignment: .leading)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 2.5, height: 2.5)
    }

    /// 小片盒：金属块 + 琥珀灯。
    private var filmBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isDark
                      ? LinearGradient(colors: [Color(white: 0.27), Color(white: 0.11)],
                                       startPoint: .top, endPoint: .bottom)
                      : LinearGradient(colors: [Color(white: 1.0), Color(white: 0.90)],
                                       startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(accentText.opacity(isDark ? 0.52 : 0.45), lineWidth: 0.7)
            Image(systemName: "film.stack")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accentText)
        }
        .frame(width: 21, height: 21)
        .shadow(color: ledColor.opacity(isDark ? 0.25 : 0.18), radius: 4)
    }

    // MARK: 机械选片开关

    private var tabs: some View {
        HStack(spacing: 2) {
            channelSegment(.all)
            channelSegment(.movies)
            channelSegment(.shows)
            typeSlot
            channelSegment(.folder)
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(channelFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(channelStroke, lineWidth: 0.7)
                }
        }
        .padding(.horizontal, 8)
    }

    /// 主频道：全部 / 电影 / 电视剧 / 文件夹。切换频道时清掉内容类型筛选。
    private func channelSegment(_ item: CinemaTab) -> some View {
        let active = store.cinemaTab == item && !(item == .all && store.cinemaTypeFilterID != nil)
        let hovered = hoveredTab == item
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                store.cinemaTypeFilterID = nil
                store.cinemaTab = item
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tabIconColor(active: active, hovered: hovered))
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tabTextColor(active: active, hovered: hovered))
                    .shadow(color: ledColor.opacity(active ? (isDark ? 0.55 : 0.16) : 0), radius: 4)
            }
            .frame(width: segmentWidth(item), height: 28)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(segmentFill(active: active, hovered: hovered))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(active ? ledColor.opacity(isDark ? 0.34 : 0.42) : Color.clear,
                                  lineWidth: 0.7)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(active ? ledColor : .clear)
                    .frame(width: 18, height: 1.6)
                    .padding(.bottom, 2.5)
                    .shadow(color: ledColor.opacity(active ? 0.75 : 0), radius: 3)
            }
            .shadow(color: ledColor.opacity(active ? 0.14 : 0), radius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredTab = item
            } else if hoveredTab == item {
                hoveredTab = nil
            }
        }
        .help(item.title)
    }

    /// 类型占位：未选择时只留一枚小箭头，不占文字位；选中后这里直接显示选中的类型。
    private var typeSlot: some View {
        let bucket = selectedTypeBucket
        let active = bucket != nil || showTypePanel
        return Button {
            showTypePanel.toggle()
        } label: {
            HStack(spacing: 5) {
                if let bucket {
                    Image(systemName: bucket.type.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(accentText)
                    Text(bucket.type.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accentText)
                        .lineLimit(1)
                        .shadow(color: ledColor.opacity(isDark ? 0.55 : 0.16), radius: 4)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(hoveredTypeKey || active
                                     ? accentText
                                     : (isDark ? Color.white.opacity(0.46) : Color(white: 0.40)))
                    .rotationEffect(.degrees(showTypePanel ? 180 : 0))
                    .shadow(color: ledColor.opacity(hoveredTypeKey || active ? 0.5 : 0), radius: 3)
            }
            .frame(height: 28)
            .padding(.horizontal, bucket == nil ? 7 : 9)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(segmentFill(active: active, hovered: hoveredTypeKey))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(active ? ledColor.opacity(isDark ? 0.34 : 0.42) : Color.clear,
                                  lineWidth: 0.7)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(active ? ledColor : .clear)
                    .frame(width: 14, height: 1.6)
                    .padding(.bottom, 2.5)
                    .shadow(color: ledColor.opacity(active ? 0.75 : 0), radius: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(.easeOut(duration: 0.16), value: showTypePanel)
        .onHover { hoveredTypeKey = $0 }
        .help(bucket.map { "类型：\($0.type.title) · 点按切换" } ?? "按类型浏览")
        .popover(isPresented: $showTypePanel, arrowEdge: .bottom) {
            CinemaTypePanel(scope: scope) {
                showTypePanel = false
            }
            .environmentObject(store)
        }
    }

    private var typeBuckets: [CinemaTypeBucket] {
        store.cinemaAggregate(for: scope).types
    }

    /// 当前选中的类型；类型列表里找不到时仍按 id 还原一个，保证占位处显示正确。
    private var selectedTypeBucket: CinemaTypeBucket? {
        guard let id = store.cinemaTypeFilterID else { return nil }
        return typeBuckets.first { $0.id == id }
            ?? CinemaTypeBucket(type: .descriptor(id: id), count: 0)
    }

    /// 窄窗口下主导航宽度：文字始终展示，只压缩留白。
    private func segmentWidth(_ item: CinemaTab) -> CGFloat {
        switch item {
        case .all: return 56
        case .movies: return 52
        case .shows: return 70
        case .folder: return 70
        }
    }

    private func segmentFill(active: Bool, hovered: Bool) -> LinearGradient {
        if active {
            return LinearGradient(colors: [ledColor.opacity(isDark ? 0.20 : 0.24),
                                           ledColor.opacity(isDark ? 0.05 : 0.08)],
                                  startPoint: .top, endPoint: .bottom)
        }
        let hoverBase: Double = isDark ? 0.09 : 0.05
        return LinearGradient(colors: [Color.primary.opacity(hovered ? hoverBase : 0),
                                       Color.primary.opacity(hovered ? hoverBase * 0.4 : 0)],
                              startPoint: .top, endPoint: .bottom)
    }

    // MARK: 继续播放

    /// 视图切换：直接写出「书架 / 海报墙 / 卡片 / 列表」，不再只给一排图标。
    private var viewSwitch: some View {
        HStack(spacing: 2) {
            ForEach(CinemaViewMode.allCases) { mode in
                let active = store.cinemaViewMode == mode
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        store.cinemaViewMode = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(active
                                         ? accentText
                                         : (isDark ? Color.white.opacity(0.58) : Color(white: 0.36)))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(active ? ledColor.opacity(isDark ? 0.16 : 0.18) : .clear)
                        }
                        .overlay {
                            if active {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(ledColor.opacity(0.34), lineWidth: 0.6)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isDark ? Color.white.opacity(0.04) : Color.white.opacity(0.50))
        }
        .padding(.horizontal, 6)
    }

    // MARK: 筛选 / 排序

    private var searchKey: some View {
        Button {
            store.cinemaSearchVisible = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDark ? Color.white.opacity(0.60) : Color(white: 0.34))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.10),
                                      lineWidth: 0.7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .keyboardShortcut("f", modifiers: .command)
        .help("搜索影院（⌘F）")
    }

    /// 顶栏小按键的统一外观。
    private func iconKey(_ icon: String,
                         help: String,
                         active: Bool = false,
                         showsDot: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active
                                 ? accentText
                                 : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active
                              ? ledColor.opacity(isDark ? 0.12 : 0.16)
                              : (isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(active ? ledColor.opacity(0.36)
                                             : (isDark ? Color.white.opacity(0.09)
                                                       : Color.black.opacity(0.10)),
                                      lineWidth: 0.7)
                }
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle()
                            .fill(LumaBrand.coral)
                            .frame(width: 5, height: 5)
                            .offset(x: 1.5, y: -1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(help)
    }

    private var parentalKey: some View {
        let locked = store.cinemaParentalLocked
        return iconKey(locked ? "lock.fill" : "lock.open",
                       help: locked ? "家长控制已启用 · 点击输入 PIN" : "家长控制已解锁 · 点击重新上锁",
                       active: locked) {
            if locked {
                store.cinemaPINPromptVisible = true
            } else {
                store.lockCinemaParental()
            }
        }
    }

    private var filterMenu: some View {
        Button {
            showFilter.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                Text(hasFilter ? filterTitle : "筛选")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(hasFilter ? accentText
                                       : (isDark ? Color.white.opacity(0.60) : Color(white: 0.34)))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hasFilter ? ledColor.opacity(isDark ? 0.10 : 0.14)
                                    : (isDark ? Color.white.opacity(0.035)
                                              : Color.white.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(hasFilter ? ledColor.opacity(0.36)
                                            : (isDark ? Color.white.opacity(0.09)
                                                      : Color.black.opacity(0.10)),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, 8)
        .help("按内容、年份、类型、地区、语言、分辨率、规格、片长、评分与观看状态筛选")
        .popover(isPresented: $showFilter, arrowEdge: .bottom) {
            CinemaFilterPanel(scope: scope) {
                showFilter = false
            }
            .environmentObject(store)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CinemaSort.allCases) { option in
                Button {
                    store.cinemaSort = option
                } label: {
                    if store.cinemaSort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(store.cinemaSort.shortTitle)
                    .font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
            }
            .foregroundStyle(isDark ? Color.white.opacity(0.60) : Color(white: 0.34))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.10),
                                  lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("排序：\(store.cinemaSort.title)")
    }

    // MARK: 智能助手

    /// 一键智能整理：把当前影院交给助手，由模型按目录逐部匹配电影 / 剧集与季集。
    private var autoMatchKey: some View {
        let active = hoveredAutoMatch || store.aiIsResponding
        return Button {
            store.presentCinemaAutoMatch()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(keyFill)
                    .brightness(hoveredAutoMatch ? (isDark ? 0.05 : 0.02) : 0)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(keyStroke, lineWidth: 0.7)
                Image(systemName: "bolt.badge.automatic")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(active
                                     ? ledColor
                                     : (isDark ? Color.white.opacity(0.66) : Color(white: 0.40)))
            }
            .frame(width: 26, height: 26)
            .shadow(color: ledColor.opacity(active ? 0.35 : 0), radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hoveredAutoMatch = $0 }
        .padding(.trailing, 4)
        .help("一键智能整理：让助手按目录树逐部匹配电影 / 剧集，季与集自动对应（先授权后写入）")
        .accessibilityLabel("一键智能整理")
    }

    private var assistantKey: some View {
        Button {
            store.showAIAssistant = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(keyFill)
                    .brightness(hoveredAssistant ? (isDark ? 0.05 : 0.02) : 0)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(keyStroke, lineWidth: 0.7)
                Image(systemName: "sparkles")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hoveredAssistant
                                     ? assistantTint
                                     : (isDark ? Color.white.opacity(0.66) : Color(white: 0.40)))
            }
            .frame(width: 26, height: 26)
            .shadow(color: assistantTint.opacity(hoveredAssistant ? 0.35 : 0), radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hoveredAssistant = $0 }
        .padding(.trailing, 7)
        .help("智能助手：用自然语言查找、整理图库（写操作会先确认）")
        .accessibilityLabel("智能助手")
    }

    // MARK: 刮削按钮

    /// 悬停才算「点亮」：静止时是一枚黄铜暗键，和整条面板融为一体。
    private var scrapeHot: Bool { hoveredScrape && !isScraping }

    private var scrapeKey: some View {
        Button {
            if isScraping {
                store.cancelCinemaScrape()
            } else {
                store.startCinemaScrape(for: scope)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isScraping ? "stop.circle.fill" : "wand.and.stars")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(isScraping ? "取消" : "刮削")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(scrapeHot ? Color.black.opacity(0.88) : accentText)
            .padding(.horizontal, 13)
            .frame(height: 26)
            .background {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(scrapeFill)
                    if isScraping {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ledColor.opacity(0.85))
                            .frame(height: 1.6)
                            .padding(.horizontal, 5)
                            .padding(.bottom, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaleEffect(x: max(0.02, store.cinemaScrapeProgress), anchor: .leading)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(scrapeHot ? ledColor.opacity(0.85)
                                            : ledColor.opacity(isDark ? 0.30 : 0.38),
                                  lineWidth: 0.8)
            }
            .shadow(color: ledColor.opacity(scrapeHot ? 0.18 : 0), radius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredScrape = $0 }
        .help(isScraping
              ? "取消刮削（已完成的结果会保留）"
              : "刮削这个链接下的视频")
        .contextMenu {
            Button("重新刮削全部") {
                store.startCinemaScrape(for: scope, force: true)
            }
        }
    }

    private var scrapeFill: LinearGradient {
        if scrapeHot {
            return LinearGradient(colors: [LumaBrand.amber, LumaBrand.coral],
                                  startPoint: .top, endPoint: .bottom)
        }
        if isScraping {
            return isDark
                ? LinearGradient(colors: [Color(red: 0.22, green: 0.18, blue: 0.11),
                                          Color(red: 0.10, green: 0.085, blue: 0.06)],
                                 startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(red: 0.975, green: 0.935, blue: 0.855),
                                          Color(red: 0.925, green: 0.865, blue: 0.755)],
                                 startPoint: .top, endPoint: .bottom)
        }
        return isDark
            ? LinearGradient(colors: [Color(red: 0.19, green: 0.16, blue: 0.11),
                                      Color(red: 0.09, green: 0.08, blue: 0.06)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.992, green: 0.968, blue: 0.910),
                                      Color(red: 0.950, green: 0.912, blue: 0.820)],
                             startPoint: .top, endPoint: .bottom)
    }

    // MARK: 更多（清单 / 记录 / 通知 / 设置）

    /// 右侧「更多」：清单筛选与记录类入口收进一个带图标的菜单，设置也从这里进。
    /// 按键带未读角标，通知收起来之后不会丢掉提示。
    private var moreMenu: some View {
        let unread = store.cinemaUnreadNotificationCount
        let favoriteCount = store.cinemaUserStates.values.filter(\.favorite).count
        let listsActive = store.cinemaFavoritesOnly || store.cinemaActiveListID != nil
        let hot = hoveredMore || unread > 0 || listsActive
        return Menu {
            Button {
                store.cinemaFavoritesOnly.toggle()
                store.cinemaActiveListID = nil
            } label: {
                Label(store.cinemaFavoritesOnly ? "取消收藏筛选（\(favoriteCount)）" : "收藏（\(favoriteCount)）",
                      systemImage: store.cinemaFavoritesOnly ? "heart.fill" : "heart")
            }
            if store.cinemaLists.isEmpty {
                Text("还没有自定义清单")
            } else {
                ForEach(store.cinemaLists) { list in
                    Button {
                        store.cinemaActiveListID = list.id
                        store.cinemaFavoritesOnly = false
                    } label: {
                        Label("\(list.name)（\(list.itemIDs.count)）", systemImage: "list.bullet")
                    }
                }
            }
            if listsActive {
                Button {
                    store.cinemaActiveListID = nil
                    store.cinemaFavoritesOnly = false
                } label: {
                    Label("清除清单筛选", systemImage: "xmark.circle")
                }
            }
            Button { store.cinemaNewListVisible = true } label: {
                Label("新建清单…", systemImage: "plus")
            }

            Divider()

            Button { store.cinemaHistoryVisible = true } label: {
                Label("观看记录", systemImage: "clock.arrow.circlepath")
            }
            Button { store.cinemaNotificationsVisible = true } label: {
                Label(unread > 0 ? "通知中心 · \(unread) 条未读" : "通知中心",
                      systemImage: unread > 0 ? "bell.badge" : "bell")
            }

            Divider()

            Button {
                presentCinemaSettings()
            } label: {
                Label("影院设置…", systemImage: "gearshape")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(keyFill)
                Circle()
                    .strokeBorder(keyStroke, lineWidth: 0.8)
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hot
                                     ? accentText
                                     : (isDark ? Color.white.opacity(0.58) : Color(white: 0.42)))
            }
            .frame(width: 24, height: 24)
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text("\(min(unread, 99))")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(isDark ? Color.black.opacity(0.85) : .white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(Capsule().fill(ledColor))
                        .offset(x: 4, y: -3)
                }
            }
            .shadow(color: ledColor.opacity(hot && unread > 0 ? 0.35 : 0), radius: 5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hoveredMore = $0 }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .help("更多：清单 / 观看记录 / 通知中心 / 影院设置")
    }

    // MARK: 面板质感

    private var engravedSeparator: some View {
        Rectangle()
            .fill(isDark
                  ? LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.12), .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [.white.opacity(0.85), .black.opacity(0.16), .white.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
            .frame(width: 0.8, height: 17)
    }

    /// 深色是黑金放映面板，浅色是香槟银面板：顶部高光、左侧放映灯、两端螺丝与一条克制的底沿灯带。
    private var consolePlate: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(plateFill)

            // 左侧放映灯：把铭牌一侧微微照亮，而不是整条面板泛黄。
            Ellipse()
                .fill(RadialGradient(colors: [ledColor.opacity(isDark ? 0.10 : 0.14), .clear],
                                     center: .center, startRadius: 1, endRadius: 120))
                .frame(width: 260, height: 36)
                .blur(radius: 14)
                .offset(x: -140)

            // 顶部内高光。
            VStack {
                LinearGradient(colors: [topHighlight, .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 1.2)
                Spacer()
            }

            // 底沿灯带：只在中间淡淡亮起，不做整条跑马灯。
            VStack {
                Spacer()
                LinearGradient(colors: [ledColor.opacity(isDark ? 0.30 : 0.35),
                                        unmatchedColor.opacity(isDark ? 0.12 : 0.15),
                                        .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 0.8)
                    .padding(.horizontal, 18)
            }

            HStack {
                screw
                Spacer()
                screw
            }
            .padding(.horizontal, 4)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(plateStroke, lineWidth: 0.8)
        }
        .shadow(color: plateShadow, radius: 7, y: 3)
    }

    private var screw: some View {
        Circle()
            .fill(isDark
                  ? LinearGradient(colors: [.white.opacity(0.30), .black.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                  : LinearGradient(colors: [.white.opacity(0.95), .black.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 2.6, height: 2.6)
    }

    // MARK: 状态详情

    private var statusPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "film.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentText)
                Text("放映室")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                Text("CINEMA")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(settings.cinemaProvider.title) 优先")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(LinearGradient(colors: [ledColor.opacity(0.6), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            VStack(spacing: 7) {
                if let mountName {
                    popoverRow("资料库", mountName)
                }
                popoverRow("已识别", "\(matchedCount) 部")
                popoverRow("未识别", "\(unmatchedCount) 部")
                popoverRow("影片总数", "\(scopeEntries.count) 部")
            }

            if isScraping {
                HStack(spacing: 8) {
                    ProgressView(value: store.cinemaScrapeProgress)
                        .controlSize(.small)
                    Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    addSourceButton
                    Spacer(minLength: 0)
                    rescrapeButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    addSourceButton
                    rescrapeButton
                }
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("影院设置") {
                    showStatus = false
                    presentCinemaSettings()
                }
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private var addSourceButton: some View {
        // 文档约定 F5：铭牌浮层给「添加片源」这一项主行动。
        Button {
            showStatus = false
            store.presentCloudWizard()
        } label: {
            Label("添加片源", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
    }

    private var rescrapeButton: some View {
        Button("重新刮削全部") {
            showStatus = false
            store.startCinemaScrape(for: scope, force: true)
        }
        .disabled(isScraping)
    }

    private func popoverRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 筛选面板

/// 筛选项流式布局：按标签实际宽度排版，一行放不下就换行。
/// 不用等宽网格，像「1080P / 2K」「杜比全景声」这种长标签也能完整显示、不被截断。
private struct CinemaFilterFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                width = max(width, lineWidth)
                height += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct CinemaFilterPanel: View {
    let scope: CinemaScope
    let onClose: () -> Void

    @EnvironmentObject private var store: LibraryStore

    private var matchedEntries: [CinemaEntry] {
        store.cinemaEntries(for: scope).values.filter { $0.matched }
    }

    /// 具体年份，而不是「2020s」这种年代区间。
    private var years: [Int] {
        Set(matchedEntries.compactMap(\.year)).sorted(by: >)
    }

    // 以下选项全部从当前影院的刮削结果聚合：库里没有的档位不出现。

    private var kinds: [CinemaMediaKind] {
        let present = Set(matchedEntries.map(\.kind))
        return CinemaMediaKind.allCases.filter { present.contains($0) }
    }

    private var resolutions: [CinemaResolutionFilter] {
        CinemaResolutionFilter.allCases.filter { option in
            matchedEntries.contains { option.matches($0.file) }
        }
    }

    private var specs: [CinemaSpecFilter] {
        CinemaSpecFilter.allCases.filter { option in
            matchedEntries.contains { option.matches($0.file) }
        }
    }

    private var runtimes: [CinemaRuntimeFilter] {
        CinemaRuntimeFilter.allCases.filter { option in
            matchedEntries.contains { option.matches($0.runtime) }
        }
    }

    private var ratings: [CinemaRatingFilter] {
        CinemaRatingFilter.allCases.filter { option in
            matchedEntries.contains { option.matches($0.rating) }
        }
    }

    private var watchStates: [CinemaWatchFilter] {
        let present = Set(matchedEntries.map { store.cinemaWatchState(for: $0) })
        return CinemaWatchFilter.allCases.filter { present.contains($0) }
    }

    private var genres: [String] {
        Set(matchedEntries.flatMap { $0.genres ?? [] }).sorted()
    }

    private var countries: [String] {
        ranked { $0.countries ?? [] }
    }

    private var languages: [String] {
        ranked { $0.originalLanguage.map { [$0] } ?? [] }
    }

    /// 地区 / 语言按出现次数排序：常用项排前面，避免弹层里出现一长串冷门值。
    private func ranked(_ values: (CinemaEntry) -> [String]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in matchedEntries {
            for value in values(entry) where !value.isEmpty {
                counts[value, default: 0] += 1
            }
        }
        return counts.keys.sorted { lhs, rhs in
            let l = counts[lhs] ?? 0
            let r = counts[rhs] ?? 0
            if l != r { return l > r }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private var matchCount: Int {
        let entries = matchedEntries.filter { store.cinemaPassesFilters($0) }
        let series = store.cinemaSeries(for: scope).filter { store.cinemaPassesFilters($0) }
        return entries.count + series.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("筛选")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(matchCount) 个条目符合")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 11) {
                    group("内容（可多选）") {
                        chip("全部", selected: store.cinemaKindFilters.isEmpty) {
                            store.cinemaKindFilters = []
                        }
                        ForEach(kinds) { kind in
                            chip(kind.title, selected: store.cinemaKindFilters.contains(kind)) {
                                var next = store.cinemaKindFilters
                                if next.contains(kind) { next.remove(kind) } else { next.insert(kind) }
                                store.cinemaKindFilters = next
                            }
                        }
                    }

                    if !years.isEmpty {
                        group("年份（可多选）") {
                            chip("全部", selected: store.cinemaYears.isEmpty) {
                                store.cinemaYears = []
                            }
                            ForEach(years, id: \.self) { year in
                                chip("\(year)", selected: store.cinemaYears.contains(year)) {
                                    var next = store.cinemaYears
                                    if next.contains(year) { next.remove(year) } else { next.insert(year) }
                                    store.cinemaYears = next
                                }
                            }
                        }
                    }

                    group("类型（可多选）") {
                        chip("全部", selected: store.cinemaGenres.isEmpty) {
                            store.cinemaGenres = []
                        }
                        ForEach(genres, id: \.self) { genre in
                            chip(genre, selected: store.cinemaGenres.contains(genre)) {
                                var next = store.cinemaGenres
                                if next.contains(genre) { next.remove(genre) } else { next.insert(genre) }
                                store.cinemaGenres = next
                            }
                        }
                    }

                    if !countries.isEmpty {
                        group("地区（可多选）") {
                            chip("全部", selected: store.cinemaCountries.isEmpty) {
                                store.cinemaCountries = []
                            }
                            ForEach(capped(countries, selected: store.cinemaCountries, limit: 18),
                                    id: \.self) { country in
                                chip(country, selected: store.cinemaCountries.contains(country)) {
                                    var next = store.cinemaCountries
                                    if next.contains(country) { next.remove(country) } else { next.insert(country) }
                                    store.cinemaCountries = next
                                }
                            }
                        }
                    }

                    if !languages.isEmpty {
                        group("语言（可多选）") {
                            chip("全部", selected: store.cinemaLanguages.isEmpty) {
                                store.cinemaLanguages = []
                            }
                            ForEach(capped(languages, selected: store.cinemaLanguages, limit: 12),
                                    id: \.self) { code in
                                chip(CinemaLanguageCatalog.title(code),
                                     selected: store.cinemaLanguages.contains(code)) {
                                    var next = store.cinemaLanguages
                                    if next.contains(code) { next.remove(code) } else { next.insert(code) }
                                    store.cinemaLanguages = next
                                }
                            }
                        }
                    }

                    if !resolutions.isEmpty {
                        group("分辨率（可多选）") {
                            chip("全部", selected: store.cinemaResolutions.isEmpty) {
                                store.cinemaResolutions = []
                            }
                            ForEach(resolutions) { option in
                                chip(option.title, selected: store.cinemaResolutions.contains(option)) {
                                    var next = store.cinemaResolutions
                                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                                    store.cinemaResolutions = next
                                }
                            }
                        }
                    }

                    if !specs.isEmpty {
                        group("规格（可多选）") {
                            chip("全部", selected: store.cinemaSpecFilters.isEmpty) {
                                store.cinemaSpecFilters = []
                            }
                            ForEach(specs) { option in
                                chip(option.title, selected: store.cinemaSpecFilters.contains(option)) {
                                    var next = store.cinemaSpecFilters
                                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                                    store.cinemaSpecFilters = next
                                }
                            }
                        }
                    }

                    if !runtimes.isEmpty {
                        group("片长（可多选）") {
                            chip("全部", selected: store.cinemaRuntimeFilters.isEmpty) {
                                store.cinemaRuntimeFilters = []
                            }
                            ForEach(runtimes) { option in
                                chip(option.title, selected: store.cinemaRuntimeFilters.contains(option)) {
                                    var next = store.cinemaRuntimeFilters
                                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                                    store.cinemaRuntimeFilters = next
                                }
                            }
                        }
                    }

                    if !ratings.isEmpty {
                        group("评分（可多选）") {
                            chip("全部", selected: store.cinemaRatingFilters.isEmpty) {
                                store.cinemaRatingFilters = []
                            }
                            ForEach(ratings) { option in
                                chip(option.title, selected: store.cinemaRatingFilters.contains(option)) {
                                    var next = store.cinemaRatingFilters
                                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                                    store.cinemaRatingFilters = next
                                }
                            }
                        }
                    }

                    if !watchStates.isEmpty {
                        group("观看状态（可多选）") {
                            chip("全部", selected: store.cinemaWatchFilters.isEmpty) {
                                store.cinemaWatchFilters = []
                            }
                            ForEach(watchStates) { option in
                                chip(option.title, selected: store.cinemaWatchFilters.contains(option)) {
                                    var next = store.cinemaWatchFilters
                                    if next.contains(option) { next.remove(option) } else { next.insert(option) }
                                    store.cinemaWatchFilters = next
                                }
                            }
                        }
                    }

                    group("智能") {
                        chip("最近 30 天", selected: store.cinemaSmartRecent) {
                            store.cinemaSmartRecent.toggle()
                        }
                    }

                    group("我的") {
                        chip("仅看收藏", selected: store.cinemaFavoritesOnly) {
                            store.cinemaFavoritesOnly.toggle()
                        }
                        ForEach(store.cinemaLists) { list in
                            chip("\(list.name) \(list.count)",
                                 selected: store.cinemaActiveListID == list.id) {
                                store.cinemaActiveListID = store.cinemaActiveListID == list.id ? nil : list.id
                            }
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 480)

            Divider()

            HStack(spacing: 10) {
                Button("重置") { reset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    /// 地区 / 语言按出现次数排序，只展示前 N 个；已选项即使排在后面也始终保留。
    private func capped(_ values: [String], selected: Set<String>, limit: Int) -> [String] {
        let head = Array(values.prefix(limit))
        let extra = values.filter { selected.contains($0) && !head.contains($0) }
        return head + extra
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            CinemaFilterFlow(spacing: 6, lineSpacing: 6) {
                content()
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .background(selected ? LumaBrand.amber.opacity(0.18)
                                     : Color.primary.opacity(0.055),
                            in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(selected ? LumaBrand.amber.opacity(0.5) : Color.clear,
                                      lineWidth: 0.8)
                }
                .foregroundStyle(selected ? LumaBrand.amber : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func reset() {
        store.resetCinemaFilters()
    }
}

// MARK: - 类型弹层

/// 「类型」弹层：列出当前影院聚合出的全部类型，点选即筛选、再点取消。
/// 类型再多也只占顶栏一个占位，不再需要「固定 / 折叠」的概念。
private struct CinemaTypePanel: View {
    let scope: CinemaScope
    let onClose: () -> Void

    @EnvironmentObject private var store: LibraryStore

    private var buckets: [CinemaTypeBucket] {
        store.cinemaAggregate(for: scope).types
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("按类型浏览")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(buckets.count) 个类型")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if buckets.isEmpty {
                Text("刮削完成后，会按 TMDB 的类型标签自动归类。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CinemaFilterFlow(spacing: 6, lineSpacing: 6) {
                    chip("全部",
                         icon: "square.grid.2x2",
                         count: nil,
                         selected: store.cinemaTypeFilterID == nil) {
                        store.cinemaTypeFilterID = nil
                    }
                    ForEach(buckets) { bucket in
                        chip(bucket.type.title,
                             icon: bucket.type.icon,
                             count: bucket.count,
                             selected: store.cinemaTypeFilterID == bucket.id) {
                            if store.cinemaTypeFilterID == bucket.id {
                                store.cinemaTypeFilterID = nil
                            } else {
                                store.cinemaTypeFilterID = bucket.id
                                store.cinemaTab = .all
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func chip(_ title: String,
                      icon: String,
                      count: Int?,
                      selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .opacity(0.65)
                }
            }
            .foregroundStyle(selected ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            .background(selected ? LumaBrand.amber.opacity(0.18) : Color.primary.opacity(0.055),
                        in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(selected ? LumaBrand.amber.opacity(0.5) : Color.clear,
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 标题栏托管

/// 把影院控制台直接装进窗口的标题栏容器，而不是注册成 NSToolbar 项。
/// NSToolbar 在窗口变窄时会把放不下的项整条收进溢出菜单（控制台就消失了）；
/// 装进标题栏后系统不再做这个判断，任何窗口尺寸下控制台都常驻，
/// 宽度不够时由控制台内部的横向滚动承接。
struct CinemaTitlebarConsoleHost: NSViewRepresentable {
    let store: LibraryStore
    let settings: AppSettings
    let viewer: ViewerModel
    let openSettingsAction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, settings: settings, viewer: viewer, openSettings: openSettingsAction)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.openSettings = openSettingsAction
        context.coordinator.refreshRoot()
        context.coordinator.logState("update viewer=\(viewer.viewerID?.uuidString ?? "nil") "
                                     + "editor=\(viewer.editorID?.uuidString ?? "nil") "
                                     + "immersive=\(viewer.videoImmersiveFullScreen) "
                                     + "layout=\(settings.viewerLayout)")
        nsView.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        coordinator.remove()
    }

    /// 只负责汇报「自己挂到哪个窗口」，真正的控制台挂在标题栏容器上。
    final class AnchorView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    final class Coordinator {
        private let store: LibraryStore
        private let settings: AppSettings
        private let viewer: ViewerModel
        var openSettings: () -> Void
        weak var anchor: AnchorView?

        private var host: NSHostingView<AnyView>?
        private weak var window: NSWindow?
        private weak var container: NSView?
        private var leadingConstraint: NSLayoutConstraint?
        private var trailingConstraint: NSLayoutConstraint?
        private var centerYConstraint: NSLayoutConstraint?
        private var heightConstraint: NSLayoutConstraint?
        private var observers: [NSObjectProtocol] = []

        init(store: LibraryStore,
             settings: AppSettings,
             viewer: ViewerModel,
             openSettings: @escaping () -> Void) {
            self.store = store
            self.settings = settings
            self.viewer = viewer
            self.openSettings = openSettings
        }

        private func makeRoot() -> AnyView {
            AnyView(
                TitlebarConsoleRoot(openSettings: openSettings)
                    .environmentObject(store)
                    .environmentObject(settings)
                    .environmentObject(viewer)
            )
        }

        func refreshRoot() {
            host?.rootView = makeRoot()
            // 查看器打开后控制台内容会变成透明占位，但 NSHostingView 的 frame 仍然铺满标题栏，
            // 会把手势全部吞掉，导致播放器顶栏按钮点不动。直接隐藏，让点击落到下面真正的工具栏。
            host?.isHidden = isSuppressed
        }

        /// 查看器 / 编辑器打开时顶栏归它们自己使用，影院控制台整块让位。
        private var isSuppressed: Bool {
            MainActor.assumeIsolated {
                viewer.viewerID != nil || viewer.editorID != nil
            }
        }

        func attach(to window: NSWindow?) {
            guard let window else { return remove() }
            guard let container = Self.titlebarContainer(in: window) else { return }
            if self.window === window,
               self.container === container,
               let host,
               host.superview === container {
                logState("reuse")
                updateInsets()
                return
            }

            removeHost()
            self.window = window
            self.container = container

            let hosting = NSHostingView(rootView: makeRoot())
            // 这个 NSHostingView 只是铺在标题栏里的浮层，不能参与窗口尺寸计算：
            // 查看器打开时根视图会缩成 0×0，SwiftUI 会顺带把整个主窗口按内容尺寸缩到最小。
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting, positioned: .above, relativeTo: nil)

            let leading = hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 128)
            let trailing = hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10)
            let centerY = hosting.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            let height = hosting.heightAnchor.constraint(equalToConstant: 38)
            height.priority = .defaultHigh
            NSLayoutConstraint.activate([
                leading, trailing, centerY, height,
                hosting.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 2),
                hosting.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -2)
            ])
            leadingConstraint = leading
            trailingConstraint = trailing
            centerYConstraint = centerY
            heightConstraint = height
            hosting.isHidden = isSuppressed
            host = hosting

            observe(window)
            updateInsets()
            logState("attached")
        }

        func remove() {
            removeHost()
            removeObservers()
            window = nil
            container = nil
        }

        private func removeHost() {
            NSLayoutConstraint.deactivate([leadingConstraint, trailingConstraint,
                                           centerYConstraint, heightConstraint].compactMap { $0 })
            leadingConstraint = nil
            trailingConstraint = nil
            centerYConstraint = nil
            heightConstraint = nil
            host?.removeFromSuperview()
            host = nil
        }

        private func updateInsets() {
            guard let window, let container,
                  let leadingConstraint, let trailingConstraint, let heightConstraint else { return }
            leadingConstraint.constant = Self.leadingInset(in: window, container: container)
            trailingConstraint.constant = -10
            heightConstraint.constant = min(38, max(24, container.bounds.height - 4))
        }

        private func observe(_ window: NSWindow) {
            removeObservers()
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didDeminiaturizeNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.logState("notify \(name.rawValue)")
                    self?.updateInsets()
                    // 全屏进出时标题栏容器可能换新：稍后再挂一次。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.attach(to: window)
                    }
                }
            }
        }

        private func removeObservers() {
            for token in observers { NotificationCenter.default.removeObserver(token) }
            observers.removeAll()
        }

        // MARK: 临时诊断（LUMA_TOOLBAR_LOG）

        func logState(_ tag: String) {
            guard ProcessInfo.processInfo.environment["LUMA_TOOLBAR_LOG"] != nil,
                  let window, let container else { return }
            let hostFrame = host?.frame.debugDescription ?? "nil"
            let line = "\(tag) win=\(window.frame) content=\(window.contentLayoutRect) "
                + "min=\(window.minSize) contentMin=\(window.contentMinSize) "
                + "style=\(window.styleMask.rawValue) toolbarVisible=\(window.toolbar?.isVisible ?? false) "
                + "container=\(type(of: container)) frame=\(container.frame) bounds=\(container.bounds) "
                + "host=\(hostFrame)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: "/tmp/luma-titlebar.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }

        deinit {
            removeObservers()
        }

        // MARK: 布局定位

        /// 控制台从侧边栏右侧开始：展开时避开标题栏里的侧边栏开关，
        /// 收起时留出开关本身的位置。
        private static func leadingInset(in window: NSWindow, container: NSView) -> CGFloat {
            if let split = splitView(in: window.contentView),
               let sidebar = split.arrangedSubviews.first,
               sidebar.frame.width > 1 {
                let rect = sidebar.convert(sidebar.bounds, to: container)
                return max(90, rect.maxX + 8)
            }
            return 128
        }

        private static func splitView(in view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView { return split }
            for subview in view.subviews {
                if let found = splitView(in: subview) { return found }
            }
            return nil
        }

        /// 标题栏容器：窗口主题框里名为 NSTitlebarContainerView 的那层。
        private static func titlebarContainer(in window: NSWindow) -> NSView? {
            guard let frameView = window.contentView?.superview else { return nil }
            if let found = findTitlebarContainer(in: frameView) { return found }
            return window.standardWindowButton(.closeButton)?.superview
        }

        private static func findTitlebarContainer(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("TitlebarContainer") { return view }
            for subview in view.subviews {
                if let found = findTitlebarContainer(in: subview) { return found }
            }
            return nil
        }
    }
}

/// 标题栏控制台的根视图：查看器 / 播放器 / 编辑器打开后，顶栏归查看器自己用，
/// 影院控制台要一起让位，不能浮在照片或视频画面上。
private struct TitlebarConsoleRoot: View {
    @EnvironmentObject private var viewer: ViewerModel
    let openSettings: () -> Void

    private var suppressed: Bool {
        viewer.viewerID != nil || viewer.editorID != nil
    }

    var body: some View {
        // 播放 / 查看 / 编辑时只做视觉隐藏，不能把根视图缩成 0×0：
        // 托管视图尺寸塌陷会让整个窗口跟着缩成一条。
        CinemaToolbarConsole(openSettingsOverride: openSettings)
            .opacity(suppressed ? 0 : 1)
            .allowsHitTesting(!suppressed)
            .accessibilityHidden(suppressed)
            // 标题栏浮层会吞掉原生双击标题栏事件：空白处补回窗口缩放，
            // 与双击左侧栏 / 标题栏的「占满屏幕」行为保持一致。
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.performZoom(nil)
            }
    }
}
