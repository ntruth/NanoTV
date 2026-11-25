import SwiftUI
import AppKit

// MARK: - 顶部滚动日期

/// 「所有照片」网格的滚动坐标系：探针把内容偏移量换算成可见区域。
enum GalleryScrollSpace {
    static let name = "galleryScroll"
}

struct GalleryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 年 / 月 / 所有照片 的磨砂分段切换：悬停与选中都带柔和胶囊，贴合系统「照片」的顶栏。
struct TimelineGroupingSwitch: View {
    @Binding var selection: GridGrouping
    @EnvironmentObject private var settings: AppSettings
    @Namespace private var pill
    @State private var hoveredOption: GridGrouping?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GridGrouping.allCases) { option in
                let active = option == selection
                Button {
                    guard !active else { return }
                    withAnimation(settings.motion.layout) { selection = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .padding(.horizontal, 15)
                        .frame(height: 26)
                        .background {
                            if active {
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.13))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                    }
                                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "groupingPill", in: pill)
                            } else if hoveredOption == option {
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredOption = hovering ? option : (hoveredOption == option ? nil : hoveredOption)
                }
                .help(hint(for: option))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .help("按时间分组：年 / 月 / 所有照片")
    }

    private func hint(for option: GridGrouping) -> String {
        switch option {
        case .years: return "按年分组浏览照片"
        case .months: return "按月分组浏览照片"
        case .all: return "显示全部照片，顶栏日期随滚动位置实时联动"
        }
    }
}

/// 收藏浏览方式切换：与地图样式切换一致的 segmented 外观。
struct FavoritesViewModeSwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Picker("收藏浏览方式", selection: $store.favoritesViewMode) {
            ForEach(FavoritesViewMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(store.favoritesViewMode.hint)
    }
}

struct PlaceGranularitySwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Picker("地点聚合层级", selection: $store.placeGranularity) {
            ForEach(PlaceGranularity.allCases) { option in
                Text(option.shortTitle).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("按省份、城市、区县或街道聚合同一片区域的照片")
    }
}

struct MapStyleSwitch: View {
    @AppStorage("map.style") private var styleRaw = MapStyleMode.map.rawValue

    private var selection: Binding<MapStyleMode> {
        Binding(
            get: { MapStyleMode(rawValue: styleRaw) ?? .map },
            set: { styleRaw = $0.rawValue }
        )
    }

    var body: some View {
        Picker("地图显示方式", selection: selection) {
            ForEach(MapStyleMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("切换地图、卫星底图或当前视野的照片网格")
    }
}

/// 整理工作室的维度切换：评分 / 旗标 / 色标 / 关键词。
/// 选中态对齐人物页的系统分段控件：明确的灰色胶囊 + 深色半粗文字，不再靠材质差异提示。
struct OrganizeDimensionSwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OrganizeDimension.allCases) { item in
                let selected = store.organizeDimension == item
                Button {
                    // 只改维度，不在这里开动画：维度切换会换掉下方整块分布面板，
                    // 用 withAnimation 会把结果网格与滚动条一起带动，造成整页抖动。
                    store.organizeDimension = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.13))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                                }
                                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.caption)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: store.organizeDimension)
        .fixedSize()
    }
}

/// 视频页的「海报墙 / 时间轴」切换：图标 + 文字的分段胶囊，
/// 选中项用强调色渐变托底，切换时滑片过渡，与顶栏其它圆角控件同一套材质与描边。
struct VideoHubLayoutSwitch: View {
    @EnvironmentObject private var store: LibraryStore
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VideoHubLayout.allCases) { layout in
                segment(layout)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .fixedSize()
    }

    private func segment(_ layout: VideoHubLayout) -> some View {
        let selected = store.videoHubLayout == layout
        return Button {
            guard !selected else { return }
            withAnimation(.snappy(duration: 0.22)) {
                store.videoHubLayout = layout
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: layout.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(layout.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.32),
                                                      Color.accentColor.opacity(0.13)],
                                             startPoint: .top,
                                             endPoint: .bottom))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 0.6)
                        }
                        .shadow(color: Color.accentColor.opacity(0.20), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "videoHubLayoutSelection", in: selection)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(layout.help)
        .accessibilityLabel(layout.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct PeopleGroupFilterSwitch: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Picker("人物筛选", selection: $store.peopleFilter) {
            ForEach(PeopleGroupFilter.allCases) { option in
                Text(option.shortTitle).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(store.peopleFilter.help)
    }
}

// MARK: - 工具栏通用外观

/// 顶栏图标的统一样式：固定点击区域、统一字号与视觉重量，悬停时给一层柔和圆角底。
/// 所有顶栏控件都走这个视图，避免个别图标自带底色/尺寸造成「有的大有的小」。
struct GalleryToolbarIconLabel: View {
    let systemName: String
    var active: Bool = false
    var activeColor: Color = .accentColor
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? activeColor : Color.primary)
            .frame(width: 32, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 把若干顶栏控件收进同一个磨砂胶囊：间距、高度、描边完全一致，和年 / 月切换保持同一套语言。
struct GalleryToolbarPill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 3) {
            content
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }
}
