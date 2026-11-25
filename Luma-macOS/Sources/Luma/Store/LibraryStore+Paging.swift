import Foundation
import SwiftUI

/// 大图库的分页窗口：筛选、排序、总量都由 SQLite 完成，Store 只保留已加载的若干页。
extension LibraryStore {
    /// 时间轴范围（所有照片/媒体类型等）可下推的条件；与分组模式无关。
    var timelineQuery: PhotoQuery? {
        guard !needsLibrarySetup, metadataStore != nil,
              !isSystemScope, !isCloudScope,
              selectedPlace == nil, selectedPerson == nil,
              selectedFavoriteBucket == nil,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              photos.count >= Self.windowThreshold,
              let scope = sidebarItem.photoQueryScope else { return nil }
        return PhotoQuery(scope: scope,
                          filter: photoFilter,
                          keyword: keywordFilter,
                          sortKey: sortKey,
                          ascending: sortAscending,
                          minRating: ratingFilter,
                          flag: flagFilter,
                          colorLabel: colorLabelFilter)
    }

    /// 系统图库的索引查询描述：索引可用且当前范围能翻译成 SQL 时生效。
    var systemQuery: SystemQuery? {
        guard systemIndex != nil, !needsLibrarySetup, isSystemScope else { return nil }
        // 收藏汇总下钻：年份可以直接下推成「收藏 + 日期区间」，不必等上万条汇总读完；
        // 其它维度需要地点 / 相机等逐张元数据，继续用汇总时载入的完整收藏列表。
        if let bucket = selectedFavoriteBucket {
            if isSystemScope, bucket.dimension == .year, let year = Int(bucket.key) {
                var query = cachedSystemQuery(.favorites)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                query.startDate = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
                query.endDate = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
                query.sortKey = .capturedAt
                query.ascending = false
                return query
            }
            return nil
        }
        // 地点详情展示的是聚类自带的那组照片，不是一个 SystemQueryScope：
        // 让它走内存列表，查看器翻页 / 序号才会和屏幕上的照片一致。
        if selectedPlace != nil { return nil }
        if sidebarItem == .systemPeople {
            guard let person = selectedPerson else { return nil }
            return cachedSystemQuery(.person(person.id))
        }
        let scope: SystemQueryScope
        if searchScope != .currentView, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 全局 / 模块内搜索：索引查询放宽到全库；窗口内只查当前范围。
            scope = .all
        } else {
            guard let s = sidebarItem.systemQueryScope else { return nil }
            scope = s
        }
        return cachedSystemQuery(scope)
    }

    /// 按当前输入条件缓存索引查询。这个构建会遍历拾光补充元数据，
    /// 而 `systemQuery` / `pagedKey` / `visibleCount` 都在 SwiftUI body 里被反复读取，
    /// 每次重算会让主线程持续满载（表现为 CPU 飙升、界面狂闪）。
    func cachedSystemQuery(_ scope: SystemQueryScope) -> SystemQuery {
        let signature = [
            scope.rawKey, photoFilter.rawValue, sortKey.rawValue, String(sortAscending),
            searchText, searchScope.rawValue, keywordFilter ?? "", String(contentRevision),
            String(systemStructureRevision), String(systemOverlays.count),
            String(photoKitLongExposureIDs?.count ?? -1),
            String(photoKitCinematicIDs?.count ?? -1),
            systemIndexSignature
        ].joined(separator: "\u{1F}")
        if signature == systemQueryCacheSignature, let cached = systemQueryCache[scope.rawKey] {
            return cached
        }
        if signature != systemQueryCacheSignature {
            systemQueryCacheSignature = signature
            systemQueryCache.removeAll(keepingCapacity: true)
            systemQueryKeyCache.removeAll(keepingCapacity: true)
        }
        let query = buildSystemQuery(scope: scope)
        systemQueryCache[scope.rawKey] = query
        // 只在这里构建一次 key：收藏 / 隐藏叠加多时它可能是很长的字符串，
        // 不能每次 SwiftUI body 读取 `pagedKey` 时重新拼接。
        systemQueryKeyCache[scope.rawKey] = query.key
        return query
    }

    /// 时间轴范围的系统图库查询（年 / 月总览也用它）。
    var systemTimelineQuery: SystemQuery? {
        guard isTimelineScope, isSystemScope, systemIndex != nil else { return nil }
        return cachedSystemQuery(.all)
    }

    /// 系统图库「所有照片」网格分页：年 / 月总览时交给 SQL 分区，不返回照片窗口。
    var systemPagedQuery: SystemQuery? {
        if isTimelineScope && grouping != .all { return nil }
        return systemQuery
    }

    /// 是否处于系统图库索引分页模式。
    var isSystemPagedScope: Bool { systemPagedQuery != nil }

    /// 「所有照片」网格分页：只有时间轴范围才受年/月总览影响，其它范围始终是普通网格。
    var pagedQuery: PhotoQuery? {
        if isTimelineScope {
            return grouping == .all ? timelineQuery : nil
        }
        return timelineQuery
    }

    /// 当前是否处于 SQL 分页模式（本地图库或系统图库索引）。
    var isPagedScope: Bool { pagedQuery != nil || isSystemPagedScope }

    /// 分页窗口的加载标记：系统索引与本地窗口各有一套，界面上必须按当前模式取用。
    var isPagedWindowLoading: Bool {
        isSystemPagedScope ? isSystemWindowLoading : isWindowLoading
    }

    var hasLoadedPagedWindow: Bool {
        isSystemPagedScope ? hasLoadedSystemWindow : hasLoadedWindow
    }

    /// 当前分页窗口里已加载的照片（系统索引 / 本地索引），供「新照片在底部」的网格使用。
    var loadedWindowPhotos: [PhotoItem] {
        isSystemPagedScope ? systemWindowPhotos : windowPhotos
    }

    /// 「新照片在底部」的时间轴能否按整库排名跳转（系统直连按日期定位，本地与索引模式按偏移取页）。
    var supportsTimelineJump: Bool {
        isPagedScope
    }

    /// 查看器 / 胶片条是否按网格的视觉顺序（旧 → 新）排列。
    /// 「图库」页新照片在底部时，网格是从旧到新，序号与左右翻页必须跟着屏幕走。
    var viewerUsesVisualTimelineOrder: Bool { timelineShowsNewestAtBottom }

    /// 查看器 / 胶片条使用的照片顺序：默认查询顺序（新 → 旧），时间轴在底部时反转成旧 → 新。
    var viewerVisiblePhotos: [PhotoItem] {
        // 从地图 / 地点 / 卡片墙打开：查看器直接用点击时那份列表。
        if !viewerContextPhotos.isEmpty { return viewerContextPhotos }
        let items = visiblePhotos
        guard viewerUsesVisualTimelineOrder else { return items }
        return Array(items.reversed())
    }

    /// 已加载窗口第一张在整库查询顺序里的排名（0 = 最新）。
    var timelineWindowStartRank: Int {
        isSystemPagedScope ? systemWindowStartRank : windowStartOffset
    }

    /// 已加载窗口上方（更早）还没加载的数量：虚拟占位按它换算高度。
    var timelineOlderUnloadedCount: Int {
        if isSystemPagedScope {
            return max(0, systemWindowTotal - systemWindowStartRank - systemWindowPhotos.count)
        }
        guard isPagedScope else { return 0 }
        return max(0, windowTotal - windowStartOffset - windowPhotos.count)
    }

    /// 已加载窗口下方（更新）还没加载的数量。
    var timelineNewerUnloadedCount: Int {
        if isSystemPagedScope { return max(0, systemWindowStartRank) }
        guard isPagedScope else { return 0 }
        return max(0, windowStartOffset)
    }

    /// 网格初始定位用的「最新一张」：分页模式取窗口第一张，内存模式取可见集合第一张。
    var newestLoadedPhotoID: UUID? {
        if isSystemPagedScope { return systemWindowPhotos.first?.id }
        if isPagedScope { return windowPhotos.first?.id }
        return visiblePhotos.first?.id
    }

    /// 驱动初始定位的数量：分页窗口数量，或内存模式的可见数量。
    var anchorPhotoCount: Int {
        isPagedScope ? loadedWindowPhotos.count : visiblePhotos.count
    }

    /// 视图用 `.task(id:)` 监听：范围、筛选、排序或内容版本变化时刷新窗口。
    var pagedKey: String {
        if let query = systemPagedQuery {
            let key = systemQueryKeyCache[query.scope.rawKey] ?? query.key
            return "sys#\(key)#\(systemIndexSignature)"
        }
        guard let query = pagedQuery else { return "" }
        return "\(query.key)#\(contentRevision)"
    }

    var visibleCount: Int {
        if isSystemPagedScope {
            if let similarScope {
                return systemWindowPhotos.lazy.filter { similarScope.ids.contains($0.id) }.count
            }
            return systemWindowTotal
        }
        return isPagedScope ? windowTotal : visiblePhotos.count
    }

    var visibleVideoCount: Int {
        if isSystemPagedScope {
            if let similarScope {
                return systemWindowPhotos.lazy.filter {
                    similarScope.ids.contains($0.id) && $0.isVideo
                }.count
            }
            return systemWindowVideos
        }
        return isPagedScope ? windowVideos : visiblePhotos.lazy.filter { $0.isVideo }.count
    }

    var canLoadMoreVisible: Bool {
        if isSystemPagedScope {
            if similarScope != nil { return false }
            return systemWindowPhotos.count < systemWindowTotal
        }
        return isPagedScope && windowPhotos.count < windowTotal
    }

    /// 已加载的窗口是否已经对应「当前范围」的查询。
    /// 从别的页面切回图库时，新查询的窗口是异步取回的，期间内存里还是上一个范围的照片；
    /// 此时不能按旧数据恢复滚动位置，否则会停在错位的占位区。
    var isPagedWindowFresh: Bool {
        if let query = systemPagedQuery {
            return hasLoadedSystemWindow && systemWindowKey == "sys#\(query.key)#\(systemIndexSignature)"
        }
        guard let query = pagedQuery else { return false }
        return hasLoadedWindow && windowKeyValue == "\(query.key)#\(contentRevision)"
    }

    /// 首次进入或查询条件变化时加载第一页；内容版本变化时保留已加载页数，避免滚动位置跳回顶部。
    func reloadVisibleWindowIfNeeded() {
        if let query = systemPagedQuery {
            reloadSystemWindowIfNeeded(query)
            return
        }
        guard let query = pagedQuery else { return }
        let key = "\(query.key)#\(contentRevision)"
        if let target = scrollTargetID,
           key != windowKeyValue || !windowPhotos.contains(where: { $0.id == target }) {
            focusWindow(on: target, query: query, key: key)
            return
        }
        // 窗口标记相同但内容为空（例如从年 / 月总览切回「所有照片」时窗口被清过）：
        // 不能直接返回，否则网格只剩按总数生成的虚拟占位，整屏空白。
        if key == windowKeyValue, hasLoadedWindow, !windowPhotos.isEmpty { return }
        let sameQuery = query.key == windowQueryKey
        if !sameQuery {
            // 范围或排序变了：先清空旧窗口，避免短暂显示上一次的结果。
            windowPhotos = []
            windowTotal = 0
            windowVideos = 0
            hasLoadedWindow = false
        }
        let limit = sameQuery ? max(Self.windowPageSize, windowPhotos.count) : Self.windowPageSize
        loadWindow(query: query, key: key, start: 0, limit: limit, replace: true)
    }

    /// 时间轴跳转：把分页窗口整体重定位到第 `rank` 张（0 = 最新一张）。
    /// 只更新窗口内容与起始排名，滚动位置不变——界面按排名换算的虚拟占位高度会自然对齐。
    func jumpTimelineWindow(toRank rank: Int) {
        // 本地图库：按偏移重新取一页，虚拟占位随 `windowStartOffset` 自动重新配平。
        if !isSystemPagedScope {
            guard isPagedScope, let query = pagedQuery else { return }
            let total = windowTotal
            guard total > 0 else { return }
            let pageSize = Self.windowPageSize
            let start = min(max(0, rank), max(0, total - pageSize))
            guard start != windowStartOffset else { return }
            let key = windowKeyValue.isEmpty ? "\(query.key)#\(contentRevision)" : windowKeyValue
            loadWindow(query: query, key: key, start: start, limit: pageSize, replace: true)
            return
        }
        guard let index = systemIndex, let query = systemPagedQuery else { return }
        let total = systemWindowTotal
        guard total > 0 else { return }
        let pageSize = Self.windowPageSize
        let start = min(max(0, rank), max(0, total - pageSize))
        // 索引模式：本地索引可以直接按偏移取一页，排名即偏移。
        if index.direct == nil {
            let key = systemWindowKey
            systemWindowTask?.cancel()
            systemWindowQuery = query
            isSystemWindowLoading = true
            systemWindowTask = Task { [weak self] in
                let page = await Task.detached(priority: .userInitiated) {
                    index.page(query, offset: start, limit: pageSize)
                }.value
                guard let self, !Task.isCancelled, self.systemWindowKey == key else { return }
                self.isSystemWindowLoading = false
                guard !page.isEmpty else { return }
                self.systemWindowStart = start
                self.systemWindowStartRank = start
                self.systemWindowPhotos = page.map { self.applySystemOverlay($0) }
                self.rememberSystemPhotos(self.systemWindowPhotos)
                self.systemWindowRevision &+= 1
                self.hasLoadedSystemWindow = true
                // 落在这一页中间：滚动位置与换页前的视野中心基本对齐，不会停在占位空白里。
                self.timelineJumpLandingID = self.systemWindowPhotos[self.systemWindowPhotos.count / 2].id
            }
            return
        }
        // 最旧的一页按升序直接取：日期插值会在顶部留下几张看不见的「更早照片」，
        // 第一张照片的序号就会平白多出几张。按升序取最旧一页，排名 = 总数 − 这一页的张数，是精确的。
        let isOldestPage = start > 0 && start >= max(0, total - pageSize)
        var pageQuery = query
        if isOldestPage {
            pageQuery.ascending = true
        } else {
            guard let date = index.timelineDate(atRank: start) else {
                return
            }
            pageQuery.endDate = date.addingTimeInterval(1)
        }
        let key = systemWindowKey
        systemWindowTask?.cancel()
        // 换页后「继续加载更早」要沿用这次的日期上界，否则会从整库最新处重新取一页（内容重复）。
        systemWindowQuery = isOldestPage ? query : pageQuery
        isSystemWindowLoading = true
        systemWindowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([PhotoItem], Int) in
                if isOldestPage {
                    let oldest = index.page(pageQuery, offset: 0, limit: pageSize)
                    return (Array(oldest.reversed()), max(0, total - oldest.count))
                }
                let page = index.page(pageQuery, offset: 0, limit: pageSize)
                // 排名只用时刻表插值：`directIndex` 要对整库做 COUNT，百万级要好几秒，
                // 而占位高度只受排名影响，差几十张在滚动条上几乎看不出来。
                let loadedRank = page.first.map { index.timelineRank(of: $0.capturedAt) } ?? start
                return (page, loadedRank)
            }.value
            guard let self, !Task.isCancelled, self.systemWindowKey == key else {
                self?.isSystemWindowLoading = false
                return
            }
            self.isSystemWindowLoading = false
            guard !result.0.isEmpty else { return }
            self.systemWindowStart = 0
            self.systemWindowStartRank = result.1
            self.systemWindowPhotos = result.0.map { self.applySystemOverlay($0) }
            self.rememberSystemPhotos(self.systemWindowPhotos)
            self.systemWindowRevision &+= 1
            self.hasLoadedSystemWindow = true
            // 占位高度只是按排名估算，真正落位交给网格滚到这一张，避免停在空白占位里。
            self.timelineJumpLandingID = self.systemWindowPhotos[self.systemWindowPhotos.count / 2].id
        }
    }

    /// 网格滚动到末尾时加载下一页。
    func loadMoreVisibleWindow() {
        if let query = systemPagedQuery {
            guard !isSystemWindowLoading, canLoadMoreVisible else { return }
            // 换过页的窗口带着日期上界，继续取更早时必须沿用同一条查询。
            loadSystemWindow(query: systemWindowQuery ?? query,
                             key: systemWindowKey,
                             start: systemWindowStart + systemWindowPhotos.count,
                             limit: Self.windowPageSize,
                             replace: false)
            return
        }
        guard let query = pagedQuery, !isWindowLoading, canLoadMoreVisible else { return }
        let key = windowKeyValue.isEmpty ? "\(query.key)#\(contentRevision)" : windowKeyValue
        loadWindow(query: query, key: key,
                   start: windowStartOffset + windowPhotos.count,
                   limit: Self.windowPageSize,
                   replace: false)
    }

    /// 让窗口包含指定照片（月总览定位、方向键跳转），并把网格滚动过去。
    func focusWindow(on photoID: UUID) {
        if let query = systemPagedQuery {
            focusSystemWindow(on: photoID, query: query)
            return
        }
        guard let query = pagedQuery else {
            scrollTargetID = photoID
            return
        }
        focusWindow(on: photoID, query: query, key: "\(query.key)#\(contentRevision)")
    }

    /// 查看器胶片条取当前照片前后各 `viewerStripRadius` 张：
    /// 单屏要铺满整行并与系统「照片」一样密，只取前后 8 张会留下大片空白。
    static let viewerStripRadius = 40

    func refreshViewerStripIfNeeded() {
        // 外部列表（地图 / 地点 / 卡片墙）与「相似照片」直接按整份列表翻页，不再单独取窗口片段。
        if !viewerContextPhotos.isEmpty || similarScope != nil {
            viewerStripTask?.cancel()
            viewerStrip = []
            viewerStripKey = nil
            return
        }
        // 连拍组内浏览直接使用整组成员，不再按当前查询取前后若干张。
        if viewerModel.burstMembers.count > 1 { return }
        if isSystemPagedScope, let query = systemPagedQuery, let id = viewerID,
           let index = systemIndex {
            let key = "sys#\(query.key)#\(systemIndexSignature)#\(id.uuidString)"
            guard key != viewerStripKey else { return }
            viewerStripKey = key
            viewerStripTask?.cancel()
            viewerStripTask = Task { [weak self] in
                let photos = await Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
                    let radius = Self.viewerStripRadius
                    if let current = index.index(of: id, in: query) {
                        let total = index.summary(query).total
                        let start = max(0, current - radius)
                        let end = min(total, current + radius + 1)
                        guard end > start else { return [] }
                        return index.photos(in: query, range: start..<end)
                    }
                    // 直连模式没有全局下标：沿相邻项向两侧各取若干张拼出胶片条。
                    guard index.direct != nil, let current = index.photo(id: id) else { return [] }
                    var before: [PhotoItem] = []
                    var cursor = id
                    for _ in 0..<radius {
                        guard let previous = index.neighbor(of: cursor, delta: -1, in: query) else { break }
                        before.append(previous)
                        cursor = previous.id
                    }
                    var result = Array(before.reversed())
                    result.append(current)
                    cursor = id
                    for _ in 0..<radius {
                        guard let next = index.neighbor(of: cursor, delta: 1, in: query) else { break }
                        result.append(next)
                        cursor = next.id
                    }
                    return result
                }.value
                guard let self, !Task.isCancelled, self.viewerStripKey == key else { return }
                let ordered = self.viewerUsesVisualTimelineOrder ? Array(photos.reversed()) : photos
                self.viewerStrip = ordered.map { self.applySystemOverlay($0) }
            }
            return
        }
        guard isPagedScope, let id = viewerID,
              let store = metadataStore, let query = pagedQuery else {
            viewerStrip = []
            viewerStripKey = nil
            return
        }
        let key = "\(query.key)#\(contentRevision)#\(id.uuidString)"
        guard key != viewerStripKey else { return }
        viewerStripKey = key
        viewerStripTask?.cancel()
        viewerStripTask = Task { [weak self] in
            let photos = await Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
                guard let index = store.index(of: id, in: query) else { return [] }
                let total = store.summary(query).total
                let radius = Self.viewerStripRadius
                let start = max(0, index - radius)
                let end = min(total, index + radius + 1)
                guard end > start else { return [] }
                return store.photos(in: query, range: start..<end)
            }.value
            guard let self, !Task.isCancelled, self.viewerStripKey == key else { return }
            self.viewerStrip = self.viewerUsesVisualTimelineOrder ? Array(photos.reversed()) : photos
        }
    }

    /// 年 / 月总览是否也可以走 SQL 分区。
    var usesSQLOverview: Bool {
        if isSystemScope {
            return systemTimelineQuery != nil && grouping != .all
        }
        return timelineQuery != nil && (grouping == .years || grouping == .months)
    }

    /// 视图用 `.task(id:)` 监听总览数据刷新。
    var overviewKey: String {
        if isSystemScope {
            guard usesSQLOverview, let query = systemTimelineQuery else { return "" }
            // 直连模式的年 / 月计数来自后台快照：快照到达会提升 contentRevision，这里必须跟着刷新。
            return "sys#\(query.key)#\(systemIndexSignature)#\(grouping.rawValue)#\(contentRevision)"
        }
        guard usesSQLOverview, let query = timelineQuery else { return "" }
        return "\(query.key)#\(contentRevision)#\(grouping.rawValue)"
    }

    func reloadOverviewIfNeeded() {
        if isSystemScope {
            reloadSystemOverviewIfNeeded()
            return
        }
        guard usesSQLOverview, let query = timelineQuery, let store = metadataStore else { return }
        let key = "\(query.key)#\(contentRevision)#\(grouping.rawValue)"
        guard key != overviewKeyValue else { return }
        overviewTask?.cancel()
        overviewKeyValue = key
        isOverviewLoading = true
        let grouping = self.grouping
        overviewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (buckets: [PhotoPeriodBucket], months: [PhotoMonthGroup]) in
                switch grouping {
                case .years:
                    return (store.yearBuckets(query), [])
                case .months:
                    return ([], store.monthGroups(query))
                case .all:
                    return ([], [])
                }
            }.value
            guard let self, !Task.isCancelled, self.overviewKeyValue == key else { return }
            self.isOverviewLoading = false
            if grouping == .years {
                self.yearBuckets = result.buckets
            } else {
                self.monthGroups = result.months
            }
            self.resolvePendingMonthScroll()
        }
    }

    /// 从年总览点进某年时，等月份数据到手再定位到该年第一个月。
    private func resolvePendingMonthScroll() {
        guard let year = pendingMonthScrollYear else { return }
        guard let group = monthGroups.first(where: { $0.id.hasPrefix("\(year)-") }) else { return }
        pendingMonthScrollYear = nil
        scrollTargetSection = group.id
    }

    // MARK: - 内部

    private func loadWindow(query: PhotoQuery, key: String, start: Int, limit: Int, replace: Bool) {
        guard let store = metadataStore else { return }
        windowTask?.cancel()
        windowKeyValue = key
        windowQueryKey = query.key
        windowQuery = query
        isWindowLoading = true
        windowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PhotoQuerySummary, [PhotoItem]) in
                let summary = store.summary(query)
                let page = store.page(query, offset: start, limit: limit)
                return (summary, page)
            }.value
            guard let self, !Task.isCancelled, self.windowKeyValue == key else { return }
            self.isWindowLoading = false
            self.windowTotal = result.0.total
            self.windowVideos = result.0.videos
            self.windowStartOffset = start
            self.windowPhotos = replace ? result.1 : self.windowPhotos + result.1
            self.windowRevision &+= 1
            self.hasLoadedWindow = true
            self.prefetchGridThumbnails(self.windowPhotos, newest: replace)
        }
    }

    private func focusWindow(on photoID: UUID, query: PhotoQuery, key: String) {
        guard let store = metadataStore else { return }
        windowTask?.cancel()
        windowKeyValue = key
        windowQueryKey = query.key
        windowQuery = query
        isWindowLoading = true
        let pageSize = Self.windowPageSize
        windowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PhotoQuerySummary, Int, [PhotoItem]) in
                let summary = store.summary(query)
                let index = store.index(of: photoID, in: query) ?? 0
                let start = max(0, min(index - pageSize / 2, max(0, summary.total - pageSize)))
                let page = store.page(query, offset: start, limit: pageSize)
                return (summary, start, page)
            }.value
            guard let self, !Task.isCancelled, self.windowKeyValue == key else { return }
            self.isWindowLoading = false
            self.windowTotal = result.0.total
            self.windowVideos = result.0.videos
            self.windowStartOffset = result.1
            self.windowPhotos = result.2
            self.windowRevision &+= 1
            self.hasLoadedWindow = true
            self.scrollTargetID = photoID
        }
    }

    // MARK: - 系统图库索引窗口

    /// 把当前范围 / 筛选 / 排序 / 搜索翻译成索引查询；拾光的补充元数据（收藏 / 隐藏 / 关键词）作为覆盖条件参与。
    func buildSystemQuery(scope: SystemQueryScope) -> SystemQuery {
        var query = SystemQuery()
        query.scope = scope
        query.filter = photoFilter
        // 直连模式下非日期排序要临时排序整库，百万级图库只保留拍摄 / 添加时间。
        if let index = systemIndex, index.direct != nil, index.trueTotal > 1_000_000,
           sortKey != .capturedAt, sortKey != .addedAt {
            query.sortKey = .capturedAt
        } else {
            query.sortKey = sortKey
        }
        query.ascending = sortAscending
        // 官方相簿沿用图库自己保存的排序（ZGENERICALBUM.ZCUSTOMSORTKEY）：
        // 1 = 显式按日期、2 = 按标题、4 = 手动拖拽顺序；0 表示跟随默认（拍摄日期降序）。
        // 拾光里拖拽过的相簿同样按手动顺序展示，只在该相簿里生效。
        if case .album(let id) = scope, let album = systemAlbum(id: id) {
            let stored = album.customSortKey ?? 0
            if isSystemAlbumManualOrder(id) || stored & 4 != 0 {
                query.manualOrder = true
                query.ascending = true
            } else if sortKey == .capturedAt, stored & 2 != 0 {
                query.sortKey = .title
                query.ascending = album.customSortAscending ?? true
            } else if sortKey == .capturedAt, stored & 1 != 0 {
                query.sortKey = .capturedAt
                query.ascending = album.customSortAscending ?? true
            }
        }
        // 「最近保存 / 最近查看」的截止时间由查询执行时按需取（默认 30 天前）。
        // 不能写进查询：它随当前时间变化，会让 `query.key` 每次都不同，
        // 进而把分页窗口当成「条件变了」反复重置（换页后立刻回到最新一张）。
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parsed = SearchQueryParser.parse(trimmed)
            query.startDate = parsed.startDate
            query.endDate = parsed.endDate
            query.onlyFavorites = parsed.onlyFavorites
            query.onlyVideos = parsed.onlyVideos
            query.onlyPhotos = parsed.onlyPhotos
            query.onlyScreenshots = parsed.onlyScreenshots
            query.onlyLivePhotos = parsed.onlyLivePhotos
            query.onlyEdited = parsed.onlyEdited
            query.tokens = parsed.tokens
            // 直连模式的地名只有二进制归档：把「上海」这类查询换成命中的资产 UUID 并进 SQL。
            if let index = systemIndex, index.direct != nil, !parsed.tokens.isEmpty {
                var placeIDs: [String: [String]] = [:]
                for token in parsed.tokens {
                    let ids = index.directPlaceAssetIDs(matching: token)
                    if !ids.isEmpty { placeIDs[token] = ids }
                }
                query.tokenPlaceIDs = placeIDs.isEmpty ? nil : placeIDs
            }
            // 官方关键词 / 拾光 AI 标签与 OCR 只存在内存索引里，SQL 无从比对：
            // 同样按 token 换算出命中的资产，作为该 token 的 OR 条件并入。
            if !parsed.tokens.isEmpty {
                let native = ensureSystemNativeKeywordsLoaded()
                var keywordIDs: [String: [String]] = [:]
                for token in parsed.tokens {
                    let needle = token.lowercased()
                    var ids = Set<UUID>()
                    for (keyword, assetIDs) in native
                    where keyword.lowercased().contains(needle) {
                        ids.formUnion(assetIDs)
                    }
                    for (photoID, analysis) in systemAnalysisIndex
                    where analysis.searchBlob.contains(needle) {
                        ids.insert(photoID)
                    }
                    if !ids.isEmpty { keywordIDs[token] = ids.map(\.uuidString) }
                }
                query.tokenKeywordIDs = keywordIDs.isEmpty ? nil : keywordIDs
            }
        }
        if let keyword = keywordFilter, !keyword.isEmpty {
            // 官方图库自带的 ZKEYWORD + 拾光补充关键词取并集，再下推成 UUID 条件。
            var ids = Set(systemOverlays.compactMap { id, overlay in
                (overlay.keywords?.contains(keyword) ?? false) ? id : nil
            })
            if let native = ensureSystemNativeKeywordsLoaded()[keyword] {
                ids.formUnion(native)
            }
            query.overlayKeywordIDs = ids.map(\.uuidString)
        }
        // 地点详情页直接用 `PlaceCluster.photos` 渲染，不再把地点命中的照片 ID 下推成 IN 条件：
        // 那样每次构建查询都要对全部带 GPS 的照片重算聚类键，且残留的 selectedPlace
        // 会把「图库」「相簿」等其它范围过滤成空。
        var favoriteAdds: [String] = []
        var favoriteRemoves: [String] = []
        var hiddenAdds: [String] = []
        var hiddenRemoves: [String] = []
        for (id, overlay) in systemOverlays {
            if let favorite = overlay.isFavorite {
                if favorite { favoriteAdds.append(id.uuidString) } else { favoriteRemoves.append(id.uuidString) }
            }
            if let hidden = overlay.isHidden {
                if hidden { hiddenAdds.append(id.uuidString) } else { hiddenRemoves.append(id.uuidString) }
            }
        }
        query.favoriteAdds = favoriteAdds
        query.favoriteRemoves = favoriteRemoves
        query.hiddenAdds = hiddenAdds
        query.hiddenRemoves = hiddenRemoves
        // 长曝光仍由 PhotoKit 智能相簿给出 ID；电影效果 / 空间媒体由 Photos.sqlite 直接判定，
        // 不再依赖照片权限，也不会因为 PhotoKit 未就绪而被过滤成空集合。
        switch scope {
        case .longExposures:
            query.includeIDs = (photoKitLongExposureIDs ?? Set<UUID>()).map(\.uuidString)
        case .cinematics:
            // 电影效果没有稳定的 Photos.sqlite 字段，集合来自 PhotoKit 智能相簿。
            query.includeIDs = (photoKitCinematicIDs ?? Set<UUID>()).map(\.uuidString)
        default:
            break
        }
        return query
    }

    private func reloadSystemWindowIfNeeded(_ query: SystemQuery) {
        let key = "sys#\(query.key)#\(systemIndexSignature)"
        let sameQuery = query.key == systemWindowQuery?.key
        if let target = scrollTargetID,
           key != systemWindowKey || !systemWindowPhotos.contains(where: { $0.id == target }) {
            focusSystemWindow(on: target, query: query)
            return
        }
        if key == systemWindowKey, hasLoadedSystemWindow, !systemWindowPhotos.isEmpty { return }
        if !sameQuery {
            systemWindowPhotos = []
            systemWindowTotal = 0
            systemWindowVideos = 0
            systemWindowStartRank = 0
            hasLoadedSystemWindow = false
        }
        let limit = sameQuery ? max(Self.windowPageSize, systemWindowPhotos.count) : Self.windowPageSize
        loadSystemWindow(query: query, key: key, start: 0, limit: limit, replace: true)
    }

    private func loadSystemWindow(query: SystemQuery, key: String, start: Int, limit: Int, replace: Bool) {
        guard let index = systemIndex else { return }
        systemWindowTask?.cancel()
        systemWindowKey = key
        systemWindowQuery = query
        isSystemWindowLoading = true
        systemWindowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PhotoQuerySummary, [PhotoItem]) in
                // 接续加载时页查询带着日期上界，`summary` 会变成「上界以内」的数量：
                // 总数只由首屏（整条查询）决定，追加时不再重算。
                let summary = replace ? index.summary(query) : PhotoQuerySummary(total: 0, videos: 0)
                return (summary, index.page(query, offset: start, limit: limit))
            }.value
            guard let self, !Task.isCancelled, self.systemWindowKey == key else { return }
            self.isSystemWindowLoading = false
            if replace {
                self.systemWindowTotal = result.0.total
                self.systemWindowVideos = result.0.videos
            }
            self.systemWindowStart = start
            self.systemWindowStartRank = replace ? 0 : self.systemWindowStartRank
            let mapped = result.1.map { self.applySystemOverlay($0) }
            self.systemWindowPhotos = replace ? mapped : self.systemWindowPhotos + mapped
            self.rememberSystemPhotos(mapped)
            self.systemWindowRevision &+= 1
            self.hasLoadedSystemWindow = true
            self.prefetchGridThumbnails(self.systemWindowPhotos, newest: replace)
        }
    }

    /// 窗口落位后预取头部格子的缩略图：首屏立即可见，继续滚动时也已命中缓存。
    private func prefetchGridThumbnails(_ photos: [PhotoItem], newest: Bool) {
        guard !photos.isEmpty else { return }
        if usesPhotoKitThumbnails {
            // 系统「照片」自己会按窗口预热缩略图，比逐个解 derivative 更接近官方体验。
            let slice = Array(newest ? photos.prefix(160) : photos.suffix(160))
            PhotoKitThumbnailProvider.shared.prefetch(photos: slice,
                                                      maxPixel: ImageLoader.gridQuickPixel)
        } else {
            // 本地 / 外接图库：单批张数按实测磁盘与解码耗时自适应，慢盘上不会一次排太多。
            let cap = min(ImageLoader.prefetchBatchLimit, photos.count)
            let slice = Array(newest ? photos.prefix(cap) : photos.suffix(cap))
            ImageLoader.prefetchGridQuick(for: slice)
        }
    }

    private func focusSystemWindow(on photoID: UUID, query: SystemQuery) {
        guard let index = systemIndex else { return }
        let key = "sys#\(query.key)#\(systemIndexSignature)"
        systemWindowTask?.cancel()
        systemWindowKey = key
        systemWindowQuery = query
        isSystemWindowLoading = true
        let pageSize = Self.windowPageSize
        systemWindowTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PhotoQuerySummary, Int, [PhotoItem]) in
                let summary = index.summary(query)
                // 直连模式没有全局下标：按拍摄时间换算整库排名，再用日期界取一页，避免大 OFFSET。
                if index.direct != nil, query.sortKey == .capturedAt, !query.ascending,
                   let photo = index.photo(id: photoID) {
                    var pageQuery = query
                    pageQuery.endDate = photo.capturedAt.addingTimeInterval(1)
                    let page = index.page(pageQuery, offset: 0, limit: pageSize)
                    let rank = page.first.map { index.timelineRank(of: $0.capturedAt) }
                        ?? index.timelineRank(of: photo.capturedAt)
                    return (summary, rank, page)
                }
                let current = index.index(of: photoID, in: query) ?? 0
                let start = max(0, min(current - pageSize / 2, max(0, summary.total - pageSize)))
                return (summary, start, index.page(query, offset: start, limit: pageSize))
            }.value
            guard let self, !Task.isCancelled, self.systemWindowKey == key else { return }
            self.isSystemWindowLoading = false
            self.systemWindowTotal = result.0.total
            self.systemWindowVideos = result.0.videos
            self.systemWindowStart = result.1
            self.systemWindowStartRank = result.1
            self.systemWindowPhotos = result.2.map { self.applySystemOverlay($0) }
            self.systemWindowRevision &+= 1
            self.hasLoadedSystemWindow = true
            self.scrollTargetID = photoID
        }
    }

    private func reloadSystemOverviewIfNeeded() {
        guard usesSQLOverview, let query = systemTimelineQuery, let index = systemIndex else { return }
        let key = "sys#\(query.key)#\(systemIndexSignature)#\(grouping.rawValue)#\(contentRevision)"
        guard key != overviewKeyValue else { return }
        overviewTask?.cancel()
        overviewKeyValue = key
        isOverviewLoading = true
        let grouping = self.grouping
        overviewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (buckets: [PhotoPeriodBucket], months: [PhotoMonthGroup]) in
                switch grouping {
                case .years:
                    return (index.yearBuckets(query), [])
                case .months:
                    return ([], index.monthGroups(query))
                case .all:
                    return ([], [])
                }
            }.value
            guard let self, !Task.isCancelled, self.overviewKeyValue == key else { return }
            self.isOverviewLoading = false
            if grouping == .years {
                self.yearBuckets = result.buckets
            } else {
                self.monthGroups = result.months
            }
            self.resolvePendingMonthScroll()
        }
    }
}
