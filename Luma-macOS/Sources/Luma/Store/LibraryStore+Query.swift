import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Queries

    var sidebarTitle: String {
        if let similarScope { return "与「\(similarScope.title)」相似" }
        switch sidebarItem {
        case .library: return "图库"
        case .cinema: return "影院"
        case .collections: return "精选集"
        case .favorites: return "个人收藏"
        case .recentlySaved: return "最近保存"
        case .duplicates: return "重复项目"
        case .map: return "地图"
        case .places: return "位置"
        case .people: return "人物"
        case .videos: return "视频"
        case .screenshots: return "截屏"
        case .hidden: return "已隐藏"
        case .allAlbums: return "所有相簿"
        case .mediaTypes: return "媒体类型"
        case .scenes: return "场景"
        case .moreItems: return "更多项目"
        case .keywords:
            return selectedKeyword.map { "关键词：#\($0)" } ?? "关键词"
        case .album(let id): return albums.first(where: { $0.id == id })?.name ?? "相簿"
        case .smartAlbum(let id): return smartAlbums.first(where: { $0.id == id })?.name ?? "智能相簿"
        case .folder(let id): return folders.first(where: { $0.id == id })?.name ?? "文件夹"
        case .selfies: return "自拍"
        case .panoramas: return "全景照片"
        case .livePhotos: return "实况照片"
        case .animated: return "动图"
        case .raws: return "RAW"
        case .recentlyEdited: return "最近编辑"
        case .imports: return "导入项目"
        case .ocrTexts: return "包含文字"
        case .scene(let id): return SceneCatalog.category(id: id)?.title ?? "场景"
        case .health: return "图库体检"
        case .ratings, .flags, .colorLabels: return "图库整理"
        case .blurry: return "可能模糊"
        case .similarDuplicates: return "相似备选"
        case .largeVideos: return "过大视频"
        case .revisit: return "值得重看"
        case .trash: return "最近删除"
        case .systemLibrary: return systemLibraryName ?? "系统照片图库"
        case .systemCollections: return "精选集"
        case .systemAlbums: return "相簿"
        case .systemMediaTypes: return "媒体类型"
        case .systemMoreItems: return "更多项目"
        case .systemKeywords:
            return selectedKeyword.map { "关键词：#\($0)" } ?? "关键词"
        case .systemLibraries: return "图库"
        case .cloudStorages: return "网络存储"
        case .catalogSources: return "网络资源"
        case .networkCinema: return "网络影院"
        case .systemAlbum(let id): return systemAlbums.first(where: { $0.id == id })?.name ?? "系统相簿"
        case .systemFolder(let id): return systemFolders.first(where: { $0.id == id })?.name ?? "系统文件夹"
        case .systemFavorites: return "个人收藏"
        case .systemVideos: return "视频"
        case .systemScreenshots: return "截屏"
        case .systemHidden: return "已隐藏"
        case .systemTrash: return "最近删除"
        case .systemPortraits: return "人像"
        case .systemSelfies: return "自拍"
        case .systemLivePhotos: return "实况照片"
        case .systemPanoramas: return "全景照片"
        case .systemLongExposure: return "长曝光"
        case .systemTimelapse: return "延时摄影"
        case .systemCinematic: return "电影效果"
        case .systemSpatial: return "空间"
        case .systemBursts: return "连拍快照"
        case .systemSlowMotion: return "慢动作"
        case .systemScreenRecordings: return "录屏"
        case .systemAnimated: return "动图"
        case .systemRAW: return "RAW"
        case .systemEdited: return "最近编辑"
        case .systemRecentlyViewed: return "最近查看"
        case .systemDuplicates: return "重复项目"
        case .systemRecentlySaved: return "最近保存"
        case .systemImports: return "导入项目"
        case .systemImportSession: return "导入项目"
        case .systemRevisit: return "值得重看"
        case .systemHealth: return "图库体检"
        case .systemRatings, .systemFlags, .systemColorLabels: return "图库整理"
        case .systemScenes: return "场景"
        case .systemScene(let id): return SceneCatalog.category(id: id)?.title ?? "场景"
        case .systemOcrTexts: return "包含文字"
        case .systemMap: return "地图"
        case .systemPlaces: return "位置"
        case .systemPeople: return "人物"
        case .cloudMount(let id):
            if let section = cloudModel.overview { return section.title }
            if let path = cloudModel.selectedFolderPath,
               let folder = cloudModel.scanFolders.first(where: { $0.path == path }) {
                return folder.name
            }
            // 与拾光 / 系统图库一致：选中媒体类型或「更多项目」入口后，标题就是该范围。
            if cloudModel.scope != .all { return cloudModel.scope.title }
            return cloudMounts.first(where: { $0.id == id })?.name ?? "网络存储"
        case .cloudCinema(let id):
            return cloudMounts.first(where: { $0.id == id }).map { "\($0.name) · 影院" } ?? "影院"
        case .catalogSource(let id):
            // 分类信息由顶栏舱体承担，窗口标题只保留资源名，避免两处重复。
            return catalogModel.sources.first(where: { $0.id == id })?.name ?? "网络资源"
        case .iptv: return "网络电视"
        }
    }

    var isSystemScope: Bool {
        sidebarItem.isSystemScope
    }

    /// 系统图库是否走「索引直连」：没有本地索引，年 / 月总览按快照 + 范围样本渲染。
    var isDirectSystemIndex: Bool {
        systemIndex?.direct != nil
    }

    /// 当前范围的上一级（用于工具栏「返回」与相簿链路）：没有上一级时返回 nil。
    var navigationParent: (item: SidebarItem, title: String)? {
        switch sidebarItem {
        case .album(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return nil }
            if let folderID = album.folderID,
               let folder = folders.first(where: { $0.id == folderID }) {
                return (.folder(folderID), folder.name)
            }
            return (.allAlbums, "所有相簿")
        case .folder(let id):
            guard let folder = folders.first(where: { $0.id == id }) else { return nil }
            if let parentID = folder.parentID,
               let parent = folders.first(where: { $0.id == parentID }) {
                return (.folder(parentID), parent.name)
            }
            return (.allAlbums, "所有相簿")
        case .smartAlbum:
            return (.allAlbums, "所有相簿")
        case .systemAlbum(let id):
            guard let album = systemAlbum(id: id) else { return nil }
            if let parentID = album.parentFolder,
               let parent = systemFolders.first(where: { $0.id == parentID }) {
                return (.systemFolder(parentID), parent.name)
            }
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        case .systemFolder(let id):
            guard let folder = systemFolders.first(where: { $0.id == id }) else { return nil }
            if let parentID = folder.parent,
               let parent = systemFolders.first(where: { $0.id == parentID }) {
                return (.systemFolder(parentID), parent.name)
            }
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        case .allAlbums, .mediaTypes, .scenes, .moreItems:
            return (.library, "图库")
        case .systemAlbums, .systemMediaTypes, .systemMoreItems, .systemScenes:
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        case .systemHealth:
            return (.systemLibrary, systemLibraryName ?? "所有项目")
        case .systemScene:
            return (.systemScenes, "场景")
        case .systemImportSession:
            return (.systemImports, "导入项目")
        case .keywords:
            return selectedKeyword != nil ? (.keywords, "关键词") : (.moreItems, "更多项目")
        case .systemKeywords:
            return selectedKeyword != nil ? (.systemKeywords, "关键词") : (.systemMoreItems, "更多项目")
        case .cloudMount(let id):
            // 网盘与拾光 / 系统图库一致：分类、相簿与总览都能返回上一层。
            guard cloudModel.overview != nil
                    || cloudModel.selectedFolderPath != nil
                    || cloudModel.scope != .all else { return nil }
            return (.cloudMount(id), cloudMounts.first(where: { $0.id == id })?.name ?? "网络存储")
        default:
            return nil
        }
    }

    /// 回到当前相簿 / 文件夹 / 网盘目录的上一级。
    func navigateUp() {
        if case .cloudMount = sidebarItem {
            if cloudModel.overview != nil {
                showCloudOverview(nil)
            } else if cloudModel.selectedFolderPath != nil {
                cloudGoUp()
            } else if cloudModel.scope != .all {
                setCloudScope(cloudModel.scope.keywordOverviewParent ?? .all)
            }
            return
        }
        guard let parent = navigationParent else { return }
        navigate(to: parent.item)
    }

    /// 「返回上一级」是否可用：网盘目录链与分类总览也算一层。
    var canNavigateUp: Bool {
        if case .cloudMount = sidebarItem {
            return cloudModel.overview != nil
                || cloudModel.selectedFolderPath != nil
                || cloudModel.scope != .all
        }
        return navigationParent != nil
    }

    // MARK: - 相簿层级面包屑

    /// 当前相簿 / 文件夹的完整层级（从「所有相簿」到当前项），顶部工具栏据此显示面包屑。
    var albumBreadcrumbs: [AlbumBreadcrumb] {
        switch sidebarItem {
        case .allAlbums:
            return [AlbumBreadcrumb(id: "local.root", title: "所有相簿", item: .allAlbums)]
        case .folder(let id):
            return [AlbumBreadcrumb(id: "local.root", title: "所有相簿", item: .allAlbums)]
                + localFolderChain(upTo: id)
        case .album(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return [] }
            return [AlbumBreadcrumb(id: "local.root", title: "所有相簿", item: .allAlbums)]
                + localFolderChain(upTo: album.folderID)
                + [AlbumBreadcrumb(id: "local.album.\(id)", title: album.name, item: .album(id))]
        case .smartAlbum(let id):
            guard let album = smartAlbums.first(where: { $0.id == id }) else { return [] }
            return [AlbumBreadcrumb(id: "local.root", title: "所有相簿", item: .allAlbums),
                    AlbumBreadcrumb(id: "local.smart.\(id)", title: album.name, item: .smartAlbum(id))]
        case .systemAlbums:
            return [AlbumBreadcrumb(id: "sys.root", title: "所有相簿", item: .systemAlbums)]
        case .systemFolder(let id):
            return [AlbumBreadcrumb(id: "sys.root", title: "所有相簿", item: .systemAlbums)]
                + systemFolderChain(upTo: id)
        case .systemAlbum(let id):
            guard let album = systemAlbum(id: id) else { return [] }
            return [AlbumBreadcrumb(id: "sys.root", title: "所有相簿", item: .systemAlbums)]
                + systemFolderChain(upTo: album.parentFolder)
                + [AlbumBreadcrumb(id: "sys.album.\(id)", title: album.name, item: .systemAlbum(id))]
        default:
            return []
        }
    }

    /// 从一个文件夹向上收集祖先（含自身），带循环保护。
    private func localFolderChain(upTo folderID: UUID?) -> [AlbumBreadcrumb] {
        var crumbs: [AlbumBreadcrumb] = []
        guard folderID != nil else { return crumbs }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var current = folderID
        var hops = 0
        while let id = current, hops < 64, let folder = byID[id] {
            crumbs.insert(AlbumBreadcrumb(id: "local.folder.\(id)", title: folder.name, item: .folder(id)),
                          at: 0)
            current = folder.parentID
            hops += 1
        }
        return crumbs
    }

    private func systemFolderChain(upTo folderID: Int64?) -> [AlbumBreadcrumb] {
        var crumbs: [AlbumBreadcrumb] = []
        guard folderID != nil else { return crumbs }
        let byID = Dictionary(uniqueKeysWithValues: systemFolders.map { ($0.id, $0) })
        var current = folderID
        var hops = 0
        while let id = current, hops < 64, let folder = byID[id] {
            crumbs.insert(AlbumBreadcrumb(id: "sys.folder.\(id)", title: folder.name, item: .systemFolder(id)),
                          at: 0)
            current = folder.parent
            hops += 1
        }
        return crumbs
    }

    /// 当前图库就是官方「照片」图库：拾光作为它的增强层，主界面直接展示这个库自己的照片，
    /// 拾光自己的元数据（设置、相簿、分析）写在同一个库的 `database/Luma.sqlite` 里。
    var isNativeContainer: Bool {
        guard let url = LibraryPaths.containerLibraryURL else { return false }
        return LibraryPaths.isNativeLibrary(url)
    }

    /// 原生系统图库的缩略图优先交给系统「照片」（已有缩略图 + 可预取 + 支持 iCloud 资源）。
    /// 其它图库（外接 .photoslibrary、拾光本地库）继续走本地 derivative 解码。
    var usesPhotoKitThumbnails: Bool {
        isSystemScope && isNativeContainer && PhotoKitThumbnailProvider.shared.isAvailable
    }

    var isCloudScope: Bool {
        if case .cloudMount = sidebarItem { return true }
        return false
    }

    /// 当前是否是照片网格页面（用于菜单项的可用状态）。
    var isGridScopeForCommands: Bool {
        // 网盘与拾光 / 系统图库一致：普通照片列表才是网格，总览与专用页面不是。
        if isCloudScope {
            return cloudModel.overview == nil && !cloudModel.scope.usesDedicatedView
        }
        switch sidebarItem {
        case .keywords, .systemKeywords:
            // 关键词总览是卡片墙；进入某个关键词后是照片列表。
            return selectedKeyword != nil
        case .collections, .map, .places, .systemMap, .systemPlaces, .systemPeople,
             .allAlbums, .folder, .systemFolder, .people, .cloudMount, .duplicates,
             .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes, .systemScenes,
             .systemCollections, .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages,
             .catalogSources,
             .systemDuplicates, .systemImports, .systemHealth, .health,
             .videos, .systemVideos:
            return false
        default:
            return true
        }
    }

    var isReadOnlyScope: Bool { isSystemScope || isCloudScope }

    /// 当前是否是相簿总览页面（「所有相簿」与文件夹层级）。
    var isAlbumOverviewScope: Bool {
        switch sidebarItem {
        case .allAlbums, .folder, .systemFolder, .systemAlbums: return true
        default: return false
        }
    }

    /// 只有「图库」这一层需要年/月时间轴总览，相簿与文件夹保持普通网格。
    /// 网盘与拾光 / 系统图库一致：只有整个网盘（全部项目）是「图库」页，
    /// 媒体类型、更多项目与目录相簿都是相簿级普通网格。
    var isTimelineScope: Bool {
        if sidebarItem == .library || sidebarItem == .systemLibrary { return true }
        if isCloudScope {
            return cloudModel.overview == nil
                && cloudModel.selectedFolderPath == nil
                && cloudModel.scope == .all
        }
        return false
    }

    /// 「个人收藏」使用独立的浏览方式（全部 / 年 / 类型）。
    var isFavoritesScope: Bool {
        sidebarItem == .favorites || sidebarItem == .systemFavorites
    }

    /// 「图库」页与官方「照片」一致：新照片在底部，进入时先看最新，
    /// 向上滚动翻看更早的照片。系统图库、拾光图库与网盘的「全部项目」适用；
    /// 筛选 / 搜索 / 其它排序时仍按普通降序展示。
    var timelineShowsNewestAtBottom: Bool {
        guard grouping == .all, sortKey == .capturedAt, !sortAscending,
              photoFilter == .all, keywordFilter == nil, !hasMetadataFilters,
              selectedPlace == nil, selectedPerson == nil, similarScope == nil,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isSystemScope { return isTimelineScope && isSystemPagedScope }
        if isCloudScope { return isTimelineScope }
        return sidebarItem == .library
    }

    var isCurrentCloudWritable: Bool {
        guard case .cloudMount(let id) = sidebarItem,
              let mount = cloudMounts.first(where: { $0.id == id }) else { return false }
        return mount.kind.supportsWrite
    }

    /// 当前挂载是否为 SMB：系统已把它挂成 /Volumes 下的本地文件系统，可复用系统应用与访达。
    var isCurrentCloudSMB: Bool {
        guard case .cloudMount(let id) = sidebarItem,
              let mount = cloudMounts.first(where: { $0.id == id }) else { return false }
        return mount.kind == .smb
    }

    /// 媒体类型总览：数量与封面一次遍历算完（本地 / 系统图库共用）。
    var mediaTypeSummary: MediaTypeSummary {
        // 系统图库索引模式：直接读索引聚合，不遍历整库。
        if isSystemScope, let index = systemIndex {
            let key = "sys-\(systemIndexSignature)-\(photoKitLongExposureIDs?.count ?? -1)-\(photoKitCinematicIDs?.count ?? -1)"
            if mediaTypeSummaryCacheKey == key { return mediaTypeSummaryCacheValue }
            var summary = index.mediaTypeSummary(overrides: buildSystemQuery(scope: .all))
            // 长曝光 / 电影效果由 PhotoKit 智能相簿提供 ID，这里按索引汇总数量与封面。
            for (type, scope) in [(MediaTypeKey.longExposure, SystemQueryScope.longExposures),
                                  (MediaTypeKey.cinematic, SystemQueryScope.cinematics)] {
                let ids = type == .longExposure ? photoKitLongExposureIDs : photoKitCinematicIDs
                guard let ids, !ids.isEmpty else { continue }
                var query = buildSystemQuery(scope: scope)
                query.filter = .all
                query.tokens = []
                query.overlayKeywordIDs = nil
                let count = index.summary(query).total
                guard count > 0 else { continue }
                summary.counts[type] = count
                summary.covers[type] = index.page(query, offset: 0, limit: 1).first
            }
            summary.covers = summary.covers.mapValues { applySystemOverlay($0) }
            mediaTypeSummaryCacheKey = key
            mediaTypeSummaryCacheValue = summary
            return summary
        }
        let key = "\(contentRevision)-\(isSystemScope)"
        if mediaTypeSummaryCacheKey == key { return mediaTypeSummaryCacheValue }
        var summary = MediaTypeSummary()
        let source = isSystemScope ? systemPhotos : photos
        for photo in source {
            guard photo.deletedAt == nil, !photo.isHidden else { continue }
            for type in MediaTypeKey.allCases where type.matches(photo) {
                summary.counts[type, default: 0] += 1
                if summary.covers[type] == nil {
                    summary.covers[type] = photo
                }
            }
        }
        // 小图库走内存快照时，长曝光 / 电影效果仍需按 PhotoKit 智能相簿的 ID 汇总。
        if isSystemScope {
            for (type, ids) in [(MediaTypeKey.longExposure, photoKitLongExposureIDs),
                                (MediaTypeKey.cinematic, photoKitCinematicIDs)] {
                guard let ids, !ids.isEmpty else { continue }
                let matched = source.filter { $0.deletedAt == nil && !$0.isHidden && ids.contains($0.id) }
                guard let cover = matched.first else { continue }
                summary.counts[type] = matched.count
                summary.covers[type] = cover
            }
        }
        mediaTypeSummaryCacheKey = key
        mediaTypeSummaryCacheValue = summary
        return summary
    }

    /// 当前图库身份卡的数据：系统图库索引模式下内存里的 `photos` 只有当前窗口，
    /// 不能再用它数总数，否则设置页会显示 0。
    struct LibraryStats {
        var photos = 0
        var videos = 0
        var albums = 0
        var folders = 0
        var systemLibraries = 0
    }

    var libraryStats: LibraryStats {
        var stats = LibraryStats()
        if isNativeContainer, let index = systemIndex {
            let totals = index.activeMediaTotals()
            stats.photos = totals.photos
            stats.videos = totals.videos
            stats.albums = systemAlbums.count
            stats.folders = systemFolders.count
        } else if isNativeContainer {
            // 索引还没就绪：先用已扫描到的系统图库项目兜底。
            let visible = systemPhotos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }
            stats.photos = visible.filter { !$0.isVideo }.count
            stats.videos = visible.filter { $0.isVideo }.count
            stats.albums = systemAlbums.count
            stats.folders = systemFolders.count
        } else {
            let visible = photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }
            stats.photos = visible.filter { !$0.isVideo }.count
            stats.videos = visible.filter { $0.isVideo }.count
            stats.albums = albums.count
            stats.folders = folders.count
        }
        // 当前图库本身就是系统「照片」图库时，系统图库数量也要把它算进去。
        stats.systemLibraries = systemLibraries.count + (isNativeContainer ? 1 : 0)
        return stats
    }

    /// 身份卡封面：系统图库索引模式按索引取第一张，内存里没有整库照片对象。
    var libraryCoverPhoto: PhotoItem? {
        if isNativeContainer, let index = systemIndex {
            return index.page(buildSystemQuery(scope: .all), offset: 0, limit: 1)
                .first
                .map { applySystemOverlay($0) }
        }
        let visible = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        return visible.first(where: { !$0.isVideo }) ?? visible.first
    }

    func photos(for item: SidebarItem) -> [PhotoItem] {
        // 地点详情：聚类自带的照片就是屏幕上这一组，直接作为可见列表，
        // 查看器翻页、序号与底部胶片条才会和地点页显示的一致。
        if let place = selectedPlace {
            return place.photos.filter { $0.deletedAt == nil && !$0.isHidden }
        }
        // 系统图库索引模式：内存只有已加载窗口，整库范围/排序由 SystemIndex 完成。
        if isSystemPagedScope {
            if let similarScope {
                return systemWindowPhotos.filter { similarScope.ids.contains($0.id) }
            }
            return systemWindowPhotos
        }
        let live = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        switch item {
        case .library, .collections, .allAlbums, .people, .imports:
            return live
        case .ocrTexts:
            return live.filter { !(analysisIndex[$0.id]?.text.isEmpty ?? true) }
        case .scene(let id):
            return photosMatchingScene(id)
        case .health:
            return live
        case .blurry:
            return blurryPhotos
        case .similarDuplicates:
            return similarDuplicatePhotos
        case .largeVideos:
            return largeVideoPhotos
        case .revisit:
            return revisitPhotos
        case .systemLibrary:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
        case .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes, .systemScenes,
             .systemCollections, .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages,
             .catalogSources, .networkCinema,
             .systemHealth, .cinema, .cloudCinema, .catalogSource, .iptv:
            // 总览页只展示分类卡片，不返回照片。
            return []
        case .systemFavorites:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isFavorite }
        case .systemVideos:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isVideo }
        case .systemScreenshots:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.kind == .screenshot }
        case .systemHidden:
            return systemPhotos.filter { $0.deletedAt == nil && $0.isHidden }
        case .systemTrash:
            return systemPhotos.filter { $0.deletedAt != nil }
        case .systemPortraits:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isPortraitCapture }
        case .systemSelfies:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && !$0.isVideo && $0.kind == .selfie
            }
        case .systemLivePhotos:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isLivePhoto }
        case .systemPanoramas:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.kind == .panorama }
        case .systemSlowMotion:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isSlowMotion }
        case .systemTimelapse:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isTimelapse }
        case .systemBursts:
            // 按组展示代表照片：键照片 + 单成员组自身，与官方「照片」及索引 / 直连口径一致。
            let burstMembers = systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isBurstItem }
            let groupCounts = Dictionary(grouping: burstMembers, by: { $0.burstGroupID ?? "" })
                .mapValues(\.count)
            return burstMembers.filter { $0.isBurstKeyPhoto || (groupCounts[$0.burstGroupID ?? ""] ?? 0) == 1 }
        case .systemLongExposure:
            let ids = photoKitLongExposureIDs ?? []
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && ids.contains($0.id) }
        case .systemCinematic:
            let ids = photoKitCinematicIDs ?? []
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && ids.contains($0.id) }
        case .systemSpatial:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isSpatial }
        case .systemScreenRecordings:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isScreenRecording }
        case .systemAnimated:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && ($0.isAnimated || $0.isAnimatedFile)
            }
        case .systemRAW:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isRAWFile }
        case .systemEdited:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && !$0.isVideo && ($0.editedAt != nil || $0.hasEdits)
            }
        case .systemRecentlyViewed:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden
                    && ($0.viewedAt ?? .distantPast) >= Self.recentlyViewedCutoff
            }
        case .systemDuplicates:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isDuplicateItem }
        case .systemRecentlySaved:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && $0.addedAt >= Self.recentlySavedCutoff
            }
        case .systemImports, .systemImportSession:
            // 「导入项目」是会话列表；单次会话由系统索引分页查询。
            return []
        case .systemRevisit:
            let now = Date()
            let captureCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge)
            let viewCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitViewAge)
            return systemPhotos.filter { photo in
                guard photo.deletedAt == nil, !photo.isHidden else { return false }
                guard photo.capturedAt < captureCutoff else { return false }
                guard let viewedAt = photo.viewedAt else { return true }
                return viewedAt < viewCutoff
            }
        case .systemScene(let id):
            guard let category = SceneCatalog.category(id: id) else { return [] }
            // 只遍历已识别的照片，避免为了场景范围扫描整个系统图库。
            return systemAnalysisIndex.compactMap { photoID, analysis in
                guard let photo = systemPhoto(id: photoID),
                      photo.deletedAt == nil, !photo.isHidden else { return nil }
                return SceneCatalog.matches(category, analysis: analysis, photo: photo) ? photo : nil
            }
        case .systemOcrTexts:
            return systemAnalysisIndex.compactMap { photoID, analysis in
                guard !analysis.text.isEmpty,
                      let photo = systemPhoto(id: photoID),
                      photo.deletedAt == nil, !photo.isHidden else { return nil }
                return photo
            }
        case .systemMap:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && $0.hasLocation
            }
        case .systemPlaces:
            return systemPhotos.filter {
                $0.deletedAt == nil && !$0.isHidden && $0.hasLocation
            }
        case .systemPeople:
            return systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
        case .cloudMount:
            return cloudVisiblePhotos
        case .systemAlbum(let id):
            guard let album = systemAlbums.first(where: { $0.id == id }) else { return [] }
            let ids = Set(album.assetIDs)
            return systemPhotos.filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
        case .systemFolder(let id):
            let folderIDs = systemFolderSubtreeIDs(id)
            let albumIDs = Set(systemAlbums.filter {
                $0.parentFolder.map { folderIDs.contains($0) } ?? false
            }.map { $0.id })
            let assetIDs = Set(systemAlbums.filter { albumIDs.contains($0.id) }.flatMap { $0.assetIDs })
            return systemPhotos.filter {
                assetIDs.contains($0.id) && $0.deletedAt == nil && !$0.isHidden
            }
        case .favorites:
            return live.filter { $0.isFavorite }
        case .recentlySaved:
            let limit = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            return live.filter { $0.addedAt >= limit }
        case .duplicates:
            return duplicateGroups.flatMap(\.photos)
        case .keywords, .systemKeywords:
            // 总览是卡片墙；进入某个关键词后返回该词下的照片列表。
            return selectedKeyword.map { keywordPhotos($0) } ?? []
        case .map:
            return live.filter { $0.hasLocation }
        case .places:
            return live.filter { $0.hasLocation }
        case .videos:
            return live.filter { $0.isVideo }
        case .screenshots:
            return live.filter { $0.kind == .screenshot }
        case .selfies:
            return live.filter { $0.kind == .selfie }
        case .panoramas:
            return live.filter { $0.kind == .panorama }
        case .livePhotos:
            return live.filter { $0.isLivePhoto }
        case .animated:
            return live.filter { $0.isAnimatedFile || $0.isAnimated }
        case .raws:
            return live.filter { $0.isRAWFile }
        case .recentlyEdited:
            return live.filter { $0.hasEdits || $0.editedAt != nil }
        case .hidden:
            return photos.filter { $0.deletedAt == nil && $0.isHidden }
        case .album(let id):
            guard let album = albums.first(where: { $0.id == id }) else { return [] }
            // 相簿内按用户拖拽顺序展示，而不是全局拍摄时间顺序。
            let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            return album.photoIDs.compactMap { byID[$0] }
        case .smartAlbum(let id):
            guard let album = smartAlbums.first(where: { $0.id == id }) else { return [] }
            return live.filter { album.matches($0, analysis: self.analysisIndex[$0.id]) }
        case .folder(let id):
            let folderIDs = folderSubtreeIDs(id)
            let photoIDs = Set(albums.filter {
                $0.folderID.map { folderIDs.contains($0) } ?? false
            }.flatMap { $0.photoIDs })
            return live.filter { photoIDs.contains($0.id) }
        case .trash:
            return photos.filter { $0.deletedAt != nil }
        case .ratings, .flags, .colorLabels,
             .systemRatings, .systemFlags, .systemColorLabels:
            // 整理工作室自带分布与筛选网格，不走普通照片范围。
            return []
        }
    }

    var basePhotos: [PhotoItem] {
        photos(for: sidebarItem)
    }

    // MARK: - 总览卡片封面

    /// 「更多项目」卡片封面：每个入口取该范围的第一张照片。
    /// 系统图库索引库直接查 SQL，本地库按入口语义先命中先返回；结果按内容版本缓存。
    func moreItemsCover(for item: SidebarItem) -> PhotoItem? {
        let token = "\(contentRevision)|\(systemIndexSignature)|\(isSystemScope)"
        if moreItemsCoverToken != token {
            moreItemsCoverToken = token
            moreItemsCoverCache.removeAll()
            moreItemsCoverMissing.removeAll()
        }
        if let cover = moreItemsCoverCache[item] { return cover }
        if moreItemsCoverMissing.contains(item) { return nil }
        let cover = resolveMoreItemsCover(item)
        if let cover {
            moreItemsCoverCache[item] = cover
        } else {
            moreItemsCoverMissing.insert(item)
        }
        return cover
    }

    private func resolveMoreItemsCover(_ item: SidebarItem) -> PhotoItem? {
        if isSystemScope {
            // 人物 / 体检 / 导入项目没有可查询的单张照片范围，保留图标卡片。
            if item == .systemPeople || item == .systemHealth || item == .systemImports {
                return nil
            }
            if item == .systemKeywords {
                guard let first = keywordOptions.first else { return nil }
                return keywordCover(for: first.name)
            }
            if let scope = item.systemQueryScope, let index = systemIndex {
                return index.page(cachedSystemQuery(scope), offset: 0, limit: 1).first
            }
            return photos(for: item).first
        }
        func first(_ predicate: (PhotoItem) -> Bool) -> PhotoItem? {
            for photo in photos where predicate(photo) { return photo }
            return nil
        }
        switch item {
        case .favorites:
            return first { $0.deletedAt == nil && !$0.isHidden && $0.isFavorite }
        case .trash:
            return first { $0.deletedAt != nil }
        case .recentlySaved:
            return first {
                $0.deletedAt == nil && !$0.isHidden && $0.addedAt >= Self.recentlySavedCutoff
            }
        case .recentlyEdited:
            return first { $0.deletedAt == nil && !$0.isHidden && ($0.hasEdits || $0.editedAt != nil) }
        case .imports:
            return first { $0.deletedAt == nil && !$0.isHidden && $0.importBatchID != nil }
        case .ocrTexts:
            return first {
                $0.deletedAt == nil && !$0.isHidden && !(analysisIndex[$0.id]?.text.isEmpty ?? true)
            }
        case .revisit:
            return revisitPhotos.first
        case .health:
            return blurryPhotos.first
        case .map, .places:
            return first { $0.deletedAt == nil && !$0.isHidden && $0.hasLocation }
        case .hidden:
            return first { $0.deletedAt == nil && $0.isHidden }
        case .duplicates:
            return duplicateGroups.first?.photos.first
        case .keywords:
            guard let first = keywordOptions.first else { return nil }
            return keywordCover(for: first.name)
        default:
            return nil
        }
    }

    func matchesFilter(_ photo: PhotoItem, albumPhotoIDs: Set<UUID>) -> Bool {
        switch photoFilter {
        case .all: return true
        case .favorites: return photo.isFavorite
        case .edited: return photo.hasEdits
        case .photos: return !photo.isVideo
        case .videos: return photo.isVideo
        case .screenshots:
            // 网盘没有可读的相机元数据，截屏只能按文件名判断。
            if photo.isCloud { return CloudMediaNaming.looksLikeScreenshot(photo.originalName) }
            return photo.kind == .screenshot
        case .mine: return photo.make != nil || photo.model != nil
        case .notInAlbum: return !albumPhotoIDs.contains(photo.id)
        }
    }

    /// 解析后的搜索条件：支持场景词、时间词（去年 / 5月 / 2024年）、类型限定与人物名。
    var currentSearchQuery: SearchQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchQuery() }
        var query = SearchQueryParser.parse(trimmed)
        guard !query.tokens.isEmpty, !localPeople.isEmpty else { return query }
        // 标签词里出现人物名时，改为按「这个人出现在照片里」筛选。
        var matchedPeople: Set<UUID> = []
        query.tokens.removeAll { token in
            guard let person = localPeople.first(where: {
                $0.name.lowercased() == token && !$0.assetIDs.isEmpty
            }) else { return false }
            matchedPeople.insert(person.id)
            return true
        }
        query.personIDs = matchedPeople
        return query
    }

    func matchesSearch(_ photo: PhotoItem, query: SearchQuery,
                       peopleByID: [UUID: LocalPerson] = [:]) -> Bool {
        guard !query.isEmpty else { return true }

        if let start = query.startDate, photo.capturedAt < start { return false }
        if let end = query.endDate, photo.capturedAt >= end { return false }
        if query.onlyFavorites, !photo.isFavorite { return false }
        if query.onlyVideos, !photo.isVideo { return false }
        if query.onlyPhotos, photo.isVideo { return false }
        if query.onlyScreenshots {
            let isScreenshot = photo.isCloud
                ? CloudMediaNaming.looksLikeScreenshot(photo.originalName)
                : photo.kind == .screenshot
            if !isScreenshot { return false }
        }
        if query.onlyLivePhotos, !photo.isLivePhoto { return false }
        if query.onlyEdited, !photo.hasEdits { return false }

        if !query.personIDs.isEmpty {
            for personID in query.personIDs {
                guard let person = peopleByID[personID],
                      person.assetIDs.contains(photo.id) else { return false }
            }
        }

        guard !query.tokens.isEmpty else { return true }

        var parts = [
            photo.originalName,
            photo.displayTitle,
            photo.displayFilename,
            (photo.displayFilename as NSString).pathExtension,
            photo.make ?? "",
            photo.model ?? "",
            photo.lens ?? "",
            photo.iso ?? "",
            photo.placeCountry ?? "",
            photo.placeProvince ?? "",
            photo.placeCity ?? "",
            photo.placeDistrict ?? "",
            photo.placePOI ?? "",
            (photo.keywords ?? []).joined(separator: " "),
            Self.kindTitle(photo.kind),
            DateText.fullFormatter.string(from: photo.capturedAt),
            DateText.dayFormatter.string(from: photo.capturedAt),
            DateText.yearFormatter.string(from: photo.capturedAt),
            formatFileSize(photo.fileSize)
        ]
        // 端侧分析结果：场景标签 + OCR 文字。网盘与系统图库的识别结果只在内存里。
        let analysis = analysisIndex[photo.id]
            ?? (photo.isCloud ? cloudModel.analysis[photo.id] : nil)
            ?? (photo.isSystem ? systemAnalysisIndex[photo.id] : nil)
        if let analysis, !analysis.searchBlob.isEmpty {
            parts.append(analysis.searchBlob)
        }
        let haystack = parts.joined(separator: " ").lowercased()
        // 单个自然语言查询（如「海边日落」「吃火锅」）用本地模型扩展出的标准标签兜底。
        let semanticHit = query.tokens.count == 1 && !semanticSearchTags.isEmpty
            && semanticSearchTags.contains { haystack.contains($0.lowercased()) }
        if semanticHit { return true }
        return query.tokens.allSatisfy { token in
            if haystack.contains(token) { return true }
            // 中文口语查询扩展成标准标签 / 旧版 Vision 英文标签。
            return SceneCatalog.searchLabels(for: token).contains { haystack.contains($0.lowercased()) }
        }
    }

    /// 网络存储网格：套用范围、筛选、搜索与排序；目录结果规模有限，直接在内存处理并缓存。
    var cloudVisiblePhotos: [PhotoItem] {
        let key = [
            String(cloudModel.revision),
            String(describing: cloudModel.scope),
            String(cloudModel.analysis.count),
            String(cloudModel.metadataRevision),
            String(cloudModel.people.count),
            String(cloudModel.viewedAt.count),
            similarScope?.sourceID.uuidString ?? "",
            String(similarScope?.ids.count ?? 0),
            searchText,
            searchScope.rawValue,
            photoFilter.rawValue,
            String(ratingFilter),
            flagFilter?.rawValue ?? "",
            colorLabelFilter?.rawValue ?? "",
            sortKey.rawValue,
            String(sortAscending)
        ].joined(separator: "\u{1F}")
        if cloudVisibleCacheKey == key { return cloudVisibleCacheValue }
        var items = cloudPhotos.filter { !$0.isHidden }
        switch cloudModel.scope {
        case .all:
            break
        case .people:
            // 一次构建人物照片集合，避免逐张照片重复展开人物列表。
            let ids = Set(cloudPeople.flatMap { $0.assetIDs })
            items = items.filter { ids.contains($0.id) }
        case .duplicates:
            let ids = cloudDuplicatePhotoIDs
            items = items.filter { ids.contains($0.id) }
        case .recentlyViewed:
            items = items.filter { cloudPhoto($0, matches: .recentlyViewed) }
        case let scope:
            items = items.filter { cloudPhoto($0, matches: scope) }
        }
        if let similarScope {
            items = items.filter { similarScope.ids.contains($0.id) }
        }
        if photoFilter != .all {
            items = items.filter { matchesFilter($0, albumPhotoIDs: []) }
        }
        if hasMetadataFilters {
            items = items.filter { matchesMetadataFilters($0) }
        }
        let query = currentSearchQuery
        if !query.isEmpty {
            let peopleByID = Dictionary(uniqueKeysWithValues: localPeople.map { ($0.id, $0) })
            items = items.filter { matchesSearch($0, query: query, peopleByID: peopleByID) }
        }
        let sorted: [PhotoItem]
        // 扫描结束后全盘清单已按拍摄时间倒序：没有额外筛选时直接复用，省掉每次都排两万项。
        let alreadySorted = sortKey == .capturedAt
            && !sortAscending
            && photoFilter == .all
            && !hasMetadataFilters
            && similarScope == nil
            && query.isEmpty
            && cloudModel.scope == .all
            && !cloudModel.scanPhase.isScanning
        if alreadySorted {
            sorted = items
        } else if case .recentlyViewed = cloudModel.scope {
            // 与系统图库一致：按本机查看时间倒序，不再套用网格排序。
            let viewed = cloudModel.viewedAt
            sorted = items.sorted {
                (viewed[$0.id] ?? .distantPast) > (viewed[$1.id] ?? .distantPast)
            }
        } else if case .recentlySaved = cloudModel.scope {
            // 最近保存：按网盘文件的修改时间倒序，与系统图库的「最近保存」一致。
            sorted = items.sorted { $0.addedAt > $1.addedAt }
        } else {
            sorted = sortedByCurrentKey(items)
        }
        cloudVisibleCacheKey = key
        cloudVisibleCacheValue = sorted
        return sorted
    }

    /// 影响 `visiblePhotos` 的状态指纹；筛选、排序、搜索等变化都会换 key。
    var visibleStateKey: String {
        var parts: [String] = []
        parts.append(String(contentRevision))
        parts.append(String(windowRevision))
        parts.append(String(describing: sidebarItem))
        parts.append(selectedKeyword ?? "")
        parts.append(searchText)
        parts.append(semanticSearchTags.joined(separator: "|"))
        parts.append(searchScope.rawValue)
        parts.append(String(analysisIndex.count))
        parts.append(photoFilter.rawValue)
        parts.append(keywordFilter ?? "")
        parts.append(String(ratingFilter))
        parts.append(flagFilter?.rawValue ?? "")
        parts.append(colorLabelFilter?.rawValue ?? "")
        parts.append(selectedPlace?.id ?? "")
        parts.append(selectedPerson.map { String($0.id) } ?? "")
        parts.append(sortKey.rawValue)
        parts.append(String(sortAscending))
        parts.append(String(cloudModel.revision))
        parts.append(String(describing: cloudModel.scope))
        parts.append(String(cloudModel.analysis.count))
        parts.append(String(cloudModel.metadataRevision))
        parts.append(String(cloudModel.people.count))
        parts.append(String(isLoadingSystemLibrary))
        // 端侧分析会改变搜索/场景/OCR 的命中结果，必须参与缓存失效（避免分析过程中反复重算全库）。
        parts.append(String((searchText.isEmpty && !isAnalysisScope) ? 0 : analysisIndex.count))
        // 系统图库的识别结果只在内存里，同样影响场景 / 包含文字范围。
        parts.append(String(isSystemScope ? systemAnalysisIndex.count : 0))
        parts.append(similarScope?.sourceID.uuidString ?? "")
        parts.append(String(similarScope?.ids.count ?? 0))
        parts.append(systemIndexSignature)
        parts.append(String(systemWindowRevision))
        parts.append(String(hasLoadedSystemWindow))
        parts.append(selectedFavoriteBucket?.id ?? "")
        parts.append(favoritesDigestLoadedToken)
        return parts.joined(separator: "\u{1F}")
    }

    var visiblePhotos: [PhotoItem] {
        // 系统图库：索引分页窗口。
        if isSystemPagedScope {
            if let similarScope {
                return systemWindowPhotos.filter { similarScope.ids.contains($0.id) }
            }
            return systemWindowPhotos
        }
        // 大图库：筛选/排序在 SQLite 完成，这里只返回已加载的窗口。
        if isPagedScope { return windowPhotos }
        // 大图库（数十万项）筛选 + 排序开销很大，这里按关键状态缓存结果。
        let key = visibleStateKey
        if visibleCacheKey == key { return visibleCacheValue }
        let value = computeVisiblePhotos()
        visibleCacheKey = key
        visibleCacheValue = value
        return value
    }

    /// 网格滚动时按 id 查拍摄时间（顶栏日期范围）；随可见集合缓存，避免逐帧遍历全库。
    var photoDateLookup: [UUID: Date] {
        let key = visibleStateKey
        if dateLookupCacheKey == key { return dateLookupCache }
        let items = visiblePhotos
        var map: [UUID: Date] = [:]
        map.reserveCapacity(items.count)
        for item in items { map[item.id] = item.capturedAt }
        dateLookupCacheKey = key
        dateLookupCache = map
        return map
    }

    func computeVisiblePhotos() -> [PhotoItem] {
        // 网络存储的筛选、搜索与排序已经在 `cloudVisiblePhotos` 中完成。
        if isCloudScope { return basePhotos }
        // 收藏汇总下钻：数据源是汇总时载入的完整收藏列表，不再依赖分页窗口。
        var items: [PhotoItem]
        if isFavoritesScope, let bucket = selectedFavoriteBucket {
            items = favoritesDigestSource.filter { bucket.matches($0) }
        } else if !isSystemScope, searchScope != .currentView, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 全局 / 模块内搜索：从全库出发，不受当前视图范围限制；窗口内才只过滤当前已加载内容。
            items = photos
        } else {
            items = basePhotos
        }
        if photoFilter != .all {
            let albumPhotoIDs: Set<UUID>
            if isSystemScope {
                albumPhotoIDs = Set(systemAlbums.flatMap { $0.assetIDs })
            } else {
                albumPhotoIDs = Set(albums.flatMap { $0.photoIDs })
            }
            items = items.filter { matchesFilter($0, albumPhotoIDs: albumPhotoIDs) }
        }
        if hasMetadataFilters {
            items = items.filter { matchesMetadataFilters($0) }
        }
        if let selectedPlace {
            items = items.filter {
                PlaceClusterBuilder.key(for: $0, granularity: placeGranularity).id == selectedPlace.id
            }
        }
        if let selectedPerson {
            let ids = Set(selectedPerson.assetIDs)
            items = items.filter { ids.contains($0.id) }
        }
        if let keywordFilter, !keywordFilter.isEmpty {
            items = items.filter { $0.tags.contains(keywordFilter) }
        }
        if let similarScope {
            items = items.filter { similarScope.ids.contains($0.id) }
        }
        let query = currentSearchQuery
        if !query.isEmpty {
            let peopleByID = Dictionary(uniqueKeysWithValues: localPeople.map { ($0.id, $0) })
            items = items.filter { matchesSearch($0, query: query, peopleByID: peopleByID) }
        }
        switch sidebarItem {
        case .recentlySaved, .systemRecentlySaved, .systemImports:
            return items.sorted { $0.addedAt > $1.addedAt }
        case .trash, .systemTrash:
            return items.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .systemAlbum(let id):
            // 官方相簿在 Photos.sqlite 的关联表里保存了自己的显示顺序（拍摄日期 / 添加日期 / 手动拖拽）。
            // 默认沿用该顺序（与系统「照片」一致）；用户在排序菜单里换成其它字段时按用户选择排序。
            guard sortKey == .capturedAt, let album = systemAlbum(id: id) else {
                return sortedByCurrentKey(items)
            }
            let positions = Dictionary(uniqueKeysWithValues:
                album.assetIDs.enumerated().map { ($0.element, $0.offset) })
            return items.sorted {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }
        case .places, .systemPlaces:
            // 地点详情沿用聚类自带的顺序，与地点页照片墙保持一致；
            // 概览页没有照片，仍按全局排序。
            return selectedPlace == nil ? sortedByCurrentKey(items) : items
        default:
            // 扫描过程中先按数据库顺序展示，结束后再统一排序，避免反复排序超大数组。
            if isLoadingSystemLibrary, isSystemScope {
                return items
            }
            // 相簿使用用户拖拽排序，不再按全局排序字段重排。
            if case .album = sidebarItem {
                return items
            }
            return sortedByCurrentKey(items)
        }
    }

    /// 切换排序字段：同时按该字段的默认方向调整升/降序。
    func applySort(_ key: SortKey) {
        // 用户在系统相簿里显式选了排序方式：退出拖拽产生的手动顺序。
        if case .systemAlbum(let id) = sidebarItem, isSystemAlbumManualOrder(id) {
            clearSystemAlbumManualOrder(id)
        }
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = key.prefersAscending
        }
    }

    func sortedByCurrentKey(_ items: [PhotoItem]) -> [PhotoItem] {
        let ascending = sortAscending
        func compareStrings(_ lhs: String, _ rhs: String) -> Bool {
            let result = lhs.localizedStandardCompare(rhs)
            guard result != .orderedSame else { return false }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        switch sortKey {
        case .capturedAt:
            return items.sorted { ascending ? $0.capturedAt < $1.capturedAt : $0.capturedAt > $1.capturedAt }
        case .addedAt:
            return items.sorted { ascending ? $0.addedAt < $1.addedAt : $0.addedAt > $1.addedAt }
        case .title:
            return items.sorted { compareStrings($0.displayTitle, $1.displayTitle) }
        case .filename:
            return items.sorted { compareStrings($0.displayFilename, $1.displayFilename) }
        case .fileSize:
            return items.sorted { ascending ? $0.fileSize < $1.fileSize : $0.fileSize > $1.fileSize }
        case .kind:
            return items.sorted { compareStrings(Self.kindTitle($0.kind), Self.kindTitle($1.kind)) }
        case .camera:
            return items.sorted { compareStrings($0.model ?? $0.make ?? "", $1.model ?? $1.make ?? "") }
        case .place:
            return items.sorted {
                compareStrings(PlaceClusterBuilder.key(for: $0, granularity: placeGranularity).title,
                               PlaceClusterBuilder.key(for: $1, granularity: placeGranularity).title)
            }
        case .duration:
            return items.sorted { ascending ? ($0.duration ?? 0) < ($1.duration ?? 0)
                                           : ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }

    static func kindTitle(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "照片"
        case .video: return "视频"
        case .screenshot: return "截屏"
        case .panorama: return "全景"
        case .selfie: return "自拍"
        }
    }

    var sections: [PhotoSection] {
        // 分段需要遍历全部可见项，按指纹缓存，避免翻页/选中时反复分组。
        let key = visibleStateKey + "\u{1E}" + grouping.rawValue
            + "\u{1E}" + stackMode.rawValue + "#\(stackRevision)"
        if sectionsCacheKey == key { return sectionsCacheValue }
        let value = computeSections()
        sectionsCacheKey = key
        sectionsCacheValue = value
        return value
    }

    func computeSections() -> [PhotoSection] {
        // 堆叠形态只在分段这一步收起：查看器 / 选区 / 计数仍然拿完整列表。
        // 年 / 月总览是按真实数量的卡片页，不做堆叠（堆叠只在照片网格里生效）。
        let stackable = !(isTimelineScope && grouping != .all)
        let items = (stackable && isStackingEnabled) ? stackedPhotos(visiblePhotos) : visiblePhotos
        guard !items.isEmpty else { return [] }
        // 「导入项目」按导入批次分段；系统图库没有批次号，按导入（加入库）日期分组，展示与拾光一致。
        if sidebarItem == .imports || sidebarItem == .systemImports {
            return importSections(from: items)
        }
        // 只有图库才按年/月分段；相簿、文件夹、智能项目一律单段普通网格。
        if grouping == .all || !isTimelineScope {
            return [PhotoSection(id: "all", title: nil, photos: items)]
        }
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        for item in items {
            let components = calendar.dateComponents([.year, .month, .day], from: item.capturedAt)
            let key: String
            switch grouping {
            case .years:
                key = "\(components.year ?? 0)"
            case .months:
                key = "\(components.year ?? 0)-\(components.month ?? 0)"
            case .all:
                key = "all"
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
        }
        let sectionDates = buckets.mapValues { $0.first?.capturedAt ?? .distantPast }
        let newestFirst = sortKey == .capturedAt ? !sortAscending : true
        let sortedKeys = order.sorted { lhs, rhs in
            let left = sectionDates[lhs] ?? .distantPast
            let right = sectionDates[rhs] ?? .distantPast
            return newestFirst ? left > right : left < right
        }
        return sortedKeys.map { key in
            let bucket = buckets[key] ?? []
            let title: String
            switch grouping {
            case .years:
                title = DateText.yearFormatter.string(from: bucket.first?.capturedAt ?? Date())
            case .months:
                title = DateText.monthFormatter.string(from: bucket.first?.capturedAt ?? Date())
            case .all:
                title = ""
            }
            return PhotoSection(id: key, title: title, photos: bucket)
        }
    }

    /// 「导入项目」分段：同一批导入共用一个批次 ID；旧照片按添加日期归组。
    func importSections(from items: [PhotoItem]) -> [PhotoSection] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        var dates: [String: Date] = [:]
        for item in items {
            let key: String
            if let batch = item.importBatchID {
                key = "batch-\(batch.uuidString)"
            } else {
                let parts = calendar.dateComponents([.year, .month, .day], from: item.addedAt)
                key = String(format: "day-%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
            dates[key] = min(dates[key] ?? item.addedAt, item.addedAt)
        }
        return order
            .sorted { (dates[$0] ?? .distantPast) > (dates[$1] ?? .distantPast) }
            .map { key in
                let stamp = dates[key] ?? Date()
                return PhotoSection(id: key,
                                    title: "导入于 " + Self.importTitleFormatter.string(from: stamp),
                                    photos: buckets[key] ?? [])
            }
    }

    static let importTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    // MARK: - 时间轴总览

    /// 年总览点击某年：切到月总览，并定位到该年的第一个月。
    func openMonths(of year: Int) {
        grouping = .months
        // 大图库：月份数据来自 SQL 分区，优先用已加载的月份分段定位。
        if usesSQLOverview {
            if let group = monthGroups.first(where: { $0.id.hasPrefix("\(year)-") }) {
                scrollTargetSection = group.id
            } else {
                pendingMonthScrollYear = year
                reloadOverviewIfNeeded()
            }
            return
        }
        let calendar = Calendar.current
        guard let first = visiblePhotos.first(where: {
            calendar.component(.year, from: $0.capturedAt) == year
        }) else { return }
        let parts = calendar.dateComponents([.year, .month], from: first.capturedAt)
        scrollTargetSection = "\(parts.year ?? year)-\(parts.month ?? 1)"
    }

    /// 月总览点击某天：回到所有照片并定位到那天的第一张。
    func openAllPhotos(at photoID: UUID) {
        grouping = .all
        scrollTargetID = photoID
        // 大图库需要先把窗口移到目标照片附近，再交给网格滚动。
        if isPagedScope { reloadVisibleWindowIfNeeded() }
    }

    func photo(id: UUID) -> PhotoItem? {
        photos.first(where: { $0.id == id })
    }

    var viewerPhoto: PhotoItem? {
        guard let viewerID else { return nil }
        // 影院打开的视频可能不在当前网盘目录里，直接使用快照。
        if let cinemaPlaybackPhoto, cinemaPlaybackPhoto.id == viewerID {
            return cinemaPlaybackPhoto
        }
        // 网络资源的虚拟分集同样不在图库里，按播放上下文直接取。
        if let catalogPhoto = catalogPlaybackPhoto(for: viewerID) {
            return catalogPhoto
        }
        // 网络电视的虚拟频道同样按播放上下文直接取。
        if let tvPhoto = tvPlaybackPhoto(for: viewerID) {
            return tvPhoto
        }
        // 查看器 body 会多次读取当前照片，缓存一次避免重复线性查找。
        if let cache = viewerPhotoCache, cache.id == viewerID, cache.revision == contentRevision {
            return cache.photo
        }
        let value = anyPhoto(id: viewerID)
        // 网盘照片列表变动不经过 contentRevision，不做缓存。
        if value?.isCloud != true {
            viewerPhotoCache = ViewerPhotoCache(id: viewerID, revision: contentRevision, photo: value)
        }
        return value
    }

    /// 自动生成的回忆（本地图库）。
    var memories: [PhotoMemory] {
        if memoryCacheKey == contentRevision { return memoryCacheValue }
        let value = MemoryBuilder.build(from: photos)
        memoryCacheKey = contentRevision
        memoryCacheValue = value
        return value
    }

    /// 按时间与地点自动识别的旅行。
    var trips: [TripStory] {
        if tripCacheKey == contentRevision { return tripCacheValue }
        let value = TripBuilder.build(from: photos)
        tripCacheKey = contentRevision
        tripCacheValue = value
        return value
    }

    /// 把一次旅行直接转成电影风格的回忆影片。
    func playTripMemory(_ trip: TripStory) {
        activeTrip = nil
        let photos = trip.photos.filter { !$0.isVideo }
        guard !photos.isEmpty else {
            showToast("这次旅行没有可播放的照片")
            return
        }
        activeMemory = PhotoMemory(id: "memory-" + trip.id,
                                   title: trip.title,
                                   subtitle: trip.subtitle,
                                   kind: .place,
                                   photos: photos,
                                   style: .cinematic)
    }

    var totalLibraryCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.count
    }

    var videoCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden && $0.isVideo }.count
    }

    var hiddenCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && $0.isHidden }.count
    }

    var trashCount: Int {
        photos.lazy.filter { $0.deletedAt != nil }.count
    }

    var libraryTotalBytes: Int64 {
        photos.reduce(Int64(0)) { $0 + ($1.deletedAt == nil ? $1.fileSize : 0) }
    }

    var libraryDateRange: String? {
        var minDate: Date?
        var maxDate: Date?
        for photo in photos where photo.deletedAt == nil {
            if let current = minDate {
                if photo.capturedAt < current { minDate = photo.capturedAt }
            } else {
                minDate = photo.capturedAt
            }
            if let current = maxDate {
                if photo.capturedAt > current { maxDate = photo.capturedAt }
            } else {
                maxDate = photo.capturedAt
            }
        }
        guard let minDate, let maxDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return "\(formatter.string(from: minDate)) – \(formatter.string(from: maxDate))"
    }

    var geoPhotos: [PhotoItem] {
        // 网盘照片的 GPS 来自 EXIF，读取后与本地照片共用同一套地图 / 位置视图。
        if isCloudScope { return cloudGeoPhotos }
        // 系统图库索引模式：地图取全部带位置的照片，统计与地点数不做截断。
        if isSystemScope, let index = systemIndex {
            let key = "sys-\(systemIndexSignature)"
            if systemGeoCacheKey == key { return systemGeoCache }
            let photos = index.photosWithLocation()
                .map { applySystemOverlay($0) }
                .filter { $0.hasLocation }
            systemGeoCacheKey = key
            systemGeoCache = photos
            return photos
        }
        if geoPhotosCacheKey == contentRevision {
            return geoPhotosCacheValue
        }
        let source = isSystemScope
            ? systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden }
            : photos.filter { $0.deletedAt == nil && !$0.isHidden }
        let result = source.filter { $0.hasLocation }
        geoPhotosCacheKey = contentRevision
        geoPhotosCacheValue = result
        return result
    }
}
