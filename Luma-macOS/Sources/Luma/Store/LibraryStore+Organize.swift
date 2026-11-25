import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Navigation

    func navigate(to item: SidebarItem) {
        // 影视源只属于网络影院：任何指向它的「网络资源频道页」都改道到网络影院。
        var item = item
        if case .catalogSource(let id) = item,
           catalogModel.isSource(id, in: .networkCinema) {
            networkCinemaSourceID = id
            if !networkCinemaTab.browsesContent {
                networkCinemaTab = .movies
            }
            item = .networkCinema
        }
        let pageChanged = sidebarItem != item
        sidebarItem = item
        if pageChanged {
            // 上一个页面遗留的定位请求（查看器返回、方向键、年月跳转）不能带到新页面，
            // 否则切回图库时会滚到一张与当前范围无关的照片上。
            scrollTargetID = nil
            timelineJumpLandingID = nil
        }
        // 拾光 / 系统图库 / 网盘共用同一套浏览态清理，网盘换范围时也调用这里。
        clearTransientBrowsingState()
        if case .cloudMount(let id) = item {
            openCloudMount(id)
        }
        if case .catalogSource(let id) = item {
            catalogModel.focus(id)
        }
        prewarmOpenedCollection(item)
        loadPhotoKitMediaTypesIfNeeded()
    }

    /// 启动恢复后纠正旧页面：上次停在影视源的「网络资源频道页」时，改停到网络影院。
    func redirectCinemaSidebarItemIfNeeded() {
        guard case .catalogSource(let id) = sidebarItem,
              catalogModel.isSource(id, in: .networkCinema) else { return }
        networkCinemaSourceID = id
        if !networkCinemaTab.browsesContent {
            networkCinemaTab = .movies
        }
        sidebarItem = .networkCinema
    }

    // MARK: - 返回搜索

    /// 记下搜索现场：详情页顶栏据此显示「返回搜索」，一步回到刚才的关键词与筛选。
    func beginSearchReturn(_ snapshot: SearchReturnSnapshot) {
        searchReturn = snapshot
    }

    /// 跨库命中要等目标图库就绪才真正落地：就绪后再补上落点页面。
    func markSearchReturnLanded(_ item: SidebarItem) {
        guard var snapshot = searchReturn else { return }
        snapshot.landingItem = item
        searchReturn = snapshot
    }

    /// 「返回搜索」是否可用：只在由搜索跳到的那个页面上出现。
    var searchReturnAvailable: Bool {
        guard let snapshot = searchReturn, let landing = snapshot.landingItem else { return false }
        return landing == sidebarItem
    }

    /// 顶栏「返回搜索」：回到搜索前的页面，恢复关键词与来源 / 类型筛选。
    func returnToSearch() {
        guard let snapshot = searchReturn, searchReturnAvailable else { return }
        searchReturn = nil
        pendingSearchRestore = snapshot
        searchScope = snapshot.scope
        if sidebarItem != snapshot.originItem {
            // 这里会清掉搜索词与临时浏览态；恢复内容在下面重新写回。
            navigate(to: snapshot.originItem)
        }
        searchText = snapshot.query
    }

    /// 切换浏览范围时清理的临时状态：选择、查看器、搜索、筛选与二级详情。
    /// 拾光 / 系统图库走 `navigate(to:)`，网盘走 `setCloudScope` / `selectCloudFolder`，三处行为一致。
    func clearTransientBrowsingState() {
        selection.removeAll()
        viewerID = nil
        searchText = ""
        photoFilter = .all
        keywordFilter = nil
        clearMetadataFilters()
        selectedKeyword = nil
        selectedPlace = nil
        selectedPerson = nil
        similarScope = nil
        selectedFavoriteBucket = nil
        // 离开网络影院时详情随之关闭，顶栏返回不会残留到别的页面。
        networkCinemaDetail = nil
    }

    /// 打开相簿 / 文件夹后预热前若干张快速缩略图（解码一次并写入本地快速层缓存），
    /// 让首屏与后续滚动直接命中；切换范围时取消上一次预热。
    private func prewarmOpenedCollection(_ item: SidebarItem) {
        thumbnailPrewarmTask?.cancel()
        thumbnailPrewarmTask = nil

        let limit = Self.thumbnailPrewarmLimit
        // 系统图库的相簿 / 文件夹：成员列表与照片元数据都在后台取，
        // 打开几千张的大相簿时不会在点击瞬间阻塞主线程。
        if let index = systemIndex {
            switch item {
            case .systemAlbum(let id):
                thumbnailPrewarmTask = prewarmSystemSelection {
                    let ids = Array(index.albumAssetIDs(id).prefix(limit))
                    return index.photos(ids: ids)
                }
                return
            case .systemFolder(let id):
                thumbnailPrewarmTask = prewarmSystemSelection {
                    let ids = index.folderPreviewAssetIDs(id, limit: limit)
                    return index.photos(ids: ids)
                }
                return
            default:
                break
            }
        }

        let targets: [PhotoItem]
        switch item {
        case .systemAlbum(let id):
            guard let album = systemAlbum(id: id) else { return }
            targets = Array(album.assetIDs.lazy.compactMap { self.systemPhotoIndex[$0] }.prefix(limit))
        case .systemFolder(let id):
            targets = systemFolderPreviewAssetIDs(id, limit: limit)
                .compactMap { self.systemPhotoIndex[$0] }
        case .album, .folder:
            targets = Array(photos(for: item).prefix(limit))
        default:
            return
        }

        guard !targets.isEmpty else { return }
        thumbnailPrewarmTask = ImageLoader.prewarmQuickThumbnails(for: targets)
    }

    /// 后台取回首屏照片，再交给缩略图预热；主线程只负责轻量的 overlay 叠加。
    private func prewarmSystemSelection(_ fetch: @escaping () -> [PhotoItem]) -> Task<Void, Never> {
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) { fetch() }.value
            guard let self, !Task.isCancelled else { return }
            let targets = items.map { self.applySystemOverlay($0) }
            guard !targets.isEmpty else { return }
            if self.usesPhotoKitThumbnails {
                PhotoKitThumbnailProvider.shared.prefetch(photos: targets,
                                                          maxPixel: ImageLoader.gridQuickPixel)
            } else {
                self.thumbnailPrewarmTask = ImageLoader.prewarmQuickThumbnails(for: targets)
            }
        }
    }

    /// 预热数量上限：覆盖两屏左右，再多会挤占滚动时的解码资源。
    private static let thumbnailPrewarmLimit = 300

    func clearFilter() {
        photoFilter = .all
        keywordFilter = nil
        clearMetadataFilters()
    }

    // MARK: - Keywords

    var keywordOptions: [KeywordOption] {
        var counts: [String: Int] = [:]
        if isCloudScope {
            // 网盘：关键词是拾光为远端文件记录的本地标签。
            for photo in cloudPhotos where !photo.isHidden {
                for tag in photo.tags {
                    counts[tag, default: 0] += 1
                }
            }
        } else if isSystemScope {
            // 官方「照片」图库：图库自带的 ZKEYWORD 与拾光补充的关键词合并统计，
            // 同一张照片同一标签只算一次。
            var idsByKeyword: [String: Set<UUID>] = [:]
            for (name, ids) in ensureSystemNativeKeywordsLoaded() {
                idsByKeyword[name] = Set(ids)
            }
            for (id, overlay) in systemOverlays {
                for tag in overlay.keywords ?? [] {
                    idsByKeyword[tag, default: []].insert(id)
                }
            }
            counts = idsByKeyword.mapValues(\.count)
        } else {
            for photo in photos where photo.deletedAt == nil {
                for tag in photo.tags {
                    counts[tag, default: 0] += 1
                }
            }
        }
        return counts.map { KeywordOption(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 打开某个关键词：留在关键词页里进入独立详情（卡片墙 + 照片列表 + 返回）。
    func openKeyword(_ name: String, system: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: SidebarItem = system ? .systemKeywords : .keywords
        if sidebarItem != target { sidebarItem = target }
        selection.removeAll()
        viewerID = nil
        searchText = ""
        photoFilter = .all
        keywordFilter = nil
        clearMetadataFilters()
        selectedKeyword = trimmed
        selectedPlace = nil
        selectedPerson = nil
        similarScope = nil
        loadPhotoKitMediaTypesIfNeeded()
    }

    /// 从关键词详情回到卡片墙。
    func closeKeyword() {
        selectedKeyword = nil
        selection.removeAll()
        viewerID = nil
        keywordFilter = nil
    }

    /// 某个关键词下的全部照片；系统图库把官方标签与拾光补充标签合并。
    func keywordPhotos(_ name: String) -> [PhotoItem] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if isCloudScope {
            return cloudPhotos.filter { $0.tags.contains(trimmed) }
        }
        if isSystemScope {
            var ids = Set(systemOverlays.compactMap { id, overlay in
                (overlay.keywords?.contains(trimmed) ?? false) ? id : nil
            })
            if let native = ensureSystemNativeKeywordsLoaded()[trimmed] {
                ids.formUnion(native)
            }
            guard !ids.isEmpty else { return [] }
            let items: [PhotoItem]
            if let index = systemIndex {
                items = index.photos(ids: Array(ids))
            } else {
                items = ids.compactMap { systemPhoto(id: $0) }
            }
            return items.sorted { $0.capturedAt > $1.capturedAt }
        }
        return photos.filter { $0.deletedAt == nil && $0.tags.contains(trimmed) }
    }

    /// 关键词卡片墙的封面：取该关键词下的第一张照片。
    func keywordCover(for keyword: String) -> PhotoItem? {
        let token = [
            String(contentRevision),
            systemIndexSignature,
            String(cloudModel.revision),
            String(cloudModel.metadataRevision),
            String(describing: sidebarItem)
        ].joined(separator: "\u{1F}")
        if keywordCoverToken != token {
            keywordCoverToken = token
            keywordCoverCache.removeAll()
            keywordCoverMissing.removeAll()
        }
        if let cover = keywordCoverCache[keyword] { return cover }
        if keywordCoverMissing.contains(keyword) { return nil }
        let cover: PhotoItem?
        if isCloudScope {
            cover = cloudPhotos.first { $0.tags.contains(keyword) }
        } else if isSystemScope {
            if let id = systemOverlays.first(where: {
                $0.value.keywords?.contains(keyword) ?? false
            })?.key {
                cover = systemPhoto(id: id)
            } else {
                // 官方图库自带的关键词：取该词下拍摄时间最新的一张作为封面。
                let first = ensureSystemNativeKeywordsLoaded()[keyword]?.first
                cover = first.flatMap { systemPhoto(id: $0) }
            }
        } else {
            cover = photos.first { $0.deletedAt == nil && $0.tags.contains(keyword) }
        }
        if let cover {
            keywordCoverCache[keyword] = cover
        } else {
            keywordCoverMissing.insert(keyword)
        }
        return cover
    }

    func addKeyword(_ keyword: String, to ids: Set<UUID>) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ids.isEmpty else { return }
        if isCloudScope {
            updateCloudKeywords(ids) { tags in
                guard !tags.contains(trimmed) else { return false }
                tags.append(trimmed)
                return true
            }
            showToast("已添加关键词「\(trimmed)」")
            return
        }
        // 官方「照片」图库：关键词写进拾光数据库（Photos.sqlite 只读）。
        if canEditNativeOverlay {
            let systemIDs = ids.filter { isSystemPhotoID($0) }
            if !systemIDs.isEmpty {
                for id in systemIDs {
                    var list = systemPhoto(id: id)?.keywords ?? []
                    if !list.contains(trimmed) { list.append(trimmed) }
                    setSystemKeywords(list, ids: [id])
                }
                showToast("已添加关键词「\(trimmed)」")
                return
            }
        }
        var changed = false
        let beforePhotos = photoSnapshot(ids)
        for index in photos.indices where ids.contains(photos[index].id) {
            var list = photos[index].keywords ?? []
            if !list.contains(trimmed) {
                list.append(trimmed)
                photos[index].keywords = list
                changed = true
            }
        }
        if changed {
            save()
            recordUndo("添加关键词", beforePhotos: beforePhotos)
            showToast("已添加关键词「\(trimmed)」")
        }
    }

    func removeKeyword(_ keyword: String, from ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if isCloudScope {
            updateCloudKeywords(ids) { tags in
                guard tags.contains(keyword) else { return false }
                tags.removeAll { $0 == keyword }
                return true
            }
            return
        }
        if canEditNativeOverlay {
            let systemIDs = ids.filter { isSystemPhotoID($0) }
            if !systemIDs.isEmpty {
                for id in systemIDs {
                    var list = systemPhoto(id: id)?.keywords ?? []
                    list.removeAll { $0 == keyword }
                    setSystemKeywords(list, ids: [id])
                }
                return
            }
        }
        let beforePhotos = photoSnapshot(ids)
        for index in photos.indices where ids.contains(photos[index].id) {
            guard var list = photos[index].keywords else { continue }
            list.removeAll { $0 == keyword }
            photos[index].keywords = list.isEmpty ? nil : list
        }
        save()
        recordUndo("移除关键词", beforePhotos: beforePhotos)
    }

    func deleteKeyword(_ keyword: String) {
        if isCloudScope {
            for (key, tags) in cloudKeywords where tags.contains(keyword) {
                var updated = tags
                updated.removeAll { $0 == keyword }
                if updated.isEmpty {
                    cloudKeywords.removeValue(forKey: key)
                } else {
                    cloudKeywords[key] = updated
                }
            }
            for index in cloudPhotos.indices {
                guard cloudPhotos[index].keywords?.contains(keyword) ?? false else { continue }
                cloudPhotos[index].keywords?.removeAll { $0 == keyword }
                if cloudPhotos[index].keywords?.isEmpty ?? false {
                    cloudPhotos[index].keywords = nil
                }
                updateCachedCloudPhoto(cloudPhotos[index])
            }
            persistCloudKeywords()
            cloudScopeCountsCacheKey = nil
            cloudVisibleCacheKey = nil
            cloudModel.metadataRevision += 1
            showToast("已删除关键词「\(keyword)」")
            return
        }
        if canEditNativeOverlay {
            // 关键词只存在于拾光的补充元数据里，索引模式下不需要遍历整库。
            let targets = systemOverlays.compactMap { id, overlay in
                (overlay.keywords?.contains(keyword) ?? false) ? id : nil
            }
            for id in targets {
                var list = systemPhoto(id: id)?.keywords ?? []
                list.removeAll { $0 == keyword }
                setSystemKeywords(list, ids: [id])
            }
        }
        let affected = Set(photos.filter { ($0.keywords ?? []).contains(keyword) }.map(\.id))
        let beforePhotos = photoSnapshot(affected)
        for index in photos.indices {
            guard var list = photos[index].keywords else { continue }
            list.removeAll { $0 == keyword }
            photos[index].keywords = list.isEmpty ? nil : list
        }
        if keywordFilter == keyword {
            keywordFilter = nil
        }
        save()
        recordUndo("删除关键词", beforePhotos: beforePhotos)
        showToast("已删除关键词「\(keyword)」")
    }

    // MARK: - Albums & folders

    func rootFolders() -> [AlbumFolder] {
        folders.filter { $0.parentID == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func childFolders(of parentID: UUID?) -> [AlbumFolder] {
        folders.filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func albums(in folderID: UUID?) -> [Album] {
        albums.filter { $0.folderID == folderID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 包含自身的文件夹子树。
    func folderSubtreeIDs(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var queue: [UUID] = [id]
        while let current = queue.popLast() {
            for child in folders where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    func systemFolderSubtreeIDs(_ id: Int64) -> Set<Int64> {
        var result: Set<Int64> = [id]
        var queue: [Int64] = [id]
        while let current = queue.popLast() {
            for child in systemFolders where child.parent == current && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    var rootAlbums: [Album] {
        albums(in: nil)
    }

    func folderPath(_ folderID: UUID?) -> String {
        guard let folderID, let folder = folders.first(where: { $0.id == folderID }) else { return "" }
        let parent = folderPath(folder.parentID)
        return parent.isEmpty ? folder.name : parent + " / " + folder.name
    }

    var folderOptions: [FolderOption] {
        folders.map { FolderOption(id: $0.id, path: folderPath($0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - 固定项目（系统项 / 相簿 / 文件夹）

    static let pinnedItemsKey = "pinned_sidebar_v3"
    /// 旧版固定列表：迁移时保留其中用户自己固定的相簿 / 文件夹。
    static let legacyPinnedItemsKey = "pinned_sidebar_v2"

    /// 首次打开图库时默认固定在「固定」分区的系统项目，顺序即侧边栏展示顺序。
    static let defaultPinnedSystemKeys = [
        "favorites", "people", "map", "places", "videos"
    ]

    /// 从当前图库读取固定项，并过滤掉已被删除的相簿与文件夹。
    func loadPinnedItems() {
        let albumIDs = Set(albums.map(\.id))
        let folderIDs = Set(folders.map(\.id))
        let smartAlbumIDs = Set(smartAlbums.map(\.id))
        func filtered(_ list: [PinnedSidebarItem]) -> [PinnedSidebarItem] {
            list.filter { item in
                switch item {
                case .system, .systemAlbum, .systemFolder:
                    // 系统图库的相簿 / 文件夹按需异步载入，不在启动时按当前列表剔除。
                    return true
                case .album(let id): return albumIDs.contains(id)
                case .smartAlbum(let id): return smartAlbumIDs.contains(id)
                case .folder(let id): return folderIDs.contains(id)
                }
            }
        }

        if let raw = metadataStore?.setting(Self.pinnedItemsKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PinnedSidebarItem].self, from: data) {
            pinnedItems = filtered(decoded)
            return
        }

        // 没有新版列表：系统项回到默认顺序，保留旧版里用户固定的相簿 / 文件夹。
        let legacyRaw = metadataStore?.setting(Self.legacyPinnedItemsKey)
            ?? metadataStore?.setting("pinned_sidebar")
        let legacy = legacyRaw.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([PinnedSidebarItem].self, from: $0) } ?? []
        let custom = legacy.filter { item in
            if case .system = item { return false }
            return true
        }
        pinnedItems = filtered(Self.defaultPinnedSystemKeys.map { .system($0) } + custom)
        savePinnedItems()
    }

    func savePinnedItems() {
        guard let data = try? JSONEncoder().encode(pinnedItems),
              let raw = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.pinnedItemsKey, raw)
    }

    func isPinned(_ item: PinnedSidebarItem) -> Bool {
        pinnedItems.contains(item)
    }

    /// 固定 / 取消固定一个系统项、相簿、智能相簿或文件夹。
    func togglePin(_ item: PinnedSidebarItem) {
        if let index = pinnedItems.firstIndex(of: item) {
            pinnedItems.remove(at: index)
        } else {
            pinnedItems.append(item)
        }
        savePinnedItems()
    }

    /// 拖动排序：把一项固定插到目标项前面（原地移动，顺序立即保存）。
    func movePinned(id: String, before targetID: String) {
        guard id != targetID,
              let from = pinnedItems.firstIndex(where: { $0.id == id }) else { return }
        let moving = pinnedItems.remove(at: from)
        let insertIndex = pinnedItems.firstIndex(where: { $0.id == targetID }) ?? pinnedItems.count
        pinnedItems.insert(moving, at: insertIndex)
        savePinnedItems()
    }

    /// 拖动排序：把一项固定移到末尾。
    func movePinnedToEnd(id: String) {
        guard let from = pinnedItems.firstIndex(where: { $0.id == id }),
              from != pinnedItems.count - 1 else { return }
        let moving = pinnedItems.remove(at: from)
        pinnedItems.append(moving)
        savePinnedItems()
    }

    var pinnedAlbums: [Album] {
        pinnedItems.compactMap { item in
            guard case .album(let id) = item else { return nil }
            return albums.first { $0.id == id }
        }
    }

    var pinnedFolders: [AlbumFolder] {
        pinnedItems.compactMap { item in
            guard case .folder(let id) = item else { return nil }
            return folders.first { $0.id == id }
        }
    }

    func createAlbum(named name: String, folderID: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let beforeAlbums = albums
        let album = Album(name: trimmed, folderID: folderID)
        albums.append(album)
        sidebarItem = .album(album.id)
        save()
        recordUndo("新建相簿", beforeAlbums: beforeAlbums)
    }

    func renameAlbum(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let beforeAlbums = albums
        albums[index].name = trimmed
        save()
        recordUndo("重命名相簿", beforeAlbums: beforeAlbums)
    }

    /// 删除相簿 / 智能相簿 / 文件夹时同步取消固定。
    func removePinned(albumIDs: Set<UUID> = [],
                      folderIDs: Set<UUID> = [],
                      smartAlbumIDs: Set<UUID> = [],
                      systemAlbumIDs: Set<Int64> = []) {
        guard !albumIDs.isEmpty || !folderIDs.isEmpty
            || !smartAlbumIDs.isEmpty || !systemAlbumIDs.isEmpty else { return }
        let before = pinnedItems.count
        pinnedItems.removeAll { item in
            switch item {
            case .system, .systemFolder: return false
            case .album(let id): return albumIDs.contains(id)
            case .smartAlbum(let id): return smartAlbumIDs.contains(id)
            case .folder(let id): return folderIDs.contains(id)
            case .systemAlbum(let id): return systemAlbumIDs.contains(id)
            }
        }
        if pinnedItems.count != before {
            savePinnedItems()
        }
    }

    func deleteAlbum(_ id: UUID) {
        let beforeAlbums = albums
        albums.removeAll { $0.id == id }
        removePinned(albumIDs: [id])
        if case .album(let current) = sidebarItem, current == id {
            sidebarItem = .allAlbums
        }
        save()
        recordUndo("删除相簿", beforeAlbums: beforeAlbums)
    }

    @discardableResult
    func createFolder(named name: String, parentID: UUID? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let beforeFolders = folders
        let folder = AlbumFolder(name: trimmed, parentID: parentID)
        folders.append(folder)
        save()
        recordUndo("新建文件夹", beforeFolders: beforeFolders)
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let beforeFolders = folders
        folders[index].name = trimmed
        save()
        recordUndo("重命名文件夹", beforeFolders: beforeFolders)
    }

    func deleteFolder(_ id: UUID) {
        let beforeFolders = folders
        let beforeAlbums = albums
        var folderIDs: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.parentID != nil && folderIDs.contains(folder.parentID!) {
                if !folderIDs.contains(folder.id) {
                    folderIDs.insert(folder.id)
                    changed = true
                }
            }
        }
        let removedAlbumIDs = Set(albums.filter { $0.folderID != nil && folderIDs.contains($0.folderID!) }.map { $0.id })
        albums.removeAll { removedAlbumIDs.contains($0.id) }
        folders.removeAll { folderIDs.contains($0.id) }
        removePinned(albumIDs: removedAlbumIDs, folderIDs: folderIDs)
        if case .album(let current) = sidebarItem, removedAlbumIDs.contains(current) {
            sidebarItem = .allAlbums
        }
        save()
        recordUndo("删除文件夹", beforeAlbums: beforeAlbums, beforeFolders: beforeFolders)
        showToast("已删除文件夹与其中的相簿")
    }

    func moveAlbum(_ id: UUID, toFolder folderID: UUID?) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let beforeAlbums = albums
        albums[index].folderID = folderID
        save()
        recordUndo("移动相簿", beforeAlbums: beforeAlbums)
        showToast(folderID == nil ? "已移到相簿顶层" : "已移到「\(folderPath(folderID))」")
    }

    func addToAlbum(_ albumID: UUID, photoIDs: Set<UUID>) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }), !photoIDs.isEmpty else { return }
        let beforeAlbums = albums
        let existing = Set(albums[index].photoIDs)
        let additions = photoIDs.subtracting(existing)
        // 按图库中的顺序追加，保证新加入项目的位置稳定，便于后续拖拽排序。
        let ordered = photos.map(\.id).filter { additions.contains($0) }
        albums[index].photoIDs.append(contentsOf: ordered)
        save()
        recordUndo("添加到相簿", beforeAlbums: beforeAlbums)
        showToast("已添加到「\(albums[index].name)」")
    }

    /// 当前所在的可重排相簿（系统相簿只读，不参与）。
    var currentAlbumID: UUID? {
        guard case .album(let id) = sidebarItem, !isReadOnlyScope else { return nil }
        return id
    }

    /// 当前相簿用户指定的封面（未指定则为 nil）。
    var currentAlbumCoverID: UUID? {
        guard let albumID = currentAlbumID else { return nil }
        return albums.first(where: { $0.id == albumID })?.coverPhotoID
    }

    /// 指定相簿封面（照片或视频均可）；传 nil 恢复自动拼图封面。
    func setAlbumCover(_ photoID: UUID?, for albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        if let photoID, !albums[index].photoIDs.contains(photoID) { return }
        guard albums[index].coverPhotoID != photoID else { return }
        let beforeAlbums = albums
        albums[index].coverPhotoID = photoID
        save()
        recordUndo("设置相簿封面", beforeAlbums: beforeAlbums)
        showToast(photoID == nil ? "已恢复自动封面" : "已设为相簿封面")
    }

    var canReorderCurrentAlbum: Bool {
        currentAlbumID != nil
    }

    /// 相簿内拖拽排序：把 moving 中的项目移动到 targetID 前/后。
    func moveAlbumPhotos(albumID: UUID, moving: Set<UUID>, targetID: UUID, after: Bool) {
        guard !moving.isEmpty, !moving.contains(targetID),
              let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        var order = albums[index].photoIDs
        let movingIDs = order.filter { moving.contains($0) }
        guard !movingIDs.isEmpty, order.contains(targetID) else { return }

        let beforeAlbums = albums
        order.removeAll { moving.contains($0) }
        guard let targetIndex = order.firstIndex(of: targetID) else { return }
        let insertIndex = after ? targetIndex + 1 : targetIndex
        order.insert(contentsOf: movingIDs, at: min(insertIndex, order.count))
        guard order != albums[index].photoIDs else { return }
        albums[index].photoIDs = order
        save()
        recordUndo("调整相簿顺序", beforeAlbums: beforeAlbums)
    }

    func removeFromCurrentAlbum(_ ids: Set<UUID>) {
        guard case .album(let albumID) = sidebarItem,
              let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let beforeAlbums = albums
        albums[index].photoIDs.removeAll { ids.contains($0) }
        // 被移除的项目如果正被用作封面，回落到自动封面。
        if let cover = albums[index].coverPhotoID, ids.contains(cover) {
            albums[index].coverPhotoID = nil
        }
        selection.removeAll()
        save()
        recordUndo("移出相簿", beforeAlbums: beforeAlbums)
    }

    func albumsContaining(_ id: UUID) -> [Album] {
        albums.filter { $0.photoIDs.contains(id) }
    }

    // MARK: - 智能相簿

    static let smartAlbumsSettingKey = "smart_albums"

    func loadSmartAlbums() {
        guard let raw = metadataStore?.setting(Self.smartAlbumsSettingKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SmartAlbum].self, from: data) else {
            smartAlbums = []
            return
        }
        smartAlbums = decoded
    }

    func persistSmartAlbums() {
        guard let encoded = try? JSONEncoder().encode(smartAlbums),
              let text = String(data: encoded, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.smartAlbumsSettingKey, text)
    }

    func presentSmartAlbumEditor(_ album: SmartAlbum? = nil) {
        if let album {
            editingSmartAlbum = album
        } else {
            var draft = SmartAlbum(name: "新建智能相簿")
            draft.rules = [SmartRule(field: .favorite, value: "是")]
            editingSmartAlbum = draft
        }
    }

    func saveSmartAlbum(_ album: SmartAlbum) {
        if let index = smartAlbums.firstIndex(where: { $0.id == album.id }) {
            smartAlbums[index] = album
        } else {
            smartAlbums.append(album)
        }
        persistSmartAlbums()
        editingSmartAlbum = nil
        navigate(to: .smartAlbum(album.id))
        showToast("已保存智能相簿「\(album.name)」")
    }

    func deleteSmartAlbum(_ id: UUID) {
        smartAlbums.removeAll { $0.id == id }
        removePinned(smartAlbumIDs: [id])
        persistSmartAlbums()
        if case .smartAlbum(let current) = sidebarItem, current == id {
            sidebarItem = .library
        }
        showToast("已删除智能相簿")
    }

    func smartAlbumCount(_ album: SmartAlbum) -> Int {
        let live = photos.filter { $0.deletedAt == nil && !$0.isHidden }
        return live.reduce(into: 0) { result, photo in
            if album.matches(photo, analysis: self.analysisIndex[photo.id]) { result += 1 }
        }
    }

    // MARK: - 批量更改

    func presentBatchChange() {
        let ids = commandTargetIDs
        guard !ids.isEmpty else {
            showToast("请先选择要更改的项目")
            return
        }
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘为只读，不支持批量更改")
            return
        }
        batchChangeTargets = ids
        showBatchChangeSheet = true
    }

    /// 传入 nil 表示不修改对应字段。
    func applyBatchChange(title: String?, date: Date?, place: String?) {
        guard !batchChangeTargets.isEmpty else { return }
        let beforePhotos = photoSnapshot(batchChangeTargets)
        var touched = 0
        for index in photos.indices where batchChangeTargets.contains(photos[index].id) {
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                photos[index].title = trimmed.isEmpty ? nil : trimmed
            }
            if let date {
                photos[index].capturedAt = date
            }
            if let place {
                let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
                photos[index].placeCity = trimmed.isEmpty ? nil : trimmed
                photos[index].placePOI = trimmed.isEmpty ? nil : trimmed
            }
            touched += 1
        }
        save()
        recordUndo("批量更改", beforePhotos: beforePhotos)
        showToast("已更改 \(touched) 项")
        showBatchChangeSheet = false
        batchChangeTargets = []
    }

    var albumsSorted: [Album] {
        albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
