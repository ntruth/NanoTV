import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院页的卡片模式：主卡 + 胶片条。

extension CinemaLibraryView {
    // MARK: 卡片模式（A2：主卡 + 胶片条，沿用 16:9 宽幅）

    func cardKey(movie: CinemaEntry) -> String { "movie-\(movie.id.uuidString)" }
    func cardKey(series: CinemaSeries) -> String { "series-\(series.id)" }

    func selectedMovie(in list: [CinemaEntry]) -> CinemaEntry? {
        if let key = cardHeroKey, key.hasPrefix("movie-"),
           let id = UUID(uuidString: String(key.dropFirst(6))) {
            return list.first { $0.id == id }
        }
        return list.first
    }

    func selectedSeries(in list: [CinemaSeries]) -> CinemaSeries? {
        if let key = cardHeroKey, key.hasPrefix("series-") {
            return list.first { cardKey(series: $0) == key }
        }
        return list.first
    }

    @ViewBuilder
    var cardContent: some View {
        switch store.cinemaTab {
        case .folder:
            EmptyView()
        case .movies:
            if movies.isEmpty {
                if isFilteringCinema { filterEmptyState } else { tabEmptyState("还没有识别到电影") }
            } else {
                cardStage(movies: movies, series: [])
            }
        case .shows:
            if series.isEmpty {
                if isFilteringCinema {
                    filterEmptyState
                } else if !unmatchedSeries.isEmpty {
                    cardStage(movies: [], series: unmatchedSeries)
                } else {
                    tabEmptyState("还没有识别到电视剧")
                }
            } else {
                cardStage(movies: [], series: series)
            }
        case .all:
            if movies.isEmpty, series.isEmpty {
                if isFilteringCinema { filterEmptyState } else { tabEmptyState("还没有可展示的影片") }
            } else {
                cardStage(movies: movies, series: series)
            }
        }
    }

    /// 主卡 + 胶片条：大卡给完整信息与主操作，下面的 16:9 胶片条负责快速切换。
    /// 胶片条放不下时不再横向滚动，而是收成「还有 N 部」一格，点开展开成完整网格。
    @ViewBuilder
    func cardStage(movies movieList: [CinemaEntry], series seriesList: [CinemaSeries]) -> some View {
        let movie = selectedMovie(in: movieList)
        let show = selectedSeries(in: seriesList)
        VStack(alignment: .leading, spacing: 16) {
            if let movie {
                cardHeroMovie(movie)
            } else if let show {
                cardHeroSeries(show)
            }
            if !movieList.isEmpty {
                cardFilmstripSection(
                    key: "movie",
                    title: "电影",
                    items: movieList.map {
                        CardStripItem(id: $0.id.uuidString,
                                      title: $0.title,
                                      subtitle: cardMeta(year: $0.year, genres: $0.genres),
                                      artwork: $0.backdropURL ?? $0.posterURL)
                    },
                    selectedID: movie?.id.uuidString
                ) { id in
                    guard let entry = movieList.first(where: { $0.id.uuidString == id }) else { return }
                    cardHeroKey = cardKey(movie: entry)
                }
            }
            if !seriesList.isEmpty {
                cardFilmstripSection(
                    key: "series",
                    title: "剧集",
                    items: seriesList.map {
                        CardStripItem(id: $0.id,
                                      title: $0.title,
                                      subtitle: "\($0.episodeCount) 集",
                                      artwork: $0.backdropURL ?? $0.posterURL)
                    },
                    selectedID: show?.id
                ) { id in
                    guard let item = seriesList.first(where: { $0.id == id }) else { return }
                    cardHeroKey = cardKey(series: item)
                }
            }
        }
        .onPreferenceChange(CinemaStripWidthKey.self) { width in
            if width > 0, abs(width - cardStripWidth) > 1 { cardStripWidth = width }
        }
    }

    /// 胶片条分组：默认只铺一行，放不下的收成「还有 N 部」；
    /// 点开后在原位换成完整网格，再点「收起」回到胶片条。
    func cardFilmstripSection(key: String,
                                      title: String,
                                      items: [CardStripItem],
                                      selectedID: String?,
                                      onSelect: @escaping (String) -> Void) -> some View {
        let expanded = expandedCardStrips.contains(key)
        let spacing: CGFloat = 10
        let cell = cinemaCardStripCellWidth
        let slots = max(2, Int((cardStripWidth + spacing) / (cell + spacing)))
        let collapsedCount = items.count > slots ? max(1, slots - 1) : items.count
        let shown = expanded ? items : Array(items.prefix(collapsedCount))
        let hidden = items.count - shown.count
        let canToggle = hidden > 0 || expanded
        return VStack(alignment: .leading, spacing: 10) {
            cardFilmstripHeader(title,
                                count: items.count,
                                expanded: expanded,
                                canToggle: canToggle) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if expanded {
                        _ = expandedCardStrips.remove(key)
                    } else {
                        _ = expandedCardStrips.insert(key)
                    }
                }
            }
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell),
                                             spacing: spacing, alignment: .leading)],
                          alignment: .leading,
                          spacing: spacing) {
                    ForEach(shown) { item in
                        filmstripCell(item, selected: item.id == selectedID) {
                            onSelect(item.id)
                        }
                    }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: spacing) {
                    ForEach(shown) { item in
                        filmstripCell(item, selected: item.id == selectedID) {
                            onSelect(item.id)
                        }
                    }
                    if hidden > 0 {
                        filmstripMoreTile(hidden: hidden) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                _ = expandedCardStrips.insert(key)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: CinemaStripWidthKey.self, value: proxy.size.width)
            }
        }
    }

    func cardFilmstripHeader(_ title: String,
                                     count: Int,
                                     expanded: Bool,
                                     canToggle: Bool,
                                     onToggle: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text("点胶片切换主卡")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            if canToggle {
                Button(expanded ? "收起" : "查看全部") { onToggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                    .help(expanded ? "收起成一行胶片条" : "展开成完整网格，不用横向滚动")
            }
        }
    }

    /// 胶片条里的一格：16:9 缩略图 + 片名，选中项用琥珀描边。
    func filmstripCell(_ item: CardStripItem,
                               selected: Bool,
                               action: @escaping () -> Void) -> some View {
        let cell = cinemaCardStripCellWidth
        return Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CinemaArtwork(urlString: item.artwork, maxPixelSize: 480)
                    .frame(width: cell, height: cell * 9 / 16)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.78)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .padding(8)
            }
            .frame(width: cell, height: cell * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? LumaBrand.amber : Color.white.opacity(0.10),
                                  lineWidth: selected ? 2 : 0.6)
            }
            .shadow(color: .black.opacity(selected ? 0.30 : 0.14),
                    radius: selected ? 10 : 4, y: selected ? 5 : 2)
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    /// 放不下的那一叠：虚线香槟框 + 胶片图标，点开就把整组铺成网格。
    func filmstripMoreTile(hidden: Int, action: @escaping () -> Void) -> some View {
        let cell = cinemaCardStripCellWidth
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(LumaBrand.amber.opacity(0.92))
                Text("还有 \(hidden) 部")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("展开全部")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: cell, height: cell * 9 / 16)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [.black.opacity(0.38),
                                                  LumaBrand.amber.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.38),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .buttonStyle(.plain)
        .help("展开剩下的 \(hidden) 部")
    }

    /// 16:9 主卡：背景大图 + 三行简介 + 播放 / 详情 / 收藏。
    func cardHeroMovie(_ entry: CinemaEntry) -> some View {
        let progress = store.cinemaProgress[entry.id]
        let isFavorite = store.cinemaUserState(for: entry.id).favorite
        return ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: entry.backdropURL ?? entry.posterURL, maxPixelSize: 1600)
                .frame(maxWidth: .infinity)
                .frame(height: 344)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35), .black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    cardHeroChip(entry.kind == .movie ? "电影" : "剧集")
                    if let year = entry.year { cardHeroChip(String(year)) }
                    ForEach(Array((entry.genres ?? []).prefix(2)), id: \.self) { genre in
                        cardHeroChip(genre)
                    }
                    Spacer(minLength: 0)
                    if let rating = entry.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                Text(entry.title)
                    .font(.system(size: 27, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button {
                        store.openCinema(entry, queue: aggregate.allEntries)
                    } label: {
                        Label(progress.map { $0.fraction > 0.01 && !$0.isFinished ? "继续播放" : "播放" } ?? "播放",
                              systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .controlSize(.large)

                    Button {
                        openDetail(entry)
                    } label: {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.large)

                    Button {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) {
                            store.toggleCinemaFavorite(entry.id)
                        }
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isFavorite ? LumaBrand.coral : .white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)

                    if store.cinemaVersionCount(for: entry) > 1 {
                        Text("\(store.cinemaVersionCount(for: entry)) 个版本")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(24)
        }
        .frame(height: 344)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
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

    /// 剧集主卡：优先继续下一集。
    func cardHeroSeries(_ item: CinemaSeries) -> some View {
        let resume = resumeEpisode(for: item)
        let watched = watchedEpisodeCount(item)
        return ZStack(alignment: .bottomLeading) {
            CinemaArtwork(urlString: item.backdropURL ?? item.posterURL, maxPixelSize: 1600)
                .frame(maxWidth: .infinity)
                .frame(height: 344)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35), .black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    cardHeroChip("剧集")
                    if let year = item.year { cardHeroChip(String(year)) }
                    cardHeroChip("\(item.episodeCount) 集")
                    if watched > 0 { cardHeroChip("已看 \(watched)") }
                    Spacer(minLength: 0)
                    if let rating = item.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                Text(item.title)
                    .font(.system(size: 27, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button {
                        if let target = resume {
                            store.openCinema(target, queue: seriesQueue(for: item))
                        }
                    } label: {
                        Label(resumeSubtitle(for: item) ?? "播放第一集", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .controlSize(.large)
                    .disabled(resume == nil)

                    Button {
                        detailTarget = .series(item)
                    } label: {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.large)
                    Spacer(minLength: 0)
                }
            }
            .padding(24)
        }
        .frame(height: 344)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    func cardHeroChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.12), in: Capsule())
    }

    func movieCard(_ entry: CinemaEntry) -> some View {
        let progress = store.cinemaProgress[entry.id]
        return CinemaWideCard(title: entry.title,
                              meta: cardMeta(year: entry.year, genres: entry.genres),
                              artworkURL: entry.backdropURL ?? entry.posterURL,
                              fallbackPhoto: entry.file.photoItem,
                              rating: entry.rating,
                              badges: cardBadges(for: entry),
                              progressFraction: progress?.fraction,
                              progressText: progress.map { "已看 \(Int($0.fraction * 100))%" },
                              onOpen: { openDetail(entry) },
                              onPlay: { store.openCinema(entry, queue: aggregate.allEntries) })
            .id(entry.id)
    }

    func seriesCard(_ item: CinemaSeries) -> some View {
        let watched = watchedEpisodeCount(item)
        let resume = resumeEpisode(for: item)
        let progressText: String? = resumeSubtitle(for: item)
            ?? (watched > 0 ? "已看 \(watched)/\(item.episodeCount) 集" : nil)
        let fraction = item.episodeCount > 0 ? Double(watched) / Double(item.episodeCount) : nil
        return CinemaWideCard(title: item.title,
                              meta: cardMeta(year: item.year, genres: item.genres),
                              artworkURL: item.backdropURL ?? item.posterURL,
                              fallbackPhoto: item.latestEpisode?.file.photoItem,
                              rating: item.rating,
                              badges: ["\(item.episodeCount) 集"] + (watched > 0 ? ["已看 \(watched)"] : []),
                              progressFraction: fraction,
                              progressText: progressText,
                              onOpen: { detailTarget = .series(item) },
                              onPlay: { if let resume { store.openCinema(resume, queue: seriesQueue(for: item)) } })
            .id(item.id)
    }

    func cardMeta(year: Int?, genres: [String]?) -> String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let genres, !genres.isEmpty {
            parts.append(contentsOf: genres.prefix(2))
        }
        return parts.joined(separator: " · ")
    }

    /// 卡片规格角标：优先取文件标记，没有就按分辨率兜底。
    func cardBadges(for entry: CinemaEntry) -> [String] {
        var tags = Array(entry.file.displayTags.prefix(2))
        if tags.isEmpty {
            let width = entry.file.pixelWidth
            if width >= 3000 { tags.append("4K") }
            else if width >= 1800 { tags.append("1080P") }
            else if width > 0 { tags.append("720P") }
        }
        let versions = store.cinemaVersionCount(for: entry)
        if versions > 1 { tags.append("\(versions) 版本") }
        return Array(tags.prefix(3))
    }
}
