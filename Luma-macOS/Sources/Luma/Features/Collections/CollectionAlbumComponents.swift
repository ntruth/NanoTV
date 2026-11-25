import AppKit
import SwiftUI
import LumaContentCore


/// 相簿封面、排版与人物页共用的组件。

/// 无封面时的占位样式：相簿 / 文件夹 / 分类图标。
enum AlbumPlaceholderStyle {
    case album
    case folder
    case icon(String)
}

/// 文件夹封面：2×2 四宫格，每张图各占 25% 面积；不足 4 张的空位用浅色占位。
/// 只有 1 张时直接铺满，避免整块缩略图只亮一小格。
struct FolderMosaicImage: View {
    let photos: [PhotoItem]
    var side: CGFloat = 220

    var body: some View {
        if photos.isEmpty {
            AlbumPlaceholderArt(style: .folder)
        } else if photos.count == 1, let photo = photos.first {
            PhotoThumbnailView(photo: photo, purpose: .cover(side))
        } else {
            GeometryReader { proxy in
                let gap: CGFloat = 1.5
                let cellWidth = max(1, (proxy.size.width - gap) / 2)
                let cellHeight = max(1, (proxy.size.height - gap) / 2)
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        cell(0, width: cellWidth, height: cellHeight)
                        cell(1, width: cellWidth, height: cellHeight)
                    }
                    HStack(spacing: gap) {
                        cell(2, width: cellWidth, height: cellHeight)
                        cell(3, width: cellWidth, height: cellHeight)
                    }
                }
            }
            .background(Color.secondary.opacity(0.08))
        }
    }

    @ViewBuilder
    func cell(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        if index < photos.count {
            PhotoThumbnailView(photo: photos[index], purpose: .cover(min(width, height)))
                .frame(width: width, height: height)
                .clipped()
        } else {
            Color.secondary.opacity(0.08)
                .frame(width: width, height: height)
        }
    }
}

/// 相簿卡片封面：单张图片铺满整张卡片；没有可用照片时显示占位插画。
struct AlbumCoverImage: View {
    let photo: PhotoItem?
    var side: CGFloat = 220
    var style: AlbumPlaceholderStyle = .album

    var body: some View {
        if let photo {
            PhotoThumbnailView(photo: photo, purpose: .cover(side))
        } else {
            AlbumPlaceholderArt(style: style)
        }
    }
}

/// 相簿总览的展示形式切换（网格 / 列表 / 拼贴墙），与「显示 › 相簿显示方式」共用同一个设置。
struct AlbumDisplayStyleMenu: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            ForEach(AlbumDisplayStyle.allCases) { style in
                Toggle(isOn: Binding(
                    get: { store.albumDisplayStyle == style },
                    set: { isOn in
                        guard isOn else { return }
                        withAnimation(settings.motion.layout) { store.albumDisplayStyle = style }
                    }
                )) {
                    Label(style.title, systemImage: style.icon)
                }
            }
        } label: {
            Image(systemName: store.albumDisplayStyle.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(store.albumDisplayStyle == .grid ? Color.primary : Color.accentColor)
                .frame(width: 26, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(store.albumDisplayStyle == .grid
                              ? Color.clear
                              : Color.accentColor.opacity(0.18))
                }
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("相簿显示方式：网格 / 列表 / 拼贴墙")
        .accessibilityLabel("相簿显示方式")
        .accessibilityValue(store.albumDisplayStyle.title)
    }
}

/// 相簿总览列表项：方形封面 + 名称 + 数量，与系统「照片」的列表视图一致（本地与系统图库共用）。
struct AlbumOverviewRow<MenuContent: View>: View {
    let title: String
    let subtitle: String
    let cover: PhotoItem?
    let placeholder: AlbumPlaceholderStyle
    let side: CGFloat
    var highlighted: Bool = false
    let action: () -> Void
    let menu: MenuContent

    @State private var hovering = false

    init(title: String,
         subtitle: String,
         cover: PhotoItem?,
         placeholder: AlbumPlaceholderStyle,
         side: CGFloat,
         highlighted: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.placeholder = placeholder
        self.side = side
        self.highlighted = highlighted
        self.action = action
        self.menu = menu()
    }

    var corner: CGFloat { max(10, side * 0.2) }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let cover {
                    PhotoThumbnailView(photo: cover, purpose: .cover(side))
                } else {
                    AlbumPlaceholderArt(style: placeholder)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.10 : (hovering ? 0.04 : 0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : Color.clear,
                              lineWidth: highlighted ? 2 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .contextMenu { menu }
    }
}

/// 相簿总览拼贴墙方块：无边封面拼贴 + 渐变叠字（本地与系统图库共用）。
struct AlbumOverviewTile<MenuContent: View>: View {
    @EnvironmentObject private var settings: AppSettings

    let title: String
    let subtitle: String
    let photos: [PhotoItem]
    let placeholder: AlbumPlaceholderStyle
    let side: CGFloat
    let isFolder: Bool
    var highlighted: Bool = false
    let action: () -> Void
    let menu: MenuContent

    @State private var hovering = false

    init(title: String,
         subtitle: String,
         photos: [PhotoItem],
         placeholder: AlbumPlaceholderStyle,
         side: CGFloat,
         isFolder: Bool,
         highlighted: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.subtitle = subtitle
        self.photos = photos
        self.placeholder = placeholder
        self.side = side
        self.isFolder = isFolder
        self.highlighted = highlighted
        self.action = action
        self.menu = menu()
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AlbumCollageCover(photos: photos, side: side, style: placeholder)
                .frame(width: side, height: side)

            LinearGradient(colors: [.clear, .black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: isFolder ? "folder.fill" : "rectangle.stack.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(11)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: highlighted ? 2 : 0.5)
        }
        .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 14, y: 6)
        .scaleEffect(hovering && settings.hoverLift ? settings.motion.hoverScale : 1)
        .animation(settings.motion.hover, value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .contextMenu { menu }
    }
}

/// 相簿总览在列表 / 拼贴墙下的拼贴封面：1 张铺满，2 张左右分栏，3 张左大右二，4 张 2×2。
struct AlbumCollageCover: View {
    let photos: [PhotoItem]
    let side: CGFloat
    var style: AlbumPlaceholderStyle = .album

    var items: [PhotoItem] { Array(photos.prefix(4)) }

    var body: some View {
        if items.isEmpty {
            AlbumPlaceholderArt(style: style)
        } else {
            GeometryReader { geo in
                let gap: CGFloat = 1.5
                Group {
                    switch items.count {
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
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    func cell(_ photo: PhotoItem) -> some View {
        PhotoThumbnailView(photo: photo, purpose: .cover(side / 2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

/// 占位插画：柔和强调色渐变底 + 叠放的照片卡片 / 立体文件夹，随卡片尺寸等比缩放。
struct AlbumPlaceholderArt: View {
    let style: AlbumPlaceholderStyle

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                backdrop(side: side)
                switch style {
                case .album:
                    photoStack(side: side)
                case .folder:
                    folderArt(side: side)
                case .icon(let name):
                    iconArt(name, side: side)
                }
            }
        }
    }

    // MARK: - 背景

    func backdrop(side: CGFloat) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            LinearGradient(colors: [Color.accentColor.opacity(0.30),
                                    Color.accentColor.opacity(0.05)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.13), .clear],
                           center: UnitPoint(x: 0.76, y: 0.16),
                           startRadius: 0,
                           endRadius: side * 0.8)
        }
    }

    // MARK: - 相簿：叠放的照片

    func photoStack(side: CGFloat) -> some View {
        let s = side * 0.62
        let corner = s * 0.09
        return ZStack {
            photoTile(side: s, corner: corner,
                      fill: Color.white.opacity(0.12), glyph: false)
                .frame(width: s * 0.80, height: s * 0.80)
                .rotationEffect(.degrees(-11))
                .offset(x: -s * 0.07, y: s * 0.06)

            photoTile(side: s, corner: corner,
                      fill: Color.white.opacity(0.20), glyph: false)
                .frame(width: s * 0.87, height: s * 0.87)
                .rotationEffect(.degrees(8))
                .offset(x: s * 0.06, y: s * 0.03)

            photoTile(side: s, corner: corner,
                      fill: LinearGradient(colors: [Color.white.opacity(0.95),
                                                    Color.white.opacity(0.74)],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                      glyph: true)
                .frame(width: s * 0.92, height: s * 0.92)
                .shadow(color: .black.opacity(0.22), radius: s * 0.07, y: s * 0.03)
        }
    }

    func photoTile<Fill: ShapeStyle>(side: CGFloat,
                                             corner: CGFloat,
                                             fill: Fill,
                                             glyph: Bool) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
            }
            .overlay {
                if glyph {
                    Image(systemName: "photo.fill")
                        .font(.system(size: side * 0.24, weight: .regular))
                        .foregroundStyle(Color.accentColor.opacity(0.58))
                }
            }
    }

    // MARK: - 文件夹：立体文件夹 + 露出的照片

    func folderArt(side: CGFloat) -> some View {
        let s = side * 0.64
        let corner = s * 0.10
        return ZStack {
            FolderBackShape(cornerRadius: corner)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.90),
                                              Color.accentColor.opacity(0.48)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s * 0.98, height: s * 0.84)
                .offset(y: s * 0.05)
                .shadow(color: .black.opacity(0.22), radius: s * 0.06, y: s * 0.03)

            // 从文件夹里露出的照片（偏右，让左上标签可见）
            RoundedRectangle(cornerRadius: corner * 0.8, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.93),
                                              Color.white.opacity(0.70)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: s * 0.46, height: s * 0.34)
                .offset(x: s * 0.12, y: -s * 0.06)
                .overlay {
                    Image(systemName: "photo.fill")
                        .font(.system(size: s * 0.11, weight: .regular))
                        .foregroundStyle(Color.accentColor.opacity(0.52))
                        .offset(x: s * 0.12, y: -s * 0.11)
                }

            // 前挡板：半透明高光，让底层强调色透出
            RoundedRectangle(cornerRadius: corner * 1.1, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.30),
                                              Color.white.opacity(0.07)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s, height: s * 0.50)
                .offset(y: s * 0.20)
                .overlay {
                    RoundedRectangle(cornerRadius: corner * 1.1, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(0.40))
                        .frame(height: 0.8)
                        .padding(.horizontal, corner * 1.4)
                        .offset(y: 0.6)
                }
        }
    }

    // MARK: - 分类图标

    func iconArt(_ name: String, side: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: side * 0.26, weight: .regular))
            .foregroundStyle(Color.accentColor.opacity(0.85))
            .frame(width: side * 0.46, height: side * 0.46)
            .background(Circle().fill(Color.white.opacity(0.10)))
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
            }
    }
}

/// 文件夹背板：左下主体 + 左上标签，两段圆角矩形合并填充。
struct FolderBackShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyTop = rect.height * 0.16
        path.addRoundedRect(in: CGRect(x: rect.minX,
                                       y: rect.minY + bodyTop,
                                       width: rect.width,
                                       height: rect.height - bodyTop),
                            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                            style: .continuous)
        path.addRoundedRect(in: CGRect(x: rect.minX,
                                       y: rect.minY,
                                       width: rect.width * 0.55,
                                       height: rect.height * 0.34),
                            cornerSize: CGSize(width: cornerRadius * 0.9, height: cornerRadius * 0.9),
                            style: .continuous)
        return path
    }
}

struct PeopleView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var pinchBase: Double?
    @State private var detailMode: PersonDetailMode = .summary
    @State private var insight: PersonInsight?
    @State private var heroAvatar: NSImage?
    @State private var collapseProgress: CGFloat = 0

    var body: some View {
        if store.isSystemScope {
            if let person = store.selectedPerson {
                personDetail(person)
            } else {
                overview
            }
        } else {
            LocalPeopleView()
        }
    }

    var people: [SystemPersonInfo] { store.systemPeople }

    /// 人物卡片尺寸跟随工具栏缩放（56…360 → 72…300）。
    var cardSize: CGFloat {
        min(300, max(72, CGFloat(store.thumbSize)))
    }

    var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    var overview: some View {
        VStack(spacing: 0) {
            if people.isEmpty {
                emptyState
            } else if filteredPeople.isEmpty {
                filterEmptyState
            } else {
                systemPeopleBar
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35),
                                                 spacing: cardSize * 0.16, alignment: .top)],
                              alignment: .leading,
                              spacing: cardSize * 0.2) {
                        ForEach(filteredPeople) { person in
                            PersonCardView(person: person, avatarSize: cardSize * 0.94, style: store.peopleDisplayStyle)
                                .onTapGesture { store.openPerson(person) }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 56)
                }
                .simultaneousGesture(pinchGesture)
            }
        }
    }

    /// 按当前聚合筛选得到的人物；宠物不参与「已命名 / 待命名」。
    /// 「全部」时平铺展示，不再按命名状态分节；只有选了筛选才收窄集合。
    var filteredPeople: [SystemPersonInfo] {
        switch store.peopleFilter {
        case .all: return people
        case .named: return people.filter { !$0.isUnnamed && !$0.isPet }
        case .unnamed: return people.filter { $0.isUnnamed && !$0.isPet }
        case .pets: return people.filter(\.isPet)
        }
    }

    /// 系统图库的人物由官方识别，这里只提供「刷新读取结果」的入口。
    var systemPeopleBar: some View {
        HStack(spacing: 10) {
            Text("由 macOS「照片」在端侧识别，拾光只读引用")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                store.refreshSystemPeople()
            } label: {
                Label("刷新识别结果", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("重新读取官方「照片」图库里的人物与宠物")
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
    }

    /// 当前聚合筛选没有结果时的占位；与「图库为空」区分开，避免误以为识别失败。
    var filterEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.peopleFilter.icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(store.peopleFilter.emptyTitle)
                .font(.system(size: 16, weight: .semibold))
            Text(store.peopleFilter.emptyHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    var emptyState: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.14), Color.clear],
                           startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 96, height: 96)
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Text("人物与宠物")
                    .font(.system(size: 22, weight: .semibold))
                Text("连接 macOS 官方「照片」图库后，这里会显示官方端侧识别出的人物与宠物（含尚未命名的聚类）；识别始终在本机完成，本 App 不会上传任何照片。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                HStack(spacing: 18) {
                    featureChip(icon: "lock.shield", title: "端侧识别")
                    featureChip(icon: "person.2", title: "官方结果")
                    featureChip(icon: "photo.on.rectangle", title: "只读引用")
                }
                .padding(.top, 4)

                Button {
                    store.refreshSystemPeople()
                } label: {
                    Label("刷新识别结果", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(30)
        }
    }

    func personDetail(_ person: SystemPersonInfo) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PersonDetailHero(name: person.name,
                                 subtitle: insight?.subtitle ?? "正在整理这段影像…",
                                 avatar: heroAvatar,
                                 isPet: person.isPet,
                                 cover: insight?.coverPhoto
                                    ?? person.keyAssetID.flatMap { store.anyPhoto(id: $0) },
                                 mode: detailMode,
                                 collapse: detailMode == .map ? 1 : collapseProgress,
                                 onBack: { store.closePerson() },
                                 onModeChange: { newMode in
                                     withAnimation(.snappy(duration: 0.26)) { detailMode = newMode }
                                 })

                if detailMode == .map {
                    // 地图档：页头收成一条紧凑栏，剩下的空间全部交给地图。
                    PersonMapPanel(source: .system(person), name: person.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            PersonScrollTracker(coordinateSpace: "systemPersonScroll")
                            if detailMode == .summary {
                                if let insight {
                                    PersonInsightSummaryView(insight: insight, name: person.name)
                                } else {
                                    insightLoading.frame(height: 360)
                                }
                            } else {
                                allPhotos(availableWidth: proxy.size.width,
                                          fillHeight: proxy.size.height)
                            }
                        }
                        .id(detailMode)
                    }
                    .coordinateSpace(name: "systemPersonScroll")
                    .onPreferenceChange(PersonScrollOffsetKey.self) { offset in
                        let value = min(1, max(0, offset / 180))
                        if abs(value - collapseProgress) > 0.004 {
                            collapseProgress = value
                        }
                    }
                }
            }
        }
        .task(id: person.id) {
            detailMode = .summary
            collapseProgress = 0
            insight = nil
            let request = PersonAvatarLoader.request(for: person, size: 84)
            heroAvatar = PersonAvatarLoader.cached(request)
            if heroAvatar == nil {
                heroAvatar = await PersonAvatarLoader.load(request, store: store)
            }
            let loaded = await store.systemPersonInsightAsync(for: person)
            if !Task.isCancelled, store.selectedPerson?.id == person.id {
                insight = loaded
            }
        }
        .onChange(of: store.selectedPerson?.id) { _, _ in
            detailMode = .summary
            collapseProgress = 0
            insight = nil
        }
    }

    var insightLoading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在整理这段影像故事…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「全部」：瀑布流拼贴，卡片保留原始比例并常驻投影。
    func allPhotos(availableWidth: CGFloat, fillHeight: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("全部影像")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(store.visibleCount.formatted()) 张")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)

            MasonryPhotoGrid(photos: store.visiblePhotos,
                             availableWidth: availableWidth,
                             targetWidth: CGFloat(store.thumbSize) * 1.25)
        }
        .padding(.bottom, 56)
        .photoMarqueeSelection(fillHeight: fillHeight)
    }

    func featureChip(icon: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(width: 84, height: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PersonAvatarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let person: SystemPersonInfo
    let size: CGFloat
    /// 头像形状：圆形或圆角方形；默认圆形（详情页等场景沿用圆形）。
    var style: PeopleDisplayStyle = .circle

    @State private var image: NSImage?

    var request: PersonAvatarRequest {
        PersonAvatarLoader.request(for: person, size: size)
    }

    /// 裁切形状：圆角方形沿用全局卡片圆角设置。
    var shape: AnyShape {
        switch style {
        case .circle: AnyShape(Circle())
        case .roundedSquare: AnyShape(RoundedRectangle(cornerRadius: settings.cardRadius, style: .continuous))
        }
    }

    var body: some View {
        ZStack {
            shape
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.25)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: person.isPet ? "pawprint.fill" : "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.stroke(Color.white.opacity(0.18), lineWidth: 0.8)
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

struct PersonCardView: View {
    let person: SystemPersonInfo
    /// 头像直径，随工具栏缩放变化。
    var avatarSize: CGFloat = 124
    /// 头像形状（圆形 / 圆角方形），随当前图库保存。
    var style: PeopleDisplayStyle = .circle

    var body: some View {
        PeoplePersonCardShell(name: person.name, count: person.faceCount) {
            PersonAvatarView(person: person, size: avatarSize, style: style)
        }
    }
}
