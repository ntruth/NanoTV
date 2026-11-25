import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院页的书架：继续观看、我的清单、分类行与主视觉。

extension CinemaLibraryView {
    // MARK: 书架

    @ViewBuilder
    var shelfContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .all:
            // 按类型浏览时「继续观看」不属于这个类型，先收起来，避免混进无关影片。
            if store.cinemaTypeFilterID == nil, !store.cinemaContinueRecords(for: scope).isEmpty {
                continueShelf
            }
            categoryRow
            if !movies.isEmpty {
                shelf("最近添加", Array(movies.prefix(18)))
                shelf("高分电影", Array(movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(18)))
            }
            if !series.isEmpty {
                seriesShelf("剧集", series)
            }
            collectionShelves
            if !store.cinemaLists.isEmpty {
                myListsShelf
            }
            networkResourceShelf
            if series.isEmpty, movies.isEmpty, isFilteringCinema {
                filterEmptyState
            }
            // 没匹配上的也摆出来，否则「有 67 个视频但影院是空的」看起来像刮削没跑。
            // 筛选生效时它们没有年份 / 类型可比，先收起来。
            if !isFilteringCinema, !unmatched.isEmpty {
                unmatchedShelf
            }
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电影")
                }
            } else {
                hero(entries: movies)
                collectionShelves
                shelf("最近添加", Array(movies.prefix(18)))
                shelf("高分电影", Array(movies.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }.prefix(18)))
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    // 一集都没识别上时也按剧聚合展示，而不是给一张空页。
                    unmatchedShelf
                } else if !unmatched.isEmpty {
                    unmatchedEmptyState
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                seriesHero()
                seriesShelf("全部剧集", series)
                if !isFilteringCinema, !unmatchedSeries.isEmpty {
                    unmatchedShelf
                }
            }
        }
    }

    // MARK: 分类行

    /// 网络资源的稍后看与更新日历：只展示网页资源站的数据，
    /// 网络影院的影视源条目不会混进这里。
    @ViewBuilder
    var networkResourceShelf: some View {
        let favorites = Array(store.catalogModel.resourceFavorites.prefix(10))
        let resourceIDs = store.catalogModel.resourceSourceIDs
        let updates = Array(store.catalogModel.calendarItems
            .filter { resourceIDs.contains($0.sourceID) }
            .suffix(10))
        if !favorites.isEmpty || !updates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("网络资源")
                        .font(.system(size: 14, weight: .semibold))
                    Text("稍后看 \(store.catalogModel.resourceFavorites.count) · 更新 \(store.catalogModel.calendarItems.filter { resourceIDs.contains($0.sourceID) }.count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button("打开网络资源") {
                        store.navigate(to: .catalogSources)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LumaBrand.amber)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(favorites) { favorite in
                            networkResourceChip(title: favorite.title, badge: "稍后看") {
                                store.navigate(to: .catalogSource(favorite.sourceID))
                            }
                        }
                        ForEach(updates) { item in
                            networkResourceChip(title: item.title, badge: "更新") {
                                store.navigate(to: .catalogSource(item.sourceID))
                            }
                        }
                    }
                }
            }
        }
    }

    func networkResourceChip(title: String,
                                     badge: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(badge)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(LumaBrand.amber.opacity(0.12), in: Capsule())
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// 首页分类总览：上半是全部 / 收藏 / 最近 / 高分快捷条件，下半把所有内容类型平铺出来。
    /// 「全部」页因此能直接看到每个类型有多少条，不用再展开顶栏的类型弹层。
    var categoryRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("分类")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    categoryChip("全部",
                                 icon: "square.grid.2x2.fill",
                                 count: allEntries.count,
                                 active: !store.cinemaHasAttributeFilters
                                     && !store.cinemaFavoritesOnly
                                     && store.cinemaActiveListID == nil) {
                        store.resetCinemaFilters()
                    }
                    categoryChip("收藏",
                                 icon: "heart.fill",
                                 count: categoryFavoriteCount,
                                 active: store.cinemaFavoritesOnly) {
                        store.cinemaFavoritesOnly.toggle()
                    }
                    categoryChip("最近 30 天",
                                 icon: "clock.fill",
                                 count: categoryRecentCount,
                                 active: store.cinemaSmartRecent) {
                        store.cinemaSmartRecent.toggle()
                    }
                    categoryChip("高分 8+",
                                 icon: "star.fill",
                                 count: categoryHighRatedCount,
                                 active: store.cinemaSmartHighRated) {
                        store.cinemaSmartHighRated.toggle()
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            if !aggregate.types.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("类型")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(aggregate.types.count) 个")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(aggregate.types) { bucket in
                                typeChip(bucket)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    /// 类型胶囊：点一下就按这个类型筛选，再点取消；条目数来自未筛选的全量统计。
    func typeChip(_ bucket: CinemaTypeBucket) -> some View {
        let selected = store.cinemaTypeFilterID == bucket.id
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                if selected {
                    store.cinemaTypeFilterID = nil
                } else {
                    store.cinemaTypeFilterID = bucket.id
                    store.cinemaTab = .all
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: bucket.type.icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(bucket.type.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(bucket.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.6)
            }
            .foregroundStyle(selected ? LumaBrand.amber : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? LumaBrand.amber.opacity(0.16) : Color.primary.opacity(0.05),
                        in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(selected ? LumaBrand.amber.opacity(0.45) : Color.clear,
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(bucket.type.title) · \(bucket.count) 部")
    }

    var categoryFavoriteCount: Int { aggregate.favoriteCount }

    var categoryRecentCount: Int { aggregate.recentCount }

    var categoryHighRatedCount: Int { aggregate.highRatedCount }

    func categoryChip(_ title: String,
                              icon: String,
                              count: Int,
                              active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(active ? LumaBrand.amber.opacity(0.18) : Color.primary.opacity(0.05))
                    Circle()
                        .strokeBorder(active ? LumaBrand.amber.opacity(0.5) : Color.primary.opacity(0.08),
                                      lineWidth: 0.8)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                }
                .frame(width: 48, height: 48)
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) · \(count) 部")
    }

    // MARK: 主视觉

    @ViewBuilder
    func hero(entries: [CinemaEntry]? = nil) -> some View {
        let pool = entries ?? self.entries
        if let entry = pool.first(where: { $0.backdropURL != nil }) ?? pool.first {
            // 切分类 / 切筛选时 Hero 换片：新旧背景交叉淡入，不硬切。
            ZStack {
                CinemaHeroCard(entry: entry,
                               onPlay: { store.openCinema(entry) },
                               onDetail: { openDetail(entry) })
                    .id(entry.id)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: entry.id)
        }
    }

    func shelf(_ title: String, _ list: [CinemaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { entry in
                        posterCard(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 继续观看

    @ViewBuilder
    var continueShelf: some View {
        let records = store.cinemaContinueRecords(for: scope)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("继续观看")
                        .font(.system(size: 14, weight: .semibold))
                    if records.count > 1 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                continueExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(records.count) 部待续播")
                                Image(systemName: continueExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(continueExpanded ? LumaBrand.amber : .secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(continueExpanded ? "收起待续播队列" : "展开全部待续播")
                    } else {
                        Text("1 部待续播")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if records.count > 1, continueExpanded {
                        Text("\(records.count) 部全部展开")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                if continueExpanded {
                    // 展开：队列换成多行网格，一屏看全，不再横向滚动。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 236),
                                                 spacing: 14, alignment: .leading)],
                              alignment: .leading,
                              spacing: 14) {
                        ForEach(records) { record in
                            CinemaContinueCard(record: record) {
                                openContinue(record)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(records.prefix(3)) { record in
                                CinemaContinueCard(record: record) {
                                    openContinue(record)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    func openContinue(_ record: CinemaProgressRecord) {
        guard let entry = store.cinemaEntries(for: scope)[record.photoID] else { return }
        // 从影院里点任何一张卡都先看详情，播放交给详情页的「继续播放」。
        openDetail(entry)
    }

    // MARK: 我的清单

    var myListsShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("我的清单")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.cinemaLists.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    panelTarget = .newList
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaBrand.amber)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(store.cinemaLists) { list in
                        cinemaListCard(list)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    func cinemaListCard(_ list: CinemaListRecord) -> some View {
        let active = store.cinemaActiveListID == list.id
        return Button {
            store.cinemaActiveListID = active ? nil : list.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: list.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(list.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(list.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(active ? "已筛选" : "点击筛选")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(11)
            .frame(width: 172, height: 82, alignment: .leading)
            .background(active ? LumaBrand.amber.opacity(0.12)
                               : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? LumaBrand.amber.opacity(0.45)
                                         : Color.primary.opacity(0.06),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除清单", role: .destructive) {
                store.deleteCinemaList(list.id)
            }
        }
    }

    // MARK: 剧集（多集 → 一张卡）

    @ViewBuilder
    func seriesHero() -> some View {
        if let item = series.first(where: { $0.backdropURL != nil }) ?? series.first {
            ZStack {
                CinemaSeriesHeroCard(series: item,
                                     onPlay: {
                                         if let target = resumeEpisode(for: item) {
                                             store.openCinema(target, queue: seriesQueue(for: item))
                                         }
                                     },
                                     onOpen: { detailTarget = .series(item) })
                    .id(item.id)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: item.id)
        }
    }

    func seriesShelf(_ title: String, _ list: [CinemaSeries]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(list) { item in
                        CinemaSeriesCard(series: item) {
                            detailTarget = .series(item)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 未识别同样按剧聚合：一部剧一张卡，电影仍是一条一张。
    var unmatchedShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未识别 · 可右键重新刮削")
                .font(.system(size: 14, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(unmatchedSeries) { item in
                        CinemaSeriesCard(series: item) {
                            detailTarget = .series(item)
                        }
                    }
                    ForEach(unmatchedMovies.prefix(18)) { entry in
                        posterCard(entry)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    func open(_ raw: String) {
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }
}
