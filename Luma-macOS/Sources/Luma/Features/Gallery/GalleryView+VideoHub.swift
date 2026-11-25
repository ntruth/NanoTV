import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaCore

/// 视频页顶栏与工具栏项。

extension GalleryView {
    // MARK: - Toolbar items

    /// 缩放控件：滑杆拖拽实时跟手（不加动画），按钮/快捷键才用短动画补间。
    /// 卡片墙调每行张数，照片网格调缩略图尺寸。
    var zoomControl: some View {
        GalleryToolbarPill {
            Button {
                withAnimation(settings.motion.layout) {
                    store.zoomStep(-1)
                }
            } label: {
                GalleryToolbarIconLabel(systemName: "minus")
            }
            .buttonStyle(.plain)
            .disabled(store.isCardWallScope
                      ? store.cardColumns <= LibraryStore.cardColumnsRange.lowerBound
                      : store.thumbSize <= LibraryStore.thumbSizeRange.lowerBound)
            .help("缩小\(zoomControlTitle)（⌘-）")
            .accessibilityLabel("缩小")

            zoomSlider
                .frame(width: 74)
                .controlSize(.mini)
                .accessibilityLabel(zoomControlTitle)

            Button {
                withAnimation(settings.motion.layout) {
                    store.zoomStep(1)
                }
            } label: {
                GalleryToolbarIconLabel(systemName: "plus")
            }
            .buttonStyle(.plain)
            .disabled(store.isCardWallScope
                      ? store.cardColumns >= LibraryStore.cardColumnsRange.upperBound
                      : store.thumbSize >= LibraryStore.thumbSizeRange.upperBound)
            .help("放大\(zoomControlTitle)（⌘+）")
            .accessibilityLabel("放大")
        }
        .help("\(zoomControlTitle)：\(zoomDensityText)（⌘+ / ⌘- / ⌘0，或双指捏合；每个侧边栏页面分别记忆）")
    }

    @ViewBuilder
    var zoomSlider: some View {
        if store.isCardWallScope {
            Slider(value: Binding(get: { Double(store.cardColumns) },
                                  set: { store.cardColumns = Int($0.rounded()) }),
                   in: Double(LibraryStore.cardColumnsRange.lowerBound)...Double(LibraryStore.cardColumnsRange.upperBound),
                   step: 1)
                .help("\(zoomControlTitle)：\(zoomDensityText)（拖动调节，⌘0 复位）")
        } else {
            Slider(value: $store.thumbSize, in: LibraryStore.thumbSizeRange)
                .help("\(zoomControlTitle)：\(zoomDensityText)（拖动调节，⌘0 复位）")
        }
    }

    /// 缩放控件提示里用张数说明，避免出现看不懂的 pt 值。
    var zoomDensityText: String {
        if isVideoHubScope || isCatalogScope {
            return "卡片 \(Int(store.thumbSize)) pt"
        }
        return store.isCardWallScope ? "每行 \(store.cardColumns) 张" : "每行 \(store.gridColumnCount) 张"
    }

    var zoomControlTitle: String {
        switch store.sidebarItem {
        case .videos, .systemVideos: return "视频卡片大小"
        case .catalogSource: return "海报大小"
        case .allAlbums, .folder, .systemFolder: return "相簿卡片大小"
        case .mediaTypes, .scenes, .systemAlbums, .systemMediaTypes,
             .moreItems, .systemMoreItems, .systemLibraries, .cloudStorages, .systemImports:
            return "卡片大小"
        case .people, .systemPeople: return "人物卡片大小"
        case .places, .systemPlaces: return "地点卡片大小"
        case .keywords, .systemKeywords: return "关键词卡片大小"
        default: return "缩略图大小"
        }
    }

    var layoutMenu: some View {
        Menu {
            ForEach(ThumbnailAspect.allCases) { aspect in
                Button {
                    guard aspect != store.thumbnailAspect else { return }
                    withAnimation(settings.motion.layout) {
                        store.thumbnailAspect = aspect
                    }
                } label: {
                    if store.thumbnailAspect == aspect {
                        Label(aspect.title, systemImage: "checkmark")
                    } else {
                        Label(aspect.title, systemImage: aspect.icon)
                    }
                }
            }
        } label: {
            GalleryToolbarIconLabel(systemName: store.thumbnailAspect.icon,
                                    active: store.thumbnailAspect != .square)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("显示形式：\(store.thumbnailAspect.title)。可选正方形、完整宽高比、瀑布流、列表")
        .accessibilityLabel("显示形式")
        .accessibilityValue(store.thumbnailAspect.title)
    }

    /// 视图控制（显示形式 / 堆叠 / 排序 / 筛选）收进同一个胶囊，避免系统逐个包裹造成大小与间距不一致。
    var galleryLayoutPill: some View {
        GalleryToolbarPill {
            layoutMenu
            stackMenu
            sortMenu
            filterMenu
        }
    }

    /// 堆叠浏览：连拍、实况与同场景连拍收成一摞，双击或右键展开。
    var stackMenu: some View {
        Menu {
            Section("堆叠浏览") {
                ForEach(StackMode.allCases) { mode in
                    Button {
                        guard mode != store.stackMode else { return }
                        withAnimation(settings.motion.layout) {
                            store.stackMode = mode
                        }
                    } label: {
                        if store.stackMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }
            if !store.expandedStackIDs.isEmpty {
                Divider()
                Button("收起全部堆叠") {
                    withAnimation(settings.motion.layout) {
                        store.collapseAllStacks()
                    }
                }
            }
        } label: {
            GalleryToolbarIconLabel(systemName: store.stackMode.icon,
                                    active: store.isStackingEnabled)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("堆叠浏览：\(store.stackMode.detail)。连拍组双击进查看器整组浏览，其它堆叠双击原地展开")
        .accessibilityLabel("堆叠浏览")
        .accessibilityValue(store.stackMode.title)
    }

    /// 常用动作（助手 / 更多 / 信息 / 共享 / 收藏）收进第二个胶囊，与视图控制左右对称。
    var galleryActionPill: some View {
        GalleryToolbarPill {
            assistantButton
            ellipsisMenu
            infoButton
            shareButton
            favoriteButton
        }
    }

    // MARK: - 视频页顶栏

    /// 与「位置」页一致的顶栏组合：统计胶囊 + 分段视图 + 筛选。
    var videoHubPrincipalControls: some View {
        HStack(spacing: 8) {
            chipPill(icon: "video.fill", text: store.videoHubStatsText)
            videoLayoutSwitch
            GalleryToolbarPill {
                videoFilterMenu
            }
        }
    }

    var videoLayoutSwitch: some View {
        VideoHubLayoutSwitch()
    }

    /// 年份与时长收进同一个菜单：工具栏宽度有限，拆成两个菜单会互相挤掉。
    var videoFilterMenu: some View {
        Menu {
            Section("年份") {
                Button {
                    store.videoHubFilter.year = nil
                } label: {
                    if store.videoHubFilter.year == nil {
                        Label("全部年份", systemImage: "checkmark")
                    } else {
                        Text("全部年份")
                    }
                }
                ForEach(store.videoHubData.availableYears, id: \.self) { year in
                    Button {
                        store.videoHubFilter.year = year
                    } label: {
                        let title = String(year) + " 年"
                        if store.videoHubFilter.year == year {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }

            Section("时长") {
                Button {
                    store.videoHubFilter.duration = nil
                } label: {
                    if store.videoHubFilter.duration == nil {
                        Label("全部时长", systemImage: "checkmark")
                    } else {
                        Text("全部时长")
                    }
                }
                ForEach(VideoDurationBand.allCases) { band in
                    Button {
                        store.videoHubFilter.duration = band
                    } label: {
                        let title = "\(band.title) · \(band.detail)"
                        if store.videoHubFilter.duration == band {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }

            if store.videoHubFilter.isActive {
                Divider()
                Button("清除筛选") {
                    store.videoHubFilter = VideoHubFilter()
                }
            }
        } label: {
            videoFilterLabel(icon: store.videoHubFilter.isActive
                                 ? "line.3.horizontal.decrease.circle.fill"
                                 : "line.3.horizontal.decrease.circle",
                             text: videoFilterSummary ?? "筛选",
                             active: store.videoHubFilter.isActive)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按年份或时长筛选视频")
        .accessibilityLabel("筛选视频")
    }

    var videoFilterSummary: String? {
        var parts: [String] = []
        if let year = store.videoHubFilter.year {
            parts.append(String(year) + " 年")
        }
        if let duration = store.videoHubFilter.duration {
            parts.append(duration.title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func videoFilterLabel(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .frame(height: 26)
        .padding(.horizontal, 7)
        .contentShape(Rectangle())
    }

    var isFiltering: Bool {
        store.photoFilter != .all || store.keywordFilter != nil || store.hasMetadataFilters
    }

    /// 悬停即可读懂当前顺序，不必打开菜单。
    var sortHelpText: String {
        "排序：\(store.sortKey.title) · \(store.sortAscending ? "升序" : "降序")。点击调整排序方式、方向与缩略图信息"
    }

    var sortMenu: some View {
        Menu {
            Section("排序方式") {
                ForEach(SortKey.allCases) { key in
                    Button {
                        store.applySort(key)
                    } label: {
                        if store.sortKey == key {
                            Label("\(key.title)（\(store.sortAscending ? "升序 ↑" : "降序 ↓")）",
                                  systemImage: "checkmark")
                        } else {
                            Label(key.title, systemImage: key.icon)
                        }
                    }
                }
            }

            Section("排序方向") {
                Button {
                    store.sortAscending = true
                } label: {
                    if store.sortAscending {
                        Label("升序 ↑", systemImage: "checkmark")
                    } else {
                        Text("升序 ↑")
                    }
                }
                Button {
                    store.sortAscending = false
                } label: {
                    if store.sortAscending {
                        Text("降序 ↓")
                    } else {
                        Label("降序 ↓", systemImage: "checkmark")
                    }
                }
            }

            Section("缩略图上显示") {
                metadataOptions()
            }
        } label: {
            GalleryToolbarIconLabel(systemName: "arrow.up.arrow.down",
                                    active: store.sortKey != .capturedAt || store.sortAscending)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(sortHelpText)
        .accessibilityLabel("排序")
        .accessibilityValue("\(store.sortKey.title)，\(store.sortAscending ? "升序" : "降序")")
    }

    @ViewBuilder
    func metadataOptions() -> some View {
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

    /// 网络存储没有「已编辑」与「相簿」概念，隐藏这两个无效筛选项。
    var availableFilters: [PhotoFilter] {
        guard store.isCloudScope else { return PhotoFilter.allCases }
        return PhotoFilter.allCases.filter { $0 != .edited && $0 != .notInAlbum }
    }

    var filterMenu: some View {
        Menu {
            ForEach(availableFilters) { filter in
                Button {
                    store.photoFilter = filter
                } label: {
                    if store.photoFilter == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Label(filter.title, systemImage: filter.icon)
                    }
                }
            }

            if !store.isSystemScope, !store.isCloudScope {
                Divider()

                Section("评分") {
                    Button {
                        store.ratingFilter = 0
                    } label: {
                        if store.ratingFilter == 0 {
                            Label("不限", systemImage: "checkmark")
                        } else {
                            Text("不限")
                        }
                    }
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            store.ratingFilter = value
                        } label: {
                            if store.ratingFilter == value {
                                Label("\(value) 星及以上", systemImage: "checkmark")
                            } else {
                                Label("\(value) 星及以上", systemImage: "star.fill")
                            }
                        }
                    }
                }

                Section("旗标") {
                    Button {
                        store.flagFilter = nil
                    } label: {
                        if store.flagFilter == nil {
                            Label("不限", systemImage: "checkmark")
                        } else {
                            Text("不限")
                        }
                    }
                    ForEach([PhotoFlag.pick, .reject]) { flag in
                        Button {
                            store.flagFilter = flag
                        } label: {
                            if store.flagFilter == flag {
                                Label(flag.title, systemImage: "checkmark")
                            } else {
                                Label(flag.title, systemImage: flag.icon)
                            }
                        }
                    }
                }

                Section("色标") {
                    Button {
                        store.colorLabelFilter = nil
                    } label: {
                        if store.colorLabelFilter == nil {
                            Label("不限", systemImage: "checkmark")
                        } else {
                            Text("不限")
                        }
                    }
                    ForEach(PhotoColorLabel.allCases.filter { $0 != .none }) { label in
                        Button {
                            store.colorLabelFilter = label
                        } label: {
                            if store.colorLabelFilter == label {
                                Label(label.title, systemImage: "checkmark")
                            } else {
                                Label(label.title, systemImage: "circle.fill")
                            }
                        }
                    }
                }

                if store.hasMetadataFilters {
                    Button("清除评分 / 旗标 / 色标筛选") {
                        store.clearMetadataFilters()
                    }
                }
            }

            Divider()

            if !store.isSystemScope, !store.isCloudScope, !store.keywordOptions.isEmpty {
                Section("关键词") {
                    ForEach(store.keywordOptions.prefix(10)) { option in
                        Button {
                            store.keywordFilter = option.name
                        } label: {
                            if store.keywordFilter == option.name {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Label(option.name, systemImage: "tag")
                            }
                        }
                    }
                    if store.keywordFilter != nil {
                        Button("清除关键词筛选") {
                            store.keywordFilter = nil
                        }
                    }
                }
            }

            if !store.isSystemScope, !store.isCloudScope {
                Button("管理关键词…") {
                    store.showKeywordManager = true
                }
            }
        } label: {
            GalleryToolbarIconLabel(
                systemName: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                active: isFiltering
            )
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(isFiltering ? "筛选：\(filterSummary)" : "筛选：当前显示全部照片（可按收藏、已编辑、关键词等过滤）")
        .accessibilityLabel("筛选")
        .accessibilityValue(isFiltering ? filterSummary : "全部照片")
    }

    /// 菜单未打开时也能从悬停提示看到筛选条件。
    var filterSummary: String {
        var parts: [String] = []
        if store.photoFilter != .all { parts.append(store.photoFilter.title) }
        if store.ratingFilter > 0 { parts.append("评分 ≥ \(store.ratingFilter)") }
        if let flag = store.flagFilter { parts.append(flag.title) }
        if let label = store.colorLabelFilter { parts.append("色标：\(label.title)") }
        if let keyword = store.keywordFilter { parts.append("关键词：\(keyword)") }
        return parts.isEmpty ? "全部照片" : parts.joined(separator: " · ")
    }

    /// 「更多」只放图库里没有独立入口的动作；排序、元数据、缩略图比例已在工具栏按钮与菜单栏中提供。
    var ellipsisMenu: some View {
        Menu {
            if store.canImportCurrentSystemScope {
                Button(store.currentSystemScopeImportTitle) {
                    store.importCurrentSystemScopeToLibrary()
                }
                Divider()
            }

            if !selectionModel.ids.isEmpty, !store.isReadOnlyScope {
                Section("所选 \(selectionModel.ids.count) 项") {
                    Button("压缩所选…") {
                        store.presentCompression(for: selectionModel.ids)
                    }
                    Button("导出所选到文件夹…") {
                        store.presentBatchExport()
                    }
                }
                Divider()
            }

            Button(store.isImporting ? "查看导入…" : "导入照片…") {
                store.presentImportPanel()
            }
            if !store.isCloudScope {
                Button("在访达中显示图库") {
                    if store.isSystemScope {
                        store.revealSystemLibraryInFinder()
                    } else {
                        store.revealLibraryInFinder()
                    }
                }
            }
            if store.trashCount > 0 {
                Divider()
                Button("清空最近删除", role: .destructive) {
                    store.confirmEmptyTrash()
                }
            }
        } label: {
            GalleryToolbarIconLabel(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("更多操作：导入照片、压缩 / 导出所选、在访达中显示、清空最近删除")
        .accessibilityLabel("更多操作")
    }

    var assistantButton: some View {
        Button {
            store.showAIAssistant = true
        } label: {
            GalleryToolbarIconLabel(systemName: "sparkles", active: true)
        }
        .buttonStyle(.plain)
        .help("智能助手：用自然语言查找、整理图库（写操作会先确认）")
        .accessibilityLabel("智能助手")
    }

    var infoButton: some View {
        Button {
            store.showLibraryInfo.toggle()
        } label: {
            GalleryToolbarIconLabel(systemName: store.showLibraryInfo ? "info.circle.fill" : "info.circle",
                                    active: store.showLibraryInfo)
        }
        .buttonStyle(.plain)
        .help("信息面板：查看图库统计、当前照片详情与存储情况")
        .accessibilityLabel("信息面板")
    }

    /// 浮动信息卡：不随选择变化关闭，方向键切换照片时内容就地更新；
    /// 标题区域可拖动移动，右下角可拖动调整大小，双击标题复位。
    func libraryInfoPanel(container: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("信息")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .gesture(infoPanelDragGesture(container: container))
                .onTapGesture(count: 2) { resetInfoPanel(container: container) }
                .help("拖动移动；双击复位")

                Button {
                    store.showLibraryInfo = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭信息")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Group {
                    if selectionModel.ids.count == 1,
                       let id = selectionModel.ids.first,
                       let photo = store.anyPhoto(id: id) {
                        PhotoQuickInfoView(photo: photo)
                    } else if store.isCloudScope {
                        CloudMountInfoView()
                    } else if store.isSystemScope {
                        SystemLibraryInfoView()
                    } else {
                        LibraryInfoView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: infoPanelSize.width, height: infoPanelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(infoPanelResizeGesture(container: container))
                .help("拖动调整大小")
                .padding(4)
        }
        .shadow(color: .black.opacity(0.20), radius: 22, y: 10)
    }

    func infoPanelDragGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if infoDragOrigin == nil { infoDragOrigin = infoPanelOffset }
                guard let origin = infoDragOrigin else { return }
                infoPanelOffset = clampedInfoOffset(
                    CGSize(width: origin.width + value.translation.width,
                           height: origin.height + value.translation.height),
                    container: container)
            }
            .onEnded { _ in infoDragOrigin = nil }
    }

    func infoPanelResizeGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if infoResizeOrigin == nil { infoResizeOrigin = infoPanelSize }
                guard let origin = infoResizeOrigin else { return }
                infoPanelSize = clampedInfoSize(
                    CGSize(width: origin.width + value.translation.width,
                           height: origin.height + value.translation.height),
                    container: container)
                infoPanelOffset = clampedInfoOffset(infoPanelOffset, container: container)
            }
            .onEnded { _ in infoResizeOrigin = nil }
    }

    func resetInfoPanel(container: CGSize) {
        infoPanelSize = clampedInfoSize(CGSize(width: 400, height: 560), container: container)
        infoPanelOffset = .zero
    }

    func clampedInfoSize(_ size: CGSize, container: CGSize) -> CGSize {
        let maxWidth = max(380, min(760, container.width - 60))
        let maxHeight = max(240, min(900, container.height - 90))
        return CGSize(width: min(max(380, size.width), maxWidth),
                      height: min(max(240, size.height), maxHeight))
    }

    func clampedInfoOffset(_ offset: CGSize, container: CGSize) -> CGSize {
        let maxLeft = -(container.width - infoPanelSize.width - 28)
        let maxDown = container.height - infoPanelSize.height - 24
        return CGSize(width: min(0, max(maxLeft, offset.width)),
                      height: min(max(0, maxDown), max(0, offset.height)))
    }

    var shareButton: some View {
        ShareLink(items: store.shareURLs) {
            GalleryToolbarIconLabel(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .disabled(store.shareURLs.isEmpty)
        .help("共享所选照片（未选择时共享当前照片）")
        .accessibilityLabel("共享")
    }

    var favoriteButton: some View {
        Button {
            store.toggleFavoriteCurrent()
        } label: {
            GalleryToolbarIconLabel(systemName: store.currentIsFavorite ? "heart.fill" : "heart",
                                    active: store.currentIsFavorite,
                                    activeColor: .pink)
        }
        .buttonStyle(.plain)
        .disabled(!store.canToggleFavorite
                  || (selectionModel.ids.isEmpty && store.viewerID == nil))
        .help(store.currentIsFavorite ? "取消收藏当前选择" : "把当前选择加入个人收藏")
        .accessibilityLabel(store.currentIsFavorite ? "取消个人收藏" : "标记为个人收藏")
    }

    var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.85),
                          style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            .background(Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 56, height: 56)
                        .background(.regularMaterial, in: Circle())
                    Text("松开以导入照片")
                        .font(.system(size: 14, weight: .semibold))
                    Text("支持照片、视频与文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            store.prepareImport(urls)
        }
        return true
    }
}
