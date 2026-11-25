import SwiftUI

/// 跨源榜单：把各源首页 / 热榜 / 今日新增轮转混排成一张总榜。
/// 顶部是维度切换与数据概览，下面是三甲展台、各源冠军、完整名次与双栏数据。
struct CatalogRankingView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    /// 可选的来源范围：网络影院只统计影视源；网络资源总览不传，等于只看资源站。
    var sourceScope: Set<UUID>? = nil
    /// 当前榜单属于哪个域：两个域各读自己的缓存，互不混入。
    var domain: CatalogDomain = .networkResource
    /// 紧凑头部：网络影院里工具栏分页已经是标题，不再写一段页面说明。
    var compact: Bool = false
    /// 可选的自定义打开方式：网络影院用它进影院详情页；不传则按网络资源的方式直接起播。
    var onOpen: ((UUID, CatalogItem) -> Void)? = nil

    @State private var sourceFilter: UUID?

    private var entries: [CatalogSpotlightItem] {
        catalog.currentSpotlight(in: domain).filter { inScope($0.sourceID) }
    }

    private var isLoading: Bool {
        switch catalog.spotlightMode {
        case .latest: return catalog.isSpotlightLoading
        case .hot: return catalog.isSpotlightHotLoading
        case .todayNew: return false
        }
    }

    private var sourceCount: Int { Set(entries.map(\.sourceID)).count }

    /// 今天与近 7 天的记录量：直接从本机更新日历算，不发请求。
    private var todayCount: Int {
        catalog.todaySpotlight.filter { inScope($0.sourceID) }.count
    }
    private var weekCount: Int {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6,
                                  to: calendar.startOfDay(for: Date())) ?? Date()
        return catalog.calendarItems.filter { inScope($0.sourceID) && $0.firstSeen >= start }.count
    }

    private func inScope(_ sourceID: UUID) -> Bool {
        sourceScope?.contains(sourceID) ?? true
    }

    private func open(_ sourceID: UUID, _ item: CatalogItem) {
        if let onOpen {
            onOpen(sourceID, item)
        } else {
            catalog.playRemote(sourceID: sourceID, item: item)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if entries.isEmpty {
                    emptyState
                } else {
                    podium
                    championStrip
                    rankSection
                    dataSection
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.automatic)
        .task { catalog.loadSpotlight(domain: domain) }
    }

    // MARK: - 头部

    @ViewBuilder
    private var header: some View {
        if compact {
            // 读数已经在窗口标题栏里，内容区只留维度与操作。
            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 12)
                modePicker
                refreshButton
                randomButton
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(catalog.spotlightMode.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text(catalog.spotlightMode == .todayNew
                             ? "本机今天第一次看到的条目，不需要请求站点"
                             : "按源轮转混排，同一屏里能看到各平台的内容")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 12)

                    modePicker
                    refreshButton
                    randomButton
                }

                statChips
            }
        }
    }

    private var statChips: some View {
        HStack(spacing: 8) {
            statChip("\(entries.count)", "条")
            statChip("\(sourceCount)", "个源")
            statChip("\(todayCount)", "今天新增")
            statChip("\(weekCount)", "近 7 天")
            Spacer(minLength: 0)
        }
    }

    private var refreshButton: some View {
        Button {
            catalog.loadSpotlight(force: true, domain: domain)
        } label: {
            if isLoading {
                ProgressView().controlSize(.mini).frame(width: 26, height: 26)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .help("重新汇总各源")
    }

    private var randomButton: some View {
        Button {
            guard let pick = entries.randomElement() else { return }
            open(pick.sourceID, pick.item)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dice.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("随便看看")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.accentColor.opacity(0.13),
                        in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .disabled(entries.isEmpty)
        .help("从当前维度随机播放一部")
    }

    private func statChip(_ value: String, _ caption: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CatalogSpotlightMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        catalog.loadSpotlight(mode: mode, domain: domain)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(catalog.spotlightMode == mode ? Color.white : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        if catalog.spotlightMode == mode {
                            Capsule(style: .continuous).fill(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    // MARK: - 三甲

    private var podium: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("三甲", detail: "各源混排的前 3 名")
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                    if let source = catalog.sources.first(where: { $0.id == entry.sourceID }) {
                        podiumCard(entry, source: source, rank: index + 1)
                    }
                }
            }
        }
    }

    private func podiumCard(_ entry: CatalogSpotlightItem,
                            source: CatalogSource,
                            rank: Int) -> some View {
        let tint = source.kind.sidebarTint
        let rating = ratingText(entry.item.remark)
        return Button {
            open(entry.sourceID, entry.item)
        } label: {
            ZStack(alignment: .topLeading) {
                CatalogArtworkImage(source: source, urlString: entry.item.coverURL, cornerRadius: 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 196)

                LinearGradient(colors: [.black.opacity(0.12),
                                        .black.opacity(0.30),
                                        .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("\(rank)")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(rank == 1 ? Color.black.opacity(0.85) : .white)
                            .frame(width: 30, height: 30)
                            .background {
                                if rank == 1 {
                                    Circle().fill(AnyShapeStyle(LumaBrand.amber))
                                } else {
                                    Circle().fill(.black.opacity(0.42))
                                        .overlay(Circle().strokeBorder(.white.opacity(0.28),
                                                                       lineWidth: 0.8))
                                }
                            }
                        Spacer(minLength: 6)
                        if let rating {
                            ratingBadge(rating, compact: true)
                        }
                        Text(source.name)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.38), in: Capsule(style: .continuous))
                    }

                    Spacer(minLength: 0)

                    Text(entry.item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)

                    HStack(spacing: 5) {
                        Circle().fill(tint).frame(width: 4.5, height: 4.5)
                        Text(entry.item.remark.isEmpty ? "直接播放" : entry.item.remark)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                .padding(13)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(rank == 1 ? LumaBrand.amber.opacity(0.55) : .white.opacity(0.14),
                                  lineWidth: rank == 1 ? 1.2 : 0.7)
            }
            .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(entry.item.title)
    }

    // MARK: - 各源冠军

    private var championStrip: some View {
        let champions = perSourceChampions
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("各源冠军", detail: "\(champions.count) 个源各取首位")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(champions) { entry in
                        if let source = catalog.sources.first(where: { $0.id == entry.sourceID }) {
                            championCard(entry, source: source)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func championCard(_ entry: CatalogSpotlightItem,
                              source: CatalogSource) -> some View {
        let tint = source.kind.sidebarTint
        return Button {
            open(entry.sourceID, entry.item)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .frame(width: 176, height: 99)
                    .overlay {
                        CatalogArtworkImage(source: source,
                                            urlString: entry.item.coverURL,
                                            cornerRadius: 10)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                       startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 3) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 7.5, weight: .bold))
                            Text(source.name)
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.42), in: Capsule(style: .continuous))
                        .padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(entry.item.title)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 7)
                            .padding(.bottom, 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
                    }
                    .help(entry.item.title)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 完整名次

    private var rankSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("完整榜单",
                         detail: sourceFilter == nil ? "第 4 名起" : "已按来源筛选")
            filterChips
            VStack(spacing: 6) {
                ForEach(listEntries, id: \.element.id) { item in
                    if let source = catalog.sources.first(where: { $0.id == item.element.sourceID }) {
                        CatalogRankRow(source: source,
                                       title: item.element.item.title,
                                       coverURL: item.element.item.coverURL,
                                       remark: item.element.item.remark,
                                       rating: ratingText(item.element.item.remark),
                                       rank: item.offset + 1) {
                            open(item.element.sourceID, item.element.item)
                        }
                    }
                }
            }
            if listEntries.isEmpty {
                Text("这个来源暂时没有更多条目")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            }
        }
    }

    /// 未筛选时跳过已出现在三甲里的前 3 名，避免同一批内容重复堆叠。
    private var listEntries: [(offset: Int, element: CatalogSpotlightItem)] {
        let all = Array(entries.enumerated())
        if let sourceFilter {
            return all.filter { $0.element.sourceID == sourceFilter }
        }
        return Array(all.dropFirst(3))
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(nil, title: "全部")
                ForEach(entrySources) { source in
                    filterChip(source.id, title: source.name)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private func filterChip(_ id: UUID?, title: String) -> some View {
        let active = sourceFilter == id
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                sourceFilter = id
            }
        } label: {
            HStack(spacing: 5) {
                if let id, let source = catalog.sources.first(where: { $0.id == id }) {
                    Circle()
                        .fill(source.kind.sidebarTint)
                        .frame(width: 4.5, height: 4.5)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(active ? Color.accentColor : Color.primary.opacity(0.05),
                        in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据

    private var dataSection: some View {
        HStack(alignment: .top, spacing: 14) {
            sourceDistributionCard
                .frame(maxWidth: .infinity)
            weekActivityCard
                .frame(maxWidth: .infinity)
        }
    }

    private var sourceDistributionCard: some View {
        let counts = Dictionary(grouping: entries, by: \.sourceID).mapValues(\.count)
        let ranked = counts
            .compactMap { id, count -> (String, Int, Color)? in
                guard let source = catalog.sources.first(where: { $0.id == id }) else { return nil }
                return (source.name, count, source.kind.sidebarTint)
            }
            .sorted { $0.1 > $1.1 }
        let total = max(1, entries.count)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("来源分布", detail: "\(ranked.count) 个源")
            VStack(spacing: 8) {
                ForEach(Array(ranked.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle().fill(item.2).frame(width: 5, height: 5)
                            Text(item.0)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 88, alignment: .leading)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.05))
                                Capsule()
                                    .fill(LinearGradient(colors: [item.2, item.2.opacity(0.45)],
                                                         startPoint: .leading,
                                                         endPoint: .trailing))
                                    .frame(width: max(4, proxy.size.width * CGFloat(item.1)
                                                      / CGFloat(total)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(item.1)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
            }
        }
    }

    private var weekActivityCard: some View {
        let bars = weekBars
        let peak = max(1, bars.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("近 7 天新增", detail: "来自更新日历")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(bars) { bar in
                        RankingWeekBarView(bar: bar, peak: peak)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
                }
            }
        }
    }

    private var weekBars: [RankingWeekBar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: catalog.calendarItems.filter { inScope($0.sourceID) }) {
            calendar.startOfDay(for: $0.firstSeen)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEEE"
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let isToday = calendar.isDateInToday(day)
            return RankingWeekBar(id: day,
                                  count: grouped[day]?.count ?? 0,
                                  label: isToday ? "今" : formatter.string(from: day),
                                  isToday: isToday)
        }
    }

    // MARK: - 通用

    private var perSourceChampions: [CatalogSpotlightItem] {
        var seen = Set<UUID>()
        var result: [CatalogSpotlightItem] = []
        for entry in entries where seen.insert(entry.sourceID).inserted {
            result.append(entry)
        }
        return result
    }

    private var entrySources: [CatalogSource] {
        var seen = Set<UUID>()
        var result: [CatalogSource] = []
        for entry in entries {
            guard seen.insert(entry.sourceID).inserted,
                  let source = catalog.sources.first(where: { $0.id == entry.sourceID }) else {
                continue
            }
            result.append(source)
        }
        return result
    }

    /// 从备注里抠出评分，例如「更新至 7 集 · 7.9 分」。
    private func ratingText(_ text: String) -> String? {
        guard let range = text.range(of: #"(\d{1,2}(?:\.\d)?)\s*分"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range])
            .replacingOccurrences(of: "分", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func ratingBadge(_ rating: String, compact: Bool = false) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: compact ? 7 : 8))
            Text(rating)
                .font(.system(size: compact ? 9 : 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(LumaBrand.amber)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, 2)
        .background(LumaBrand.amber.opacity(0.14), in: Capsule(style: .continuous))
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LumaBrand.gradient)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView().controlSize(.regular)
                Text("正在汇总各源…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: catalog.spotlightMode.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text(catalog.spotlightMode == .todayNew ? "今天还没有记录到新内容" : "这个维度暂时没有可用内容")
                    .font(.system(size: 14, weight: .semibold))
                Text(catalog.spotlightMode == .todayNew
                     ? "浏览几个源、或在更新日历里补录一次，这里就会出现今天的新内容。"
                     : "检查源是否启用，或点右上角重新汇总。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

/// 名次列表的一行：序号、封面、标题、来源与评分，悬停浮出播放键。
private struct CatalogRankRow: View {
    let source: CatalogSource
    let title: String
    let coverURL: String
    let remark: String
    let rating: String?
    let rank: Int
    let action: () -> Void

    @State private var hovering = false

    private var tint: Color { source.kind.sidebarTint }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(String(format: "%02d", rank))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rank <= 10 ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(rank <= 10 ? Color.accentColor.opacity(0.12)
                                           : Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 用 Color.clear 先占住 16:9 的版面，再把封面铺进 overlay：
                // 直接给 scaledToFill 的图片定 frame，图片会按自身比例撑开、压到相邻行。
                Color.clear
                    .frame(width: 104, height: 58)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: coverURL, cornerRadius: 8)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(hovering ? 1 : 0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Circle().fill(tint).frame(width: 4.5, height: 4.5)
                        Text(source.name)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        if !remark.isEmpty {
                            Text("·")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                            Text(remark)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7.5))
                        Text(rating)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(LumaBrand.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LumaBrand.amber.opacity(0.12), in: Capsule(style: .continuous))
                }

                Image(systemName: hovering ? "play.circle.fill" : "chevron.right")
                    .font(.system(size: hovering ? 19 : 10, weight: .semibold))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 22)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.018),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.35)
                                           : Color.primary.opacity(0.05),
                                  lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// 近 7 天柱状图的一根柱子：今天用品牌渐变，其余用强调色淡底。
private struct RankingWeekBar: Identifiable {
    var id: Date
    var count: Int
    var label: String
    var isToday: Bool
}

private struct RankingWeekBarView: View {
    let bar: RankingWeekBar
    let peak: Int

    private var height: CGFloat {
        max(5, 46 * CGFloat(bar.count) / CGFloat(max(1, peak)))
    }

    private var fillStyle: AnyShapeStyle {
        bar.isToday
            ? AnyShapeStyle(LumaBrand.gradient)
            : AnyShapeStyle(Color.accentColor.opacity(0.3))
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(bar.count > 0 ? "\(bar.count)" : " ")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(height: 11)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fillStyle)
                .frame(height: height)
            Text(bar.label)
                .font(.system(size: 8.5))
                .foregroundStyle(bar.isToday ? Color.accentColor : Color.secondary.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
    }
}
