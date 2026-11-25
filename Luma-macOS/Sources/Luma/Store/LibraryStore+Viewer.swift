import Foundation
import AppKit
import AVFoundation
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - Viewer

    func openViewer(_ id: UUID) {
        openViewer(id, context: [])
    }

    /// 从非图库网格（地图 / 地点 / 卡片墙）打开查看器：序号、总数与左右翻页都以这份列表为准。
    /// 传空数组等价于普通打开（按当前图库查询定位）。
    func openViewer(_ id: UUID, context: [PhotoItem]) {
        if cinemaPlaybackPhoto?.id != id {
            finishCinemaPlayback()
            cinemaPlaybackPhoto = nil
        }
        // 打开的不是虚拟分集时，结束上一次网络资源播放。
        if catalogPlaybackPhoto(for: id) == nil {
            finishCatalogPlayback()
        }
        // 打开的不是电视频道时，结束上一次直播会话。
        if tvPlaybackPhoto(for: id) == nil {
            finishTVPlayback()
        }
        viewerContextPhotos = context
        // 只让查看器的插入 / 移除参与动画：整窗级的 animation 会把网格、
        // 工具栏和选中态的更新一起塞进弹簧动画，开合时容易出现残影或掉帧。
        withAnimation(AppSettings.shared.motion.overlay) {
            viewerID = id
        }
        selection = [id]
        recordView(id)
        // 打开新照片时丢掉上一次的下标缓存，按当前查询重新算一次序号与邻居，
        // 避免沿用上一张的 ±1 结果把偏差带进来。
        viewerIndexCache = nil
        viewerPositionCache = nil
        // 连拍：先按当前照片载入整组，后面的翻页与序号都在组内进行。
        refreshViewerBurstGroup()
        // 非分页范围下这里会把胶片条清空，避免沿用上一次的窗口片段。
        refreshViewerStripIfNeeded()
        if AppSettings.shared.showInfoOnOpen {
            showInfoPanel = true
        }
    }

    func closeViewer() {
        finishCinemaPlayback()
        finishCatalogPlayback()
        finishTVPlayback()
        let lastID = viewerID
        withAnimation(AppSettings.shared.motion.overlay) {
            viewerID = nil
        }
        cinemaPlaybackPhoto = nil
        viewerStrip = []
        viewerStripKey = nil
        viewerContextPhotos = []
        viewerIndexCache = nil
        viewerPositionCache = nil
        viewerModel.videoQuarterTurns = 0
        clearViewerBurstState()
        // 从网络资源详情页起的播：关闭后回到那一页详情，而不是频道列表。
        restoreCatalogDetailIfNeeded()
        // 「所有照片」时间轴里翻页可能已经走出已加载窗口：返回网格时把它滚回来。
        // 用最小滚动：目标本来就可见时不动，避免关闭动画期间网格整体跳位。
        if let lastID, isTimelineScope, isPagedScope {
            revealInWindow(lastID, minimal: true)
        }
    }

    /// 按「点击照片时」设置打开：查看器 / 编辑器 / 系统默认应用。
    func openPhoto(_ id: UUID, by mode: PhotoOpenMode) {
        switch mode {
        case .viewer:
            openViewer(id)
        case .editor:
            // 视频与只读项目（系统图库 / 只读网盘）仍交给查看器。
            if let photo = anyPhoto(id: id), !photo.isVideo, !photo.isReadOnly {
                openEditor(id)
            } else {
                openViewer(id)
            }
        case .systemApp:
            openInSystemApp(id)
        }
    }

    func viewerStep(_ delta: Int) {
        guard let viewerID else { return }
        let step = delta > 0 ? 1 : -1
        // 连拍：在原组内按拍摄顺序翻页，与官方「照片」一致（翻到末尾回到第一张）。
        if viewerModel.burstMembers.count > 1,
           let position = viewerModel.burstMembers.firstIndex(where: { $0.id == viewerID }) {
            let members = viewerModel.burstMembers
            var next = position + step
            if next < 0 { next = members.count - 1 }
            if next >= members.count { next = 0 }
            let target = members[next]
            viewerIndexCache = nil
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            return
        }
        // 「图库」页新照片在底部时，网格视觉顺序是旧 → 新（与查询顺序相反），
        // 查看器的下一张 / 上一张必须跟着屏幕走。
        let queryStep = viewerUsesVisualTimelineOrder ? -step : step
        // 外部列表（地图 / 地点 / 卡片墙）与「相似照片」：都按屏幕上的那份列表翻页。
        if !viewerContextPhotos.isEmpty || similarScope != nil {
            let count = viewerNavigationPhotos.count
            guard count > 0,
                  let current = viewerNavigationPhotos.firstIndex(where: { $0.id == viewerID }) else { return }
            let target = viewerNavigationPhotos[(current + viewerNavigationStep(delta) + count) % count]
            viewerIndexCache = nil
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            return
        }
        // 系统图库索引：顺序由索引决定，相邻项用索引查询，翻页成本与总量无关。
        if isSystemPagedScope, let query = systemPagedQuery, let index = systemIndex {
            // 直连模式没有全局下标（`index(of:)` 为 nil），不能拿它当翻页前提；
            // 相邻项由索引 / 直连 SQL 直接查询，翻页成本与总量无关。
            guard let target = index.neighbor(of: viewerID, delta: queryStep, in: query) else {
                return
            }
            if let current = viewerQueryIndex(of: viewerID), visibleCount > 0 {
                var next = current + queryStep
                if next < 0 { next += visibleCount }
                if next >= visibleCount { next -= visibleCount }
                viewerIndexCache = ViewerIndexCache(key: pagedKey, id: target.id, index: next)
            } else {
                viewerIndexCache = nil
            }
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            refreshViewerStripIfNeeded()
            return
        }
        // 大图库：顺序由 SQLite 决定，相邻项用 keyset 查询，翻页成本与总量无关。
        if isPagedScope, let query = pagedQuery, let store = metadataStore {
            guard let current = viewerQueryIndex(of: viewerID), visibleCount > 0,
                  let target = store.neighbor(of: viewerID, delta: queryStep, in: query) else {
                return
            }
            var next = current + queryStep
            if next < 0 { next += visibleCount }
            if next >= visibleCount { next -= visibleCount }
            viewerIndexCache = ViewerIndexCache(key: pagedKey, id: target.id, index: next)
            self.viewerID = target.id
            selection = [target.id]
            recordView(target.id)
            refreshViewerStripIfNeeded()
            return
        }
        let items = visiblePhotos
        guard !items.isEmpty else { return }
        // 连翻时避免每次都线性扫描超大数组。
        guard let current = viewerQueryIndex(of: viewerID) else { return }
        var next = current + queryStep
        if next < 0 { next = items.count - 1 }
        if next >= items.count { next = 0 }
        let target = items[next]
        viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: target.id, index: next)
        self.viewerID = target.id
        selection = [target.id]
        recordView(target.id)
    }

    /// 查看器翻页使用的列表：外部列表（地图 / 地点 / 卡片墙）优先，否则用图库可见集合。
    private var viewerNavigationPhotos: [PhotoItem] {
        viewerContextPhotos.isEmpty ? visiblePhotos : viewerContextPhotos
    }

    /// 翻页方向：外部列表按原顺序，图库在「新照片在底部」时反转。
    private func viewerNavigationStep(_ delta: Int) -> Int {
        let step = delta > 0 ? 1 : -1
        guard viewerContextPhotos.isEmpty else { return step }
        return viewerUsesVisualTimelineOrder ? -step : step
    }

    /// 视频播完后自动连播列表里的下一个视频（跳过照片）；已是最后一个则保持停住。
    func playNextVideo(after id: UUID) {
        guard viewerID == id else { return }
        // 影院条目不在 viewerNavigationPhotos 里，直接走影院自己带的播放队列。
        if cinemaPlaybackEntry?.file.photoID == id, stepCinemaQueue(1) { return }
        // 用窗口内的局部位次，避免分页模式下全局下标与窗口长度不一致。
        let items = viewerNavigationPhotos
        guard let current = items.firstIndex(where: { $0.id == id }) else { return }
        let step = viewerNavigationStep(1)
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo {
                let target = items[index]
                viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: target.id, index: index)
                viewerID = target.id
                selection = [target.id]
                recordView(target.id)
                return
            }
            index += step
        }
    }

    /// 在查看器里跳到上一个 / 下一个视频（跳过照片），供视频控制条使用。
    func viewerStepVideo(_ delta: Int) {
        guard let viewerID else { return }
        // 影院播放时让「上一集 / 下一集」走播放队列，和自动连播保持同一条路径。
        if cinemaPlaybackEntry?.file.photoID == viewerID, stepCinemaQueue(delta) { return }
        let items = viewerNavigationPhotos
        guard let current = items.firstIndex(where: { $0.id == viewerID }) else { return }
        let step = viewerNavigationStep(delta)
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo {
                let target = items[index]
                let key = isPagedScope ? pagedKey : visibleStateKey
                viewerIndexCache = ViewerIndexCache(key: key, id: target.id, index: index)
                self.viewerID = target.id
                selection = [target.id]
                recordView(target.id)
                return
            }
            index += step
        }
    }

    /// 分集式片源：网络资源剧集，或网络存储（SMB / 网盘）影院里的视频。
    /// 这类片源把方向键让给播放控制：← / → 快进快退，↑ / ↓ 上一条 / 下一条。
    func usesEpisodeTransport(for photo: PhotoItem) -> Bool {
        if catalogPlaybackContexts[photo.id] != nil { return true }
        return photo.isCloud && cinemaPlaybackPhoto != nil
    }

    /// 从指定项目出发，前 / 后是否还有可跳转的视频。
    func hasAdjacentVideo(from id: UUID, delta: Int) -> Bool {
        if cinemaPlaybackEntry?.file.photoID == id {
            return cinemaQueueNeighbor(of: id, delta: delta) != nil
        }
        let items = viewerNavigationPhotos
        guard let current = items.firstIndex(where: { $0.id == id }) else { return false }
        let step = viewerNavigationStep(delta)
        var index = current + step
        while index >= 0 && index < items.count {
            if items[index].isVideo { return true }
            index += step
        }
        return false
    }

    // MARK: - 视频菜单命令
    //
    // 「视频」菜单、顶栏播放舱与画面内控制条共用这里的入口：三处只操作同一份
    // `ViewerModel.videoPlayer` 与旋转角度，状态不会分叉。

    /// 查看器里正在显示的视频；没有视频时菜单项整体置灰。
    var commandVideo: PhotoItem? {
        guard let photo = viewerPhoto, photo.isVideo else { return nil }
        return photo
    }

    var canControlVideoPlayback: Bool { commandVideo != nil }

    var videoIsMuted: Bool { viewerModel.videoPlayer.isMuted }
    var videoIsLooping: Bool { viewerModel.videoPlayer.isLooping }
    var videoUsesFill: Bool { AppSettings.shared.videoFramingMode == .fill }
    var videoPipActive: Bool { viewerModel.videoPlayer.isPipActive }
    var videoPipAvailable: Bool { viewerModel.videoPlayer.isPipAvailable }
    var videoSpeed: Double { viewerModel.videoPlayer.speed }

    var videoCanStepBackward: Bool {
        guard let id = commandVideo?.id else { return false }
        return hasAdjacentVideo(from: id, delta: -1)
    }

    var videoCanStepForward: Bool {
        guard let id = commandVideo?.id else { return false }
        return hasAdjacentVideo(from: id, delta: 1)
    }

    func toggleVideoPlaybackCommand() {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.togglePlay()
    }

    /// 快进 / 快退：与画面内快捷键一致，走 `requestSeek` 以便云盘重建流。
    func seekVideoCommand(by delta: Double) {
        guard canControlVideoPlayback else { return }
        let player = viewerModel.videoPlayer
        player.requestSeek(to: player.currentTime + delta)
    }

    func stepVideoFrameCommand(by count: Int) {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.stepFrame(by: count)
    }

    func toggleVideoMuteCommand() {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.isMuted.toggle()
    }

    func setVideoVolumeCommand(_ volume: Double) {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.volume = volume
        viewerModel.videoPlayer.isMuted = false
    }

    // MARK: 音轨 / 字幕

    /// 可切换的音轨：网盘流式播放时是 ffprobe 探测结果，本地视频是 AV 原生音轨组。
    var videoAudioChoices: [VideoPlaybackUI.AudioChoice] {
        viewerModel.videoPlaybackUI.audioChoices
    }

    var videoSelectedAudioIndex: Int {
        viewerModel.videoPlaybackUI.selectedAudioIndex
    }

    func selectVideoAudioCommand(_ index: Int) {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlaybackUI.selectAudio(index)
    }

    var videoLegibleOptions: [AVMediaSelectionOption] {
        viewerModel.videoPlayer.legibleOptions
    }

    func isVideoLegibleSelected(_ option: AVMediaSelectionOption) -> Bool {
        viewerModel.videoPlayer.selectedLegible == option
    }

    /// 切换内嵌字幕：外挂字幕优先于内嵌字幕，选内嵌时先清掉外挂。
    func selectVideoLegibleCommand(_ option: AVMediaSelectionOption?) {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlaybackUI.clearSubtitle()
        viewerModel.videoPlayer.selectLegible(option)
    }

    var videoHasSubtitle: Bool { viewerModel.videoPlaybackUI.hasSubtitle }
    /// 视频文件里自带的内嵌字幕是否已选中。
    var videoHasEmbeddedSubtitle: Bool { viewerModel.videoPlayer.selectedLegible != nil }

    func pickVideoSubtitleCommand() {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlaybackUI.pickSubtitle()
    }

    func clearVideoSubtitleCommand() {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlaybackUI.clearSubtitle()
    }

    func adjustVideoSubtitleOffsetCommand(by delta: Double) {
        guard canControlVideoPlayback, videoHasSubtitle else { return }
        viewerModel.videoPlaybackUI.adjustOffset(delta)
    }

    func resetVideoSubtitleOffsetCommand() {
        guard canControlVideoPlayback, videoHasSubtitle else { return }
        viewerModel.videoPlaybackUI.resetOffset()
    }

    func toggleVideoLoopCommand() {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.isLooping.toggle()
    }

    func toggleVideoGravityCommand() {
        guard canControlVideoPlayback else { return }
        let settings = AppSettings.shared
        settings.videoFramingMode = settings.videoFramingMode == .fill ? .fit : .fill
    }

    func setVideoSpeedCommand(_ speed: Double) {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.setSpeed(speed)
    }

    func rotateVideoDisplayCommand() {
        guard canControlVideoPlayback else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            viewerModel.videoQuarterTurns = (viewerModel.videoQuarterTurns + 1) % 4
        }
    }

    func toggleVideoPipCommand() {
        guard canControlVideoPlayback else { return }
        viewerModel.videoPlayer.togglePip()
    }

    func toggleVideoFullScreenCommand() {
        guard canControlVideoPlayback else { return }
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    /// 保存当前帧：与画面朝向一致（「视频」菜单与顶栏、画面内控制条共用）。
    func saveVideoFrameCommand() {
        guard let photo = commandVideo else { return }
        let turns = viewerModel.videoQuarterTurns
        let player = viewerModel.videoPlayer
        Task { @MainActor in
            guard let frame = await player.currentFrameImage() else {
                showToast("无法获取当前帧")
                return
            }
            let image = turns == 0
                ? frame
                : (ImageTransform.rotate(frame, degrees: turns * 90) ?? frame)
            let panel = NSSavePanel()
            let base = (photo.originalName as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "-截图.png"
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                showToast("截图保存失败")
                return
            }
            do {
                try data.write(to: url)
                showToast("已保存截图")
            } catch {
                showToast("截图保存失败：\(error.localizedDescription)")
            }
        }
    }

    /// 查看器显示的序号（0 起）：默认就是查询顺序；
    /// 「新照片在底部」时换算成网格的视觉顺序（第 1 张是最早的，最后一张是最新的）。
    func viewerIndex(of id: UUID) -> Int? {
        guard let raw = viewerQueryIndex(of: id) else { return nil }
        let total = visibleCount
        guard viewerUsesVisualTimelineOrder, total > 0 else { return raw }
        return max(0, min(total - 1, total - 1 - raw))
    }

    /// 查看器顶栏 / 全屏底栏的「当前 / 总数」。
    /// 任何入口（相簿位置跳转、场景目录、卡片墙与目录封面…）打开都必须给出一组数字：
    /// 优先用查询下标（分页 / 系统索引，与网格顺序和翻页一致），算不出时依次退回
    /// 已加载窗口 → 胶片条 → 可见列表 → 照片自身所属的完整范围。
    func viewerPosition(of id: UUID) -> (index: Int, total: Int) {
        let key = visibleStateKey
        if let cache = viewerPositionCache, cache.key == key, cache.id == id {
            return (cache.index, cache.total)
        }
        let position = resolveViewerPosition(of: id)
        viewerPositionCache = ViewerPositionCache(key: key, id: id,
                                                 index: position.index, total: position.total)
        return position
    }

    private func resolveViewerPosition(of id: UUID) -> (index: Int, total: Int) {
        // 从地图 / 地点 / 卡片墙打开：序号与总数都以那份列表为准。
        if let position = viewerContextPhotos.firstIndex(where: { $0.id == id }) {
            return (position, viewerContextPhotos.count)
        }
        if let index = viewerIndex(of: id) {
            // 全局排名可用：总数是整段范围的数量，不是已加载窗口。
            return (index, max(visibleCount, index + 1, 1))
        }
        // 分页窗口已加载：窗口起始排名 + 窗口内位置就是整段范围里的序号。
        if isSystemPagedScope {
            let total = max(systemWindowTotal, systemWindowStartRank + systemWindowPhotos.count, 1)
            if let position = systemWindowPhotos.firstIndex(where: { $0.id == id }) {
                return (visualIndex(systemWindowStartRank + position, total: total), total)
            }
        } else if isPagedScope {
            let total = max(windowTotal, windowStartOffset + windowPhotos.count, 1)
            if let position = windowPhotos.firstIndex(where: { $0.id == id }) {
                return (visualIndex(windowStartOffset + position, total: total), total)
            }
        }
        // 胶片条已经是网格的视觉顺序，直接取位置。
        if let position = viewerStrip.firstIndex(where: { $0.id == id }) {
            return (position, viewerStrip.count)
        }
        let visible = viewerVisiblePhotos
        if let position = visible.firstIndex(where: { $0.id == id }) {
            return (position, visible.count)
        }
        // 照片不在当前可见集合里（卡片墙 / 目录封面 / 其它范围直接打开）：
        // 退回它自身所属的完整范围，保证序号与总数不会凭空消失。
        let own = ownScopePhotos(for: id)
        if let position = own.firstIndex(where: { $0.id == id }) {
            return (position, own.count)
        }
        return (0, 1)
    }

    /// 查询顺序排名换算成网格的视觉顺序排名。
    private func visualIndex(_ raw: Int, total: Int) -> Int {
        guard viewerUsesVisualTimelineOrder, total > 0 else { return raw }
        return max(0, min(total - 1, total - 1 - raw))
    }

    /// 当前照片所属的完整范围：网盘全部照片 / 系统图库 / 本地库。
    private func ownScopePhotos(for id: UUID) -> [PhotoItem] {
        if let photo = anyPhoto(id: id) {
            if photo.isCloud { return cloudPhotos }
            if photo.isSystem { return systemPhotos }
        }
        return photos
    }

    /// 当前照片在查询顺序里的下标（0 = 最新）；内部翻页运算统一用它，界面序号再经 `viewerIndex(of:)` 换算。
    func viewerQueryIndex(of id: UUID) -> Int? {
        // 「相似照片」是过滤后的固定集合：序号必须在集合内算，不能沿用整库下标。
        if similarScope != nil {
            guard let index = visiblePhotos.firstIndex(where: { $0.id == id }) else { return nil }
            viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: id, index: index)
            return index
        }
        if isSystemPagedScope {
            if let cache = viewerIndexCache, cache.key == pagedKey, cache.id == id {
                return cache.index
            }
            // 直连模式没有全局下标（一次 COUNT 会扫整库）：查看器都是从网格打开的，
            // 用「窗口起始排名 + 窗口内位置」换算，后续翻页由 `viewerStep` 按 ±1 维护缓存。
            if systemIndex?.direct != nil {
                // 窗口必须已经是当前查询的窗口；否则位置与起始排名对不上，
                // 宁可先不显示序号，也不要显示一个会跳变的错误数字。
                guard systemWindowQuery?.key == systemPagedQuery?.key,
                      let position = systemWindowPhotos.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                let index = systemWindowStartRank + position
                viewerIndexCache = ViewerIndexCache(key: pagedKey, id: id, index: index)
                return index
            }
            guard let query = systemPagedQuery,
                  let index = systemIndex?.index(of: id, in: query) else {
                return nil
            }
            viewerIndexCache = ViewerIndexCache(key: pagedKey, id: id, index: index)
            return index
        }
        if isPagedScope {
            if let cache = viewerIndexCache, cache.key == pagedKey, cache.id == id {
                return cache.index
            }
            // 必须以「当前查询」为准：窗口查询可能还是上一次范围的，拿它算序号会整体偏移。
            guard let query = pagedQuery,
                  let index = metadataStore?.index(of: id, in: query) else {
                return nil
            }
            viewerIndexCache = ViewerIndexCache(key: pagedKey, id: id, index: index)
            return index
        }
        let items = visiblePhotos
        if let cache = viewerIndexCache,
           cache.key == visibleStateKey,
           cache.id == id,
           cache.index < items.count,
           items[cache.index].id == id {
            return cache.index
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        viewerIndexCache = ViewerIndexCache(key: visibleStateKey, id: id, index: index)
        return index
    }

    func openEditor(_ id: UUID) {
        guard let photo = anyPhoto(id: id), !photo.isVideo, !photo.isCloud else { return }
        if photo.isSystem {
            // 系统照片走 PhotoKit 非破坏性编辑：只有「照片」当前图库可写时开放。
            guard canWriteSystemLibrary else {
                showToast("当前图库只读，无法编辑；请先在「照片」中打开这个图库")
                return
            }
            editorID = id
            return
        }
        editorID = id
    }

    func closeEditor() {
        editorID = nil
    }

    // MARK: - Editing

    func commitEditedImage(photoID: UUID, jpegData: Data, pixelWidth: Int, pixelHeight: Int,
                           recipe: String? = nil) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        let filename = photoID.uuidString + ".jpg"
        let url = LibraryPaths.edited.appendingPathComponent(filename)
        LibraryPaths.prepare()
        try? jpegData.write(to: url, options: .atomic)

        var updated = photos[index]
        updated.editedFilename = filename
        updated.pixelWidth = pixelWidth
        updated.pixelHeight = pixelHeight
        updated.editRecipe = recipe
        // 渲染结果已经包含旋转，清除旋转元数据避免二次旋转。
        updated.rotation = nil
        ImportService.makeImageThumbnail(url: url, destination: LibraryPaths.thumbnailURL(for: updated))
        updated.editVersion += 1
        photos[index] = updated

        ImageLoader.invalidate(photo: updated)
        save()
        editorID = nil
        showToast("已保存修改")
    }

    func revertEdits(_ photoID: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        if let editedFilename = photos[index].editedFilename {
            try? FileManager.default.removeItem(at: LibraryPaths.edited.appendingPathComponent(editedFilename))
        }
        var updated = photos[index]
        updated.editedFilename = nil
        updated.rotation = nil
        updated.editRecipe = nil
        ImportService.generateThumbnail(for: updated)
        updated.editVersion += 1
        photos[index] = updated

        ImageLoader.invalidate(photo: updated)
        save()
        showToast("已还原为原始照片")
    }

    // MARK: - 编辑点复制 / 粘贴

    func copyEdits(_ photoID: UUID) {
        guard let photo = photo(id: photoID) else { return }
        guard let recipe = photo.editRecipe else {
            showToast("这张照片没有可复制的编辑点")
            return
        }
        copiedEditRecipe = recipe
        showToast("已复制编辑点")
    }

    func pasteEdits(_ photoID: UUID) {
        guard let recipeString = copiedEditRecipe else {
            showToast("请先复制编辑点")
            return
        }
        guard let photo = photo(id: photoID), !photo.isVideo,
              !photo.isReadOnly, !photo.isDeleted else {
            showToast("该照片不支持粘贴编辑点")
            return
        }
        guard let state = EditState(jsonString: recipeString) else { return }
        let baseURL = LibraryPaths.originalURL(for: photo)
        guard let base = PhotoRenderer.loadBase(url: baseURL) else {
            showToast("无法读取原始照片")
            return
        }
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: base, state: state, maxPixel: nil)
            }.value
            guard let rendered, let data = Self.jpegData(from: rendered) else {
                showToast("粘贴编辑点失败")
                return
            }
            commitEditedImage(photoID: photoID,
                              jpegData: data,
                              pixelWidth: rendered.width,
                              pixelHeight: rendered.height,
                              recipe: recipeString)
        }
    }

    nonisolated static func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    }
}
