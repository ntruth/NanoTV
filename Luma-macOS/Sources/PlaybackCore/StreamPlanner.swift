import Foundation

/// 转封装模式：只换容器，或兼容兜底重编码。
public enum StreamMode: Equatable, Sendable {
    /// 只转封装（-c:v copy）：最快，H.264 / HEVC 等 AVPlayer 能解的编码走这条。
    case remux
    /// 转封装失败时降级为重编码 H.264，兼容 RealVideo / Theora 等编码。
    case transcode
}

/// 一次边下边播会话的完整参数。由 `VideoStreamSession` 计算出真实起流点后交给 `StreamPlanner`。
public struct StreamRequest {
    /// ffmpeg 的输入：本地路径，或本机 Range 代理地址。
    public var input: String
    /// 输入是否来自网络（决定 readrate）。
    public var isRemote: Bool
    public var mode: StreamMode
    /// 调用方请求的起流秒数（未对齐）。
    public var startOffset: Double
    /// 会话 0 点对应的片源秒数（真实落点 / 关键帧）。
    public var sessionStart: Double
    public var isHEVC: Bool
    public var isHDR: Bool
    public var supportsToneMapping: Bool
    /// 内置 ffmpeg 是否带 libplacebo：杜比视界的 RPU 只能由它应用。
    public var supportsLibplacebo: Bool
    /// 完整色彩管线：转封装原样写回容器，避免 HDR / DV 被当成 SDR 解码。
    public var color: VideoColorInfo
    /// 源画面尺寸与帧率：重编码时据此决定是否需要降档（像素率过高会跑不到实时）。
    public var sourceSize: CGSize
    public var frameRate: Double
    /// 隔行源：重编码前先 `bwdif` 去隔行（转封装无法处理，保持原样交给系统）。
    public var isInterlaced: Bool
    /// 蓝光多角度视角（1 起）。只有 `bluray:` 输入才有效，普通文件忽略。
    public var angle: Int
    /// 当前选中的音轨序号（单音轨模式用）。
    public var audioIndex: Int
    /// 全部音轨明细：多音轨会话会一次全部映射，切换时由 AVPlayer 即时换轨。
    public var audioTracks: [AudioTrackInfo]
    public var audioChannels: Int
    /// 选中音轨的编码（展示名），用于决定能否直接拷贝。
    public var audioCodec: String?
    /// 音频延迟（秒）：正值音频延后，负值音频提前。非 0 时音频必须重编码。
    public var audioDelay: Double
    /// 多声道输出方式：自动保留源声道，或强制降混成立体声。
    public var audioDownmix: AudioDownmixMode
    /// 重编码时的目标编码：H.264 兼容优先，或 HEVC 高效 / 低功耗。
    public var transcodeMode: VideoTranscodeMode
    /// 重编码时保留 HDR（输出 HDR10），而不是先做色调映射。
    /// HDR 屏上没必要映射：映射链（libplacebo）4K60 实测只有 <1× 实时，去掉后能到 1.5×。
    public var preserveHDR: Bool
    /// 网络缓冲档位：决定远端 readrate。
    public var bufferProfile: BufferProfile
    /// 是否允许音轨直通（copy）。AC-3 / E-AC-3 直通后若播放器读不到音轨，
    /// 播放编排会用 false 重建一次，强制重编码兜底。
    public var audioPassthrough: Bool
    public var burnSubtitle: URL?
    /// 要烧录的内嵌图形字幕轨（ffprobe 的 0:s:N 序号）。PGS / VobSub 无法转成文本，
    /// 只能在重编码时用 overlay 叠进画面。
    public var burnSubtitleStream: Int?
    /// HLS 分片与播放列表的输出目录。
    public var outputDirectory: URL
    /// 直播源：去掉 readrate、用滑动窗口分片，并把请求头交给 ffmpeg 的 HTTP 客户端。
    public var isLive: Bool
    /// 直播源要求的请求头（UA / Referer 等）。
    public var headers: [String: String]

    public init(input: String,
                isRemote: Bool,
                mode: StreamMode,
                startOffset: Double,
                sessionStart: Double,
                isHEVC: Bool,
                isHDR: Bool,
                supportsToneMapping: Bool,
                supportsLibplacebo: Bool = false,
                color: VideoColorInfo = VideoColorInfo(),
                sourceSize: CGSize = .zero,
                frameRate: Double = 0,
                isInterlaced: Bool = false,
                angle: Int = 1,
                audioIndex: Int,
                audioTracks: [AudioTrackInfo] = [],
                audioChannels: Int,
                audioCodec: String?,
                audioDelay: Double = 0,
                audioDownmix: AudioDownmixMode = .source,
                transcodeMode: VideoTranscodeMode = .compatibility,
                preserveHDR: Bool = false,
                audioPassthrough: Bool = true,
                bufferProfile: BufferProfile = .defaultProfile,
                burnSubtitle: URL?,
                burnSubtitleStream: Int? = nil,
                outputDirectory: URL,
                isLive: Bool = false,
                headers: [String: String] = [:]) {
        self.input = input
        self.isRemote = isRemote
        self.mode = mode
        self.startOffset = startOffset
        self.sessionStart = sessionStart
        self.isHEVC = isHEVC
        self.isHDR = isHDR
        self.supportsToneMapping = supportsToneMapping
        self.supportsLibplacebo = supportsLibplacebo
        self.color = color
        self.sourceSize = sourceSize
        self.frameRate = frameRate
        self.isInterlaced = isInterlaced
        self.angle = max(1, angle)
        self.audioIndex = audioIndex
        self.audioTracks = audioTracks
        self.audioChannels = audioChannels
        self.audioCodec = audioCodec
        self.audioDelay = audioDelay
        self.audioDownmix = audioDownmix
        self.transcodeMode = transcodeMode
        self.preserveHDR = preserveHDR
        self.audioPassthrough = audioPassthrough
        self.bufferProfile = bufferProfile
        self.burnSubtitle = burnSubtitle
        self.burnSubtitleStream = burnSubtitleStream
        self.outputDirectory = outputDirectory
        self.isLive = isLive
        self.headers = headers
    }
}

/// ffmpeg 参数的唯一构造点：音画同步、音频拷贝、多音轨、延迟、HDR 映射、切片策略都在这里收口。
public enum StreamPlanner {
    /// 可以直接拷进 fMP4 HLS、且 AVPlayer 原生支持的音轨编码。
    /// AC-3 / E-AC-3 已实测（5.1）：AVPlayer 对 fMP4 HLS 中的 `ac-3 / ec-3` 返回 readyToPlay 且音轨可见，
    /// 因此蓝光常见的 AC-3 轨道可以原样直通，省一次重编码并保住码率。
    public static let copyableAudioCodecs: Set<String> = AudioPlaybackPlan.copyableCodecs

    /// 视频流是否为拷贝（拷贝时 ffmpeg 只能从关键帧起流）。
    public static func copiesVideo(mode: StreamMode,
                                   burnSubtitle: URL?,
                                   burnSubtitleStream: Int? = nil) -> Bool {
        burnSubtitle == nil && burnSubtitleStream == nil && mode == .remux
    }

    public static func shouldCopyAudio(codec: String?,
                                       channels: Int = 2,
                                       downmix: AudioDownmixMode = .source,
                                       mode: StreamMode,
                                       burnSubtitle: URL?,
                                       burnSubtitleStream: Int? = nil,
                                       audioDelay: Double = 0,
                                       allowPassthrough: Bool = true) -> Bool {
        guard allowPassthrough else { return false }
        guard copiesVideo(mode: mode, burnSubtitle: burnSubtitle,
                          burnSubtitleStream: burnSubtitleStream) else { return false }
        // 延迟必须靠滤镜实现，滤镜要求解码重编码。
        guard abs(audioDelay) < 0.001 else { return false }
        return AudioPlaybackPlan.action(codec: codec,
                                        channels: channels,
                                        downmix: downmix,
                                        allowPassthrough: true,
                                        copiesVideo: true) == .copy
    }

    /// DTS-HD / TrueHD 这类 AVPlayer 无法解码的高码率多声道声轨：
    /// 重编码目标用 E-AC-3 1536k，比 AC-3 640k 保留更多细节（Atmos 对象层仍会丢弃）。
    public static func prefersEAC3(codec: String?, channels: Int) -> Bool {
        AudioPlaybackPlan.prefersEAC3(codec: codec, channels: channels)
    }

    /// 能否用「一个 HLS 会话装下所有音轨」：之后切换音轨只让 AVPlayer 换轨，不再重启 ffmpeg。
    /// 会话与参数构造共用这份判断，避免两边条件不一致（例如 HDR 退回单音轨后仍按 master 找片单）。
    public static func usesMultipleAudioTracks(for request: StreamRequest) -> Bool {
        usesMultipleAudioTracks(mode: request.mode,
                                burnSubtitle: request.burnSubtitle,
                                burnSubtitleStream: request.burnSubtitleStream,
                                isHDR: request.isHDR,
                                color: request.color,
                                audioPassthrough: request.audioPassthrough,
                                audioDelay: request.audioDelay,
                                audioTracks: request.audioTracks)
    }

    public static func usesMultipleAudioTracks(mode: StreamMode,
                                               burnSubtitle: URL?,
                                               burnSubtitleStream: Int?,
                                               isHDR: Bool,
                                               color: VideoColorInfo,
                                               audioPassthrough: Bool,
                                               audioDelay: Double,
                                               audioTracks: [AudioTrackInfo]) -> Bool {
        let effectiveMode: StreamMode =
            burnSubtitle == nil && burnSubtitleStream == nil ? mode : .transcode
        guard effectiveMode == .remux else { return false }
        // HDR / 杜比视界不能用多音轨 master：ffmpeg 生成的 master 没有 VIDEO-RANGE，
        // AVPlayer 会拒绝整条流（实测 CoreMediaErrorDomain -12927）；
        // 单音轨 media playlist 保留 HDR 视频拷贝可正常播放。
        guard !isHDR, !color.isHDR, !color.isDolbyVision else { return false }
        guard audioPassthrough else { return false }
        guard abs(audioDelay) < 0.001 else { return false }
        // 音轨逐条决策：能直通的拷贝、DTS / TrueHD 转 AC-3、其余转 AAC，
        // 混合编码符合同一条 master 的规范（实测 CODECS 会写成 ac-3,mp4a.40.2）。
        guard audioTracks.count > 1 else { return false }
        return true
    }

    /// 改动任何会改变分片内容的参数（滤镜、编码器、切片、色彩标记）后，
    /// 必须把 `VideoStreamSession.cacheKeyVersion` +1，否则新策略会命中旧缓存。
    public static func arguments(for request: StreamRequest) -> [String] {
        let effectiveMode: StreamMode =
            request.burnSubtitle == nil && request.burnSubtitleStream == nil ? request.mode : .transcode
        let copiesVideo = effectiveMode == .remux
        let seeking = request.startOffset > 0.5
        let multiAudio = usesMultipleAudioTracks(for: request)

        var arguments = ["-y", "-v", "error"]
        // 只看开头 2 MB 就足够判断流信息，缩短首段等待（原来 4 MB 在网盘上要多读几秒）。
        arguments += ["-probesize", "2M", "-analyzeduration", "2M"]
        // 本地文件读盘快，保持 12×；网盘按缓冲档位决定生成倍率，提前量由会话的 pacing 控制。
        // 直播由源按实时推送，限速反而会积压，直接不限。
        if !request.isLive {
            arguments += ["-readrate", request.isRemote ? "\(request.bufferProfile.remoteReadRate)" : "12"]
        }
        if seeking {
            // 输入选项，必须放在 -i 之前：关掉「解码后精确丢弃」，
            // 音轨才会和视频一样从 demuxer 落到的关键帧开始。
            if copiesVideo { arguments += ["-noaccurate_seek"] }
            // 拷贝视频时传请求值（探测也用同一个值）；重编码时传对齐后的关键帧。
            let seekValue = copiesVideo ? request.startOffset : request.sessionStart
            arguments += ["-ss", String(format: "%.3f", seekValue)]
        }
        // 蓝光多角度：`-angle` 是 demuxer 输入选项，必须放在 -i 之前；普通文件忽略。
        if request.angle > 1, request.input.hasPrefix("bluray:") {
            arguments += ["-angle", "\(request.angle)"]
        }
        // 图形字幕（PGS / VobSub）要按全画布合成，先告诉字幕解码器画布尺寸。
        if request.burnSubtitleStream != nil,
           request.sourceSize.width > 0, request.sourceSize.height > 0 {
            arguments += ["-canvas_size",
                          "\(Int(request.sourceSize.width))x\(Int(request.sourceSize.height))"]
        }
        // 重编码时先接硬件解码：4K60 HEVC 软解实测只有约 0.6× 实时，转码永远追不上播放；
        // 接上 VideoToolbox 后解码几乎不占 CPU。转封装用不到解码，不加。
        if effectiveMode == .transcode {
            arguments += ["-hwaccel", "videotoolbox"]
        }
        // 直播直接把源地址交给 ffmpeg：带上源要求的 UA / Referer，断流时自动重连。
        if request.isLive {
            if let userAgent = request.headers.first(where: {
                $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
            })?.value, !userAgent.isEmpty {
                arguments += ["-user_agent", userAgent]
            }
            let extraHeaders = request.headers
                .filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)\r\n" }
                .joined()
            if !extraHeaders.isEmpty {
                arguments += ["-headers", extraHeaders]
            }
            arguments += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        }
        arguments += ["-i", request.input]
        if seeking {
            // 实测三种配方（copyts + start_at_zero / 不用 copyts / copyts + output_ts_offset）
            // 的 fMP4 时间轴都归零到 0，首帧音画偏差完全一致；去掉 copyts 后首片快约 2.7×。
            // 只保留 avoid_negative_ts：把落点前的负时间戳统一平移到 0。
            arguments += ["-avoid_negative_ts", "make_zero"]
        }
        // 烧录内嵌图形字幕时视频由 filter_complex 输出，不能再 map 原始视频轨。
        if request.burnSubtitleStream == nil {
            arguments += ["-map", "0:v:0"]
        }
        // 烧录字幕必须重编码，不能走 -c:v copy。
        switch effectiveMode {
        case .remux:
            arguments += ["-c:v", "copy"]
            if let tag = request.color.remuxCodecTag {
                // 杜比视界必须保留 dvh1 / dvhe：改成 hvc1 会让播放器忽略 DOVI 元数据。
                // 写 DV 到 MP4 属于 ffmpeg 的实验性封装，需要显式放开。
                arguments += ["-strict", "unofficial", "-tag:v", tag]
            } else if request.isHEVC {
                // AVFoundation 只认 hvc1 标签，ffmpeg 默认写 hev1。
                arguments += ["-tag:v", "hvc1"]
            }
            appendColorTags(&arguments, color: request.color)
            if multiAudio {
                // 逐条音轨决定拷贝 / AC-3 / AAC：混合编码符合同一条 master 的规范。
                for (index, track) in request.audioTracks.enumerated() {
                    arguments += ["-map", "0:a:\(track.ordinal)"]
                    let action = AudioPlaybackPlan.action(codec: track.codec,
                                                          channels: track.channels,
                                                          downmix: request.audioDownmix,
                                                          allowPassthrough: request.audioPassthrough,
                                                          copiesVideo: true)
                    arguments += audioArguments(action: action,
                                                streamIndex: index,
                                                channels: track.channels,
                                                downmix: request.audioDownmix)
                }
                // 语言标签会写进 HLS 的 EXT-X-MEDIA，播放器音轨菜单据此命名。
                for (index, track) in request.audioTracks.enumerated() {
                    if let language = track.language, !language.isEmpty,
                       language.lowercased() != "und" {
                        arguments += ["-metadata:s:a:\(index)", "language=\(language)"]
                    }
                }
            } else if shouldCopyAudio(codec: request.audioCodec,
                                      channels: request.audioChannels,
                                      downmix: request.audioDownmix,
                                      mode: request.mode,
                                      burnSubtitle: request.burnSubtitle,
                                      audioDelay: request.audioDelay,
                                      allowPassthrough: request.audioPassthrough) {
                // 能拷就拷：省一次重编码，也不存在「音频被裁到别处」的可能。
                arguments += ["-c:a", "copy"]
            } else {
                appendEncodedAudio(&arguments, request: request)
            }
        case .transcode:
            // 用 VideoToolbox 硬件编码：4K HDR 色调映射 / 烧录字幕时 libx264 明显慢于实时，
            // 播放端就会周期性缓冲甚至长时间卡住；硬件编码能留出足够余量。
            // allow_sw 允许在没有硬件会话时回退到系统软件编码，不会因此打不开片。
            let profile = TranscodeProfile.make(sourceSize: request.sourceSize,
                                                frameRate: request.frameRate,
                                                transcodeMode: request.transcodeMode)
            // 图形字幕按源分辨率合成：降档后字幕帧与视频帧尺寸不一致，位置会错乱，
            // 因此烧录 PGS / VobSub 时不做分辨率降档（UHD BD 是 24p，本来也不触发降档）。
            let scaled = request.burnSubtitleStream == nil
                ? profile
                : TranscodeProfile(bitrate: TranscodeProfile.bitrate(
                    forHeight: request.sourceSize.height > 0 ? Int(request.sourceSize.height) : 1080),
                    codec: profile.codec)
            // HDR 屏上的 HDR10 源：保留 HDR，只缩放 + 重编码。
            // 色调映射链（libplacebo）4K60 实测只有 <1× 实时，去掉后同样素材能到约 1.5×。
            // 杜比视界必须靠 libplacebo 应用 RPU，不能走这条路。
            let keepsHDR = request.preserveHDR
                && (request.isHDR || request.color.isHDR || request.color.isDolbyVision)
                && !request.color.isDolbyVision
            // 保留 HDR 只能输出 HEVC 10bit（H.264 没有 10bit / HDR 输出）。
            var effectiveProfile = scaled
            if keepsHDR, effectiveProfile.codec != .hevc {
                effectiveProfile.codec = .hevc
            }
            let usesHEVC = effectiveProfile.codec == .hevc
            arguments += ["-c:v", usesHEVC ? "hevc_videotoolbox" : "h264_videotoolbox",
                          "-b:v", "\(effectiveProfile.bitrate)",
                          "-maxrate", "\(effectiveProfile.maxrate)",
                          "-bufsize", "\(effectiveProfile.bufsize)",
                          "-allow_sw", "1",
                          "-pix_fmt", effectiveProfile.pixelFormat]
            if usesHEVC {
                // AVFoundation 只认 hvc1；Main10 与 10-bit 输出是本机实测可播放的组合。
                arguments += ["-tag:v", "hvc1", "-profile:v", "main10"]
                if request.transcodeMode == .lowPower {
                    arguments += ["-power_efficient", "1", "-prio_speed", "1"]
                }
            }
            // 强制 2 秒关键帧：长 GOP 片源也能按 hls_time 切片，首段不必等一整条 GOP。
            arguments += ["-force_key_frames", "expr:gte(t,n_forced*2)"]
            var filters: [String] = []
            // 隔行源（1080i / DVD）先还原成逐行：缩放、色调映射与字幕都基于逐行帧。
            if request.isInterlaced {
                filters.append(PlaybackFilters.deinterlaceChain)
            }
            if let burnSubtitle = request.burnSubtitle {
                filters.append(PlaybackFilters.subtitleBurnFilter(burnSubtitle))
            }
            var toneMapped = false
            if keepsHDR {
                // 保留 HDR 时只做缩放，色彩原样（不转 bt709）。
                if let outputHeight = effectiveProfile.outputSize.map({ Int($0.height) }) {
                    filters.append("scale=-2:\(outputHeight):flags=bicubic")
                }
                filters.append("format=p010le")
            } else if request.isHDR || request.color.isDolbyVision,
               request.supportsToneMapping,
               let chain = PlaybackFilters.toneMapChain(
                   dolbyVision: request.color.isDolbyVision,
                   supportsLibplacebo: request.supportsLibplacebo,
                   outputWidth: effectiveProfile.outputSize.map { Int($0.width) },
                   outputHeight: effectiveProfile.outputSize.map { Int($0.height) },
                   inputColor: request.color) {
                filters.append(chain)
                toneMapped = true
            } else if let outputHeight = effectiveProfile.outputSize.map({ Int($0.height) }) {
                // 非 HDR 的重编码也要按同一套像素率上限降档。
                filters.append("scale=-2:\(outputHeight)")
            }
            if let subtitleStream = request.burnSubtitleStream {
                // 图形字幕无法转文本：ffmpeg 把 PGS 解成位图后按字幕自带坐标叠回画面，
                // 只能走 filter_complex（-vf 无法接收第二条流）。
                // eof_action=pass：字幕轨结束后继续输出视频，避免最后一帧字幕被无限重复。
                var graph = "[0:v:0]"
                graph += filters.isEmpty ? "format=yuv420p" : filters.joined(separator: ",")
                graph += "[vbase];[vbase][0:s:\(subtitleStream)]overlay=format=auto:eof_action=pass[v]"
                arguments += ["-filter_complex", graph, "-map", "[v]"]
            } else if !filters.isEmpty {
                arguments += ["-vf", filters.joined(separator: ",")]
            }
            if toneMapped {
                arguments += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            } else if keepsHDR {
                // 保留 HDR：写回源色彩标记；缺失时按 HDR10 默认值补齐，否则播放器按 SDR 解码。
                var color = request.color
                if color.primaries == nil { color.primaries = "bt2020" }
                if color.transfer == nil { color.transfer = "smpte2084" }
                if color.matrix == nil { color.matrix = "bt2020nc" }
                if color.range == nil { color.range = "tv" }
                appendColorTags(&arguments, color: color)
            }
            appendEncodedAudio(&arguments, request: request)
        }
        if !multiAudio {
            arguments += ["-map", "0:a:\(request.audioIndex)?"]
        }
        // 4K 高码率重新封装时包队列容易溢出（Too many packets buffered），放宽到 2048。
        arguments += ["-max_muxing_queue_size", "2048"]
        arguments += ["-f", "hls",
                      "-hls_time", "2",
                      "-hls_init_time", "0.5",
                      // 直播用滑动窗口：只留最近几段，避免长时间观看把磁盘写满。
                      "-hls_list_size", request.isLive ? "6" : "0"]
        if request.isLive {
            // 分片先写临时文件再改名，并在滑出窗口后删除旧段。
            arguments += ["-hls_flags", "delete_segments+temp_file"]
        } else {
            arguments += ["-hls_playlist_type", "event",
                          "-hls_flags", "temp_file"]
        }
        arguments += ["-hls_segment_type", "fmp4"]
        if multiAudio {
            // 一个视频 variant + 每路音轨一条 media playlist，播放器可即时换轨。
            arguments += ["-hls_fmp4_init_filename", "init_%v.mp4",
                          "-hls_segment_filename",
                          request.outputDirectory.appendingPathComponent("seg_%v_%05d.m4s", isDirectory: false).path,
                          "-var_stream_map", varStreamMap(request.audioTracks),
                          "-master_pl_name", "master.m3u8",
                          request.outputDirectory.appendingPathComponent("live_%v.m3u8", isDirectory: false).path]
        } else {
            arguments += ["-hls_fmp4_init_filename", "init.mp4",
                          "-hls_segment_filename",
                          request.outputDirectory.appendingPathComponent("seg%05d.m4s", isDirectory: false).path,
                          request.outputDirectory.appendingPathComponent("live.m3u8", isDirectory: false).path]
        }
        return arguments
    }

    /// 转封装时把源文件的色彩标记写回容器：Matroska 常把色域 / 传输特性放在容器层，
    /// 只写码流 VUI 的 fMP4 会丢，AVPlayer 就按 BT.709 / SDR 解码。
    private static func appendColorTags(_ arguments: inout [String], color: VideoColorInfo) {
        let tags: [(String, String?)] = [
            ("-color_primaries", color.primaries),
            ("-color_trc", color.transfer),
            ("-colorspace", color.matrix),
            ("-color_range", color.range)
        ]
        for (option, value) in tags {
            guard let value, !value.isEmpty, value.lowercased() != "unknown" else { continue }
            arguments += [option, value]
        }
    }

    /// 音频重编码：DTS-HD / TrueHD 转 E-AC-3 1536k（AVPlayer 原生支持），其余用 AAC。
    /// 直通兜底会话（audioPassthrough = false）一律用 AAC：它是最小公分母，
    /// 在「直通后播放器读不到音轨」这种未知原因下最先被救回来。
    private static func appendEncodedAudio(_ arguments: inout [String], request: StreamRequest) {
        let action = AudioPlaybackPlan.action(codec: request.audioCodec,
                                              channels: request.audioChannels,
                                              downmix: request.audioDownmix,
                                              allowPassthrough: request.audioPassthrough,
                                              copiesVideo: true)
        // 单轨分支只在无法拷贝时进来；action 实际只会是 .eac3 / .aac。
        arguments += ["-async", "1"]
        arguments += audioArguments(action: action == .copy ? .aac : action,
                                    streamIndex: nil,
                                    channels: request.audioChannels,
                                    downmix: request.audioDownmix)
        if let filter = audioDelayFilter(request.audioDelay) {
            arguments += ["-af", filter]
        }
    }

    /// 单条音轨的 ffmpeg 参数；`streamIndex` 有值时生成 `-c:a:N` 这类按流指定的参数。
    private static func audioArguments(action: AudioTrackAction,
                                       streamIndex: Int?,
                                       channels: Int,
                                       downmix: AudioDownmixMode) -> [String] {
        // 全局选项是 -c:a / -b:a / -ac；按流指定才是 -c:a:N / -b:a:N / -ac:a:N。
        let codecOption = streamIndex.map { "-c:a:\($0)" } ?? "-c:a"
        let bitrateOption = streamIndex.map { "-b:a:\($0)" } ?? "-b:a"
        let channelsOption = streamIndex.map { "-ac:a:\($0)" } ?? "-ac"
        switch action {
        case .copy:
            return [codecOption, "copy"]
        case .eac3:
            // E-AC-3 最多 5.1（ffmpeg 编码器不接受 7.1）：7.1 源下混到 6 声道。
            // 1536k 是蓝光常见档，比 AC-3 640k 保留更多细节；实测 AVPlayer 可播 `ec-3`。
            return [codecOption, "eac3",
                    bitrateOption, "1536k",
                    channelsOption, "6"]
        case .aac:
            var result = [codecOption, "aac",
                          bitrateOption, AudioPlaybackPlan.aacBitrate(channels: channels,
                                                                      downmix: downmix)]
            if downmix == .stereo {
                result += [channelsOption, "2"]
            }
            return result
        }
    }

    /// 音频延迟滤镜：正值补静音，负值裁掉开头。
    private static func audioDelayFilter(_ delay: Double) -> String? {
        guard abs(delay) > 0.001 else { return nil }
        if delay > 0 {
            let milliseconds = Int((delay * 1000).rounded())
            return "adelay=delays=\(milliseconds):all=1"
        }
        return String(format: "atrim=start=%.3f,asetpts=PTS-STARTPTS", -delay)
    }

    private static func varStreamMap(_ tracks: [AudioTrackInfo]) -> String {
        var parts = ["v:0,agroup:aud"]
        for (index, track) in tracks.enumerated() {
            var entry = "a:\(index),agroup:aud"
            if index == 0 { entry += ",default:yes" }
            let language = (track.language ?? "").lowercased()
            if !language.isEmpty, language != "und" {
                // ffmpeg 用 name 替换 `%v` 生成分片文件名：同语言多音轨必须带序号，
                // 否则后一条会覆盖前一条的 m3u8 / init，音轨菜单指向同一份内容。
                let name = tracks.count > 1 ? "\(language)-\(index + 1)" : language
                // 只有 language 会写进 master 的 `LANGUAGE` 属性，AVPlayer 菜单才显示
                // English / 日本語 这类可读名称；只写 name 时菜单是 Unknown / audio_2。
                entry += ",language:\(language),name:\(name)"
            }
            parts.append(entry)
        }
        return parts.joined(separator: " ")
    }
}
