import SwiftUI
import AppKit
import Foundation
import LumaContentCore

/// 网盘影院、续播与网盘管理页。

// MARK: - 影院页

/// 影院页：把所有网盘的刮削结果汇成一面真实海报墙。
/// 先看「最近刮削」与「接着看」，再按电影 / 剧集浏览；点海报直接开播，底部保留每个存储的刮削入口。
struct CloudStoragesCinemaView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    /// 控制台状态：与图2 一致的「来源 → 分段 → 姿态 → 筛选 / 排序」结构。
    @State private var selectedMountID: UUID?
    @State private var tab: CinemaTab = .all
    @State private var viewMode: CinemaViewMode = .shelf
    @State private var filter: CinemaWallFilter = .all
    @State private var sortOrder: CinemaWallSort = .recent
    @State private var query = ""
    /// 聚合页里的详情：与本地 / 网盘影院同一套内联详情页，点海报先进详情再播放。
    @State private var detailTarget: CinemaDetailTarget?

    var body: some View {
        let wall = buildWall()
        let items = filteredItems(wall)

        return ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    console(wall)

                    if cloud.mounts.isEmpty {
                        LumaEmptyState(symbol: "film.stack",
                                       title: "还没有存储影院",
                                       message: "接入网络存储并打开影院后，视频会被识别成电影与剧集，汇总到这里。",
                                       style: .card,
                                       actions: [LumaEmptyAction(title: "接入存储",
                                                                 symbol: "plus") {
                                           store.presentCloudWizard()
                                       }])
                    } else {
                        if viewMode == .shelf {
                            shelfContent(wall, items: items)
                        } else if items.isEmpty {
                            noMatchState
                        } else {
                            wallTitle(items)
                            switch viewMode {
                            case .wall:
                                posterWall(items)
                            case .card:
                                wideCardWall(items)
                            case .list:
                                itemList(items)
                            case .shelf:
                                EmptyView()
                            }
                        }

                        if viewMode == .shelf {
                            mountSection(filteredMounts(wall))
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let target = detailTarget {
                inlineDetail(target)
                    .overlay(alignment: .topLeading) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil }
                            store.cinemaDetailOpen = false
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .bold))
                                Text("返回聚合影院")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                            }
                            .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .padding(18)
                        .help("返回聚合影院 (Esc)")
                    }
                    .onDisappear { store.cinemaDetailOpen = false }
            }
        }
    }

    /// 内联详情：复用本地影院的详情组件，返回后仍停在聚合页原来的位置。
    @ViewBuilder
    private func inlineDetail(_ target: CinemaDetailTarget) -> some View {
        switch target {
        case .series(let series):
            CinemaSeriesDetailView(
                series: series,
                onPlay: { entry in store.openCinema(entry) },
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environmentObject(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        case .entry(let entry):
            CinemaDetailView(
                entry: entry,
                onOpenEntry: { next in
                    withAnimation(.easeOut(duration: 0.2)) { detailTarget = .entry(next) }
                },
                onClose: { withAnimation(.easeOut(duration: 0.2)) { detailTarget = nil } }
            )
            .environmentObject(store)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        default:
            EmptyView()
        }
    }

    // MARK: - 控制台

    private func console(_ wall: CloudCinemaWall) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    mountMenu(wall)
                    Divider().frame(height: 22)
                    categoryTabs
                    Divider().frame(height: 22)
                    viewModeTabs
                    Divider().frame(height: 22)
                    filterMenu
                    sortMenu
                    searchField
                    Spacer(minLength: 4)
                    scrapeMenu
                    moreMenu(wall)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .scrollClipDisabled()

            Divider().opacity(0.45).padding(.horizontal, 12)

            compactStats(wall)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.07),
                                              Color.primary.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.14),
                                                      .clear,
                                                      .black.opacity(0.12)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    /// 读数整合进同一条控制台：切换来源 / 分段时，下面的数字同步变。
    private func compactStats(_ wall: CloudCinemaWall) -> some View {
        let stats = statsScope(wall)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                statCell("已识别", "\(stats.matched)", "部",
                         symbol: "checkmark.seal.fill", tint: LumaBrand.mint)
                cellDivider
                statCell("电影", "\(stats.movies)", "部",
                         symbol: "film.fill", tint: LumaBrand.violet)
                cellDivider
                statCell("剧集", "\(stats.series)", "部",
                         symbol: "tv.fill", tint: LumaBrand.cyan)
                cellDivider
                statCell("待识别", "\(stats.unmatched)", "项",
                         symbol: "questionmark.circle.fill", tint: LumaBrand.amber)
                cellDivider
                statCell("续看", "\(stats.continueCount)", "条",
                         symbol: "play.circle.fill", tint: LumaBrand.coral)
                Spacer(minLength: 0)
            }
        }
        .scrollClipDisabled()
    }

    private func statCell(_ title: String, _ value: String, _ unit: String,
                          symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.6, height: 13)
    }

    private func statsScope(_ wall: CloudCinemaWall) -> (matched: Int, movies: Int, series: Int,
                                                         unmatched: Int, continueCount: Int) {
        if let id = selectedMountID,
           let item = wall.mounts.first(where: { $0.mount.id == id }) {
            return (item.summary.matched,
                    item.summary.movies,
                    item.summary.shows,
                    item.summary.unmatched,
                    wall.continueRecords.filter { $0.mountID == id }.count)
        }
        return (wall.movies.count + wall.series.count,
                wall.movies.count,
                wall.series.count,
                wall.unmatched,
                wall.continueRecords.count)
    }

    private func mountMenu(_ wall: CloudCinemaWall) -> some View {
        Menu {
            Button {
                selectedMountID = nil
            } label: {
                Label("全部存储", systemImage: selectedMountID == nil ? "checkmark" : "externaldrive.connected.to.line.below")
            }
            Divider()
            ForEach(wall.mounts) { item in
                Button {
                    selectedMountID = item.mount.id
                } label: {
                    Label("\(item.mount.name) · \(item.summary.matched) 已识别",
                          systemImage: selectedMountID == item.mount.id ? "checkmark" : "externaldrive")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LumaBrand.violet)
                VStack(alignment: .leading, spacing: 0) {
                    Text("影院")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(selectedMountName(wall))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text("\(matchedCount(wall)) 已识别")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择影院来源")
    }

    private var categoryTabs: some View {
        HStack(spacing: 2) {
            ForEach([CinemaTab.all, .movies, .shows]) { item in
                let active = tab == item
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { tab = item }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background {
                        if active {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button {
                browseFolders()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                    Text("文件夹")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("到存储里按文件夹浏览")
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var viewModeTabs: some View {
        HStack(spacing: 2) {
            ForEach(CinemaViewMode.allCases) { mode in
                let active = viewMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { viewMode = mode }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var filterMenu: some View {
        Menu {
            ForEach(CinemaWallFilter.allCases) { option in
                Button {
                    filter = option
                } label: {
                    Label(option.title, systemImage: filter == option ? "checkmark" : option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(filter == .all ? "筛选" : filter.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(filter == .all ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CinemaWallSort.allCases) { option in
                Button {
                    sortOrder = option
                } label: {
                    Label(option.title, systemImage: sortOrder == option ? "checkmark" : option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(sortOrder.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索片名 / 存储", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    store.startModuleSearch(.cinema, query: query)
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 176, height: 26)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private var scrapeMenu: some View {
        Menu {
            if let id = selectedMountID, let mount = cloud.mounts.first(where: { $0.id == id }) {
                Button("刮削「\(mount.name)」") { store.startCinemaScrape(for: .mount(id)) }
                Button("强制重新刮削「\(mount.name)」") {
                    store.startCinemaScrape(for: .mount(id), force: true)
                }
            } else {
                ForEach(cloud.mounts) { mount in
                    Button("刮削「\(mount.name)」") {
                        store.startCinemaScrape(for: .mount(mount.id))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if store.cinemaScrapeRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(store.cinemaScrapeRunning
                     ? "\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)"
                     : "刮削")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(LumaBrand.amber.opacity(0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 0.7)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.cinemaScrapeRunning)
        .help("识别电影与剧集")
    }

    private func moreMenu(_ wall: CloudCinemaWall) -> some View {
        Menu {
            if let id = selectedMountID {
                Button("进入「\(selectedMountName(wall))」影院") { enterCinema(mountID: id) }
                Button("在存储中打开") { browseFolders() }
                Divider()
                Button("回到全部存储") { selectedMountID = nil }
            } else {
                Button("按文件夹浏览存储") {
                    cloud.setStoragesTab(.storages)
                }
            }
            Button("网络存储管理") { cloud.setStoragesTab(.storages) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 聚合内容

    /// 书架：最近刮削 + 接着看 + 电影 / 剧集两组海报。
    @ViewBuilder
    private func shelfContent(_ wall: CloudCinemaWall, items: [CloudCinemaWallItem]) -> some View {
        let spotlight = items.filter { $0.backdropURL != nil }.max { $0.date < $1.date } ?? items.first
        if let spotlight {
            spotlightCard(spotlight)
        }

        let records = filteredContinue(wall)
        if !records.isEmpty {
            continueShelf(records)
        }

        if items.isEmpty {
            if wall.movies.isEmpty && wall.series.isEmpty {
                scrapeHint
            } else {
                noMatchState
            }
        } else {
            let movies = items.filter { $0.series == nil }
            let series = items.filter { $0.series != nil }
            if !movies.isEmpty {
                posterSection(title: "电影", symbol: "film.fill",
                              tint: LumaBrand.violet, items: movies)
            }
            if !series.isEmpty {
                posterSection(title: "剧集", symbol: "tv.fill",
                              tint: LumaBrand.cyan, items: series)
            }
        }
    }

    private func wallTitle(_ items: [CloudCinemaWallItem]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "film.stack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LumaBrand.violet)
            Text(tab == .movies ? "电影" : (tab == .shows ? "剧集" : "全部影片"))
                .font(.system(size: 14, weight: .semibold))
            Text("\(items.count) 部")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// 海报墙：只留竖版海报，密度交给自适应列宽。
    private func posterWall(_ items: [CloudCinemaWallItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106, maximum: 132), spacing: 14)],
                  alignment: .leading,
                  spacing: 16) {
            ForEach(items) { item in
                CloudCinemaPosterCard(item: item) { openDetail(item) }
                    .contextMenu {
                        Button("查看详情") { openDetail(item) }
                        Button("播放") { open(item) }
                        Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
                    }
            }
        }
    }

    /// 卡片：16:9 横版，适合快速扫一眼剧情封面。
    private func wideCardWall(_ items: [CloudCinemaWallItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)],
                  alignment: .leading,
                  spacing: 14) {
            ForEach(items) { item in
                wideCard(item)
            }
        }
    }

    private func wideCard(_ item: CloudCinemaWallItem) -> some View {
        Button { openDetail(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                CloudHubArtwork(urlString: item.artworkURL, cornerRadius: 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 136)
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 7.5, weight: .semibold))
                            Text(item.mountName)
                                .font(.system(size: 8.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.35), in: Capsule(style: .continuous))
                        .padding(8)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(item.detail)
                        Text(CloudHubFormat.relative(item.date))
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看「\(item.title)」详情")
        .contextMenu {
            Button("查看详情") { openDetail(item) }
            Button("播放") { open(item) }
            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
        }
    }

    /// 列表：一行一部，扫描时信息最密。
    private func itemList(_ items: [CloudCinemaWallItem]) -> some View {
        CloudHubPanel(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                itemRow(items[index])
                if index < items.count - 1 {
                    Divider().opacity(0.35).padding(.leading, 64)
                }
            }
        }
    }

    private func itemRow(_ item: CloudCinemaWallItem) -> some View {
        Button { openDetail(item) } label: {
            HStack(spacing: 11) {
                CloudHubArtwork(urlString: item.artworkURL, cornerRadius: 6)
                    .frame(width: 56, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(item.detail) · \(item.mountName)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(CloudHubFormat.relative(item.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LumaBrand.amber.opacity(0.92)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看「\(item.title)」详情")
    }

    private var noMatchState: some View {
        LumaEmptyState(symbol: "line.3.horizontal.decrease.circle",
                       title: "没有匹配的影片",
                       message: "换一个存储、分段或关键词试试。")
    }

    // MARK: - 控制台数据

    private func filteredItems(_ wall: CloudCinemaWall) -> [CloudCinemaWallItem] {
        var result: [CloudCinemaWallItem]
        switch tab {
        case .movies: result = wall.movies
        case .shows: result = wall.series
        default: result = wall.movies + wall.series
        }
        if let id = selectedMountID {
            result = result.filter { $0.mountID == id }
        }
        switch filter {
        case .all:
            break
        case .artwork:
            result = result.filter { $0.artworkURL != nil }
        case .recent:
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            result = result.filter { $0.date > cutoff }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.mountName.localizedCaseInsensitiveContains(keyword)
            }
        }
        switch sortOrder {
        case .recent: result.sort { $0.date > $1.date }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year: result.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        return result
    }

    private func filteredContinue(_ wall: CloudCinemaWall) -> [CinemaProgressRecord] {
        guard let id = selectedMountID else { return wall.continueRecords }
        return wall.continueRecords.filter { $0.mountID == id }
    }

    private func filteredMounts(_ wall: CloudCinemaWall) -> [CloudMountCinemaItem] {
        guard let id = selectedMountID else { return wall.mounts }
        return wall.mounts.filter { $0.mount.id == id }
    }

    private func selectedMountName(_ wall: CloudCinemaWall) -> String {
        guard let id = selectedMountID,
              let item = wall.mounts.first(where: { $0.mount.id == id }) else { return "全部存储" }
        return item.mount.name
    }

    private func matchedCount(_ wall: CloudCinemaWall) -> Int {
        if let id = selectedMountID {
            return wall.mounts.first { $0.mount.id == id }?.summary.matched ?? 0
        }
        return wall.movies.count + wall.series.count
    }

    /// 「文件夹」分段：回到存储本身按目录浏览。
    private func browseFolders() {
        if let id = selectedMountID {
            store.navigate(to: .cloudMount(id))
        } else {
            cloud.setStoragesTab(.storages)
        }
    }

    // MARK: 最近刮削

    func spotlightCard(_ item: CloudCinemaWallItem) -> some View {
        Button { openDetail(item) } label: {
            ZStack(alignment: .bottomLeading) {
                CloudHubArtwork(urlString: item.backdropURL ?? item.artworkURL, cornerRadius: 20)
                    .frame(maxWidth: .infinity)
                    .frame(height: 232)

                LinearGradient(colors: [.black.opacity(0.02),
                                        .black.opacity(0.34),
                                        .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("最近刮削")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(.white.opacity(0.18), in: Capsule(style: .continuous))
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text(item.mountName)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.78))
                    }
                    Text(item.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("查看详情")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 13)
                        .frame(height: 27)
                        .background(.white.opacity(0.95), in: Capsule(style: .continuous))

                        Text("刮削于 \(CloudHubFormat.relative(item.date))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .padding(.top, 2)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 232)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .help("查看「\(item.title)」详情")
        .contextMenu {
            Button("查看详情") { openDetail(item) }
            Button("播放") { open(item) }
            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
        }
    }

    // MARK: 接着看

    func continueShelf(_ records: [CinemaProgressRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("接着看", count: records.count, unit: "条",
                         symbol: "play.circle.fill", tint: LumaBrand.coral)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(records.prefix(12))) { record in
                        CloudCinemaContinueCard(record: record,
                                                mountName: mountName(for: record)) {
                            resume(record)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 海报墙

    func posterSection(title: String,
                               symbol: String,
                               tint: Color,
                               items: [CloudCinemaWallItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, count: items.count, unit: "部", symbol: symbol, tint: tint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 106, maximum: 132), spacing: 14)],
                      alignment: .leading,
                      spacing: 16) {
                ForEach(items) { item in
                    CloudCinemaPosterCard(item: item) { openDetail(item) }
                        .contextMenu {
                            Button("查看详情") { openDetail(item) }
                            Button("播放") { open(item) }
                            Button("进入「\(item.mountName)」影院") { enterCinema(mountID: item.mountID) }
                        }
                }
            }
        }
    }

    var scrapeHint: some View {
        CloudHubPanel {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LumaBrand.amber.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有刮削出海报")
                        .font(.system(size: 12, weight: .semibold))
                    Text("在下面的存储行里点「刮削」，识别出的电影与剧集会出现在这面墙上。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
        }
    }

    // MARK: 按存储

    func mountSection(_ items: [CloudMountCinemaItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("按存储", count: items.count, unit: "个",
                         symbol: "externaldrive.fill", tint: LumaBrand.amber)
            CloudHubPanel(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    mountRow(items[index])
                    if index < items.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 56)
                    }
                }
            }
        }
    }

    func mountRow(_ item: CloudMountCinemaItem) -> some View {
        let scope = CinemaScope.mount(item.mount.id)
        let scraping = store.cinemaScrapeRunning && store.cinemaScrapeScope == scope
        let tint = item.mount.kind.hubTint
        let continueCount = store.cinemaContinueRecords(for: scope).count
        let connection = connectionSummary(item.mount)
        let scanText = scanSummary(item.mount)

        return HStack(spacing: 12) {
            CloudMountBadge(mount: item.mount, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.mount.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    CloudHubTag(text: item.summary.matched > 0 ? "已识别 \(item.summary.matched)" : "未刮削",
                                tint: item.summary.matched > 0 ? LumaBrand.mint : Color.secondary)
                }
                HStack(spacing: 10) {
                    Text("电影 \(item.summary.movies)")
                    Text("剧集 \(item.summary.shows)")
                    Text("续看 \(continueCount)")
                    if let scraped = item.summary.lastScrapedAt {
                        Text("刮削于 \(CloudHubFormat.relative(scraped))")
                    }
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                // 每个源都有一行汇总：连接状态 + 上次扫描时间，不用点进详情。
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connection.tint)
                            .frame(width: 5, height: 5)
                        Text(connection.text)
                    }
                    Text("上次扫描 \(scanText)")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            if scraping {
                ProgressView().controlSize(.mini)
                Text("\(store.cinemaScrapeDone)/\(store.cinemaScrapeTotal)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            CloudHubCapsuleButton(title: "刮削", symbol: "wand.and.stars", tint: tint) {
                store.startCinemaScrape(for: scope)
            }
            CloudHubCapsuleButton(title: "进入影院", symbol: "arrow.up.right",
                                  tint: tint, prominent: true) {
                enterCinema(mountID: item.mount.id)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 最近一次连接检测的结果：没有检测记录时标「未检测」。
    func connectionSummary(_ mount: CloudMount) -> (text: String, tint: Color) {
        let job = store.recentSourceJobs(kind: .connectivity).first {
            $0.sourceID.uuidValue == mount.id
        }
        guard let job else { return ("未检测", .secondary) }
        if job.phase == .finished {
            return ("在线 · \(CloudHubFormat.relative(job.updatedAt))", LumaBrand.mint)
        }
        return ("离线 · \(CloudHubFormat.relative(job.updatedAt))", LumaBrand.coral)
    }

    /// 上次完整扫描时间：深度扫描时间优先，其次刮削时间，都没有就提示未扫描。
    func scanSummary(_ mount: CloudMount) -> String {
        if let date = store.cloudDeepScanDate(mount.id) {
            return CloudHubFormat.relative(date)
        }
        if let states = store.cloudIndexStates()[mount.id] {
            return CloudHubFormat.relative(states.updatedAt)
        }
        return "未扫描"
    }

    func sectionTitle(_ title: String,
                              count: Int,
                              unit: String,
                              symbol: String,
                              tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text("\(count) \(unit)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据

    func buildWall() -> CloudCinemaWall {
        var wall = CloudCinemaWall()
        wall.continueRecords = store.cloudMountContinueRecords

        for mount in cloud.mounts {
            let entries = Array(store.cinemaEntries(for: .mount(mount.id)).values)
            let summary = CloudCinemaSummary(entries: entries)
            wall.mounts.append(CloudMountCinemaItem(mount: mount, summary: summary))
            wall.unmatched += summary.unmatched

            for entry in entries where entry.matched && entry.kind == .movie {
                wall.movies.append(CloudCinemaWallItem(
                    id: "movie-\(mount.id)-\(entry.id)",
                    mountID: mount.id,
                    mountName: mount.name,
                    title: entry.title,
                    detail: movieDetail(entry),
                    artworkURL: entry.posterURL ?? entry.backdropURL,
                    backdropURL: entry.backdropURL,
                    date: entry.scrapedAt,
                    entry: entry,
                    series: nil))
            }

            for series in store.cinemaSeries(for: .mount(mount.id)) {
                wall.series.append(CloudCinemaWallItem(
                    id: "series-\(mount.id)-\(series.id)",
                    mountID: mount.id,
                    mountName: mount.name,
                    title: series.title,
                    detail: series.subtitle,
                    artworkURL: series.posterURL ?? series.backdropURL,
                    backdropURL: series.backdropURL,
                    date: series.latestEpisode?.scrapedAt ?? .distantPast,
                    entry: nil,
                    series: series))
            }
        }

        wall.movies.sort { $0.date > $1.date }
        wall.series.sort { $0.date > $1.date }

        let all = wall.movies + wall.series
        wall.spotlight = all.filter { $0.backdropURL != nil }.max { $0.date < $1.date }
            ?? all.max { $0.date < $1.date }
        return wall
    }

    func movieDetail(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        parts.append("电影")
        if let runtime = entry.runtime, runtime > 0 { parts.append("\(runtime) 分钟") }
        return parts.joined(separator: " · ")
    }

    /// 点海报 / 卡片：先进入该条目所属存储的影院作用域，再打开同一套内联详情。
    func openDetail(_ item: CloudCinemaWallItem) {
        store.activateCinemaScope(.mount(item.mountID))
        store.cinemaDetailOpen = true
        withAnimation(.easeOut(duration: 0.2)) {
            if let series = item.series {
                detailTarget = .series(series)
            } else if let entry = item.entry {
                detailTarget = .entry(entry)
            }
        }
    }

    func open(_ item: CloudCinemaWallItem) {
        store.activateCinemaScope(.mount(item.mountID))
        if let entry = item.entry {
            store.openCinema(entry)
            return
        }
        guard let series = item.series else { return }
        // 有进度就看那一集，否则从第一集开始。
        let watched = Set(store.cloudMountContinueRecords.map(\.photoID))
        if let resume = series.episodes.first(where: { watched.contains($0.file.photoID) }) {
            store.openCinema(resume)
        } else if let first = series.episodes.first {
            store.openCinema(first)
        }
    }

    func resume(_ record: CinemaProgressRecord) {
        guard let mountID = record.mountID else { return }
        store.activateCinemaScope(.mount(mountID))
        if let entry = store.cinemaIndexes[.mount(mountID)]?[record.photoID] {
            store.openCinema(entry)
        } else {
            store.navigate(to: .cloudCinema(mountID))
        }
    }

    func enterCinema(mountID: UUID) {
        store.activateCinemaScope(.mount(mountID))
        store.navigate(to: .cloudCinema(mountID))
    }

    func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return cloud.mounts.first { $0.id == mountID }?.name ?? "网络存储"
    }
}

/// 海报墙的一次性聚合结果：按挂载遍历一遍，视图只读结果。
struct CloudCinemaWall {
    var mounts: [CloudMountCinemaItem] = []
    var movies: [CloudCinemaWallItem] = []
    var series: [CloudCinemaWallItem] = []
    var spotlight: CloudCinemaWallItem?
    var continueRecords: [CinemaProgressRecord] = []
    var unmatched = 0
}

/// 海报墙的一张条目：电影取单条刮削结果，剧集取合并后的整部剧。
struct CloudCinemaWallItem: Identifiable {
    let id: String
    let mountID: UUID
    let mountName: String
    let title: String
    let detail: String
    let artworkURL: String?
    let backdropURL: String?
    let date: Date
    let entry: CinemaEntry?
    let series: CinemaSeries?

    /// 年份：电影取单条，剧集取整部剧。
    var year: Int? { entry?.year ?? series?.year }
}

/// 影院聚合页的筛选：全部 / 有海报 / 最近 30 天。
private enum CinemaWallFilter: String, CaseIterable, Identifiable {
    case all, artwork, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .artwork: return "有海报"
        case .recent: return "最近 30 天"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .artwork: return "photo"
        case .recent: return "calendar"
        }
    }
}

/// 影院聚合页的排序：最近刮削 / 片名 / 年份。
private enum CinemaWallSort: String, CaseIterable, Identifiable {
    case recent, title, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "最近"
        case .title: return "片名"
        case .year: return "年份"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .title: return "textformat"
        case .year: return "calendar"
        }
    }
}

/// 海报墙卡片：竖版海报 + 标题 + 副标题，悬停出播放按钮。
struct CloudCinemaPosterCard: View {
    let item: CloudCinemaWallItem
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CloudHubArtwork(urlString: item.artworkURL, cornerRadius: 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)

                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.55)],
                               startPoint: .center,
                               endPoint: .bottom)

                HStack(spacing: 4) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                    Text(item.mountName)
                        .font(.system(size: 8.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.35), in: Capsule(style: .continuous))
                .padding(8)

                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.95)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? LumaBrand.amber.opacity(0.80)
                                          : Color.white.opacity(0.10),
                                  lineWidth: 1)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)

            Text(item.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Text(item.detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("查看「\(item.title)」详情")
    }
}

/// 接着看卡片：横版剧照 + 进度条，悬停出播放按钮。
struct CloudCinemaContinueCard: View {
    let record: CinemaProgressRecord
    let mountName: String
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 10)
                .frame(width: 208, height: 117)

            LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.74)],
                           startPoint: .top,
                           endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(mountName) · \(CloudHubFormat.remaining(record.remainingSeconds))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(10)

            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.96)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: 208, height: 117)
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.26))
                    Capsule()
                        .fill(LumaBrand.coral)
                        .frame(width: max(3, proxy.size.width * min(1, max(0, record.fraction))))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? LumaBrand.coral.opacity(0.85)
                                      : Color.white.opacity(0.10),
                              lineWidth: 1)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("继续播放 \(record.title)")
    }
}

/// 影院卡片的一行数据：挂载 + 汇总。
struct CloudMountCinemaItem: Identifiable {
    let mount: CloudMount
    let summary: CloudCinemaSummary

    var id: UUID { mount.id }
}

/// 单个网盘影院的轻量汇总：只遍历一次条目，避免卡片里反复过滤。
struct CloudCinemaSummary {
    var total = 0
    var matched = 0
    var movies = 0
    var shows = 0
    var unmatched = 0
    var lastScrapedAt: Date?

    init(entries: [CinemaEntry]) {
        total = entries.count
        let matchedEntries = entries.filter(\.matched)
        matched = matchedEntries.count
        unmatched = entries.count - matched
        movies = matchedEntries.filter { $0.kind == .movie }.count
        shows = matchedEntries.filter { $0.kind == .tv }.count
        lastScrapedAt = entries.map(\.scrapedAt).max()
    }
}

// MARK: - 续播页

/// 续播页：跨存储汇总未看完的视频，按最近观看排序；底部保留刚看完的记录。
struct CloudStoragesResumeView: View {
    @EnvironmentObject private var store: LibraryStore

    var continueRecords: [CinemaProgressRecord] { store.cloudMountContinueRecords }
    var finishedRecords: [CinemaProgressRecord] { Array(store.cloudMountFinishedRecords.prefix(6)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if continueRecords.isEmpty {
                    LumaEmptyState(symbol: "play.circle",
                                   title: "还没有未看完的视频",
                                   message: "在任意网盘的影院里播放视频后，进度会出现在这里，可以直接接着看。",
                                   style: .card)
                } else {
                    CloudHubPanel(spacing: 0) {
                        ForEach(continueRecords.indices, id: \.self) { index in
                            resumeRow(continueRecords[index])
                            if index < continueRecords.count - 1 {
                                Divider().opacity(0.35).padding(.leading, 142)
                            }
                        }
                    }
                }

                if !finishedRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LumaBrand.mint)
                            Text("最近看完")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(store.cloudMountFinishedRecords.count) 条")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        CloudHubPanel(spacing: 0) {
                            ForEach(finishedRecords.indices, id: \.self) { index in
                                finishedRow(finishedRecords[index])
                                if index < finishedRecords.count - 1 {
                                    Divider().opacity(0.35).padding(.leading, 112)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func resumeRow(_ record: CinemaProgressRecord) -> some View {
        let mountName = mountName(for: record)
        return HStack(alignment: .center, spacing: 16) {
            // 刮削封面优先取横版剧照（backdrop），按 16:10 裁切才不会把人像挤没。
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 9)
                .frame(width: 108, height: 66)

            VStack(alignment: .leading, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.quaternary)
                    }
                    Text(mountName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                CloudHubProgressBar(fraction: record.fraction, tint: LumaBrand.coral)
                    .frame(maxWidth: 360)
                HStack(spacing: 7) {
                    Text(CloudHubFormat.remaining(record.remainingSeconds))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(Int((record.fraction * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumaBrand.coral)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text(CloudHubFormat.relative(record.updatedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 16)

            CloudHubCapsuleButton(title: "继续观看", symbol: "play.fill",
                                  tint: LumaBrand.coral, prominent: true) {
                resume(record)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { resume(record) }
        .contextMenu {
            Button("继续观看") { resume(record) }
            if let mountID = record.mountID {
                Button("打开这个存储的影院") {
                    store.activateCinemaScope(.mount(mountID))
                    store.navigate(to: .cloudCinema(mountID))
                }
            }
        }
    }

    func finishedRow(_ record: CinemaProgressRecord) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CloudHubArtwork(urlString: record.artworkURL, cornerRadius: 7)
                .frame(width: 80, height: 50)
                .opacity(0.72)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(mountName(for: record))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text("看完于 \(CloudHubFormat.relative(record.updatedAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 16)
            CloudHubTag(text: "已看完", tint: LumaBrand.mint)
            CloudHubCapsuleButton(title: "重看", symbol: "arrow.counterclockwise",
                                  tint: LumaBrand.mint) {
                resume(record)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    func mountName(for record: CinemaProgressRecord) -> String {
        guard let mountID = record.mountID else { return "本地图库" }
        return store.cloudMounts.first { $0.id == mountID }?.name ?? "网络存储"
    }

    func resume(_ record: CinemaProgressRecord) {
        guard let mountID = record.mountID else { return }
        store.activateCinemaScope(.mount(mountID))
        if let entry = store.cinemaIndexes[.mount(mountID)]?[record.photoID] {
            store.openCinema(entry)
        } else {
            // 刮削索引被清掉时仍能回到该网盘影院，续播记录不会丢。
            store.navigate(to: .cloudCinema(mountID))
        }
    }
}

// MARK: - 网盘管理

/// 网盘管理：接入、鉴权、索引、接入范围、扫描动作与跨源总览集中在一页。
/// 原来「存储 / 总览 / 管理」三个分页看的是同一批存储，这里按存储逐条核对，
/// 卡片既能看到连接与索引状态，也能直接打开、重扫、改范围、换凭据或断开。
struct CloudStoragesManageView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @State private var indexStates: [UUID: MetadataStore.CloudIndexState] = [:]
    @State private var renamingMount: CloudMount?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if cloud.mounts.isEmpty {
                    LumaEmptyState(symbol: "wrench.and.screwdriver",
                                   title: "还没有需要管理的存储",
                                   message: "接入存储后，这里会列出每个连接的鉴权方式、读写权限、索引体量与新鲜度。",
                                   style: .card,
                                   actions: [LumaEmptyAction(title: "接入存储",
                                                             symbol: "plus") {
                                       store.presentCloudWizard()
                                   }])
                } else {
                    headerActions
                    safetyNote
                    VStack(spacing: 12) {
                        ForEach(cloud.mounts) { mount in
                            maintenanceCard(mount)
                        }
                    }
                    overviewSection
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: cloud.mounts.count) {
            indexStates = store.cloudIndexStates()
            autoCheckMounts()
        }
        .alert("重命名网络存储", isPresented: renamePresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renamingMount = nil }
            Button("保存") {
                if let mount = renamingMount {
                    store.renameCloudMount(mount.id, to: renameText)
                }
                renamingMount = nil
            }
        } message: {
            Text("只修改显示名称，不会影响网盘上的内容。")
        }
    }

    /// 页头动作：原来在标题右侧，标题删掉后收进管理读数面板的顶行，贴着说明走。
    var headerActions: some View {
        HStack(spacing: 8) {
            Text("接入、鉴权、索引与接入范围 · 只改本机配置，不写回网盘")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                checkAllMounts()
            } label: {
                HStack(spacing: 4) {
                    if isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(isChecking ? "检测中" : "检测状态")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(cloud.mounts.isEmpty || isChecking)
            .help("逐个拉取存储的根目录，确认凭据与网络是否正常")
            Button {
                store.presentCloudWizard()
            } label: {
                Label("接入存储", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("通过向导接入 WebDAV、SMB 共享或网盘")
        }
    }

    /// 与存储卡片同页的跨源总览：不再单独占一个分页。
    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 4)
            CloudStoragesSnapshotPanels()
        }
    }

    var renamePresented: Binding<Bool> {
        Binding(get: { renamingMount != nil },
                set: { if !$0 { renamingMount = nil } })
    }

    /// 还有存储正在检测：页头按钮与每张卡的状态徽章共用同一份状态。
    var isChecking: Bool {
        cloud.mountHealth.values.contains { $0.state == .checking }
    }

    func checkAllMounts() {
        for mount in cloud.mounts {
            probe(mount)
        }
    }

    /// 进入页面时只补测「没测过 / 超过 5 分钟 / 上次失败」的存储。
    func autoCheckMounts() {
        let now = Date()
        for mount in cloud.mounts {
            guard let health = cloud.mountHealth[mount.id] else {
                probe(mount)
                continue
            }
            if health.state == .checking || health.state == .healthy,
               let checkedAt = health.checkedAt,
               now.timeIntervalSince(checkedAt) < 300 {
                continue
            }
            probe(mount)
        }
    }

    /// 检测单个存储：登记到统一任务中心，只拉一次根目录，不改当前浏览目录或索引。
    func probe(_ mount: CloudMount) {
        guard cloud.mountHealth[mount.id]?.state != .checking else { return }
        Task { @MainActor in
            _ = await store.runCloudHealthCheck(mount)
        }
    }

    /// 连通性徽章：与资源页的「在线 / 需验证 / 离线」语义保持一致。
    func healthBadge(_ mount: CloudMount) -> some View {
        let health = cloud.mountHealth[mount.id]
        let state = health?.state ?? .unknown
        let tint: Color
        let text: String
        var showsSpinner = false
        switch state {
        case .checking:
            tint = .secondary
            text = "检测中"
            showsSpinner = true
        case .healthy:
            tint = .green
            text = "在线"
        case .authRequired:
            tint = .orange
            text = "需验证"
        case .offline:
            tint = .red
            text = "离线"
        case .degraded:
            tint = .orange
            text = "受限"
        case .unknown:
            tint = .secondary
            text = "已接入"
        }
        return HStack(spacing: 4) {
            if showsSpinner {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        }
        .help(healthHelp(health))
    }

    func healthHelp(_ health: SourceHealth?) -> String {
        guard let health, health.state != .checking else { return "正在检测连接…" }
        var parts: [String] = []
        if health.state == .healthy {
            parts.append("连通正常")
            if let ms = health.latencyMilliseconds { parts.append("\(ms) ms") }
        } else if health.checkedAt != nil {
            parts.append("检测未通过")
        }
        if let message = health.message, !message.isEmpty { parts.append(message) }
        return parts.isEmpty ? "点击「检测」确认连接" : parts.joined(separator: " · ")
    }

    var safetyNote: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LumaBrand.mint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaBrand.mint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("只读优先，派生数据留在本机")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("除 WebDAV 外均为只读；收藏、关键词、评分、续播与索引都存在当前图库，不会写回网盘。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
        }
        .padding(14)
        .lumaGlassCard(cornerRadius: 16, shadow: false)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LumaBrand.mint.opacity(0.18), lineWidth: 0.7)
        }
    }

    func maintenanceCard(_ mount: CloudMount) -> some View {
        let state = indexStates[mount.id]
        let tint = mount.kind.hubTint

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CloudMountBadge(mount: mount, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mount.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text(address(for: mount))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                healthBadge(mount)
                CloudHubTag(text: mount.kind.supportsWrite ? "可写" : "只读",
                            tint: mount.kind.supportsWrite ? LumaBrand.mint : LumaBrand.violet)
                CloudHubTag(text: mount.kind.title, tint: tint)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                      alignment: .leading,
                      spacing: 8) {
                infoCell("鉴权方式", authText(for: mount))
                infoCell("接入范围", scopeText(for: mount))
                infoCell("权限", mount.kind.supportsWrite ? "可写入 WebDAV" : "只读浏览")
                infoCell("索引", indexText(state))
                infoCell("接入时间", DateText.monthFormatter.string(from: mount.createdAt))
            }

            if let deep = store.cloudDeepScanDate(mount.id) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .medium))
                    Text("上次深度扫描 \(CloudHubFormat.relative(deep))")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                CloudHubCapsuleButton(title: "打开", symbol: "arrow.up.right", tint: tint) {
                    store.navigate(to: .cloudMount(mount.id))
                }
                CloudHubCapsuleButton(title: "重新扫描", symbol: "arrow.clockwise", tint: tint) {
                    store.navigate(to: .cloudMount(mount.id))
                    store.refreshCloudDirectory()
                }
                CloudHubCapsuleButton(title: "检测", symbol: "waveform.path.ecg", tint: tint) {
                    probe(mount)
                }
                if mount.kind.supportsAccessScope {
                    CloudHubCapsuleButton(title: "接入范围", symbol: "scope", tint: tint) {
                        store.presentCloudWizard(editing: mount)
                    }
                }
                CloudHubCapsuleButton(title: connectionActionTitle(for: mount),
                                      symbol: "key.horizontal", tint: tint) {
                    if mount.kind == .webdav || mount.kind == .smb {
                        store.presentCloudSheet(mount)
                    } else {
                        store.presentCloudWizard(flow: mount.kind.wizardFlow)
                    }
                }
                CloudHubCapsuleButton(title: "重命名", symbol: "pencil", tint: tint) {
                    renameText = mount.name
                    renamingMount = mount
                }
                Spacer(minLength: 4)
                Button {
                    store.confirmRemoveCloudMount(mount.id)
                } label: {
                    Text("断开连接")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LumaBrand.coral)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(LumaBrand.coral.opacity(0.10), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 18)
    }

    func infoCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.quaternary)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func authText(for mount: CloudMount) -> String {
        switch mount.kind {
        case .smb, .webdav: return "账号密码"
        case .quark, .aliyun, .pan115: return "浏览器 Cookie"
        case .baidu: return mount.authMode == .oauth ? "OAuth 令牌" : "浏览器 Cookie"
        }
    }

    func scopeText(for mount: CloudMount) -> String {
        var parts: [String] = []
        if mount.scanAll { parts.append("整个共享") }
        if mount.scopeRoots.isEmpty {
            parts.append("整个网盘")
        } else {
            parts.append("\(mount.scopeRoots.count) 个目录")
        }
        if !mount.excludedRoots.isEmpty {
            parts.append("排除 \(mount.excludedRoots.count)")
        }
        return parts.joined(separator: " · ")
    }

    func indexText(_ state: MetadataStore.CloudIndexState?) -> String {
        guard let state else { return "尚未建立" }
        let base = "\(state.mediaCount.formatted()) 项 · \(state.folderCount.formatted()) 目录"
        return state.complete ? base : base + " · 未完成"
    }

    func address(for mount: CloudMount) -> String {
        let detail = (mount.baseURL.isEmpty ? mount.lastPath : mount.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "点击进入浏览云端目录" : detail
    }

    func connectionActionTitle(for mount: CloudMount) -> String {
        switch mount.kind {
        case .webdav, .smb: return "编辑连接"
        case .quark, .aliyun, .pan115: return "更新 Cookie"
        case .baidu: return "重新授权"
        }
    }
}

// MARK: - 通用组件

/// 页头：与网络资源各分页保持同一套字号与留白。
struct CloudHubPageHeader: View {
    let title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 磨砂面板：统一内边距与圆角，五个分页共用。
struct CloudHubPanel<Content: View>: View {
    var spacing: CGFloat
    var content: Content

    init(spacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaGlassCard(cornerRadius: 20)
    }
}

/// 读数块：图标 + 标题 + 大号读数 + 说明。
struct CloudHubStatPod: View {
    let title: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 0.7)
        }
    }
}

/// 小胶囊标签：状态、类型与数量。
struct CloudHubTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.13), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            }
    }
}

/// 胶囊动作按钮：普通态用淡色底，主操作直接铺强调色。
struct CloudHubCapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .accentColor
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(tint)
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(prominent ? Color.white.opacity(0.20) : tint.opacity(0.22),
                                  lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 品牌标识：官方网盘用产品图标，其余用协议渐变 + 系统符号。
struct CloudMountBadge: View {
    let mount: CloudMount
    var size: CGFloat = 38

    var tint: Color { mount.kind.hubTint }

    var body: some View {
        Group {
            if let brand = mount.kind.brand {
                CloudBrandIcon(brand: brand, size: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: mount.kind.symbolName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                }
            }
        }
        .shadow(color: tint.opacity(0.26), radius: 7, y: 3)
    }
}

/// 远端海报：复用影院的内存缓存，不在总览里另起一套下载。
struct CloudHubArtwork: View {
    let urlString: String?
    var cornerRadius: CGFloat = 8
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        }
        .task(id: urlString) {
            guard let urlString else { image = nil; return }
            image = await CinemaArtworkCache.shared.image(for: urlString)
        }
    }
}

/// 体量条：索引分布与播放进度共用，宽度按比例铺满。
struct CloudHubVolumeBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// 播放进度条：比体量条更细，带一点内高光。
struct CloudHubProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 1)
                            .padding(.horizontal, 3)
                    }
            }
        }
        .frame(height: height)
    }
}

// MARK: - 格式化

enum CloudHubFormat {
    /// 相对时间：总览里只关心「刚刚 / N 分钟前 / N 天前」，超过一个月回到月份。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400)) 天前" }
        return DateText.monthFormatter.string(from: date)
    }

    /// 剩余时长：按小时 / 分钟粗粒度展示，避免出现「还剩 4872 秒」。
    static func remaining(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "还剩 \(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "还剩 \(minutes) 分钟" }
        return "还剩不到 1 分钟"
    }

    /// 总时长：续播页的「剩余时长」读数。
    static func hours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 1 { return String(format: "%.1f", hours) }
        return "\(max(0, Int((seconds / 60).rounded())))"
    }
}

// MARK: - 协议配色

extension CloudKind {
    /// 总览分页里的协议配色：与侧边栏、卡片保持同一套色相。
    var hubTint: Color {
        switch self {
        case .webdav: return Color(red: 0.32, green: 0.74, blue: 0.82)
        case .smb: return Color(red: 0.52, green: 0.58, blue: 0.96)
        case .aliyun: return Color(red: 1.00, green: 0.60, blue: 0.30)
        case .baidu: return Color(red: 0.26, green: 0.54, blue: 0.98)
        case .quark: return Color(red: 0.44, green: 0.50, blue: 1.00)
        case .pan115: return Color(red: 0.18, green: 0.56, blue: 0.96)
        }
    }
}
