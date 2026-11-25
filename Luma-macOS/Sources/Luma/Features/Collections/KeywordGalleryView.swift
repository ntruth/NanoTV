import SwiftUI

/// 关键词页：概览是卡片墙，点入某个关键词后是独立的照片列表（类似人物 / 位置的详情）。
struct KeywordGalleryView: View {
    var system: Bool

    @EnvironmentObject private var store: LibraryStore

    /// 连接的非当前系统图库是只读的：关键词无法添加，文案里直接说明原因。
    private var isReadOnlySystem: Bool { system && !store.canEditNativeOverlay }

    var body: some View {
        if let keyword = store.selectedKeyword {
            KeywordDetailView(keyword: keyword, system: system)
        } else {
            KeywordWallView(system: system,
                            isReadOnlySystem: isReadOnlySystem,
                            onOpen: { store.openKeyword($0, system: system) })
        }
    }
}

/// 网盘的关键词卡片墙：关键词是拾光为远端文件记录的本地标签。
struct CloudKeywordGalleryView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        KeywordWallView(system: false,
                        isReadOnlySystem: false,
                        hint: "选中网盘照片后点「关键词」即可打标；标签只记录在本机，不会写回网盘。",
                        emptyHint: "选择网盘照片，右键或底部工具栏点「关键词」添加第一个标签。",
                        onOpen: { store.setCloudScope(.keyword($0)) })
    }
}

// MARK: - 卡片墙

private struct KeywordWallView: View {
    let system: Bool
    let isReadOnlySystem: Bool
    var hint: String?
    var emptyHint: String?
    let onOpen: (String) -> Void

    @EnvironmentObject private var store: LibraryStore

    init(system: Bool,
         isReadOnlySystem: Bool,
         hint: String? = nil,
         emptyHint: String? = nil,
         onOpen: @escaping (String) -> Void) {
        self.system = system
        self.isReadOnlySystem = isReadOnlySystem
        self.hint = hint
        self.emptyHint = emptyHint
        self.onOpen = onOpen
    }

    private var options: [KeywordOption] { store.keywordOptions }

    private var hintText: String {
        if let hint { return hint }
        if isReadOnlySystem {
            return "只读系统图库：把官方「照片」图库作为当前图库后即可添加关键词。"
        }
        return system
            ? "官方图库的标签与拾光补充的关键词合并显示；选中照片后点「关键词」可继续添加。"
            : "给照片添加关键词：选中照片后点「关键词」，标签随图库保存。"
    }

    private var emptyHintText: String {
        if let emptyHint { return emptyHint }
        if isReadOnlySystem {
            return "只读系统图库不能添加关键词；在拾光图库或官方「照片」图库中整理标签。"
        }
        return "在照片上右键选择「添加关键词…」即可开始整理。"
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 20
            let available = max(160, proxy.size.width - 48)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Text("\(options.count.formatted()) 个关键词")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(options.reduce(0) { $0 + $1.count }.formatted()) 张照片")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 12)
                        Text(hintText)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if options.isEmpty {
                        emptyState
                    } else {
                        let maxFit = max(1, Int((available + spacing) / (140 + spacing)))
                        let columnCount = min(store.cardColumns, maxFit)
                        let itemWidth = max(140, (available - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                                                 count: columnCount),
                                  alignment: .leading,
                                  spacing: 24) {
                            ForEach(options) { option in
                                KeywordCardView(name: option.name,
                                                count: option.count,
                                                cover: store.keywordCover(for: option.name),
                                                width: itemWidth)
                                    .onTapGesture { onOpen(option.name) }
                                    .help("查看「\(option.name)」下的全部照片")
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有关键词")
                .font(.system(size: 13.5, weight: .medium))
            Text(emptyHintText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }
}

/// 单个关键词卡片：封面 + 渐变蒙层 + 关键词与数量。
/// 悬停状态放在卡片内部，避免整面卡片墙随鼠标移动反复重算（此前会造成个别卡片文字丢失）。
private struct KeywordCardView: View {
    let name: String
    let count: Int
    let cover: PhotoItem?
    let width: CGFloat

    @EnvironmentObject private var settings: AppSettings
    @State private var isHovered = false

    private var height: CGFloat { max(118, width * 0.66) }
    private var corner: CGFloat { max(10, settings.cardRadius) }

    var body: some View {
        // 单层「封面 → 渐变 → 文案」用 overlay 串起来：ZStack 里的多子视图在
        // LazyVGrid 懒加载时曾被合成为 0 尺寸，导致部分卡片只剩封面。
        coverLayer
            .frame(width: width, height: height)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.18), .black.opacity(0.72)],
                               startPoint: .top,
                               endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(displayName)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(count.formatted()) 张照片")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 6)
                    countBadge
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.bottom, 12)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(7)
                    .background(.black.opacity(0.3), in: Circle())
                    .padding(9)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.3 : 0.12), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(isHovered ? 0.3 : 0.12),
                    radius: isHovered ? 16 : 7,
                    y: isHovered ? 9 : 3)
            .scaleEffect(isHovered && settings.hoverLift ? settings.motion.hoverScale : 1)
            .animation(settings.motion.hover, value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .onHover { isHovered = $0 }
    }

    private var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名关键词" : name
    }

    @ViewBuilder
    private var coverLayer: some View {
        if let cover {
            PhotoThumbnailView(photo: cover, purpose: .cover(400))
        } else {
            LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.16)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "tag")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                }
        }
    }

    private var countBadge: some View {
        Text(count.formatted())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.18), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
    }
}

// MARK: - 关键词详情

/// 某个关键词下的全部照片：封面页头 + 返回 + 瀑布流照片墙（同人物 / 位置详情的组织方式）。
private struct KeywordDetailView: View {
    let keyword: String
    let system: Bool

    @EnvironmentObject private var store: LibraryStore
    @State private var pinchBase: Double?

    private var photos: [PhotoItem] { store.visiblePhotos }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    hero(width: proxy.size.width)
                    if photos.isEmpty {
                        emptyState
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("全部影像")
                                .font(.system(size: 15, weight: .semibold))
                            Text("\(photos.count.formatted()) 张")
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(system ? "官方标签 + 拾光关键词" : "按当前排序显示")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 12)

                        MasonryPhotoGrid(photos: photos,
                                         availableWidth: max(160, proxy.size.width - 48),
                                         targetWidth: CGFloat(store.thumbSize) * 1.25)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.bottom, 56)
                .photoMarqueeSelection(fillHeight: proxy.size.height)
            }
            .simultaneousGesture(pinchGesture)
        }
    }

    private func hero(width: CGFloat) -> some View {
        coverLayer
            .frame(width: width, height: 236)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.06), .black.opacity(0.3), .black.opacity(0.74)],
                               startPoint: .top,
                               endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    backButton
                    Spacer(minLength: 16)
                    Text("#\(displayName)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
                    Text("\(photos.count.formatted()) 张照片")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                        .padding(.top, 5)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipped()
    }

    @ViewBuilder
    private var coverLayer: some View {
        if let cover = photos.first ?? store.keywordCover(for: keyword) {
            PhotoThumbnailView(photo: cover, purpose: .cover(1200))
                .overlay(Color.black.opacity(0.05))
        } else {
            LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0.2)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "tag")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                }
        }
    }

    private var backButton: some View {
        Button {
            store.closeKeyword()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("关键词")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .heroGlass(Capsule(), strokeWidth: 0.6)
        }
        .buttonStyle(.plain)
        .help("返回关键词列表")
    }

    private var displayName: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名关键词" : keyword
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("这个关键词下没有照片")
                .font(.system(size: 13.5, weight: .medium))
            Text("照片可能已被移除，或标签来自其他图库。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                      max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }
}
