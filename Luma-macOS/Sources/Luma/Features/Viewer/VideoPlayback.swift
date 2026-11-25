import SwiftUI
import AVKit
import AVFoundation
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PlaybackCore

// MARK: - 视频画面

private final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()
    /// 窗口内浏览时设为 false：播放器与容器都透明，露出背后的照片模糊灯箱。
    var showsOpaqueBackground = true {
        didSet {
            let color = showsOpaqueBackground ? NSColor.black : NSColor.clear
            layer?.backgroundColor = color.cgColor
            playerLayer.backgroundColor = color.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    var opaqueBackground: Bool = true
    let onPipController: (AVPictureInPictureController?) -> Void

    final class Coordinator {
        var pip: AVPictureInPictureController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.showsOpaqueBackground = opaqueBackground
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
            context.coordinator.pip = controller
            onPipController(controller)
        }
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.showsOpaqueBackground = opaqueBackground
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        if coordinator.pip?.isPictureInPictureActive == true {
            coordinator.pip?.stopPictureInPicture()
        }
        coordinator.pip = nil
        // 视图被移除时兜底停播：避免上层没走 onDisappear 时声音还在响。
        nsView.playerLayer.player?.pause()
        nsView.playerLayer.player = nil
    }
}

// MARK: - 进度条

struct VideoScrubber: View {
    let progress: Double
    /// 缓冲区间末尾与起点（比例）：起点是当前会话还能直接回退的最早位置。
    let buffered: Double
    var bufferedStart: Double = 0
    /// 轨道与进度点颜色：画面控制条用白色，窗口工具栏跟随明暗外观。
    var tint: Color = .white
    /// 进度点的描边色：白点配深描边，彩色点配白描边，深浅底上都能看清。
    var knobBorder: Color = .white.opacity(0.6)
    /// 总时长：用于预览气泡上的时间标签。
    var duration: Double = 0
    /// 章节起点（比例）：轨道上画细刻度，电影 / 蓝光的段落一目了然。
    var chapterFractions: [Double] = []
    /// 悬停 / 拖动时取该比例处的画面帧；为空则不显示预览。
    var thumbnailPreview: ((Double) async -> NSImage?)?
    /// 悬停 / 拖动位置变化（nil 表示离开）：顶栏预览气泡据此跟随光标。
    var onPreviewChange: ((Double?) -> Void)?
    let onSeek: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragValue: Double = 0
    @State private var hoverFraction: Double?
    @State private var previewImage: NSImage?
    @State private var previewFraction: Double?
    @State private var previewTask: Task<Void, Never>?

    private var isExpanded: Bool { isHovering || isDragging }
    private var trackHeight: CGFloat { isExpanded ? 4.5 : 3 }
    private var knobSize: CGFloat { isExpanded ? 12 : 8 }
    private var haloSize: CGFloat { isExpanded ? 21 : 14 }

    private func clamp(_ value: Double) -> Double {
        // 非有限值会让 frame(width:) 变成 NaN，SwiftUI 布局会直接卡死。
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = clamp(isDragging ? dragValue : progress)
            let playedWidth = width * value
            let bufferedStartX = width * clamp(bufferedStart)
            let bufferedEndX = width * clamp(buffered)
            ZStack(alignment: .leading) {
                // 轨道：内凹细槽 + 细描边，像一条嵌进玻璃里的轨道。
                Capsule()
                    .fill(tint.opacity(0.13))
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(0.10), lineWidth: 0.5)
                    }

                // 缓冲区间：只画「已经生成、能立即跳过去」的一段。
                // 从保留起点开始画而不是永远从 0 开始——拖到未生成区间后重新起流，
                // 更早的位置需要重建，不该假装已缓存。
                if bufferedEndX > bufferedStartX + 0.5 {
                    Capsule()
                        .fill(tint.opacity(0.24))
                        .frame(width: bufferedEndX - bufferedStartX, height: trackHeight)
                        .offset(x: bufferedStartX)
                }

                // 已播放段：渐变轨道，收尾处更亮。播放中按采样间隔做线性补间，进度是滑行而不是跳格。
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: playedWidth, height: trackHeight)
                    .animation(isDragging ? nil : .linear(duration: 0.25), value: playedWidth)

                // 缓冲前沿：亮线标出「到这里都准备好了」，和 YouTube / Infuse 的处理一致。
                if bufferedEndX > bufferedStartX + 0.5,
                   bufferedEndX < width - 0.5,
                   bufferedEndX > playedWidth + 1 {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: 1.5, height: trackHeight + 1)
                        .offset(x: bufferedEndX - 0.75)
                        .shadow(color: tint.opacity(0.35), radius: 2)
                        .allowsHitTesting(false)
                }

                // 章节刻度：起点位置画一条短竖线，便于在进度条上直接认出段落。
                if !chapterFractions.isEmpty {
                    ForEach(Array(chapterFractions.indices), id: \.self) { index in
                        Capsule()
                            .fill(tint.opacity(isExpanded ? 0.62 : 0.4))
                            .frame(width: 1.2, height: trackHeight + (isExpanded ? 8 : 4))
                            .offset(x: width * clamp(chapterFractions[index]) - 0.6)
                            .allowsHitTesting(false)
                    }
                }

                // 悬停位置标线：像 YouTube 那样先给出落点，再浮出画面预览。
                if let hoverFraction, isExpanded {
                    Rectangle()
                        .fill(tint.opacity(0.42))
                        .frame(width: 1, height: trackHeight + 7)
                        .offset(x: width * hoverFraction - 0.5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // 进度点：外圈柔光 + 实心圆 + 细描边，悬停 / 拖动时整体放大。
                knob
                    .offset(x: playedWidth - knobSize / 2)
                    .animation(isDragging ? nil : .linear(duration: 0.25), value: playedWidth)
                    .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isExpanded)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topLeading) {
                previewBubble(width: width)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    isHovering = true
                    let fraction = clamp(point.x / width)
                    hoverFraction = fraction
                    onPreviewChange?(fraction)
                    requestPreview(fraction)
                case .ended:
                    isHovering = false
                    hoverFraction = nil
                    onPreviewChange?(nil)
                    if !isDragging { clearPreview() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        dragValue = clamp(gesture.location.x / width)
                        hoverFraction = dragValue
                        onPreviewChange?(dragValue)
                        requestPreview(dragValue)
                        onSeek(dragValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                        hoverFraction = nil
                        onPreviewChange?(nil)
                        clearPreview()
                        onCommit(dragValue)
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            if !hovering, !isDragging { clearPreview() }
        }
    }

    @ViewBuilder
    private func previewBubble(width: CGFloat) -> some View {
        if let previewImage, let previewFraction {
            let bubbleWidth: CGFloat = 168
            let bubbleHeight: CGFloat = 95
            let x = min(max(0, width * previewFraction - bubbleWidth / 2), max(0, width - bubbleWidth))
            Image(nsImage: previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: bubbleWidth, height: bubbleHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.7)
                }
                .overlay(alignment: .bottomTrailing) {
                    if duration > 0 {
                        Text(formatPreviewTime(duration * previewFraction))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(.black.opacity(0.55), in: Capsule(style: .continuous))
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                .offset(x: x, y: -(bubbleHeight + 12))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func requestPreview(_ fraction: Double) {
        guard let thumbnailPreview else { return }
        previewFraction = fraction
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            // 轻微防抖：手指快速掠过时不取帧，停住 90ms 再取，预览跟手又不抢解码。
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let image = await thumbnailPreview(fraction)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { previewImage = image }
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewImage = nil
        previewFraction = nil
    }

    private func formatPreviewTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 进度点：一团柔光托着一颗镜头对焦点似的小圆。
    private var knob: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(isExpanded ? 0.32 : 0.16))
                .frame(width: haloSize, height: haloSize)
                .blur(radius: isExpanded ? 3.5 : 2.5)

            Circle()
                .fill(tint)
                .frame(width: knobSize, height: knobSize)
                .overlay {
                    Circle().strokeBorder(knobBorder, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
        }
    }
}

// MARK: - 缓冲提示

/// 起播 / 缓冲 / 跳转落地前的等待动画：一圈渐变弧 + 呼吸光点。
/// 延迟 0.22 秒出现，本地秒开或短跳转不会闪一下白圈。
private struct VideoBufferingOverlay: View {
    let active: Bool
    var label: String = "缓冲中"
    /// 起播阶段立即显示，不走 0.22 秒防抖：否则打开视频时中间会空一段时间。
    var immediate = false
    /// 首帧之前的等待用更大的转圈（盖在海报底图上），出画面后的补缓冲保持紧凑。
    var prominent = false

    @State private var visible = false
    @State private var spinning = false
    @State private var pulsing = false

    var body: some View {
        Group {
            if visible {
                VStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 2.4)
                        Circle()
                            .trim(from: 0, to: 0.62)
                            .stroke(AngularGradient(colors: [Color.accentColor.opacity(0.15),
                                                             Color.accentColor,
                                                             LumaBrand.cyan],
                                                    center: .center,
                                                    startAngle: .degrees(0),
                                                    endAngle: .degrees(360)),
                                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .rotationEffect(.degrees(spinning ? 360 : 0))
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 4)
                            .scaleEffect(pulsing ? 1.7 : 0.7)
                            .opacity(pulsing ? 0.32 : 1)
                    }
                    .frame(width: prominent ? 54 : 40, height: prominent ? 54 : 40)

                    Text(label)
                        .font(.system(size: prominent ? 11.5 : 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(prominent ? 0.82 : 0.62))
                }
                .padding(.horizontal, prominent ? 28 : 20)
                .padding(.vertical, prominent ? 20 : 15)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: visible)
        .allowsHitTesting(false)
        .task(id: active) {
            guard active else {
                visible = false
                spinning = false
                pulsing = false
                return
            }
            // 等一小会儿再出现：进度条小跳一下不该闪出加载动画。
            if !immediate {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            guard !Task.isCancelled else { return }
            visible = true
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                spinning = true
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/// 起播垫底：直接把缩略图 / 海报铺满画面，出第一帧后淡出。
/// 不再做「正在准备第一帧」这类整页加载文案——播放器该做的是尽快出画面，
/// 等待反馈交给紧凑的缓冲胶囊，界面不整块闪动。
private struct VideoPosterBackdrop: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// 工具栏播放按钮里的迷你缓冲环。
private struct VideoMiniSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.62)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

// MARK: - 播放器视图

/// 测量控制条实际尺寸，用于拖拽时把控制条限制在视频区域内。
private struct VideoControlPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 按住连发：按下立刻执行一次，之后重复间隔从 0.30s 递减到 0.14s 后匀速。
/// 配合 `VideoPlayerModel.seekStep(_:base:isRepeat:)` 使用：按住越久步长倍率越高，
/// 到 8× 封顶后就是匀速快进 / 快退。
private struct HoldRepeatGesture: ViewModifier {
    let action: () -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var pressing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { pressing in
                if pressing {
                    start()
                } else {
                    stop()
                }
            } perform: {}
            .onDisappear(perform: stop)
    }

    private func start() {
        guard !pressing else { return }
        pressing = true
        action()
        holdTask = Task { @MainActor in
            var interval: UInt64 = 300_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                action()
                if interval > 140_000_000 {
                    interval = max(140_000_000, interval - 20_000_000)
                }
            }
        }
    }

    private func stop() {
        pressing = false
        holdTask?.cancel()
        holdTask = nil
    }
}

/// 播放器控制按钮：悬停高亮、选中态使用强调色。
private struct VideoControlButton: View {
    let icon: String
    var active = false
    var emphasized = false
    /// 重建流 / 缓冲时显示转圈，替代播放暂停图标。
    var busy = false
    var help: String?
    /// 快进 / 快退用：按住不放持续步进，而不是只跳一次。
    var repeatsWhileHeld = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        withHelp
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering }
            }
    }

    @ViewBuilder
    private var withHelp: some View {
        if let help {
            core.help(help)
        } else {
            core
        }
    }

    @ViewBuilder
    private var core: some View {
        if repeatsWhileHeld {
            content.modifier(HoldRepeatGesture(action: action))
        } else {
            Button(action: action) { content }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        ZStack {
            if busy {
                VideoMiniSpinner()
            } else {
                Image(systemName: icon)
                    .font(.system(size: emphasized ? 13.5 : 11.5, weight: .semibold))
                    .foregroundStyle(active ? Color.accentColor : Color.white.opacity(hovering ? 1 : 0.86))
            }
        }
        .frame(width: emphasized ? 31 : 26, height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
        }
        .contentShape(Rectangle())
    }

    private var fill: Color {
        if active { return Color.accentColor.opacity(0.2) }
        if emphasized { return Color.white.opacity(hovering ? 0.22 : 0.14) }
        return Color.white.opacity(hovering ? 0.14 : 0.001)
    }
}

struct VideoPlayerStage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewer: ViewerModel
    let photo: PhotoItem
    /// 播放状态由查看器持有：顶栏融合模式下，窗口工具栏要用同一份状态渲染播放控件。
    @ObservedObject var model: VideoPlayerModel
    /// 音轨 / 字幕状态：与窗口顶栏共享同一份。
    @ObservedObject var ui: VideoPlaybackUI
    /// 手动旋转角度同样提到查看器，顶栏按钮与画面共用。
    @Binding var quarterTurns: Int
    /// 保存当前帧需要读取查看器里的照片与旋转状态，由查看器提供。
    var onCaptureFrame: () -> Void = {}
    /// 窗口内浏览：播放器透明，画面两侧露出照片模糊灯箱。
    var transparentBackground: Bool = false
    /// 查看器的缩放与位移：只作用于画面，控制层始终保持原尺寸。
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    @State private var sourceURL: URL?
    /// 当前片源的播放模式与能力：直播不显示进度条 / 续播，后续电视频道页直接读它。
    @State private var playbackMode: PlaybackMode = .vod
    @State private var playbackCapabilities: PlaybackCapabilities = .vod
    /// 云端直链要求的请求头（WebDAV 的 Basic 认证等），转码时同样要带上。
    @State private var sourceHeaders: [String: String] = [:]
    /// 百度直链不带扩展名、要求固定 UA，且会 302 到 CDN；
    /// 用资源加载器转发，保证每一跳都带请求头并补全 Content-Type。
    @State private var cloudResourceLoader: CloudAssetResourceLoader?
    /// 播放器是否已经装上片子。PhotoKit 返回的素材可能没有本地 URL，不能只看 sourceURL。
    @State private var hasLoadedVideo = false
    @State private var assetOptions: [String: Any] = [:]
    @State private var isPreparing = true
    /// 起播阶段的底图：本地视频直接读缩略图做模糊背景，网络源没有就退回渐变。
    @State private var loadingThumbnail: NSImage?
    @State private var failureMessage: String?
    /// 云端直链获取失败的具体原因（授权、文件 ID、接口错误等）。
    @State private var streamFailure: String?
    @State private var canTranscode = false
    @State private var isTranscoding = false
    /// 本次装片是否已经为「系统播放器不兼容」自动重编码过一次：失败后不再反复拉起 ffmpeg。
    @State private var didAutoTranscodeFallback = false
    /// 探测到的完整时长 / 编码信息：跳转后的新会话仍按完整时间轴显示进度。
    @State private var probeDuration: Double = 0
    @State private var probeIsHEVC = false
    @State private var probeIsHDR = false
    /// 片源色彩管线：转封装写回容器、HDR 策略判断都要用。
    @State private var probeColor = VideoColorInfo()
    /// 杜比视界缺 libplacebo 的提示只弹一次。
    @State private var dvHintShown = false
    @State private var probeAudioCount = 0
    @State private var probeAudioTracks: [AudioTrackInfo] = []
    /// ffprobe 补齐的完整技术信息：码率 / 帧率 / HDR / 章节。
    @State private var playbackProbe = VideoProbe()
    /// 本次播放的 HDR 映射覆盖：nil 表示跟随设置；用户切开关后按新策略重建流。
    @State private var hdrToneMapOverride: Bool?
    /// 蓝光多角度：可用视角数量与当前选择（1 起）。
    @State private var angleCount = 1
    @State private var selectedAngle = 1
    /// I 键播放信息叠加。
    @State private var showPlaybackInfo = false
    /// ⌘⇧I：在播放信息里展开完整 ffprobe 字段。
    @State private var showFullProbe = false
    /// 电视 OSD：频道号输入缓冲。
    @State private var tvChannelNumberBuffer = ""
    @State private var tvChannelNumberTask: Task<Void, Never>?
    /// 内嵌字幕只自动尝试挂载一次，避免用户主动关掉后又弹回来。
    @State private var autoEmbeddedTried = false
    /// 完整缓存起播时真实直链还在后台解析：技术探测等直链回来再做，先不探测占位地址。
    @State private var cachedSourcePending = false
    /// 控制层是否处于“刚操作过”的可见状态；播放中静止数秒后自动淡出。
    @State private var controlsShown = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var lastHoverMove = Date.distantPast
    /// 控制条可自由拖动，位置按比例以外的绝对偏移持久化。
    @AppStorage("video.controls.offsetX") private var controlOffsetX: Double = 0
    @AppStorage("video.controls.offsetY") private var controlOffsetY: Double = 0
    @State private var controlPanelSize: CGSize = .zero
    @State private var dragStartOffset: CGSize?
    /// 时长文字点击后显示剩余时间。
    @State private var showRemainingTime = false
    @State private var hasPrevVideo = false
    @State private var hasNextVideo = false
    /// 视频原始尺寸（仅影响播放显示，不改原文件）。
    @State private var videoSize: CGSize = .zero
    /// 载入代次：连续翻页时旧任务从 await 恢复后不能再把上一个视频装进播放器，
    /// 否则界面已经切到别的照片，旧视频的声音还在继续。
    @State private var loadGeneration = 0
    /// 播放器真正所在的窗口：全屏按钮必须切换这个窗口，
    /// 用 NSApp.keyWindow 在弹出面板 / 子窗口存在时会切错窗口。
    @State private var playerWindow: NSWindow?

    /// 播放编排状态由内核持有；这里只读转发，避免 View 再维护一份会话状态。
    private var playbackSession: PlaybackSession { viewer.playbackSession }
    private var streamSession: VideoStreamSession? { playbackSession.streamSession }
    private var streamMode: VideoStreamSession.Mode { playbackSession.streamMode }
    private var streamAudioIndex: Int { playbackSession.streamAudioIndex }
    private var isRestartingStream: Bool { playbackSession.isRestartingStream }

    /// 控制条距视频底部的默认间距；向上拖动的下限与之一致。
    private let controlPanelBottomInset: CGFloat = 28
    /// 允许向下拖动控制条的距离上限，避免贴到画面边缘。
    private let controlPanelMaxDownOffset: CGFloat = 16

    private var controlsVisible: Bool { controlsShown || !model.isPlaying }

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }

    private var buffered: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.bufferedEndTime / model.duration))
    }

    /// 起播前向缓冲：先用短缓冲把画面放出来，播放开始后由播放编排拉到设置里的档位。
    /// 直接给 16 秒会让 AVPlayer 先攒够数据才起播，网络源上就是几秒黑屏。
    private var startupForwardBuffer: Double {
        min(4, settings.videoBufferProfile.forwardBufferDuration)
    }

    /// 当前会话还能直接回退到的最早位置：更早的分片已经不在，跳过去会重建流。
    private var bufferedStart: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, playbackSession.retainedStartSeconds / model.duration))
    }

    private var activeFailure: String? {
        // 重建流期间旧会话的本地分片服务会短暂断开，AVPlayer 随即报「无法连接服务器」。
        // 这属于中间态，真正的失败由 failureMessage 表达，不能把瞬时错误弹成错误卡片。
        if isPreparing || playbackSession.isRestartingStream { return failureMessage }
        return failureMessage ?? model.errorMessage
    }

    /// 当前画面是不是电视频道（直播或回看）。
    private var tvPlaybackChannel: TVChannel? {
        store.tvPlaybackChannel(for: photo.id)
    }

    /// 只有直播才启用遥控语义（换台 / 频道带）；回看走点播的进度条。
    private var tvLiveChannel: TVChannel? {
        guard playbackMode == .live, let channel = tvPlaybackChannel, !channel.isCatchUp else {
            return nil
        }
        return channel
    }

    /// 电视 OSD 的独立子视图：把大段类型推断从 `body` 里拆出去。
    @ViewBuilder
    private var tvOverlay: some View {
        // 失败态也保留频道信息条，和概念图「状态 C」一致：先知道是哪个台，再看卡片。
        if let channel = tvPlaybackChannel {
            TVPlaybackOverlay(channel: channel,
                              photoID: photo.id,
                              isLive: playbackMode == .live && !channel.isCatchUp,
                              controlsVisible: activeFailure == nil ? controlsVisible : true,
                              timeshiftActive: $viewer.tvTimeshiftActive,
                              showGuide: $viewer.tvGuideShown,
                              model: model,
                              failureMode: activeFailure != nil,
                              usesWindowToolbarActions: transparentBackground
                                  && !viewer.videoImmersiveFullScreen
                                  && settings.videoControlPlacement == .topIntegrated,
                              onCaptureFrame: onCaptureFrame)
        }
    }

    private func resetTVInput() {
        // 换台后收起节目单抽屉，清掉未提交的频道号输入。
        viewer.tvGuideShown = false
        viewer.tvTimeshiftActive = false
        tvChannelNumberTask?.cancel()
        tvChannelNumberTask = nil
        tvChannelNumberBuffer = ""
    }

    /// 时移步进：限制在真实可 seek 的窗口内，避免越过河床两端。
    private func seekTimeshift(by delta: Double) {
        let lower = model.seekableStartTime
        let upper = max(lower, model.bufferedEndTime - 0.4)
        let target = min(upper, max(lower, model.currentTime + delta))
        model.requestSeek(to: target)
    }

    /// 电视线路失败自动顺延：成功返回 true，重新装片；全部失败时保留错误卡片。
    private func attemptTVLineFallback(reason: String? = nil) -> Bool {
        guard store.advanceTVLineAfterFailure(for: photo.id, reason: reason) else {
            // 只有多线路频道才提示「全部线路失败」，单线路直接交给错误卡片。
            if store.tvLineCount(for: photo.id) > 1 {
                store.showToast("这个频道的全部线路都失败了")
            }
            return false
        }
        failureMessage = nil
        streamFailure = nil
        return true
    }

    /// 把播放错误翻译成失败卡片上的一行原因。
    private func lineFailureReason(_ failure: PlaybackFailure?) -> String {
        guard let failure else { return "无响应" }
        if let status = failure.httpStatus { return "返回 \(status)" }
        switch failure.code {
        case -1001: return "超时"
        case -1004, -1005, -1009: return "无法连接"
        case -11800, -11828, -12927: return "编码不兼容"
        default: break
        }
        return failure.domain == NSURLErrorDomain ? "网络错误" : "无响应"
    }

    /// 打开 / 切换条目时启动装片，顺带恢复上次的倍速。
    private func startPlaybackTask() async {
        loadGeneration &+= 1
        if settings.videoRememberSpeed, settings.videoLastSpeed > 0,
           settings.videoLastSpeed != 1 {
            model.setSpeed(settings.videoLastSpeed)
        }
        await preparePlayback(generation: loadGeneration)
    }

    /// 播放器上报失败：电视频道先尝试换到备用线路，其余情况走原有的转码兜底。
    private func handlePlaybackFailure(_ failure: PlaybackFailure?) {
        guard let failure else { return }
        // 电视频道：任一线路被拒都先顺延到下一条，全部失败才交给错误卡片。
        if tvPlaybackChannel != nil,
           attemptTVLineFallback(reason: lineFailureReason(failure)) { return }
        guard hasLoadedVideo else { return }
        Diagnostics.record("装片失败 \(photo.originalName)："
                           + "\(failure.domain ?? "-") \(failure.code.map(String.init) ?? "-") "
                           + "incompatible=\(failure.isIncompatibleAsset) \(failure.message)")
        guard FFmpeg.isAvailable, sourceURL != nil else { return }
        canTranscode = true
        // -12927 / -11828：系统播放器判定码流不兼容，重封装不会变好，直接改走兼容转码。
        guard failure.isIncompatibleAsset, !didAutoTranscodeFallback else { return }
        didAutoTranscodeFallback = true
        autoFallbackToTranscode(after: failure)
    }

    /// 流地址层面失败（403 / 超时 / 直链失效）：电视频道再顺延一次备用线路。
    private func handleStreamFailureChange(_ value: String?) {
        guard let value, tvPlaybackChannel != nil else { return }
        _ = attemptTVLineFallback(reason: value.lowercased().contains("403") ? "返回 403" : "无响应")
    }

    /// 离开播放层：停流、撤销画中画与窗口显示模式，全部集中在这里，避免 `body` 里的闭包过大。
    private func handleStageDisappear() {
        FullScreenDiagnostics.log("video stage disappear \(photo.originalName)")
        if settings.videoRememberSpeed { settings.videoLastSpeed = model.speed }
        NowPlayingCenter.shared.deactivate()
        VideoScrubPreviewCenter.shared.fallbackProvider = nil
        VideoScrubPreviewCenter.shared.end()
        loadGeneration &+= 1
        hideControlsTask?.cancel()
        model.seekRouter = nil
        model.scrubGuard = nil
        playbackSession.onHardStall = nil
        playbackSession.onNativeStall = nil
        model.stop()
        DisplayModeMatcher.restore()
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        playbackSession.stop()
    }

    /// 读取本地缩略图做起播底图；网络 / 云盘视频没有对应文件时返回 nil。
    private func fileExistsThumbnail() -> NSImage? {
        let url = LibraryPaths.thumbnailURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 等待层：第一帧出来之前用海报垫底，出画面后淡出；
    /// 出画面之后的卡顿只用紧凑缓冲胶囊，不整页遮挡。
    @ViewBuilder
    private var waitingLayer: some View {
        if activeFailure == nil {
            if !model.isItemReady {
                VideoPosterBackdrop(image: loadingThumbnail)
                    .transition(.opacity)
            }
            // 起播等待只覆盖「还没出画面」：装片完成后的音轨校验不该在画面上继续转圈。
            // 重建流期间由 isStalled（isReloading）接管，给一枚轻量反馈即可。
            let preparingFirstFrame = isPreparing && !model.isItemReady
            VideoBufferingOverlay(active: model.isStalled || preparingFirstFrame,
                                  label: preparingFirstFrame ? "载入中" : "缓冲中",
                                  immediate: !model.isItemReady,
                                  prominent: !model.isItemReady)
        }
    }

    /// 当前时间点应显示的字幕（已套用字幕偏移），带 ASS 样式时会按样式渲染。
    private var activeCue: SubtitleCue? {
        ui.cue(at: model.currentTime)
    }

    /// 字幕覆盖层：SRT / VTT 用用户设置，ASS / SSA 优先用字幕自带的颜色、字号与对齐。
    @ViewBuilder
    private func subtitleOverlay(_ cue: SubtitleCue, in size: CGSize) -> some View {
        let style = cue.style
        let fontSize = settings.subtitleFontSize * (style?.fontScale ?? 1)
        let color = style?.primaryColor.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue).opacity($0.alpha)
        } ?? subtitleTextColor
        let outline = style?.outlineColor.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue).opacity($0.alpha)
        } ?? Color.black
        let anchor = style?.verticalAnchor ?? 1

        VStack(spacing: 0) {
            if anchor <= 0.25 {
                subtitleText(cue, fontSize: fontSize, color: color, outline: outline)
                    .padding(.top, 48)
                Spacer(minLength: 0)
            } else if anchor < 0.75 {
                Spacer(minLength: 0)
                subtitleText(cue, fontSize: fontSize, color: color, outline: outline)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                subtitleText(cue, fontSize: fontSize, color: color, outline: outline)
                    .padding(.bottom, subtitleBottomPadding(in: size))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func subtitleText(_ cue: SubtitleCue,
                              fontSize: Double,
                              color: Color,
                              outline: Color) -> some View {
        Text(cue.text)
            .font(.system(size: fontSize, weight: cue.style?.bold == true ? .bold : .semibold))
            .italic(cue.style?.italic == true)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(settings.subtitleBackground ? Color.black.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 用四个方向的零模糊阴影模拟 ASS 描边。
            .shadow(color: outline.opacity(0.95), radius: 1, x: 0, y: 0)
            .shadow(color: outline.opacity(0.8), radius: 0, x: 1.2, y: 0)
            .shadow(color: outline.opacity(0.8), radius: 0, x: -1.2, y: 0)
            .shadow(color: outline.opacity(0.8), radius: 0, x: 0, y: 1.2)
            .shadow(color: outline.opacity(0.8), radius: 0, x: 0, y: -1.2)
            .frame(maxWidth: 860)
            .padding(.horizontal, 40)
    }

    private var subtitleTextColor: Color {
        switch settings.subtitleColor {
        case "yellow": return Color(red: 1.0, green: 0.86, blue: 0.38)
        case "cyan": return Color(red: 0.45, green: 0.95, blue: 0.98)
        case "green": return Color(red: 0.58, green: 0.98, blue: 0.66)
        default: return .white
        }
    }

    private func subtitleBottomPadding(in size: CGSize) -> CGFloat {
        switch settings.subtitlePosition {
        case "middle": return max(160, size.height * 0.34)
        case "lower": return 190
        default: return 118
        }
    }

    // MARK: 播放信息 / 章节

    /// I 键信息叠加：码率 / 帧率 / HDR / 音轨 / 章节，全部来自起播后补的 ffprobe。
    private var playbackInfoOverlay: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
                Text("播放信息")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Button {
                    showPlaybackInfo = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭 (I)")
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.7)

            // 四列固定顺序：视频 / 音频 / 字幕 / 播放，扫一眼就能读完。
            HStack(alignment: .top, spacing: 16) {
                infoColumn("视频") {
                    infoRow("画面", playbackResolutionText)
                    infoRow("编码", playbackCodecText)
                    infoRow("容器", playbackContainerText)
                    infoRow("码率", playbackBitrateText)
                    infoRow("帧率", playbackFrameRateText)
                    infoRow("HDR", playbackProbe.hdrLabel ?? (playbackProbe.isHDR ? "HDR" : "SDR"))
                    infoRow("色彩", playbackColorText)
                }
                infoColumn("音频") {
                    infoRow("主音轨", playbackPrimaryAudioText)
                    infoRow("编码", playbackAudioCodecText)
                    infoRow("声道", playbackAudioChannelsText)
                    infoRow("语言", playbackAudioLanguageText)
                    infoRow("轨道数", playbackAudioTrackCountText)
                    infoRow("输出", "系统默认输出")
                }
                infoColumn("字幕") {
                    infoRow("当前", playbackSubtitleCurrentText)
                    infoRow("来源", playbackSubtitleSourceText)
                    infoRow("轨道", playbackSubtitleTracksText)
                    infoRow("时间轴", playbackSubtitleOffsetText)
                    infoRow("字号", playbackSubtitleSizeText)
                    infoRow("位置", playbackSubtitlePositionText)
                }
                infoColumn("播放") {
                    infoRow("章节", playbackChapterText)
                    if angleCount > 1 {
                        infoRow("角度", "\(selectedAngle)/\(angleCount)")
                    }
                    infoRow("大小", playbackFileSizeText)
                    infoRow("已播", playbackPlayedText)
                    infoRow("实时码率", playbackLiveBitrateText)
                    infoRow("丢帧", playbackDroppedFramesText)
                    infoRow("解码", playbackDecodeText)
                }
            }

            Divider().overlay(Color.white.opacity(0.10))

            Button {
                showFullProbe.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showFullProbe ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                    Text(showFullProbe ? "收起完整探测信息" : "更多探测信息")
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                    Text("⇧⌘I")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .foregroundStyle(.white.opacity(0.62))
            }
            .buttonStyle(.plain)

            if showFullProbe {
                ScrollView {
                    Text(fullProbeText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(playbackPathText, forType: .string)
            } label: {
                HStack(spacing: 6) {
                    Text("路径")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                    Text(playbackPathText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            .help("复制路径")
        }
        .padding(14)
        .frame(width: 520)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    /// 一列信息：小标题 + 若干行，四列宽度自适应。
    private func infoColumn<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(LumaBrand.amber.opacity(0.9))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 播放信息里的路径：网盘用云端路径，本地用源文件路径。
    private var playbackPathText: String {
        if let path = photo.cloudPath, !path.isEmpty { return path }
        if let sourceURL { return sourceURL.path }
        return LibraryPaths.sourceURL(for: photo).path
    }

    private var playbackResolutionText: String {
        let size = playbackProbe.size.width > 0 ? playbackProbe.size : videoSize
        guard size.width > 0, size.height > 0 else { return "—" }
        return "\(Int(size.width))×\(Int(size.height))"
    }

    private var playbackCodecText: String {
        var parts: [String] = []
        if let codec = playbackProbe.codec ?? photo.videoCodec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if let container = playbackProbe.containerName, !container.isEmpty {
            parts.append(container)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var playbackBitrateText: String {
        let bitrate = playbackProbe.bitrate
        guard bitrate > 0 else { return "—" }
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        return "\(bitrate / 1000) kbps"
    }

    private var playbackFrameRateText: String {
        guard playbackProbe.frameRate > 0 else { return playbackProbe.isInterlaced ? "隔行" : "—" }
        let fps = String(format: "%.2f fps", playbackProbe.frameRate)
        return playbackProbe.isInterlaced ? fps + " · 隔行（转码去隔行）" : fps
    }

    private var playbackAudioText: String {
        let tracks = playbackAudioTracks
        guard let first = tracks.first else { return "—" }
        let base = first.displayName.isEmpty ? "音轨 1" : first.displayName
        return tracks.count > 1 ? "\(base) · 共 \(tracks.count) 轨" : base
    }

    /// 音频列的细分字段：全部来自 ffprobe，缺数据时明确显示「—」。
    private var playbackAudioTracks: [AudioTrackInfo] {
        playbackProbe.audioTracks.isEmpty ? probeAudioTracks : playbackProbe.audioTracks
    }

    private var playbackPrimaryAudioText: String {
        guard let first = playbackAudioTracks.first else { return "—" }
        return first.displayName.isEmpty ? "音轨 1" : first.displayName
    }

    private var playbackAudioCodecText: String {
        guard let codec = playbackAudioTracks.first?.codec, !codec.isEmpty else { return "—" }
        return codec.uppercased()
    }

    private var playbackAudioChannelsText: String {
        guard let channels = playbackAudioTracks.first?.channels, channels > 0 else { return "—" }
        switch channels {
        case 1: return "单声道"
        case 2: return "立体声"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) 声道"
        }
    }

    private var playbackAudioLanguageText: String {
        guard let language = playbackAudioTracks.first?.language,
              !language.isEmpty, language.lowercased() != "und" else { return "—" }
        return language.uppercased()
    }

    private var playbackAudioTrackCountText: String {
        "\(playbackAudioTracks.count) 条"
    }

    private var playbackContainerText: String {
        guard let container = playbackProbe.containerName, !container.isEmpty else { return "—" }
        return container
    }

    /// 色彩：原色域 / 传输函数 / 量化范围 / codec tag，HDR 片源一眼能看出 BT.2020 + PQ。
    private var playbackColorText: String {
        let color = playbackProbe.color
        var parts: [String] = []
        if let primaries = color.primaries, !primaries.isEmpty { parts.append(primaries.uppercased()) }
        if let transfer = color.transfer, !transfer.isEmpty { parts.append(transfer.uppercased()) }
        if let range = color.range, !range.isEmpty { parts.append(range.uppercased()) }
        if let tag = color.codecTag, !tag.isEmpty { parts.append(tag) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var playbackFileSizeText: String {
        guard photo.fileSize > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file)
    }

    private var playbackPlayedText: String {
        let total = model.duration > 0 ? model.duration : (playbackProbe.duration > 0 ? playbackProbe.duration : 0)
        guard total > 0 else { return "—" }
        return "\(formatPlayerTime(model.currentTime)) / \(formatPlayerTime(total))"
    }

    /// 运行时码率 / 丢帧：从 AVPlayerItem 的访问日志取，起播几秒后才有值。
    private var playbackAccessLogEvent: AVPlayerItemAccessLogEvent? {
        model.player.currentItem?.accessLog()?.events.last
    }

    private var playbackLiveBitrateText: String {
        guard let bitrate = playbackAccessLogEvent?.observedBitrate, bitrate > 0 else { return "—" }
        return String(format: "%.1f Mbps", bitrate / 1_000_000)
    }

    private var playbackDroppedFramesText: String {
        guard let log = playbackAccessLogEvent else { return "—" }
        return "\(log.numberOfDroppedVideoFrames) 帧"
    }

    private var playbackDecodeText: String {
        if !playbackProbe.isVideoDecodable { return "软件转码" }
        return playbackProbe.isHEVC ? "硬解 · HEVC" : "系统硬解"
    }

    private var playbackSubtitleCurrentText: String {
        if let burn = ui.burnSubtitleName { return burn }
        if let ordinal = ui.embeddedTrackOrdinal,
           let track = ui.embeddedTracks.first(where: { $0.ordinal == ordinal }) {
            return track.displayName
        }
        if let name = ui.subtitleName, !name.isEmpty { return name }
        return "关"
    }

    private var playbackSubtitleSourceText: String {
        if ui.burnSubtitleName != nil || ui.burnSubtitleStream != nil { return "烧录" }
        if ui.embeddedTrackOrdinal != nil { return "内嵌" }
        if ui.subtitleName != nil { return "外挂" }
        return "—"
    }

    private var playbackSubtitleTracksText: String {
        let embedded = playbackProbe.subtitleTracks.count
        return embedded > 0 ? "内嵌 \(embedded) 轨" : "无内嵌轨"
    }

    private var playbackSubtitleOffsetText: String {
        String(format: "%+.1fs", ui.subtitleOffset)
    }

    private var playbackSubtitleSizeText: String {
        String(format: "%.0f pt", settings.subtitleFontSize)
    }

    private var playbackSubtitlePositionText: String {
        switch settings.subtitlePosition {
        case "middle": return "居中"
        case "lower": return "偏低"
        default: return "底部"
        }
    }

    /// ⌘⇧I 的完整探测信息：直接按字段列出，方便排查 HDR / 音轨 / 字幕轨问题。
    private var fullProbeText: String {
        let probe = playbackProbe
        var lines: [String] = []
        lines.append("path        \(playbackPathText)")
        lines.append("container   \(probe.containerName ?? "—")")
        lines.append("codec       \(probe.codec ?? photo.videoCodec ?? "—")  hevc=\(probe.isHEVC)")
        lines.append("size        \(Int(probe.size.width))×\(Int(probe.size.height))")
        lines.append("bitrate     \(probe.bitrate) bps")
        lines.append("frameRate   \(String(format: "%.3f", probe.frameRate))  interlaced=\(probe.isInterlaced)")
        lines.append("hdr         \(probe.hdrLabel ?? "—")  dv=\(probe.isDolbyVision)  profile=\(probe.color.dvProfile.map(String.init) ?? "—")")
        lines.append("color       primaries=\(probe.color.primaries ?? "—") transfer=\(probe.color.transfer ?? "—") matrix=\(probe.color.matrix ?? "—") range=\(probe.color.range ?? "—")")
        lines.append("decodable   \(probe.isVideoDecodable)  angles=\(probe.angleCount)")
        lines.append("chapters    \(probe.chapters.count)")
        for (index, track) in playbackAudioTracks.enumerated() {
            lines.append("audio[\(index)]    \(track.displayName)  codec=\(track.codec) channels=\(track.channels)")
        }
        for (index, track) in probe.subtitleTracks.enumerated() {
            lines.append("subtitle[\(index)] \(track.displayName)  image=\(track.isImage) forced=\(track.isForced)")
        }
        return lines.joined(separator: "\n")
    }

    /// 当前所在章节（信息叠加用）：章节标题来自蓝光播放列表 / Matroska。
    private var playbackChapterText: String {
        let chapters = playbackProbe.chapters.sorted { $0.start < $1.start }
        guard !chapters.isEmpty else { return "无" }
        let index = chapters.lastIndex(where: { $0.start <= model.currentTime + 0.2 }) ?? 0
        return "\(index + 1)/\(chapters.count) · \(chapters[index].title)"
    }

    /// 进度条上的章节刻度（比例）。
    private var chapterFractions: [Double] {
        guard model.duration > 0 else { return [] }
        return playbackProbe.chapters
            .map { min(1, max(0, $0.start / model.duration)) }
            .filter { $0 > 0.01 && $0 < 0.99 }
    }

    /// 探测结果统一入口：信息叠加、章节菜单与 HDR 开关都从同一份数据刷新，
    /// 避免各条起播分支只更新其中一部分。
    private func applyPlaybackProbe(_ probe: VideoProbe) {
        playbackProbe = probe
        // 角度数随探测结果更新；换到单角度片源时把选择收回 1。
        angleCount = max(1, probe.angleCount)
        if selectedAngle > angleCount { selectedAngle = 1 }
        // 蓝光盘内标题只在有章节时读（章节菜单的标题行）；普通片源不做多余的文件枚举。
        let discTitle = probe.chapters.count > 1
            ? sourceURL.flatMap { BluraySource.discTitle(for: $0) }
            : nil
        ui.updateChapters(probe.chapters, discTitle: discTitle)
        ui.updateAngles(count: angleCount, selected: selectedAngle)
        refreshHDRToneMapState()
    }

    /// HDR 映射开关：只有片源是 HDR / 杜比视界、且本机具备映射能力时才出现。
    private func refreshHDRToneMapState() {
        let probe = playbackProbe
        let isHDRSource = probe.isHDR || probe.isDolbyVision || probe.color.isHDR
        let capable = isHDRSource
            && VideoSupport.supportsToneMapping
            && !(probe.isDolbyVision && !VideoSupport.supportsLibplacebo)
        ui.updateHDRToneMap(available: capable, enabled: needsToneMapping(probe))
    }

    /// 章节跳转：⌥← / ⌥→ 与章节菜单共用；没有章节时返回 false，让按键继续走原逻辑。
    @discardableResult
    private func seekChapter(step: Int) -> Bool {
        let chapters = playbackProbe.chapters.sorted { $0.start < $1.start }
        guard chapters.count > 1 else { return false }
        if step > 0 {
            guard let next = chapters.first(where: { $0.start > model.currentTime + 0.6 }) else {
                return true
            }
            seekPlayback(to: next.start)
        } else {
            if let index = chapters.lastIndex(where: { $0.start <= model.currentTime - 2 }) {
                seekPlayback(to: chapters[index].start)
            } else {
                seekPlayback(to: chapters[0].start)
            }
        }
        return true
    }

    var body: some View {
        GeometryReader { proxy in
        ZStack {
            if !transparentBackground {
                Color.black
            }

            if hasLoadedVideo, activeFailure == nil {
                // 画面布局只发生在显示层：比例预设裁出一个居中框，平移与显示方式都在框内完成。
                let layout = framingLayout(in: proxy.size)
                ZStack {
                    PlayerLayerView(player: model.player,
                                    gravity: settings.videoFramingMode.gravity,
                                    opaqueBackground: !transparentBackground) { controller in
                        DispatchQueue.main.async {
                            model.attachPip(controller)
                        }
                    }
                    .frame(width: layout.preRotationContentSize.width,
                           height: layout.preRotationContentSize.height)
                    .rotationEffect(.degrees(Double(quarterTurns) * 90))
                    .offset(layout.panOffset)
                }
                .frame(width: layout.boxSize.width, height: layout.boxSize.height)
                .clipped()
                .scaleEffect(zoom)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if activeFailure == nil {
                tapLayer
            }

            // 起播阶段：海报直接垫底，出画面后淡出；等待反馈只留一枚紧凑缓冲胶囊。
            waitingLayer
                .animation(.easeOut(duration: 0.25), value: model.isItemReady)

            if let failure = activeFailure {
                failureView(failure)
            }

            if activeFailure == nil, let cue = activeCue {
                subtitleOverlay(cue, in: proxy.size)
            }

            if activeFailure == nil {
                centerPlayButton
                // 顶栏融合由窗口工具栏渲染控件；视频真全屏时工具栏被隐藏，改用画面内控制条。
                // 电视直播全屏已经用频道 OSD（顶部频道条 + 底部动作胶囊）承载操作，
                // 再叠一条通用播放栏会重复，这里直接不显示。
                let hidesPlaybackControls = tvLiveChannel != nil && viewer.videoImmersiveFullScreen
                if !hidesPlaybackControls,
                   settings.videoControlPlacement == .floating || !transparentBackground
                    || viewer.videoImmersiveFullScreen {
                    controls(stage: proxy.size)
                }
                // 顶栏融合模式下音轨 / 字幕入口在窗口工具栏的播放舱里。
            }

            // 电视 OSD：频道号 / Now & Next / 节目单抽屉 / 底部频道带。
            // 只在播放器已经就绪时出现，避免和失败卡片、起播海报叠在一起。
            tvOverlay

            if showPlaybackInfo, activeFailure == nil {
                VStack {
                    HStack {
                        Spacer()
                        playbackInfoOverlay
                    }
                    Spacer()
                }
                .padding(18)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // 播放器控件始终按深色玻璃渲染，避免浅色外观下白色文字叠在亮色材质上。
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                handleHoverMove()
            case .ended:
                scheduleControlsHide()
            }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing {
                scheduleControlsHide()
            } else {
                hideControlsTask?.cancel()
                controlsShown = true
            }
        }
        .onChange(of: photo.id) { _, _ in
            resetTVInput()
        }
        // 只在「开始 / 继续播放」时恢复生成，**暂停时不挂起 ffmpeg**：
        // EVENT 列表停更超过 1.5 × TARGETDURATION，AVPlayer 会报 -12888 并判定流已结束，
        // 之后不再拉新分片，恢复播放时直接卡死。暂停期间继续生成也顺带把后面缓冲做好。
        .onChange(of: model.wantsPlayback) { _, wants in
            if wants { playbackSession.setGenerationActive(true) }
        }
        // 转封装后的 HLS 也可能在解码阶段失败：这时必须把「转换为兼容格式」入口放出来，
        // 否则用户只能停在错误页。真正的兼容性判断由 ffmpeg 转码兜底。
        .onChange(of: model.playbackFailure) { _, failure in
            handlePlaybackFailure(failure)
        }
        .onChange(of: settings.preservePitchAtSpeed) { _, enabled in
            model.preservesPitch = enabled
            model.applyPitchPreference()
        }
        .onChange(of: settings.systemMediaIntegration) { _, enabled in
            if enabled {
                activateNowPlaying()
            } else {
                NowPlayingCenter.shared.deactivate()
            }
        }
        .onChange(of: model.isBuffering) { _, buffering in
            guard buffering, hasLoadedVideo else { return }
            Diagnostics.record("播放缓冲 \(photo.originalName) at \(Int(model.currentTime))s", level: .verbose)
        }
        // 流地址层面失败（403 / 超时 / 直链失效）不会走 playbackFailure，单独顺延一次。
        .onChange(of: streamFailure) { _, value in
            handleStreamFailureChange(value)
        }
        // 原生容器的音轨组就绪 / 切换后，把选项同步给顶栏与画面内菜单。
        .onChange(of: model.audioOptions.count) { _, _ in refreshAudioChoices() }
        .onChange(of: model.selectedAudio) { _, _ in refreshAudioChoices() }
        .task(id: photo.id) {
            await startPlaybackTask()
        }
        .onDisappear {
            handleStageDisappear()
        }
        .background(
            KeyEventMonitor { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)
        )
        .background(
            WindowAccessor { window in
                if playerWindow !== window { playerWindow = window }
            }
            .frame(width: 0, height: 0)
        )
        }
    }

    /// 换片 / 首帧载入的完整准备流程：重置状态、注册播放回调，再起播。
    /// 从 `.task` 里抽出来，避免 SwiftUI 对超大表达式做类型检查超时。
    private func preparePlayback(generation: Int) async {
        autoEmbeddedTried = false
        // 播放期偏好：变速保音调、音轨是否即时切换都在装片前交给内核。
        model.preservesPitch = settings.preservePitchAtSpeed
        playbackSession.prefersMultiAudio = settings.instantAudioSwitch
        // 起播底图：本地视频的缩略图先垫一层模糊背景，网络源没有就退回渐变。
        loadingThumbnail = fileExistsThumbnail()
        // 网络资源：用当前这一集的封面做起播底图；单集没有封面时才退回条目封面。
        if loadingThumbnail == nil,
           let context = store.catalogPlaybackContexts[photo.id] {
            let cover = context.episode.coverURL.isEmpty ? context.item.coverURL : context.episode.coverURL
            if !cover.isEmpty {
                let source = context.source
                let targetID = photo.id
                Task { @MainActor in
                    let artwork = await CatalogArtworkCache.shared.image(source: source,
                                                                         urlString: cover,
                                                                         quick: true)
                    guard photo.id == targetID else { return }
                    if let artwork {
                        loadingThumbnail = artwork
                    }
                }
            }
        }
        // 影院匹配过的本地 / SMB 视频：用刮削背景图做起播底图，
        // 大文件探测 / 首段生成期间不会只剩一块黑底。
        // 剧集优先取「本集剧照」，没有剧照（或电影）才回退整部作品的背景。
        if loadingThumbnail == nil,
           let entry = store.cinemaPlaybackEntry,
           entry.file.photoID == photo.id,
           let artwork = store.cinemaGridArtwork(for: photo) {
            let targetID = photo.id
            let tvID = entry.tmdbID
            let season = entry.season
            let episode = entry.episode
            let isEpisode = entry.kind == .tv && tvID != nil && season != nil && episode != nil
            Task { @MainActor in
                if isEpisode, let tvID, let season, let episode {
                    var still = store.cachedCinemaEpisodeInfos(tvID: tvID,
                                                               season: season)?.infos[episode]?.stillURL
                    if still == nil {
                        // 本集剧照还没缓存：补拉一次（12 小时内只请求一次）。
                        still = await store.refreshCinemaEpisodeInfos(tvID: tvID,
                                                                      season: season)?[episode]?.stillURL
                    }
                    if let still,
                       let image = await CinemaArtworkCache.shared.image(for: still) {
                        guard photo.id == targetID else { return }
                        if loadingThumbnail == nil { loadingThumbnail = image }
                        return
                    }
                    guard photo.id == targetID, loadingThumbnail == nil else { return }
                }
                let image = await CinemaArtworkCache.shared.image(for: artwork)
                guard photo.id == targetID, loadingThumbnail == nil else { return }
                if let image { loadingThumbnail = image }
            }
        }
        // 先停掉上一个视频：新视频的 URL / 探测还是要等一会，
        // 期间旧音频继续播会让"画面已经是别的照片，声音还在"。
        model.stop()
        playbackSession.stop()
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        sourceURL = nil
        sourceHeaders = [:]
        hasLoadedVideo = false
        probeDuration = 0
        probeIsHEVC = false
        probeIsHDR = false
        probeAudioCount = 0
        probeAudioTracks = []
        applyPlaybackProbe(VideoProbe())
        hdrToneMapOverride = nil
        selectedAngle = 1
        showPlaybackInfo = false
        ui.reset()
        configureSubtitleQuery()
        registerPlaybackCallbacks()
        quarterTurns = 0
        videoSize = .zero
        refreshVideoNeighbors()
        await load(generation: generation)
        registerScrubPreviewFallback()
        activateNowPlaying()
        await loadTechnicalProbe(generation: generation)
        // 优先级最低的一档：同目录 / 内嵌都没挂上时，才按设置在线匹配一条。
        await ui.autoMatchOnlineSubtitleIfNeeded()
    }

    /// 在线字幕搜索上下文：影院用刮削出的片名与季集号，网络资源用条目标题与集数。
    private func configureSubtitleQuery() {
        if let entry = store.cinemaPlaybackEntry, entry.file.photoID == photo.id {
            ui.subtitleQuery = CinemaSubtitleQuery(title: entry.title,
                                                   season: entry.season,
                                                   episode: entry.episode)
        } else if let context = store.catalogPlaybackContext(for: photo.id) {
            ui.subtitleQuery = CinemaSubtitleQuery(title: context.item.title,
                                                   season: nil,
                                                   episode: context.episode.index)
        } else {
            // 图库里的视频没有刮削信息：用文件名兜底，手动搜在线字幕时还能用。
            let name = (photo.originalName as NSString).deletingPathExtension
            ui.subtitleQuery = name.isEmpty ? nil : CinemaSubtitleQuery(title: name,
                                                                        season: nil,
                                                                        episode: nil)
        }
    }

    /// 拖动进度条的预览帧：HLS 已生成区间用会话取帧，其余回退到原始片源。
    private func scrubThumbnail(fraction: Double) async -> NSImage? {
        guard settings.scrubPreviewEnabled else { return nil }
        if let image = await VideoScrubThumbnails.image(player: model.player,
                                                        fraction: fraction,
                                                        duration: model.duration) {
            return image
        }
        guard let sourceURL, model.duration > 0 else { return nil }
        return await VideoScrubThumbnails.sourceImage(source: sourceURL,
                                                      headers: sourceHeaders,
                                                      seconds: model.duration * fraction,
                                                      duration: model.duration)
    }

    /// 顶栏悬停预览的回退取帧：拖到 HLS 还没生成的区间时，从原始片源抽一帧。
    private func registerScrubPreviewFallback() {
        VideoScrubPreviewCenter.shared.fallbackProvider = { fraction, duration in
            guard settings.scrubPreviewEnabled, let url = sourceURL, duration > 0 else { return nil }
            return await VideoScrubThumbnails.sourceImage(source: url,
                                                          headers: sourceHeaders,
                                                          seconds: duration * fraction,
                                                          duration: duration)
        }
    }

    /// 播放回调只在换片时注册一次：一切跳转、音轨、字幕操作都从这里分发。
    private func registerPlaybackCallbacks() {
        model.onPlaybackEnd = {
            playbackSession.notifyPlaybackFinished()
            guard settings.autoPlayNextVideo else { return }
            store.playNextVideo(after: photo.id)
        }
        // 所有界面跳转（进度条 / 工具栏 / 快捷键）统一走路由器：
        // 云盘拖到未生成区间时重建流，已完成缓存的 HLS 直接 seek。
        model.seekRouter = { target in
            // 正在重建流：新会话还没装好，先记下最新目标，就绪后再追过去。
            if playbackSession.isRestartingStream {
                playbackSession.queueRestart(target)
                return true
            }
            guard playbackSession.streamSession != nil else { return false }
            if playbackSession.isCompleteCache { return false }
            // 是否要重建流由内核统一判定，播放页不再自己算窗口。
            if playbackSession.seekDecision(target: target) == .restart {
                restartStreaming(at: target)
                return true
            }
            return false
        }
        // 卡死兜底：分片充足却长时间不前进，AVPlayer 可能进入了无法自愈的等待状态，
        // 由播放页在当前位置重建一次流。
        playbackSession.onHardStall = { target in
            guard !playbackSession.isRestartingStream else { return }
            restartStreaming(at: target)
        }
        // 直连云端视频卡住：网盘直链只有一条连接，被限速后永远等不到数据，
        // 改走转封装 + 本地 Range 代理的并行预取。
        playbackSession.onNativeStall = { target in
            switchToStreamingForSlowSource(at: target)
        }
        // 拖动时只允许在已生成区间内落帧预览，越界位置等松手后再重建流。
        model.scrubGuard = { target in
            // 重建流期间旧会话已经/正在废弃，不再用它做预览落帧。
            if playbackSession.isRestartingStream { return false }
            guard let session = playbackSession.streamSession,
                  !session.isCompleteCache else { return true }
            return target >= session.retainedStartSeconds - 1
                && target <= session.generatedEndSeconds + 2
        }
        ui.onMessage = { message in store.showToast(message) }
        ui.onSelectStreamAudio = { index in
            // 多音轨 HLS：所有音轨都已在同一会话里，AVPlayer 即时换轨即可。
            if playbackSession.isMultiAudio, index < model.audioOptions.count {
                playbackSession.previewAudioIndex(index)
                model.selectAudio(index: index)
                refreshAudioChoices()
                return
            }
            if playbackSession.streamSession != nil {
                switchAudio(to: index)
            } else if index < model.audioOptions.count {
                model.selectAudio(model.audioOptions[index])
            }
        }
        ui.onSeekChapter = { target in
            seekPlayback(to: target)
        }
        ui.onToggleHDRToneMapping = { enabled in
            setHDRToneMapping(enabled)
        }
        ui.onSelectAngle = { angle in
            setAngle(angle)
        }
        ui.onSelectEmbeddedSubtitle = { track in
            Task { await extractEmbeddedSubtitle(track) }
        }
        ui.onSubtitleSelectionRemembered = { selection in
            settings.rememberSubtitle(selection, for: photo.id)
        }
        ui.onBurnSubtitleChanged = {
            guard sourceURL != nil else {
                store.showToast("当前视频没有可读取的源文件，无法烧录字幕")
                return
            }
            let target = model.currentTime
            playbackSession.stop()
            hasLoadedVideo = false
            isPreparing = true
            let generation = loadGeneration
            Task { @MainActor in
                let started = await startStreaming(generation: generation, autoplay: true,
                                                   offset: max(0, target - 1),
                                                   resumeAt: target,
                                                   mode: .transcode,
                                                   audioIndex: playbackSession.streamAudioIndex)
                if !started, generation == loadGeneration {
                    model.seek(to: target)
                }
                isPreparing = false
            }
        }
    }

    /// 系统媒体集成：控制中心 / 耳机 / 键盘媒体键看到当前视频并可直接控制。
    private func activateNowPlaying() {
        guard settings.systemMediaIntegration else {
            NowPlayingCenter.shared.deactivate()
            return
        }
        let subtitle: String?
        if let entry = store.cinemaPlaybackEntry {
            var parts = [entry.title]
            if let title = photo.title, title != entry.title { parts.append(title) }
            subtitle = parts.joined(separator: " · ")
        } else if let title = photo.title, title != photo.originalName {
            subtitle = title
        } else {
            subtitle = nil
        }
        NowPlayingCenter.shared.activate(model: model,
                                         title: photo.title ?? photo.originalName,
                                         subtitle: subtitle,
                                         artwork: loadingThumbnail,
                                         onNext: { store.viewerStepVideo(1) },
                                         onPrevious: { store.viewerStepVideo(-1) })
    }

    /// 起播后再补一次 ffprobe：拿码率 / 帧率 / HDR / 章节，供 I 键信息叠加与章节菜单使用。
    /// 不阻塞起播；HLS 播放列表与不存在的本地文件直接跳过。
    private func loadTechnicalProbe(generation: Int) async {
        // 缓存起播时真实直链还在后台解析：先不拿占位地址做探测，等直链回来再补。
        guard !cachedSourcePending else { return }
        guard let url = sourceURL else { return }
        if url.pathExtension.lowercased() == "m3u8" { return }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return }
        let probe = await VideoSupport.technicalProbe(url: url, options: assetOptions)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard probe.hasVideoTrack || !probe.chapters.isEmpty || !probe.subtitleTracks.isEmpty else { return }

        var merged = playbackProbe
        if probe.size.width > 0 { merged.size = probe.size }
        if let codec = probe.codec { merged.codec = codec }
        merged.isHDR = merged.isHDR || probe.isHDR
        merged.isDolbyVision = merged.isDolbyVision || probe.isDolbyVision
        merged.isInterlaced = merged.isInterlaced || probe.isInterlaced
        merged.angleCount = max(merged.angleCount, probe.angleCount)
        if let label = probe.hdrLabel, !label.isEmpty { merged.hdrLabel = label }
        if probe.bitrate > 0 { merged.bitrate = probe.bitrate }
        if probe.frameRate > 0 { merged.frameRate = probe.frameRate }
        if let container = probe.containerName { merged.containerName = container }
        if !probe.chapters.isEmpty { merged.chapters = probe.chapters }
        if probe.audioTracks.count > merged.audioTracks.count { merged.audioTracks = probe.audioTracks }
        merged.duration = max(merged.duration, probe.duration)
        if merged.subtitleTracks.isEmpty, !probe.subtitleTracks.isEmpty {
            merged.subtitleTracks = probe.subtitleTracks
        }
        applyPlaybackProbe(merged)
        applyDisplayRate(merged.frameRate)
        // 预热接管 / 转封装起流时音轨信息可能为空：探测到后补齐菜单。
        if merged.audioTracks.count > probeAudioTracks.count {
            probeAudioTracks = merged.audioTracks
            probeAudioCount = merged.audioTracks.count
            refreshAudioChoices()
        }
        ui.updateEmbeddedTracks(merged.subtitleTracks)
        restoreRememberedSubtitleIfNeeded()
        autoLoadEmbeddedSubtitleIfNeeded()
    }

    /// 上次手动选过的字幕：同一部影片重开时优先恢复，不再走默认偏好。
    /// 同目录外挂字幕可能已经自动挂上，这里按记忆覆盖；当次已手动选过则不打扰。
    private func restoreRememberedSubtitleIfNeeded() {
        guard !ui.hasManualSubtitleChoice else { return }
        guard let memory = settings.rememberedSubtitle(for: photo.id) else { return }
        switch memory.kind {
        case .embedded:
            guard ui.embeddedTrackOrdinal == nil, let ordinal = memory.ordinal,
                  let track = ui.embeddedTracks.first(where: { $0.ordinal == ordinal && !$0.isImage })
            else { return }
            ui.selectEmbeddedTrack(track, remember: false)
        case .external:
            guard let fileName = memory.fileName, let sourceURL,
                  let url = SubtitleLoader.sibling(named: fileName, of: sourceURL) else { return }
            guard ui.subtitleName != fileName else { return }
            ui.loadSubtitle(url: url)
        }
    }

    /// 内嵌字幕轨探测到后自动挂载一条：按默认中文偏好排序（简体 > 繁体 > 中文 > 原文）。
    /// 只对本地 / SMB 源自动提取，云端交给用户手动选，避免和起流抢网盘带宽。
    private func autoLoadEmbeddedSubtitleIfNeeded() {
        // 默认字幕设为「不自动挂载」时，连内嵌轨也不主动提取。
        guard settings.videoPreferredSubtitle != "off" else { return }
        guard settings.autoEmbeddedSubtitles else { return }
        guard let sourceURL, sourceURL.isFileURL else { return }
        guard !autoEmbeddedTried,
              !ui.hasSubtitle,
              ui.embeddedTrackOrdinal == nil else { return }
        // 图形字幕（PGS）提不出来，只从文本轨里挑；forced 只翻译招牌 / 歌曲，排在完整轨之后。
        let textTracks = ui.embeddedTracks.filter { !$0.isImage }
        guard !textTracks.isEmpty else { return }
        autoEmbeddedTried = true
        let preferred = textTracks.filter { !$0.isForced }
        let pool = preferred.isEmpty ? textTracks : preferred
        guard let index = SubtitlePreference.bestIndex(languages: pool.map(\.language),
                                                      titles: pool.map(\.title)) else { return }
        ui.selectEmbeddedTrack(pool[index], remember: false)
    }

    /// 用 ffmpeg 把选中的内嵌字幕轨提取成 ASS 文本，再交给字幕覆盖层渲染。
    private func extractEmbeddedSubtitle(_ track: SubtitleTrackInfo) async {
        guard let sourceURL else {
            ui.failEmbeddedSubtitle("当前视频没有可读取的源文件")
            return
        }
        let mount = photo.isCloud ? store.cloudMount(for: photo.cloudMountID) : nil
        let cues = await EmbeddedSubtitleLoader.extract(source: sourceURL,
                                                        headers: sourceHeaders,
                                                        trustSelfSigned: mount?.trustSelfSigned ?? false,
                                                        track: track.ordinal)
        guard !Task.isCancelled else { return }
        ui.applyEmbeddedSubtitle(name: track.displayName, cues: cues)
    }

    /// 按片源帧率切显示器刷新率：设置里可关，找不到合适模式会自动保持原样。
    /// 延迟到首帧出来之后再切：切模式会短暂黑屏，和起播叠在一起就会被看成「打开时卡了一下」。
    private func applyDisplayRate(_ rate: Double) {
        guard settings.matchDisplayFrameRate, rate > 1 else { return }
        let generation = loadGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            DisplayModeMatcher.match(frameRate: rate)
        }
    }

    /// 显示器是否能显示 HDR（EDR headroom > 1.0）。SDR 屏上让系统自己 tone map 观感会变，
    /// 所以自动策略改为先映射成 SDR 再播。
    ///
    /// 必须优先看播放窗口所在的那块屏：`NSScreen.main` 在 App 不是前台 / 窗口全屏切换时
    /// 可能为 nil，之前会误判成 SDR 屏，把 4K60 HDR 强行转码（只有 1× 实时，必然周期性缓冲）。
    private var displaySupportsHDR: Bool {
        if let screen = playerWindow?.screen ?? NSScreen.main {
            return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        }
        // 窗口还没挂到屏幕上：只要任意一块屏支持 EDR 就按 HDR 处理。
        return NSScreen.screens.contains {
            $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        }
    }

    /// 屏幕信息：排查「为什么这条 HDR 片走了转码」时直接看日志。
    private var displayHDRDiagnostics: String {
        let screen = playerWindow?.screen ?? NSScreen.main
        let edr = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? -1
        return "displayHDR=\(displaySupportsHDR) edr=\(String(format: "%.2f", edr))"
    }

    /// 缓存快路径没有探测，只能按当前设置与屏幕能力判断是否必须拿 SDR 结果：
    /// 否则 SDR 屏 / 强制映射会命中之前生成的 HDR remux 缓存，画面发灰过曝。
    private var cacheRequiresSDR: Bool {
        // 用本次播放实际生效的策略判断：播放器内的 HDR 开关优先于全局设置，
        // 否则手动切换映射后仍会命中之前生成的 HDR remux 缓存。
        let mode = effectiveHDRMode
        guard mode != .keepHDR, VideoSupport.supportsToneMapping else { return false }
        return mode == .toneMapSDR || !displaySupportsHDR
    }

    /// 本次播放实际生效的 HDR 策略：播放器内的开关优先于全局设置。
    private var effectiveHDRMode: VideoHDRMode {
        guard let hdrToneMapOverride else { return settings.videoHDRMode }
        return hdrToneMapOverride ? .toneMapSDR : .keepHDR
    }

    /// 这条片源是否需要先做 HDR → SDR 映射再交给播放器。
    /// 决策顺序：保持原样 > 能力检查 > 用户强制 > 自动（屏幕 EDR）。
    private func needsToneMapping(_ probe: VideoProbe) -> Bool {
        guard probe.isHDR || probe.isDolbyVision || probe.color.isHDR else { return false }
        guard effectiveHDRMode != .keepHDR else { return false }
        guard VideoSupport.supportsToneMapping else { return false }
        // 杜比视界的 RPU 只有 libplacebo 能应用：没有它就别转码，宁可按原样交给系统。
        if probe.isDolbyVision, !VideoSupport.supportsLibplacebo { return false }
        if effectiveHDRMode == .toneMapSDR { return true }
        // HDR 屏优先保留片源：杜比视界 P5 也交给系统解码，只有 SDR 屏才映射。
        // 若系统拒绝该码流，PlaybackSession 会按起流失败自动降级为重编码 + tone map。
        return !displaySupportsHDR
    }

    /// 4K 50/60fps 的 HEVC：实测这台机器的系统解码器出不了画面（有声音、全黑），
    /// 而且换容器也救不回来。直接重编码虽然多花几秒起播，但比「黑屏几秒再降级」干净。
    private static func requiresRecodeForHighFrameRate4K(_ probe: VideoProbe) -> Bool {
        guard probe.isHEVC, probe.frameRate >= 45 else { return false }
        return max(probe.size.width, probe.size.height) >= 1700
    }

    /// 杜比视界 P5 的播放路径提示：HDR 屏保留原样时记录一次诊断；
    /// 没有 libplacebo 时明确告诉用户颜色无法还原，而不是静默偏色。
    private func notifyIfDolbyVisionUnsupported(_ probe: VideoProbe) {
        guard probe.isDolbyVision, probe.color.dvProfile == 5, !dvHintShown else { return }
        if !VideoSupport.supportsLibplacebo {
            dvHintShown = true
            Diagnostics.record("杜比视界 Profile 5 缺少 libplacebo，无法正确映射颜色：\(photo.originalName)")
            store.showToast("杜比视界 Profile 5 需要带 libplacebo 的 ffmpeg 才能还原颜色")
        } else if settings.videoHDRMode == .automatic, displaySupportsHDR {
            dvHintShown = true
            Diagnostics.record("杜比视界 P5：HDR 屏保留原样，交给系统解码：\(photo.originalName)")
        }
    }

    /// 当前播放的是网络资源的分集（每一集都是一个虚拟视频）。
    private var isCatalogPlayback: Bool {
        store.catalogPlaybackContext(for: photo.id) != nil
    }

    /// 分集式片源（网络资源 / 网络存储影院）：方向键让给播放控制，← / → 快进快退，↑ / ↓ 上一条 / 下一条。
    private var isEpisodeTransport: Bool {
        store.usesEpisodeTransport(for: photo)
    }

    /// 视频快捷键：
    /// - 图库视频与照片翻页一致：← / → 上一个 / 下一个项目（照片与视频都算），↑ / ↓ 快退 / 快进。
    /// - 网络资源与网络存储影院的视频：← / → 快退 / 快进，↑ / ↓ 上一条 / 下一条。
    /// - ⌘ + 方向键：始终只切换上一个 / 下一个视频。
    /// - J / L：快退 / 快进，与方向键共用同一个步长与加速。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)

        // 可自定义快捷键允许 ⌥ / ⌃ / ⇧ 组合，先于固定键位匹配。
        if !hasCommand, handleCustomShortcut(event) { return true }

        // 电视遥控语义：↑↓ 换台、数字键输入频道号、E 节目单、S 收藏。
        if let channel = tvPlaybackChannel, !hasCommand, flags.isEmpty {
            // Esc 逐层退出：先回直播 / 收节目单抽屉，再收 OSD，最后交给查看器退出播放。
            if event.keyCode == 53 {
                if viewer.tvTimeshiftActive {
                    viewer.tvTimeshiftActive = false
                    model.requestSeek(to: max(0, model.bufferedEndTime - 0.5))
                    model.play()
                    return true
                }
                if viewer.tvGuideShown {
                    withAnimation(.easeOut(duration: 0.2)) { viewer.tvGuideShown = false }
                    return true
                }
                if controlsShown, model.isPlaying {
                    withAnimation(.easeInOut(duration: 0.25)) { controlsShown = false }
                    return true
                }
            }
            if tvLiveChannel != nil {
                if event.keyCode == 126 {
                    switchTVChannel(step: -1)
                    return true
                }
                if event.keyCode == 125 {
                    switchTVChannel(step: 1)
                    return true
                }
                // 时移模式里 ← / → 变成 10 秒步进；否则仍按直播语义切线路。
                if viewer.tvTimeshiftActive {
                    if event.keyCode == 123 {
                        seekTimeshift(by: -10)
                        return true
                    }
                    if event.keyCode == 124 {
                        seekTimeshift(by: 10)
                        return true
                    }
                }
                if let live = tvLiveChannel, live.streamLines.count > 1 {
                    if event.keyCode == 123 {
                        store.switchTVLine(for: photo.id, delta: -1)
                        return true
                    }
                    if event.keyCode == 124 {
                        store.switchTVLine(for: photo.id, delta: 1)
                        return true
                    }
                }
                // L：从时移 / 落后处跳回直播边缘。
                if event.keyCode == 37 {
                    viewer.tvTimeshiftActive = false
                    model.requestSeek(to: max(0, model.bufferedEndTime - 0.5))
                    model.play()
                    store.showToast("已回到直播")
                    return true
                }
                if let digit = channelDigit(event.keyCode) {
                    appendChannelDigit(digit)
                    return true
                }
            }
            if event.keyCode == 14 {
                viewer.tvGuideShown.toggle()
                return true
            }
            if event.keyCode == 1 {
                store.tvModel.toggleFavorite(channel)
                store.showToast(store.tvModel.isFavorite(channel)
                                ? "已收藏 \(channel.name)"
                                : "已取消收藏 \(channel.name)")
                return true
            }
        }

        // ⌥← / ⌥→：上一章 / 下一章；I：播放信息叠加；⇧⌘I：完整探测信息。
        if flags == .option, event.keyCode == 123, seekChapter(step: -1) { return true }
        if flags == .option, event.keyCode == 124, seekChapter(step: 1) { return true }
        if hasCommand, flags.contains(.shift), event.keyCode == 34 {
            showPlaybackInfo = true
            showFullProbe.toggle()
            return true
        }
        if event.keyCode == 34, flags.isEmpty {
            showPlaybackInfo.toggle()
            return true
        }
        // S / A：快速切换字幕 / 音轨，切换结果用 Toast 回报当前轨道。
        if event.keyCode == 1, flags.isEmpty {
            cycleSubtitleTrack()
            return true
        }
        if event.keyCode == 0, flags.isEmpty {
            cycleAudioTrack()
            return true
        }

        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        let episodeTransport = isEpisodeTransport
        // 回看是一档节目的点播：← / → 用来快退 / 快进，不翻上一条 / 下一条。
        let seeksWithArrows = episodeTransport || (tvPlaybackChannel?.isCatchUp == true)
        switch event.keyCode {
        case 123:
            if seeksWithArrows {
                model.seekStep(-1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            } else if hasCommand {
                store.viewerStepVideo(-1)
            } else {
                store.viewerStep(-1)
            }
            return true
        case 124:
            if seeksWithArrows {
                model.seekStep(1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            } else if hasCommand {
                store.viewerStepVideo(1)
            } else {
                store.viewerStep(1)
            }
            return true
        case 126:
            if episodeTransport || hasCommand {
                store.viewerStepVideo(-1)
            } else {
                model.seekStep(1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            }
            return true
        case 125:
            if episodeTransport || hasCommand {
                store.viewerStepVideo(1)
            } else {
                model.seekStep(-1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            }
            return true
        case 49:
            // 空格与系统「照片」一致：收起查看器回到图库；播放/暂停用 K 或回车。
            // 长按的重复事件直接吞掉，避免刚打开又被关掉。
            guard !event.isARepeat else { return true }
            store.closeViewer()
            return true
        case 36:
            // 回车：播放 / 暂停（始终保留为备用键）。
            model.togglePlay()
            return true
        case 43:
            model.stepFrame(by: -1)
            return true
        case 47:
            model.stepFrame(by: 1)
            return true
        default:
            return false
        }
    }

    /// ↑↓ 换台：沿用查看器里的频道上下文，并在顶部提示目标频道。
    private func switchTVChannel(step: Int) {
        let photos = store.tvPlaybackPhotos
        guard photos.count > 1,
              let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        let target = photos[(index + step + photos.count) % photos.count]
        if let next = store.tvPlaybackChannel(for: target.id) {
            store.showToast("\(String(format: "%02d", store.tvModel.channelNumber(for: next))) · \(next.name)")
        }
        store.viewerStep(step)
    }

    /// 主键盘数字 0–9 的 keyCode。
    private func channelDigit(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 29: return 0
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    /// 数字键 1.5 秒缓冲：期间继续输入就拼成多位频道号，超时后直接跳转。
    private func appendChannelDigit(_ digit: Int) {
        guard tvChannelNumberBuffer.count < 3 else { return }
        tvChannelNumberBuffer.append(String(digit))
        store.showToast("频道号 \(tvChannelNumberBuffer)")
        tvChannelNumberTask?.cancel()
        tvChannelNumberTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            commitChannelNumber()
        }
    }

    private func commitChannelNumber() {
        let value = Int(tvChannelNumberBuffer) ?? 0
        tvChannelNumberBuffer = ""
        tvChannelNumberTask = nil
        guard value > 0 else { return }
        let list = store.tvModel.channelsForFocusedSource
        guard let target = list.first(where: { store.tvModel.channelNumber(for: $0) == value }) else {
            store.showToast("没有 \(value) 号频道")
            return
        }
        store.showToast("\(String(format: "%02d", value)) · \(target.name)")
        store.switchTVChannel(target)
    }

    /// S 键：在内嵌文本字幕之间轮换，最后一轨之后关闭字幕。
    private func cycleSubtitleTrack() {
        let tracks = playbackProbe.subtitleTracks.filter { !$0.isImage }
        guard !tracks.isEmpty else {
            store.showToast("这个视频没有可切换的内嵌字幕")
            return
        }
        if let current = ui.embeddedTrackOrdinal,
           let index = tracks.firstIndex(where: { $0.ordinal == current }) {
            let next = tracks.index(after: index)
            if next < tracks.endIndex {
                ui.selectEmbeddedTrack(tracks[next])
                store.showToast("字幕 · \(tracks[next].displayName)")
            } else {
                ui.clearEmbeddedSubtitle()
                store.showToast("已关闭字幕")
            }
        } else {
            ui.selectEmbeddedTrack(tracks[0])
            store.showToast("字幕 · \(tracks[0].displayName)")
        }
    }

    /// A 键：在音轨之间轮换。
    private func cycleAudioTrack() {
        let choices = ui.audioChoices
        guard choices.count > 1 else {
            store.showToast("这个视频只有一条音轨")
            return
        }
        guard let index = choices.firstIndex(where: { $0.index == ui.selectedAudioIndex }) else {
            ui.selectAudio(choices[0].index)
            return
        }
        let next = choices[(index + 1) % choices.count]
        ui.selectAudio(next.index)
        store.showToast("音轨 · \(next.title.isEmpty ? "音轨 \(next.index + 1)" : next.title)")
    }

    /// 设置 › 快捷键里可自定义的播放器动作。
    private func handleCustomShortcut(_ event: NSEvent) -> Bool {
        if ShortcutStore.matches(event, .videoPlayPause) {
            model.togglePlay()
            return true
        }
        if ShortcutStore.matches(event, .videoMute) {
            model.isMuted.toggle()
            return true
        }
        if ShortcutStore.matches(event, .videoForward) {
            model.seekStep(1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            return true
        }
        if ShortcutStore.matches(event, .videoBackward) {
            model.seekStep(-1, base: settings.videoSeekStep, isRepeat: event.isARepeat)
            return true
        }
        if ShortcutStore.matches(event, .videoAspect) {
            toggleGravity()
            return true
        }
        if ShortcutStore.matches(event, .videoRotate) {
            rotatePlayer()
            return true
        }
        if ShortcutStore.matches(event, .videoFullscreen) {
            toggleFullScreen()
            return true
        }
        return false
    }

    private var tapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                toggleFullScreen()
            }
            .onTapGesture {
                model.togglePlay()
            }
    }

    // MARK: 控制层显隐

    private func handleHoverMove() {
        let now = Date()
        guard now.timeIntervalSince(lastHoverMove) > 0.12 else { return }
        lastHoverMove = now
        revealControls()
    }

    private func revealControls() {
        if !controlsShown {
            withAnimation(.easeOut(duration: 0.18)) { controlsShown = true }
        }
        scheduleControlsHide()
    }

    /// 播放中静止 3 秒后淡出控制层；暂停时控制层始终可见。
    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard model.isPlaying else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.28)) { controlsShown = false }
        }
    }

    private var centerPlayButton: some View {
        // 缓冲 / 跳转时不要露出播放按钮，否则看起来像是被暂停了。
        let visible = !model.isPlaying && !isPreparing && !model.isStalled && activeFailure == nil
        return Button {
            model.play()
            revealControls()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 1.5)
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.38), radius: 20, y: 8)
        }
        .buttonStyle(.plain)
        .help("播放 (K)")
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.88)
        .allowsHitTesting(visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: visible)
    }

    private var volumeIcon: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var durationText: String {
        if showRemainingTime, model.duration > 0 {
            return "-" + formatPlayerTime(max(0, model.duration - model.currentTime))
        }
        return formatPlayerTime(model.duration)
    }

    private func controls(stage: CGSize) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 30, height: 3)
                }
                .frame(width: 52, height: 12)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { resetControlPanel() }
                .help("按住拖动控制条，双击复位")

                HStack(spacing: 8) {
                    Text(formatPlayerTime(model.currentTime))
                        .frame(minWidth: 38, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    VideoScrubber(progress: progress,
                                  buffered: buffered,
                                  bufferedStart: bufferedStart,
                                  knobBorder: .black.opacity(0.35),
                                  duration: model.duration,
                                  chapterFractions: chapterFractions,
                                  thumbnailPreview: { fraction in
                                      await scrubThumbnail(fraction: fraction)
                                  }) { value in
                        scrubPlayback(to: value * model.duration)
                    } onCommit: { value in
                        seekPlayback(to: value * model.duration)
                    }
                    Text(durationText)
                        .frame(minWidth: 38, alignment: .leading)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Rectangle())
                        .onTapGesture { showRemainingTime.toggle() }
                        .help("点击切换已播 / 剩余时长")
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 2) {
                    VideoControlButton(icon: model.isPlaying ? "pause.fill" : "play.fill",
                                       emphasized: true,
                                       busy: model.isStalled,
                                       help: model.isStalled ? "正在载入新位置"
                                                             : (model.isPlaying ? "暂停 (K)" : "播放 (K)")) {
                        model.togglePlay()
                    }
                    VideoControlButton(icon: "backward.end",
                                       help: isEpisodeTransport ? "上一条 (↑)" : "上一个 (←)") {
                        if isEpisodeTransport {
                            store.viewerStepVideo(-1)
                        } else {
                            store.viewerStep(-1)
                        }
                    }
                    .disabled(!hasPrevVideo)
                    VideoControlButton(icon: "gobackward",
                                       help: isEpisodeTransport
                                           ? "后退 \(Int(settings.videoSeekStep)) 秒 (← / J)，按住快退"
                                           : "后退 \(Int(settings.videoSeekStep)) 秒 (↓ / J)，按住快退",
                                       repeatsWhileHeld: true) {
                        model.seekStep(-1, base: settings.videoSeekStep, isRepeat: true)
                    }
                    VideoControlButton(icon: "goforward",
                                       help: isEpisodeTransport
                                           ? "前进 \(Int(settings.videoSeekStep)) 秒 (→ / L)，按住快进"
                                           : "前进 \(Int(settings.videoSeekStep)) 秒 (↑ / L)，按住快进",
                                       repeatsWhileHeld: true) {
                        model.seekStep(1, base: settings.videoSeekStep, isRepeat: true)
                    }
                    VideoControlButton(icon: "forward.end",
                                       help: isEpisodeTransport ? "下一条 (↓)" : "下一个 (→)") {
                        if isEpisodeTransport {
                            store.viewerStepVideo(1)
                        } else {
                            store.viewerStep(1)
                        }
                    }
                    .disabled(!hasNextVideo)

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 5)

                    VideoControlButton(icon: volumeIcon,
                                       help: model.isMuted ? "取消静音 (M)" : "静音 (M)") {
                        if model.volume == 0 {
                            model.volume = 1
                            model.isMuted = false
                        } else {
                            model.isMuted.toggle()
                        }
                    }
                    Slider(value: $model.volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 46)
                        .tint(.white)
                        .help("音量")

                    Spacer(minLength: 6)

                    speedMenu

                    VideoControlButton(icon: "info.circle", active: showPlaybackInfo,
                                       help: "播放信息 (I)") {
                        showPlaybackInfo.toggle()
                    }

                    VideoMediaMenuButtons(ui: ui, model: model)

                    VideoControlButton(icon: "repeat", active: model.isLooping,
                                       help: model.isLooping ? "关闭循环播放" : "循环播放") {
                        model.isLooping.toggle()
                    }
                    VideoControlButton(icon: "aspectratio",
                                       active: settings.videoFramingMode == .fill,
                                       help: settings.videoFramingMode == .fill
                                           ? "适应画面 (A)" : "填充画面 (A)") {
                        toggleGravity()
                    }
                    VideoControlButton(icon: "rotate.right", active: quarterTurns != 0, help: "旋转 90° (R)") {
                        rotatePlayer()
                    }
                    if settings.videoPiPEnabled {
                        VideoControlButton(icon: "pip", active: model.isPipActive, help: "画中画") {
                            model.togglePip()
                        }
                        .disabled(!model.isPipAvailable)
                    }
                    VideoControlButton(icon: "camera", help: "保存当前帧") {
                        onCaptureFrame()
                    }
                    VideoControlButton(icon: "arrow.up.left.and.arrow.down.right", help: "全屏 (F)") {
                        toggleFullScreen()
                    }
                }
                .foregroundStyle(.white)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.22))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: VideoControlPanelSizeKey.self,
                                           value: geometry.size)
                }
            }
            .onPreferenceChange(VideoControlPanelSizeKey.self) { size in
                controlPanelSize = size
                reclampControlOffset(stage: stage)
            }
            .onChange(of: stage) { _, _ in
                reclampControlOffset(stage: stage)
            }
            .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
            .padding(.horizontal, 24)
            .padding(.bottom, controlPanelBottomInset)
            .offset(x: controlOffsetX, y: controlOffsetY)
            .gesture(panelDragGesture(stage: stage))
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .scaleEffect(controlsVisible ? 1 : 0.985, anchor: .bottom)
            .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        }
    }

    private func toggleGravity() {
        // A 键/按钮仍是「适应 ↔ 填充」的快捷切换；拉伸、原始像素与比例预设在画面菜单里。
        settings.videoFramingMode = settings.videoFramingMode == .fill ? .fit : .fill
    }

    private func rotatePlayer() {
        withAnimation(.easeInOut(duration: 0.22)) {
            quarterTurns = (quarterTurns + 1) % 4
        }
    }

    /// 显示层布局：比例预设决定裁剪框，显示方式决定框内画面尺寸，平移只在画面超出裁剪框时生效。
    private func framingLayout(in stage: CGSize) -> VideoFramingLayout {
        let natural = videoSize.width > 0 && videoSize.height > 0 ? videoSize : stage
        return VideoFramingGeometry.layout(stage: stage,
                                           naturalSize: natural,
                                           quarterTurns: quarterTurns,
                                           mode: settings.videoFramingMode,
                                           preset: settings.videoAspectPreset,
                                           pan: CGSize(width: settings.videoPanX,
                                                       height: settings.videoPanY))
    }

    private func refreshVideoNeighbors() {
        // 图库视频的 ← / → 与照片翻页一致：前后总有可跳转的项目（首尾循环）。
        if isEpisodeTransport {
            hasPrevVideo = store.hasAdjacentVideo(from: photo.id, delta: -1)
            hasNextVideo = store.hasAdjacentVideo(from: photo.id, delta: 1)
        } else {
            hasPrevVideo = true
            hasNextVideo = true
        }
    }

    private func resetControlPanel() {
        withAnimation(.easeOut(duration: 0.2)) {
            controlOffsetX = 0
            controlOffsetY = 0
        }
    }

    private func panelDragGesture(stage: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = CGSize(width: controlOffsetX, height: controlOffsetY)
                }
                guard let start = dragStartOffset else { return }
                let proposed = CGSize(width: start.width + value.translation.width,
                                      height: start.height + value.translation.height)
                let clamped = clampControlOffset(proposed, stage: stage)
                controlOffsetX = clamped.width
                controlOffsetY = clamped.height
            }
            .onEnded { _ in dragStartOffset = nil }
    }

    /// 控制条可拖到画面内任意位置，但不会移出视频区域。
    private func clampControlOffset(_ proposed: CGSize, stage: CGSize) -> CGSize {
        guard stage.width > 0, stage.height > 0, controlPanelSize.width > 0 else {
            return proposed
        }
        let maxX = max(0, (stage.width - controlPanelSize.width) / 2 - 10)
        let maxUp = max(0, stage.height - controlPanelBottomInset - controlPanelSize.height - 10)
        let dx = min(maxX, max(-maxX, proposed.width))
        let dy = min(controlPanelMaxDownOffset, max(-maxUp, proposed.height))
        return CGSize(width: dx, height: dy)
    }

    /// 窗口尺寸或控制条尺寸变化后，把已保存的偏移重新夹回可见范围。
    private func reclampControlOffset(stage: CGSize) {
        let clamped = clampControlOffset(CGSize(width: controlOffsetX, height: controlOffsetY),
                                         stage: stage)
        if clamped.width != CGFloat(controlOffsetX) || clamped.height != CGFloat(controlOffsetY) {
            controlOffsetX = clamped.width
            controlOffsetY = clamped.height
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                Button {
                    model.setSpeed(value)
                } label: {
                    if model.speed == value {
                        Label(speedLabel(value), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(value))
                    }
                }
            }
            Divider()
            Menu("音频延迟 \(audioDelayLabel)") {
                Button("音频延后 0.1 秒") { adjustAudioDelay(0.1) }
                Button("音频提前 0.1 秒") { adjustAudioDelay(-0.1) }
                Button("音频延后 0.5 秒") { adjustAudioDelay(0.5) }
                Button("音频提前 0.5 秒") { adjustAudioDelay(-0.5) }
                Button("重置音频延迟") { applyAudioDelay(0) }
            }
        } label: {
            Text(speedLabel(model.speed))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 26)
                .background(Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度与音频延迟")
    }

    private var audioDelayLabel: String {
        let milliseconds = Int((playbackSession.audioDelay * 1000).rounded())
        return milliseconds == 0 ? "0 ms" : String(format: "%+d ms", milliseconds)
    }

    private func adjustAudioDelay(_ delta: Double) {
        let value = ((playbackSession.audioDelay + delta) * 10).rounded() / 10
        applyAudioDelay(min(2, max(-2, value)))
    }

    /// 音频延迟靠 ffmpeg 滤镜实现：改动后按当前位置重建一次流。
    private func applyAudioDelay(_ value: Double) {
        playbackSession.audioDelay = value
        guard playbackSession.streamSession != nil else {
            store.showToast("音频延迟 \(audioDelayLabel)，下次起流生效")
            return
        }
        store.showToast("音频延迟 \(audioDelayLabel)")
        restartStreaming(at: model.currentTime)
    }

    private func speedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }

    // MARK: - 跳转与流重建

    /// 云盘边下边播的已生成区间随 ffmpeg 进度增长，拖到未生成位置时用 -ss 重新起流。
    private func seekPlayback(to target: Double) {
        model.requestSeek(to: target)
    }

    /// 拖动进度条时的预览落帧：越界范围由 model.scrubGuard 统一拦截。
    private func scrubPlayback(to target: Double) {
        model.scrub(to: target)
    }

    /// 播放中切换 HDR 色调映射：按新策略在当前时间点重建一次流。
    /// 重建后 streamMode 由新会话接管，之后所有跳转 / 拖动 / 回退都沿用同一模式，
    /// 不会出现「看了一半映射画面、下一跳又回到未映射」。
    private func setHDRToneMapping(_ enabled: Bool) {
        guard hdrToneMapOverride != enabled else { return }
        hdrToneMapOverride = enabled
        refreshHDRToneMapState()
        guard sourceURL != nil, hasLoadedVideo else { return }
        let target = model.currentTime
        let wasPlaying = model.wantsPlayback
        let generation = loadGeneration
        let audioIndex = playbackSession.streamAudioIndex
        store.showToast(enabled ? "已开启 HDR 色调映射（本次播放）" : "已关闭 HDR 色调映射（本次播放）")
        playbackSession.stop()
        hasLoadedVideo = false
        isPreparing = true
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: wasPlaying,
                                               offset: max(0, target - 1),
                                               resumeAt: target > 1 ? target : nil,
                                               mode: enabled ? .transcode : .remux,
                                               audioIndex: audioIndex)
            if !started, generation == loadGeneration {
                // 关掉映射后系统仍解不了（极少见）：退回原位置与播放状态。
                model.seek(to: target)
                if wasPlaying { model.play() }
            }
            isPreparing = false
        }
    }

    /// 蓝光多角度：按新视角在当前时间点重建流。
    /// `-angle` 只作用于 bluray 输入；重建后后续跳转 / 拖动沿用同一视角。
    private func setAngle(_ angle: Int) {
        let target = min(max(1, angle), max(1, angleCount))
        guard target != selectedAngle else { return }
        selectedAngle = target
        ui.updateAngles(count: angleCount, selected: target)
        guard sourceURL != nil, hasLoadedVideo else { return }
        let position = model.currentTime
        let wasPlaying = model.wantsPlayback
        let generation = loadGeneration
        let mode: VideoStreamSession.Mode = playbackSession.streamSession != nil
            ? playbackSession.streamMode
            : (needsToneMapping(playbackProbe) ? .transcode : .remux)
        store.showToast("角度 \(target)/\(angleCount)")
        playbackSession.stop()
        hasLoadedVideo = false
        isPreparing = true
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: wasPlaying,
                                               offset: max(0, position - 1),
                                               resumeAt: position > 1 ? position : nil,
                                               mode: mode,
                                               audioIndex: playbackSession.streamAudioIndex)
            if !started, generation == loadGeneration {
                model.seek(to: position)
                if wasPlaying { model.play() }
            }
            isPreparing = false
        }
    }

    private func switchAudio(to index: Int) {
        guard playbackSession.streamSession != nil,
              index != playbackSession.streamAudioIndex else { return }
        let target = model.currentTime
        playbackSession.previewAudioIndex(index)
        refreshAudioChoices()
        restartStreaming(at: target)
    }

    /// 把 HLS 音轨或原生 AV 音轨统一映射成菜单里的选项。
    private func refreshAudioChoices() {
        // 多音轨会话：AVPlayer 给的选项顺序就是 master 里的音轨顺序，可直接换轨。
        // 菜单标题优先用探测到的语言 / 声道 / 编码；AVPlayer 对 HLS 音轨常只给出
        // "Unknown" 或 audio_N，直接展示会分不清哪条是国语、哪条是英语。
        if playbackSession.isMultiAudio, !model.audioOptions.isEmpty {
            let choices = model.audioOptions.enumerated().map { offset, option in
                let title = probeAudioTracks.indices.contains(offset)
                    ? probeAudioTracks[offset].displayName
                    : option.displayName
                return VideoPlaybackUI.AudioChoice(index: offset, title: title)
            }
            ui.updateAudio(choices: choices,
                           selected: preferredAudioPosition(in: probeAudioTracks)
                               ?? model.currentAudioIndex)
            return
        }
        if streamSession != nil {
            if !probeAudioTracks.isEmpty {
                ui.updateAudio(choices: probeAudioTracks.map {
                    VideoPlaybackUI.AudioChoice(index: $0.ordinal, title: $0.displayName)
                }, selected: preferredAudioPosition(in: probeAudioTracks)
                    .map { probeAudioTracks[$0].ordinal } ?? streamAudioIndex)
            } else {
                let count = max(0, probeAudioCount)
                ui.updateAudio(choices: (0..<count).map {
                    VideoPlaybackUI.AudioChoice(index: $0, title: "音轨 \($0 + 1)")
                }, selected: streamAudioIndex)
            }
        } else {
            let choices = model.audioOptions.enumerated().map {
                VideoPlaybackUI.AudioChoice(index: $0.offset, title: $0.element.displayName)
            }
            let selected = model.selectedAudio.flatMap { model.audioOptions.firstIndex(of: $0) } ?? 0
            ui.updateAudio(choices: choices, selected: selected)
        }
    }

    /// 默认音轨偏好：按语言 / 标题挑一条，命不中时回落到原逻辑。
    private func preferredAudioPosition(in tracks: [AudioTrackInfo]) -> Int? {
        let preference = settings.videoPreferredAudio
        guard preference != "original", !tracks.isEmpty else { return nil }
        let wanted = preference == "zh"
            ? ["zh", "chi", "cmn", "cn", "yue"]
            : ["en", "eng"]
        return tracks.firstIndex { track in
            let code = (track.language ?? "").lowercased()
            if wanted.contains(where: { code.hasPrefix($0) }) { return true }
            let title = (track.title ?? "").lowercased()
            return preference == "zh"
                ? (title.contains("国") || title.contains("中") || title.contains("粤"))
                : (title.contains("english") || title.contains("英语"))
        }
    }

    private func restartStreaming(at target: Double) {
        // 重建流期间又拖到了别处：只记最后一个目标，当前会话就绪后再追过去。
        // 连续拖动不能排队拉起多个 ffmpeg，也不能拿旧会话的时间轴去 seek。
        if playbackSession.isRestartingStream {
            playbackSession.queueRestart(target)
            return
        }
        guard playbackSession.streamSession != nil else {
            model.seek(to: target)
            return
        }
        isPreparing = true
        // 旧流先停住音画：新位置的分片要一会儿才好，继续播旧位置只会让人以为没跳过去。
        let wasPlaying = model.isPlaying
        model.pause()
        let generation = loadGeneration
        let mode = playbackSession.streamMode
        let audio = playbackSession.streamAudioIndex
        let seekStartedAt = Date()
        Task { @MainActor in
            let outcome = await playbackSession.restart(at: target) { next in
                // 云盘直链可能已过期：跳转前重新解析一次，避免重建流仍用旧地址。
                if photo.isCloud, let refreshed = try? await store.cloudStreamOrThrow(for: photo) {
                    sourceURL = refreshed.url
                    sourceHeaders = refreshed.headers
                }
                return makeStreamContext(generation: generation,
                                         offset: max(0, next - 1),
                                         resumeAt: next,
                                         mode: mode,
                                         audioIndex: audio,
                                         // 原来暂停着拖到未生成区间，重建完会自己播起来；
                                         // 沿用拖动前的播放意图，暂停就停在目标帧。
                                         autoplay: wasPlaying)
            }
            switch outcome {
            case .started:
                hasLoadedVideo = true
                failureMessage = nil
                canTranscode = false
            case .failed(let message, let canTranscode):
                failureMessage = message
                self.canTranscode = canTranscode
                if wasPlaying, generation == loadGeneration { model.play() }
            case .cancelled, .queued:
                break
            }
            let elapsed = Int(Date().timeIntervalSince(seekStartedAt) * 1000)
            let remote = photo.isCloud ? "网盘" : "本地"
            Diagnostics.record("拖拽起流 \(photo.originalName) \(remote) → \(Int(target))s 用时 \(elapsed)ms")
            isPreparing = false
        }
    }

    /// 云盘直链失效时重新解析；代理的下载线程会阻塞等待结果。
    private func cloudRefreshClosure() -> (() -> (URL, [String: String])?)? {
        guard photo.isCloud else { return nil }
        return {
            // 在主线程阻塞等待会死锁（解析本身要回主线程）。
            guard !Thread.isMainThread else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var result: (URL, [String: String])?
            Task { @MainActor in
                if let stream = try? await store.cloudStreamOrThrow(for: photo) {
                    result = (stream.url, stream.headers)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
            return result
        }
    }

    /// 系统播放器拒绝码流（-12927 / -11828）时自动重编码一次：
    /// 沿用当前播放位置与音轨，避免用户停在错误页手动点「转换为兼容格式」。
    private func autoFallbackToTranscode(after failure: PlaybackFailure) {
        let generation = loadGeneration
        let target = model.currentTime
        let audioIndex = playbackSession.streamAudioIndex
        Diagnostics.record("自动兼容转码 \(photo.originalName) at \(Int(target))s "
                           + "（\(failure.domain ?? "-") \(failure.code.map(String.init) ?? "-")）")
        isPreparing = true
        failureMessage = nil
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: true,
                                               offset: max(0, target - 1),
                                               resumeAt: target > 1 ? target : nil,
                                               mode: .transcode,
                                               audioIndex: audioIndex)
            guard generation == loadGeneration else { return }
            if !started, failureMessage == nil {
                failureMessage = "该视频的编码不受系统播放器支持，兼容转换也未能启动。"
                canTranscode = true
                isPreparing = false
            }
        }
    }

    /// 直连播放被网盘限速时的兜底：改用本地转封装，从当前位置接着播。
    /// 网盘直链只有一条 HTTP 连接，CDN 限速后缓冲只出不进；转封装走本地 Range 代理，
    /// 会按档位并发预取多个分块（流畅档 8 路 × 16MB），吞吐通常是单连接的数倍。
    private func switchToStreamingForSlowSource(at target: Double) {
        guard photo.isCloud, let url = sourceURL,
              url.pathExtension.lowercased() != "m3u8",
              !playbackSession.isRestartingStream, !isPreparing else { return }
        Diagnostics.record("直连限速切转封装：\(photo.originalName) → \(Int(target))s")
        let generation = loadGeneration
        let audioIndex = playbackSession.streamAudioIndex
        isPreparing = true
        Task { @MainActor in
            let started = await startStreaming(generation: generation,
                                               autoplay: true,
                                               offset: max(0, target - 1),
                                               resumeAt: target,
                                               mode: .remux,
                                               audioIndex: audioIndex)
            guard generation == loadGeneration else { return }
            if !started, failureMessage == nil {
                failureMessage = "网盘直连太慢，转封装也未能启动。"
                isPreparing = false
            }
        }
    }

    /// 启动转封装会话；编码不兼容时自动降级为重编码 H.264。
    /// 起流：`offset` 是 ffmpeg 的读取位置（会再对齐到关键帧），
    /// `resumeAt` 是播放器最终要落到的绝对秒数（装片后先定位再开播）。
    private func startStreaming(generation: Int, autoplay: Bool, offset: Double,
                                resumeAt: Double? = nil,
                                mode initialMode: VideoStreamSession.Mode,
                                audioIndex: Int,
                                isLive: Bool = false) async -> Bool {
        guard let context = makeStreamContext(generation: generation,
                                              offset: offset,
                                              resumeAt: resumeAt,
                                              mode: initialMode,
                                              audioIndex: audioIndex,
                                              autoplay: autoplay,
                                              isLive: isLive) else { return false }
        let outcome = await playbackSession.start(context)
        switch outcome {
        case .started:
            hasLoadedVideo = true
            failureMessage = nil
            isPreparing = false
            canTranscode = false
            refreshAudioChoices()
            return true
        case .cancelled, .queued:
            return false
        case .failed(let message, let canTranscode):
            failureMessage = message
            self.canTranscode = canTranscode
            isPreparing = false
            return false
        }
    }

    /// 把播放页掌握的片源 / 探测 / 设置打包给内核；起流与降级逻辑不再留在 View 里。
    private func makeStreamContext(generation: Int,
                                   offset: Double,
                                   resumeAt: Double?,
                                   mode: VideoStreamSession.Mode,
                                   audioIndex: Int,
                                   autoplay: Bool,
                                   isLive: Bool = false) -> PlaybackStreamContext? {
        guard let sourceURL else { return nil }
        let token = generation
        return PlaybackStreamContext(
            photoID: photo.id,
            title: photo.originalName,
            sourceURL: sourceURL,
            headers: sourceHeaders,
            trustSelfSigned: store.cloudMount(for: photo.cloudMountID)?.trustSelfSigned ?? false,
            isHEVC: probeIsHEVC,
            isHDR: probeIsHDR,
            color: probeColor,
            duration: probeDuration,
            size: videoSize,
            frameRate: playbackProbe.frameRate,
            isInterlaced: playbackProbe.isInterlaced,
            angle: selectedAngle,
            audioTracks: probeAudioTracks,
            audioIndex: audioIndex,
            audioDownmix: settings.audioDownmix,
            transcodeMode: settings.videoTranscodeMode,
            // HDR 屏 + 自动策略：重编码时保留 HDR，跳过色调映射（映射链 4K60 只有 <1× 实时）。
            preserveHDR: displaySupportsHDR && effectiveHDRMode != .toneMapSDR,
            burnSubtitle: ui.burnSubtitleURL,
            burnSubtitleStream: ui.burnSubtitleStream,
            cacheSignature: VideoStreamSession.lumaCacheSignature,
            refreshSource: cloudRefreshClosure(),
            autoplay: autoplay,
            loop: settings.loopVideoByDefault,
            muted: settings.muteVideoByDefault,
            offset: offset,
            resumeAt: resumeAt,
            preferredMode: mode,
            isLive: isLive,
            generation: token,
            isCurrent: { token == loadGeneration })
    }

    /// 失败卡片：电视频道用「逐条线路原因 + 可操作按钮」，其他片源沿用原卡片。
    @ViewBuilder
    private func failureView(_ message: String) -> some View {
        if let channel = store.tvPlaybackChannel(for: photo.id) {
            tvFailureCard(channel: channel, fallbackMessage: message)
        } else {
            defaultFailureView(message)
        }
    }

    /// 概念「状态 C · 失败与换线」：全部线路失败后升级为居中卡片。
    private func tvFailureCard(channel: TVChannel, fallbackMessage: String) -> some View {
        let summary = store.tvLineFailureSummary(for: photo.id)
        let total = store.tvLineCount(for: photo.id)
        let reasonText = summary.isEmpty
            ? fallbackMessage
            : "\(total) 条线路都失败了：\(summary)。"
        return VStack(spacing: 12) {
            Text("这个频道暂时看不了")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.white)
            Text(reasonText)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                tvFailureButton("重试", prominent: true) {
                    failureMessage = nil
                    Task { await load(generation: loadGeneration) }
                }
                tvFailureButton("换一条线路", prominent: false) {
                    _ = store.switchTVLine(for: photo.id, delta: 1)
                }
                .disabled(total < 2)
                tvFailureButton("打开信号页", prominent: false) {
                    store.closeViewer()
                    store.tvModel.setHubTab(.status)
                }
                tvFailureButton("复制流地址", prominent: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(channel.streamURL, forType: .string)
                    store.showToast("已复制流地址")
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                }
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .padding(24)
    }

    private func tvFailureButton(_ title: String,
                                 prominent: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.white.opacity(0.86))
                .padding(.horizontal, 12)
                .padding(.vertical, 5.5)
                .background(prominent ? TVBrand.wave : Color.white.opacity(0.12),
                            in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func defaultFailureView(_ message: String) -> some View {
        let httpStatus = model.playbackFailure?.httpStatus
        return VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.75))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if photo.isCloud,
               store.cloudMount(for: photo.cloudMountID)?.kind == .pan115,
               message.contains("403") {
                Text("115 可能触发了风控验证或直链已失效：请先在 115 网页端打开该视频完成验证，再回到拾光重试；仍失败时可在「编辑接入范围」里重新保存一次 Cookie。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 10) {
                // HTTP 4xx / 5xx 是线路本身拒绝，转码解决不了，不展示这个入口。
                if canTranscode, (httpStatus ?? 0) < 400 {
                    Button {
                        transcodeAndPlay()
                    } label: {
                        HStack(spacing: 6) {
                            if isTranscoding {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(isTranscoding ? "正在转换…" : "转换为兼容格式并播放")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTranscoding)
                }
                if sourceURL != nil, !photo.isCloud {
                    Button("用其他播放器打开") {
                        if let sourceURL {
                            NSWorkspace.shared.open(sourceURL)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                }
                if photo.isCloud, let mountID = photo.cloudMountID {
                    Button("打开网盘连接") {
                        store.closeViewer()
                        store.navigate(to: .cloudMount(mountID))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                    .help("在网盘连接页检查授权状态或重新登录")
                }
                // 站点直链解析失败（如 CDN 拒绝请求）时，退回原站详情页播放。
                if isCatalogPlayback,
                   let context = store.catalogPlaybackContext(for: photo.id),
                   let pageURL = URL(string: context.episode.pageURL) {
                    Button("在浏览器中播放") {
                        NSWorkspace.shared.open(pageURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                    .help("在默认浏览器打开该条目的原始播放页")
                }
                Button("重试") {
                    Task { await load(generation: loadGeneration) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.16), in: Capsule())
            }
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .padding(24)
    }

    // MARK: 载入

    private func load(generation: Int) async {
        FullScreenDiagnostics.log("video load start \(photo.originalName) generation=\(generation)")
        // 不在这里恢复刷新率：连播同一帧率的剧集时，先恢复再匹配会让屏幕黑闪两次。
        // 新片的匹配在首帧出来后由 applyDisplayRate 负责，退出播放时 onDisappear 统一恢复。
        isPreparing = true
        cachedSourcePending = false
        failureMessage = nil
        streamFailure = nil
        canTranscode = false
        isTranscoding = false
        didAutoTranscodeFallback = false
        assetOptions = [:]
        sourceHeaders = [:]
        hasLoadedVideo = false
        cloudResourceLoader?.invalidate()
        cloudResourceLoader = nil
        playbackSession.stop()
        playbackSession.beginItem(photo.id, hooks: store)
        // 当前查看器仍以点播为主；电视直播接入后按 PlaybackTarget 设置 .live。
        playbackSession.playbackMode = .vod

        let autoplay = settings.autoPlayVideo
        // 续播 / 片头由内核钩子统一提供（影院进度、目录起播秒数）。
        let resumeOffset = playbackSession.resumePosition

        // 上一集快看完时预热好的下一集：首段已生成，直接接管，省掉解析直链与探测。
        if !ui.isBurningSubtitle,
           let warm = store.takePrewarmedCinemaStream(for: photo.id) {
            sourceURL = warm.sourceURL
            sourceHeaders = warm.headers
            assetOptions = [CloudPlayback.headerFieldsKey: warm.headers]
            playbackSession.adopt(warm.session)
            var probe = VideoProbe()
            probe.hasVideoTrack = true
            probe.isPlayable = true
            probe.duration = max(photo.duration ?? 0, warm.duration)
            if warm.videoSize.width > 0, warm.videoSize.height > 0 {
                probe.size = warm.videoSize
            } else if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            // 预热时已探测过：接管后不再重探，音轨菜单也能直接显示语言 / 声道。
            probe.audioTracks = warm.audioTracks
            probe.audioTrackCount = warm.audioTracks.count
            videoSize = probe.size
            probeDuration = probe.duration
            probeIsHEVC = warm.isHEVC
            probeIsHDR = false
            probeColor = VideoColorInfo()
            probeAudioCount = warm.audioTracks.count
            probeAudioTracks = warm.audioTracks
            applyPlaybackProbe(probe)
            model.load(url: warm.playlistURL, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                       startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                       playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
            hasLoadedVideo = true
            isPreparing = false
            failureMessage = nil
            canTranscode = false
            // 预热时生成被暂停过：真正开播后必须恢复，否则不会再有新分片。
            playbackSession.setGenerationActive(true)
            refreshAudioChoices()
            ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            return
        }

        // 已有完整 HLS 缓存：不解析直链、不探测远端，直接用缓存起播。
        // 只对云端 / 网络资源生效：本地文件本来就不落缓存。
        if !ui.isBurningSubtitle,
           photo.isCloud || store.catalogPlaybackContext(for: photo.id) != nil,
           VideoStreamSession.hasCompleteCache(environment: .luma,
                                                photoID: photo.id,
                                                cacheSignature: VideoStreamSession.lumaCacheSignature,
                                                requiresSDR: cacheRequiresSDR,
                                                supportsLibplacebo: VideoSupport.supportsLibplacebo),
           await playFromCompleteCache(generation: generation,
                                       autoplay: autoplay,
                                       resumeOffset: resumeOffset) {
            return
        }

        let source = await resolveSource()
        guard generation == loadGeneration, !Task.isCancelled else { return }
        var failedProbe: VideoProbe?

        // 电视直播的非 HLS 源（http-flv / http-ts）：系统播放器不支持，
        // 直接交给 ffmpeg 转封装成滑动窗口 HLS，跳过 AVFoundation 探测与缓存查找。
        if let source, playbackMode == .live, !source.isHLS, FFmpeg.isAvailable {
            sourceURL = source.url
            sourceHeaders = source.headers
            assetOptions = [CloudPlayback.headerFieldsKey: source.headers]
            failureMessage = nil
            isPreparing = true
            playbackSession.playbackMode = .live
            // 直播没有完整时长：进度条不参与，尺寸用列表元数据兜底。
            probeDuration = 0
            if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            if await startStreaming(generation: generation, autoplay: autoplay,
                                    offset: 0, resumeAt: nil, mode: .remux,
                                    audioIndex: 0, isLive: true) {
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            }
            return
        }

        // 百度直链：URL 没有扩展名、AVPlayer 跳转后不会继续带 UA；
        // WebDAV：必须带 Basic 认证头，AVPlayer 直连不会发送；
        // 两者都由资源加载器代取，探测与播放都拿到明确的 Content-Type。
        var playbackAsset: AVAsset?
        var playbackURL = source?.url
        // 官方转码的 HLS 播放列表：AVPlayer 原生支持，不能交给 ffmpeg 按字节读取。
        if let source, source.isHLS {
            sourceURL = source.url
            sourceHeaders = source.headers
            assetOptions = [CloudPlayback.headerFieldsKey: source.headers]
            var probe = VideoProbe()
            probe.hasVideoTrack = true
            probe.isPlayable = true
            probe.duration = photo.duration ?? 0
            if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
            videoSize = probe.size
            model.load(url: source.url, options: assetOptions, probe: probe, autoplay: autoplay,
                       loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                       startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                       playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
            hasLoadedVideo = true
            isPreparing = false
            probeDuration = probe.duration
            probeIsHEVC = false
            probeIsHDR = false
            probeColor = VideoColorInfo()
            probeAudioCount = 0
            probeAudioTracks = []
            applyPlaybackProbe(probe)
            ui.loadSiblingIfAvailable(sourceURL: sourceURL)
            return
        }
        if let source {
            sourceURL = source.url
            sourceHeaders = source.headers
            assetOptions = [CloudPlayback.headerFieldsKey: source.headers]
            let mount = photo.isCloud ? store.cloudMount(for: photo.cloudMountID) : nil
            let needsProxy = mount.map { $0.kind == .baidu || $0.kind == .webdav } ?? false
            if needsProxy,
               let made = CloudAssetResourceLoader.makeAsset(
                   upstreamURL: source.url,
                   headers: source.headers,
                   trustSelfSigned: mount?.trustSelfSigned ?? false,
                   pathExtension: (photo.originalName as NSString).pathExtension) {
                cloudResourceLoader = made.loader
                playbackAsset = made.asset
                playbackURL = made.asset.url
            }
        }

        // 原图路径存在才探测：iCloud / 共享相簿项目在 Photos.sqlite 里有路径，本机却没有文件。
        let canUseLocal = playbackURL.map { photo.isCloud || FileManager.default.fileExists(atPath: $0.path) } ?? false
        // 烧录字幕必须经过 ffmpeg 重编码，跳过系统原生直接播放。
        if let playbackURL, canUseLocal, !ui.isBurningSubtitle {
            // 复用同一份 AVAsset 做探测与播放：SMB / 外置盘少开一次文件，轨道信息也直接复用。
            let asset = playbackAsset ?? AVURLAsset(url: playbackURL, options: assetOptions)
            // 资源加载器代取的地址 ffprobe 读不了，只有普通地址才做 ffprobe 兜底。
            let probe = await VideoSupport.probe(asset: asset,
                                                 fallbackURL: playbackAsset == nil ? playbackURL : nil,
                                                 options: assetOptions)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // AVPlayer 没有去隔行开关：隔行源跳过原生直连，交给 ffmpeg 重编码 + bwdif。
            // 4K 50/60fps HEVC 直连会黑屏有声音，同样跳过（统一走重编码）。
            if probe.hasVideoTrack, probe.isPlayable, !probe.isInterlaced,
               !Self.requiresRecodeForHighFrameRate4K(probe),
               !needsToneMapping(probe) {
                videoSize = probe.size
                model.load(asset: asset, probe: probe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                           playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = probe.duration
                probeIsHEVC = probe.isHEVC
                probeIsHDR = probe.isHDR
                probeColor = probe.color
                probeAudioCount = probe.audioTrackCount
                probeAudioTracks = probe.audioTracks
                applyPlaybackProbe(probe)
                applyDisplayRate(probe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                notifyIfDolbyVisionUnsupported(probe)
                return
            }
            failedProbe = probe
            // HDR / 杜比视界片源按设置先做色调映射：跳过系统原生直解，交给 ffmpeg 转码。
            if probe.hasVideoTrack, probe.isPlayable {
                Diagnostics.record("HDR 片源改走色调映射：\(photo.originalName) "
                                   + "dv=\(probe.isDolbyVision) "
                                   + "profile=\(probe.color.dvProfile.map(String.init) ?? "-") "
                                   + "策略=\(effectiveHDRMode.rawValue) "
                                   + "override=\(hdrToneMapOverride.map { $0 ? "on" : "off" } ?? "nil") "
                                   + displayHDRDiagnostics)
            } else if photo.isCloud {
                Diagnostics.record("云端视频探测失败 \(photo.originalName)：track=\(probe.hasVideoTrack) "
                                   + "playable=\(probe.isPlayable) codec=\(probe.codec ?? "-") "
                                   + "host=\(playbackURL.host ?? "-")")
            }
        } else if !photo.isSystem {
            if let streamFailure, photo.isCloud {
                failureMessage = "无法获取网盘播放地址：\(streamFailure)"
            } else if let streamFailure {
                failureMessage = "无法定位视频文件：\(streamFailure)"
            } else {
                failureMessage = "无法定位视频文件"
            }
            isPreparing = false
            return
        }
        // 翻页后旧任务可能刚从 await 恢复：不再往播放器里装上一个视频。
        guard generation == loadGeneration, !Task.isCancelled else { return }

        if !ui.isBurningSubtitle,
           let cached = cachedTranscodeURL(), FileManager.default.fileExists(atPath: cached.path) {
            let cachedProbe = await VideoSupport.probe(url: cached)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if cachedProbe.hasVideoTrack, cachedProbe.isPlayable {
                sourceURL = cached
                videoSize = cachedProbe.size
                model.load(url: cached, probe: cachedProbe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                           playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = cachedProbe.duration
                probeIsHEVC = cachedProbe.isHEVC
                probeIsHDR = cachedProbe.isHDR
                probeColor = cachedProbe.color
                probeAudioCount = cachedProbe.audioTrackCount
                probeAudioTracks = cachedProbe.audioTracks
                applyPlaybackProbe(cachedProbe)
                applyDisplayRate(cachedProbe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                return
            }
        }

        // 系统「照片」图库：本机没有原图时交给 PhotoKit，
        // 共享相簿与仅存 iCloud 的视频会由 Photos 自己下载后再交给播放器。
        if photo.isSystem {
            guard let resolved = await PhotoKitBridge.videoAsset(id: photo.id) else {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                failureMessage = "无法从系统「照片」图库读取该视频，可能仍在 iCloud 或共享相簿中下载。"
                isPreparing = false
                return
            }
            let probe = await VideoSupport.probe(asset: resolved.asset)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if probe.hasVideoTrack, probe.isPlayable {
                sourceURL = resolved.url
                videoSize = probe.size
                model.load(asset: resolved.asset, probe: probe, autoplay: autoplay,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           startAt: resumeOffset, forwardBufferDuration: startupForwardBuffer)
                           playbackSession.markResumeApplied(playbackSession.resumeIsProgress && (resumeOffset ?? 0) > 3)
                hasLoadedVideo = true
                isPreparing = false
                probeDuration = probe.duration
                probeIsHEVC = probe.isHEVC
                probeIsHDR = probe.isHDR
                probeColor = probe.color
                probeAudioCount = probe.audioTrackCount
                probeAudioTracks = probe.audioTracks
                applyPlaybackProbe(probe)
                applyDisplayRate(probe.frameRate)
                refreshAudioChoices()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                return
            }
            failedProbe = probe
        }

        // 系统不支持的容器（MKV / AVI…）：ffmpeg 边下载边封装成 fMP4 HLS，
        // 第一段分片就绪即可播放，不必等整部文件下载 / 转换完。
        let formatName = Self.formatDescription(name: photo.originalName, codec: failedProbe?.codec)
        if let failedProbe {
            probeDuration = failedProbe.duration > 0 ? failedProbe.duration : (photo.duration ?? 0)
            // MKV 这类容器 AVFoundation 探测不到编码，用网盘列表里的元数据补齐，
            // 否则 HEVC 转封装不会写 hvc1 标签，AVPlayer 会直接拒绝播放。
            probeIsHEVC = failedProbe.isHEVC || photo.videoCodec?.lowercased() == "hevc"
            probeIsHDR = failedProbe.isHDR
            probeColor = failedProbe.color
            notifyIfDolbyVisionUnsupported(failedProbe)
            probeAudioCount = failedProbe.audioTrackCount
            probeAudioTracks = failedProbe.audioTracks
            applyPlaybackProbe(failedProbe)
            if failedProbe.size.width > 0, failedProbe.size.height > 0 {
                videoSize = failedProbe.size
            } else if photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
        }
        // 烧录字幕跳过了系统原生探测：用列表元数据补齐时长 / 尺寸，转码流才有正确的进度条。
        if ui.isBurningSubtitle {
            if probeDuration <= 0 { probeDuration = photo.duration ?? 0 }
            if videoSize == .zero, photo.pixelWidth > 0, photo.pixelHeight > 0 {
                videoSize = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
            }
        }
        if sourceURL != nil, FFmpeg.isAvailable {
            // 不弹「正在准备」告警卡片：直接进入播放界面转圈，首段就绪后自动开播。
            failureMessage = nil
            isPreparing = true
            // 续播直接从目标位置起流，省掉「先播片头再重建流」的一跳。
            let startOffset = resumeOffset ?? 0
            // HDR / 杜比视界按设置色调映射；隔行源必须重编码去隔行；其余走无损转封装。
            // 视频轨被系统判定不可解码时也只能重编码：只换容器救不回来，直连更是黑屏有声音。
            let streamProbe = failedProbe ?? playbackProbe
            if !streamProbe.isVideoDecodable, streamProbe.hasVideoTrack {
                Diagnostics.record("视频轨系统无法解码，改走重编码：\(photo.originalName) "
                                   + "codec=\(streamProbe.codec ?? "-") "
                                   + "\(Int(streamProbe.size.width))x\(Int(streamProbe.size.height)) "
                                   + "fps=\(Int(streamProbe.frameRate))")
            }
            let highFrameRate4K = Self.requiresRecodeForHighFrameRate4K(streamProbe)
            if highFrameRate4K {
                Diagnostics.record("4K 高帧率 HEVC 直接重编码：\(photo.originalName) "
                                   + "codec=\(streamProbe.codec ?? "-") "
                                   + "\(Int(streamProbe.size.width))x\(Int(streamProbe.size.height)) "
                                   + "fps=\(Int(streamProbe.frameRate))")
            }
            let streamMode: VideoStreamSession.Mode =
                (needsToneMapping(streamProbe) || streamProbe.isInterlaced
                 || !streamProbe.isVideoDecodable || highFrameRate4K) ? .transcode : .remux
            if await startStreaming(generation: generation, autoplay: autoplay,
                                    offset: startOffset,
                                    resumeAt: startOffset > 0 ? startOffset : nil,
                                    mode: streamMode, audioIndex: 0) {
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                return
            }
            return
        }

        isPreparing = false
        if photo.isCloud {
            failureMessage = "该云端视频（\(formatName)）系统无法直接播放。"
                + "安装 ffmpeg（brew install ffmpeg）后可转换为兼容格式。"
        } else {
            failureMessage = "系统无法解码该视频（\(formatName)）。安装 ffmpeg 后可自动转换为兼容格式。"
        }
    }

    /// 完整缓存命中：用片源元数据直接起本地 HLS，远端直链放到后台补。
    /// 缓存里已经是完整时间轴，续播也直接从缓存起播，不再等 ffmpeg 从中间重建。
    private func playFromCompleteCache(generation: Int,
                                       autoplay: Bool,
                                       resumeOffset: Double?) async -> Bool {
        sourceURL = cachedPlaybackSource()
        sourceHeaders = [:]
        assetOptions = [:]
        var probe = VideoProbe()
        probe.hasVideoTrack = true
        probe.isPlayable = true
        probe.duration = photo.duration ?? 0
        if photo.pixelWidth > 0, photo.pixelHeight > 0 {
            probe.size = CGSize(width: photo.pixelWidth, height: photo.pixelHeight)
        }
        videoSize = probe.size
        probeDuration = probe.duration
        probeIsHEVC = photo.videoCodec?.lowercased() == "hevc"
        // 多音轨 / HDR 缓存无法从远端重新探测：用缓存清单恢复音轨结构与色彩标记。
        let manifest = VideoStreamSession.cachedManifest(
            environment: .luma,
            photoID: photo.id,
            cacheSignature: VideoStreamSession.lumaCacheSignature)
        probeIsHDR = manifest?.isHDR ?? false
        probeColor = VideoColorInfo(isHDR: manifest?.isHDR ?? false,
                                    isDolbyVision: manifest?.isDolbyVision ?? false)
        let cachedTracks = manifest?.audioTracks ?? []
        probe.audioTracks = cachedTracks
        probe.audioTrackCount = cachedTracks.count
        probeAudioCount = cachedTracks.count
        probeAudioTracks = cachedTracks
        applyPlaybackProbe(probe)
        refreshAudioChoices()

        let start = max(0, resumeOffset ?? 0)
        cachedSourcePending = true
        let started = await startStreaming(generation: generation,
                                           autoplay: autoplay,
                                           offset: start,
                                           resumeAt: start > 0 ? start : nil,
                                           mode: .remux,
                                           audioIndex: 0)
        guard started else {
            cachedSourcePending = false
            return false
        }

        // 内嵌字幕 / 未缓存区间的预览帧仍要用原始直链，后台补齐即可，不挡起播。
        Task { @MainActor in
            let resolved = await resolveSource()
            guard generation == loadGeneration else { return }
            cachedSourcePending = false
            guard let resolved else { return }
            sourceURL = resolved.url
            sourceHeaders = resolved.headers
            assetOptions = [CloudPlayback.headerFieldsKey: resolved.headers]
            registerScrubPreviewFallback()
            ui.loadSiblingIfAvailable(sourceURL: resolved.url)
            await loadTechnicalProbe(generation: generation)
        }
        return true
    }

    /// 缓存命中时给起流上下文一个非本地文件地址：缓存目录只按 photoID 命名，
    /// 不需要真实直链；但不能用 file://，否则会被当成「本地源」而不复用缓存。
    private func cachedPlaybackSource() -> URL {
        if let context = store.catalogPlaybackContext(for: photo.id),
           let url = URL(string: context.episode.pageURL) {
            return url
        }
        if let path = photo.cloudPath, let url = URL(string: path) {
            return url
        }
        return URL(string: "luma-cache://cache")!
    }

    /// MKV / AVI 这类容器 AVFoundation 根本不解析，探测拿不到编码，直接说明容器更准确。
    private static func formatDescription(name: String, codec: String?) -> String {
        let unsupported: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "rmvb", "rm",
                                        "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv",
                                        "divx", "mxf", "asf"]
        let ext = (name as NSString).pathExtension.lowercased()
        if unsupported.contains(ext) { return "\(ext.uppercased()) 容器" }
        return codec ?? "未知编码"
    }

    private func resolveSource() async -> (url: URL, headers: [String: String], isHLS: Bool)? {
        do {
            let session = try await store.preparePlaybackSession(for: photo)
            playbackMode = session.mode
            playbackCapabilities = session.capabilities
            return (session.stream.url, session.stream.headers, session.stream.isHLS)
        } catch {
            streamFailure = error.localizedDescription
            return nil
        }
    }

    private func cachedTranscodeURL() -> URL? {
        LibraryPaths.transcodes.appendingPathComponent(photo.id.uuidString + ".mp4", isDirectory: false)
    }

    private func transcodeAndPlay() {
        guard !isTranscoding, let sourceURL else { return }
        isTranscoding = true
        let generation = loadGeneration
        let isCloud = photo.isCloud
        let headers = sourceHeaders
        Task { @MainActor in
            do {
                guard let destination = cachedTranscodeURL() else { return }
                if isCloud {
                    // MKV 等容器连探测都过不了，ffmpeg 直接从远端读取再封装成 MP4。
                    try await VideoSupport.transcodeRemote(
                        source: sourceURL,
                        headers: headers,
                        trustSelfSigned: store.cloudMount(for: photo.cloudMountID)?.trustSelfSigned ?? false,
                        toneMapHDR: probeIsHDR,
                        isDolbyVision: probeColor.isDolbyVision,
                        destination: destination)
                } else {
                    try await VideoSupport.transcode(source: sourceURL, destination: destination,
                                                     toneMapHDR: probeIsHDR,
                                                     isDolbyVision: probeColor.isDolbyVision,
                                                     sourceSize: videoSize,
                                                     frameRate: playbackProbe.frameRate,
                                                     color: probeColor)
                }
                let probe = await VideoSupport.probe(url: destination)
                // 转换期间已经翻到别的照片：不要再把结果塞进播放器。
                guard generation == loadGeneration else { return }
                guard probe.hasVideoTrack, probe.isPlayable else {
                    isTranscoding = false
                    failureMessage = "转换后的文件仍无法播放，请确认 ffmpeg 组件完整。"
                    return
                }
                videoSize = probe.size
                probeDuration = probe.duration
                applyDisplayRate(probe.frameRate)
                model.load(url: destination, probe: probe, autoplay: true,
                           loop: settings.loopVideoByDefault, muted: settings.muteVideoByDefault,
                           forwardBufferDuration: startupForwardBuffer)
                hasLoadedVideo = true
                failureMessage = nil
                canTranscode = false
                isTranscoding = false
                VideoCache.luma.trimIfNeeded()
                ui.loadSiblingIfAvailable(sourceURL: sourceURL)
                store.showToast("已转换为兼容格式并开始播放")
            } catch {
                guard generation == loadGeneration else { return }
                isTranscoding = false
                failureMessage = "转换失败：\(error.localizedDescription)"
            }
        }
    }

    private func toggleFullScreen() {
        // 优先用播放器自己所在的窗口：弹出面板 / 子窗口抢到 key 时也不会切错窗口。
        let target = playerWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        FullScreenDiagnostics.log("toggleFullScreen window=\(String(describing: target)) isFullScreen=\(target?.styleMask.contains(.fullScreen) ?? false)")
        target?.toggleFullScreen(nil)
    }
}

// MARK: - 窗口工具栏里的播放控件

/// 顶栏播放按钮：尺寸大于系统工具栏图标，带悬停浮层与选中强调色。
struct VideoDeckButton: View {
    let icon: String
    var active = false
    var help: String?
    /// 快进 / 快退用：按住不放持续步进，而不是只跳一次。
    var repeatsWhileHeld = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        core
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
            .animation(.snappy(duration: 0.18), value: active)
            .help(help ?? "")
    }

    @ViewBuilder
    private var core: some View {
        if repeatsWhileHeld {
            content.modifier(HoldRepeatGesture(action: action))
        } else {
            Button(action: action) { content }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Color.accentColor
                                    : Color.primary.opacity(hovering ? 1 : 0.82))
            .frame(width: 26, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.16)
                                 : Color.primary.opacity(hovering ? 0.09 : 0.001))
            }
            .contentShape(Rectangle())
    }
}

/// 播放舱里的播放控制组：上一个 / 后退 10 秒 / 播放 / 前进 10 秒 / 下一个。
struct VideoToolbarTransport: View {
    @ObservedObject var model: VideoPlayerModel
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    /// 快进 / 快退步长：与播放器和快捷键共用设置里的值。
    var seekStep: Double = 10
    /// 网络资源剧集：↑ / ↓ 切集，← / → 快进快退；
    /// 图库视频与照片翻页一致：← / → 上一个 / 下一个项目，↑ / ↓ 快进快退。
    var episodeMode: Bool = false

    var body: some View {
        HStack(spacing: 1) {
            VideoDeckButton(icon: "backward.end.fill",
                            help: episodeMode ? "上一集 (↑)" : "上一个 (←)") {
                onPrev()
            }
            .disabled(!hasPrev)

            transportDivider

            VideoDeckButton(icon: "gobackward",
                            help: episodeMode
                                ? "后退 \(Int(seekStep)) 秒 (← / J)，按住快退"
                                : "后退 \(Int(seekStep)) 秒 (↓ / J)，按住快退",
                            repeatsWhileHeld: true) {
                model.seekStep(-1, base: seekStep, isRepeat: true)
            }

            playButton

            VideoDeckButton(icon: "goforward",
                            help: episodeMode
                                ? "前进 \(Int(seekStep)) 秒 (→ / L)，按住快进"
                                : "前进 \(Int(seekStep)) 秒 (↑ / L)，按住快进",
                            repeatsWhileHeld: true) {
                model.seekStep(1, base: seekStep, isRepeat: true)
            }

            transportDivider

            VideoDeckButton(icon: "forward.end.fill",
                            help: episodeMode ? "下一集 (↓)" : "下一个 (→)") {
                onNext()
            }
            .disabled(!hasNext)
        }
        // 播放舱内已经留了内边距：这里只需要一点点空隙，避免按钮贴着分隔线。
        .padding(.horizontal, 1)
        .fixedSize()
    }

    private var transportDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 13)
            .padding(.horizontal, 2)
    }

    private var playButton: some View {
        Button {
            model.togglePlay()
        } label: {
            ZStack {
                if model.isStalled {
                    // 缓冲中不显示暂停图标：换成小转环，跟画面里的等待动画一致。
                    VideoMiniSpinner()
                } else {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(Color.accentColor)
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                }
                .shadow(color: Color.accentColor.opacity(0.30), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .animation(.snappy(duration: 0.2), value: model.isPlaying)
        .help(model.isPlaying ? "暂停 (K)" : "播放 (K)")
    }
}

/// 工具栏中部的进度行：当前时间 / 可拖动进度条 / 总时长（点击切换剩余时间）。
struct VideoToolbarProgress: View {
    @ObservedObject var model: VideoPlayerModel
    /// 播放编排：缓冲区间从它的已生成末尾 / 保留起点来。
    @ObservedObject var session: PlaybackSession
    @Binding var showsRemaining: Bool
    /// 章节刻度（比例）：顶栏进度条与画面内进度条保持一致。
    var chapterFractions: [Double] = []

    /// 悬停预览需要窗口坐标来对准光标（工具栏自己装不下气泡）。
    @State private var hostWindow: NSWindow?

    private var progress: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.currentTime / model.duration))
    }

    private var buffered: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, model.bufferedEndTime / model.duration))
    }

    private var bufferedStart: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, session.retainedStartSeconds / model.duration))
    }

    private var durationText: String {
        if showsRemaining, model.duration > 0 {
            return "-" + formatPlayerTime(max(0, model.duration - model.currentTime))
        }
        return formatPlayerTime(model.duration)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(formatPlayerTime(model.currentTime))
                .frame(minWidth: 36, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())

            // 轨道用强调色：与信息行的进度圆环同一套语言，进度点带柔光。
            VideoScrubber(progress: progress,
                          buffered: buffered,
                          bufferedStart: bufferedStart,
                          tint: Color.accentColor,
                          duration: model.duration,
                          chapterFractions: chapterFractions,
                          onPreviewChange: { fraction in
                              guard AppSettings.shared.scrubPreviewEnabled else {
                                  VideoScrubPreviewCenter.shared.end()
                                  return
                              }
                              if let fraction {
                                  VideoScrubPreviewCenter.shared.hover(fraction: fraction,
                                                                       duration: model.duration,
                                                                       player: model.player,
                                                                       window: hostWindow)
                              } else {
                                  VideoScrubPreviewCenter.shared.end()
                              }
                          }) { value in
                model.scrub(to: value * model.duration)
            } onCommit: { value in
                model.requestSeek(to: value * model.duration)
            }
            // 播放舱宽度固定，进度条吃掉中间的全部宽度，翻页时长度不变。
            .frame(minWidth: 120, maxWidth: .infinity)

            Text(durationText)
                .frame(minWidth: 40, alignment: .leading)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
                .contentShape(Rectangle())
                .onTapGesture { showsRemaining.toggle() }
                .help("点击切换已播 / 剩余时长")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help("拖动进度条定位")
        .background {
            WindowAccessor { window in
                if hostWindow !== window { hostWindow = window }
            }
        }
    }
}

/// 进度条右侧的音量：平时只是一枚扬声器图标，鼠标移上去向左展开一条可拖动的小轨道，
/// 移开自动收起；点图标静音。轨道与进度条同一套配色和进度点样式，展开过程带弹簧动画。
struct VideoInlineVolume: View {
    @ObservedObject var model: VideoPlayerModel

    @State private var isHovering = false
    @State private var isDragging = false

    private var isExpanded: Bool { isHovering || isDragging }

    private var icon: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 5) {
            volumeRail
                .frame(width: isExpanded ? 84 : 0, height: 16)
                .opacity(isExpanded ? 1 : 0)
                .clipped()

            Button {
                if model.volume == 0 {
                    model.volume = 0.6
                    model.isMuted = false
                } else {
                    model.isMuted.toggle()
                }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.isMuted ? "取消静音（移入展开音量）" : "静音（移入展开音量）")
        }
        .onHover { inside in
            isHovering = inside
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isExpanded)
    }

    private var volumeRail: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = model.isMuted ? 0 : min(1, max(0, model.volume))
            let knobSize: CGFloat = isDragging ? 10 : 7
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 3)
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }

                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.40),
                                                  Color.accentColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * value, height: 3)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: knobSize, height: knobSize)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.8)
                    }
                    .shadow(color: Color.accentColor.opacity(0.40), radius: 3)
                    .offset(x: width * value - knobSize / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let next = min(1, max(0, gesture.location.x / width))
                        model.volume = next
                        if model.isMuted, next > 0 { model.isMuted = false }
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
    }
}

/// 工具栏右侧的播放选项：把倍速、循环、填充、旋转、画中画、音量与截图收进一个菜单，
/// 顶栏只留一枚入口，避免按钮挤在一起。
struct VideoToolbarOptions: View {
    /// 只保留几份快照，不直接观察播放器：播放器每 250ms 发布一次播放时间，
    /// 直接观察会让工具栏菜单跟着 250ms 重建，展开的子菜单会被收起、点不中。
    let model: VideoPlayerModel
    @ObservedObject var settings: AppSettings
    let quarterTurns: Int
    let onRotate: () -> Void
    let onCapture: () -> Void

    @State private var speed: Double
    @State private var looping: Bool
    @State private var muted: Bool
    @State private var pipActive: Bool
    @State private var pipAvailable: Bool

    init(model: VideoPlayerModel,
         settings: AppSettings,
         quarterTurns: Int,
         onRotate: @escaping () -> Void,
         onCapture: @escaping () -> Void) {
        self.model = model
        _settings = ObservedObject(wrappedValue: settings)
        self.quarterTurns = quarterTurns
        self.onRotate = onRotate
        self.onCapture = onCapture
        _speed = State(initialValue: model.speed)
        _looping = State(initialValue: model.isLooping)
        _muted = State(initialValue: model.isMuted)
        _pipActive = State(initialValue: model.isPipActive)
        _pipAvailable = State(initialValue: model.isPipAvailable)
    }

    private var pipActiveBinding: Binding<Bool> {
        Binding(get: { pipActive },
                set: { active in
                    guard active != pipActive else { return }
                    pipActive = active
                    model.togglePip()
                })
    }

    var body: some View {
        Menu {
            Section("播放速度") {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                    Button {
                        speed = value
                        model.setSpeed(value)
                    } label: {
                        if speed == value {
                            Label(speedLabel(value), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(value))
                        }
                    }
                }
            }

            Section("画面") {
                Toggle("循环播放", isOn: Binding(get: { looping },
                                                 set: { looping = $0; model.isLooping = $0 }))
                Menu("显示方式") {
                    ForEach(VideoFramingMode.allCases) { mode in
                        Toggle(isOn: Binding(
                            get: { settings.videoFramingMode == mode },
                            set: { isOn in
                                if isOn { settings.videoFramingMode = mode }
                            }
                        )) {
                            Text(mode.title)
                        }
                    }
                }
                Menu("画面比例") {
                    ForEach(VideoAspectPreset.allCases) { preset in
                        Toggle(isOn: Binding(
                            get: { settings.videoAspectPreset == preset },
                            set: { isOn in
                                guard isOn else { return }
                                settings.videoAspectPreset = preset
                                settings.videoPanX = 0
                                settings.videoPanY = 0
                            }
                        )) {
                            Text(preset.title)
                        }
                    }
                }
                Menu("平移画面") {
                    Button("上移画面") { nudgePan(dx: 0, dy: -0.25) }
                    Button("下移画面") { nudgePan(dx: 0, dy: 0.25) }
                    Button("左移画面") { nudgePan(dx: -0.25, dy: 0) }
                    Button("右移画面") { nudgePan(dx: 0.25, dy: 0) }
                    Button("居中") {
                        settings.videoPanX = 0
                        settings.videoPanY = 0
                    }
                }
                Button("旋转 90°") { onRotate() }
                Toggle("画中画", isOn: pipActiveBinding)
                    .disabled(!pipAvailable)
            }

            Section("声音") {
                Toggle("静音", isOn: Binding(get: { muted },
                                             set: { muted = $0; model.isMuted = $0 }))
                Button("音量 25%") { setVolume(0.25) }
                Button("音量 50%") { setVolume(0.5) }
                Button("音量 100%") { setVolume(1) }
            }

            Divider()

            Button("保存当前帧…") { onCapture() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.82))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(quarterTurns == 0 ? "播放选项" : "播放选项（画面已旋转）")
        // 只在这几个值真的变化时同步快照；播放时间推进不会触发重绘。
        .onReceive(model.$speed) { speed = $0 }
        .onReceive(model.$isLooping) { looping = $0 }
        .onReceive(model.$isMuted) { muted = $0 }
        .onReceive(model.$isPipActive) { pipActive = $0 }
        .onReceive(model.$isPipAvailable) { pipAvailable = $0 }
    }

    private func setVolume(_ value: Double) {
        model.volume = value
        model.isMuted = false
        muted = false
    }

    private func nudgePan(dx: Double, dy: Double) {
        settings.videoPanX = min(1, max(-1, settings.videoPanX + dx))
        settings.videoPanY = min(1, max(-1, settings.videoPanY + dy))
    }

    private func speedLabel(_ value: Double) -> String {
        String(format: "%g×", value)
    }
}

func formatPlayerTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

/// 音轨 / 字幕菜单：顶栏与画面内控制条共用同一组状态与交互。
struct VideoMediaMenuButtons: View {
    enum Style {
        /// 叠在画面上：白色图标 + 深色底。
        case overlay
        /// 窗口工具栏 / 播放舱：跟随系统明暗。
        case toolbar
    }

    @ObservedObject var ui: VideoPlaybackUI
    @ObservedObject var model: VideoPlayerModel
    var style: Style = .overlay
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 2) {
            // 画面入口顶栏与画面内共用：显示方式、比例预设与平移都只改显示层。
            framingMenu
            if ui.audioChoices.count > 1 { audioMenu }
            // 章节 / 角度 / HDR 入口顶栏与画面内共用：蓝光与电影都靠它跳段、切视角与切映射。
            if ui.chapters.count > 1 { chapterMenu }
            if ui.angleCount > 1 { angleMenu }
            if ui.hdrToneMapAvailable { hdrMenu }
            // 顶栏只保留音轨入口：字幕在画面内控制条与「视频 › 字幕」菜单里切换。
            if style == .overlay { subtitleMenu }
        }
    }

    private var framingMenu: some View {
        Menu {
            Section("显示方式") {
                ForEach(VideoFramingMode.allCases) { mode in
                    Toggle(isOn: Binding(
                        get: { settings.videoFramingMode == mode },
                        set: { isOn in
                            if isOn { settings.videoFramingMode = mode }
                        }
                    )) {
                        Text(mode.title)
                    }
                }
            }
            Section("画面比例") {
                ForEach(VideoAspectPreset.allCases) { preset in
                    Toggle(isOn: Binding(
                        get: { settings.videoAspectPreset == preset },
                        set: { isOn in
                            guard isOn else { return }
                            settings.videoAspectPreset = preset
                            // 换比例后原来的平移量没有意义，回到居中。
                            settings.videoPanX = 0
                            settings.videoPanY = 0
                        }
                    )) {
                        Text(preset.title)
                    }
                }
            }
            Section("平移") {
                Button("上移画面") { nudgePan(dx: 0, dy: -0.25) }
                Button("下移画面") { nudgePan(dx: 0, dy: 0.25) }
                Button("左移画面") { nudgePan(dx: -0.25, dy: 0) }
                Button("右移画面") { nudgePan(dx: 0.25, dy: 0) }
                Button("居中") {
                    settings.videoPanX = 0
                    settings.videoPanY = 0
                }
            }
            Divider()
            Text("\(settings.videoFramingMode.title) · \(settings.videoAspectPreset.title)")
        } label: {
            icon("crop", active: settings.videoFramingMode != .fit
                || settings.videoAspectPreset != .source)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("画面显示方式 / 比例 / 平移")
    }

    /// 平移量是 -1...1 的比例，由布局层换算成像素；画面不超出裁剪框时移动不会有可见效果。
    private func nudgePan(dx: Double, dy: Double) {
        settings.videoPanX = min(1, max(-1, settings.videoPanX + dx))
        settings.videoPanY = min(1, max(-1, settings.videoPanY + dy))
    }

    private var chapterMenu: some View {
        Menu {
            // 蓝光盘内标题：标准里没有逐章文本名，用它做菜单标题行。
            if let discTitle = ui.discTitle {
                Text(discTitle)
                Divider()
            }
            ForEach(Array(ui.chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    ui.onSeekChapter?(chapter.start)
                } label: {
                    if ui.currentChapterIndex(at: model.currentTime) == index {
                        Label(chapterTitle(chapter), systemImage: "checkmark")
                    } else {
                        Text(chapterTitle(chapter))
                    }
                }
            }
        } label: {
            icon("list.bullet.rectangle.portrait", active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("章节（⌥← / ⌥→）")
    }

    private func chapterTitle(_ chapter: VideoChapter) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "章节" : title
    }

    private var angleMenu: some View {
        Menu {
            ForEach(1...ui.angleCount, id: \.self) { angle in
                Button {
                    ui.selectAngle(angle)
                } label: {
                    if angle == ui.selectedAngle {
                        Label("角度 \(angle)", systemImage: "checkmark")
                    } else {
                        Text("角度 \(angle)")
                    }
                }
            }
        } label: {
            icon("camera.rotate", active: ui.selectedAngle > 1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("蓝光多角度")
    }

    private var hdrMenu: some View {
        Menu {
            Toggle("色调映射到 SDR", isOn: Binding(
                get: { ui.hdrToneMapEnabled },
                set: { ui.setHDRToneMap($0) }
            ))
            Text(ui.hdrToneMapEnabled ? "当前：已映射，颜色与片源观感一致（转码）"
                                      : "当前：原样交给系统解码（HDR 屏）")
        } label: {
            icon("sun.max", active: ui.hdrToneMapEnabled)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("HDR 色调映射（本次播放）")
    }

    private var audioMenu: some View {
        Menu {
            // 用菜单式 Toggle 而不是自绘 checkmark：macOS 的 NSMenu 只认系统勾选状态，
            // HStack 里的 Image 会被丢掉，表现就是「一条都没选中」。
            ForEach(ui.audioChoices) { choice in
                let title = choice.title.isEmpty ? "音轨 \(choice.index + 1)" : choice.title
                Toggle(isOn: Binding(
                    get: { choice.index == ui.selectedAudioIndex },
                    set: { isOn in
                        if isOn { ui.selectAudio(choice.index) }
                    }
                )) {
                    Text(title)
                }
            }
        } label: {
            icon("waveform", active: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("音轨")
    }

    private var subtitleMenu: some View {
        Menu {
            if !ui.embeddedTracks.isEmpty {
                ForEach(ui.embeddedTracks) { track in
                    if track.isImage {
                        // 图形字幕（PGS / VobSub）无法转文本，只能烧进画面。
                        Button {
                            ui.burnEmbeddedTrack(track)
                        } label: {
                            if ui.burnSubtitleStream == track.ordinal {
                                Label("烧录图形 · \(track.displayName)", systemImage: "checkmark")
                            } else {
                                Text("烧录图形 · \(track.displayName)")
                            }
                        }
                    } else {
                        Button {
                            ui.selectEmbeddedTrack(track)
                        } label: {
                            if ui.embeddedTrackOrdinal == track.ordinal {
                                Label("内嵌 · \(track.displayName)", systemImage: "checkmark")
                            } else {
                                Text("内嵌 · \(track.displayName)")
                            }
                        }
                        .disabled(ui.embeddedLoading)
                    }
                }
                if ui.embeddedLoading { Text("正在提取内嵌字幕…") }
                Divider()
            }
            Button("载入字幕文件…") { ui.pickSubtitle() }
            Button("烧录字幕（PGS / SUP / ASS）…") { ui.pickBurnInSubtitle() }
            if let burnName = ui.burnSubtitleName {
                Button("关闭烧录：\(burnName)") { ui.clearBurnInSubtitle() }
            }
            if ui.canSearchOnlineSubtitles {
                Button(ui.onlineSubtitleLoading ? "正在搜索在线字幕…" : "在线搜索字幕…") {
                    ui.searchOnlineSubtitles()
                }
                .disabled(ui.onlineSubtitleLoading)
                if !ui.onlineSubtitles.isEmpty {
                    Menu("选择在线字幕") {
                        ForEach(ui.onlineSubtitles) { match in
                            Button(subtitleOptionTitle(match)) {
                                ui.downloadOnlineSubtitle(match)
                            }
                        }
                    }
                } else if let hint = ui.onlineSubtitleHint {
                    Text(hint)
                }
            }
            if ui.hasSubtitle {
                Button("关闭字幕") { ui.clearEmbeddedSubtitle() }
                Divider()
                Button("字幕延后 0.5 秒") { ui.adjustOffset(0.5) }
                Button("字幕提前 0.5 秒") { ui.adjustOffset(-0.5) }
                Button("重置偏移（当前 \(offsetText)）") { ui.resetOffset() }
            }
            if ui.embeddedTrackOrdinal != nil {
                Button("关闭内嵌字幕") { ui.clearEmbeddedSubtitle() }
            }
            if !model.legibleOptions.isEmpty {
                Divider()
                ForEach(model.legibleOptions.indices, id: \.self) { index in
                    let option = model.legibleOptions[index]
                    Button {
                        ui.clearSubtitle()
                        model.selectLegible(option)
                    } label: {
                        if model.selectedLegible == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
                if model.selectedLegible != nil {
                    Button("关闭内嵌字幕") { model.selectLegible(nil) }
                }
            }
        } label: {
            icon(ui.hasSubtitle || model.selectedLegible != nil ? "captions.bubble.fill" : "captions.bubble",
                 active: ui.hasSubtitle || model.selectedLegible != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
    }

    private var offsetText: String {
        String(format: "%+.1fs", ui.subtitleOffset)
    }

    private func subtitleOptionTitle(_ match: CinemaSubtitleMatch) -> String {
        var parts = [match.provider.title, match.languageTitle, match.title]
        if let release = match.release, !release.isEmpty { parts.append(release) }
        if let downloads = match.downloads, downloads > 0 { parts.append("↓\(downloads)") }
        return parts.joined(separator: " · ")
    }

    private func icon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(foreground(active))
            .frame(width: 26, height: style == .overlay ? 26 : 24)
            .background {
                RoundedRectangle(cornerRadius: style == .overlay ? 7 : 6, style: .continuous)
                    .fill(background(active))
            }
            .contentShape(Rectangle())
    }

    private func foreground(_ active: Bool) -> Color {
        if active { return Color.accentColor }
        return style == .overlay ? Color.white.opacity(0.86) : Color.primary.opacity(0.82)
    }

    private func background(_ active: Bool) -> Color {
        if active { return Color.accentColor.opacity(style == .overlay ? 0.2 : 0.16) }
        return style == .overlay ? Color.white.opacity(0.001) : Color.primary.opacity(0.001)
    }
}
