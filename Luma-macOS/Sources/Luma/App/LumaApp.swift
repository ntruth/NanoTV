import SwiftUI
import AppKit

@main
struct LumaApp: App {
    @NSApplicationDelegateAdaptor(LumaAppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var settings = AppSettings.shared
    /// 侧边栏可见性：菜单与工具栏按钮共用，收起后仍能重新打开。
    @StateObject private var sidebarChrome = SidebarChrome()
    /// 多图库聚合读数：图库总览页与窗口标题共用同一份数据。
    @StateObject private var libraryAggregate = LibraryAggregateModel()
    /// 菜单栏「关于拾光」走独立品牌窗口，与设置里的关于共用同一套动效。
    @Environment(\.openWindow) private var openWindow
    /// 模块开关：关掉的模块不再出现在「接入…」菜单里。
    @AppStorage(SettingsKeys.moduleCloud) private var cloudModule = true
    @AppStorage(SettingsKeys.moduleCatalog) private var catalogModule = true
    @AppStorage(SettingsKeys.showTelevision) private var televisionModule = true
    @AppStorage(SettingsKeys.moduleCinema) private var cinemaModule = true

    private var favoriteCommandTitle: String {
        store.currentIsFavorite ? "取消个人收藏" : "标记为个人收藏"
    }

    private var hideCommandTitle: String {
        let ids = store.commandTargetIDs
        let allHidden = !ids.isEmpty && ids.allSatisfy { store.photo(id: $0)?.isHidden == true }
        return allHidden ? "取消隐藏" : "隐藏"
    }

    private var canEditCommand: Bool {
        store.commandTargetIDs.contains { id in
            guard let photo = store.anyPhoto(id: id), !photo.isVideo else { return false }
            if photo.isSystem { return store.canWriteSystemLibrary }
            return !photo.isReadOnly
        }
    }

    private var canRotateCommand: Bool {
        store.commandTargetIDs.contains { id in
            guard let photo = store.photo(id: id) else { return false }
            return !photo.isVideo && !photo.isReadOnly
        }
    }

    private var canEditMetadataCommand: Bool {
        !store.commandTargetIDs.isEmpty && store.canEditMetadataWorkflow
    }

    /// 「导出视频…」只在当前目标里含视频时可用。
    private var canExportVideoCommand: Bool {
        !store.commandTargetIDs.isEmpty
            && store.commandTargetIDs.contains { store.anyPhoto(id: $0)?.isVideo == true }
    }

    private static func videoSpeedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }

    var body: some Scene {
        // 单窗口：不再允许新建第二个主窗口；关掉主窗口即退出（见 LumaAppDelegate）。
        Window("拾光", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(store.selectionModel)
                .environmentObject(store.viewerModel)
                .environmentObject(store.cloudModel)
                .environmentObject(store.catalogModel)
                .environmentObject(store.tvModel)
                .environmentObject(sidebarChrome)
                .environmentObject(libraryAggregate)
                .frame(minWidth: 1080, minHeight: 660)
        }
        .defaultSize(width: LumaAppDelegate.preferredWindowSize.width,
                     height: LumaAppDelegate.preferredWindowSize.height)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于拾光") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoActionName.map { "撤销\($0)" } ?? "撤销") {
                    store.performUndoCommand()
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button(store.redoActionName.map { "重做\($0)" } ?? "重做") {
                    store.performRedoCommand()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("新建相簿") {
                    // 原生「照片」图库下写回系统相簿，其它范围照旧建拾光相簿。
                    store.presentNewAlbumCommand()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("新建智能相簿…") {
                    store.presentSmartAlbumEditor()
                }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            }
            CommandGroup(after: .newItem) {
                Button(store.isImporting ? "查看导入…" : "导入照片…") {
                    store.presentImportPanel()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("从「照片」导入…") {
                    store.presentPhotoPicker()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store.isNativeContainer)

                Button("新建图库…") {
                    store.beginNewLibraryFlow()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                // 接入：统一收进二级菜单，按「图库 / 存储 / 资源 / 影院 / 电视」列出来源。
                Menu("接入") {
                    Button("其他图库…") {
                        store.presentLibraryContainerPanel()
                    }
                    .keyboardShortcut("o", modifiers: [.command])

                    if cloudModule {
                        Button("网络存储…") {
                            store.presentCloudWizard()
                        }
                    }

                    if catalogModule {
                        Button("网络资源…") {
                            store.presentCatalogWizard()
                        }
                    }

                    // 网络影院：独立于「网络存储 › 影院」，打开的是聚合影视源的跨源海报墙。
                    if cinemaModule {
                        Button("网络影院…") {
                            store.navigate(to: .networkCinema)
                            store.presentCatalogWizard(domain: .networkCinema)
                        }
                    }

                    // 网络电视：先打开开关，再进接入面板（默认不接入任何源，可粘贴 M3U 或导入文件）。
                    if televisionModule {
                        Button("网络电视…") {
                            store.tvModel.setEnabled(true)
                            store.tvModel.showWizard = true
                        }
                    }
                }

                Button("切换图库…") {
                    store.presentLibraryPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("断开当前图库…") {
                    guard let url = LibraryPaths.containerLibraryURL else { return }
                    store.confirmDisconnectLibrary(
                        path: url.path,
                        name: url.deletingPathExtension().lastPathComponent)
                }
                .disabled(!store.hasContainerLibrary)
                .help("退出当前图库并回到「创建或打开图库」；图库文件与照片保留")

                Button("在「照片」中打开图库") {
                    store.openContainerInPhotos()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!store.hasContainerLibrary)

                Button("重新读取「照片」图库") {
                    store.reloadSystemLibrary()
                }
                .disabled(store.systemLibraryPath == nil)

                Button(store.currentSystemScopeImportTitle) {
                    store.importCurrentSystemScopeToLibrary()
                }
                .disabled(!store.canImportCurrentSystemScope || store.isNativeContainer)

                Button("导出所选…") {
                    store.presentBatchExport()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!store.commandPolicy.isEnabled(.exportSelection))

                Button("压缩所选…") {
                    store.presentCompression(for: store.selection)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!store.commandPolicy.isEnabled(.compressSelection))

                Button("选择全部") {
                    store.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(store.visibleCount == 0)
            }
            CommandMenu("照片") {
                Button(store.navigationParent.map { "返回「\($0.title)」" } ?? "返回上一级") {
                    store.navigateUp()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!store.canNavigateUp)

                Divider()

                // 堆叠浏览形态：与工具栏的堆叠菜单保持同一份状态。
                Menu("堆叠") {
                    ForEach(StackMode.allCases) { mode in
                        Button {
                            store.stackMode = mode
                        } label: {
                            if store.stackMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                    if !store.expandedStackIDs.isEmpty {
                        Divider()
                        Button("收起全部堆叠") {
                            store.collapseAllStacks()
                        }
                    }
                }

                Button("打开所选") {
                    if let id = store.commandTargetIDs.first {
                        store.openViewer(id)
                    }
                }
                .disabled(store.commandTargetIDs.isEmpty)

                // 内容条目：网络影院详情打开时，命令菜单与详情页共用同一份 CommandPolicy。
                if let entry = store.networkCinemaDetail {
                    Divider()
                    Button(store.catalog.isFavorite(sourceID: entry.source.id, itemID: entry.item.id)
                           ? "从稍后看移除"
                           : "加入稍后看") {
                        store.toggleNetworkCinemaWatchlist()
                    }
                    .disabled(!store.commandPolicy.isEnabled(.watchlist))
                    Button("打开影视源站点") {
                        store.openNetworkCinemaSourceSite()
                    }
                    .disabled(!store.commandPolicy.isEnabled(.openSourceSite))
                }

                Button("编辑…") {
                    store.openEditorFromCommand()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!canEditCommand)

                Button("复制编辑点") {
                    if let id = store.commandTargetIDs.first {
                        store.copyEdits(id)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!store.commandTargetIDs.contains { store.photo(id: $0)?.editRecipe != nil })

                Button("粘贴编辑点") {
                    if let id = store.commandTargetIDs.first {
                        store.pasteEdits(id)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(store.copiedEditRecipe == nil
                          || store.commandTargetIDs.isEmpty
                          || store.isReadOnlyScope)

                Button("向右旋转") {
                    store.rotateCommand(clockwise: true)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!canRotateCommand)

                Button("向左旋转") {
                    store.rotateCommand(clockwise: false)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!canRotateCommand)

                Divider()

                Button("复制照片") {
                    store.duplicateCommand()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!store.commandPolicy.isEnabled(.duplicate))

                Button("粘贴") {
                    store.pasteFromPasteboard()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(!store.commandPolicy.isEnabled(.paste))

                Button("打印…") {
                    store.printCommand()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(!store.commandPolicy.isEnabled(.printSelection))

                Button("设为桌面背景") {
                    if let id = store.commandTargetIDs.first {
                        store.setAsDesktopBackground(id)
                    }
                }
                .disabled(store.commandTargetIDs.first.flatMap { store.anyPhoto(id: $0) }?.isVideo ?? true)

                Button("幻灯片播放") {
                    store.presentSlideshow()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(store.visibleCount == 0 || store.editorID != nil || store.showSlideshow)

                Divider()

                Button(favoriteCommandTitle) {
                    store.toggleFavoriteCurrent()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!store.commandPolicy.isEnabled(.favorite))

                Button(hideCommandTitle) {
                    store.toggleHiddenCommand()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(store.commandTargetIDs.isEmpty || (store.isReadOnlyScope && !store.canEditNativeOverlay))

                Button("添加关键词…") {
                    if store.selection.isEmpty, let id = store.viewerID {
                        store.selection = [id]
                    }
                    store.showKeywordManager = true
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(store.commandTargetIDs.isEmpty || (store.isReadOnlyScope && !store.canEditNativeOverlay))

                Menu("评分") {
                    Button("无评分") { store.setRatingCurrent(0) }
                        .keyboardShortcut("0", modifiers: [.option])
                    Divider()
                    ForEach(1...5, id: \.self) { value in
                        Button("\(value) 星") { store.setRatingCurrent(value) }
                            .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: [.option])
                    }
                }
                .disabled(!canEditMetadataCommand)

                Menu("旗标") {
                    Button("留用") { store.setFlagCurrent(.pick) }
                        .keyboardShortcut("p", modifiers: [.option])
                    Button("排除") { store.setFlagCurrent(.reject) }
                        .keyboardShortcut("x", modifiers: [.option])
                    Divider()
                    Button("清除旗标") { store.setFlagCurrent(.none) }
                }
                .disabled(!canEditMetadataCommand)

                Menu("色标") {
                    Button("红色") { store.setColorLabelCurrent(.red) }
                        .keyboardShortcut("6", modifiers: [.option])
                    Button("黄色") { store.setColorLabelCurrent(.yellow) }
                        .keyboardShortcut("7", modifiers: [.option])
                    Button("绿色") { store.setColorLabelCurrent(.green) }
                        .keyboardShortcut("8", modifiers: [.option])
                    Button("蓝色") { store.setColorLabelCurrent(.blue) }
                        .keyboardShortcut("9", modifiers: [.option])
                    Divider()
                    Button("清除色标") { store.setColorLabelCurrent(.none) }
                }
                .disabled(!canEditMetadataCommand)

                Button("批量更改…") {
                    store.presentBatchChange()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!store.commandPolicy.isEnabled(.batchChange))

                Divider()

                Button("复制") {
                    store.copySelectionToPasteboard()
                }
                .disabled(!store.commandPolicy.isEnabled(.copy))

                Button("在访达中显示") {
                    store.revealCommandTargetsInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.commandTargetIDs.isEmpty
                          || (store.isCloudScope && !store.isCurrentCloudSMB))

                Divider()

                Button("移到最近删除") {
                    store.confirmDelete(store.commandTargetIDs)
                }
                .disabled(!store.commandPolicy.isEnabled(.deleteToTrash))

                Button("永久删除…") {
                    store.confirmPermanentDelete(store.commandTargetIDs)
                }
                .disabled(!store.commandPolicy.isEnabled(.deletePermanently))

                if store.sidebarItem == .trash {
                    Button("恢复") {
                        store.restore(store.commandTargetIDs)
                    }
                    .disabled(store.commandTargetIDs.isEmpty)
                }

                Divider()

                Button("图库体检") {
                    if store.isCloudScope {
                        store.setCloudScope(.health)
                    } else if store.isSystemScope {
                        store.navigate(to: .systemHealth)
                    } else {
                        store.navigate(to: .health)
                    }
                }

                Button("值得重看") {
                    if store.isCloudScope {
                        store.setCloudScope(.revisit)
                    } else {
                        store.navigate(to: store.isSystemScope ? .systemRevisit : .revisit)
                    }
                }
            }
            // 视频相关的操作统一收在这里：播放控制、画面调整与文件操作都只针对当前查看器里的视频。
            CommandMenu("视频") {
                Button("播放 / 暂停") {
                    store.toggleVideoPlaybackCommand()
                }
                .disabled(!store.canControlVideoPlayback)

                Button("上一个视频") {
                    store.viewerStepVideo(-1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(!store.videoCanStepBackward)

                Button("下一个视频") {
                    store.viewerStepVideo(1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(!store.videoCanStepForward)

                Divider()

                Button("快退 10 秒") {
                    store.seekVideoCommand(by: -10)
                }
                .disabled(!store.canControlVideoPlayback)

                Button("快进 10 秒") {
                    store.seekVideoCommand(by: 10)
                }
                .disabled(!store.canControlVideoPlayback)

                Button("上一帧") {
                    store.stepVideoFrameCommand(by: -1)
                }
                .disabled(!store.canControlVideoPlayback)

                Button("下一帧") {
                    store.stepVideoFrameCommand(by: 1)
                }
                .disabled(!store.canControlVideoPlayback)

                Divider()

                Menu("播放速度") {
                    ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                        Button {
                            store.setVideoSpeedCommand(value)
                        } label: {
                            if store.videoSpeed == value {
                                Label(Self.videoSpeedLabel(value), systemImage: "checkmark")
                            } else {
                                Text(Self.videoSpeedLabel(value))
                            }
                        }
                    }
                }
                .disabled(!store.canControlVideoPlayback)

                Toggle("循环播放", isOn: Binding(
                    get: { store.videoIsLooping },
                    set: { _ in store.toggleVideoLoopCommand() }
                ))
                .disabled(!store.canControlVideoPlayback)

                Toggle("填充画面", isOn: Binding(
                    get: { store.videoUsesFill },
                    set: { _ in store.toggleVideoGravityCommand() }
                ))
                .disabled(!store.canControlVideoPlayback)

                Button("旋转 90°") {
                    store.rotateVideoDisplayCommand()
                }
                .disabled(!store.canControlVideoPlayback)

                Toggle("画中画", isOn: Binding(
                    get: { store.videoPipActive },
                    set: { _ in store.toggleVideoPipCommand() }
                ))
                .disabled(!store.canControlVideoPlayback || !store.videoPipAvailable)

                Divider()

                Toggle("静音", isOn: Binding(
                    get: { store.videoIsMuted },
                    set: { _ in store.toggleVideoMuteCommand() }
                ))
                .disabled(!store.canControlVideoPlayback)

                Menu("音量") {
                    Button("25%") { store.setVideoVolumeCommand(0.25) }
                    Button("50%") { store.setVideoVolumeCommand(0.5) }
                    Button("100%") { store.setVideoVolumeCommand(1) }
                }
                .disabled(!store.canControlVideoPlayback)

                Menu("音轨") {
                    if store.videoAudioChoices.isEmpty {
                        Button("暂无可切换音轨") {}
                            .disabled(true)
                    } else {
                        // 菜单式 Toggle：系统自己画勾，自绘 Image 在 NSMenu 里会被丢掉。
                        ForEach(store.videoAudioChoices) { choice in
                            let title = choice.title.isEmpty ? "音轨 \(choice.index + 1)" : choice.title
                            Toggle(isOn: Binding(
                                get: { choice.index == store.videoSelectedAudioIndex },
                                set: { isOn in
                                    if isOn { store.selectVideoAudioCommand(choice.index) }
                                }
                            )) {
                                Text(title)
                            }
                        }
                    }
                }
                .disabled(!store.canControlVideoPlayback)

                Menu("字幕") {
                    Button("载入字幕文件…") {
                        store.pickVideoSubtitleCommand()
                    }

                    if store.videoHasSubtitle {
                        Button("关闭字幕") {
                            store.clearVideoSubtitleCommand()
                        }
                        Divider()
                        Button("字幕延后 0.5 秒") {
                            store.adjustVideoSubtitleOffsetCommand(by: 0.5)
                        }
                        Button("字幕提前 0.5 秒") {
                            store.adjustVideoSubtitleOffsetCommand(by: -0.5)
                        }
                        Button("重置偏移") {
                            store.resetVideoSubtitleOffsetCommand()
                        }
                    }

                    if !store.videoLegibleOptions.isEmpty {
                        Divider()
                        ForEach(store.videoLegibleOptions.indices, id: \.self) { index in
                            let option = store.videoLegibleOptions[index]
                            Button {
                                store.selectVideoLegibleCommand(option)
                            } label: {
                                if store.isVideoLegibleSelected(option) {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                        if store.videoHasEmbeddedSubtitle {
                            Button("关闭内嵌字幕") {
                                store.selectVideoLegibleCommand(nil)
                            }
                        }
                    }
                }
                .disabled(!store.canControlVideoPlayback)

                Divider()

                Button("保存当前帧…") {
                    store.saveVideoFrameCommand()
                }
                .disabled(!store.canControlVideoPlayback)

                Button("全屏播放") {
                    store.toggleVideoFullScreenCommand()
                }
                .disabled(!store.canControlVideoPlayback)

                Divider()

                Button("导出视频…") {
                    store.presentBatchExport()
                }
                .disabled(!canExportVideoCommand)

                Button("在访达中显示") {
                    store.revealCommandTargetsInFinder()
                }
                .disabled(store.commandTargetIDs.isEmpty
                          || (store.isCloudScope && !store.isCurrentCloudSMB))
            }
            CommandGroup(after: .toolbar) {
                Button("搜索") {
                    store.focusSearchField()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("键盘快捷键…") {
                    store.showShortcutHelp = true
                }
                .keyboardShortcut("/", modifiers: [.command])

                Button("智能助手…") {
                    store.showAIAssistant = true
                }

                Button("智能美化…") {
                    store.showBeautyPanel = true
                }
                .disabled(!store.canScanBeauty)

                Divider()

                Picker("分组方式", selection: $store.grouping) {
                    ForEach(GridGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.inline)
                .disabled(!store.isTimelineScope)

                Divider()

                Menu("排序") {
                    ForEach(SortKey.allCases) { key in
                        Button {
                            store.applySort(key)
                        } label: {
                            Label(store.sortKey == key
                                  ? "\(key.title) · \(store.sortAscending ? "升序 ↑" : "降序 ↓")"
                                  : key.title,
                                  systemImage: store.sortKey == key ? "checkmark" : key.icon)
                        }
                    }
                    Divider()
                    Button(store.sortAscending ? "改为降序 ↓" : "改为升序 ↑") {
                        store.sortAscending.toggle()
                    }
                }
                .disabled(!store.isGridScopeForCommands)

                Menu("相簿显示方式") {
                    ForEach(AlbumDisplayStyle.allCases) { style in
                        Toggle(isOn: Binding(
                            get: { store.albumDisplayStyle == style },
                            set: { isOn in
                                guard isOn else { return }
                                store.albumDisplayStyle = style
                            }
                        )) {
                            Label(style.title, systemImage: style.icon)
                        }
                    }
                }
                .disabled(!store.isAlbumOverviewScope)

                Menu("元数据") {
                    Toggle("标题", isOn: $settings.metadata.title)
                    Toggle("拍摄日期", isOn: $settings.metadata.capturedDate)
                    Toggle("关键词", isOn: $settings.metadata.keywords)
                    Toggle("已编辑", isOn: $settings.metadata.edited)
                    Toggle("文件类型", isOn: $settings.metadata.fileType)
                    Toggle("个人收藏", isOn: $settings.metadata.favorite)
                    Toggle("位置", isOn: $settings.metadata.location)
                    Toggle("相机", isOn: $settings.metadata.camera)
                    Toggle("分辨率", isOn: $settings.metadata.resolution)
                    Toggle("文件大小", isOn: $settings.metadata.fileSize)
                    Toggle("来源", isOn: $settings.metadata.source)
                    Toggle("视频时长", isOn: $settings.metadata.duration)
                }

                Divider()

                Button("显示/隐藏信息面板") {
                    store.showInfoPanel.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(store.viewerID == nil)

                Toggle("显示底部缩略图", isOn: $settings.viewerFilmstrip)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(store.viewerID == nil)

                Button(sidebarChrome.isVisible ? "隐藏边栏" : "显示边栏") {
                    sidebarChrome.isVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])

                Button("放大缩略图") {
                    withAnimation { store.zoomStep(1) }
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("缩小缩略图") {
                    withAnimation { store.zoomStep(-1) }
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("恢复默认缩略图大小") {
                    withAnimation { store.resetZoom() }
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Window("导入", id: "import") {
            ImportSheetView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(store.selectionModel)
                .environmentObject(store.viewerModel)
                .environmentObject(store.cloudModel)
                .tint(settings.accentColor)
                .accentColor(settings.accentColor)
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)

        // 图库选择器是独立小窗口（对齐系统「照片」的选取图库）：
        // 打开期间主窗口整窗隐藏（含窗口框架），选定或取消后由 RootView 恢复。
        Window("选取图库", id: "libraryPicker") {
            LibraryPickerView()
                .environmentObject(store)
                .tint(settings.accentColor)
                .accentColor(settings.accentColor)
        }
        .windowResizability(.contentSize)

        // 关于：系统默认面板太素，这里换成带「光之河」动效的品牌窗口。
        Window("关于拾光", id: "about") {
            AboutWindowView()
                .environmentObject(settings)
        }
        .defaultSize(width: 520, height: 500)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(store.selectionModel)
                .environmentObject(store.viewerModel)
                .environmentObject(store.cloudModel)
        }
    }
}

// MARK: - 应用生命周期

/// 拾光只保留一个实例、一个主窗口：关掉窗口就是退出应用。
final class LumaAppDelegate: NSObject, NSApplicationDelegate {
    /// 主窗口的默认尺寸：贴着当前屏幕留一点边，首屏能放下更多内容。
    static var preferredWindowSize: CGSize {
        guard let visible = NSScreen.main?.visibleFrame.size else {
            return CGSize(width: 1440, height: 900)
        }
        return CGSize(width: min(1800, max(1360, visible.width - 48)),
                      height: min(1160, max(880, visible.height - 48)))
    }

    /// 已经手动调整过的小窗口会被状态恢复带回来，这里只在明显偏小时放大。
    /// 只允许变大：窗口本来比目标大（换过显示器 / 状态恢复带回大尺寸）时原样保留，
    /// 否则启动时的这次校正会把窗口莫名缩小。
    static func enlargeMainWindowIfNeeded() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.styleMask.contains(.titled)
                && !($0 is NSPanel) && $0.sheetParent == nil
        }) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // 目标尺寸按窗口所在屏幕计算，不能拿 NSScreen.main 去套另一块屏幕。
        let target = CGSize(width: min(1800, max(1360, visible.width - 48)),
                            height: min(1160, max(880, visible.height - 48)))
        let current = window.contentLayoutRect.size
        guard current.width < target.width - 80 || current.height < target.height - 80 else {
            return
        }
        let width = max(current.width, min(target.width, visible.width - 32))
        let height = max(current.height, min(target.height, visible.height - 56))
        guard width > current.width + 1 || height > current.height + 1 else { return }
        window.setContentSize(NSSize(width: width, height: height))
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                      y: visible.midY - frame.height / 2))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 智能助手可能正在跑长任务（刮削 / 批量整理 / 多轮工具调用）：
        // 这时关掉窗口只收起界面，后台继续执行；完成后从 Dock 重新打开就能看到结果。
        let aiBusy = MainActor.assumeIsolated {
            LibraryStore.current?.aiIsResponding == true
        }
        return !aiBusy
    }

    /// 重复启动（如再次 `open Luma.app`）时激活已有实例并退出，不产生第二份进程。
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current }
        guard let existing = others.first else { return }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.install()
        // 上次退出时窗口可能被拖小了；启动时统一拉回「默认大尺寸」。
        // 窗口由 SwiftUI 创建与还原，稍后再校正一次，避免被状态恢复覆盖。
        DispatchQueue.main.async { Self.enlargeMainWindowIfNeeded() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { Self.enlargeMainWindowIfNeeded() }
        // 文本框里兼容 Windows 的 Ctrl+C / Ctrl+V 粘贴习惯。
        ControlKeyTextShortcuts.install()
        // 空闲时预热 ffmpeg 的杜比视界运行时，把 Vulkan 初始化挪出「点开视频」的等待。
        FFmpegPrewarm.schedule()
        guard let path = ProcessInfo.processInfo.environment["LUMA_SNAPSHOT"] else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView else {
                try? Data("no-window".utf8).write(to: URL(fileURLWithPath: path + ".marker"))
                return
            }
            if let image = CGWindowListCreateImage(.null,
                                                   .optionIncludingWindow,
                                                   CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            // 退路：直接渲染内容视图，不依赖屏幕录制权限。
            if !FileManager.default.fileExists(atPath: path),
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            try? Data("captured".utf8).write(to: URL(fileURLWithPath: path + ".marker"))
        }
    }
}
