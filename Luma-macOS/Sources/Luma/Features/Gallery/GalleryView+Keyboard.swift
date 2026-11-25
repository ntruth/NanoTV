import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaCore

/// 图库的键盘操作：快捷键与上下移动。

extension GalleryView {
    // MARK: - Keyboard

    func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    var gridColumnCount: Int {
        store.gridColumnCount
    }

    /// 把真实网格宽度回传给 Store，设置面板「每行几张」与实际网格保持一致。
    func updateGridContentWidth(_ width: CGFloat) {
        let value = max(120, width)
        if abs(store.gridContentWidth - value) > 0.5 {
            store.gridContentWidth = value
        }
        store.reconcileDefaultDensitiesIfNeeded()
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard isGridScope || showsWindowSearchGrid,
              !isFavoritesDigestHub,
              store.viewerID == nil,
              store.editorID == nil,
              !store.showSlideshow,
              store.activeMemory == nil,
              store.activeTrip == nil,
              !store.showNewAlbumSheet,
              !store.showKeywordManager,
              !store.showShortcutHelp,
              // 确认卡片打开时，把键盘交给卡片（避免误触网格操作）。
              !store.hasPendingConfirmation else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            // 文本输入中不劫持 ⌘A/⌘C/⌘F 等系统文本命令。
            if isEditingText { return false }
            if event.keyCode == 51 {
                // 只读的系统图库在可写（PhotoKit 指向当前库）时允许移到「照片」的最近删除。
                let systemWritable = store.isSystemScope && store.canWriteSystemLibrary
                guard !store.isReadOnlyScope || systemWritable else { return false }
                let ids = selectionModel.ids
                guard !ids.isEmpty else { return false }
                // 最近删除里再按删除就是永久删除（需确认）。
                if flags.contains(.option) || store.sidebarItem == .trash {
                    guard !store.isReadOnlyScope else { return false }
                    store.confirmPermanentDelete(ids)
                } else {
                    store.confirmDelete(ids)
                }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                store.selectAll()
                return true
            case "c":
                store.copySelectionToPasteboard()
                return true
            case "v":
                guard !store.isReadOnlyScope else { return false }
                store.pasteFromPasteboard()
                return true
            case "d":
                guard !store.isReadOnlyScope, !selectionModel.ids.isEmpty else { return false }
                store.duplicateCommand()
                return true
            case "f":
                store.focusSearchField()
                return true
            case "r":
                guard !store.isReadOnlyScope else { return false }
                store.rotateCommand(clockwise: !flags.contains(.option))
                return true
            case "0":
                store.resetZoom()
                return true
            default:
                return false
            }
        }
        // 方向键自带 Function / 小键盘标记，不能因此丢弃；
        // 只屏蔽会与菜单快捷键冲突的修饰键。
        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于这条守卫匹配。
        if handleCustomShortcut(event) { return true }

        guard flags.intersection([.option, .control]).isEmpty else { return false }

        // 正在输入搜索词且尚未选中任何项目时，把方向键留给文本输入。
        if isEditingText, selectionModel.ids.isEmpty { return false }

        switch event.keyCode {
        case 123:
            // 「图库」页新照片在底部时，数据顺序与视觉顺序相反，左右键跟随视觉方向。
            store.moveSelection(by: store.timelineShowsNewestAtBottom ? 1 : -1)
            return true
        case 124:
            store.moveSelection(by: store.timelineShowsNewestAtBottom ? -1 : 1)
            return true
        case 126:
            moveSelectionVertically(-1)
            return true
        case 125:
            moveSelectionVertically(1)
            return true
        case 47:
            guard !flags.contains(.shift), !selectionModel.ids.isEmpty,
                  store.canToggleFavorite else { return false }
            store.toggleFavoriteSelection()
            return true
        case 36, 49:
            // 搜索框等文本输入中，空格与回车要正常输入文字。
            if isEditingText { return false }
            guard !selectionModel.ids.isEmpty else { return false }
            store.openSelectionInViewer()
            return true
        case 53:
            guard !selectionModel.ids.isEmpty else { return false }
            store.clearSelection()
            return true
        default:
            return false
        }
    }

    /// 设置 › 快捷键里可自定义的网格动作。
    func handleCustomShortcut(_ event: NSEvent) -> Bool {
        // 搜索框等文本输入中，回车 / 字母都要正常输入文字。
        guard !isEditingText else { return false }
        if ShortcutStore.matches(event, .galleryOpen) {
            guard !selectionModel.ids.isEmpty else { return false }
            store.openSelectionInViewer()
            return true
        }
        if ShortcutStore.matches(event, .galleryFavorite) {
            guard !selectionModel.ids.isEmpty, store.canToggleFavorite else { return false }
            store.toggleFavoriteSelection()
            return true
        }
        return false
    }

    // MARK: - 键盘上下移动

    /// 上下方向键按单元格的真实位置找「下一排」，落在正下方。
    /// 正方形与瀑布流、跨分段边界都适用；找不到可用行时退回按列数步进。
    func moveSelectionVertically(_ direction: Int) {
        let frames = frameCache.frames
        guard let currentID = navigationAnchorID(), let current = frames[currentID] else {
            store.moveSelection(by: direction)
            return
        }

        let epsilon: CGFloat = 1
        let candidates = frames.filter { id, frame in
            guard id != currentID else { return false }
            return direction > 0
                ? frame.minY > current.minY + epsilon
                : frame.minY < current.minY - epsilon
        }
        guard !candidates.isEmpty else {
            // 下一排还没被 LazyVGrid 创建：按列数步进，触发滚动后再继续沿真实位置移动。
            // 「图库」页新照片在底部时，数据顺序与视觉顺序相反，步进方向也要跟着翻转。
            let step = store.timelineShowsNewestAtBottom ? -direction : direction
            store.moveSelection(by: step * gridColumnCount)
            return
        }

        // 先锁定最近的一排（上方取最大 minY，下方取最小 minY），再选水平中心最近的一格。
        let targetY = direction > 0
            ? candidates.values.map(\.minY).min() ?? current.minY
            : candidates.values.map(\.minY).max() ?? current.minY
        let row = candidates.filter { abs($0.value.minY - targetY) <= 1.5 }
        guard let best = row.min(by: {
            abs($0.value.midX - current.midX) < abs($1.value.midX - current.midX)
        }) else { return }

        selectionModel.ids = [best.key]
        store.selectionAnchorID = best.key
        store.scrollTargetID = best.key
    }

    func navigationAnchorID() -> UUID? {
        if let anchor = store.selectionAnchorID, selectionModel.ids.contains(anchor) {
            return anchor
        }
        return selectionModel.ids.first
    }
}
