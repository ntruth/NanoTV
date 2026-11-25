import Foundation
import AppKit

/// 图库级操作的一步撤销记录：`undo` / `redo` 只回填内存状态并落盘，
/// 不再经过会重新记录撤销的操作入口。
struct LibraryUndoStep {
    let title: String
    let undo: (LibraryStore) -> Void
    let redo: (LibraryStore) -> Void
}

/// 图库元数据操作的撤销 / 重做。
/// 只覆盖可逆的内存元数据变更（删除进最近删除、相簿与文件夹、收藏 / 隐藏 / 关键词 / 批量更改、合并重复）；
/// 永久删除、清空最近删除、导入、编辑原图与压缩不进入撤销栈。
extension LibraryStore {
    /// 撤销栈上限：只保留最近若干步，避免内存里堆积过多快照。
    static let undoLimit = 30

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 记录一步已经完成的元数据变更。
    /// - Parameters:
    ///   - beforePhotos: 变更前受影响照片的完整快照（键为照片 ID）；当前状态即重做目标。
    ///   - beforeAlbums: 变更前的相簿列表；传 nil 表示本次不涉及相簿。
    ///   - beforeFolders: 变更前的文件夹列表；传 nil 表示本次不涉及文件夹。
    func recordUndo(_ title: String,
                    beforePhotos: [UUID: PhotoItem] = [:],
                    beforeAlbums: [Album]? = nil,
                    beforeFolders: [AlbumFolder]? = nil) {
        // 系统图库与网盘只读，官方图库的补充元数据也不纳入撤销。
        guard !isReadOnlyScope, !isSystemScope, !isCloudScope else { return }
        let afterPhotos = photoSnapshot(Set(beforePhotos.keys))
        let afterAlbums = beforeAlbums.map { _ in albums }
        let afterFolders = beforeFolders.map { _ in folders }

        let step = LibraryUndoStep(
            title: title,
            undo: { store in
                store.applyUndoState(photos: beforePhotos, albums: beforeAlbums, folders: beforeFolders)
                store.showToast("已撤销：\(title)")
            },
            redo: { store in
                store.applyUndoState(photos: afterPhotos, albums: afterAlbums, folders: afterFolders)
                store.showToast("已重做：\(title)")
            })
        undoStack.append(step)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
        syncUndoActions()
    }

    /// 抓取指定照片的完整快照：只保存受影响的项目，撤销栈的内存占用与选择规模成正比。
    func photoSnapshot(_ ids: Set<UUID>) -> [UUID: PhotoItem] {
        guard !ids.isEmpty else { return [:] }
        var result: [UUID: PhotoItem] = [:]
        for photo in photos where ids.contains(photo.id) {
            result[photo.id] = photo
        }
        return result
    }

    /// 撤销 / 重做共用的状态回填：只覆盖快照里的字段，其余内容保持当前值。
    private func applyUndoState(photos snapshot: [UUID: PhotoItem],
                                albums newAlbums: [Album]?,
                                folders newFolders: [AlbumFolder]?) {
        if !snapshot.isEmpty {
            for index in photos.indices {
                guard let item = snapshot[photos[index].id] else { continue }
                photos[index] = item
            }
        }
        if let newAlbums { albums = newAlbums }
        if let newFolders { folders = newFolders }
        // 撤销「删除相簿 / 文件夹」后当前范围可能已不存在，回到相簿总览。
        if case .album(let id) = sidebarItem, !albums.contains(where: { $0.id == id }) {
            sidebarItem = .allAlbums
        }
        if case .folder(let id) = sidebarItem, !folders.contains(where: { $0.id == id }) {
            sidebarItem = .allAlbums
        }
        save()
    }

    /// 菜单与 ⌘Z 的统一入口：文本输入中把撤销让给系统文本框，避免抢走输入框的回退。
    func performUndoCommand() {
        // 编辑器有自己的调整历史，⌘Z 由编辑器处理。
        guard editorID == nil else { return }
        if forwardTextEdit(redoing: false) { return }
        performUndo()
    }

    func performRedoCommand() {
        guard editorID == nil else { return }
        if forwardTextEdit(redoing: true) { return }
        performRedo()
    }

    private func forwardTextEdit(redoing: Bool) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView,
              let manager = responder.undoManager else { return false }
        if redoing {
            manager.redo()
        } else {
            manager.undo()
        }
        return true
    }

    func performUndo() {
        guard !needsLibrarySetup, let step = undoStack.popLast() else { return }
        redoStack.append(step)
        syncUndoActions()
        step.undo(self)
    }

    func performRedo() {
        guard !needsLibrarySetup, let step = redoStack.popLast() else { return }
        undoStack.append(step)
        syncUndoActions()
        step.redo(self)
    }

    /// 切换图库 / 重新载入时清空：撤销步骤只对记录它的那个图库有效。
    func resetUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        syncUndoActions()
    }

    private func syncUndoActions() {
        undoActionName = undoStack.last?.title
        redoActionName = redoStack.last?.title
    }
}
