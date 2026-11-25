import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Selection

    func handleTap(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift),
           let anchor = selectionAnchorID,
           let anchorIndex = visiblePhotos.firstIndex(where: { $0.id == anchor }),
           let targetIndex = visiblePhotos.firstIndex(where: { $0.id == id }) {
            let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            selection = Set(visiblePhotos[range].map { $0.id })
            return
        }
        if flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            selectionAnchorID = id
        } else {
            selection = [id]
            selectionAnchorID = id
        }
    }

    /// 键盘方向键移动选择；delta 为正表示向后（右/下）。
    func moveSelection(by delta: Int) {
        // 「相似照片」是过滤后的固定集合：选择只在屏幕上这份列表里移动。
        if similarScope != nil {
            // 堆叠形态下屏幕上只有代表图：方向键按屏幕顺序移动，不能跳到收起的成员上。
            let items = isStackingEnabled ? stackedPhotos(visiblePhotos) : visiblePhotos
            guard !items.isEmpty else { return }
            guard let current = selection.first.flatMap({ id in
                items.firstIndex(where: { $0.id == id })
            }) else {
                selection = [items[0].id]
                selectionAnchorID = items[0].id
                viewerIndexCache = nil
                return
            }
            let next = min(items.count - 1, max(0, current + delta))
            guard next != current else { return }
            selection = [items[next].id]
            selectionAnchorID = items[next].id
            viewerIndexCache = nil
            return
        }
        // 系统图库索引：位置与相邻项都由索引给出，跨越未加载窗口也能继续移动。
        if isSystemPagedScope, let query = systemPagedQuery, let index = systemIndex,
           let currentID = selection.first {
            let total = visibleCount
            guard total > 0 else { return }
            let current = viewerQueryIndex(of: currentID)
            if abs(delta) == 1 {
                guard !(current == 0 && delta < 0), !(current == total - 1 && delta > 0) else { return }
                guard let target = index.neighbor(of: currentID, delta: delta, in: query) else { return }
                selection = [target.id]
                selectionAnchorID = target.id
                // 网格里移动选择不预写下标：窗口可能在移动过程中重新锚定，
                // 写下去的错误序号会一直留到打开查看器之后。
                viewerIndexCache = nil
                revealInWindow(target.id)
                return
            }
            let nextIndex = current.map { min(total - 1, max(0, $0 + delta)) }
                ?? (delta >= 0 ? 0 : total - 1)
            guard let target = index.page(query, offset: nextIndex, limit: 1).first else { return }
            selection = [target.id]
            selectionAnchorID = target.id
            viewerIndexCache = nil
            revealInWindow(target.id)
            return
        }
        // 大图库：位置与目标都由 SQLite 给出，跨越未加载的窗口也能继续移动。
        if isPagedScope, let query = pagedQuery, let store = metadataStore {
            let total = visibleCount
            guard total > 0 else { return }
            let current = selection.first.flatMap { viewerQueryIndex(of: $0) }
            // 单步移动走 keyset 查询，长按方向键不会有 O(偏移量) 的开销。
            if let current, abs(delta) == 1, let currentID = selection.first {
                guard !(current == 0 && delta < 0), !(current == total - 1 && delta > 0) else { return }
                guard let target = store.neighbor(of: currentID, delta: delta, in: query) else { return }
                selection = [target.id]
                selectionAnchorID = target.id
                viewerIndexCache = nil
                revealInWindow(target.id)
                return
            }
            let nextIndex = current.map { min(total - 1, max(0, $0 + delta)) }
                ?? (delta >= 0 ? 0 : total - 1)
            guard let target = store.photo(atOffset: nextIndex, in: query) else { return }
            selection = [target.id]
            selectionAnchorID = target.id
            viewerIndexCache = nil
            revealInWindow(target.id)
            return
        }
        let items = isStackingEnabled ? stackedPhotos(visiblePhotos) : visiblePhotos
        guard !items.isEmpty else { return }
        let currentIndex = selection.first.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(items.count - 1, max(0, currentIndex + delta))
        } else {
            nextIndex = delta >= 0 ? 0 : items.count - 1
        }
        let id = items[nextIndex].id
        selection = [id]
        selectionAnchorID = id
        scrollTargetID = id
    }

    /// 让分页窗口包含指定照片：已加载就直接滚动，否则重新取目标附近的一页。
    /// - Parameter minimal: 目标已可见时不再移动（关闭查看器时使用，避免网格整体跳位）。
    func revealInWindow(_ id: UUID, minimal: Bool = false) {
        scrollTargetMinimal = minimal
        if isSystemPagedScope {
            if systemWindowPhotos.contains(where: { $0.id == id }) {
                scrollTargetID = id
            } else {
                focusWindow(on: id)
            }
            return
        }
        if windowPhotos.contains(where: { $0.id == id }) {
            scrollTargetID = id
        } else {
            focusWindow(on: id)
        }
    }

    func openSelectionInViewer() {
        // 优先打开最近一次点击/方向键定位的项目，而不是 Set 中的任意一张。
        if let anchor = selectionAnchorID, selection.contains(anchor) {
            openViewer(anchor)
            return
        }
        if let id = visiblePhotos.first(where: { selection.contains($0.id) })?.id {
            openViewer(id)
        } else if let id = selection.first {
            // 分页模式下选中的项目可能不在已加载窗口里。
            openViewer(id)
        }
    }

    func selectAll() {
        // 系统图库：全选目标是「当前范围的全部照片」，而不是已经加载的分页窗口。
        if isSystemPagedScope, let query = systemPagedQuery, let index = systemIndex {
            Task {
                // 几十万条 UUID 的读取与建集合都放在后台，避免全选瞬间卡住界面。
                let result = await Task.detached(priority: .userInitiated) {
                    let ids = index.allIDs(query)
                    return (ids, Set(ids))
                }.value
                guard let first = result.0.first else { return }
                selection = result.1
                selectionAnchorID = first
            }
            return
        }
        // 大图库只取 id 列，避免为了全选把全部照片读进内存。
        if isPagedScope, let query = pagedQuery, let store = metadataStore {
            Task {
                let ids = await Task.detached(priority: .userInitiated) {
                    store.allIDs(query)
                }.value
                guard !ids.isEmpty else { return }
                selection = Set(ids)
                selectionAnchorID = ids.first
            }
            return
        }
        selection = Set(visiblePhotos.map { $0.id })
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: - Actions

    /// 收藏只改本地元数据；网络存储与官方「照片」图库（拾光补充元数据）也允许。
    var canToggleFavorite: Bool {
        !isReadOnlyScope || isCloudScope || canEditNativeOverlay
    }

    func toggleFavorite(_ id: UUID) {
        if let photo = anyPhoto(id: id), photo.isCloud {
            setCloudFavorite(!photo.isFavorite, for: [id])
            return
        }
        if let photo = anyPhoto(id: id), photo.isSystem, canEditNativeOverlay {
            setSystemFavorite(!photo.isFavorite, ids: [id])
            return
        }
        guard !isSystemScope, let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let beforePhotos = photoSnapshot([id])
        photos[index].isFavorite.toggle()
        save()
        recordUndo(photos[index].isFavorite ? "设为收藏" : "取消收藏", beforePhotos: beforePhotos)
    }

    func toggleFavoriteSelection() {
        toggleFavorite(ids: selection)
    }

    /// 一组项目是否全部已收藏 / 已隐藏：右键菜单文案用。
    /// 逐项调用 `anyPhoto` 在大选区下是 O(n²)，这里按来源各遍历一次。
    func selectionCommonFlags(_ ids: Set<UUID>) -> (allFavorite: Bool, allHidden: Bool) {
        guard !ids.isEmpty else { return (false, false) }
        var remaining = ids
        var allFavorite = true
        var allHidden = true

        func consume(_ photo: PhotoItem) {
            remaining.remove(photo.id)
            if !photo.isFavorite { allFavorite = false }
            if !photo.isHidden { allHidden = false }
        }
        for photo in photos where remaining.contains(photo.id) {
            consume(photo)
        }
        for photo in cloudPhotos where remaining.contains(photo.id) {
            consume(photo)
        }
        for id in remaining {
            guard let item = systemPhoto(id: id) else { continue }
            consume(item)
        }
        return (allFavorite, allHidden)
    }

    /// 对一组项目切换收藏（右键多选 / 菜单 / 工具栏共用）。
    /// 全部已收藏时取消收藏，否则统一设为收藏。
    func toggleFavorite(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if isCloudScope {
            let shouldFavorite = !ids.allSatisfy { anyPhoto(id: $0)?.isFavorite == true }
            setCloudFavorite(shouldFavorite, for: ids)
            return
        }
        if isSystemScope, canEditNativeOverlay {
            let shouldFavorite = !ids.allSatisfy { anyPhoto(id: $0)?.isFavorite == true }
            setSystemFavorite(shouldFavorite, ids: ids)
            return
        }
        guard !isReadOnlyScope else { return }
        let shouldFavorite = !ids.allSatisfy { photo(id: $0)?.isFavorite == true }
        let beforePhotos = photoSnapshot(ids)
        for index in photos.indices where ids.contains(photos[index].id) {
            photos[index].isFavorite = shouldFavorite
        }
        save()
        recordUndo(shouldFavorite ? "设为收藏" : "取消收藏", beforePhotos: beforePhotos)
    }

    func toggleFavoriteCurrent() {
        guard canToggleFavorite else { return }
        if let viewerID {
            toggleFavorite(viewerID)
        } else if !selection.isEmpty {
            toggleFavoriteSelection()
        }
    }

    func setHidden(_ ids: Set<UUID>, hidden: Bool) {
        if isSystemScope, canEditNativeOverlay {
            guard !ids.isEmpty else { return }
            setSystemHidden(hidden, ids: ids)
            if let viewerID, ids.contains(viewerID) { self.viewerID = nil }
            selection.removeAll()
            return
        }
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        let beforePhotos = photoSnapshot(ids)
        for index in photos.indices where ids.contains(photos[index].id) {
            photos[index].isHidden = hidden
        }
        if let viewerID, ids.contains(viewerID) {
            self.viewerID = nil
        }
        selection.removeAll()
        save()
        recordUndo(hidden ? "隐藏" : "取消隐藏", beforePhotos: beforePhotos)
    }

    func delete(_ ids: Set<UUID>) {
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        // 已经在最近删除里，再次删除就是永久删除。
        if sidebarItem == .trash {
            confirmPermanentDelete(ids)
            return
        }
        let beforePhotos = photoSnapshot(ids)
        let beforeAlbums = albums
        let now = Date()
        for index in photos.indices where ids.contains(photos[index].id) {
            photos[index].deletedAt = now
        }
        // 移动进最近删除时同样要脱离相簿（含封面引用），恢复后再按需重新加入。
        detachFromAlbums(ids)
        if let viewerID, ids.contains(viewerID) {
            self.viewerID = nil
        }
        selection.removeAll()
        save()
        recordUndo("移入最近删除", beforePhotos: beforePhotos, beforeAlbums: beforeAlbums)
        showToast("已移至最近删除")
    }

    func restore(_ ids: Set<UUID>) {
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        let beforePhotos = photoSnapshot(ids)
        for index in photos.indices where ids.contains(photos[index].id) {
            photos[index].deletedAt = nil
        }
        selection.removeAll()
        save()
        recordUndo("恢复", beforePhotos: beforePhotos)
        showToast("已恢复")
    }

    /// 最近删除中的项目按设置保留期自动清理；保留期为 0 时不自动删除。
    func purgeExpiredTrashIfNeeded() {
        let days = AppSettings.shared.trashRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        // 只有真正位于「最近删除」且超过保留期的项目才会被清理；
        // 未删除项目的 deletedAt 为 nil，绝不能被当成过期项。
        let expired = photos.filter { photo in
            guard let deletedAt = photo.deletedAt else { return false }
            return deletedAt < cutoff
        }
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.id))
        for photo in expired {
            purgeAssetArtifacts(photo)
        }
        photos.removeAll { ids.contains($0.id) }
        purgeAssetMetadata(ids)
        if let viewerID, ids.contains(viewerID) {
            self.viewerID = nil
        }
        save()
    }

    func deletePermanently(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let targets = ids.compactMap { photo(id: $0) }
        for photo in targets {
            purgeAssetArtifacts(photo)
        }
        photos.removeAll { ids.contains($0.id) }
        purgeAssetMetadata(ids)
        if let viewerID, ids.contains(viewerID) {
            self.viewerID = nil
        }
        selection.removeAll()
        save()
        showToast("已永久删除")
    }

    /// 菜单与快捷键统一的操作目标：优先查看器里的项目，其次多选。
    var commandTargetIDs: Set<UUID> {
        if let viewerID { return [viewerID] }
        return selection
    }

    /// 永久删除前先弹出确认卡片；真正执行在 `performPendingDeletion()`。
    func confirmPermanentDelete(_ ids: Set<UUID>) {
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        pendingDeletion = DeleteRequest(ids: ids, kind: .permanent)
    }

    func toggleHiddenCommand() {
        let ids = commandTargetIDs
        if isSystemScope, canEditNativeOverlay {
            guard !ids.isEmpty else { return }
            let shouldHide = !ids.allSatisfy { anyPhoto(id: $0)?.isHidden == true }
            setHidden(ids, hidden: shouldHide)
            showToast(shouldHide ? "已隐藏" : "已取消隐藏")
            return
        }
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        let shouldHide = !ids.allSatisfy { photo(id: $0)?.isHidden == true }
        setHidden(ids, hidden: shouldHide)
        showToast(shouldHide ? "已隐藏" : "已取消隐藏")
    }

    /// 非破坏性旋转：只更新旋转元数据，原文件不变。
    func rotateCommand(clockwise: Bool) {
        let ids = commandTargetIDs
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        var rotatedCount = 0
        let delta = clockwise ? 90 : -90

        for index in photos.indices where ids.contains(photos[index].id) {
            var photo = photos[index]
            guard !photo.isVideo else { continue }
            let next = ((photo.rotationAngle + delta) % 360 + 360) % 360
            photo.rotation = next == 0 ? nil : next
            photo.editVersion += 1
            ImportService.generateThumbnail(for: photo)
            photos[index] = photo
            ImageLoader.invalidate(photo: photo)
            rotatedCount += 1
        }

        guard rotatedCount > 0 else {
            showToast("所选项目不支持旋转")
            return
        }
        save()
        showToast(clockwise ? "已向右旋转 \(rotatedCount) 张" : "已向左旋转 \(rotatedCount) 张")
    }

    func copySelectionToPasteboard() {
        let targets = commandTargetIDs.compactMap { anyPhoto(id: $0) }
        guard !targets.isEmpty else { return }
        let urls = targets.filter { !$0.isCloud }.map { LibraryPaths.exportURL(for: $0) as NSURL }
        guard !urls.isEmpty else {
            showToast("云端项目请使用「导出」保存到本地")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        showToast("已复制 \(urls.count) 个项目")
    }

    /// 从剪贴板粘贴：支持文件 URL，以及直接复制的图片数据（PNG / TIFF）。
    func pasteFromPasteboard() {
        // 「照片」菜单里的「粘贴」绑定了 ⌘V，会抢走文本框（API Key、搜索、智能助手输入等）的粘贴。
        // 焦点在可编辑文本框时，把 ⌘V 交还给系统做普通文本粘贴。
        let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if let editor = keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.paste(nil)
            return
        }
        guard !isReadOnlyScope else {
            showToast("当前视图不支持粘贴")
            return
        }
        let pasteboard = NSPasteboard.general

        var sources: [URL] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            sources = urls.filter { ImportService.isSupported($0) }
        }

        var temporaryURLs: [URL] = []
        if sources.isEmpty {
            let imageTypes: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.tiff, "tiff")]
            for (type, ext) in imageTypes {
                guard let data = pasteboard.data(forType: type) else { continue }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Pasted-\(UUID().uuidString).\(ext)")
                if (try? data.write(to: url)) != nil {
                    sources = [url]
                    temporaryURLs = [url]
                }
                break
            }
        }

        guard !sources.isEmpty else {
            showToast("剪贴板中没有可导入的照片或视频")
            return
        }

        let inputs = sources
        Task {
            var imported: [PhotoItem] = []
            let batchID = UUID()
            for url in inputs {
                // 统一走 IngestService 的本地文件入口，不再直接调 ImportService。
                let service = ingestService
                let item = await Task.detached(priority: .userInitiated) {
                    try? service.importLocalFile(url)
                }.value
                if var item {
                    item.importBatchID = batchID
                    imported.append(item)
                }
            }
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
            guard !imported.isEmpty else {
                showToast("粘贴失败")
                return
            }
            photos.append(contentsOf: imported)
            selection = Set(imported.map(\.id))
            save()
            // 在相簿里粘贴：新项目同时加入当前相簿，否则用户会以为「粘贴没反应」。
            if let albumID = currentAlbumID {
                addToAlbum(albumID, photoIDs: Set(imported.map(\.id)))
            } else if case .smartAlbum(_) = sidebarItem {
                showToast("已粘贴 \(imported.count) 项；智能相簿会按条件自动收录")
            } else {
                showToast("已粘贴 \(imported.count) 项")
            }
        }
    }

    /// 复制照片（⌘D）：复制原文件，生成一个独立的图库项目。
    func duplicateCommand() {
        let ids = commandTargetIDs
        guard !isReadOnlyScope, !ids.isEmpty else { return }
        LibraryPaths.prepare()

        var copies: [PhotoItem] = []
        var failed = 0

        for source in photos where ids.contains(source.id) {
            var copy = source
            copy.id = UUID()

            let ext = (source.filename as NSString).pathExtension
            let filename = "\(copy.id.uuidString).\(ext.isEmpty ? "jpg" : ext)"
            let destination = LibraryPaths.originals
                .appendingPathComponent(LibraryPaths.shard(for: copy.id), isDirectory: true)
                .appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: LibraryPaths.originalURL(for: source),
                                                 to: destination)
            } catch {
                failed += 1
                continue
            }

            copy.filename = filename
            copy.originalName = Self.duplicateName(source.originalName)
            copy.addedAt = Date()
            copy.deletedAt = nil
            copy.isDuplicateItem = true
            copy.editVersion += 1

            if let editedFilename = source.editedFilename {
                let editedName = copy.id.uuidString + ".jpg"
                let editedSource = LibraryPaths.edited.appendingPathComponent(editedFilename)
                let editedTarget = LibraryPaths.edited.appendingPathComponent(editedName)
                if (try? FileManager.default.copyItem(at: editedSource, to: editedTarget)) != nil {
                    copy.editedFilename = editedName
                } else {
                    copy.editedFilename = nil
                }
            } else {
                copy.editedFilename = nil
            }

            if let liveFilename = source.livePhotoFilename {
                let liveSource = LibraryPaths.originals
                    .appendingPathComponent(LibraryPaths.shard(for: source.id), isDirectory: true)
                    .appendingPathComponent(liveFilename)
                let liveTarget = destination.deletingLastPathComponent()
                    .appendingPathComponent(liveFilename)
                if (try? FileManager.default.copyItem(at: liveSource, to: liveTarget)) == nil {
                    copy.isLivePhoto = false
                    copy.livePhotoFilename = nil
                }
            }

            ImportService.generateThumbnail(for: copy)
            copies.append(copy)
        }

        guard !copies.isEmpty else {
            showToast(failed > 0 ? "复制失败" : "没有可复制的项目")
            return
        }

        photos.append(contentsOf: copies)
        selection = Set(copies.map(\.id))
        save()
        // 在相簿里复制：副本同样留在当前相簿。
        if let albumID = currentAlbumID {
            addToAlbum(albumID, photoIDs: Set(copies.map(\.id)))
        } else {
            showToast(failed == 0 ? "已复制 \(copies.count) 项" : "已复制 \(copies.count) 项，\(failed) 项失败")
        }
    }

    static func duplicateName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? stem + " 副本" : "\(stem) 副本.\(ext)"
    }

    /// 打印所选项目（⌘P）：每张照片一页，等比缩放居中。
    func printCommand() {
        let items = commandTargetIDs.compactMap { anyPhoto(id: $0) }
        guard !items.isEmpty else {
            showToast("没有可打印的项目")
            return
        }
        let localItems = items.filter { !$0.isCloud }
        guard !localItems.isEmpty else {
            showToast("云端项目请先导出后再打印")
            return
        }

        let printView = PhotoPrintView(items: localItems)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.topMargin = 30
        info.bottomMargin = 30
        info.leftMargin = 30
        info.rightMargin = 30
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = "拾光照片"
        operation.run()
    }

    /// 幻灯片播放（⌥⌘P）。
    func presentSlideshow() {
        guard !visiblePhotos.isEmpty else {
            showToast("没有可播放的项目")
            return
        }
        // 幻灯片以窗口级覆盖方式呈现，先关闭查看器避免两层键盘监听。
        viewerID = nil
        showSlideshow = true
    }

    func revealCommandTargetsInFinder() {
        let targets = commandTargetIDs.compactMap { anyPhoto(id: $0) }
        guard !targets.isEmpty else { return }
        if targets.count == 1, let id = targets.first?.id {
            revealInFinder(id)
            return
        }
        let urls = targets.filter { !$0.isCloud }.map { LibraryPaths.exportURL(for: $0) }
        guard !urls.isEmpty else {
            showToast("云端项目请使用「导出」保存到本地")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openEditorFromCommand() {
        for id in commandTargetIDs {
            guard let photo = anyPhoto(id: id), !photo.isVideo else { continue }
            if photo.isSystem {
                guard canWriteSystemLibrary else { continue }
            } else if photo.isReadOnly {
                continue
            }
            openEditor(id)
            return
        }
    }

    /// ⌘F：请求顶栏的自定义搜索框获得焦点（由 `GalleryView` 响应）。
    func focusSearchField() {
        searchFocusRequest += 1
    }

    func emptyTrash() {
        let ids = Set(photos.filter { $0.deletedAt != nil }.map { $0.id })
        deletePermanently(ids)
    }

    /// 清空最近删除前展示确认卡片；真正执行在 `performPendingDeletion()`。
    func confirmEmptyTrash() {
        let ids = Set(photos.filter { $0.deletedAt != nil }.map { $0.id })
        guard !ids.isEmpty else {
            showToast("最近删除是空的")
            return
        }
        pendingDeletion = DeleteRequest(ids: ids, kind: .emptyTrash)
    }
}
