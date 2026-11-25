import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院页的列表模式：表头、行与选中项操作。

extension CinemaLibraryView {
    // MARK: 列表

    @ViewBuilder
    var listContent: some View {
        // 上千行时只构建视口内的行，滚动才继续实例化。
        LazyVStack(spacing: 0) {
            listHeader
            Divider().opacity(0.5)
            switch store.cinemaTab {
            case .folder:
                EmptyView()
            case .all:
                if !series.isEmpty {
                    ForEach(listedSeries) { item in
                        seriesListRow(item, badge: "剧集")
                    }
                    Divider().opacity(0.4)
                }
                if !movies.isEmpty {
                    ForEach(listedMovies) { entry in
                        entryListRow(entry)
                    }
                }
                if series.isEmpty, movies.isEmpty, isFilteringCinema {
                    filterEmptyState
                }
                if !isFilteringCinema, !unmatched.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(unmatchedSeries) { item in
                        seriesListRow(item, badge: "未识别")
                    }
                    ForEach(unmatchedMovies) { entry in
                        entryListRow(entry)
                    }
                }
            case .movies:
                if movies.isEmpty {
                    if isFilteringCinema {
                        filterEmptyState
                    } else {
                        tabEmptyState("还没有识别到电影")
                    }
                } else {
                    ForEach(listedMovies) { entry in
                        entryListRow(entry)
                    }
                }
            case .shows:
                if series.isEmpty {
                    if isFilteringCinema {
                        filterEmptyState
                    } else if !unmatchedSeries.isEmpty {
                        ForEach(unmatchedSeries) { item in
                            seriesListRow(item, badge: "未识别")
                        }
                    } else {
                        tabEmptyState("还没有识别到电视剧")
                    }
                } else {
                    ForEach(listedSeries) { item in
                        seriesListRow(item, badge: "剧集")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .focusable()
        .focused($listFocus)
        // 去掉系统默认的蓝色焦点描边：它会把整张列表框成一圈，和影院的暗色面板冲突。
        .focusEffectDisabled()
        .onAppear { listFocus = true }
        .onKeyPress(.space) {
            guard store.viewerID == nil else { return .ignored }
            playSelectedListRow()
            return .handled
        }
        .onKeyPress(.return) {
            guard store.viewerID == nil else { return .ignored }
            openSelectedListRow()
            return .handled
        }
    }

    func seriesListRow(_ item: CinemaSeries, badge: String) -> some View {
        let watched = watchedEpisodeCount(item)
        return CinemaListRow(artworkURL: item.artworkURL,
                      fallbackPhoto: item.latestEpisode?.file.photoItem,
                      title: item.title,
                      subtitle: resumeSubtitle(for: item) ?? item.subtitle,
                      year: item.year.map(String.init) ?? "—",
                      rating: item.rating,
                      genres: item.latestEpisode?.genres?.joined(separator: " / ") ?? "—",
                      spec: watched > 0 ? "\(watched)/\(item.episodeCount) 集" : "\(item.episodeCount) 集",
                      badge: badge,
                      progress: nil,
                      onOpen: { detailTarget = .series(item) },
                      selected: selectedListSeriesID == item.id,
                      onSelect: {
                          selectedListEntryID = nil
                          selectedListSeriesID = item.id
                      },
                      onPlay: { if let target = resumeEpisode(for: item) { store.openCinema(target, queue: seriesQueue(for: item)) } },
                      singleClickOpensDetail: true)
            .contextMenu {
                Button("播放") {
                    if let target = resumeEpisode(for: item) {
                        store.openCinema(target, queue: seriesQueue(for: item))
                    }
                }
                Button("查看详情") { detailTarget = .series(item) }
                Divider()
                Button("选择海报…") { requestArtwork(.poster, for: item) }
                Button("选择背景…") { requestArtwork(.backdrop, for: item) }
            }
    }

    /// 列表行右键换封面：取这部剧里已匹配的一集，交给统一候选面板。
    func requestArtwork(_ kind: CinemaArtworkKind, for item: CinemaSeries) {
        guard let sample = item.episodes.first(where: { $0.matched && $0.tmdbID != nil }) else {
            store.showToast("先匹配这部剧，才能更换封面")
            return
        }
        // 菜单收起后再弹面板，避免菜单窗口抢焦点导致 sheet 不出现。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: sample)
        }
    }

    /// 影片列表行 / 卡片右键换封面。
    func requestArtwork(_ kind: CinemaArtworkKind, for entry: CinemaEntry) {
        guard entry.matched, entry.tmdbID != nil else {
            store.showToast("先匹配这部片，才能更换封面")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            artworkRequest = CinemaArtworkPickerRequest(kind: kind, entry: entry)
        }
    }

    /// 上次播放优先：进行中的一集 → 最后看完的下一集 → 第一集。
    func resumeEpisode(for item: CinemaSeries) -> CinemaEntry? {
        let ordered = item.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
        if let inProgress = ordered.first(where: { store.cinemaWatchState(for: $0) == .inProgress }) {
            return inProgress
        }
        if let last = ordered.lastIndex(where: { store.cinemaWatchState(for: $0) == .finished }),
           last + 1 < ordered.count {
            return ordered[last + 1]
        }
        return ordered.first ?? item.latestEpisode
    }

    func watchedEpisodeCount(_ item: CinemaSeries) -> Int {
        item.episodes.filter { store.cinemaWatchState(for: $0) == .finished }.count
    }

    /// 列表副标题：有进行中的一集时优先显示「上次看到 SxxExx · 已看 yy%」。
    func resumeSubtitle(for item: CinemaSeries) -> String? {
        guard let target = resumeEpisode(for: item),
              let progress = store.cinemaProgress[target.id],
              progress.fraction > 0.01, !progress.isFinished else { return nil }
        let label: String
        if let season = target.season, let episode = target.episode {
            label = String(format: "S%02dE%02d", season, episode)
        } else if let episode = target.episode {
            label = "第 \(episode) 集"
        } else {
            label = "上次"
        }
        return "上次看到 \(label) · 已看 \(Int(progress.fraction * 100))%"
    }

    func selectedListSeries() -> CinemaSeries? {
        guard let id = selectedListSeriesID else { return nil }
        return (series + unmatchedSeries).first(where: { $0.id == id })
    }

    func selectedListEntry() -> CinemaEntry? {
        guard let id = selectedListEntryID else { return nil }
        return (movies + unmatchedMovies).first(where: { $0.id == id })
    }

    func playSelectedListRow() {
        if let entry = selectedListEntry() {
            store.openCinema(entry, queue: aggregate.allEntries)
        } else if let item = selectedListSeries(), let target = resumeEpisode(for: item) {
            store.openCinema(target, queue: seriesQueue(for: item))
        }
    }

    func openSelectedListRow() {
        if let entry = selectedListEntry() {
            openDetail(entry)
        } else if let item = selectedListSeries() {
            detailTarget = .series(item)
        }
    }

    var listHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 44, height: 1)
            sortHeader("片名", sort: .title)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            sortHeader("年份", sort: .year)
                .frame(width: 56, alignment: .leading)
            sortHeader("评分", sort: .rating)
                .frame(width: 56, alignment: .leading)
            Text("类型")
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text("规格")
                .frame(width: 150, alignment: .leading)
            HStack(spacing: 4) {
                Text("状态")
                Button {
                    store.cinemaSort = .recent
                    listSortReversed = false
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(store.cinemaSort == .recent ? LumaBrand.amber : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("按最近添加排序")
            }
            .frame(width: 104, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 表头点击排序：只切排序字段，再次点击同一列反转方向。
    func sortHeader(_ title: String, sort: CinemaSort) -> some View {
        Button {
            if store.cinemaSort == sort {
                listSortReversed.toggle()
            } else {
                store.cinemaSort = sort
                listSortReversed = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if store.cinemaSort == sort {
                    Image(systemName: sortArrow(sort))
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(store.cinemaSort == sort ? LumaBrand.amber : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    func sortArrow(_ sort: CinemaSort) -> String {
        let naturalAscending = sort == .title
        let ascending = listSortReversed ? !naturalAscending : naturalAscending
        return ascending ? "chevron.up" : "chevron.down"
    }

    func entryListRow(_ entry: CinemaEntry) -> some View {
        CinemaListRow(artworkURL: entry.artworkURL,
                      fallbackPhoto: entry.file.photoItem,
                      title: entry.title,
                      subtitle: entry.file.filename,
                      year: entry.year.map(String.init) ?? "—",
                      rating: entry.rating,
                      genres: entry.genres?.joined(separator: " / ") ?? "—",
                      spec: entrySpec(entry),
                      badge: entry.matched ? (entry.kind == .movie ? "电影" : "剧集") : "未识别",
                      progress: store.cinemaProgress[entry.id],
                      onOpen: { openDetail(entry) },
                      selected: selectedListEntryID == entry.id,
                      onSelect: {
                          selectedListSeriesID = nil
                          selectedListEntryID = entry.id
                      },
                      onPlay: { store.openCinema(entry, queue: aggregate.allEntries) },
                      singleClickOpensDetail: true)
            .contextMenu {
                CinemaEntryContextMenu(
                    entry: entry,
                    onPlay: { store.openCinema(entry, queue: aggregate.allEntries) },
                    onDetail: { openDetail(entry) },
                    onManualMatch: { panelTarget = .match(entry) },
                    onArtwork: { kind in requestArtwork(kind, for: entry) }
                )
            }
    }

    /// 整部剧按季、集排好，作为播放队列：播完自动下一集，顶栏「下一集」也能用。
    func seriesQueue(for item: CinemaSeries) -> [CinemaEntry] {
        item.episodes.sorted { lhs, rhs in
            if (lhs.season ?? 0) != (rhs.season ?? 0) {
                return (lhs.season ?? 0) < (rhs.season ?? 0)
            }
            return (lhs.episode ?? 0) < (rhs.episode ?? 0)
        }
    }

    func entrySpec(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if entry.file.pixelWidth > 0, entry.file.pixelHeight > 0 {
            parts.append("\(entry.file.pixelWidth)×\(entry.file.pixelHeight)")
        }
        if let codec = entry.file.videoCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        parts.append(contentsOf: entry.file.displayTags.prefix(2))
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: 详情入口

    func openDetail(_ entry: CinemaEntry) {
        withAnimation(.easeOut(duration: 0.2)) {
            if entry.kind == .tv,
               let item = store.cinemaSeries(for: scope, matched: entry.matched)
                .first(where: { series in
                    series.episodes.contains(where: { $0.id == entry.id })
                }) {
                detailTarget = .series(item)
                return
            }
            detailTarget = .entry(entry)
        }
    }

    /// 筛选把当前分页筛空：告诉用户是筛选而不是刮削没结果，并提供一键复位。
    var filterEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("没有符合筛选条件的影片")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(filterSummary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("清除筛选") {
                withAnimation(.snappy(duration: 0.16)) {
                    store.resetCinemaFilters()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// 顶栏筛选条件的可读描述，例如「2024 · 科幻 · 4K · 进行中」。
    var filterSummary: String {
        var parts: [String] = []
        if let typeID = store.cinemaTypeFilterID {
            parts.append(CinemaContentType.descriptor(id: typeID).title)
        }
        if !store.cinemaKindFilters.isEmpty {
            parts.append(store.cinemaKindFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaYears.isEmpty {
            parts.append(store.cinemaYears.sorted(by: >).map(String.init).joined(separator: "/"))
        }
        if !store.cinemaGenres.isEmpty {
            parts.append(store.cinemaGenres.sorted().joined(separator: "/"))
        }
        if !store.cinemaCountries.isEmpty {
            parts.append(store.cinemaCountries.sorted().joined(separator: "/"))
        }
        if !store.cinemaLanguages.isEmpty {
            parts.append(store.cinemaLanguages.sorted()
                .map(CinemaLanguageCatalog.title)
                .joined(separator: "/"))
        }
        if !store.cinemaResolutions.isEmpty {
            parts.append(store.cinemaResolutions.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaSpecFilters.isEmpty {
            parts.append(store.cinemaSpecFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaRuntimeFilters.isEmpty {
            parts.append(store.cinemaRuntimeFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaRatingFilters.isEmpty {
            parts.append(store.cinemaRatingFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if !store.cinemaWatchFilters.isEmpty {
            parts.append(store.cinemaWatchFilters.map(\.title).sorted().joined(separator: "/"))
        }
        if store.cinemaSmartHighRated { parts.append("高分 8+") }
        if store.cinemaSmartRecent { parts.append("最近 30 天") }
        if store.cinemaFavoritesOnly { parts.append("收藏") }
        if let list = store.cinemaList(store.cinemaActiveListID) { parts.append(list.name) }
        return parts.joined(separator: " · ")
    }
}
