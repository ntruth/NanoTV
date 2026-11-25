import SwiftUI

/// 打开中的网盘的分类入口：与拾光图库侧边栏一致 ——
/// 媒体类型 / 更多项目 / 场景 / 相簿（文件夹即相簿）。
struct CloudMountDetailView: View {
    /// 所属网盘实例：影院页也归属于它，不依赖当前 sidebarItem。
    let mountID: UUID

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings

    /// 网盘里只常用「影院」：媒体类型 / 更多项目 / 场景 / 相簿全部默认收起。
    @State private var collapsed: Set<String> = ["media", "more", "scenes", "albums"]
    @State private var hoveredSection: String?
    @State private var hoveredScope: String?
    @State private var expandedFolders: Set<String> = []
    @State private var hoveredFolder: String?
    @State private var hoveredCinema = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            cinemaRow
            // 与系统图库同一套层级：影院（网盘自有）→ 媒体类型 → 更多项目 → 场景 → 相簿。
            // 与系统图库一致：没有可用媒体类型且没有 EXIF 待读时，整个分区不占位。
            if !visibleMediaTypes.isEmpty
                || cloud.isScanningMetadata
                || store.cloudMetadataPendingCount > 0 {
                sectionHeader("媒体类型", key: "media", topPadding: 8, section: .mediaTypes,
                              menu: {
                                  if cloud.isScanningMetadata {
                                      Button("停止读取照片信息") { store.cancelCloudMetadataScan() }
                                  } else if store.cloudMetadataPendingCount > 0 {
                                      Button("读取照片信息（EXIF）…") { store.scanCloudMetadata() }
                                  }
                              })
                if !collapsed.contains("media") {
                    mediaRows
                    metadataStatusRow
                }
            }

            sectionHeader("更多项目", key: "more", section: .moreItems)
            if !collapsed.contains("more") {
                moreItemRows
            }

            sectionHeader("场景", key: "scenes", section: .scenes,
                          menu: {
                              if cloud.isAnalyzing {
                                  Button("停止识别") { store.cancelCloudContentAnalysis() }
                              } else if store.cloudPendingAnalysisCount > 0 {
                                  Button("识别当前列表…") { store.analyzeCloudContent() }
                              }
                          })
            if !collapsed.contains("scenes") {
                sceneBody
            }

            // 与系统图库一致：没有目录相簿时隐藏「相簿」分区（扫描期间保留进度提示）。
            if hasAlbums {
                sectionHeader("相簿", key: "albums", section: .folders,
                              menu: {
                                  Button(store.isCloudScanning ? "停止扫描" : "重新扫描网盘") {
                                      if store.isCloudScanning {
                                          store.stopCloudAlbumScan()
                                      } else {
                                          store.beginCloudAlbumScan(mountID: mountID)
                                      }
                                  }
                              })
                if !collapsed.contains("albums") {
                    albumRows
                }
            }
        }
        // 分类的收起状态按网盘分别保存，下次打开同一网盘时恢复。
        // 没有保存过时按默认：四个分类分区全部收起，只露出「影院」入口。
        .onAppear {
            collapsed = SidebarStateStorage.hasValue(collapsedKey)
                ? SidebarStateStorage.stringSet(collapsedKey)
                : ["media", "more", "scenes", "albums"]
        }
        .onChange(of: collapsed) { _, value in
            SidebarStateStorage.save(collapsedKey, value)
        }
    }

    /// 当前可展示的媒体类型：与系统图库一样，数量为 0 的类型不占位。
    private var visibleMediaTypes: [MediaTypeKey] {
        let counts = store.cloudScopeCounts
        return MediaTypeKey.cloudCases.filter { key in
            guard let scope = key.cloudScope else { return false }
            return counts.count(for: scope) > 0
        }
    }

    private var hasAlbums: Bool {
        !store.cloudRootFolders.isEmpty || cloud.scanPhase.isScanning
    }

    private var collapsedKey: String {
        SidebarStateStorage.Key.cloudDetailSections(mountID)
    }

    /// 是否正在浏览这个网盘的列表本身（影院页不算：进影院时高亮只留给影院行）。
    /// 网盘的分段 / 相簿选中状态记在共享的浏览模型里，只有当前网盘才该亮；
    /// 否则进入影院后整库行仍高亮，多个实例时每个展开的树还会重复亮同一行。
    private var isBrowsingThisMount: Bool {
        if case .cloudMount(let id) = store.sidebarItem { return id == mountID }
        return false
    }

    /// 影院与「视频 / 相簿」是并列的两个入口：在影院里点任何一个列表入口，
    /// 都要真正切回这个网盘的列表，而不是只改状态、页面仍停在影院。
    private func leaveCinemaIfNeeded() {
        if store.sidebarItem == .cloudCinema(mountID) {
            store.navigate(to: .cloudMount(mountID))
        }
    }

    private func openOverview(_ section: CloudOverviewSection) {
        leaveCinemaIfNeeded()
        store.openCloudOverview(section)
    }

    // MARK: - 影院（归属这个网盘）

    private var cinemaRow: some View {
        let scope = CinemaScope.mount(mountID)
        let isActive = store.sidebarItem == .cloudCinema(mountID)
        let count = store.cinemaMatchedCount(for: scope)
        let scraping = store.cinemaScrapeRunning && store.cinemaScrapeScope == scope

        return Button {
            store.activateCinemaScope(scope)
            store.navigate(to: .cloudCinema(mountID))
        } label: {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                Image(systemName: "film.stack")
                    .font(.system(size: LumaMetrics.sidebarIconSize))
                    .foregroundStyle(LumaBrand.violet)
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text("影院")
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if scraping {
                    Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    ProgressView()
                        .controlSize(.mini)
                } else if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: isActive, hovered: hoveredCinema)
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveredCinema = $0 }
        .help("这个网盘自己的电影与剧集：海报、刮削与播放入口")
        .contextMenu {
            Button("打开影院") {
                store.activateCinemaScope(scope)
                store.navigate(to: .cloudCinema(mountID))
            }
            Divider()
            // 网盘目录扫描与影院是两件事：这里也要能扫，否则相簿分区收起时找不到入口。
            Button(store.isCloudScanning ? "停止扫描网盘" : "重新扫描网盘") {
                if store.isCloudScanning {
                    store.stopCloudAlbumScan()
                } else {
                    store.beginCloudAlbumScan(mountID: mountID, forceFull: true)
                }
            }
            Divider()
            Button("刮削新视频") {
                store.startCinemaScrape(for: scope)
            }
            Button("重新刮削全部") {
                store.startCinemaScrape(for: scope, force: true)
            }
            Button("清除刮削结果", role: .destructive) {
                store.clearCinemaIndex(for: scope)
            }
        }
    }

    // MARK: - 更多项目（与系统图库同一套条目、顺序与显示条件）

    @ViewBuilder
    private var moreItemRows: some View {
        // 条目、顺序与显示条件全部取自 `CloudScope.moreItems`，与总览卡片墙共用一份定义。
        // 只读能力（图库整理 / 最近编辑 / 最近保存 / 最近删除 / 导入项目）也在相同位置，
        // 点开后是同一套右侧页面。
        let counts = store.cloudScopeCounts
        ForEach(CloudScope.moreItems(counts: counts, analyzedCount: store.cloudAnalyzedCount),
                id: \.self) { scope in
            scopeRow(scope,
                     trailingIcon: scope == .trash ? "lock.fill" : nil,
                     helpText: moreItemHelp(scope))
        }
    }

    /// 与系统图库同位入口的补充说明（只读能力在网盘里没有真实数据）。
    private func moreItemHelp(_ scope: CloudScope) -> String? {
        switch scope {
        case .recentlyEdited: return "网盘为只读，没有编辑记录"
        case .recentlySaved: return "按网盘文件的修改时间，列出最近 30 天保存的项目"
        case .trash: return "网盘不提供最近删除，请在网盘 App 或网页中管理"
        case .imports: return "网盘不产生导入批次"
        default: return nil
        }
    }

    /// EXIF 读取进度：网盘照片的拍摄时间、相机与 GPS 全部来自文件头部，不下载原图。
    @ViewBuilder
    private var metadataStatusRow: some View {
        if cloud.isScanningMetadata {
            HStack(spacing: 7) {
                ProgressView(value: cloud.metadataProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("读取信息 \(Int((cloud.metadataProgress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else if store.cloudMetadataPendingCount > 0 {
            Button {
                store.scanCloudMetadata()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "camera.metering.center.weighted")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text("继续读取照片信息（剩余 \(store.cloudMetadataPendingCount) 张）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从文件头部读取拍摄时间、相机、镜头与 GPS，用于地图、位置与值得重看")
        }
    }

    // MARK: - 媒体类型（与拾光同一组类型、顺序与显示条件）

    @ViewBuilder
    private var mediaRows: some View {
        ForEach(visibleMediaTypes) { key in
            if let scope = key.cloudScope {
                scopeRow(scope)
            }
        }
    }

    // MARK: - 场景（端侧识别）

    @ViewBuilder
    private var sceneBody: some View {
        if cloud.isAnalyzing {
            HStack(spacing: 7) {
                ProgressView(value: cloud.analysisProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
                Text("识别中 \(Int((cloud.analysisProgress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else if cloud.analysis.isEmpty {
            Button {
                store.analyzeCloudContent()
            } label: {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: LumaMetrics.sidebarIconSize))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: LumaMetrics.sidebarIconColumn)
                    Text("识别内容…")
                        .font(.system(size: LumaMetrics.sidebarTextSize))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在本机识别当前网盘列表的场景与图内文字")
            Text("识别场景与图内文字，全部在本机完成，不会上传照片")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        } else {
            let counts = store.cloudScopeCounts
            let visible = SceneCatalog.categories.filter { (counts.scenes[$0.id] ?? 0) > 0 }
            if visible.isEmpty {
                Text("未识别到常见场景")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            } else {
                ForEach(visible) { category in
                    scopeRow(.scene(category.id), count: counts.scenes[category.id] ?? 0)
                }
            }
            let pending = store.cloudPendingAnalysisCount
            if pending > 0 {
                Button {
                    store.analyzeCloudContent()
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: LumaMetrics.sidebarIconSize))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: LumaMetrics.sidebarIconColumn)
                        Text("继续识别（剩余 \(pending) 张）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("每次最多识别 120 张，避免一次读取过多网盘文件")
            }
        }
    }

    // MARK: - 相簿（文件夹）

    @ViewBuilder
    private var albumRows: some View {
        let folders = store.cloudRootFolders
        if folders.isEmpty {
            if cloud.scanPhase.isScanning {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在扫描网盘目录…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            } else {
                Text("扫描完成后，网盘文件夹会作为相簿出现在这里")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
        } else {
            // 侧边栏可能有一千多个目录：用 LazyVStack，只为可见行创建封面与手势。
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(folders) { node in
                    folderNode(node, level: 0)
                }
            }
        }
    }

    private func folderNode(_ node: CloudFolderNode, level: Int) -> AnyView {
        let isExpanded = expandedFolders.contains(node.path)
        let isSelected = isBrowsingThisMount
            && cloud.overview == nil
            && store.cloudSelectedFolderPath == node.path
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Button {
                    withAnimation(settings.motion.layout) {
                        if isExpanded {
                            expandedFolders.remove(node.path)
                        } else {
                            expandedFolders.insert(node.path)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(node.children.isEmpty ? 0 : 1)
                .disabled(node.children.isEmpty)

                Button {
                    leaveCinemaIfNeeded()
                    store.showCloudOverview(nil)
                    store.selectCloudFolder(path: node.path)
                } label: {
                    HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                        folderCover(node)
                        Text(node.name)
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if node.photoCount > 0 {
                            Text(node.photoCount.formatted())
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8 + CGFloat(level) * 14)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background {
                LumaRowHighlight(active: isSelected, hovered: hoveredFolder == node.path)
            }
            .onHover { hovering in
                if hovering {
                    hoveredFolder = node.path
                } else if hoveredFolder == node.path {
                    hoveredFolder = nil
                }
            }
            .help(node.path)

            if isExpanded {
                ForEach(node.children) { child in
                    folderNode(child, level: level + 1)
                }
            }
        })
    }

    @ViewBuilder
    private func folderCover(_ node: CloudFolderNode) -> some View {
        if let cover = node.cover {
            PhotoThumbnailView(photo: cover, purpose: .cover(20))
                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                            style: .continuous))
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
                .background(Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                                 style: .continuous))
        }
    }

    // MARK: - 分区头与行

    /// 分区头与拾光 / 系统图库共用 `SidebarSectionHeader`：同一套强调色细线、悬停按钮与点击区域。
    private func sectionHeader<MenuContent: View>(
        _ title: String,
        key: String,
        topPadding: CGFloat = 12,
        section: CloudOverviewSection? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }
    ) -> some View {
        let openAction: (() -> Void)? = section.map { value in
            { openOverview(value) }
        }
        return SidebarSectionHeader(
            title: title,
            collapsed: collapsed.contains(key),
            active: section.map { cloud.overview == $0 } ?? false,
            topPadding: topPadding,
            isHovered: hoveredSection == key,
            onOpen: openAction,
            onToggle: { toggle(key) },
            menu: menu
        )
        .onHover { inside in
            hoveredSection = inside ? key : (hoveredSection == key ? nil : hoveredSection)
        }
    }

    private func toggle(_ key: String) {
        withAnimation(settings.motion.layout) {
            if collapsed.contains(key) {
                collapsed.remove(key)
            } else {
                collapsed.insert(key)
            }
        }
    }

    /// 分类行与拾光共用 `SidebarCategoryRow`：同一套图标列、字号、内边距、悬停高亮与点击选中的表现。
    private func scopeRow(_ scope: CloudScope, count: Int? = nil,
                          trailingIcon: String? = nil,
                          helpText: String? = nil) -> some View {
        SidebarCategoryRow(
            icon: scope.icon,
            title: scope.title,
            iconColor: scope == .favorites ? .pink
                : (scope == .ratings ? .yellow : (scope == .trash ? .secondary : .accentColor)),
            trailingIcon: trailingIcon,
            count: count,
            isActive: isBrowsingThisMount
                && cloud.overview == nil
                && store.cloudSelectedFolderPath == nil
                && cloud.scope == scope,
            isHovered: hoveredScope == scope.key,
            helpText: helpText ?? scope.title,
            action: {
                leaveCinemaIfNeeded()
                store.setCloudScope(scope)
            }
        )
        .onHover { hovering in
            if hovering {
                hoveredScope = scope.key
            } else if hoveredScope == scope.key {
                hoveredScope = nil
            }
        }
    }
}
