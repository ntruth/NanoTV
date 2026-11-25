import Foundation
import CoreGraphics

/// 音轨信息：用于播放器的音轨菜单展示语言 / 声道 / 编码。
public struct AudioTrackInfo: Identifiable, Equatable, Codable, Sendable {
    /// 在音频流中的序号（0 起），与 ffmpeg 的 `-map 0:a:N` 对应。
    public let ordinal: Int
    public let codec: String
    public let channels: Int
    public let language: String?
    public let title: String?

    public var id: Int { ordinal }

    public var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, language.lowercased() != "und" {
            parts.append(language)
        }
        if channels > 0 {
            parts.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : channels == 2 ? "立体声" : "\(channels) 声道")
        }
        if !codec.isEmpty { parts.append(codec) }
        return parts.joined(separator: " · ")
    }

    public init(ordinal: Int, codec: String, channels: Int, language: String?, title: String?) {
        self.ordinal = ordinal
        self.codec = codec
        self.channels = channels
        self.language = language
        self.title = title
    }
}

/// 内嵌字幕轨：用于字幕菜单与 ffmpeg 提取。
public struct SubtitleTrackInfo: Identifiable, Equatable {
    /// 在字幕流中的序号（0 起），与 ffmpeg 的 `-map 0:s:N` 对应。
    public let ordinal: Int
    public let codec: String
    public let language: String?
    public let title: String?
    /// 图形字幕（PGS / VobSub 等）无法转成文本，只能烧录。
    public let isImage: Bool
    /// forced 轨只翻译对白以外的内容（招牌 / 歌曲），自动挂载时排在完整轨之后。
    public let isForced: Bool
    /// 容器标记的默认轨：同语言多轨时优先。
    public let isDefault: Bool

    public var id: Int { ordinal }

    public var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, language.lowercased() != "und" {
            parts.append(language)
        }
        if !codec.isEmpty { parts.append(codec) }
        if isImage { parts.append("图形") }
        if isForced { parts.append("强制") }
        return parts.isEmpty ? "字幕 \(ordinal + 1)" : parts.joined(separator: " · ")
    }

    public init(ordinal: Int, codec: String, language: String?, title: String?, isImage: Bool,
                isForced: Bool = false, isDefault: Bool = false) {
        self.ordinal = ordinal
        self.codec = codec
        self.language = language
        self.title = title
        self.isImage = isImage
        self.isForced = isForced
        self.isDefault = isDefault
    }
}

/// 一个视频章节：来自 ffprobe 的 `chapters`，用于播放器章节菜单与快捷键。
public struct VideoChapter: Identifiable, Equatable {
    public let start: Double
    public let end: Double
    public let title: String
    public var id: Double { start }

    public init(start: Double, end: Double, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

/// 片源的色彩管线信息：转封装时原样写回容器，避免 HDR / 杜比视界被当成 SDR 解码。
///
/// 字段值与 ffmpeg / ffprobe 的输出保持一致（bt2020 / smpte2084 / arib-std-b67 / tv），
/// 可以直接拼进 `-color_primaries` 等参数。
public struct VideoColorInfo: Equatable, Sendable {
    /// bt709 / bt2020 / smpte432…
    public var primaries: String?
    /// bt709 / smpte2084 / arib-std-b67…
    public var transfer: String?
    /// bt709 / bt2020nc…
    public var matrix: String?
    /// tv（limited）/ pc（full）。
    public var range: String?
    /// 视频流原始 codec tag：hvc1 / hev1 / dvh1 / dvhe。
    public var codecTag: String?
    public var isHDR: Bool
    public var isDolbyVision: Bool
    /// 杜比视界 profile：5 的 base layer 是 IPT，没有 DOVI 处理必然偏绿 / 偏紫。
    public var dvProfile: Int?

    public init(primaries: String? = nil, transfer: String? = nil, matrix: String? = nil,
                range: String? = nil, codecTag: String? = nil,
                isHDR: Bool = false, isDolbyVision: Bool = false, dvProfile: Int? = nil) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.codecTag = codecTag
        self.isHDR = isHDR
        self.isDolbyVision = isDolbyVision
        self.dvProfile = dvProfile
    }

    public var isEmpty: Bool {
        primaries == nil && transfer == nil && matrix == nil && range == nil
            && codecTag == nil && !isHDR && !isDolbyVision
    }

    /// 转封装要写回的 codec tag：杜比视界保留 dvh1 / dvhe（Matroska 没有 tag 时补 dvh1），
    /// 其余交给调用方按编码处理。把 dvhe 改成 hvc1 会让 AVFoundation 直接忽略 DOVI 元数据。
    public var remuxCodecTag: String? {
        guard isDolbyVision else { return nil }
        if let codecTag, codecTag.hasPrefix("dvh") { return codecTag }
        return "dvh1"
    }
}

/// 播放前的探测结果：容器 / 编码 / HDR / 音轨 / 章节。
public struct VideoProbe {
    public var isPlayable = false
    public var hasVideoTrack = false
    public var duration: Double = 0
    public var size: CGSize = .zero
    public var codec: String?
    /// HEVC 转封装时需要显式写 hvc1 标签，AVFoundation 不认 ffmpeg 默认的 hev1。
    public var isHEVC = false
    /// HDR（PQ / HLG）：转码时按需做色调映射，避免 SDR 屏幕发灰。
    public var isHDR = false
    /// 杜比视界：ffprobe 的 codec_tag_string（dvh1 / dvhe）或 DOVI side data。
    public var isDolbyVision = false
    /// 展示用 HDR 标记：Dolby Vision / HDR10+ / HDR10 / HLG。
    public var hdrLabel: String?
    /// 完整色彩管线：转封装写回容器、色调映射选滤镜都靠它。
    public var color = VideoColorInfo()
    /// 整体码率（bps），来自 format.bit_rate。
    public var bitrate: Int = 0
    /// 帧率（fps），来自 avg_frame_rate / r_frame_rate 或 AVAssetTrack。
    public var frameRate: Double = 0
    /// 隔行片源（ffprobe 的 field_order 为 tt / bb / tb / bt）：转码时必须先做去隔行。
    /// DVD / 老蓝光演唱会常见 1080i，不处理会出现梳齿。
    public var isInterlaced = false
    /// 系统能否解码主视频轨（AVAssetTrack.isDecodable）。
    /// false 时既不能直连也不能只转封装：AVPlayer 会出声音但画面是黑的，必须重编码。
    public var isVideoDecodable = true
    /// 蓝光多角度视角数量：1 表示普通影片。来自主播放列表（MPLS）。
    public var angleCount = 1
    /// 容器名（format_name，例如 matroska,webm）。
    public var containerName: String?
    /// 章节列表；没有章节时为空。
    public var chapters: [VideoChapter] = []
    /// 音轨数量：HLS 转封装一次只映射一条，用来决定是否显示音轨切换。
    public var audioTrackCount = 0
    /// 音轨明细（ffprobe 能拿到语言 / 声道 / 编码）。
    public var audioTracks: [AudioTrackInfo] = []
    /// 内嵌字幕轨（可提取成文本 cue，图形字幕只能烧录）。
    public var subtitleTracks: [SubtitleTrackInfo] = []

    public init() {}
}

public extension VideoProbe {
    /// AVFoundation 对 `hev1` 标签的 HEVC 会返回 `isPlayable = false`（视频轨也报
    /// `isDecodable = false`），但 AVPlayer 实际能起播。若只看 `isPlayable`，这类 MP4/MOV
    /// 会被误判成「不能直读」，白走一次 remux。
    ///
    /// 只在 AVFoundation 已知可播的容器 + 编码组合上放宽；MKV / AVI / WebM 的轨道通常
    /// 根本读不到（`hasVideoTrack == false`），不会被这里救活。
    static func allowsNativePlayback(assetIsPlayable: Bool,
                                     hasVideoTrack: Bool,
                                     codec: String?,
                                     containerExtension: String?,
                                     audioDecodable: Bool = true) -> Bool {
        guard hasVideoTrack, audioDecodable else { return false }
        if assetIsPlayable { return true }
        // 只给「HEVC + MP4/MOV」这条已确认误报的路径放宽；H.264 / ProRes 的
        // isPlayable=false 通常是真的解不了，不能一并放过。
        let containers: Set<String> = ["mp4", "m4v", "mov", "qt"]
        guard let ext = containerExtension?.lowercased(), containers.contains(ext) else {
            return false
        }
        return codec == "HEVC"
    }
}

public enum VideoError: LocalizedError {
    case transcodeUnavailable
    case transcodeFailed
    /// 带 ffmpeg 输出的失败原因（401、编码不支持等）。
    case transcodeFailedMessage(String)

    public var errorDescription: String? {
        switch self {
        case .transcodeUnavailable:
            return "未检测到 ffmpeg，无法转换该视频格式"
        case .transcodeFailed:
            return "视频转换失败"
        case .transcodeFailedMessage(let message):
            return "视频转换失败：\(message)"
        }
    }
}
