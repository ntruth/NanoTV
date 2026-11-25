import Foundation

/// 重编码目标编码：兼容优先（H.264）或效率优先（HEVC / 低功耗 HEVC）。
///
/// 只影响需要重编码的链路（边下边播转码、离线「转换为兼容格式」）；remux 始终原样拷贝视频。
public enum VideoTranscodeMode: String, CaseIterable, Identifiable, Sendable {
    /// H.264：所有 Mac 与旧设备都能解，兼容性最好。
    case compatibility
    /// HEVC：同码率画质更好，体积更小；输出 hvc1，AVPlayer 原生支持。
    case efficiency
    /// HEVC + 低功耗编码：速度 / 发热优先，画质略软。
    case lowPower

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compatibility: return "兼容"
        case .efficiency: return "高效"
        case .lowPower: return "低功耗"
        }
    }

    public var detail: String {
        switch self {
        case .compatibility:
            return "H.264 编码，所有设备都能解码；兼容性最好，码率也最高。"
        case .efficiency:
            return "HEVC（hvc1）编码，同码率画质更好、体积更小；本机 AVPlayer 原生支持。"
        case .lowPower:
            return "HEVC 低功耗编码，编码更快、发热更低；画质略软，适合长片与笔记本电池供电。"
        }
    }

    public var usesHEVC: Bool { self != .compatibility }
}

/// 转码输出的视频编码（与 `VideoTranscodeMode` 的区别：这里只描述编码本身）。
public enum TranscodeVideoCodec: String, Equatable, Sendable {
    case h264
    case hevc
}

/// 多声道音频的输出方式。
public enum AudioDownmixMode: String, CaseIterable, Identifiable, Sendable {
    /// 保持源声道：5.1 / 7.1 原样保留，由系统按输出设备自行下混。
    case source
    /// 强制立体声：所有需要重编码的音轨统一成 2.0。
    case stereo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return "保持原样"
        case .stereo: return "立体声"
        }
    }

    public var detail: String {
        switch self {
        case .source:
            return "默认保持原音质：能直通就直通；DTS-HD / TrueHD 用 E-AC-3 1536k，不下混。"
        case .stereo:
            return "仅手动选择时生效：多声道统一下混为 2.0，适合耳机或显示器扬声器。"
        }
    }
}

/// 单条音轨在 HLS 会话里的处理方式。
public enum AudioTrackAction: Equatable, Sendable {
    case copy
    case eac3
    case aac
}

/// 逐条音轨的音频策略：部分轨道直通、部分重编码，同一次 HLS 会话里可以混合。
public enum AudioPlaybackPlan {
    /// 可以直接拷进 fMP4 HLS、且 AVPlayer 原生支持的音轨编码。
    /// AC-3 / E-AC-3 已实测（5.1）：AVPlayer 对 fMP4 HLS 中的 `ac-3 / ec-3` 返回 readyToPlay 且音轨可见。
    public static let copyableCodecs: Set<String> = ["aac", "alac", "ac3", "eac3"]

    /// DTS-HD / TrueHD 这类 AVPlayer 无法解码的高码率多声道声轨：
    /// 重编码目标用 E-AC-3 1536k（蓝光常见档），比 AC-3 640k 保留更多细节；实测 AVPlayer 可播。
    public static func prefersEAC3(codec: String?, channels: Int) -> Bool {
        guard channels > 2 else { return false }
        return ["dts", "dts-hd", "truehd", "mlp"].contains((codec ?? "").lowercased())
    }

    /// 单轨决策。`copiesVideo` = 视频是 remux 拷贝；需要重编码视频时仍可直通音频。
    public static func action(codec: String?,
                              channels: Int,
                              downmix: AudioDownmixMode,
                              allowPassthrough: Bool,
                              copiesVideo: Bool) -> AudioTrackAction {
        // 立体声模式必须重编码：多声道源没法用拷贝把 6 声道变成 2 声道。
        if downmix == .stereo, channels > 2 { return .aac }
        guard allowPassthrough, copiesVideo else { return .aac }
        if copyableCodecs.contains((codec ?? "").lowercased()) { return .copy }
        if prefersEAC3(codec: codec, channels: channels) { return .eac3 }
        return .aac
    }

    /// AAC 目标码率：多声道给 512k，立体声给 256k。
    public static func aacBitrate(channels: Int, downmix: AudioDownmixMode) -> String {
        channels > 2 && downmix == .source ? "512k" : "256k"
    }
}
