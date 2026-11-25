import Foundation
import AppKit
import AVFoundation
import PlaybackCore
import UniformTypeIdentifiers

// MARK: - 视频格式

/// 集中维护可导入/可播放的视频扩展名。部分容器（mkv/avi/flv/wmv…）系统 UTI 未声明为 movie，
/// 只能按扩展名识别，因此这里以白名单为主、UTType 为辅。
enum VideoFormats {
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "qt",
        "avi", "mkv", "webm", "flv", "f4v", "wmv", "asf",
        "mpg", "mpeg", "m2v", "mpe", "m1v", "vob", "ts", "m2ts", "mts", "mtts",
        "3gp", "3g2", "ogv", "rm", "rmvb", "divx", "dv", "mxf", "amv"
    ]

    static func isVideoExtension(_ ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    /// 打开面板允许的文件类型：系统 image/movie 加上每种视频扩展名的 UTI。
    static var importContentTypes: [UTType] {
        var types: [UTType] = [.image, .movie]
        // 蓝光光盘镜像。
        if let iso = UTType(filenameExtension: "iso") { types.append(iso) }
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext), !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }
}

// MARK: - ffmpeg / ffprobe

/// 系统未安装 ffmpeg 时，AVFoundation 无法解码的容器会给出明确提示；
/// 安装后即可自动转码播放，并用于生成缩略图。
enum FFmpeg {
    static let executable: URL? = locate("ffmpeg")
    static let probe: URL? = locate("ffprobe")
    /// 支持 zscale + tonemap 的 ffmpeg：优先用内置静态包（已带 libzimg），
    /// 内置包缺失或过旧时退回系统 / Homebrew ffmpeg。
    static let toneMapExecutable: URL? = locate("ffmpeg", requiredFilters: ["zscale", "tonemap"],
                                                purpose: "HDR 色调映射")
    /// 带 libplacebo 的 ffmpeg：杜比视界的 DOVI RPU 只能由它应用。
    /// 发布包内置 ffmpeg-full + MoltenVK；开发期未打包时回退 Homebrew。
    static let libplaceboExecutable: URL? = locate("ffmpeg", requiredFilters: ["libplacebo"],
                                                   purpose: "杜比视界映射（libplacebo）")

    static var isAvailable: Bool { executable != nil }

    /// 是否有能正确处理杜比视界的 ffmpeg。
    static var supportsLibplacebo: Bool { libplaceboExecutable != nil }

    /// Vulkan loader 靠 ICD 清单找到 libMoltenVK：优先用 App 内置的（随 ffmpeg 一起打包），
    /// 找不到再退回 Homebrew 的 molten-vk。
    static var vulkanICDPath: String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("lib/MoltenVK_icd.json").path,
           fm.fileExists(atPath: bundled) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json",
            "/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json"
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    /// 子进程需要额外注入的环境变量：libplacebo 初始化 Vulkan 时要用到 MoltenVK。
    static var processEnvironment: [String: String] {
        guard let icd = vulkanICDPath else { return [:] }
        return ["VK_ICD_FILENAMES": icd]
    }

    /// 转码时按需选择可做色调映射的二进制。
    static func executable(preferToneMap: Bool, preferLibplacebo: Bool = false) -> URL? {
        if preferToneMap, preferLibplacebo, let libplaceboExecutable { return libplaceboExecutable }
        if preferToneMap, let toneMapExecutable { return toneMapExecutable }
        return executable
    }

    private static func locate(_ name: String,
                               requiredFilters: [String] = [],
                               purpose: String? = nil) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        // 优先使用 App 内置的 ffmpeg（build.sh 把 ffmpeg-full + 依赖打进 Contents/Resources/bin、lib）。
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/\(name)").path {
            candidates.append(bundled)
        }
        candidates += [
            // Homebrew 的 ffmpeg-full 是 keg-only：带 libplacebo，杜比视界 P5 只能靠它正确映射。
            "/opt/homebrew/opt/ffmpeg-full/bin/\(name)",
            "/usr/local/opt/ffmpeg-full/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/local/bin/\(name)"
        ]
        var searchPaths = candidates
        if let whichPath = which(name) { searchPaths.append(whichPath) }
        for path in searchPaths where fm.isExecutableFile(atPath: path) {
            if !requiredFilters.isEmpty {
                guard supportsFilters(URL(fileURLWithPath: path), requiredFilters) else { continue }
                Diagnostics.record("视频组件：\(purpose ?? "HDR 色调映射") 使用 \(path)")
            } else {
                Diagnostics.record("视频组件：使用 \(path)")
            }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/which") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func supportsFilters(_ url: URL, _ required: [String]) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return required.allSatisfy { text.contains($0) }
    }
}

// MARK: - 视频探测与转换

enum VideoSupport {
    /// 用于播放前的快速探测。
    static func probe(url: URL, options: [String: Any] = [:]) async -> VideoProbe {
        await probe(asset: AVURLAsset(url: url, options: options), fallbackURL: url, options: options)
    }

    /// 复用调用方已经建好的 AVAsset：SMB / 外置盘上少开一次文件，
    /// 轨道信息也是同一份缓存，交给 AVPlayerItem 后首帧更快。
    static func probe(asset: AVAsset, fallbackURL: URL?,
                      options: [String: Any] = [:]) async -> VideoProbe {
        let headers = options[CloudPlayback.headerFieldsKey] as? [String: String] ?? [:]
        // 网络卷（SMB / WebDAV）上的 MKV / AVI：AVFoundation 既解析不了，又可能卡在读取上。
        // 直接跳过它，只用带读取上限的 ffprobe——否则打开 60GB 这类大文件会先黑屏几十秒。
        if let fallbackURL, shouldProbeWithFFprobeOnly(fallbackURL) {
            return await boundedProbe(url: fallbackURL, headers: headers, timeout: 15)
        }
        var probe = await probe(asset: asset)
        guard let fallbackURL else { return probe }
        if !probe.isPlayable || probe.duration <= 0 || probe.size.width <= 0 {
            // ffprobe 是阻塞子进程：外置盘 / 网盘片源动辄几秒到几十秒，
            // 一定不能跑在调用方线程（打开视频时就是主线程）上，否则整个 App 像卡死。
            let fallback = await boundedProbe(url: fallbackURL, headers: headers, timeout: 15)
            if probe.duration <= 0 { probe.duration = fallback.duration }
            if probe.size.width <= 0 { probe.size = fallback.size }
            if probe.codec == nil { probe.codec = fallback.codec }
            if !probe.isHEVC { probe.isHEVC = fallback.isHEVC }
            if !probe.isHDR { probe.isHDR = fallback.isHDR }
            if !probe.isDolbyVision { probe.isDolbyVision = fallback.isDolbyVision }
            probe.color = merged(probe.color, with: fallback.color)
            if probe.hdrLabel == nil { probe.hdrLabel = fallback.hdrLabel }
            if probe.bitrate == 0 { probe.bitrate = fallback.bitrate }
            if probe.frameRate <= 0 { probe.frameRate = fallback.frameRate }
            if !probe.isInterlaced { probe.isInterlaced = fallback.isInterlaced }
            if probe.containerName == nil { probe.containerName = fallback.containerName }
            if probe.chapters.isEmpty { probe.chapters = fallback.chapters }
            if probe.audioTrackCount == 0 { probe.audioTrackCount = fallback.audioTrackCount }
            if probe.audioTracks.isEmpty { probe.audioTracks = fallback.audioTracks }
            if probe.subtitleTracks.isEmpty { probe.subtitleTracks = fallback.subtitleTracks }
        }
        return probe
    }

    /// 播放信息叠加与章节用：总是跑一次 ffprobe，拿码率 / 帧率 / HDR / 章节等完整字段。
    /// 调用方在后台任务里 await，不阻塞起播；ffprobe 失败时退回 AVFoundation 探测。
    static func technicalProbe(url: URL, options: [String: Any] = [:]) async -> VideoProbe {
        let headers = options[CloudPlayback.headerFieldsKey] as? [String: String] ?? [:]
        // NAS 上再跑一次探测会和起流抢同一块网络带宽，大文件尤其明显；
        // 播放阶段优先保证不卡，信息以起播时的探测为准。
        if headers.isEmpty, isNetworkVolume(url) {
            return VideoProbe()
        }
        let probed = await Task.detached(priority: .utility) {
            if !headers.isEmpty {
                return ffprobeMetadata(url: url, headers: headers, timeout: 15)
            }
            // 远端大文件不能放任 ffprobe 读几十 MB 再解析：WebDAV / 网盘上经常直接超时。
            if !url.isFileURL {
                return ffprobeMetadata(inputArguments: remoteProbeArguments + ["-i", url.path],
                                       timeout: 15)
            }
            return ffprobeMetadata(url: url, timeout: 20)
        }.value
        if probed.hasVideoTrack || probed.duration > 0 {
            return probed
        }
        return await probe(asset: AVURLAsset(url: url, options: options))
    }

    /// CMFormatDescription → 与 ffmpeg 同名的色彩参数。
    private static func colorInfo(from description: CMFormatDescription) -> VideoColorInfo {
        var info = VideoColorInfo()
        let subType = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [UInt8((subType >> 24) & 0xFF), UInt8((subType >> 16) & 0xFF),
                     UInt8((subType >> 8) & 0xFF), UInt8(subType & 0xFF)]
        if let tag = String(bytes: bytes, encoding: .ascii) {
            info.codecTag = tag.lowercased()
        }
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        // AVFoundation 对 MP4/MOV 常把色彩放在 CVImageBuffer* 扩展里，而不是
        // kCMFormatDescriptionExtension_*；两条都读，否则原生 HDR 会被当成 SDR。
        func value(_ cmKey: CFString, _ cvKey: String) -> Any? {
            extensions[cmKey as String] ?? extensions[cvKey]
        }
        info.primaries = primariesName(value(kCMFormatDescriptionExtension_ColorPrimaries,
                                             "CVImageBufferColorPrimaries") as? String)
        info.transfer = transferName(value(kCMFormatDescriptionExtension_TransferFunction,
                                           "CVImageBufferTransferFunction") as? String)
        info.matrix = matrixName(value(kCMFormatDescriptionExtension_YCbCrMatrix,
                                       "CVImageBufferYCbCrMatrix") as? String)
        if let full = value(kCMFormatDescriptionExtension_FullRangeVideo,
                            "FullRangeVideo") as? Bool {
            info.range = full ? "pc" : "tv"
        }
        info.isHDR = info.primaries == "bt2020"
            || info.transfer == "smpte2084"
            || info.transfer == "arib-std-b67"
        // 杜比视界在 MOV / MP4 里用 dvh1 / dvhe 标记；hvc1 也可能是 DV，交给 ffprobe 兜底补 profile。
        info.isDolbyVision = info.codecTag?.hasPrefix("dvh") ?? false
        return info
    }

    /// CMFormatDescription 的扩展值是 CoreMedia 常量字符串，这里映射成 ffmpeg 的参数名。
    private static func primariesName(_ raw: String?) -> String? {
        switch raw {
        case "ITU_R_709_2": return "bt709"
        case "ITU_R_2020": return "bt2020"
        case "SMPTE_C": return "smpte170m"
        case "EBU_3213_E": return "bt470bg"
        case "SMPTE_240M_1995": return "smpte240m"
        case "P3_D65": return "smpte432"
        case "P3_DCI": return "smpte431"
        case "GENERIC_FILM": return "film"
        default: return nil
        }
    }

    private static func transferName(_ raw: String?) -> String? {
        switch raw {
        case "ITU_R_709_2": return "bt709"
        case "ITU_R_2020": return "bt2020-10"
        case "SMPTE_ST_2084", "SMPTE_ST_2084_PQ": return "smpte2084"
        case "ITU_R_2100_HLG": return "arib-std-b67"
        case "SMPTE_ST_428_1": return "smpte428"
        case "SMPTE_240M_1995": return "smpte240m"
        default: return nil
        }
    }

    private static func matrixName(_ raw: String?) -> String? {
        switch raw {
        case "ITU_R_709_2": return "bt709"
        case "ITU_R_2020": return "bt2020nc"
        case "SMPTE_C", "ITU_R_601_4": return "smpte170m"
        case "EBU_3213_E": return "bt470bg"
        case "SMPTE_240M_1995": return "smpte240m"
        case "FCC": return "fcc"
        default: return nil
        }
    }

    /// 合并两次探测的色彩信息：AVFoundation 缺的字段由 ffprobe 补齐。
    private static func merged(_ base: VideoColorInfo, with other: VideoColorInfo) -> VideoColorInfo {
        var info = base
        if info.primaries == nil { info.primaries = other.primaries }
        if info.transfer == nil { info.transfer = other.transfer }
        if info.matrix == nil { info.matrix = other.matrix }
        if info.range == nil { info.range = other.range }
        if info.codecTag == nil { info.codecTag = other.codecTag }
        if info.dvProfile == nil { info.dvProfile = other.dvProfile }
        info.isHDR = info.isHDR || other.isHDR
        info.isDolbyVision = info.isDolbyVision || other.isDolbyVision
        return info
    }

    private static func normalizedColorValue(_ raw: String?) -> String? {
        guard let value = raw?.lowercased(), !value.isEmpty,
              value != "unknown", value != "reserved" else { return nil }
        return value
    }

    /// 任意 AVAsset（例如 PhotoKit 返回的云端素材，没有本地 URL）的轨道探测。
    static func probe(asset: AVAsset) async -> VideoProbe {
        var probe = VideoProbe()

        let playable = (try? await asset.load(.isPlayable)) ?? false
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        probe.hasVideoTrack = !tracks.isEmpty

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            probe.duration = max(0, duration.seconds)
        }
        if let track = tracks.first {
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let oriented = natural.applying(transform)
            probe.size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            probe.frameRate = Double(track.nominalFrameRate)
            // 4K50/60 的 hev1 片源系统会直接报不可解码：这时直连只会「有声音没画面」，
            // 必须改走重编码。宁可多一次转码，也不能让用户对着黑屏听声音。
            probe.isVideoDecodable = (try? await track.load(.isDecodable)) ?? true
            if let formats = try? await track.load(.formatDescriptions), let first = formats.first {
                probe.codec = codecDisplayName(CMFormatDescriptionGetMediaSubType(first))
                probe.isHEVC = probe.codec == "HEVC"
                // 完整色彩管线从格式描述里拿：直连播放也要知道是 HDR10 / HLG 还是杜比视界。
                probe.color = colorInfo(from: first)
                probe.isHDR = probe.color.isHDR
                probe.isDolbyVision = probe.color.isDolbyVision
            }
        }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        probe.audioTrackCount = audioTracks.count
        probe.audioTracks = await audioTrackInfos(audioTracks)
        // 音轨解不了时不能盲目放宽：否则会得到「有画面没声音」。
        var audioDecodable = true
        for track in audioTracks {
            if let decodable = try? await track.load(.isDecodable), !decodable {
                audioDecodable = false
                break
            }
        }
        // `isPlayable` 对 hev1 的 HEVC 会误报 false：按容器 + 编码放宽，避免白走 remux。
        // 但视频轨被系统明确判定不可解码时不能放宽：直连会黑屏有声音，必须重编码。
        // 关闭「优先系统硬解」时不再直读，统一走转封装 / 软解路径。
        probe.isPlayable = AppSettings.shared.videoPreferHardwareDecoding
            && probe.isVideoDecodable && VideoProbe.allowsNativePlayback(
            assetIsPlayable: playable,
            hasVideoTrack: probe.hasVideoTrack,
            codec: probe.codec,
            containerExtension: (asset as? AVURLAsset)?.url.pathExtension,
            audioDecodable: audioDecodable)
        return probe
    }

    /// AVFoundation 路径的音轨明细：原生直读没有走 ffprobe，也要有语言 / 声道 / 编码，
    /// 否则多音轨 MP4 的菜单与「DTS→AC-3」判断都会缺输入。
    private static func audioTrackInfos(_ tracks: [AVAssetTrack]) async -> [AudioTrackInfo] {
        var infos: [AudioTrackInfo] = []
        for (index, track) in tracks.enumerated() {
            var codec = ""
            var channels = 0
            if let formats = try? await track.load(.formatDescriptions), let first = formats.first {
                codec = audioCodecName(CMFormatDescriptionGetMediaSubType(first))
                if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
                    channels = Int(stream.mChannelsPerFrame)
                }
            }
            let language = try? await track.load(.languageCode)
            infos.append(AudioTrackInfo(ordinal: index, codec: codec, channels: channels,
                                        language: language, title: nil))
        }
        return infos
    }

    /// AVFoundation 的音频 fourCC 与 ffmpeg 的 codec_name 不是同一套写法（`ac-3` vs `ac3`），
    /// 统一成 StreamPlanner 能识别的 token，避免把可直通的 AC-3 误判成陌生编码。
    private static func audioCodecName(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let raw = (String(bytes: bytes, encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        switch raw {
        case "aac", "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "ac-3": return "AC3"
        case "ec-3": return "EAC3"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64": return "PCM"
        case "opus": return "OPUS"
        case ".mp3", "mp3": return "MP3"
        case "flac": return "FLAC"
        default: return prettyCodec(raw)
        }
    }

    /// 导入时同步读取尺寸/时长，AVFoundation 读不到时回退 ffprobe。
    static func quickMetadata(url: URL) -> VideoProbe {
        var probe = VideoProbe()
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .video).first {
            let natural = track.naturalSize
            let oriented = natural.applying(track.preferredTransform)
            probe.size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            probe.hasVideoTrack = true
            if let formats = track.formatDescriptions as? [CMFormatDescription], let first = formats.first {
                probe.codec = codecDisplayName(CMFormatDescriptionGetMediaSubType(first))
            }
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 { probe.duration = seconds }
        probe.isPlayable = probe.hasVideoTrack

        if !probe.hasVideoTrack || probe.duration <= 0 {
            let fallback = ffprobeMetadata(url: url)
            if probe.size.width <= 0 { probe.size = fallback.size }
            if probe.duration <= 0 { probe.duration = fallback.duration }
            if probe.codec == nil { probe.codec = fallback.codec }
            probe.hasVideoTrack = probe.hasVideoTrack || fallback.hasVideoTrack
        }
        return probe
    }

    /// 远端探测的读取上限：WebDAV / 网盘上不限制 analyzeduration 会先读几十 MB，
    /// 61 GB 这类大文件经常直接超过 20~30 秒超时，表现为打开视频长时间没有反馈。
    static let remoteProbeArguments = ["-probesize", "5M", "-analyzeduration", "1000000"]

    /// 网络卷（SMB / WebDAV / NFS）：随机读与首次打开都明显慢于本地盘。
    static func isNetworkVolume(_ url: URL) -> Bool {
        guard url.isFileURL else { return true }
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false
    }

    /// ffprobe 只能确认「有视频轨」，判断不了 AVFoundation 能不能解这个容器。
    /// 本地文件必须按容器白名单重新判定：否则 MKV / AVI 会被当成原生可播，
    /// 装片时报 -11828 再回退成重编码，4K60 上转码追不上播放，表现为周期性缓冲。
    private static func applyingNativePlayability(_ probe: VideoProbe, for url: URL) -> VideoProbe {
        guard url.isFileURL, probe.hasVideoTrack else { return probe }
        var result = probe
        result.isPlayable = AppSettings.shared.videoPreferHardwareDecoding
            && VideoProbe.allowsNativePlayback(
            assetIsPlayable: false,
            hasVideoTrack: true,
            codec: probe.codec,
            containerExtension: url.pathExtension)
        return result
    }

    /// 网络卷上的这些容器系统本来就播不了，AVFoundation 探测只会白等。
    private static func shouldProbeWithFFprobeOnly(_ url: URL) -> Bool {
        guard isNetworkVolume(url) else { return false }
        switch url.pathExtension.lowercased() {
        case "mkv", "avi", "ts", "m2ts", "mts", "wmv", "flv",
             "rmvb", "rm", "divx", "vob", "ogv":
            return true
        default:
            return false
        }
    }

    /// 带读取上限的 ffprobe：远端（或网络卷）先限制探测读量，避免大文件卡在解析上。
    private static func boundedProbe(url: URL,
                                     headers: [String: String],
                                     timeout: TimeInterval) async -> VideoProbe {
        let network = isNetworkVolume(url)
        // 网络盘上 57GB 这类 REMUX 光读头部也可能超过 15 秒；给足时间，
        // 同时不读章节（MKV 章节常在文件尾部，SMB 上要额外跨大半个文件）。
        let effectiveTimeout = network && headers.isEmpty ? max(timeout, 45) : timeout
        return await Task.detached(priority: .userInitiated) {
            if !headers.isEmpty {
                return ffprobeMetadata(url: url, headers: headers, timeout: effectiveTimeout)
            }
            if network {
                return applyingNativePlayability(
                    ffprobeMetadata(inputArguments: remoteProbeArguments + ["-i", url.path],
                                    timeout: effectiveTimeout, includeChapters: false),
                    for: url)
            }
            return ffprobeMetadata(url: url, timeout: effectiveTimeout)
        }.value
    }

    /// 远端视频探测：WebDAV 需要 Basic 认证头等，ffprobe 同样要带上。
    static func ffprobeMetadata(url: URL, headers: [String: String],
                                tlsInsecure: Bool = false,
                                timeout: TimeInterval? = nil) -> VideoProbe {
        guard !headers.isEmpty || tlsInsecure else { return ffprobeMetadata(url: url, timeout: timeout) }
        var input: [String] = []
        if tlsInsecure { input += ["-tls_verify", "0"] }
        input += remoteProbeArguments
        input += inputArguments(url: url, headers: headers)
        return ffprobeMetadata(inputArguments: input, timeout: timeout)
    }

    static func ffprobeMetadata(url: URL, timeout: TimeInterval? = nil,
                                includeChapters: Bool = true) -> VideoProbe {
        // 蓝光目录 / ISO 必须走 bluray 协议：直接给目录路径 ffprobe 读不出流信息，
        // 章节 / HDR / 隔行标记也全都拿不到。
        let input = BluraySource.ffmpegInput(for: url) ?? url.path
        // 网络卷上的 SMB / WebDAV 文件也要限制探测读量，否则大文件会卡在 ffprobe 解析上。
        let arguments = url.isFileURL && !isNetworkVolume(url)
            ? ["-i", input]
            : remoteProbeArguments + ["-i", input]
        var probe = ffprobeMetadata(inputArguments: arguments, timeout: timeout,
                                    includeChapters: includeChapters)
        probe = applyingNativePlayability(probe, for: url)
        // libbluray 不把播放列表的章节标记交给 ffmpeg：目录原盘从 MPLS 里补，
        // 否则章节菜单与 ⌥← / ⌥→ 在电影盘上永远不可用。
        if probe.chapters.count < 2, BluraySource.discRoot(for: url) != nil {
            let chapters = BluraySource.chapters(for: url)
            if chapters.count > 1 { probe.chapters = chapters }
        }
        return probe
    }

    private static func ffprobeMetadata(inputArguments: [String],
                                        timeout: TimeInterval? = nil,
                                        includeChapters: Bool = true) -> VideoProbe {
        ffprobeRun(inputArguments: inputArguments, timeout: timeout,
                   includeChapters: includeChapters).probe
    }

    /// 蓝光导入诊断：跑一次 ffprobe 并保留 stderr，
    /// 用来把 AACS / BD+ / 未检测到蓝光结构等失败翻译成明确提示。
    static func blurayProbe(root: URL) -> (probe: VideoProbe, error: String) {
        guard let input = BluraySource.ffmpegInput(for: root) else {
            return (VideoProbe(), "Blu-ray disc not detected")
        }
        // warning 而不是 error：加密盘「The disc is encrypted」这类说明是 warning 级，
        // 只有它才能区分 AACS / BD+ 与「不是蓝光目录」。
        return ffprobeRun(inputArguments: ["-i", input], timeout: 45, logLevel: "warning")
    }

    private static func ffprobeRun(inputArguments: [String],
                                   timeout: TimeInterval?,
                                   logLevel: String = "error",
                                   includeChapters: Bool = true) -> (probe: VideoProbe, error: String) {
        var probe = VideoProbe()
        guard let ffprobe = FFmpeg.probe else { return (probe, "未检测到 ffprobe") }
        let process = Process()
        process.executableURL = ffprobe
        var arguments = ["-v", logLevel, "-print_format", "json",
                         "-show_format", "-show_streams"]
        // 章节留在文件尾部：网络盘 / 大 MKV 上读它会额外跨大半个文件，播放前探测可以跳过。
        if includeChapters { arguments.append("-show_chapters") }
        process.arguments = arguments + inputArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr 落到临时文件：用 Pipe 却不读会写满缓冲区而永久阻塞；
        // 临时文件可以在进程退出后安全读取，失败原因（AACS / BD+ 等）也靠它带出来。
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-ffprobe-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardError = logHandle ?? FileHandle.nullDevice

        func finish() -> String {
            try? logHandle?.close()
            let text = (try? String(contentsOf: logURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            return text
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            _ = finish()
            return (probe, error.localizedDescription)
        }
        if let timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.terminationHandler = nil
                Diagnostics.record("ffprobe 探测超时（\(Int(timeout)) 秒），已终止")
                let text = finish()
                return (probe, text.isEmpty ? "读取超时" : text)
            }
        } else {
            finished.wait()
        }
        let errorText = finish()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (probe, errorText)
        }

        let streams = json["streams"] as? [[String: Any]] ?? []
        guard let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            return (probe, errorText)
        }
        probe.hasVideoTrack = true
        probe.isPlayable = true

        var width = video["width"] as? Int ?? 0
        var height = video["height"] as? Int ?? 0
        var rotation = 0
        if let sideData = video["side_data_list"] as? [[String: Any]],
           let value = sideData.compactMap({ $0["rotation"] as? Double }).first {
            rotation = Int(value)
        } else if let tags = video["tags"] as? [String: Any], let value = tags["rotate"] as? String {
            rotation = Int(value) ?? 0
        }
        rotation = ((rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            swap(&width, &height)
        }
        probe.size = CGSize(width: width, height: height)

        let format = json["format"] as? [String: Any]
        let durationText = (format?["duration"] as? String) ?? (video["duration"] as? String)
        if let text = durationText, let seconds = Double(text) {
            probe.duration = max(0, seconds)
        }
        if let codec = video["codec_name"] as? String {
            probe.codec = prettyCodec(codec)
            probe.isHEVC = codec.lowercased() == "hevc"
        }
        // HDR 判定：PQ（smpte2084）/ HLG（arib-std-b67）或 BT.2020 色域。
        let primaries = (video["color_primaries"] as? String)?.lowercased()
        let transfer = (video["color_transfer"] as? String)?.lowercased()
        probe.isHDR = primaries == "bt2020"
            || transfer == "smpte2084"
            || transfer == "arib-std-b67"

        // 杜比视界：codec_tag_string（dvh1 / dvhe）或 DOVI side data。
        let sideData = video["side_data_list"] as? [[String: Any]] ?? []
        let sideTypes = sideData.compactMap { $0["side_data_type"] as? String }
            .joined(separator: " ").lowercased()
        let codecTag = (video["codec_tag_string"] as? String)?.lowercased() ?? ""
        probe.isDolbyVision = codecTag.hasPrefix("dvh") || codecTag == "dovi"
            || sideTypes.contains("dovi") || sideTypes.contains("dolby vision")
            || sideData.contains(where: { $0["dv_profile"] != nil })
        if probe.isDolbyVision {
            probe.hdrLabel = "Dolby Vision"
        } else if sideTypes.contains("smpte2094-40") || sideTypes.contains("hdr10+") {
            probe.hdrLabel = "HDR10+"
        } else if transfer == "smpte2084" {
            probe.hdrLabel = "HDR10"
        } else if transfer == "arib-std-b67" {
            probe.hdrLabel = "HLG"
        } else if primaries == "bt2020" {
            probe.hdrLabel = "HDR"
        }
        // 完整色彩管线：转封装写回容器、色调映射选滤镜都靠它。
        let dvProfile = sideData.compactMap { $0["dv_profile"] as? Int }.first
            ?? sideData.compactMap { ($0["dv_profile"] as? String).flatMap(Int.init) }.first
        probe.color = VideoColorInfo(
            primaries: normalizedColorValue(primaries),
            transfer: normalizedColorValue(transfer),
            matrix: normalizedColorValue(video["color_space"] as? String),
            range: normalizedColorValue(video["color_range"] as? String),
            codecTag: codecTag.isEmpty ? nil : codecTag,
            isHDR: probe.isHDR,
            isDolbyVision: probe.isDolbyVision,
            dvProfile: dvProfile)

        // Matroska 把 DOVI 配置放在容器侧数据里，ffprobe 不一定输出；
        // 用 ffmpeg 读一次文件头（约 0.1 秒）把 profile 补出来，否则 P5 会被当成普通 HEVC 解码。
        let pixelFormat = (video["pix_fmt"] as? String)?.lowercased() ?? ""
        if probe.isHEVC, !probe.isDolbyVision,
           probe.color.primaries == nil, pixelFormat.contains("10"),
           let profile = dolbyVisionProfile(inputArguments: inputArguments) {
            probe.isDolbyVision = true
            probe.isHDR = true
            probe.color.isDolbyVision = true
            probe.color.isHDR = true
            probe.color.dvProfile = profile
            // P5 的容器标记惯例：BT.2020 + PQ；真正解出正确颜色仍要靠 DOVI RPU。
            probe.color.transfer = "smpte2084"
            probe.color.primaries = "bt2020"
            probe.color.codecTag = probe.color.codecTag ?? "dvh1"
            probe.hdrLabel = "Dolby Vision"
        }

        let averageRate = parseFrameRate(video["avg_frame_rate"])
        probe.frameRate = averageRate > 0 ? averageRate : parseFrameRate(video["r_frame_rate"])
        // 隔行标记：tt / bb / tb / bt 都是隔行（1080i、DVD）；progressive / unknown 不算。
        let fieldOrder = (video["field_order"] as? String)?.lowercased() ?? ""
        probe.isInterlaced = ["tt", "bb", "tb", "bt"].contains(fieldOrder)
        if probe.bitrate == 0,
           let text = format?["bit_rate"] as? String,
           let value = Int(text) {
            probe.bitrate = value
        }
        probe.containerName = format?["format_name"] as? String
        probe.chapters = (json["chapters"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
            guard let start = Double((item["start_time"] as? String) ?? "") else { return nil }
            let end = Double((item["end_time"] as? String) ?? "") ?? start
            let title = ((item["tags"] as? [String: Any])?["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return VideoChapter(start: start,
                                end: end,
                                title: (title?.isEmpty == false ? title! : "第 \(index + 1) 章"))
        }
        let audioStreams = streams.filter { ($0["codec_type"] as? String) == "audio" }
        probe.audioTracks = audioStreams.enumerated().map { offset, stream in
            let tags = stream["tags"] as? [String: Any]
            return AudioTrackInfo(
                ordinal: offset,
                codec: (stream["codec_name"] as? String).map(prettyCodec) ?? "",
                channels: stream["channels"] as? Int ?? 0,
                language: tags?["language"] as? String,
                title: tags?["title"] as? String)
        }
        probe.audioTrackCount = probe.audioTracks.count
        // 内嵌字幕轨：图形字幕（PGS / VobSub）只能烧录，文本字幕可直接提取成 cue。
        let imageSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]
        probe.subtitleTracks = streams
            .filter { ($0["codec_type"] as? String) == "subtitle" }
            .enumerated()
            .map { offset, stream in
                let tags = stream["tags"] as? [String: Any]
                let disposition = stream["disposition"] as? [String: Any]
                let codec = ((stream["codec_name"] as? String) ?? "").lowercased()
                return SubtitleTrackInfo(ordinal: offset,
                                         codec: codec.isEmpty ? "" : prettyCodec(codec),
                                         language: tags?["language"] as? String,
                                         title: tags?["title"] as? String,
                                         isImage: imageSubtitleCodecs.contains(codec),
                                         isForced: (disposition?["forced"] as? Int) == 1,
                                         isDefault: (disposition?["default"] as? Int) == 1)
            }
        return (probe, errorText)
    }

    /// 用 ffmpeg 读一次文件头，从 DOVI configuration record 里取 profile。
    /// ffprobe 对 Matroska 的 DOVI 侧数据支持不稳定，这一步只读头部、约 0.1 秒。
    private static func dolbyVisionProfile(inputArguments: [String],
                                           timeout: TimeInterval = 10) -> Int? {
        guard let ffmpeg = FFmpeg.executable else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        // 不带输出文件：ffmpeg 打印完流信息就会退出，不会真的解码。
        process.arguments = ["-hide_banner", "-nostdin", "-v", "info"] + inputArguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            guard finished.wait(timeout: .now() + 2) != .timedOut else {
                kill(process.processIdentifier, SIGKILL)
                return nil
            }
        }
        let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") where line.contains("DOVI configuration record") {
            guard let range = line.range(of: "profile:") else { continue }
            let digits = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .prefix(while: { $0.isNumber })
            if let profile = Int(digits) { return profile }
        }
        return nil
    }

    /// ffprobe 的帧率是 `30000/1001` 这样的分数，也兼容直接的浮点数。
    private static func parseFrameRate(_ raw: Any?) -> Double {
        guard let text = raw as? String, !text.isEmpty else { return 0 }
        let parts = text.split(separator: "/")
        if parts.count == 2,
           let numerator = Double(parts[0]),
           let denominator = Double(parts[1]),
           denominator > 0 {
            return numerator / denominator
        }
        return Double(text) ?? 0
    }

    /// 生成视频缩略图：先走 AVFoundation，失败则用 ffmpeg 抽帧。
    @discardableResult
    static func makeThumbnail(url: URL, destination: URL) -> Bool {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        for seconds in [0.2, 0.0, 1.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                ImportService.writeJPEG(image, to: destination, quality: 0.9)
                return true
            }
        }

        guard let ffmpeg = FFmpeg.executable else { return false }
        // ffmpeg 同样先写临时文件，成功后再替换：读取方（网格 / 内容识别）不会读到半张图。
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).jpg")
        let process = Process()
        process.executableURL = ffmpeg
        // 蓝光原盘用 bluray 协议读取；对原盘做输入级 -ss 不稳定，直接取首帧。
        let blurayInput = BluraySource.ffmpegInput(for: url)
        var arguments = ["-y", "-v", "error"]
        if blurayInput == nil { arguments += ["-ss", "0.3"] }
        arguments += ["-i", blurayInput ?? url.path,
                      "-frames:v", "1", "-vf", "scale='min(1200,iw)':-2", temp.path]
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        ThumbnailFileIndex.shared.recordWrite(url: destination)
        return true
    }

    /// 远端抽帧：MKV 等容器系统无法解码，由 ffmpeg 直接读取远端地址（带认证头）。
    @discardableResult
    static func makeRemoteThumbnail(url: URL, headers: [String: String],
                                    trustSelfSigned: Bool = false, destination: URL) -> Bool {
        guard let ffmpeg = FFmpeg.executable else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString).jpg")
        var arguments = ["-y", "-v", "error"]
        if !headers.isEmpty {
            arguments += ["-headers", headerBlock(headers)]
        }
        // NAS 的自签名证书：只有挂载点明确信任时才跳过校验。
        if trustSelfSigned {
            arguments += ["-tls_verify", "0"]
        }
        arguments += ["-ss", "1"]
        arguments += inputArguments(url: url, headers: [:])
        arguments += ["-frames:v", "1", "-vf", "scale='min(1200,iw)':-2", temp.path]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        return true
    }

    /// 用 ffmpeg 转成 H.264 + AAC 的 MP4，供系统不支持解码的容器播放。
    /// HDR 源按需做色调映射，避免 SDR 屏幕发灰 / 过曝。
    static func transcode(source: URL, destination: URL, toneMapHDR: Bool = false,
                          isDolbyVision: Bool = false,
                          sourceSize: CGSize = .zero,
                          frameRate: Double = 0,
                          color: VideoColorInfo = VideoColorInfo()) async throws {
        try await transcode(inputArguments: ["-i", source.path],
                            destination: destination,
                            toneMapHDR: toneMapHDR,
                            isDolbyVision: isDolbyVision,
                            sourceSize: sourceSize,
                            frameRate: frameRate,
                            color: color)
    }

    /// HDR → SDR 色调映射的滤镜链（定义在内核，播放与导入共用）。
    static let hdrToneMapChain = PlaybackFilters.hdrToneMapChain

    /// HDR → SDR 色调映射参数；内置 ffmpeg 不带 zscale 时返回空，退化为普通转码。
    /// 杜比视界必须走 libplacebo（应用 DOVI RPU），否则返回空：宁可保持原封装也不要烘错颜色。
    static func hdrToneMapArguments(toneMapHDR: Bool, isDolbyVision: Bool = false,
                                    outputSize: CGSize? = nil,
                                    color: VideoColorInfo = VideoColorInfo()) -> [String] {
        guard toneMapHDR, supportsToneMapping,
              let chain = PlaybackFilters.toneMapChain(
                  dolbyVision: isDolbyVision,
                  supportsLibplacebo: supportsLibplacebo,
                  outputWidth: outputSize.map { Int($0.width) },
                  outputHeight: outputSize.map { Int($0.height) },
                  inputColor: color)
        else { return [] }
        return ["-vf", chain,
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    }

    /// ffmpeg 的 subtitles 烧录滤镜；路径里的反斜杠、冒号与单引号必须转义。
    static func subtitleBurnFilter(_ url: URL) -> String {
        PlaybackFilters.subtitleBurnFilter(url)
    }

    /// 是否有可用的 zscale + tonemap（内置静态包已带 libzimg，缺失时回退系统 ffmpeg）。
    /// 只要 zscale 或 libplacebo 任一可用，就具备色调映射能力。
    static var supportsToneMapping: Bool {
        FFmpeg.toneMapExecutable != nil || FFmpeg.libplaceboExecutable != nil
    }

    /// 是否有能应用杜比视界 DOVI RPU 的 ffmpeg（libplacebo）。
    static var supportsLibplacebo: Bool { FFmpeg.libplaceboExecutable != nil }

    /// 设置页展示用：杜比视界 Profile 5 当前能否正确还原。
    static var dolbyVisionSupportText: String {
        if supportsLibplacebo { return "已就绪（libplacebo + MoltenVK）" }
        if supportsToneMapping { return "未安装：杜比视界 P5 会偏绿，HDR10 / HLG 正常" }
        return "未安装：HDR 片源无法色调映射"
    }

    /// 缺失时给出可直接执行的安装命令。发布包里已内置 ffmpeg-full + MoltenVK，
    /// 只有在构建时没能打包（例如开发机没装 ffmpeg-full）才会走到这里。
    static let dolbyVisionInstallHint =
        "brew install ffmpeg-full molten-vk（需原生 arm64 Homebrew，keg-only 无需配置）"

    /// 从远端直播流录制一段固定时长（复制封装，不重编码）：电视「30 秒片段」走这里，
    /// 录完由统一的入库服务收进图库，不再各自写一套 ffmpeg 参数与落盘位置。
    static func recordRemoteClip(source: URL,
                                 headers: [String: String],
                                 trustSelfSigned: Bool = false,
                                 seconds: Int,
                                 destination: URL) async throws {
        guard let ffmpeg = FFmpeg.executable else { throw VideoError.transcodeUnavailable }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var arguments = ["-y", "-v", "error"]
        if trustSelfSigned { arguments += ["-tls_verify", "0"] }
        arguments += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        arguments += inputArguments(url: source, headers: headers)
        arguments += ["-t", "\(seconds)", "-c", "copy",
                      "-movflags", "+faststart", destination.path]
        let status = try await run(ffmpeg, arguments)
        guard status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw VideoError.transcodeFailed
        }
    }

    /// 云端视频转码：ffmpeg 直接从远端读取（带认证头）。
    /// 先尝试把视频流无损封装进 MP4（仅音频转 AAC），系统仍无法播放时再全量转 H.264。
    static func transcodeRemote(source: URL, headers: [String: String],
                                trustSelfSigned: Bool = false,
                                toneMapHDR: Bool = false,
                                isDolbyVision: Bool = false,
                                destination: URL) async throws {
        guard let ffmpeg = FFmpeg.executable else { throw VideoError.transcodeUnavailable }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        var tlsArguments: [String] = []
        if trustSelfSigned { tlsArguments = ["-tls_verify", "0"] }
        var inputArguments = tlsArguments
        inputArguments += self.inputArguments(url: source, headers: headers)

        let metadata = ffprobeMetadata(url: source, headers: headers, tlsInsecure: trustSelfSigned)
        let remuxed = destination.deletingLastPathComponent()
            .appendingPathComponent(".remux-\(UUID().uuidString).mp4")
        var arguments = ["-y", "-v", "error"]
        arguments += inputArguments
        arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
        // AVFoundation 只认 hvc1 标签，ffmpeg 默认写 hev1。
        if metadata.codec == "HEVC" { arguments += ["-tag:v", "hvc1"] }
        arguments += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", remuxed.path]

        _ = try? await run(ffmpeg, arguments)
        if FileManager.default.fileExists(atPath: remuxed.path) {
            let check = await probe(asset: AVURLAsset(url: remuxed))
            if check.hasVideoTrack, check.isPlayable {
                try moveIntoPlace(remuxed, destination: destination)
                return
            }
            try? FileManager.default.removeItem(at: remuxed)
        }
        // HDR 源不能走无损封装时，必须做色调映射后再编码。
        try await transcode(inputArguments: inputArguments,
                            destination: destination,
                            toneMapHDR: toneMapHDR || metadata.isHDR,
                            isDolbyVision: metadata.isDolbyVision,
                            sourceSize: metadata.size,
                            frameRate: metadata.frameRate,
                            color: metadata.color)
    }

    private static func transcode(inputArguments: [String], destination: URL,
                                  toneMapHDR: Bool, isDolbyVision: Bool = false,
                                  sourceSize: CGSize = .zero,
                                  frameRate: Double = 0,
                                  color: VideoColorInfo = VideoColorInfo()) async throws {
        // 离线整片转换同样按档位走：4K60 这类高像素率片源降到 1440p，避免整片转几十分钟。
        // frameRate 必须用真实值：按 30fps 估算会让 4K60 不降档。
        let settings = AppSettings.shared
        let profile = TranscodeProfile.make(sourceSize: sourceSize,
                                            frameRate: frameRate,
                                            transcodeMode: settings.videoTranscodeMode)
        let toneMap = hdrToneMapArguments(toneMapHDR: toneMapHDR, isDolbyVision: isDolbyVision,
                                          outputSize: profile.outputSize,
                                          color: color)
        guard let ffmpeg = FFmpeg.executable(preferToneMap: !toneMap.isEmpty,
                                             preferLibplacebo: !toneMap.isEmpty && isDolbyVision) else {
            throw VideoError.transcodeUnavailable
        }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".transcode-\(UUID().uuidString).mp4")

        let usesHEVC = profile.codec == .hevc
        var arguments = ["-y", "-v", "error"]
        arguments += inputArguments
        arguments += ["-map", "0:v:0",
                      "-map", "0:a:0?",
                      // 硬件编码比 libx264 medium 快一个数量级，整片转换不必再等几十分钟。
                      "-c:v", usesHEVC ? "hevc_videotoolbox" : "h264_videotoolbox",
                      "-b:v", "\(profile.bitrate)", "-maxrate", "\(profile.maxrate)",
                      "-bufsize", "\(profile.bufsize)", "-allow_sw", "1"]
        if usesHEVC {
            // AVFoundation 只认 hvc1；Main10 与 10-bit 输出已在边下边播链路上实测可播放。
            arguments += ["-tag:v", "hvc1", "-profile:v", "main10"]
            if settings.videoTranscodeMode == .lowPower {
                arguments += ["-power_efficient", "1", "-prio_speed", "1"]
            }
        }
        if toneMap.isEmpty {
            // 不需要映射时也要按档位降分辨率；不降就只锁像素格式。
            if let outputHeight = profile.outputSize.map({ Int($0.height) }) {
                arguments += ["-vf", "scale=-2:\(outputHeight)"]
            }
        } else {
            arguments += toneMap
        }
        arguments += ["-pix_fmt", profile.pixelFormat]
        // 音频默认保持源声道与较高码率；只有手动选「立体声」才下混到 2.0。
        if settings.audioDownmix == .stereo {
            arguments += ["-c:a", "aac", "-b:a", "256k", "-ac", "2"]
        } else {
            arguments += ["-c:a", "aac", "-b:a", "512k"]
        }
        arguments += ["-movflags", "+faststart",
                      partial.path]
        let status = try await run(ffmpeg, arguments)

        guard status == 0, FileManager.default.fileExists(atPath: partial.path) else {
            try? FileManager.default.removeItem(at: partial)
            throw VideoError.transcodeFailed
        }
        try moveIntoPlace(partial, destination: destination)
    }

    /// ffmpeg 的 `-headers`：每个请求头一行，以 CRLF 结尾。
    private static func headerBlock(_ headers: [String: String]) -> String {
        headers.map { "\($0.key): \($0.value)\r\n" }.joined()
    }

    private static func inputArguments(url: URL, headers: [String: String]) -> [String] {
        var arguments: [String] = []
        if !headers.isEmpty {
            arguments += ["-headers", headerBlock(headers)]
        }
        // 蓝光目录 / ISO 必须用 bluray 协议，file URL 交给 ffmpeg 是打不开的。
        arguments += ["-i", BluraySource.ffmpegInput(for: url) ?? url.absoluteString]
        return arguments
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // 内置 MoltenVK 的 ICD 路径：libplacebo 走 Vulkan 时必须显式告知。
        let environment = FFmpeg.processEnvironment
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func moveIntoPlace(_ partial: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    static func codecDisplayName(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let raw = String(bytes: bytes, encoding: .ascii) ?? ""
        return prettyCodec(raw)
    }

    private static func prettyCodec(_ raw: String) -> String {
        switch raw.lowercased() {
        case "avc1", "h264", "x264": return "H.264"
        case "hvc1", "hev1", "hevc", "h265": return "HEVC"
        case "vp09", "vp9": return "VP9"
        case "vp08", "vp8": return "VP8"
        case "av01", "av1": return "AV1"
        case "mp4v", "mpeg4": return "MPEG-4"
        case "ap4h", "apch", "apcn", "apcs", "apco", "ap4x": return "ProRes"
        case "mjpg", "mjpeg": return "Motion JPEG"
        case "mpeg2video", "m2v1": return "MPEG-2"
        case "theora": return "Theora"
        case "rv40", "rv30": return "RealVideo"
        case "wmv3", "wmv2", "wmv1": return "WMV"
        case "flv1": return "Sorenson H.263"
        default: return raw.isEmpty ? "未知编码" : raw.uppercased()
        }
    }
}
