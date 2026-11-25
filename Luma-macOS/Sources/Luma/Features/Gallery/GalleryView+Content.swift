import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaCore

/// 图库主内容与底部计数胶囊。

extension GalleryView {
    // MARK: - Content

    @ViewBuilder
    func content(width: CGFloat) -> some View {
        if isUnifiedSearchActive {
            // 全局搜索调度所有已启用来源；模块内搜索只调度当前功能自己的来源。
            SearchResultsPage(query: store.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                              store: store,
                              catalog: catalog,
                              tv: store.tvModel,
                              scopes: store.searchScope == .module ? moduleSearchScopes : nil) {
                photoContent(width: width)
            }
            // 切换搜索范围 / 模块来源要换一组来源重搜：重建结果页，让 StateObject 按新范围初始化。
            .id(searchPageIdentity)
        } else if showsWindowSearchGrid {
            photoContent(width: width)
        } else {
            switch store.sidebarItem {
            case .cinema:
                CinemaLibraryView()
            case .videos, .systemVideos:
                VideoHubView()
            case .cloudCinema(let mountID):
                CinemaLibraryView(mountID: mountID)
            case .collections:
                CollectionsView()
            case .systemCollections:
                SystemCollectionsView()
            case .map, .systemMap:
                PhotoMapView()
            case .places, .systemPlaces:
                PlaceStatisticsView(query: $placesQuery)
            case .duplicates:
                DuplicatesView()
            case .systemDuplicates:
                DuplicatesView(system: true)
            case .health, .systemHealth:
                LibraryHealthView()
            case .ratings, .systemRatings, .flags, .systemFlags,
                 .colorLabels, .systemColorLabels:
                OrganizeStudioView()
            case .allAlbums:
                AlbumsOverviewView()
            case .folder(let id):
                AlbumsOverviewView(folderID: id)
            case .systemFolder(let id):
                SystemFolderOverviewView(folderID: id)
            case .systemAlbums:
                SystemFolderOverviewView()
            case .mediaTypes, .systemMediaTypes:
                MediaTypesOverviewView()
            case .scenes, .systemScenes:
                ScenesOverviewView()
            case .moreItems:
                MoreItemsOverviewView(system: false)
            case .systemMoreItems:
                MoreItemsOverviewView(system: true)
            case .keywords:
                KeywordGalleryView(system: false)
            case .systemKeywords:
                KeywordGalleryView(system: true)
            case .systemImports:
                ImportSessionsOverviewView()
            case .systemLibraries:
                LibraryHubView()
            case .cloudStorages:
                CloudStoragesHubView()
            case .catalogSources:
                CatalogHubView()
            case .networkCinema:
                NetworkCinemaHubView()
                    .environmentObject(store.networkCinemaModel)
            case .people, .systemPeople:
                PeopleView()
            case .revisit, .systemRevisit:
                RevisitView()
            case .catalogSource(let id):
                CatalogChannelView(sourceID: id)
            case .iptv:
                TVHubView()
            case .cloudMount:
                if isCloudGridScope {
                    // 与拾光 / 系统图库同一套网格：分组、排序、筛选、缩放、列表形式与计数胶囊都复用。
                    photoContent(width: width)
                        .task(id: cloudGridPrefetchKey) {
                            guard let task = store.prefetchCloudThumbnails(for: store.visiblePhotos) else { return }
                            await withTaskCancellationHandler {
                                await task.value
                            } onCancel: {
                                task.cancel()
                            }
                        }
                } else if let section = store.cloudOverviewSection {
                    CloudOverviewView(section: section)
                } else {
                    // 网盘专属页面：与拾光 / 系统图库的同名页面共用同一个入口位置。
                    switch store.cloudScope {
                    case .map:
                        PhotoMapView()
                    case .places:
                        PlaceStatisticsView(query: $placesQuery)
                    case .keywords:
                        CloudKeywordGalleryView()
                    case .people:
                        CloudPeopleView()
                    case .duplicates:
                        CloudDuplicatesView()
                    case .health:
                        CloudHealthView()
                    case .revisit:
                        // 与拾光 / 系统图库同一套「值得重看」主体页，数据源切到当前网盘目录。
                        RevisitView()
                    case .ratings:
                        // 与系统图库同一套整理工作台：评分 / 旗标 / 色标只在拾光本地记录。
                        OrganizeStudioView()
                    case .recentlyEdited, .trash, .imports:
                        CloudReadOnlyScopeView(scope: store.cloudScope)
                    default:
                        photoContent(width: width)
                    }
                }
            case .favorites, .systemFavorites:
                if store.favoritesViewMode != .all, store.selectedFavoriteBucket == nil {
                    FavoritesDigestView()
                } else if store.selectedFavoriteBucket != nil {
                    photoContent(width: width)
                        .task(id: store.favoritesDigestToken) {
                            store.loadFavoritesDigestIfNeeded()
                        }
                } else {
                    photoContent(width: width)
                }
            default:
                photoContent(width: width)
            }
        }
    }

    /// 普通照片网格：空状态、加载状态与年 / 月总览都在这里。
    @ViewBuilder
    func photoContent(width: CGFloat) -> some View {
        // 年 / 月总览的数据来自分区查询，系统图库的内存窗口此时为空，
        // 不能按 visibleCount 判定为「没有照片」，否则会直接显示空状态。
        let showsTimelineOverview = store.isTimelineScope && store.grouping != .all
        if store.visibleCount == 0, !showsTimelineOverview {
            if store.isCloudScope {
                // 网盘的空态还要承担扫描进度、错误与重新授权入口。
                CloudGridEmptyState()
            } else if store.isPagedScope, store.isPagedWindowLoading || !store.hasLoadedPagedWindow {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在读取图库…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isLoadingSystemLibrary, store.isSystemScope {
                // 读取进度统一显示在顶部状态胶囊里，这里留空避免同一句文案出现两遍。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }
        } else {
            photoGrid(width: width)
        }
    }

    // MARK: - 底部计数胶囊

    /// 网格页在底部居中显示当前范围的照片/视频总数（对齐系统「照片」）。
    /// 选中照片后计数标签仍然保留，方便边选边看范围规模。
    var showsCountPill: Bool {
        (isGridScope || showsWindowSearchGrid) && store.visibleCount > 0
            && !(store.isFavoritesScope && store.favoritesViewMode != .all
                 && store.selectedFavoriteBucket == nil)
    }

    var countPill: some View {
        HStack(spacing: 6) {
            Image(systemName: store.visibleVideoCount > 0 && store.visibleCount == store.visibleVideoCount
                  ? "video" : "photo.stack")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(countPillText)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .lumaGlassCapsule()
        .animation(settings.motion.overlay, value: countPillText)
        .accessibilityLabel(countPillText)
    }

    var countPillText: String {
        let total = store.visibleCount
        let videos = store.visibleVideoCount
        let photos = total - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos.formatted()) 张照片") }
        if videos > 0 { parts.append("\(videos.formatted()) 个视频") }
        return parts.joined(separator: "、")
    }

    @ViewBuilder
    func photoGrid(width: CGFloat) -> some View {
        if store.isTimelineScope {
            switch store.grouping {
            case .years:
                YearOverviewView(width: width)
            case .months:
                MonthOverviewView(width: width)
            case .all:
                allPhotosGrid(width: width)
            }
        } else {
            allPhotosGrid(width: width)
        }
    }

    /// 系统图库超大时按「首屏 1200 张」渐进渲染；索引分页模式由 `loadMoreVisibleWindow` 负责。
    var systemWindowActive: Bool {
        !store.isSystemPagedScope && store.isSystemScope && store.grouping == .all && store.visibleCount > 1_500
    }

    var canLoadMoreSystemWindow: Bool {
        systemWindowActive && systemRenderLimit < store.visibleCount
    }

    /// 范围、筛选、搜索或排序变化时，把系统图库的渲染窗口收回首屏。
    var systemWindowKey: String {
        [String(describing: store.sidebarItem), store.photoFilter.rawValue,
         store.keywordFilter ?? "", store.searchText,
         store.sortKey.rawValue, String(store.sortAscending)]
            .joined(separator: "\u{1F}")
    }

    /// 消费 `store.scrollTargetID`：默认居中，关闭查看器时用最小滚动（已可见就不动）。
    func scrollToRequestedTarget(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = store.scrollTargetID else { return }
        let anchor: UnitPoint? = store.scrollTargetMinimal ? nil : .center
        store.scrollTargetMinimal = false
        if animated {
            withAnimation(.snappy(duration: 0.28)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
        store.scrollTargetID = nil
    }

    func windowedPhotos(_ photos: [PhotoItem]) -> [PhotoItem] {
        guard systemWindowActive, photos.count > systemRenderLimit else { return photos }
        return Array(photos.prefix(systemRenderLimit))
    }

    func allPhotosGrid(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { container in
                if store.isStackingEnabled {
                    // 堆叠形态按已加载窗口流式渲染：收起后的张数与整库计数不再一一对应，
                    // 不能用「整库虚拟占位」的排名换算，否则滚动条与视野会对不上。
                    forwardPhotoGrid(width: width, viewport: container.size, proxy: proxy)
                } else if store.timelineShowsNewestAtBottom {
                    reversePhotoGrid(width: width, viewport: container.size, proxy: proxy)
                } else if store.supportsTimelineJump {
                    forwardPagedGrid(width: width, viewport: container.size, proxy: proxy)
                } else {
                    forwardPhotoGrid(width: width, viewport: container.size, proxy: proxy)
                }
            }
        }
        .id(gridPageIdentity)
    }

    /// 回到「所有照片」后把视野拉回已加载窗口：窗口不在最新一页时，
    /// 下方全是按总数生成的空白占位，停在默认位置会整屏空白。
    func restoreTimelinePosition(_ proxy: ScrollViewProxy) {
        guard needsTimelineRestore else { return }
        // 范围切换后新窗口是异步取回的：旧窗口还在时先不定位，
        // 等 `hasLoadedPagedWindow` 变化后再由调用方补一次。
        if store.isPagedScope, !store.isPagedWindowFresh { return }
        guard let target = store.newestLoadedPhotoID else { return }
        needsTimelineRestore = false
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: store.timelineShowsNewestAtBottom ? .bottom : .top)
        }
    }

    /// 时间轴网格的页面身份：范围 / 分组 / 排序 / 过滤变化时重建滚动视图，
    /// 与 macOS 官方「照片」一致，换页后不再沿用上一页的滚动偏移。
    var gridPageIdentity: String {
        [String(describing: store.sidebarItem),
         store.grouping.rawValue,
         store.sortKey.rawValue,
         String(store.sortAscending),
         store.photoFilter.rawValue,
         String(store.timelineShowsNewestAtBottom),
         store.stackMode.rawValue,
         cloudPageIdentity]
            .joined(separator: "|")
    }

    /// 网盘页面身份：sidebarItem 始终是 `.cloudMount`，切换范围 / 目录 / 总览必须显式参与身份。
    var cloudPageIdentity: String {
        guard store.isCloudScope else { return "" }
        return [store.currentCloudMountID?.uuidString ?? "",
                store.cloudSelectedFolderPath ?? "",
                String(describing: store.cloudScope),
                store.cloudOverviewSection?.rawValue ?? ""]
            .joined(separator: "|")
    }

    /// 网盘缩略图预取键：范围 / 目录 / 数量变化时重启预取。
    var cloudGridPrefetchKey: String {
        guard store.isCloudScope else { return "" }
        return [cloudPageIdentity,
                String(store.visibleCount / 200)]
            .joined(separator: "|")
    }

    /// 常规方向（最新在上）：分段网格 + 悬浮分段头 + 底部继续加载。
    func forwardPhotoGrid(width: CGFloat, viewport: CGSize, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // 滚动探针：把内容上移量换算成当前可见区域，驱动顶栏日期范围。
                GeometryReader { geo in
                    Color.clear.preference(
                        key: GalleryScrollOffsetKey.self,
                        value: -geo.frame(in: .named(GalleryScrollSpace.name)).minY
                    )
                }
                .frame(height: 0)

                ForEach(store.sections) { section in
                    Section {
                        sectionGrid(photos: windowedPhotos(section.photos), width: width)
                    } header: {
                        if let title = section.title {
                            SectionHeaderView(title: title, count: section.photos.count)
                        }
                    }
                }
                if store.canLoadMoreVisible || canLoadMoreSystemWindow {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载更多…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .lumaGlassCapsule(shadow: false)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .onAppear {
                        if store.canLoadMoreVisible {
                            store.loadMoreVisibleWindow()
                        } else if canLoadMoreSystemWindow {
                            systemRenderLimit += 1_200
                        }
                    }
                    // 堆叠视图也会走这条流式加载（系统图库分页同样追加到窗口）：
                    // 监听已加载窗口而不是本地窗口，两种分页模式都能继续取下一页。
                    .onChange(of: store.loadedWindowPhotos.count) { _, _ in
                        store.loadMoreVisibleWindow()
                    }
                    .help("继续加载更多照片")
                }
                Color.clear.frame(height: 76)
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                frameCache.frames = frames
                guard store.grouping == .all else { return }
                lastDateSpanOffset = .greatestFiniteMagnitude
                updateVisibleDateSpan(offset: lastScrollOffset,
                                      viewportHeight: viewport.height)
            }
            .onPreferenceChange(GalleryScrollOffsetKey.self) { offset in
                lastScrollOffset = offset
                updateVisibleDateSpan(offset: offset, viewportHeight: viewport.height)
                // macOS 14 没有 onScrollGeometryChange：用滚动探针换算的偏移兜底驱动取页。
                if #unavailable(macOS 15.0) {
                    preloadForwardPageIfNeeded(offset: offset, viewport: viewport.height, width: width)
                    handleTimelineScroll(offset: offset,
                                         viewport: viewport,
                                         width: width,
                                         orientation: .newestAtTop)
                }
            }
            .photoMarqueeSelection(fillHeight: viewport.height)
        }
        .scrollIndicators(.automatic)
        .coordinateSpace(name: GalleryScrollSpace.name)
        .defaultScrollAnchor(.top)
        .onAppear {
            if store.scrollTargetID != nil {
                DispatchQueue.main.async {
                    scrollToRequestedTarget(proxy, animated: false)
                }
            } else {
                restoreTimelinePosition(proxy)
            }
        }
        .onChange(of: systemWindowKey) { _, _ in systemRenderLimit = 1_200 }
        .onChange(of: store.pagedKey) { _, _ in lastDateSpanOffset = .greatestFiniteMagnitude }
        .simultaneousGesture(pinchGesture)
        .onChange(of: store.scrollTargetID) { _, target in
            guard target != nil else { return }
            scrollToRequestedTarget(proxy, animated: true)
        }
    }

    /// 正序（最新在上）的分页网格：已加载窗口在上，下面按整库总数留出「更早照片」的等高占位，
    /// 滚动条因此一次覆盖整库；滚到窗口下沿自动取下一页，拖进占位区则按排名重定位窗口。
    func forwardPagedGrid(width: CGFloat, viewport: CGSize, proxy: ScrollViewProxy) -> some View {
        let layout = timelineLayout(width: width, orientation: .newestAtTop)
        return ScrollView {
            // 与反序时间轴同款非懒容器：整库占位交给 VStack 首帧定高，网格内部仍由 LazyVGrid 懒渲染。
            VStack(alignment: .leading, spacing: 0) {
                // 滚动探针：把内容上移量换算成当前可见区域，驱动顶栏日期范围。
                GeometryReader { geo in
                    Color.clear.preference(
                        key: GalleryScrollOffsetKey.self,
                        value: -geo.frame(in: .named(GalleryScrollSpace.name)).minY
                    )
                }
                .frame(height: 0)

                // 窗口上方（更新）未加载的照片。
                if layout.newerCount > 0 {
                    Color.clear.frame(height: layout.newerHeight)
                }
                ForEach(store.sections) { section in
                    if let title = section.title {
                        SectionHeaderView(title: title, count: section.photos.count)
                    }
                    sectionGrid(photos: section.photos, width: width)
                }
                // 窗口下方（更早）未加载的照片：用等高空白代表，滚动条才反映整库长度。
                if layout.olderCount > 0 {
                    Color.clear.frame(height: layout.olderHeight)
                }
                Color.clear.frame(height: 76)
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                frameCache.frames = frames
                guard store.grouping == .all else { return }
                lastDateSpanOffset = .greatestFiniteMagnitude
                updateVisibleDateSpan(offset: lastScrollOffset, viewportHeight: viewport.height)
            }
            .onPreferenceChange(GalleryScrollOffsetKey.self) { offset in
                lastScrollOffset = offset
                updateVisibleDateSpan(offset: offset, viewportHeight: viewport.height)
            }
            .photoMarqueeSelection(fillHeight: viewport.height)
        }
        .scrollIndicators(.automatic)
        .coordinateSpace(name: GalleryScrollSpace.name)
        .defaultScrollAnchor(.top)
        .overlay(alignment: .top) {
            // 换页 / 接续加载期间给一个浮层提示，不参与内容高度，不会顶动网格。
            if store.isPagedWindowLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .lumaGlassCapsule(shadow: false)
                    .padding(.top, 10)
            }
        }
        .modifier(TimelineScrollObserver { value in
            lastScrollOffset = value.offset
            updateVisibleDateSpan(offset: value.offset, viewportHeight: value.viewport)
            // 提前一屏预取下一页：等滚到占位边缘时数据已经到手，不会出现空白停顿。
            preloadForwardPageIfNeeded(offset: value.offset, viewport: value.viewport, width: width)
            handleTimelineScroll(offset: value.offset,
                                 viewport: CGSize(width: width, height: value.viewport),
                                 width: width,
                                 orientation: .newestAtTop)
        })
        .onAppear {
            lastTimelineJumpOffset = -1
            if store.scrollTargetID != nil {
                DispatchQueue.main.async {
                    scrollToRequestedTarget(proxy, animated: false)
                }
            } else {
                restoreTimelinePosition(proxy)
            }
        }
        .onChange(of: store.pagedKey) { _, _ in
            lastDateSpanOffset = .greatestFiniteMagnitude
            lastTimelineJumpOffset = -1
            timelineJumpTask?.cancel()
        }
        .onChange(of: store.loadedWindowPhotos.count) { _, _ in
            // 换页 / 接续加载完成后占位已重新配平：清掉旧偏移，下一次滚动按新布局重新决策。
            lastTimelineJumpOffset = -1
            restoreTimelinePosition(proxy)
        }
        .onChange(of: store.hasLoadedPagedWindow) { _, loaded in
            // 范围切换后新窗口取回：此时才按真实数据把视野锚回时间轴起点。
            guard loaded else { return }
            restoreTimelinePosition(proxy)
        }
        .onChange(of: store.timelineJumpLandingID) { _, target in
            guard let target else { return }
            // 换页后的第一次滚动由系统执行，期间不要把它当成用户拖动再次换页。
            suppressTimelineJumpsUntil = Date().timeIntervalSince1970 + 1.2
            DispatchQueue.main.async {
                proxy.scrollTo(target, anchor: .center)
                store.timelineJumpLandingID = nil
            }
        }
        .onChange(of: store.scrollTargetID) { _, target in
            guard target != nil else { return }
            scrollToRequestedTarget(proxy, animated: true)
        }
        .simultaneousGesture(pinchGesture)
    }

    /// 「新照片在底部」：内容按旧 → 新排列，进入即停在最新一屏；上方按未加载数量留虚拟占位，
    /// 滚动条因此代表整库长度（整库超高时按比例压缩，避免超出 macOS 可渲染高度导致整屏空白）。
    /// 向上滚到已加载窗口顶部时接续取更早一页；拖动条拖进占位区时按排名整体重定位窗口。
    func reversePhotoGrid(width: CGFloat, viewport: CGSize, proxy: ScrollViewProxy) -> some View {
        let photos = store.sections.reversed().flatMap { $0.photos.reversed() }
        let layout = timelineLayout(width: width, orientation: .newestAtBottom)
        return ScrollView {
            // 这里必须用非懒容器：外层 LazyVStack 会把「巨大占位 + 网格」一起懒估算，
            // 实测网格内容高度为 0（一张都不渲染）；VStack 让高度在首帧就确定。
            VStack(alignment: .leading, spacing: 0) {
                // 未加载的更早照片：用等高空白代表，滚动条才反映整库长度。
                if layout.olderCount > 0 {
                    Color.clear.frame(height: layout.olderHeight)
                }
                sectionGrid(photos: photos, width: width)
                if layout.newerCount > 0 {
                    Color.clear.frame(height: layout.newerHeight)
                }
                Color.clear.frame(height: 76)
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { frames in
                frameCache.frames = frames
                lastDateSpanOffset = .greatestFiniteMagnitude
                updateVisibleDateSpan(offset: lastScrollOffset, viewportHeight: viewport.height)
            }
            .photoMarqueeSelection(fillHeight: viewport.height)
        }
        .scrollIndicators(.automatic)
        .coordinateSpace(name: GalleryScrollSpace.name)
        .defaultScrollAnchor(.bottom)
        .overlay(alignment: .top) {
            // 换页 / 接续加载期间给一个浮层提示，不参与内容高度，不会顶动网格。
            if store.isPagedWindowLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .lumaGlassCapsule(shadow: false)
                    .padding(.top, 10)
            }
        }
        .onChange(of: store.loadedWindowPhotos.count) { _, _ in
            // 窗口异步加载完成：从年 / 月总览回来时在这里补做一次视野恢复。
            restoreTimelinePosition(proxy)
            guard let anchor = olderLoadAnchor else { return }
            olderLoadAnchor = nil
            // 更早的一页追加后，占位会同步缩小但压缩比例不同：
            // 滚回原来最上面那张，视野里的照片保持不动。
            DispatchQueue.main.async {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        .onChange(of: store.hasLoadedPagedWindow) { _, loaded in
            guard loaded else { return }
            restoreTimelinePosition(proxy)
        }
        .modifier(TimelineScrollObserver { value in
            lastScrollOffset = value.offset
            lastTimelineContentHeight = value.contentHeight
            lastTimelineViewport = value.viewport
            updateVisibleDateSpan(offset: value.offset, viewportHeight: value.viewport)
            // 打开页面时窗口宽度 / 侧边栏在动画，占位高度会跟着变，滚动位置也会连续跳。
            // 只有「已经贴住底部并稳定」才开始响应换页，避免把动画过程当成用户拖动；
            // 落位后不会再有几何回调，所以用延时任务复查最后记录的数值。
            if !timelineGridReady {
                guard value.contentHeight > value.viewport,
                      value.offset >= value.contentHeight - value.viewport - 2 else { return }
                timelineAnchorReadyTask?.cancel()
                timelineAnchorReadyTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    guard lastTimelineContentHeight > lastTimelineViewport,
                          lastScrollOffset >= lastTimelineContentHeight - lastTimelineViewport - 2 else { return }
                    timelineGridReady = true
                }
                return
            }
            handleTimelineScroll(offset: value.offset,
                                 viewport: CGSize(width: width, height: value.viewport),
                                 width: width,
                                 orientation: .newestAtBottom)
        })
        .onAppear {
            timelineGridReady = false
            lastTimelineJumpOffset = -1
            // 网格是新建的：遗留的定位请求（年 / 月总览点某天、选中项定位）在这里消费，
            // 否则它永远不会被 onChange 触发，视野会停在空白占位里。
            if let target = store.scrollTargetID,
               store.loadedWindowPhotos.contains(where: { $0.id == target }) {
                DispatchQueue.main.async {
                    scrollToRequestedTarget(proxy, animated: false)
                }
            } else {
                restoreTimelinePosition(proxy)
            }
        }
        .onChange(of: store.pagedKey) { _, _ in
            lastDateSpanOffset = .greatestFiniteMagnitude
            timelineGridReady = false
            lastTimelineJumpOffset = -1
        }
        .simultaneousGesture(pinchGesture)
        .onChange(of: store.timelineJumpLandingID) { _, target in
            guard let target else { return }
            // 换页后的第一次滚动由系统执行，期间不要把它当成用户拖动再次换页。
            suppressTimelineJumpsUntil = Date().timeIntervalSince1970 + 1.2
            timelineGridReady = true
            // 新一页的视图可能还没完成布局，稍后再滚一次确保真的落到这张照片上。
            DispatchQueue.main.async {
                proxy.scrollTo(target, anchor: .center)
                store.timelineJumpLandingID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .onChange(of: store.scrollTargetID) { _, target in
            guard target != nil else { return }
            scrollToRequestedTarget(proxy, animated: true)
        }
    }

    /// 虚拟占位可用的最大高度。macOS 上滚动内容高度一旦超出可渲染范围（实测约两千万点），
    /// SwiftUI 会直接不绘制内容、整屏空白；所以整库占位统一按比例压缩到安全高度以内，
    /// 排名换算用同一比例还原，滚动条依然覆盖整库而不是只有一页。
    static let maxVirtualTimelineHeight: CGFloat = 1_500_000

    /// 虚拟占位 / 排名换算用的列数与行高（与网格同一套尺寸估算）。
    struct TimelineGridMetrics {
        let columns: Int
        let rowHeight: CGFloat
        /// 整库占位相对真实网格高度的压缩比例（1 = 不压缩）。
        let placeholderScale: CGFloat

        func rows(for count: Int) -> Int {
            guard count > 0, columns > 0 else { return 0 }
            return (count + columns - 1) / columns
        }

        /// 已加载窗口的真实高度。
        func windowHeight(for count: Int) -> CGFloat {
            CGFloat(rows(for: count)) * rowHeight
        }

        /// 未加载照片的虚拟占位高度（按整库比例压缩）。
        func placeholderHeight(for count: Int) -> CGFloat {
            CGFloat(rows(for: count)) * rowHeight * placeholderScale
        }
    }

    /// 时间轴网格的排布方向：新照片在底部（反序）或最新在上（正序）。
    enum TimelineOrientation {
        case newestAtBottom
        case newestAtTop
    }

    /// 时间轴网格的纵向分段：把「窗口前占位 → 已加载窗口 → 窗口后占位」拼成整库长度。
    /// 反序时窗口前是更早的照片、窗口后是更新的照片；正序则相反。
    struct TimelineLayout {
        let metrics: TimelineGridMetrics
        let orientation: TimelineOrientation
        let olderCount: Int
        let loadedCount: Int
        let newerCount: Int
        let total: Int

        var olderHeight: CGFloat { metrics.placeholderHeight(for: olderCount) }
        var windowHeight: CGFloat { metrics.windowHeight(for: loadedCount) }
        var newerHeight: CGFloat { metrics.placeholderHeight(for: newerCount) }
        var contentHeight: CGFloat { olderHeight + windowHeight + newerHeight }

        /// 已加载窗口在内容坐标里的上沿 / 下沿。
        var windowTop: CGFloat { orientation == .newestAtBottom ? olderHeight : newerHeight }
        var windowBottom: CGFloat { windowTop + windowHeight }

        /// 已加载窗口里最新一张的整库排名（0 = 最新）。
        var startRank: Int {
            orientation == .newestAtBottom
                ? max(0, total - olderCount - loadedCount)
                : max(0, newerCount)
        }

        /// 视口中心落在整库里的第几张（0 = 最新）：占位按压缩比例换算回真实排名。
        func rank(atCenter center: CGFloat) -> Int {
            guard total > 0 else { return 0 }
            let y = min(max(0, center), max(0, contentHeight - 0.5))
            switch orientation {
            case .newestAtBottom:
                if olderCount > 0, olderHeight > 0, y < olderHeight {
                    let ratio = Double((olderHeight - y) / olderHeight)
                    return clampedRank(Double(startRank + loadedCount - 1) + ratio * Double(olderCount))
                }
                if y < olderHeight + windowHeight {
                    let row = Int((y - olderHeight) / max(metrics.rowHeight, 1))
                    return clampedRank(Double(startRank + loadedCount - 1 - row * metrics.columns))
                }
                guard newerCount > 0, newerHeight > 0 else { return clampedRank(Double(startRank)) }
                let ratio = Double((y - olderHeight - windowHeight) / newerHeight)
                return clampedRank(Double(startRank - 1) - ratio * Double(newerCount))
            case .newestAtTop:
                if newerCount > 0, newerHeight > 0, y < newerHeight {
                    let ratio = Double((newerHeight - y) / newerHeight)
                    return clampedRank(Double(startRank) - ratio * Double(newerCount))
                }
                if y < newerHeight + windowHeight {
                    let row = Int((y - newerHeight) / max(metrics.rowHeight, 1))
                    return clampedRank(Double(startRank + row * metrics.columns))
                }
                guard olderCount > 0, olderHeight > 0 else {
                    return clampedRank(Double(startRank + loadedCount - 1))
                }
                let ratio = Double((y - newerHeight - windowHeight) / olderHeight)
                return clampedRank(Double(startRank + loadedCount - 1) + ratio * Double(olderCount))
            }
        }

        private func clampedRank(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return min(max(0, Int(value.rounded())), max(0, total - 1))
        }
    }

    func timelineMetrics(width: CGFloat, total: Int) -> TimelineGridMetrics {
        let contentWidth = max(120, width)
        let spacing: CGFloat = 2
        let columns: Int
        let rowHeight: CGFloat
        switch store.thumbnailAspect {
        case .square:
            let target = CGFloat(store.thumbSize)
            columns = GridLayout.columns(contentWidth: contentWidth,
                                         targetSize: target,
                                         spacing: spacing)
            let cell = GridLayout.squareCellWidth(contentWidth: contentWidth,
                                                  columns: columns,
                                                  spacing: spacing)
            rowHeight = cell + spacing
        case .actual:
            rowHeight = max(60, CGFloat(store.thumbSize) * 0.92) + spacing
            columns = max(1, Int(contentWidth / max((rowHeight - spacing) * 1.2, 1)))
        case .masonry:
            let target = max(90, CGFloat(store.thumbSize))
            columns = GridLayout.columns(contentWidth: contentWidth,
                                         targetSize: target,
                                         spacing: spacing)
            rowHeight = target * 1.25 + spacing
        case .list:
            columns = 1
            rowHeight = 34
        }
        let safeColumns = max(1, columns)
        let fullRows = (max(total, 0) + safeColumns - 1) / safeColumns
        let fullHeight = CGFloat(fullRows) * rowHeight
        let scale = fullHeight > Self.maxVirtualTimelineHeight
            ? Self.maxVirtualTimelineHeight / fullHeight
            : 1
        return TimelineGridMetrics(columns: safeColumns,
                                   rowHeight: rowHeight,
                                   placeholderScale: scale)
    }

    /// 时间轴网格的当前分段布局。换页 / 接续加载刚完成时视图里捕获的布局已经过期，
    /// 决策时必须以 Store 的实时状态重算，否则会按旧高度算出错误排名、来回跳。
    func timelineLayout(width: CGFloat, orientation: TimelineOrientation) -> TimelineLayout {
        // 「相似照片」是固定集合的过滤视图，窗口总数不等于可见数量，不能按整库留占位。
        let jumpable = store.supportsTimelineJump && store.similarScope == nil
        return TimelineLayout(metrics: timelineMetrics(width: width, total: store.visibleCount),
                              orientation: orientation,
                              olderCount: jumpable ? store.timelineOlderUnloadedCount : 0,
                              loadedCount: store.loadedWindowPhotos.count,
                              newerCount: jumpable ? store.timelineNewerUnloadedCount : 0,
                              total: store.visibleCount)
    }

    /// 时间轴网格滚动：停下后再决策（滚动途中布局连续变化，按中途状态取页只会来回跳）。
    func handleTimelineScroll(offset: CGFloat, viewport: CGSize, width: CGFloat,
                                      orientation: TimelineOrientation) {
        guard offset.isFinite, viewport.height > 1 else { return }
        guard Date().timeIntervalSince1970 > suppressTimelineJumpsUntil else { return }
        guard abs(offset - lastTimelineJumpOffset) > 8 else { return }
        lastTimelineJumpOffset = offset
        timelineJumpTask?.cancel()
        timelineJumpTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            decideTimelineWork(offset: offset, viewport: viewport.height, width: width,
                               orientation: orientation)
        }
    }

    func decideTimelineWork(offset: CGFloat, viewport: CGFloat, width: CGFloat,
                                    orientation: TimelineOrientation) {
        guard store.supportsTimelineJump, !store.isPagedWindowLoading else { return }
        let layout = timelineLayout(width: width, orientation: orientation)
        guard layout.total > 0, layout.loadedCount > 0 else { return }
        let center = offset + viewport / 2
        let edge = layout.metrics.rowHeight * 2
        guard center >= layout.windowTop, center < layout.windowBottom else {
            // 视野落在虚拟占位里（拖动条被拖到远处 / 快速甩动）：按排名整体重定位窗口。
            jumpTimelineTo(centerRank: layout.rank(atCenter: center), layout: layout)
            return
        }
        switch orientation {
        case .newestAtBottom:
            if layout.olderCount > 0, center - layout.windowTop < edge {
                // 正常向上滚动到已加载窗口的顶部：接续取更早一页，高度差用锚点照片补偿。
                loadOlderTimelinePage(restoreAnchor: true)
            } else if layout.newerCount > 0, layout.windowBottom - center < edge {
                // 往下（更新）一侧没有追加接口：整体重定位到当前视野的中心。
                jumpTimelineTo(centerRank: layout.rank(atCenter: center), layout: layout)
            }
        case .newestAtTop:
            if layout.olderCount > 0, layout.windowBottom - center < edge {
                // 正序：更早的照片就在窗口下方，直接追加下一页，顶部锚定不需要补偿。
                loadOlderTimelinePage(restoreAnchor: false)
            } else if layout.newerCount > 0, center - layout.windowTop < edge {
                // 窗口上方还有更新的照片：整体重定位到当前视野的中心。
                jumpTimelineTo(centerRank: layout.rank(atCenter: center), layout: layout)
            }
        }
    }

    func loadOlderTimelinePage(restoreAnchor: Bool) {
        guard store.canLoadMoreVisible, !store.isPagedWindowLoading else { return }
        olderLoadAnchor = restoreAnchor ? store.loadedWindowPhotos.last?.id : nil
        store.loadMoreVisibleWindow()
    }

    /// 正序网格的提前预取：视口下沿接近已加载窗口底部时先把下一页取回来，
    /// 等真正滚到占位边缘时数据已就绪，不会先看到一片空白再补内容。
    func preloadForwardPageIfNeeded(offset: CGFloat, viewport: CGFloat, width: CGFloat) {
        guard store.supportsTimelineJump, store.similarScope == nil,
              store.canLoadMoreVisible, !store.isPagedWindowLoading else { return }
        guard abs(offset - lastForwardPreloadOffset) >= 24 else { return }
        lastForwardPreloadOffset = offset
        let layout = timelineLayout(width: width, orientation: .newestAtTop)
        guard layout.olderCount > 0, layout.loadedCount > 0 else { return }
        // 只在窗口内容还占着屏幕时预取；拖进占位区交给滚动停稳后的重定位逻辑。
        guard offset < layout.windowBottom,
              offset + viewport >= layout.windowBottom - layout.metrics.rowHeight * 3 else { return }
        store.loadMoreVisibleWindow()
    }

    /// 把分页窗口整体重定位到「视野中心那张」附近。
    func jumpTimelineTo(centerRank rank: Int, layout: TimelineLayout) {
        let pageSize = layout.loadedCount
        guard pageSize > 0, layout.total > pageSize else { return }
        let start = layout.startRank
        // 目标本来就在当前窗口里：不需要重定位。
        guard rank < start || rank >= start + pageSize else { return }
        let target = min(max(0, rank - pageSize / 2), max(0, layout.total - pageSize))
        // 换页后内容高度会整体重排并连续回调几何值，静默一小段时间避免被当成新的拖动。
        suppressTimelineJumpsUntil = Date().timeIntervalSince1970 + 1.0
        store.jumpTimelineWindow(toRank: target)
    }

    /// 按当前滚动位置算出顶栏副标题的日期范围（与系统「照片」一致，随滚动动态变化）。
    /// 只统计与视口相交的单元格；快速滚动时若暂时没有命中，用离视口最近的一张兜底，
    /// 避免顶栏日期停在上一屏、和画面里的照片对不上。
    func updateVisibleDateSpan(offset: CGFloat, viewportHeight: CGFloat) {
        guard store.isTimelineScope, store.grouping == .all else {
            if !store.visibleDateSpanText.isEmpty { store.visibleDateSpanText = "" }
            return
        }
        guard viewportHeight > 0,
              abs(offset - lastDateSpanOffset) >= 8 else { return }
        lastDateSpanOffset = offset

        let frames = frameCache.frames
        guard !frames.isEmpty else { return }
        let lookup = store.photoDateLookup
        let top = offset
        let bottom = offset + viewportHeight
        var start: Date?
        var end: Date?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var nearestDate: Date?
        for (id, frame) in frames {
            guard let captured = lookup[id] else { continue }
            if frame.maxY >= top, frame.minY <= bottom {
                if start == nil || captured < start! { start = captured }
                if end == nil || captured > end! { end = captured }
            } else {
                let distance = frame.minY > bottom ? frame.minY - bottom : top - frame.maxY
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestDate = captured
                }
            }
        }
        if start == nil, let nearestDate {
            start = nearestDate
            end = nearestDate
        }
        guard let start, let end else { return }
        let text = DateText.span(from: start, to: end)
        if store.visibleDateSpanText != text { store.visibleDateSpanText = text }
    }

    /// 按用户选择的显示形式渲染一段照片：正方形 / 完整宽高比 / 瀑布流 / 列表。
    /// 统一留出顶部间距：无分段标题时（「所有照片」）首排照片不会贴着工具栏。
    @ViewBuilder
    func sectionGrid(photos: [PhotoItem], width: CGFloat) -> some View {
        Group {
            switch store.thumbnailAspect {
            case .square:
                SquarePhotoGrid(photos: photos, availableWidth: width,
                                stacked: store.isStackingEnabled)
                    .padding(.bottom, 26)
            case .actual:
                JustifiedPhotoGrid(photos: photos,
                                   availableWidth: width,
                                   targetHeight: CGFloat(store.thumbSize) * 0.92,
                                   stacked: store.isStackingEnabled)
                    .padding(.bottom, 26)
            case .masonry:
                MasonryPhotoGrid(photos: photos,
                                 availableWidth: width,
                                 targetWidth: CGFloat(store.thumbSize),
                                 stacked: store.isStackingEnabled)
                    .padding(.bottom, 26)
            case .list:
                PhotoListView(photos: photos, availableWidth: width,
                              stacked: store.isStackingEnabled)
                    .padding(.bottom, 20)
            }
        }
        .padding(.top, 10)
    }

    var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }
}
