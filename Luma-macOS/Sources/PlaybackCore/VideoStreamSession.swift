import Foundation

/// 完整 HLS 缓存的旁路清单：记录缓存的音轨结构与生成时的策略签名。
/// 命中缓存时不必重新解析远端，也能正确生成多音轨菜单与 master 入口。
public struct StreamCacheManifest: Codable, Equatable, Sendable {
    /// 清单 / 缓存布局版本：ffmpeg 参数或目录结构变化时在这里 +1。
    public static let currentVersion = 3
    public var version: Int
    public var isMultiAudio: Bool
    public var audioTracks: [AudioTrackInfo]
    /// 生成这份缓存时的播放策略签名；命中时必须与当前策略一致。
    public var cacheSignature: String
    /// 缓存是否为 HDR 输出：SDR 屏 / 强制映射时不能直接拿 HDR remux 缓存。
    public var isHDR: Bool
    /// 杜比视界缓存：没有 libplacebo 时无法映射，只能保持 HDR。
    public var isDolbyVision: Bool

    public init(version: Int = StreamCacheManifest.currentVersion,
                isMultiAudio: Bool,
                audioTracks: [AudioTrackInfo],
                cacheSignature: String = "",
                isHDR: Bool = false,
                isDolbyVision: Bool = false) {
        self.version = version
        self.isMultiAudio = isMultiAudio
        self.audioTracks = audioTracks
        self.cacheSignature = cacheSignature
        self.isHDR = isHDR
        self.isDolbyVision = isDolbyVision
    }
}

/// 边下载边转封装：ffmpeg 把远端（或本地）MKV 封成 fMP4 分片 HLS，
/// 由本机回环 HTTP 服务交给 AVPlayer。首段生成即可开播，不必等整部文件下载完。
/// 已完整转换过的结果留在图库 transcodes 目录，下次打开同一视频直接复用。
///
/// 网盘直链不走 ffmpeg 自带的 HTTP 客户端：先由 `RemoteRangeSource` 代理成本机可 Range 读取的地址，
/// 再交给 ffmpeg。这样既能复用 App 已验证过的请求头 / 302 / 证书策略，又允许按位置读取而不是只能从头顺序灌。
public final class VideoStreamSession {
    public typealias Mode = StreamMode

    /// 缓存键里的策略版本：转封装参数、分片布局、滤镜 / 画面策略或缓存判定规则变化时 +1。
    /// App 会把它拼进策略签名，旧缓存目录自然失效，不会命中旧结果。
    /// 改动 `StreamPlanner.arguments` 里任何会影响分片内容的参数时都要记得 +1。
    /// v4：缓存清单记录 HDR / 杜比视界，SDR 屏不再误用 HDR remux 缓存。
    /// v5：音频改为逐轨策略（直通 / AC-3 / AAC），并加入降混与转码编码签名。
    public static let cacheKeyVersion = 5

    /// 缓存目录 / 二进制 / 日志 / 缓存清理策略全部由 App 注入。
    private let environment: PlaybackEnvironment
    /// 完整转换结果的缓存目录（只有带 EXT-X-ENDLIST 的播放列表才会放进来）。
    private let cacheDirectory: URL
    /// 本次播放独占的工作目录：避免同一视频的两个会话互删中间文件。
    private let workDirectory: URL
    private let source: URL
    private let headers: [String: String]
    /// 挂载点勾选了「信任自签名证书」：URLSession 需要放行 NAS 的自签名证书。
    private let trustSelfSigned: Bool
    private let mode: Mode
    /// 从第几秒开始读取：用户拖到未生成区间时，用 -ss 重新起一个会话。
    private let startOffset: Double
    /// 实际起流位置（对齐到关键帧）：播放器时间轴从它开始，再由 startAt 前跳到目标位置。
    public private(set) var playbackStartOffset: Double = 0
    private let isHEVC: Bool
    private let isHDR: Bool
    /// 完整色彩管线：转封装写回容器，杜比视界还要靠它决定能否色调映射。
    private let color: VideoColorInfo
    /// 源画面尺寸与帧率：重编码时决定输出档位（4K60 这类高像素率会降档）。
    private let sourceSize: CGSize
    private let frameRate: Double
    /// 隔行源：重编码时用 bwdif 去隔行。
    private let isInterlaced: Bool
    /// 蓝光多角度视角（1 起）：只有 `bluray:` 输入才有意义，普通文件忽略。
    private let angle: Int
    /// 只映射这一条音轨；切换音轨时调用方会重新建会话。
    private let audioIndex: Int
    /// 全部音轨：多音轨会话一次映射完，切轨时由 AVPlayer 即时换。
    private let audioTracks: [AudioTrackInfo]
    /// 音频延迟（秒）：正值延后、负值提前，非 0 时音频必须重编码。
    private let audioDelay: Double
    /// 多声道输出方式：自动保留源声道，或强制降混成立体声。
    private let audioDownmix: AudioDownmixMode
    /// 重编码目标编码：H.264 兼容 / HEVC 高效 / HEVC 低功耗。
    private let transcodeMode: VideoTranscodeMode
    /// 重编码时保留 HDR（HDR 屏）：跳过色调映射，直接缩放到 HDR HEVC。
    private let preserveHDR: Bool
    /// 是否允许音轨直通。兜底会话为 false：一律重编码，且不复用 / 不写入只含直通结果的缓存。
    private let audioPassthrough: Bool
    /// 本次会话是否包含多条音轨（播放器侧可即时切换）。
    public private(set) var isMultiAudio = false
    /// 直播会话：源持续推送、没有完整时长，不落缓存，输入直接交给 ffmpeg。
    private let isLive: Bool
    /// 音轨声道数：>2 时给 AAC 更高码率，避免把 5.1 压得太狠。
    private let audioChannels: Int
    /// 选中音轨的编码（ffprobe 的展示名）。AAC / ALAC 可以直接拷进 fMP4，
    /// 省掉一次重编码，也彻底避开「精确裁剪音频」带来的偏移。
    private let audioCodec: String?
    /// 需要烧录的外挂字幕；有值时强制走重编码，并把字幕叠进画面。
    private let burnSubtitle: URL?
    /// 需要烧录的内嵌图形字幕轨（PGS / VobSub）；同样强制重编码。
    private let burnSubtitleStream: Int?
    /// 播放策略签名：进入缓存目录名，策略变化后不会命中旧缓存。
    private let cacheSignature: String
    /// 预热会话只负责出首段，不把半份音轨结构写进长期缓存。
    private let allowsCachePersistence: Bool
    /// 云盘直链过期时重新解析（由播放页提供）。
    private let refreshSource: (() -> (URL, [String: String])?)?

    private var process: Process?
    private var server: LocalHLSServer?
    private var rangeSource: RemoteRangeSource?
    private var logURL: URL?
    private let stateLock = NSLock()
    private var sourceFailure: String?
    /// 主动关闭会话时置位：ffmpeg 因收到 SIGTERM 退出属于预期行为，不再记录为转换失败。
    private var stopping = false
    /// ffmpeg 是否被暂停生成（播放器暂停时挂起进程，避免后台把整片转完）。
    private var generationPaused = false
    /// 进程当前是否真的处于 SIGSTOP。
    private var processStopped = false
    /// 当前保留的最小分片序号（播放中滚动清理）。
    private var minSegmentIndex = 0
    /// 最小保留分片对应的时间偏移（相对会话起点）。
    private var retainedOffset: Double = 0
    /// 已生成区间末尾（绝对秒）的缓存：进度条每 0.25 秒刷新，不能每次都解析 m3u8。
    private var cachedGeneratedEnd: Double = 0
    private var generatedEndSampleAt: Date = .distantPast
    /// 上次解析时播放列表的字节数：没长大就跳过解析。
    private var cachedPlaylistSize: Int = -1
    /// 实际提供给播放器的目录：命中缓存时是缓存目录，否则是工作目录。
    private var servingDirectory: URL
    private var usesCache = false
    /// 用户在设置里选的档位：自适应升档的上限。
    private let configuredProfile: BufferProfile
    /// 当前生效档位：网络变慢时会被临时降档，恢复后回到 `configuredProfile`。
    private var adaptiveProfile: BufferProfile
    private var adaptationState = BufferAdaptationState()
    /// Range 代理最近一次实测吞吐（bit/s）。
    private var lastThroughputBps: Double = 0
    /// 当前生成内容的平均码率估算（bit/s），按 10 秒采样一次。
    private var cachedOutputBitrate: Double = 0
    private var outputBitrateSampledAt: Date = .distantPast
    /// 自适应切换档位时通知播放器（用于调整前向缓冲）。
    public var onAdaptiveProfileChange: ((BufferProfile) -> Void)?

    public init(environment: PlaybackEnvironment,
                photoID: UUID, source: URL, headers: [String: String], trustSelfSigned: Bool = false,
                mode: Mode = .remux, startOffset: Double = 0, isHEVC: Bool = false,
                isHDR: Bool = false, color: VideoColorInfo = VideoColorInfo(),
                sourceSize: CGSize = .zero, frameRate: Double = 0,
                isInterlaced: Bool = false,
                angle: Int = 1,
                audioIndex: Int = 0, audioChannels: Int = 2,
                audioCodec: String? = nil,
                audioTracks: [AudioTrackInfo] = [],
                audioDelay: Double = 0,
                audioDownmix: AudioDownmixMode = .source,
                transcodeMode: VideoTranscodeMode = .compatibility,
                preserveHDR: Bool = false,
                audioPassthrough: Bool = true,
                burnSubtitle: URL? = nil,
                burnSubtitleStream: Int? = nil,
                cacheSignature: String = "",
                allowsCachePersistence: Bool = true,
                isLive: Bool = false,
                refreshSource: (() -> (URL, [String: String])?)? = nil) {
        self.environment = environment
        let profile = environment.bufferProfile
        self.configuredProfile = profile
        self.adaptiveProfile = profile
        self.cacheSignature = cacheSignature
        self.allowsCachePersistence = allowsCachePersistence
        self.isLive = isLive
        let base = environment.cacheDirectory
        self.cacheDirectory = base.appendingPathComponent(
            Self.cacheDirectoryName(photoID: photoID,
                                    burnSubtitle: burnSubtitle,
                                    signature: cacheSignature),
            isDirectory: true)
        // 工作目录带 `-session-`：启动时据此清理异常退出留下的中间产物。
        self.workDirectory = base.appendingPathComponent(
            photoID.uuidString + Self.burnSuffix(burnSubtitle) + "-session-" + UUID().uuidString + ".hls",
            isDirectory: true)
        self.servingDirectory = workDirectory
        self.source = source
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
        self.mode = mode
        self.startOffset = max(0, startOffset)
        self.playbackStartOffset = max(0, startOffset)
        self.isHEVC = isHEVC
        self.isHDR = isHDR
        self.color = color
        self.sourceSize = sourceSize
        self.frameRate = frameRate
        self.isInterlaced = isInterlaced
        self.angle = max(1, angle)
        self.audioIndex = max(0, audioIndex)
        self.audioTracks = audioTracks
        self.audioDelay = audioDelay
        self.audioDownmix = audioDownmix
        self.transcodeMode = transcodeMode
        self.preserveHDR = preserveHDR
        self.audioPassthrough = audioPassthrough
        self.isMultiAudio = StreamPlanner.usesMultipleAudioTracks(
            mode: mode,
            burnSubtitle: burnSubtitle,
            burnSubtitleStream: burnSubtitleStream,
            isHDR: isHDR,
            color: color,
            audioPassthrough: audioPassthrough,
            audioDelay: audioDelay,
            audioTracks: audioTracks)
        self.audioChannels = max(1, audioChannels)
        self.audioCodec = audioCodec
        self.burnSubtitle = burnSubtitle
        self.burnSubtitleStream = burnSubtitleStream
        self.refreshSource = refreshSource
    }

    private var playlistPath: URL {
        // 单参数 appendingPathComponent 会 lstat，这个路径在等首段时每 100ms 读一次。
        servingDirectory.appendingPathComponent(isMultiAudio ? "master.m3u8" : "live.m3u8",
                                                isDirectory: false)
    }

    /// 本地 / SMB 源不落长期缓存：源就在本地，重转很快，缓存只会白占磁盘。
    private var persistCache: Bool { !source.isFileURL }

    /// 只有「云端、完整、从 0 开始、默认音轨、无损转封装」的结果才值得写长期缓存。
    /// 从中间起流生成的是半截时间轴，不能当完整缓存保存。
    /// 隔行源要转码去隔行，remux 结果画面有梳齿，不能落缓存。
    private var canPersistCache: Bool {
        // 直播没有完整结束，永远不写长期缓存。
        !isLive
            // 没有策略签名时禁止写缓存：不同策略会生成不同分片，不能共用同一个目录。
            && !cacheSignature.isEmpty
            // 音频延迟靠滤镜实现，缓存里的音频是 0 延迟版本，不能复用也不能覆盖它。
            && abs(audioDelay) < 0.001
            && allowsCachePersistence && audioPassthrough
            && burnSubtitle == nil && burnSubtitleStream == nil && persistCache && mode == .remux
            && startOffset < 0.5 && audioIndex == 0 && !isInterlaced
    }

    /// 复用已有完整缓存的条件：缓存永远是从 0 生成的完整时间轴，
    /// 续播（startOffset > 0）也能直接拿它播放，再由播放器前跳到目标秒。
    private var canServeFromCache: Bool {
        guard !isLive,
              !cacheSignature.isEmpty,
              abs(audioDelay) < 0.001,
              audioPassthrough,
              burnSubtitle == nil, burnSubtitleStream == nil,
              persistCache, mode == .remux,
              audioIndex == 0, !isInterlaced else { return false }
        // 清单必须存在且策略签名一致：旧布局 / 旧参数生成的目录一律不复用。
        guard let manifest = Self.cachedManifest(at: cacheDirectory),
              manifest.cacheSignature == cacheSignature,
              manifest.isMultiAudio == isMultiAudio else { return false }
        return true
    }

    /// 已删除分片之前的起点（秒）：跳转到这之前需要重新起流。
    /// 现在播放中不再删分片，这个值等于会话起点，回退只受「已生成区间」限制。
    public var retainedStartSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playbackStartOffset + retainedOffset
    }

    /// 播放中只调整生成节奏，不再滚动删除分片。
    /// EVENT 列表只追加时 AVPlayer 最稳定；每次滚动删除都会让播放器重新对齐，
    /// 在 SMB / 慢盘上表现为「播一会儿卡一下」。分片在会话结束时随工作目录统一清理。
    public func trim(before seconds: Double) {
        guard !usesCache else { return }
        updateGenerationPacing(playback: seconds)
    }

    /// 是否在播放已经完整生成过的 HLS 缓存（整部片都可直接 seek）。
    public var isCompleteCache: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return usesCache
    }

    /// 多音轨时 master.m3u8 里没有分片时长，要读视频轨自己的列表。
    private var durationPlaylistPath: URL {
        servingDirectory.appendingPathComponent(isMultiAudio ? "live_0.m3u8" : "live.m3u8",
                                                isDirectory: false)
    }

    /// 已生成区间末尾（绝对秒）：进度条浅色段的终点，也是「不重建流就能跳过去」的上界。
    /// 进度条刷新比这里频繁，0.5 秒内复用上一次采样，避免每帧都解析播放列表。
    public var generatedEndSeconds: Double {
        let now = Date()
        stateLock.lock()
        let sampledAt = generatedEndSampleAt
        let cached = cachedGeneratedEnd
        let cachedSize = cachedPlaylistSize
        let offset = playbackStartOffset
        stateLock.unlock()
        if now.timeIntervalSince(sampledAt) < 0.5 { return cached }

        // 播放列表没长大就说明 ffmpeg 没写出新分片（常见于暂停 / 提前量触顶），
        // 不必每隔半秒把整份 m3u8 重新读进内存。
        let path = durationPlaylistPath
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size])
            .flatMap { ($0 as? NSNumber)?.intValue } ?? -1
        if size == cachedSize, size >= 0 {
            stateLock.lock()
            generatedEndSampleAt = now
            stateLock.unlock()
            return cached
        }

        let produced = Self.playlistDuration(path) ?? 0
        let end = produced.isFinite && produced > 0 ? offset + produced : offset
        stateLock.lock()
        cachedGeneratedEnd = end.isFinite ? end : cached
        cachedPlaylistSize = size
        generatedEndSampleAt = now
        stateLock.unlock()
        return cachedGeneratedEnd
    }

    private func currentMinSegmentIndex() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return minSegmentIndex
    }

    /// 预热会话专用：出首段后先停止生成，等真正开播时再恢复。
    /// 注意只用于「还没有播放器在读这个列表」的会话——播放中挂起 ffmpeg 会让
    /// EVENT 列表停更，AVPlayer 会报 -12888 并判定流结束（见 `updateGenerationPacing`）。
    public func setGenerationActive(_ active: Bool) {
        guard !usesCache, let process, process.isRunning else { return }
        stateLock.lock()
        generationPaused = !active
        stateLock.unlock()
        applyGenerationState()
    }

    /// 播放中只做网络自适应，**绝不把 ffmpeg 挂起（SIGSTOP）**。
    ///
    /// HLS 播放列表是 EVENT 类型，AVPlayer 会当直播处理：列表超过 1.5 × TARGETDURATION
    /// （约 16 秒）没有更新就报 `-12888 Playlist File unchanged`，并直接判定
    /// “end of all streams”，之后不再拉新分片；缓冲耗尽后必然卡在暂停态。
    /// 因此「提前量过大」不再挂起生成：让 ffmpeg 一直跑到片尾（会写满该集的工作目录，
    /// 会话结束时统一清理）。挂起只保留给用户主动暂停。
    private func updateGenerationPacing(playback seconds: Double) {
        guard let process, process.isRunning else { return }
        let offset = playbackStartOffset
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let produced = Self.playlistDuration(self.durationPlaylistPath) else { return }
            let ahead = produced + offset - seconds
            self.evaluateAdaptation(produced: produced, ahead: ahead)
        }
    }

    private var currentAdaptiveProfile: BufferProfile {
        stateLock.lock()
        defer { stateLock.unlock() }
        return adaptiveProfile
    }

    /// 远端播放时按实测吞吐与生成领先量调整档位；本地 / SMB 没有 Range 代理，直接跳过。
    private func evaluateAdaptation(produced: Double, ahead: Double) {
        guard environment.adaptiveBuffering, let rangeSource else { return }
        stateLock.lock()
        let throughput = lastThroughputBps
        let current = adaptiveProfile
        stateLock.unlock()
        guard throughput > 0, produced >= 5,
              let required = outputBitrate(produced: produced) else { return }

        stateLock.lock()
        let next = adaptationState.evaluate(current: current,
                                            ceiling: configuredProfile,
                                            throughputBps: throughput,
                                            requiredBps: required,
                                            leadSeconds: ahead)
        if let next { adaptiveProfile = next }
        stateLock.unlock()

        guard let next, next != current else { return }
        rangeSource.updateProfile(next)
        environment.record("网络自适应：\(current.title) → \(next.title) "
                           + "吞吐 \(Int(throughput / 1_000_000))Mbps "
                           + "目标 \(Int(required / 1_000_000))Mbps 领先 \(Int(ahead))s")
        onAdaptiveProfileChange?(next)
    }

    /// 用已生成分片的字节数 / 秒数估算当前内容码率，10 秒采样一次。
    private func outputBitrate(produced: Double) -> Double? {
        let now = Date()
        stateLock.lock()
        let cached = cachedOutputBitrate
        let sampledAt = outputBitrateSampledAt
        stateLock.unlock()
        if now.timeIntervalSince(sampledAt) < 10, cached > 0 { return cached }

        let bytes = Self.outputBytes(in: workDirectory)
        guard produced > 3, bytes > 0 else { return nil }
        let bitrate = Double(bytes) * 8 / produced
        stateLock.lock()
        cachedOutputBitrate = bitrate
        outputBitrateSampledAt = now
        stateLock.unlock()
        return bitrate
    }

    private static func outputBytes(in directory: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(Int64(0)) { total, url in
            let name = url.lastPathComponent
            guard name.hasPrefix("seg") || name.hasPrefix("init") else { return total }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// 把「用户暂停」意图转换成一次 SIGSTOP / SIGCONT。
    /// 播放中的提前量不再挂起生成：EVENT 列表停更会让 AVPlayer 判定流已结束。
    private func applyGenerationState() {
        guard !usesCache, let process, process.isRunning,
              process.processIdentifier > 1 else { return }
        stateLock.lock()
        let shouldStop = generationPaused
        guard processStopped != shouldStop else {
            stateLock.unlock()
            return
        }
        processStopped = shouldStop
        stateLock.unlock()
        // 进程可能在这几行之间退出：再确认一次，避免给复用后的 pid 发信号。
        guard process.isRunning, process.processIdentifier > 1 else { return }
        kill(process.processIdentifier, shouldStop ? SIGSTOP : SIGCONT)
        // 卡住排查最需要知道的一件事：ffmpeg 是被谁挂起的。
        environment.record(shouldStop ? "生成挂起（用户暂停）" : "生成恢复")
    }

    /// 是否已被主动关闭：起流是后台任务，stop() 可能在任意一步之间发生。
    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    /// 读播放列表里所有分片的时长总和：比按分片数估算准确，关键帧切分也不会偏。
    private static func playlistDuration(_ url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var total = 0.0
        var found = false
        for line in text.split(separator: "\n") where line.hasPrefix("#EXTINF:") {
            let value = line.dropFirst("#EXTINF:".count)
                .split(separator: ",", maxSplits: 1).first ?? ""
            if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) {
                total += seconds
                found = true
            }
        }
        return found ? total : nil
    }

    /// 失败是否来自网盘（鉴权 / 网络 / 非视频数据）：这类失败重编码也没用。
    public var failureIsSource: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sourceFailure != nil
    }

    /// 启动本地服务并返回可播放的 m3u8 地址；首次播放会等第一段分片就绪。
    public func start() async throws -> URL {
        guard !isStopping else { throw CancellationError() }
        if canServeFromCache, Self.isComplete(cacheDirectory) {
            usesCache = true
            // 缓存是完整时间轴（从 0 生成）：续播也以 0 为基准，播放器再前跳到目标秒。
            playbackStartOffset = 0
            servingDirectory = cacheDirectory
            // 按「最后一次播放」做 LRU，常用片不会被新片挤掉。
            environment.cache.touch(cacheDirectory)
            // 标记为使用中：容量清理 / 手动清空不能把这个目录删掉。
            environment.cache.markActive(cacheDirectory)
            environment.record("命中完整缓存 \(cacheDirectory.lastPathComponent)"
                               + " 起播 \(Int(startOffset))s 直接复用")
        } else {
            // 只有完整回放才复用/清理长期缓存；跳转或换音轨的临时会话不能动它。
            // 旧版本还给本地文件存过整部 HLS，这里一并清掉。
            if canPersistCache || !persistCache {
                let stale = cacheDirectory
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.removeItem(at: stale)
                }
            }
            try? FileManager.default.removeItem(at: workDirectory)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        }

        let server = LocalHLSServer(directory: servingDirectory)
        server.minSegmentIndexProvider = { [weak self] in
            guard let self else { return 0 }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            return self.minSegmentIndex
        }
        // 卡死排查需要知道播放器还在不在拉列表、分片是不是 404；正常分片不记录。
        server.onRequest = { [weak self] message in
            self?.environment.record(message)
        }
        let port = try server.start()
        // 起流期间页面可能已经关闭 / 又拖到了别处：这里必须检查，
        // 否则会在 stop() 之后又挂上一个没人负责的本地服务。
        stateLock.lock()
        let canceled = stopping
        if !canceled { self.server = server }
        stateLock.unlock()
        if canceled {
            server.stop()
            throw CancellationError()
        }
        if !usesCache {
            try launch()
            try await waitForPlaylist()
        }
        // 多音轨时真正的入口是 master.m3u8，各音轨是独立的 media playlist。
        // 之前统一返回 live.m3u8，多音轨会话会直接 404，表现为「刚播一下就停」。
        let entryName = isMultiAudio ? "master.m3u8" : "live.m3u8"
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(entryName)") else {
            stop()
            throw VideoError.transcodeUnavailable
        }
        return url
    }

    public func stop() {
        stateLock.lock()
        // 连续快进会反复重建会话：stop 必须幂等，重复 terminate 可能触发 Foundation 异常。
        guard !stopping else {
            stateLock.unlock()
            return
        }
        stopping = true
        let activeProcess = process
        let paused = processStopped
        process = nil
        stateLock.unlock()

        let wasServingCache = usesCache
        if wasServingCache {
            environment.cache.markInactive(cacheDirectory)
            usesCache = false
        }

        if !wasServingCache, activeProcess != nil,
           !FileManager.default.fileExists(atPath: playlistPath.path) {
            environment.record("边下边播会话提前结束（首段未生成）")
        }
        // 先让 ffmpeg 退出，再撤掉它的本地数据源：
        // 反过来的话 ffmpeg 会在已经被关闭的代理服务上继续读，产生无意义的报错。
        if let activeProcess, activeProcess.isRunning, activeProcess.processIdentifier > 1 {
            // 被 SIGSTOP 挂起的进程要先恢复，否则 SIGTERM 不会立即生效。
            if paused { kill(activeProcess.processIdentifier, SIGCONT) }
            activeProcess.terminate()
            // 滤镜链（libplacebo / Vulkan）偶发挂死，收到 SIGTERM 仍占住多核不放。
            // 2 秒还没退出就强制结束，避免停止播放后留下一个满负荷 ffmpeg。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if activeProcess.isRunning {
                    kill(activeProcess.processIdentifier, SIGKILL)
                }
            }
        }
        rangeSource?.stop()
        rangeSource = nil
        server?.stop()
        server = nil
        if let logURL {
            try? FileManager.default.removeItem(at: logURL)
            self.logURL = nil
        }
        // 命中缓存直接回放：缓存目录不归本会话所有，这里不能再做「把工作目录升级为缓存」的处理。
        guard !wasServingCache else { return }
        // 播放中删过旧分片的结果不完整，不能作为下次直接回放的缓存。
        if canPersistCache, currentMinSegmentIndex() == 0, Self.isComplete(workDirectory) {
            // 先写清单再挪目录：命中时根据它决定走 master.m3u8 还是 live.m3u8。
            writeCacheManifest(to: workDirectory)
            // 云端完整结果挪到缓存位置，下次直接回放；本地源不落缓存。
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.moveItem(at: workDirectory, to: cacheDirectory)
            environment.cache.trimIfNeeded()
        } else {
            // 没转完的中间产物留着也没法播；可能有好几 GB，放后台删。
            let stale = workDirectory
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    // MARK: - 内部

    /// 烧录字幕会改变画面，必须和普通缓存分开，否则会命中没有字幕的旧结果。
    private static func burnSuffix(_ burnSubtitle: URL?) -> String {
        burnSubtitle.map { "-burn-\(abs($0.path.hashValue))" } ?? ""
    }

    /// 缓存目录名 = 资源 ID + 烧录字幕标记 + 播放策略签名。
    /// 签名变化（HDR 策略、音轨模式、转封装参数版本）会落到不同目录，旧结果不会被误命中。
    private static func cacheDirectoryName(photoID: UUID,
                                           burnSubtitle: URL?,
                                           signature: String) -> String {
        let clean = sanitizeSignature(signature)
        let signaturePart = clean.isEmpty ? "" : "-\(clean)"
        return photoID.uuidString + burnSuffix(burnSubtitle) + signaturePart + ".hls"
    }

    /// 目录名只保留安全字符：策略签名来自设置组合，不允许带路径分隔符。
    private static func sanitizeSignature(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = raw.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars)
    }

    /// 该片在指定策略下是否已有完整 HLS 缓存：命中时不需要远端直链 / 探测就能起播。
    /// 必须同时满足「播放列表完整」与「清单策略签名一致」：
    /// 旧版本生成的无签名目录（`<photoID>.hls`）一律不算缓存，避免不同策略互相命中。
    public static func hasCompleteCache(environment: PlaybackEnvironment,
                                        photoID: UUID,
                                        burnSubtitle: URL? = nil,
                                        cacheSignature: String,
                                        requiresSDR: Bool = false,
                                        supportsLibplacebo: Bool = false) -> Bool {
        guard !cacheSignature.isEmpty else { return false }
        let directory = cacheDirectory(environment: environment,
                                       photoID: photoID,
                                       burnSubtitle: burnSubtitle,
                                       cacheSignature: cacheSignature)
        guard isComplete(directory),
              let manifest = cachedManifest(at: directory),
              manifest.cacheSignature == cacheSignature else { return false }
        guard requiresSDR else { return true }
        // 需要映射到 SDR 时，HDR remux 缓存不能用；杜比视界在没有 libplacebo 时
        // 本来也无法映射，退回原样反而是当前策略。
        if manifest.isHDR {
            return manifest.isDolbyVision && !supportsLibplacebo
        }
        return true
    }

    /// 读取缓存清单：多音轨缓存命中时用它恢复音轨菜单，不必重新探测远端。
    /// 清单缺失或签名不一致都返回 nil：调用方不能用别的策略生成的音轨结构。
    public static func cachedManifest(environment: PlaybackEnvironment,
                                      photoID: UUID,
                                      burnSubtitle: URL? = nil,
                                      cacheSignature: String) -> StreamCacheManifest? {
        guard !cacheSignature.isEmpty else { return nil }
        guard let manifest = cachedManifest(at: cacheDirectory(environment: environment,
                                                               photoID: photoID,
                                                               burnSubtitle: burnSubtitle,
                                                               cacheSignature: cacheSignature)) else {
            return nil
        }
        guard manifest.cacheSignature == cacheSignature else { return nil }
        return manifest
    }

    private static func cacheDirectory(environment: PlaybackEnvironment,
                                       photoID: UUID,
                                       burnSubtitle: URL?,
                                       cacheSignature: String) -> URL {
        environment.cacheDirectory.appendingPathComponent(
            cacheDirectoryName(photoID: photoID,
                               burnSubtitle: burnSubtitle,
                               signature: cacheSignature),
            isDirectory: true)
    }

    private static let manifestFileName = "manifest.json"

    private static func cachedManifest(at directory: URL) -> StreamCacheManifest? {
        let url = directory.appendingPathComponent(manifestFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(StreamCacheManifest.self, from: data),
              manifest.version == StreamCacheManifest.currentVersion else { return nil }
        return manifest
    }

    private func writeCacheManifest(to directory: URL) {
        let manifest = StreamCacheManifest(isMultiAudio: isMultiAudio,
                                           audioTracks: audioTracks,
                                           cacheSignature: cacheSignature,
                                           isHDR: isHDR || color.isDolbyVision,
                                           isDolbyVision: color.isDolbyVision)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.manifestFileName, isDirectory: false),
                        options: .atomic)
    }

    /// 完整缓存判定：单音轨看 live.m3u8，多音轨看 master 引用的各条 media playlist。
    /// 只有全部 media playlist 都写了 ENDLIST 才算真正转完。
    private static func isComplete(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        let playlists = names.filter { $0.hasSuffix(".m3u8") }
        guard !playlists.isEmpty else { return false }
        let mediaPlaylists = playlists.filter { $0 != "master.m3u8" }
        guard !mediaPlaylists.isEmpty else { return false }
        return mediaPlaylists.allSatisfy { name in
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("#EXT-X-ENDLIST")
        }
    }

    private func launch() throws {
        // HDR 屏 + HDR10 源：保留 HDR 只缩放，不跑色调映射（映射链只有 <1× 实时）。
        // 杜比视界必须靠 libplacebo 应用 RPU，仍走原来的映射路径。
        let keepsHDR = preserveHDR && (isHDR || color.isHDR) && !color.isDolbyVision
        let needsToneMap = mode == .transcode && (isHDR || color.isDolbyVision)
            && !keepsHDR && environment.supportsToneMapping
        // 杜比视界的 RPU 只能由 libplacebo 应用：没有它就别把错误的颜色烘进转码结果。
        let needsLibplacebo = needsToneMap && color.isDolbyVision && environment.supportsLibplacebo
        guard let ffmpeg = environment.executable(preferToneMap: needsToneMap,
                                                  preferLibplacebo: needsLibplacebo) else {
            throw VideoError.transcodeUnavailable
        }
        if keepsHDR, mode == .transcode {
            environment.record("重编码保留 HDR（不映射）："
                               + "primary=\(color.primaries ?? "bt2020") trc=\(color.transfer ?? "smpte2084")")
        }
        if needsToneMap {
            // 排查偏色时先看这条：HDR / DV 到底走了哪条映射链。
            let chain = needsLibplacebo ? "libplacebo"
                : (color.isDolbyVision ? "缺少 libplacebo，未映射" : "zscale")
            environment.record("HDR 色调映射：\(chain) "
                               + "dv=\(color.isDolbyVision) "
                               + "profile=\(color.dvProfile.map(String.init) ?? "-") "
                               + "primaries=\(color.primaries ?? "-") trc=\(color.transfer ?? "-")")
        }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let isRemote = !source.isFileURL
        var inputTarget: String
        if isRemote, isLive {
            // 直播流是持续推送、不可 Range 的：不套本地代理，直接把源地址交给 ffmpeg。
            inputTarget = source.absoluteString
        } else if isRemote {
            let proxy = RemoteRangeSource(upstream: source,
                                          headers: headers,
                                          trustSelfSigned: trustSelfSigned,
                                          cacheDirectory: workDirectory.appendingPathComponent("range-cache",
                                                                                              isDirectory: true),
                                          profile: environment.bufferProfile,
                                          log: environment.record)
            proxy.onFailure = { [weak self] message in
                self?.recordSourceFailure(message)
            }
            proxy.onAuthFailure = refreshSource
            proxy.onThroughput = { [weak self] bitsPerSecond in
                guard let self else { return }
                self.stateLock.lock()
                self.lastThroughputBps = bitsPerSecond
                self.stateLock.unlock()
            }
            let inputURL = try proxy.start()
            if isStopping {
                proxy.stop()
                throw CancellationError()
            }
            rangeSource = proxy
            inputTarget = inputURL.absoluteString
        } else {
            // 蓝光原盘交给 ffmpeg 的 bluray 协议：libbluray 负责播放列表与无缝分支。
            inputTarget = BluraySource.ffmpegInput(for: source) ?? source.path
        }

        // 视频流拷贝时 ffmpeg 只能从关键帧起流，音频却是解码后按目标时间精确裁剪的。
        // 两者一旦不一致，从第一帧起就差一个 GOP（跳片头 / 续播必现）。
        // 关掉 accurate_seek 让音轨也落在同一个关键帧，再用单帧探测拿到真实起点。
        let copiesVideo = StreamPlanner.copiesVideo(mode: mode, burnSubtitle: burnSubtitle,
                                                    burnSubtitleStream: burnSubtitleStream)
        let seeking = startOffset > 0.5

        if seeking {
            if copiesVideo {
                playbackStartOffset = Self.actualSeekStart(requested: startOffset,
                                                           input: inputTarget,
                                                           ffmpeg: environment.ffmpeg)
                    ?? startOffset
            } else {
                // 重编码时两轨都会被精确裁剪，保持原来的关键帧对齐即可。
                playbackStartOffset = Self.alignedKeyframe(before: startOffset,
                                                           input: inputTarget,
                                                           ffprobe: environment.ffprobe)
            }
        } else {
            playbackStartOffset = 0
        }
        if seeking, abs(playbackStartOffset - startOffset) > 0.2 {
            environment.record("起流对齐 \(Int(startOffset))s → \(Int(playbackStartOffset))s"
                               + (copiesVideo ? "（真实落点）" : "（关键帧）"))
        }

        let request = StreamRequest(input: inputTarget,
                                    isRemote: isRemote,
                                    mode: mode,
                                    startOffset: startOffset,
                                    sessionStart: playbackStartOffset,
                                    isHEVC: isHEVC,
                                    isHDR: isHDR,
                                    supportsToneMapping: environment.supportsToneMapping,
                                    supportsLibplacebo: environment.supportsLibplacebo,
                                    color: color,
                                    sourceSize: sourceSize,
                                    frameRate: frameRate,
                                    isInterlaced: isInterlaced,
                                    angle: angle,
                                    audioIndex: audioIndex,
                                    audioTracks: audioTracks,
                                    audioChannels: audioChannels,
                                    audioCodec: audioCodec,
                                    audioDelay: audioDelay,
                                    audioDownmix: audioDownmix,
                                    transcodeMode: transcodeMode,
                                    preserveHDR: preserveHDR,
                                    audioPassthrough: audioPassthrough,
                                    bufferProfile: environment.bufferProfile,
                                    burnSubtitle: burnSubtitle,
                                    burnSubtitleStream: burnSubtitleStream,
                                    outputDirectory: workDirectory,
                                    isLive: isLive,
                                    headers: headers)
        let arguments = StreamPlanner.arguments(for: request)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        // 内置 MoltenVK 的 ICD 路径通过环境变量交给 Vulkan loader。
        environment.apply(to: process)
        process.standardOutput = Pipe()
        // stderr 落到临时文件：失败时把最后几行写进诊断日志，便于定位 401 / 编码不支持。
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-ffmpeg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardError = logHandle ?? FileHandle.nullDevice
        self.logURL = logURL

        process.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            guard let self else { return }
            self.stateLock.lock()
            let intentional = self.stopping
            self.stateLock.unlock()
            guard !intentional,
                  finished.terminationReason == .exit,
                  finished.terminationStatus != 0 else { return }
            let tail = Self.tail(of: logURL)
            self.environment.record("边下边播转换异常结束 status=\(finished.terminationStatus)：\(tail)")
            // 这里不标记为「源失败」：编码器 / 滤镜 / 封装参数出错时，降级重编码仍可能成功。
            // 真正的网盘 / 鉴权失败由 RemoteRangeSource 通过 onFailure 第一时间记下。
        }
        try process.run()
        // 起流期间会话可能已经被关闭：不能再把进程挂到一个已经 stop 的会话上。
        stateLock.lock()
        let canceled = stopping
        if !canceled { self.process = process }
        stateLock.unlock()
        if canceled {
            process.terminate()
            try? FileManager.default.removeItem(at: logURL)
            self.logURL = nil
            throw CancellationError()
        }
    }

    /// 用与真正转封装完全相同的 seek 方式读一帧视频，得到 demuxer 的实际落点。
    /// `-noaccurate_seek` 下视频会退到请求点之前的关键帧，这个值才是播放器时间轴的真实 0 点。
    /// 失败 / 超时返回 nil，调用方退回请求值：音画仍然同步，只是落点可能差一个 GOP。
    private static func actualSeekStart(requested: Double, input: String, ffmpeg: URL?) -> Double? {
        guard let ffmpeg else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error",
            "-probesize", "2M", "-analyzeduration", "2M",
            "-noaccurate_seek",
            "-ss", String(format: "%.3f", requested),
            "-i", input,
            // 保留绝对时间戳：输出的第一行 pts 就是源文件里的真实时间。
            "-copyts",
            "-map", "0:v:0",
            "-c", "copy",
            "-frames:v", "1",
            "-f", "framecrc", "-"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        // 不读 stderr 时必须接 nullDevice，否则报错一多会写满管道、进程永久阻塞。
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // 与 alignedKeyframe 一致：网盘读区间偶尔很慢，最多等 4 秒。
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // framecrc 首行会声明时间基，例如 `#tb 0: 1/1000`。
        // 时间基是「分子/分母」：1/1000 表示 pts 每 1000 个单位是 1 秒。
        var timebase = 1.0 / 1000.0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("#tb 0:") {
                let parts = line.dropFirst("#tb 0:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: "/")
                if parts.count == 2, let numerator = Double(parts[0]),
                   let denominator = Double(parts[1]), numerator > 0, denominator > 0 {
                    timebase = numerator / denominator
                }
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            // framecrc 列：stream, dts, pts, duration, size, hash —— 取 pts。
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let pts = Double(fields[2].trimmingCharacters(in: .whitespaces)) else { continue }
            return max(0, pts * timebase)
        }
        return nil
    }

    /// 找目标位置之前最近的关键帧。最多往回看 15 秒，常规 GOP 足够覆盖；
    /// 探测失败或超时都退回目标位置，保持原来的行为。
    private static func alignedKeyframe(before target: Double, input: String, ffprobe: URL?) -> Double {
        guard let ffprobe else { return target }
        let windowStart = max(0, target - 15)
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_packets",
            "-show_entries", "packet=pts_time,flags",
            "-read_intervals", String(format: "%.3f%%%.3f", windowStart, target),
            "-of", "csv=p=0",
            input
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return target }

        // 网盘读区间偶尔很慢：最多等 4 秒，超时直接按目标位置起流。
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return target
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var keyframes: [Double] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ",")
            guard parts.count >= 2, parts[1].contains("K"),
                  let value = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  value >= 0, value <= target + 0.05 else { continue }
            keyframes.append(value)
        }
        guard let keyframe = keyframes.max(), target - keyframe < 15.05 else { return target }
        return keyframe
    }

    private func recordSourceFailure(_ message: String) {
        stateLock.lock()
        if sourceFailure == nil { sourceFailure = message }
        stateLock.unlock()
        environment.record("边下边播失败：\(message)")
    }

    private var currentSourceFailure: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sourceFailure
    }

    /// 等 ffmpeg 写出第一版播放列表（第一段分片完成后才会写）。
    /// 网盘限速时 4K 视频的首段可能要几十秒，这里每 5 秒记一次已写入字节，便于排查卡在下载还是卡在封装。
    /// 首段就绪后再多等一小段提前量：只给播放器 2 秒缓冲时，网络卷上的高码率片源几乎立刻耗尽，
    /// 表现就是「刚出画面就卡一下」。本地盘生成很快，这段等待几乎不增加起播时间。
    private func waitForPlaylist() async throws {
        var firstSegmentAt: Date?
        let leadTarget = startupLeadSeconds
        for index in 0..<1200 {
            try Task.checkCancellation()
            if isStopping { throw CancellationError() }
            // 文件刚创建时可能只有一个头部，没有分片：AVPlayer 会当成 0 秒的片子，
            // 播一下就停在开头。必须等到至少写出一段（或明确结束）再交给播放器。
            if Self.playlistHasSegments(durationPlaylistPath),
               !isMultiAudio || FileManager.default.fileExists(atPath: playlistPath.path) {
                if leadTarget <= 0 { return }
                if firstSegmentAt == nil { firstSegmentAt = Date() }
                let generated = Self.playlistDuration(durationPlaylistPath) ?? 0
                let waited = Date().timeIntervalSince(firstSegmentAt ?? Date())
                // 生成太慢时不无限等：最多多等 8 秒，先把播放器接上，后续靠卡顿自愈。
                if generated >= leadTarget || waited >= 8 {
                    if generated > 0 {
                        environment.record("起播缓冲 \(Int(generated))s / 目标 \(Int(leadTarget))s")
                    }
                    return
                }
            }
            if let process, !process.isRunning {
                let reason = currentSourceFailure ?? Self.tail(of: logURL)
                throw VideoError.transcodeFailedMessage(reason)
            }
            if index % 50 == 0 {
                let size = Self.directorySize(workDirectory)
                environment.record("边下边播等待首段：已写入 \(size / 1024) KB")
            }
            // 取消时直接抛出，避免 try? 吞掉 CancellationError 后空转。
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let size = Self.directorySize(workDirectory)
        let extra = currentSourceFailure.map { "：\($0)" } ?? ""
        throw VideoError.transcodeFailedMessage("等待首段超时，已写入 \(size / 1024 / 1024) MB\(extra)")
    }

    /// 起播前希望先攒下的生成量。
    /// 只攒 2–3 秒时，跳转后播放器出画面几秒就把缓冲耗尽，立刻「卡一下」；
    /// 音轨又比视频轨先就绪，观感是先有声、后有画面、再顿一下。
    /// 5 秒是「起播够快」与「第一跳不卡」的折中：本地盘生成是实时的数倍，通常只多等一秒。
    private var startupLeadSeconds: Double {
        switch currentAdaptiveProfile {
        case .thrifty: return 3
        case .balanced: return 4
        case .smooth: return 5
        }
    }

    /// 播放列表里已经有分片，才算真的可以交给播放器。
    private static func playlistHasSegments(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("#EXTINF") || text.contains("#EXT-X-ENDLIST")
    }

    /// 读取播放列表，算出第 index 个分片在会话内的起始秒数。
    private static func segmentStartTime(_ playlist: URL, index: Int) -> Double? {
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return nil }
        var elapsed: Double = 0
        var pendingDuration: Double?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTINF:") {
                let value = trimmed
                    .dropFirst("#EXTINF:".count)
                    .split(separator: ",")
                    .first
                    .flatMap { Double($0) }
                pendingDuration = value
                continue
            }
            guard trimmed.hasPrefix("seg"), trimmed.hasSuffix(".m4s"),
                  let value = Int(trimmed.dropFirst(3).dropLast(4)) else { continue }
            if value == index { return elapsed }
            elapsed += pendingDuration ?? 2
            pendingDuration = nil
        }
        return nil
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return items.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private static func tail(of url: URL?) -> String {
        guard let url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "无输出" }
        let lines = text.split(separator: "\n").suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty ? "无输出" : lines.joined(separator: " | ")
    }

    deinit {
        // 会话没走 stop() 时也要摘掉“使用中”标记，否则缓存永远不参与清理。
        if usesCache { environment.cache.markInactive(cacheDirectory) }
    }
}
