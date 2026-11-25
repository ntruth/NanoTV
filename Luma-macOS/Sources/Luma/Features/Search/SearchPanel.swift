import SwiftUI
import LumaContentCore

extension SearchSourceKind {
    var tint: Color {
        switch self {
        case .library: return Color(red: 0.36, green: 0.62, blue: 1.00)
        case .cloud: return Color(red: 0.30, green: 0.78, blue: 0.76)
        case .cinema: return Color(red: 0.98, green: 0.67, blue: 0.30)
        case .networkCinema: return Color(red: 0.96, green: 0.45, blue: 0.58)
        case .television: return Color(red: 0.36, green: 0.85, blue: 0.96)
        case .catalog: return Color(red: 0.72, green: 0.55, blue: 0.98)
        }
    }
}

// MARK: - 来源胶囊

/// 来源切换条：只展示 `center.scopes` 里配置过的来源。
/// 全局搜索传全部来源；模块内搜索只传自己需要的来源，出现的就是单个 / 少量胶囊。
struct SearchScopeBar: View {
    @ObservedObject var center: SearchCenter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if center.scopes.count > 1 {
                    chip(title: "全部",
                         icon: "sparkle.magnifyingglass",
                         count: center.totalCount,
                         tint: Color.accentColor,
                         active: center.activeSource == nil,
                         loading: center.isSearching) {
                        withAnimation(.snappy(duration: 0.18)) {
                            center.setActiveSource(nil)
                        }
                    }
                }
                ForEach(center.scopes) { source in
                    chip(title: source.title,
                         icon: source.icon,
                         count: center.count(for: source),
                         tint: source.tint,
                         active: center.activeSource == source,
                         loading: center.searchingSources.contains(source)) {
                        withAnimation(.snappy(duration: 0.18)) {
                            center.setActiveSource(source)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
        }
    }

    private func chip(title: String, icon: String, count: Int, tint: Color,
                      active: Bool, loading: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(active ? Color.white : tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                if loading {
                    // 正在检索这个来源：给一个小转圈，比一直显示旧计数更直观。
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else if count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(active ? Color.white.opacity(0.82) : Color.secondary)
                }
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? AnyShapeStyle(tint)
                                 : AnyShapeStyle(Color.primary.opacity(0.055)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.clear : Color.primary.opacity(0.07),
                                  lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("只看\(title)")
    }
}

// MARK: - 结果面板

/// 搜索结果面板：既服务「全部来源」的聚合视图，也服务单个来源的完整列表。
/// 图库照片支持注入宿主自己的网格（分页、选择、查看器都沿用原实现）。
struct SearchContent<PhotoGrid: View>: View {
    @ObservedObject var center: SearchCenter
    @ViewBuilder var photoGrid: () -> PhotoGrid
    let onOpen: (SearchHit) -> Void
    /// 全部来源都为空时展示的提示（宿主可自定义）。
    var emptyView: AnyView? = nil

    var body: some View {
        if let source = center.activeSource {
            sourceContent(source)
        } else {
            allContent
        }
    }

    // MARK: 全部来源

    private var allContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if center.sections.isEmpty {
                    if center.isSearching {
                        loadingHint("正在检索各来源…")
                    } else {
                        emptyView ?? AnyView(defaultEmpty)
                    }
                } else {
                    ForEach(center.sections) { section in
                        sectionPreview(section)
                    }
                    ForEach(center.scopes.filter { center.searchingSources.contains($0) }) { source in
                        loadingHint("正在检索\(source.title)…")
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 44)
        }
    }

    private func sectionPreview(_ section: SearchSection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SearchSectionHeader(source: section.source,
                                count: section.total,
                                showsMore: true) {
                withAnimation(.snappy(duration: 0.18)) {
                    center.setActiveSource(section.source)
                }
            }
            if section.hits.isEmpty {
                Text("没有匹配的\(section.source.title)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(section.hits.prefix(5)) { hit in
                    SearchHitRow(hit: hit, onOpen: onOpen)
                }
            }
        }
    }

    // MARK: 单个来源

    @ViewBuilder
    private func sourceContent(_ source: SearchSourceKind) -> some View {
        let section = center.section(for: source)
        VStack(spacing: 0) {
            if let section {
                if source == .library {
                    // 图库固定露出 图片 / 视频 / 相簿 / 文件夹 / 人物 / 场景 / 位置：
                    // 某一类这次没有命中也要显示 0，用户才知道该去哪个类型看结果。
                    libraryKindBar(section)
                } else if source == .television {
                    // 电视固定露出「直播 / 节目」两个 tab：没有节目也保留入口，
                    // 用户能明确知道节目单也在搜，而不是只有频道列表。
                    televisionKindBar(section)
                } else if section.orderedKinds.count > 1 {
                    kindBar(section)
                }
                // 电视 / 资源 / 影院 / 网盘：先按「源」筛，再按源下面的「分类」筛。
                originBar(section)
                categoryBar(section)
            }
            if source == .library, let section,
               showsLibraryGrid(section) {
                photoGrid()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let section {
                            let hits = filteredHits(section)
                            if hits.isEmpty {
                                emptyHint(center.activeKind.map { "没有匹配的\($0.title)" }
                                          ?? "没有匹配的\(source.title)")
                            } else {
                                ForEach(hits) { hit in
                                    SearchHitRow(hit: hit, onOpen: onOpen)
                                }
                            }
                        } else if center.searchingSources.contains(source) {
                            loadingHint("正在检索\(source.title)…")
                        } else {
                            emptyHint("没有匹配的\(source.title)")
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .padding(.bottom, 44)
                }
            }
        }
    }

    private var isShowingPhotos: Bool {
        center.activeKind == nil || center.activeKind == .photo
    }

    /// 只有当前图库的命中才用宿主的照片墙：一旦有其它图库的照片 / 视频，
    /// 改走结果行，跨库内容才不会因为网格只覆盖当前库而消失。
    private func isShowingLibraryGrid(_ section: SearchSection) -> Bool {
        !section.hits.contains {
            $0.isOtherLibrary && ($0.kind == .photo || $0.kind == .video)
        }
    }

    /// 图库「全部」只有命中全是图片 / 视频时才用宿主的照片墙；
    /// 一旦还有场景 / 地点 / 人物 / 相簿 / 文件夹，照片墙只会显示图片视频，
    /// 把这几类结果整个吞掉（界面看上去「一条都没有」），改用结果行全部列出。
    private func showsLibraryGrid(_ section: SearchSection) -> Bool {
        guard isShowingPhotos, isShowingLibraryGrid(section) else { return false }
        if center.activeKind == .photo || center.activeKind == .video { return true }
        return section.kindCounts.allSatisfy {
            $0.value == 0 || $0.key == .photo || $0.key == .video
        }
    }

    private func filteredHits(_ section: SearchSection) -> [SearchHit] {
        var hits = section.hits
        // 会话恢复 / 换库后可能还带着上一轮的「源」「分类」筛选。
        // 当前结果里已经没有这个值时就忽略，否则整类结果会被一个不存在的条件清空
        // （胶囊上有计数，列表却是空的）。
        if let origin = center.activeOrigin,
           section.origins.contains(where: { $0.title == origin }) {
            hits = hits.filter { $0.origin == origin }
        }
        if let category = center.activeCategory,
           section.categories(under: center.activeOrigin).contains(where: { $0.title == category }) {
            hits = hits.filter { $0.category == category }
        }
        guard let kind = center.activeKind else { return hits }
        if kind == .photo, section.source == .library, isShowingLibraryGrid(section) {
            // 图片与视频由宿主的网格展示，这里不再重复列行。
            return hits.filter { $0.kind != .photo && $0.kind != .video }
        }
        return hits.filter { $0.kind == kind }
    }

    /// 「源」筛选：网盘 / 影院范围 / 电视播放列表 / 资源站点，只有多于一个源时出现。
    @ViewBuilder
    private func originBar(_ section: SearchSection) -> some View {
        let origins = section.origins
        if origins.count > 1 {
            filterStrip(title: "源",
                        options: origins,
                        active: center.activeOrigin,
                        tint: section.source.tint,
                        allLabel: "全部源",
                        allCount: nil) { origin in
                center.activeOrigin = origin
                // 换源后原来的分类多半已经不存在，直接回到全部分类。
                center.activeCategory = nil
            }
        }
    }

    /// 「分类」筛选：电视频道分组、资源分类、网盘目录等。
    @ViewBuilder
    private func categoryBar(_ section: SearchSection) -> some View {
        let categories = section.categories(under: center.activeOrigin)
        if categories.count > 1 {
            filterStrip(title: "分类",
                        options: categories,
                        active: center.activeCategory,
                        tint: section.source.tint,
                        allLabel: "全部分类",
                        allCount: nil) { category in
                center.activeCategory = category
            }
        }
    }

    private func filterStrip(title: String,
                             options: [(title: String, count: Int)],
                             active: String?,
                             tint: Color,
                             allLabel: String,
                             allCount: Int?,
                             action: @escaping (String?) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.tertiary)
                kindChip(allLabel,
                         count: allCount ?? options.reduce(0) { $0 + $1.count },
                         active: active == nil,
                         tint: tint) {
                    withAnimation(.snappy(duration: 0.18)) { action(nil) }
                }
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    kindChip(option.title,
                             count: option.count,
                             active: active == option.title,
                             tint: tint) {
                        withAnimation(.snappy(duration: 0.18)) { action(option.title) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 9)
        }
    }

    /// 图库的固定类型条：即使某一类本次没有命中，也保留入口与 0 计数。
    private var libraryKinds: [SearchHitKind] {
        [.photo, .video, .album, .folder, .person, .scene, .place]
    }

    private func libraryKindBar(_ section: SearchSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindChip("全部", count: section.total, active: center.activeKind == nil,
                         tint: section.source.tint) {
                    withAnimation(.snappy(duration: 0.18)) { center.activeKind = nil }
                }
                ForEach(libraryKinds, id: \.self) { kind in
                    kindChip(kind.title,
                             count: section.kindCounts[kind] ?? 0,
                             active: center.activeKind == kind,
                             tint: section.source.tint) {
                        withAnimation(.snappy(duration: 0.18)) { center.activeKind = kind }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }

    /// 电视的固定类型条：直播 / 节目两个 tab 始终在场，节目为 0 也保留入口。
    private var televisionKinds: [SearchHitKind] {
        [.channel, .program]
    }

    private func televisionKindBar(_ section: SearchSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindChip("全部", count: section.total, active: center.activeKind == nil,
                         tint: section.source.tint) {
                    withAnimation(.snappy(duration: 0.18)) { center.activeKind = nil }
                }
                ForEach(televisionKinds, id: \.self) { kind in
                    kindChip(kind.title,
                             count: section.kindCounts[kind] ?? 0,
                             active: center.activeKind == kind,
                             tint: section.source.tint) {
                        withAnimation(.snappy(duration: 0.18)) { center.activeKind = kind }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }

    private func kindBar(_ section: SearchSection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindChip("全部", count: section.total, active: center.activeKind == nil,
                         tint: section.source.tint) {
                    withAnimation(.snappy(duration: 0.18)) { center.activeKind = nil }
                }
                ForEach(section.orderedKinds, id: \.self) { kind in
                    kindChip(kind.title,
                             count: section.kindCounts[kind] ?? 0,
                             active: center.activeKind == kind,
                             tint: section.source.tint) {
                        withAnimation(.snappy(duration: 0.18)) { center.activeKind = kind }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
        }
    }

    private func kindChip(_ title: String, count: Int, active: Bool, tint: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                Text(count.formatted())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(active ? tint : Color.secondary)
            }
            .foregroundStyle(active ? tint : Color.primary.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                Capsule(style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color.primary.opacity(0.045))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.45) : Color.primary.opacity(0.07),
                                  lineWidth: 0.6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 通用提示

    private func loadingHint(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }

    private var defaultEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有找到「\(center.query)」")
                .font(.system(size: 13, weight: .semibold))
            Text("换个更短的关键词再试一次。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - 分区标题

struct SearchSectionHeader: View {
    let source: SearchSourceKind
    let count: Int
    var showsMore: Bool = false
    var onMore: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(source.tint.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: source.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(source.tint)
                }
            Text(source.title)
                .font(.system(size: 14, weight: .semibold))
            Text(count.formatted())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if showsMore, let onMore {
                Button(action: onMore) {
                    HStack(spacing: 3) {
                        Text("查看全部")
                            .font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(source.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 命中行

struct SearchHitRow: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    let hit: SearchHit
    let onOpen: (SearchHit) -> Void

    var body: some View {
        HStack(spacing: 11) {
            visual
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let badge = hit.badge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hit.source.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(hit.source.tint.opacity(0.12), in: Capsule(style: .continuous))
            }
            Image(systemName: trailingSymbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hit.source.tint)
                .frame(width: 22, height: 22)
                .background(hit.source.tint.opacity(0.12), in: Circle())
        }
        .searchRowChrome()
        .onTapGesture { onOpen(hit) }
        .help(hit.title)
    }

    private var trailingSymbol: String {
        switch hit.kind {
        case .movie, .series, .channel, .program: return "play.fill"
        default: return "chevron.right"
        }
    }

    @ViewBuilder
    private var visual: some View {
        switch hit.visual {
        case .photo(let photo):
            PhotoThumbnailView(photo: photo, purpose: .cover(64))
                .frame(width: 50, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                }
        case .albumCover(let photo, let style):
            AlbumCoverImage(photo: photo, side: 120, style: style)
                .frame(width: 46, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .avatar(let data, let isPet):
            ZStack {
                Circle().fill(hit.source.tint.opacity(0.18))
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: isPet ? "pawprint.fill" : "person.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(hit.source.tint)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        case .place:
            iconPlate("mappin.and.ellipse")
        case .scene:
            iconPlate("sparkles")
        case .cloudFile(let isVideo):
            iconPlate(isVideo ? "video.fill" : "photo.fill")
        case .cloudFolder:
            iconPlate("folder.fill")
        case .cinemaPoster(let url, let kind):
            CinemaSearchPoster(urlString: url, kind: kind)
        case .channelLogo(let url):
            TVLogoImage(urlString: url,
                        size: CGSize(width: 52, height: 30),
                        cornerRadius: 7)
                .background(Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .catalogCover(let sourceID, let url):
            if let source = catalog.sources.first(where: { $0.id == sourceID }) {
                CatalogArtworkImage(source: source,
                                    urlString: url,
                                    cornerRadius: 7,
                                    quality: .thumbnail)
                    .frame(width: 42, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                iconPlate("safari.fill")
            }
        }
    }

    private func iconPlate(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hit.source.tint.opacity(0.13))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hit.source.tint)
            }
    }
}

/// 影院海报：优先缓存里的封面，没有时用类型色块占位。
struct CinemaSearchPoster: View {
    let urlString: String?
    let kind: CinemaMediaKind

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.30, green: 0.22, blue: 0.16),
                                    Color(red: 0.18, green: 0.14, blue: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: kind == .movie ? "film" : "tv")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: 42, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        }
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else { return }
            if let cached = await CinemaArtworkCache.shared.image(for: urlString, maxPixelSize: 200) {
                image = cached
            }
        }
    }
}

// MARK: - 行样式

private struct SearchRowChrome: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.075 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.22)
                                          : Color.primary.opacity(0.06),
                                  lineWidth: hovering ? 0.9 : 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .animation(.easeOut(duration: 0.13), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func searchRowChrome() -> some View { modifier(SearchRowChrome()) }
}
