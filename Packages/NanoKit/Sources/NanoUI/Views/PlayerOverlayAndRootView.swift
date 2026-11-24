import AVKit
import NanoCore
import NanoDesignSystem
import NanoPlayerKit
import SwiftUI

// MARK: - 1. 统一全屏播放器（支持外挂字幕实时渲染、字幕时间轴偏移、音轨切换、自动故障切源横幅与底部快速换台抽屉）

public struct UnifiedPlayerOverlayView: View {
    @Bindable public var appVM: NanoAppViewModel
    @State private var showOSDControls: Bool = true
    @State private var showTrackSelectorPopover: Bool = false
    @State private var isDraggingSeekSlider: Bool = false
    @State private var sliderDragTimeSec: Double = 0
    @State private var proPanelTab: Int = 0
    @State private var onlineSubQuery: String = ""
    @State private var onlineSubResults: [OnlineSubtitleCandidate] = []
    @State private var isSearchingOnlineSubs: Bool = false

    public init(appVM: NanoAppViewModel) {
        self.appVM = appVM
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if appVM.player.activeEngine == .mpvMetalEngine {
                    MPVHardwareSurfaceView(controller: appVM.player)
                } else {
                    VideoPlayer(player: appVM.player.avPlayer)
                }
            }
            .scaleEffect(appVM.player.aspectCropMode == .fillScreen ? 1.18 : (appVM.player.aspectCropMode == .anamorphic239 ? CGSize(width: 1.12, height: 1.0) : CGSize(width: 1.0, height: 1.0)))
            .ignoresSafeArea()

            // 外挂 .srt / .ass 实时对白渲染层
            if let subLine = appVM.player.activeExternalSubtitleLine, !subLine.isEmpty {
                VStack {
                    Spacer()
                    Text(subLine)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.62)))
                        .padding(.bottom, showOSDControls ? 115 : 44)
                }
                .allowsHitTesting(false)
            }

            if showOSDControls {
                VStack(spacing: 12) {
                    topOSDBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                    if let failoverMsg = appVM.player.failoverBannerMessage {
                        Text(failoverMsg)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NanoPalette.amberGold))
                    }

                    Spacer()

                    if appVM.player.activeLiveChannel != nil {
                        bottomLiveChannelDrawer
                            .padding(.horizontal, 24)
                            .padding(.bottom, 22)
                    } else {
                        bottomVODControlBar
                            .padding(.horizontal, 24)
                            .padding(.bottom, 22)
                    }
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showTrackSelectorPopover) {
            audioAndSubtitleTrackSheet
        }
    }

    private var topOSDBanner: some View {
        HStack(spacing: 16) {
            Button {
                appVM.player.stopAndDismiss()
                appVM.isPresentingFullPlayer = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .buttonStyle(.plain)

            if let liveCh = appVM.player.activeLiveChannel {
                HStack(spacing: 14) {
                    Text(String(format: "%02d", liveCh.channelNumber))
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(liveCh.displayName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            NanoLiveBadge(text: "直播")
                        }
                        Text("\(liveCh.currentProgram?.title ?? "实时信号")  ·  接下来：\(liveCh.nextProgram?.title ?? "精彩节目")")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        Task { await appVM.player.switchLiveLine(delta: -1) }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    Text("\(liveCh.displayName)  \(appVM.player.activeLineIndex + 1) / \(liveCh.lines.count)")
                        .font(.system(size: 13, weight: .semibold))

                    Button {
                        Task { await appVM.player.switchLiveLine(delta: 1) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(.black.opacity(0.62)))
            } else if let ticket = appVM.player.activeTicket {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ticket.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(ticket.subtitle ?? "") · 内核：\(appVM.player.activeEngine.rawValue)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))

                Spacer()

                Button {
                    showTrackSelectorPopover = true
                } label: {
                    Label("字幕 / 音轨", systemImage: "captions.bubble.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.black.opacity(0.62)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bottomLiveChannelDrawer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(appVM.liveChannels) { ch in
                    let isCurrent = (appVM.player.activeLiveChannel?.id == ch.id)
                    Button {
                        Task { await appVM.player.playLiveChannel(ch, lineIndex: 0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "%02d", ch.channelNumber))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(isCurrent ? .black.opacity(0.7) : .white.opacity(0.6))
                            Text(ch.displayName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(isCurrent ? .black : .white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(width: 155, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isCurrent ? Color.white : Color.black.opacity(0.65))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bottomVODControlBar: some View {
        VStack(spacing: 10) {
            // 1. 可拖拽高清视频进度条（支持任意位置快进/后退秒跳）
            if appVM.player.durationSec > 0 {
                HStack(spacing: 12) {
                    Text(formatTime(isDraggingSeekSlider ? sliderDragTimeSec : appVM.player.currentTimeSec))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 56, alignment: .leading)

                    #if os(macOS)
                    Slider(
                        value: Binding(
                            get: { isDraggingSeekSlider ? sliderDragTimeSec : appVM.player.currentTimeSec },
                            set: { newVal in sliderDragTimeSec = newVal }
                        ),
                        in: 0...max(1, appVM.player.durationSec),
                        onEditingChanged: { editing in
                            isDraggingSeekSlider = editing
                            if !editing {
                                appVM.player.seekAbsolute(to: sliderDragTimeSec)
                            }
                        }
                    )
                    .tint(NanoPalette.amberGold)
                    #else
                    ProgressView(value: min(appVM.player.currentTimeSec, appVM.player.durationSec), total: max(1, appVM.player.durationSec))
                        .tint(NanoPalette.amberGold)
                    #endif

                    Text(formatTime(appVM.player.durationSec))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 56, alignment: .trailing)
                }
            }

            // 2. 播放/暂停、快退/快进按钮组（绑定键盘左右方向键与空格键）及 0.5x ~ 4.0x 全档倍速胶囊
            HStack(spacing: 12) {
                Button {
                    appVM.player.togglePlayPause()
                } label: {
                    Image(systemName: appVM.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .keyboardShortcut(.space, modifiers: [])
                #endif

                Button {
                    appVM.player.seek(by: -30)
                } label: {
                    Label("30s", systemImage: "gobackward.30")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    appVM.player.seek(by: -10)
                } label: {
                    Label("10s", systemImage: "gobackward.10")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                #if os(macOS)
                .keyboardShortcut(.leftArrow, modifiers: [])
                #endif

                Button {
                    appVM.player.seek(by: 10)
                } label: {
                    Label("10s", systemImage: "goforward.10")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                #if os(macOS)
                .keyboardShortcut(.rightArrow, modifiers: [])
                #endif

                Button {
                    appVM.player.seek(by: 30)
                } label: {
                    Label("30s", systemImage: "goforward.30")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Spacer()

                ForEach([Float(0.5), Float(0.75), Float(1.0), Float(1.25), Float(1.5), Float(2.0), Float(3.0), Float(4.0)], id: \.self) { rate in
                    Button("\(String(format: "%gx", rate))") {
                        appVM.player.playbackRate = rate
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(appVM.player.playbackRate == rate ? .black : .white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(appVM.player.playbackRate == rate ? NanoPalette.amberGold : Color.white.opacity(0.15)))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.76)))
    }

    private var audioAndSubtitleTrackSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Infuse Pro 专业影音调校与在线字幕")
                    .font(.headline)
                Spacer()
                Picker("", selection: $proPanelTab) {
                    Text("画面与HDR").tag(0)
                    Text("音频增强").tag(1)
                    Text("字幕与在线搜").tag(2)
                    Text("A-B循环").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }

            Divider()

            switch proPanelTab {
            case 0:
                // 1. 画面裁剪去黑边 + HDR 色调映射 + 反交错
                VStack(alignment: .leading, spacing: 12) {
                    Picker("画面比例与黑边裁剪", selection: $appVM.player.aspectCropMode) {
                        ForEach(VideoAspectCropMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    Picker("HDR -> SDR 色调映射算法", selection: $appVM.player.hdrToneMapping) {
                        ForEach(HDRToneMappingCurve.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    Toggle("开启隔行扫描反交错 (Deinterlace · 修复 1080i 锯齿)", isOn: $appVM.player.deinterlaceEnabled)
                }

            case 1:
                // 2. 人声对白增强 / 夜间模式 + 300% 音量增益 + 蓝牙回音壁音画同步校准
                VStack(alignment: .leading, spacing: 12) {
                    Picker("音频 DSP 动态模式", selection: $appVM.player.audioDSPMode) {
                        ForEach(AudioDSPMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    HStack {
                        Text("音量增强增益：\(appVM.player.volumeBoostPercent)%")
                        Spacer()
                        Button("100%") { appVM.player.volumeBoostPercent = 100 }
                        Button("150%") { appVM.player.volumeBoostPercent = 150 }
                        Button("200%") { appVM.player.volumeBoostPercent = 200 }
                        Button("300%") { appVM.player.volumeBoostPercent = 300 }
                    }

                    HStack {
                        Text("无线音箱/耳机延迟校准：\(appVM.player.audioDelayMs) ms")
                        Spacer()
                        Button("-50ms") { appVM.player.audioDelayMs -= 50 }
                        Button("归零") { appVM.player.audioDelayMs = 0 }
                        Button("+50ms") { appVM.player.audioDelayMs += 50 }
                    }

                    if !appVM.player.audioTracks.isEmpty {
                        Divider()
                        Text("切换内封音轨").font(.subheadline.bold())
                        ForEach(appVM.player.audioTracks) { aud in
                            Button(aud.displayName) {
                                Task { await appVM.player.selectMediaTrack(aud) }
                            }
                        }
                    }
                }

            case 2:
                // 3. 在线一键秒搜下载双语字幕 + 本地字幕轨切换 + 时间轴微调
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("输入片名搜索 OpenSubtitles / 射手双语字幕...", text: $onlineSubQuery)
                            .textFieldStyle(.roundedBorder)
                        Button(isSearchingOnlineSubs ? "检索中..." : "在线搜字幕") {
                            isSearchingOnlineSubs = true
                            let q = onlineSubQuery.isEmpty ? (appVM.player.activeTicket?.title ?? "") : onlineSubQuery
                            Task {
                                let found = await OnlineSubtitleSearchService.shared.searchSubtitles(query: q, tmdbID: appVM.player.activeTMDBID)
                                await MainActor.run {
                                    self.onlineSubResults = found
                                    self.isSearchingOnlineSubs = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !onlineSubResults.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(onlineSubResults) { cand in
                                    HStack {
                                        Text("[\(cand.format)] \(cand.fileName) · \(cand.language)")
                                            .font(.caption.bold())
                                            .lineLimit(1)
                                        Spacer()
                                        Button("秒下并挂载") {
                                            Task {
                                                if let localURL = try? await OnlineSubtitleSearchService.shared.downloadSubtitleToLocal(cand) {
                                                    await appVM.player.loadExternalSubtitleContent(from: localURL)
                                                }
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .frame(height: 110)
                    }

                    Divider()

                    HStack {
                        Text("字幕时间轴微调：\(String(format: "%+.1f 秒", appVM.player.subtitleDelaySec))")
                        Spacer()
                        Button("-0.5s") { appVM.player.subtitleDelaySec -= 0.5 }
                        Button("归零") { appVM.player.subtitleDelaySec = 0 }
                        Button("+0.5s") { appVM.player.subtitleDelaySec += 0.5 }
                    }
                }

            default:
                // 4. A-B 精彩片段循环与精确跳秒
                VStack(alignment: .leading, spacing: 12) {
                    Text("A-B 片段循环（设置起点 A 与终点 B 后自动无缝往复播放）")
                        .font(.subheadline)
                    HStack(spacing: 12) {
                        Button("设当前为 A 点 (\(formatTime(appVM.player.loopPointASec ?? 0)))") {
                            appVM.player.loopPointASec = appVM.player.currentTimeSec
                        }
                        Button("设当前为 B 点 (\(formatTime(appVM.player.loopPointBSec ?? 0)))") {
                            appVM.player.loopPointBSec = appVM.player.currentTimeSec
                        }
                        Button("清除循环") {
                            appVM.player.loopPointASec = nil
                            appVM.player.loopPointBSec = nil
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("完成") { showTrackSelectorPopover = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 560)
        .onAppear {
            if onlineSubQuery.isEmpty {
                onlineSubQuery = appVM.player.activeTicket?.title ?? ""
            }
        }
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec > 0 else { return "00:00" }
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 2. 双端自适应主导航根容器（打通真实文件树 VFSFileBrowserView 与整面影院海报墙 CinemaPosterWallView）

public struct NanoRootView: View {
    @State private var appVM = NanoAppViewModel()
    @State private var quickSidebarQuery: String = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebarMenuContent
                .navigationSplitViewColumnWidth(min: 220, ideal: 242, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                detailStageContent

                if let ticket = appVM.player.activeTicket, !appVM.isPresentingFullPlayer {
                    miniNowPlayingBar(ticket: ticket)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
            }
        }
        #if os(macOS)
        .background(
            Button("") {
                appVM.selectedSection = .unifiedSearch
            }
            .keyboardShortcut("f", modifiers: [.command])
            .opacity(0)
        )
        .fullScreenCoverOrOverlay(isPresented: $appVM.isPresentingFullPlayer) {
            UnifiedPlayerOverlayView(appVM: appVM)
        }
        #else
        .fullScreenCover(isPresented: $appVM.isPresentingFullPlayer) {
            UnifiedPlayerOverlayView(appVM: appVM)
        }
        #endif
    }

    private var sidebarMenuContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(NanoPalette.amberGold)
                    Text("Nano")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                // 侧边栏常驻全局快搜框（回车直达统一流式搜索页）
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NanoPalette.electricBlue)
                    TextField("统一搜索 (⌘F)...", text: $quickSidebarQuery)
                        .textFieldStyle(.plain)
                        .foregroundStyle(NanoPalette.textPrimary)
                        .font(.system(size: 12))
                        .onSubmit {
                            let kw = quickSidebarQuery
                            appVM.selectedSection = .unifiedSearch
                            appVM.searchCoordinator.performUnifiedSearch(keyword: kw, in: appVM)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
                )

                sidebarRow(
                    title: "全局统一搜索",
                    icon: "sparkle.magnifyingglass",
                    badge: appVM.searchCoordinator.results.isEmpty ? nil : "\(appVM.searchCoordinator.results.count)",
                    target: .unifiedSearch
                )

                // 分组 1：网络存储与影院海报墙
                sidebarGroupHeader("网络存储与影院")
                VStack(spacing: 4) {
                    sidebarRow(title: "网络存储中心", icon: "externaldrive.fill.badge.wifi", badge: "\(appVM.visibleStorageSources.count)", target: .storageHub)
                    sidebarRow(title: "内置小雅服务", icon: "shippingbox.and.arrow.backward.fill", badge: "5678", target: .embeddedXiaoya)
                    sidebarRow(title: "影院海报墙 (分类)", icon: "film.stack.fill", badge: "\(appVM.visibleMediaItems.count)", target: .cinemaWall)
                    ForEach(appVM.visibleStorageSources) { src in
                        sidebarRow(title: src.name, icon: src.type.iconSystemName, badge: nil, target: .storageDetail(src.id))
                    }
                }

                // 分组 2：网络电视 (IPTV)
                sidebarGroupHeader("网络电视")
                VStack(spacing: 4) {
                    sidebarRow(title: "全频直播", icon: "play.tv.fill", badge: "\(appVM.liveChannels.count)", target: .liveTVAll)
                    sidebarRow(title: "收藏频道", icon: "star.fill", badge: "\(appVM.liveChannels.filter(\.isFavorite).count)", target: .liveTVCategory("收藏"))
                    sidebarRow(title: "央视", icon: "circle.fill", badge: nil, target: .liveTVCategory("央视"))
                    sidebarRow(title: "卫视", icon: "circle.fill", badge: nil, target: .liveTVCategory("卫视"))
                    sidebarRow(title: "港澳台", icon: "circle.fill", badge: nil, target: .liveTVCategory("港澳台"))
                    sidebarRow(title: "4K8K 频道", icon: "4k.tv.fill", badge: nil, target: .liveTVCategory("4K8K 频道"))
                }

                // 分组 3：网络资源
                sidebarGroupHeader("网络资源")
                VStack(spacing: 4) {
                    sidebarRow(title: "全部资源仪表盘", icon: "square.grid.2x2.fill", badge: "\(appVM.visibleRemoteSites.count)", target: .remoteResourceHub)
                    ForEach(appVM.visibleRemoteSites) { site in
                        sidebarRow(title: site.name, icon: "safari", badge: "\(site.categoryCount)", target: .remoteSiteDetail(site.id))
                    }
                }

                // 分组 4：音频与系统同步
                sidebarGroupHeader("音频与 Pro 系统")
                VStack(spacing: 4) {
                    sidebarRow(title: "Hi-Fi 音乐中心", icon: "music.note.house.fill", badge: "\(appVM.musicTracks.count)", target: .musicCenter)
                    sidebarRow(title: "Infuse Pro 测速与同步", icon: "speedometer", badge: "PRO", target: .infuseProLab)
                    sidebarRow(
                        title: appVM.privacyGuard.isUnlocked ? "隐私空间 (已解锁)" : "同步与隐私设置",
                        icon: appVM.privacyGuard.isUnlocked ? "lock.open.fill" : "gearshape.2.fill",
                        badge: nil,
                        target: .settingsSync
                    )
                }
            }
            .padding(12)
        }
        .background(NanoPalette.sidebarBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private var detailStageContent: some View {
        switch appVM.selectedSection {
        case .unifiedSearch:
            UnifiedSearchView(appVM: appVM)
        case .storageHub:
            StorageHubView(appVM: appVM)
        case .embeddedXiaoya:
            EmbeddedXiaoyaCenterView(appVM: appVM)
        case .storageDetail(let sourceID):
            if let src = appVM.storageSources.first(where: { $0.id == sourceID }) {
                VFSFileBrowserView(appVM: appVM, source: src)
            } else {
                StorageHubView(appVM: appVM)
            }
        case .cinemaWall:
            CinemaPosterWallView(appVM: appVM)
        case .cinemaDetail(let mediaID):
            CinemaDetailView(appVM: appVM, mediaID: mediaID)
        case .liveTVAll:
            LiveTVHubView(appVM: appVM, forcedCategory: nil)
        case .liveTVCategory(let cat):
            LiveTVHubView(appVM: appVM, forcedCategory: cat)
        case .remoteResourceHub:
            RemoteResourceHubView(appVM: appVM)
        case .remoteSiteDetail(let siteID):
            if let site = appVM.remoteSites.first(where: { $0.id == siteID }) {
                RemoteSiteCategoryBrowserView(appVM: appVM, site: site)
            } else {
                RemoteResourceHubView(appVM: appVM)
            }
        case .musicCenter:
            MusicCenterView(appVM: appVM)
        case .infuseProLab:
            InfuseProLabAndSpeedTestView(appVM: appVM)
        case .privacySpace, .settingsSync:
            SyncAndPrivacySettingsView(appVM: appVM)
        }
    }

    private func sidebarGroupHeader(_ title: String) -> some View {
        Text("| \(title)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(NanoPalette.electricBlue.opacity(0.9))
            .padding(.horizontal, 10)
    }

    private func sidebarRow(title: String, icon: String, badge: String?, target: NanoSidebarSection) -> some View {
        let isSelected = (appVM.selectedSection == target)
        return Button {
            appVM.selectedSection = target
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : NanoPalette.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : NanoPalette.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : NanoPalette.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? NanoPalette.electricBlue.opacity(0.85) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func miniNowPlayingBar(ticket: PlayableStreamTicket) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .foregroundStyle(NanoPalette.amberGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(ticket.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                if let sub = ticket.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(NanoPalette.textSecondary)
                }
            }
            Spacer()
            Button {
                appVM.player.togglePlayPause()
            } label: {
                Image(systemName: appVM.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button("展开画面") {
                appVM.isPresentingFullPlayer = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NanoPalette.subtleBorder, lineWidth: 1))
        )
    }
}

#if os(macOS)
private extension View {
    func fullScreenCoverOrOverlay<OverlayContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> OverlayContent
    ) -> some View {
        ZStack {
            self
            if isPresented.wrappedValue {
                content()
                    .zIndex(999)
            }
        }
    }
}
#endif
