import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

/// 系统图库侧边栏计数：一次遍历算完，供徽标与「更多项目」的显示条件共用。
struct SystemSidebarCounts {
    var active = 0
    var hidden = 0
    var trash = 0
    var duplicate = 0
    var recentlySaved = 0
    var imports = 0
    var portrait = 0
    var screenshots = 0
    var totalBytes: Int64 = 0
    var earliest: Date?
    var latest: Date?
}

/// 系统图库「精选集」的汇总快照：数量 + 每类最多 4 张样本。
struct SystemCollectionSnapshot {
    var counts: [String: Int] = [:]
    var samples: [String: [PhotoItem]] = [:]
}

extension LibraryStore {
    // MARK: - System library

    func systemRootFolders() -> [SystemFolderInfo] {
        systemChildFolders(of: nil)
    }

    func systemChildFolders(of parent: Int64?) -> [SystemFolderInfo] {
        systemFolders.filter { $0.parent == parent }
            .sorted { Self.systemSortKey($0) < Self.systemSortKey($1) }
    }

    func systemAlbums(in parent: Int64?) -> [SystemAlbumInfo] {
        systemAlbums.filter { $0.parentFolder == parent }
            .sorted { Self.systemSortKey($0) < Self.systemSortKey($1) }
    }

    /// 文件夹与相簿按图库原始顺序（Photos.sqlite 的 Z_PK）混排，与官方「照片」侧边栏一致。
    /// 大图库有上万个相簿，按父节点一次性分组并缓存；只随相簿结构变化失效，
    /// 扫描时逐批到达的照片不会反复触发重建。
    func systemChildren(of parent: Int64?) -> [SystemSidebarEntry] {
        if systemChildrenCacheRevision != systemStructureRevision {
            var buckets: [Int64: [SystemSidebarEntry]] = [:]
            for folder in systemFolders {
                buckets[folder.parent ?? -1, default: []].append(.folder(folder))
            }
            for album in systemAlbums {
                buckets[album.parentFolder ?? -1, default: []].append(.album(album))
            }
            for key in buckets.keys {
                buckets[key]?.sort { $0.sortIndex < $1.sortIndex }
            }
            systemChildrenBuckets = buckets
            systemChildrenCacheRevision = systemStructureRevision
        }
        return systemChildrenBuckets[parent ?? -1] ?? []
    }

    /// 侧边栏系统树拍平后的一行：文件夹与相簿按图库顺序混排，用层级控制缩进。
    /// id 在拍平时算好一次，避免 `ForEach` 每次重建 body 都为上万行重复拼字符串。
    struct SystemFlatRow: Identifiable {
        let entry: SystemSidebarEntry
        let level: Int
        let id: String
    }

    /// 把系统树按当前展开状态拍平成单层数组。
    /// 侧边栏把它直接喂给最外层 `LazyVStack`：展开几千个相簿也只创建可见行，
    /// 不会再因为嵌套懒加载容器把整棵子树一次性实例化。
    func systemFlatRows(expanded: Set<Int64>, expansionRevision: Int) -> [SystemFlatRow] {
        let key = "\(systemStructureRevision)#\(expansionRevision)"
        if key == systemFlatRowsCacheKey { return systemFlatRowsCache }
        var rows: [SystemFlatRow] = []
        func walk(_ parent: Int64?, _ level: Int) {
            for entry in systemChildren(of: parent) {
                rows.append(SystemFlatRow(entry: entry, level: level, id: entry.id))
                if case .folder(let folder) = entry, expanded.contains(folder.id) {
                    walk(folder.id, level + 1)
                }
            }
        }
        walk(nil, 0)
        systemFlatRowsCacheKey = key
        systemFlatRowsCache = rows
        return rows
    }

    /// 侧边栏徽标用的有效项目数（不含已删除与隐藏），按内容版本缓存。
    var systemActivePhotoCount: Int {
        systemSidebarCounts.active
    }

    /// 精选集卡片（后台版）：7 个分类各取 4 张样本，稀有分类会扫描一段日期索引，
    /// 放到后台执行，避免首次打开精选集卡住主线程。
    func systemCollectionSnapshotAsync() async -> SystemCollectionSnapshot {
        guard let index = systemIndex else { return systemCollectionSnapshot() }
        let scopes: [(String, SystemQueryScope)] = [
            ("favorites", .favorites), ("videos", .videos), ("selfies", .selfies),
            ("panoramas", .panoramas), ("screenshots", .screenshots),
            ("recentlySaved", .recentlySaved), ("edited", .edited)
        ]
        var queries: [(String, SystemQuery)] = []
        for (key, scope) in scopes {
            var query = buildSystemQuery(scope: scope)
            query.filter = .all
            query.tokens = []
            query.overlayKeywordIDs = nil
            query.includeIDs = nil
            queries.append((key, query))
        }
        let pairs = await Task.detached(priority: .userInitiated) {
            queries.map { (key, query) in
                (key, index.summary(query).total, index.page(query, offset: 0, limit: 4))
            }
        }.value
        var result = SystemCollectionSnapshot()
        for (key, count, photos) in pairs {
            result.counts[key] = count
            result.samples[key] = photos.map { applySystemOverlay($0) }
        }
        return result
    }

    /// 系统图库「精选集」：索引模式按分类各取 4 张样本，不遍历整库。
    func systemCollectionSnapshot() -> SystemCollectionSnapshot {
        var result = SystemCollectionSnapshot()
        if let index = systemIndex {
            let scopes: [(String, SystemQueryScope)] = [
                ("favorites", .favorites), ("videos", .videos), ("selfies", .selfies),
                ("panoramas", .panoramas), ("screenshots", .screenshots),
                ("recentlySaved", .recentlySaved), ("edited", .edited)
            ]
            for (key, scope) in scopes {
                var query = buildSystemQuery(scope: scope)
                query.filter = .all
                query.tokens = []
                query.overlayKeywordIDs = nil
                query.includeIDs = nil
                result.counts[key] = index.summary(query).total
                result.samples[key] = index.page(query, offset: 0, limit: 4).map { applySystemOverlay($0) }
            }
            return result
        }
        for photo in systemPhotos {
            guard photo.deletedAt == nil, !photo.isHidden else { continue }
            func add(_ key: String) {
                result.counts[key, default: 0] += 1
                if (result.samples[key]?.count ?? 0) < 4 {
                    result.samples[key, default: []].append(photo)
                }
            }
            if photo.isFavorite { add("favorites") }
            if photo.isVideo { add("videos") }
            if !photo.isVideo, photo.kind == .selfie { add("selfies") }
            if photo.kind == .panorama { add("panoramas") }
            if photo.kind == .screenshot { add("screenshots") }
            if photo.addedAt >= Self.recentlySavedCutoff { add("recentlySaved") }
            if !photo.isVideo, photo.editedAt != nil || photo.hasEdits { add("edited") }
        }
        return result
    }

    /// 系统图库侧边栏计数：一次遍历算完所有徽标，避免每个计数各扫一遍 20 万张照片。
    var systemSidebarCounts: SystemSidebarCounts {
        if systemCountsCacheRevision == contentRevision, let cached = systemCountsCache {
            return cached
        }
        // 索引模式：一次 SQL 聚合，不遍历整库。
        if let index = systemIndex {
            let raw = index.counts(overrides: buildSystemQuery(scope: .all))
            var counts = SystemSidebarCounts()
            counts.active = raw.active
            counts.hidden = raw.hidden
            counts.trash = raw.trash
            counts.duplicate = raw.duplicate
            counts.recentlySaved = raw.recentlySaved
            counts.imports = raw.imports
            counts.portrait = raw.portrait
            counts.screenshots = raw.screenshots
            counts.totalBytes = raw.totalBytes
            counts.earliest = raw.earliest
            counts.latest = raw.latest
            systemCountsCache = counts
            systemCountsCacheRevision = contentRevision
            return counts
        }
        var counts = SystemSidebarCounts()
        let cutoff = Self.recentlySavedCutoff
        for photo in systemPhotos {
            guard photo.deletedAt == nil else {
                counts.trash += 1
                continue
            }
            counts.totalBytes += photo.fileSize
            counts.earliest = min(counts.earliest ?? photo.capturedAt, photo.capturedAt)
            counts.latest = max(counts.latest ?? photo.capturedAt, photo.capturedAt)
            if photo.isHidden {
                counts.hidden += 1
                continue
            }
            counts.active += 1
            if photo.isDuplicateItem { counts.duplicate += 1 }
            if photo.addedAt >= cutoff { counts.recentlySaved += 1 }
            if photo.isDeviceImport { counts.imports += 1 }
            if photo.isPortraitCapture { counts.portrait += 1 }
            if photo.kind == .screenshot { counts.screenshots += 1 }
        }
        systemCountsCache = counts
        systemCountsCacheRevision = contentRevision
        return counts
    }

    // MARK: - 系统图库重复项目

    /// 系统图库的重复组（由后台算好）。打开重复页时先调用
    /// `loadSystemDuplicateGroupsIfNeeded()`，计算结果到达前返回上一次的缓存。
    var systemDuplicateGroups: [DuplicateGroup] { systemDuplicateGroupsCache }

    /// 缓存失效：清空版本号并通知界面在后台重算。
    func invalidateSystemDuplicateGroups() {
        systemDuplicateGroupsCacheKey = nil
        systemDuplicateGroupsToken &+= 1
    }

    /// 后台计算系统图库重复分组：三万多条重复标记的查询、解码与归组都不占用主线程，
    /// 界面先显示进度，完成后一次性刷新。结果按内容版本缓存，重复打开直接复用。
    func loadSystemDuplicateGroupsIfNeeded() {
        guard systemDuplicateGroupsTask == nil else { return }
        let key = "\(contentRevision)"
        if systemDuplicateGroupsCacheKey == key { return }
        guard let index = systemIndex else {
            // 小库只有内存快照，直接在调用线程算完。
            let source = systemPhotos.map { applySystemOverlay($0) }
            systemDuplicateGroupsCache = DuplicateDetector.groups(from: source, mergeFlagged: true)
            systemDuplicateGroupsCacheKey = key
            return
        }
        let revision = contentRevision
        let overlays = isNativeContainer ? systemOverlays : [:]
        isLoadingSystemDuplicates = true
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(systemLibraryPath ?? LibraryPaths.root.standardizedFileURL.path),
                      kind: .index,
                      title: "计算重复分组",
                      isCancellable: false)
        )
        systemDuplicateGroupsTask = Task.detached(priority: .userInitiated) { [weak self, index, overlays, key] in
            let photos = index.duplicatePhotos().map { photo in
                Self.applyAssetOverlay(overlays[photo.id], to: photo)
            }
            let groups = DuplicateDetector.groups(from: photos, mergeFlagged: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.systemDuplicateGroupsTask = nil
                self.isLoadingSystemDuplicates = false
                self.finishSourceJob(jobID, message: "重复分组已更新")
                guard self.contentRevision == revision else {
                    // 计算期间图库内容变了：丢弃结果，按最新内容重算。
                    self.loadSystemDuplicateGroupsIfNeeded()
                    return
                }
                self.systemDuplicateGroupsCacheKey = key
                self.systemDuplicateGroupsCache = groups
            }
        }
    }

    /// 官方图库只读：拾光的「合并」是隐藏其余副本（写补充元数据，可撤销），不删除 Apple 的照片。
    @discardableResult
    func hideSystemDuplicateCopies(_ group: DuplicateGroup, keeping keepID: UUID) -> Int {
        guard canEditNativeOverlay else { return 0 }
        let ids = Set(group.photos.map(\.id)).subtracting([keepID])
        guard !ids.isEmpty else { return 0 }
        setSystemHidden(true, ids: ids)
        invalidateSystemDuplicateGroups()
        showToast("已隐藏 \(ids.count) 个副本，可在「已隐藏」中恢复")
        return ids.count
    }

    /// 隐藏全部重复组里的多余副本，每组保留推荐版本。
    @discardableResult
    func hideAllSystemDuplicateCopies() -> (groups: Int, hidden: Int) {
        guard canEditNativeOverlay else { return (0, 0) }
        var groupCount = 0
        var hidden = 0
        for group in systemDuplicateGroups {
            let ids = Set(group.photos.map(\.id)).subtracting([group.keepID])
            guard !ids.isEmpty else { continue }
            setSystemHidden(true, ids: ids)
            groupCount += 1
            hidden += ids.count
        }
        guard hidden > 0 else { return (0, 0) }
        invalidateSystemDuplicateGroups()
        showToast("已隐藏 \(groupCount) 组重复项目中的 \(hidden) 个副本")
        return (groupCount, hidden)
    }

    /// 把重复组的保留版本拷贝一份到拾光，官方图库本身保持只读。
    func importSystemDuplicateKeep(_ group: DuplicateGroup) {
        importSystemPhotos([group.pick.photo], albumName: "重复项目")
    }

    /// 把单张系统图库照片拷贝到拾光（只读来源的导出出口）。
    func importSystemPhotoToLibrary(_ photo: PhotoItem) {
        guard photo.isSystem else { return }
        importSystemPhotos([photo], albumName: nil)
    }

    /// 原始顺序缺失（旧缓存或异常数据）时退回主键，保证排序稳定。
    private static func systemSortKey(_ folder: SystemFolderInfo) -> Int64 {
        folder.sortIndex != 0 ? folder.sortIndex : folder.id
    }

    private static func systemSortKey(_ album: SystemAlbumInfo) -> Int64 {
        album.sortIndex != 0 ? album.sortIndex : album.id
    }

    func systemPhoto(id: UUID) -> PhotoItem? {
        if let item = systemPhotoIndex[id] { return item }
        // 窗口里刚出现过的照片走内存，避免 body 求值时同步查 Photos.sqlite。
        if let recent = systemRecentPhotos[id] { return recent }
        guard let index = systemIndex else { return nil }
        return index.photo(id: id).map { applySystemOverlay($0) }
    }

    /// 把已加载窗口里的照片记进内存（有上限），供 body 里的高频读取使用。
    func rememberSystemPhotos(_ photos: [PhotoItem]) {
        guard !photos.isEmpty else { return }
        if systemRecentPhotos.count + photos.count > 4_000 {
            systemRecentPhotos.removeAll(keepingCapacity: true)
        }
        for item in photos { systemRecentPhotos[item.id] = item }
    }

    func anyPhoto(id: UUID) -> PhotoItem? {
        photos.first(where: { $0.id == id })
            ?? systemPhoto(id: id)
            ?? cloudPhotos.first(where: { $0.id == id })
    }

    /// 该 ID 是否属于当前系统图库（可能只在索引里，尚未加载进内存窗口）。
    func isSystemPhotoID(_ id: UUID) -> Bool {
        if systemPhotoIndex[id] != nil { return true }
        if systemOverlays[id] != nil { return true }
        return systemIndex?.photo(id: id) != nil
    }

    func presentSystemLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "连接"
        panel.message = "连接后可在侧边栏切换；只记录连接地址，不会改变 App 自己的图库位置。同一个图库不会重复登记。"
        if panel.runModal() == .OK, let url = panel.url {
            // 「自己外接自己」不产生第二条连接：当前图库本身不能重复登记。
            if isContainerNativeLibraryPath(url.standardizedFileURL.path) {
                showToast("这就是当前图库本身，不需要重复连接")
                return
            }
            connectSystemLibrary(url)
        }
    }

    /// 选择要打开 / 切换的 App 图库（会真正切换本地库位置）。
    func presentLibraryContainerPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要打开或切换的 .photoslibrary 图库"
        if panel.runModal() == .OK, let url = panel.url {
            // 接入的图库记进当前图库自己的数据：切走之后，本图库的「图库」分区仍保留这条记录。
            if LibraryPaths.isLibraryContainer(url) {
                registerKnownLibrary(url)
            }
            activateLibrary(url)
        }
    }

    @discardableResult
    func createLibrary(at url: URL, migratingLocalData: Bool = false) async -> Bool {
        guard LibraryPaths.createLibrary(at: url) else {
            showToast("无法创建照片图库（目标位置已存在同名项目）")
            return false
        }
        // 与切换一致：切库成功后再释放当前库，创建 / 切换失败时不留空壳。
        // 迁入旧数据可能在几十 GB 级别，切换过程把大块复制放到后台执行。
        guard await LibraryPaths.switchContainerAsync(to: url, migratingLocalData: migratingLocalData) else {
            showToast("无法创建照片图库（目标位置不可写）")
            return false
        }
        flushMetadata()
        metadataStore = nil
        // 新图库的快照目录与修订号都要重新建立。
        resetSourceContentCache()
        resetInMemoryCachesForLibrarySwitch()
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexComplete = true
        metadataStore = try? MetadataStore(url: LibraryPaths.metadataFile)
        // 新图库是空白库：不继承其它图库的历史，「图库」分区里只记它自己。
        // 这份记录写在新图库自己的设置里，换库时各自独立。
        knownLibraries = [SystemLibraryRef(
            path: url.standardizedFileURL.path,
            name: url.deletingPathExtension().lastPathComponent)]
        persistKnownLibraries()
        // 新库还没有自己的主题时，把向导里选好的外观 / 强调色写进去。
        AppSettings.shared.seedThemeForCurrentLibraryIfNeeded()
        resetFaceClusterState()
        let data = metadataStore?.loadLibrary() ?? LibraryData()
        photos = data.photos
        albums = data.albums
        folders = data.folders
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        similarScope = nil
        abortHealthScan()
        healthReport = nil
        selection.removeAll()
        viewerID = nil
        editorID = nil
        // 新图库从零开始：网络资源也读这个新库自己的配置（通常是空的）。
        finishCatalogPlayback()
        catalogModel.loadForCurrentLibrary()
        // 新图库是全新的：上一个图库的连接、网盘与库级设置都不能带进来。
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        reloadPerLibraryState()
        navigate(to: .library)
        rememberLibrary(url)
        showLibraryPicker = false
        showNewLibrarySheet = false
        libraryPickerOnLaunch = false
        needsLibrarySetup = false
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        showToast("已创建 \(url.lastPathComponent)")
        return true
    }

    func resetSystemLibraryState() {
        systemLibraryPath = nil
        systemLibraryName = nil
        systemPhotos = []
        systemAlbums = []
        systemFolders = []
        systemPeople = []
        systemPhotoIndex = [:]
        systemAlbumIndex = [:]
        systemOverlays = [:]
        systemTotalAssetCount = 0
        systemLibraryError = nil
        systemLibraryLoadedPath = nil
        systemIndex = nil
        systemIndexSignature = ""
        systemNativeKeywordIndex = nil
        systemNativeKeywordIDMap = [:]
        photoKitLongExposureIDs = nil
        photoKitCinematicIDs = nil
        isPhotoKitMediaTypeLoaded = false
        systemIndexReady = false
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        systemGeoCacheKey = nil
        systemGeoCache = []
        viewerStripKey = nil
        viewerStrip = []
        // 识别结果只属于当前系统图库，断开或换库时一并清空并取消进行中的识别。
        systemAnalysisTask?.cancel()
        systemAnalysisTask = nil
        systemAnalysisCancelled = false
        systemAnalysisAutoResume = false
        systemAnalysisIndex = [:]
        isAnalyzingSystemContent = false
        systemAnalysisDone = 0
        systemAnalysisTotal = 0
        systemFeatures = [:]
        healthReport = nil
        healthReportScopeTag = nil
        similarScope = nil
        clearSystemWindow()
    }

    /// 清空系统图库的分页窗口（换库、重建索引、切换系统图库时调用）。
    func clearSystemWindow() {
        systemWindowTask?.cancel()
        systemWindowTask = nil
        systemWindowPhotos = []
        systemRecentPhotos.removeAll(keepingCapacity: false)
        systemWindowTotal = 0
        systemWindowVideos = 0
        systemWindowKey = ""
        systemWindowStart = 0
        systemWindowQuery = nil
        hasLoadedSystemWindow = false
        isSystemWindowLoading = false
        systemWindowRevision &+= 1
    }

    /// App 内的「新建图库」：先打开创建向导（名称 / 位置 / 能力 / 库级设置），
    /// 用户确认后才真正建库，不会点一下就凭空多出一个空图库。
    func beginNewLibraryFlow() {
        showNewLibrarySheet = true
    }

    /// 换库时作废只属于上一个图库的内存缓存：缩略图 / 海报解码结果、网络影院的列表与资料。
    /// 磁盘快照、SQLite 与缓存目录都在各自图库内部，换库后由上层重新读取，不在这里删文件。
    func resetInMemoryCachesForLibrarySwitch() {
        ImageLoader.clearMemoryCaches()
        CatalogArtworkMemory.shared.removeAll()
        tvModel.clearImageCaches()
        networkCinemaModel.resetForLibrarySwitch()
    }

    /// 选位置 → 建库。返回是否真的建好，调用方据此决定要不要关掉建库向导。
    @discardableResult
    func presentNewLibraryPanel(migratingLocalData: Bool = false) async -> Bool {
        let panel = NSSavePanel()
        panel.title = "新建图库"
        panel.message = "将创建一个与官方同款的 .photoslibrary 图库包（database / originals / resources）"
        panel.prompt = "创建"
        panel.nameFieldStringValue = "未命名.photoslibrary"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        let url = selected.pathExtension.lowercased() == "photoslibrary"
            ? selected
            : selected.appendingPathExtension("photoslibrary")
        let created = await createLibrary(at: url, migratingLocalData: migratingLocalData)
        if !created {
            // 建库向导仍盖在主窗口上，Toast 会被挡住：用系统弹窗把失败原因说清楚。
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法创建照片图库"
            alert.informativeText = FileManager.default.fileExists(atPath: url.path)
                ? "这个位置已经有同名图库，或目标文件夹不可写。换个名称 / 位置再试。"
                : "请确认目标文件夹可写，然后重试。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        return created
    }

    /// 切换 App 自己的图库位置（会迁移/打开本地库）。
    func switchLibraryContainer(_ url: URL) {
        guard LibraryPaths.isLibraryContainer(url) else {
            showToast("请选择有效的 .photoslibrary 图库")
            return
        }

        let sameContainer = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
            == url.standardizedFileURL.path
        // 已经在用这个图库：只把界面切回它，不重放换库清理。
        // 撤销栈、回收站清理、缩略图预热都属于「换库」，重复选当前库不该丢现场。
        if sameContainer {
            showNewLibrarySheet = false
            showLibraryPicker = false
            libraryPickerOnLaunch = false
            containerLibraryPath = LibraryPaths.containerLibraryURL?.path
            needsLibrarySetup = LibraryPaths.requiresLibrarySetup
            rememberLibrary(url)
            if LibraryPaths.isNativeLibrary(url) {
                // 已加载就直接切回它的页面，未加载才扫描（不会重复重扫）。
                connectSystemLibrary(url)
            } else {
                navigate(to: .library)
            }
            return
        }

        // 先把目标图库切过去，成功后再放手当前库的数据库：
        // 切换失败（不存在 / 只读 / 无权限）时当前图库必须原样可用。
        guard LibraryPaths.switchContainer(to: url, migratingLocalData: false) else {
            showToast("无法切换照片图库：请确认这个图库可写")
            return
        }
        flushMetadata()
        metadataStore = nil
        // 快照与修订号跟着图库走。
        resetSourceContentCache()
        resetInMemoryCachesForLibrarySwitch()
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexComplete = true
        metadataStore = try? MetadataStore(url: LibraryPaths.metadataFile)
        resetFaceClusterState()
        let data = metadataStore?.loadLibrary() ?? LibraryData()
        photos = data.photos
        albums = data.albums
        folders = data.folders
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        similarScope = nil
        abortHealthScan()
        healthReport = nil
        selection.removeAll()
        viewerID = nil
        editorID = nil
        // 网络资源跟着图库走：换库后重新读取新图库自己的源、片单与日历。
        finishCatalogPlayback()
        catalogModel.loadForCurrentLibrary()
        redirectCinemaSidebarItemIfNeeded()

        needsLibrarySetup = LibraryPaths.requiresLibrarySetup
        rememberLibrary(url)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        containerLibraryPath = LibraryPaths.containerLibraryURL?.path
        showToast("已打开 \(url.deletingPathExtension().lastPathComponent)")

        guard LibraryPaths.isNativeLibrary(url) else {
            // 打开哪个图库就用哪个图库自己的连接、网盘与设置。
            resetCloudStateForLibrarySwitch()
            resetSystemLibraryState()
            // 「系统图库」这一分区跟着图库走：恢复该图库自己记住的连接（可能没有）。
            systemLibraryPath = metadataStore?.setting("system_library_path")
            if let path = systemLibraryPath {
                systemLibraryName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            }
            reloadPerLibraryState()
            navigate(to: .library)
            return
        }

        // 当前图库就是官方「照片」图库：它直接作为主侧边栏展示，不再登记成「连接的系统图库」。
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        systemLibraryPath = url.path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", url.path)
        reloadPerLibraryState()
        // 走统一入口：官方图库会先申请照片访问授权，再开始扫描，避免扫到一半被打断。
        loadSystemLibraryIfNeeded(.systemLibrary)
        navigate(to: .systemLibrary)
    }

    /// 只记录 / 连接系统「照片」图库，绝不改变 App 自己的图库位置。
    /// - Parameter forceRefresh: 「重新读取」时传 true，忽略已加载缓存并重建索引。
    func connectSystemLibrary(_ url: URL, forceRefresh: Bool = false) {
        guard LibraryPaths.isLibraryContainer(url) else {
            showToast("请选择有效的 .photoslibrary 图库")
            return
        }
        guard LibraryPaths.isNativeLibrary(url) else {
            showToast("这不是系统「照片」图库；如需切换 App 图库，请使用「切换图库…」")
            return
        }

        let path = url.standardizedFileURL.path
        let isSelf = isContainerNativeLibraryPath(path)

        // 已经在浏览同一个系统图库：只切回该页面，不重复扫描，避免来回切换。
        if !forceRefresh,
           let current = systemLibraryPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }),
           current == path,
           let loaded = systemLibraryLoadedPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }),
           loaded == path,
           !isLoadingSystemLibrary {
            showLibraryPicker = false
            libraryPickerOnLaunch = false
            if !isSystemScope { navigate(to: .systemLibrary) }
            return
        }

        // 换的是另一个系统图库：上一个库的识别结果 / 窗口 / 计数都属于旧库，全部作废。
        if let current = systemLibraryPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }),
           current != path {
            resetSystemLibraryState()
        }

        systemLibraryPath = path
        systemLibraryName = url.deletingPathExtension().lastPathComponent
        systemLibraryError = nil
        metadataStore?.setSetting("system_library_path", path)
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        if isSelf {
            // 「自己外接自己」不算连接：当前 App 图库只保留在「图库」里，不登记成第二个条目。
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, path) }
            persistSystemLibraries(systemLibraries)
        } else {
            registerSystemLibrary(URL(fileURLWithPath: path))
        }
        if forceRefresh {
            loadSystemLibrary(at: URL(fileURLWithPath: path), informOnFailure: true, forceRefresh: true)
        } else {
            // 统一走授权 / 已加载判断：官方图库首次打开会先申请照片访问授权。
            loadSystemLibraryIfNeeded(.systemLibrary)
        }
        navigate(to: .systemLibrary)
    }

    func openContainerInPhotos() {
        guard LibraryPaths.containerLibraryURL != nil else {
            showToast("请先连接一个照片图库")
            return
        }
        LibraryPaths.openContainerInPhotos()
    }

    var containerLibraryName: String? {
        LibraryPaths.containerLibraryURL?.lastPathComponent
    }

    var storageLocationDescription: String? {
        guard LibraryPaths.containerLibraryURL != nil else { return nil }
        return LibraryPaths.root.path
    }

    var hasContainerLibrary: Bool {
        LibraryPaths.containerLibraryURL != nil
    }

    /// 切换 / 新建图库后，把「只属于当前图库」的数据与设置整体换一遍：
    /// 图库级设置、视图状态、系统图库连接、网盘挂载与收藏、最近删除清理。
    func reloadPerLibraryState() {
        // 换库时停止上一个图库的缩略图预热，避免把缓存写进新库。
        thumbnailPrewarmTask?.cancel()
        thumbnailPrewarmTask = nil
        // 命名 / 新建相簿这类弹窗带着上一个图库的 ID，换库后必须关掉，不能让它操作新库。
        namePrompt = nil
        showNewAlbumSheet = false
        AppSettings.shared.reloadLibraryScopedValues()
        loadViewPreferences()
        loadCloudFavorites()
        loadCloudKeywords()
        loadCloudMarks()
        loadCloudMounts()
        cinemaIndexes = [:]
        loadCinemaIndexes()
        migrateLegacyCinemaIndexIfNeeded()
        loadAIState()
        loadSystemLibraries()
        loadKnownLibraries()
        loadSystemManualOrderAlbums()
        // 网络电视源与顺序写在各自图库里，换库后要重新读。
        tvModel.reloadForCurrentLibrary()
        purgeExpiredTrashIfNeeded()
        // 美化推荐是派生结果，换库后必须清空，避免把上一个图库的照片带过来。
        resetBeautyState()
        // 体检结果与系统图库识别缓存同样只属于上一个图库 / 连接。
        healthTask?.cancel()
        healthTask = nil
        healthReport = nil
        healthReportScopeTag = nil
        isScanningHealth = false
        healthScanProgress = 0
        systemAnalysisIndex = [:]
        systemAnalysisAutoResume = false
        systemFeatures = [:]
        // 换库后 PhotoKit 的写入目标需要重新检测。
        systemWriteTargetState = .unknown
        // 地图页的定位照片 / 地点聚类同样只属于上一个图库。
        resetPlaceCaches()
        // 撤销栈只对记录它的图库有效，换库时一并清空。
        resetUndoHistory()
        // 查重哈希与相似组只属于上一个图库。
        resetHashState()
        vaultProgress = nil
        vaultReport = nil
        vaultBackupPath = nil
        vaultLastBackupDate = nil
        // 删除确认卡片里的 ID 属于上一个图库，换库时必须丢弃。
        resetConfirmationState()
    }

    // MARK: - 图库选择器

    static let recentLibrariesKey = LibraryPaths.recentLibrariesKey

    func presentLibraryPicker() {
        showLibraryPicker = true
    }

    /// 记录用过的图库，供选择器列表使用。
    func rememberLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths.removeLast(paths.count - 10) }
        UserDefaults.standard.set(paths, forKey: Self.recentLibrariesKey)
        // 同时登记到全局图库列表：第一次的那个成为系统默认图库，之后都算挂载图库。
        registerKnownLibrary(url)
    }

    // MARK: - 系统图库列表

    /// 归一化路径：只差尾部斜杠 / 相对写法的同一个图库必须视为同一条记录。
    func isSameSystemLibraryPath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    /// 当前 App 图库本身就是官方「照片」图库时的自身路径；不是这种图库则返回 nil。
    var containerNativeLibraryPath: String? {
        guard let url = LibraryPaths.containerLibraryURL,
              LibraryPaths.isNativeLibrary(url) else { return nil }
        return url.standardizedFileURL.path
    }

    func isContainerNativeLibraryPath(_ path: String) -> Bool {
        guard let selfPath = containerNativeLibraryPath else { return false }
        return isSameSystemLibraryPath(path, selfPath)
    }

    /// 正在浏览的系统图库就是 App 自己的图库（而不是外接的第二个库）。
    var isBrowsingContainerSystemLibrary: Bool {
        guard let path = systemLibraryPath else { return false }
        return isContainerNativeLibraryPath(path)
    }

    /// 绑定关系（打开过的图库 / 已连接的照片图库）只写在**当前图库自己的** SQLite settings 里。
    /// 断开 = 从当前图库的记录里删掉，下次打开这个图库就不会再出现。
    private static let connectedLibrariesSettingKey = "system_libraries"
    private static let knownLibrariesSettingKey = "known_libraries"

    /// 旧版本把这两份记录放在全局偏好里：只做一次性迁移，迁完立即删除。
    /// 否则断开的图库下次启动又会被旧数据拉回来。
    private static let legacyConnectedLibrariesKey = "settings.systemLibraries"
    private static let legacyGlobalConnectedLibrariesKey = "settings.systemLibraries.global"
    private static let legacyKnownLibrariesKey = LibraryPaths.knownLibrariesKey

    /// 读当前图库自己的记录；当前图库还没有这份记录时，把旧版全局数据迁进来一次。
    private func storedBindings(_ settingKey: String,
                                legacyKeys: [String]) -> [SystemLibraryRef]? {
        if let json = metadataStore?.setting(settingKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SystemLibraryRef].self, from: data) {
            return decoded
        }
        for key in legacyKeys {
            // 当前图库没打开时不迁移：没有可写入的库，迁完就丢了。
            guard metadataStore != nil else { return nil }
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([SystemLibraryRef].self, from: data) else { continue }
            UserDefaults.standard.removeObject(forKey: key)
            return decoded
        }
        return nil
    }

    private func persistBindings(_ list: [SystemLibraryRef], settingKey: String) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        // 当前图库没打开（建库 / 打开引导页）时没有可写的库，交给下次打开时重建。
        metadataStore?.setSetting(settingKey, json)
    }

    /// 读取**当前图库**自己的系统图库连接列表；同一时间只有一个处于连接/展开状态。
    func loadSystemLibraries() {
        var list = storedBindings(Self.connectedLibrariesSettingKey,
                                  legacyKeys: [Self.legacyGlobalConnectedLibrariesKey,
                                               Self.legacyConnectedLibrariesKey]) ?? []
        // 列表可保存多个图库，按归一化路径去重。上限放宽到 50。
        var seen: Set<String> = []
        list = list.filter {
            seen.insert(URL(fileURLWithPath: $0.path).standardizedFileURL.path).inserted
        }
        if list.count > 50 { list.removeLast(list.count - 50) }
        // 当前图库本身是官方「照片」图库时，它的内容是主侧边栏，不登记成额外连接。
        if let nativeSelfPath = containerNativeLibraryPath {
            list.removeAll { isSameSystemLibraryPath($0.path, nativeSelfPath) }
        }
        if let path = systemLibraryPath,
           !isContainerNativeLibraryPath(path),
           !list.contains(where: { isSameSystemLibraryPath($0.path, path) }) {
            list.insert(SystemLibraryRef(path: path,
                                         name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                        at: 0)
        }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    func persistSystemLibraries(_ list: [SystemLibraryRef]) {
        persistBindings(list, settingKey: Self.connectedLibrariesSettingKey)
    }

    // MARK: - 全部图库（默认 + 挂载）

    /// 所有打开过的图库：第一条是系统默认图库，其余都是挂载图库。
    /// 记录写在当前图库自己的 settings 里：断开即删除，下次打开这个图库不再出现。
    /// - Parameter inheritRecentIfEmpty: 没有打开任何图库（启动引导页）时，允许用「最近打开」兜底，
    ///   让「创建或打开图库」界面能列出历史库；图库内部的调用一律不继承。
    func loadKnownLibraries(inheritRecentIfEmpty: Bool = false) {
        let stored = storedBindings(Self.knownLibrariesSettingKey,
                                    legacyKeys: [Self.legacyKnownLibrariesKey])
        var list = stored ?? []
        // 当前图库还没有这份记录（首次升级）：用「最近打开」恢复一次，之后以图库记录为准。
        // 空白图库不参与迁移：那是刚建的新库，不该继承别的图库的历史。
        let hasContent = !photos.isEmpty || !albums.isEmpty || !folders.isEmpty
        if stored == nil, hasContent || inheritRecentIfEmpty,
           let recent = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) {
            list = recent.reversed().compactMap { path in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return SystemLibraryRef(
                    path: path,
                    name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            }
        }
        var seen: Set<String> = []
        list = list.filter {
            seen.insert(URL(fileURLWithPath: $0.path).standardizedFileURL.path).inserted
        }
        // 当前图库必须在列表里：首次升级 / 首次打开时用它兜底。
        if let current = LibraryPaths.containerLibraryURL?.standardizedFileURL.path,
           !list.contains(where: { isSameSystemLibraryPath($0.path, current) }) {
            list.append(SystemLibraryRef(
                path: current,
                name: URL(fileURLWithPath: current).deletingPathExtension().lastPathComponent))
        }
        knownLibraries = list
        // 「默认」= 下次启动会打开的那个库：显式默认优先，否则就是上次打开的库。
        let explicit = UserDefaults.standard.bool(forKey: LibraryPaths.defaultLibraryExplicitKey)
        let saved = UserDefaults.standard.string(forKey: LibraryPaths.defaultLibraryKey)
        if explicit, let saved, list.contains(where: { isSameSystemLibraryPath($0.path, saved) }) {
            defaultLibraryPath = saved
        } else if let last = LibraryPaths.lastOpenedLibraryURL(),
                  list.contains(where: { isSameSystemLibraryPath($0.path, last.path) }) {
            defaultLibraryPath = last.path
        } else {
            defaultLibraryPath = nil
        }
        persistKnownLibraries()
    }

    func persistKnownLibraries() {
        persistBindings(knownLibraries, settingKey: Self.knownLibrariesSettingKey)
    }

    /// 记录一个打开过的图库：首次打开的那个自动成为系统默认图库，之后只追加挂载图库。
    func registerKnownLibrary(_ url: URL) {
        // 首次运行时先从旧记录恢复历史图库，默认图库才不会错认成刚打开的这一个。
        if knownLibraries.isEmpty { loadKnownLibraries() }
        let path = url.standardizedFileURL.path
        if !knownLibraries.contains(where: { isSameSystemLibraryPath($0.path, path) }) {
            knownLibraries.append(SystemLibraryRef(
                path: path,
                name: url.deletingPathExtension().lastPathComponent))
        }
        persistKnownLibraries()
    }

    /// 某个路径是不是启动图库：显式默认优先，其次是上次打开的图库。
    /// 它代表「下次启动会打开哪个库」，界面上的「默认」标记以它为准。
    func isDefaultLibrary(_ path: String) -> Bool {
        guard let url = LibraryPaths.storedDefaultLibrary() ?? LibraryPaths.lastOpenedLibraryURL() else {
            return false
        }
        return isSameSystemLibraryPath(path, url.path)
    }

    /// 是否用户显式设置的默认图库（与「上次打开」区分，用于文案与移除保护）。
    func isExplicitDefaultLibrary(_ path: String) -> Bool {
        guard let url = LibraryPaths.storedDefaultLibrary() else { return false }
        return isSameSystemLibraryPath(path, url.path)
    }

    /// 把某个图库设为默认：下次启动直接打开它，并排到全部图库的第一位。
    /// 这里会点亮「用户显式设置」标记，旧版本自动挑出来的默认值不会改变启动行为。
    func setDefaultLibrary(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              LibraryPaths.isLibraryContainer(url) else {
            showToast("找不到这个图库，可能已被移动或删除")
            return
        }
        let normalized = url.path
        defaultLibraryPath = normalized
        LibraryPaths.setStoredDefaultLibrary(url)
        if let index = knownLibraries.firstIndex(where: { isSameSystemLibraryPath($0.path, normalized) }) {
            let item = knownLibraries.remove(at: index)
            knownLibraries.insert(item, at: 0)
            persistKnownLibraries()
        } else {
            registerKnownLibrary(url)
        }
        let name = url.deletingPathExtension().lastPathComponent
        showToast("「\(name)」已设为默认图库，下次启动直接打开")
    }

    /// 断开一个图库：从「全部图库」、最近打开与默认图库记录里移除。
    /// 如果它正是当前打开的图库，同时释放容器并回到「创建或打开图库」界面；
    /// 磁盘上的图库包与照片一律保留，之后可以重新打开。
    func disconnectLibrary(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let name = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        let isCurrent = LibraryPaths.containerLibraryURL.map {
            isSameSystemLibraryPath($0.path, normalized)
        } ?? false

        removeLibraryBindings(normalized)
        if let active = systemLibraryPath, isSameSystemLibraryPath(active, normalized) {
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }

        if isCurrent {
            releaseCurrentLibraryForDetach()
        }
        loadKnownLibraries()
        showToast("已断开「\(name)」，磁盘上的图库文件仍保留")
    }

    /// 从一个图库里删掉另一个图库的绑定：打开过的列表、已连接的照片图库、最近打开，
    /// 以及默认图库 / 下次启动引导，全部一起清理，避免它从别处再冒出来。
    private func removeLibraryBindings(_ normalized: String) {
        knownLibraries.removeAll { isSameSystemLibraryPath($0.path, normalized) }
        if systemLibraries.contains(where: { isSameSystemLibraryPath($0.path, normalized) }) {
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, normalized) }
            persistSystemLibraries(systemLibraries)
        }
        // 选择器的数据源包含「最近打开」：断开时必须一起清掉，否则它还会出现在选取图库里。
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? []
        recent.removeAll { isSameSystemLibraryPath($0, normalized) }
        UserDefaults.standard.set(recent, forKey: Self.recentLibrariesKey)
        persistKnownLibraries()
        // 默认图库按原始记录判断：库不在磁盘上时 storedDefaultLibrary() 会返回 nil，
        // 只按有效路径判断会漏清理，等外置盘重新插上就又会被当作默认库打开。
        let defaults = UserDefaults.standard
        if defaults.string(forKey: LibraryPaths.defaultLibraryKey)
            .map({ isSameSystemLibraryPath($0, normalized) }) == true {
            defaults.removeObject(forKey: LibraryPaths.defaultLibraryKey)
            defaults.removeObject(forKey: LibraryPaths.defaultLibraryExplicitKey)
        }
        if LibraryPaths.storedLastOpenedPath()
            .map({ isSameSystemLibraryPath($0, normalized) }) == true {
            LibraryPaths.clearBootstrap()
        }
    }

    /// 退出当前图库但保留文件：清空只属于这个图库的内存状态，回到建库 / 打开引导。
    /// 之后新建或打开图库时，`switchLibraryContainer` / `createLibrary` 会重新装载状态。
    private func releaseCurrentLibraryForDetach() {
        flushMetadata()
        metadataStore = nil
        resetSourceContentCache()
        resetInMemoryCachesForLibrarySwitch()
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexComplete = true
        photos = []
        albums = []
        folders = []
        smartAlbums = []
        pinnedItems = []
        selection.removeAll()
        viewerID = nil
        editorID = nil
        similarScope = nil
        abortHealthScan()
        healthReport = nil
        finishCatalogPlayback()
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        resetFaceClusterState()
        resetBeautyState()
        resetPlaceCaches()
        resetUndoHistory()
        resetHashState()
        resetConfirmationState()
        navigate(to: .library)
        LibraryPaths.detach()
        containerLibraryPath = nil
        needsLibrarySetup = true
        showLibraryPicker = false
        libraryPickerOnLaunch = false
        showNewLibrarySheet = false
    }

    /// 登记系统图库：列表可保存多个，连接新图库时追加或更新，切换只改变当前连接。
    func registerSystemLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        // 自己外接自己：只切换回当前图库，不写进连接列表。
        if isContainerNativeLibraryPath(path) {
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, path) }
            persistSystemLibraries(systemLibraries)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        var list = systemLibraries
        if let index = list.firstIndex(where: { isSameSystemLibraryPath($0.path, path) }) {
            list[index] = SystemLibraryRef(path: path, name: name)
        } else {
            list.insert(SystemLibraryRef(path: path, name: name), at: 0)
        }
        if list.count > 50 { list.removeLast(list.count - 50) }
        systemLibraries = list
        persistSystemLibraries(list)
    }

    /// 断开某个系统图库；若断开的正是当前库，则退回「图库」。
    func removeSystemLibrary(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let active = systemLibraryPath, isSameSystemLibraryPath(active, normalized) {
            if isSystemScope {
                navigate(to: .library)
            }
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }
        // 同一个库可能同时登记在「打开过的图库」和「最近打开」里：
        // 只删当前这一份的话，断开后它会立刻从另一个列表冒出来。
        removeLibraryBindings(normalized)
        loadKnownLibraries()
    }

    // MARK: - 外接盘变化

    /// 监听卷卸载：正在浏览的外接图库被拔掉时自动退回「图库」，
    /// 连接记录保留（重新插上还能点回来），并清掉官方库判断的缓存。
    func observeVolumeRemoval() {
        guard volumeRemovalObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        volumeRemovalObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification,
                                                         object: nil,
                                                         queue: .main) { [weak self] _ in
            LibraryPaths.invalidateNativeCache()
            Task { @MainActor in self?.handleVolumeRemoval() }
        })
    }

    /// 卷卸载后的降级：不要把界面停在一个已经不存在的图库上。
    func handleVolumeRemoval() {
        if let path = systemLibraryPath, !FileManager.default.fileExists(atPath: path) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            showToast("「\(name)」所在的磁盘已断开，已切回图库")
            if isSystemScope { navigate(to: .library) }
            resetSystemLibraryState()
            metadataStore?.setSetting("system_library_path", nil)
        }
        if let container = LibraryPaths.containerLibraryURL,
           !LibraryPaths.isLibraryContainer(container) {
            showToast("当前图库所在的外置盘已断开，请重新连接后再继续操作")
        }
    }

    /// 点击侧边栏里的系统图库：已加载过就只切回页面，不重复扫描。
    func activateSystemLibrary(_ ref: SystemLibraryRef) {
        guard FileManager.default.fileExists(atPath: ref.path) else {
            // 外置盘没插时不能把连接记录删掉，否则重新插上就找不回来了。
            showToast("找不到「\(ref.name)」，可能已被移动、删除，或外置盘未连接")
            return
        }
        // 旧数据里可能把「自己」登记成了一条连接：切回自己并清掉那条重复记录。
        if isContainerNativeLibraryPath(ref.path) {
            systemLibraries.removeAll { isSameSystemLibraryPath($0.path, ref.path) }
            persistSystemLibraries(systemLibraries)
            connectSystemLibrary(URL(fileURLWithPath: ref.path))
            return
        }
        connectSystemLibrary(URL(fileURLWithPath: ref.path))
    }

    /// 在系统「照片」中打开指定的系统图库。
    func openSystemLibraryInPhotos(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 选择器里列出的图库：当前图库、所有打开过的图库（含外置盘上的）、最近打开过的，
    /// 以及「图片」文件夹里的 .photoslibrary。与侧边栏的「全部图库」共用同一份记录。
    func knownLibraryEntries() -> [LibraryEntry] {
        var urls: [URL] = []
        if let current = LibraryPaths.containerLibraryURL {
            urls.append(current)
        }
        urls.append(contentsOf: knownLibraries.map { URL(fileURLWithPath: $0.path) })
        for path in UserDefaults.standard.stringArray(forKey: Self.recentLibrariesKey) ?? [] {
            urls.append(URL(fileURLWithPath: path))
        }
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first,
           let items = try? FileManager.default.contentsOfDirectory(at: pictures,
                                                                   includingPropertiesForKeys: nil) {
            urls.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "photoslibrary" })
        }

        var seen = Set<String>()
        var entries: [LibraryEntry] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            entries.append(LibraryEntry(id: path,
                                        url: url,
                                        name: url.deletingPathExtension().lastPathComponent,
                                        modifiedAt: modified,
                                        isCurrent: LibraryPaths.containerLibraryURL?.standardizedFileURL.path == path,
                                        isDefault: isExplicitDefaultLibrary(path)))
        }

        entries.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
        return entries
    }

    /// 打开任意 .photoslibrary（含官方「照片」图库）：都以这个图库为准切换，
    /// 展示它自己的内容，之后的导入、编辑与设置都写入它自己的数据库。
    func activateLibrary(_ url: URL) {
        // 失效的图库（目录被移动 / 删除，或外置盘没插）绝不能进入切换流程：
        // 切换失败会把界面留在半截状态，看起来像图库和侧边栏一起消失了。
        guard LibraryPaths.isLibraryContainer(url) else {
            let name = url.deletingPathExtension().lastPathComponent
            showToast(name.isEmpty
                      ? "找不到这个图库，可能已被移动或删除"
                      : "找不到「\(name)」，可能已被移动、删除，或外置盘未连接")
            return
        }
        // 选择器窗口的关闭放在 switchLibraryContainer 成功之后：
        // 切换失败（只读 / 无权限）时保留选择器，用户可以直接换一个库再试。
        switchLibraryContainer(url)
    }

    // MARK: - 官方图库照片的补充元数据

    /// 当前是否允许给官方「照片」图库的照片写拾光的补充元数据。
    var canEditNativeOverlay: Bool { isNativeContainer }

    /// 原生导入完成后写拾光侧的第二份元数据：系统侧由 PhotoKit 写，这里只补标题。
    func recordSystemImportOverlay(assetID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveSystemOverlay(assetID) { overlay in
            if (overlay.title ?? "").isEmpty { overlay.title = trimmed }
        }
    }

    func updateSystemPhoto(_ id: UUID, mutate: (inout PhotoItem) -> Void) {
        systemRecentPhotos[id] = nil
        if let index = systemPhotos.firstIndex(where: { $0.id == id }) {
            mutate(&systemPhotos[index])
            systemPhotoIndex[id] = systemPhotos[index]
            return
        }
        // 索引模式：同步更新已加载窗口 / 胶片条，避免整页刷新。
        if let position = systemWindowPhotos.firstIndex(where: { $0.id == id }) {
            mutate(&systemWindowPhotos[position])
            systemPhotoIndex[id] = systemWindowPhotos[position]
        }
        if let position = viewerStrip.firstIndex(where: { $0.id == id }) {
            mutate(&viewerStrip[position])
        }
        if var item = systemPhotoIndex[id] ?? systemPhoto(id: id) {
            mutate(&item)
            systemPhotoIndex[id] = item
        }
        systemWindowRevision &+= 1
        // 收藏 / 隐藏覆盖会改变索引查询与侧边栏计数，必须让缓存失效。
        contentRevision &+= 1
    }

    private func saveSystemOverlay(_ id: UUID, mutate: (inout MetadataStore.AssetOverlay) -> Void) {
        guard let store = metadataStore else { return }
        // 覆盖元数据变了：窗口缓存里的旧对象要作废，下次读取才会带上新的收藏 / 隐藏状态。
        systemRecentPhotos[id] = nil
        var overlay = systemOverlays[id] ?? MetadataStore.AssetOverlay()
        mutate(&overlay)
        systemOverlays[id] = overlay
        // 收藏 / 隐藏 / 关键词都会参与索引查询条件，缓存必须失效。
        systemQueryCacheSignature = nil
        systemFavoritesRevision &+= 1
        store.saveOverlay(id, overlay)
    }

    /// 收藏 / 取消收藏官方图库里的照片。
    /// 官方库作为当前图库时经 PhotoKit 写回「照片」；否则只写拾光数据库（`Photos.sqlite` 保持只读）。
    func setSystemFavorite(_ favorite: Bool, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        let writeBack = canWriteSystemLibrary
        for id in ids {
            updateSystemPhoto(id) { $0.isFavorite = favorite }
            if !writeBack {
                saveSystemOverlay(id) { $0.isFavorite = favorite }
            }
        }
        guard writeBack else {
            // 挂载的其它照片图库完全只读：收藏只记录在拾光，不碰原库。
            showToast(favorite ? "已收藏（仅记录在拾光：此图库只读）" : "已取消收藏（仅记录在拾光）")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else {
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = favorite } }
                return
            }
            do {
                try await PhotoKitBridge.setFavorite(favorite, assetIDs: Array(ids))
                // 写回成功后清掉拾光覆盖值，以「照片」为准。
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = nil } }
                self.systemFavoritesRevision &+= 1
                self.showToast(favorite ? "已加入收藏，并同步到「照片」" : "已取消收藏，并同步到「照片」")
            } catch {
                for id in ids { self.saveSystemOverlay(id) { $0.isFavorite = favorite } }
                self.showToast("写回「照片」失败，已只记录在拾光：\(error.localizedDescription)")
            }
        }
    }

    /// 隐藏 / 取消隐藏：官方库作为当前图库时经 PhotoKit 写回「照片」。
    func setSystemHidden(_ hidden: Bool, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        // 隐藏会改变重复组的成员，让重复页在后台重新分组。
        invalidateSystemDuplicateGroups()
        let writeBack = canWriteSystemLibrary
        for id in ids {
            updateSystemPhoto(id) { $0.isHidden = hidden }
            if !writeBack {
                saveSystemOverlay(id) { $0.isHidden = hidden }
            }
        }
        guard writeBack else { return }
        Task {
            guard await prepareSystemLibraryWrite() else {
                for id in ids { self.saveSystemOverlay(id) { $0.isHidden = hidden } }
                return
            }
            do {
                try await PhotoKitBridge.setHidden(hidden, assetIDs: Array(ids))
                for id in ids { self.saveSystemOverlay(id) { $0.isHidden = nil } }
            } catch {
                for id in ids { self.saveSystemOverlay(id) { $0.isHidden = hidden } }
                self.showToast("写回「照片」失败，已只记录在拾光：\(error.localizedDescription)")
            }
        }
    }

    func setSystemKeywords(_ keywords: [String], ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        let value = keywords.isEmpty ? nil : keywords
        for id in ids {
            updateSystemPhoto(id) { $0.keywords = value }
            saveSystemOverlay(id) { $0.keywords = value }
        }
    }

    /// 系统图库的评分 / 旗标 / 色标只写拾光叠加数据，不修改 `Photos.sqlite`。
    func setSystemRating(_ rating: Int, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        let value = min(5, max(0, rating))
        for id in ids {
            updateSystemPhoto(id) { $0.rating = value }
            saveSystemOverlay(id) { $0.rating = value }
        }
    }

    func setSystemFlag(_ flag: PhotoFlag, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        for id in ids {
            updateSystemPhoto(id) { $0.flag = flag }
            saveSystemOverlay(id) { $0.flag = flag }
        }
    }

    func setSystemColorLabel(_ label: PhotoColorLabel, ids: Set<UUID>) {
        guard canEditNativeOverlay, !ids.isEmpty else { return }
        for id in ids {
            updateSystemPhoto(id) { $0.colorLabel = label }
            saveSystemOverlay(id) { $0.colorLabel = label }
        }
    }

    /// 记录查看：官方图库照片的查看时间同样只写拾光数据库。
    func recordSystemView(_ id: UUID) {
        guard canEditNativeOverlay, let item = systemPhoto(id: id) else { return }
        let now = Date()
        if let last = item.viewedAt, now.timeIntervalSince(last) < 3600 { return }
        // 「看过」只影响「值得重看」，不参与查询条件，也不显示在网格上。
        // 不能走 updateSystemPhoto / saveSystemOverlay：它们会推进 contentRevision、
        // 清空查询缓存并重建收藏汇总，大图库（几万张）开图那一刻整个窗口都要重算。
        if var cached = systemPhotoIndex[id] {
            cached.viewedAt = now
            systemPhotoIndex[id] = cached
        }
        guard let store = metadataStore else { return }
        var overlay = systemOverlays[id] ?? MetadataStore.AssetOverlay()
        overlay.viewedAt = now
        systemOverlays[id] = overlay
        store.saveOverlay(id, overlay)
    }

    /// 首次进入系统图库相关页面时才扫描 Photos.sqlite，避免启动即加载。
    func loadSystemLibraryIfNeeded(_ item: SidebarItem) {
        guard item.isSystemScope,
              systemPhotos.isEmpty,
              systemIndex == nil,
              systemLibraryError == nil,
              !isLoadingSystemLibrary,
              let path = systemLibraryPath else { return }
        let url = URL(fileURLWithPath: path)
        // 官方「照片」图库首次打开：先弹系统的照片访问授权，用户选择后再开始读取，
        // 避免扫描进行到一半才被授权框打断。
        if isNativeContainer, PhotoKitBridge.isAuthorizationUndetermined {
            isLoadingSystemLibrary = true
            systemScanCount = 0
            systemLibraryError = nil
            Task { [weak self] in
                _ = await PhotoKitBridge.ensureAuthorized()
                guard let self else { return }
                self.isLoadingSystemLibrary = false
                self.loadSystemLibrary(at: url, informOnFailure: true)
            }
            return
        }
        loadSystemLibrary(at: url, informOnFailure: true)
    }

    func loadSystemLibrary(at url: URL, informOnFailure: Bool = true, forceRefresh: Bool = false) {
        // 同一个库已经加载好（或正在加载）：只切页面，不重扫。
        // 「重新读取」传 forceRefresh 才会重建索引。
        if !forceRefresh {
            if isLoadingSystemLibrary { return }
            if systemIndex != nil,
               let loaded = systemLibraryLoadedPath,
               isSameSystemLibraryPath(loaded, url.path) {
                return
            }
        }
        // 打开系统图库默认展示「所有照片」全量网格，并按图库原始顺序（拍摄日期从新到旧）排列。
        if grouping != .all { grouping = .all }
        if sortKey != .capturedAt || sortAscending {
            sortKey = .capturedAt
            sortAscending = false
        }
        // 当前图库就是官方图库时，先从它自己的 Luma.sqlite 读回拾光的补充元数据。
        // 浏览外接图库时不能把 App 自己图库的收藏 / 评分 / 关键词套过去。
        if isNativeContainer, systemLibraryPath == nil || isBrowsingContainerSystemLibrary {
            systemOverlays = metadataStore?.loadOverlays() ?? [:]
        } else {
            systemOverlays = [:]
        }
        isLoadingSystemLibrary = true
        systemScanCount = 0
        systemLibraryError = nil
        systemLibraryLoadedPath = nil
        // 先清空，随后用索引、缓存或按批次增量展示。
        systemPhotos = []
        systemPhotoIndex = [:]
        systemAlbums = []
        systemFolders = []
        systemAlbumIndex = [:]
        systemAlbumCoverCache.removeAll()
        systemAlbumCoverMisses.removeAll()
        systemAlbumCoverLoading.removeAll()
        // PhotoKit 缩略图缓存只对当前图库有效：换库后资产标识与预取队列都要清空。
        PhotoKitThumbnailProvider.shared.reset()
        systemPeople = []
        systemTotalAssetCount = 0
        systemIndex = nil
        systemIndexSignature = ""
        // 关键词属于这个图库，换库 / 重扫时一并重新读取。
        systemNativeKeywordIndex = nil
        systemNativeKeywordIDMap = [:]
        systemIndexReady = false
        clearSystemWindow()
        selection.removeAll()
        viewerID = nil

        // 每次载入递增令牌：重扫时旧的扫描结果与缓存写入都要作废。
        systemLoadToken &+= 1
        let token = systemLoadToken
        // 十万级图库的索引构建可能要跑一阵：登记为后台任务，切走页面也能看到进度。
        let loadJobID = beginSourceJob(
            SourceJob(sourceID: .library(url.path), kind: .index, title: "载入系统图库", isCancellable: false)
        )

        if forceRefresh, let file = LibraryPaths.systemIndexFile(for: url) {
            try? FileManager.default.removeItem(at: file)
        }

        Task {
            defer {
                if token == systemLoadToken {
                    finishSourceJob(loadJobID, message: "系统图库已载入")
                } else {
                    cancelSourceJob(loadJobID)
                }
            }
            // 0. 相簿 / 文件夹 / 人物都只是元数据：先从 Photos.sqlite 读出并展示，
            //    不必等照片扫描 / 索引构建完成（十万项图库这一步只读几张元数据表）。
            let albumsTask = Task.detached(priority: .userInitiated) {
                SystemIndex.albumMetadata(libraryURL: url)
            }
            let peopleTask = Task.detached(priority: .userInitiated) {
                SystemIndex.peopleMetadata(libraryURL: url)
            }
            // 官方图库自带的关键词同样只是一张小表，和相簿 / 人物一起先读出来。
            let keywordTask = Task.detached(priority: .userInitiated) {
                SystemIndex.nativeKeywordMap(libraryURL: url)
            }
            let early = await albumsTask.value
            let earlyPeople = await peopleTask.value
            guard token == systemLoadToken else { return }
            if !early.albums.isEmpty || !early.folders.isEmpty {
                systemAlbums = early.albums
                systemFolders = early.folders
                systemAlbumIndex = Dictionary(uniqueKeysWithValues: early.albums.map { ($0.id, $0) })
                systemStructureRevision &+= 1
            }
            if !earlyPeople.isEmpty { systemPeople = earlyPeople }
            let earlyKeywords = await keywordTask.value
            guard token == systemLoadToken else { return }
            systemNativeKeywordIndex = earlyKeywords.byKeyword
            systemNativeKeywordIDMap = earlyKeywords.byAsset

            // 0. 直连模式：不复制整库，直接对 Photos.sqlite 分页查询。
            let directIndex = await Task.detached(priority: .userInitiated) {
                SystemIndex.openDirect(libraryURL: url)
            }.value
            guard token == systemLoadToken else { return }
            if let directIndex {
                directIndex.onDirectCountsReady = { [weak self] in
                    guard let self else { return }
                    self.systemCountsCache = nil
                    self.systemCountsCacheRevision = -1
                    self.mediaTypeSummaryCacheKey = nil
                    // 后台补好的地图 / 位置数据需要让 geoPhotos 重新取一次。
                    self.systemGeoCacheKey = nil
                    self.contentRevision &+= 1
                    // contentRevision 不是 @Published：手动通知一次，地图 / 地点页才会用上新数据。
                    self.objectWillChange.send()
                }
                await applySystemIndex(directIndex, at: url)
                isLoadingSystemLibrary = false
                systemScanCount = 0
                return
            }

            // 1. 已有匹配的索引：直接按窗口浏览，无需扫描整库。
            let opened = await Task.detached(priority: .userInitiated) {
                SystemIndex.openIfFresh(libraryURL: url)
            }.value
            guard token == systemLoadToken else { return }
            if let opened {
                await applySystemIndex(opened, at: url)
                isLoadingSystemLibrary = false
                systemScanCount = 0
                resumeSystemAnalysisIfNeeded()
                return
            }

            // 2. 大图库或已有旧索引：从 Photos.sqlite 重建索引（毫秒级分页，常驻内存只有一个窗口）。
            let total = await Task.detached(priority: .userInitiated) {
                SystemIndex.assetCount(libraryURL: url) ?? 0
            }.value
            guard token == systemLoadToken else { return }
            let indexExists = LibraryPaths.systemIndexFile(for: url)
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if total > SystemIndex.largeLibraryThreshold || indexExists {
                // 建索引期间同样逐批显示：百万级图库不必等索引写完才出图，
                // 索引就绪后再切换成 SQL 窗口浏览（内存只保留一个窗口）。
                let (stream, continuation) = Self.makeSystemBatchStream()
                let buildTask = Task.detached(priority: .userInitiated) { () -> Result<SystemIndex, Error> in
                    defer { continuation.finish() }
                    do {
                        let index = try SystemIndex.prepare(
                            libraryURL: url,
                            progress: { count in
                                Task { @MainActor [weak self] in
                                    guard let self, self.systemLoadToken == token else { return }
                                    self.systemScanCount = count
                                    self.updateSourceJob(loadJobID,
                                                         message: "已载入 \(count.formatted()) 项")
                                }
                            },
                            onBatch: { batch in continuation.yield(batch) })
                        return .success(index)
                    } catch {
                        return .failure(error)
                    }
                }
                await drainSystemBatches(stream, token: token, displayLimit: Self.systemStreamDisplayLimit)
                let result = await buildTask.value
                guard token == systemLoadToken else { return }
                if case .success(let index) = result {
                    await applySystemIndex(index, at: url)
                    isLoadingSystemLibrary = false
                    systemScanCount = 0
                    resumeSystemAnalysisIfNeeded()
                    return
                }
                // 索引不可用（磁盘不可写 / 图库正在写入）：回退到内存快照，功能不缺失。
                // 先清掉建索引期间先显示的半份数据，避免下面重新扫描时重复追加。
                systemPhotos = []
                systemPhotoIndex = [:]
            }

            // 3. 小图库或索引不可用：沿用内存快照与扫描缓存。
            // 先读扫描缓存：命中就立刻出图，只有图库确有变化时才在后台重扫。
            let cached = await Task.detached(priority: .userInitiated) {
                SystemLibraryCache.load(for: url)
            }.value

            guard token == systemLoadToken else { return }

            if let cached {
                applySystemSnapshot(cached.snapshot, at: url)
                if cached.isFresh, !forceRefresh {
                    isLoadingSystemLibrary = false
                    systemScanCount = 0
                    resumeSystemAnalysisIfNeeded()
                    return
                }
            }

            // 没有缓存时边扫边显示；有缓存时保持现有内容，扫描结束后整体替换。
            let streamBatches = cached == nil
            var continuation: AsyncStream<[PhotoItem]>.Continuation?
            var stream: AsyncStream<[PhotoItem]>?
            if streamBatches {
                let pair = Self.makeSystemBatchStream()
                stream = pair.0
                continuation = pair.1
            }

            // 扫描与索引构建放在后台。
            let batchContinuation = continuation
            let scanTask = Task.detached(priority: .userInitiated) { [weak self] () -> Result<SystemLoadPayload, Error> in
                defer { batchContinuation?.finish() }
                do {
                    let snapshot = try SystemPhotosLibrary.scan(
                        libraryURL: url,
                        progress: { count in
                            Task { @MainActor in
                                guard let self, self.systemLoadToken == token else { return }
                                self.systemScanCount = count
                                self.updateSourceJob(loadJobID,
                                                     message: "已载入 \(count.formatted()) 项")
                            }
                        },
                        onBatch: streamBatches ? { batch in batchContinuation?.yield(batch) } : nil
                    )
                    return .success(SystemLoadPayload(snapshot: snapshot))
                } catch {
                    return .failure(error)
                }
            }

            // 边扫描边显示：每批到达就追加，用户可以立刻开始浏览。
            if let stream {
                await drainSystemBatches(stream, token: token)
            }

            let result = await scanTask.value
            guard token == systemLoadToken else { return }
            switch result {
            case .success(let payload):
                applySystemSnapshot(payload.snapshot, at: url)
                SystemLibraryCache.save(payload.snapshot, for: url)
            case .failure(let error):
                systemLibraryError = error.localizedDescription
                if cached == nil {
                    systemPhotos = []
                    systemAlbums = []
                    systemFolders = []
                    systemPeople = []
                    systemPhotoIndex = [:]
                    systemAlbumIndex = [:]
                }
                if informOnFailure {
                    showToast(error.localizedDescription)
                }
            }
            isLoadingSystemLibrary = false
            systemScanCount = 0
            // 扫描结束后按最终内容重算重复分组。
            invalidateSystemDuplicateGroups()
            // 新照片进入系统图库后，继续增量识别（仅在已经开启过识别时）。
            resumeSystemAnalysisIfNeeded()
        }
    }

    /// 建索引期间「先显示」的缓冲上限：只保留开头这一段供用户浏览，
    /// 索引就绪后会整体替换成 SQL 窗口，不把整个图库常驻内存。
    static let systemStreamDisplayLimit = 40_000

    /// 扫描 / 建索引的批次通道：后台逐批投递，主线程按 2000 张或 0.3 秒合并刷新。
    static func makeSystemBatchStream()
        -> (AsyncStream<[PhotoItem]>, AsyncStream<[PhotoItem]>.Continuation) {
        var continuation: AsyncStream<[PhotoItem]>.Continuation!
        let stream = AsyncStream<[PhotoItem]>(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
        return (stream, continuation)
    }

    @MainActor
    private func drainSystemBatches(_ stream: AsyncStream<[PhotoItem]>,
                                    token: Int,
                                    displayLimit: Int? = nil) async {
        var pending: [PhotoItem] = []
        pending.reserveCapacity(2_000)
        var appended = 0
        var lastFlush = Date()
        func flush() {
            guard !pending.isEmpty, token == systemLoadToken else {
                pending.removeAll(keepingCapacity: true)
                return
            }
            if displayLimit.map({ appended < $0 }) ?? true {
                systemPhotos.append(contentsOf: pending)
                for item in pending {
                    systemPhotoIndex[item.id] = item
                }
                appended += pending.count
            }
            pending.removeAll(keepingCapacity: true)
        }
        for await batch in stream {
            guard token == systemLoadToken else { break }
            pending.append(contentsOf: batch.map { applySystemOverlay($0) })
            if pending.count >= 2_000 || Date().timeIntervalSince(lastFlush) > 0.3 {
                flush()
                lastFlush = Date()
            }
        }
        flush()
    }

    /// 应用系统图库索引：内存只保留相簿 / 文件夹 / 人物这些轻量元数据，照片按窗口查询。
    /// 相簿 / 文件夹 / 人物在直连模式下每次访问都会查一次 `Photos.sqlite`，
    /// 统一放到后台线程读取，避免打开图库时主线程被上万条元数据查询堵住。
    func applySystemIndex(_ index: SystemIndex, at url: URL) async {
        let metadata = await Task.detached(priority: .userInitiated) {
            () -> (albums: [SystemAlbumInfo], folders: [SystemFolderInfo], people: [SystemPersonInfo]) in
            // 相簿项目数一次聚合读入缓存，侧边栏逐行判断「空相簿」时不再查库。
            index.warmDirectAlbumCounts()
            return (index.albums, index.folders, index.people)
        }.value
        systemIndex = index
        systemIndexSignature = "\(url.path)#\(index.total)#\(index.trueTotal)"
        systemLibraryName = index.name
        systemPhotos = []
        systemPhotoIndex = [:]
        // 直连模式下 albums / folders / people 每次访问都会查一次 Photos.sqlite，
        // 这里只取一遍再复用，避免启动时把上万个相簿查两次。
        let albums = metadata.albums
        let folders = metadata.folders
        systemAlbums = albums
        systemFolders = folders
        systemPeople = metadata.people
        systemAlbumIndex = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        systemTotalAssetCount = index.trueTotal
        systemLibraryError = nil
        systemLibraryLoadedPath = url.path
        systemIndexReady = true
        // 缩略图目录先登记到索引：外接库里每个格子的存在性判断都变成内存查询。
        // 官方 derivative 目录可能有上百万个文件，只预热一小段时间；本机缩略图缓存给足预算。
        ThumbnailFileIndex.shared.warm(root: LibraryPaths.systemDerivatives(libraryURL: url))
        ThumbnailFileIndex.shared.warm(root: url.appendingPathComponent("scopes/cloudsharing",
                                                                       isDirectory: true))
        ThumbnailFileIndex.shared.warm(root: LibraryPaths.systemThumbs, timeBudget: 3)
        invalidateSystemDuplicateGroups()
        systemGeoCacheKey = nil
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        mediaTypeSummaryCacheKey = nil
        systemStructureRevision &+= 1
        contentRevision &+= 1
        clearSystemWindow()
        hydrateSystemCacheIfNeeded()
        loadPhotoKitMediaTypesIfNeeded()
        // 载入完成后再判定一次：挂载的其它照片图库在这里被标成只读。
        refreshSystemWriteTargetState()
        // 跨图库搜索点开的条目：目标系统图库的索引到这一刻才真正可用。
        consumePendingLibraryOpenIfReady()
    }

    /// 长曝光 / 电影效果只能通过 PhotoKit 智能相簿取 ID；仅对当前官方图库有效。
    /// 这里绝不申请权限：浏览网络资源、网络电视等页面也会走到导航收尾，
    /// 授权只由用户主动打开系统图库时申请。
    func loadPhotoKitMediaTypesIfNeeded() {
        guard isNativeContainer,
              PhotoKitBridge.hasReadWritePermission,
              !isPhotoKitMediaTypeLoaded else { return }
        isPhotoKitMediaTypeLoaded = true
        Task { [weak self] in
            let ids = await PhotoKitBridge.specialMediaTypeAssetIDs()
            guard let self else { return }
            guard let ids else {
                // 没有照片权限：保留入口但结果为空，下次进入时再请求。
                self.isPhotoKitMediaTypeLoaded = false
                return
            }
            self.photoKitLongExposureIDs = ids.longExposure
            self.photoKitCinematicIDs = ids.cinematic
            self.mediaTypeSummaryCacheKey = nil
            self.contentRevision &+= 1
        }
    }

    /// 应用一份系统图库快照（缓存或扫描结果）。
    func applySystemSnapshot(_ snapshot: SystemLibrarySnapshot, at url: URL) {
        systemLibraryName = snapshot.name
        systemPhotos = snapshot.photos.map { applySystemOverlay($0) }
        systemAlbums = snapshot.albums
        systemFolders = snapshot.folders
        systemPeople = snapshot.people
        systemPhotoIndex = Dictionary(uniqueKeysWithValues: systemPhotos.map { ($0.id, $0) })
        systemAlbumIndex = Dictionary(uniqueKeysWithValues: snapshot.albums.map { ($0.id, $0) })
        systemTotalAssetCount = snapshot.totalAssetCount ?? snapshot.photos.count
        systemLibraryError = nil
        systemLibraryLoadedPath = url.path
        invalidateSystemDuplicateGroups()
        hydrateSystemCacheIfNeeded()
        refreshSystemWriteTargetState()
    }

    /// 把拾光的补充元数据叠加到官方「照片」图库的照片上（收藏 / 隐藏 / 关键词 / 标题 / 查看时间）。
    /// 只影响拾光自己的展示，不修改 `Photos.sqlite`。
    func applySystemOverlay(_ photo: PhotoItem) -> PhotoItem {
        Self.applyingOverlays(photo,
                              overlays: systemOverlays,
                              nativeKeywords: systemNativeKeywordIDMap,
                              isNative: isNativeContainer)
    }

    /// 叠加规则的批量 / 后台版本：overlay 与官方关键词由调用方先快照，
    /// 批量汇总（如个人收藏）时不必回主线程逐条读取 Store 状态。
    nonisolated static func applyingOverlays(_ photo: PhotoItem,
                                             overlays: [UUID: MetadataStore.AssetOverlay],
                                             nativeKeywords: [UUID: [String]],
                                             isNative: Bool) -> PhotoItem {
        var item = photo
        if isNative, let overlay = overlays[photo.id] {
            item = applyAssetOverlay(overlay, to: item)
        }
        // 官方图库自带的关键词与拾光补充关键词合并展示，信息面板 / 搜索都能看到。
        if let native = nativeKeywords[photo.id], !native.isEmpty {
            var merged = item.keywords ?? []
            for tag in native where !merged.contains(tag) { merged.append(tag) }
            item.keywords = merged
        }
        return item
    }

    /// 读回官方图库自带的关键词（每次载入图库读一次；`Photos.sqlite` 只读，不会写回）。
    @discardableResult
    func ensureSystemNativeKeywordsLoaded() -> [String: [UUID]] {
        if let cached = systemNativeKeywordIndex { return cached }
        guard let path = systemLibraryPath else { return [:] }
        let map = SystemIndex.nativeKeywordMap(libraryURL: URL(fileURLWithPath: path))
        systemNativeKeywordIndex = map.byKeyword
        systemNativeKeywordIDMap = map.byAsset
        return map.byKeyword
    }

    /// 该关键词是否来自官方图库：只读，无法从 `Photos.sqlite` 删除。
    func isNativeSystemKeyword(_ name: String) -> Bool {
        isSystemScope && ensureSystemNativeKeywordsLoaded()[name] != nil
    }

    /// 叠加规则的纯函数版本：后台分组时直接使用，不依赖主线程状态。
    nonisolated static func applyAssetOverlay(_ overlay: MetadataStore.AssetOverlay?,
                                              to photo: PhotoItem) -> PhotoItem {
        guard let overlay else { return photo }
        var item = photo
        if let favorite = overlay.isFavorite { item.isFavorite = favorite }
        if let hidden = overlay.isHidden { item.isHidden = hidden }
        if let keywords = overlay.keywords { item.keywords = keywords }
        if let title = overlay.title { item.title = title }
        if let viewed = overlay.viewedAt { item.viewedAt = viewed }
        if let rating = overlay.rating { item.rating = rating }
        if let flag = overlay.flag { item.flag = flag }
        if let colorLabel = overlay.colorLabel { item.colorLabel = colorLabel }
        return item
    }

    struct SystemLoadPayload {
        let snapshot: SystemLibrarySnapshot
    }

    func reloadSystemLibrary() {
        guard let path = systemLibraryPath else { return }
        loadSystemLibrary(at: URL(fileURLWithPath: path), informOnFailure: true, forceRefresh: true)
    }

    func disconnectSystemLibrary() {
        guard let path = systemLibraryPath else { return }
        removeSystemLibrary(path)
    }

    func revealSystemLibraryInFinder() {
        guard let path = systemLibraryPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var systemLibraryTotalBytes: Int64 {
        systemSidebarCounts.totalBytes
    }

    var systemTrashCount: Int {
        systemSidebarCounts.trash
    }

    static var recentlySavedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    /// 「最近查看」按系统「照片」的 30 天窗口统计。
    static var recentlyViewedCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
    }

    var systemPortraitCount: Int {
        systemSidebarCounts.portrait
    }

    var systemDuplicateCount: Int {
        systemSidebarCounts.duplicate
    }

    var systemScreenshotCount: Int {
        systemSidebarCounts.screenshots
    }

    var systemRecentlySavedCount: Int {
        systemSidebarCounts.recentlySaved
    }

    var systemImportCount: Int {
        systemSidebarCounts.imports
    }

    var systemHiddenCount: Int {
        systemSidebarCounts.hidden
    }

    func systemAlbumNamesContaining(_ id: UUID) -> [String] {
        if let index = systemIndex { return index.albumNames(containing: id) }
        return systemAlbums.filter { $0.assetIDs.contains(id) }.map { $0.name }
    }

    /// 侧边栏相簿封面：索引模式按需查询第一张，不加载整个相簿。
    func systemAlbumFirstPhoto(_ albumID: Int64) -> PhotoItem? {
        if let index = systemIndex {
            return index.firstAlbumPhoto(albumID).map { applySystemOverlay($0) }
        }
        guard let album = systemAlbum(id: albumID),
              let first = album.assetIDs.first else { return nil }
        return systemPhoto(id: first)
    }

    /// 侧边栏相簿封面的异步版本：查询放到后台，视图 body 只调用它、不再同步查库。
    /// 结果按相簿缓存，滚动离开再回来不会重复读 `Photos.sqlite`。
    func systemAlbumCover(_ albumID: Int64) async -> PhotoItem? {
        if let cached = systemAlbumCoverCache[albumID] { return cached }
        if systemAlbumCoverMisses.contains(albumID) { return nil }
        // 同一个相簿同时被多处请求时只查一次，其余请求等结果。
        if systemAlbumCoverLoading.contains(albumID) {
            while systemAlbumCoverLoading.contains(albumID) {
                if Task.isCancelled { return nil }
                try? await Task.sleep(nanoseconds: 20_000_000)
                if let cached = systemAlbumCoverCache[albumID] { return cached }
                if systemAlbumCoverMisses.contains(albumID) { return nil }
            }
            return systemAlbumCoverCache[albumID]
        }
        systemAlbumCoverLoading.insert(albumID)
        defer { systemAlbumCoverLoading.remove(albumID) }
        let index = systemIndex
        let raw: PhotoItem?
        if let index {
            raw = await Task.detached(priority: .utility) {
                index.firstAlbumPhoto(albumID)
            }.value
        } else {
            // 扫描 / 建索引期间还没有索引：内存快照查找本身是 O(1)，直接同步取。
            raw = systemAlbumFirstPhoto(albumID)
        }
        guard let raw else {
            systemAlbumCoverMisses.insert(albumID)
            return nil
        }
        let photo = applySystemOverlay(raw)
        systemAlbumCoverCache[albumID] = photo
        return photo
    }

    /// 相簿封面（可多张）：索引模式按官方顺序取前若干张，跳过已删除与隐藏项目。
    func systemAlbumPreviewPhotos(_ albumID: Int64, limit: Int) -> [PhotoItem] {
        guard limit > 0 else { return [] }
        if let index = systemIndex {
            return index.albumPreviewPhotos(albumID, limit: limit).map { applySystemOverlay($0) }
        }
        var result: [PhotoItem] = []
        for id in systemAlbum(id: albumID)?.assetIDs ?? [] where result.count < limit {
            if let photo = systemPhoto(id: id), photo.deletedAt == nil, !photo.isHidden {
                result.append(photo)
            }
        }
        return result
    }

    /// 相簿封面的异步版本：相簿墙可能有上万个相簿，body 里逐张同步查 `Photos.sqlite`
    /// 会让打开文件夹直接卡住。命中索引缓存时立刻返回，否则在后台取。
    func systemAlbumPreviewPhotosAsync(_ albumID: Int64, limit: Int) async -> [PhotoItem] {
        guard limit > 0 else { return [] }
        guard let index = systemIndex else {
            return systemAlbumPreviewPhotos(albumID, limit: limit)
        }
        if let cached = index.cachedAlbumPreviewPhotos(albumID, limit: limit) {
            return cached.map { applySystemOverlay($0) }
        }
        let raw = await Task.detached(priority: .utility) {
            index.albumPreviewPhotos(albumID, limit: limit)
        }.value
        return raw.map { applySystemOverlay($0) }
    }

    /// 官方导入会话（按导入时间从新到旧）；本地库没有这套记录。
    var systemImportSessions: [SystemImportSession] {
        systemIndex?.importSessions ?? []
    }

    /// 导入会话的封面（官方索引里批内第一张）。
    func systemImportSessionCover(_ sessionID: Int64) -> PhotoItem? {
        guard let photo = systemIndex?.importSessionCover(sessionID) else { return nil }
        return applySystemOverlay(photo)
    }

    /// 导入批次的拍摄跨度与视频数量。
    func systemImportSessionSummary(_ sessionID: Int64) -> SystemImportSessionSummary? {
        systemIndex?.importSessionSummary(sessionID)
    }

    /// 相簿项目数：索引模式直接读索引，避免依赖内存里的空 assetIDs。
    /// 结果按结构版本缓存：侧边栏滚动时每个可见行都会问一次，不能每帧都查库。
    func systemAlbumPhotoCount(_ albumID: Int64) -> Int {
        if systemAlbumCountCacheRevision != systemStructureRevision {
            systemAlbumCountCache.removeAll(keepingCapacity: true)
            systemAlbumCountCacheRevision = systemStructureRevision
        }
        if let cached = systemAlbumCountCache[albumID] { return cached }
        let count: Int
        if let index = systemIndex {
            count = index.albumAssetCount(albumID)
        } else {
            count = systemAlbum(id: albumID)?.assetIDs.count ?? 0
        }
        systemAlbumCountCache[albumID] = count
        return count
    }

    /// 侧边栏相簿是否为空。
    func systemAlbumIsEmpty(_ albumID: Int64) -> Bool {
        // 扫描 / 建索引期间相簿成员还没读完：不显示「空相簿」标记，避免误判。
        if systemIndex == nil, isLoadingSystemLibrary { return false }
        return systemAlbumPhotoCount(albumID) == 0
    }

    /// 按主键取相簿：优先走索引，索引尚未建立时退回线性查找。
    func systemAlbum(id: Int64) -> SystemAlbumInfo? {
        if let album = systemAlbumIndex[id] { return album }
        return systemAlbums.first(where: { $0.id == id })
    }

    var systemLibraryDateRange: String? {
        let counts = systemSidebarCounts
        guard let minDate = counts.earliest, let maxDate = counts.latest else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return "\(formatter.string(from: minDate)) – \(formatter.string(from: maxDate))"
    }

    func importSystemSelectionToLibrary() {
        let targets = selection.compactMap { systemPhoto(id: $0) }
        guard !targets.isEmpty else { return }
        importSystemPhotos(targets, albumName: nil)
    }

    func importSystemAlbumToLibrary(_ albumID: Int64) {
        let targets: [PhotoItem]
        if let index = systemIndex {
            targets = index.photos(ids: index.albumAssetIDs(albumID)).map { applySystemOverlay($0) }
        } else {
            guard let album = systemAlbums.first(where: { $0.id == albumID }) else { return }
            targets = album.assetIDs.compactMap { systemPhoto(id: $0) }
        }
        let albumName = systemAlbums.first(where: { $0.id == albumID })?.name
        guard !targets.isEmpty else {
            showToast("该相簿里没有可拷贝的项目")
            return
        }
        importSystemPhotos(targets, albumName: albumName)
    }

    /// 递归收集系统文件夹（含子文件夹与其相簿）里的所有项目 ID。
    func systemFolderAssetIDs(_ folderID: Int64) -> [UUID] {
        if let index = systemIndex { return index.folderAssetIDs(folderID) }
        var ids: [UUID] = []
        for album in systemAlbums where album.parentFolder == folderID {
            ids.append(contentsOf: album.assetIDs)
        }
        for child in systemFolders where child.parent == folderID {
            ids.append(contentsOf: systemFolderAssetIDs(child.id))
        }
        return ids
    }

    /// 只取前 `limit` 个项目 ID：打开文件夹时预热缩略图，避免为预热遍历整棵子树。
    func systemFolderPreviewAssetIDs(_ folderID: Int64, limit: Int) -> [UUID] {
        if let index = systemIndex { return index.folderPreviewAssetIDs(folderID, limit: limit) }
        var ids: [UUID] = []
        ids.reserveCapacity(limit)
        func walk(_ id: Int64) {
            guard ids.count < limit else { return }
            for album in systemAlbums where album.parentFolder == id {
                ids.append(contentsOf: album.assetIDs.prefix(limit - ids.count))
                if ids.count >= limit { return }
            }
            for child in systemFolders where child.parent == id {
                walk(child.id)
                if ids.count >= limit { return }
            }
        }
        walk(folderID)
        return ids
    }

    /// 重新读取官方「照片」的人物 / 宠物列表。
    /// 识别本身由 macOS「照片」在端侧完成，拾光只刷新读到的结果。
    func refreshSystemPeople() {
        guard let index = systemIndex else {
            showToast("系统图库尚未就绪，请稍后重试")
            return
        }
        systemPeople = index.people
        showToast(systemPeople.isEmpty
                  ? "官方图库里还没有识别出人物"
                  : "已刷新 \(systemPeople.count.formatted()) 位人物 / 宠物")
    }

    func importSystemFolderToLibrary(_ folderID: Int64) {
        guard let folder = systemFolders.first(where: { $0.id == folderID }) else { return }
        let ids = systemFolderAssetIDs(folderID)
        let targets: [PhotoItem]
        if let index = systemIndex {
            targets = index.photos(ids: ids).map { applySystemOverlay($0) }
        } else {
            targets = ids.compactMap { systemPhoto(id: $0) }
        }
        guard !targets.isEmpty else {
            showToast("该文件夹里没有可拷贝的项目")
            return
        }
        importSystemPhotos(targets, albumName: folder.name)
    }

    /// 当前系统图库范围（相簿 / 文件夹）能否整体拷贝到拾光。
    var canImportCurrentSystemScope: Bool {
        switch sidebarItem {
        case .systemAlbum, .systemFolder: return true
        default: return false
        }
    }

    var currentSystemScopeImportTitle: String {
        switch sidebarItem {
        case .systemAlbum(let id):
            return "拷贝「\(systemAlbums.first(where: { $0.id == id })?.name ?? "相簿")」到拾光"
        case .systemFolder(let id):
            return "拷贝「\(systemFolders.first(where: { $0.id == id })?.name ?? "文件夹")」到拾光"
        default:
            return "拷贝到拾光"
        }
    }

    func importCurrentSystemScopeToLibrary() {
        switch sidebarItem {
        case .systemAlbum(let id):
            importSystemAlbumToLibrary(id)
        case .systemFolder(let id):
            importSystemFolderToLibrary(id)
        default:
            break
        }
    }

    func importSystemPhotos(_ targets: [PhotoItem], albumName: String?) {
        // 已经在拾光里的项目（同名同大小）不重复拷贝。
        let existing = Set(photos.map { "\($0.originalName)|\($0.fileSize)" })
        let pending = targets.filter { !existing.contains("\($0.originalName)|\($0.fileSize)") }
        let skipped = targets.count - pending.count
        guard !pending.isEmpty else {
            showToast(skipped > 0 ? "这些项目已经在拾光里了" : "没有可拷贝的项目")
            return
        }
        showToast("正在拷贝 \(pending.count) 项到拾光…")
        Task {
            var imported: [PhotoItem] = []
            let batchID = UUID()
            for target in pending {
                guard let path = target.systemOriginalPath else { continue }
                // 统一走 IngestService 的本地文件入口，不再直接调 ImportService。
                let service = ingestService
                let item = await Task.detached(priority: .userInitiated) {
                    try? service.importLocalFile(URL(fileURLWithPath: path))
                }.value
                if var item {
                    item.importBatchID = batchID
                    imported.append(item)
                }
            }
            photos.append(contentsOf: imported)
            if let albumName, !imported.isEmpty {
                if let index = albums.firstIndex(where: { $0.name == albumName }) {
                    albums[index].photoIDs.append(contentsOf: imported.map { $0.id })
                } else {
                    var album = Album(name: albumName)
                    album.photoIDs = imported.map { $0.id }
                    albums.append(album)
                }
            }
            save()
            selection.removeAll()
            var message = "已拷贝 \(imported.count) 项到拾光"
            if skipped > 0 { message += "，跳过 \(skipped) 项重复项目" }
            showToast(message)
        }
    }
}
