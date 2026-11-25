import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 继续观看卡片、海报叠层与推荐货架。

// MARK: - 继续观看卡片

struct CinemaContinueCard: View {
    let record: CinemaProgressRecord
    let onOpen: () -> Void

    @State private var hovered = false

    var remainingText: String {
        let minutes = Int(record.remainingSeconds / 60)
        if minutes >= 60 {
            return "还剩 \(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "还剩 \(max(1, minutes)) 分钟"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                CinemaArtwork(urlString: record.artworkURL, contentMode: .fill)
                    .frame(width: 236, height: 133)
                    .clipped()

                LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Text(record.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 12)

                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.94)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(hovered ? 1 : 0.92)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule()
                            .fill(LumaBrand.amber)
                            .frame(width: max(3, geo.size.width * record.fraction))
                    }
                }
                .frame(height: 3)
            }
            .frame(width: 236, height: 133)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? LumaBrand.amber.opacity(0.85)
                                          : Color.white.opacity(0.10),
                                  lineWidth: 1)
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .animation(.easeOut(duration: 0.16), value: hovered)

            HStack(spacing: 6) {
                Text(remainingText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int(record.fraction * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 236)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("查看 \(record.title) 的详情")
    }
}

// MARK: - 详情页海报切换

/// 详情页竖版海报：最多 5 张，像一叠蓝光盒左右翻页。
/// 只有一张时保持原来的静态海报，不出现多余控件；翻页是预览，点「设为封面」才写回索引。
struct CinemaPosterDeck: View {
    let width: CGFloat
    /// 当前已保存的封面；nil 时退回本地缩略图。
    let posterURL: String?
    /// 没有网络海报时的本地兜底：剧集取第一集，影片取文件本身。
    let fallbackPhoto: PhotoItem?
    /// 已匹配 TMDB 才去拉候选，避免没配 Key 的库白跑请求。
    let canLoadMore: Bool
    /// 拉取更多海报；调用方负责按语言 / 评分排序。
    let loadCandidates: () async -> [String]
    /// 「设为封面」：写回索引并停在这张。
    let onApply: (String) -> Void

    @State private var urls: [String] = []
    @State private var index = 0
    @State private var hovered = false

    var inner: CGFloat { max(80, width - 8) }
    var deckHeight: CGFloat { width * 1.5 }
    var currentURL: String? { urls.indices.contains(index) ? urls[index] : posterURL }
    var multiple: Bool { urls.count > 1 }
    /// 匹配状态在详情异步补全后才就绪，所以加载键要同时看封面和「能否拉候选」。
    var reloadKey: String { "\(posterURL ?? "-")#\(canLoadMore)" }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // 后层两张：下一张偏右下、上一张偏左上，形成一叠实体海报的厚度。
                if let next = peekURL(1) {
                    peekCard(next, x: 9, y: 6, scale: 0.962, opacity: 0.50)
                }
                if let previous = peekURL(-1), previous != peekURL(1) {
                    peekCard(previous, x: -8, y: 3, scale: 0.976, opacity: 0.36)
                }
                frontCard
                if multiple {
                    HStack {
                        navButton("chevron.left") { step(-1) }
                        Spacer(minLength: 0)
                        navButton("chevron.right") { step(1) }
                    }
                    .padding(.horizontal, 7)
                }
            }
            .frame(width: width, height: deckHeight)
            .onHover { hovered = $0 }

            if multiple { pager }
            if let url = currentURL, url != posterURL { applyButton(url) }
        }
        .task(id: reloadKey) { await reload() }
    }

    // MARK: 主卡与后层

    var frontCard: some View {
        ZStack {
            if let url = currentURL {
                CinemaArtwork(urlString: url, contentMode: .fill, maxPixelSize: 640)
                    .id(url)
                    .transition(.opacity)
            } else if let fallbackPhoto {
                PhotoThumbnailView(photo: fallbackPhoto, purpose: .cover(400))
            } else {
                CinemaDetailTone.ink.opacity(0.06)
            }
        }
        .frame(width: inner, height: inner * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .padding(4)
        .background(cinemaChampagneFrame,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
    }

    func peekCard(_ url: String,
                          x: CGFloat,
                          y: CGFloat,
                          scale: CGFloat,
                          opacity: Double) -> some View {
        CinemaArtwork(urlString: url, contentMode: .fill, maxPixelSize: 420)
            .frame(width: inner, height: inner * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .padding(4)
            .background(cinemaChampagneFrame,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: x, y: y)
            .blur(radius: 0.7)
            .allowsHitTesting(false)
    }

    func peekURL(_ offset: Int) -> String? {
        guard urls.count > 1 else { return nil }
        let count = urls.count
        let position = ((index + offset) % count + count) % count
        let url = urls[position]
        return url == currentURL ? nil : url
    }

    // MARK: 控件

    func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 25, height: 25)
                .background(.black.opacity(hovered ? 0.58 : 0.36), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(hovered ? 0.34 : 0.18), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0.72)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .help(icon.contains("left") ? "上一张封面" : "下一张封面")
    }

    var pager: some View {
        HStack(spacing: 7) {
            ForEach(urls.indices, id: \.self) { position in
                Button { select(position) } label: {
                    Capsule()
                        .fill(position == index ? LumaBrand.amber
                                                : CinemaDetailTone.ink.opacity(0.20))
                        .frame(width: position == index ? 14 : 5, height: 5)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("第 \(position + 1) 张封面")
            }
            Text("\(index + 1)/\(urls.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                .padding(.leading, 2)
        }
        .animation(.easeOut(duration: 0.18), value: index)
    }

    func applyButton(_ url: String) -> some View {
        Button { onApply(url) } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9, weight: .bold))
                Text("设为封面")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(LumaBrand.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(LumaBrand.amber.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(LumaBrand.amber.opacity(0.35), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .help("把这张设为封面，海报墙与列表同步更新")
    }

    // MARK: 切换与加载

    func step(_ delta: Int) {
        guard urls.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            index = (index + delta + urls.count) % urls.count
        }
        prefetchNeighbors()
    }

    func select(_ position: Int) {
        guard urls.indices.contains(position), position != index else { return }
        withAnimation(.easeInOut(duration: 0.2)) { index = position }
        prefetchNeighbors()
    }

    func prefetchNeighbors() {
        guard urls.count > 1 else { return }
        let count = urls.count
        CinemaArtworkCache.shared.prefetch([urls[(index + 1) % count],
                                            urls[(index - 1 + count) % count]],
                                           maxPixelSize: 640)
    }

    func reload() async {
        var list: [String] = []
        if let posterURL, !posterURL.isEmpty, !list.contains(posterURL) {
            list.append(posterURL)
        }
        if canLoadMore {
            let more = await loadCandidates()
            for url in more where !url.isEmpty && !list.contains(url) {
                list.append(url)
            }
        }
        urls = Array(list.prefix(5))
        index = 0
    }
}

// MARK: - 远程海报

struct CinemaArtwork: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    /// 解码上限（像素）：卡片按列宽量级取图，详情底图再取大一点，避免整张原图常驻内存。
    var maxPixelSize: Int = 800
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                LinearGradient(colors: [Color(nsColor: .quaternaryLabelColor).opacity(0.20),
                                        Color(nsColor: .quaternaryLabelColor).opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                LumaShimmer()
            }
        }
        .task(id: "\(urlString ?? "")|\(maxPixelSize)") {
            guard let urlString else {
                image = nil
                failed = true
                return
            }
            let loaded = await CinemaArtworkCache.shared.image(for: urlString, maxPixelSize: maxPixelSize)
            if let loaded {
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            } else {
                failed = true
            }
        }
    }
}

// MARK: - 相似推荐

/// 推荐卡的位置：悬停档案要贴着卡片显示，又不能被横向滚动区裁掉。
struct CinemaRecommendationAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 相似推荐横条：只展示，点击回本库找同 tmdbID 的条目；悬停显示资料卡。
struct CinemaRecommendationShelf: View {
    let groups: [CinemaRecommendationGroup]
    /// 本库是否已有这部：悬停时给出「本库已有 / 未入库」提示。
    let isLocal: (CinemaRecommendation) -> Bool
    let onOpen: (CinemaRecommendation) -> Void
    let onSearchOnline: (CinemaRecommendation) -> Void
    /// 豆瓣条目：只能外部打开。
    let onOpenExternal: (CinemaRecommendation) -> Void

    @EnvironmentObject private var store: LibraryStore
    /// 悬停项：与演职员头像一致的抬起、琥珀描边、右上角 ↗ 角标。
    @State private var hovered: String?
    @State private var activeSource: CinemaRecommendationGroup.Source?
    /// 悬停时按需补的 TMDB 详情：简介 / 类型 / 评分。
    @State private var hoveredDetails: [String: CinemaDetails] = [:]
    @State private var loadingDetails: Set<String> = []
    /// 悬停档案实测高度：贴底时据此上移。
    @State private var hoverCardHeight: CGFloat = 260

    var activeGroup: CinemaRecommendationGroup? {
        if let activeSource,
           let group = groups.first(where: { $0.source == activeSource }) {
            return group
        }
        return groups.first
    }

    var visibleItems: [CinemaRecommendation] { activeGroup?.items ?? [] }

    @ViewBuilder
    var body: some View {
        if let group = activeGroup {
            VStack(alignment: .leading, spacing: 10) {
                // 标题与 tab 同一行：和「剧集」与季标签的排法一致。
                HStack(alignment: .center, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(LumaBrand.amber)
                        .frame(width: 3, height: 14)
                    Text("相似推荐")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(group.items.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    tabs
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if group.items.isEmpty {
                    emptyGroupHint(group)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(group.items) { item in
                                card(item)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            // 悬停档案挂在横条外层：不会被横向 ScrollView 裁掉。
            .overlayPreferenceValue(CinemaRecommendationAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let id = hovered,
                       let anchor = anchors[id],
                       let item = visibleItems.first(where: { $0.id == id }) {
                        let rect = proxy[anchor]
                        let margin: CGFloat = 8
                        let gap: CGFloat = 12
                        let width = min(330, max(250, proxy.size.width * 0.52))
                        let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                        let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                        let x = min(max(margin, rawX), max(margin, proxy.size.width - width - margin))
                        let y = min(max(0, rect.minY), max(0, proxy.size.height - hoverCardHeight))
                        hoverCard(item)
                            .frame(width: width)
                            .background {
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear { hoverCardHeight = geo.size.height }
                                        .onChange(of: geo.size.height) { _, height in
                                            hoverCardHeight = height
                                        }
                                }
                            }
                            .offset(x: x, y: y)
                            .id(item.id)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onChange(of: hovered) { _, id in
                guard let id, let item = visibleItems.first(where: { $0.id == id }) else { return }
                loadDetailsIfNeeded(item)
            }
        }
    }

    /// 悬停补详情：TMDB 条目按 tmdbID 拉简介；豆瓣条目没有接口，只用已有字段。
    func loadDetailsIfNeeded(_ item: CinemaRecommendation) {
        guard item.doubanID == nil, item.tmdbID > 0,
              hoveredDetails[item.id] == nil,
              !loadingDetails.contains(item.id) else { return }
        loadingDetails.insert(item.id)
        let credit = CinemaPersonCredit(tmdbID: item.tmdbID,
                                        isTV: item.kind == .tv,
                                        title: item.title,
                                        year: item.year,
                                        posterURL: item.posterURL)
        Task {
            let details = await store.cinemaCreditDetails(for: credit)
            if let details { hoveredDetails[item.id] = details }
            loadingDetails.remove(item.id)
        }
    }

    /// 悬停资料卡：与剧集悬停档案同一套深色玻璃 + 琥珀描边。
    func hoverCard(_ item: CinemaRecommendation) -> some View {
        let details = hoveredDetails[item.id]
        let genreText = (details?.genres ?? []).prefix(3).joined(separator: " / ")
        let overview = details?.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rating = details?.rating ?? item.rating
        let loading = loadingDetails.contains(item.id)
        let local = isLocal(item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                CinemaArtwork(urlString: item.posterURL, contentMode: .fill, maxPixelSize: 360)
                    .frame(width: 76, height: 114)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(CinemaDetailTone.ink.opacity(0.10), lineWidth: 0.5)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.kind == .tv ? "剧集" : "电影")
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        if let year = item.year {
                            Text(String(year))
                                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        }
                        if let rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(LumaBrand.amber)
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    if !genreText.isEmpty {
                        Text(genreText)
                            .font(.system(size: 10))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.60))
                            .lineLimit(1)
                    }
                    if let minutes = details?.runtime, minutes > 0 {
                        Text("\(minutes) 分钟")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                    }
                    if loading, overview.isEmpty {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }

            if !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 11))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.82))
                    .lineSpacing(3)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !loading {
                Text(item.doubanID != nil ? "豆瓣条目 · 可在浏览器查看完整资料" : "暂无简介")
                    .font(.system(size: 11))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
            }

            Rectangle()
                .fill(CinemaDetailTone.ink.opacity(0.07))
                .frame(height: 0.6)

            HStack(spacing: 5) {
                Image(systemName: item.doubanID != nil ? "safari" : (local ? "play.rectangle.fill" : "sparkles"))
                    .font(.system(size: 9, weight: .semibold))
                Text(footerText(item, local: local))
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(item.doubanID != nil ? LumaBrand.amber.opacity(0.9)
                                                  : (local ? LumaBrand.mint : LumaBrand.amber.opacity(0.9)))
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(CinemaDetailTone.plate)
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.06),
                                                      CinemaDetailTone.ink.opacity(0.015)],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: CinemaDetailTone.shadow(0.55), radius: 22, y: 10)
    }

    func footerText(_ item: CinemaRecommendation, local: Bool) -> String {
        if item.doubanID != nil { return "豆瓣条目 · 点击在浏览器打开" }
        return local ? "本库已有 · 点击查看详情" : "未入库 · 点击去网络影院"
    }

    var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups) { group in
                    let active = group.source == activeGroup?.source
                    Button {
                        activeSource = group.source
                    } label: {
                        Text("\(group.title) \(group.items.count)")
                            .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? .black : Color.white.opacity(0.72))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(active ? LumaBrand.amber : Color.white.opacity(0.10),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 分组没有内容时的说明行（豆瓣常见：片名没命中或被限流）。
    func emptyGroupHint(_ group: CinemaRecommendationGroup) -> some View {
        HStack(spacing: 7) {
            Image(systemName: group.source == .douban ? "text.magnifyingglass" : "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LumaBrand.amber.opacity(0.80))
            Text(group.source == .douban
                 ? "豆瓣暂时没有相似条目：片名没命中或被限流，稍后再打开详情试试。"
                 : "暂时没有推荐内容")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func card(_ item: CinemaRecommendation) -> some View {
        let active = hovered == item.id
        let local = isLocal(item)
        return Button {
            onOpen(item)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                CinemaArtwork(urlString: item.posterURL, contentMode: .fill, maxPixelSize: 420)
                    .frame(width: 108, height: 162)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(active ? LumaBrand.amber.opacity(0.85) : .white.opacity(0.10),
                                          lineWidth: active ? 1.4 : 0.6)
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 17, height: 17)
                            .background(LumaBrand.amber, in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5) }
                            .padding(6)
                            .scaleEffect(active ? 1 : 0.4)
                            .opacity(active ? 1 : 0)
                            .offset(x: 1.5, y: 1.5)
                    }
                Text(item.title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? LumaBrand.amber : .white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(item.kind == .tv ? "剧集" : "电影")
                        .foregroundStyle(.white.opacity(0.45))
                    if let year = item.year {
                        Text(String(year))
                    }
                    if let rating = item.rating, rating > 0 {
                        Text(String(format: "★ %.1f", rating))
                            .foregroundStyle(LumaBrand.amber.opacity(0.9))
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(active ? .white.opacity(0.72) : .secondary)
                // 悬停时补一行状态：本库已有直接进详情，未入库去网络影院。
                // 常驻占位，悬停时高度不跳。
                Text(local ? "本库已有 · 点击查看" : "未入库 · 点击去网络影院")
                    .font(.system(size: 9))
                    .foregroundStyle(local ? LumaBrand.mint : LumaBrand.amber.opacity(0.9))
                    .lineLimit(1)
                    .opacity(active ? 1 : 0)
            }
            .frame(width: 108, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(active ? 1.03 : 1)
        .offset(y: active ? -2 : 0)
        .shadow(color: LumaBrand.amber.opacity(active ? 0.35 : 0), radius: 9, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: active)
        .onHover { inside in
            if inside {
                hovered = item.id
            } else if hovered == item.id {
                hovered = nil
            }
        }
        .anchorPreference(key: CinemaRecommendationAnchorKey.self, value: .bounds) {
            [item.id: $0]
        }
        .contextMenu {
            if item.doubanID != nil {
                Button("在豆瓣打开「\(item.title)」") { onOpenExternal(item) }
            } else {
                Button("网络影院搜索「\(item.title)」（即将上线）") { onSearchOnline(item) }
            }
        }
        .help("点击查看；右键可在网络影院搜索（即将上线）")
    }
}

// MARK: - 焦点环
