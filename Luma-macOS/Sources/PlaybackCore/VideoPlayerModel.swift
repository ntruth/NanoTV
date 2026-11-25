import AVFoundation
import AVKit
import Combine
import QuartzCore

/// 播放器装片失败的完整原因：错误域 / 错误码与用户可读文案。
/// `isIncompatibleAsset` 表示系统播放器认为编码 / 容器不兼容或媒体数据无法加载，
/// 重封装不会变好，只能转码。
public struct PlaybackFailure: Equatable, Sendable {
    public let domain: String?
    public let code: Int?
    public let message: String
    public let isIncompatibleAsset: Bool
    /// 底层 CoreMedia 错误里带出的 HTTP 状态码（例如直播源返回 403），非 HTTP 失败为 nil。
    public let httpStatus: Int?

    /// 从 `AVPlayerItem.error` 提取，沿 underlying error 链匹配已知的不兼容错误码。
    public init(error: NSError?, fallback: String) {
        var chain: [NSError] = []
        var current = error
        while let item = current, chain.count < 4 {
            chain.append(item)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // -12927 = kFigPlayerError_IncompatibleAsset；-11828 = AVErrorIncompatibleAsset；
        // -11829 = AVErrorFailedToLoadMediaData（码流无法解封装时实际更常见）。
        let incompatibleAsset = chain.contains {
            ($0.domain == "CoreMediaErrorDomain" && $0.code == -12927)
                || ($0.domain == "AVFoundationErrorDomain" && $0.code == -11828)
        }
        let unloadableMedia = chain.contains {
            $0.domain == "AVFoundationErrorDomain" && $0.code == -11829
        }
        self.domain = error?.domain
        self.code = error?.code
        self.isIncompatibleAsset = incompatibleAsset || unloadableMedia
        self.httpStatus = chain.lazy.compactMap(Self.httpStatus(in:)).first
        if incompatibleAsset {
            self.message = "系统播放器无法解码该视频的编码或 HDR 格式（\(error?.domain ?? "CoreMedia") \(error?.code ?? -12927)）。"
        } else if unloadableMedia {
            self.message = "系统播放器无法加载该视频的媒体数据（AVFoundation -11829），"
                + "可能是编码不受支持或分片损坏。"
        } else {
            let raw = error?.localizedDescription ?? fallback
            self.message = raw.isEmpty ? fallback : raw
        }
    }

    /// 从 CoreMedia 的错误描述里取 HTTP 状态码，例如
    /// `CoreMediaErrorDomain error -12660 - HTTP 403: Forbidden`。
    private static func httpStatus(in error: NSError) -> Int? {
        let text = error.localizedDescription
        guard let range = text.range(of: #"HTTP \d{3}"#, options: .regularExpression) else { return nil }
        return Int(text[range].drop { !$0.isNumber })
    }
}

/// AVPlayer 播放引擎：只负责「装片 → 播放 → 跳转 → 轨道选择 → 状态发布」。
/// 片源解析、ffmpeg 会话、进度落盘、UI 布局都不在这里。
public final class VideoPlayerModel: ObservableObject {
    public let player = AVPlayer()

    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var bufferedTime: Double = 0
    /// ffmpeg 已生成 / 已缓存到的末尾：HLS 边转边播时播放器只缓冲几秒，
    /// 进度条要画的是「已经写好、可以立即跳转」的区间。
    @Published public private(set) var generatedEndTime: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    /// 当前 AVPlayerItem 是否已经 readyToPlay。装上片子到出第一帧之间还有一段空窗，
    /// 这段时间界面必须显示等待动画，否则看起来就像「暂停了」。
    @Published public private(set) var isItemReady = false
    /// 跳转请求还没有落地：大文件 / 网络流拖进度条时要等一会儿。
    @Published public private(set) var isSeeking = false
    /// 用户意图是「要播放」：暂停时为 false。
    /// 缓冲等待也算播放中，否则中央会冒出播放按钮、控制条也会突然弹出来。
    @Published public private(set) var wantsPlayback = false
    @Published public private(set) var errorMessage: String?
    /// 最近一次装片失败的结构化原因：播放页据此判断能否自动转码兜底。
    @Published public private(set) var playbackFailure: PlaybackFailure?
    /// 正在重建底层流（重新起 ffmpeg）：旧 item 还挂着，但本地 HLS 服务已停，
    /// 这期间必须显示等待转圈，也不能把旧 item 的瞬时网络错误当成致命错误。
    @Published public private(set) var isReloading = false
    @Published public private(set) var isPipAvailable = false
    @Published public private(set) var isPipActive = false
    /// 可选音轨 / 内嵌字幕（AVFoundation 原生容器与 HLS 音轨组）。
    @Published public private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published public private(set) var selectedAudio: AVMediaSelectionOption?
    /// 播放项实际装上的轨道数（含视频）与音轨数：HLS 单音轨也可用。
    @Published public private(set) var itemTrackCount = 0
    @Published public private(set) var itemAudioTrackCount = 0
    @Published public private(set) var legibleOptions: [AVMediaSelectionOption] = []
    @Published public private(set) var selectedLegible: AVMediaSelectionOption?

    @Published public var speed: Double = 1
    @Published public var volume: Double = 1 {
        didSet { player.volume = Float(volume) }
    }
    @Published public var isMuted = false {
        didSet { player.isMuted = isMuted }
    }
    @Published public var isLooping = false
    /// 变速播放是否保持音调（频谱算法）。由播放页按设置注入，装片时生效。
    public var preservesPitch = true
    /// 媒体选项读取完成：参数是可选音轨数量。
    /// 播放编排用它检查「AC-3 直通后播放器到底有没有音轨」，为 0 时退回重编码。
    public var onMediaOptionsLoaded: ((Int) -> Void)?
    /// 播放项轨道读取完成：参数是（总轨数，音轨数）。
    /// 单音轨 HLS 没有 audible 组，只能用 `AVPlayerItem.tracks` 判断是否真的装了音轨。
    public var onItemTracksLoaded: ((Int, Int) -> Void)?

    /// 会话时间轴 ↔ 完整片源时间轴。
    private var timeline = PlaybackTimeline()
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var itemCancellables: Set<AnyCancellable> = []
    private var pipObservers: Set<AnyCancellable> = []
    private var endObserver: NSObjectProtocol?
    private weak var pipController: AVPictureInPictureController?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var pendingAutoplay = false
    /// 续播定位：装片后先 seek 到目标位置再开播，避免先播 0 秒再跳。
    private var pendingInitialSeek: Double?
    /// 定位完成前不让周期采样把时间轴改回 0，进度文字不会闪一下片头。
    private var suppressTimeUpdates = false
    /// 连续拖动时只认最后一次跳转：旧的 seek 回调不能把「跳转中」提前关掉。
    private var seekToken = 0
    /// 正在拖动进度条：这期间画面只做关键帧预览，时间轴不接受周期采样回写。
    private var isScrubbing = false
    /// 拖动预览跳转是否在途；配合 pendingScrubTarget 合并连续请求。
    private var scrubSeekInFlight = false
    private var pendingScrubTarget: Double?
    /// 兜底判定：周期采样里进度连续 1 秒不动就算卡住了（KVO 偶尔不报 waiting 状态）。
    private var lastSampleTime: Double = -1
    private var stalledSamples = 0
    /// 播放到结尾且未开启循环时回调，用于自动连播下一个视频。
    public var onPlaybackEnd: (@MainActor () -> Void)?
    /// 云盘流式播放的跳转路由：返回 true 表示调用方（播放页）已经重建了流，本次不再直接 seek。
    public var seekRouter: ((Double) -> Bool)?
    /// 拖动预览的可落帧范围：边下边播的 HLS 只允许在已生成区间内预览，
    /// 越界位置留给松手后的重建流程，否则画面会跳到生成末尾再弹回来。
    public var scrubGuard: ((Double) -> Bool)?

    /// 快进 / 快退的连按加速：同方向连续触发时按阶梯放大步长。
    private var seekAccelLevel = 0
    private var lastSeekAt = Date.distantPast
    private var lastSeekDirection = 0
    /// 上一跳的目标位置：网络资源重建流期间 currentTime 还停在旧位置，
    /// 连按要从上一跳的目标继续累加，否则每步都落在同一个点上。
    private var lastStepTarget: Double?
    /// 当前这次 seek 是否由连按发起：外部定位要重置连按基准。
    private var isStepSeeking = false
    private static let seekAccelSteps: [Double] = [1, 2, 3, 4, 6, 8]

    public init() {
        installTimeObserver()
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let waiting = status == .waitingToPlayAtSpecifiedRate
                // 「等待数据」仍然算播放中：只是画面暂时跟不上，不能当成暂停。
                self.isPlaying = status == .playing || waiting
                // 拖动期间播放器为落帧短暂进入等待是正常的，不能闪缓冲动画。
                self.isBuffering = waiting && !self.isScrubbing
                if status == .playing { self.isSeeking = false }
            }
            .store(in: &cancellables)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let item = note.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                if self.duration > 0 { self.currentTime = self.duration }
                if self.isLooping {
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.player.playImmediately(atRate: Float(self.speed))
                } else {
                    self.player.pause()
                    self.onPlaybackEnd?()
                }
            }
        }

        // 周期采样在暂停时不一定触发，用独立计时器兜住「停在 EVENT 列表末尾」的恢复。
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.resumeIfPausedUnexpectedly()
            }
            .store(in: &cancellables)
    }

    deinit {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                // 拖动期间画面只做关键帧预览，时间轴停在手指位置，不能被采样回写。
                if seconds.isFinite, !self.suppressTimeUpdates, !self.isScrubbing {
                    self.currentTime = self.timeline.absolute(local: seconds)
                    self.sampleStall(localSeconds: max(0, seconds))
                }
                guard let item = self.player.currentItem else { return }
                // 边下边播的 HLS 时长会随分片写入增长，取较大值更新进度条上限。
                let value = CMTimeGetSeconds(item.duration)
                if value.isFinite, value > 0 {
                    let total = self.timeline.absolute(local: value)
                    if total > self.duration { self.duration = total }
                }
                if let range = item.loadedTimeRanges.last?.timeRangeValue {
                    let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                    if end.isFinite {
                        let absolute = self.timeline.absolute(local: end)
                        let clamped = self.duration > 0 ? min(absolute, self.duration) : absolute
                        if clamped > self.bufferedTime { self.bufferedTime = clamped }
                    }
                }
            }
        }
    }

    /// AVPlayer 播到当前 EVENT 播放列表末尾会自己停下（rate 归零），但用户意图仍是播放。
    /// 新分片写好后它不会自动续播；这里按用户意图把它重新拉起来，
    /// 否则界面会停在「有缓冲却暂停」，只能手动点一次播放。
    private func resumeIfPausedUnexpectedly() {
        guard wantsPlayback, isItemReady, !isReloading, !isSeeking, !isScrubbing,
              errorMessage == nil, let item = player.currentItem,
              player.timeControlStatus == .paused else { return }
        // 以完整片长判断是否真的播完：HLS 的 item.duration 只到「已生成末尾」，
        // 在那里停下属于临时缓冲，必须重新拉起。
        if duration > 0 {
            guard currentTime < duration - 0.5 else { return }
        } else {
            let end = CMTimeGetSeconds(item.duration)
            if end.isFinite, end > 0, currentTime >= timeline.absolute(local: end) - 0.5 { return }
        }
        player.playImmediately(atRate: Float(speed))
    }

    /// 采样兜底：KVO 偶尔不会报「等待数据」，但进度停住是能直接看到的。
    /// 连续 4 个采样（约 1 秒）没前进就置为缓冲中；一旦重新前进立即恢复。
    private func sampleStall(localSeconds: Double) {
        let advanced = abs(localSeconds - lastSampleTime) >= 0.01
        lastSampleTime = localSeconds
        if advanced {
            stalledSamples = 0
            if isBuffering, player.timeControlStatus == .playing { isBuffering = false }
            return
        }
        guard wantsPlayback, isItemReady else {
            stalledSamples = 0
            return
        }
        // 片尾停在最后一帧不算卡顿。
        if duration > 0, currentTime >= duration - 0.6 {
            stalledSamples = 0
            return
        }
        stalledSamples += 1
        if stalledSamples >= 4 { isBuffering = true }
    }

    // MARK: - 装载

    public func load(url: URL, options: [String: Any] = [:], probe: VideoProbe,
                     autoplay: Bool = true, loop: Bool = false, muted: Bool = false,
                     timelineOffset: Double = 0, startAt: Double? = nil,
                     forwardBufferDuration: Double = BufferProfile.defaultProfile.forwardBufferDuration) {
        load(asset: AVURLAsset(url: url, options: options), probe: probe,
             autoplay: autoplay, loop: loop, muted: muted,
             timelineOffset: timelineOffset, startAt: startAt,
             forwardBufferDuration: forwardBufferDuration)
    }

    /// 直接装载 AVAsset：PhotoKit 返回的云端 / 共享相簿素材没有本地文件 URL。
    /// `startAt` 是完整时间轴上的起播秒数：装片后先定位再开播，不会先闪一下 0 秒。
    public func load(asset: AVAsset, probe: VideoProbe,
                     autoplay: Bool = true, loop: Bool = false, muted: Bool = false,
                     timelineOffset: Double = 0, startAt: Double? = nil,
                     forwardBufferDuration: Double = BufferProfile.defaultProfile.forwardBufferDuration) {
        resetForNewItem()
        timeline = PlaybackTimeline(sessionStart: timelineOffset)
        duration = probe.duration
        isLooping = loop
        isMuted = muted
        pendingAutoplay = autoplay
        if let startAt, startAt > timeline.sessionStart {
            pendingInitialSeek = startAt
            suppressTimeUpdates = true
            currentTime = startAt
        }

        let item = AVPlayerItem(asset: asset)
        // 前向缓冲由网络缓冲档位决定：流畅档 16 秒，弱网 / 省流档更短。
        item.preferredForwardBufferDuration = forwardBufferDuration
        observe(item)
        player.replaceCurrentItem(with: item)
        // 可能在订阅之后就已经 ready：补一次同步，避免等待动画一直不消失。
        isItemReady = item.status == .readyToPlay
        player.isMuted = isMuted
        player.volume = Float(volume)
    }

    public func stop() {
        player.pause()
        // 换片才算新起点；重建流会在同一个视频里重新 load，不能清掉连按加速。
        seekAccelLevel = 0
        lastSeekAt = .distantPast
        lastSeekDirection = 0
        lastStepTarget = nil
        isStepSeeking = false
        resetForNewItem()
        player.replaceCurrentItem(with: nil)
    }

    private func resetForNewItem() {
        errorMessage = nil
        playbackFailure = nil
        itemCancellables.removeAll()
        currentTime = 0
        bufferedTime = 0
        generatedEndTime = 0
        isBuffering = false
        isPlaying = false
        isItemReady = false
        isSeeking = false
        wantsPlayback = false
        seekToken &+= 1
        isScrubbing = false
        pendingScrubTarget = nil
        scrubSeekInFlight = false
        lastSampleTime = -1
        stalledSamples = 0
        pendingAutoplay = false
        pendingInitialSeek = nil
        suppressTimeUpdates = false
        timeline = PlaybackTimeline()
        audioOptions = []
        selectedAudio = nil
        itemTrackCount = 0
        itemAudioTrackCount = 0
        legibleOptions = []
        selectedLegible = nil
        audioGroup = nil
        legibleGroup = nil
    }

    private func observe(_ item: AVPlayerItem) {
        // 高倍速播放保持音调不变（0.25×～4× 都可用）：默认 timeDomain 在 2× 以上会明显失真。
        item.audioTimePitchAlgorithm = preservesPitch ? .spectral : .timeDomain
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.errorMessage = nil
                    // 到这里才真正有画面：之前一律按「还没准备好」显示等待动画。
                    self.isItemReady = true
                    let value = CMTimeGetSeconds(item.duration)
                    if value.isFinite, value > 0 {
                        let total = self.timeline.absolute(local: value)
                        if total > self.duration { self.duration = total }
                    }
                    self.refreshMediaOptions(for: item)
                    self.refreshItemTracks(for: item)
                    // 续播：先定位到目标帧，再开始播放，界面不会闪一下片头。
                    if let start = self.pendingInitialSeek {
                        self.pendingInitialSeek = nil
                        let local = self.timeline.local(absolute: start)
                        // 允许半秒误差：HLS 分片只能从关键帧起解，零容差会逼播放器先解完
                        // 前一整个 GOP 才出画面；这段时间里音频已经开唱，就成了「先有声音再有画面」。
                        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                        self.player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                                         toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                            DispatchQueue.main.async {
                                guard let self else { return }
                                self.suppressTimeUpdates = false
                                if self.pendingAutoplay {
                                    self.pendingAutoplay = false
                                    self.beginInitialPlayback()
                                }
                            }
                        }
                    } else if self.pendingAutoplay {
                        self.pendingAutoplay = false
                        self.beginInitialPlayback()
                    }
                case .failed:
                    let failure = PlaybackFailure(error: item.error.map { $0 as NSError },
                                                  fallback: "该视频无法播放")
                    self.playbackFailure = failure
                    self.errorMessage = failure.message
                    self.isItemReady = false
                    self.isBuffering = false
                    self.isSeeking = false
                default:
                    self.isItemReady = false
                }
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] empty in
                guard let self, let item, self.player.currentItem === item else { return }
                // 用「想播」判断，不能用 isPlaying：等待数据时它已经不是 .playing。
                if empty, self.wantsPlayback, !self.isScrubbing { self.isBuffering = true }
            }
            .store(in: &itemCancellables)

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] keepUp in
                guard let self, let item, self.player.currentItem === item else { return }
                if keepUp { self.isBuffering = false }
            }
            .store(in: &itemCancellables)
    }

    // MARK: - 播放控制

    public func play() {
        guard player.currentItem != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            // 从本段起点重新播：跳转会话的时间轴 0 对应会话起点。
            seek(to: timeline.sessionStart)
        }
        wantsPlayback = true
        player.playImmediately(atRate: Float(speed))
    }

    /// 装片后的首播：不用 playImmediately。
    /// playImmediately 会立刻把音频推出去，而视频轨还在解首帧；再加上缓冲只有几秒，
    /// 表现就是「先有声音、后有画面、然后再卡一下」。这里交给 AVPlayer 等缓冲就绪再起播。
    private func beginInitialPlayback() {
        guard player.currentItem != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: timeline.sessionStart)
        }
        wantsPlayback = true
        player.play()
    }

    public func pause() {
        wantsPlayback = false
        isBuffering = false
        player.pause()
    }

    public func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// 正式定位：播放中放宽到 0.1 秒容差（肉眼无感，但比精确 seek 快一个数量级），
    /// 暂停时精确落帧，保证截图与字幕对齐。
    public func seek(to seconds: Double) {
        // 没装片时 seek 不会回调 completion，先挡掉避免拖动状态卡住。
        guard player.currentItem != nil, seconds.isFinite else { return }
        // 外部定位（进度条 / 章节 / 续播）打断连按加速的累加基准。
        if !isStepSeeking { lastStepTarget = nil }
        // 落地完成前挂起周期采样：否则时间轴会先弹回旧位置再跳到目标，看起来像抖了一下。
        isScrubbing = true
        pendingScrubTarget = nil
        let target = timeline.clamp(seconds, duration: duration)
        currentTime = target
        let local = timeline.local(absolute: target)
        let tolerance: CMTime = wantsPlayback
            ? CMTime(seconds: 0.1, preferredTimescale: 600)
            : .zero
        seekToken &+= 1
        let token = seekToken
        isSeeking = true
        player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.seekToken else { return }
                self.isSeeking = false
                self.isScrubbing = false
                self.isBuffering = false
            }
        }
    }

    public func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    /// 按设置步长快进 / 快退：同方向连按（或长按的系统重复事件）逐级加速，
    /// 换方向或停手 1.2 秒后回到 1×。单次最多 10 分钟，避免一瞬间跳到片尾。
    public func seekStep(_ direction: Int, base: Double, isRepeat: Bool = false) {
        let now = Date()
        let gap = now.timeIntervalSince(lastSeekAt)
        // 长按的系统重复事件很密：加速到高档后限频，避免每一帧都跳一次。
        if isRepeat, gap < 0.12 { return }
        let accelerated = direction == lastSeekDirection && gap < 1.2
        if accelerated {
            seekAccelLevel = min(seekAccelLevel + 1, Self.seekAccelSteps.count - 1)
        } else {
            seekAccelLevel = 0
        }
        lastSeekAt = now
        lastSeekDirection = direction
        let multiplier = Self.seekAccelSteps[seekAccelLevel]
        let step = min(max(base, 1) * multiplier, 600)
        // 网络资源拖到未生成区间会重建流：这段时间 currentTime 还没跟上，
        // 从上一跳的目标继续累加，按住左右键才会真正加速。
        let origin = accelerated ? (lastStepTarget ?? currentTime) : currentTime
        guard origin.isFinite else { return }
        var target = origin + Double(direction) * step
        guard target.isFinite else { return }
        if duration > 0 {
            target = min(max(0, target), duration)
        }
        lastStepTarget = target
        isStepSeeking = true
        requestSeek(to: target)
        isStepSeeking = false
    }

    public func setSpeed(_ value: Double) {
        speed = value
        if isPlaying { player.rate = Float(value) }
    }

    public func stepFrame(by count: Int) {
        guard let item = player.currentItem else { return }
        if isPlaying { pause() }
        item.step(byCount: count)
    }

    // MARK: - 拖动预览

    /// 拖动进度条：只落到最近关键帧做预览，不触发精确解码。
    /// 精确 seek 要从关键帧一路解到目标帧，网络与大文件上会明显卡顿；
    /// 拖动只求「大概到这里」，松手后再做一次正式定位。
    public func scrub(to seconds: Double) {
        guard player.currentItem != nil, duration > 0, seconds.isFinite else { return }
        // 手动拖动是新的起点：连按加速不再沿用上一跳目标。
        lastStepTarget = nil
        let target = timeline.clamp(seconds, duration: duration)
        isScrubbing = true
        currentTime = target
        if let scrubGuard, !scrubGuard(target) { return }
        pendingScrubTarget = target
        // 已有在途请求时只更新目标，回调落地后会立刻追到最新位置。
        guard !scrubSeekInFlight else { return }
        performScrubSeek()
    }

    /// 取消拖动预览：只丢弃排队目标，在途请求由它的回调自行收尾。
    public func cancelScrub() {
        isScrubbing = false
        pendingScrubTarget = nil
    }

    private func performScrubSeek() {
        guard let target = pendingScrubTarget else {
            scrubSeekInFlight = false
            return
        }
        pendingScrubTarget = nil
        scrubSeekInFlight = true
        let local = timeline.local(absolute: target)
        player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                    toleranceBefore: .positiveInfinity,
                    toleranceAfter: .positiveInfinity) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pendingScrubTarget != nil {
                    self.performScrubSeek()
                } else {
                    self.scrubSeekInFlight = false
                }
            }
        }
    }

    // MARK: - 音轨 / 内嵌字幕

    /// 装载完成后读取可切换的音轨与内嵌字幕（HLS 只有音轨组）。
    private func refreshMediaOptions(for item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard let self, self.player.currentItem === item else { return }
            let group = try? await asset.loadMediaSelectionGroup(for: .audible)
            // await 期间可能已经换片 / 重建会话：旧 item 的音轨组不能写到新会话上，
            // 否则「音轨 0 条」的结论会被误当成新会话没有音频。
            guard self.player.currentItem === item else { return }
            if let group {
                self.audioGroup = group
                self.audioOptions = group.options
                self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: group)
            }
            // 直通兜底：音轨组为空时由播放编排决定是否重建成 AAC / AC-3。
            self.onMediaOptionsLoaded?(self.audioOptions.count)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard self.player.currentItem === item else { return }
            if let legible {
                self.legibleGroup = legible
                self.legibleOptions = legible.options
                self.selectedLegible = item.currentMediaSelection.selectedMediaOption(in: legible)
            }
        }
    }

    /// HLS 的 `item.tracks` 在 ready 之后才填好；单音轨会话没有 audible 组，
    /// 用这里的音轨数判断「音轨直通后是不是有画面没声音」。
    /// 首片音频包可能比视频晚就绪：只看到视频轨时至少观察 1 秒，避免把「还没解析出来」当成「没有音轨」。
    private func refreshItemTracks(for item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            guard let self, self.player.currentItem === item else { return }
            var emptyAudioSamples = 0
            for attempt in 0..<8 {
                // 每次重试都确认 item 还是当前这个：等 250ms 期间可能已经换了会话。
                guard self.player.currentItem === item else { return }
                let tracks = item.tracks.compactMap(\.assetTrack)
                if tracks.isEmpty {
                    // 全部 assetTrack 都还没解析出来时不要下结论，避免把「未知」当成「没有音轨」。
                    if attempt == 7 {
                        self.onItemTracksLoaded?(0, 0)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                let audio = tracks.filter { $0.mediaType == .audio }.count
                self.itemTrackCount = tracks.count
                self.itemAudioTrackCount = audio
                if audio > 0 {
                    self.onItemTracksLoaded?(tracks.count, audio)
                    return
                }
                // 只有视频轨：连续 4 次（约 1 秒）都读不到音频才回调，单次瞬时状态不触发重建。
                emptyAudioSamples += 1
                if emptyAudioSamples >= 4 || attempt == 7 {
                    self.onItemTracksLoaded?(tracks.count, 0)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    public func selectAudio(_ option: AVMediaSelectionOption?) {
        guard let group = audioGroup, let item = player.currentItem else { return }
        if let option {
            item.select(option, in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedAudio = option
    }

    /// 按菜单顺序切换音轨：HLS 多音轨会话里由 AVPlayer 即时换轨，不需要重建流。
    public func selectAudio(index: Int) {
        guard index >= 0, index < audioOptions.count else { return }
        selectAudio(audioOptions[index])
    }

    /// 当前选中音轨在 `audioOptions` 里的位置。
    public var currentAudioIndex: Int {
        guard let selectedAudio else { return 0 }
        return audioOptions.firstIndex(of: selectedAudio) ?? 0
    }

    public func selectLegible(_ option: AVMediaSelectionOption?) {
        guard let group = legibleGroup, let item = player.currentItem else { return }
        if let option {
            item.select(option, in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedLegible = option
    }

    // MARK: - 画中画

    public func attachPip(_ controller: AVPictureInPictureController?) {
        pipController = controller
        pipObservers.removeAll()
        guard let controller else {
            isPipAvailable = false
            isPipActive = false
            return
        }
        controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in
                self?.isPipAvailable = possible
            }
            .store(in: &pipObservers)

        controller.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isPipActive = active
            }
            .store(in: &pipObservers)
    }

    public func togglePip() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - 截图

    public func currentFrameImage() async -> CGImage? {
        guard let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = player.currentTime()
        guard let result = try? await generator.image(at: time) else { return nil }
        return result.image
    }

    /// 需要给用户看得见的等待动画：还没出画面，或真的卡在缓冲上。
    /// 跳转不参与判断：拖动 / 快进由目标帧直接接管，再闪一圈缓冲动画反而显得迟钝。
    public var isStalled: Bool {
        // 重建流期间旧 item 仍是 ready，但它依赖的本地分片服务已经停了：
        // 统一按「等待中」显示转圈，避免界面停在暂停按钮或闪一下错误。
        if isReloading { return player.currentItem != nil }
        guard errorMessage == nil, player.currentItem != nil else { return false }
        if isSeeking { return false }
        if !isItemReady { return true }
        return isBuffering && wantsPlayback
    }

    /// 由播放编排在重建流前后设置：只影响等待动画与瞬时错误，不动时间轴。
    public func setReloading(_ active: Bool) {
        isReloading = active
    }

    /// 由播放编排在每次时间轴刷新时同步：进度条浅色段画到这里。
    public func setGeneratedEnd(_ seconds: Double) {
        let value = max(0, seconds)
        guard abs(value - generatedEndTime) > 0.05 else { return }
        generatedEndTime = value
    }

    /// 网络自适应降档 / 升档时调整前向缓冲：只改缓冲目标，不打断当前播放。
    public func setForwardBufferDuration(_ seconds: Double) {
        guard seconds > 0, let item = player.currentItem else { return }
        guard abs(item.preferredForwardBufferDuration - seconds) > 0.1 else { return }
        item.preferredForwardBufferDuration = seconds
    }

    /// 进度条实际画出的缓冲末尾：播放器缓冲 + 已生成分片，取较大值。
    public var bufferedEndTime: Double {
        max(bufferedTime, generatedEndTime)
    }

    /// 还能退回多远：播放器报出的可 seek 区间起点（会话内时间）。
    /// 直播时移的「时间河」用它当河床起点，避免河随画面一起漂移。
    public var seekableStartTime: Double {
        guard let item = player.currentItem else { return 0 }
        let starts = item.seekableTimeRanges.compactMap { value -> Double? in
            let start = CMTimeGetSeconds(value.timeRangeValue.start)
            return start.isFinite ? start : nil
        }
        return max(0, starts.min() ?? 0)
    }

    /// 卡住时的一条完整状态快照：区分「播放器在等什么」和「本地服务没数据」。
    public func diagnosticSnapshot() -> String {
        let item = player.currentItem
        let itemStatus: String
        switch item?.status {
        case .readyToPlay: itemStatus = "ready"
        case .failed: itemStatus = "failed"
        case .unknown: itemStatus = "unknown"
        default: itemStatus = "none"
        }
        let ranges = item?.loadedTimeRanges.map { value -> String in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
            return String(format: "%.1f-%.1f", start, end)
        }.joined(separator: ",") ?? "-"
        // 可 seek 区间：和 loadedTimeRanges 一起看，才能判断「是没缓冲」还是「播放列表没更新」。
        let seekable = item?.seekableTimeRanges.map { value -> String in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
            return String(format: "%.1f-%.1f", start, end)
        }.joined(separator: ",") ?? "-"
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        // AVPlayer 自己报的位置（会话内时间）：和 ranges / seekable 同一坐标系，排查卡死最直接。
        let avSeconds = CMTimeGetSeconds(player.currentTime())
        let avTime = avSeconds.isFinite ? String(format: "%.1f", avSeconds) : "-"
        let control: String
        switch player.timeControlStatus {
        case .playing: control = "playing"
        case .paused: control = "paused"
        default: control = "waiting"
        }
        return "tc=\(control) rate=\(player.rate) wants=\(wantsPlayback) playing=\(isPlaying) "
            + "buffering=\(isBuffering) seeking=\(isSeeking) scrubbing=\(isScrubbing) "
            + "reload=\(isReloading) ready=\(isItemReady) item=\(itemStatus) "
            + "empty=\(item?.isPlaybackBufferEmpty ?? false) "
            + "keepUp=\(item?.isPlaybackLikelyToKeepUp ?? false) "
            + "ranges=[\(ranges)] seekable=[\(seekable)] av=\(avTime) "
            + "pos=\(String(format: "%.1f", currentTime)) "
            + "local=\(String(format: "%.1f", timeline.local(absolute: currentTime))) "
            + "base=\(String(format: "%.1f", timeline.sessionStart)) "
            + "dur=\(String(format: "%.1f", duration)) "
            + "waiting=\(waiting) err=\(item?.error?.localizedDescription ?? "-")"
    }

    /// AVPlayer 偶发卡在「等待数据」但实际分片已经就绪：轻推一下目标时间重新触发解码。
    public func nudgePlayback() {
        guard wantsPlayback, !isReloading, player.currentItem != nil else { return }
        let local = timeline.local(absolute: currentTime + 0.12)
        guard local.isFinite, local >= 0 else { return }
        player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.wantsPlayback else { return }
                self.player.playImmediately(atRate: Float(self.speed))
            }
        }
    }

    /// 设置页切换「高倍速保持音调」后立即作用到当前 item，不必重新装片。
    public func applyPitchPreference() {
        player.currentItem?.audioTimePitchAlgorithm = preservesPitch ? .spectral : .timeDomain
    }

    /// 界面上的跳转统一走这里：云盘未生成区间会触发重新起流。
    public func requestSeek(to seconds: Double) {
        // NaN / 无穷大会让时间轴与进度条布局一起坏掉，直接丢弃。
        guard seconds.isFinite else { return }
        cancelScrub()
        if let seekRouter, seekRouter(seconds) { return }
        seek(to: seconds)
    }
}
