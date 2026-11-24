import AVFoundation
import Foundation
import NanoCore
import NanoSync
import NanoVFS
import Observation
#if canImport(Libmpv)
import Libmpv
#endif

public enum PlayerBackendEngine: String, Sendable {
    case avPlayerNative = "AVPlayer (Apple 硬解)"
    case mpvMetalEngine = "MPVKit (libmpv + VideoToolbox)"
}

public protocol ExternalMPVBackendAdapter: AnyObject, Sendable {
    func attachRenderSurface(_ rawViewOrLayerPointer: UnsafeMutableRawPointer)
    func loadStream(url: URL, headers: [String: String], startSec: Double)
    func loadExternalSubtitle(url: URL)
    func applyInfuseProAVSettings(
        aspectMode: VideoAspectCropMode,
        toneMapping: HDRToneMappingCurve,
        deinterlace: Bool,
        audioMode: AudioDSPMode,
        volumeBoostPercent: Int,
        audioDelayMs: Int
    )
    func setRate(_ rate: Float)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

#if canImport(Libmpv)
/// 真实 MPVKit (libmpv) 硬件加速后端实现（当设置 NANO_USE_VENDOR_LIBS=1 时自动编译激活）
public final class LibmpvHardwareBackend: ExternalMPVBackendAdapter, @unchecked Sendable {
    private var mpvHandle: OpaquePointer?

    public init() {
        let handle = mpv_create()
        if let handle {
            mpv_set_option_string(handle, "hwdec", "videotoolbox")
            mpv_set_option_string(handle, "vo", "gpu-next")
            // 激活 libplacebo 杜比视界 RPU 动态元数据解析与 EDR 色彩空间输出，防止 MKV 杜比视界偏紫偏绿
            mpv_set_option_string(handle, "target-colorspace-hint", "yes")
            mpv_set_option_string(handle, "keep-open", "yes")
            mpv_set_option_string(handle, "sub-auto", "fuzzy")
            mpv_initialize(handle)
            self.mpvHandle = handle
        }
    }

    public func attachRenderSurface(_ rawViewOrLayerPointer: UnsafeMutableRawPointer) {
        guard let mpvHandle else { return }
        var wid = Int64(Int(bitPattern: rawViewOrLayerPointer))
        mpv_set_option(mpvHandle, "wid", MPV_FORMAT_INT64, &wid)
    }

    public func loadStream(url: URL, headers: [String: String], startSec: Double) {
        guard let mpvHandle else { return }
        if !headers.isEmpty {
            let headerFields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            mpv_set_option_string(mpvHandle, "http-header-fields", headerFields)
        }
        if startSec > 0 {
            mpv_set_option_string(mpvHandle, "start", String(format: "%.1f", startSec))
        }
        command(["loadfile", url.absoluteString, "replace"])
    }

    public func loadExternalSubtitle(url: URL) {
        command(["sub-add", url.absoluteString, "select"])
    }

    public func applyInfuseProAVSettings(
        aspectMode: VideoAspectCropMode,
        toneMapping: HDRToneMappingCurve,
        deinterlace: Bool,
        audioMode: AudioDSPMode,
        volumeBoostPercent: Int,
        audioDelayMs: Int
    ) {
        guard let mpvHandle else { return }
        mpv_set_option_string(mpvHandle, "volume-max", "300")
        mpv_set_option_string(mpvHandle, "volume", "\(volumeBoostPercent)")
        mpv_set_option_string(mpvHandle, "tone-mapping", toneMapping.mpvOptionValue)
        mpv_set_option_string(mpvHandle, "deinterlace", deinterlace ? "yes" : "no")
        let delaySec = Double(audioDelayMs) / 1000.0
        mpv_set_option_string(mpvHandle, "audio-delay", String(format: "%.3f", delaySec))

        switch aspectMode {
        case .originalFit:
            mpv_set_option_string(mpvHandle, "panscan", "0.0")
            mpv_set_option_string(mpvHandle, "video-aspect-override", "-1")
        case .fillScreen:
            mpv_set_option_string(mpvHandle, "panscan", "1.0")
        case .anamorphic239:
            mpv_set_option_string(mpvHandle, "video-aspect-override", "2.39:1")
        case .classic4x3:
            mpv_set_option_string(mpvHandle, "video-aspect-override", "4:3")
        }

        switch audioMode {
        case .passthrough:
            mpv_set_option_string(mpvHandle, "af", "")
        case .dialogueClarity:
            mpv_set_option_string(mpvHandle, "af", "lavfi=[pan=stereo|FL=0.5*FC+0.707*FL|FR=0.5*FC+0.707*FR]")
        case .lateNightDRC:
            mpv_set_option_string(mpvHandle, "af", "lavfi=[dynaudnorm=f=150:g=15]")
        }
    }

    public func setRate(_ rate: Float) {
        guard let mpvHandle else { return }
        var r = Double(rate)
        mpv_set_property(mpvHandle, "speed", MPV_FORMAT_DOUBLE, &r)
    }

    public func play() {
        guard let mpvHandle else { return }
        var flag: Int32 = 0
        mpv_set_property(mpvHandle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func pause() {
        guard let mpvHandle else { return }
        var flag: Int32 = 1
        mpv_set_property(mpvHandle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func seek(to seconds: Double) {
        command(["seek", String(format: "%.2f", seconds), "absolute"])
    }

    public func stop() {
        command(["stop"])
    }

    private func command(_ args: [String]) {
        guard let mpvHandle else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { ($0 as NSString).utf8String }
        cArgs.append(nil)
        cArgs.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command(mpvHandle, buf.baseAddress)
        }
    }

    deinit {
        if let mpvHandle {
            mpv_terminate_destroy(mpvHandle)
        }
    }
}
#endif

/// 跨 macOS 与 tvOS 的双内核播放状态机控制器（含进度自动落库、字幕音轨管理、直播断流自动切源）
@Observable
public final class NanoPlayerController: @unchecked Sendable {
    public static let shared = NanoPlayerController()

    public private(set) var activeTicket: PlayableStreamTicket?
    public private(set) var activePersistenceKey: String?
    public private(set) var activeEngine: PlayerBackendEngine = .avPlayerNative
    public private(set) var isPlaying: Bool = false
    public private(set) var isBuffering: Bool = false
    public private(set) var currentTimeSec: Double = 0
    public private(set) var durationSec: Double = 0
    public private(set) var failoverBannerMessage: String?

    // 音轨与外挂/内封字幕状态
    public private(set) var audioTracks: [PlayerMediaTrackOption] = []
    public private(set) var subtitleTracks: [PlayerMediaTrackOption] = []
    public var selectedAudioTrackID: String?
    public var selectedSubtitleTrackID: String?
    public var subtitleDelaySec: Double = 0.0
    public private(set) var activeExternalSubtitleLine: String?
    private var parsedExternalCues: [SubtitleCueItem] = []

    // Infuse Pro 级音视频调校与章节/A-B循环状态
    public var aspectCropMode: VideoAspectCropMode = .originalFit { didSet { syncInfuseProDSP() } }
    public var hdrToneMapping: HDRToneMappingCurve = .bt2390 { didSet { syncInfuseProDSP() } }
    public var deinterlaceEnabled: Bool = false { didSet { syncInfuseProDSP() } }
    public var audioDSPMode: AudioDSPMode = .passthrough { didSet { syncInfuseProDSP() } }
    public var volumeBoostPercent: Int = 100 {
        didSet {
            avPlayer.volume = min(1.0, Float(volumeBoostPercent) / 100.0)
            syncInfuseProDSP()
        }
    }
    public var audioDelayMs: Int = 0 { didSet { syncInfuseProDSP() } }
    public var activeTMDBID: Int?
    public var activeIsMovie: Bool = true
    public var loopPointASec: Double?
    public var loopPointBSec: Double?
    public var chapters: [MediaChapterPoint] = []

    public var playbackRate: Float = 1.0 {
        didSet {
            avPlayer.rate = isPlaying ? playbackRate : 0
            mpvAdapter?.setRate(playbackRate)
        }
    }

    // IPTV 直播多线路容灾状态
    public private(set) var activeLiveChannel: IPTVChannelGroup?
    public private(set) var activeLineIndex: Int = 0
    private var consecutiveFailoverCount: Int = 0
    private var liveWatchdogTask: Task<Void, Never>?

    public let avPlayer = AVPlayer()
    public var mpvAdapter: (any ExternalMPVBackendAdapter)?
    private var timeObserverToken: Any?
    private var itemFailedObserver: NSObjectProtocol?
    private var lastSavedProgressTimestamp: Double = 0

    public init() {
        #if canImport(Libmpv)
        self.mpvAdapter = LibmpvHardwareBackend()
        #endif
        setupTimeAndFailureObservers()
    }

    public static func selectOptimalEngine(
        for ticket: PlayableStreamTicket,
        hasMPVInstalled: Bool
    ) -> PlayerBackendEngine {
        let ext = ticket.streamURL.pathExtension.lowercased()
        let mpvPreferredExts: Set<String> = ["mkv", "avi", "rmvb", "iso", "m2ts", "flv", "ape", "dsf", "dff", "wmv"]

        if ticket.prefersDolbyVisionNative && (ext == "mp4" || ext == "m3u8" || ext == "mov") {
            return .avPlayerNative
        }
        if mpvPreferredExts.contains(ext) && hasMPVInstalled {
            return .mpvMetalEngine
        }
        return .avPlayerNative
    }

    /// 启动点播或直播，支持传入持久化键 `persistenceKey` 自动恢复上次播放进度及挂载外挂字幕
    @MainActor
    public func startPlayback(
        ticket: PlayableStreamTicket,
        persistenceKey: String? = nil,
        externalSubtitles: [URL] = []
    ) async {
        self.activeTicket = ticket
        let resolvedKey = persistenceKey ?? ticket.streamURL.absoluteString
        self.activePersistenceKey = ticket.isLiveStream ? nil : resolvedKey
        self.isBuffering = true
        self.failoverBannerMessage = nil
        self.parsedExternalCues = []
        self.activeExternalSubtitleLine = nil

        // 若未显式指定起始时间，自动从 SQLite 恢复上次观看秒数
        var resumePosition = ticket.startPositionSec
        if !ticket.isLiveStream && resumePosition <= 0 {
            let savedRecords = await NanoDatabaseStore.shared.fetchAll(namespace: "playback_history", as: PlaybackProgressRecord.self)
            if let match = savedRecords.first(where: { $0.id == resolvedKey }),
               match.positionSec > 5,
               (match.durationSec == 0 || match.positionSec < match.durationSec - 30) {
                resumePosition = match.positionSec
            }
        }

        var targetURL = ticket.streamURL
        if !ticket.headers.isEmpty && ticket.streamURL.host != "127.0.0.1" {
            if let proxied = try? await LocalStreamProxyServer.shared.registerStream(
                remoteURL: ticket.streamURL,
                headers: ticket.headers
            ) {
                targetURL = proxied
            }
        }

        let chosen = Self.selectOptimalEngine(for: ticket, hasMPVInstalled: mpvAdapter != nil)
        self.activeEngine = chosen
        let ext = ticket.streamURL.pathExtension.lowercased()
        if ["mkv", "iso", "rmvb", "avi", "flv", "wmv"].contains(ext) && mpvAdapter == nil {
            self.failoverBannerMessage = "当前文件为 .\(ext) 封装，请以 NANO_USE_VENDOR_LIBS=1 编译启用 MPVKit 全格式硬解内核"
        }
        let effectiveStart = max(resumePosition, Double(ticket.introSkipSec))

        switch chosen {
        case .avPlayerNative:
            mpvAdapter?.stop()
            let asset = AVURLAsset(url: targetURL)
            let item = AVPlayerItem(asset: asset)
            // 开启逐帧 HDR10+ / Dolby Vision 动态元数据透传，并保持 0.5x~4.0x 倍速播放人声音调不变
            item.appliesPerFrameHDRDisplayMetadata = true
            item.audioTimePitchAlgorithm = .timeDomain
            avPlayer.replaceCurrentItem(with: item)
            await inspectAVAssetTracks(asset: asset, item: item, externalSubtitles: externalSubtitles)
            if effectiveStart > 0 && !ticket.isLiveStream {
                await avPlayer.seek(to: CMTime(seconds: effectiveStart, preferredTimescale: 600))
            }
            avPlayer.playImmediately(atRate: playbackRate)
            self.isPlaying = true
            self.isBuffering = false

        case .mpvMetalEngine:
            avPlayer.pause()
            mpvAdapter?.loadStream(url: targetURL, headers: ticket.headers, startSec: effectiveStart)
            for subURL in externalSubtitles {
                mpvAdapter?.loadExternalSubtitle(url: subURL)
            }
            mpvAdapter?.play()
            self.isPlaying = true
            self.isBuffering = false
        }

        // 若存在同目录外挂字幕，自动加载第一条供实时渲染
        if let firstSub = externalSubtitles.first {
            await loadExternalSubtitleContent(from: firstSub)
        }
        syncInfuseProDSP()

        if !ticket.isLiveStream, let tmdb = activeTMDBID {
            let pct = durationSec > 0 ? (currentTimeSec / durationSec) * 100.0 : 1.0
            Task {
                await TraktSyncService.shared.reportScrobble(action: "start", tmdbID: tmdb, isMovie: activeIsMovie, progressPercent: pct)
            }
        }
    }

    /// 加载并解析外挂 `.srt` / `.ass` 字幕文件（支持远程 HTTP/本地文件）
    @MainActor
    public func loadExternalSubtitleContent(from url: URL) async {
        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (fetched, _) = try await URLSession.shared.data(from: url)
                data = fetched
            }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
                ?? ""
            let cues = ExternalSubtitleParser.parse(content: text, fileExtension: url.pathExtension)
            self.parsedExternalCues = cues
            self.selectedSubtitleTrackID = url.absoluteString
            mpvAdapter?.loadExternalSubtitle(url: url)
        } catch {
            self.parsedExternalCues = []
        }
    }

    /// 切换音轨或字幕轨道
    @MainActor
    public func selectMediaTrack(_ option: PlayerMediaTrackOption) async {
        guard let item = avPlayer.currentItem else { return }
        switch option.trackType {
        case .audio:
            selectedAudioTrackID = option.id
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
               let matched = group.options.first(where: { $0.displayName == option.displayName }) {
                item.select(matched, in: group)
            }
        case .subtitle:
            if option.id == "sub_off" {
                selectedSubtitleTrackID = "sub_off"
                parsedExternalCues = []
                activeExternalSubtitleLine = nil
                if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                    item.select(nil, in: group)
                }
                return
            }
            if let extURL = option.externalFileURL {
                await loadExternalSubtitleContent(from: extURL)
            } else if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                      let matched = group.options.first(where: { $0.displayName == option.displayName }) {
                parsedExternalCues = []
                activeExternalSubtitleLine = nil
                selectedSubtitleTrackID = option.id
                item.select(matched, in: group)
            }
        }
    }

    /// 播放 IPTV 频道组，并开启 8 秒首包缓冲超时看门狗自动故障切源
    @MainActor
    public func playLiveChannel(_ channel: IPTVChannelGroup, lineIndex: Int = 0, isAutoFailover: Bool = false) async {
        guard !channel.lines.isEmpty else { return }
        let safeIdx = max(0, min(channel.lines.count - 1, lineIndex))
        if !isAutoFailover {
            self.consecutiveFailoverCount = 0
        }
        self.activeLiveChannel = channel
        self.activeLineIndex = safeIdx

        let line = channel.lines[safeIdx]
        guard let url = URL(string: line.url) else { return }
        var headers: [String: String] = [:]
        if let ua = line.userAgent { headers["User-Agent"] = ua }
        if let ref = line.referer { headers["Referer"] = ref }

        let subtitleText = channel.currentProgram?.title ?? "实时直播 · 线路 \(safeIdx + 1)/\(channel.lines.count)"
        let ticket = PlayableStreamTicket(
            title: channel.displayName,
            subtitle: subtitleText,
            streamURL: url,
            headers: headers,
            isLiveStream: true
        )
        await startPlayback(ticket: ticket)
        if isAutoFailover {
            self.failoverBannerMessage = "原线路响应异常，已自动切换至备用线路 \(safeIdx + 1)/\(channel.lines.count)"
        }
        armLiveStreamWatchdog(expectedChannelID: channel.id, lineIdx: safeIdx)
    }

    @MainActor
    public func switchLiveLine(delta: Int, isAutoFailover: Bool = false) async {
        guard let channel = activeLiveChannel, !channel.lines.isEmpty else { return }
        let count = channel.lines.count
        let nextIdx = (activeLineIndex + delta + count) % count
        await playLiveChannel(channel, lineIndex: nextIdx, isAutoFailover: isAutoFailover)
    }

    @MainActor
    public func togglePlayPause() {
        let pct = durationSec > 0 ? (currentTimeSec / durationSec) * 100.0 : 0
        if isPlaying {
            avPlayer.pause()
            mpvAdapter?.pause()
            isPlaying = false
            persistCurrentProgressImmediately()
            if let tmdb = activeTMDBID {
                Task { await TraktSyncService.shared.reportScrobble(action: "pause", tmdbID: tmdb, isMovie: activeIsMovie, progressPercent: pct) }
            }
        } else {
            avPlayer.playImmediately(atRate: playbackRate)
            mpvAdapter?.play()
            isPlaying = true
            if let tmdb = activeTMDBID {
                Task { await TraktSyncService.shared.reportScrobble(action: "start", tmdbID: tmdb, isMovie: activeIsMovie, progressPercent: pct) }
            }
        }
    }

    @MainActor
    public func seek(by deltaSec: Double) {
        let target = max(0, currentTimeSec + deltaSec)
        seekAbsolute(to: target)
    }

    @MainActor
    public func seekAbsolute(to targetSec: Double) {
        let clamped = max(0, targetSec)
        avPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        mpvAdapter?.seek(to: clamped)
        currentTimeSec = clamped
    }

    @MainActor
    public func stopAndDismiss() {
        persistCurrentProgressImmediately()
        if let tmdb = activeTMDBID, durationSec > 0 {
            let finalPct = (currentTimeSec / durationSec) * 100.0
            let isMov = activeIsMovie
            Task { await TraktSyncService.shared.reportScrobble(action: "stop", tmdbID: tmdb, isMovie: isMov, progressPercent: finalPct) }
        }
        liveWatchdogTask?.cancel()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        mpvAdapter?.stop()
        isPlaying = false
        activeTicket = nil
        activeLiveChannel = nil
        activeTMDBID = nil
        loopPointASec = nil
        loopPointBSec = nil
        parsedExternalCues = []
        activeExternalSubtitleLine = nil
    }

    public func attachNativeRenderSurface(_ pointer: UnsafeMutableRawPointer) {
        mpvAdapter?.attachRenderSurface(pointer)
    }

    private func syncInfuseProDSP() {
        mpvAdapter?.applyInfuseProAVSettings(
            aspectMode: aspectCropMode,
            toneMapping: hdrToneMapping,
            deinterlace: deinterlaceEnabled,
            audioMode: audioDSPMode,
            volumeBoostPercent: volumeBoostPercent,
            audioDelayMs: audioDelayMs
        )
    }

    // MARK: - 内部监听：进度定时写库、外挂字幕同步、直播断流毫秒级切源

    @MainActor
    private func inspectAVAssetTracks(asset: AVURLAsset, item: AVPlayerItem, externalSubtitles: [URL]) async {
        var audios: [PlayerMediaTrackOption] = []
        if let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible) {
            for (idx, opt) in audioGroup.options.enumerated() {
                audios.append(PlayerMediaTrackOption(id: "aud_\(idx)", trackType: .audio, displayName: opt.displayName, languageCode: opt.extendedLanguageTag))
            }
        }
        self.audioTracks = audios
        self.selectedAudioTrackID = audios.first?.id

        var subs: [PlayerMediaTrackOption] = [
            PlayerMediaTrackOption(id: "sub_off", trackType: .subtitle, displayName: "关闭字幕")
        ]
        for extURL in externalSubtitles {
            subs.append(PlayerMediaTrackOption(id: extURL.absoluteString, trackType: .subtitle, displayName: "外挂 · \(extURL.lastPathComponent)", externalFileURL: extURL))
        }
        if let subGroup = try? await asset.loadMediaSelectionGroup(for: .legible) {
            for (idx, opt) in subGroup.options.enumerated() {
                subs.append(PlayerMediaTrackOption(id: "sub_in_\(idx)", trackType: .subtitle, displayName: "内封 · \(opt.displayName)", languageCode: opt.extendedLanguageTag))
            }
        }
        self.subtitleTracks = subs
    }

    private func armLiveStreamWatchdog(expectedChannelID: UUID, lineIdx: Int) {
        liveWatchdogTask?.cancel()
        liveWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard let currentCh = self.activeLiveChannel,
                      currentCh.id == expectedChannelID,
                      self.activeLineIndex == lineIdx,
                      currentCh.lines.count > 1 else { return }
                let itemFailed = (self.avPlayer.currentItem?.status == .failed)
                let stalledAtZero = (self.currentTimeSec < 0.2 && self.avPlayer.timeControlStatus != .playing)
                if (itemFailed || stalledAtZero) && self.consecutiveFailoverCount < currentCh.lines.count - 1 {
                    self.consecutiveFailoverCount += 1
                    Task {
                        await self.switchLiveLine(delta: 1, isAutoFailover: true)
                    }
                }
            }
        }
    }

    private func persistCurrentProgressImmediately() {
        guard let key = activePersistenceKey,
              let ticket = activeTicket,
              !ticket.isLiveStream,
              currentTimeSec > 2 else { return }
        let record = PlaybackProgressRecord(
            id: key,
            vfsPath: key,
            title: ticket.title,
            positionSec: currentTimeSec,
            durationSec: durationSec
        )
        Task {
            try? await NanoDatabaseStore.shared.upsert(namespace: "playback_history", id: key, value: record)
        }
    }

    private func setupTimeAndFailureObservers() {
        let interval = CMTime(seconds: 0.4, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let sec = time.seconds
            guard sec.isFinite else { return }
            self.currentTimeSec = sec

            // 1. A-B 片段循环检测
            if let pointA = self.loopPointASec, let pointB = self.loopPointBSec, pointB > pointA + 1.0, sec >= pointB {
                self.avPlayer.seek(to: CMTime(seconds: pointA, preferredTimescale: 600))
                self.mpvAdapter?.seek(to: pointA)
                return
            }

            // 2. 同步更新外挂字幕当前对白行
            if !self.parsedExternalCues.isEmpty {
                self.activeExternalSubtitleLine = ExternalSubtitleParser.activeSubtitleText(
                    in: self.parsedExternalCues,
                    at: sec,
                    delaySec: self.subtitleDelaySec
                )
            }

            // 2. 每隔 5 秒自动将点播进度写入 SQLite
            if abs(sec - self.lastSavedProgressTimestamp) >= 5.0 {
                self.lastSavedProgressTimestamp = sec
                self.persistCurrentProgressImmediately()
            }

            // 3. 片尾自动跳过检测
            if let dur = self.avPlayer.currentItem?.duration.seconds, dur.isFinite && dur > 0 {
                self.durationSec = dur
                if let ticket = self.activeTicket,
                   !ticket.isLiveStream,
                   ticket.outroSkipSec > 0,
                   dur - sec <= Double(ticket.outroSkipSec) {
                    self.persistCurrentProgressImmediately()
                    self.avPlayer.pause()
                    self.isPlaying = false
                }
            }
        }

        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  let liveCh = self.activeLiveChannel,
                  liveCh.lines.count > 1,
                  self.consecutiveFailoverCount < liveCh.lines.count - 1 else { return }
            self.consecutiveFailoverCount += 1
            Task { @MainActor in
                await self.switchLiveLine(delta: 1, isAutoFailover: true)
            }
        }
    }
}
