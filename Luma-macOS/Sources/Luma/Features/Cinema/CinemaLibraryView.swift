import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院详情 / 面板统一深色底：避免跟随系统浅色外观出现白底。
let cinemaSheetBackground = Color(red: 0.055, green: 0.06, blue: 0.075)


struct CinemaLibraryView: View {
    /// nil 表示本地图库的影院；有值表示某一个网盘实例自己的影院。
    let mountID: UUID?

    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var viewer: ViewerModel
    @Environment(\.openSettings) var openSettings
    /// 打开设置时直接落在「影院」分页。
    @AppStorage(SettingsKeys.selectedTab) var settingsTab: SettingsTab = .general

    /// 当前打开的详情（剧集 / 影片）：直接在页面内展示，不再单独弹窗。
    @State var detailTarget: CinemaDetailTarget?
    /// 搜索 / 观看记录 / 任务等辅助面板仍走 sheet，和详情分开存，互不覆盖。
    @State var panelTarget: CinemaDetailTarget?
    /// 列表模式的选中行：单击选中、双击详情、空格播放。
    @State var selectedListEntryID: UUID?
    @State var selectedListSeriesID: String?
    /// 列表行右键「更换海报 / 背景」：候选面板由整页统一承载。
    @State var artworkRequest: CinemaArtworkPickerRequest?
    @FocusState var listFocus: Bool
    /// 文件夹视图的聚合结果：按目录分组，匹配后显示影片 / 剧集名。
    @State var folders: [CinemaFolder] = []
    @State var foldersLoaded = false
    @State var hoveredFolderID: String?
    @State var scrapingFolderIDs: Set<String> = []
    /// 当前钻进到哪一层（nil 表示顶层）；可以一直点下去。
    @State var selectedFolderPath: String?
    /// 海报墙密度：紧凑 / 标准 / 大图，设置里可改，立即生效。
    @AppStorage("cinema_wall_density") var wallDensity: CinemaWallDensity = .normal
    /// 列表表头的升降序：再次点击同一列时反转，只影响列表呈现。
    @State var listSortReversed = false
    /// F5 首次建库：用户点过「稍后再说」或已有片源后不再出现。
    @AppStorage("cinema_first_run_dismissed") var firstRunDismissed = false
    /// 继续观看默认只铺一排；点「N 部待续播」展开成完整队列。
    @State var continueExpanded = false
    /// 卡片模式胶片条的可用宽度：按它算一行放得下几格，不再横向滚动。
    @State var cardStripWidth: CGFloat = 1280
    /// 卡片模式里已展开成完整网格的分组（movie / series）。
    @State var expandedCardStrips: Set<String> = []
    /// 卡片模式当前主卡选中的影片 / 剧集：nil 时回落到第一项。
    @State var cardHeroKey: String?

    init(mountID: UUID? = nil) {
        self.mountID = mountID
    }

    var scope: CinemaScope { mountID.map { .mount($0) } ?? .local }

    /// 文件夹只在切到该分段时重算；匹配 / 刮削后靠 Store 的刷新信号重新聚合。
    var folderRefreshKey: String {
        "\(store.cinemaTab.rawValue)|\(LibraryStore.cinemaScopeKey(scope))"
            + "|\(store.cinemaFolderRefreshToken)|\(store.cinemaEntries(for: scope).count)"
    }

    /// 页面所有派生数据都来自 Store 的一次性聚合快照：
    /// 只有刮削索引 / 筛选 / 排序变化时才重算，body 里反复读取只是取缓存。
    var aggregate: CinemaAggregate {
        store.cinemaAggregate(for: scope)
    }

    /// 这个链接下所有刮削过的条目（含未识别的），页面上要能看到「有视频」。
    var allEntries: [CinemaEntry] { aggregate.allEntries }
    var entries: [CinemaEntry] { aggregate.entries }
    var unmatched: [CinemaEntry] { aggregate.unmatched }
    var movies: [CinemaEntry] { aggregate.movies }
    /// 未识别的剧同样聚合成一张卡，避免一集一张铺满整行。
    var unmatchedSeries: [CinemaSeries] { aggregate.unmatchedSeries }
    var unmatchedMovies: [CinemaEntry] { aggregate.unmatchedMovies }
    /// 同一部剧的多集合并成一张卡片；筛选条件与条目列表保持一致。
    var series: [CinemaSeries] { aggregate.series }

    /// 列表模式下的显示顺序：表头再次点击时反转，不改变海报墙与卡片。
    var listedMovies: [CinemaEntry] {
        listSortReversed ? Array(movies.reversed()) : movies
    }

    var listedSeries: [CinemaSeries] {
        listSortReversed ? Array(series.reversed()) : series
    }

    /// 自动归组：同一 belongs_to_collection 的电影聚成合集，至少 2 部才展示。
    var cinemaCollections: [CinemaCollectionGroup] { aggregate.collections }

    @ViewBuilder
    var collectionShelves: some View {
        if !cinemaCollections.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(cinemaCollections) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(group.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(group.entries.count) 部")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(group.entries) { entry in
                                    posterCard(entry)
                                        .frame(width: 132)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
        }
    }

    /// 是否启用了顶栏筛选（年代 / 类型 / 分辨率 / 观看状态 / 智能 / 收藏 / 清单）。
    var isFilteringCinema: Bool {
        store.cinemaHasAttributeFilters
            || store.cinemaFavoritesOnly
            || store.cinemaActiveListID != nil
    }

    var needsConfig: Bool {
        store.cinemaNeedsConfiguration
    }

    /// 先把分页写成「影院」，再打开设置窗口，保证一进来就是影院设置。
    func openCinemaSettings() {
        settingsTab = .cinema
        openSettings()
    }

    var body: some View {
        ZStack {
            // 列表放进 overlay：它只负责显示，不参与整页尺寸推导。
            // 否则海报墙 / 横向滚动的理想宽度会把窗口的最小宽度撑大，详情页也跟着超宽。
            Color.clear
                .overlay {
                    libraryContent
                        .opacity(detailTarget == nil ? 1 : 0)
                        .allowsHitTesting(detailTarget == nil)
                }
            if let target = detailTarget {
                inlineDetail(target)
                    // 详情之间直接切换（例如合集里的下一部）时重建状态，
                    // 否则 TMDB 补全结果会停在上一个条目上。
                    .id(target.id)
                    .transition(.opacity)
            }
        }
        // 影院控制台直接铺在窗口标题栏上：不走 NSToolbar 项，
        // 窗口怎么缩都不会被系统整条收进溢出菜单。
        .background {
            if ProcessInfo.processInfo.environment["LUMA_NO_CONSOLE_HOST"] == nil {
                CinemaTitlebarConsoleHost(store: store,
                                          settings: settings,
                                          viewer: viewer,
                                          openSettingsAction: { openSettings() })
            }
        }
        .animation(.easeOut(duration: 0.16), value: detailTarget?.id)
        // 列表留在下层，但它仍持有键盘焦点：进详情时交出去，
        // 否则空格 / 回车会被看不见的海报墙截走。
        .onChange(of: detailTarget?.id) { _, current in
            store.cinemaDetailOpen = current != nil
            if current == nil {
                if store.cinemaViewMode == .list { listFocus = true }
            } else {
                listFocus = false
            }
        }
        // 文件夹钻取也复用顶栏的「返回」：进入目录时把深度报给控制台。
        .onChange(of: selectedFolderPath) { _, path in
            store.cinemaFolderDepth = path == nil ? 0 : breadcrumbPaths.count
        }
        .onChange(of: store.cinemaFolderCloseTick) { _, _ in
            guard selectedFolderPath != nil else { return }
            goUp()
        }
        // 切离「文件夹」分段时收起当前目录，否则顶栏会一直停在「返回」形态。
        .onChange(of: store.cinemaTab) { _, tab in
            if tab != .folder, selectedFolderPath != nil { selectedFolderPath = nil }
        }
        // 播放器打开期间把键盘焦点交出去：否则回车 / 空格会被看不见的海报墙截走。
        .onChange(of: store.viewerID) { _, viewing in
            if viewing != nil {
                listFocus = false
            } else if detailTarget == nil, store.cinemaViewMode == .list {
                listFocus = true
            }
        }
        // 顶栏「返回」由详情页自己逐层消费（演职员 → 详情 → 列表）。
        .onDisappear {
            store.cinemaDetailOpen = false
            store.cinemaFolderDepth = 0
        }
    }

    /// 内嵌的剧集 / 影片详情：铺满影院页面，返回后回到原来的列表位置。
    @ViewBuilder
    func inlineDetail(_ target: CinemaDetailTarget) -> some View {
        switch target {
        case .series(let item):
            CinemaSeriesDetailView(
                series: item,
                onPlay: { entry in
                    store.openCinema(entry, queue: seriesQueue(for: item))
                },
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environmentObject(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        case .entry(let entry):
            CinemaDetailView(
                entry: entry,
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environmentObject(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        default:
            EmptyView()
        }
    }

    /// 统一错误卡的恢复动作：重试刮削 / 去设置里改刮削源。
    func handleCinemaRecovery(_ action: RecoveryAction) {
        switch action {
        case .retry:
            store.startCinemaScrape(for: scope, force: true)
        case .reconfigureSource, .reauthorize:
            settingsTab = .cinema
            openSettings()
        case .openInBrowser(let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        case .openSystemSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        case .allowInsecureTLS:
            break
        }
    }

    /// 书架 / 海报墙 / 列表本体：详情打开时留在下层，关掉后滚动位置不丢。
    var libraryContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if needsConfig {
                        setupBanner
                    }
                    if store.cinemaScrapeRunning, store.cinemaScrapeScope == scope {
                        progressBar
                    } else if let sourceError = store.cinemaSourceError {
                        SourceErrorView(error: sourceError) { action in
                            handleCinemaRecovery(action)
                        }
                    } else if let message = store.cinemaScrapeMessage {
                        statusBanner(message)
                    }
                    content
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .topTrailing) {
                CinemaToastStack()
                    .environmentObject(store)
            }
            .overlay(alignment: .trailing) {
                wallLetterRail(proxy)
            }
        .task(id: scope) {
            // 换片源时收掉详情，避免显示上一个来源的剧集 / 影片。
            detailTarget = nil
            // 兜底：播放失败可能留下「viewerID 有值、但照片已找不到」的幽灵查看器，
            // 它会让顶栏整体让位给查看器，导致影院控制台消失。
            if store.viewerPhoto == nil, store.viewerID != nil {
                store.viewerID = nil
            }
            // 视频全屏标记若在退出系统全屏时没被复位，也会让整个窗口工具栏消失；
            // 回到影院说明已不在全屏，顺手复位。
            if store.viewerModel.videoImmersiveFullScreen,
               NSApp.keyWindow?.styleMask.contains(.fullScreen) != true {
                store.viewerModel.videoImmersiveFullScreen = false
            }
            // 只切换影院的作用域，不顺带刮削：影院和「视频」是两个入口，
            // 打开影院不应该等于把这个链接下的视频扫一遍，刮削只由显式点击触发。
            store.activateCinemaScope(scope)
        }
        .task(id: folderRefreshKey) {
            guard store.cinemaTab == .folder else { return }
            foldersLoaded = false
            await Task.yield()
            folders = store.cinemaFolders(for: scope)
            foldersLoaded = true
            syncFolderSelection()
        }
        // 只有面板走 sheet；剧集 / 影片详情已经改成页面内展示。
        .sheet(item: $panelTarget) { target in
            switch target {
            case .newList:
                CinemaNewListSheet { name in
                    store.createCinemaList(named: name)
                    panelTarget = nil
                } onCancel: {
                    panelTarget = nil
                }
                .environmentObject(store)
            case .search:
                CinemaSearchPanel { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        openDetail(entry)
                    }
                } onOpenSeries: { item in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        detailTarget = .series(item)
                    }
                } onPlay: { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.openCinema(entry)
                    }
                }
                .environmentObject(store)
            case .history:
                CinemaHistoryPanel(scope: scope) { entry in
                    panelTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.openCinema(entry)
                    }
                }
                .environmentObject(store)
            case .notifications:
                CinemaNotificationSheet()
                    .environmentObject(store)
            case .pin:
                CinemaPINPromptSheet()
                    .environmentObject(store)
            case .folder(let folder):
                CinemaFolderDetailView(folder: folder,
                                       scope: scope,
                                       onPlay: { entry in
                                           panelTarget = nil
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                               store.openCinema(entry)
                                           }
                                       },
                                       onOpenEntry: { entry in
                                           panelTarget = nil
                                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                               detailTarget = .entry(entry)
                                           }
                                       })
                .environmentObject(store)
            case .folderMatch(let folder):
                CinemaMatchSheet(photos: folder.subtreePhotos, folderHint: folder.hint) {
                    panelTarget = nil
                    refreshFolders()
                }
                .environmentObject(store)
            case .match(let entry):
                CinemaMatchSheet(entry: entry) {
                    panelTarget = nil
                    refreshFolders()
                }
                .environmentObject(store)
            case .series, .entry:
                // 详情页不再走弹窗，这里只是让 switch 保持穷尽。
                EmptyView()
            }
        }
        // 列表行右键换封面：和详情页共用同一个候选面板。
        .sheet(item: $artworkRequest) { request in
            CinemaArtworkPickerSheet(kind: request.kind, entry: request.entry) { url in
                store.applyCinemaArtwork(request.entry,
                                         posterURL: request.kind == .poster ? url : nil,
                                         backdropURL: request.kind == .backdrop ? url : nil)
            }
        }
        // 顶栏按钮通过 Store 旗标请求面板；这里统一转成单 sheet，避免多个 sheet 互相覆盖。
        .onChange(of: store.cinemaSearchVisible) { _, visible in
            guard visible else { return }
            store.cinemaSearchVisible = false
            panelTarget = .search
        }
        .onChange(of: store.cinemaHistoryVisible) { _, visible in
            guard visible else { return }
            store.cinemaHistoryVisible = false
            panelTarget = .history
        }
        .onChange(of: store.cinemaNewListVisible) { _, visible in
            guard visible else { return }
            store.cinemaNewListVisible = false
            panelTarget = .newList
        }
        .onChange(of: store.cinemaNotificationsVisible) { _, visible in
            guard visible else { return }
            store.cinemaNotificationsVisible = false
            panelTarget = .notifications
        }
        .onChange(of: store.cinemaPINPromptVisible) { _, visible in
            guard visible else { return }
            store.cinemaPINPromptVisible = false
            panelTarget = .pin
        }
        }
    }

}
