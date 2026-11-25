import SwiftUI
import AppKit

/// 侧边栏是否展开：工具栏按钮和菜单「显示/隐藏边栏」共用这一份状态。
///
/// 系统自带的 sidebar toggle 在侧边栏收起后会跟着侧边栏一起从工具栏消失，
/// 这时只剩 SwiftUI 的 `columnVisibility` 绑定，用户没有任何入口能再打开。
/// 所以自己持有可见性，按钮常驻，关闭后仍能一键展开。
@MainActor
final class SidebarChrome: ObservableObject {
    @Published var isVisible = true
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var tv: IPTVBrowserModel
    @EnvironmentObject private var viewer: ViewerModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sidebarChrome: SidebarChrome
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// 主窗口与全局空格键监听：相簿 / 媒体类型 / 人物 / 地点等任意照片网格都能用空格打开查看。
    @State private var hostWindow: NSWindow?
    @State private var spaceMonitor: Any?
    /// 当前侧边栏可见性；视频全屏时临时切到 `.detailOnly`，退出后恢复。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var columnVisibilityBeforeFullScreen: NavigationSplitViewVisibility = .all
    /// 侧边栏重建信号：视频全屏 / 窗口尺寸还原后，SwiftUI 偶尔会把分栏停在
    /// 「列还在、内容没铺开」的中间态（左侧一片空白）。换个身份强制重建侧边栏内容。
    @State private var sidebarRelayoutToken = 0
    /// 进入视频全屏前的窗口尺寸，退出全屏后还原。
    @State private var windowFrameBeforeFullScreen: NSRect?

    var body: some View {
        ZStack {
            if store.needsLibrarySetup {
                LibrarySetupView()
                    .environmentObject(store)
                    .toolbar(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            } else if store.libraryPickerOnLaunch {
                // 启动占位：选定图库之前不打开任何图库。此时主窗口已被选取图库窗口整窗隐藏，
                // 这里的空白环境光只兜住隐藏生效前一瞬间的画面。
                LumaAmbientBackground()
                    .toolbar(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            } else {
                mainContent
            }

            ToastView()
                .zIndex(4)

            // 删除前的确认卡片：盖在网格、查看器与编辑器之上，确认后才真正删除。
            if let request = store.pendingDeletion {
                DeleteConfirmOverlay(request: request)
                    .environmentObject(store)
                    .environmentObject(settings)
                    .transition(.opacity)
                    .zIndex(8)
            }

            // 断开系统图库 / 网络存储前的确认卡片。
            if let request = store.pendingDisconnect {
                DisconnectConfirmOverlay(request: request)
                    .environmentObject(store)
                    .environmentObject(settings)
                    .transition(.opacity)
                    .zIndex(8)
            }
        }
        .sheet(isPresented: $catalog.showWizard) {
            CatalogWizardView()
                .environmentObject(catalog)
                .environmentObject(store)
        }
        .sheet(isPresented: $tv.showWizard) {
            TVSourceWizardView()
                .environmentObject(tv)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showNewAlbumSheet) {
            NewAlbumSheet()
                .environmentObject(store)
        }
        // 「新建图库」复用首次启动的建库流程（能力 → 位置并创建），
        // 不再另造一套表单；建好后立刻切到新图库。
        .sheet(isPresented: $store.showNewLibrarySheet) {
            LibrarySetupView(creatingAdditionalLibrary: true)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $store.showKeywordManager) {
            KeywordManagerView()
                .environmentObject(store)
        }
        .sheet(item: $store.systemToolsRequest) { request in
            SystemToolsSheet(request: request)
                .environmentObject(store)
        }
        // 命名弹窗由根视图统一呈现：⌘⇧N、侧边栏右键都写同一个状态，
        // 侧边栏收起时也要能弹出。
        .sheet(item: $store.namePrompt) { payload in
            NamePromptSheet(payload: payload)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showCompressionSheet) {
            CompressionSheetView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showShortcutHelp) {
            ShortcutHelpView(showsCloseButton: true)
        }
        .sheet(isPresented: $store.showAIAssistant) {
            AIAssistantView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $store.showBeautyPanel) {
            BeautyRecommendView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $cloud.showSheet) {
            CloudConnectSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $cloud.showWizard) {
            CloudSetupWizardView()
                .environmentObject(store)
        }
        .sheet(item: $cloud.nameRequest) { request in
            CloudNameSheet(request: request)
                .environmentObject(store)
        }
        .sheet(item: $store.editingSmartAlbum) { album in
            SmartAlbumEditorView(album: album)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showBatchChangeSheet) {
            BatchChangeView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showExportSheet) {
            ExportOptionsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showPhotoPicker) {
            PhotoPickerSheet()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
        }
        // 相簿 / 网格右键「手动匹配…」：不用先进入影院，直接在当前窗口完成匹配。
        .sheet(item: $store.cinemaQuickMatch) { request in
            CinemaMatchSheet(photos: request.photos) {
                store.cinemaQuickMatch = nil
            }
            .environmentObject(store)
        }
        .onChange(of: store.showImportSheet) { _, visible in
            if visible {
                openWindow(id: "import")
            } else {
                dismissWindow(id: "import")
            }
        }
        .onChange(of: store.importPanelOpenRequest) { _, _ in
            openWindow(id: "import")
        }
        .onChange(of: store.showLibraryPicker) { _, visible in
            syncLibraryPickerWindow(visible: visible)
        }
        // 视频全屏：进入系统全屏时收起侧边栏，退出时恢复进入前的状态。
        // 用 willEnter 而不是 didEnter：侧边栏与系统全屏动画同时开始，避免先看到一条完整侧边栏。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            FullScreenDiagnostics.log("willEnter frame=\(window.frame)")
            beginVideoImmersiveFullScreenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            FullScreenDiagnostics.log("didExit frame=\(window.frame)")
            endVideoImmersiveFullScreen()
            restoreWindowFrameAfterFullScreen()
            // 全屏进出 + 窗口 frame 还原之后，分栏偶尔不再给侧边栏铺内容：
            // 等回位动画结束再重建一次侧边栏，避免左侧留一片空白。
            nudgeSidebarLayout(after: 0.9)
        }
        // 工具栏从隐藏切回可见时，SwiftUI 偶尔不会把自定义项重新挂回去
        // （影院控制台整条不见）：主动让 AppKit 校验一次可见项。
        .onChange(of: toolbarHidden) { _, hidden in
            guard !hidden, let window = hostWindow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                window.toolbar?.validateVisibleItems()
            }
        }
        .onChange(of: viewer.viewerID) { _, newValue in
            handleViewerIDChange(newValue)
        }
        .onOpenURL { url in
            store.handleOpenedLibrary(url)
        }
        .task(id: store.visibleCount) {
            guard ProcessInfo.processInfo.environment["LUMA_OPEN_FIRST"] != nil,
                  store.viewerID == nil else { return }
            let wantsVideo = ProcessInfo.processInfo.environment["LUMA_OPEN_VIDEO"] != nil
            let target = wantsVideo
                ? store.visiblePhotos.first(where: { $0.isVideo })
                : store.visiblePhotos.first(where: { !$0.isVideo })
            guard let target else { return }
            store.openViewer(target.id)
        }
        // 影院详情跟随应用外观：浅色皮肤下页面、标题栏与控制台一起保持浅色，
        // 深色皮肤下仍是影院暗色，不再整窗固定切深色。
        .preferredColorScheme(settings.appearance.colorScheme)
        // tint 负责控件（滑杆、开关、按钮），accentColor 让 Color.accentColor（选中框、高亮、强调文字）
        // 解析成同一个颜色，避免出现「滑杆粉色、选中框蓝色」两套配色。
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .animation(settings.motion.overlay, value: viewer.editorID == nil)
        .animation(settings.motion.overlay, value: store.showSlideshow)
        .animation(settings.motion.overlay, value: store.activeMemory?.id)
        .animation(settings.motion.overlay, value: store.activeTrip?.id)
        .animation(settings.motion.overlay, value: store.pendingDeletion?.id)
        .animation(settings.motion.overlay, value: store.pendingDisconnect?.id)
        .background(WindowAccessor { window in
            if hostWindow !== window { hostWindow = window }
            // 选取图库窗口打开期间主窗口不能露出框架：捕获到窗口就立刻隐藏，
            // 覆盖按住 Option 启动、主窗口刚建好就被前置的首帧。
            if store.showLibraryPicker, let window {
                window.orderOut(nil)
            }
        })
        .onAppear {
            installSpaceMonitor()
            // 临时诊断：自动进入影院并打开第一条视频，用于排查播放时的标题栏布局。
            if ProcessInfo.processInfo.environment["LUMA_DEBUG_PLAY"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if case .cinema = store.sidebarItem {
                    } else if let mount = store.cloudMounts.first(where: {
                        !store.cinemaEntries(for: .mount($0.id)).isEmpty
                    }) {
                        store.sidebarItem = .cloudCinema(mount.id)
                    } else {
                        store.sidebarItem = .cinema
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let scope: CinemaScope
                    if case .cloudCinema(let id) = store.sidebarItem { scope = .mount(id) } else { scope = .local }
                    let entries = Array(store.cinemaEntries(for: scope).values)
                    if let entry = entries.first(where: { $0.file.photoItem.isVideo }) ?? entries.first {
                        store.openCinema(entry)
                    }
                }
            }
            // 按住 Option 启动：store 在 init 里已置位，这里直接开选择器窗口。
            if store.showLibraryPicker { syncLibraryPickerWindow(visible: true) }
        }
        .task {
            // 启动兜底：极端时序下 onAppear 里的 openWindow 可能被 SwiftUI 丢弃，
            // 主窗口已隐藏而选择器没弹出会让应用看起来「无窗口」。稍后补开一次。
            try? await Task.sleep(nanoseconds: 500_000_000)
            if store.showLibraryPicker { openWindow(id: "libraryPicker") }
        }
        .modifier(CinemaWindowSizeLock(window: hostWindow, isCinema: isCinemaPage))
        .onDisappear { removeSpaceMonitor() }
    }

    /// 影院页（本地影院或某个网盘的影院）：进入时锁一次窗口尺寸。
    private var isCinemaPage: Bool {
        switch store.sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    // MARK: - 选取图库窗口

    /// 图库选择器走独立小窗口（对齐系统「照片」）：打开期间主窗口整窗隐藏（含框架），
    /// 选定 / 取消 / 红叉关闭后由 `showLibraryPicker` 归零触发恢复。
    /// 不能改回挂主窗口的 sheet：sheet 是主窗口的子窗口，主窗口一隐藏 sheet 会跟着消失。
    private func syncLibraryPickerWindow(visible: Bool) {
        if visible {
            openWindow(id: "libraryPicker")
            hostWindow?.orderOut(nil)
            // 下一帧再补一次：兜住启动过程中 SwiftUI 把主窗口重新前置的时序。
            DispatchQueue.main.async {
                hostWindow?.orderOut(nil)
            }
        } else {
            dismissWindow(id: "libraryPicker")
            hostWindow?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 空格键

    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleSpaceKey(event) ? nil : event
        }
    }

    private func removeSpaceMonitor() {
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
            self.spaceMonitor = nil
        }
    }

    /// 空格：任意照片网格里打开所选照片，查看器里再次按下收起（由查看器自己的键盘处理）。
    /// 放在 RootView 是为了让相簿 / 媒体类型 / 人物 / 地点 / 重复项等所有页面行为一致。
    private func handleSpaceKey(_ event: NSEvent) -> Bool {
        // 忽略长按产生的重复事件：否则一次稍长的空格会在「打开 → 关闭」之间反复切换。
        guard event.keyCode == 49, !event.isARepeat else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        guard let window = hostWindow ?? event.window,
              event.window === window,
              window.attachedSheet == nil else { return false }
        // 查看器 / 编辑器 / 幻灯片 / 回忆 / 行程 / 确认卡片 / 文本输入都交给各自的处理器。
        guard store.viewerID == nil, store.editorID == nil,
              !store.showSlideshow, store.activeMemory == nil, store.activeTrip == nil,
              !store.hasPendingConfirmation else { return false }
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSTextField { return false }
        guard !store.selection.isEmpty else { return false }
        store.openSelectionInViewer()
        return true
    }

    /// 侧边栏收起后的常驻入口。系统自带的 sidebar toggle 会随侧边栏一起消失，
    /// 没有这个按钮就只能靠菜单快捷键了，所以做成内容区左上角一枚浮动胶囊。
    private var sidebarRevealButton: some View {
        Button {
            sidebarChrome.isVisible = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 10, weight: .semibold))
                Text("显示边栏")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("显示边栏（⌃⌘S）")
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .id(sidebarRelayoutToken)
        } detail: {
            ZStack {
                // 环境光垫在内容之下：磨砂侧边栏、浮动胶囊与网格间隙都能透出颜色。
                LumaAmbientBackground()
                GalleryView()
                // 侧边栏收起后：系统自带的 toggle 会跟着侧边栏一起从工具栏消失，
                // 这里补一个常驻的「显示边栏」入口，收起后随时能展开。
                if !sidebarChrome.isVisible {
                    sidebarRevealButton
                        .padding(.top, 10)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                        .zIndex(0.5)
                }
                if settings.viewerLayout == .window, store.viewerPhoto != nil {
                    PhotoViewerView(embedded: true)
                        // 视频真全屏：查看器自身伸进顶部安全区，把工具栏空出来的那一条吃掉。
                        // 只加在组件上、不加在整窗或分栏上，避免影响窗口尺寸计算。
                        .ignoresSafeArea(edges: viewer.videoImmersiveFullScreen ? .all : [])
                        .background(Color(nsColor: .windowBackgroundColor))
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(toolbarHidden ? .hidden : .visible, for: .windowToolbar)
        // 两个方向同步：菜单 / 按钮改可见性 → 动分栏；系统侧收起（全屏等）→ 回写状态。
        .onChange(of: sidebarChrome.isVisible) { _, visible in
            let target: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            guard columnVisibility != target else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                columnVisibility = target
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            if sidebarChrome.isVisible != visible {
                sidebarChrome.isVisible = visible
            }
        }

        if store.viewerPhoto != nil, settings.viewerLayout == .fullscreen {
            PhotoViewerView()
                .transition(.opacity.combined(with: .scale(scale: settings.motion.viewerScale)))
                .zIndex(2)
        }

        if let editorID = viewer.editorID, let photo = store.anyPhoto(id: editorID) {
            PhotoEditorView(photo: photo)
                .transition(.opacity.combined(with: .scale(scale: settings.motion.viewerScale)))
                .zIndex(3)
        }

        if store.showSlideshow {
            SlideshowView()
                .environmentObject(store)
                .transition(.opacity)
                .zIndex(6)
        }

        if let trip = store.activeTrip {
            TripStoryView(trip: trip)
                .environmentObject(store)
                .environmentObject(settings)
                .transition(.opacity)
                .zIndex(6.5)
        }

        if let memory = store.activeMemory {
            MemoryMovieView(memory: memory)
                .environmentObject(store)
                .transition(.opacity)
                .zIndex(7)
        }
    }

    /// 进入系统全屏且当前看的是视频：隐藏侧边栏，画面独占整个窗口。
    private func beginVideoImmersiveFullScreenIfNeeded() {
        guard viewer.viewerID != nil, store.viewerPhoto?.isVideo == true else { return }
        guard !viewer.videoImmersiveFullScreen else { return }
        // 记住进入前的窗口尺寸：反复进出全屏时，AppKit 会按内容算回退尺寸，
        // 不还原就会一次比一次矮。
        if let window = hostWindow, !window.styleMask.contains(.fullScreen) {
            windowFrameBeforeFullScreen = window.frame
        }
        columnVisibilityBeforeFullScreen = columnVisibility
        viewer.videoImmersiveFullScreen = true
        FullScreenDiagnostics.log("begin immersive savedFrame=\(String(describing: windowFrameBeforeFullScreen))")
        // 不叠加 SwiftUI 动画：系统正在播放全屏动画，两套动画同时改侧边栏
        // 会把分栏停在「侧边栏已收起、详情列还是旧宽度」的中间态。
        columnVisibility = .detailOnly
        // SwiftUI 的 toolbar(.hidden) 在系统全屏动画期间会被 AppKit 忽略：
        // 动画结束后再补一次原生隐藏，顶部不再留一条黑带。
        if let window = hostWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                window.toolbar?.isVisible = false
            }
        }
    }

    /// 退出全屏：恢复进入前的侧边栏可见性，顶栏随全屏状态自动恢复。
    private func endVideoImmersiveFullScreen() {
        guard viewer.videoImmersiveFullScreen else { return }
        viewer.videoImmersiveFullScreen = false
        FullScreenDiagnostics.log("end immersive")
        columnVisibility = columnVisibilityBeforeFullScreen
        hostWindow?.toolbar?.isVisible = true
    }

    /// 退出全屏后把窗口拉回进入前的尺寸，避免多次进出后窗口越来越矮。
    private func restoreWindowFrameAfterFullScreen() {
        guard let frame = windowFrameBeforeFullScreen, let window = hostWindow else { return }
        windowFrameBeforeFullScreen = nil
        // 等系统退出全屏的回位动画和窗口 frame 自动保存都结束再钉回原尺寸，
        // 太早设置会被 AppKit 后续的回位覆盖掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            FullScreenDiagnostics.log("restore frame saved=\(frame) current=\(window.frame)")
            window.setFrame(frame, display: true)
        }
    }

    /// 全屏 / 窗口尺寸变化后重建侧边栏内容，修复「列还在、内容空白」的分栏中间态。
    private func nudgeSidebarLayout(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            sidebarRelayoutToken &+= 1
        }
    }

    private func handleViewerIDChange(_ newValue: UUID?) {
        FullScreenDiagnostics.log("viewerID -> \(String(describing: newValue)) immersive=\(viewer.videoImmersiveFullScreen)")
        // 幽灵查看器兜底：ID 还在但照片已找不到时，覆盖层会留下一块空白。
        // 等一个 runloop 再判断，避免打开瞬间的正常空档被误关。
        if let newValue {
            DispatchQueue.main.async {
                guard store.viewerID == newValue, store.viewerPhoto == nil else { return }
                store.closeViewer()
            }
        }
        // 全屏里直接关掉查看器：只退出全屏，布局与侧边栏等系统退出后再恢复，
        // 避免退出动画途中改布局把窗口尺寸算歪（反复进出会让窗口越来越矮）。
        guard newValue == nil, viewer.videoImmersiveFullScreen else { return }
        hostWindow?.toggleFullScreen(nil)
    }

    private var toolbarHidden: Bool {
        // 窗口内浏览保留统一工具栏：返回、缩放、拍摄时间与操作都放在工具栏里。
        // 编辑器 / 「整窗查看器」/ 视频真全屏都会盖满窗口：整条隐藏，
        // 视频全屏改用画面内控制条（底部已有的那一条），顶部不再占一条黑带。
        // 退出全屏后由 toolbarHidden 的 onChange 主动 validateVisibleItems，
        // 避免 SwiftUI 偶尔不把影院控制台重新挂回标题栏。
        viewer.editorID != nil
            || (store.viewerPhoto != nil && settings.viewerLayout == .fullscreen)
            || viewer.videoImmersiveFullScreen
    }
}

/// 进入影院时短暂锁住窗口尺寸。
///
/// 影院页会把工具栏整体让给标题栏控制台；SwiftUI 重建工具栏 / 标题栏浮层时，
/// 偶尔会按内容理想尺寸把主窗口缩回默认大小。这里在尺寸真正变小时立即还原，
/// 用户自己拖拽窗口时立刻解锁，绝不和用户抢尺寸。
private struct CinemaWindowSizeLock: ViewModifier {
    let window: NSWindow?
    let isCinema: Bool

    @State private var lockedFrame: NSRect?
    @State private var unlockTask: DispatchWorkItem?
    @State private var isLiveResizing = false
    @State private var isApplying = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isCinema) { _, entered in
                if entered {
                    lock()
                } else {
                    release()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
                guard (note.object as? NSWindow) === window else { return }
                isLiveResizing = true
                release()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
                guard (note.object as? NSWindow) === window else { return }
                isLiveResizing = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
                enforce(note.object as? NSWindow)
            }
    }

    private func lock() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        lockedFrame = window.frame
        unlockTask?.cancel()
        let task = DispatchWorkItem { lockedFrame = nil }
        unlockTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func release() {
        unlockTask?.cancel()
        unlockTask = nil
        lockedFrame = nil
    }

    private func enforce(_ changed: NSWindow?) {
        guard let changed, changed === window,
              !isApplying,
              !isLiveResizing,
              !changed.styleMask.contains(.fullScreen),
              let locked = lockedFrame else { return }
        let current = changed.frame
        guard current.width < locked.width - 1 || current.height < locked.height - 1 else { return }
        isApplying = true
        FullScreenDiagnostics.log("cinema size lock \(current) -> \(locked)\n"
                                  + Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
        changed.setFrame(locked, display: true)
        isApplying = false
    }
}

/// 临时诊断：视频全屏进出与窗口尺寸问题排查用，定位后删除。
enum FullScreenDiagnostics {
    static func log(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/luma-fs.log")
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
