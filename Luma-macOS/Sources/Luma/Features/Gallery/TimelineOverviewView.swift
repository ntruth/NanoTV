import AppKit
import SwiftUI

/// 总览卡片的拼图底板：1～4 张照片铺满卡片。
private struct TimelineMosaic: View {
    let photos: [PhotoItem]

    private let gap: CGFloat = 3

    var body: some View {
        let items = Array(photos.prefix(4))
        Group {
            switch items.count {
            case 0:
                Color(nsColor: .quaternaryLabelColor).opacity(0.25)
            case 1:
                cell(items[0])
            case 2:
                HStack(spacing: gap) {
                    cell(items[0])
                    cell(items[1])
                }
            case 3:
                HStack(spacing: gap) {
                    cell(items[0])
                    VStack(spacing: gap) {
                        cell(items[1])
                        cell(items[2])
                    }
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        cell(items[0])
                        cell(items[1])
                    }
                    HStack(spacing: gap) {
                        cell(items[2])
                        cell(items[3])
                    }
                }
            }
        }
    }

    private func cell(_ photo: PhotoItem) -> some View {
        PhotoThumbnailView(photo: photo)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 年/月总览里的一张卡片。
private struct TimelineCard: View {
    let photos: [PhotoItem]
    let title: String
    let subtitle: String
    let width: CGFloat
    let height: CGFloat
    /// 月视图里的「某日」卡片：日期小标签贴在左上角，不随卡片放大。
    var compactTitle = false
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    private var corner: CGFloat { max(10, settings.cardRadius) }
    private var titleSize: CGFloat {
        compactTitle ? 14 : min(34, max(17, height * 0.115))
    }
    private var titleWeight: Font.Weight { compactTitle ? .semibold : .bold }

    /// 卡片上的日期角标：日卡片用高对比胶囊，年卡片用大标题。
    @ViewBuilder
    private var titleOverlay: some View {
        if compactTitle {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .monospacedDigit()
            .contentTransition(.numericText())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.34), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .padding(.horizontal, 10)
            .padding(.top, 10)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: titleSize, weight: titleWeight, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }

    var body: some View {
        // 只把拼图放进 Button；压暗层与日期角标放在 Button 外层叠加，
        // 否则 macOS 的按钮只绘制第一个子视图，标签会整条消失。
        Button(action: action) {
            TimelineMosaic(photos: photos)
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .overlay {
            LinearGradient(colors: [Color.black.opacity(0.62),
                                    Color.black.opacity(0.22),
                                    Color.black.opacity(0)],
                           startPoint: .top,
                           endPoint: .center)
                .allowsHitTesting(false)
        }
        .overlay {
            LinearGradient(colors: [.clear, Color.black.opacity(0.42)],
                           startPoint: .center,
                           endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .overlay {
            if hovering {
                // 悬停玻璃反光：卡片不缩放、不位移，只加一层很轻的受光。
                LinearGradient(colors: [Color.white.opacity(0.14),
                                        .clear,
                                        Color.black.opacity(0.06)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                    .blendMode(.softLight)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) { titleOverlay }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: compactTitle ? 15 : 18))
                .foregroundStyle(.white.opacity(0.78))
                .padding(compactTitle ? 10 : 14)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.88)
                .animation(settings.motion.hover, value: hovering)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                              lineWidth: hovering ? 1 : 0.5)
        }
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.14),
                radius: hovering ? 16 : 7,
                y: hovering ? 9 : 3)
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onHover { hovering = $0 }
        .animation(settings.motion.hover, value: hovering)
        .help(title)
    }
}

private enum TimelineMetrics {
    static let gap: CGFloat = 14
    static let horizontal: CGFloat = 20

    static func columns(contentWidth: CGFloat, minCardWidth: CGFloat) -> Int {
        max(2, Int((contentWidth + gap) / (minCardWidth + gap)))
    }

    static func cardWidth(contentWidth: CGFloat, columns: Int) -> CGFloat {
        max(80, (contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
    }
}

/// 「年」分组：每年一张拼图卡片，点击进入该年的月总览。
struct YearOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    let width: CGFloat

    private var contentWidth: CGFloat { max(280, width - TimelineMetrics.horizontal * 2) }
    private var columns: Int {
        TimelineMetrics.columns(contentWidth: contentWidth, minCardWidth: 340)
    }
    private var cardWidth: CGFloat {
        TimelineMetrics.cardWidth(contentWidth: contentWidth, columns: columns)
    }
    private var cardHeight: CGFloat {
        let zoom = min(2.0, max(0.55, CGFloat(store.thumbSize) / 132))
        return min(520, max(150, cardWidth * 0.64 * zoom))
    }

    var body: some View {
        ScrollView {
            if store.usesSQLOverview {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelineMetrics.gap),
                                         count: columns),
                          spacing: TimelineMetrics.gap) {
                    ForEach(store.yearBuckets) { bucket in
                        TimelineCard(photos: Array(bucket.photos.prefix(4)),
                                     title: bucket.title,
                                     subtitle: "\(bucket.count.formatted()) 个项目",
                                     width: cardWidth,
                                     height: cardHeight) {
                            if let year = Int(bucket.id) {
                                store.openMonths(of: year)
                            }
                        }
                        .id(bucket.id)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, TimelineMetrics.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 28)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelineMetrics.gap),
                                         count: columns),
                          spacing: TimelineMetrics.gap) {
                    ForEach(store.sections) { section in
                        if !section.photos.isEmpty {
                            TimelineCard(photos: Array(section.photos.prefix(4)),
                                         title: section.title ?? "\(section.id)年",
                                         subtitle: "\(section.photos.count.formatted()) 个项目",
                                         width: cardWidth,
                                         height: cardHeight) {
                                if let year = Int(section.id) {
                                    store.openMonths(of: year)
                                }
                            }
                            .id(section.id)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, TimelineMetrics.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .scrollIndicators(.automatic)
        .task(id: store.overviewKey) { store.reloadOverviewIfNeeded() }
        .overlay {
            if store.usesSQLOverview, store.isOverviewLoading, store.yearBuckets.isEmpty {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}

/// 「月」总览里的一天：样本最多 4 张，`count` 是当天真实总数。
private struct MonthDay: Identifiable {
    let id: String
    let title: String
    let count: Int
    let photos: [PhotoItem]
}

/// 「月」分组：按月分段，段内用「首日大卡 + 右侧三张」的拼图展示每一天；
/// 点击某天会切回「所有照片」并定位到那一天。
struct MonthOverviewView: View {
    @EnvironmentObject private var store: LibraryStore
    let width: CGFloat

    private var contentWidth: CGFloat { max(280, width - TimelineMetrics.horizontal * 2) }
    private var columns: Int {
        TimelineMetrics.columns(contentWidth: contentWidth, minCardWidth: 300)
    }
    private var cardWidth: CGFloat {
        TimelineMetrics.cardWidth(contentWidth: contentWidth, columns: columns)
    }
    private var cardHeight: CGFloat {
        let zoom = min(2.0, max(0.55, CGFloat(store.thumbSize) / 132))
        return min(480, max(140, cardWidth * 0.72 * zoom))
    }
    private var gap: CGFloat { TimelineMetrics.gap }
    /// 宽屏时每月用编辑部式拼图：首日大卡 + 右侧三张堆叠；窄屏退回等宽网格。
    private var usesMosaic: Bool { contentWidth >= 560 }

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gap), count: columns)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if store.usesSQLOverview, store.isDirectSystemIndex {
                        directMonthGrid
                    } else if store.usesSQLOverview {
                        ForEach(store.monthGroups) { month in
                            Section {
                                monthBody(month.days.map {
                                    MonthDay(id: $0.id, title: $0.title, count: $0.count, photos: $0.photos)
                                })
                            } header: {
                                SectionHeaderView(title: month.title, count: month.count)
                            }
                            .id(month.id)
                        }
                    } else {
                        ForEach(store.sections) { section in
                            Section {
                                monthBody(dayGroups(in: section.photos))
                            } header: {
                                if let title = section.title {
                                    SectionHeaderView(title: title, count: section.photos.count)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 76)
                }
            }
            .scrollIndicators(.automatic)
            .onAppear { scrollToTarget(proxy) }
            .onChange(of: store.scrollTargetSection) { _, _ in scrollToTarget(proxy) }
            .onChange(of: store.monthGroups.count) { _, _ in scrollToTarget(proxy) }
            .task(id: store.overviewKey) { store.reloadOverviewIfNeeded() }
            .overlay {
                if store.usesSQLOverview, store.isOverviewLoading, store.monthGroups.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                }
            }
        }
    }

    /// 直连模式没有逐天数据：每个月一张卡片，样本取该月最新 4 张。
    private var directMonthGrid: some View {
        LazyVGrid(columns: gridItems, alignment: .leading, spacing: gap) {
            ForEach(store.monthGroups) { month in
                TimelineCard(photos: Array(month.samples.prefix(4)),
                             title: month.title,
                             subtitle: "\(month.count.formatted()) 个项目",
                             width: cardWidth,
                             height: cardHeight,
                             compactTitle: true) {
                    if let first = month.samples.first {
                        store.openAllPhotos(at: first.id)
                    }
                }
                .id(month.id)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, TimelineMetrics.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 26)
    }

    @ViewBuilder
    private func monthBody(_ days: [MonthDay]) -> some View {
        if usesMosaic, days.count >= 4 {
            VStack(spacing: gap) {
                mosaicHero(Array(days.prefix(4)))
                if days.count > 4 {
                    LazyVGrid(columns: gridItems, alignment: .leading, spacing: gap) {
                        ForEach(Array(days.dropFirst(4))) { day in
                            dayCard(day, width: cardWidth, height: cardHeight)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, TimelineMetrics.horizontal)
            .padding(.bottom, 26)
        } else {
            LazyVGrid(columns: gridItems, spacing: gap) {
                ForEach(days) { day in
                    dayCard(day, width: cardWidth, height: cardHeight)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, TimelineMetrics.horizontal)
            .padding(.bottom, 26)
        }
    }

    /// 首日大卡占左侧约 62%，右侧三天等分堆叠，和系统「照片」的月拼图一致。
    private func mosaicHero(_ days: [MonthDay]) -> some View {
        let zoom = min(2.0, max(0.55, CGFloat(store.thumbSize) / 132))
        let heroWidth = max(200, (contentWidth - gap) * 0.62)
        let stackWidth = max(120, contentWidth - gap - heroWidth)
        let heroHeight = min(560, max(240, heroWidth * 0.52 * zoom))
        let stackCardHeight = max(76, (heroHeight - gap * 2) / 3)
        return HStack(alignment: .top, spacing: gap) {
            dayCard(days[0], width: heroWidth, height: heroHeight)
            VStack(spacing: gap) {
                ForEach(Array(days[1...3])) { day in
                    dayCard(day, width: stackWidth, height: stackCardHeight)
                }
            }
        }
    }

    private func dayCard(_ day: MonthDay, width: CGFloat, height: CGFloat) -> some View {
        // 月份已由分区标题给出，卡片角标只显示「日」，并放大字号。
        return TimelineCard(photos: Array(day.photos.prefix(4)),
                            title: day.title,
                            subtitle: "\(day.count) 张",
                            width: width,
                            height: height,
                            compactTitle: true) {
            if let first = day.photos.first {
                store.openAllPhotos(at: first.id)
            }
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = store.scrollTargetSection else { return }
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(target, anchor: .top)
            }
            store.scrollTargetSection = nil
        }
    }

    private func dayGroups(in photos: [PhotoItem]) -> [MonthDay] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        var titles: [String: String] = [:]
        for photo in photos {
            let parts = calendar.dateComponents([.year, .month, .day], from: photo.capturedAt)
            let key = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
                titles[key] = "\(parts.day ?? 0)日"
            }
            buckets[key]?.append(photo)
        }
        return order.compactMap { key in
            guard let items = buckets[key], let title = titles[key] else { return nil }
            return MonthDay(id: key, title: title, count: items.count, photos: items)
        }
    }
}
