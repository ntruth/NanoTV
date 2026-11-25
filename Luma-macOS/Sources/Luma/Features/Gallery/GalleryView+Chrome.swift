import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaCore

/// 图库顶部的上下文条与工具栏内容。

extension GalleryView {
    // MARK: - 顶部上下文条

    /// 人物 / 位置 / 图库体检 / 精选集：把原本占首屏的大标题压缩进统一工具栏。
    var showsContextChip: Bool {
        if store.isCloudScope {
            switch store.cloudScope {
            case .people, .places, .keywords, .health: return true
            default: return false
            }
        }
        switch store.sidebarItem {
        case .people, .systemPeople, .places, .systemPlaces, .health, .systemHealth,
             .collections, .systemCollections, .keywords, .systemKeywords,
             .systemImportSession:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    var contextChip: some View {
        if store.isCloudScope {
            switch store.cloudScope {
            case .people:
                chipPill(icon: "person.2",
                         text: "\(store.cloudPeople.count.formatted()) 位 · 本机聚类")
            case .places:
                if let place = store.selectedPlace {
                    chipPill(icon: "mappin",
                             text: "\(place.title) · \(place.count.formatted()) 张照片")
                } else {
                    chipPill(icon: "mappin.and.ellipse",
                             text: "\(store.placeClusters.count.formatted()) 个地点 · \(store.geoPhotos.count.formatted()) 张")
                }
            case .keywords:
                if let keyword = store.selectedKeyword {
                    chipPill(icon: "tag",
                             text: "#\(keyword) · \(store.visibleCount.formatted()) 张照片")
                } else {
                    let options = store.keywordOptions
                    let photos = options.reduce(0) { $0 + $1.count }
                    chipPill(icon: "tag",
                             text: "\(options.count.formatted()) 个关键词 · \(photos.formatted()) 张")
                }
            case .health:
                if cloud.isScanningHealth {
                    chipPill(icon: "stethoscope",
                             text: "检查中 \(Int((cloud.healthScanProgress * 100).rounded()))%")
                } else if let report = cloud.healthReport {
                    chipPill(icon: "stethoscope",
                             text: "模糊 \(report.blurry.count) · 相似 \(report.similarDuplicatePhotos.count) · 已查 \(report.scannedCount)")
                } else {
                    chipPill(icon: "stethoscope", text: "本机检查照片质量")
                }
            default:
                EmptyView()
            }
        } else {
            switch store.sidebarItem {
        case .collections:
            chipPill(icon: "rectangle.stack", text: "智能汇总 · 照片 / 视频 / 编辑成果")
        case .systemCollections:
            chipPill(icon: "rectangle.stack",
                     text: "只读汇总 · \(store.systemLibraryName ?? "系统照片图库")")
        case .people:
            if let id = store.selectedLocalPersonID,
               let person = store.localPeople.first(where: { $0.id == id }) {
                chipPill(icon: "person.crop.circle",
                         text: "\(person.name) · \(person.assetIDs.count.formatted()) 张照片")
            } else {
                chipPillAction(icon: "person.2",
                               text: "\(store.localPeople.count.formatted()) 位 · 本机聚类") {
                    Button {
                        if store.isClusteringFaces {
                            store.cancelFaceClustering()
                        } else {
                            store.startFaceClustering()
                        }
                    } label: {
                        Image(systemName: store.isClusteringFaces ? "stop.circle" : "wand.and.stars")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(store.isClusteringFaces ? "停止人物分析" : "分析尚未处理过的照片")
                }
            }
        case .systemPeople:
            if let person = store.selectedPerson {
                chipPill(icon: person.isPet ? "pawprint" : "person.crop.circle",
                         text: "\(person.name) · \(person.faceCount.formatted()) 张照片")
            } else {
                chipPill(icon: "person.2",
                         text: "\(store.systemPeople.count.formatted()) 位 · 官方识别")
            }
        case .places, .systemPlaces:
            if let place = store.selectedPlace {
                chipPill(icon: "mappin",
                         text: "\(place.title) · \(place.count.formatted()) 张照片")
            } else {
                chipPill(icon: "mappin.and.ellipse",
                         text: "\(store.placeClusters.count.formatted()) 个地点 · \(store.geoPhotos.count.formatted()) 张")
            }
        case .keywords, .systemKeywords:
            if let keyword = store.selectedKeyword {
                chipPill(icon: "tag",
                         text: "#\(keyword) · \(store.visibleCount.formatted()) 张照片")
            } else {
                let options = store.keywordOptions
                let photos = options.reduce(0) { $0 + $1.count }
                chipPill(icon: "tag",
                         text: "\(options.count.formatted()) 个关键词 · \(photos.formatted()) 张")
            }
        case .health, .systemHealth:
            if store.isScanningHealth {
                chipPill(icon: "stethoscope",
                         text: "检查中 \(Int(store.healthScanProgress * 100))% · 模糊 \(store.healthReport?.blurry.count ?? 0) 张")
            } else if store.isFinalizingHealth {
                chipPill(icon: "stethoscope",
                         text: "整理中 · 已查 \(store.healthReport?.scannedCount ?? 0) 张")
            } else if store.healthReportMatchesCurrentScope, let report = store.healthReport {
                chipPill(icon: "stethoscope",
                         text: "模糊 \(report.blurry.count) · 相似 \(report.similarDuplicatePhotos.count) · 已查 \(report.scannedCount)")
            } else {
                chipPill(icon: "stethoscope", text: "本机检查照片质量")
            }
        case .systemImportSession(let id):
            importSessionChip(id)
        default:
            EmptyView()
            }
        }
    }
    /// 导入批次页的顶栏信息：这批内容的导入时间、照片 / 视频构成与拍摄跨度。
    @ViewBuilder
    func importSessionChip(_ id: Int64) -> some View {
        let summary = store.systemImportSessionSummary(id)
        HStack(spacing: 9) {
            chipText(icon: "square.and.arrow.down.on.square",
                     text: importSessionDateText(id))
            chipDivider
            chipText(icon: "photo.on.rectangle",
                     text: importCompositionText(summary))
            if let span = importCaptureSpanText(summary) {
                chipDivider
                chipText(icon: "calendar", text: span)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .help("这次导入的批次信息")
    }

    var chipDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 0.6, height: 13)
    }

    func importSessionDateText(_ id: Int64) -> String {
        guard let session = store.systemImportSessions.first(where: { $0.id == id }) else {
            return "导入批次"
        }
        return "\(DateText.fullFormatter.string(from: session.createdAt)) 导入"
    }

    func importCompositionText(_ summary: SystemImportSessionSummary?) -> String {
        guard let summary, summary.totalCount > 0 else {
            return "\(store.visibleCount.formatted()) 项"
        }
        if summary.videoCount > 0 {
            let photos = max(0, summary.totalCount - summary.videoCount)
            return "\(photos.formatted()) 照片 · \(summary.videoCount.formatted()) 视频"
        }
        return "\(summary.totalCount.formatted()) 项"
    }

    func importCaptureSpanText(_ summary: SystemImportSessionSummary?) -> String? {
        guard let summary, let earliest = summary.earliest, let latest = summary.latest else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(earliest, inSameDayAs: latest) {
            return "拍摄于 \(DateText.dayFormatter.string(from: earliest))"
        }
        let start = DateText.dayFormatter.string(from: earliest)
        let end = DateText.dayFormatter.string(from: latest)
        let days = (calendar.dateComponents([.day],
                                            from: calendar.startOfDay(for: earliest),
                                            to: calendar.startOfDay(for: latest)).day ?? 0) + 1
        return "拍摄 \(start) – \(end) · 跨 \(days) 天"
    }

    // MARK: - 工具栏内容

    /// 工具栏中区：分页胶囊 / 源内浏览条 / 资源控制台。
    @ViewBuilder
    var principalBarContent: some View {
        if isLibraryHubScope {
            // 图库总览：资源 / 照片 / 收藏并入工具栏同一行。
            LibraryHubTabs()
        } else if isCatalogHubScope {
            // 网络资源总览：浏览 / 片单 / 更新日历并入工具栏同一行。
            CatalogHubTabs()
        } else if isCloudStoragesHubScope {
            // 网络存储总览：总览 / 存储 / 影院 / 续播 / 管理并入工具栏同一行。
            CloudStoragesHubTabs()
        } else if isTVHubScope {
            // 网络电视总览：频道 / 电视源 / 状态并入工具栏同一行。
            // 点开具体源后只显示这一个源，工具栏换成源内浏览条。
            if let playlistID = store.tvModel.focusedPlaylistID {
                TVFocusedSourceBar(playlistID: playlistID)
            } else {
                TVHubTabs()
            }
        } else if isNetworkCinemaScope {
            // 网络影院：详情页只显示正在看的这部片；聚合页才有分页胶囊。
            // 点开具体源后不在顶部占位，分类与内容全部交给页面自己展示。
            if let detail = store.networkCinemaDetail {
                NetworkCinemaDetailTitleBar(entry: detail)
            } else if store.networkCinemaSourceID != nil {
                NetworkCinemaSourceConsole()
            } else {
                NetworkCinemaHubTabs()
            }
        } else if isCatalogScope {
            // 网络资源：中区是「分类 + 站点 + 刷新」舱体，分类菜单与左侧菜单同源。
            CatalogToolbarConsole()
        } else {
            principalToolbarContent
        }
    }

    @ViewBuilder
    var navigationToolbarContent: some View {
        if showsCinemaConsole {
            // 影院控制台由工具栏里的左右两段承担，这里不再重复显示。
            EmptyView()
        } else if let snapshot = store.searchReturn, store.searchReturnAvailable {
            // 由搜索结果点进来的页面：一步回到刚才的关键词与筛选。
            Button {
                store.returnToSearch()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("搜索「\(snapshot.query)」")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .help("返回搜索结果")
            .accessibilityLabel("返回搜索结果")
        } else if isCloudMountScope,
                  store.cloudBreadcrumbChain.count > 1 || store.cloudOverviewSection != nil {
            LumaBreadcrumbBar(crumbs: cloudBreadcrumbCrumbs) { crumb in
                selectCloudCrumb(crumb)
            }
        } else if store.albumBreadcrumbs.count > 1 {
            LumaBreadcrumbBar(crumbs: store.albumBreadcrumbs.map {
                LumaBreadcrumbBar.Crumb(id: $0.id, title: $0.title)
            }) { crumb in
                if let target = store.albumBreadcrumbs.first(where: { $0.id == crumb.id }) {
                    store.navigate(to: target.item)
                }
            }
        } else if let parent = store.navigationParent {
            Button {
                store.navigateUp()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(parent.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                }
            }
            .help("返回\(parent.title)")
            .accessibilityLabel("返回\(parent.title)")
        }
    }

    var isCloudMountScope: Bool { store.isCloudScope }

    /// 影院（本地图库或某个网盘的）在顶栏显示专用的控制台。
    var isCinemaScope: Bool {
        switch store.sidebarItem {
        case .cinema, .cloudCinema: return true
        default: return false
        }
    }

    /// 影院顶栏控制台常驻（搜索时也不换血），避免输入第一个字时整条工具栏重建、搜索框失焦。
    var showsCinemaConsole: Bool {
        isCinemaScope
    }

    /// 网盘面包屑：整个网盘 → 文件夹相簿链路；分类总览或具体分类再追加一节。
    var cloudBreadcrumbCrumbs: [LumaBreadcrumbBar.Crumb] {
        var crumbs = store.cloudBreadcrumbChain.map {
            LumaBreadcrumbBar.Crumb(id: "folder:" + $0.id, title: $0.name)
        }
        if let section = store.cloudOverviewSection {
            crumbs.append(LumaBreadcrumbBar.Crumb(id: "overview", title: section.title))
        } else if store.cloudScope != .all {
            crumbs.append(LumaBreadcrumbBar.Crumb(id: "scope", title: store.cloudScope.title))
        }
        return crumbs
    }

    func selectCloudCrumb(_ crumb: LumaBreadcrumbBar.Crumb) {
        if crumb.id == "overview" {
            store.showCloudOverview(nil)
            return
        }
        if crumb.id == "scope" {
            // 与拾光的分类页一致：点当前分类退回整个网盘（关键词退回关键词总览）。
            store.setCloudScope(store.cloudScope.keywordOverviewParent ?? .all)
            return
        }
        // 总览页点节点：先退出总览与分类，再进入目标目录。
        if store.cloudOverviewSection != nil {
            store.showCloudOverview(nil)
        }
        if store.cloudScope != .all {
            store.setCloudScope(store.cloudScope.keywordOverviewParent ?? .all)
        }
        let path = String(crumb.id.dropFirst("folder:".count))
        store.selectCloudFolder(path: path == store.cloudBreadcrumbRootID ? nil : path)
    }

    /// 网盘工具栏动作：刷新与（可写时）新建 / 上传，与其它工具胶囊同一套外观。
    var cloudToolbarActions: some View {
        GalleryToolbarPill {
            if store.isCurrentCloudWritable {
                Menu {
                    Button("新建文件夹…") { store.requestCloudNewFolder() }
                    Button("上传照片/视频…") { store.presentCloudUploadPanel() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建文件夹或上传")
            }
            Button {
                store.refreshCloudDirectory()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重新扫描这个网盘")
        }
    }

    @ViewBuilder
    var principalToolbarContent: some View {
        if isCloudMountScope {
            // 与拾光 / 系统图库同一套中间栏：总览与专用页面由窗口标题表达；
            // 普通照片列表显示年 / 月 / 所有照片分组，分类页显示对应上下文。
            if store.cloudOverviewSection != nil {
                EmptyView()
            } else if isCloudGridScope, store.isTimelineScope {
                TimelineGroupingSwitch(selection: $store.grouping)
            } else if showsContextChip {
                contextChip
            } else if isOrganizeScope {
                organizeStatsChip
            }
        } else if isGridScope, store.isTimelineScope {
            TimelineGroupingSwitch(selection: $store.grouping)
        } else if isGridScope, store.isFavoritesScope {
            if let bucket = store.selectedFavoriteBucket {
                favoritesBucketChip(bucket)
            } else {
                FavoritesViewModeSwitch()
            }
        } else if isVideoHubScope, !hasSearchText {
            // 与「位置」一致：统计胶囊 + 分段视图 + 筛选靠右，标题留在左侧。
            videoHubPrincipalControls
        } else if showsContextChip {
            contextChip
        } else if isOrganizeScope {
            organizeStatsChip
        }
    }

    @ViewBuilder
    var primaryActionToolbarContent: some View {
        if isCloudMountScope {
            cloudToolbarActions
        }
        if isPlacesScope {
            PlaceGranularitySwitch()
            placesSearchField
        }
        if isMapScope {
            // 搜索时页面已经切成结果页，地图底图切换不再有意义。
            if !hasSearchText {
                MapStyleSwitch()
            }
            gallerySearchField
        }
        if store.sidebarItem == .people || store.sidebarItem == .systemPeople
            || (store.isCloudScope && store.cloudScope == .people) {
            PeopleGroupFilterSwitch()
        }
        if store.sidebarItem == .health || store.sidebarItem == .systemHealth {
            GalleryToolbarPill { healthToolbarActions }
        }
        if isOrganizeScope {
            OrganizeDimensionSwitch()
        }
        if isGridScope {
            // 收藏汇总维度页也要保留这一组：切维度时右侧工具栏不能突然少两块。
            galleryLayoutPill
        }
        // 总览类页面（图库 / 网络资源 / 网络存储 / 影院 / 电视）没有单张照片动作：右侧只留智能助手，
        // ⋯ / 信息 / 共享 / 收藏在这里无意义，与搜索一起在所有分页保持一致。
        if isHubBarScope {
            // 窄窗口只留一个会收缩的搜索按钮，避免把工具栏挤进溢出菜单。
            if !toolbarCompact {
                GalleryToolbarPill {
                    assistantButton
                }
            }
        } else {
            galleryActionPill
        }
        // 这些模块的每个分页都保留同一个顶栏搜索，切换 tab 时右侧不会少一块。
        if !isPlacesScope && !isRevisitScope && !isMapScope {
            gallerySearchField
        }
    }

    func chipPill(icon: String, text: String) -> some View {
        chipText(icon: icon, text: text)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
    }

    /// 整理工作室的汇总：已评分 / 已选 / 已拒绝 / 有颜色，与「位置」的统计胶囊同一套语言。
    var organizeStatsChip: some View {
        let stats = store.organizeStudioStats
        return HStack(spacing: 8) {
            organizeStatItem("已评分", stats.rated, icon: "star.fill", tint: LumaBrand.amber)
            chipDivider
            organizeStatItem("已选", stats.pick, icon: "flag.fill", tint: LumaBrand.mint)
            chipDivider
            organizeStatItem("已拒绝", stats.reject, icon: "xmark.circle.fill", tint: LumaBrand.coral)
            chipDivider
            organizeStatItem("有颜色", stats.labeled, icon: "paintpalette.fill", tint: LumaBrand.violet)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .help("当前图库的评分、旗标与色标汇总")
    }

    func organizeStatItem(_ title: String, _ value: Int,
                                  icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(value.formatted())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .help(title)
    }

    /// 收藏汇总下钻后的顶栏：返回汇总 + 当前分类 + 数量。
    func favoritesBucketChip(_ bucket: FavoritesBucketSelection) -> some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    store.clearFavoritesBucket()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(store.favoritesViewMode.title)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回\(store.favoritesViewMode.title)汇总")

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 0.6, height: 13)

            chipText(icon: bucket.dimension == .person ? "person.crop.circle" : bucketIcon(bucket),
                     text: "\(bucket.title) · \(store.visibleCount.formatted()) 项")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .help("当前只显示该分类的收藏")
    }

    func bucketIcon(_ bucket: FavoritesBucketSelection) -> String {
        switch bucket.dimension {
        case .year: return "calendar"
        case .kind: return FavoriteKindBucket(rawValue: bucket.key)?.icon ?? "photo"
        case .place: return "mappin.and.ellipse"
        case .camera: return "camera"
        case .person: return "person.crop.circle"
        }
    }

    func chipPillAction<Trailing: View>(icon: String,
                                                text: String,
                                                @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            chipText(icon: icon, text: text)
            trailing()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
    }

    func chipText(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    var placesSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索地点", text: $placesQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 120)
            if !placesQuery.isEmpty {
                Button {
                    placesQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .help("搜索地点")
    }

    /// 顶栏搜索：宽度够时是一条固定宽的搜索框，窗口变窄后收成放大镜图标，点开才是输入框。
    @ViewBuilder
    var gallerySearchField: some View {
        if toolbarCompact {
            compactSearchButton
        } else {
            searchPill(width: 280)
        }
    }

    private var compactSearchButton: some View {
        Button {
            showSearchPopover = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.searchText.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(store.searchText.isEmpty
                                      ? Color.primary.opacity(0.10)
                                      : Color.accentColor.opacity(0.45),
                                      lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .help("搜索图库 / 网盘 / 影院 / 电视 / 资源（⌘F）")
        .popover(isPresented: $showSearchPopover, arrowEdge: .bottom) {
            searchPill(width: 320)
                .padding(10)
                .onAppear { isSearchFieldFocused = true }
        }
    }

    private func searchPill(width: CGFloat) -> some View {
        searchFieldContent
            .padding(.horizontal, 11)
            .frame(width: width, height: 32)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isSearchFieldFocused
                                  ? Color.accentColor.opacity(0.55)
                                  : Color.primary.opacity(0.10),
                                  lineWidth: isSearchFieldFocused ? 1 : 0.5)
            }
            .contentShape(Capsule())
            .help("统一搜索：图库 / 网盘 / 影院 / 电视 / 资源（⌘F，Esc 清除）")
            .accessibilityLabel("统一搜索")
    }

    /// 搜索范围三档菜单：全局（默认）/ 模块内（本功能）/ 窗口内（当前窗口）。
    func searchScopeMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            ForEach(availableSearchScopes) { scope in
                Button {
                    store.searchScope = scope
                } label: {
                    if store.searchScope == scope {
                        SwiftUI.Label("\(scope.title) · \(scope.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(scope.title) · \(scope.detail)")
                    }
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("搜索范围：\(store.searchScope.title) · \(store.searchScope.detail)")
        .accessibilityLabel("搜索范围")
    }

    private var searchFieldContent: some View {
        HStack(spacing: 6) {
            Button {
                isSearchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSearchFieldFocused ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索照片（⌘F）")

            TextField("搜索照片、影片、频道、资源", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFieldFocused)
                .onSubmit {
                    isSearchFieldFocused = false
                    showSearchPopover = false
                }
                .onExitCommand {
                    if store.searchText.isEmpty {
                        isSearchFieldFocused = false
                        showSearchPopover = false
                    } else {
                        store.searchText = ""
                    }
                }

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }

            searchScopeMenu {
                Text(store.searchScope.shortTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule(style: .continuous))
            }
        }
    }

    /// 影院顶栏搜索：与放映机控制台同一套内嵌屏质感，浅色下换成香槟白屏。
    var cinemaSearchField: some View {
        let dark = scheme == .dark
        let accent = dark ? LumaBrand.amber : Color(red: 0.62, green: 0.41, blue: 0.08)
        let primaryText = dark ? Color.white.opacity(0.92) : Color(white: 0.15)
        let placeholder = dark ? Color.white.opacity(0.32) : Color(white: 0.52)
        let iconIdle = dark ? Color.white.opacity(0.50) : Color(white: 0.42)
        let faint = dark ? Color.white.opacity(0.45) : Color(white: 0.55)

        return HStack(spacing: 6) {
            Button {
                isSearchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSearchFieldFocused ? accent : iconIdle)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索影片（⌘F）")

            ZStack(alignment: .leading) {
                if store.searchText.isEmpty {
                    Text("搜索名称、场景、图内文字")
                        .font(.system(size: 11))
                        .foregroundStyle(placeholder)
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(primaryText)
                    .focused($isSearchFieldFocused)
                    .onSubmit { isSearchFieldFocused = false }
                    .onExitCommand {
                        if store.searchText.isEmpty {
                            isSearchFieldFocused = false
                        } else {
                            store.searchText = ""
                        }
                    }
            }

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(faint)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }

            searchScopeMenu {
                Text(store.searchScope.shortTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06),
                                in: Capsule(style: .continuous))
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 224, height: 26)
        .background {
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: dark
                                     ? [Color(white: 0.14), Color(white: 0.075)]
                                     : [Color(white: 0.995), Color(white: 0.945)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [.black.opacity(dark ? 0.30 : 0.05), .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(isSearchFieldFocused
                              ? accent.opacity(0.70)
                              : (dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)),
                              lineWidth: isSearchFieldFocused ? 1 : 0.7)
        }
        .shadow(color: isSearchFieldFocused ? accent.opacity(0.18) : .clear, radius: 6)
        .contentShape(Capsule())
        .help("搜索影片：名称、场景、图内文字（⌘F，Esc 清除）")
        .accessibilityLabel("搜索影片")
    }

    @ViewBuilder
    var healthToolbarActions: some View {
        if store.isScanningHealth {
            Button {
                store.cancelHealthScan()
            } label: {
                GalleryToolbarIconLabel(systemName: "stop.circle")
            }
            .buttonStyle(.plain)
            .help("停止本次体检")
        } else {
            Button {
                store.showBeautyPanel = true
            } label: {
                GalleryToolbarIconLabel(systemName: "wand.and.stars")
            }
            .buttonStyle(.plain)
            .disabled(!store.canScanBeauty)
            .help("按画面偏差推荐可批量美化的照片")

            Button {
                store.scanLibraryHealth()
            } label: {
                GalleryToolbarIconLabel(systemName: "stethoscope")
            }
            .buttonStyle(.plain)
            .disabled(!store.canScanHealth || store.isFinalizingHealth)
            .help("扫描当前图库的照片质量与重复内容")
        }
    }
}
