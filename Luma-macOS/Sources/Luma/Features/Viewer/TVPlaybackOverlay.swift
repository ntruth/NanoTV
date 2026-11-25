import SwiftUI
import AppKit
import PlaybackCore

/// 电视 OSD：叠在播放画面上的一层频道语义，不接管播放器本身。
/// 频道信息与动作都收在窗口工具栏里；画面只保留时间河与节目单抽屉。
/// 信息贴边、中间留空，保证不遮住画面主体。
struct TVPlaybackOverlay: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel

    let channel: TVChannel
    let photoID: UUID
    let isLive: Bool
    let controlsVisible: Bool
    @Binding var timeshiftActive: Bool
    @Binding var showGuide: Bool
    @ObservedObject var model: VideoPlayerModel
    /// 全部线路失败：只保留顶部频道信息，收起时间河 / 抽屉。
    var failureMode: Bool = false
    /// 频道级动作（截帧 / 节目单 / 收藏频道）是否已经由窗口工具栏承载：
    /// 工具栏可见时不再在画面里重复一份，全屏或独立查看器时仍保留。
    var usesWindowToolbarActions: Bool = false
    /// 截帧：把当前画面连同频道 / 节目信息存下来。
    var onCaptureFrame: () -> Void = {}

    @State private var dayOffset = 0
    /// 时移：暂停直播时截下的一帧，胶片带上的「当前格」用它。
    @State private var riverFrame: NSImage?
    /// 回到直播时的收束动画：0…1 的视觉位置，不动真实播放时间。
    @State private var riverCatchUp: Double?
    @State private var riverRewinding = false
    /// 直播边缘的呼吸灯。
    @State private var livePulse = false
    /// 节目单里正在悬停的节目：行底色与操作胶囊只在悬停时抬起。
    @State private var hoveredProgramID: String?

    private var currentProgram: TVEPGProgram? { tv.currentProgram(for: channel) }
    private var lineCount: Int { store.tvLineCount(for: photoID) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 全屏 / 独立查看器没有窗口工具栏：在画面左上角补一条紧凑频道信息，
                // 频道号、台标、Now & Next、线路读数一个不少。
                if !usesWindowToolbarActions {
                    HStack(spacing: 0) {
                        compactInfoBar
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                // 频道信息与动作都已经并入窗口工具栏；画面在全屏 / 独立查看器时
                // 才补一小块操作胶囊，其余情况保持干净的纯画面。
                if !usesWindowToolbarActions, controlsVisible, !failureMode {
                    HStack {
                        Spacer(minLength: 0)
                        actionDock
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
                // 概念 A · 时间河：暂停直播后，底部不再是进度条，而是一条从过去流向现在的河。
                if showTimeRiver, !failureMode {
                    timeRiver
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // 概念 A：画面中央只留一行「时间差」，提醒你停在河里、直播还在走。
            if timeshiftActive, showTimeRiver, !failureMode {
                centerTimeCaption
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if showGuide, !failureMode {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        // 概念 B：抽屉宽 392px，窄屏不超过画面 46%，只覆盖右侧。
                        guideDrawer(width: min(392, max(288, proxy.size.width * 0.46)),
                                    maxHeight: max(300, proxy.size.height - 28))
                            .padding(.vertical, 14)
                            .padding(.trailing, 14)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .animation(.easeOut(duration: 0.22), value: showGuide)
        .task { tv.loadEPGIfNeeded() }
        .onChange(of: showGuide) { _, open in
            // 打开「节目信息」时按需检查节目单：内存缓存够新就直接用，
            // 过期才把刷新排进后台任务，不挡播放。
            if open { tv.loadEPGIfNeeded() }
        }
        .onChange(of: currentProgram?.id) { _, _ in
            // 节目切换时把抽屉拉回「今天」，避免停在上一次翻到的日期。
            if dayOffset != 0, currentProgram != nil { dayOffset = 0 }
        }
        .onChange(of: model.isPlaying) { _, playing in
            // 暂停直播即进入时移，底部展开时间河。
            if isLive, !playing, model.isItemReady, liveEdge > 1 {
                timeshiftActive = true
            }
        }
        .onChange(of: photoID) { _, _ in
            timeshiftActive = false
            riverFrame = nil
            riverCatchUp = nil
        }
        .onChange(of: timeshiftActive) { _, active in
            if active {
                captureRiverFrame()
                startLivePulse()
            } else {
                riverCatchUp = nil
                riverRewinding = false
            }
        }
        .onChange(of: model.currentTime) { _, _ in
            // 追到直播边缘（拖动或按 L）后自动收起时间河。
            if timeshiftActive, model.isPlaying, lag < 1.2 {
                timeshiftActive = false
            }
        }
        .onChange(of: tv.reminderNotice) { _, notice in
            guard let notice else { return }
            store.showToast(notice)
            tv.clearReminderNotice()
        }
    }

    // MARK: - 画面左上角紧凑频道信息

    /// 只在没有窗口工具栏时出现：全屏沉浸或独立查看器窗口。
    private var compactInfoBar: some View {
        HStack(spacing: 9) {
            Text(String(format: "%02d", tv.channelNumber(for: channel)))
                .font(.system(size: 19, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .fixedSize()

            TVLogoImage(urlString: channel.logoURL,
                        size: CGSize(width: 42, height: 20),
                        cornerRadius: 4)
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if channel.isCatchUp {
                        Text("回看")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.16),
                                        in: Capsule(style: .continuous))
                    } else {
                        TVLiveBadge()
                    }
                }
                HStack(spacing: 5) {
                    if let program = currentProgram {
                        Text(program.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                        Text(clock(program.start) + " – " + clock(program.end))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                    } else {
                        Text("暂无节目单")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text("·")
                        .foregroundStyle(.white.opacity(0.35))
                    Text("\(lineCount) 线路 · \(channel.isHLS ? "HLS" : "HTTP")")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                }
            }

            // 节目进度：与工具栏频道舱同一条细线。
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(TVBrand.wave)
                        .frame(width: max(0, proxy.size.width
                                          * (currentProgram.map(programProgress) ?? 0)))
                }
            }
            .frame(width: 110, height: 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    // MARK: - 画面操作胶囊

    /// 画面右下角的一小块操作胶囊：时移 / 线路 / 睡眠 / 录制 / 截帧 / 节目单 / 收藏。
    /// 频道号、台名、Now & Next 与线路读数已经并入窗口工具栏的「频道舱」，
    /// 这里只保留可点的动作，不再单独占一条信息卡。
    private var actionDock: some View {
        topBarActions
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var topBarActions: some View {
        // 与窗口工具栏共用同一个动作组：时移 / 线路 / 睡眠 / 录制 / 截帧 / 节目单 / 收藏
        // 的位置和图标不会再随入口不同而漂移。
        TVChannelActionCluster(channel: channel,
                               photoID: photoID,
                               isLive: isLive,
                               timeshiftActive: $timeshiftActive,
                               showGuide: $showGuide,
                               style: .overlay,
                               onReturnToLive: timeshiftActive ? { returnToLive() } : nil,
                               onToggleTimeshift: {
                                   if timeshiftActive {
                                       returnToLive()
                                   } else {
                                       model.pause()
                                       timeshiftActive = true
                                   }
                               },
                               onCapture: onCaptureFrame)
    }

    // MARK: - 时间河（时移）

    /// 直播边缘（绝对秒）：ffmpeg 已生成的分片末尾与播放器缓冲末端取较大值。
    private var liveEdge: Double { max(0, model.bufferedEndTime) }
    /// 河床起点：取播放器真实可 seek 的起点，河是固定的，只有直播边缘在走。
    private var windowStart: Double {
        min(model.seekableStartTime, max(0, liveEdge - 1))
    }
    private var windowSpan: Double { max(1, liveEdge - windowStart) }
    private var lag: Double { max(0, liveEdge - model.currentTime) }
    private var riverProgress: Double {
        min(1, max(0, (model.currentTime - windowStart) / windowSpan))
    }
    private var showTimeRiver: Bool {
        guard isLive, model.isItemReady, liveEdge > 1 else { return false }
        return timeshiftActive || !model.isPlaying
    }

    /// 视觉上的河位：回到直播时先用 240ms 把它推到 1，再真正 seek。
    private var knobProgress: Double { riverCatchUp ?? riverProgress }

    /// 画面中央的时间差：概念图里那句「画面停在…直播已经走到…」。
    private var centerTimeCaption: some View {
        let now = Date()
        let picture = now.addingTimeInterval(-lag)
        return VStack(spacing: 3) {
            Text("画面停在 \(wallClock(picture))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
            Text("直播已经走到 \(wallClock(now))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TVBrand.signal.opacity(0.72))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.32),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 暂停时抓一帧当胶片「当前格」，抓不到就退回信号页缩略图。
    private func captureRiverFrame(after delay: Double = 0.15) {
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let cg = await model.currentFrameImage() else { return }
            riverFrame = NSImage(cgImage: cg,
                                 size: NSSize(width: cg.width, height: cg.height))
        }
    }

    /// 直播边缘的呼吸灯：一个红色小竖条来回明暗。
    private func startLivePulse() {
        livePulse = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            livePulse = true
        }
    }

    /// 10 秒步进，限制在真实可 seek 的窗口内。
    private func nudge(_ delta: Double) {
        guard !riverRewinding else { return }
        let lower = model.seekableStartTime
        let upper = max(lower, liveEdge - 0.4)
        let target = min(upper, max(lower, model.currentTime + delta))
        model.requestSeek(to: target)
        captureRiverFrame(after: 0.6)
    }

    /// 回到直播：金色河段在 240ms 内收束到右端，再跳回直播边缘。
    private func returnToLive() {
        guard !riverRewinding else { return }
        riverRewinding = true
        riverCatchUp = riverProgress
        withAnimation(.easeInOut(duration: 0.24)) {
            riverCatchUp = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            model.requestSeek(to: max(0, liveEdge - 0.5))
            model.play()
            timeshiftActive = false
            riverCatchUp = nil
            riverRewinding = false
        }
    }

    private var timeRiver: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("时间河")
                        .font(.system(size: 17, weight: .medium, design: .serif))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text("TEMPORAL TRANSPORT")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(TVBrand.gold.opacity(0.55))
                }
                Spacer(minLength: 0)
                Text("LAG \(lagClock)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TVBrand.gold)
                lagBar
                // 10 秒步进：键盘 ←/→ 与这两个按钮等价。
                Button { nudge(-10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .frame(width: 24, height: 18)
                        .background(Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("回退 10 秒（←）")
                Button { nudge(10) } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .frame(width: 24, height: 18)
                        .background(Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("前进 10 秒（→）")
                Button { returnToLive() } label: {
                    Text("回到直播")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(TVBrand.gold, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(riverRewinding)
                .help("跳回直播边缘 (L)")
            }

            filmstrip
            riverRail
            riverTicks
        }
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.05, green: 0.055, blue: 0.07).opacity(0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(TVBrand.gold.opacity(0.16), lineWidth: 0.7)
                }
        }
        .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
    }

    private var lagBar: some View {
        Capsule()
            .fill(
                LinearGradient(colors: [TVBrand.gold.opacity(0.85), TVBrand.signal],
                               startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: 46, height: 3)
    }

    /// 胶片带：五个时间点，中间偏右是当前画面，最右是仍在前进的直播。
    /// 上下两排齿孔是「这是一段被拖动的胶片」的拟物提示。
    private var filmstrip: some View {
        VStack(spacing: 3) {
            sprocketRow
            HStack(spacing: 6) {
                ForEach(Array(stripLabels.enumerated()), id: \.offset) { pair in
                    let isNow = pair.offset == stripLabels.count - 1
                    let isCurrent = pair.offset == stripLabels.count - 2
                    ZStack(alignment: .bottomLeading) {
                        filmCell(index: pair.offset)
                        Text(pair.element)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(isNow ? TVBrand.signal : Color.white.opacity(0.6))
                            .padding(.horizontal, 5)
                            .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isCurrent ? TVBrand.wave
                                                    : (isNow ? TVBrand.signal.opacity(0.6)
                                                             : Color.white.opacity(0.10)),
                                          lineWidth: isCurrent || isNow ? 1 : 0.5)
                    }
                }
            }
            sprocketRow
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                }
        }
    }

    /// 胶片齿孔：一排等距小方孔。
    private var sprocketRow: some View {
        Canvas { context, size in
            let hole: CGFloat = 3.4
            var x: CGFloat = 1.5
            while x < size.width - hole {
                let rect = CGRect(x: x, y: (size.height - hole) / 2,
                                  width: hole, height: hole)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                             with: .color(Color.white.opacity(0.18)))
                x += 10
            }
        }
        .frame(height: 6)
        .allowsHitTesting(false)
    }

    /// 胶片格：当前格用真实截帧；越往前越暗、越不饱和，像在河里往回走。
    @ViewBuilder
    private func filmCell(index: Int) -> some View {
        let currentIndex = stripLabels.count - 2
        let distance = abs(index - currentIndex)
        let probe = tv.probeReports[channel.id]?.image
        let image: NSImage? = index == currentIndex ? (riverFrame ?? probe) : probe
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(max(0.25, 1 - Double(distance) * 0.18))
                .brightness(-Double(distance) * 0.05)
                .overlay(Color.black.opacity(0.18 + Double(distance) * 0.10))
        } else {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.black.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// 五个采样点：-2:00 / -1:30 / -1:00 / 当前落后 / NOW；窗口不足时按比例收敛。
    private var stripLabels: [String] {
        let span = min(120, windowSpan)
        let currentLag = min(lag, span)
        return [
            "-" + shortClock(span),
            "-" + shortClock(span * 0.75),
            "-" + shortClock(span * 0.5),
            "-" + shortClock(currentLag),
            "NOW"
        ]
    }

    private var riverRail: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knobX = width * knobProgress
            let knobW: CGFloat = 11
            let railY: CGFloat = 18
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: width, height: 6)
                    .offset(y: railY)
                // 金色：已经看过的河段。
                Capsule()
                    .fill(
                        LinearGradient(colors: [TVBrand.gold.opacity(0.25), TVBrand.gold.opacity(0.8)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(0, knobX), height: 6)
                    .offset(y: railY)
                // 红色斜纹：画面与直播之间的时间差。
                hatch
                    .frame(width: max(0, width - knobX), height: 6)
                    .offset(x: knobX, y: railY)
                // 最右侧红线：仍在前进的直播，带一点呼吸。
                Rectangle()
                    .fill(TVBrand.signal)
                    .frame(width: 2, height: 11)
                    .offset(x: width - 2, y: railY - 2.5)
                    .opacity(livePulse ? 0.45 : 1)
                // 铜制滑块：竖向拉丝铜牌，上沿挂着落后读数。
                Capsule()
                    .fill(
                        LinearGradient(colors: [TVBrand.gold.opacity(0.98),
                                                Color(red: 0.52, green: 0.36, blue: 0.12)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: knobW, height: 20)
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6)
                    }
                    .shadow(color: TVBrand.gold.opacity(0.55), radius: 6)
                    .offset(x: max(0, min(width - knobW, knobX - knobW / 2)),
                            y: railY - 7)
                // 滑块下方的青色指针，指向轨道上的确切位置。
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(TVBrand.wave)
                    .frame(width: 2, height: 6)
                    .offset(x: max(0, min(width - 2, knobX - 1)), y: railY + 10)
                // 落后读数：概念图里挂在滑块正上方的铜色小牌。
                Text("-" + shortClock(lag))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TVBrand.gold, in: Capsule(style: .continuous))
                    .fixedSize()
                    .offset(x: max(0, min(width - 48, knobX - 24)), y: 0)
            }
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !riverRewinding else { return }
                        let fraction = min(1, max(0, value.location.x / max(1, width)))
                        model.scrub(to: windowStart + fraction * windowSpan)
                    }
                    .onEnded { value in
                        guard !riverRewinding else { return }
                        let fraction = min(1, max(0, value.location.x / max(1, width)))
                        model.requestSeek(to: windowStart + fraction * windowSpan)
                        // 松手后把新位置的画面抓进胶片带。
                        captureRiverFrame(after: 0.7)
                    }
            )
        }
        .frame(height: 40)
    }

    private var hatch: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(TVBrand.signal.opacity(0.18)))
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(TVBrand.signal.opacity(0.55)), lineWidth: 1)
                x += 5
            }
        }
    }

    private var riverTicks: some View {
        HStack(spacing: 0) {
            Text(tickLabel(windowSpan))
            Spacer(minLength: 0)
            Text(tickLabel(windowSpan * 0.5))
            Spacer(minLength: 0)
            Text(tickLabel(min(30, windowSpan)))
            Spacer(minLength: 0)
            Text("NOW")
                .foregroundStyle(TVBrand.signal)
        }
        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.42))
    }

    /// 河床刻度：分钟用 MIN、秒用 SEC，和概念图的量纲一致。
    private func tickLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total >= 60 { return "-\(total / 60) MIN" }
        return "-\(total) SEC"
    }

    private var lagClock: String {
        let seconds = Int(lag.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func shortClock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total >= 60 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes):00" : String(format: "%d:%02d", minutes, rest)
        }
        return "\(total)s"
    }

    // MARK: - 节目单抽屉（影院放映单）

    private func guideDrawer(width: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            guideHeader

            dayChips
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Rectangle()
                .fill(LinearGradient(colors: [TVBrand.gold.opacity(0.22),
                                              Color.white.opacity(0.04)],
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(height: 0.7)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    if dayPrograms.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: tv.isLoadingEPG ? "hourglass" : "calendar.badge.exclamationmark")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(TVBrand.gold.opacity(0.55))
                            Text(tv.isLoadingEPG ? "正在读取节目单…" : "这一天还没有节目单")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            LazyVStack(spacing: 1) {
                                ForEach(dayPrograms) { program in
                                    programRow(program)
                                        .id(program.id)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .onAppear {
                    if let current = currentProgram, dayOffset == 0 {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
                .onChange(of: dayOffset) { _, _ in
                    if let current = currentProgram, dayOffset == 0 {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            guideFooter
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background { guideDrawerBackground }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [TVBrand.gold.opacity(0.30), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 0.8)
                .padding(.horizontal, 24)
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
    }

    /// 抽屉头：英文 kicker + 台名衬线大字 + 日期与节目数，像一张影院放映单。
    private var guideHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("PROGRAM GUIDE")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(TVBrand.gold.opacity(0.9))
                Rectangle()
                    .fill(TVBrand.gold.opacity(0.28))
                    .frame(width: 18, height: 0.7)
                Text("\(dayPrograms.count) 个节目")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
                Spacer(minLength: 0)
                Button {
                    showGuide = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.07), in: Circle())
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .help("收起节目单 (E)")
            }

            HStack(spacing: 9) {
                TVLogoImage(urlString: channel.logoURL,
                            size: CGSize(width: 38, height: 21),
                            cornerRadius: 4)
                    .padding(4)
                    .background(Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 21, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(dayTitle(dayOffset))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 2.5, height: 2.5)
                        Text(dayCaption)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
                if isLive, dayOffset == 0 {
                    TVLiveBadge()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(dayOffsets, id: \.self) { offset in
                    let active = dayOffset == offset
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { dayOffset = offset }
                    } label: {
                        HStack(spacing: 4) {
                            if active {
                                Circle()
                                    .fill(TVBrand.gold)
                                    .frame(width: 3.5, height: 3.5)
                            }
                            Text(dayTitle(offset))
                                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                        }
                        .foregroundStyle(active ? TVBrand.gold : Color.white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(active ? TVBrand.gold.opacity(0.14) : Color.white.opacity(0.045),
                                    in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(active ? TVBrand.gold.opacity(0.50)
                                                     : Color.white.opacity(0.06),
                                              lineWidth: 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 2)
        }
    }

    private func programRow(_ program: TVEPGProgram) -> some View {
        let live = program.isLive && dayOffset == 0
        let past = program.end <= Date()
        let future = program.start > Date()
        let catchUp = past && !(channel.catchUpSource ?? "").isEmpty
        let reminded = tv.isReminded(program)
        let hovered = hoveredProgramID == program.id
        let playable = catchUp || future
        let progress = programProgress(program)
        let remaining = max(0, Int(program.end.timeIntervalSinceNow / 60))

        return Button {
            if catchUp {
                showGuide = false
                store.openTVCatchup(channel, program: program)
            } else if future {
                tv.toggleReminder(program, channel: channel)
            }
        } label: {
            HStack(spacing: 0) {
                Text(clock(program.start))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(live ? TVBrand.signal
                                          : Color.white.opacity(past ? 0.30 : 0.55))
                    .frame(width: 42, alignment: .trailing)
                    .padding(.trailing, 9)

                // 时间轴：一根细脊 + 每档一个节点，正在播的节点带一层红光。
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 1)
                    if live {
                        Circle()
                            .fill(TVBrand.signal.opacity(0.16))
                            .frame(width: 15, height: 15)
                    }
                    Circle()
                        .fill(live ? TVBrand.signal
                                   : (past ? TVBrand.gold.opacity(0.70)
                                           : Color.white.opacity(0.22)))
                        .frame(width: live ? 6 : 4.5, height: live ? 6 : 4.5)
                }
                .frame(width: 14)
                .padding(.trailing, 9)

                VStack(alignment: .leading, spacing: 3) {
                    Text(program.title)
                        .font(.system(size: live ? 12.5 : 11.5,
                                     weight: live ? .semibold : .regular,
                                     design: live ? .serif : .default))
                        .foregroundStyle(.white.opacity(live ? 0.96 : 0.78))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text("\(max(1, Int(program.duration / 60))) 分钟")
                        if live {
                            Text("· 已播 \(Int(progress * program.duration / 60)) 分钟")
                            Text("· 还剩 \(remaining) 分钟")
                                .foregroundStyle(TVBrand.gold.opacity(0.72))
                        } else if let subtitle = program.subtitle, !subtitle.isEmpty {
                            Text("· \(subtitle)")
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)

                    if live {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.10))
                                Capsule()
                                    .fill(LinearGradient(colors: [TVBrand.signal,
                                                                  TVBrand.gold.opacity(0.85)],
                                                         startPoint: .leading,
                                                         endPoint: .trailing))
                                    .frame(width: max(2, proxy.size.width * progress))
                            }
                        }
                        .frame(height: 2)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 6)

                guideStatusPill(live: live, past: past,
                                catchUp: catchUp, reminded: reminded)
                    .opacity(hovered || live || reminded ? 1 : 0.82)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, live ? 10 : 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(live
                          ? AnyShapeStyle(LinearGradient(colors: [TVBrand.signal.opacity(0.15),
                                                                  TVBrand.gold.opacity(0.035)],
                                                         startPoint: .leading,
                                                         endPoint: .trailing))
                          : AnyShapeStyle(hovered ? Color.white.opacity(0.045) : Color.clear))
            }
            .overlay {
                if live || hovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(live ? TVBrand.signal.opacity(0.22)
                                           : Color.white.opacity(0.07),
                                      lineWidth: 0.6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playable)
        .onHover { inside in
            if inside {
                hoveredProgramID = program.id
            } else if hoveredProgramID == program.id {
                hoveredProgramID = nil
            }
        }
        .help(future
              ? (reminded ? "点击取消开播提醒" : "节目开播时用系统通知提醒")
              : (catchUp ? "回看 \(program.title)" : program.title))
    }

    /// 行尾状态胶囊：直播用红、可回看用金、可预约用中性白。
    private func guideStatusPill(live: Bool, past: Bool,
                                 catchUp: Bool, reminded: Bool) -> some View {
        let color = statusColor(live: live, past: past, catchUp: catchUp, reminded: reminded)
        return HStack(spacing: 3.5) {
            if live {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
            }
            Text(statusText(live: live, past: past, catchUp: catchUp, reminded: reminded))
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(live ? 0.8 : 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(live ? 0.14 : 0.08), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
        }
        .fixedSize()
    }

    private var guideFooter: some View {
        HStack(spacing: 10) {
            guideLegendDot(TVBrand.gold.opacity(0.8), "可回看")
            guideLegendDot(TVBrand.signal, "正在播")
            guideLegendDot(Color.white.opacity(0.28), "可预约")
            Spacer(minLength: 0)
            Text("E")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text("收起")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.28))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.6)
        }
    }

    private func guideLegendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    /// 抽屉底：深色玻璃 + 左上暖金环境光 + 右下一点信号红，和影院的海报灯箱同一套语言。
    private var guideDrawerBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.075, blue: 0.11).opacity(0.72),
                                              Color.black.opacity(0.78)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            RadialGradient(colors: [TVBrand.gold.opacity(0.11), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 300)
            RadialGradient(colors: [TVBrand.signal.opacity(0.07), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 260)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 抽屉副标题：日期 + 星期，不再重复「今天」。
    private var dayCaption: String {
        let calendar = Calendar.current
        guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { return "" }
        return date.formatted(.dateTime.month(.defaultDigits).day().weekday(.wide))
    }

    // MARK: - 数据

    private var dayPrograms: [TVEPGProgram] {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { return [] }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return tv.programs(for: channel)
            .filter { $0.start >= start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    private var dayOffsets: [Int] {
        guard isLive else { return [0] }
        let supportsCatchUp = !(channel.catchUpSource ?? "").isEmpty
        // 正数 = 过去（回看天数由源声明），负数 = 未来（预约）。
        // 与节目回看页一致：前天 / 昨天 / 今天 / 明天 / 后天。
        let past = supportsCatchUp ? min(6, channel.effectiveCatchUpDays - 1) : 0
        return Array(-2...past)
    }

    private func dayTitle(_ offset: Int) -> String {
        switch offset {
        case -2: return "后天"
        case -1: return "明天"
        case 0: return "今天"
        case 1: return "昨天"
        default:
            let calendar = Calendar.current
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return "今天" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
    }

    private func statusText(live: Bool, past: Bool, catchUp: Bool, reminded: Bool) -> String {
        if live { return "直播" }
        if past { return catchUp ? "回看" : "已结束" }
        return reminded ? "已预约" : "预约"
    }

    private func statusColor(live: Bool, past: Bool, catchUp: Bool, reminded: Bool) -> Color {
        if live { return TVBrand.signal }
        if past { return catchUp ? TVBrand.gold.opacity(0.92) : Color.white.opacity(0.32) }
        return reminded ? TVBrand.gold : Color.white.opacity(0.45)
    }

    private func programProgress(_ program: TVEPGProgram) -> Double {
        let now = Date()
        guard program.end > program.start else { return 0 }
        return min(1, max(0, now.timeIntervalSince(program.start) / program.duration))
    }

    private func clock(_ date: Date) -> String {
        Self.clockFormatter.string(from: date)
    }

    /// 时移读数要带秒：画面 / 直播 / 落后的时间点精确到秒。
    private func wallClock(_ date: Date) -> String {
        Self.wallClockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let wallClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
