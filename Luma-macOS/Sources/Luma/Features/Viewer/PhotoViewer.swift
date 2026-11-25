import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LumaCore

struct PhotoViewerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewer: ViewerModel
    @Environment(\.colorScheme) private var colorScheme
    /// true 表示嵌入主窗口浏览（保留侧边栏与工具栏），对应官方「照片」的窗口内查看。
    var embedded: Bool = false
    @State private var image: NSImage?
    /// 动图（GIF / 动画 WebP 等）的逐帧图像，交给 `AnimatedImageView` 打开即播放。
    @State private var animatedImage: NSImage?
    /// 窗口内浏览的背景图：照片/视频缩略图，用来铺满舞台两侧，避免竖图出现大片死黑。
    @State private var backdropImage: NSImage?
    /// 查看器占位层：先显示网格缩略图/中等尺寸，全尺寸解码完成后直接替换。
    @State private var placeholder: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// 舞台尺寸：双指滚动拖动画面时用来限制边界。
    @State private var stageSize: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var pinchStartZoom: CGFloat?
    @State private var pinchStartOffset: CGSize = .zero
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var didAppear = false
    @State private var hostWindow: NSWindow?
    @State private var showShortcutHelp = false
    @State private var livePlayer: AVPlayer?
    @State private var livePlaying = false
    @State private var liveEndObserver: NSObjectProtocol?
    /// 连拍逐帧播放任务。
    @State private var burstPlayTask: Task<Void, Never>?
    /// 「保留所选，删除其余」的确认卡片。
    @State private var confirmBurstKeep = false
    /// 顶栏与画面内控制条共享的音轨 / 字幕状态（由 ViewerModel 持有，「视频」菜单也读这一份）。
    private var videoUI: VideoPlaybackUI { viewer.videoPlaybackUI }
    /// 顶栏时间点击后显示剩余时长。
    @State private var videoShowsRemainingTime = false

    private var videoModel: VideoPlayerModel { viewer.videoPlayer }

    private var photo: PhotoItem? { store.viewerPhoto }
    /// 连拍组内浏览：组为空时按普通照片浏览。
    private var burstMembers: [PhotoItem] { viewer.burstMembers }
    /// 分页模式下是当前照片附近的一小段；连拍时是整组成员；否则是完整的可见列表。
    private var items: [PhotoItem] {
        if !burstMembers.isEmpty { return burstMembers }
        let strip = store.viewerStrip
        return strip.isEmpty ? store.viewerVisiblePhotos : strip
    }
    /// 序号与总数：优先用查询下标，算不出时由 Store 逐级兜底，
    /// 从相簿位置跳转、场景目录、卡片墙封面等入口打开也必须有数字。
    private var viewerPosition: (index: Int, total: Int) {
        guard let id = photo?.id else { return (0, 1) }
        if !burstMembers.isEmpty {
            return (burstMembers.firstIndex(where: { $0.id == id }) ?? 0, burstMembers.count)
        }
        return store.viewerPosition(of: id)
    }
    private var totalCount: Int { viewerPosition.total }
    private var loadKey: String {
        guard let photo else { return "none" }
        // 电视线路切换会自增 token：变化后重新装片，不必退出播放器。
        return "\(photo.id.uuidString)-\(photo.editVersion)-\(settings.viewFullHDR)-\(store.tvLineTokens[photo.id, default: 0])"
    }
    private var currentIndex: Int? {
        guard photo != nil else { return nil }
        return viewerPosition.index
    }

    /// 当前照片在可见列表里的位置，用于工具栏上的小进度环。
    private var progressFraction: CGFloat {
        guard let currentIndex, totalCount > 0 else { return 0 }
        return min(1, max(0, CGFloat(currentIndex + 1) / CGFloat(totalCount)))
    }

    var body: some View {
        ZStack {
            // 视频真全屏的纯黑底：常驻在层级里、只改透明度。
            // 用 if 切换底色会改变 ZStack 的子视图结构，SwiftUI 会重建播放器，
            // 全屏时表现为「黑屏没画面，但声音还在放」。
            Color.black
                .opacity(viewer.videoImmersiveFullScreen ? 1 : 0)

            // 照片与窗口内浏览的灯箱底；全屏视频时让位给纯黑。
            photoBackdrop(immersive: !embedded)
                .opacity(viewer.videoImmersiveFullScreen ? 0 : 1)

            if let photo {
                if embedded {
                    embeddedLayout(photo)
                } else {
                    HStack(spacing: 0) {
                        ZStack {
                            stage(photo)
                            chrome(photo)
                        }
                        if viewer.showInfoPanel {
                            InfoPanelView(photo: photo)
                                .frame(width: 304)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
            }
        }
        .task(id: loadKey) {
            await load()
        }
        .task(id: photo?.cacheKey) {
            await loadBackdrop()
        }
        .onChange(of: settings.viewerBackdrop) { _, enabled in
            // 关掉背景虚化时清掉已加载的模糊底图，打开时补回来。
            if enabled {
                Task { await loadBackdrop() }
            } else {
                backdropImage = nil
            }
        }
        .scaleEffect(didAppear ? 1 : 0.985)
        .opacity(didAppear ? 1 : 0)
        .onAppear {
            installViewerKeyMonitor()
            installViewerScrollMonitor()
            withAnimation(.easeOut(duration: 0.18)) { didAppear = true }
        }
        .onDisappear {
            removeViewerKeyMonitor()
            removeViewerScrollMonitor()
            stopLivePhoto()
            stopBurstPlayback()
            VideoScrubPreviewCenter.shared.end()
        }
        .background(
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        )
        .animation(settings.motion.overlay, value: viewer.showInfoPanel)
        // 窗口内浏览：把返回、缩放、拍摄时间与操作交给统一工具栏，画面里只留照片。
        .toolbar {
            if embedded {
                embeddedToolbar
            }
        }
        // 连拍处理：保留所选，其余移入最近删除。
        .confirmationDialog("保留所选照片？",
                            isPresented: $confirmBurstKeep,
                            titleVisibility: .visible) {
            Button("保留 \(viewer.burstSelection.count) 张，删除其余 \(max(0, burstMembers.count - viewer.burstSelection.count)) 张",
                   role: .destructive) {
                store.deleteBurstPhotos(keeping: viewer.burstSelection)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("其余照片会移入最近删除，30 天内可恢复。")
        }
    }

    // MARK: - 查看器背景

    /// 查看器「灯箱」底：用当前照片自身的模糊影像铺满整个舞台。
    /// 竖图 / 竖视频两侧、宽图上下都不再出现大片死黑，同时保留照片本身的色彩气质。
    /// - Parameter immersive: 全屏查看时压得更暗，突出前景照片。
    private func photoBackdrop(immersive: Bool) -> some View {
        GeometryReader { proxy in
            ZStack {
                if immersive {
                    Color.black
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }

                // 设置里关闭「背景虚化」时只保留纯色底：翻页不再为每张照片重算大半径模糊。
                if settings.viewerBackdrop {
                    // 模糊底只需要低分辨率缩略图，避免每次缩放都对全尺寸图重算大半径模糊。
                    if let backdrop = backdropImage ?? placeholder ?? image {
                        Image(nsImage: backdrop)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(1.12)
                            .blur(radius: immersive ? 64 : 52)
                            .clipped()
                    }

                    // 压暗到能看清前景，又保留一圈来自照片本身的环境色。
                    Color.black.opacity(immersive
                                        ? (colorScheme == .dark ? 0.58 : 0.44)
                                        : (colorScheme == .dark ? 0.46 : 0.24))

                    RadialGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.05), .clear],
                                   center: .center,
                                   startRadius: 40,
                                   endRadius: 720)

                    RadialGradient(colors: [.clear, Color.black.opacity(immersive
                                                                       ? 0.50
                                                                       : (colorScheme == .dark ? 0.38 : 0.12))],
                                   center: .center,
                                   startRadius: 260,
                                   endRadius: 1000)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private func embeddedLayout(_ photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 画面直接铺满内容区：不再给照片额外的上下/左右留边。
                stage(photo)
                if viewer.showInfoPanel {
                    InfoPanelView(photo: photo)
                        .frame(width: 304)
                        .background(.regularMaterial)
                        .transition(.move(edge: .trailing))
                }
            }
            // 连拍按官方「照片」的做法：普通浏览不铺胶片条，进入选择后底部才浮出整组帧条。
            // 视频真全屏时不铺帧条：否则底部被占去一条，画面就铺不满了。
            if settings.viewerFilmstrip, totalCount > 1, burstMembers.isEmpty,
               !viewer.videoImmersiveFullScreen {
                embeddedFilmstrip(photo)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if viewer.burstSelectionMode, !burstMembers.isEmpty {
                burstSelectionPanel(photo)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 顶栏进度条的悬停关键帧：工具栏装不下气泡，画在画面这一层，
        // 全屏时浮在工具栏下方，窗口内贴着画面上沿。
        .overlay {
            if showsVideoToolbarControls {
                VideoScrubPreviewOverlay(topInset: viewer.videoImmersiveFullScreen ? 70 : 6)
                    .zIndex(3)
            }
        }
        .animation(settings.motion.overlay, value: settings.viewerFilmstrip)
        .animation(settings.motion.overlay, value: viewer.showInfoPanel)
        .animation(settings.motion.overlay, value: viewer.burstSelectionMode)
    }

    /// 连拍选择模式下浮在舞台上方的帧条：与官方「照片」一样是一块居中的深色圆角面板，
    /// 帧缩略图带勾选圈，右侧放全选、收藏所选与「保留所选，删除其余」。
    private func burstSelectionPanel(_ photo: PhotoItem) -> some View {
        HStack(spacing: 12) {
            Button("全选") {
                store.selectAllBurstMembers()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .help("选中组内全部照片")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(burstMembers) { item in
                            Button {
                                store.toggleBurstSelection(item.id)
                            } label: {
                                FilmstripThumb(photo: item, isCurrent: item.id == photo.id)
                                    .overlay(alignment: .topTrailing) {
                                        let picked = viewer.burstSelection.contains(item.id)
                                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(picked ? Color.accentColor : Color.white)
                                            .shadow(color: .black.opacity(0.55), radius: 2, y: 0.5)
                                            .padding(4)
                                    }
                                    .opacity(viewer.burstSelection.contains(item.id) ? 1 : 0.6)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 520)
                .onAppear { proxy.scrollTo(photo.id, anchor: .center) }
                .onChange(of: photo.id) { _, id in
                    withAnimation(settings.motion.overlay) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider()
                .frame(height: 26)
                .overlay(.white.opacity(0.18))

            Button {
                store.favoriteBurstSelection()
            } label: {
                Image(systemName: "heart")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .disabled(viewer.burstSelection.isEmpty)
            .help("收藏所选")

            Button {
                confirmBurstKeep = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .disabled(viewer.burstSelection.isEmpty)
            .help("保留所选，删除其余")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private func embeddedFilmstrip(_ photo: PhotoItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(items) { item in
                        Button {
                            viewer.viewerID = item.id
                        } label: {
                            FilmstripThumb(photo: item, isCurrent: item.id == photo.id)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .frame(height: 76)
            // 通到底部的渐变与整宽缩略图：不再是一块悬空的小玻璃，两侧也不留空白。
            .background {
                LinearGradient(colors: [Color.black.opacity(0.10),
                                        Color.black.opacity(0.58),
                                        Color.black.opacity(0.86)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.white.opacity(0.14), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 1)
            }
            .onAppear { proxy.scrollTo(photo.id, anchor: .center) }
            .onChange(of: photo.id) { _, id in
                withAnimation(settings.motion.overlay) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .help("底部缩略图：点按可切换照片")
    }

    // MARK: - 顶栏照片信息

    // MARK: - 顶栏视频控件

    /// 顶栏融合是否生效：窗口内浏览视频，且设置里选了「顶栏融合」。
    private var showsVideoToolbarControls: Bool {
        embedded && settings.videoControlPlacement == .topIntegrated && (photo?.isVideo ?? false)
    }

    /// 顶栏播放舱：上行是拍摄信息与序号，下行是进度与时间。
    /// 宽度固定、高度压到两行最紧凑的一档：翻页时胶囊尺寸不变，画面也不会被工具栏遮住太多。
    /// 直播没有可拖动的时间轴，顶栏只保留一行换台信息，避免内容顶出胶囊。
    @ViewBuilder
    private func videoToolbarDeck(_ photo: PhotoItem) -> some View {
        if store.tvPlaybackChannel(for: photo.id) != nil {
            TVToolbarDeck(store: store, photo: photo, player: videoModel, tv: store.tvModel)
        } else if let entry = cinemaEntry(for: photo) {
            // 影视播放：顶栏改成「正在放映」舱，不再显示文件拍摄时间。
            // 宽度跟随工具栏可用空间（上限 600），并把实测宽度交给信息行做分级收放。
            HStack(alignment: .center, spacing: 8) {
                CinemaArtwork(urlString: entry.posterURL ?? entry.backdropURL,
                              contentMode: .fill,
                              maxPixelSize: 160)
                    .frame(width: 20, height: 27)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                    }
                    .fixedSize()
                    .help("正在播放：\(entry.title)")

                VStack(spacing: 1) {
                    // 工具栏给的实际宽度只有 GeometryReader 拿得到（偏好值传不出 ToolbarItem），
                    // 用它驱动信息行的分级收放，宽窄判断才真实可靠。
                    GeometryReader { proxy in
                        cinemaToolbarInfoLine(entry, width: proxy.size.width)
                            .frame(width: proxy.size.width, height: 18, alignment: .leading)
                    }
                    .frame(height: 18)
                    HStack(spacing: 6) {
                        VideoToolbarProgress(model: videoModel,
                                             session: viewer.playbackSession,
                                             showsRemaining: $videoShowsRemainingTime,
                                             chapterFractions: toolbarChapterFractions)
                            .frame(maxWidth: .infinity)
                        VideoInlineVolume(model: videoModel)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 0)
            .frame(minWidth: 520, maxWidth: 640)
        } else if let context = catalogContext(for: photo) {
            // 网络资源（网页源）：海报 + 片名 + 来源站点 + 分集号 + 队列 / 下一集，
            // 与直播舱、影院舱共用同一套信息语言与分级收放规则。
            HStack(alignment: .center, spacing: 8) {
                CatalogArtworkImage(source: context.source,
                                    urlString: catalogCoverURL(context),
                                    cornerRadius: 3)
                    .frame(width: 20, height: 27)
                    .fixedSize()
                    .help("正在播放：\(context.item.title)")

                VStack(spacing: 1) {
                    GeometryReader { proxy in
                        catalogToolbarInfoLine(context, photo: photo, width: proxy.size.width)
                            .frame(width: proxy.size.width, height: 18, alignment: .leading)
                    }
                    .frame(height: 18)
                    HStack(spacing: 6) {
                        VideoToolbarProgress(model: videoModel,
                                             session: viewer.playbackSession,
                                             showsRemaining: $videoShowsRemainingTime,
                                             chapterFractions: toolbarChapterFractions)
                            .frame(maxWidth: .infinity)
                        VideoInlineVolume(model: videoModel)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 0)
            .frame(minWidth: 520, maxWidth: 640)
        } else {
            // 工具栏本身已经有一层玻璃胶囊：这里不再叠自己的背景，只保留内容。
            VStack(spacing: 0) {
                videoToolbarInfoLine(photo)
                HStack(spacing: 6) {
                    VideoToolbarProgress(model: videoModel,
                                         session: viewer.playbackSession,
                                         showsRemaining: $videoShowsRemainingTime,
                                         chapterFractions: toolbarChapterFractions)
                        .frame(maxWidth: .infinity)
                    // 音量收在进度右端：移入图标向左展开一条可拖动的小轨道，不占常驻宽度。
                    VideoInlineVolume(model: videoModel)
                }
            }
            .padding(.horizontal, 12)
            // 两行内容贴住胶囊上沿时会被切掉：顶部留出一点余量，底部相应收紧，整体高度不变。
            .padding(.top, 5)
            .padding(.bottom, 0)
            // 固定宽度：尽量容下标题 / 时间 / 地点 / 序号，翻页时不再左右跳动。
            .frame(width: 560)
        }
    }

    /// 当前播放项是否来自影院（且与查看器里的条目对得上）。
    private func cinemaEntry(for photo: PhotoItem) -> CinemaEntry? {
        guard let entry = store.cinemaPlaybackEntry, entry.file.photoID == photo.id else { return nil }
        return entry
    }

    /// 影院信息行：只保留「正在放映」的必要信息，并随舱宽分级收放。
    /// 宽：片名 + 类型年份 + 季集号 + 评分 + 画质；中：去类型与画质；
    /// 窄：只留片名 + 季集号；队列位置与「下一集」始终靠右，窄舱下按钮退化成图标。
    private func cinemaToolbarInfoLine(_ entry: CinemaEntry, width: CGFloat) -> some View {
        let wide = width >= 560
        let regular = width >= 470
        let specs = wide ? cinemaBadgeTags(entry.file, limit: 1) : []
        let episode = cinemaEpisodeCode(entry)
        let next = entry.kind == .tv ? store.cinemaQueueNeighbor(of: entry.id, delta: 1) : nil
        return HStack(spacing: 5) {
            // 左右各留一段可伸缩空白：片名与标签整体居中，光标不用去最左边找。
            Spacer(minLength: 6)
            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.01)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(cinemaTitleHelp(entry))

            if wide {
                let kindText = entry.kind == .tv ? "剧集" : "电影"
                Text(entry.year.map { "\(kindText) · \($0)" } ?? kindText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.52))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    .fixedSize()
                    .help(entry.year.map { "\(kindText) · \($0) 年" } ?? kindText)
            }

            if let episode {
                Text(episode)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                    }
                    .fixedSize()
                    .help(cinemaEpisodeHelp(entry))
            }

            if regular, let rating = entry.rating ?? entry.doubanRating, rating > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5))
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(LumaBrand.amber)
                .fixedSize()
                .help("评分 \(String(format: "%.1f", rating))")
            }

            ForEach(specs, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.50))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .fixedSize()
            }

            Spacer(minLength: 4)

            if let currentIndex, regular {
                Text("\(currentIndex + 1)/\(totalCount)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.48))
                    .lineLimit(1)
                    .fixedSize()
                    .help(entry.kind == .tv
                          ? "队列位置：第 \(currentIndex + 1) / \(totalCount) 集"
                          : "队列位置：第 \(currentIndex + 1) / \(totalCount) 部")
            }

            if let next {
                Button {
                    _ = store.stepCinemaQueue(1)
                } label: {
                    HStack(spacing: 3) {
                        if wide || regular { Text("下一集") }
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.horizontal, wide || regular ? 6 : 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("下一集：\(cinemaNextEpisodeHelp(next))")
            }

            // 音轨 / 字幕 / 比例入口按真实宽度占位，不再浮在文字上方。
            VideoMediaMenuButtons(ui: videoUI, model: videoModel, style: .toolbar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    private func cinemaTitleHelp(_ entry: CinemaEntry) -> String {
        guard let original = entry.originalTitle,
              !original.isEmpty,
              original != entry.title else { return entry.title }
        return "\(entry.title)（\(original)）"
    }

    /// 季集号：第1季·第1集；一次包含多集时写成第1季·第1-3集。
    private func cinemaEpisodeCode(_ entry: CinemaEntry) -> String? {
        guard entry.kind == .tv else { return nil }
        if let season = entry.season, let episode = entry.episode {
            if let end = entry.episodeEnd, end > episode {
                return "第\(season)季·第\(episode)-\(end)集"
            }
            return "第\(season)季·第\(episode)集"
        }
        if let episode = entry.episode {
            if let end = entry.episodeEnd, end > episode {
                return "第\(episode)-\(end)集"
            }
            return "第\(episode)集"
        }
        return nil
    }

    private func cinemaEpisodeHelp(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let season = entry.season { parts.append("第 \(season) 季") }
        if let episode = entry.episode {
            if let end = entry.episodeEnd, end > episode {
                parts.append("第 \(episode)–\(end) 集")
            } else {
                parts.append("第 \(episode) 集")
            }
        }
        return parts.isEmpty ? "剧集" : parts.joined(separator: " · ")
    }

    private func cinemaNextEpisodeHelp(_ entry: CinemaEntry) -> String {
        let code = cinemaEpisodeCode(entry)
        return code.map { "\($0) · \(entry.title)" } ?? entry.title
    }

    // MARK: - 网络资源播放舱

    /// 当前播放项是否来自网络资源（网页源分集）。
    private func catalogContext(for photo: PhotoItem) -> CatalogPlaybackContext? {
        store.catalogPlaybackContext(for: photo.id)
    }

    private func catalogCoverURL(_ context: CatalogPlaybackContext) -> String {
        context.episode.coverURL.isEmpty ? context.item.coverURL : context.episode.coverURL
    }

    /// 站点备注里的评分：`更新至 7 集 · 8.1 分` → 8.1。
    private func catalogRating(from remark: String) -> Double? {
        for part in remark.split(separator: "·") {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard text.hasSuffix("分"),
                  let value = Double(text.dropLast().trimmingCharacters(in: .whitespaces)) else { continue }
            return value
        }
        return nil
    }

    /// 网络资源信息行：片名 / 来源站点 / 分集号 / 站点评分，右端是队列位置与「下一集」。
    /// 来源站点用它的强调色圆点标记，相当于直播里的台标身份。
    private func catalogToolbarInfoLine(_ context: CatalogPlaybackContext,
                                        photo: PhotoItem,
                                        width: CGFloat) -> some View {
        let wide = width >= 560
        let regular = width >= 470
        let remark = context.item.remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let rating = catalogRating(from: remark)
        let hasNext = store.hasAdjacentVideo(from: photo.id, delta: 1)
        return HStack(spacing: 5) {
            // 左右各留一段可伸缩空白：片名与来源 / 分集整体居中。
            Spacer(minLength: 6)
            Text(context.item.title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.01)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(context.item.title)

            // 来源站点：颜色圆点常驻，名称在常规宽度以上出现。
            HStack(spacing: 3) {
                Circle()
                    .fill(context.source.kind.sidebarTint)
                    .frame(width: 5, height: 5)
                if wide || regular {
                    Text(context.source.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.52))
                        .lineLimit(1)
                        .frame(maxWidth: 72, alignment: .leading)
                }
            }
            .fixedSize()
            .help("来源：\(context.source.name)")

            Text(context.episode.title)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                }
                .fixedSize()
                .help(context.episode.title)

            if regular, let rating {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7.5))
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(LumaBrand.amber)
                .fixedSize()
                .help("站点评分 \(String(format: "%.1f", rating))")
            } else if wide, !remark.isEmpty, rating == nil {
                // 没有评分时退回站点自己的更新备注，只露出一小段，悬停看全文。
                Text(remark.count > 12 ? String(remark.prefix(12)) + "…" : remark)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.46))
                    .lineLimit(1)
                    .fixedSize()
                    .help(remark)
            }

            Spacer(minLength: 4)

            if let currentIndex, regular {
                Text("\(currentIndex + 1)/\(totalCount)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.48))
                    .lineLimit(1)
                    .fixedSize()
                    .help("播放列表位置：\(currentIndex + 1) / \(totalCount)")
            }

            if hasNext {
                Button {
                    store.viewerStepVideo(1)
                } label: {
                    HStack(spacing: 3) {
                        if wide || regular { Text("下一集") }
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.horizontal, wide || regular ? 6 : 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("播放下一集")
            }

            VideoMediaMenuButtons(ui: videoUI, model: videoModel, style: .toolbar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// 播放舱第一行：与原先顶栏信息一致，标题 / 实况 / 日期时间 / 地点 / 圆环与序号全部保留。
    private func videoToolbarInfoLine(_ photo: PhotoItem) -> some View {
        let tvName = tvChannelName(for: photo)
        let title = burstTitle ?? tvName ?? infoTitle(for: photo)
        let showsLead = title != nil || photo.isLivePhoto
        return HStack(spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(-0.01)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if photo.isLivePhoto {
                liveTag
            }

            if showsLead {
                infoSeparator
            }

            if tvName == nil {
                if photo.hasKnownCaptureDate {
                    captureStamp(photo.capturedAt, size: 11)
                } else {
                    Text("时间未知")
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
            }

            if let place = infoPlaceLine(for: photo) {
                infoSeparator
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(place)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
            }

            if let currentIndex {
                infoSeparator
                progressRing
                // 与照片模式的序号写法一致：当前序号 + 总数，播放舱变宽后不再省略总数。
                HStack(spacing: 2) {
                    Text("\((currentIndex + 1).formatted())")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Text("/ \(totalCount.formatted())")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                .lineLimit(1)
                .fixedSize()
            }

        }
        // 信息行整体居中，音轨 / 字幕按钮浮在右端，避免把信息拽到左侧。
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            // 音轨 / 字幕入口：与画面内控制条、顶栏保持同一份状态。
            VideoMediaMenuButtons(ui: videoUI, model: videoModel, style: .toolbar)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// 播放舱进度条的章节刻度：与画面内进度条同一份章节数据。
    private var toolbarChapterFractions: [Double] {
        guard videoModel.duration > 0 else { return [] }
        return videoUI.chapters
            .map { min(1, max(0, $0.start / videoModel.duration)) }
            .filter { $0 > 0.01 && $0 < 0.99 }
    }

    private func rotateVideoPlayer() {
        store.rotateVideoDisplayCommand()
    }

    private func toggleVideoFullScreen() {
        store.toggleVideoFullScreenCommand()
    }

    /// 保存当前帧：与画面朝向一致，由查看器统一保存（顶栏与画面内控制条共用）。
    private func captureVideoFrame() {
        store.saveVideoFrameCommand()
    }

    // MARK: - 电视直播：工具栏动作

    /// 时移开关：进入时暂停直播回看刚过去的画面，再点一次回到直播边缘。
    private func toggleTVTimeshift() {
        if viewer.tvTimeshiftActive {
            viewer.tvTimeshiftActive = false
            videoModel.requestSeek(to: max(0, videoModel.bufferedEndTime - 0.5))
            videoModel.play()
            store.showToast("已回到直播")
        } else {
            videoModel.pause()
            viewer.tvTimeshiftActive = true
        }
    }

    /// 顶栏中部的照片信息：地点 / 实况 / 拍摄时间 / 地理位置 / 序号。
    /// 单行紧凑排版，高度严格控制在工具栏内，既不裁切也不会把旁边的控件顶大。
    private func viewerToolbarInfo(_ photo: PhotoItem) -> some View {
        let tvName = tvChannelName(for: photo)
        let title = burstTitle ?? tvName ?? infoTitle(for: photo)
        let showsLead = title != nil || photo.isLivePhoto
        return HStack(spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(-0.01)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if photo.isLivePhoto {
                liveTag
            }

            if showsLead {
                Capsule()
                    .fill(Color.primary.opacity(0.20))
                    .frame(width: 1, height: 12)
            }

            if tvName == nil {
                if photo.hasKnownCaptureDate {
                    captureStamp(photo.capturedAt, size: 11.5)
                } else {
                    Text("时间未知")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .lineLimit(1)
                }
            }

            if let place = infoPlaceLine(for: photo) {
                infoSeparator
                HStack(spacing: 2) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(place)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineLimit(1)
                }
            }

            if let currentIndex {
                infoSeparator
                progressRing
                HStack(spacing: 2) {
                    Text("\((currentIndex + 1).formatted())")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    Text("/ \(totalCount.formatted())")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            // 工具栏底下可能是深色照片，必须用不透明度更高的材质托底才看得清。
            Capsule().fill(.regularMaterial)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .help(photo.displayTitle)
        .accessibilityElement(children: .combine)
    }

    /// 拍摄时间：年月日 + 时分秒。突出「月日」，时间整体弱化成次级信息；
    /// 秒不加强调色，保持顶栏安静。
    private func captureStamp(_ date: Date, size: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(DateText.dayFormatter.string(from: date))
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary.opacity(0.95))
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 0.8, height: size - 2)
            Text(DateText.secondTimeFormatter.string(from: date))
                .foregroundStyle(Color.primary.opacity(0.58))
        }
        .font(.system(size: size, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("拍摄于 \(DateText.dayFormatter.string(from: date)) "
                            + DateText.secondTimeFormatter.string(from: date))
    }

    /// 实况标记：和地点、时间同一套信息语言，不再依赖画面上的角标。
    private var liveTag: some View {
        HStack(spacing: 2) {
            Image(systemName: "livephoto")
                .font(.system(size: 8.5, weight: .semibold))
            Text("实况")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.accentColor.opacity(0.13), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 0.5)
        }
    }

    private var infoSeparator: some View {
        Circle()
            .fill(Color.primary.opacity(0.28))
            .frame(width: 2.5, height: 2.5)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.28), lineWidth: 1.7)
            Circle()
                .trim(from: 0, to: progressFraction)
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .animation(settings.motion.overlay, value: progressFraction)
    }

    /// 缩放胶囊左侧的小圆环：随放大程度填充，让百分比多一层直觉读数。
    private var zoomRing: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: zoomRingFraction)
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 9, height: 9)
    }

    /// 放大范围 1x–5x 映射到圆环的 0–1。
    private var zoomRingFraction: CGFloat {
        min(1, max(0, (zoom - 1) / 4))
    }

    /// 连拍标题：与官方「照片」一致，显示整组的有效成员数。
    private var burstTitle: String? {
        guard burstMembers.count > 1 else { return nil }
        return "连拍快照（\(burstMembers.count) 张照片）"
    }

    /// 连拍顶栏用带秒的时间，与官方「照片」的「09:22:40」一致。
    private static let burstTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 顶栏主标题：与信息面板 / 网格地点标签同一套层级（街道 → 城市 → 区县 → 省 → 国家）。
    /// 没有地点信息时返回 nil，顶栏只显示时间与序号，不用文件名冒充标题。
    private func infoTitle(for photo: PhotoItem) -> String? {
        photo.placeTitle
    }

    /// 电视直播的频道名：直播没有真实拍摄时间，顶栏用它替代日期时间。
    private func tvChannelName(for photo: PhotoItem) -> String? {
        store.tvPlaybackChannel(for: photo.id)?.name
    }

    /// 地点副行：标题已占用街道时补城市 / 区县，标题是城市时补区县或省份。
    /// 没有地名但有坐标时显示经纬度；完全没有地理信息时整段隐藏。
    private func infoPlaceLine(for photo: PhotoItem) -> String? {
        if let subtitle = photo.placeSubtitle { return subtitle }
        return coordinateText(for: photo)
    }

    /// 经纬度文案：地名还没解析出来时用它兜底，避免定位段整段消失。
    private func coordinateText(for photo: PhotoItem) -> String? {
        guard let latitude = photo.latitude, let longitude = photo.longitude,
              CoordinateValidator.isValid(latitude: latitude, longitude: longitude) else {
            return nil
        }
        let lat = String(format: "%.2f°%@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat) · \(lon)"
    }

    /// 窗口内浏览的工具栏：返回、缩放、拍摄时间 / 序号、操作。
    @ToolbarContentBuilder
    private var embeddedToolbar: some ToolbarContent {
        if let photo {
            ToolbarItem(placement: .navigation) {
                // 返回与视频播放控制放在同一个工具栏项里：系统会把它们收进同一块玻璃胶囊，
                // 和照片模式一样只占最左侧一条，不再多出一块悬空的控制条。
                HStack(spacing: 8) {
                    Button {
                        // 视频全屏里「返回」只退出系统全屏：画面继续播放，查看器不关、不回列表。
                        if viewer.videoImmersiveFullScreen {
                            FullScreenDiagnostics.log("toolbarBack -> exit fullscreen")
                            hostWindow?.toggleFullScreen(nil)
                        } else {
                            FullScreenDiagnostics.log("toolbarBack -> close viewer")
                            store.closeViewer()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(viewer.videoImmersiveFullScreen ? "退出全屏 (Esc)" : "返回图库 (Esc)")

                    if showsVideoToolbarControls {
                        let episodeMode = store.usesEpisodeTransport(for: photo)
                        VideoToolbarTransport(model: videoModel,
                                              hasPrev: episodeMode
                                                  ? store.hasAdjacentVideo(from: photo.id, delta: -1) : true,
                                              hasNext: episodeMode
                                                  ? store.hasAdjacentVideo(from: photo.id, delta: 1) : true,
                                              onPrev: {
                            if episodeMode {
                                store.viewerStepVideo(-1)
                            } else {
                                store.viewerStep(-1)
                            }
                        },
                                              onNext: {
                            if episodeMode {
                                store.viewerStepVideo(1)
                            } else {
                                store.viewerStep(1)
                            }
                        },
                                              seekStep: settings.videoSeekStep,
                                              episodeMode: episodeMode)
                    }
                }
                .padding(.horizontal, showsVideoToolbarControls ? 3 : 0)
            }

            // 连拍选择模式：与官方「照片」一致，左上角显示「连拍快照（N张照片）」。
            if viewer.burstSelectionMode, !burstMembers.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Text(burstTitle ?? "连拍快照")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ToolbarItem(placement: .navigation) {
                // 工具栏里不再放整条缩放滑杆（在玻璃工具栏里会撑成一条空白长条）；
                // 只在放大后显示一个紧凑的缩放胶囊，点一下回到适应窗口。
                if zoom > 1.01 {
                    Button {
                        resetZoom()
                    } label: {
                        // 背景与内容放在同一个固定尺寸的容器里：
                        // 之前胶囊按内容自适应，工具栏会在缩放时把它压窄，百分比就溢出到胶囊外。
                        ZStack {
                            Capsule().fill(Color.accentColor.opacity(0.14))
                            Capsule().strokeBorder(
                                LinearGradient(colors: [Color.accentColor.opacity(0.55),
                                                        Color.accentColor.opacity(0.15)],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing),
                                lineWidth: 0.6)
                            HStack(spacing: 4) {
                                zoomRing
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .fixedSize()
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 64, height: 20)
                        .contentShape(Capsule())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("恢复到适应窗口 (0)")
                    .animation(settings.motion.overlay, value: zoom)
                }
            }

            // 地点 / 实况 / 拍摄时间 / 序号：与顶部工具栏同一行；连拍时换成官方的两行信息。
            ToolbarItem(placement: .principal) {
                if showsVideoToolbarControls {
                    videoToolbarDeck(photo)
                } else {
                    principalInfo(photo)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewer.burstSelectionMode, !burstMembers.isEmpty {
                    // 与官方「照片」一致：完成选择只保留「取消 / 完成」两个按钮。
                    Button("取消") {
                        endBurstSelection()
                    }
                    .help("取消连拍选择")

                    Button("完成") {
                        endBurstSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .help("完成连拍选择")
                } else {
                    // 视频规格与照片操作共用同一块操作胶囊：
                    // 播放选项 / 全屏排在信息、胶片条等照片操作之前，顺序与参考图一致。
                    if showsVideoToolbarControls {
                        VideoToolbarOptions(model: videoModel,
                                            settings: settings,
                                            quarterTurns: viewer.videoQuarterTurns,
                                            onRotate: rotateVideoPlayer,
                                            onCapture: captureVideoFrame)
                        VideoDeckButton(icon: "arrow.up.left.and.arrow.down.right",
                                        help: "全屏 (F)",
                                        action: toggleVideoFullScreen)

                        // 电视频道：直播动作 + 频道动作全部收进工具栏，
                        // 与画面 OSD 共用同一个动作组，顺序与行为不会各写一套。
                        if let channel = store.tvPlaybackChannel(for: photo.id) {
                            TVChannelActionCluster(channel: channel,
                                                   photoID: photo.id,
                                                   isLive: !channel.isCatchUp,
                                                   timeshiftActive: $viewer.tvTimeshiftActive,
                                                   showGuide: $viewer.tvGuideShown,
                                                   style: .toolbar,
                                                   onToggleTimeshift: toggleTVTimeshift,
                                                   onCapture: captureVideoFrame)
                        }
                    }

                    // 电视频道：信息 / 胶片条 / 共享 / 收藏照片 / 幻灯片 / 编辑这些照片向操作没有意义，
                    // 全部交给播放页的频道工具，工具栏只保留播放器通用能力。
                    if store.tvPlaybackChannel(for: photo.id) == nil {
                        Button {
                            viewer.showInfoPanel.toggle()
                        } label: {
                            Image(systemName: viewer.showInfoPanel ? "info.circle.fill" : "info.circle")
                        }
                        .help("信息")

                        // 连拍的帧条只在选择模式浮出，普通浏览时不提供胶片条开关。
                        if burstMembers.isEmpty {
                            Button {
                                settings.viewerFilmstrip.toggle()
                            } label: {
                                Image(systemName: "film")
                            }
                            .foregroundStyle(settings.viewerFilmstrip ? Color.accentColor : Color.primary)
                            .help(settings.viewerFilmstrip ? "隐藏底部缩略图" : "显示底部缩略图")
                        }

                        ShareLink(items: store.shareURLs) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(store.shareURLs.isEmpty)
                        .help("共享")

                        if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                            Button {
                                store.toggleFavorite(photo.id)
                            } label: {
                                Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                            }
                            .foregroundStyle(photo.isFavorite ? Color.pink : Color.primary)
                            .help(photo.isFavorite ? "取消收藏" : "收藏")
                        }

                        if !photo.isVideo, (!photo.isReadOnly || photo.isSystem), store.canScanBeauty {
                            Button {
                                store.showBeautyPanel = true
                            } label: {
                                Image(systemName: "wand.and.stars")
                            }
                            .help("智能美化…")
                        }

                        Button {
                            store.presentSlideshow()
                        } label: {
                            Image(systemName: "play.rectangle")
                        }
                        .disabled(store.visibleCount == 0)
                        .help("幻灯片播放")

                        if burstMembers.count > 1 {
                            Button {
                                toggleBurstPlayback()
                            } label: {
                                Image(systemName: viewer.burstPlaying ? "pause.fill" : "play.fill")
                            }
                            .help(viewer.burstPlaying ? "暂停连拍播放 (P)" : "播放连拍快照 (P)")
                        }

                        moreMenu(photo)

                        if !photo.isVideo,
                           !photo.isReadOnly || (photo.isSystem && store.canWriteSystemLibrary) {
                            Button {
                                store.openEditor(photo.id)
                            } label: {
                                Text("编辑")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("编辑照片")
                        }
                    }
                }
            }
        }
    }

    /// 顶栏中部信息：连拍时按官方「照片」排成两行（标题 / 连拍标签 + 日期 + 组内序号）。
    @ViewBuilder
    private func principalInfo(_ photo: PhotoItem) -> some View {
        if burstMembers.isEmpty {
            viewerToolbarInfo(photo)
        } else if viewer.burstSelectionMode {
            // 选择模式：上行「日期 时间 · i/N」，下行「进行选择」。
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(DateText.dayFormatter.string(from: photo.capturedAt))
                    Text(Self.burstTimeFormatter.string(from: photo.capturedAt))
                    if let currentIndex {
                        Text("·")
                        Text("\(currentIndex + 1)/\(burstMembers.count)")
                            .contentTransition(.numericText())
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

                Text("进行选择")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
        } else {
            // 普通浏览：上行地点标题，下行「连拍快照（N张照片） · 日期 时间 · i/N」。
            VStack(spacing: 1) {
                if let title = infoTitle(for: photo) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(-0.01)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(burstTitle ?? "连拍快照")
                    Text("·")
                    Text(DateText.dayFormatter.string(from: photo.capturedAt))
                    Text(Self.burstTimeFormatter.string(from: photo.capturedAt))
                    if let currentIndex {
                        Text("·")
                        Text("\(currentIndex + 1)/\(burstMembers.count)")
                            .contentTransition(.numericText())
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 退出连拍选择模式（取消与完成都只收起选择，不改动照片）。
    private func endBurstSelection() {
        viewer.burstSelectionMode = false
        viewer.burstSelection = []
    }

    private func stage(_ photo: PhotoItem) -> some View {
        GeometryReader { proxy in
            // 角标要打在照片本身上：先按实际显示尺寸算出照片在舞台里的留边，
            // 竖图 / 宽图两侧或上下的空白区域不能出现「人像」「实况」和定位图钉。
            let shownForBadges = image ?? animatedImage ?? placeholder
            let fittedForBadges = shownForBadges.map { fittedSize($0, in: proxy.size) } ?? proxy.size
            let imageInsetX = max(0, (proxy.size.width - fittedForBadges.width) / 2)
            let imageInsetY = max(0, (proxy.size.height - fittedForBadges.height) / 2)
            // 全屏时顶部还有一排 chrome 按钮，角标再往下让一档。
            let badgeTop = max(imageInsetY + 14, embedded ? 14 : 58)
            ZStack {
                if photo.isVideo {
                    // 视频只缩放画面本身，播放控件保持原尺寸；放大后同样可以拖动。
                    VideoPlayerStage(photo: photo,
                                     model: videoModel,
                                     ui: videoUI,
                                     quarterTurns: $viewer.videoQuarterTurns,
                                     onCaptureFrame: { captureVideoFrame() },
                                     transparentBackground: embedded,
                                     zoom: zoom,
                                     offset: offset)
                        .simultaneousGesture(magnifyGesture(stage: proxy.size, fitted: proxy.size))
                        .simultaneousGesture(panGesture(
                            stage: proxy.size,
                            fitted: proxy.size,
                            bottomGuard: settings.videoControlPlacement == .topIntegrated && embedded ? 0 : 170))
                } else if livePlaying, let livePlayer {
                    // 实况就在照片原位播放：尺寸与静态照片完全一致，
                    // 不走视频播放器，也不显示时长 / 进度 / 播放信息。
                    let fitted = image.map { fittedSize($0, in: proxy.size) }
                    LivePhotoLayerView(player: livePlayer)
                        .frame(width: fitted?.width ?? proxy.size.width,
                               height: fitted?.height ?? proxy.size.height)
                } else if photo.playsAnimation, let animated = animatedImage {
                    // 动图在查看器里直接播放，不需要额外的播放按钮。
                    let fitted = fittedSize(animated, in: proxy.size)
                    AnimatedImageView(image: animated)
                        .frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .shadow(color: .black.opacity(embedded ? 0.28 : 0),
                                radius: embedded ? 20 : 0,
                                y: embedded ? 8 : 0)
                } else if let shown = image ?? placeholder {
                    let fitted = fittedSize(shown, in: proxy.size)
                    ZStack {
                        // 占位层一直垫在下面，全尺寸图淡入时不会出现“先糊后清”的跳变。
                        if let placeholder {
                            Image(nsImage: placeholder)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                        }
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(offset)
                    .shadow(color: .black.opacity(embedded ? 0.28 : 0),
                            radius: embedded ? 20 : 0,
                            y: embedded ? 8 : 0)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(embedded ? Color.secondary : Color.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { stageSize = proxy.size }
            .onChange(of: proxy.size) { _, size in stageSize = size }
            .overlay {
                if !photo.isVideo, let shown = image ?? animatedImage ?? placeholder, !livePlaying {
                    let fitted = fittedSize(shown, in: proxy.size)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    toggleZoom(at: value.location, stage: proxy.size, fitted: fitted)
                                }
                        )
                        .simultaneousGesture(magnifyGesture(stage: proxy.size, fitted: fitted))
                        .simultaneousGesture(panGesture(stage: proxy.size, fitted: fitted))
                }
            }
            .clipped()
            // 画面角标：连拍「进行选择…」与 RAW / 人像 / 实况角标一起贴在照片左上内侧；
            // 已识别并命名的人物，名字紧跟角标打在照片上。
            .overlay(alignment: .topLeading) {
                let names = showsStageBadges(photo) ? store.personNames(for: photo.id) : []
                VStack(alignment: .leading, spacing: 6) {
                    if burstMembers.count > 1, !viewer.burstSelectionMode {
                        burstSelectBadge
                    }
                    if showsStageBadges(photo), hasStageBadgeContent(photo) {
                        HStack(spacing: 6) {
                            if photo.isRAWFile {
                                rawBadge
                            }
                            if photo.isPortraitCapture {
                                portraitBadge
                                    .allowsHitTesting(false)
                            }
                            if livePhotoURL(for: photo) != nil {
                                Button {
                                    toggleLivePhoto()
                                } label: {
                                    liveStageBadge
                                }
                                .buttonStyle(.plain)
                                .help("播放实况照片 (L)")
                            }
                        }
                    }
                    if showsStageBadges(photo), !names.isEmpty {
                        personNameRow(names)
                    }
                }
                .padding(.leading, imageInsetX + 14)
                .padding(.top, badgeTop)
            }
            .overlay(alignment: .topTrailing) {
                if showsStageBadges(photo), photo.hasLocation {
                    locationBadge
                        .padding(.trailing, imageInsetX + 14)
                        .padding(.top, badgeTop)
                }
            }
            // 连拍选择模式：照片右下角的圆形勾选，与官方「照片」一致，点按勾选当前这一张。
            .overlay(alignment: .bottomTrailing) {
                if viewer.burstSelectionMode, !burstMembers.isEmpty {
                    Button {
                        store.toggleBurstSelection(photo.id)
                    } label: {
                        Image(systemName: viewer.burstSelection.contains(photo.id)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, imageInsetX + 16)
                    .padding(.bottom, imageInsetY + 16)
                    .help(viewer.burstSelection.contains(photo.id) ? "取消勾选这张" : "勾选这张")
                }
            }
        }
    }

    /// 照片本体上的左上角标（RAW / 人像 / 实况）是否有内容。
    private func hasStageBadgeContent(_ photo: PhotoItem) -> Bool {
        photo.isRAWFile || photo.isPortraitCapture || livePhotoURL(for: photo) != nil
    }

    /// 照片本体上的角标只在静态照片、未缩放时出现；实况播放与放大查看时让位给画面。
    private func showsStageBadges(_ photo: PhotoItem) -> Bool {
        guard !photo.isVideo, !livePlaying, zoom <= 1.01 else { return false }
        return hasStageBadgeContent(photo) || photo.hasLocation
            || !store.personNames(for: photo.id).isEmpty
    }

    // MARK: - 画面角标

    /// RAW 照片的画面角标：与「人像」「实况」同一套深色胶囊。
    private var rawBadge: some View {
        Text("RAW")
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color.black.opacity(0.38), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
    }

    /// 已命名人物：一行小胶囊打在照片上，超过 3 人折叠成 +N。
    private func personNameRow(_ names: [PhotoPersonName]) -> some View {
        HStack(spacing: 5) {
            ForEach(names.prefix(3)) { person in
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(person.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.38), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
            }
            if names.count > 3 {
                Text("+\(names.count - 3)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.38), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
        .allowsHitTesting(false)
    }

    /// 连拍「进行选择…」：与官方「照片」一致，贴在照片左上角的深色胶囊。
    private var burstSelectBadge: some View {
        Button {
            beginBurstSelection()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("进行选择…")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.45), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("进行选择…")
    }

    /// 实况照片的画面角标：与「人像」同一套深色胶囊，点击即原位播放。
    private var liveStageBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: livePlaying ? "pause.fill" : "livephoto.play")
                .font(.system(size: 9.5, weight: .semibold))
            Text("实况")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.black.opacity(0.38), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    /// 人像照片的角标，与系统「照片」一致：画面左上角的「人像」胶囊。
    private var portraitBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Color.white.opacity(0.18), in: Circle())
            Text("人像")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.38), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    /// 带定位信息的照片：右上角地图图钉，点击打开信息面板查看地点与地图。
    private var locationBadge: some View {
        Button {
            withAnimation(settings.motion.overlay) { viewer.showInfoPanel = true }
        } label: {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .background(Color.black.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help("查看位置信息")
        .accessibilityLabel("查看位置信息")
    }

    // MARK: - Zoom math

    private func fittedSize(_ image: NSImage, in stage: CGSize) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0, stage.width > 0, stage.height > 0 else {
            return .zero
        }
        let scale = min(stage.width / size.width, stage.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func clampedOffset(_ proposed: CGSize, stage: CGSize,
                               fitted: CGSize, zoom: CGFloat) -> CGSize {
        guard zoom > 1 else { return .zero }
        let maxX = max(0, (fitted.width * zoom - stage.width) / 2)
        let maxY = max(0, (fitted.height * zoom - stage.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    /// 以某个视图坐标为锚点缩放，保持该点下的画面不动。
    private func zoomedOffset(around location: CGPoint, stage: CGSize,
                              oldZoom: CGFloat, oldOffset: CGSize, newZoom: CGFloat) -> CGSize {
        let p = CGPoint(x: location.x - stage.width / 2, y: location.y - stage.height / 2)
        let q = CGPoint(x: (p.x - oldOffset.width) / max(oldZoom, 0.0001),
                        y: (p.y - oldOffset.height) / max(oldZoom, 0.0001))
        return CGSize(width: p.x - q.x * newZoom, height: p.y - q.y * newZoom)
    }

    private func magnifyGesture(stage: CGSize, fitted: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                    pinchStartOffset = offset
                }
                guard let startZoom = pinchStartZoom else { return }
                let newZoom = min(5, max(1, startZoom * value.magnification))
                let proposed = zoomedOffset(around: value.startLocation, stage: stage,
                                            oldZoom: startZoom, oldOffset: pinchStartOffset,
                                            newZoom: newZoom)
                zoom = newZoom
                offset = clampedOffset(proposed, stage: stage, fitted: fitted, zoom: newZoom)
            }
            .onEnded { _ in
                pinchStartZoom = nil
                baseOffset = offset
                if zoom <= 1.01 {
                    withAnimation(.easeOut(duration: 0.22)) {
                        zoom = 1
                        offset = .zero
                        baseOffset = .zero
                    }
                }
            }
    }

    private func panGesture(stage: CGSize, fitted: CGSize,
                            bottomGuard: CGFloat = 0) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                // 视频底部是播放控件（进度条可拖动），从这一区域开始的拖动留给播放器。
                if bottomGuard > 0, value.startLocation.y > stage.height - bottomGuard { return }
                let proposed = CGSize(width: baseOffset.width + value.translation.width,
                                      height: baseOffset.height + value.translation.height)
                offset = clampedOffset(proposed, stage: stage, fitted: fitted, zoom: zoom)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func toggleZoom(at location: CGPoint, stage: CGSize, fitted: CGSize) {
        let target: CGFloat = zoom > 1.01 ? 1 : 2.5
        let proposed = target > 1
            ? clampedOffset(zoomedOffset(around: location, stage: stage, oldZoom: zoom,
                                         oldOffset: offset, newZoom: target),
                            stage: stage, fitted: fitted, zoom: target)
            : .zero
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            zoom = target
            offset = proposed
        }
        baseOffset = proposed
        pinchStartZoom = nil
    }

    private func adjustZoom(by factor: CGFloat) {
        let oldZoom = zoom
        let target = min(5, max(1, zoom * factor))
        let ratio = target / max(oldZoom, 0.0001)
        withAnimation(.easeInOut(duration: 0.2)) {
            zoom = target
            if target <= 1.01 {
                offset = .zero
                baseOffset = .zero
            } else {
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
            }
        }
        pinchStartZoom = nil
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            zoom = 1
            offset = .zero
        }
        baseOffset = .zero
        pinchStartZoom = nil
    }

    private func chrome(_ photo: PhotoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                circleButton("xmark") { store.closeViewer() }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DateText.fullFormatter.string(from: photo.capturedAt))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(burstTitle ?? photo.displayTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                    circleButton(photo.isFavorite ? "heart.fill" : "heart") {
                        store.toggleFavorite(photo.id)
                    }
                    .help(photo.isFavorite ? "取消收藏" : "收藏")
                }

                if burstMembers.count > 1 {
                    circleButton(viewer.burstPlaying ? "pause.fill" : "play.fill") {
                        toggleBurstPlayback()
                    }
                    .help(viewer.burstPlaying ? "暂停连拍播放 (P)" : "播放连拍快照 (P)")
                }

                circleButton("info.circle") {
                    viewer.showInfoPanel.toggle()
                }
                .help("信息")

                circleButton("questionmark.circle") {
                    showShortcutHelp.toggle()
                }
                .help("键盘快捷键")
                .popover(isPresented: $showShortcutHelp, arrowEdge: .bottom) {
                    ShortcutHelpView()
                }

                if !photo.isVideo,
                   !photo.isReadOnly || (photo.isSystem && store.canWriteSystemLibrary) {
                    circleButton("slider.horizontal.3") {
                        store.openEditor(photo.id)
                    }
                    .help("编辑")
                }

                moreMenu(photo)

                if photo.isCloud, store.isCurrentCloudWritable {
                    circleButton("trash") {
                        store.confirmDeleteCloud([photo.id])
                    }
                    .help("从云端删除")
                } else if !photo.isReadOnly {
                    circleButton("trash") {
                        store.confirmDelete([photo.id])
                    }
                    .help("删除")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.top, 16)

            Spacer()

            if settings.viewerFilmstrip, totalCount > 1, !photo.isVideo,
               viewer.burstSelectionMode || burstMembers.isEmpty {
                FilmstripView(items: items,
                              currentID: photo.id,
                              selection: viewer.burstSelectionMode && !burstMembers.isEmpty
                                  ? viewer.burstSelection : nil) { id in
                    if viewer.burstSelectionMode, !burstMembers.isEmpty {
                        store.toggleBurstSelection(id)
                    } else {
                        viewer.viewerID = id
                    }
                }
                .padding(.bottom, 10)
            }

            HStack(spacing: 12) {
                if viewer.burstSelectionMode, !burstMembers.isEmpty {
                    Text("已选 \(viewer.burstSelection.count) / \(burstMembers.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                    Button("全选") { store.selectAllBurstMembers() }
                        .buttonStyle(.plain)
                    Button {
                        store.favoriteBurstSelection()
                    } label: {
                        Image(systemName: "heart")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewer.burstSelection.isEmpty)
                    .help("收藏所选")
                    Button {
                        confirmBurstKeep = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewer.burstSelection.isEmpty)
                    .help("保留所选，删除其余")
                    Button("完成") {
                        endBurstSelection()
                    }
                    .buttonStyle(.plain)
                    .help("完成连拍选择")
                } else {
                    if !photo.isVideo {
                        zoomControls
                        Divider()
                            .frame(height: 14)
                            .overlay(.white.opacity(0.18))
                    }
                    if let currentIndex {
                        Text("\(currentIndex + 1) / \(totalCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 18)
        }

        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
                .allowsHitTesting(false)
        }
    }

    private func moreMenu(_ photo: PhotoItem) -> some View {
        Menu {
            Button("导出…") { store.export(photo.id) }
            Button("打印…") { store.printCommand() }
            // 窗口内浏览时，幻灯片 / 胶片条 / 信息 / 收藏 / 共享都在工具栏右侧有独立按钮，
            // 菜单里不再重复；全屏查看器的顶部只有一排圆钮，这些入口继续保留在这里。
            if !embedded {
                Button("幻灯片播放") { store.presentSlideshow() }
                Button(settings.viewerFilmstrip ? "隐藏底部缩略图" : "显示底部缩略图") {
                    settings.viewerFilmstrip.toggle()
                }
                Button(viewer.showInfoPanel ? "隐藏信息面板" : "显示信息面板") {
                    viewer.showInfoPanel.toggle()
                }
                if !photo.isReadOnly || photo.isCloud || store.canEditNativeOverlay {
                    Button(photo.isFavorite ? "取消收藏" : "收藏") {
                        store.toggleFavorite(photo.id)
                    }
                }
                ShareLink(items: store.shareURLs) {
                    Text("共享…")
                }
                .disabled(store.shareURLs.isEmpty)
            }
            if !photo.isCloud || store.isCurrentCloudSMB {
                Button("在访达中显示") { store.revealInFinder(photo.id) }
            }
            if photo.isCloud, store.isCurrentCloudWritable {
                Button("重命名…") { store.requestCloudRename(photo.id) }
                Divider()
                Button("从云端删除…", role: .destructive) {
                    store.confirmDeleteCloud([photo.id])
                }
            }
            if !photo.isReadOnly {
                Button("复制照片") { store.duplicateCommand() }
                if !photo.isVideo {
                    Menu("旋转") {
                        Button("向右旋转") { store.rotateCommand(clockwise: true) }
                        Button("向左旋转") { store.rotateCommand(clockwise: false) }
                    }
                }
                if !photo.isVideo, !photo.isCloud {
                    Button("压缩…") {
                        store.presentCompression(for: [photo.id])
                    }
                    if PhotoCompressor.hasBackup(for: photo) {
                        Button("还原压缩前的原图") {
                            store.revertCompression(photo.id)
                        }
                    }
                }
                Button(photo.isHidden ? "取消隐藏" : "隐藏") {
                    store.setHidden([photo.id], hidden: !photo.isHidden)
                }
                if photo.hasEdits {
                    Button("复制编辑点") {
                        store.copyEdits(photo.id)
                    }
                    Button("还原为原始照片") {
                        store.revertEdits(photo.id)
                    }
                }
                if store.copiedEditRecipe != nil {
                    Button("粘贴编辑点") {
                        store.pasteEdits(photo.id)
                    }
                }
                Divider()
                Button("删除", role: .destructive) {
                    store.confirmDelete([photo.id])
                }
            }
        } label: {
            // 工具栏里与其他图标同尺寸、同风格，不自绘圆底；
            // 全屏查看器顶部是一排圆形材质按钮，这里保持同样的圆钮外观。
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: embedded ? 26 : 34, height: embedded ? 24 : 34)
                .background {
                    if !embedded {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    if !embedded {
                        Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    }
                }
                .shadow(color: .black.opacity(embedded ? 0 : 0.18), radius: 6, y: 2)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var zoomControls: some View {
        HStack(spacing: 9) {
            Button {
                adjustZoom(by: 1 / 1.35)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoom <= 1.001)

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .frame(minWidth: 36)

            Button {
                adjustZoom(by: 1.35)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(zoom >= 4.999)

            Button {
                resetZoom()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("适应窗口 (0)")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.82))
    }

    // MARK: - Viewer keyboard

    private func installViewerKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleViewerKey(event) ? nil : event
        }
    }

    private func removeViewerKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - 滚轮缩放

    private func installViewerScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleViewerScroll(event) ? nil : event
        }
    }

    private func removeViewerScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func handleViewerScroll(_ event: NSEvent) -> Bool {
        guard viewer.viewerID != nil, viewer.editorID == nil else { return false }
        guard let window = hostWindow ?? event.window, event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard abs(event.scrollingDeltaY) > 0.01 || abs(event.scrollingDeltaX) > 0.01 else { return false }

        // 在胶片条、信息面板、顶部工具栏上滚动时不缩放，避免抢走滚动操作。
        if let content = window.contentView {
            let point = content.convert(event.locationInWindow, from: nil)
            if point.y < 150 { return false }
            if point.y > content.bounds.height - 70 { return false }
            if viewer.showInfoPanel, point.x > content.bounds.width - 310 { return false }
        }

        // 已放大：双指滚动改为拖动画面（照片和视频一致），边界与鼠标拖动相同。
        if zoom > 1.001 {
            let fitted = stageFittedSize()
            guard fitted.width > 0 else { return false }
            let proposed = CGSize(width: baseOffset.width + event.scrollingDeltaX,
                                  height: baseOffset.height + event.scrollingDeltaY)
            offset = clampedOffset(proposed, stage: stageSize, fitted: fitted, zoom: zoom)
            baseOffset = offset
            return true
        }

        // 未放大：窗口内查看不拦截滚动；全屏时双指滚动仍用于放大。
        guard !embedded else { return false }
        let delta = event.scrollingDeltaY
        let factor = min(1.3, max(0.72, 1 + delta * 0.02))
        let target = min(5, max(1, zoom * factor))
        guard abs(target - zoom) > 0.0005 else { return false }
        zoom = target
        if target <= 1.01 {
            offset = .zero
            baseOffset = .zero
        }
        pinchStartZoom = nil
        return true
    }

    /// 当前画面的实际显示尺寸：双指拖动时用来限制可移动范围。
    private func stageFittedSize() -> CGSize {
        guard stageSize.width > 0, stageSize.height > 0 else { return .zero }
        guard photo?.isVideo != true,
              let shown = image ?? animatedImage ?? placeholder else { return stageSize }
        return fittedSize(shown, in: stageSize)
    }

    private func handleViewerKey(_ event: NSEvent) -> Bool {
        guard let window = hostWindow ?? event.window else { return false }
        guard event.window === window else { return false }
        guard window.attachedSheet == nil else { return false }
        // 确认卡片打开时，把键盘交给卡片。
        guard !store.hasPendingConfirmation else { return false }
        guard viewer.viewerID != nil, viewer.editorID == nil, store.activeMemory == nil else { return false }
        guard let photo else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 连拍选择模式：Esc 只退出选择、空格切换当前照片的勾选，都不关闭查看器。
        if viewer.burstSelectionMode {
            if event.keyCode == 53 {
                endBurstSelection()
                return true
            }
            if event.keyCode == 49,
               flags.intersection([.shift, .option, .command, .control]).isEmpty {
                store.toggleBurstSelection(photo.id)
                return true
            }
        }

        // 照片与视频通用的命令。
        if flags.contains(.command) {
            if event.keyCode == 51 {
                if photo.isCloud {
                    store.confirmDeleteCloud([photo.id])
                } else if !photo.isSystem {
                    if flags.contains(.option) {
                        store.confirmPermanentDelete([photo.id])
                    } else {
                        store.confirmDelete([photo.id])
                    }
                }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                store.copySelectionToPasteboard()
                return true
            case "v":
                guard !store.isReadOnlyScope else { return false }
                store.pasteFromPasteboard()
                return true
            case "d":
                guard !photo.isReadOnly else { return false }
                store.duplicateCommand()
                return true
            default:
                return false
            }
        }
        // 方向键在多数键盘上会带上 Function / 小键盘标记，不能因此丢弃；
        // 只屏蔽会与系统菜单快捷键冲突的修饰键。
        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于这条守卫匹配。
        if handleCustomShortcut(event, photo: photo) { return true }

        guard flags.intersection([.option, .control]).isEmpty else { return false }

        // 连拍：P 播放 / 暂停整组帧序列。
        if burstMembers.count > 1, event.charactersIgnoringModifiers?.lowercased() == "p" {
            toggleBurstPlayback()
            return true
        }

        // 空格：与系统「照片」一致，打开后再次按下即收起查看器回到图库。
        // 长按的重复事件不处理，避免「刚打开又被关掉」的闪烁。
        if event.keyCode == 49, !event.isARepeat,
           flags.intersection([.shift, .option, .control]).isEmpty {
            store.closeViewer()
            return true
        }

        // 视频的方向键、空格等由播放器自行处理。
        guard !photo.isVideo else { return false }

        switch event.keyCode {
        case 123, 126:
            store.viewerStep(-1)
            return true
        case 124, 125:
            store.viewerStep(1)
            return true
        default:
            return false
        }
    }

    /// 设置 › 快捷键里可自定义的查看器动作。
    /// 放在修饰键守卫之前，才能支持 ⌥ / ⌃ / ⇧ 组合；⌘ 组合仍留给系统菜单。
    private func handleCustomShortcut(_ event: NSEvent, photo: PhotoItem) -> Bool {
        if (!photo.isReadOnly || photo.isCloud),
           ShortcutStore.matches(event, .viewerFavorite) {
            store.toggleFavorite(photo.id)
            return true
        }
        if ShortcutStore.matches(event, .viewerInfo) {
            viewer.showInfoPanel.toggle()
            return true
        }
        if ShortcutStore.matches(event, .viewerZoomIn) {
            adjustZoom(by: 1.35)
            return true
        }
        if ShortcutStore.matches(event, .viewerZoomOut) {
            adjustZoom(by: 1 / 1.35)
            return true
        }
        if ShortcutStore.matches(event, .viewerZoomFit) {
            resetZoom()
            return true
        }

        guard !photo.isVideo else { return false }

        if photo.isLivePhoto, ShortcutStore.matches(event, .viewerLivePhoto) {
            toggleLivePhoto()
            return true
        }
        if (!photo.isReadOnly || (photo.isSystem && store.canWriteSystemLibrary)),
           ShortcutStore.matches(event, .viewerEdit) {
            store.openEditor(photo.id)
            return true
        }
        if ShortcutStore.matches(event, .viewerFullscreen) {
            NSApp.keyWindow?.toggleFullScreen(nil)
            return true
        }
        return false
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 实况照片

    private func livePhotoURL(for photo: PhotoItem) -> URL? {
        guard photo.isLivePhoto, !photo.isVideo,
              let url = LibraryPaths.livePhotoURL(for: photo),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func toggleLivePhoto() {
        guard let photo else { return }
        if livePlaying {
            stopLivePhoto()
            return
        }
        guard let url = livePhotoURL(for: photo) else {
            store.showToast("找不到实况照片的配对视频")
            return
        }
        let player = AVPlayer(url: url)
        livePlayer = player
        livePlaying = true
        liveEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                stopLivePhoto()
            }
        }
        player.play()
    }

    private func stopLivePhoto() {
        livePlayer?.pause()
        livePlayer = nil
        livePlaying = false
        if let liveEndObserver {
            NotificationCenter.default.removeObserver(liveEndObserver)
            self.liveEndObserver = nil
        }
    }

    // MARK: - 连拍快照

    /// 播放 / 暂停连拍：按拍摄顺序逐帧切换，与官方「照片」的连播观感一致。
    private func toggleBurstPlayback() {
        if viewer.burstPlaying {
            stopBurstPlayback()
            return
        }
        guard burstMembers.count > 1 else { return }
        guard let current = burstMembers.firstIndex(where: { $0.id == viewer.viewerID }) else { return }
        // 已经在最后一张时从头播放。
        if current == burstMembers.count - 1, let first = burstMembers.first {
            viewer.viewerID = first.id
        }
        viewer.burstPlaying = true
        burstPlayTask?.cancel()
        burstPlayTask = Task { @MainActor in
            // 约每秒 8 帧：既保留连拍的连续感，也给全尺寸解码留出时间。
            while !Task.isCancelled, viewer.burstPlaying {
                guard let position = viewer.burstMembers.firstIndex(where: { $0.id == viewer.viewerID }),
                      position + 1 < viewer.burstMembers.count else { break }
                try? await Task.sleep(nanoseconds: 125_000_000)
                guard !Task.isCancelled, viewer.burstPlaying else { break }
                let next = position + 1
                // 预取后两帧，播放时不会每帧都停在占位层。
                for offset in 1...2 where next + offset < viewer.burstMembers.count {
                    ImageLoader.prefetchDisplay(for: viewer.burstMembers[next + offset],
                                                sdr: !settings.viewFullHDR)
                }
                viewer.viewerID = viewer.burstMembers[next].id
            }
            if viewer.burstPlaying { viewer.burstPlaying = false }
        }
    }

    private func stopBurstPlayback() {
        burstPlayTask?.cancel()
        burstPlayTask = nil
        viewer.burstPlaying = false
    }

    /// 进入「进行选择…」：停掉播放，从空选择开始。
    private func beginBurstSelection() {
        stopBurstPlayback()
        viewer.burstSelection = []
        viewer.burstSelectionMode = true
    }

    /// 为窗口内浏览准备一张铺满舞台的缩略图；视频没有解码帧时也能拿到封面帧。
    /// 系统图库的缩略图可能正在后台生成，未就绪时短暂重试，避免舞台两侧一直是黑的。
    private func loadBackdrop() async {
        backdropImage = nil
        // 设置里关闭背景虚化时不加载模糊底图，翻页少一次缩略图读取。
        guard settings.viewerBackdrop, let photo else { return }
        for _ in 0..<6 {
            guard !Task.isCancelled, store.viewerPhoto?.id == photo.id else { return }
            let loaded = await PhotoThumbnailLoader.load(photo: photo,
                                                         purpose: .cover(320),
                                                         store: store)
            guard !Task.isCancelled, store.viewerPhoto?.id == photo.id else { return }
            if let loaded {
                backdropImage = loaded
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    private func load() async {
        stopLivePhoto()
        zoom = 1
        offset = .zero
        baseOffset = .zero
        pinchStartZoom = nil
        guard let photo else {
            image = nil
            animatedImage = nil
            placeholder = nil
            return
        }
        let fullHDR = settings.viewFullHDR
        if photo.isVideo {
            image = nil
            animatedImage = nil
            placeholder = nil
        } else {
            // 切换照片时先清掉上一张；占位层直接用网格里已解码的那一档，开图即有内容。
            image = nil
            animatedImage = nil
            placeholder = ImageLoader.cachedPreview(for: photo)

            let target = photo
            if target.isCloud {
                let loaded = await store.cloudDisplayImage(for: target)
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                let result = fullHDR ? loaded : loaded.map(ImageLoader.sdrImage)
                if placeholder == nil { image = result } else { show(result) }
            } else if let cached = ImageLoader.cachedDisplayImage(for: target, sdr: !fullHDR) {
                // 命中全尺寸缓存：直接出图，不做多余动画。
                image = cached
            } else {
                // 二级占位：磁盘上的 1200px 缩略图，比 192px 放大清晰得多。
                let medium = await Task.detached(priority: .userInitiated) {
                    ImageLoader.gridThumbnail(for: target, maxPixel: 1024)
                }.value
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                if let medium { placeholder = medium }
                prefetchQuickNeighbors(of: target)
                let loaded = await Task.detached(priority: .userInitiated) {
                    ImageLoader.displayImage(for: target, sdr: !fullHDR)
                }.value
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                if placeholder == nil {
                    image = loaded
                } else {
                    show(loaded)
                }
            }
            // 动图：额外取一份保留全部帧的图像，查看器里打开即循环播放。
            if target.playsAnimation {
                let animated: NSImage?
                if target.isCloud {
                    animated = await store.cloudAnimatedImage(for: target)
                } else {
                    animated = await Task.detached(priority: .userInitiated) {
                        ImageLoader.animatedImage(for: target)
                    }.value
                }
                guard !Task.isCancelled, viewer.viewerID == target.id else { return }
                animatedImage = animated
            }
        }
        prefetchNeighbors(of: photo, fullHDR: fullHDR)
    }

    /// 全尺寸图就绪后直接替换占位层：切换照片不做淡入 / 位移，连翻时更干脆。
    private func show(_ newImage: NSImage?) {
        image = newImage
    }

    /// 预取前后各两张的快速层，连翻时每一张都能立刻显示。
    private func prefetchQuickNeighbors(of photo: PhotoItem) {
        let photos = items
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        for delta in [1, 2, -1, -2] {
            var next = index + delta
            if next < 0 { next += photos.count }
            if next >= photos.count { next -= photos.count }
            guard next >= 0, next < photos.count else { continue }
            let target = photos[next]
            guard !target.isVideo, !target.isCloud else { continue }
            ImageLoader.prefetchQuick(for: target)
            // 紧邻的一张额外预取 1024px 中等层，翻过去时占位更清晰。
            if abs(delta) == 1 {
                ImageLoader.prefetchMedium(for: target)
            }
        }
    }

    /// 预取前后各一张的全尺寸显示图。
    private func prefetchNeighbors(of photo: PhotoItem, fullHDR: Bool) {
        let photos = items
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        for delta in [1, -1] {
            var next = index + delta
            if next < 0 { next = photos.count - 1 }
            if next >= photos.count { next = 0 }
            let target = photos[next]
            guard !target.isVideo, !target.isCloud else { continue }
            ImageLoader.prefetchDisplay(for: target, sdr: !fullHDR)
        }
    }
}

private extension PhotoItem {
    /// 没有读到任何拍摄日期时 `capturedAt` 会是纪元起点（显示成 1970 年）。
    /// 顶栏用「时间未知」代替这种异常日期，避免把缺失信息伪装成真实时间。
    var hasKnownCaptureDate: Bool {
        capturedAt.timeIntervalSince1970 > 86_400
    }
}

// MARK: - 工具栏频道舱

/// 窗口工具栏里的电视「频道舱」：频道号 / 台标 / 台名 / 直播状态 + Now & Next + 节目进度 + 线路读数。
/// 独立成小视图，直接观察播放器与频道模型，节目进度与收藏状态才能随时间实时刷新。
private struct TVToolbarDeck: View {
    @ObservedObject var store: LibraryStore
    let photo: PhotoItem
    /// 播放器：只传给音量控件；频道舱本身不再按播放时间 4Hz 重绘。
    let player: VideoPlayerModel
    /// 频道模型：节目单与收藏状态变化时刷新。
    @ObservedObject var tv: IPTVBrowserModel

    var body: some View {
        let channel = store.tvPlaybackChannel(for: photo.id)
        let number = channel.map { tv.channelNumber(for: $0) } ?? 0
        let now = channel.flatMap { tv.currentProgram(for: $0) }
        let lineIndex = store.tvLineIndex(for: photo.id)
        let lineCount = store.tvLineCount(for: photo.id)
        let isCatchup = channel?.isCatchUp == true
        let programTitle = isCatchup
            ? (photo.title ?? channel?.name ?? "回看")
            : now?.title

        // 单行排布：频道身份 + Now + 线路。
        // 台名 / 节目不设固定宽度，靠 layoutPriority 吃满剩余空间：
        // 台名优先完整显示，节目在后，窗口变窄时先收节目，再收台名。
        // 回看在下面多一行真正的进度条：可点、可拖，不再挤在舱底 1.5pt 的细线上。
        return VStack(spacing: 3) {
            HStack(spacing: 7) {
                // 频道号：整条舱里最重的一档，扫一眼就知道在哪个台。
                Text(String(format: "%02d", number))
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .fixedSize()

                TVLogoImage(urlString: channel?.logoURL,
                            size: CGSize(width: 38, height: 19),
                            cornerRadius: 3)
                    .fixedSize()

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 16)

                Text(channel?.name ?? "直播频道")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.01)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
                    .help(channel?.name ?? "直播频道")

                // 直播状态只留一枚信号点，不再占用「直播」两个字的宽度。
                if isCatchup {
                    tag("回看")
                } else {
                    Circle()
                        .fill(TVBrand.signal)
                        .frame(width: 5.5, height: 5.5)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                        }
                        .shadow(color: TVBrand.signal.opacity(0.55), radius: 3)
                        .fixedSize()
                        .help("正在直播")
                }

                if let programTitle {
                    Text(programTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .help(isCatchup
                              ? programTitle
                              : programTitle + " · "
                                + Self.clock.string(from: now?.start ?? Date())
                                + "–" + Self.clock.string(from: now?.end ?? Date()))
                } else {
                    Text("暂无节目单")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isCatchup {
                    Text(Self.catchupWhen(photo.capturedAt))
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                        .fixedSize()
                        .help("这档节目的播出时间")
                }

                Spacer(minLength: 4)

                if lineCount > 1 {
                    readout(channel: channel,
                            lineIndex: lineIndex,
                            lineCount: lineCount)
                }
                VideoInlineVolume(model: player)
            }
            if isCatchup {
                TVCatchupProgressBar(model: player, epgDuration: photo.duration ?? 0)
                    .padding(.horizontal, 2)
            }
        }
        .frame(minWidth: 480, maxWidth: 720)
        .padding(.horizontal, 8)
        .padding(.top, 3)
        .padding(.bottom, isCatchup ? 1 : 2)
        // 直播：节目进度贴在舱底；回看已经有自己那一行可拖进度条，不再叠一条细线。
        .overlay(alignment: .bottom) {
            if !isCatchup {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(TVBrand.wave.opacity(0.72))
                                .frame(width: max(0, proxy.size.width
                                                  * Self.progress(now, at: context.date)))
                        }
                        .transaction { $0.animation = nil }
                    }
                    .frame(height: 1.5)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 0.5)
            }
        }
    }

    /// 右侧读数胶囊：多线路时点「1/2」直接换线。
    /// 单线与协议文字不再常驻，把宽度让给台名与节目。
    private func readout(channel: TVChannel?,
                         lineIndex: Int,
                         lineCount: Int) -> some View {
        Menu {
            ForEach(Array((channel?.streamLines ?? []).enumerated()), id: \.offset) { index, url in
                Button {
                    _ = store.selectTVLine(index, for: photo.id)
                } label: {
                    let title = "线路 \(index + 1) · \(protocolLabel(of: url, channel: channel))"
                    if index == lineIndex {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            HStack(spacing: 1.5) {
                Text("\(lineIndex + 1)/\(lineCount)")
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(Color.primary.opacity(0.80))
            .font(.system(size: 8.5, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择播放线路 · 当前 \(lineIndex + 1)/\(lineCount)")
    }

    /// 单条线路的协议：优先用换线时记下的元数据，缺失时跟随频道当前协议。
    private func protocolLabel(of url: String, channel: TVChannel?) -> String {
        let hls = store.tvLineMetadata[url]?.isHLS ?? (channel?.isHLS ?? true)
        return hls ? "HLS" : "HTTP"
    }

    /// 台名旁的小标签（回看 / 时移等）。
    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
            .fixedSize()
    }

    /// 回看的播出时刻：「昨天 20:04」比一个光秃秃的 20:04 更好定位。
    private static func catchupWhen(_ date: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "今天"
        } else if calendar.isDateInYesterday(date) {
            day = "昨天"
        } else if let before = calendar.date(byAdding: .day, value: -2,
                                             to: calendar.startOfDay(for: Date())),
                  calendar.isDate(date, inSameDayAs: before) {
            day = "前天"
        } else {
            day = date.formatted(.dateTime.month(.defaultDigits).day())
        }
        return day + " " + clock.string(from: date)
    }

    private static func progress(_ program: TVEPGProgram?, at date: Date) -> CGFloat {
        guard let program else { return 0 }
        let span = program.end.timeIntervalSince(program.start)
        guard span > 1 else { return 0 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(program.start) / span)))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 回看进度条

/// 回看舱里唯一跟随播放器刷新的读数格式。
private enum TVDeckFormat {
    /// 播放读数：不足一小时用 mm:ss，超过用 h:mm:ss。
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// 回看进度条：信息行下方独立一行，`已播 · 轨道 · 总时长`。
/// 直接复用播放页的 `VideoScrubber`——整条 16pt 都是热区，悬停加粗、拖动跟手、
/// 松手才真正落位；不再是舱底那条 1.5pt 只能看的细线。
/// 总时长优先用播放器解析出的片长，解析不出时用节目单时长兜底，避免读数停在 00:00。
private struct TVCatchupProgressBar: View {
    @ObservedObject var model: VideoPlayerModel
    let epgDuration: Double

    private var total: Double {
        model.duration > 1 ? model.duration : max(0, epgDuration)
    }
    private var position: Double { max(0, model.currentTime) }
    private var progress: Double {
        guard total > 1 else { return 0 }
        return min(1, max(0, position / total))
    }
    private var buffered: Double {
        guard total > 1 else { return 0 }
        return min(1, max(0, model.bufferedTime / total))
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(TVDeckFormat.timecode(position))
                .foregroundStyle(TVBrand.gold.opacity(0.95))
                .frame(minWidth: 34, alignment: .trailing)

            VideoScrubber(progress: progress,
                          buffered: buffered,
                          tint: TVBrand.gold,
                          knobBorder: Color.white.opacity(0.72),
                          duration: total,
                          onSeek: { value in
                              guard total > 1 else { return }
                              model.scrub(to: value * total)
                          },
                          onCommit: { value in
                              guard total > 1 else { return }
                              model.requestSeek(to: value * total)
                          })
                .frame(minWidth: 140, maxWidth: .infinity)

            Text(TVDeckFormat.timecode(total))
                .foregroundStyle(Color.primary.opacity(0.52))
                .frame(minWidth: 34, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .contentShape(Rectangle())
        .help(total > 1 ? "点按 / 拖动定位 · 剩余 \(TVDeckFormat.timecode(max(0, total - position)))"
                        : "回看进度")
    }
}
