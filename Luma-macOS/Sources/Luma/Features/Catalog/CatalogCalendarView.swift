import SwiftUI

/// 更新日历分页：按月拼贴片源的上架 / 更新日期（站点没给时退回本机首次看到），点某天只看当天新片。
///
/// 性能约定：
/// - 聚合结果只在「月份 / 筛选 / 选中日 / 数据量」变化时算一次（`snapshot`），
///   鼠标悬停、滚动、动画都不会重算全表。
/// - 单日条目默认只铺 24 条，其余用「显示更多」分批展开，避免一次创建上千个封面视图。
struct CatalogCalendarView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    /// 可选的来源范围：网络影院只看影视源的更新；网络资源总览不传，等于只看资源站。
    var sourceScope: Set<UUID>? = nil
    /// 当前日历属于哪个模块：只补录这个域的源，两个模块的日历互不混用。
    var domain: CatalogDomain = .networkResource
    /// 紧凑头部：网络影院里工具栏分页已经是标题，不再写一段日历说明。
    var compact: Bool = false
    /// 可选的自定义打开方式：网络影院用它进影院详情页；不传则按网络资源的方式直接起播。
    var onOpenItem: ((CatalogCalendarItem, CatalogSource) -> Void)? = nil

    @State private var month = Date()
    @State private var sourceFilter: UUID?
    @State private var snapshot = MonthSnapshot()
    /// 单日网格一次渲染多少条。
    @State private var dayLimit = 24

    private var calendar: Calendar { Calendar.current }

    /// 实际生效的源范围：调用方没传时按模块兜底，绝不退化成「全部源」。
    private var effectiveScope: Set<UUID> {
        if let sourceScope { return sourceScope }
        return domain == .networkCinema ? catalog.cinemaSourceIDs : catalog.resourceSourceIDs
    }

    /// 当前范围内的源对象。
    private var scopedSources: [CatalogSource] {
        let ids = effectiveScope
        return catalog.sources.filter { ids.contains($0.id) }
    }

    /// 选中的日期跟着模型走：切换分页或重启后都回到上一次选择。
    private var selectedDay: Date? { catalog.calendarSelectedDay }

    /// 最近一次补录新进来的条目：排最前并高亮。
    private var newIDs: Set<String> { Set(catalog.calendarNewIDs) }

    /// 当前来源范围内的日历条目：只统计本模块的源。
    private var scopedItems: [CatalogCalendarItem] {
        let ids = effectiveScope
        return catalog.calendarItems.filter { ids.contains($0.sourceID) }
    }

    /// 聚合缓存的失效条件：任何一项变化才重新遍历日历。
    private struct SnapshotKey: Equatable {
        var monthStart: Date
        var filter: UUID?
        var selectedDay: Date?
        var itemCount: Int
        var firstID: String?
        var lastID: String?
        var newCount: Int
        var sourceCount: Int
    }

    private var snapshotKey: SnapshotKey {
        let items = scopedItems
        return SnapshotKey(monthStart: calendar.dateInterval(of: .month, for: month)?.start ?? month,
                           filter: sourceFilter,
                           selectedDay: selectedDay,
                           itemCount: items.count,
                           firstID: items.first?.id,
                           lastID: items.last?.id,
                           newCount: catalog.calendarNewIDs.count,
                           sourceCount: scopedSources.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                header
                if scopedItems.isEmpty {
                    emptyState
                } else {
                    // 紧凑模式：本月 / 活跃源 / 今天已经写在窗口标题下方，内容区只留最活跃与连续更新。
                    if !compact { statCards }
                    calendarCard
                    if let selectedDay, !snapshot.selectedItems.isEmpty {
                        daySection(selectedDay)
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, compact ? 8 : 14)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.automatic)
        // 聚合只在关键状态变化时跑一次；悬停格子不再触发全表遍历。
        .task(id: snapshotKey) {
            snapshot = makeSnapshot()
        }
        .task {
            if let saved = catalog.calendarSelectedDay {
                month = saved
            } else {
                catalog.selectCalendarDay(Date())
                month = Date()
            }
            // 进来先扫一遍本模块各源首页，把今天新出现的条目补进日历（15 分钟内只扫一次）。
            catalog.refreshCalendarToday(domain: domain)
        }
        .onChange(of: selectedDay) { _, _ in
            dayLimit = 24
        }
        .onChange(of: sourceFilter) { _, _ in
            dayLimit = 24
        }
    }

    // MARK: - 聚合

    private func makeSnapshot() -> MonthSnapshot {
        var snapshot = MonthSnapshot()
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return snapshot }
        let newIDs = self.newIDs
        let selected = selectedDay
        var grouped: [Date: [CatalogCalendarItem]] = [:]
        var selectedFresh: [CatalogCalendarItem] = []
        var selectedOld: [CatalogCalendarItem] = []
        var allDays: Set<Date> = []

        for item in scopedItems {
            if let sourceFilter, item.sourceID != sourceFilter { continue }
            let day = calendar.startOfDay(for: item.firstSeen)
            allDays.insert(day)
            if interval.contains(item.firstSeen) {
                snapshot.monthItems.append(item)
                snapshot.dayCounts[day, default: 0] += 1
                snapshot.sourceCounts[item.sourceID, default: 0] += 1
                if newIDs.contains(item.id) {
                    snapshot.dayNewCounts[day, default: 0] += 1
                }
                grouped[day, default: []].append(item)
            }
            if let selected, calendar.isDate(item.firstSeen, inSameDayAs: selected) {
                snapshot.selectedSourceCounts[item.sourceID, default: 0] += 1
                if newIDs.contains(item.id) {
                    selectedFresh.append(item)
                } else {
                    selectedOld.append(item)
                }
            }
        }

        snapshot.sourcesByID = Dictionary(uniqueKeysWithValues: scopedSources.map { ($0.id, $0) })

        // 每天取最早出现的一条做主封面，其余稳定随机抽 3 张做叠放缩略图。
        for (day, entries) in grouped {
            guard let lead = entries.min(by: { $0.firstSeen < $1.firstSeen }) else { continue }
            var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(day.timeIntervalSince1970))
                                            ^ UInt64(entries.count &* 2654435761))
            let others = Array(entries.filter { $0.id != lead.id }
                .shuffled(using: &generator).prefix(3))
            snapshot.previews[day] = ([lead] + others).compactMap { entry in
                guard let source = snapshot.sourcesByID[entry.sourceID] else { return nil }
                return CalendarPreview(id: "\(entry.sourceID.uuidString)|\(entry.itemID)",
                                       coverURL: entry.coverURL,
                                       source: source)
            }
        }

        snapshot.activeSources = scopedSources
            .filter { snapshot.sourceCounts[$0.id] != nil }
            .sorted { (snapshot.sourceCounts[$0.id] ?? 0) > (snapshot.sourceCounts[$1.id] ?? 0) }

        // 新补录的排最前，其余仍按时间倒序。
        snapshot.selectedItems = selectedFresh.sorted { $0.firstSeen > $1.firstSeen }
            + selectedOld.sorted { $0.firstSeen > $1.firstSeen }
        snapshot.selectedFreshCount = selectedFresh.count
        snapshot.newIDs = newIDs

        // 从今天往前数连续有更新的天数。
        var cursor = calendar.startOfDay(for: Date())
        while allDays.contains(cursor), snapshot.streakDays < 365 {
            snapshot.streakDays += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return snapshot
    }

    // MARK: - 头部

    @ViewBuilder
    private var header: some View {
        if compact {
            // 网络影院：来源筛选与月份切换并成一行，统计卡片紧跟其后，不再留一整行空白。
            HStack(alignment: .center, spacing: 12) {
                if !snapshot.activeSources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            sourceChip(nil, title: "全部")
                            ForEach(snapshot.activeSources) { source in
                                sourceChip(source.id, title: source.name)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .scrollClipDisabled()
                }
                if catalog.isCalendarRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 12)
                if let top = snapshot.activeSources.first {
                    compactStat(symbol: "flame.fill",
                                text: "\(top.name) \(snapshot.sourceCounts[top.id] ?? 0) 条")
                }
                compactStat(symbol: "calendar.badge.clock",
                            text: "连续 \(snapshot.streakDays) 天")
                monthSwitcher
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Text("优先按站点给的上架日期落位；站点没有日期时按本机第一次看到记录。格子背景是当天最早出现的几张封面。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    if catalog.isCalendarRefreshing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("正在补录各源…")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 12)

                    monthSwitcher
                }

                if !snapshot.activeSources.isEmpty {
                    CatalogFlowLayout(spacing: 6, lineSpacing: 6) {
                        sourceChip(nil, title: "全部")
                        ForEach(snapshot.activeSources) { source in
                            sourceChip(source.id, title: source.name)
                        }
                    }
                }
            }
        }
    }

    private var monthSwitcher: some View {
        HStack(spacing: 6) {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("上个月")

            Text(monthTitle(month))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 92)

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("下个月")

            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    month = Date()
                    catalog.selectCalendarDay(Date())
                }
            } label: {
                Text("本月")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color.accentColor.opacity(0.12),
                                in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                catalog.refreshCalendarToday(force: true, domain: domain)
            } label: {
                if catalog.isCalendarRefreshing {
                    ProgressView().controlSize(.mini)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
            }
            .buttonStyle(.plain)
            .help("刷新各源今天的更新")
        }
    }

    private func sourceChip(_ id: UUID?, title: String) -> some View {
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

    // MARK: - 统计

    private var statCards: some View {
        HStack(spacing: 12) {
            statCard("本月新增", "\(snapshot.monthItems.count) 条", symbol: "sparkles")
            statCard("活跃源", "\(snapshot.activeSources.count) 个",
                     symbol: "antenna.radiowaves.left.and.right")
            statCard("最活跃", mostActiveText, symbol: "flame.fill")
            statCard("连续更新", "\(snapshot.streakDays) 天", symbol: "calendar.badge.clock")
            Spacer(minLength: 0)
        }
    }

    /// 紧凑读数：和来源筛选、月份切换同一行，替代整块统计卡片。
    private func compactStat(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func statCard(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, compact ? 8 : 11)
        .frame(minWidth: 118, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        }
    }

    private var mostActiveText: String {
        guard let top = snapshot.activeSources.first else { return "—" }
        return "\(top.name) \(snapshot.sourceCounts[top.id] ?? 0)"
    }

    // MARK: - 月历

    private var calendarCard: some View {
        let days = monthDays(month)
        return VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                      spacing: 6) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let start = calendar.startOfDay(for: day)
                        CalendarDayCell(day: day,
                                        count: snapshot.dayCounts[start] ?? 0,
                                        newCount: snapshot.dayNewCounts[start] ?? 0,
                                        previews: snapshot.previews[start] ?? [],
                                        isSelected: selectedDay.map {
                                            calendar.isDate($0, inSameDayAs: day)
                                        } ?? false,
                                        isToday: calendar.isDateInToday(day),
                                        label: dayLabel(day)) {
                            select(day)
                        }
                    } else {
                        Color.clear.frame(height: 96)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("点某一天查看当天新片")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("背景为当天最早出现的封面；更多内容会随浏览慢慢补进来")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
        }
    }

    private func select(_ day: Date) {
        withAnimation(.easeOut(duration: 0.16)) {
            catalog.selectCalendarDay(day)
        }
        // 选到今天时顺手补一次本模块各源最新，别的日期没有可拉的新数据。
        if calendar.isDateInToday(day) {
            catalog.refreshCalendarToday(domain: domain)
        }
    }

    // MARK: - 当天条目

    private func daySection(_ day: Date) -> some View {
        let items = snapshot.selectedItems
        let visible = items.prefix(dayLimit)
        let remaining = max(0, items.count - dayLimit)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(dayLabel(day))
                    .font(.system(size: 13, weight: .semibold))
                Text(breakdownText(snapshot.selectedSourceCounts))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if snapshot.selectedFreshCount > 0 {
                    Text("新 \(snapshot.selectedFreshCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.red.opacity(0.86), in: Capsule(style: .continuous))
                }
                Spacer()
                Text("\(items.count) 条")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 12)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(visible)) { entry in
                    if let source = snapshot.sourcesByID[entry.sourceID] {
                        itemCell(entry, source: source,
                                 isNew: snapshot.newIDs.contains(entry.id))
                    }
                }
            }
            if remaining > 0 {
                Button {
                    dayLimit += 24
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("显示更多（还有 \(remaining) 条）")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.1),
                                in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
        }
    }

    private func itemCell(_ entry: CatalogCalendarItem, source: CatalogSource,
                          isNew: Bool = false) -> some View {
        Button {
            if let onOpenItem {
                onOpenItem(entry, source)
            } else {
                catalog.playRemote(sourceID: entry.sourceID, item: entry.item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: entry.coverURL,
                                            cornerRadius: 9)
                    }
                    .overlay(alignment: .topLeading) {
                        if isNew {
                            Text("新")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.red.opacity(0.9), in: Capsule(style: .continuous))
                                .shadow(color: Color.red.opacity(0.4), radius: 4, y: 1)
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isNew ? Color.red.opacity(0.55)
                                                : Color.primary.opacity(0.07),
                                          lineWidth: isNew ? 1.1 : 0.6)
                    }
                Text(entry.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isNew ? Color.primary.opacity(0.95)
                                           : Color.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 28, alignment: .topLeading)
                HStack(spacing: 4) {
                    Circle()
                        .fill(source.kind.sidebarTint)
                        .frame(width: 4, height: 4)
                    Text(source.name)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            CatalogPlaylistMenu(source: source, item: entry.item)
        }
        .help(entry.title)
    }

    private func breakdownText(_ counts: [UUID: Int]) -> String {
        scopedSources.compactMap { source in
            counts[source.id].map { "\(source.name) \($0)" }
        }
        .joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
            Text("还没有更新记录")
                .font(.system(size: 15, weight: .semibold))
            Text("浏览任意源的首页后，条目会按站点上架日期（没有日期时按首次看到）记进日历。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: 日期工具

    private func monthDays(_ month: Date) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        var result: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            result.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        return result
    }

    private var weekdayLabels: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private func monthTitle(_ date: Date) -> String {
        Self.monthTitleFormatter.string(from: date)
    }

    private func dayLabel(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return Self.dayLabelFormatter.string(from: day)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            month = next
            catalog.selectCalendarDay(nil)
        }
    }
}

// MARK: - 聚合结果

/// 一帧里用到的全部派生数据：只遍历一次日历，
/// 避免每个子视图各过滤一遍全表，切换分页时卡在主线程。
private struct MonthSnapshot {
    var monthItems: [CatalogCalendarItem] = []
    var dayCounts: [Date: Int] = [:]
    var dayNewCounts: [Date: Int] = [:]
    var previews: [Date: [CalendarPreview]] = [:]
    var sourceCounts: [UUID: Int] = [:]
    var activeSources: [CatalogSource] = []
    var selectedItems: [CatalogCalendarItem] = []
    var selectedSourceCounts: [UUID: Int] = [:]
    var selectedFreshCount = 0
    var streakDays = 0
    var sourcesByID: [UUID: CatalogSource] = [:]
    var newIDs: Set<String> = []
}

/// 日历格里最多铺 4 张封面，一眼看出当天是哪几部。
private struct CalendarPreview: Identifiable {
    var id: String
    var coverURL: String
    var source: CatalogSource
}

// MARK: - 单日格子

/// 悬停状态收在格子里：鼠标划过只重绘这一格，不会让整页重新聚合。
private struct CalendarDayCell: View {
    let day: Date
    let count: Int
    let newCount: Int
    let previews: [CalendarPreview]
    let isSelected: Bool
    let isToday: Bool
    let label: String
    let action: () -> Void

    @State private var hovering = false

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        let lead = previews.first
        let hasContent = lead != nil
        let number = calendar.component(.day, from: day)
        return Button(action: action) {
            ZStack(alignment: .topLeading) {
                // 只用一张主封面铺满，避免多张拼贴在窄格里比例打架。
                if let lead {
                    CatalogArtworkImage(source: lead.source,
                                        urlString: lead.coverURL,
                                        cornerRadius: 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    LinearGradient(colors: [.black.opacity(0.50),
                                            .black.opacity(0.10),
                                            .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                } else {
                    Color.primary.opacity(0.035)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 4) {
                        dateBadge(number: number,
                                  hasContent: hasContent,
                                  highlighted: isSelected || isToday)
                        Spacer(minLength: 0)
                        if count > 0 {
                            countBadge(count, hasContent: hasContent, hasNew: newCount > 0)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .bottom, spacing: 6) {
                        if hovering, hasContent {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                Text("查看")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(.black.opacity(0.48),
                                        in: Capsule(style: .continuous))
                            .transition(.opacity)
                        } else if !hasContent {
                            Capsule()
                                .fill(Color.primary.opacity(0.09))
                                .frame(width: 14, height: 2)
                        }
                        Spacer(minLength: 0)
                        if previews.count > 1 {
                            stackedThumbs(Array(previews.dropFirst()))
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(cellBorder(hasContent: hasContent),
                                  lineWidth: isSelected ? 2 : (hovering ? 1.4 : (isToday ? 1 : 0.6)))
            }
            .shadow(color: hasContent ? .black.opacity(hovering ? 0.28 : 0.16) : .clear,
                    radius: hovering ? 10 : 6,
                    y: hovering ? 5 : 3)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.28) : .clear, radius: 9)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("\(label) · \(count) 条")
    }

    private func dateBadge(number: Int, hasContent: Bool, highlighted: Bool) -> some View {
        Text("\(number)")
            .font(.system(size: 10.5, weight: hasContent || highlighted ? .bold : .regular,
                          design: .rounded))
            .monospacedDigit()
            .foregroundStyle(hasContent || highlighted ? Color.white
                             : Color.secondary.opacity(0.75))
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background {
                if hasContent {
                    Capsule(style: .continuous).fill(.black.opacity(0.42))
                } else if highlighted {
                    Capsule(style: .continuous).fill(Color.accentColor.opacity(0.85))
                }
            }
    }

    private func countBadge(_ count: Int, hasContent: Bool, hasNew: Bool = false) -> some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(hasNew ? Color.white
                                    : (hasContent ? Color.white : Color.accentColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                if hasNew {
                    Capsule(style: .continuous).fill(Color.red.opacity(0.92))
                } else if hasContent {
                    Capsule(style: .continuous).fill(.black.opacity(0.48))
                } else {
                    Capsule(style: .continuous).fill(Color.accentColor.opacity(0.14))
                }
            }
    }

    /// 右下角露出几张叠放的封面，告诉用户这一天不止一条。
    private func stackedThumbs(_ previews: [CalendarPreview]) -> some View {
        HStack(spacing: -7) {
            ForEach(Array(previews.prefix(3).enumerated()), id: \.element.id) { index, preview in
                CatalogArtworkImage(source: preview.source,
                                    urlString: preview.coverURL,
                                    cornerRadius: 4)
                    .frame(width: 19, height: 25)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 0.9)
                    }
                    .zIndex(Double(3 - index))
            }
        }
    }

    private func cellBorder(hasContent: Bool) -> Color {
        if isSelected { return Color.accentColor }
        if hovering { return Color.accentColor.opacity(0.85) }
        if isToday { return Color.primary.opacity(hasContent ? 0.5 : 0.24) }
        return Color.primary.opacity(0.06)
    }
}

/// 稳定的伪随机数：同一天抽到的封面保持一致，只有数据量变化时才重新洗牌。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
