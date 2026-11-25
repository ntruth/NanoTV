import Foundation
import CoreGraphics
import Combine

/// 一次边下边播起流的完整输入：由 App 的播放页提供，内核不解析图库 / 网盘 / 剧集。
public struct PlaybackStreamContext {
    public var photoID: UUID
    public var title: String
    public var sourceURL: URL
    public var headers: [String: String]
    public var trustSelfSigned: Bool
    public var isHEVC: Bool
    public var isHDR: Bool
    /// 完整色彩管线：转封装原样写回，HDR / DV 策略也据此判断。
    public var color: VideoColorInfo
    /// 完整片源时长与画面尺寸：用于进度条与旋转布局。
    public var duration: Double
    public var size: CGSize
    /// 源帧率：重编码时与画面尺寸一起决定输出档位。
    public var frameRate: Double
    /// 隔行源（1080i / DVD）：重编码时先去隔行，避免梳齿。
    public var isInterlaced: Bool
    /// 蓝光多角度视角（1 起）：切换角度会重建流。
    public var angle: Int
    public var audioTracks: [AudioTrackInfo]
    public var audioIndex: Int
    /// 多声道输出方式：自动保留源声道，或强制降混成立体声。
    public var audioDownmix: AudioDownmixMode
    /// 重编码目标编码：兼容 / 高效 / 低功耗。
    public var transcodeMode: VideoTranscodeMode
    /// 重编码时保留 HDR（HDR 屏 + HDR10 源）：不做色调映射，输出 HDR HEVC。
    public var preserveHDR: Bool
    /// 需要烧录的外挂字幕；有值时强制走重编码。
    public var burnSubtitle: URL?
    /// 需要烧录的内嵌图形字幕轨序号（PGS / VobSub）。
    public var burnSubtitleStream: Int?
    /// 播放策略签名：进入转码缓存目录名，策略变化后不复用旧结果。
    public var cacheSignature: String
    /// 云盘直链过期时重新解析。
    public var refreshSource: (() -> (URL, [String: String])?)?
    public var autoplay: Bool
    public var loop: Bool
    public var muted: Bool
    /// ffmpeg 读取位置（会再对齐到关键帧）。
    public var offset: Double
    /// 播放器最终要落到的完整时间轴秒数。
    public var resumeAt: Double?
    public var preferredMode: StreamMode
    /// 直播：没有续播、不落缓存，非 HLS 源直接交给 ffmpeg 转封装。
    public var isLive: Bool
    /// 换片令牌：起流完成后用来判断这次请求是否已经过期。
    public var generation: Int
    public var isCurrent: () -> Bool

    public init(photoID: UUID,
                title: String,
                sourceURL: URL,
                headers: [String: String],
                trustSelfSigned: Bool,
                isHEVC: Bool,
                isHDR: Bool,
                color: VideoColorInfo = VideoColorInfo(),
                duration: Double,
                size: CGSize,
                frameRate: Double = 0,
                isInterlaced: Bool = false,
                angle: Int = 1,
                audioTracks: [AudioTrackInfo],
                audioIndex: Int,
                audioDownmix: AudioDownmixMode = .source,
                transcodeMode: VideoTranscodeMode = .compatibility,
                preserveHDR: Bool = false,
                burnSubtitle: URL?,
                burnSubtitleStream: Int? = nil,
                cacheSignature: String = "",
                refreshSource: (() -> (URL, [String: String])?)?,
                autoplay: Bool,
                loop: Bool,
                muted: Bool,
                offset: Double,
                resumeAt: Double?,
                preferredMode: StreamMode,
                isLive: Bool = false,
                generation: Int,
                isCurrent: @escaping () -> Bool) {
        self.photoID = photoID
        self.title = title
        self.sourceURL = sourceURL
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.isHEVC = isHEVC
        self.isHDR = isHDR
        self.color = color
        self.duration = duration
        self.size = size
        self.frameRate = frameRate
        self.isInterlaced = isInterlaced
        self.angle = max(1, angle)
        self.audioTracks = audioTracks
        self.audioIndex = audioIndex
        self.audioDownmix = audioDownmix
        self.transcodeMode = transcodeMode
        self.preserveHDR = preserveHDR
        self.burnSubtitle = burnSubtitle
        self.burnSubtitleStream = burnSubtitleStream
        self.cacheSignature = cacheSignature
        self.refreshSource = refreshSource
        self.autoplay = autoplay
        self.loop = loop
        self.muted = muted
        self.offset = offset
        self.resumeAt = resumeAt
        self.preferredMode = preferredMode
        self.isLive = isLive
        self.generation = generation
        self.isCurrent = isCurrent
    }
}

public enum PlaybackStreamOutcome: Equatable {
    /// 首段已就绪，播放器已装片。
    case started
    /// 起流失败；`canTranscode` 表示可以提示「转换为兼容格式」。
    case failed(message: String, canTranscode: Bool)
    /// 换片 / 任务取消，结果直接丢弃。
    case cancelled
    /// 已经有重建任务在跑，本次只排进了待办。
    case queued
}

/// 播放编排：起流、降级、seek 重建、音轨切换、分片回收。
///
/// 播放页只负责解析片源与 UI；这里不依赖 SwiftUI / 图库，所有外部能力通过
/// `PlaybackEnvironment` 与 `PlaybackStreamContext` 注入。
@MainActor
public final class PlaybackSession: ObservableObject {
    public let engine: VideoPlayerModel
    private let environment: PlaybackEnvironment

    @Published public private(set) var streamSession: VideoStreamSession?
    @Published public private(set) var streamMode: StreamMode = .remux
    @Published public private(set) var streamAudioIndex = 0
    @Published public private(set) var isRestartingStream = false

    /// 当前条目的播放钩子（影院 / 目录），由播放页在载入前注入。
    public private(set) weak var hooks: PlaybackHooks?
    public private(set) var currentPhotoID: UUID?
    /// 播放模式：直播跳过续播、片头片尾、剩余预热与进度写回。
    /// 由播放页在 `beginItem` 后设置；默认点播，保持旧行为不变。
    public var playbackMode: PlaybackMode = .vod
    /// 本次起播是否用了续播位置：片头识别据此决定是否再跳。
    public private(set) var resumeApplied = false
    /// 音频延迟（秒）：正值音频延后、负值提前。调整后需要重建一次流。
    public var audioDelay: Double = 0
    /// 是否允许把多条音轨装进同一会话（关闭后切轨仍会重建流）。
    public var prefersMultiAudio = true
    /// 长时间卡死且分片充足时的兜底：由播放页重建一次流（目标秒数）。
    /// AVPlayer 偶发进入无法自愈的等待状态，重新装片是唯一可靠的恢复方式。
    public var onHardStall: (@MainActor (Double) -> Void)?
    /// 直连播放（没有本地 HLS 会话）卡住时的兜底入口：目标秒数。
    /// 网盘直链基本只有一条连接，被 CDN 限速时播放器怎么等都等不到数据；
    /// 播放页收到后改用 ffmpeg 转封装，由本地 Range 代理并发预取。
    public var onNativeStall: (@MainActor (Double) -> Void)?

    private var pendingResume: Double?
    private var resumeAttempted = false
    private var resumeAttempts = 0
    private var resumeRetryAt = Date.distantPast
    private var introApplied = false
    private var outroApplied = false
    private var nearEndSent = false
    private var lastProgressSavedAt = Date.distantPast
    private var progressCancellable: AnyCancellable?
    private var pendingRestartTarget: Double?
    private var trimTask: Task<Void, Never>?
    /// 缓冲诊断：记录卡住时长与「已生成分片领先播放位置多少秒」。
    private var stallBeganAt: Date?
    private var lastStallLogAt = Date.distantPast
    /// 播放器卡死时的自愈：轻推定位的次数与时间。
    private var lastNudgeAt = Date.distantPast
    private var nudgeCount = 0
    private var lastHeartbeatAt = Date.distantPast
    private var didEscalateStall = false
    private var stallTimer: AnyCancellable?
    /// 本次装片是否已由播放器报出音轨组（`onMediaOptionsLoaded` 回调置位）。
    private var mediaOptionsLoaded = false
    private var loadedAudioTrackCount = 0
    /// 起播阶段是否已经把前向缓冲从「短」升到档位设定。
    private var didUpgradeStartupBuffer = false
    /// 单音轨会话的判据：`AVPlayerItem.tracks` 里实际装了几条音轨。
    private var itemTracksLoaded = false
    private var loadedItemTrackCount = 0
    private var loadedItemAudioTrackCount = 0

    public init(engine: VideoPlayerModel, environment: PlaybackEnvironment) {
        self.engine = engine
        self.environment = environment
        bindProgress()
        // 音轨组读取完成是判断「直通是否真的出音轨」的唯一时机：这里只记结果，
        // 是否重建由 start 决定（不能在回调里直接起流，否则会和起流流程并发）。
        engine.onMediaOptionsLoaded = { [weak self] count in
            self?.mediaOptionsLoaded = true
            self?.loadedAudioTrackCount = count
        }
        // 单音轨 HLS 没有 audible 组：用播放项轨道数兜住「有画面没声音」。
        engine.onItemTracksLoaded = { [weak self] total, audio in
            self?.itemTracksLoaded = true
            self?.loadedItemTrackCount = total
            self?.loadedItemAudioTrackCount = audio
        }
        // 卡住时时间轴停止变化，Combine 的 tick 不会再触发：用独立计时器持续观察。
        stallTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.trackStall() }
    }

    /// 新片载入前重置播放钩子状态。
    public func beginItem(_ photoID: UUID, hooks: PlaybackHooks?) {
        self.hooks = hooks
        currentPhotoID = photoID
        pendingResume = nil
        resumeAttempted = false
        resumeApplied = false
        resumeAttempts = 0
        resumeRetryAt = .distantPast
        introApplied = false
        outroApplied = false
        nearEndSent = false
        lastProgressSavedAt = .distantPast
        audioDelay = 0
        didUpgradeStartupBuffer = false
    }

    /// 当前条目的续播位置：原生播放与边下边播共用同一来源。
    public var resumePosition: Double? {
        guard playbackMode != .live, let photoID = currentPhotoID else { return nil }
        return hooks?.resumePosition(for: photoID)
    }

    /// 续播是否来自「上次看到一半」的进度；片头起播不算。
    public var resumeIsProgress: Bool {
        guard playbackMode != .live, let photoID = currentPhotoID else { return false }
        return hooks?.hasResumeProgress(for: photoID) ?? false
    }

    /// 原生 AVPlayer 装片后用一次，把续播状态同步给片头 / 进度逻辑。
    public func markResumeApplied(_ applied: Bool) {
        resumeAttempted = true
        resumeApplied = applied
        pendingResume = nil
        if let photoID = currentPhotoID {
            hooks?.resumeConsumed(for: photoID)
        }
    }

    /// 在线片头识别拿到更准确的时间轴后，直接跳过去。
    public func requestIntroSkip(seconds: Double) {
        guard seconds > 0 else { return }
        introApplied = true
        engine.requestSeek(to: seconds)
    }

    /// 自然播放结束：交给钩子落盘并标记完成。
    public func notifyPlaybackFinished() {
        guard let photoID = currentPhotoID, let hooks else { return }
        hooks.playbackFinished(photoID: photoID,
                               position: engine.duration,
                               duration: engine.duration)
    }

    private func bindProgress() {
        progressCancellable = engine.$duration
            .combineLatest(engine.$currentTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration, current in
                guard let self else { return }
                self.refreshBufferedEnd()
                self.upgradeStartupBufferIfNeeded()
                self.handleTick(current: current, duration: duration)
            }
    }

    /// 起播先用短缓冲把画面放出来，播放真正开始后再拉到档位设定。
    /// 16 秒的前向缓冲会让 AVPlayer 先攒够数据才起播，云端 4K 上就是好几秒的黑屏。
    private func upgradeStartupBufferIfNeeded() {
        guard !didUpgradeStartupBuffer, engine.isPlaying else { return }
        didUpgradeStartupBuffer = true
        engine.setForwardBufferDuration(environment.bufferProfile.forwardBufferDuration)
    }

    /// 缓冲段取「已生成区间末尾」与 AVPlayer 自身已加载范围的较大值：
    /// HLS 是边转边播，播放器只缓冲几秒，而 ffmpeg 已经写好的分片都能直接跳。
    private func refreshBufferedEnd() {
        let end = max(engine.bufferedTime, streamSession?.generatedEndSeconds ?? 0)
        guard end.isFinite, end >= 0 else { return }
        engine.setGeneratedEnd(end)
    }

    /// 缓冲诊断：区分「播放器没在请求」和「ffmpeg 还没生成」。
    /// 日志里带领先秒数，用户反馈卡住时能直接判断是服务问题还是转码太慢。
    private func trackStall() {
        let now = Date()
        let ahead = (streamSession?.generatedEndSeconds ?? 0) - engine.currentTime
        guard engine.wantsPlayback, engine.isBuffering else {
            stallBeganAt = nil
            nudgeCount = 0
            didEscalateStall = false
            // 正常播放时每 10 秒留一条心跳：能直接看出时间轴是否还在前进。
            if engine.wantsPlayback, streamSession != nil,
               now.timeIntervalSince(lastHeartbeatAt) >= 10 {
                lastHeartbeatAt = now
                environment.record("播放心跳 pos=\(Int(engine.currentTime))s 领先=\(Int(ahead))s")
            }
            return
        }
        if stallBeganAt == nil { stallBeganAt = now }
        guard let began = stallBeganAt else { return }
        let stalled = now.timeIntervalSince(began)

        // 直连播放（没有本地 HLS 会话）卡住：网盘直链基本是单连接，容易被 CDN 限速
        // （实测 115 只有 ~327kbps，片源需要 856kbps）。这里不再干等，
        // 交给播放页改用转封装 —— Range 代理会并发预取，吞吐通常是单连接的数倍。
        if stalled >= 8, streamSession == nil, !didEscalateStall, !engine.isSeeking {
            didEscalateStall = true
            environment.record("直连播放卡住 \(Int(stalled))s，改用本地转封装（并行预取）")
            onNativeStall?(engine.currentTime)
        }

        // 分片明明已经就绪，播放器却长时间不前进：轻推一次目标时间重新触发解码。
        if stalled >= 12, ahead >= 8, nudgeCount < 3,
           now.timeIntervalSince(lastNudgeAt) >= 10 {
            lastNudgeAt = now
            nudgeCount += 1
            environment.record("播放器卡住 \(Int(stalled))s：已生成领先 \(Int(ahead))s，重新定位一次")
            engine.nudgePlayback()
        }

        guard stalled >= 5, now.timeIntervalSince(lastStallLogAt) >= 10 else { return }
        lastStallLogAt = now
        environment.record("缓冲等待 \(Int(stalled))s：已生成领先 \(Int(ahead))s · "
                           + "mode=\(streamMode == .transcode ? "transcode" : "remux") · "
                           + engine.diagnosticSnapshot())

        // 轻推无效、分片又很充足：交给播放页重建一次流。
        // 10 秒就重建：实测卡死时生成早已领先几分钟，继续等 40 秒只会让用户干瞪眼。
        if stalled >= 10, ahead >= 30, !didEscalateStall, streamSession != nil {
            didEscalateStall = true
            environment.record("卡住超过 10s 且分片充足，重建流恢复播放")
            onHardStall?(engine.currentTime)
        }
    }

    private func handleTick(current: Double, duration: Double) {
        trackStall()
        // 直播没有有限时长：续播、片头片尾、剩余预热与进度写回都不适用。
        guard playbackMode != .live else { return }
        guard let photoID = currentPhotoID, let hooks else { return }

        // 续播重试：云盘起流前 seek 可能暂时无效，最多重试 8 次、每秒一次。
        // 必须要求 current > 3：重建流时 engine.load 会把 currentTime 重置为 0，
        // 若用 0 去比较续播点，会把「刚拖到的远端位置」误判成没跳成功，又拉回片头。
        if let pending = pendingResume, duration > 0, current > 3 {
            if abs(current - pending) < 4 {
                pendingResume = nil
                resumeAttempts = 0
            } else if current < pending - 4,
                      pending > 3,
                      pending < duration - 3,
                      resumeAttempts < 8,
                      Date().timeIntervalSince(resumeRetryAt) > 1 {
                resumeAttempts += 1
                resumeRetryAt = Date()
                engine.requestSeek(to: pending)
            } else if pending >= duration - 3 {
                pendingResume = nil
            }
        }

        guard duration > 0, current > 3 else { return }

        // 片头：只在没有续播、且还没超过片头时自动跳过。
        let intro = hooks.introSeconds(for: photoID)
        if intro > 0, !introApplied, !resumeApplied,
           current > 1, current < intro - 2, current < 120 {
            introApplied = true
            engine.requestSeek(to: intro)
        }

        // 片尾：进入设定区间直接跳到结尾并标记看完。
        let outro = hooks.outroSeconds(for: photoID)
        if outro > 0, !outroApplied, current > 30, duration - current <= outro {
            outroApplied = true
            engine.requestSeek(to: duration - 0.4)
            hooks.playbackFinished(photoID: photoID, position: duration, duration: duration)
        }

        // 剩余 5 分钟开始预热下一集 / 下一部。
        if !nearEndSent, duration - current <= 300 {
            nearEndSent = true
            hooks.playbackNearEnd(photoID: photoID)
        }

        let now = Date()
        guard now.timeIntervalSince(lastProgressSavedAt) > 10 else { return }
        lastProgressSavedAt = now
        hooks.playbackProgress(photoID: photoID, position: current, duration: duration)
    }

    // MARK: - 查询

    public var retainedStartSeconds: Double {
        streamSession?.retainedStartSeconds ?? 0
    }

    /// 当前会话是否已包含多条音轨：是则切换音轨只需让 AVPlayer 换轨，不用重建 ffmpeg。
    public var isMultiAudio: Bool {
        streamSession?.isMultiAudio ?? false
    }

    public var isCompleteCache: Bool {
        streamSession?.isCompleteCache ?? false
    }

    /// 当前会话内 seek 是否会命中已生成 / 已保留区间。
    public func seekDecision(target: Double) -> SeekPlanner.Decision {
        guard let stream = streamSession else { return .inSession }
        // 用 ffmpeg 已生成的分片末尾，而不是 AVPlayer 几秒的加载窗口：
        // 浅色缓冲段画到哪里，就应该能直接跳到哪里。
        return SeekPlanner.decide(target: target,
                                  retainedStart: stream.retainedStartSeconds,
                                  generatedEnd: stream.generatedEndSeconds,
                                  isCompleteCache: stream.isCompleteCache)
    }

    // MARK: - 起流

    /// 起流；转封装失败时自动降级为重编码 H.264。
    public func start(_ context: PlaybackStreamContext) async -> PlaybackStreamOutcome {
        let startedAt = Date()
        engine.setGeneratedEnd(0)
        var mode = context.preferredMode
        // 烧录字幕必须重编码，不能沿用 remux。
        if context.burnSubtitle != nil || context.burnSubtitleStream != nil { mode = .transcode }
        var attempt = 0
        /// 直通兜底：AC-3 / E-AC-3 直通或 DTS→AC-3 编码后，播放器可能一条音轨都读不到，
        /// 表现为「有画面没声音」。只兜底一次，之后强制用 AAC 重编码。
        var audioFallbackUsed = false
        /// 首次算出的起播位置：兜底重建时要沿用，不能把续播点丢掉。
        var appliedStartAt: Double?
        while attempt < 2 {
            let audioChannels = context.audioTracks.first(where: { $0.ordinal == context.audioIndex })?.channels
                ?? context.audioTracks.first?.channels ?? 2
            let audioCodec = context.audioTracks.first(where: { $0.ordinal == context.audioIndex })?.codec
                ?? context.audioTracks.first?.codec
            let session = VideoStreamSession(
                environment: environment,
                photoID: context.photoID,
                source: context.sourceURL,
                headers: context.headers,
                trustSelfSigned: context.trustSelfSigned,
                mode: mode,
                startOffset: context.offset,
                isHEVC: context.isHEVC,
                isHDR: context.isHDR,
                color: context.color,
                sourceSize: context.size,
                frameRate: context.frameRate,
                isInterlaced: context.isInterlaced,
                angle: context.angle,
                audioIndex: context.audioIndex,
                audioChannels: audioChannels,
                audioCodec: audioCodec,
                audioTracks: prefersMultiAudio ? context.audioTracks : [],
                audioDelay: audioDelay,
                audioDownmix: context.audioDownmix,
                transcodeMode: context.transcodeMode,
                preserveHDR: context.preserveHDR,
                audioPassthrough: !audioFallbackUsed,
                burnSubtitle: context.burnSubtitle,
                burnSubtitleStream: context.burnSubtitleStream,
                cacheSignature: context.cacheSignature,
                isLive: context.isLive,
                refreshSource: context.refreshSource)
            do {
                // 起流要做目录清理、拉起 ffmpeg、等服务写首段：全部是阻塞操作，
                // 放后台执行，否则打开视频的瞬间界面会停住。
                let starting = Task.detached(priority: .userInitiated) {
                    try await session.start()
                }
                let playlist = try await withTaskCancellationHandler {
                    try await starting.value
                } onCancel: {
                    starting.cancel()
                }
                guard context.isCurrent() else {
                    session.stop()
                    return .cancelled
                }
                adopt(session, mode: mode, audioIndex: context.audioIndex)
                // 会话会把读取位置对齐到关键帧：时间轴以对齐点为 0，再前跳到目标。
                let base = session.playbackStartOffset
                // 首次起播才向钩子要续播位置；后续重建流只认调用方给的目标。
                if appliedStartAt == nil {
                    if context.isLive {
                        // 直播没有续播：不查进度、不前跳。
                        pendingResume = nil
                        resumeAttempts = 0
                        appliedStartAt = nil
                    } else if !resumeAttempted {
                        appliedStartAt = context.resumeAt ?? hooks?.resumePosition(for: context.photoID)
                        resumeAttempted = true
                        resumeApplied = resumeIsProgress && (appliedStartAt ?? 0) > 3
                        pendingResume = appliedStartAt
                        hooks?.resumeConsumed(for: context.photoID)
                    } else {
                        // 重建流：目标由调用方显式给出，不再拿首次续播点做重试。
                        pendingResume = nil
                        resumeAttempts = 0
                        appliedStartAt = context.resumeAt
                    }
                }
                var probe = VideoProbe()
                probe.hasVideoTrack = true
                probe.isPlayable = true
                probe.duration = context.duration
                probe.size = context.size
                mediaOptionsLoaded = false
                loadedAudioTrackCount = 0
                itemTracksLoaded = false
                loadedItemTrackCount = 0
                loadedItemAudioTrackCount = 0
                engine.load(url: playlist, probe: probe, autoplay: context.autoplay,
                            loop: context.loop, muted: context.muted,
                            timelineOffset: base,
                            startAt: appliedStartAt,
                            // 起播只用短缓冲，播放开始后再由 upgradeStartupBufferIfNeeded 拉到档位设定。
                            forwardBufferDuration: min(4, environment.bufferProfile.forwardBufferDuration))
                didUpgradeStartupBuffer = false
                // 直通 / AC-3 会话可能「有画面没声音」：多音轨看 audible 组，
                // 单音轨 HLS 没有 audible 组，改看 AVPlayerItem.tracks 实际装了几条音轨。
                if !audioFallbackUsed, !context.audioTracks.isEmpty,
                   shouldVerifyAudio(context, mode: mode, codec: audioCodec, channels: audioChannels) {
                    let missingAudio: Bool
                    if session.isMultiAudio {
                        let count = await waitForAudioTrackCount()
                        missingAudio = mediaOptionsLoaded && engine.isItemReady && count == 0
                    } else {
                        await waitForItemTracks()
                        missingAudio = itemTracksLoaded && engine.isItemReady
                            && loadedItemTrackCount > 0 && loadedItemAudioTrackCount == 0
                    }
                    guard context.isCurrent() else {
                        session.stop()
                        return .cancelled
                    }
                    if missingAudio {
                        audioFallbackUsed = true
                        environment.record("播放器读不到音轨（源 \(context.audioTracks.count) 条 "
                                           + "codec=\(audioCodec ?? "-")），改为 AAC 重编码重建：\(context.title)")
                        // 先卸掉静音的 item：旧分片服务马上会被关掉，留着它会抛一个瞬时错误。
                        engine.stop()
                        session.stop()
                        continue
                    }
                }
                // 预热会话可能已挂起生成：装片后恢复，否则列表不再增长。
                session.setGenerationActive(true)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                let remote = context.sourceURL.isFileURL ? "本地" : "网盘"
                environment.record("首段就绪 \(context.title) \(remote) mode=\(mode) "
                                   + "offset=\(Int(context.offset)) 对齐=\(Int(base)) 用时 \(elapsed)ms")
                return .started
            } catch {
                session.stop()
                guard context.isCurrent() else { return .cancelled }
                // 网盘 / 网络失败：重编码也没用，直接暴露转码入口与错误原因。
                if session.failureIsSource {
                    return .failed(message: "边下边播启动失败：\(error.localizedDescription)",
                                   canTranscode: true)
                }
                if mode == .remux {
                    environment.record("转封装失败，降级为重编码：\(error.localizedDescription)")
                    mode = .transcode
                    attempt += 1
                    continue
                }
                // 色调映射（libplacebo / Vulkan 不可用）失败时退回无损转封装：
                // 颜色可能仍偏，但至少能播，不至于整个视频打不开。
                if context.burnSubtitle == nil, context.preferredMode == .transcode {
                    environment.record("色调映射失败，退回无损转封装：\(error.localizedDescription)")
                    mode = .remux
                    attempt += 1
                    continue
                }
                return .failed(message: "边下边播启动失败：\(error.localizedDescription)",
                               canTranscode: true)
            }
        }
        return .failed(message: "边下边播启动失败", canTranscode: true)
    }

    /// 该会话的音频是否走「直通 / DTS→E-AC-3」这类播放器可能读不出来的分支。
    /// 已经是 AAC 的会话再退回 AAC 也不会变，不必多等那几秒。
    private func shouldVerifyAudio(_ context: PlaybackStreamContext,
                                   mode: StreamMode,
                                   codec: String?,
                                   channels: Int) -> Bool {
        // 烧录字幕会强制重编码，但音频策略仍按真实分支判断（重编码模式不拷贝音频）。
        let effectiveMode: StreamMode =
            context.burnSubtitle == nil && context.burnSubtitleStream == nil ? mode : .transcode
        let copiesAudio = effectiveMode == .remux
            && StreamPlanner.shouldCopyAudio(codec: codec,
                                             channels: channels,
                                             downmix: context.audioDownmix,
                                             mode: effectiveMode,
                                             burnSubtitle: context.burnSubtitle,
                                             burnSubtitleStream: context.burnSubtitleStream,
                                             audioDelay: audioDelay)
        return copiesAudio || StreamPlanner.prefersEAC3(codec: codec, channels: channels)
    }

    /// 等播放器报出可选音轨数：直通 / AC-3 到底有没有出音轨，只有 AVPlayer 能回答。
    /// item 就绪后音轨组通常 1 秒内读完；最多等 4 秒，装片失败或取消时提前退出。
    private func waitForAudioTrackCount() async -> Int {
        for _ in 0..<40 {
            if mediaOptionsLoaded { return loadedAudioTrackCount }
            if Task.isCancelled || engine.errorMessage != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return mediaOptionsLoaded ? loadedAudioTrackCount : 0
    }

    /// 等播放项轨道读完：单音轨 HLS 没有 audible 组，只能看 `AVPlayerItem.tracks`。
    /// 播放器内部会观察 1–2 秒才下结论，这里留 6 秒余量。
    private func waitForItemTracks() async {
        for _ in 0..<60 {
            if itemTracksLoaded { return }
            if Task.isCancelled || engine.errorMessage != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 接管已经预热好的会话（下一集首段已生成）。
    public func adopt(_ session: VideoStreamSession,
                      mode: StreamMode = .remux,
                      audioIndex: Int = 0) {
        streamSession?.stop()
        session.onAdaptiveProfileChange = { [weak self] profile in
            Task { @MainActor [weak self] in
                self?.engine.setForwardBufferDuration(profile.forwardBufferDuration)
            }
        }
        streamSession = session
        streamMode = mode
        streamAudioIndex = audioIndex
        didUpgradeStartupBuffer = false
        startTrimLoop()
    }

    /// 切换音轨：先乐观更新菜单选中项，成功起流后会再次写入。
    public func previewAudioIndex(_ index: Int) {
        streamAudioIndex = index
    }

    // MARK: - 重建流

    /// 重建流的入口。连续调用时只保留最后一个目标，不会并发拉起多个 ffmpeg。
    /// `makeContext` 由播放页提供：负责解析最新直链并组装起流参数。
    public func restart(
        at target: Double,
        makeContext: @escaping @MainActor (Double) async -> PlaybackStreamContext?
    ) async -> PlaybackStreamOutcome {
        // 快进 / 拖动可能算出非有限值（进度条宽度为 0、时长异常等）：直接丢弃，
        // 不能拿 NaN 去起流或 seek，否则 AVPlayer 的时间轴会被污染。
        guard target.isFinite else { return .cancelled }
        if isRestartingStream {
            pendingRestartTarget = target
            return .queued
        }
        isRestartingStream = true
        // 旧会话的本地分片服务马上会被关掉：这段时间统一显示等待，不展示暂停或瞬时错误。
        engine.setReloading(true)
        pendingRestartTarget = nil
        let wasPlaying = engine.isPlaying
        engine.pause()
        var currentTarget = max(0, target)
        var last: PlaybackStreamOutcome = .cancelled
        var attempts = 0

        while true {
            // 连按 / 长按方向键时目标每 100ms 变一次：先等它安静下来，
            // 避免「拉起 ffmpeg → 立刻杀掉 → 再拉起」的抖动。
            // SMB / 4K 解码场景下这种抖动最容易把进程和本地服务拖进异常状态。
            guard await waitForSettledTarget(&currentTarget) else {
                last = .cancelled
                break
            }
            streamSession?.stop()
            streamSession = nil
            guard let context = await makeContext(currentTarget) else {
                last = .cancelled
                break
            }
            last = await start(context)
            if case .cancelled = last { break }

            attempts += 1
            // 重建期间又拖到了别处：只认最新位置，过期的目标直接丢掉。
            if let next = pendingRestartTarget, abs(next - currentTarget) > 0.75 {
                pendingRestartTarget = nil
                guard attempts < 12 else {
                    // 极端情况下（一直按住方向键）也要保证退出：
                    // 用最后一个目标起好的会话就是当前会话，剩余目标下次按键再处理。
                    break
                }
                currentTarget = next.isFinite ? max(0, next) : currentTarget
                continue
            }
            pendingRestartTarget = nil
            break
        }

        isRestartingStream = false
        engine.setReloading(false)
        if case .failed = last, wasPlaying {
            engine.seek(to: currentTarget)
            engine.play()
        }
        return last
    }

    /// 等待起流目标稳定：期间收到更新的目标就继续等，最多 0.6 秒。
    /// 返回 false 表示会话已被关闭（页面退出 / stop），调用方应直接结束。
    private func waitForSettledTarget(_ target: inout Double) async -> Bool {
        // 单次点击 / 单次拖动松手没有排队目标：直接起流，不为防抖白等 150ms。
        if pendingRestartTarget == nil { return isRestartingStream && !Task.isCancelled }
        var quietSince = Date()
        while Date().timeIntervalSince(quietSince) < 0.15 {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled || !isRestartingStream { return false }
            if let next = pendingRestartTarget, abs(next - target) > 0.75 {
                target = next.isFinite ? max(0, next) : target
                pendingRestartTarget = nil
                quietSince = Date()
            }
            if Date().timeIntervalSince(quietSince) > 0.6 { break }
        }
        return true
    }

    public func queueRestart(_ target: Double) {
        guard target.isFinite else { return }
        pendingRestartTarget = target
    }

    // MARK: - 生命周期

    public func setGenerationActive(_ active: Bool) {
        streamSession?.setGenerationActive(active)
    }

    public func stop() {
        trimTask?.cancel()
        trimTask = nil
        engine.setReloading(false)
        streamSession?.stop()
        streamSession = nil
        pendingRestartTarget = nil
        isRestartingStream = false
        streamMode = .remux
        streamAudioIndex = 0
    }

    /// 播放中每 3 秒滚动清理旧分片，并让生成提前量及时收敛。
    private func startTrimLoop() {
        trimTask?.cancel()
        trimTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, let stream = self.streamSession else { continue }
                stream.trim(before: self.engine.currentTime)
            }
        }
    }
}
