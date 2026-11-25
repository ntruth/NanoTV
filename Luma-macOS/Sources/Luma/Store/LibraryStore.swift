import Foundation
import AppKit
import SwiftUI
import Combine
import CoreLocation
import UniformTypeIdentifiers
import LumaCore
import LumaContentCore

struct LibraryData: Codable {
    var photos: [PhotoItem] = []
    var albums: [Album] = []
    var folders: [AlbumFolder] = []

    init() {}

    init(photos: [PhotoItem] = [], albums: [Album] = [], folders: [AlbumFolder] = []) {
        self.photos = photos
        self.albums = albums
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photos = (try? container.decodeIfPresent([PhotoItem].self, forKey: .photos)) ?? []
        albums = (try? container.decodeIfPresent([Album].self, forKey: .albums)) ?? []
        folders = (try? container.decodeIfPresent([AlbumFolder].self, forKey: .folders)) ?? []
    }
}

/// 从全局搜索结果跳走前的搜索现场：详情页顶栏据此提供「返回搜索」。
/// `landingItem` 是跳转落点：只有当前仍停在这个落点页面时才显示返回入口，
/// 用户主动去别的页面后入口自动消失。
struct SearchReturnSnapshot: Equatable {
    var query: String
    var scope: SearchScope
    var source: SearchSourceKind?
    var kind: SearchHitKind?
    var origin: String?
    var category: String?
    /// 搜索页所处的基准页面：恢复搜索时先回到这里。
    var originItem: SidebarItem
    var landingItem: SidebarItem?
}

/// 搜索范围三档：全局 / 模块内（本功能）/ 窗口内（当前窗口）。
enum SearchScope: String, CaseIterable, Identifiable {
    /// 跨模块统一搜索。
    case global
    /// 只搜当前功能自己的来源（如网络影院只搜影视源、网络资源只搜资源站）。
    case module
    /// 当前窗口内：只过滤当前视图已经展示的内容。
    case currentView

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "全局"
        case .module: return "模块内"
        case .currentView: return "窗口内"
        }
    }

    var shortTitle: String { title }

    var detail: String {
        switch self {
        case .global: return "全部模块"
        case .module: return "本模块来源"
        case .currentView: return "当前窗口内容"
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    /// 单窗口应用里唯一的主图库：AppDelegate 关窗时用它判断智能助手是否还在后台执行。
    static weak var current: LibraryStore?
    @Published var photos: [PhotoItem] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published var albums: [Album] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published var folders: [AlbumFolder] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// 智能相簿：按条件自动筛选，不需要手动加入照片。
    @Published var smartAlbums: [SmartAlbum] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// 被固定到侧边栏「固定」分区的相簿与文件夹（按固定顺序展示）。
    @Published var pinnedItems: [PinnedSidebarItem] = []
    /// 正在编辑的智能相簿草稿（非空时弹出编辑器）。
    @Published var editingSmartAlbum: SmartAlbum?

    @Published var sidebarItem: SidebarItem = .library {
        didSet {
            guard sidebarItem != oldValue else { return }
            // 每个侧边栏页面各自记住滑杆位置：离开前存下当前范围，进入目标范围时恢复。
            thumbSizes[thumbSizeScopeKey(for: oldValue)] = thumbSize
            if let saved = thumbSizes[thumbSizeScopeKey(for: sidebarItem)] {
                thumbSize = saved
            } else {
                // 新打开的页面用设置里的默认大小，不再沿用上一个页面可能调小后的值。
                thumbSize = defaultGridThumbSize
                thumbSizes[thumbSizeScopeKey(for: sidebarItem)] = thumbSize
            }
            persistThumbSizes()
            // 卡片墙的每行张数同样按页面记忆。
            cardColumnsByScope[cardColumnsScopeKey(for: oldValue)] = cardColumns
            if let saved = cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] {
                cardColumns = saved
            } else {
                cardColumns = Self.defaultCardColumnsValue
                cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] = cardColumns
            }
            persistCardColumns()
            // 侧边栏记忆：下次打开从当前页面继续。
            persistSidebarItem(sidebarItem)
            loadSystemLibraryIfNeeded(sidebarItem)
        }
    }
    @Published var grouping: GridGrouping = .all {
        didSet { persistViewPreference(SettingsKeys.grouping, grouping.rawValue) }
    }
    /// 网格的堆叠浏览形态：关闭 / 仅连拍 / 连拍与同场景。随当前图库保存。
    @Published var stackMode: StackMode = .off {
        didSet {
            guard stackMode != oldValue else { return }
            persistViewPreference(SettingsKeys.stackMode, stackMode.rawValue)
            stackRevision &+= 1
        }
    }
    /// 已展开的堆叠（键为代表图 id）：展开后代表图后面跟着整组成员。
    @Published var expandedStackIDs: Set<UUID> = []
    /// 堆叠展开状态版本：`sections` 的缓存键包含它，展开 / 收起立即生效。
    var stackRevision = 0
    /// 堆叠分组计划缓存：键为可见集合指纹 + 模式，滚动 / 选中时直接命中。
    var stackPlanCacheKey = ""
    var stackPlanCache: StackPlan?
    /// 「个人收藏」的浏览方式（全部 / 年 / 类型 / 地点 / 相机 / 人物），随当前图库保存；默认先看年份。
    @Published var favoritesViewMode: FavoritesViewMode = .years {
        didSet {
            guard favoritesViewMode != oldValue else { return }
            persistViewPreference(SettingsKeys.favoritesViewMode, favoritesViewMode.rawValue)
            selectedFavoriteBucket = nil
        }
    }
    /// 收藏汇总页正在下钻的分类；非空时网格只显示该类收藏。
    @Published var selectedFavoriteBucket: FavoritesBucketSelection?
    /// 系统图库文件夹的整理流程：提取确认 → 执行中 → 清理空文件夹确认。
    @Published var systemFolderPrompt: SystemFolderPrompt?
    /// 当前原生图库能否被 PhotoKit 写入：mismatch 表示打开的不是「照片」正在使用的那个图库。
    @Published var systemWriteTargetState: SystemWriteTargetState = .unknown
    /// 在拾光里拖拽排序过的系统相簿：查询按「照片」的手动顺序展示（相簿自己的排序设置仍由「照片」保存）。
    var systemManualOrderAlbums: Set<Int64> = []
    /// 系统图库的工具弹窗：修改拍摄信息、移动相簿到文件夹、新建相簿并加入、删除文件夹确认。
    @Published var systemToolsRequest: SystemToolsRequest?
    @Published var favoritesDigest: FavoritesDigest?
    @Published var isLoadingFavoritesDigest = false
    /// 汇总数据源（完整收藏列表），卡片封面与下钻过滤共用。
    var favoritesDigestSource: [PhotoItem] = []
    var favoritesDigestLoadedToken = ""
    var favoritesDigestTask: Task<Void, Never>?

    // MARK: 视频页
    /// 视频页的派生结果（分组、轨道、统计），由 `refreshVideoHubIfNeeded()` 统一生成。
    @Published var videoHubData = VideoHubData()
    /// 视频页顶栏筛选：具体年份 + 时长档。
    @Published var videoHubFilter = VideoHubFilter() {
        didSet {
            guard videoHubFilter != oldValue else { return }
            refreshVideoHubIfNeeded(force: true)
        }
    }
    /// 视频页排列方式（海报墙 / 时间轴）。
    @Published var videoHubLayout: VideoHubLayout = .wall
    /// 视频页「视角」维度（精选 / 年份 / 时长 / 地点 / 人物）。
    @Published var videoHubDimension: VideoHubDimension = .featured
    var videoHubCacheToken = ""
    /// 后台汇总用的完整视频列表：只加载一次，筛选在其上内存过滤，不再依赖分页窗口。
    var videoHubFullVideos: [PhotoItem] = []
    var videoHubFullToken = ""
    var videoHubLoadingToken = ""
    @Published var isVideoHubLoading = false
    var videoHubLoadTask: Task<Void, Never>?

    /// 缩略图 / 卡片尺寸范围（pt）：滑杆、按钮、⌘+ / ⌘-、捏合都按这个范围夹紧。
    static let thumbSizeRange: ClosedRange<Double> = 56...360

    /// 正方形照片网格的格子间距（与 SquarePhotoGrid 一致）。
    static let gridSpacing: CGFloat = 2
    /// 设置面板还没拿到真实网格宽度时的估算宽度。
    static let gridFallbackWidth: CGFloat = 1000

    /// 图库网格内容区宽度，由 GalleryView 的布局回传；设置面板据此换算出真实的每行张数。
    @Published var gridContentWidth: CGFloat = 0

    /// 换算用的内容宽度：还没渲染过照片网格时按常见窗口宽度估算。
    var gridLayoutWidth: CGFloat {
        gridContentWidth > 200 ? gridContentWidth : Self.gridFallbackWidth
    }

    /// 当前页面在真实内容宽度下每行能放下几张（与网格实际列数一致）。
    var gridColumnCount: Int {
        Self.gridColumnCount(forThumbSize: thumbSize, contentWidth: gridLayoutWidth)
    }

    static func gridColumnCount(forThumbSize size: Double, contentWidth: CGFloat) -> Int {
        max(1, GridLayout.columns(contentWidth: max(120, contentWidth),
                                  targetSize: CGFloat(size),
                                  spacing: gridSpacing))
    }

    /// 反算：让这个宽度下正好每行 `columns` 张的缩略图尺寸。
    static func thumbSize(forGridColumns columns: Int, contentWidth: CGFloat) -> Double {
        let width = max(120, contentWidth)
        let count = CGFloat(max(1, columns))
        let raw = (width + gridSpacing) / count - gridSpacing - 0.01
        return min(thumbSizeRange.upperBound, max(thumbSizeRange.lowerBound, Double(raw)))
    }

    /// 「图片列表新页面默认」在当前窗口宽度下对应的缩略图尺寸。
    var defaultGridThumbSize: Double {
        Self.thumbSize(forGridColumns: AppSettings.shared.defaultGridColumns,
                       contentWidth: gridLayoutWidth)
    }

    @Published var thumbSize: Double = LibraryStore.thumbSize(forGridColumns: AppSettings.shared.defaultGridColumns,
                                                              contentWidth: LibraryStore.gridFallbackWidth) {
        didSet {
            let clamped = min(Self.thumbSizeRange.upperBound,
                              max(Self.thumbSizeRange.lowerBound, thumbSize))
            if clamped != thumbSize {
                thumbSize = clamped
                return
            }
            persistViewPreference(SettingsKeys.thumbSize, String(thumbSize))
            // 记住当前侧边栏页面自己的滑杆位置。
            let key = thumbSizeScopeKey(for: sidebarItem)
            if thumbSizes[key] != thumbSize {
                thumbSizes[key] = thumbSize
                persistThumbSizes()
            }
        }
    }

    /// 每个侧边栏页面的缩略图尺寸（「放大 / 缩小」滑杆位置），随当前图库保存。
    private var thumbSizes: [String: Double] = [:]

    /// 滑杆记忆的键：同一相簿 / 文件夹 / 场景各自独立。
    func thumbSizeScopeKey(for item: SidebarItem) -> String {
        String(describing: item)
    }

    private func persistThumbSizes() {
        guard let data = try? JSONEncoder().encode(thumbSizes),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(SettingsKeys.thumbSizes, json)
    }

    /// ⌘0 / 菜单「恢复默认缩略图大小」：当前页面回到设置里的默认尺寸。
    func resetThumbSizeToDefault() {
        thumbSize = defaultGridThumbSize
    }

    /// 把设置里的默认尺寸应用到所有侧边栏页面，清掉各页面单独记忆的滑杆位置。
    func applyDefaultThumbSizeToAllScopes() {
        thumbSizes.removeAll()
        thumbSize = defaultGridThumbSize
        thumbSizes[thumbSizeScopeKey(for: sidebarItem)] = thumbSize
        persistThumbSizes()
    }

    // MARK: 卡片墙（相簿 / 媒体类型 / 场景 / 更多项目 / 关键词）

    /// 卡片墙每行列数范围。
    static let cardColumnsRange: ClosedRange<Int> = 2...8

    static var defaultCardColumnsValue: Int {
        min(cardColumnsRange.upperBound,
            max(cardColumnsRange.lowerBound, AppSettings.shared.defaultCardColumns))
    }

    /// 卡片墙每行列数，按侧边栏页面分别记忆。
    @Published var cardColumns: Int = LibraryStore.defaultCardColumnsValue {
        didSet {
            let clamped = min(Self.cardColumnsRange.upperBound,
                              max(Self.cardColumnsRange.lowerBound, cardColumns))
            if clamped != cardColumns {
                cardColumns = clamped
                return
            }
            let key = cardColumnsScopeKey(for: sidebarItem)
            if cardColumnsByScope[key] != cardColumns {
                cardColumnsByScope[key] = cardColumns
                persistCardColumns()
            }
        }
    }

    private var cardColumnsByScope: [String: Int] = [:]

    func cardColumnsScopeKey(for item: SidebarItem) -> String {
        String(describing: item)
    }

    private func persistCardColumns() {
        guard let data = try? JSONEncoder().encode(cardColumnsByScope),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(SettingsKeys.cardColumns, json)
    }

    /// 当前页面是卡片墙而不是照片网格。
    var isCardWallScope: Bool {
        switch sidebarItem {
        case .allAlbums, .folder, .systemFolder, .systemAlbums,
             .mediaTypes, .systemMediaTypes, .scenes, .systemScenes,
             .moreItems, .systemMoreItems, .keywords, .systemKeywords:
            return true
        case .cloudMount:
            // 网盘的分区总览与图库的分类卡片墙一致：缩放调的是列数。
            return cloudOverviewSection != nil
        default:
            return false
        }
    }

    /// 工具栏放大 / 缩小：卡片墙改列数，照片网格改缩略图尺寸。
    func zoomStep(_ delta: Int) {
        if isCardWallScope {
            cardColumns = min(Self.cardColumnsRange.upperBound,
                              max(Self.cardColumnsRange.lowerBound, cardColumns + delta))
        } else {
            thumbSize = min(Self.thumbSizeRange.upperBound,
                            max(Self.thumbSizeRange.lowerBound,
                                thumbSize + Double(delta) * 16))
        }
    }

    /// ⌘0：当前页面回到设置里的默认密度。
    func resetZoom() {
        if isCardWallScope {
            cardColumns = Self.defaultCardColumnsValue
        } else {
            resetThumbSizeToDefault()
        }
    }

    /// 把设置里的卡片默认列数应用到所有侧边栏页面。
    func applyDefaultCardColumnsToAllScopes() {
        cardColumnsByScope.removeAll()
        cardColumns = Self.defaultCardColumnsValue
        cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] = cardColumns
        persistCardColumns()
    }

    /// 升级到「每行张数」后，等网格真实宽度已知再把当前页面对齐到默认密度。
    private var pendingDensityReconcile = false

    func reconcileDefaultDensitiesIfNeeded() {
        guard pendingDensityReconcile, gridContentWidth > 200 else { return }
        pendingDensityReconcile = false
        thumbSize = defaultGridThumbSize
        thumbSizes[thumbSizeScopeKey(for: sidebarItem)] = thumbSize
        persistThumbSizes()
        cardColumns = Self.defaultCardColumnsValue
        cardColumnsByScope[cardColumnsScopeKey(for: sidebarItem)] = cardColumns
        persistCardColumns()
    }

    @Published var thumbnailAspect: ThumbnailAspect = .square {
        didSet { persistViewPreference(SettingsKeys.thumbnailAspect, thumbnailAspect.rawValue) }
    }
    /// 相簿总览（「所有相簿」与文件夹层级）的展示形式，随当前图库保存。
    @Published var albumDisplayStyle: AlbumDisplayStyle = .grid {
        didSet { persistViewPreference(SettingsKeys.albumDisplayStyle, albumDisplayStyle.rawValue) }
    }
    @Published var photoFilter: PhotoFilter = .all
    @Published var keywordFilter: String?
    /// 元数据筛选：评分下限（0 表示不限）、旗标、色标。
    @Published var ratingFilter: Int = 0
    @Published var flagFilter: PhotoFlag?
    @Published var colorLabelFilter: PhotoColorLabel?
    /// 关键词页里进入的单个关键词（卡片墙点入后的独立详情）。
    @Published var selectedKeyword: String?
    /// 「位置」页里进入的单个地点。
    @Published var selectedPlace: PlaceCluster?
    /// 「位置」页的聚合层级（省 / 市 / 区县 / 街道），随当前图库保存；默认细到街道。
    @Published var placeGranularity: PlaceGranularity = .street {
        didSet {
            guard placeGranularity != oldValue else { return }
            persistViewPreference(SettingsKeys.placeGranularity, placeGranularity.rawValue)
            selectedPlace = nil
            resetPlaceClusterCaches()
        }
    }
    @Published var isResolvingPlaces = false
    @Published var placeResolveDone = 0
    @Published var placeResolveTotal = 0
    /// 「人物」页的聚合筛选（全部 / 已命名 / 待命名 / 宠物），随当前图库保存。
    @Published var peopleFilter: PeopleGroupFilter = .all {
        didSet {
            guard peopleFilter != oldValue else { return }
            persistViewPreference(SettingsKeys.peopleFilter, peopleFilter.rawValue)
        }
    }
    /// 「人物」总览的头像形状（圆形 / 圆角方形），随当前图库保存。
    @Published var peopleDisplayStyle: PeopleDisplayStyle = .circle {
        didSet {
            guard peopleDisplayStyle != oldValue else { return }
            persistViewPreference(SettingsKeys.peopleDisplayStyle, peopleDisplayStyle.rawValue)
        }
    }
    /// 「整理工作室」的浏览维度（评分 / 旗标 / 色标 / 关键词），随当前图库保存。
    @Published var organizeDimension: OrganizeDimension = .rating {
        didSet {
            guard organizeDimension != oldValue else { return }
            persistViewPreference(SettingsKeys.organizeDimension, organizeDimension.rawValue)
        }
    }
    /// 整理工作室的分布统计：由整理页重新取数时回填，顶栏胶囊直接读取。
    @Published var organizeStudioStats = OrganizeStudioStats()
    @Published var sortKey: SortKey = .capturedAt {
        didSet { persistViewPreference(SettingsKeys.sortKey, sortKey.rawValue) }
    }
    /// 升序 / 降序（日期类默认降序，名称类默认升序）。
    @Published var sortAscending: Bool = false {
        didSet { persistViewPreference(SettingsKeys.sortAscending, sortAscending ? "1" : "0") }
    }
    @Published var searchText: String = "" {
        // 搜索清空后不再保留「模块内」的来源指定，避免带到下一次搜索。
        didSet {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingSearchScope = nil
            }
        }
    }
    /// 模块内搜索下沉：模块只声明来源，统一搜索页按该来源打开。
    @Published var pendingSearchScope: SearchSourceKind?
    /// 从模块内发起搜索：范围切到「模块内」，统一搜索页只调度该模块自己的来源。
    func startModuleSearch(_ scope: SearchSourceKind, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearchScope = scope
        searchScope = .module
        searchText = trimmed
    }
    /// 自然语言搜索扩展出的标准标签（由本地 SigLIP 文本编码器异步计算）。
    @Published var semanticSearchTags: [String] = []
    /// 搜索范围三档：全局（默认）/ 模块内（本功能）/ 窗口内（当前窗口）。
    @Published var searchScope: SearchScope = .global
    /// 搜索结果跳转现场（nil = 当前不是从搜索点进来的）。
    @Published var searchReturn: SearchReturnSnapshot?
    /// 返回搜索时要恢复的关键词与筛选，由搜索页在出现时消费。
    @Published var pendingSearchRestore: SearchReturnSnapshot?
    var semanticSearchQuery = ""
    var semanticSearchTask: Task<Void, Never>?
    /// ⌘F 聚焦请求：自增一次即让顶栏搜索框获得焦点。
    @Published var searchFocusRequest = 0
    /// 选择状态独立成模型，避免选中项变化导致图库整体刷新。
    let selectionModel = SelectionModel()
    var selection: Set<UUID> {
        get { selectionModel.ids }
        set { selectionModel.ids = newValue }
    }
    /// 键盘导航时请求网格滚动到指定照片。
    @Published var scrollTargetID: UUID?
    /// 消费 `scrollTargetID` 时是否只用「最小滚动」（目标已可见就不动）。
    /// 关闭查看器时用最小滚动：否则网格会在查看器淡出的同时整体跳到居中，看起来像残影。
    var scrollTargetMinimal = false
    /// 月总览里请求滚动到指定月份分段。
    @Published var scrollTargetSection: String?
    /// 顶栏副标题：网格当前可见区域的日期范围，随滚动动态更新。
    @Published var visibleDateSpanText = ""
    var selectionAnchorID: UUID?

    /// 查看器 / 编辑器状态独立成模型。
    let viewerModel = ViewerModel()
    var viewerID: UUID? {
        get { viewerModel.viewerID }
        set { viewerModel.viewerID = newValue }
    }
    var editorID: UUID? {
        get { viewerModel.editorID }
        set { viewerModel.editorID = newValue }
    }
    /// 从某张照片复制下来的编辑点（JSON）。
    @Published var copiedEditRecipe: String?
    var showInfoPanel: Bool {
        get { viewerModel.showInfoPanel }
        set { viewerModel.showInfoPanel = newValue }
    }
    @Published var showNewAlbumSheet = false
    /// 「新建图库」向导：确认名称、位置、能力与库级设置后才真正建库并切过去。
    @Published var showNewLibrarySheet = false
    /// 命名弹窗（新建 / 重命名本地与系统相簿、文件夹）。由侧边栏统一呈现，
    /// 菜单快捷键与右键菜单都往这里写，只有一个弹窗，不会互相顶掉。
    @Published var namePrompt: NamePromptPayload?
    @Published var showLibraryInfo = false
    @Published var showKeywordManager = false
    @Published var showShortcutHelp = false
    @Published var showSlideshow = false
    /// 智能助手面板（只读问答 + 检索建议）。
    @Published var showAIAssistant = false
    @Published var aiMessages: [AIChatMessage] = []
    @Published var aiInput = ""
    @Published var aiConfig = AIConfig()
    @Published var aiIsResponding = false
    /// 正在执行的步骤（如「读取影院目录」「写回匹配结果」），用于对话里的运行状态。
    @Published var aiActivity: String?
    @Published var aiError: String?
    /// 影院「一键智能整理」期间跳过逐轮确认：入口本身就是用户授权，且只放行影院写工具。
    var aiAutoMatchCinema = false
    /// 最近一次 search_cinema_candidates 的候选：apply_cinema_match 按 candidate_id 取回完整元数据。
    var aiCinemaCandidateCache: [String: CinemaMatch] = [:]
    /// 目录 NFO 缓存：同一目录只解析一次；没有 NFO 的目录也记住。
    var cinemaNFOByFolder: [String: CinemaNFO] = [:]
    var cinemaNFOEmptyFolders: Set<String> = []
    /// 本地目录监听（FSEvents）：只在本地 originals 目录有变化时刷新影院。
    var localCinemaWatcher: LocalCinemaWatcher?
    @Published var activeMemory: PhotoMemory?
    /// 正在查看的旅行故事线。
    @Published var activeTrip: TripStory?

    /// 尚未选择图库：必须先新建或打开一个 .photoslibrary 才能进入主界面。
    @Published var needsLibrarySetup = false
    /// 图库选择器（按住 Option 启动时自动弹出）。
    @Published var showLibraryPicker = false
    /// 启动时就弹出的图库选择器：选定之前不打开任何图库，主界面先保持空白。
    @Published var libraryPickerOnLaunch = false

    @Published var showImportSheet = false
    @Published var showPhotoPicker = false
    @Published var importPanelOpenRequest = 0
    @Published var importCandidates: [ImportCandidate] = []
    @Published var importProgress: ImportProgress?
    @Published var isImporting = false
    @Published var importCancelled = false

    /// 图库保险库：备份 / 校验 / 恢复的界面状态。
    @Published var vaultProgress: VaultProgress?
    @Published var vaultReport: VaultReport?
    @Published var vaultBackupPath: String?
    @Published var vaultLastBackupDate: Date?

    @Published var showCompressionSheet = false
    @Published var compressionTargets: Set<UUID> = []
    @Published var compressionSettings = CompressionSettings()
    @Published var compressionEstimates: [UUID: CompressionEstimate] = [:]
    @Published var compressionEstimating = false

    /// 批量更改（标题 / 拍摄日期 / 地点）。
    @Published var showBatchChangeSheet = false
    @Published var batchChangeTargets: Set<UUID> = []

    /// 导出设置面板。
    @Published var showExportSheet = false
    @Published var exportOptions = ExportOptions()
    @Published var exportTargets: Set<UUID> = []
    @Published var compressionProgress: CompressionProgress?
    @Published var isCompressing = false

    /// 删除前的确认请求：界面层先展示优雅提示，用户确认后才真正删除。
    /// 移到最近删除、永久删除与清空最近删除都走这里；智能助手等已有自己确认流程的入口可直接调 `delete`。
    @Published var pendingDeletion: DeleteRequest?

    /// 断开系统图库 / 网络存储前的确认请求（只移除连接与本机缓存，不动原始数据）。
    @Published var pendingDisconnect: DisconnectRequest?

    @Published var systemLibraryPath: String?
    @Published var systemLibraryName: String?
    /// 搜索里点开网盘文件时暂存的文件路径：目录数据就绪后自动打开查看器。
    @Published var pendingCloudOpenPath: String?
    /// 当前打开并作为拾光系统图库的容器路径；切换图库后设置页会即时刷新。
    @Published var containerLibraryPath: String?
    /// 侧边栏「系统图库」里展示的所有已连接图库。
    @Published var systemLibraries: [SystemLibraryRef] = []
    /// 打开过的全部图库：第一条是系统默认图库，其余都是挂载图库。
    /// 全局持久化，切换 / 新建图库后不会把之前的图库弄丢。
    @Published var knownLibraries: [SystemLibraryRef] = []
    /// 系统默认图库路径：第一次打开的那个图库，固定不变、不可移除。
    @Published var defaultLibraryPath: String?
    @Published var systemPhotos: [PhotoItem] = [] {
        didSet { contentRevision &+= 1 }
    }
    /// 官方「照片」图库照片的拾光补充元数据（收藏 / 隐藏 / 查看时间 / 关键词 / 标题）。
    /// 只存在当前图库自己的 `Luma.sqlite`，不写回 `Photos.sqlite`。
    var systemOverlays: [UUID: MetadataStore.AssetOverlay] = [:]
    /// 收藏 / 隐藏叠加的变更版本：收藏汇总只关心这类变化，
    /// 不能跟着 `contentRevision`（后台计数、识别回填都会改它）反复重建上万条收藏。
    var systemFavoritesRevision = 0
    @Published var systemAlbums: [SystemAlbumInfo] = [] {
        didSet {
            contentRevision &+= 1
            systemStructureRevision &+= 1
        }
    }
    @Published var systemFolders: [SystemFolderInfo] = [] {
        didSet {
            contentRevision &+= 1
            systemStructureRevision &+= 1
        }
    }
    /// 相簿 / 文件夹结构版本：与逐批到达的照片增量分离，
    /// 避免扫描过程中每 2000 张就重建一次上万个相簿的分桶与排序。
    var systemStructureRevision = 0
    /// 系统相簿主键索引：侧边栏封面与按 ID 查找不再线性扫全量相簿数组。
    var systemAlbumIndex: [Int64: SystemAlbumInfo] = [:]
    /// 侧边栏相簿项目数缓存：索引模式下每次取数都是一条 SQL COUNT，
    /// 上千个相簿滚动时按结构版本缓存，避免每帧每个可见行都查一次库。
    var systemAlbumCountCache: [Int64: Int] = [:]
    var systemAlbumCountCacheRevision = -1
    /// 侧边栏计数（有效 / 隐藏 / 删除 / 重复等）的合并缓存，按内容版本失效。
    var systemCountsCache: SystemSidebarCounts?
    var systemCountsCacheRevision = -1
    @Published var systemPeople: [SystemPersonInfo] = []
    @Published var selectedPerson: SystemPersonInfo?
    /// 本地图库的端侧人物聚类结果。
    @Published var localPeople: [LocalPerson] = []
    @Published var selectedLocalPersonID: UUID?
    @Published var isClusteringFaces = false
    @Published var faceClusterProgress: FaceClusterProgress?
    /// 照片 → 已命名人物的反向索引：查看器在画面上打名字时用，避免每次重绘都扫全部聚类。
    var photoPersonNamesIndex: [UUID: [PhotoPersonName]] = [:]
    var photoPersonNamesIndexKey = ""
    /// 端侧智能分析索引（场景标签 + OCR 文字），仅本地图库。
    @Published var analysisIndex: [UUID: PhotoAnalysis] = [:]
    @Published var isAnalyzingIntelligence = false
    @Published var intelligenceDone = 0
    @Published var intelligenceTotal = 0
    /// 系统图库的端侧识别结果（场景 / 图内文字）。内存即时刷新，并写入当前图库的 `system_analysis`。
    @Published var systemAnalysisIndex: [UUID: PhotoAnalysis] = [:]
    /// 系统图库的端侧特征向量（相似检索 / 体检时写入，缓存到 `system_analysis.feature`）。
    @Published var systemFeatures: [UUID: Data] = [:]
    /// 本次运行中用户是否主动开启过系统图库内容识别。
    /// 只有开启过才在新照片出现时自动续跑；打开图库不会默认扫描场景。
    /// 该状态会按系统图库路径持久化，关库 / 切库回来能接着识别。
    var systemAnalysisAutoResume = false
    /// 正在把落库的识别结果读回内存；识别任务开始前会先等它完成。
    var systemAnalysisHydration: Task<Void, Never>?
    @Published var isAnalyzingSystemContent = false
    @Published var systemAnalysisDone = 0
    @Published var systemAnalysisTotal = 0
    /// 「查找相似照片」的临时范围；导航到其它范围时清空。
    @Published var similarScope: SimilarityScope?
    /// 图库体检结果（模糊照片、相似连拍、大视频）。本地结果写这里；网盘结果在 `CloudBrowserModel.healthReport`。
    @Published var healthReport: LibraryHealthReport?
    /// 体检结果来源："system" 表示系统图库，nil 表示本地图库。
    var healthReportScopeTag: String?
    @Published var isScanningHealth = false
    /// 暂停后正在补齐相似连拍与落盘的短暂时段。
    @Published var isFinalizingHealth = false
    @Published var healthScanProgress = 0.0
    /// 智能美化扫描结果与批量应用进度；推荐结果按范围写入 `derived_reports`，系统图库 / 网盘默认另存副本到本地图库。
    @Published var beautyReport: BeautyReport?
    /// 当前美化推荐是否来自系统图库（与本地 / 网盘结果互不通用）。
    var beautyReportIsSystem = false
    @Published var isScanningBeauty = false
    @Published var beautyScanProgress = 0.0
    @Published var isApplyingBeauty = false
    @Published var beautyApplyProgress = 0.0
    @Published var showBeautyPanel = false
    @Published var isLoadingSystemLibrary = false
    /// 系统图库扫描进度（已读取的资源数）。
    @Published var systemScanCount = 0
    /// 系统图库中的项目总数。
    @Published var systemTotalAssetCount = 0
    @Published var systemLibraryError: String?

    // MARK: 影院刮削
    /// 各作用域（本地图库 / 每个网盘）的刮削结果，按视频 photoID 索引。
    @Published var cinemaIndexes: [CinemaScope: [UUID: CinemaEntry]] = [:] {
        didSet { cinemaDataRevision &+= 1 }
    }
    /// 当前正在查看的影院作用域。
    @Published var cinemaActiveScope: CinemaScope = .local
    /// 影院顶栏的分段（全部 / 电影 / 电视剧），与内容页共用。
    @Published var cinemaTab: CinemaTab = .all
    /// 影院的浏览姿态（书架 / 海报墙 / 列表）；写入本地偏好，下次进入保持。
    /// 默认改成海报墙：旧版本默认书架，这里做一次性迁移，之后再改就按用户自己的来。
    @Published var cinemaViewMode: CinemaViewMode = LibraryStore.initialCinemaViewMode {
        didSet {
            UserDefaults.standard.set(cinemaViewMode.rawValue, forKey: "cinema_view_mode")
        }
    }

    private static var initialCinemaViewMode: CinemaViewMode {
        let defaults = UserDefaults.standard
        let modeKey = "cinema_view_mode"
        let migratedKey = "cinema_view_mode_wall_default"
        var raw = defaults.string(forKey: modeKey)
        if !defaults.bool(forKey: migratedKey) {
            defaults.set(true, forKey: migratedKey)
            if raw == nil || raw == CinemaViewMode.shelf.rawValue {
                raw = CinemaViewMode.wall.rawValue
                defaults.set(raw, forKey: modeKey)
            }
        }
        return CinemaViewMode(rawValue: raw ?? "") ?? .wall
    }

    /// 影院的年份筛选（具体年份，如 2024），空集合表示全部；可多选。
    @Published var cinemaYears: Set<Int> = [] { didSet { bumpCinemaFilters() } }
    /// 影院的类型筛选（剧情 / 科幻 / 悬疑……），空集合表示全部；可多选。
    @Published var cinemaGenres: Set<String> = [] { didSet { bumpCinemaFilters() } }
    /// 顶栏内容类型（动漫 / 综艺 / 演唱会 / 纪录片 / 其它 TMDB 类型）；nil 表示全部。
    /// 与「类型」多选筛选不同：它是影院的一级入口，单选。
    @Published var cinemaTypeFilterID: String? = nil { didSet { bumpCinemaFilters() } }
    /// 内容形态筛选（电影 / 电视剧），空集合表示全部；可多选。
    @Published var cinemaKindFilters: Set<CinemaMediaKind> = [] { didSet { bumpCinemaFilters() } }
    /// 地区（出品国家）筛选，空集合表示全部；可多选。
    @Published var cinemaCountries: Set<String> = [] { didSet { bumpCinemaFilters() } }
    /// 语言筛选：存 ISO 代码，界面翻译成中文；空集合表示全部；可多选。
    @Published var cinemaLanguages: Set<String> = [] { didSet { bumpCinemaFilters() } }
    /// 片长分档，空集合表示全部；可多选。
    @Published var cinemaRuntimeFilters: Set<CinemaRuntimeFilter> = [] { didSet { bumpCinemaFilters() } }
    /// 评分分档，空集合表示全部；可多选。
    @Published var cinemaRatingFilters: Set<CinemaRatingFilter> = [] { didSet { bumpCinemaFilters() } }
    /// 分辨率筛选；空集合表示全部；可多选。
    @Published var cinemaResolutions: Set<CinemaResolutionFilter> = [] { didSet { bumpCinemaFilters() } }
    /// 观看状态筛选；空集合表示全部；可多选。
    @Published var cinemaWatchFilters: Set<CinemaWatchFilter> = [] { didSet { bumpCinemaFilters() } }
    /// 规格筛选：杜比视界 / HDR / 杜比全景声 / 高帧率；空集合表示全部。
    @Published var cinemaSpecFilters: Set<CinemaSpecFilter> = [] { didSet { bumpCinemaFilters() } }
    /// 智能筛选：评分 8 以上 / 最近 30 天添加。
    @Published var cinemaSmartHighRated = false { didSet { bumpCinemaFilters() } }
    @Published var cinemaSmartRecent = false { didSet { bumpCinemaFilters() } }
    /// 排序方式；写入本地偏好，下次进入保持。
    @Published var cinemaSort: CinemaSort = CinemaSort(
        rawValue: UserDefaults.standard.string(forKey: "cinema_sort") ?? ""
    ) ?? .recent {
        didSet {
            UserDefaults.standard.set(cinemaSort.rawValue, forKey: "cinema_sort")
            bumpCinemaFilters()
            // 切到随机排序时立刻换一批顺序，让用户看到「重排」生效。
            if cinemaSort == .random {
                cinemaShuffleSeed = UInt64.random(in: 1...UInt64.max)
            }
        }
    }
    /// 筛选条件变化：只自增版本号，聚合签名 O(1) 判断是否需要重算。
    func bumpCinemaFilters() {
        cinemaFilterRevision &+= 1
    }
    /// 随机排序的本次会话种子：进入影院 / 切到随机时重新生成。
    var cinemaShuffleSeed: UInt64 = UInt64.random(in: 1...UInt64.max)
    /// 正在刮削的作用域，用于对应网盘的侧边栏显示进度。
    @Published var cinemaScrapeScope: CinemaScope?
    @Published var cinemaScrapeRunning = false
    /// 当前刮削任务：取消按钮直接 cancel，循环与网络请求都会尽快退出。
    var cinemaScrapeTask: Task<Void, Never>?
    @Published var cinemaScrapeDone = 0
    @Published var cinemaScrapeTotal = 0
    @Published var cinemaScrapeMessage: String?
    /// 影院刮削的结构化错误：统一错误卡据此展示重试 / 改配置。
    @Published var cinemaSourceError: SourceError?
    /// 设置面板里「测试连接」的运行状态与结果。
    @Published var cinemaConnectionTesting = false
    @Published var cinemaConnectionResult: CinemaConnectionResult?
    /// 从影院打开的视频快照：即使该网盘目录没有加载，也能直接进查看器播放。
    var cinemaPlaybackPhoto: PhotoItem?
    /// 影院续播记录，按视频 photoID 索引；只存快照，不依赖刮削索引仍然存在。
    @Published var cinemaProgress: [UUID: CinemaProgressRecord] = [:] {
        didSet { cinemaDataRevision &+= 1 }
    }
    /// 影院索引是否完成首次读取：首屏用它决定显示骨架屏还是空态。
    @Published var cinemaIndexLoaded = false
    /// 影院播放队列：从海报墙 / 剧集详情开播时带上当前上下文。
    /// 播完或按「下一集」时在这里前进，不再依赖查看器的照片列表。
    @Published var cinemaQueue: [CinemaEntry] = []
    /// 详情页返回记忆：每部剧记住上次看的季与选中集，不写 UserDefaults。
    var cinemaSeriesMemory: [String: CinemaSeriesMemory] = [:]
    /// 影院本地用户状态：收藏 / 想看 / 个人评分。
    @Published var cinemaUserStates: [UUID: CinemaUserState] = [:] {
        didSet { cinemaDataRevision &+= 1 }
    }
    /// 已忽略的视频：不再参与刮削，也不出现在影院列表里。
    @Published var cinemaIgnoredIDs: [CinemaScope: Set<UUID>] = [:] {
        didSet { cinemaDataRevision &+= 1 }
    }
    /// 正在删除原文件的条目：右键菜单据此禁用重复点击。
    @Published var cinemaDeletingIDs: Set<UUID> = []
    /// 自定义清单（手动选片）。
    @Published var cinemaLists: [CinemaListRecord] = [] {
        didSet { cinemaDataRevision &+= 1 }
    }
    /// 当前正在按清单筛选；nil 表示未筛选。
    @Published var cinemaActiveListID: UUID? { didSet { bumpCinemaFilters() } }
    /// 是否只看收藏。
    @Published var cinemaFavoritesOnly = false { didSet { bumpCinemaFilters() } }
    /// 多版本默认文件：版本键 → 用户指定的 photoID。
    /// 卡片与剧集聚合优先用这一版，其余版本仍在详情页可选。
    @Published var cinemaDefaultVersions: [String: UUID] = [:] {
        didSet { cinemaDataRevision &+= 1 }
    }
    /// 影院搜索面板与观看记录面板的显示状态。
    @Published var cinemaSearchVisible = false
    /// 从网络资源 / 全局搜索跳进影院时带过来的关键词：面板打开后用一次就清空。
    @Published var cinemaSearchSeed: String?
    @Published var cinemaHistoryVisible = false
    /// 影院详情是否正以页面内铺满的方式打开：顶栏控制台据此切到「返回」形态。
    @Published var cinemaDetailOpen = false
    /// 顶栏「返回」的自增信号；影院页收到后收起详情。
    @Published var cinemaDetailCloseTick = 0
    /// 文件夹视图当前钻到第几层（0 = 顶层）：顶栏据此也切到「返回」形态。
    @Published var cinemaFolderDepth = 0
    /// 顶栏「返回」在文件夹视图里的自增信号；影院页收到后回上一级目录。
    @Published var cinemaFolderCloseTick = 0
    /// 顶栏「新建清单…」请求。
    @Published var cinemaNewListVisible = false
    /// 统一任务中心的历史记录：刮削 / 扫描 / 导入 / 录制共用一套，退出应用后仍可回看。
    @Published var sourceJobHistory: [JobProgress] = []
    /// 通知中心：任务结果归档（今天 / 本周分组，保留 30 天）。
    @Published var cinemaNotificationsVisible = false
    @Published var cinemaNotifications: [CinemaNotification] = []
    /// 右上角 Toast 栈（最多 3 条）；成功类 4 秒自动消失，失败 / 进度常驻。
    @Published var cinemaToasts: [CinemaToast] = []
    var cinemaToastTasks: [UUID: Task<Void, Never>] = [:]
    /// 家长控制本次会话是否已用 PIN 解锁；退出应用后重新上锁。
    @Published var cinemaParentalUnlocked = false
    /// 家长控制解锁面板。
    @Published var cinemaPINPromptVisible = false
    /// 相簿里右键「手动匹配」的目标视频；由 RootView 统一弹出匹配面板。
    @Published var cinemaQuickMatch: CinemaQuickMatchRequest?
    /// 文件夹视图的刷新信号：匹配 / 刮削 / 清空索引后自增。
    @Published var cinemaFolderRefreshToken = 0
    /// 剧集级跳过片头 / 片尾设置，按 CinemSeries.id 索引。
    @Published var cinemaIntroMarks: [String: CinemaIntroMark] = [:]
    /// 单集覆盖：按 CinemaEntry.id 索引，优先级高于整部剧的默认值。
    @Published var cinemaEpisodeIntroMarks: [String: CinemaIntroMark] = [:]
    /// 已经尝试过在线片头识别的剧集键：查不到的不再反复请求。
    var cinemaIntroAutoTried: Set<String> = []
    /// 已经尝试过在线片头识别的单集：失败的不在每次播放时重试。
    var cinemaEpisodeIntroTried: Set<String> = []
    /// 下一集预热好的流（只保留一个）。
    var cinemaPrewarmedStream: CinemaPrewarmedStream?
    /// 正在预热的任务：换目标时先取消。
    var cinemaPrewarmTask: Task<Void, Never>?
    /// 预热目标：避免进度回调每秒都取消重开同一个预热。
    var cinemaPrewarmTarget: UUID?
    /// 当前从影院打开的视频条目：查看器内的播放进度会写回这条记录。
    var cinemaPlaybackEntry: CinemaEntry?

    /// 网盘状态独立成模型；这里保留同名转发，Store 扩展方法无需改动。
    let cloudModel = CloudBrowserModel()
    /// 网络资源（影视源）状态：与网盘并列，但不参与图库索引与扫描。
    let catalogModel = CatalogBrowserModel()
    /// 网络电视：默认开启，内置大陆 / 港 / 台三条公开列表。
    let tvModel = IPTVBrowserModel()
    /// 网络影院当前分页（影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注）：侧边栏快捷行与页面共用。
    @Published var networkCinemaTab: NetworkCinemaTab = NetworkCinemaTab.persisted {
        didSet {
            guard networkCinemaTab != oldValue else { return }
            UserDefaults.standard.set(networkCinemaTab.rawValue,
                                      forKey: NetworkCinemaTab.storageKey)
        }
    }
    /// 网络影院当前只看某个影视源；nil 表示全部来源。
    @Published var networkCinemaSourceID: UUID? = nil
    /// 站点页当前选中的一级 / 二级分类：页面与顶栏控制台共用同一份。
    @Published var networkCinemaTopCategoryID: String?
    @Published var networkCinemaSubCategoryID: String?
    /// 站点页顶栏的搜索词：只过滤当前已加载的内容，不跳转模块搜索。
    @Published var networkCinemaSourceQuery: String = ""
    /// 网络影院排序：页面筛选条与站点页顶栏共用，切换后当前列表立即重排。
    @Published var networkCinemaSort: NetworkCinemaSort = .recent
    /// 全局搜索点开某个网络影院条目：页面出现时消费并清空，直接停在详情页。
    @Published var networkCinemaPendingItem: NetworkCinemaItem?
    /// 网络影院当前打开的详情（nil = 分页 / 列表）：顶栏的返回与标题胶囊据此显示。
    @Published var networkCinemaDetail: NetworkCinemaItem?
    /// 从全局搜索空态跳过来时带上的关键词：页面出现时填进页内搜索框。
    @Published var networkCinemaSearchSeed: String?
    /// 跨图库搜索点开的条目：目标图库加载完成后消费，打开照片 / 相簿 / 人物。
    @Published var pendingLibraryOpen: LibraryPendingOpen?
    /// 网络影院：跨源列表、搜索与 TMDB / 豆瓣资料补全。
    /// 放在 Store 上是为了切页后探测与补全继续跑，进度在左下角任务条可见。
    lazy var networkCinemaModel: NetworkCinemaModel = {
        let model = NetworkCinemaModel()
        model.jobCenter = sourceJobCenter
        model.onJobChange = { [weak self] in self?.sourceJobRevision &+= 1 }
        model.onJobFinished = { [weak self] id in self?.archiveSourceJob(id) }
        return model
    }()
    /// 统一后台任务中心：云盘扫描、资源健康 / 日历、影院刮削共用。
    let sourceJobCenter = SourceJobCenter()
    /// 任务进度变化时自增，界面据此刷新任务条。
    @Published var sourceJobRevision = 0
    /// 统一续播存储：影院与网络资源共用一套读写接口（只适配，不迁移数据）。
    lazy var playbackProgressStore = SourcePlaybackProgressStore(library: self,
                                                                 catalog: catalogModel)
    /// 源运行时：注册表 + 统一激活入口 + 源会话。
    lazy var sourceHub = SourceHubModel(store: self)
    /// 播放协调器：解析 target → 会话；现有 PhotoItem 流程也经它补模式与能力。
    lazy var playbackCoordinator = PlaybackCoordinator(resolver: LibraryPlaybackProvider(store: self))
    private var contentSnapshotStore: FileContentSnapshotStore?
    /// 源内容快照：新源 / 新页面先铺上次内容，再后台刷新。
    /// 换图库后快照目录跟着换，所以用可重置的懒加载而不是一次性 lazy。
    var contentSnapshots: FileContentSnapshotStore {
        if let contentSnapshotStore { return contentSnapshotStore }
        let store = FileContentSnapshotStore(directory: LibraryPaths.sourceSnapshotsDir)
        contentSnapshotStore = store
        return store
    }
    /// 源修订号：内容变化时自增，界面与快照据此判断是否重读。
    let sourceRevisions = SourceRevisionTracker()
    /// 快照 + 修订号的统一入口：仓库读写、首屏恢复都走它。
    lazy var sourceContentCache = SourceContentCache(store: self)

    /// 统一入库入口：电视录制 / 影院缓存 / 资源站保存都走它。
    lazy var ingestService = LibraryIngestService(store: self)

    /// 按源能力注册的 AI 工具：影院 / 资源等模块自己声明定义与执行。
    lazy var aiToolRegistry = AIToolRegistry(providers: [
        AIToolProviders.cinema(store: self),
        AIToolProviders.catalog(store: self),
        AIToolProviders.networkCinema(store: self),
        AIToolProviders.television(store: self)
    ])
    /// 发给模型的完整工具定义：中央工具 + 各 provider。
    var aiToolDefinitions: [AIRequestTool] { AILibraryTools.definitions + aiToolRegistry.definitions }

    /// 详情补全：影院等来源在仓库返回后追加元数据。
    lazy var metadataEnrichers: MetadataEnricherCenter = {
        let center = MetadataEnricherCenter()
        center.register(CinemaMetadataEnricher(store: self))
        center.register(NetworkCinemaMetadataEnricher(store: self))
        return center
    }()

    /// 换图库：快照目录与修订号都属于上一个图库，整体作废后按新路径重建。
    func resetSourceContentCache() {
        contentSnapshotStore = nil
        sourceRevisions.resetAll()
        sourceContentCache.prune()
    }
    /// 网络资源播放：每集一个虚拟视频，交给查看器翻页与播放。
    var catalogPlaybackPhotos: [PhotoItem] = []
    var catalogPlaybackContexts: [UUID: CatalogPlaybackContext] = [:]
    /// 网络电视播放：一个频道映射成一个虚拟视频，直播不写续播进度。
    var tvPlaybackPhotos: [PhotoItem] = []
    var tvPlaybackChannels: [UUID: TVChannel] = [:]
    /// 回看条目：播放模式走点播，播放器显示进度条而不是直播沿。
    var tvCatchupPhotoIDs: Set<UUID> = []
    /// 电视线路切换代次：自增后播放层会重新载入当前线路。
    @Published var tvLineTokens: [UUID: Int] = [:]
    /// 当前线路下标与本轮已失败的线路：自动顺延时避免在两条坏线之间来回跳。
    var tvLineIndexes: [UUID: Int] = [:]
    var tvFailedLineIndexes: [UUID: Set<Int>] = [:]
    /// 每条线路的失败原因：失败卡片逐条列出「线路 2 返回 403」。
    var tvLineFailureNotes: [UUID: [Int: String]] = [:]
    /// 每条线路的请求头与协议：跨源并入的同名频道和主线路可能不同（HLS / HTTP-FLV）。
    var tvLineMetadata: [String: TVLineMetadata] = [:]
    /// 续播起播秒数：等播放器载入新分集后消费一次。
    var catalogPendingSeek: Double?
    /// 从网络资源详情页起播时记下的返回目标：关闭播放器后回到该详情，而不是频道列表。
    var catalogReturnSourceID: UUID?
    var catalogReturnItem: CatalogItem?
    var cloudMounts: [CloudMount] {
        get { cloudModel.mounts }
        set { cloudModel.mounts = newValue }
    }
    var cloudFolders: [CloudEntry] {
        get { cloudModel.folders }
        set { cloudModel.folders = newValue }
    }
    var cloudPhotos: [PhotoItem] {
        get { cloudModel.photos }
        set { cloudModel.photos = newValue }
    }
    var cloudPath: String {
        get { cloudModel.path }
        set { cloudModel.path = newValue }
    }
    var cloudTrail: [CloudCrumb] {
        get { cloudModel.trail }
        set { cloudModel.trail = newValue }
    }
    var cloudLoading: Bool {
        get { cloudModel.loading }
        set { cloudModel.loading = newValue }
    }
    var cloudError: String? {
        get { cloudModel.error }
        set { cloudModel.error = newValue }
    }
    var showCloudSheet: Bool {
        get { cloudModel.showSheet }
        set { cloudModel.showSheet = newValue }
    }
    var cloudSheetMount: CloudMount? {
        get { cloudModel.sheetMount }
        set { cloudModel.sheetMount = newValue }
    }
    var showCloudWizard: Bool {
        get { cloudModel.showWizard }
        set { cloudModel.showWizard = newValue }
    }
    var cloudWizardInitialFlow: CloudWizardFlow? {
        get { cloudModel.wizardInitialFlow }
        set { cloudModel.wizardInitialFlow = newValue }
    }
    var cloudWizardEditingMountID: UUID? {
        get { cloudModel.wizardEditingMountID }
        set { cloudModel.wizardEditingMountID = newValue }
    }
    var cloudNameRequest: CloudNameRequest? {
        get { cloudModel.nameRequest }
        set { cloudModel.nameRequest = newValue }
    }
    var cloudBusyText: String? {
        get { cloudModel.busyText }
        set { cloudModel.busyText = newValue }
    }

    @Published var toast: String?

    var toastTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var compressionTask: Task<Void, Never>?
    /// 打开相簿 / 文件夹后的缩略图预热任务，切换范围时取消。
    var thumbnailPrewarmTask: Task<Void, Never>?
    var compressionEstimateTask: Task<Void, Never>?
    var compressionCancelled = false
    var intelligenceTask: Task<Void, Never>?
    var intelligenceCancelled = false
    var systemAnalysisTask: Task<Void, Never>?
    var systemAnalysisCancelled = false
    var aiTask: Task<Void, Never>?
    /// 最近一次发给模型的候选照片顺序，用于解析工具参数里的「#3」这类编号。
    var aiLastCandidateIDs: [UUID] = []
    /// 候选照片的文件名到 id，解析模型直接写文件名的情况。
    var aiLastCandidateNames: [String: UUID] = [:]
    /// 网络资源工具最近一次返回的候选：ref（`#1`）或 `sourceID|itemID` → 源与条目。
    /// 播放入口与稍后看都靠它把模型看到的编号还原成具体条目。
    var aiCatalogCandidates: [String: (sourceID: UUID, item: CatalogItem)] = [:]
    var healthTask: Task<Void, Never>?
    /// 体检任务标识：取消或重新开始后，旧任务不再写回进度与结果。
    var healthScanToken = UUID()
    var beautyTask: Task<Void, Never>?
    var sceneCountsCacheKey: String?
    var sceneCountsCache: [String: Int] = [:]
    /// 系统图库待识别数量：随照片窗口与已识别数量缓存，避免侧边栏悬停时反复遍历整库。
    var systemPendingAnalysisCacheKey: String?
    var systemPendingAnalysisCache = 0
    /// 场景总览（数量 + 封面）一次遍历缓存。
    var sceneSummaryCacheKey: String?
    var sceneSummaryCache = SceneSummary()
    /// 媒体类型总览（数量 + 封面）一次遍历缓存。
    var mediaTypeSummaryCacheKey: String?
    var mediaTypeSummaryCacheValue = MediaTypeSummary()
    /// 「更多项目」总览卡片封面（按入口缓存，内容版本变化时失效）。
    var moreItemsCoverToken: String?
    var moreItemsCoverCache: [SidebarItem: PhotoItem] = [:]
    var moreItemsCoverMissing: Set<SidebarItem> = []
    /// 关键词卡片墙的封面（按关键词缓存，内容版本变化时失效）。
    var keywordCoverToken: String?
    var keywordCoverCache: [String: PhotoItem] = [:]
    var keywordCoverMissing: Set<String> = []
    /// 重复项目分组一次遍历缓存（按内容版本失效）。
    var duplicateGroupsCacheKey: String?
    var duplicateGroupsCache: [DuplicateGroup] = []
    /// 查重 2.0：相似照片组与哈希扫描状态。
    @Published var similarPhotoGroups: [SimilarPhotoGroup] = []
    @Published var isScanningHashes = false
    @Published var hashScanCompleted = 0
    @Published var hashScanTotal = 0
    var hashScanTask: Task<Void, Never>?
    var hashScanToken = UUID()
    /// 系统图库重复项目分组（首次打开重复页时在后台计算，结果按内容版本缓存）。
    @Published var systemDuplicateGroupsCache: [DuplicateGroup] = []
    /// 重复分组失效计数：界面用 `.task(id:)` 监听，变化后重新触发后台计算。
    @Published var systemDuplicateGroupsToken = 0
    @Published var isLoadingSystemDuplicates = false
    var systemDuplicateGroupsCacheKey: String?
    var systemDuplicateGroupsTask: Task<Void, Never>?
    var metadataStore: MetadataStore?
    var systemPhotoIndex: [UUID: PhotoItem] = [:]
    /// 最近在系统图库窗口 / 查看器里出现过的照片。
    /// 顶栏收藏态、查看记录这些在 SwiftUI body 里会被高频读取，
    /// 每次去查 Photos.sqlite 会排队等索引任务的锁，启动期直接卡住主线程。
    var systemRecentPhotos: [UUID: PhotoItem] = [:]
    /// 已完成扫描的系统图库路径；再次点击同一个图库时只切换页面，不重复扫描。
    var systemLibraryLoadedPath: String?
    /// 系统图库载入令牌：每次载入递增，旧扫描的结果不再写回状态与缓存。
    var systemLoadToken = 0
    var terminateObserver: NSObjectProtocol?
    /// 回到前台时校验当前网盘索引的新鲜度（影院 / 网盘浏览页）。
    var activationObserver: NSObjectProtocol?

    var cloudDirectoryCache: [String: (folders: [CloudEntry], photos: [PhotoItem])] = [:]
    var cloudLoadToken = 0

    /// 云照片的本地收藏（"mountID|path"），只记录在拾光本地，不写回网盘。
    @Published var cloudFavorites: Set<String> = []
    /// 云照片的本地关键词（"mountID|path" → 标签数组），只记录在拾光本地，不写回网盘。
    @Published var cloudKeywords: [String: [String]] = [:]
    /// 云照片的本地评分 / 旗标 / 色标（"mountID|path" → 标记），只记录在拾光本地，不写回网盘。
    @Published var cloudMarks: [String: CloudMark] = [:]
    var cloudVisibleCacheKey: String?
    var cloudVisibleCacheValue: [PhotoItem] = []
    /// 网盘分类计数与场景计数缓存（键含目录版本与识别进度）。
    var cloudScopeCountsCacheKey: String?
    var cloudScopeCountsCache = CloudScopeCounts()
    /// 网盘「相簿」文件夹树与选中目录的子目录集合缓存。
    var cloudFolderTreeCacheKey: String?
    var cloudFolderTreeCacheValue: [CloudFolderNode] = []
    var cloudFolderDescendantCacheKey: String?
    var cloudFolderDescendantCacheValue: Set<String> = []

    var placeCache: [String: PlaceInfo] = [:]
    var placeCacheLoaded = false
    /// 本次会话里逆地理编码失败的查询格：系统会限流，失败后不再反复请求，避免空转。
    var placeResolveFailedKeys: Set<String> = []
    /// 地图页的派生数据：带定位的照片与地点聚类按内容版本缓存，
    /// 避免一次打开地图时在每次 body 求值里重扫整库。
    var geoPhotosCacheKey = -1
    var geoPhotosCacheValue: [PhotoItem] = []
    var placeClustersCacheKey = ""
    var placeClustersCacheValue: [PlaceCluster] = []
    var placeGroupsCacheKey = ""
    var placeGroupsCacheValue: [(title: String, clusters: [PlaceCluster])] = []
    /// 地点聚类 / 分组的缓存令牌：内容版本变化即失效（换成字符串便于和云盘等外部键比较）。
    var placeCacheToken: String { String(contentRevision) }

    /// 图库级撤销 / 重做栈（仅内存，不落盘）：只保存元数据变更的逆操作。
    var undoStack: [LibraryUndoStep] = []
    var redoStack: [LibraryUndoStep] = []
    /// 影院数据版本号：刮削索引 / 观看进度 / 收藏 / 忽略 / 清单任一变化时自增，
    /// 影院页据此复用上一次聚合结果，而不是每次 body 都全量重算。
    var cinemaDataRevision = 0
    /// 影院筛选项版本号：任一筛选 / 排序变化时自增。
    /// 聚合签名只拼两个整数，不再每次 body 都 join 十几个条件数组。
    var cinemaFilterRevision = 0
    /// 影院派生数据快照（条目 / 电影 / 剧集 / 统计 / 字母索引）。
    var cinemaAggregateCacheKey: String?
    var cinemaAggregateCacheValue: CinemaAggregate?
    /// 剧集聚合按作用域缓存：搜索、统计与详情页会反复取同一份结果。
    struct CinemaSeriesCacheEntry {
        let revision: Int
        let matched: [CinemaSeries]
        let unmatched: [CinemaSeries]
    }
    var cinemaSeriesCache: [CinemaScope: CinemaSeriesCacheEntry] = [:]
    /// 菜单标题用的最近一步操作名（随撤销 / 重做更新）。
    @Published var undoActionName: String?
    @Published var redoActionName: String?

    /// 图库内容版本号：数组变更时自增，用于缓存筛选/排序结果。
    var contentRevision = 0
    var visibleCacheKey: String?
    var visibleCacheValue: [PhotoItem] = []
    var sectionsCacheKey: String?
    var sectionsCacheValue: [PhotoSection] = []
    /// 网格滚动时按 id 查拍摄时间；随可见集合指纹缓存，避免每帧遍历全库。
    var dateLookupCacheKey: String?
    var dateLookupCache: [UUID: Date] = [:]
    /// 系统图库侧边栏子项（文件夹 + 相簿混排），按结构版本一次性分组。
    var systemChildrenCacheRevision = -1
    var systemChildrenBuckets: [Int64: [SystemSidebarEntry]] = [:]
    /// 侧边栏系统树拍平后的行缓存：键 = 结构版本 + 展开版本，悬停等无关状态不会触发重算。
    var systemFlatRowsCacheKey = ""
    var systemFlatRowsCache: [SystemFlatRow] = []

    // MARK: - 大图库分页窗口
    //
    // 本地图库超过阈值时，筛选/排序/分段交给 SQLite，Store 只保留当前加载的窗口。
    @Published var windowPhotos: [PhotoItem] = []
    @Published var windowTotal = 0
    @Published var windowVideos = 0
    @Published var isWindowLoading = false
    /// 当前查询的第一页是否已经拿到，用来区分「正在加载」与「确实为空」。
    @Published var hasLoadedWindow = false
    /// 查看器胶片条使用当前照片附近的一小段照片，避免为翻页载入整段窗口。
    @Published var viewerStrip: [PhotoItem] = []
    /// 查看器的外部列表（地图 / 地点 / 卡片墙等非图库网格）：
    /// 非空时序号、总数与左右翻页都以它为准，而不是图库分页窗口。
    var viewerContextPhotos: [PhotoItem] = []
    var windowKeyValue = ""
    var windowQueryKey = ""
    var windowQuery: PhotoQuery?
    var windowStartOffset = 0
    /// 窗口内容变化计数，参与 `visibleStateKey` 让分段缓存失效。
    var windowRevision = 0
    var windowTask: Task<Void, Never>?
    var viewerStripKey: String?
    var viewerStripTask: Task<Void, Never>?

    // 年 / 月总览也走 SQL 分区：只保留每月/每天最多 4 张样本与真实总数。
    @Published var yearBuckets: [PhotoPeriodBucket] = []
    @Published var monthGroups: [PhotoMonthGroup] = []
    @Published var isOverviewLoading = false
    var overviewKeyValue = ""
    var overviewTask: Task<Void, Never>?
    var pendingMonthScrollYear: Int?

    static let windowPageSize = 600
    /// 超过这个数量才启用窗口化：小图库继续走内存路径，行为完全不变。
    static let windowThreshold = 5_000

    // MARK: - 系统图库索引窗口
    //
    // 系统图库超过阈值时不再把整库 `[PhotoItem]` 装进内存：
    // `SystemIndex` 提供 SQL 分页与聚合计数，这里只保留已加载的窗口。
    var systemIndex: SystemIndex?
    /// 索引指纹（路径 + 收录数）：参与分页 key，重建索引后窗口自动刷新。
    var systemIndexSignature = ""
    /// 官方「照片」图库自带的关键词（`Photos.sqlite` 的 `ZKEYWORD`），按关键词汇总资产 ID。
    /// 系统图库载入时读一次；nil 表示尚未读取。
    var systemNativeKeywordIndex: [String: [UUID]]?
    /// 上一条的反查表（资产 ID → 关键词），用于图片信息面板与关键词筛选。
    var systemNativeKeywordIDMap: [UUID: [String]] = [:]
    /// 长曝光 / 电影效果只能由 PhotoKit 智能相簿给出 ID；nil 表示尚未读取或没有照片权限。
    @Published var photoKitLongExposureIDs: Set<UUID>?
    @Published var photoKitCinematicIDs: Set<UUID>?
    var isPhotoKitMediaTypeLoaded = false
    @Published var systemIndexReady = false
    @Published var systemWindowPhotos: [PhotoItem] = []
    @Published var systemWindowTotal = 0
    @Published var systemWindowVideos = 0
    @Published var isSystemWindowLoading = false
    @Published var hasLoadedSystemWindow = false
    var systemWindowKey = ""
    var systemWindowStart = 0
    /// 时间轴窗口在整库里的起始排名（0 = 最新一张）。滚动条进入虚拟占位区时整体重定位窗口。
    @Published var systemWindowStartRank = 0
    /// 时间轴换页后要滚到视野中心的那张照片（只用于换页落地，不参与用户主动定位）。
    @Published var timelineJumpLandingID: UUID?
    var systemWindowQuery: SystemQuery?
    var systemWindowTask: Task<Void, Never>?
    /// 窗口内容变化计数，参与 `visibleStateKey` 让分段缓存失效。
    var systemWindowRevision = 0
    /// 地图 / 足迹回放用的带位置照片缓存（索引模式下取全量）。
    var systemGeoCacheKey: String?
    var systemGeoCache: [PhotoItem] = []
    /// 系统索引查询按范围和输入条件缓存：SwiftUI body 会频繁读取
    /// `systemQuery` / `pagedKey` / `visibleCount`，每次重算会让主线程持续满载。
    var systemQueryCacheSignature: String?
    var systemQueryCache: [String: SystemQuery] = [:]
    /// `SystemQuery.key` 在收藏 / 隐藏叠加很多时会拼出很长的字符串，
    /// 而 `pagedKey` 又在 SwiftUI body 里被反复读取：构建一次后按范围复用。
    var systemQueryKeyCache: [String: String] = [:]
    /// 侧边栏相簿封面：异步查询结果按相簿缓存，body 不再逐行同步查库。
    var systemAlbumCoverCache: [Int64: PhotoItem] = [:]
    var systemAlbumCoverMisses: Set<Int64> = []
    var systemAlbumCoverLoading: Set<Int64> = []

    var viewerPhotoCache: ViewerPhotoCache?
    var viewerIndexCache: ViewerIndexCache?
    /// 查看器「当前 / 总数」的兜底结果缓存：任何入口打开都要能立即给出数字。
    var viewerPositionCache: ViewerPositionCache?

    struct ViewerPhotoCache {
        let id: UUID
        let revision: Int
        let photo: PhotoItem?
    }

    /// 查看器在当前可见列表中的位置缓存，供连翻时 O(1) 定位。
    struct ViewerIndexCache {
        let key: String
        let id: UUID
        let index: Int
    }

    /// 查看器「当前 / 总数」的兜底缓存：主路径算不出序号时避免每次渲染重复扫描列表。
    struct ViewerPositionCache {
        let key: String
        let id: UUID
        let index: Int
        let total: Int
    }

    /// 待确认的删除操作：`trash` 可撤销，`permanent` / `emptyTrash` 不可撤销。
    struct DeleteRequest: Identifiable, Equatable {
        enum Kind: Equatable {
            case trash
            case permanent
            case emptyTrash
        }

        let id = UUID()
        let ids: Set<UUID>
        let kind: Kind

        var isIrreversible: Bool {
            kind != .trash
        }
    }

    /// 待确认的断开操作：App 图库、系统图库连接或网络存储挂载。
    struct DisconnectRequest: Identifiable, Equatable {
        enum Target: Equatable {
            case appLibrary(path: String, name: String, isCurrent: Bool)
            case systemLibrary(path: String, name: String)
            case cloudMount(id: UUID, name: String, kind: CloudKind)
        }

        let id = UUID()
        let target: Target
    }

    /// 是否有任何确认卡片打开（键盘与菜单要避让）。
    var hasPendingConfirmation: Bool {
        pendingDeletion != nil || pendingDisconnect != nil
    }
    var memoryCacheKey = -1
    var memoryCacheValue: [PhotoMemory] = []
    var tripCacheKey = -1
    var tripCacheValue: [TripStory] = []
    var faceClusterTask: Task<Void, Never>?
    /// 外接盘卸载监听：卷被拔掉时把界面从失效的图库上撤下来。
    var volumeRemovalObservers: [NSObjectProtocol] = []
    /// 启动分片大小：一片几千条，够填满首屏，又不会把启动主线程卡住。
    static let libraryIndexShardSize = 5000
    /// 启动分片是否补完：未完成时 `photos` 不完整，禁止整库落盘。
    var libraryIndexComplete = true
    /// 后台补分片的任务；切换图库时取消，避免旧库条目被追加进新库。
    var libraryIndexTask: Task<Void, Never>?
    /// 分片未完成期间收到的保存请求：补齐后再补写一次。
    var pendingSaveWhileIndexing = false
    var scannedFaceIDs: Set<UUID> = []
    var faceDataLoaded = false
    /// 人脸聚类的运行标识：重新识别时换新标识，旧任务的收尾写回会被丢弃。
    var faceClusterToken = UUID()
    /// 尚未识别的照片数（增量识别入口显示剩余量），按内容版本缓存，避免反复遍历整库。
    var facePendingCacheKey = ""
    var facePendingCacheValue = 0

    init() {
        LibraryPaths.configure()
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        needsLibrarySetup = LibraryPaths.requiresLibrarySetup
        // 电视源、顺序与频道缓存写在当前图库的 SQLite：路径确定后再载入。
        tvModel.reloadForCurrentLibrary()
        // 与系统「照片」一致：按住 Option 启动时先弹出图库选择器。
        // NSEvent.modifierFlags 只反映“当前事件”的标志，启动早期 App 可能还没处理过
        // 任何事件而读不到；再读一次全局组合会话的按键状态兜底。
        let optionHeldAtLaunch = NSEvent.modifierFlags.contains(.option)
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        let startsWithLibraryPicker = optionHeldAtLaunch
        libraryPickerOnLaunch = startsWithLibraryPicker && !needsLibrarySetup

        // 没有图库时不创建任何元数据库；只有旧版本地库残留时才读取它，便于迁入新图库。
        if !needsLibrarySetup || LibraryPaths.hasLocalLibraryData {
            if let store = try? MetadataStore(url: LibraryPaths.metadataFile) {
                metadataStore = store
                // 启动分片：相簿 / 文件夹很小一次读完；资产先同步读第一片让窗口立刻有内容，
                // 剩下的在后台按页补齐，避免几万条记录卡在启动主线程上。
                let shell = store.loadLibraryShell()
                albums = shell.albums
                folders = shell.folders
                let shard = Self.libraryIndexShardSize
                let total = store.assetCount()
                photos = store.loadAssets(limit: shard, offset: 0)
                if photos.count < total {
                    libraryIndexComplete = false
                    loadRemainingAssets(total: total, shard: shard)
                }
                systemLibraryPath = store.setting("system_library_path")
                // 后台枚举一次本地缩略图目录：网格滚动时不用逐格 stat（本机盘，给足预算）。
                ThumbnailFileIndex.shared.warm(root: LibraryPaths.derivatives, timeBudget: 3)
            } else {
                loadLegacyJSON()
            }
        }

        // 图库级设置（导入选项、最近删除、系统图库上限、元数据显示）随图库保存：
        // 先接上当前图库的设置表，再把旧版全局设置一次性迁入，最后灌回 AppSettings。
        attachLibrarySettingsPersistence()
        migrateLegacySettingsIntoCurrentLibraryIfNeeded()
        AppSettings.shared.reloadLibraryScopedValues()
        // 这个图库还没有存过外观 / 强调色时，把当前主题落进它自己的设置表。
        AppSettings.shared.seedThemeForCurrentLibraryIfNeeded()

        if !needsLibrarySetup, let path = systemLibraryPath {
            // 默认不扫描系统图库：只记住名称用于侧边栏展示，用户点开系统图库时再按需加载。
            systemLibraryName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        loadSystemLibraries()
        // 「全部图库」记录与启动引导无关：没有图库时也要载入，
        // 「创建或打开图库」界面才能列出最近用过的库供直接打开。
        // 已经打开图库时以该库自己的记录为准，不从全局最近列表继承。
        loadKnownLibraries(inheritRecentIfEmpty: needsLibrarySetup)
        observeVolumeRemoval()

        // QA 钩子：在没有任何本地模型的机器上验证「打开开关 → 自动下载 → 编译 → 安装」整条链路。
        // 正常启动不会触发，只有显式设置环境变量时才执行。
        if ProcessInfo.processInfo.environment["LUMA_AUTO_INSTALL_SIGLIP2"] == "1" {
            ModelInstaller.shared.install(.siglip2)
        }

        purgeExpiredTrashIfNeeded()

        loadCloudMounts()
        loadCloudFavorites()
        loadCloudKeywords()
        loadCloudMarks()
        loadCinemaIndexes()
        migrateLegacyCinemaIndexIfNeeded()
        startLocalCinemaWatcher()
        // 上次异常退出可能留下播放会话目录：启动时在后台清掉并做一次容量回收。
        DispatchQueue.global(qos: .utility).async {
            VideoCache.luma.cleanupOrphans()
        }
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        loadViewPreferences()
        loadAIState()

        // 侧边栏记忆：有本地记录就从上次的页面开始；没有则继续走下面的默认页。
        let restoredSidebarItem = restoreSidebarItemIfPossible()

        // 当前图库就是官方「照片」图库时，主界面默认展示这个图库的照片；
        // 拾光自己的数据（导入、相簿、收藏）写在该图库第一层 database/ 里，从「拾光」分区进入。
        // 启动时弹出的图库选择器：先不打开任何图库，等用户选定后再进入。
        if !restoredSidebarItem,
           !needsLibrarySetup,
           !startsWithLibraryPicker,
           let container = LibraryPaths.containerLibraryURL,
           LibraryPaths.isNativeLibrary(container) {
            systemLibraryPath = container.path
            systemLibraryName = container.deletingPathExtension().lastPathComponent
            metadataStore?.setSetting("system_library_path", container.path)
            sidebarItem = .systemLibrary
        }

        if !startsWithLibraryPicker, let container = LibraryPaths.containerLibraryURL {
            rememberLibrary(container)
        }
        // 与系统「照片」一致：按住 Option 启动时先弹出图库选择器。
        showLibraryPicker = startsWithLibraryPicker

        // 网络资源的源、片单、日历都跟着图库：按当前图库读取一次。
        catalogModel.jobCenter = sourceJobCenter
        catalogModel.onJobChange = { [weak self] in
            self?.sourceJobRevision &+= 1
        }
        catalogModel.onJobFinished = { [weak self] id in
            self?.archiveSourceJob(id)
        }
        catalogModel.loadForCurrentLibrary()
        // 旧版本可能把影视源记成「网络资源频道页」：源装载完成后按域纠正。
        redirectCinemaSidebarItemIfNeeded()

        // 网络电视的连接检测与节目单更新同样登记到统一任务中心。
        tvModel.jobCenter = sourceJobCenter
        tvModel.onJobChange = { [weak self] in
            self?.sourceJobRevision &+= 1
        }
        tvModel.onJobFinished = { [weak self] id in
            self?.archiveSourceJob(id)
        }

        // 网络资源的播放统一交给查看器：用虚拟分集铺满上下文，左右翻页即切集。
        catalogModel.onPlayback = { [weak self] request in
            self?.playCatalog(request)
        }
        catalogModel.onPlaylistPlayback = { [weak self] items in
            self?.playCatalogPlaylist(items)
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.discardPrewarmedCinemaStream()
                self?.flushMetadata()
            }
        }

        // 从其它 App 回到前台：如果正在看某个网盘 / 它的影院，顺手做一次轻量增量同步，
        // 新加入的视频与照片不需要用户手动刷新。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCurrentCloudIndexIfNeeded()
            }
        }

        LibraryStore.current = self
    }

    deinit {
        localCinemaWatcher?.stop()
        libraryIndexTask?.cancel()
        cinemaPrewarmTask?.cancel()
        cinemaPrewarmedStream?.session.stop()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func flushMetadata() {
        metadataStore?.flush()
    }

    // MARK: - Persistence

    func loadLegacyJSON() {
        guard let data = try? Data(contentsOf: LibraryPaths.libraryFile),
              let decoded = try? JSONDecoder().decode(LibraryData.self, from: data) else {
            return
        }
        photos = decoded.photos.filter { FileManager.default.fileExists(atPath: LibraryPaths.sourceURL(for: $0).path) }
        albums = decoded.albums
        folders = decoded.folders
    }

    func save() {
        // 元数据只能写进当前图库的 SQLite；没有 MetadataStore（没有图库）时不落盘，
        // 避免在 Application Support 里写出会被下一个打开的图库误迁入的 Library.json。
        guard let metadataStore else { return }
        // 分片还没读完时 photos 不完整：整库重写会把未加载的行删掉，先记一笔等补齐。
        guard libraryIndexComplete else {
            pendingSaveWhileIndexing = true
            return
        }
        LibraryPaths.prepare()
        let data = LibraryData(photos: photos, albums: albums, folders: folders)
        metadataStore.save(data)
    }

    /// 后台补齐剩余资产：每片回到主线程一次性追加，避免逐条触发视图重算。
    private func loadRemainingAssets(total: Int, shard: Int) {
        guard let store = metadataStore else {
            libraryIndexComplete = true
            return
        }
        libraryIndexTask = Task { [weak self] in
            // 先让首屏渲染出来，再开始补剩余分片；启动阶段不再被 SQLite 读抢占。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            var offset = shard
            while offset < total {
                if Task.isCancelled { return }
                let page = await Task.detached(priority: .utility) {
                    store.loadAssets(limit: shard, offset: offset)
                }.value
                if page.isEmpty { break }
                guard let self else { return }
                self.photos.append(contentsOf: page)
                offset += shard
                await Task.yield()
            }
            guard let self else { return }
            self.libraryIndexComplete = true
            if self.pendingSaveWhileIndexing {
                self.pendingSaveWhileIndexing = false
                self.save()
            }
        }
    }

    /// 导入过程中增量写入新照片，避免每批都全量重写 assets；没有 SQLite 时退回整体保存。
    func persistImported(_ items: [PhotoItem]) {
        if let metadataStore {
            metadataStore.appendPhotos(items)
        } else {
            save()
        }
    }

    /// 视图状态（分组、排序、缩略图大小与形式）随当前图库保存，切换图库时一起切换。
    func loadViewPreferences() {
        var groupingValue: GridGrouping = .all
        var stackModeValue: StackMode = .off
        var favoritesViewModeValue: FavoritesViewMode = .years
        var aspectValue: ThumbnailAspect = .square
        var albumStyleValue: AlbumDisplayStyle = .grid
        var sortValue: SortKey = .capturedAt
        var ascendingValue: Bool?
        var placeGranularityValue: PlaceGranularity = .street
        var peopleFilterValue: PeopleGroupFilter = .all
        var peopleStyleValue: PeopleDisplayStyle = .circle
        var organizeDimensionValue: OrganizeDimension = .rating
        var sizeValue = defaultGridThumbSize
        var thumbSizesValue: [String: Double] = [:]
        var cardColumnsValue = Self.defaultCardColumnsValue
        var cardColumnsMap: [String: Int] = [:]

        if let store = metadataStore {
            if let raw = store.setting(SettingsKeys.grouping),
               let value = GridGrouping(rawValue: raw) {
                groupingValue = value
            }
            if let raw = store.setting(SettingsKeys.stackMode),
               let value = StackMode(rawValue: raw) {
                stackModeValue = value
            }
            if let raw = store.setting(SettingsKeys.favoritesViewMode),
               let value = FavoritesViewMode(rawValue: raw) {
                favoritesViewModeValue = value
            }
            if let raw = store.setting(SettingsKeys.thumbnailAspect),
               let value = ThumbnailAspect(rawValue: raw) {
                aspectValue = value
            }
            if let raw = store.setting(SettingsKeys.albumDisplayStyle),
               let value = AlbumDisplayStyle(rawValue: raw) {
                albumStyleValue = value
            }
            if let raw = store.setting(SettingsKeys.sortKey),
               let value = SortKey(rawValue: raw) {
                sortValue = value
            }
            if let raw = store.setting(SettingsKeys.sortAscending) {
                ascendingValue = raw == "1" || raw.lowercased() == "true"
            }
            if let raw = store.setting(SettingsKeys.placeGranularity),
               let value = PlaceGranularity(rawValue: raw) {
                placeGranularityValue = value
            }
            if let raw = store.setting(SettingsKeys.peopleFilter),
               let value = PeopleGroupFilter(rawValue: raw) {
                peopleFilterValue = value
            }
            if let raw = store.setting(SettingsKeys.peopleDisplayStyle),
               let value = PeopleDisplayStyle(rawValue: raw) {
                peopleStyleValue = value
            }
            if let raw = store.setting(SettingsKeys.organizeDimension),
               let value = OrganizeDimension(rawValue: raw) {
                organizeDimensionValue = value
            }
            if let raw = store.setting(SettingsKeys.thumbSize), let size = Double(raw) {
                sizeValue = min(Self.thumbSizeRange.upperBound,
                                max(Self.thumbSizeRange.lowerBound, size))
            }
            if let raw = store.setting(SettingsKeys.thumbSizes),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
                thumbSizesValue = decoded
            }
            if let raw = store.setting(SettingsKeys.cardColumns),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
                cardColumnsMap = decoded
            }
            // 从「按 pt 调大小」升级到「按每行张数」：每个图库清一次页面记忆，
            // 让所有页面先回到新的默认密度（图片列表 8 张、卡片墙 5 个）。
            if store.setting(SettingsKeys.gridColumnsMigration) != "1" {
                store.setSetting(SettingsKeys.gridColumnsMigration, "1")
                thumbSizesValue = [:]
                cardColumnsMap = [:]
                sizeValue = defaultGridThumbSize
                cardColumnsValue = Self.defaultCardColumnsValue
                pendingDensityReconcile = true
            }
        }

        grouping = groupingValue
        stackMode = stackModeValue
        expandedStackIDs = []
        favoritesViewMode = favoritesViewModeValue
        // 切换图库时旧汇总立即失效，进入收藏页会按新图库重新载入。
        favoritesDigest = nil
        favoritesDigestSource = []
        favoritesDigestLoadedToken = ""
        selectedFavoriteBucket = nil
        thumbnailAspect = aspectValue
        albumDisplayStyle = albumStyleValue
        sortKey = sortValue
        sortAscending = ascendingValue ?? sortValue.prefersAscending
        placeGranularity = placeGranularityValue
        peopleFilter = peopleFilterValue
        peopleDisplayStyle = peopleStyleValue
        organizeDimension = organizeDimensionValue
        thumbSizes = thumbSizesValue
        cardColumnsByScope = cardColumnsMap
        // 恢复当前侧边栏页面自己的滑杆位置；没记录过则沿用图库默认尺寸。
        let currentScope = thumbSizeScopeKey(for: sidebarItem)
        thumbSize = thumbSizesValue[currentScope] ?? sizeValue
        if thumbSizes[currentScope] == nil {
            thumbSizes[currentScope] = thumbSize
        }
        cardColumns = cardColumnsMap[currentScope] ?? cardColumnsValue
        if cardColumnsByScope[currentScope] == nil {
            cardColumnsByScope[currentScope] = cardColumns
        }
    }

    /// 恢复上次停留的侧边栏页面；没有记录或页面已失效时返回 false（走默认页）。
    @discardableResult
    func restoreSidebarItemIfPossible() -> Bool {
        guard let store = metadataStore,
              let raw = store.setting(SettingsKeys.sidebarItem),
              let data = Data(base64Encoded: raw),
              let item = try? JSONDecoder().decode(SidebarItem.self, from: data),
              isRestorableSidebarItem(item) else { return false }
        sidebarItem = item
        return true
    }

    private func persistSidebarItem(_ item: SidebarItem) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        persistViewPreference(SettingsKeys.sidebarItem, data.base64EncodedString())
    }

    /// 带 id 的页面要确认对象还在；回收站之类的临时页面不作为启动页。
    private func isRestorableSidebarItem(_ item: SidebarItem) -> Bool {
        switch item {
        case .trash, .systemTrash:
            return false
        case .album(let id):
            return albums.contains { $0.id == id }
        case .smartAlbum(let id):
            return smartAlbums.contains { $0.id == id }
        case .folder(let id):
            return folders.contains { $0.id == id }
        case .cloudMount(let id), .cloudCinema(let id):
            guard AppModules.isEnabled(AppModule.cloud) else { return false }
            return cloudMounts.contains { $0.id == id }
        case .cloudStorages:
            return AppModules.isEnabled(AppModule.cloud)
        case .catalogSources:
            return AppModules.isEnabled(AppModule.catalog)
        case .catalogSource(let id):
            // 影视源不能恢复成「网络资源」的频道页：它只属于网络影院。
            // 源清单还没装载时不拦截，等装载后再由选中逻辑按域纠正。
            guard AppModules.isEnabled(AppModule.catalog) else { return false }
            return catalogModel.sources.isEmpty || catalogModel.isSource(id, in: .networkResource)
        case .networkCinema:
            return AppModules.isEnabled(AppModule.cinema)
        case .iptv:
            // 设置里关掉「网络电视」模块后，不再恢复到频道页。
            return AppModules.isEnabled(AppModule.television)
        default:
            return true
        }
    }

    /// 把当前图库的设置表接入 AppSettings；闭包动态读取 `metadataStore`，切换图库后自动指向新库。
    func attachLibrarySettingsPersistence() {
        let app = AppSettings.shared
        app.libraryReader = { [weak self] key in self?.metadataStore?.setting(key) }
        app.libraryWriter = { [weak self] key, value in self?.metadataStore?.setSetting(key, value) }
    }

    /// 旧版把图库级设置存在全局 UserDefaults：升级后一次性迁入当前图库；
    /// 之后新建的图库不再继承，使用各自的默认值。
    func migrateLegacySettingsIntoCurrentLibraryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKeys.libraryScopeMigrationDone) else { return }
        defer { defaults.set(true, forKey: SettingsKeys.libraryScopeMigrationDone) }
        guard let store = metadataStore else { return }

        let keys = [SettingsKeys.importCreateAlbums, SettingsKeys.importPreserveStructure,
                    SettingsKeys.trashRetentionDays,
                    SettingsKeys.grouping, SettingsKeys.thumbnailAspect,
                    SettingsKeys.sortKey, SettingsKeys.sortAscending, SettingsKeys.thumbSize]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let bool = value as? Bool {
                store.setSetting(key, bool ? "1" : "0")
            } else if let number = value as? NSNumber {
                store.setSetting(key, number.stringValue)
            } else if let string = value as? String {
                store.setSetting(key, string)
            }
        }
        if let data = defaults.data(forKey: SettingsKeys.metadata),
           let json = String(data: data, encoding: .utf8) {
            store.setSetting(SettingsKeys.metadata, json)
        }
        if let favorites = defaults.stringArray(forKey: Self.cloudFavoritesDefaultsKey),
           let data = try? JSONEncoder().encode(favorites),
           let json = String(data: data, encoding: .utf8) {
            store.setSetting(Self.cloudFavoritesSettingKey, json)
        }
    }

    /// 图库级设置的落盘入口：只写当前图库，不再污染全局 UserDefaults。
    private func persistViewPreference(_ key: String, _ value: String) {
        metadataStore?.setSetting(key, value)
    }
}
