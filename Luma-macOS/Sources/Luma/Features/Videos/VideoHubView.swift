import SwiftUI
import AppKit

// MARK: - 页面

struct VideoHubView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var previewingID: UUID?
    @State private var collapsedGroups: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @State private var collapsedShelves: Set<String> = []
    @State private var collapsedDays: Set<String> = []

    private static let groupPageSize = 120

    private var data: VideoHubData { store.videoHubData }
    private var dimension: VideoHubDimension { store.videoHubDimension }
    private var layout: VideoHubLayout { store.videoHubLayout }

    var body: some View {
        ZStack {
            LumaAmbientBackground(intensity: 0.55)
            content
        }
        .onAppear {
            store.refreshVideoHubIfNeeded(force: true)
        }
        .onChange(of: store.visibleStateKey) { _, _ in
            store.refreshVideoHubIfNeeded()
        }
        .onChange(of: store.localPeople.count) { _, _ in
            store.refreshVideoHubIfNeeded()
        }
        .onChange(of: store.systemPeople.count) { _, _ in
            store.refreshVideoHubIfNeeded()
        }
        .onChange(of: store.sidebarItem) { _, _ in
            store.videoHubDimension = .featured
            store.videoHubLayout = .wall
            store.videoHubFilter = VideoHubFilter()
            previewingID = nil
            store.refreshVideoHubIfNeeded(force: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if data.videos.isEmpty {
            if store.isPagedWindowLoading {
                loadingState
            } else if store.videoHubFilter.isActive {
                filteredEmptyState
            } else {
                emptyState
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Color.clear
                            .frame(height: 0)
                            .id("videoHubTop")
                        if dimension == .featured, layout == .wall {
                            hero
                        }
                        statsRow
                        if layout == .wall {
                            dimensionBar
                            if dimension == .featured {
                                rails
                            }
                            groupedWall
                        } else {
                            timeline
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
                    .padding(.bottom, 70)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .onChange(of: store.videoHubFilter) { _, _ in
                    withAnimation(settings.motion.layout) {
                        proxy.scrollTo("videoHubTop", anchor: .top)
                    }
                }
                .onChange(of: store.videoHubLayout) { _, _ in
                    withAnimation(settings.motion.layout) {
                        proxy.scrollTo("videoHubTop", anchor: .top)
                    }
                }
                .onChange(of: store.videoHubDimension) { _, _ in
                    withAnimation(settings.motion.layout) {
                        proxy.scrollTo("videoHubTop", anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - 首屏

    @ViewBuilder
    private var hero: some View {
        if let photo = data.videos.first {
            VideoHeroCard(photo: photo) {
                store.openViewer(photo.id, context: data.videos)
            }
        }
    }

    // MARK: - 统计

    private var statsRow: some View {
        let loaded = data.videos.count
        let loading = store.isVideoHubLoading && store.videoHubFullVideos.isEmpty
        let total = store.videoHubFilter.isActive
            ? loaded
            : max(store.visibleCount, loaded)
        let detail: String
        if store.videoHubFilter.isActive {
            detail = "筛选结果"
        } else if loading {
            detail = "正在汇总整库…"
        } else {
            detail = "全部视频"
        }
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 340), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            statCard(title: "视频总数",
                     value: total.formatted(),
                     unit: "段",
                     detail: detail)
            statCard(title: "总时长",
                     value: loading ? "正在汇总…" : videoHubTotalDurationText(data.videos),
                     unit: nil,
                     detail: loading ? "读取视频元数据" : averageDurationText)
            statCard(title: "最近 30 天",
                     value: loading ? "—" : "+\(data.recentCount.formatted())",
                     unit: loading ? nil : "段",
                     detail: "按添加时间")
            statCard(title: "最长影像",
                     value: loading ? "—" : (data.longest?.duration.map(formatDuration) ?? "—"),
                     unit: nil,
                     detail: loading ? "等待汇总" : (data.longest.map(videoHubHeadline) ?? "还没有可统计的时长"))
        }
    }

    private var averageDurationText: String {
        let durations = data.videos.compactMap(\.duration).filter { $0 > 0 }
        guard !durations.isEmpty else { return "时长未知" }
        let average = durations.reduce(0, +) / Double(durations.count)
        return "平均 \(formatDuration(average))"
    }

    private func statCard(title: String, value: String, unit: String?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.06),
                                              Color.primary.opacity(0.02)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
        }
    }

    // MARK: - 维度

    private var dimensionEntries: [(VideoHubDimension, Int)] {
        [
            (.featured, data.videos.count),
            (.years, data.years.count),
            (.duration, data.durations.count),
            (.places, data.places.count),
            (.people, data.people.count)
        ]
    }

    private var dimensionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("视角")
                    .font(.system(size: 10.5))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
                ForEach(dimensionEntries, id: \.0) { entry in
                    dimensionChip(entry.0, count: entry.1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func dimensionChip(_ item: VideoHubDimension, count: Int) -> some View {
        let active = dimension == item
        return Button {
            withAnimation(settings.motion.layout) { store.videoHubDimension = item }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(item.title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                Text(count.formatted())
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(active ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.28),
                                                      Color.accentColor.opacity(0.10)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.45)
                                         : Color.primary.opacity(0.06),
                                  lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 轨道

    @ViewBuilder
    private var rails: some View {
        if !data.recent.isEmpty {
            shelf(title: "最近添加", note: "按添加时间", items: data.recent)
        }
        if !data.long.isEmpty {
            shelf(title: "值得重看", note: "超过 3 分钟", items: data.long)
        }
        if !data.situations.isEmpty {
            shelf(title: "情境影像", note: "录屏 · 慢动作 · 延时", items: data.situations)
        }
    }

    private func shelf(title: String, note: String, items: [PhotoItem]) -> some View {
        let collapsed = collapsedShelves.contains(title)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(settings.motion.layout) {
                    if collapsed {
                        _ = collapsedShelves.remove(title)
                    } else {
                        _ = collapsedShelves.insert(title)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                    countBadge(items.count)
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开\(title)" : "收起\(title)")

            if !collapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { photo in
                            VideoCard(photo: photo,
                                      context: data.videos,
                                      aspect: 16.0 / 9.0,
                                      previewingID: $previewingID)
                                .frame(width: videoRailWidth)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .padding(.horizontal, -2)
            }
        }
    }

    private var videoCardMinWidth: CGFloat {
        max(170, min(320, CGFloat(store.thumbSize) * 1.45))
    }

    private var videoRailWidth: CGFloat {
        max(190, min(320, CGFloat(store.thumbSize) * 1.7))
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count) 段")
            .font(.system(size: 9.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }

    // MARK: - 分组墙

    private var activeGroups: [VideoGroup] {
        switch dimension {
        case .featured, .years: return data.years
        case .duration: return data.durations
        case .places: return data.places
        case .people: return data.people
        }
    }

    @ViewBuilder
    private var groupedWall: some View {
        if activeGroups.isEmpty {
            Text("这个维度还没有可展示的视频。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
        } else {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(activeGroups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        groupHeader(group)
                        if !collapsedGroups.contains(group.id) {
                            let items = visibleGroupItems(group)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: videoCardMinWidth,
                                                             maximum: videoCardMinWidth * 1.7),
                                                   spacing: 16)],
                                alignment: .leading,
                                spacing: 18
                            ) {
                                ForEach(items) { photo in
                                    VideoCard(photo: photo,
                                              context: data.videos,
                                              aspect: 4.0 / 3.0,
                                              previewingID: $previewingID)
                                }
                            }
                            if items.count < group.videos.count {
                                Button {
                                    withAnimation(settings.motion.layout) {
                                        _ = expandedGroups.insert(group.id)
                                    }
                                } label: {
                                    Text("展开全部 \(group.videos.count.formatted()) 段")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func visibleGroupItems(_ group: VideoGroup) -> [PhotoItem] {
        expandedGroups.contains(group.id)
            ? group.videos
            : Array(group.videos.prefix(Self.groupPageSize))
    }

    private func groupHeader(_ group: VideoGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        return Button {
            withAnimation(settings.motion.layout) {
                if collapsed {
                    _ = collapsedGroups.remove(group.id)
                } else {
                    _ = collapsedGroups.insert(group.id)
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(group.title)
                    .font(.system(size: 19, weight: .semibold))
                countBadge(group.videos.count)
                Text(group.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.12), .clear],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "展开 \(group.title)" : "收起 \(group.title)")
    }

    // MARK: - 时间轴

    private var dayGroups: [VideoGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: data.videos) {
            calendar.startOfDay(for: $0.capturedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            let items = (grouped[day] ?? []).sorted { $0.capturedAt > $1.capturedAt }
            return VideoGroup(id: "day-\(day.timeIntervalSince1970)",
                              title: Self.dayTitleFormatter.string(from: day),
                              detail: Self.weekdayFormatter.string(from: day),
                              videos: items)
        }
    }

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(dayGroups) { group in
                let collapsed = collapsedDays.contains(group.id)
                HStack(alignment: .top, spacing: 14) {
                    Button {
                        withAnimation(settings.motion.layout) {
                            if collapsed {
                                _ = collapsedDays.remove(group.id)
                            } else {
                                _ = collapsedDays.insert(group.id)
                            }
                        }
                    } label: {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 3) {
                                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text(group.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .monospacedDigit()
                            }
                            Text(group.detail)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                            countBadge(group.videos.count)
                        }
                        .frame(width: 82, alignment: .trailing)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "展开 \(group.title)" : "收起 \(group.title)")

                    if collapsed {
                        Rectangle()
                            .fill(LinearGradient(colors: [Color.primary.opacity(0.10), .clear],
                                                 startPoint: .leading,
                                                 endPoint: .trailing))
                            .frame(height: 1)
                            .padding(.top, 12)
                    } else {
                        VStack(spacing: 0) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .padding(.top, 8)
                            Rectangle()
                                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                                              Color.primary.opacity(0.04)],
                                                     startPoint: .top,
                                                     endPoint: .bottom))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(width: 8)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: max(140, videoCardMinWidth * 0.85),
                                                         maximum: videoCardMinWidth * 1.4),
                                               spacing: 12)],
                            alignment: .leading,
                            spacing: 14
                        ) {
                            ForEach(group.videos) { photo in
                                VideoCard(photo: photo,
                                          context: data.videos,
                                          aspect: 16.0 / 9.0,
                                          previewingID: $previewingID)
                            }
                        }
                    }
                }
            }
        }
    }

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    // MARK: - 状态

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在整理视频…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 88, height: 88)
                Image(systemName: "video.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("还没有视频")
                .font(.system(size: 17, weight: .semibold))
            Text("导入视频，或连接包含视频的系统图库后，这里会按年份、时长、地点与人物自动整理。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有符合条件的视频")
                .font(.system(size: 17, weight: .semibold))
            Text("换一个年份或时长，或者清除筛选看全部影像。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("清除筛选") {
                store.videoHubFilter = VideoHubFilter()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 首屏卡片

private struct VideoHeroCard: View {
    let photo: PhotoItem
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            ZStack(alignment: .topLeading) {
                GeometryReader { proxy in
                    PhotoThumbnailView(photo: photo,
                                       purpose: .cover(max(900, proxy.size.width)))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.58), location: 0),
                        .init(color: .black.opacity(0.18), location: 0.42),
                        .init(color: .black.opacity(0.72), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center,
                               endPoint: .bottom)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        liveBadge
                        Spacer(minLength: 8)
                        ForEach(Array(heroSpecTags.enumerated()), id: \.offset) { _, tag in
                            heroTag(tag)
                        }
                    }
                    Spacer(minLength: 0)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 28) {
                            heroCopy
                            Spacer(minLength: 0)
                            infoPanel
                        }
                        heroCopy
                    }
                }
                .padding(22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 348)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放 \(videoHubHeadline(photo))")
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LumaBrand.amber)
                .frame(width: 5, height: 5)
            Text("最近放映")
                .font(.system(size: 10))
                .tracking(0.8)
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.34), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
        }
    }

    private func heroTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.34), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
            }
    }

    private var heroSpecTags: [String] {
        var tags: [String] = []
        if let resolution = videoResolution(photo) {
            tags.append(resolution)
        }
        if let codec = photo.videoCodec, !codec.isEmpty {
            tags.append(codec.uppercased())
        } else {
            let ext = (photo.originalName as NSString).pathExtension.uppercased()
            if !ext.isEmpty { tags.append(ext) }
        }
        if photo.isFavorite {
            tags.append("已收藏")
        }
        return tags
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(videoHubDatePlace(photo))
                .font(.system(size: 10.5))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Text(videoHubHeadline(photo))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 7) {
                ForEach(Array(videoSpecChips(photo).enumerated()), id: \.offset) { _, chip in
                    Text(chip)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                        }
                }
            }
            HStack(spacing: 11) {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("播放")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.white.opacity(0.94), in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
                if let duration = photo.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 540, alignment: .leading)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("影像信息")
                    .font(.system(size: 9.5))
                    .tracking(1.2)
                Spacer(minLength: 8)
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.white.opacity(0.48))
            .padding(.bottom, 8)
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
                .padding(.bottom, 2)
            infoRow("设备", photo.model ?? photo.make ?? "—")
            infoRow("编码", heroCodec)
            infoRow("大小", formatFileSize(photo.fileSize))
            infoRow("分辨率", videoResolution(photo) ?? "—")
        }
        .frame(width: 212)
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.black.opacity(0.26))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
        }
    }

    private var heroCodec: String {
        if let codec = photo.videoCodec, !codec.isEmpty {
            return codec.uppercased()
        }
        let ext = (photo.originalName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "—" : ext
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.42))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 视频卡片

private struct VideoCard: View {
    let photo: PhotoItem
    let context: [PhotoItem]
    var aspect: CGFloat = 4.0 / 3.0

    @Binding var previewingID: UUID?

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var previewHandle = VideoPreviewHandle()
    @State private var previewProgress: Double = 0

    private var isPreviewing: Bool { previewingID == photo.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumbnail
            Text(videoHubDatePlace(photo))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .onHover(perform: handleHover)
        .contextMenu {
            Button("播放") { open() }
            if store.canToggleFavorite {
                Button(photo.isFavorite ? "取消收藏" : "收藏") {
                    store.toggleFavorite(photo.id)
                }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            if previewingID == photo.id {
                previewingID = nil
                previewProgress = 0
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            GeometryReader { proxy in
                PhotoThumbnailView(photo: photo,
                                   purpose: .cover(max(180, proxy.size.width)))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }

            if isPreviewing, let url = previewURL {
                HoverVideoSurface(url: url, handle: previewHandle) { value in
                    previewProgress = value
                }
                .transition(.opacity)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.52)],
                           startPoint: .center,
                           endPoint: .bottom)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    if let tag = videoTag(photo) {
                        cardBadge(tag)
                    }
                    Spacer(minLength: 4)
                    if isPreviewing {
                        cardBadge("静音预览", highlighted: true)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    cardBadge(videoDurationText(photo), monospaced: true)
                }
            }
            .padding(8)
            .allowsHitTesting(false)

            if hovered, !isPreviewing {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.92))
                        .frame(width: 38, height: 38)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .offset(x: 1)
                }
                .transition(.scale.combined(with: .opacity))
                .allowsHitTesting(false)
            }

            if isPreviewing {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.22))
                            Capsule()
                                .fill(.white)
                                .frame(width: max(2, proxy.size.width * previewProgress))
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 7)
                }
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(hovered ? 0.18 : 0), radius: 14, y: 6)
        .scaleEffect(hovered ? 1.012 : 1)
        .animation(settings.motion.hover, value: hovered)
        .animation(settings.motion.overlay, value: isPreviewing)
    }

    private func cardBadge(_ text: String,
                           highlighted: Bool = false,
                           monospaced: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(highlighted ? 0.96 : 0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(.black.opacity(highlighted ? 0.54 : 0.4),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(highlighted ? 0.24 : 0.12),
                                  lineWidth: 0.6)
            }
    }

    private var previewURL: URL? {
        guard !photo.isCloud else { return nil }
        let url: URL
        if photo.isSystem {
            guard let path = photo.systemOriginalPath, !path.isEmpty else { return nil }
            url = URL(fileURLWithPath: path)
        } else {
            url = LibraryPaths.sourceURL(for: photo)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func handleHover(_ hovering: Bool) {
        hovered = hovering
        hoverTask?.cancel()
        guard hovering else {
            if previewingID == photo.id {
                previewingID = nil
                previewProgress = 0
            }
            return
        }
        guard previewURL != nil else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, hovered else { return }
            previewingID = photo.id
            previewProgress = 0
        }
    }

    private func open() {
        store.openViewer(photo.id, context: context)
    }
}

// MARK: - 标签与规格

private func videoDurationText(_ photo: PhotoItem) -> String {
    guard let duration = photo.duration, duration > 0 else { return "—" }
    return formatDuration(duration)
}

private func videoResolution(_ photo: PhotoItem) -> String? {
    guard photo.pixelWidth > 0, photo.pixelHeight > 0 else { return nil }
    return "\(photo.pixelWidth) × \(photo.pixelHeight)"
}

private func videoTag(_ photo: PhotoItem) -> String? {
    if photo.isScreenRecording { return "录屏" }
    if photo.isSlowMotion { return "慢动作" }
    if photo.isTimelapse { return "延时" }
    if photo.isCinematic { return "电影效果" }
    if photo.isSpatial { return "空间视频" }
    if photo.isFavorite { return "收藏" }
    if let duration = photo.duration, duration >= 180 { return "长片段" }
    return nil
}

private func videoSpecChips(_ photo: PhotoItem) -> [String] {
    var chips: [String] = []
    if let duration = photo.duration, duration > 0 {
        chips.append(formatDuration(duration))
    }
    if let resolution = videoResolution(photo) {
        chips.append(resolution)
    }
    if let codec = photo.videoCodec, !codec.isEmpty {
        chips.append(codec.uppercased())
    }
    if let tag = videoTag(photo) {
        chips.append(tag)
    }
    return chips
}
