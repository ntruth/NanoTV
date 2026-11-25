import AppKit
import SwiftUI
import LumaContentCore


/// 相簿分区的各类总览页：系统图库文件夹、媒体类型、场景、导入会话等。

/// 官方「照片」图库里的文件夹：只展示下一层的子文件夹与相簿（与系统「照片」一致），只读。
struct SystemFolderOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// 为空时展示系统图库根层（「相簿」分区总览）。
    var folderID: Int64? = nil

    @State private var hoveredKey: String?

    /// 卡片墙每行列数：默认尺寸下 5 个，与「所有相簿」一致。
    var entries: [SystemSidebarEntry] {
        if let folderID { return store.systemChildren(of: folderID) }
        return store.systemChildren(of: nil)
    }

    var childFolders: [SystemFolderInfo] {
        entries.compactMap { entry in
            if case .folder(let folder) = entry { return folder }
            return nil
        }
    }

    var childAlbums: [SystemAlbumInfo] {
        entries.compactMap { entry in
            if case .album(let album) = entry { return album }
            return nil
        }
    }

    var folder: SystemFolderInfo? {
        guard let folderID else { return nil }
        return store.systemFolders.first(where: { $0.id == folderID })
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if entries.isEmpty {
                        emptyState
                    } else if store.albumDisplayStyle == .grid {
                        // 按可用宽度均分列宽，默认铺满窗口，不让右侧留空。
                        let spacing: CGFloat = 22
                        let available = max(0, proxy.size.width - 48)
                        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 26) {
                            // 按侧边栏的原始顺序混排文件夹与相簿，保证两个入口看到的排序一致。
                            ForEach(entries) { entry in
                                switch entry {
                                case .folder(let child):
                                    folderCard(child, width: itemWidth)
                                case .album(let album):
                                    albumCard(album, width: itemWidth)
                                }
                            }
                        }
                    } else if store.albumDisplayStyle == .list {
                        let spacing: CGFloat = 28
                        let available = max(240, proxy.size.width - 48)
                        let columns = max(1, min(6, Int((available + spacing) / (300 + spacing))))
                        let itemWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                        let thumb = min(160, max(64, CGFloat(store.thumbSize) * 0.75))
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(itemWidth),
                                                                     spacing: spacing,
                                                                     alignment: .leading),
                                                 count: columns),
                                  alignment: .leading,
                                  spacing: 24) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .folder(let child):
                                    folderListRow(child, thumb: thumb)
                                case .album(let album):
                                    albumListRow(album, thumb: thumb)
                                }
                            }
                        }
                    } else {
                        let tile = min(320, max(120, CGFloat(store.thumbSize) * 1.7))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile),
                                                     spacing: 10, alignment: .top)],
                                  alignment: .leading,
                                  spacing: 10) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .folder(let child):
                                    folderCollageTile(child, side: tile)
                                case .album(let album):
                                    albumCollageTile(album, side: tile)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(settings.motion.layout, value: store.albumDisplayStyle)
    }

    // MARK: - 头部

    var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // 标题与返回层级由窗口工具栏统一展示，这里只保留数量与显示方式。
            Text("\(childAlbums.count) 个相簿, \(childFolders.count) 个文件夹")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            // 原生「照片」图库可写时，把新建入口放在相簿总览页上，和侧边栏分区菜单一致。
            if store.canManageSystemAlbums {
                Menu {
                    Button("新建相簿…") {
                        store.namePrompt = .newSystemAlbum(folderID: folderID)
                    }
                    Button("新建文件夹…") {
                        store.namePrompt = .newSystemFolder(parentID: folderID)
                    }
                    if folderID == nil {
                        Divider()
                        Button("清理空相簿与空文件夹…") {
                            store.presentEmptyCollectionsCleanup()
                        }
                    }
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(folderID == nil
                      ? "在「照片」中新建相簿 / 文件夹，或清理空的相簿与文件夹"
                      : "在这个文件夹里新建相簿 / 子文件夹")
            }
            AlbumDisplayStyleMenu()
        }
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(folderID == nil ? "还没有相簿" : "这个文件夹是空的")
                .font(.system(size: 17, weight: .semibold))
            Text(folderID == nil
                 ? "系统「照片」里还没有相簿或文件夹。"
                 : "系统「照片」里还没有在这个文件夹下添加相簿。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - 封面

    /// 文件夹的四宫格封面（异步）：从自身与更深层相簿里取最多 4 张；限制递归深度。
    /// 相簿墙可能有上万个相簿，封面查询必须离开 body 主线程，否则打开文件夹就卡住。
    func folderPhotosAsync(_ id: Int64, limit: Int = 4, depth: Int = 0) async -> [PhotoItem] {
        guard limit > 0, depth < 4 else { return [] }
        var result: [PhotoItem] = []
        for entry in store.systemChildren(of: id) {
            guard result.count < limit else { break }
            let photos: [PhotoItem]
            switch entry {
            case .album(let album):
                photos = await store.systemAlbumPreviewPhotosAsync(album.id, limit: limit)
            case .folder(let child):
                photos = await folderPhotosAsync(child.id, limit: limit, depth: depth + 1)
            }
            for photo in photos where result.count < limit {
                if !result.contains(where: { $0.id == photo.id }) { result.append(photo) }
            }
        }
        return result
    }

    // MARK: - 卡片

    func folderCard(_ child: SystemFolderInfo, width: CGFloat) -> some View {
        let key = "folder-\(child.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await folderPhotosAsync(child.id)
        } content: { photos in
            cardBody(key: key,
                     title: child.name,
                     cover: photos.first,
                     photos: photos,
                     placeholder: .folder,
                     width: width) {
                store.navigate(to: .systemFolder(child.id))
            } contextMenu: {
                Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
                Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
            }
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    func albumCard(_ album: SystemAlbumInfo, width: CGFloat) -> some View {
        let key = "album-\(album.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await store.systemAlbumPreviewPhotosAsync(album.id, limit: 1)
        } content: { photos in
            cardBody(key: key,
                     title: album.name,
                     cover: photos.first,
                     placeholder: .album,
                     width: width) {
                store.navigate(to: .systemAlbum(album.id))
            } contextMenu: {
                Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
                Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
            }
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    // MARK: - 列表 / 拼贴墙

    /// 文件夹子树里的相簿数量（限制递归深度，避免异常结构）。
    func folderAlbumCount(_ id: Int64, depth: Int = 0) -> Int {
        guard depth < 4 else { return 0 }
        return store.systemChildren(of: id).reduce(0) { total, entry in
            switch entry {
            case .album:
                return total + 1
            case .folder(let child):
                return total + folderAlbumCount(child.id, depth: depth + 1)
            }
        }
    }

    func folderListRow(_ child: SystemFolderInfo, thumb: CGFloat) -> some View {
        let key = "folder-row-\(child.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await folderPhotosAsync(child.id, limit: 1)
        } content: { photos in
            AlbumOverviewRow(title: child.name,
                             subtitle: folderAlbumCount(child.id).formatted(),
                             cover: photos.first,
                             placeholder: .folder,
                             side: thumb,
                             action: { store.navigate(to: .systemFolder(child.id)) },
                             menu: {
                                 Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
                                 Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
                             })
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    func albumListRow(_ album: SystemAlbumInfo, thumb: CGFloat) -> some View {
        let key = "album-row-\(album.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await store.systemAlbumPreviewPhotosAsync(album.id, limit: 1)
        } content: { photos in
            AlbumOverviewRow(title: album.name,
                             subtitle: store.systemAlbumPhotoCount(album.id).formatted(),
                             cover: photos.first,
                             placeholder: .album,
                             side: thumb,
                             action: { store.navigate(to: .systemAlbum(album.id)) },
                             menu: {
                                 Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
                                 Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
                             })
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    func folderCollageTile(_ child: SystemFolderInfo, side: CGFloat) -> some View {
        let key = "folder-tile-\(child.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await folderPhotosAsync(child.id)
        } content: { photos in
            AlbumOverviewTile(title: child.name,
                              subtitle: "\(folderAlbumCount(child.id)) 个相簿",
                              photos: photos,
                              placeholder: .folder,
                              side: side,
                              isFolder: true,
                              action: { store.navigate(to: .systemFolder(child.id)) },
                              menu: {
                                  Button("打开文件夹") { store.navigate(to: .systemFolder(child.id)) }
                                  Button("拷贝到拾光（含子文件夹）") { store.importSystemFolderToLibrary(child.id) }
                              })
        }
        .accessibilityLabel("文件夹 \(child.name)")
    }

    func albumCollageTile(_ album: SystemAlbumInfo, side: CGFloat) -> some View {
        let key = "album-tile-\(album.id)"
        return SystemCoverLoader(key: "\(key)#\(store.systemStructureRevision)") {
            await store.systemAlbumPreviewPhotosAsync(album.id, limit: 4)
        } content: { photos in
            AlbumOverviewTile(title: album.name,
                              subtitle: "\(store.systemAlbumPhotoCount(album.id)) 项",
                              photos: photos,
                              placeholder: .album,
                              side: side,
                              isFolder: false,
                              action: { store.navigate(to: .systemAlbum(album.id)) },
                              menu: {
                                  Button("打开相簿") { store.navigate(to: .systemAlbum(album.id)) }
                                  Button("拷贝到拾光") { store.importSystemAlbumToLibrary(album.id) }
                              })
        }
        .accessibilityLabel("相簿 \(album.name)")
    }

    func cardBody<MenuContent: View>(key: String,
                                             title: String,
                                             cover: PhotoItem?,
                                             photos: [PhotoItem] = [],
                                             placeholder: AlbumPlaceholderStyle,
                                             width: CGFloat,
                                             action: @escaping () -> Void,
                                             @ViewBuilder contextMenu: () -> MenuContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if photos.count >= 2 {
                    FolderMosaicImage(photos: photos, side: width)
                } else {
                    AlbumCoverImage(photo: cover, side: width, style: placeholder)
                }
            }
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture(perform: action)
        .contextMenu(menuItems: contextMenu)
    }
}

/// 封面异步加载器：先渲染占位，后台取到封面后再替换。
/// 相簿墙可能有上万个相簿，如果在 body 里同步查 `Photos.sqlite`，打开文件夹就会卡住。
struct SystemCoverLoader<Content: View>: View {
    let key: String
    let load: () async -> [PhotoItem]
    let content: ([PhotoItem]) -> Content

    @State private var photos: [PhotoItem] = []

    init(key: String,
         load: @escaping () async -> [PhotoItem],
         @ViewBuilder content: @escaping ([PhotoItem]) -> Content) {
        self.key = key
        self.load = load
        self.content = content
    }

    var body: some View {
        content(photos)
            .task(id: key) {
                let loaded = await load()
                guard !Task.isCancelled else { return }
                photos = loaded
            }
    }
}

/// 媒体类型总览：卡片墙展示各分类的数量与封面（侧边栏「媒体类型」分区头点开）。
struct MediaTypesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let summary = store.mediaTypeSummary
        let system = store.isSystemScope
        let keys = (system ? MediaTypeKey.allCases : MediaTypeKey.localCases)
            .filter { (summary.counts[$0] ?? 0) > 0 }
        CategoryOverviewView(
            entries: keys.map { key in
                CategoryOverviewEntry(id: key.rawValue,
                                      title: key.title,
                                      icon: key.icon,
                                      count: summary.counts[key] ?? 0,
                                      cover: summary.covers[key],
                                      item: key.item(system: system))
            },
            emptyIcon: "square.grid.2x2",
            emptyTitle: "还没有媒体类型",
            emptyMessage: system
                ? "系统「照片」图库里还没有可分类的项目。"
                : "导入照片后会自动按类型归类。"
        )
    }
}

/// 场景总览：卡片墙展示端侧识别出的场景分类（本地图库用落库结果，系统图库用内存结果）。
struct ScenesOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let summary = store.sceneSummary
        let categories = SceneCatalog.categories.filter { (summary.counts[$0.id] ?? 0) > 0 }
        let system = store.isSystemScope
        let analyzed = system ? store.systemAnalyzedCount : store.analyzedCount
        let analyzing = system ? store.isAnalyzingSystemContent : store.isAnalyzingIntelligence
        CategoryOverviewView(
            entries: categories.map { category in
                CategoryOverviewEntry(id: category.id,
                                      title: category.title,
                                      icon: category.icon,
                                      count: summary.counts[category.id] ?? 0,
                                      cover: summary.covers[category.id],
                                      item: system ? .systemScene(category.id) : .scene(category.id))
            },
            emptyIcon: "sparkles",
            emptyTitle: analyzed == 0 ? "还没有识别照片内容" : "未识别到常见场景",
            emptyMessage: "识别场景与照片中的文字，全部在本机完成。",
            emptyActionTitle: analyzing ? nil : (system ? "识别照片内容…" : "分析照片内容…"),
            emptyAction: {
                if system {
                    store.analyzeSystemContent()
                } else {
                    store.analyzeIntelligence()
                }
            }
        )
    }
}

/// 分类总览里的一个卡片条目。
struct CategoryOverviewEntry: Identifiable {
    let id: String
    let title: String
    let icon: String
    let count: Int
    let cover: PhotoItem?
    let item: SidebarItem
}

/// 分类卡片墙：媒体类型与场景共用（数量、封面均由 Store 汇总好）。
struct CategoryOverviewView: View {
    let entries: [CategoryOverviewEntry]
    let emptyIcon: String
    let emptyTitle: String
    let emptyMessage: String
    var emptyActionTitle: String? = nil
    var emptyAction: (() -> Void)? = nil

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredKey: String?

    /// 卡片墙每行列数：默认尺寸下 5 个，随工具栏缩放变化。
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 标题由窗口工具栏统一展示，这里只保留分类数量。
                    Text("\(entries.count) 个分类")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if entries.isEmpty {
                        emptyState
                    } else {
                        // 按可用宽度均分列宽，默认铺满窗口，不让右侧留空。
                        let spacing: CGFloat = 22
                        let available = max(0, proxy.size.width - 48)
                        let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 26) {
                            ForEach(entries) { entry in
                                card(entry, width: itemWidth)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 17, weight: .semibold))
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let emptyActionTitle, let emptyAction {
                Button(emptyActionTitle, action: emptyAction)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    func card(_ entry: CategoryOverviewEntry, width: CGFloat) -> some View {
        let key = entry.id
        return VStack(alignment: .leading, spacing: 8) {
            AlbumCoverImage(photo: entry.cover, side: width, style: .icon(entry.icon))
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            HStack(spacing: 5) {
                Image(systemName: entry.icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.count.formatted())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture {
            store.navigate(to: entry.item)
        }
        .accessibilityLabel("\(entry.title)，\(entry.count) 项")
    }
}

/// 更多项目总览：把侧边栏「更多项目」里的入口做成卡片列表（本地 / 系统图库共用）。
struct MoreItemsOverviewView: View {
    var system: Bool

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredKey: String?

    struct Entry: Identifiable {
        let id: String
        let title: String
        let icon: String
        let item: SidebarItem
    }

    var entries: [Entry] {
        if system {
            // 与侧边栏「更多项目」同一顺序、同名、同图标；条件入口也与侧边栏一致。
            var list: [Entry] = [
                Entry(id: "favorites", title: "个人收藏", icon: "heart.fill", item: .systemFavorites),
                Entry(id: "health", title: "图库体检", icon: "stethoscope", item: .systemHealth),
                Entry(id: "ratings", title: "图库整理", icon: "square.grid.2x2", item: .systemRatings),
                Entry(id: "revisit", title: "值得重看", icon: "clock.arrow.circlepath", item: .systemRevisit)
            ]
            if store.systemDuplicateCount > 0 {
                list.append(Entry(id: "duplicates", title: "重复项目", icon: "square.on.square",
                                  item: .systemDuplicates))
            }
            list += [
                Entry(id: "map", title: "地图", icon: "map", item: .systemMap),
                Entry(id: "places", title: "位置", icon: "mappin.and.ellipse", item: .systemPlaces),
                Entry(id: "people", title: "人物", icon: "person.crop.square", item: .systemPeople),
                Entry(id: "keywords", title: "关键词", icon: "tag", item: .systemKeywords)
            ]
            if store.ocrPhotoCount > 0 {
                list.append(Entry(id: "ocr", title: "包含文字", icon: "text.viewfinder", item: .systemOcrTexts))
            }
            list += [
                Entry(id: "recentlyViewed", title: "最近查看", icon: "eye", item: .systemRecentlyViewed),
                Entry(id: "recentlyEdited", title: "最近编辑", icon: "slider.horizontal.3", item: .systemEdited),
                Entry(id: "recentlySaved", title: "最近保存", icon: "square.and.arrow.down",
                      item: .systemRecentlySaved),
                Entry(id: "trash", title: "最近删除", icon: "trash", item: .systemTrash),
                Entry(id: "imports", title: "导入项目", icon: "square.and.arrow.down.on.square",
                      item: .systemImports)
            ]
            if store.systemHiddenCount > 0 {
                list.append(Entry(id: "hidden", title: "已隐藏", icon: "eye.slash", item: .systemHidden))
            }
            return list
        }
        // 与侧边栏「更多项目」同一顺序、同名、同图标；条件入口也与侧边栏一致。
        var list: [Entry] = [
            Entry(id: "favorites", title: "个人收藏", icon: "heart.fill", item: .favorites),
            Entry(id: "health", title: "图库体检", icon: "stethoscope", item: .health),
            Entry(id: "ratings", title: "图库整理", icon: "square.grid.2x2", item: .ratings),
            Entry(id: "revisit", title: "值得重看", icon: "clock.arrow.circlepath", item: .revisit)
        ]
        if store.duplicateCount > 0 {
            list.append(Entry(id: "duplicates", title: "重复项目", icon: "square.on.square",
                              item: .duplicates))
        }
        list += [
            Entry(id: "map", title: "地图", icon: "map", item: .map),
            Entry(id: "places", title: "位置", icon: "mappin.and.ellipse", item: .places),
            Entry(id: "people", title: "人物", icon: "person.crop.square", item: .people),
            Entry(id: "keywords", title: "关键词", icon: "tag", item: .keywords)
        ]
        if store.analyzedCount > 0 {
            list.append(Entry(id: "ocr", title: "包含文字", icon: "text.viewfinder", item: .ocrTexts))
        }
        list += [
            Entry(id: "recentlyEdited", title: "最近编辑", icon: "slider.horizontal.3", item: .recentlyEdited),
            Entry(id: "recentlySaved", title: "最近保存", icon: "square.and.arrow.down", item: .recentlySaved),
            Entry(id: "trash", title: "最近删除", icon: "trash", item: .trash),
            Entry(id: "imports", title: "导入项目", icon: "square.and.arrow.down.on.square", item: .imports)
        ]
        if store.hiddenCount > 0 {
            list.append(Entry(id: "hidden", title: "已隐藏", icon: "eye.slash", item: .hidden))
        }
        return list
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 标题由窗口工具栏统一展示，这里只保留入口数量。
                    Text("\(entries.count) 个入口")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // 按可用宽度均分列宽，默认铺满窗口。
                    let spacing: CGFloat = 22
                    let available = max(0, proxy.size.width - 48)
                    let maxFit = max(1, Int((available + spacing) / (120 + spacing)))
                    let columnCount = min(store.cardColumns, maxFit)
                    let itemWidth = max(120, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                             count: columnCount),
                              alignment: .leading,
                              spacing: 26) {
                        ForEach(entries) { entry in
                            card(entry, width: itemWidth)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func card(_ entry: Entry, width: CGFloat) -> some View {
        let key = entry.id
        let cover = store.moreItemsCover(for: entry.item)
        return VStack(alignment: .leading, spacing: 8) {
            // 与媒体类型 / 场景一致：优先展示该入口的第一张照片缩略图，没有照片时退回图标。
            AlbumCoverImage(photo: cover, side: width, style: .icon(entry.icon))
                .frame(width: width, height: max(120, width * 0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(hoveredKey == key ? 0.18 : 0), radius: 14, y: 6)
                .scaleEffect(hoveredKey == key && settings.hoverLift ? settings.motion.hoverScale : 1)
                .animation(settings.motion.hover, value: hoveredKey)

            HStack(spacing: 5) {
                Image(systemName: entry.icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? key : (hoveredKey == key ? nil : hoveredKey)
        }
        .onTapGesture {
            store.navigate(to: entry.item)
        }
        .help(entry.title)
        .accessibilityLabel(entry.title)
    }
}

/// 系统图库「导入项目」：按官方导入会话（Photos.sqlite 的 `ZGENERICALBUM.ZKIND = 1506`）展示。
/// 与媒体类型 / 场景总览共用同一套卡片墙，标题留给窗口工具栏，内容区不再重复大标题。
struct ImportSessionsOverviewView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        let sessions = store.systemImportSessions
        CategoryOverviewView(
            entries: sessions.map { session in
                CategoryOverviewEntry(id: "\(session.id)",
                                      title: DateText.fullFormatter.string(from: session.createdAt),
                                      icon: "square.and.arrow.down.on.square",
                                      count: session.count,
                                      cover: store.systemImportSessionCover(session.id),
                                      item: .systemImportSession(session.id))
            },
            emptyIcon: "square.and.arrow.down.on.square",
            emptyTitle: "还没有导入记录",
            emptyMessage: "从相机或存储卡导入照片后，每次导入会显示为一个批次。"
        )
    }
}

/// 图库分区：资源 / 照片 / 收藏三个分页，都是「多个图库」的聚合视图，不预选任何图库。
struct LibraryHubView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var aggregate: LibraryAggregateModel
    @AppStorage(LibraryHubTab.storageKey) private var tabRaw = LibraryHubTab.resources.rawValue

    private var tab: LibraryHubTab { LibraryHubTab(rawValue: tabRaw) ?? .resources }

    var body: some View {
        Group {
            switch tab {
            case .resources:
                LibraryResourcesView()
            case .photos:
                LibraryAggregatePhotosView(mode: .photos)
            case .favorites:
                LibraryAggregatePhotosView(mode: .favorites)
            }
        }
        // 当前容器、已连接图库或打开过的图库变化时重新统计；
        // 之前没带 force，聚合模型的 didLoad 会让页面一直停在旧数据上。
        .task(id: refreshKey) {
            await aggregate.load(store: store, force: true)
        }
    }

    private var refreshKey: String {
        let container = LibraryPaths.containerLibraryURL?.path ?? ""
        let system = store.systemLibraries.map(\.path).joined(separator: "|")
        let known = store.knownLibraries.map(\.path).joined(separator: "|")
        return "\(container)#\(system)#\(known)"
    }
}

/// 图库资源：所有图库的合计读数 + 每个图库自己的体量卡片；不选中任何图库。
/// 图库的切换、备份与清理也收在这里（设置里不再单独留「图库」分页）。
struct LibraryResourcesView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var aggregate: LibraryAggregateModel
    @State private var hoveredPath: String?
    @State private var cacheSize: Int64 = 0
    @State private var systemCacheSize: Int64 = 0
    @State private var sidecarSize: Int64 = 0
    /// 网络影院相关的可清理缓存：海报图片、列表快照 + TMDB 补全、刮削结果。
    @State private var cinemaArtworkSize: Int64 = 0
    @State private var cinemaSnapshotSize: Int64 = 0
    @State private var scrapedCinemaSize: Int64 = 0
    @State private var confirmClearScraped = false
    @State private var confirmDestroySidecar = false

    private var totalPhotos: Int { aggregate.summaries.reduce(0) { $0 + $1.photos } }
    private var totalVideos: Int { aggregate.summaries.reduce(0) { $0 + $1.videos } }
    private var totalAlbums: Int { aggregate.summaries.reduce(0) { $0 + $1.albums } }
    private var totalFolders: Int { aggregate.summaries.reduce(0) { $0 + $1.folders } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                actionDeck
                statStrip
                librariesSection
                maintenanceSection
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 56)
            // 整页铺满：资源页是读数与维护清单，不再收进 1120 的居中栏。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 标题与合计不在这里画：图库总览的页名与合计统一由顶栏标题区承担。
        .task { await refreshSizes() }
        .confirmationDialog("销毁拾光在该系统图库写入的数据？",
                            isPresented: $confirmDestroySidecar,
                            titleVisibility: .visible) {
            Button("销毁拾光数据", role: .destructive) {
                store.destroySystemLibrarySidecar()
                Task { await refreshSizes() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除拾光自己的元数据库、索引 / 快照、缩略图、转码与缓存；Apple 的 Photos.sqlite、originals 原图与衍生图不会被动到。该操作不可撤销。")
        }
        .confirmationDialog("清空全部影院的刮削结果？",
                            isPresented: $confirmClearScraped,
                            titleVisibility: .visible) {
            Button("清空刮削结果", role: .destructive) {
                store.clearAllCinemaScrapedData()
                Task {
                    // 删除排在图库数据库的串行队列里，稍等一下再统计。
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await refreshSizes()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会释放条目、详情补全与推荐占用的空间；续播进度、手动忽略与自定义片单保留。下次进入影院会重新刮削，可能需要一些时间。")
        }
    }

    // MARK: - 快捷操作

    /// 「重新统计」并入「快捷操作」标题行右侧：跟随页面下移，不再单独占一条页头。
    private var refreshStatsButton: some View {
        Button {
            Task { await aggregate.load(store: store, force: true) }
        } label: {
            HStack(spacing: 5) {
                if aggregate.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(aggregate.loading ? "统计中" : "重新统计")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(aggregate.loading)
        .help("重新读取每个图库的体量")
    }

    /// 快捷操作平铺：切换 / 新建 / 打开 / 连接照片图库 / 在访达显示全部摆在页面上，
    /// 不再收进「…」菜单；每个动作都带一句人话说明。
    private var actionDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                sectionHeader(symbol: "bolt.fill",
                              title: "快捷操作",
                              caption: "常用操作都在这里，不用翻菜单")
                refreshStatsButton
            }

            LazyVGrid(columns: deckColumns, alignment: .leading, spacing: 10) {
                LibraryActionTile(icon: "arrow.triangle.2.circlepath",
                                  title: "切换图库",
                                  detail: "在记录过的图库之间切换",
                                  tint: Color.accentColor) {
                    store.presentLibraryPicker()
                }
                LibraryActionTile(icon: "plus.rectangle.on.folder",
                                  title: "新建图库",
                                  detail: "从零建一个 .photoslibrary",
                                  tint: LumaBrand.mint) {
                    store.beginNewLibraryFlow()
                }
                LibraryActionTile(icon: "folder",
                                  title: "打开图库",
                                  detail: "打开磁盘上已有的图库",
                                  tint: LumaBrand.amber) {
                    store.presentLibraryContainerPanel()
                }
                LibraryActionTile(icon: "photo.stack",
                                  title: "连接「照片」图库",
                                  detail: "只读接入系统照片图库",
                                  tint: LumaBrand.violet) {
                    store.presentSystemLibraryPanel()
                }
                LibraryActionTile(icon: "arrow.up.forward.app",
                                  title: "在访达中显示",
                                  detail: "定位当前图库文件",
                                  tint: LumaBrand.cyan,
                                  enabled: store.containerLibraryPath != nil) {
                    store.revealLibraryInFinder()
                }
            }
        }
    }

    // MARK: - 统计读数

    private var statStrip: some View {
        LazyVGrid(columns: deckColumns, alignment: .leading, spacing: 10) {
            CloudHubStatPod(title: "图库", value: "\(aggregate.summaries.count)", unit: "个",
                            detail: "App 图库与外接图库",
                            symbol: "photo.stack", tint: LumaBrand.coral)
            CloudHubStatPod(title: "照片", value: totalPhotos.formatted(), unit: "张",
                            detail: "所有图库合计",
                            symbol: "photo.fill", tint: Color.accentColor)
            CloudHubStatPod(title: "视频", value: totalVideos.formatted(), unit: "个",
                            detail: "所有图库合计",
                            symbol: "video.fill", tint: LumaBrand.violet)
            CloudHubStatPod(title: "相簿", value: totalAlbums.formatted(), unit: "个",
                            detail: "用户相簿与智能相簿",
                            symbol: "rectangle.stack.fill", tint: LumaBrand.amber)
            CloudHubStatPod(title: "文件夹", value: totalFolders.formatted(), unit: "个",
                            detail: "目录层级合计",
                            symbol: "folder.fill", tint: LumaBrand.mint)
        }
    }

    // MARK: - 全部图库

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(symbol: "photo.stack",
                          title: "全部图库",
                          count: "\(aggregate.summaries.count)",
                          caption: "点击切换 · 右键更多操作")

            VStack(spacing: 0) {
                if aggregate.summaries.isEmpty && aggregate.loading {
                    libraryPlaceholder
                } else {
                    ForEach(Array(aggregate.summaries.enumerated()), id: \.element.id) { index, summary in
                        libraryRow(summary)
                        if index < aggregate.summaries.count - 1 {
                            libraryDivider
                        }
                    }
                    if !aggregate.summaries.isEmpty {
                        libraryDivider
                    }
                    connectRow
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
        }
    }

    private var libraryDivider: some View {
        Divider().opacity(0.45).padding(.leading, 60)
    }

    private var libraryPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在读取图库体量…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    /// 每个图库一行：图标 / 名称与路径 / 四项体量 / 索引时间或错误 / 进入箭头。
    /// 行式排版在 1–5 个图库时都能对齐，不会出现半行空洞或参差不齐的卡片高度。
    private func libraryRow(_ summary: LibraryAggregateModel.LibrarySummary) -> some View {
        let current = aggregate.isCurrent(summary, store: store)
        let hovered = hoveredPath == summary.id
        let isDefault = store.isDefaultLibrary(summary.path)
        let isExplicitDefault = store.isExplicitDefaultLibrary(summary.path)
        let isConnectedSystemLibrary = store.systemLibraries.contains {
            store.isSameSystemLibraryPath($0.path, summary.path)
        }
        // 图库目录不在了（被移动 / 删除，或外置盘未连接）：整行降级并给出明确出口，
        // 不能让它看起来还能点进去，那是「点完侧边栏全空」的来源。
        let exists = FileManager.default.fileExists(atPath: summary.path)
        return HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(current ? Color.accentColor
                                         : (exists ? Color.secondary : LumaBrand.coral.opacity(0.8)))
                .frame(width: 34, height: 34)
                .background((current ? Color.accentColor
                                     : (exists ? Color.secondary : LumaBrand.coral)).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(exists ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if current {
                        badge("当前", tint: Color.accentColor)
                    }
                    if isDefault {
                        badge("默认", tint: LumaBrand.amber)
                            .help(isExplicitDefault
                                  ? "默认图库：启动时自动打开这个图库"
                                  : "上次打开的图库：下次启动会继续打开它")
                    }
                    if !exists {
                        badge("失效", tint: LumaBrand.coral)
                            .help("图库不存在：可能已被移动、删除，或外置盘未连接")
                    }
                }
                Text(summary.path)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            // 体量读数收纳成一枚「仪表舱」：四个格子竖向分隔，
            // 数字用紧凑写法（10.1 万），再大的图库也不会被挤成两行。
            HStack(spacing: 0) {
                libraryStat("照片", summary.photos, symbol: "photo.fill", tint: Color.accentColor)
                statDivider
                libraryStat("视频", summary.videos, symbol: "video.fill", tint: LumaBrand.violet)
                statDivider
                libraryStat("相簿", summary.albums, symbol: "rectangle.stack.fill", tint: LumaBrand.amber)
                statDivider
                libraryStat("文件夹", summary.folders, symbol: "folder.fill", tint: LumaBrand.mint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
            }
            .fixedSize()

            Group {
                if !exists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(LumaBrand.coral)
                        .help("图库不存在：可能已被移动、删除，或外置盘未连接")
                } else if let error = summary.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(LumaBrand.coral)
                        .help(error)
                } else if let updated = summary.updatedAt {
                    Text(CloudHubFormat.relative(updated))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                        .help("索引于 \(CloudHubFormat.relative(updated))")
                }
            }
            .frame(width: 76, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.quaternary)
                .opacity(hovered ? 1 : 0.45)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(hovered ? Color.primary.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredPath = inside ? summary.id : (hoveredPath == summary.id ? nil : hoveredPath)
        }
        .onTapGesture { open(summary) }
        .contextMenu {
            Button("打开图库") { open(summary) }
                .disabled(!exists)
            if exists, !isExplicitDefault {
                Button("设为默认图库") { store.setDefaultLibrary(summary.path) }
            }
            if summary.isNative, exists {
                Button("在「照片」中打开图库") {
                    store.openSystemLibraryInPhotos(summary.path)
                }
            }
            if exists {
                Button("在访达中显示图库") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.path)])
                }
            }
            if !summary.isAppContainer, isConnectedSystemLibrary {
                Divider()
                Button("断开连接", role: .destructive) {
                    store.confirmRemoveSystemLibrary(path: summary.path, name: summary.name)
                }
            } else {
                // 所有 App 图库（含当前图库与默认图库）都可以断开：
                // 只删记录 / 退出容器，不删磁盘上的图库文件。
                Divider()
                Button(current ? "退出图库…" : "断开连接…", role: .destructive) {
                    store.confirmDisconnectLibrary(path: summary.path, name: summary.name)
                }
                .help(current
                      ? "退出当前图库并回到「创建或打开图库」；图库文件保留在磁盘上"
                      : "从「全部图库」移除记录；图库文件保留在磁盘上")
            }
        }
        .help(summary.path)
    }

    private var connectRow: some View {
        Button {
            store.presentSystemLibraryPanel()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 34, height: 34)
                Text("连接其他图库…")
                    .font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
            .fixedSize()
    }

    /// 仪表舱里的竖向分隔：比 Divider 更矮、更淡，只做格子分界。
    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 0.6, height: 22)
            .padding(.horizontal, 11)
    }

    /// 行内体量读数：图标 + 数字（紧凑写法）+ 名称，固定不换行，多个图库之间逐列对齐。
    private func libraryStat(_ title: String, _ value: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(Self.compactCount(value))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 54, alignment: .trailing)
        .help("\(title) \(value.formatted())")
    }

    /// 行内读数的紧凑写法：过万折成「10.1 万」，过亿折成「1.2 亿」。
    /// 列表行宽有限，101,066 这种六位数直接排会折成两行。
    private static func compactCount(_ value: Int) -> String {
        func trimmed(_ number: Double) -> String {
            let text = String(format: "%.1f", number)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        let number = Double(value)
        if value >= 100_000_000 { return trimmed(number / 100_000_000) + "亿" }
        if value >= 10_000 { return trimmed(number / 10_000) + "万" }
        return value.formatted()
    }

    // MARK: - 小节标题

    /// 快捷操作与读数共用一套列宽：两行网格左右边缘严格对齐。
    private var deckColumns: [GridItem] {
        // 最小 230 而不是 196：常规窗口下正好排成 5 列铺满整行，
        // 不会出现「5 张卡只占左边一小半、右边空一格」的观感。
        [GridItem(.adaptive(minimum: 230, maximum: .infinity), spacing: 10, alignment: .top)]
    }

    /// 统一的小节标题：图标方块 + 标题 + 数量胶囊 + 右侧说明，保证各段起点对齐。
    private func sectionHeader(symbol: String,
                               title: String,
                               count: String? = nil,
                               caption: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            if let count {
                Text(count)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            }
            Spacer(minLength: 8)
            if let caption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func open(_ summary: LibraryAggregateModel.LibrarySummary) {
        // 失效的图库只提示、不改状态：以前会一路走到切库，最后留在空壳页面上。
        guard FileManager.default.fileExists(atPath: summary.path) else {
            store.showToast("找不到「\(summary.name)」，可能已被移动、删除，或外置盘未连接")
            return
        }
        if summary.isAppContainer {
            if summary.isNative, let url = LibraryPaths.containerLibraryURL {
                store.connectSystemLibrary(url)
            } else {
                store.navigate(to: .library)
            }
            return
        }
        if let ref = store.systemLibraries.first(where: {
            store.isSameSystemLibraryPath($0.path, summary.path)
        }) {
            store.activateSystemLibrary(ref)
            return
        }
        // 打开过的其他图库（自己新建的图库 / 没登记成连接的官方库）：直接切换 App 图库。
        store.activateLibrary(URL(fileURLWithPath: summary.path))
    }

    // MARK: - 图库维护

    /// 图库维护：原来在「设置 › 图库」里的清理与备份，统一搬到资源页。
    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(symbol: "wrench.and.screwdriver.fill",
                          title: "图库维护",
                          caption: "清理缓存、做备份、恢复数据；原图与图库文件不会被删除")

            maintenanceGroup(icon: "internaldrive",
                             title: "存储与清理",
                             subtitle: "只清理这台 Mac 上的缓存与派生文件，网盘和云端原图不受影响。") {
                VStack(spacing: 0) {
                    maintenanceRow(icon: "trash",
                                   title: "最近删除",
                                   subtitle: settings.trashRetentionDays > 0
                                       ? "删除的照片超过 \(settings.trashRetentionDays) 天后，在启动时自动永久删除"
                                       : "不自动删除，需要手动清空最近删除") {
                        Picker("", selection: $settings.trashRetentionDays) {
                            Text("7 天后").tag(7)
                            Text("30 天后").tag(30)
                            Text("90 天后").tag(90)
                            Text("180 天后").tag(180)
                            Text("永不清理").tag(0)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 118)
                    }

                    maintenanceDivider

                    maintenanceRow(icon: "photo.stack",
                                   title: "系统「照片」缩略图",
                                   subtitle: "\(systemCacheSize > 0 ? formatFileSize(systemCacheSize) : "暂无缓存") · 清理后会自动重建") {
                        Button("清理") {
                            store.clearSystemThumbnailCache()
                            Task { await refreshSizes() }
                        }
                        .controlSize(.small)
                        .disabled(systemCacheSize == 0)
                    }

                    maintenanceDivider

                    maintenanceRow(icon: "externaldrive.badge.icloud",
                                   title: "网盘缩略图",
                                   subtitle: "\(cacheSize > 0 ? formatFileSize(cacheSize) : "暂无缓存") · 清理后会自动重建") {
                        Button("清理") {
                            store.clearCloudThumbnailCache()
                            Task { await refreshSizes() }
                        }
                        .controlSize(.small)
                        .disabled(cacheSize == 0)
                    }

                    maintenanceDivider

                    maintenanceRow(icon: "film",
                                   title: "影院海报与背景图",
                                   subtitle: "\(cinemaArtworkSize > 0 ? formatFileSize(cinemaArtworkSize) : "暂无缓存") · 网络影院 / 网盘影院的刮削图，清理后按需重新下载") {
                        Button("清理") {
                            CinemaArtworkCache.clearDiskCache()
                            Task {
                                // 删除在后台队列执行，稍等一下再统计，避免读到旧体积。
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                await refreshSizes()
                            }
                        }
                        .controlSize(.small)
                        .disabled(cinemaArtworkSize == 0)
                    }

                    maintenanceDivider

                    maintenanceRow(icon: "list.bullet.rectangle",
                                   title: "影院列表快照与 TMDB 补全",
                                   subtitle: "\(cinemaSnapshotSize > 0 ? formatFileSize(cinemaSnapshotSize) : "暂无缓存") · 电影 / 剧集 / 最近更新三页列表与资料匹配，清理后重新聚合") {
                        Button("清理") {
                            store.networkCinemaModel.clearCaches()
                            Task { await refreshSizes() }
                        }
                        .controlSize(.small)
                        .disabled(cinemaSnapshotSize == 0)
                    }

                    maintenanceDivider

                    maintenanceRow(icon: "film.stack",
                                   title: "影院刮削结果",
                                   subtitle: "\(scrapedCinemaSize > 0 ? formatFileSize(scrapedCinemaSize) : "暂无刮削数据") · 条目、详情补全与推荐；清理后下次进入影院重新刮削",
                                   tint: .orange) {
                        Button("清理…", role: .destructive) {
                            confirmClearScraped = true
                        }
                        .controlSize(.small)
                        .disabled(scrapedCinemaSize == 0)
                    }

                    if store.isNativeContainer {
                        maintenanceDivider
                        maintenanceRow(icon: "shippingbox",
                                       title: "系统图库旁挂数据",
                                       subtitle: "\(sidecarSize > 0 ? formatFileSize(sidecarSize) : "暂无可清理数据") · 拾光写入的索引、缩略图与缓存，不会动 Apple 的原图",
                                       tint: .orange) {
                            HStack(spacing: 8) {
                                Button("刷新") { Task { await refreshSizes() } }
                                    .controlSize(.small)
                                Button("销毁…", role: .destructive) {
                                    confirmDestroySidecar = true
                                }
                                .controlSize(.small)
                                .disabled(sidecarSize == 0)
                            }
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }

            maintenanceGroup(icon: "lock.shield",
                             title: "图库保险库",
                             subtitle: "把图库原图与数据库备份到外置盘或 NAS；恢复时只补缺失或损坏的文件。") {
                VaultSettingsView()
            }
        }
    }

    private func maintenanceGroup<Content: View>(icon: String,
                                                 title: String,
                                                 subtitle: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 29)
            content()
        }
    }

    private func maintenanceRow<Trailing: View>(icon: String,
                                                title: String,
                                                subtitle: String,
                                                tint: Color = .secondary,
                                                @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var maintenanceDivider: some View {
        Divider().padding(.leading, 56)
    }

    /// 体积读数要在后台遍历目录：以前在 `.task` 里同步扫缩略图缓存，
    /// 点进「图库 → 资源」时主线程会被堵上几百毫秒，表现为「卡一下」。
    /// `@MainActor`：`await` 之后仍回到主线程写 `@State`，避免跨线程改 SwiftUI 状态。
    @MainActor
    private func refreshSizes() async {
        let container = store.isNativeContainer ? LibraryPaths.containerLibraryURL : nil
        let sizes = await Task.detached(priority: .utility) {
            (LibraryStore.directorySize(at: LibraryPaths.cloudThumbs),
             LibraryStore.directorySize(at: LibraryPaths.systemThumbs),
             LibraryStore.sidecarSize(in: container),
             CinemaArtworkCache.diskCacheSize())
        }.value
        cacheSize = sizes.0
        systemCacheSize = sizes.1
        sidecarSize = sizes.2
        cinemaArtworkSize = sizes.3
        // 两个数据库读数是单行 SUM，几毫秒级，直接在主线程取即可。
        cinemaSnapshotSize = NetworkCinemaModel.cacheBytes()
        scrapedCinemaSize = store.scrapedCinemaBytes()
    }
}

/// 图库资源页的快捷操作卡：做成真正「可按」的按钮——渐变底面、高光描边、
/// 悬停抬起 + 品牌色光晕、按下回弹，而不是一块静态卡片。
private struct LibraryActionTile: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.10)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 0.7)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .shadow(color: tint.opacity(0.35), radius: 3, y: 0.5)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2.5) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hovering ? tint : Color.secondary.opacity(0.45))
                    .offset(x: hovering ? 1.5 : 0)
                    .opacity(hovering ? 1 : 0.55)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(LibraryActionTileStyle(tint: tint, hovering: hovering && enabled))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .help(detail)
    }
}

/// 快捷操作卡的按钮质感：底面渐变、顶部高光、悬停品牌色描边与光晕、按下缩小。
private struct LibraryActionTileStyle: ButtonStyle {
    let tint: Color
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(baseFill(pressed: pressed))
                    .overlay {
                        // 顶部一层极淡高光，让卡片有「凸起」的实体感。
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(hovering ? 0.12 : 0.06), .clear],
                                                 startPoint: .top,
                                                 endPoint: .center))
                            .allowsHitTesting(false)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.46) : Color.primary.opacity(0.10),
                                  lineWidth: hovering ? 1 : 0.7)
            }
            .shadow(color: hovering ? tint.opacity(0.22) : Color.black.opacity(0.05),
                    radius: hovering ? 12 : 3,
                    y: hovering ? 4 : 1)
            .scaleEffect(pressed ? 0.976 : 1)
            .brightness(pressed ? -0.015 : 0)
            .animation(.easeOut(duration: 0.14), value: pressed)
            .animation(.easeOut(duration: 0.16), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func baseFill(pressed: Bool) -> LinearGradient {
        let top: Color
        let bottom: Color
        if hovering {
            top = tint.opacity(pressed ? 0.20 : 0.15)
            bottom = tint.opacity(pressed ? 0.09 : 0.06)
        } else {
            top = Color.primary.opacity(pressed ? 0.09 : 0.055)
            bottom = Color.primary.opacity(pressed ? 0.05 : 0.028)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}
