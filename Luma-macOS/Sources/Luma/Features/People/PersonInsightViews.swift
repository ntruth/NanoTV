import SwiftUI
import AppKit
import Foundation

/// 人物详情的三种展示方式。
enum PersonDetailMode: String, CaseIterable, Identifiable {
    case summary
    case all
    case map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "摘要"
        case .all: return "全部"
        case .map: return "地图"
        }
    }

    var icon: String {
        switch self {
        case .summary: return "sparkles"
        case .all: return "square.grid.2x2"
        case .map: return "map"
        }
    }
}

// MARK: - 页头

/// 人物详情页头：大图封面 + 头像 + 名称 + 「摘要 / 全部」切换。
/// `collapse` 由滚动距离驱动（0 = 展开，1 = 收起），滚动时整块收缩成一条紧凑栏。
struct PersonDetailHero: View {
    @EnvironmentObject private var store: LibraryStore

    let name: String
    let subtitle: String
    let avatar: NSImage?
    let isPet: Bool
    let cover: PhotoItem?
    let mode: PersonDetailMode
    var collapse: CGFloat = 0
    let onBack: () -> Void
    let onModeChange: (PersonDetailMode) -> Void
    var onRename: (() -> Void)? = nil

    private var progress: CGFloat { min(1, max(0, collapse)) }
    private var heroHeight: CGFloat { 264 - 164 * progress }
    private var avatarSize: CGFloat { 84 - 50 * progress }
    private var nameSize: CGFloat { 29 - 14 * progress }
    private var edgePadding: CGFloat { 18 - 6 * progress }
    private var cornerRadius: CGFloat { 24 - 8 * progress }
    private var subtitleOpacity: Double { Double(max(0, 1 - progress * 1.7)) }
    private var renameOpacity: Double { Double(max(0, 1 - progress * 1.4)) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            // 不用强模糊：清晰封面 + 暗色渐变压住画面，保证文字可读。
            LinearGradient(colors: [Color.black.opacity(0.42),
                                    Color.black.opacity(0.10),
                                    Color.black.opacity(0.72)],
                           startPoint: .topLeading,
                           endPoint: .bottom)
            content
        }
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18 * Double(1 - progress * 0.6)),
                radius: 16 - 8 * progress,
                y: 8 - 3 * progress)
        .padding(.horizontal, 20)
        .padding(.top, 16 - 6 * progress)
    }

    private var background: some View {
        Group {
            if let cover {
                GeometryReader { geo in
                    PhotoHeroCover(photo: cover)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.55),
                                        Color.accentColor.opacity(0.22),
                                        Color.black.opacity(0.85)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                glassCircle(icon: "chevron.left", help: "返回人物", action: onBack)
                Spacer()
                if let onRename {
                    Button(action: onRename) {
                        Label("重命名", systemImage: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .heroGlass(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(renameOpacity)
                    .allowsHitTesting(progress < 0.5)
                    .help("重命名人物")
                }
            }

            Spacer(minLength: 2)

            HStack(alignment: .bottom, spacing: 16 - 8 * progress) {
                avatarView
                VStack(alignment: .leading, spacing: 5 - 3 * progress) {
                    Text(name)
                        .font(.system(size: nameSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .opacity(subtitleOpacity)
                    }
                }
                Spacer(minLength: 12)
                modeSwitch
            }
        }
        .padding(edgePadding)
    }

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85),
                                              Color.accentColor.opacity(0.45)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            if let avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isPet ? "pawprint.fill" : "person.fill")
                    .font(.system(size: avatarSize * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }

    private var modeSwitch: some View {
        DetailModeSwitch(mode: mode,
                         modes: [.summary, .all, .map],
                         collapse: progress,
                         onChange: onModeChange)
    }

    private func glassCircle(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .heroGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 顶部上下文条

/// 「摘要 / 全部 / 地图」胶囊切换：人物与地点详情共用，随页头收缩一起变小。
/// `modes` 允许地点详情沿用「摘要 / 全部」两档，人物详情多一档个人地图。
struct DetailModeSwitch: View {
    let mode: PersonDetailMode
    var modes: [PersonDetailMode] = [.summary, .all]
    let collapse: CGFloat
    let onChange: (PersonDetailMode) -> Void

    @Environment(\.colorScheme) private var scheme

    private var progress: CGFloat { min(1, max(0, collapse)) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { item in
                Button {
                    onChange(item)
                } label: {
                    Text(item.title)
                        .font(.system(size: 12 - 1.5 * progress, weight: .semibold))
                        .foregroundStyle(mode == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14 - 4 * progress)
                        .padding(.vertical, 6 - 2 * progress)
                        .background {
                            if mode == item {
                                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.10))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(helpText(for: item))
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
        .padding(3 - progress)
        .heroGlass(Capsule())
        .animation(.snappy(duration: 0.18), value: mode)
    }

    private func helpText(for item: PersonDetailMode) -> String {
        switch item {
        case .summary: return "查看摘要"
        case .all: return "查看全部照片"
        case .map: return "在地图上查看 TA 的足迹"
        }
    }
}

// MARK: - 滚动收缩

/// 页头封面：先出缩略图，再在后台解码一张长边 2600 的清晰图替换，避免大图拉伸发糊。
struct PhotoHeroCover: View {
    let photo: PhotoItem

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            PhotoThumbnailView(photo: photo, purpose: .cover(1200), contentMode: .fill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: photo.cacheKey) {
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.displayImage(for: photo, maxPixel: 2600)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { image = loaded }
        }
    }
}

/// 记录人物详情滚动距离（正值 = 已向下滚动）。
struct PersonScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 放在 ScrollView 顶部：把滚动距离回传给页头做收缩。
struct PersonScrollTracker: View {
    let coordinateSpace: String

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PersonScrollOffsetKey.self,
                                   value: -geo.frame(in: .named(coordinateSpace)).minY)
        }
        .frame(height: 0)
    }
}

// MARK: - 人物卡片

/// 人物总览卡片：拾光、系统图库与网盘共用同一套头像尺寸、文字层级与悬停抬升。
struct PeoplePersonCardShell<Avatar: View>: View {
    let name: String
    let count: Int
    let avatar: () -> Avatar
    /// 悬停状态留在卡片内部：上千人的列表不应该因为一次 hover 重排整个网格。
    @State private var isHovered = false

    init(name: String, count: Int, @ViewBuilder avatar: @escaping () -> Avatar) {
        self.name = name
        self.count = count
        self.avatar = avatar
    }

    var body: some View {
        VStack(spacing: 10) {
            avatar()
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.10),
                        radius: isHovered ? 14 : 6,
                        y: isHovered ? 7 : 3)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(count.formatted()) 张照片")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - 摘要

/// 人物摘要：一段画像文案 + 年度轨迹 + 地点 / 时段 / 同框 / 色彩 + 高光时刻。
struct PersonInsightSummaryView: View {
    let insight: PersonInsight
    let name: String

    private let spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            narrativeCard
            statsGrid
            if !insight.years.isEmpty { yearCard }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 288), spacing: spacing, alignment: .top)],
                      alignment: .leading,
                      spacing: spacing) {
                if !insight.places.isEmpty { placesCard }
                periodsCard
                if !insight.companions.isEmpty { companionsCard }
                if !insight.palettePhotos.isEmpty { paletteCard }
            }

            if !insight.highlights.isEmpty { highlightsSection }
            footnote
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 60)
        .frame(maxWidth: 1280, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 画像

    private var narrativeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(name) 的影像画像")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("端侧生成")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Text(insight.narrative)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.14),
                                              Color.accentColor.opacity(0.04)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.8)
        }
    }

    // MARK: 数据卡

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 12)],
                  alignment: .leading,
                  spacing: 12) {
            PersonStatCard(value: insight.totalCount.formatted(),
                           caption: "影像总数",
                           icon: "photo.stack")
            PersonStatCard(value: insight.years.count > 1
                                ? "\(insight.years.count)"
                                : (insight.years.first.map { "\($0.year)" } ?? "—"),
                           caption: insight.years.count > 1 ? "跨越年份" : "记录年份",
                           icon: "calendar")
            PersonStatCard(value: insight.activeYear.map { "\($0.year)" } ?? "—",
                           caption: "最活跃年份",
                           icon: "chart.bar.fill")
            PersonStatCard(value: insight.places.first?.name ?? "—",
                           caption: "最常出现",
                           icon: "mappin.and.ellipse")
        }
    }

    private var yearCard: some View {
        InsightCard(title: "年度轨迹", icon: "chart.bar.xaxis", subtitle: "按拍摄年份统计") {
            let peak = max(1, insight.years.map(\.count).max() ?? 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(insight.years) { bucket in
                        VStack(spacing: 6) {
                            Text(bucket.count.formatted())
                                .font(.system(size: 9.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(LinearGradient(colors: [Color.accentColor,
                                                              Color.accentColor.opacity(0.32)],
                                                     startPoint: .top,
                                                     endPoint: .bottom))
                                .frame(width: 26,
                                       height: max(6, CGFloat(bucket.count) / CGFloat(peak) * 92))
                            Text(String(bucket.year))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 30)
                        .help("\(bucket.year) 年 · \(bucket.count) 张")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var placesCard: some View {
        InsightCard(title: "常去之地", icon: "mappin.and.ellipse", subtitle: "按照片地点归并") {
            let peak = max(1, insight.places.first?.count ?? 1)
            VStack(spacing: 12) {
                ForEach(insight.places.indices, id: \.self) { index in
                    let place = insight.places[index]
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(place.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(place.count) 张")
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(LinearGradient(colors: [Color.accentColor,
                                                                      Color.accentColor.opacity(0.45)],
                                                             startPoint: .leading,
                                                             endPoint: .trailing))
                                        .frame(width: max(4, geo.size.width * CGFloat(place.count) / CGFloat(peak)))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }

    private var periodsCard: some View {
        InsightCard(title: "光线的偏好", icon: "sun.horizon", subtitle: "按拍摄时段") {
            VStack(spacing: 12) {
                ForEach(insight.periods) { slice in
                    HStack(spacing: 10) {
                        Text(slice.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 30, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule()
                                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.9),
                                                                  Color.accentColor.opacity(0.35)],
                                                         startPoint: .leading,
                                                         endPoint: .trailing))
                                    .frame(width: max(slice.count > 0 ? 4 : 0,
                                                      geo.size.width * CGFloat(slice.fraction)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int((slice.fraction * 100).rounded()))%")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var companionsCard: some View {
        InsightCard(title: "常一起出现", icon: "person.2", subtitle: "同框次数") {
            VStack(spacing: 10) {
                ForEach(insight.companions) { companion in
                    HStack(spacing: 10) {
                        CompanionAvatar(companion: companion, size: 30)
                        Text(companion.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("同框 \(companion.count) 次")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var paletteCard: some View {
        InsightCard(title: "色彩气质", icon: "paintpalette", subtitle: "缩略图平均色") {
            PhotoPalettePanel(photos: insight.palettePhotos)
        }
    }

    // MARK: 高光时刻

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("高光时刻")
                    .font(.system(size: 15, weight: .semibold))
                Text("每年最值得回看的一张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(insight.highlights) { photo in
                        PhotoHighlightCard(photo: photo)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text("画像与统计全部在本机由照片元数据派生，不上传任何照片。")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 2)
    }
}

// MARK: - 组件

/// 统一的摘要卡片外壳。
struct InsightCard<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String?
    let content: Content

    init(title: String,
         icon: String,
         subtitle: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
        }
    }
}

/// 顶部四项关键指标。
struct PersonStatCard: View {
    let value: String
    let caption: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
        }
    }
}

/// 同框人物的圆形头像。
struct CompanionAvatar: View {
    @EnvironmentObject private var store: LibraryStore

    let companion: PhotoCompanion
    let size: CGFloat

    @State private var image: NSImage?

    private var request: PersonAvatarRequest {
        PersonAvatarLoader.request(for: companion, size: size)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.42),
                                              Color.accentColor.opacity(0.2)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
        }
        .task(id: request) {
            if let cached = PersonAvatarLoader.cached(request) {
                image = cached
                return
            }
            image = await PersonAvatarLoader.load(request, store: store)
        }
    }
}

/// 高光时刻卡片：大图 + 时间地点说明。人物与地点摘要共用。
struct PhotoHighlightCard: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    let photo: PhotoItem
    @State private var isHovering = false

    var body: some View {
        Button {
            store.openPhoto(photo.id, by: settings.photoOpenMode)
        } label: {
            PhotoThumbnailView(photo: photo, purpose: .cover(280))
                .frame(width: 232, height: 156)
                .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Color.clear, Color.black.opacity(0.62)],
                                   startPoint: .center,
                                   endPoint: .bottom)
                        .frame(height: 76)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(caption)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 9)
                }
                .overlay(alignment: .topTrailing) {
                    if photo.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(isHovering ? 0.28 : 0.16),
                        radius: isHovering ? 14 : 8,
                        y: isHovering ? 7 : 4)
                .scaleEffect(isHovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(settings.motion.hover, value: isHovering)
        .help(photo.displayTitle)
    }

    private var caption: String {
        let month = DateText.monthFormatter.string(from: photo.capturedAt)
        if let place = photo.placePOI ?? photo.placeCity ?? photo.placeDistrict, !place.isEmpty {
            return "\(month) · \(place)"
        }
        return month
    }
}

/// 「色彩气质」：异步采样缩略图平均色。人物与地点摘要共用。
struct PhotoPalettePanel: View {
    let photos: [PhotoItem]

    @State private var result = PersonPalette.Result()
    @State private var isLoading = true

    private var samplingKey: String {
        photos.map { "\($0.cacheKey)" }.joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.isEmpty {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                        Text("正在采集色彩…")
                    } else {
                        Image(systemName: "paintpalette")
                        Text("暂无可采样的照片")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(height: 64)
            } else {
                HStack(spacing: 6) {
                    ForEach(result.swatches) { swatch in
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(red: swatch.red, green: swatch.green, blue: swatch.blue))
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                            }
                    }
                }
                HStack(spacing: 8) {
                    Text(result.tone)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 6)
                    Text("来自 \(result.sampleCount) 张照片")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: samplingKey) { await load() }
    }

    private func load() async {
        isLoading = true
        let source = photos
        let sampled = await Task.detached(priority: .utility) {
            PersonPalette.sample(photos: source)
        }.value
        guard !Task.isCancelled else { return }
        result = sampled
        isLoading = false
    }
}
