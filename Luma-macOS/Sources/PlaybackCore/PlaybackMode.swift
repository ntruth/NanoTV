import Foundation

/// 播放模式：点播与直播的语义差异必须由内核显式表达，
/// 不能只靠「duration 是否为 0」在界面里猜。
public enum PlaybackMode: String, Codable, Hashable, Sendable {
    /// 点播：有明确时长，可续播、可拖动、可预加载下一集。
    case vod
    /// 直播：没有有限时长，不续播、不写进度、不自动跳片尾。
    case live

    public var isLive: Bool { self == .live }
}

/// 播放能力：界面按能力隐藏控件，而不是在每个视图里判断模式。
public struct PlaybackCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// 可拖动进度条。
    public static let seek = PlaybackCapabilities(rawValue: 1 << 0)
    /// 可续播。
    public static let resume = PlaybackCapabilities(rawValue: 1 << 1)
    /// 有下一集 / 自动连播。
    public static let nextEpisode = PlaybackCapabilities(rawValue: 1 << 2)
    /// 可加载字幕。
    public static let subtitles = PlaybackCapabilities(rawValue: 1 << 3)
    /// 直播可回到直播沿。
    public static let liveEdge = PlaybackCapabilities(rawValue: 1 << 4)
    /// 支持回看 / 时移。
    public static let catchup = PlaybackCapabilities(rawValue: 1 << 5)

    public static let vod: PlaybackCapabilities = [.seek, .resume, .nextEpisode, .subtitles]
    public static let live: PlaybackCapabilities = [.liveEdge]
}

extension PlaybackCapabilities: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 解析后的真实播放流：短时效，不落库。
/// 直链、请求头、容器类型与播放模式是播放器唯一需要的片源信息。
public struct ResolvedStream: Hashable, Sendable {
    public var url: URL
    public var headers: [String: String]
    public var isHLS: Bool
    public var mode: PlaybackMode
    /// 源要求放行自签证书时置位；播放器与资源加载器据此决定是否校验证书。
    public var trustSelfSigned: Bool

    public init(url: URL,
                headers: [String: String] = [:],
                isHLS: Bool = false,
                mode: PlaybackMode = .vod,
                trustSelfSigned: Bool = false) {
        self.url = url
        self.headers = headers
        self.isHLS = isHLS
        self.mode = mode
        self.trustSelfSigned = trustSelfSigned
    }
}
