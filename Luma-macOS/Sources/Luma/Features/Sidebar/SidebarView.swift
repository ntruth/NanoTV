import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

/// 「固定」分区拖拽排序用的自定义类型，避免和照片拖拽（纯文本）互相干扰。
let pinnedSidebarDragType = UTType(exportedAs: "com.luma.sidebar-pinned-item")
/// 网络资源拖拽排序：拖动只调整源顺序，不会与照片 / 固定项混淆。
let catalogSourceDragType = UTType(exportedAs: "com.luma.sidebar-catalog-source")
/// 网络电视源拖拽排序：顺序写进电视库的 `tv_playlists.position`。
let tvSourceDragType = UTType(exportedAs: "com.luma.sidebar-tv-source")
/// 系统图库侧边栏的相簿拖拽：拖进文件夹时只认这个类型，不会和照片拖拽互相混淆。
let systemSidebarDragType = UTType(exportedAs: "com.luma.sidebar-system-item")

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var tv: IPTVBrowserModel
    @EnvironmentObject private var settings: AppSettings
    /// 设置里的「在侧边栏显示网络电视」：关闭后整段入口不渲染。
    @AppStorage(SettingsKeys.showTelevision) private var showTelevision = true
    /// 其余模块开关：关闭后整段入口不渲染，搜索也不再返回对应来源。
    @AppStorage(SettingsKeys.moduleCloud) private var showCloudModule = true
    @AppStorage(SettingsKeys.moduleCatalog) private var showCatalogModule = true
    @AppStorage(SettingsKeys.moduleCinema) private var showCinemaModule = true
    /// 侧边栏相簿默认全部收起，只记录被用户展开的文件夹，避免一次渲染上千行。
    /// 展开 / 收起状态写入本地，下次启动沿用上次的层级。
    @State private var expandedFolders: Set<UUID> =
        SidebarStateStorage.uuidSet(SidebarStateStorage.Key.expandedFolders)
    @State private var expandedSystemFolders: Set<Int64> =
        SidebarStateStorage.int64Set(SidebarStateStorage.Key.expandedSystemFolders)
    /// 系统树展开状态版本：让拍平结果只在展开/收起时重算，悬停等无关状态直接命中缓存。
    @State private var systemExpansionRevision = 0
    @State private var collapsedSystemLibraries: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.collapsedSystemLibraries)
    @State private var hoveredItem: SidebarItem?
    /// 与 hoveredItem 搭配的分区标识：同一个相簿可能同时出现在「固定」和「相簿」里。
    @State private var hoveredItemScope: String = ""
    @State private var hoveredSystemLibraryPath: String?
    /// 已收起的侧边栏分区（键为分区标识），同样持久化。
    @State private var collapsedSections: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.collapsedSections)
    /// 默认收起的分区被用户主动展开后的记录；没有记录时按默认收起。
    @State private var expandedSections: Set<String> =
        SidebarStateStorage.stringSet(SidebarStateStorage.Key.expandedSections)
    /// 默认收起「图库」分区内的当前图库实例，以及「媒体类型」与「场景」；
    /// 展开「图库」先看到实例，再展开实例才看到树，和网络存储一致。
    private static let defaultCollapsedSections: Set<String> = [
        "library.current", "luma.media", "luma.scenes", "sys.media", "sys.scenes"
    ]
    @State private var hoveredSection: String?
    @State private var dropTargetAlbumID: UUID?
    /// 系统相簿被拖到哪个文件夹上方（落点高亮）。
    @State private var systemFolderDropTarget: Int64?
    /// 「场景」分区危险操作的二次确认：清空本地 / 系统图库分析结果、系统图库重新识别。
    @State private var showResetAnalysisConfirm = false
    @State private var showResetSystemAnalysisConfirm = false
    @State private var showRestartSystemAnalysisConfirm = false
    /// 网络资源拖拽排序时的目标行：用来画一条落点提示线。
    @State private var catalogDropTargetID: UUID?
    /// 网络电视源拖拽排序时的目标行。
    @State private var tvDropTargetID: UUID?
    /// 网络电视源下展开的分类：默认全部收起，需要时再手动展开单个源。
    @State private var expandedTVSources: Set<UUID> = []
    /// 网络存储同一时间只展开一个接入：点别的接入（或它的影院）时自动收起上一个。
    @State private var expandedCloudMountID: UUID? =
        SidebarStateStorage.uuidSet(SidebarStateStorage.Key.expandedCloudMounts).first

    /// 「图库」分区里当前图库这一行的悬停状态。
    @State private var hoveredCurrentLibrary = false

    var body: some View {
        ScrollView {
            // 系统图库可能带成千上万个相簿，侧边栏必须懒加载，否则一次性创建全部行会卡死主线程。
            LazyVStack(alignment: .leading, spacing: 1) {
                librariesSection
                if showCloudModule {
                    cloudSection
                }
                if showCatalogModule {
                    catalogSection
                }
                if showCinemaModule {
                    networkCinemaSection
                }
                if showTelevision {
                    tvSection
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
            // 撑满分栏列宽、左对齐：拖动分栏时内容跟着列宽一起变。
            // 不用 containerRelativeFrame：它在分栏拖拽的实时布局里会按「上一帧的列宽」
            // 算宽，内容会缩成一条贴在右边的窄栏（截图里的错位就是这样来的）。
            .frame(maxWidth: .infinity, alignment: .leading)
            // 整理面板挂在内容上而不是根视图：根视图已经有命名弹窗，避免两个 sheet 抢同一个挂载点。
            .sheet(item: $store.systemFolderPrompt) { _ in
                SystemFolderOrganizeSheet()
                    .environmentObject(store)
            }
        }
        .scrollIndicators(.never)
        // 环境光垫在材质下面：侧边栏不是一块死灰，而是一层带颜色的磨砂玻璃。
        .background {
            ZStack {
                LumaAmbientBackground(intensity: 0.75)
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Color.white.opacity(0.05), .clear],
                               startPoint: .top, endPoint: .center)
            }
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.clear, Color.primary.opacity(0.14), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 0.5)
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom) {
            // 后台任务统一露出：网盘扫描 / 影院刮削 / 健康检测 / 日历补录。
            SourceJobStatusBar()
        }
        // 拖拽范围收在 150–360：再窄行内文字会挤成省略号，再宽只是给行尾留白。
        // 内容本身用上面 LazyVStack 的 frame(maxWidth: .infinity) 跟随列宽：
        // 之前用 containerRelativeFrame，分栏拖拽的实时布局里会按上一帧列宽算宽，
        // 内容缩成一条贴在右边的窄栏、两侧大片空白（截图里的错位就是这样来的）。
        .navigationSplitViewColumnWidth(min: 150, ideal: 248, max: 360)
        .confirmationDialog("清空照片内容分析结果？",
                            isPresented: $showResetAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空全部结果", role: .destructive) {
                store.resetIntelligenceAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除全部照片的场景标签、图内文字与相似检索特征（含已保存到图库的结果）；照片本身不受影响，之后可重新分析。")
        }
        .confirmationDialog("重新识别全部照片？",
                            isPresented: $showRestartSystemAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空并重新识别", role: .destructive) {
                store.restartSystemAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空现有识别结果并从头识别整个系统图库，耗时较长；「照片」图库本身不受影响。")
        }
        .confirmationDialog("清空系统图库识别结果？",
                            isPresented: $showResetSystemAnalysisConfirm,
                            titleVisibility: .visible) {
            Button("清空全部结果", role: .destructive) {
                store.resetSystemAnalysis()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机保存的识别缓存（场景标签、图内文字与特征）；「照片」图库与照片本身不受影响，之后可重新识别。")
        }
    }

    private func sidebarRow(_ item: SidebarItem,
                            icon: String,
                            title: String,
                            color: Color = .accentColor,
                            scope: String = "main",
                            pinKey: String? = nil) -> some View {
        SidebarCategoryRow(icon: icon,
                           title: title,
                           iconColor: color,
                           trailingIcon: pinKey == "trash" ? "lock.fill" : nil,
                           isActive: store.sidebarItem == item,
                           isHovered: hoveredItem == item && hoveredItemScope == scope,
                           action: { store.navigate(to: item) })
            .onHover { hovering in
                if hovering {
                    hoveredItem = item
                    hoveredItemScope = scope
                } else if hoveredItem == item && hoveredItemScope == scope {
                    hoveredItem = nil
                }
            }
            .contextMenu {
                if let pinKey {
                    Button(store.isPinned(.system(pinKey)) ? "取消固定" : "固定到侧边栏") {
                        store.togglePin(.system(pinKey))
                    }
                }
            }
    }

    private func trashRow(scope: String = "main", pinKey: String? = nil) -> some View {
        Button {
            store.navigate(to: .trash)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "trash")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("最近删除")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == .trash,
                                 hovered: hoveredItem == .trash && hoveredItemScope == scope)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = .trash
                hoveredItemScope = scope
            } else if hoveredItem == .trash && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .contextMenu {
            if let pinKey {
                Button(store.isPinned(.system(pinKey)) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system(pinKey))
                }
            }
        }
    }

    /// 「固定」区的条目：可拖动排序，右键取消固定。
    /// - Parameter system: 当前是否在系统「照片」图库范围内，决定条目指向系统入口还是拾光入口。
    @ViewBuilder
    private func pinnedRows(system: Bool) -> some View {
        if store.pinnedItems.isEmpty {
            Text("在项目、场景、相簿或文件夹上右键可固定到这里")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        } else {
            ForEach(store.pinnedItems) { item in
                pinnedItemRow(item, system: system)
                    .onDrag { pinnedDragProviderForSidebar(item) }
                    .onDrop(of: [pinnedSidebarDragType],
                            delegate: PinnedReorderDropDelegate(target: item, store: store))
            }
            // 拖到列表下方空白处 → 移到末尾。
            Color.clear
                .frame(height: 6)
                .onDrop(of: [pinnedSidebarDragType],
                        delegate: PinnedEndDropDelegate(store: store))
        }
    }

    /// 「固定」区里的条目：系统项、相簿、智能相簿、文件夹或系统图库的相簿 / 文件夹。
    @ViewBuilder
    private func pinnedItemRow(_ item: PinnedSidebarItem, system: Bool) -> some View {
        switch item {
        case .system(let key):
            if let info = pinnedSystemInfo(for: key, system: system) {
                sidebarRow(info.item, icon: info.icon, title: info.title,
                           color: info.color, scope: "fixed", pinKey: key)
            }
        case .album(let id):
            if let album = store.albums.first(where: { $0.id == id }) {
                albumRow(album, level: 0, scope: "fixed")
            }
        case .smartAlbum(let id):
            if let album = store.smartAlbums.first(where: { $0.id == id }) {
                smartAlbumRow(album, scope: "fixed")
            }
        case .folder(let id):
            if let folder = store.folders.first(where: { $0.id == id }) {
                folderNode(folder, level: 0, scope: "fixed")
            }
        case .systemAlbum(let id):
            if let album = store.systemAlbums.first(where: { $0.id == id }) {
                systemAlbumRow(album, level: 0, scope: "fixed")
            }
        case .systemFolder(let id):
            if let folder = store.systemFolders.first(where: { $0.id == id }) {
                systemFolderNode(folder, level: 0, scope: "fixed")
            }
        }
    }

    private struct PinnedSystemInfo {
        let title: String
        let icon: String
        var color: Color = .accentColor
        let item: SidebarItem
    }

    /// 固定项 key 在当前范围对应的入口：系统图库范围指向系统入口，拾光范围指向本地入口。
    private func pinnedSystemInfo(for key: String, system: Bool) -> PinnedSystemInfo? {
        switch key {
        case "favorites":
            return PinnedSystemInfo(title: "个人收藏", icon: "heart.fill", color: .pink,
                                    item: system ? .systemFavorites : .favorites)
        case "trash":
            return PinnedSystemInfo(title: "最近删除", icon: "trash", color: .secondary,
                                    item: system ? .systemTrash : .trash)
        case "duplicates":
            return PinnedSystemInfo(title: "重复项目", icon: "square.on.square",
                                    item: system ? .systemDuplicates : .duplicates)
        case "recentlySaved":
            return PinnedSystemInfo(title: "最近保存", icon: "square.and.arrow.down",
                                    item: system ? .systemRecentlySaved : .recentlySaved)
        case "recentlyViewed":
            return PinnedSystemInfo(title: "最近查看", icon: "eye", item: .systemRecentlyViewed)
        case "recentlyEdited":
            return PinnedSystemInfo(title: "最近编辑", icon: "slider.horizontal.3",
                                    item: system ? .systemEdited : .recentlyEdited)
        case "imports":
            return PinnedSystemInfo(title: "导入项目", icon: "square.and.arrow.down.on.square",
                                    item: system ? .systemImports : .imports)
        case "map":
            return PinnedSystemInfo(title: "地图", icon: "map", item: system ? .systemMap : .map)
        case "places":
            return PinnedSystemInfo(title: "位置", icon: "mappin.and.ellipse",
                                    item: system ? .systemPlaces : .places)
        case "people":
            return PinnedSystemInfo(title: "人物", icon: "person.crop.square",
                                    item: system ? .systemPeople : .people)
        case "hidden":
            return PinnedSystemInfo(title: "已隐藏", icon: "eye.slash", color: .secondary,
                                    item: system ? .systemHidden : .hidden)
        case "ocrTexts":
            return PinnedSystemInfo(title: "包含文字", icon: "text.viewfinder",
                                    item: system ? .systemOcrTexts : .ocrTexts)
        case "keywords":
            return PinnedSystemInfo(title: "关键词", icon: "tag",
                                    item: system ? .systemKeywords : .keywords)
        case "revisit":
            return PinnedSystemInfo(title: "值得重看", icon: "clock.arrow.circlepath",
                                    item: system ? .systemRevisit : .revisit)
        case "health":
            return PinnedSystemInfo(title: "图库体检", icon: "stethoscope",
                                    item: system ? .systemHealth : .health)
        case "ratings", "flags", "colorLabels":
            // 旧的三个固定项统一收敛成「图库整理」入口。
            return PinnedSystemInfo(title: "图库整理", icon: "square.grid.2x2", color: .yellow,
                                    item: system ? .systemRatings : .ratings)
        default:
            // 场景固定 key：`scene:<分类 id>`，与媒体类型一样随当前范围指向拾光或系统图库入口。
            if key.hasPrefix("scene:"),
               let category = SceneCatalog.category(id: String(key.dropFirst(6))) {
                return PinnedSystemInfo(title: category.title, icon: category.icon,
                                        item: system ? .systemScene(category.id)
                                                     : .scene(category.id))
            }
            guard let type = MediaTypeKey(rawValue: key) else { return nil }
            return PinnedSystemInfo(title: type.title, icon: type.icon,
                                    item: type.item(system: system))
        }
    }

    /// 文件夹展开箭头的列宽：只够放下箭头，避免封面被推远。
    private static let folderChevronWidth: CGFloat = 12
    /// 箭头与封面之间的间隙，保持紧贴但可点。
    private static let folderChevronGap: CGFloat = 3

    /// 侧边栏树形缩进：顶层与普通相簿同一列，展开后的每一层多缩进 14 pt。
    private func rowLeadingPadding(_ level: Int) -> CGFloat {
        8 + CGFloat(level) * 14
    }

    /// 相簿没有展开箭头，留出同宽的箭头列，封面才和文件夹图标对齐。
    /// 「固定」区的条目本身就是第一层，不再为箭头列预留缩进，和其它固定项左对齐。
    private func albumLeadingPadding(_ level: Int, scope: String = "albums") -> CGFloat {
        if scope == "fixed", level == 0 { return rowLeadingPadding(0) }
        return rowLeadingPadding(level) + Self.folderChevronWidth + Self.folderChevronGap
    }

    private func folderNode(_ folder: AlbumFolder, level: Int, scope: String = "albums") -> AnyView {
        let isExpanded = expandedFolders.contains(folder.id)
        let childFolders = store.childFolders(of: folder.id)
        let childAlbums = store.albums(in: folder.id)
        let hasChildren = !childFolders.isEmpty || !childAlbums.isEmpty

        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Self.folderChevronGap) {
                    Button {
                        withAnimation(settings.motion.layout) {
                            if isExpanded {
                                expandedFolders.remove(folder.id)
                            } else {
                                expandedFolders.insert(folder.id)
                            }
                        }
                        persistExpansionState()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: Self.folderChevronWidth, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasChildren ? 1 : 0)
                    .disabled(!hasChildren)

                    Button {
                        store.navigate(to: .folder(folder.id))
                    } label: {
                        HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                                .background(Color.accentColor.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                                 style: .continuous))
                            Text(folder.name)
                                .font(.system(size: LumaMetrics.sidebarTextSize))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, rowLeadingPadding(level))
                .padding(.trailing, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .background {
                    LumaRowHighlight(active: store.sidebarItem == .folder(folder.id),
                                     hovered: hoveredItem == .folder(folder.id) && hoveredItemScope == scope)
                }
                .onHover { hovering in
                    if hovering {
                        hoveredItem = .folder(folder.id)
                        hoveredItemScope = scope
                    } else if hoveredItem == .folder(folder.id) && hoveredItemScope == scope {
                        hoveredItem = nil
                    }
                }
                .contextMenu {
                    Button("打开文件夹") {
                        store.navigate(to: .folder(folder.id))
                    }
                    Button(store.isPinned(.folder(folder.id)) ? "取消固定" : "固定到侧边栏") {
                        store.togglePin(.folder(folder.id))
                    }
                    Divider()
                    Button("新建相簿…") {
                        store.namePrompt = .newAlbum(folderID: folder.id)
                    }
                    Button("新建子文件夹…") {
                        store.namePrompt = .newFolder(parentID: folder.id)
                    }
                    Divider()
                    Button("重命名文件夹…") {
                        store.namePrompt = .renameFolder(folder.id, current: folder.name)
                    }
                    Button("删除文件夹", role: .destructive) {
                        store.deleteFolder(folder.id)
                    }
                }

                if isExpanded {
                    ForEach(childFolders) { child in
                        folderNode(child, level: level + 1, scope: scope)
                    }
                    ForEach(childAlbums) { album in
                        albumRow(album, level: level + 1, scope: scope)
                    }
                }
            }
        )
    }

    private func albumRow(_ album: Album, level: Int, scope: String = "albums") -> some View {
        Button {
            store.navigate(to: .album(album.id))
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                AlbumCoverView(album: album)
                Text(album.name)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, albumLeadingPadding(level, scope: scope))
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background {
                ZStack {
                    LumaRowHighlight(active: store.sidebarItem == .album(album.id),
                                     hovered: hoveredItem == .album(album.id) && hoveredItemScope == scope)
                    if dropTargetAlbumID == album.id {
                        RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.24))
                            .overlay {
                                RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                            }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = .album(album.id)
                hoveredItemScope = scope
            } else if hoveredItem == .album(album.id) && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { dropTargetAlbumID == album.id },
            set: { targeted in
                if targeted {
                    dropTargetAlbumID = album.id
                } else if dropTargetAlbumID == album.id {
                    dropTargetAlbumID = nil
                }
            }
        )) { providers in
            PhotoDrag.loadIDs(from: providers) { ids in
                guard !ids.isEmpty else { return }
                store.addToAlbum(album.id, photoIDs: Set(ids))
            }
            return true
        }
        .contextMenu {
            Button("打开相簿") {
                store.navigate(to: .album(album.id))
            }
            Button(store.isPinned(.album(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.album(album.id))
            }
            Button("重命名相簿…") {
                store.namePrompt = .renameAlbum(album.id, current: album.name)
            }
            Menu("移到文件夹") {
                Button("相簿顶层") {
                    store.moveAlbum(album.id, toFolder: nil)
                }
                if !store.folderOptions.isEmpty {
                    Divider()
                }
                ForEach(store.folderOptions) { option in
                    Button(option.path) {
                        store.moveAlbum(album.id, toFolder: option.id)
                    }
                }
            }
            Divider()
            Button("删除相簿", role: .destructive) {
                store.deleteAlbum(album.id)
            }
        }
    }

    private func smartAlbumRow(_ album: SmartAlbum, scope: String = "smart") -> some View {
        let item = SidebarItem.smartAlbum(album.id)
        return Button {
            store.navigate(to: item)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                    .background(Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                     style: .continuous))
                Text(album.name)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == item,
                                 hovered: hoveredItem == item && hoveredItemScope == scope)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredItem = item
                hoveredItemScope = scope
            } else if hoveredItem == item && hoveredItemScope == scope {
                hoveredItem = nil
            }
        }
        .contextMenu {
            Button("打开智能相簿") { store.navigate(to: item) }
            Button(store.isPinned(.smartAlbum(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.smartAlbum(album.id))
            }
            Button("编辑条件…") { store.presentSmartAlbumEditor(album) }
            Divider()
            Button("删除智能相簿", role: .destructive) { store.deleteSmartAlbum(album.id) }
        }
        .help(album.summary)
    }

    /// 可收起的分区头：悬停时显示「更多」与「收起 / 展开」。
    /// 传入 `navigateTo` 时标题可点击，右侧显示该分区的二级总览视图。
    private func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 16,
        indent: CGFloat = 0,
        isModule: Bool = false,
        navigateTo: SidebarItem? = nil,
        beforeNavigate: (() -> Void)? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }
    ) -> some View {
        SidebarSectionHeader(
            title: title,
            collapsed: isCollapsed(key),
            active: navigateTo.map { $0 == store.sidebarItem } ?? false,
            topPadding: topPadding,
            indent: indent,
            isModule: isModule,
            isHovered: hoveredSection == key,
            onOpen: navigateTo.map { item in
                {
                    if isTopLevelSection(key) {
                        withAnimation(settings.motion.layout) { expandExclusively(key) }
                    }
                    beforeNavigate?()
                    store.navigate(to: item)
                }
            },
            onToggle: {
                withAnimation(settings.motion.layout) { toggleSection(key) }
            },
            menu: menu
        )
        .onHover { inside in
            hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
        }
    }

    private func toggleSection(_ key: String) {
        if isCollapsed(key) {
            if isTopLevelSection(key) {
                expandExclusively(key)
                return
            }
            collapsedSections.remove(key)
            expandedSections.insert(key)
        } else {
            collapsedSections.insert(key)
            expandedSections.remove(key)
        }
        persistExpansionState()
    }

    /// 顶层分区（图库 / 网络存储 / 网络资源 / 网络电视）做手风琴：
    /// 展开一个，其余已展开的顶层分区自动合上；嵌套分区不参与。
    private static let topLevelSectionKeys: Set<String> = [
        "library", "cloud", "catalog", "netcinema", "tv"
    ]

    private func isTopLevelSection(_ key: String) -> Bool {
        Self.topLevelSectionKeys.contains(key)
    }

    /// 当前真正渲染出来的顶层分区：只在这些分区之间做手风琴，
    /// 避免把当前模式里看不见的分区也写进「已收起」。
    private var visibleTopLevelSectionKeys: [String] {
        var keys: [String] = ["library"]
        if showCloudModule { keys.append("cloud") }
        if showCatalogModule { keys.append("catalog") }
        if showCinemaModule { keys.append("netcinema") }
        if showTelevision { keys.append("tv") }
        return keys
    }

    private func expandExclusively(_ key: String) {
        for other in visibleTopLevelSectionKeys where other != key {
            guard !isCollapsed(other) else { continue }
            collapsedSections.insert(other)
            expandedSections.remove(other)
        }
        collapsedSections.remove(key)
        expandedSections.insert(key)
        persistExpansionState()
    }

    /// 把当前所有层级的展开 / 收起状态写入本地：下次启动按同样的层级展示。
    private func persistExpansionState() {
        SidebarStateStorage.save(SidebarStateStorage.Key.collapsedSections, collapsedSections)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedSections, expandedSections)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedFolders, expandedFolders)
        SidebarStateStorage.save(SidebarStateStorage.Key.expandedSystemFolders, expandedSystemFolders)
        SidebarStateStorage.save(SidebarStateStorage.Key.collapsedSystemLibraries, collapsedSystemLibraries)
    }

    private func isCollapsed(_ key: String) -> Bool {
        if collapsedSections.contains(key) { return true }
        return Self.defaultCollapsedSections.contains(key) && !expandedSections.contains(key)
    }

    // MARK: - 场景（端侧智能分析）

    @ViewBuilder
    private var sceneSectionBody: some View {
        // 识别进度只在背景任务面板里展示；侧边栏保持干净，不重复一行进度。
        if store.analyzedCount == 0 {
            if !store.isAnalyzingIntelligence {
                Button {
                    store.analyzeIntelligence()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("分析照片内容…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    // 与上面的图库行对齐：图标列落在 22pt，文字落在 50pt。
                    .padding(.leading, 22)
                    .padding(.trailing, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("识别场景与照片中的文字，全部在本机完成")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        } else {
            let counts = store.sceneCounts
            let visible = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                Text("未识别到常见场景")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            } else {
                ForEach(visible) { category in
                    sceneRow(category, count: counts[category.id] ?? 0)
                }
            }
        }
    }

    private func sceneRow(_ category: SceneCategory, count: Int) -> some View {
        let item = SidebarItem.scene(category.id)
        return SidebarCategoryRow(icon: category.icon,
                                  title: category.title,
                                  count: count,
                                  isActive: store.sidebarItem == item,
                                  isHovered: hoveredItem == item,
                                  helpText: "查看「\(category.title)」照片",
                                  action: { store.navigate(to: item) })
            .contextMenu {
                Button(store.isPinned(.system("scene:\(category.id)")) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system("scene:\(category.id)"))
                }
            }
            .onHover { hovering in
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
    }

    // MARK: - 系统图库场景（端侧识别，缓存到 system_analysis）

    @ViewBuilder
    private var systemSceneSectionBody: some View {
        // 同上：识别进度已在背景任务面板，侧边栏不再重复。
        if store.systemAnalyzedCount == 0 {
            if !store.isAnalyzingSystemContent {
                Button {
                    store.analyzeSystemContent()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("识别照片内容…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("在本机识别系统图库的场景与图内文字；结果只保存在内存，不写回「照片」")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        } else {
            // 结果边识别边出现：每识别一批就刷新下面的场景行。
            let counts = store.sceneCounts
            let visible = SceneCatalog.categories.filter { (counts[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                if !store.isAnalyzingSystemContent {
                    Text("未识别到常见场景")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                }
            } else {
                ForEach(visible) { category in
                    systemSceneRow(category, count: counts[category.id] ?? 0)
                }
            }
            if !store.isAnalyzingSystemContent {
                let pending = store.systemPendingAnalysisCount
                if pending > 0 {
                    Button {
                        store.analyzeSystemContent()
                    } label: {
                        HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                            Image(systemName: "sparkles")
                                .font(.system(size: LumaMetrics.sidebarIconSize))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: LumaMetrics.sidebarIconColumn)
                            Text("继续识别（剩余 \(pending) 张）")
                                .font(.system(size: LumaMetrics.sidebarTextSize))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在后台持续识别，可随时停止；结果只保存在内存")
                }
            }
        }
    }

    private func systemSceneRow(_ category: SceneCategory, count: Int) -> some View {
        let item = SidebarItem.systemScene(category.id)
        return SidebarCategoryRow(icon: category.icon,
                                  title: category.title,
                                  count: count,
                                  isActive: store.sidebarItem == item,
                                  isHovered: hoveredItem == item,
                                  helpText: "查看「\(category.title)」照片",
                                  action: { store.navigate(to: item) })
            .contextMenu {
                Button(store.isPinned(.system("scene:\(category.id)")) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.system("scene:\(category.id)"))
                }
            }
            .onHover { hovering in
                hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
            }
    }

    // MARK: - System libraries

    /// 媒体类型数量：与系统「照片」一致，数量为 0 的类型不显示入口。
    private var mediaTypeCounts: [MediaTypeKey: Int] {
        store.mediaTypeSummary.counts
    }

    // MARK: - Libraries

    /// 统一的「图库」分区：当前图库与已连接图库都是这里的实例。
    /// 展开分区看到图库实例，展开实例才看到它自己的左侧树；
    /// 结构跟「网络存储 / 网络资源 / 网络电视」完全对齐。
    @ViewBuilder
    private var librariesSection: some View {
        sectionHeader("图库", key: "library", topPadding: 4, isModule: true,
                      navigateTo: .systemLibraries) {
            if store.isNativeContainer {
                Button("在「照片」中打开图库") { store.openContainerInPhotos() }
                Button("重新读取") { store.reloadSystemLibrary() }
                Button("在访达中显示图库") { store.revealSystemLibraryInFinder() }
                Divider()
            }
            Button("打开其他图库…") { store.presentLibraryContainerPanel() }
            Button("新建图库…") { store.beginNewLibraryFlow() }
            if let url = LibraryPaths.containerLibraryURL {
                Divider()
                Button("断开当前图库…", role: .destructive) {
                    store.confirmDisconnectLibrary(
                        path: url.path,
                        name: url.deletingPathExtension().lastPathComponent)
                }
            }
        }

        if !isCollapsed("library") {
            currentLibraryRow

            // 当前图库的树紧跟在自己的行下面：放在别的图库之后会看起来像挂到了别人身上。
            if expandedLinkedLibraryPath == nil, !isCollapsed("library.current") {
                // 树整体比图库行再缩进一级：图标列与图库行的图标列错开，层级一眼能看出。
                if store.isNativeContainer {
                    systemLibraryDetail
                        .padding(.leading, SidebarTreeMetrics.childIndent)
                } else {
                    lumaLibraryTree
                        .padding(.leading, SidebarTreeMetrics.childIndent)
                }
            }

            // 其他打开过的图库：默认图库排最前，其余平铺，不会因为新建图库而消失。
            ForEach(otherKnownLibraries) { ref in
                knownLibraryRow(ref)
            }

            // 其他已连接图库：同一时间只展开当前正在浏览的那个。
            ForEach(store.systemLibraries) { ref in
                let isExpanded = (store.systemLibraryPath.map {
                    store.isSameSystemLibraryPath($0, ref.path)
                } ?? false) && !collapsedSystemLibraries.contains(ref.path)
                systemLibraryRefRow(ref, isExpanded: isExpanded)
                if isExpanded {
                    systemLibraryDetail
                        .padding(.leading, SidebarTreeMetrics.childIndent)
                }
            }

            if store.systemLibraries.isEmpty {
                Button {
                    store.presentSystemLibraryPanel()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("连接其他图库…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 「图库」下的当前实例：始终显示图库自己的名字。
    private var currentLibraryRow: some View {
        let currentPath = LibraryPaths.containerLibraryURL?.path ?? ""
        let name = libraryDisplayName(appContainerLibraryName, path: currentPath)
        let isDefault = store.isDefaultLibrary(currentPath)
        let isExplicitDefault = store.isExplicitDefaultLibrary(currentPath)
        let expanded = !isCollapsed("library.current")
        let isActive = currentLibraryIsActive

        return HStack(spacing: 2) {
            Button {
                if expanded {
                    withAnimation(settings.motion.layout) {
                        setSectionCollapsed("library.current", true)
                    }
                    persistExpansionState()
                } else {
                    activateCurrentLibrary()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help(expanded ? "收起" : "展开")

            Button {
                activateCurrentLibrary()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    libraryKindBadge(isDefault: isDefault)
                }
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExplicitDefault
                  ? "默认图库：启动时自动打开"
                  : (isDefault ? "上次打开的图库：下次启动会继续打开它" : name))
            .contextMenu {
                Button("打开图库") { activateCurrentLibrary() }
                if store.isNativeContainer {
                    Button("在「照片」中打开图库") { store.openContainerInPhotos() }
                }
                if let url = LibraryPaths.containerLibraryURL {
                    Button("在访达中显示图库") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    if store.isNativeContainer {
                        Button("重新检测写入目标") {
                            store.refreshSystemWriteTargetState(announce: true)
                        }
                        .help("只有「照片」正在使用的官方图库才能新建 / 重命名 / 删除相簿")
                        if store.systemWriteTargetState == .mismatch {
                            Button("重新启动拾光以启用编辑") {
                                store.relaunchForLibraryWrite()
                            }
                            .help("在「照片」里切换图库后，PhotoKit 需要重启拾光才会指向新库")
                        }
                    }
                    Divider()
                    Button("断开连接…", role: .destructive) {
                        store.confirmDisconnectLibrary(path: url.path, name: name)
                    }
                    .help("退出当前图库并回到「创建或打开图库」；磁盘上的图库文件保留")
                }
            }
        }
        .background {
            LumaRowHighlight(active: isActive, hovered: hoveredCurrentLibrary)
        }
        .onHover { hovering in
            hoveredCurrentLibrary = hovering
        }
    }

    /// 其他打开过的图库（不含当前图库与已连接的图库）：默认图库排最前。
    private var otherKnownLibraries: [SystemLibraryRef] {
        let currentPath = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
        return store.knownLibraries
            .filter { ref in
                if let currentPath,
                   store.isSameSystemLibraryPath(ref.path, currentPath) { return false }
                if store.systemLibraries.contains(where: {
                    store.isSameSystemLibraryPath($0.path, ref.path)
                }) { return false }
                return true
            }
            .sorted { lhs, rhs in
                let leftDefault = store.isDefaultLibrary(lhs.path)
                let rightDefault = store.isDefaultLibrary(rhs.path)
                if leftDefault != rightDefault { return leftDefault }
                return false
            }
    }

    /// 一个打开过的图库：点一下切换过去；默认图库带锁且不能移除。
    private func knownLibraryRow(_ ref: SystemLibraryRef) -> some View {
        let isDefault = store.isDefaultLibrary(ref.path)
        let isExplicitDefault = store.isExplicitDefaultLibrary(ref.path)
        let name = libraryDisplayName(ref.name, path: ref.path)
        let exists = FileManager.default.fileExists(atPath: ref.path)
        return HStack(spacing: 2) {
            // 与带展开箭头的图库行左对齐。
            Spacer()
                .frame(width: 20)

            Button {
                guard exists else {
                    store.showToast("找不到「\(name)」，可能已被移动或删除")
                    return
                }
                store.activateLibrary(URL(fileURLWithPath: ref.path))
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: isDefault ? "internaldrive.fill" : "externaldrive.fill")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .foregroundStyle(exists ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    libraryKindBadge(isDefault: isDefault)
                }
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExplicitDefault
                  ? "默认图库：启动时自动打开"
                  : (isDefault ? "上次打开的图库：下次启动会继续打开它"
                               : (exists ? "点击切换到这个图库"
                                         : "图库不存在：可能已被移动、删除，或外置盘未连接")))
            .contextMenu {
                Button("打开此图库") {
                    store.activateLibrary(URL(fileURLWithPath: ref.path))
                }
                .disabled(!exists)
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
                }
                if exists, !isExplicitDefault {
                    Button("设为默认图库") { store.setDefaultLibrary(ref.path) }
                }
                Divider()
                Button("断开连接…", role: .destructive) {
                    store.confirmDisconnectLibrary(path: ref.path, name: name)
                }
                .help("从「全部图库」移除；如果是当前图库，会回到「创建或打开图库」")
            }
        }
    }

    /// 图库标签：只有「默认」（启动时会打开的那个）才显示。
    @ViewBuilder
    private func libraryKindBadge(isDefault: Bool) -> some View {
        if isDefault {
            libraryBadgeLabel(highlighted: true, title: "默认")
                .help("默认图库：启动时自动打开")
        }
    }

    private func libraryBadgeLabel(highlighted: Bool, title: String) -> some View {
        HStack(spacing: 2) {
            if highlighted {
                Image(systemName: "lock.fill")
                    .font(.system(size: 6.5, weight: .bold))
            }
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Capsule().fill((highlighted ? Color.accentColor : Color.primary).opacity(0.10)))
        .fixedSize()
    }

    /// App 自己图库的名字：始终取容器名，不能跟着「当前连接的系统图库」改名。
    private var appContainerLibraryName: String {
        guard let url = LibraryPaths.containerLibraryURL else { return "图库" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "图库" : name
    }

    /// 当前图库行是否处于高亮：外接 B 时 A 必须让出高亮，避免两行同时选中。
    private var currentLibraryIsActive: Bool {
        // 「图库资源」是跨图库总览：不点亮任何图库行。
        if store.sidebarItem == .systemLibraries { return false }
        if !store.isSystemScope { return true }
        return store.isNativeContainer && store.isBrowsingContainerSystemLibrary
    }

    /// 同名图库用上级目录区分，避免两行看起来一模一样。
    /// 当前图库、打开过的图库与已连接的图库一起统计，同名的两条才会加后缀。
    private func libraryDisplayName(_ name: String, path: String) -> String {
        var paths = Set<String>()
        if appContainerLibraryName == name,
           let current = LibraryPaths.containerLibraryURL?.standardizedFileURL.path {
            paths.insert(current)
        }
        for ref in store.knownLibraries where ref.name == name {
            paths.insert(URL(fileURLWithPath: ref.path).standardizedFileURL.path)
        }
        for ref in store.systemLibraries where ref.name == name {
            paths.insert(URL(fileURLWithPath: ref.path).standardizedFileURL.path)
        }
        guard paths.count > 1 else { return name }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? name : "\(name) · \(parent)"
    }

    /// 点当前图库：展开它自己的树，并切回 App 自己的图库（外接 B 时也能回到 A）。
    private func activateCurrentLibrary() {
        withAnimation(settings.motion.layout) {
            collapsedSystemLibraries.formUnion(store.systemLibraries.map(\.path))
            setSectionCollapsed("library.current", false)
        }
        persistExpansionState()
        if store.isNativeContainer, let url = LibraryPaths.containerLibraryURL {
            store.connectSystemLibrary(url)
        } else {
            store.navigate(to: .library)
        }
    }

    /// 当前真正展开着的外接图库（只有一个）。它展开时当前图库的树不再渲染。
    private var expandedLinkedLibraryPath: String? {
        guard let active = store.systemLibraryPath,
              let match = store.systemLibraries.first(where: {
                  store.isSameSystemLibraryPath($0.path, active)
              }),
              !collapsedSystemLibraries.contains(match.path) else { return nil }
        return match.path
    }

    /// 点外接图库：只展开这一棵，当前图库那棵同时合上。
    private func activateLinkedLibrary(_ ref: SystemLibraryRef) {
        withAnimation(settings.motion.layout) {
            collapsedSystemLibraries.remove(ref.path)
            setSectionCollapsed("library.current", true)
        }
        persistExpansionState()
        store.sourceHub.activate(.linkedLibrary(ref.path))
    }

    private func setSectionCollapsed(_ key: String, _ collapsed: Bool) {
        if collapsed {
            collapsedSections.insert(key)
            expandedSections.remove(key)
        } else {
            collapsedSections.remove(key)
            expandedSections.insert(key)
        }
    }

    /// 拾光自己图库的左侧树：作为「图库」实例展开后的内容。
    @ViewBuilder
    private var lumaLibraryTree: some View {
        sidebarRow(.library, icon: "photo.stack", title: "图库")
        sidebarRow(.collections, icon: "square.stack.3d.up", title: "精选集")

        sectionHeader("固定", key: "luma.fixed", topPadding: 12, indent: 0)
        if !isCollapsed("luma.fixed") {
            pinnedRows(system: false)
        }

        sectionHeader("媒体类型", key: "luma.media", topPadding: 12, indent: 0, navigateTo: .mediaTypes)
        if !isCollapsed("luma.media") {
            // 与系统「照片」一致：数量为 0 的媒体类型不占位。
            ForEach(MediaTypeKey.localCases) { key in
                if (mediaTypeCounts[key] ?? 0) > 0 {
                    sidebarRow(key.item(system: false), icon: key.icon, title: key.title,
                               pinKey: key.rawValue)
                }
            }
        }

        sectionHeader("更多项目", key: "luma.more", topPadding: 12, indent: 0, navigateTo: .moreItems)
        if !isCollapsed("luma.more") {
            // 顺序与「更多项目」总览页保持一致。
            sidebarRow(.favorites, icon: "heart.fill", title: "个人收藏", color: .pink, pinKey: "favorites")
            sidebarRow(.health, icon: "stethoscope", title: "图库体检", pinKey: "health")
            sidebarRow(.ratings, icon: "square.grid.2x2", title: "图库整理", color: .yellow,
                       pinKey: "ratings")
            sidebarRow(.revisit, icon: "clock.arrow.circlepath", title: "值得重看", pinKey: "revisit")
            if store.duplicateCount > 0 {
                sidebarRow(.duplicates, icon: "square.on.square", title: "重复项目", pinKey: "duplicates")
            }
            sidebarRow(.map, icon: "map", title: "地图", pinKey: "map")
            sidebarRow(.places, icon: "mappin.and.ellipse", title: "位置", pinKey: "places")
            sidebarRow(.people, icon: "person.crop.square", title: "人物", pinKey: "people")
            sidebarRow(.keywords, icon: "tag", title: "关键词", pinKey: "keywords")
            if store.analyzedCount > 0 {
                sidebarRow(.ocrTexts, icon: "text.viewfinder", title: "包含文字", pinKey: "ocrTexts")
            }
            sidebarRow(.recentlyEdited, icon: "slider.horizontal.3", title: "最近编辑", pinKey: "recentlyEdited")
            sidebarRow(.recentlySaved, icon: "square.and.arrow.down", title: "最近保存", pinKey: "recentlySaved")
            trashRow(pinKey: "trash")
            sidebarRow(.imports, icon: "square.and.arrow.down.on.square", title: "导入项目", pinKey: "imports")
            if store.hiddenCount > 0 {
                sidebarRow(.hidden, icon: "eye.slash", title: "已隐藏", color: .secondary, pinKey: "hidden")
            }
        }

        sectionHeader("场景", key: "luma.scenes", topPadding: 12, indent: 0, navigateTo: .scenes) {
            if store.isAnalyzingIntelligence {
                Button("停止分析") { store.cancelIntelligenceAnalysis() }
            } else {
                Button(store.analyzedCount > 0 ? "分析新照片…" : "分析照片内容…") {
                    store.analyzeIntelligence()
                }
                if store.analyzedCount > 0 {
                    Button("重新分析全部照片…") {
                        store.reanalyzeIntelligence()
                    }
                    Button("重置（清空结果）…", role: .destructive) {
                        showResetAnalysisConfirm = true
                    }
                }
            }
            if store.hasAnyScene {
                Divider()
                Button("生成场景智能相簿") {
                    store.createSceneSmartAlbums()
                }
            }
        }
        if !isCollapsed("luma.scenes") {
            sceneSectionBody
        }

        sectionHeader("相簿", key: "luma.albums", topPadding: 12, indent: 0, navigateTo: .allAlbums) {
            Button("新建相簿") {
                store.showNewAlbumSheet = true
            }
            Button("新建智能相簿…") {
                store.presentSmartAlbumEditor()
            }
        }
        if !isCollapsed("luma.albums") {
            sidebarRow(.allAlbums, icon: "rectangle.stack", title: "所有相簿")

            ForEach(store.rootFolders()) { folder in
                folderNode(folder, level: 0)
            }
            ForEach(store.rootAlbums) { album in
                albumRow(album, level: 0)
            }
        }

        if !store.smartAlbums.isEmpty {
            sectionHeader("智能相簿", key: "luma.smart", topPadding: 12, indent: 0) {
                Button("新建智能相簿…") {
                    store.presentSmartAlbumEditor()
                }
            }
            if !isCollapsed("luma.smart") {
                ForEach(store.smartAlbums) { album in
                    smartAlbumRow(album)
                }
            }
        }
    }

    /// 已连接的系统图库列表；同一时间只有一个处于连接/展开状态。
    private func systemLibraryRefRow(_ ref: SystemLibraryRef, isExpanded: Bool) -> some View {
        let isActive = store.systemLibraryPath.map { store.isSameSystemLibraryPath($0, ref.path) } ?? false
        // 图库资源总览不属于某一个图库：即使这个库正在连接中也不高亮。
        let isHighlighted = isActive && store.isSystemScope && store.sidebarItem != .systemLibraries
        let isHovered = hoveredSystemLibraryPath == ref.path
        let isDefault = store.isDefaultLibrary(ref.path)

        return HStack(spacing: 2) {
            Button {
                if isActive {
                    withAnimation(settings.motion.layout) {
                        if isExpanded {
                            collapsedSystemLibraries.insert(ref.path)
                            persistExpansionState()
                        } else {
                            activateLinkedLibrary(ref)
                        }
                    }
                } else {
                    activateLinkedLibrary(ref)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help(isExpanded ? "收起" : "展开")

            Button {
                activateLinkedLibrary(ref)
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(libraryDisplayName(ref.name, path: ref.path))
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    libraryKindBadge(isDefault: isDefault)
                    // 图库行不再显示照片个数：长名字会被挤压成「李…」，统一在「图库资源」里看体量。
                    if isActive, store.isLoadingSystemLibrary {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("在「照片」中打开图库") {
                    store.openSystemLibraryInPhotos(ref.path)
                }
                Button("重新读取") {
                    store.connectSystemLibrary(URL(fileURLWithPath: ref.path), forceRefresh: true)
                }
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
                }
                Button("选择其他图库…") { store.presentSystemLibraryPanel() }
                Button("新建图库…") { store.beginNewLibraryFlow() }
                Divider()
                Button("断开连接", role: .destructive) {
                    store.confirmRemoveSystemLibrary(path: ref.path, name: ref.name)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .padding(.trailing, 6)
            .opacity(isHovered || isHighlighted ? 1 : 0)
        }
        .background {
            LumaRowHighlight(active: isHighlighted, hovered: isHovered)
        }
        .onHover { hovering in
            hoveredSystemLibraryPath = hovering
                ? ref.path
                : (hoveredSystemLibraryPath == ref.path ? nil : hoveredSystemLibraryPath)
        }
        .contextMenu {
            Button("在「照片」中打开图库") { store.openSystemLibraryInPhotos(ref.path) }
            Button("重新读取") { store.connectSystemLibrary(URL(fileURLWithPath: ref.path)) }
            Button("在访达中显示图库") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.path)])
            }
            Divider()
            Button("断开连接", role: .destructive) {
                store.confirmRemoveSystemLibrary(path: ref.path, name: ref.name)
            }
        }
    }

    /// 当前系统图库的浏览入口（图库 / 精选集 / 固定 / 媒体类型 / 更多项目 / 场景 / 相簿），与其它分区左对齐。
    @ViewBuilder
    private var systemLibraryDetail: some View {
        // 不套内层 LazyVStack：所有行直接进入侧边栏最外层的 LazyVStack，
        // 展开成千上万个相簿时也只实例化可见行（对标系统「照片」的侧边栏）。
        Group {
            // 与「拾光」分区一致：最上面是系统图库自己的「图库」与「精选集」。
            sidebarRow(.systemLibrary, icon: "photo.stack", title: "图库")
            sidebarRow(.systemCollections, icon: "square.stack.3d.up", title: "精选集")

            sectionHeader("固定", key: "sys.fixed", topPadding: 12)
            if !isCollapsed("sys.fixed") {
                pinnedRows(system: true)
            }

            let visibleMediaTypes = MediaTypeKey.allCases.filter { (mediaTypeCounts[$0] ?? 0) > 0 }
            if !visibleMediaTypes.isEmpty {
                sectionHeader("媒体类型", key: "sys.media", topPadding: 12, navigateTo: .systemMediaTypes)
                if !isCollapsed("sys.media") {
                    ForEach(visibleMediaTypes) { key in
                        sidebarRow(key.item(system: true), icon: key.icon, title: key.title,
                                   pinKey: key.rawValue)
                    }
                }
            }

            sectionHeader("更多项目", key: "sys.more", topPadding: 12, navigateTo: .systemMoreItems)
            if !isCollapsed("sys.more") {
                // 与「更多项目」总览页保持同一顺序与图标；最近查看是系统图库独有入口。
                sidebarRow(.systemFavorites, icon: "heart.fill", title: "个人收藏", color: .pink,
                           pinKey: "favorites")
                sidebarRow(.systemHealth, icon: "stethoscope", title: "图库体检", pinKey: "health")
                sidebarRow(.systemRatings, icon: "square.grid.2x2", title: "图库整理", color: .yellow,
                           pinKey: "ratings")
                sidebarRow(.systemRevisit, icon: "clock.arrow.circlepath", title: "值得重看",
                           pinKey: "revisit")
                if store.systemDuplicateCount > 0 {
                    sidebarRow(.systemDuplicates, icon: "square.on.square", title: "重复项目",
                               pinKey: "duplicates")
                }
                sidebarRow(.systemMap, icon: "map", title: "地图", pinKey: "map")
                sidebarRow(.systemPlaces, icon: "mappin.and.ellipse", title: "位置", pinKey: "places")
                sidebarRow(.systemPeople, icon: "person.crop.square", title: "人物", pinKey: "people")
                sidebarRow(.systemKeywords, icon: "tag", title: "关键词", pinKey: "keywords")
                if store.ocrPhotoCount > 0 {
                    sidebarRow(.systemOcrTexts, icon: "text.viewfinder", title: "包含文字",
                               pinKey: "ocrTexts")
                }
                sidebarRow(.systemRecentlyViewed, icon: "eye", title: "最近查看",
                           pinKey: "recentlyViewed")
                sidebarRow(.systemEdited, icon: "slider.horizontal.3", title: "最近编辑",
                           pinKey: "recentlyEdited")
                sidebarRow(.systemRecentlySaved, icon: "square.and.arrow.down", title: "最近保存",
                           pinKey: "recentlySaved")
                systemTrashRow
                sidebarRow(.systemImports, icon: "square.and.arrow.down.on.square", title: "导入项目",
                           pinKey: "imports")
                if store.systemHiddenCount > 0 {
                    sidebarRow(.systemHidden, icon: "eye.slash", title: "已隐藏", color: .secondary,
                               pinKey: "hidden")
                }
            }

            sectionHeader("场景", key: "sys.scenes", topPadding: 12, navigateTo: .systemScenes) {
                if store.isAnalyzingSystemContent {
                    Button("停止识别") { store.cancelSystemContentAnalysis() }
                } else {
                    Button(store.systemAnalyzedCount > 0 ? "继续识别…" : "识别照片内容…") {
                        store.analyzeSystemContent()
                    }
                    if store.systemAnalyzedCount > 0 {
                        Button("重新识别全部照片…") {
                            showRestartSystemAnalysisConfirm = true
                        }
                        Button("重置（清空结果）…", role: .destructive) {
                            showResetSystemAnalysisConfirm = true
                        }
                    }
                }
            }
            if !isCollapsed("sys.scenes") {
                systemSceneSectionBody
            }

            if store.isLoadingSystemLibrary {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text(store.systemScanCount > 0
                         ? "正在读取系统图库… \(store.systemScanCount.formatted()) 项"
                         : "正在读取系统图库…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if let error = store.systemLibraryError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }

            // 可写的原生图库即使还没有相簿也保留分区入口，否则无法新建第一个相簿。
            if !store.systemFolders.isEmpty || !store.systemAlbums.isEmpty || store.canManageSystemAlbums {
                sectionHeader("相簿", key: "sys.albums", topPadding: 12, navigateTo: .systemAlbums) {
                    if store.canManageSystemAlbums {
                        Button("新建相簿…") {
                            store.namePrompt = .newSystemAlbum()
                        }
                        Button("新建文件夹…") {
                            store.namePrompt = .newSystemFolder()
                        }
                        Divider()
                        Button("清理空相簿与空文件夹…") {
                            store.presentEmptyCollectionsCleanup()
                        }
                    } else {
                        Text("挂载的图库只读，无法新建相簿或文件夹")
                            .disabled(true)
                    }
                }
            }
            if !isCollapsed("sys.albums") {
                let rows = store.systemFlatRows(expanded: expandedSystemFolders,
                                                expansionRevision: systemExpansionRevision)
                ForEach(rows) { row in
                    systemFlatRow(row.entry, level: row.level)
                }
            }
        }
    }

    private var systemTrashRow: some View {
        Button {
            store.navigate(to: .systemTrash)
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "trash")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("最近删除")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: store.sidebarItem == .systemTrash,
                                 hovered: hoveredItem == .systemTrash)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? .systemTrash : (hoveredItem == .systemTrash ? nil : hoveredItem)
        }
        .contextMenu {
            Button(store.isPinned(.system("trash")) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.system("trash"))
            }
        }
    }

    // MARK: - Network storage

    /// 侧边栏的源行统一由注册表驱动：新增 kind 只加注册表条目，不再在这里铺数组。
    private var cloudSourceDescriptors: [SourceDescriptor] {
        store.sourceRegistryState.sources(of: .cloudMount)
    }

    /// 影视源只在「网络影院」出现，网络资源分区只列网页资源站。
    private var catalogSourceDescriptors: [SourceDescriptor] {
        let cinemaIDs = catalog.cinemaSourceIDs
        return store.sourceRegistryState.sources(of: .catalogSite).filter { descriptor in
            guard let id = descriptor.id.uuidValue else { return true }
            return !cinemaIDs.contains(id)
        }
    }

    @ViewBuilder
    private var cloudSection: some View {
        sectionHeader("网络存储", key: "cloud", topPadding: 8, isModule: true,
                      navigateTo: .cloudStorages) {
            Button("网盘接入向导…") {
                store.presentCloudWizard()
            }
        }

        if !isCollapsed("cloud") {
            if cloudSourceDescriptors.isEmpty {
                Button {
                    store.presentCloudWizard()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("网盘接入向导…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(cloudSourceDescriptors) { descriptor in
                    if let mountID = descriptor.id.uuidValue,
                       let mount = cloud.mounts.first(where: { $0.id == mountID }) {
                        CloudMountSidebarRow(mount: mount,
                                             expandedMountID: $expandedCloudMountID)
                    }
                }
            }
        }
    }

    // MARK: - Network resources (catalog)

    @ViewBuilder
    private var catalogSection: some View {
        sectionHeader("网络资源", key: "catalog", topPadding: 8, isModule: true,
                      navigateTo: .catalogSources) {
            Button("接入资源…") {
                store.presentCatalogWizard()
            }
            Button("导出资源…") {
                store.exportSourceConfig(scope: .catalogResource,
                                         count: catalog.resourceSources.count,
                                         data: { catalog.exportSourceBundle(domain: .networkResource) })
            }
            .disabled(catalog.resourceSources.isEmpty)
            Button("清除全部海报缓存") {
                catalog.clearAllArtwork()
            }
        }

        if !isCollapsed("catalog") {
            if catalogSourceDescriptors.isEmpty {
                Button {
                    store.presentCatalogWizard()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("接入网络资源…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 不再保留「全部资源」这个聚合入口：分区本身就是资源总览，
                // 展开后直接列各个源，和「图库 / 网络存储 / 网络电视」保持一致。
                ForEach(catalogSourceDescriptors) { descriptor in
                    if let sourceID = descriptor.id.uuidValue,
                       let source = catalog.sources.first(where: { $0.id == sourceID }) {
                        CatalogSidebarRow(source: source,
                                          isDropTarget: catalogDropTargetID == source.id)
                            .onDrop(of: [catalogSourceDragType],
                                    delegate: CatalogSourceReorderDropDelegate(
                                        target: source.id,
                                        catalog: catalog,
                                        onTargeted: { targeted in
                                            if targeted {
                                                catalogDropTargetID = source.id
                                            } else if catalogDropTargetID == source.id {
                                                catalogDropTargetID = nil
                                            }
                                        }))
                    }
                }
                // 拖到列表末尾 → 排到最后，顺序同样作用于跨源搜索与聚合。
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [catalogSourceDragType],
                            delegate: CatalogSourceEndDropDelegate(catalog: catalog))
            }
        }
    }

    // MARK: - 网络影院

    /// 网络影院：独立于「网络存储 › 影院」，只聚合网络影视源。
    /// 与「网络资源」一致，展开后只列一级源行；分页（影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注）在页面工具栏里切换。
    @ViewBuilder
    private var networkCinemaSection: some View {
        sectionHeader("网络影院", key: "netcinema", topPadding: 8, isModule: true,
                      navigateTo: .networkCinema,
                      beforeNavigate: {
                          store.networkCinemaSourceID = nil
                      }) {
            Button("接入影视源…") {
                store.presentCatalogWizard(domain: .networkCinema)
            }
            Button("导出影视源…") {
                store.exportSourceConfig(scope: .networkCinema,
                                         count: catalog.cinemaSources.count,
                                         data: { catalog.exportSourceBundle(domain: .networkCinema) })
            }
            .disabled(catalog.cinemaSources.isEmpty)
        }

        if !isCollapsed("netcinema") {
            if enabledMovieSources.isEmpty {
                Button {
                    store.presentCatalogWizard(domain: .networkCinema)
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "popcorn")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("接入影视源…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(enabledMovieSources) { source in
                    NetworkCinemaSidebarRow(source: source,
                                            isDropTarget: catalogDropTargetID == source.id)
                        .onDrop(of: [catalogSourceDragType],
                                delegate: CatalogSourceReorderDropDelegate(
                                    target: source.id,
                                    catalog: catalog,
                                    onTargeted: { targeted in
                                        if targeted {
                                            catalogDropTargetID = source.id
                                        } else if catalogDropTargetID == source.id {
                                            catalogDropTargetID = nil
                                        }
                                    }))
                }
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [catalogSourceDragType],
                            delegate: CatalogSourceEndDropDelegate(catalog: catalog))
            }
        }
    }

    private var enabledMovieSources: [CatalogSource] {
        catalog.enabledCinemaSources
    }

    // MARK: - 网络电视

    @ViewBuilder
    private var tvSection: some View {
        // 点分区标题直接进「全频直播 · 聚合」：不沿用上次聚焦的某个源，
        // 否则会像点开 APTV 一样停在单个源上。
        sectionHeader("网络电视", key: "tv", topPadding: 8, isModule: true,
                      navigateTo: .iptv,
                      beforeNavigate: {
                          tv.focusAllSources()
                          tv.setHubTab(.channels)
                      }) {
            Button("刷新频道") { tv.refresh() }
                .disabled(!tv.enabled)
            Button("检测全部源") { tv.checkAllSources() }
                .disabled(!tv.enabled || tv.isChecking)
            Divider()
            Button("接入电视源…") { tv.showWizard = true }
            Button("导出电视源…") {
                store.exportSourceConfig(scope: .television,
                                         count: tv.playlists.count,
                                         data: { tv.exportPlaylistBundle() })
            }
            .disabled(tv.playlists.isEmpty)
        }

        if !isCollapsed("tv") {
            if tv.playlists.isEmpty {
                // 一个电视源都没有：显示「接入电视源…」，接入后换成源列表（与网络影院一致）。
                Button {
                    tv.showWizard = true
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "tv")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("接入电视源…")
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 「收藏频道 / 最近观看」不再放在侧边栏：这两个入口已收进网络电视主页。
                // 电视源默认全部收起，不在侧边栏铺开频道分类，避免把整段撑得很长。
                ForEach(tv.playlists) { playlist in
                    let categories = tv.categoryGroups(for: playlist.id)
                    tvSourceRow(playlist, categories: categories)
                        .onDrop(of: [tvSourceDragType],
                                delegate: TVSourceReorderDropDelegate(
                                    target: playlist.id,
                                    tv: tv,
                                    onTargeted: { targeted in
                                        if targeted {
                                            tvDropTargetID = playlist.id
                                        } else if tvDropTargetID == playlist.id {
                                            tvDropTargetID = nil
                                        }
                                    }))
                    if expandedTVSources.contains(playlist.id) {
                        ForEach(categories) { category in
                            tvCategoryRow(category, playlistID: playlist.id)
                        }
                    }
                }
                // 拖到列表末尾 → 排到最后，顺序同样落进电视库。
                Color.clear
                    .frame(height: 6)
                    .onDrop(of: [tvSourceDragType],
                            delegate: TVSourceEndDropDelegate(tv: tv))
            }
        }
    }

    /// 电视源健康：按最近一次检测结果给行尾状态点，未检测 / 已停用保持安静。
    private func tvSourceHealth(_ playlist: TVPlaylist) -> SourceHealth? {
        guard playlist.isEnabled else { return nil }
        if let error = playlist.lastError {
            return SourceHealth(state: .offline,
                                checkedAt: playlist.lastCheckedAt,
                                message: error)
        }
        if let latency = playlist.lastLatencyMilliseconds, latency > 2500 {
            return SourceHealth(state: .degraded,
                                checkedAt: playlist.lastCheckedAt,
                                message: "延迟偏高")
        }
        return store.sourceHub.health(for: .television(playlist.id))
    }

    private func tvSourceRow(_ playlist: TVPlaylist, categories: [TVCategory]) -> some View {
        SourceSidebarRow(
            model: SourceRowModel(
                title: playlist.name,
                subtitle: nil,
                // 与「网络资源 / 网络存储」的源行一致：单行标题 + 行尾数量，不再用第二行副标题。
                badge: nil,
                countText: playlist.isEnabled ? playlist.lastChannelCount.map { "\($0)" } : nil,
                isCurrent: store.sidebarItem == .iptv
                    && tv.focusedPlaylistID == playlist.id
                    && tv.groupFilter == nil,
                isEnabled: playlist.isEnabled,
                isLoading: tv.isChecking,
                health: tvSourceHealth(playlist)
            ),
            isExpanded: expandedTVSources.contains(playlist.id),
            showsToggle: !categories.isEmpty,
            isDropTarget: tvDropTargetID == playlist.id,
            onOpen: { openTV(playlist.id) },
            onToggle: {
                if expandedTVSources.contains(playlist.id) {
                    expandedTVSources.remove(playlist.id)
                } else {
                    expandedTVSources.insert(playlist.id)
                }
            },
            onRetry: { tv.enqueueConnectionChecks([playlist.id]) },
            dragProvider: { tvSourceDragProvider(playlist.id) }
        ) { hovered in
            // 封面与其他源行同一套语言：渐变底 + 白色粗图标 + 描边与悬停微缩放。
            ZStack {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.95),
                                                  Color.accentColor.opacity(0.60)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: playlist.isEnabled
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .frame(width: LumaMetrics.sidebarCoverSize,
                   height: LumaMetrics.sidebarCoverSize)
            .overlay {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.34 : 0.20), lineWidth: 0.6)
            }
            .shadow(color: Color.accentColor.opacity(hovered ? 0.45 : 0.26),
                    radius: hovered ? 6 : 3, y: 1.5)
            .scaleEffect(hovered ? 1.06 : 1)
            .opacity(playlist.isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.16), value: hovered)
        } menu: {
            Button("打开频道") { openTV(playlist.id) }
            Button("连接检测") { tv.enqueueConnectionChecks([playlist.id]) }
                .disabled(!playlist.isEnabled || tv.isChecking)
            Divider()
            Button("上移") { tv.movePlaylist(playlist.id, by: -1) }
                .disabled(tv.playlists.first?.id == playlist.id)
            Button("下移") { tv.movePlaylist(playlist.id, by: 1) }
                .disabled(tv.playlists.last?.id == playlist.id)
            Divider()
            Button(playlist.isEnabled ? "停用这个源" : "启用这个源") {
                tv.setPlaylistEnabled(playlist.id, enabled: !playlist.isEnabled)
            }
            Divider()
            Button("删除这个源", role: .destructive) { tv.removePlaylist(playlist.id) }
        }
    }

    /// 源下面的二级分类：点进去只显示该分类的频道。
    private func tvCategoryRow(_ category: TVCategory, playlistID: UUID) -> some View {
        SidebarCategoryRow(
            icon: "circle.fill",
            title: category.group,
            count: category.count,
            isActive: store.sidebarItem == .iptv
                && tv.focusedPlaylistID == playlistID
                && tv.groupFilter == category.group,
            helpText: "查看「\(category.group)」频道",
            leadingIndent: 30,
            iconSize: 5,
            action: { openTVGroup(category.group, in: playlistID) }
        )
    }

    private func openTVGroup(_ group: String, in playlistID: UUID) {
        if !tv.enabled { tv.setEnabled(true) }
        tv.focusGroup(group, in: playlistID)
        tv.setHubTab(.channels)
        store.navigate(to: .iptv)
    }

    private func openTV(_ playlistID: UUID) {
        // 电视源也走统一源入口：激活策略、会话与健康状态由 sourceHub 决定。
        store.sourceHub.activate(.television(playlistID))
    }

    private func toggleSystemFolder(_ id: Int64) {
        withAnimation(settings.motion.layout) {
            if expandedSystemFolders.contains(id) {
                expandedSystemFolders.remove(id)
            } else {
                expandedSystemFolders.insert(id)
            }
        }
        systemExpansionRevision &+= 1
        persistExpansionState()
    }

    /// 侧边栏系统树的「拍平行」：只画这一行，子节点由拍平数组负责（惰性渲染）。
    @ViewBuilder
    private func systemFlatRow(_ entry: SystemSidebarEntry, level: Int) -> some View {
        switch entry {
        case .folder(let folder):
            systemFolderRow(folder, level: level)
        case .album(let album):
            systemAlbumRow(album, level: level)
        }
    }

    /// 「固定」区里的文件夹：行 + 展开的子节点（数量很少，保留递归即可）。
    private func systemFolderNode(_ folder: SystemFolderInfo, level: Int, scope: String = "system") -> AnyView {
        let isExpanded = expandedSystemFolders.contains(folder.id)
        let children = store.systemChildren(of: folder.id)
        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                systemFolderRow(folder, level: level, scope: scope)
                if isExpanded {
                    ForEach(children) { child in
                        systemNode(child, level: level + 1)
                    }
                }
            }
        )
    }

    private func systemFolderRow(_ folder: SystemFolderInfo, level: Int, scope: String = "system") -> some View {
        let isExpanded = expandedSystemFolders.contains(folder.id)
        let hasChildren = !store.systemChildren(of: folder.id).isEmpty

        return HoverRowHighlight(active: store.sidebarItem == .systemFolder(folder.id)) {
            HStack(spacing: Self.folderChevronGap) {
                Button {
                    toggleSystemFolder(folder.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: Self.folderChevronWidth, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hasChildren ? 1 : 0)
                .disabled(!hasChildren)

                Button {
                    store.navigate(to: .systemFolder(folder.id))
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                            .background(Color.accentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                             style: .continuous))
                        Text(folder.name)
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, rowLeadingPadding(level))
            .padding(.trailing, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .overlay {
                // 把相簿拖到这个文件夹上时给一个落点提示，松手即移动。
                if systemFolderDropTarget == folder.id {
                    RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [systemSidebarDragType], isTargeted: Binding(
                get: { systemFolderDropTarget == folder.id },
                set: { targeted in
                    if targeted {
                        systemFolderDropTarget = folder.id
                    } else if systemFolderDropTarget == folder.id {
                        systemFolderDropTarget = nil
                    }
                }
            )) { providers in
                handleSystemAlbumDrop(providers, into: folder.id)
            }
            .contextMenu {
                Button("打开文件夹") {
                    store.navigate(to: .systemFolder(folder.id))
                }
                Button(store.isPinned(.systemFolder(folder.id)) ? "取消固定" : "固定到侧边栏") {
                    store.togglePin(.systemFolder(folder.id))
                }
                Button("拷贝到拾光（含子文件夹）") {
                    store.importSystemFolderToLibrary(folder.id)
                }
                if store.isNativeContainer {
                    // 官方图库先给出完整的管理入口；真正的写目标是「照片」当前库，
                    // 点击时再校验，失败会说明原因，避免菜单看起来像功能缺失。
                    Divider()
                    Button("在此文件夹中新建相簿…") {
                        store.namePrompt = .newSystemAlbum(folderID: folder.id)
                    }
                    Button("新建子文件夹…") {
                        store.namePrompt = .newSystemFolder(parentID: folder.id)
                    }
                    Divider()
                    Button("提取子目录相簿到当前文件夹") {
                        store.requestExtractSystemFolderAlbums(folder.id)
                    }
                    .help("把这个文件夹及其所有子目录里的相簿提取到这一层，子目录里的相簿会移到当前文件夹")
                    Button("重命名文件夹…") {
                        store.namePrompt = .renameSystemFolder(folder.id, current: folder.name)
                    }
                    Button("删除文件夹…", role: .destructive) {
                        store.presentDeleteSystemFolder(folder.id)
                    }
                    if store.systemWriteTargetState == .mismatch {
                        Divider()
                        Button("在「照片」中打开此图库…") {
                            store.openCurrentLibraryInPhotosForImport()
                        }
                        Button("重新检测写入目标") {
                            store.refreshSystemWriteTargetState(announce: true)
                        }
                        Button("重新启动拾光以启用编辑") {
                            store.relaunchForLibraryWrite()
                        }
                        .help("在「照片」里切换图库后，PhotoKit 需要重启拾光才会指向新库")
                    }
                }
            }
        }
    }

    /// 侧边栏相簿拖到文件夹：解析拖拽载荷里的相簿主键，经 PhotoKit 移到该文件夹。
    private func handleSystemAlbumDrop(_ providers: [NSItemProvider], into folderID: Int64) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: systemSidebarDragType.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  let albumID = Int64(raw) else { return }
            Task { @MainActor in
                store.moveSystemAlbums([albumID], toFolder: folderID)
            }
        }
        return true
    }

    /// 系统相簿的拖拽载荷：只带相簿主键，类型独立于照片拖拽。
    private func systemAlbumDragProvider(_ album: SystemAlbumInfo) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data("\(album.id)".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: systemSidebarDragType.identifier,
                                            visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    /// 文件夹与相簿按图库原始顺序混排渲染。
    @ViewBuilder
    private func systemNode(_ entry: SystemSidebarEntry, level: Int) -> some View {
        switch entry {
        case .folder(let folder):
            systemFolderNode(folder, level: level)
        case .album(let album):
            systemAlbumRow(album, level: level)
        }
    }

    private func systemAlbumRow(_ album: SystemAlbumInfo, level: Int, scope: String = "system") -> some View {
        HoverRowHighlight(active: store.sidebarItem == .systemAlbum(album.id)) {
            Button {
                store.navigate(to: .systemAlbum(album.id))
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    SystemAlbumCoverView(albumID: album.id)
                    Text(album.name)
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if store.systemAlbumIsEmpty(album.id) {
                        Image(systemName: "tray")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, albumLeadingPadding(level, scope: scope))
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 可写的原生图库才允许拖动：拖到侧边栏的文件夹上即移动过去。
            .modifier(SidebarAlbumDragModifier(enabled: store.canManageSystemAlbums) {
                systemAlbumDragProvider(album)
            })
            .contextMenu {
            Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
            Button(store.isPinned(.systemAlbum(album.id)) ? "取消固定" : "固定到侧边栏") {
                store.togglePin(.systemAlbum(album.id))
            }
            Button("拷贝到拾光") {
                store.importSystemAlbumToLibrary(album.id)
            }
            if store.isNativeContainer {
                Divider()
                Button("移动到文件夹…") {
                    store.presentMoveSystemAlbumsToFolder(album.id)
                }
                Button("重命名相簿…") {
                    store.namePrompt = .renameSystemAlbum(album.id, current: album.name)
                }
                Button("删除相簿", role: .destructive) {
                    store.deleteSystemAlbum(album.id)
                }
                if store.systemWriteTargetState == .mismatch {
                    Divider()
                    Button("在「照片」中打开此图库…") {
                        store.openCurrentLibraryInPhotosForImport()
                    }
                    Button("重新检测写入目标") {
                        store.refreshSystemWriteTargetState(announce: true)
                    }
                    Button("重新启动拾光以启用编辑") {
                        store.relaunchForLibraryWrite()
                    }
                    .help("在「照片」里切换图库后，PhotoKit 需要重启拾光才会指向新库")
                }
            }
            if let path = store.systemLibraryPath {
                Divider()
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }
    }
}

/// 只读图库不加拖拽：避免出现"能拖但拖不动"的假入口。
private struct SidebarAlbumDragModifier: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag(provider)
        } else {
            content
        }
    }
}


