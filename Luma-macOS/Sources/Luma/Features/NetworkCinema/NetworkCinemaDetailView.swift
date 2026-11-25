import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 分集加载失败的两种常见形态：站点 HTTP 错误、页面结构解析失败。
/// 错误文案来自 `CatalogError.errorDescription`，这里只做归类，并把「能怎么办」说清楚。
private struct EpisodeLoadFailure {
    enum Kind {
        case http(Int)
        case parse
        case other
    }

    let kind: Kind
    let message: String

    init(_ message: String) {
        self.message = message
        if message.hasPrefix("站点返回 HTTP "),
           let code = Int(message.dropFirst("站点返回 HTTP ".count)
               .prefix(while: { $0.isNumber })) {
            kind = .http(code)
        } else if message.hasPrefix("页面结构解析失败") {
            kind = .parse
        } else {
            kind = .other
        }
    }

    var badge: String? {
        switch kind {
        case .http(let code): return "HTTP \(code)"
        case .parse: return "解析失败"
        case .other: return nil
        }
    }

    var reason: String {
        switch kind {
        case .http(let code):
            switch code {
            case 401, 403:
                return "站点要求登录或拒绝了本次请求（HTTP \(code)）。可以打开原站确认，或换一个来源。"
            case 404:
                return "这个条目在站点上已经不存在（HTTP 404）。可以回到列表刷新，或换一个来源。"
            case 429:
                return "请求过于频繁，站点暂时限流（HTTP 429）。稍等片刻再重试。"
            case 451:
                return "站点因版权或地区限制拒绝了访问（HTTP 451），这类情况重试通常也不会成功。"
                    + "可以打开原站查看，或换一个来源。"
            case 500...599:
                return "站点服务暂时异常（HTTP \(code)），通常过几分钟会恢复。可以稍后重试，或换一个来源。"
            default:
                return "站点返回 HTTP \(code)，未能读取分集。可以稍后重试，或打开原站确认。"
            }
        case .parse:
            let detail = message.replacingOccurrences(of: "页面结构解析失败：", with: "")
            return "站点页面结构与预期不一致：\(detail)。可能是站点改版或条目资料缺失，"
                + "可以打开原站确认，或换一个来源。"
        case .other:
            return message
        }
    }
}

/// 网络影院的详情页：版式与影院里的影片 / 剧集详情保持一致。
/// 顶部一张档案卡（海报 + 抬头 + 标题 + 动作 + 简介 + 资料网格 + 演职员），
/// 下面是分集网格；网络影院独有的来源站点、原站入口与观看足迹并进同一张卡。
struct NetworkCinemaDetailView: View {
    let entry: NetworkCinemaItem
    @ObservedObject var model: NetworkCinemaModel

    @EnvironmentObject private var store: LibraryStore

    @State private var detail: CatalogDetail?
    @State private var isLoading = true
    @State private var error: String?
    @State private var tmdbDetails: CinemaDetails?
    @State private var doubanRating: Double?
    @State private var showTrailer = false
    @State private var dossierExpanded = false
    @State private var hoveredEpisode: Int?
    /// 演职员二级页：点演员头像进来，返回时回到这部片的详情。
    @State private var personTarget: CinemaCastMember?
    /// 按集缓存 TMDB 单集资料：悬停浮窗用标题 / 简介 / 剧照。
    @State private var episodeInfos: [Int: CinemaEpisodeInfo] = [:]
    @State private var hoverPanelHeight: CGFloat = 320
    /// 统一资料补全器补出的事实（可用线路 / TMDB 评分 / 豆瓣评分）。
    @State private var enrichedFacts: [ContentFact] = []

    // MARK: - 基础信息

    private var enrichment: NetworkCinemaEnrichment? {
        model.enrichment(for: entry)
    }

    private var title: String {
        enrichment?.title ?? entry.item.title
    }

    private var originalTitle: String? {
        guard let value = enrichment?.originalTitle,
              !value.isEmpty,
              value.caseInsensitiveCompare(title) != .orderedSame else { return nil }
        return value
    }

    private var posterURL: String? {
        if let poster = enrichment?.posterURL, !poster.isEmpty { return poster }
        return entry.item.coverURL.isEmpty ? nil : entry.item.coverURL
    }

    private var genres: [String] {
        if let list = enrichment?.genres, !list.isEmpty { return list }
        if let list = tmdbDetails?.genres, !list.isEmpty { return list }
        return []
    }

    private var year: Int? {
        enrichment?.year ?? NetworkCinemaEnrichment.year(in: entry.item.title)
    }

    private var isTV: Bool {
        enrichment?.isTV ?? entry.isTV
    }

    private var overviewText: String? {
        if let text = enrichment?.overview, !text.isEmpty { return text }
        if let text = detail?.blocks.first(where: { $0.kind == .paragraph })?.text,
           !text.isEmpty {
            return text
        }
        return nil
    }

    /// 观看足迹：网络影院独有的「上次看到哪一集、看到多少」。
    private var resumeRecord: CatalogProgress? {
        store.catalog.progress(sourceID: entry.source.id, itemID: entry.item.id)
    }

    /// 还没看完的那一集：有记录时主按钮变成「继续播放」。
    private var resumeEpisode: CatalogEpisode? {
        guard let record = resumeRecord,
              record.fraction > 0.01,
              record.fraction < 0.98,
              let detail else { return nil }
        return detail.episodes.first(where: { $0.index == record.episode })
    }

    private var trailerRequest: CinemaTrailerRequest? {
        // 预告片由豆瓣按片名自己找片源，不依赖 TMDB 是否补全成功：
        // 电影和剧集都该有这个入口。
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CinemaTrailerRequest(title: title,
                                    originalTitle: enrichment?.originalTitle,
                                    year: year,
                                    isTV: isTV)
    }

    var body: some View {
        ZStack {
            detailContent
                .opacity(personTarget == nil && !showTrailer ? 1 : 0)
                .allowsHitTesting(personTarget == nil && !showTrailer)
            if let personTarget {
                NetworkCinemaPersonView(member: personTarget) {
                    withAnimation(.easeOut(duration: 0.16)) { self.personTarget = nil }
                }
                .transition(.opacity)
            }
            if showTrailer, let request = trailerRequest {
                CinemaTrailerOverlay(request: request) {
                    showTrailer = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: personTarget?.id)
        .animation(.easeOut(duration: 0.18), value: showTrailer)
        .background(LumaAmbientBackground(intensity: 0.55))
        .task(id: entry.id) { await loadDetail() }
        .task(id: entry.id) { await loadMetadata() }
        .task(id: episodeInfoKey) { await loadEpisodeInfos() }
    }

    /// 详情主体：顶栏返回与「集卡悬停浮窗」都挂在这一层。
    private var detailContent: some View {
        pageContent
            .overlayPreferenceValue(NetworkEpisodeAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if personTarget == nil, !showTrailer,
                       // 窄窗口下浮层会盖住半张网格：不显示，信息仍在卡片与资料里。
                       proxy.size.width >= 820,
                       let index = hoveredEpisode,
                       let anchor = anchors[index],
                       let episode = detail?.episodes.first(where: { $0.index == index }) {
                        let rect = proxy[anchor]
                        let margin: CGFloat = 12
                        let gap: CGFloat = 14
                        let width = min(380, max(260, proxy.size.width * 0.36))
                        let onRight = rect.maxX + gap + width + margin <= proxy.size.width
                        let rawX = onRight ? rect.maxX + gap : rect.minX - gap - width
                        let x = min(max(margin, rawX),
                                    max(margin, proxy.size.width - width - margin))
                        let y = min(max(margin, rect.minY),
                                    max(margin, proxy.size.height - hoverPanelHeight - margin))
                        episodeHoverCard(episode, width: width)
                            .frame(width: width)
                            .background {
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear { hoverPanelHeight = geo.size.height }
                                        .onChange(of: geo.size.height) { _, value in
                                            hoverPanelHeight = value
                                        }
                                }
                            }
                            .offset(x: x, y: y)
                            .id(episode.index)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                removal: .opacity))
                            .allowsHitTesting(false)
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: hoveredEpisode)
    }

    // MARK: - 页面

    private var pageContent: some View {
        GeometryReader { proxy in
            let horizontal: CGFloat = 24
            let width = max(320, proxy.size.width - horizontal * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    dossierSection(width: width)
                    episodesSection(width: width)
                }
                .padding(.horizontal, horizontal)
                .padding(.top, 22)
                .padding(.bottom, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: - 档案卡

    /// 档案卡：海报作视觉锚点，右侧按「抬头 → 标题 → 动作 → 简介 → 资料」排，
    /// 底部接演职员，和影院详情同一套结构。
    private func dossierSection(width: CGFloat) -> some View {
        let posterWidth = cinemaDetailPosterWidth(for: width)
        return VStack(alignment: .leading, spacing: 0) {
            if width < 760 {
                VStack(alignment: .leading, spacing: 18) {
                    dossierPosterColumn(posterWidth: posterWidth)
                    dossierInfoColumn(width: max(280, width - 44))
                }
                .padding(22)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    dossierPosterColumn(posterWidth: posterWidth)
                    dossierInfoColumn(width: width - 22 * 2 - posterWidth - 24)
                }
                .padding(22)
            }

            if let cast = tmdbDetails?.cast, !cast.isEmpty {
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                castStrip(cast)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            } else if let actors = sourceActorsText {
                // TMDB 没匹配到演职员：先用源站的主演名单兜底，信息不留空。
                Rectangle()
                    .fill(CinemaDetailTone.ink.opacity(0.07))
                    .frame(height: 0.8)
                    .padding(.horizontal, 22)
                sourceCastRow(actors)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
            }
        }
        .background { dossierPlate }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [LumaBrand.amber.opacity(0.30),
                                            CinemaDetailTone.ink.opacity(0.06),
                                            Color.clear],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dossierPlate: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [CinemaDetailTone.ink.opacity(0.062),
                                          CinemaDetailTone.ink.opacity(0.022)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RadialGradient(colors: [LumaBrand.amber.opacity(0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
    }

    /// 海报 + 整部观看进度：进度条是网络影院独有的「上次看到哪里」。
    private func dossierPosterColumn(posterWidth: CGFloat) -> some View {
        VStack(spacing: 9) {
            posterCard(width: posterWidth)

            if let record = resumeRecord, record.fraction > 0.01 {
                VStack(spacing: 4) {
                    ProgressView(value: min(1, record.fraction))
                        .progressViewStyle(.linear)
                        .tint(LumaBrand.amber)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    Text("已看 第 \(record.episode) 集 · \(Int(record.fraction * 100))%")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(width: posterWidth)
            }
        }
        .frame(width: posterWidth, alignment: .top)
    }

    private func posterCard(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: width * 1.5)
            .overlay {
                if let posterURL {
                    if enrichment?.posterURL != nil {
                        CinemaArtwork(urlString: posterURL, maxPixelSize: 900)
                    } else {
                        CatalogArtworkImage(source: entry.source,
                                            urlString: posterURL,
                                            cornerRadius: 14,
                                            quality: .full)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay {
                            Image(systemName: "film")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [LumaBrand.amber.opacity(0.55),
                                                          LumaBrand.amber.opacity(0.16)],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing),
                                  lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.30), radius: 20, y: 10)
    }

    private func dossierInfoColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            dossierKicker
            dossierTitleBlock
            actions
            dossierSynopsis
            factsGrid(width: width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 抬头：档案刻字标签 + 年份 / 季 / 集 + 评分（TMDB / 豆瓣）+ 播出状态。
    private var dossierKicker: some View {
        HStack(spacing: 8) {
            Text(isTV ? "剧集档案" : "影片档案")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(CinemaDetailTone.accent.opacity(0.92))
            Rectangle()
                .fill(LumaBrand.amber.opacity(0.35))
                .frame(width: 24, height: 0.8)
            if !dossierMetaLine.isEmpty {
                Text(dossierMetaLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ratingPill
            statusPill
        }
    }

    private var dossierMetaLine: String {
        var parts: [String] = []
        if let year, year > 0 { parts.append("\(year)") }
        if isTV {
            if let seasons = seasonCountText { parts.append(seasons) }
            if let episodes = episodeCountText { parts.append(episodes) }
        } else if let runtime = cinemaMinutesText(tmdbDetails?.runtime) {
            parts.append(runtime)
        }
        return parts.joined(separator: " · ")
    }

    /// 三源评分：TMDB / 豆瓣，末尾补评分人数；一项都没有时整段不占位。
    @ViewBuilder
    private var ratingPill: some View {
        let tmdb = enrichment?.rating
        let hasTMDB = (tmdb ?? 0) > 0
        let hasDouban = (doubanRating ?? 0) > 0
        if hasTMDB || hasDouban {
            HStack(spacing: 8) {
                if let tmdb, tmdb > 0 {
                    ratingItem(icon: "film.fill", label: "TMDB",
                               value: String(format: "%.1f", tmdb), tint: LumaBrand.violet)
                }
                if hasTMDB && hasDouban {
                    Rectangle()
                        .fill(CinemaDetailTone.ink.opacity(0.12))
                        .frame(width: 0.6, height: 12)
                }
                if let doubanRating, doubanRating > 0 {
                    ratingItem(icon: "leaf.fill", label: "豆瓣",
                               value: String(format: "%.1f", doubanRating), tint: LumaBrand.mint)
                }
                if let votes = enrichment?.voteCount, votes > 0 {
                    Rectangle()
                        .fill(CinemaDetailTone.ink.opacity(0.12))
                        .frame(width: 0.6, height: 12)
                    Text(voteCountText(votes))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
    }

    private func ratingItem(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.50))
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(CinemaDetailTone.ink)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if let status = cinemaStatusText(tmdbDetails?.status) {
            let running = tmdbDetails?.status == "Returning Series"
                || tmdbDetails?.status == "In Production"
                || tmdbDetails?.status == "Planned"
            HStack(spacing: 5) {
                Circle()
                    .fill(running ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.32))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(running ? LumaBrand.mint : CinemaDetailTone.ink.opacity(0.72))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CinemaDetailTone.ink.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
            }
        }
    }

    private var dossierTitleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(CinemaDetailTone.ink)
                .lineLimit(2)
                .textSelection(.enabled)

            if let originalTitle {
                Text(originalTitle.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.42))
                    .lineLimit(1)
            }

            if let tagline = tmdbDetails?.tagline, !tagline.isEmpty {
                Text("「\(tagline)」")
                    .font(.system(size: 12, weight: .medium))
                    .italic()
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                    .lineLimit(2)
            }
        }
    }

    /// 动作：播放 / 从第一集开始 / 预告片 / 稍后看 / 打开原站，末尾是播放源。
    private var actions: some View {
        CinemaBadgeFlow(spacing: 9, lineSpacing: 9) {
            Button {
                playPrimary()
            } label: {
                Label(primaryPlayTitle, systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(LumaBrand.amber, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!contentPolicy.isEnabled(.playItem))

            if resumeEpisode != nil, let first = detail?.episodes.first {
                Button {
                    play(first, fromStart: true)
                } label: {
                    Label("从第 1 集开始", systemImage: "backward.end.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.16), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.94))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            if trailerRequest != nil {
                Button {
                    showTrailer = true
                } label: {
                    Label("预告片", systemImage: "play.rectangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(0.14), in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            if let detail {
                let favorite = store.catalog.isFavorite(sourceID: entry.source.id,
                                                        itemID: entry.item.id)
                Button {
                    store.catalog.setFavorite(!favorite,
                                              source: entry.source,
                                              items: [detail.item])
                } label: {
                    Label(favorite ? "已在稍后看" : "稍后看",
                          systemImage: favorite ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(CinemaDetailTone.ink.opacity(favorite ? 0.22 : 0.14),
                                    in: Capsule())
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(!contentPolicy.isEnabled(.watchlist))
            }

            Button {
                openSourceSite()
            } label: {
                Label("打开原站", systemImage: "safari")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(CinemaDetailTone.ink.opacity(0.14), in: Capsule())
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.92))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!contentPolicy.isEnabled(.openSourceSite))

            sourcePicker
        }
        .padding(.top, 2)
    }

    /// 网络影院条目的命令可用性：统一走 `CommandPolicy`，不在视图里各拼 `.disabled`。
    private var contentPolicy: CommandPolicy {
        let hasEpisodes = !(detail?.episodes.isEmpty ?? true)
        return CommandPolicy(context: CommandContext(
            kind: .catalogSite,
            hasSelection: false,
            hasCommandTargets: hasEpisodes,
            isReadOnlyScope: true,
            isTrash: false,
            canFavorite: false,
            canPlayItem: hasEpisodes,
            canWatchlistItem: detail != nil,
            canOpenSourceSite: detail != nil
        ))
    }

    /// 播放源：同一部片在多个影视源上时，直接在这里换源，不用回列表重新找。
    @ViewBuilder
    private var sourcePicker: some View {
        let list = model.sources(for: entry)
        if list.count > 1 {
            Menu {
                ForEach(list, id: \.id) { variant in
                    Button {
                        guard variant.id != entry.id else { return }
                        store.networkCinemaDetail = variant
                    } label: {
                        Text("\(variant.source.name) · \(healthLabel(variant.source.id))")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(healthColor(entry.source.id))
                        .frame(width: 6, height: 6)
                    Text(entry.source.name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    Text("\(list.count) 个源")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                }
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(CinemaDetailTone.ink.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换播放源：同名影片在其他影视源上的版本")
        } else {
            sourceChip
        }
    }

    private func healthColor(_ sourceID: UUID) -> Color {
        switch store.catalog.health[sourceID] {
        case .offline: return LumaBrand.coral
        case .limited: return LumaBrand.amber
        case .online, .checking, .unknown, .none: return LumaBrand.mint
        }
    }

    private func healthLabel(_ sourceID: UUID) -> String {
        store.catalog.health[sourceID]?.title ?? "未检测"
    }

    /// 来源站点标记：网络影院独有的「这一条来自哪个影视源」。
    private var sourceChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(entry.source.kind.sidebarTint)
                .frame(width: 6, height: 6)
            Text(entry.source.name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
            Text(isTV ? "剧集" : "电影")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(CinemaDetailTone.ink.opacity(0.08), in: Capsule())
        }
        .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(CinemaDetailTone.ink.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(CinemaDetailTone.ink.opacity(0.08), lineWidth: 0.6)
        }
        .fixedSize()
        .help("来自 \(entry.source.name)")
    }

    /// 简介：默认收 5 行，长简介可展开。
    @ViewBuilder
    private var dossierSynopsis: some View {
        if let overview = overviewText, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(overview)
                    .font(.system(size: 12.8))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
                    .lineSpacing(6)
                    .lineLimit(dossierExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if overview.count > 180 {
                    Button(dossierExpanded ? "收起" : "展开全文") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            dossierExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                }
            }
        } else if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取剧情简介…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
            }
        } else {
            Text("这个条目暂时没有简介。")
                .font(.system(size: 12))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
        }
    }

    // MARK: - 资料网格

    private struct NetworkFact: Identifiable {
        let icon: String
        let label: String
        let value: String
        var id: String { label + "|" + value }
    }

    private func factsGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: factsColumns(width: width),
                  alignment: .leading, spacing: 12) {
            ForEach(dossierFacts) { fact in
                HStack(spacing: 9) {
                    Image(systemName: fact.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.accent.opacity(0.90))
                        .frame(width: 24, height: 24)
                        .background(LumaBrand.amber.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.38))
                        Text(fact.value)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CinemaDetailTone.ink.opacity(0.82))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factsColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 12
        let width = width > 0 ? width : 620
        let count = max(1, GridLayout.columns(contentWidth: width, targetSize: 210, spacing: spacing))
        return Array(repeating: GridItem(.flexible(minimum: 120), spacing: spacing), count: count)
    }

    /// 资料项：TMDB 优先，源站结构化信息补齐；同名项不重复占位。
    private var dossierFacts: [NetworkFact] {
        var items: [NetworkFact] = []
        var seen = Set<String>()

        func add(_ icon: String, _ label: String, _ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(label).inserted else { return }
            items.append(NetworkFact(icon: icon, label: label, value: trimmed))
        }

        if let value = cinemaDateText(tmdbDetails?.releaseDate)
            ?? year.map({ "\($0) 年" }) {
            add("calendar", isTV ? "首播" : "上映", value)
        }
        if isTV {
            add("rectangle.stack", "季数", seasonCountText)
            add("list.number", "集数", episodeCountText)
        }
        add("clock", isTV ? "单集" : "片长", cinemaMinutesText(tmdbDetails?.runtime))
        let genreText = genres.prefix(4).joined(separator: " / ")
        if !genreText.isEmpty {
            add("theatermasks", "类型", genreText)
        }
        add("shield.lefthalf.filled", "分级", tmdbDetails?.certification)
        add("character.bubble", "语言", cinemaLanguageName(tmdbDetails?.originalLanguage))
        if let countries = tmdbDetails?.countries, !countries.isEmpty {
            add("globe.asia.australia", "国家",
                countries.prefix(2).map(cinemaCountryName).joined(separator: " / "))
        }
        if let networks = tmdbDetails?.networks, !networks.isEmpty {
            add("antenna.radiowaves.left.and.right", "平台",
                networks.prefix(3).joined(separator: " / "))
        }
        if let companies = tmdbDetails?.companies, !companies.isEmpty {
            add("building.2", "制作", companies.prefix(3).joined(separator: " / "))
        }
        if let id = enrichment?.tmdbID {
            add("number", "TMDB", "\(id)")
        }
        // 网络影院独有：来源站点与类型。
        add("dot.radiowaves.left.and.right", "来源", entry.source.name)
        add("film", "类别", isTV ? "剧集" : "电影")

        // 源站的结构化信息补在后面：上线日期、更新状态、片长、出品、播放量等。
        for fact in detail?.facts ?? [] {
            guard fact.label != "主演", fact.label != "演员" else { continue }
            add(factIcon(for: fact.label), fact.label, fact.value)
        }
        // 统一资料补全器：可用线路、TMDB / 豆瓣评分都从这里来。
        for fact in enrichedFacts {
            add(factIcon(for: fact.label), fact.label, fact.value)
        }
        return items
    }

    private func factIcon(for label: String) -> String {
        switch label {
        case "上线日期", "上映日期": return "calendar"
        case "更新状态", "状态": return "checkmark.seal"
        case "单集片长", "时长", "片长": return "clock"
        case "出品", "制作": return "building.2"
        case "播放次数": return "chart.bar.fill"
        case "收藏": return "heart"
        case "题材类型", "类型": return "theatermasks"
        case "综合评分", "评分", "TMDB 评分", "豆瓣评分": return "star.fill"
        case "可用线路", "来源线路": return "dot.radiowaves.left.and.right"
        default: return "tag"
        }
    }

    private var seasonCountText: String? {
        guard let count = tmdbDetails?.seasonCount, count > 0 else { return nil }
        return count == 1 ? "1 季" : "\(count) 季"
    }

    private var episodeCountText: String? {
        if let total = tmdbDetails?.episodeCount, total > 0 { return "\(total) 集" }
        if let count = detail?.episodes.count, count > 0 { return "\(count) 集" }
        return nil
    }

    private func voteCountText(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f 万人评分", Double(votes) / 10_000)
        }
        return "\(votes) 人评分"
    }

    // MARK: - 演职员

    private var directorText: String? {
        if let list = tmdbDetails?.directors, !list.isEmpty {
            return list.prefix(2).joined(separator: " / ")
        }
        return detail?.facts.first(where: { $0.label == "导演" })?.value
    }

    /// 源站给的主演名单：TMDB 演职员缺失时的兜底。
    private var sourceActorsText: String? {
        detail?.facts.first(where: { $0.label == "主演" || $0.label == "演员" })?.value
    }

    /// 没有 TMDB 头像时的演职员区：只用文字列出主演，不伪造可点的人物页。
    private func sourceCastRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                if let directorText {
                    Text("导演 " + directorText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.78))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func castStrip(_ cast: [CinemaCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text("演职员")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                if let directorText {
                    Text("导演 " + directorText)
                        .font(.system(size: 11))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        castTile(member)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// 与影院演职员卡同一套视觉：圆形头像 + 名字 + 角色，悬停抬起。
    private func castTile(_ member: CinemaCastMember) -> some View {
        CastTileView(member: member) {
            withAnimation(.easeOut(duration: 0.16)) { personTarget = member }
        }
    }

    // MARK: - 分集

    private func episodesSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LumaBrand.amber)
                    .frame(width: 3, height: 14)
                Text(episodesTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                if let label = episodeCountLabel {
                    Text(label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                }
                Spacer(minLength: 8)
                if resumeEpisode != nil {
                    Button("继续播放") { playPrimary() }
                        .controlSize(.small)
                }
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取分集…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                }
                .padding(.vertical, 18)
            } else if let error {
                episodeErrorCard(error)
            } else if let detail, !detail.episodes.isEmpty {
                let grid = episodeGridLayout(width: width)
                LazyVGrid(columns: grid.columns,
                          alignment: .leading, spacing: 18) {
                    ForEach(detail.episodes) { episode in
                        episodeCard(episode,
                                    cardWidth: grid.itemWidth,
                                    isCollection: detail.isCollection)
                            .anchorPreference(key: NetworkEpisodeAnchorKey.self, value: .bounds) {
                                [episode.index: $0]
                            }
                    }
                }
            } else {
                Text("这个条目暂时没有可播放的分集。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.55))
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodesTitle: String {
        if detail?.isCollection == true { return "视频" }
        return isTV ? "剧集" : "播放"
    }

    /// 播放区右上角的数量说明：电影不再写成「1 集」。
    private var episodeCountLabel: String? {
        guard let detail, !detail.episodes.isEmpty else { return nil }
        if detail.isCollection { return "\(detail.episodes.count) 个" }
        if isTV { return "\(detail.episodes.count) 集" }
        return detail.episodes.count == 1 ? "正片" : "\(detail.episodes.count) 个版本"
    }

    /// 集卡网格：列宽固定算出来，卡片按它取 16:9，不会因为某张封面是竖图被撑高。
    private struct EpisodeGridLayout {
        var columns: [GridItem]
        var itemWidth: CGFloat
    }

    private func episodeGridLayout(width: CGFloat) -> EpisodeGridLayout {
        let spacing: CGFloat = 16
        let target: CGFloat = 230
        let count = max(1, Int((max(1, width) + spacing) / (target + spacing)))
        let raw = (max(1, width) - spacing * CGFloat(count - 1)) / CGFloat(count)
        let itemWidth = min(320, max(160, raw))
        return EpisodeGridLayout(
            columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: count),
            itemWidth: itemWidth)
    }

    /// 同名条目在哪些源上有：多个源时，点集卡先选平台再播放。
    private var sourceVariants: [NetworkCinemaItem] {
        model.sources(for: entry)
    }

    private func episodeCard(_ episode: CatalogEpisode,
                             cardWidth: CGFloat,
                             isCollection: Bool) -> some View {
        let hovered = hoveredEpisode == episode.index
        let variants = sourceVariants
        return Group {
            if variants.count > 1 {
                // 同一集不同平台都有：点开先选平台，再按该平台的分集播放。
                Menu {
                    ForEach(variants, id: \.id) { variant in
                        Button {
                            play(episode, using: variant)
                        } label: {
                            Text("\(variant.source.name) · \(healthLabel(variant.source.id))")
                        }
                    }
                    if hasResumeProgress(episode) {
                        Divider()
                        Button("用当前来源从头播放") { play(episode, fromStart: true) }
                    }
                } label: {
                    episodeCardBody(episode,
                                    cardWidth: cardWidth,
                                    isCollection: isCollection,
                                    hovered: hovered)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("选择平台播放\(episodeTitle(episode, isCollection: isCollection))")
            } else {
                Button {
                    play(episode)
                } label: {
                    episodeCardBody(episode,
                                    cardWidth: cardWidth,
                                    isCollection: isCollection,
                                    hovered: hovered)
                }
                .buttonStyle(.plain)
                .help("播放\(episodeTitle(episode, isCollection: isCollection))")
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovering in
            hoveredEpisode = hovering ? episode.index : (hoveredEpisode == episode.index ? nil : hoveredEpisode)
        }
        .contextMenu {
            Button("播放") { play(episode) }
            if sourceVariants.count > 1 {
                Divider()
                ForEach(sourceVariants, id: \.id) { variant in
                    Button("用 \(variant.source.name) 播放") {
                        play(episode, using: variant)
                    }
                }
            }
            if hasResumeProgress(episode) {
                Divider()
                Button("从头播放") { play(episode, fromStart: true) }
            }
        }
    }

    /// 集卡本体：封面 / 集号 / 观看进度 / 悬停播放按钮。
    private func episodeCardBody(_ episode: CatalogEpisode,
                                 cardWidth: CGFloat,
                                 isCollection: Bool,
                                 hovered: Bool) -> some View {
        let fraction = progressFraction(for: episode)
        let isCurrent = fraction != nil
        let statusText: String? = {
            guard let fraction else { return nil }
            return fraction >= 0.98 ? "已看完" : "上次看到 \(Int(fraction * 100))%"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // 封面固定成列宽的 16:9：竖版海报也不会把整张卡撑高。
                episodeArtwork(episode)
                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(fraction.map { $0 >= 0.98 } == true ? 0.70 : 1)

                Text(episodeBadge(episode, isCollection: isCollection))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(7)
            }
            .overlay(alignment: .topLeading) {
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isCurrent ? LumaBrand.amber : Color.white.opacity(0.88))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if let fraction, fraction > 0.01 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            Rectangle()
                                .fill(LumaBrand.amber)
                                .frame(width: max(2.0, geo.size.width * min(1, fraction)))
                        }
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                }
            }
            .overlay(alignment: .center) {
                if hovered {
                    playBadge
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        hovered ? LumaBrand.amber.opacity(0.7)
                            : (isCurrent ? LumaBrand.amber.opacity(0.85)
                                         : Color.primary.opacity(0.08)),
                        lineWidth: hovered ? 1.2 : (isCurrent ? 1.6 : 0.6))
            }
            .shadow(color: hovered ? LumaBrand.amber.opacity(0.25) : .clear,
                    radius: 10, y: 2)

            Text(episodeTitle(episode, isCollection: isCollection))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.88))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func hasResumeProgress(_ episode: CatalogEpisode) -> Bool {
        guard let record = resumeRecord, record.episode == episode.index else { return false }
        return record.fraction > 0.01
    }

    @ViewBuilder
    private func episodeArtwork(_ episode: CatalogEpisode) -> some View {
        if !episode.coverURL.isEmpty {
            CatalogArtworkImage(source: entry.source,
                                urlString: episode.coverURL,
                                cornerRadius: 0,
                                quality: .full)
        } else if let still = episodeInfos[episode.index]?.stillURL, !still.isEmpty {
            // 源站不提供单集封面时，用 TMDB 的本集剧照；加载完成前先落到下面的整片图。
            CinemaArtwork(urlString: still, contentMode: .fill)
        } else if let fallback = episodeFallbackImageURL {
            // 既没有单集封面也没有单集剧照：用整部片的横图铺底，
            // 柔化暗化后把集数压在上面，避免整排集卡都是空色块。
            ZStack {
                CinemaArtwork(urlString: fallback, contentMode: .fill)
                    .blur(radius: 14, opaque: true)
                Color.black.opacity(0.32)
                Text("\(episode.index)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
        } else {
            ZStack {
                LinearGradient(colors: [LumaBrand.violet.opacity(0.30),
                                        LumaBrand.coral.opacity(0.16)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Text("\(episode.index)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
    }

    /// 集卡兜底图：整部片的横图优先，没有横图再退回海报 / 源站封面。
    private var episodeFallbackImageURL: String? {
        if let backdrop = enrichment?.backdropURL, !backdrop.isEmpty { return backdrop }
        if let poster = posterURL, !poster.isEmpty { return poster }
        return nil
    }

    private var playBadge: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.44))
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
                .offset(x: 1)
        }
        .frame(width: 42, height: 42)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private func episodeBadge(_ episode: CatalogEpisode, isCollection: Bool) -> String {
        if isCollection { return "视频 \(episode.index)" }
        if detail?.episodes.count == 1 { return "正片" }
        return "第 \(episode.index) 集"
    }

    private func episodeTitle(_ episode: CatalogEpisode, isCollection: Bool) -> String {
        if let name = episode.name, !name.isEmpty { return name }
        if isCollection { return "视频 \(episode.index)" }
        if detail?.episodes.count == 1 { return "正片" }
        return "第 \(episode.index) 集"
    }

    private func progressFraction(for episode: CatalogEpisode) -> Double? {
        guard let record = resumeRecord,
              record.episode == episode.index,
              record.fraction > 0.01 else { return nil }
        return record.fraction
    }

    // MARK: - 集卡悬停浮窗

    /// 本集资料：TMDB 有单集信息就优先用，没有就用源站给的标题 / 封面。
    private var episodeInfoKey: String {
        guard isTV, detail?.isCollection != true, let id = enrichment?.tmdbID else { return "none" }
        return "\(id)|1"
    }

    private func loadEpisodeInfos() async {
        guard isTV, detail?.isCollection != true, let id = enrichment?.tmdbID else { return }
        if let cached = store.cachedCinemaEpisodeInfos(tvID: id, season: 1) {
            episodeInfos = cached.infos
            if cached.fresh { return }
        }
        guard !Task.isCancelled else { return }
        if let fresh = await store.refreshCinemaEpisodeInfos(tvID: id, season: 1) {
            episodeInfos = fresh
        }
    }

    /// 悬停浮窗：剧照 + 本集标题 / 简介 + 来源、时长与观看进度，和影院集卡的浮窗同一套。
    private func episodeHoverCard(_ episode: CatalogEpisode, width: CGFloat) -> some View {
        let info = episodeInfos[episode.index]
        let isCollection = detail?.isCollection == true
        let heading = (info?.title.isEmpty == false ? info?.title : nil)
            ?? episodeTitle(episode, isCollection: isCollection)
        let fraction = progressFraction(for: episode)
        return VStack(alignment: .leading, spacing: 0) {
            // 悬停卡封面固定 16:9：竖版剧照 / 海报不会把整张卡拉长。
            Color.clear
                .frame(width: width, height: width * 9 / 16)
                .overlay {
                    if let still = info?.stillURL, !still.isEmpty {
                        CinemaArtwork(urlString: still, contentMode: .fill)
                    } else {
                        episodeArtwork(episode)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.66)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(episodeBadge(episode, isCollection: isCollection))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(heading)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CinemaDetailTone.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                if let overview = info?.overview,
                   !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(overview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.72))
                        .lineSpacing(4.5)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(isTV ? "源站没有提供本集简介。" : "悬停即可看到本集资料。")
                        .font(.system(size: 11))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.45))
                }

                HStack(spacing: 6) {
                    hoverFact("dot.radiowaves.left.and.right", entry.source.name)
                    if sourceVariants.count > 1 {
                        hoverFact("square.stack.3d.up", "\(sourceVariants.count) 个平台")
                    }
                    if let duration = episode.duration, !duration.isEmpty {
                        hoverFact("clock", duration)
                    }
                    if let fraction {
                        hoverFact("play.circle",
                                  fraction >= 0.98
                                  ? "已看完"
                                  : "上次看到 \(Int(fraction * 100))%")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)

                HStack(spacing: 5) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 9, weight: .semibold))
                    Text(sourceVariants.count > 1
                         ? "点击选择平台播放 · 右键更多"
                         : (fraction == nil ? "点击播放" : "点击继续播放 · 右键从头播放"))
                        .font(.system(size: 10))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CinemaDetailTone.ink.opacity(0.48))
                .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(CinemaDetailTone.plate)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.26), lineWidth: 0.8)
        }
        .shadow(color: CinemaDetailTone.shadow(0.58), radius: 26, y: 13)
    }

    private func hoverFact(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(CinemaDetailTone.ink.opacity(0.62))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(CinemaDetailTone.ink.opacity(0.07), in: Capsule())
    }

    // MARK: - 动作

    private var primaryPlayTitle: String {
        if let episode = resumeEpisode {
            return detail?.isCollection == true
                ? "继续播放 视频 \(episode.index)"
                : "继续播放 第 \(episode.index) 集"
        }
        if detail?.isCollection == true { return "从第 1 个开始" }
        return isTV ? "从第 1 集播放" : "立即播放"
    }

    private func playPrimary() {
        guard let detail, !detail.episodes.isEmpty else { return }
        if let episode = resumeEpisode {
            play(episode)
        } else {
            play(detail.episodes[0])
        }
    }

    private func play(_ episode: CatalogEpisode,
                      fromStart: Bool = false,
                      using variant: NetworkCinemaItem? = nil) {
        // 指定了别的平台：去那个源取同一集再播，不改当前页的来源。
        if let variant, variant.id != entry.id {
            playFromOtherSource(episode, fromStart: fromStart, variant: variant)
            return
        }
        guard let detail else { return }
        var seconds: Double = 0
        if !fromStart,
           let record = resumeRecord,
           record.episode == episode.index,
           record.fraction > 0.01,
           record.fraction < 0.98 {
            seconds = record.seconds
        }
        store.playCatalog(
            CatalogPlaybackRequest(source: entry.source,
                                   item: detail.item,
                                   episodes: detail.episodes,
                                   startEpisode: episode.index,
                                   startSeconds: seconds,
                                   initialStream: nil)
        )
    }

    /// 用另一个平台播放同一集：拉那个源的分集，集号对不上时退到第一集。
    private func playFromOtherSource(_ episode: CatalogEpisode,
                                     fromStart: Bool,
                                     variant: NetworkCinemaItem) {
        Task {
            do {
                let other = try await model.detail(for: variant)
                guard let target = other.episodes.first(where: { $0.index == episode.index })
                        ?? other.episodes.first else {
                    store.showToast("「\(variant.source.name)」没有这一集")
                    return
                }
                var seconds: Double = 0
                if !fromStart,
                   let record = store.catalog.progress(sourceID: variant.source.id,
                                                       itemID: variant.item.id),
                   record.episode == target.index,
                   record.fraction > 0.01,
                   record.fraction < 0.98 {
                    seconds = record.seconds
                }
                store.playCatalog(
                    CatalogPlaybackRequest(source: variant.source,
                                           item: other.item,
                                           episodes: other.episodes,
                                           startEpisode: target.index,
                                           startSeconds: seconds,
                                           initialStream: nil)
                )
            } catch {
                store.showToast("换平台播放失败：\(error.localizedDescription)")
            }
        }
    }

    private func openSourceSite() {
        let address = detail?.episodes.first?.pageURL ?? entry.source.baseURL
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 分集错误

    /// 分集读取失败：把「HTTP 状态」与「页面结构解析失败」拆成可读的原因，并给出下一步动作。
    private func episodeErrorCard(_ message: String) -> some View {
        let failure = EpisodeLoadFailure(message)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumaBrand.coral)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("分集读取失败")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CinemaDetailTone.ink)
                    if let badge = failure.badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LumaBrand.coral)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(LumaBrand.coral.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                }

                Text(failure.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CinemaDetailTone.ink.opacity(0.66))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if sourceVariants.count > 1 {
                    Text("同一个条目在 \(sourceVariants.count) 个来源上都有，可以切换来源再试。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CinemaDetailTone.ink.opacity(0.5))
                }

                HStack(spacing: 8) {
                    Button("重试") {
                        Task { await loadDetail() }
                    }
                    .controlSize(.small)
                    .help("重新向站点请求分集")
                    Button("打开原站") { openSourceSite() }
                        .controlSize(.small)
                        .help("在浏览器里打开这个条目，确认站点是否可访问")
                    Button("复制错误") { copyError(message) }
                        .controlSize(.small)
                        .help("复制完整错误信息，便于反馈")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LumaBrand.coral.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LumaBrand.coral.opacity(0.22), lineWidth: 0.8)
        }
    }

    private func copyError(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        store.showToast("错误信息已复制")
    }

    // MARK: - 加载

    private func loadDetail() async {
        isLoading = true
        error = nil
        // 换播放源时必须先丢掉上一家的分集：否则新源没回来前点播放，
        // 会把旧源的条目 ID 套到新源地址上。
        detail = nil
        do {
            detail = try await model.detail(for: entry)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMetadata() async {
        let douban = store.metadataSources()
            .first(where: { $0.provider == .douban }) as? DoubanClient
        let result = await model.loadMetadata(for: entry,
                                              tmdb: store.tmdbClient(),
                                              douban: douban)
        tmdbDetails = result.details
        doubanRating = result.douban
        await applyMetadataEnrichment()
    }

    /// 详情补全统一走 `MetadataEnricherCenter`：与本地影院共用一套事实来源。
    private func applyMetadataEnrichment() async {
        let ref = ContentRef(sourceID: .networkCinema, itemID: entry.id)
        let card = ContentCard(ref: ref, title: title)
        let enriched = await store.metadataEnrichers
            .enrich(ContentDetail(card: card), ref: ref, kind: .cinemaFeed)
        enrichedFacts = enriched.facts
    }
}

// MARK: - 演职员卡

/// 与影院演职员卡同一套视觉；点击进入网络影院的演职员页，右键可去 TMDB。
private struct CastTileView: View {
    let member: CinemaCastMember
    let onOpen: () -> Void

    @State private var hovered = false

    private var personURL: URL? {
        guard let id = member.tmdbID else { return nil }
        return URL(string: "https://www.themoviedb.org/person/\(id)")
    }

    private var searchURL: URL? {
        guard let encoded = member.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "https://www.themoviedb.org/search/person?query=\(encoded)")
    }

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let url = member.profileURL, !url.isEmpty {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(hovered
                                          ? AnyShapeStyle(AngularGradient(colors: [LumaBrand.amber,
                                                                                  LumaBrand.coral,
                                                                                  LumaBrand.amber],
                                                                         center: .center))
                                          : AnyShapeStyle(Color.primary.opacity(0.10)),
                                          lineWidth: hovered ? 1.6 : 0.6)
                }
                .shadow(color: LumaBrand.amber.opacity(hovered ? 0.42 : 0),
                        radius: hovered ? 9 : 0, y: 2)
                .scaleEffect(hovered ? 1.06 : 1)
                .offset(y: hovered ? -2 : 0)

                Text(member.name)
                    .font(.system(size: 11, weight: hovered ? .semibold : .medium))
                    .foregroundStyle(hovered ? LumaBrand.amber : Color.primary)
                    .lineLimit(1)
                Text(member.character ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(hovered ? Color.primary.opacity(0.82) : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovered)
        .contextMenu {
            if personURL != nil {
                Button("在 TMDB 查看 \(member.name)") {
                    if let personURL { NSWorkspace.shared.open(personURL) }
                }
            }
            if let searchURL {
                Button("在 TMDB 搜索 \(member.name)") {
                    NSWorkspace.shared.open(searchURL)
                }
            }
        }
        .help("查看 \(member.name) 的人物页")
    }
}

// MARK: - 集卡锚点

/// 集卡在网格里的位置：悬停时把本集档案浮在该卡片旁边，而不是盖住卡片本身。
private struct NetworkEpisodeAnchorKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>],
                       nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
