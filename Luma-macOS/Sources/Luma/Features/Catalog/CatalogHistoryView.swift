import SwiftUI

/// 观看足迹：把「接着看」与按天回看的足迹合成一个独立页面。
/// 从上到下是数据概览、接着看大卡、未看完横轨、这一周的柱状图和胶片时间轴。
struct CatalogHistoryView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore

    /// 可选的来源范围：网络影院只统计影视源的观看记录；网络资源总览不传，等于只看资源站。
    var sourceScope: Set<UUID>? = nil
    /// 当前足迹属于哪个模块：调用方没传范围时按模块兜底，绝不混入另一个域的记录。
    var domain: CatalogDomain = .networkResource
    /// 紧凑头部：网络影院里工具栏分页已经是标题，不再写一遍「观看足迹」与说明。
    var compact: Bool = false

    private let calendar = Calendar.current

    /// 实际生效的源范围。
    private var effectiveScope: Set<UUID> {
        if let sourceScope { return sourceScope }
        return domain == .networkCinema ? catalog.cinemaSourceIDs : catalog.resourceSourceIDs
    }

    /// 足迹的筛选范围：全部 / 未看完 / 已看完。
    private enum Scope: String, CaseIterable, Identifiable {
        case all = "全部"
        case unfinished = "未看完"
        case finished = "已看完"

        var id: String { rawValue }
    }

    @State private var scope: Scope = .all
    /// 在周柱状图上选中的一天：只看这一天的足迹，点第二下取消。
    @State private var selectedDay: Date?
    /// 已经在胶片时间轴里展开全部记录的天。
    @State private var expandedDays: Set<Date> = []
    @State private var showClearConfirm = false

    private var records: [CatalogProgress] {
        let ids = effectiveScope
        return catalog.allContinueWatching.filter { ids.contains($0.sourceID) }
    }
    private var unfinished: [CatalogProgress] { records.filter { $0.fraction < 0.97 } }
    private var finished: [CatalogProgress] { records.filter { $0.fraction >= 0.97 } }
    private var hero: CatalogProgress? { unfinished.first }
    private var railRecords: [CatalogProgress] { Array(unfinished.dropFirst().prefix(12)) }

    private var visibleRecords: [CatalogProgress] {
        switch scope {
        case .all: return records
        case .unfinished: return unfinished
        case .finished: return finished
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summary
                if records.isEmpty {
                    emptyState
                } else {
                    if let hero, let source = source(hero.sourceID) {
                        heroCard(hero, source: source)
                    }
                    if !railRecords.isEmpty {
                        railSection
                    }
                    weekSection
                    filmSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.automatic)
        .alert("清空观看足迹？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { catalog.clearProgress(sourceIDs: effectiveScope) }
        } message: {
            Text("会删除全部 \(records.count) 条播放进度，且无法恢复。")
        }
    }

    // MARK: - 概览

    private var summary: some View {
        let weekCount = records.filter { $0.updatedAt >= weekStart }.count
        let total = records.reduce(0.0) { $0 + max(0, $1.seconds) }
        return VStack(alignment: .leading, spacing: 14) {
            if !compact {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("观看足迹")
                            .font(.system(size: 20, weight: .semibold))
                        Text("这台机器上追过的网络内容，都在这里接着看。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    clearButton
                }
            }
            HStack(spacing: 10) {
                // 紧凑模式：累计观看 / 本周播放已经在窗口标题栏，这里只留进度分布。
                if !compact {
                    statTile("clock.arrow.circlepath", durationText(total), "累计观看", tint: LumaBrand.amber)
                    statTile("calendar", "\(weekCount)", "本周播放", tint: LumaBrand.cyan)
                }
                statTile("play.circle", "\(unfinished.count)", "未看完", tint: LumaBrand.coral)
                statTile("checkmark.circle", "\(finished.count)", "已看完", tint: LumaBrand.mint)
                if compact {
                    Spacer(minLength: 8)
                    clearButton
                }
            }
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if !records.isEmpty {
            Button {
                showClearConfirm = true
            } label: {
                Label("清空记录", systemImage: "trash")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
                    }
            }
            .buttonStyle(.plain)
            .help("删除全部播放进度")
        }
    }

    private func statTile(_ symbol: String, _ value: String,
                          _ caption: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 27, height: 27)
                .background(tint.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.7)
        }
    }

    // MARK: - 接着看

    private func heroCard(_ record: CatalogProgress, source: CatalogSource) -> some View {
        Button {
            catalog.resume(record)
        } label: {
            ZStack(alignment: .bottomLeading) {
                CatalogArtworkImage(source: source, urlString: record.coverURL, cornerRadius: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 26)
                    .scaleEffect(1.12)
                    .opacity(0.6)

                LinearGradient(colors: [.black.opacity(0.18),
                                        .black.opacity(0.55),
                                        .black.opacity(0.9)],
                               startPoint: .top, endPoint: .bottom)

                HStack(alignment: .bottom, spacing: 20) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("接着看")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(2.2)
                            .foregroundStyle(.white.opacity(0.58))
                        Text(record.title)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

                        HStack(spacing: 6) {
                            Circle().fill(source.kind.sidebarTint).frame(width: 5, height: 5)
                            Text(source.name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.72))
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(episodeText(record))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.72))
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(remainingText(record))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.66))
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule().fill(LumaBrand.amber)
                                    .frame(width: max(3, proxy.size.width * record.fraction))
                            }
                        }
                        .frame(width: 320, height: 4)
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("继续播放")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.86))
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(.white, in: Capsule(style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                }
                .padding(24)
            }
            .frame(height: 232)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("继续播放 \(record.title)")
        .contextMenu {
            Button("继续播放") { catalog.resume(record) }
            Button("从头播放") { catalog.restart(record) }
            Divider()
            Button("移出足迹", role: .destructive) { catalog.removeProgress(record) }
        }
    }

    // MARK: - 未看完

    private var railSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("未看完", detail: "\(railRecords.count) 部")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(railRecords, id: \.key) { record in
                        if let source = source(record.sourceID) {
                            HistoryCard(source: source, record: record, width: 200, height: 112,
                                        action: { catalog.resume(record) },
                                        onRestart: { catalog.restart(record) },
                                        onRemove: { remove(record) })
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - 这一周

    private var weekSection: some View {
        let bars = weekBars
        let peak = max(1, bars.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle("这一周",
                             detail: selectedDay.map { "只看 \(dayLabel($0))" } ?? "按播放时间")
                if selectedDay != nil {
                    Button {
                        withAnimation(.snappy) { selectedDay = nil }
                    } label: {
                        Label("清除筛选", systemImage: "xmark.circle.fill")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("显示全部日期")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(bars) { bar in
                    let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: bar.id) } ?? false
                    HistoryWeekBarView(bar: bar, peak: peak,
                                       isSelected: isSelected,
                                       isDimmed: selectedDay != nil && !isSelected) {
                        withAnimation(.snappy) {
                            selectedDay = isSelected ? nil : bar.id
                        }
                    }
                    .frame(maxWidth: 96)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
            }
        }
    }

    private var weekBars: [HistoryWeekBar] {
        let today = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: records) {
            calendar.startOfDay(for: $0.updatedAt)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEEE"
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let isToday = calendar.isDateInToday(day)
            return HistoryWeekBar(id: day,
                                  count: grouped[day]?.count ?? 0,
                                  label: isToday ? "今" : formatter.string(from: day),
                                  isToday: isToday)
        }
    }

    // MARK: - 胶片时间轴

    private var filmSection: some View {
        let groups = filmDays
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle("观看足迹",
                             detail: selectedDay.map { dayLabel($0) } ?? "最近 \(groups.count) 天")
                scopePicker
            }
            VStack(spacing: 0) {
                filmPerforations
                    .padding(.top, 9)
                    .padding(.horizontal, 14)
                if groups.isEmpty {
                    filmEmptyHint
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 0) {
                            ForEach(groups, id: \.day) { group in
                                filmDayGroup(group)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .scrollClipDisabled()
                }
                filmPerforations
                    .padding(.bottom, 9)
                    .padding(.horizontal, 14)
            }
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.045),
                                                  Color.primary.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(Scope.allCases) { item in
                Button {
                    withAnimation(.snappy) {
                        scope = item
                        expandedDays.removeAll()
                    }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 9.5, weight: scope == item ? .semibold : .regular))
                        .foregroundStyle(scope == item ? Color.white : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background {
                            if scope == item {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("只看\(item.rawValue)的足迹")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
    }

    private var filmEmptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(selectedDay == nil ? "这里还没有记录" : "\(dayLabel(selectedDay!)) 没有记录")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            if selectedDay != nil || scope != .all {
                Button {
                    withAnimation(.snappy) {
                        selectedDay = nil
                        scope = .all
                    }
                } label: {
                    Text("显示全部足迹")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filmPerforations: some View {
        // 齿孔按可用宽度动态铺，不能写死 90 个——否则会把整页内容撑得比窗口还宽，
        // 后面几天的柱子和卡片会被挤到视口外面。
        GeometryReader { proxy in
            let step: CGFloat = 24
            let count = max(1, Int(proxy.size.width / step))
            HStack(spacing: step - 11) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 11, height: 4)
                }
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
    }

    private func filmDayGroup(_ group: (day: Date, records: [CatalogProgress])) -> some View {
        let isExpanded = expandedDays.contains(group.day)
        let limit = 3
        let shown = isExpanded ? group.records : Array(group.records.prefix(limit))
        let hidden = group.records.count - shown.count
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(dayLabel(group.day))
                    .font(.system(size: 11, weight: .semibold))
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("\(group.records.count) 部")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(durationText(group.records.reduce(0) { $0 + max(0, $1.seconds) }))
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(shown, id: \.key) { record in
                    if let source = source(record.sourceID) {
                        HistoryCard(source: source, record: record, width: 196, height: 110,
                                    action: { catalog.resume(record) },
                                    onRestart: { catalog.restart(record) },
                                    onRemove: { remove(record) })
                    }
                }
                if hidden > 0 {
                    HistoryMoreTile(count: hidden, height: 110) {
                        withAnimation(.snappy) { _ = expandedDays.insert(group.day) }
                    }
                } else if isExpanded && group.records.count > limit {
                    HistoryMoreTile(count: nil, height: 110) {
                        withAnimation(.snappy) { _ = expandedDays.remove(group.day) }
                    }
                }
            }
        }
        .padding(.trailing, 16)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)
                .padding(.vertical, 28)
        }
    }

    private var filmDays: [(day: Date, records: [CatalogProgress])] {
        let grouped = Dictionary(grouping: visibleRecords) {
            calendar.startOfDay(for: $0.updatedAt)
        }
        let keys: [Date]
        if let selectedDay {
            let day = calendar.startOfDay(for: selectedDay)
            keys = grouped[day] == nil ? [] : [day]
        } else {
            keys = grouped.keys.sorted(by: >)
        }
        return keys.map { day in
            (day, (grouped[day] ?? []).sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    // MARK: - 通用

    private func remove(_ record: CatalogProgress) {
        withAnimation(.snappy) { catalog.removeProgress(record) }
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

    private func source(_ id: UUID) -> CatalogSource? {
        catalog.sources.first(where: { $0.id == id })
    }

    private func episodeText(_ record: CatalogProgress) -> String {
        "第 \(record.episode) 集 · 已看 \(formatTime(record.seconds))"
    }

    private func remainingText(_ record: CatalogProgress) -> String {
        if record.fraction >= 0.98 { return "已看完" }
        let remaining = max(0, record.duration - record.seconds)
        guard remaining > 30 else { return "继续播放" }
        let minutes = Int((remaining / 60).rounded())
        return minutes >= 60 ? "还剩 \(minutes / 60) 小时" : "还剩 \(minutes) 分钟"
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds > 0 ? "不到 1 分钟" : "—" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds.rounded())
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }

    private func dayLabel(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: day)
    }

    private var weekStart: Date {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LumaBrand.amber)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text("还没有观看记录")
                .font(.system(size: 14, weight: .semibold))
            Text(sourceScope == nil
                 ? "在网络资源里播放任意一集，这里会记住进度并排成时间轴。"
                 : "在网络影院的电影 / 电视剧里播放任意一集，这里会记住进度并排成时间轴。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if sourceScope == nil {
                Button {
                    catalog.setHubTab(.browse)
                    store.navigate(to: .catalogSources)
                } label: {
                    Label("去网络资源看看", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            } else {
                Button {
                    store.networkCinemaTab = .movies
                } label: {
                    Label("去看电影", systemImage: "film")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

/// 近 7 天柱状图的一根柱：今天用品牌渐变，其余用低饱和强调色。
private struct HistoryWeekBar: Identifiable {
    var id: Date
    var count: Int
    var label: String
    var isToday: Bool
}

private struct HistoryWeekBarView: View {
    let bar: HistoryWeekBar
    let peak: Int
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var action: () -> Void = {}

    @State private var hovering = false

    private var fill: AnyShapeStyle {
        if isSelected || bar.isToday { return AnyShapeStyle(LumaBrand.gradient) }
        return AnyShapeStyle(Color.accentColor.opacity(0.28))
    }

    private var height: CGFloat {
        let ratio = CGFloat(bar.count) / CGFloat(max(1, peak))
        return max(6, 58 * ratio)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(bar.count > 0 ? "\(bar.count)" : " ")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill)
                    .frame(height: height)
                    .overlay(alignment: .top) {
                        if hovering || isSelected {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(hovering ? 0.16 : 0))
                        }
                    }
                    .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear,
                            radius: 6, y: 2)
                Text(bar.label)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor
                                                : (bar.isToday ? Color.accentColor : Color.secondary))
            }
            .frame(maxWidth: .infinity)
            .opacity(isDimmed ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(bar.count > 0 ? "\(bar.count) 部 · 点击只看这一天" : "这一天没有记录")
    }
}

/// 足迹里的一格：封面 + 进度 + 标题 + 剩余时间。
private struct HistoryCard: View {
    let source: CatalogSource
    let record: CatalogProgress
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    var onRestart: () -> Void = {}
    var onRemove: () -> Void = {}

    @State private var hovering = false

    private var tint: Color { source.kind.sidebarTint }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .frame(width: width, height: height)
                    .overlay {
                        CatalogArtworkImage(source: source,
                                            urlString: record.coverURL,
                                            cornerRadius: 10)
                    }
                    .overlay(alignment: .bottom) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.35))
                                Rectangle()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(2, proxy.size.width * record.fraction))
                            }
                        }
                        .frame(height: 3)
                    }
                    .overlay {
                        if hovering {
                            ZStack {
                                Color.black.opacity(0.22)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.82))
                                    .frame(width: 30, height: 30)
                                    .background(.white.opacity(0.95), in: Circle())
                                    .shadow(color: .black.opacity(0.32), radius: 10, y: 3)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(hovering ? tint.opacity(0.75)
                                                  : Color.primary.opacity(0.08),
                                          lineWidth: hovering ? 1.1 : 0.6)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.24 : 0.12),
                            radius: hovering ? 10 : 5, y: 3)

                Text(record.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovering ? 1 : 0.88))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)

                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 4, height: 4)
                    Text("第 \(record.episode) 集")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(record.fraction >= 0.98 ? "已看完" : "\(Int(record.fraction * 100))%")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(record.title)
        .contextMenu {
            Button("继续播放") { action() }
            Button("从头播放") { onRestart() }
            Divider()
            Button("移出足迹", role: .destructive) { onRemove() }
        }
    }
}

/// 胶片时间轴末尾的「+N 展开」/「收起」小块。
private struct HistoryMoreTile: View {
    /// nil 表示收起按钮。
    let count: Int?
    let height: CGFloat
    let action: () -> Void

    @State private var hovering = false

    private var isCollapse: Bool { count == nil }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: isCollapse ? "chevron.up" : "plus")
                    .font(.system(size: 10, weight: .bold))
                Text(count.map { "+\($0)" } ?? "收起")
                    .font(.system(size: isCollapse ? 9 : 13,
                                  weight: .semibold,
                                  design: .rounded))
                    .monospacedDigit()
                if !isCollapse {
                    Text("展开")
                        .font(.system(size: 8.5))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(hovering ? Color.white : Color.accentColor)
            .frame(width: isCollapse ? 44 : 48, height: isCollapse ? 28 : height)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.accentColor.opacity(0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0 : 0.30),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.accentColor.opacity(hovering ? 0.28 : 0),
                    radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isCollapse ? "收起这一天的其他记录" : "展开当天其余 \(count ?? 0) 条")
    }
}
