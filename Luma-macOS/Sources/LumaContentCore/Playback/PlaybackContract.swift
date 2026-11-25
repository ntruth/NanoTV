import Foundation
import PlaybackCore

/// 请求画像：站点 / 网盘 / 直播源共用的 UA、Referer、请求头与证书策略。
public struct RequestProfile: Hashable, Codable, Sendable {
    public var userAgent: String?
    public var referer: String?
    public var headers: [String: String]
    public var trustSelfSigned: Bool

    public init(userAgent: String? = nil,
                referer: String? = nil,
                headers: [String: String] = [:],
                trustSelfSigned: Bool = false) {
        self.userAgent = userAgent
        self.referer = referer
        self.headers = headers
        self.trustSelfSigned = trustSelfSigned
    }

    public var headerFields: [String: String] {
        var fields = headers
        if let userAgent, !userAgent.isEmpty { fields["User-Agent"] = userAgent }
        if let referer, !referer.isEmpty { fields["Referer"] = referer }
        return fields
    }

    /// 拾光自身抓 M3U / EPG / 台标的默认画像。
    public static let luma = RequestProfile(userAgent: "Luma/2.0 (macOS)")

    /// 站点适配器抓页面的浏览器画像：多数站点按 UA 决定返回桌面版还是拦截页。
    public static let browser = RequestProfile(
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
}

/// 播放目标：播放器唯一认识的输入。
/// 具体直链由 PlaybackResolving 懒解析，签名地址不进入持久化。
public struct PlaybackTarget: Identifiable, Hashable, Codable, Sendable {
    public enum Storage: Hashable, Codable, Sendable {
        /// 本地文件。
        case localFile(path: String)
        /// 已知远端地址（云盘直链、直播流、站点直链）。
        case remote(url: String, profile: RequestProfile)
        /// 交给源适配器解析：sourceID + itemID + 可选集号。
        case provider(sourceID: SourceID, itemID: String, episodeID: String?)
    }

    public var id: UUID
    public var storage: Storage
    public var mode: PlaybackMode
    public var title: String
    public var subtitle: String?
    public var artworkURL: String?
    public var durationHint: Double?
    public var capabilities: PlaybackCapabilities

    public init(id: UUID = UUID(),
                storage: Storage,
                mode: PlaybackMode,
                title: String,
                subtitle: String? = nil,
                artworkURL: String? = nil,
                durationHint: Double? = nil,
                capabilities: PlaybackCapabilities? = nil) {
        self.id = id
        self.storage = storage
        self.mode = mode
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.durationHint = durationHint
        self.capabilities = capabilities ?? (mode == .live ? .live : .vod)
    }

    public var isLive: Bool { mode == .live }

    public var canSeek: Bool { capabilities.contains(.seek) }
    public var canResume: Bool { capabilities.contains(.resume) }
    public var hasNextEpisode: Bool { capabilities.contains(.nextEpisode) }
}

/// 播放目标解析器：本地 / 云盘 / 站点 / 影院 / 电视共用一个入口。
public protocol PlaybackResolving: Sendable {
    func resolve(_ target: PlaybackTarget) async throws -> ResolvedStream
}

/// 播放进度记录：按源 + 条目 + 集号定位。
public struct PlaybackProgress: Identifiable, Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var itemID: String
    public var episodeID: String?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public var id: String {
        "\(sourceID.rawValue)#\(itemID)#\(episodeID ?? "-")"
    }

    public init(sourceID: SourceID,
                itemID: String,
                episodeID: String? = nil,
                position: Double,
                duration: Double,
                updatedAt: Date = Date()) {
        self.sourceID = sourceID
        self.itemID = itemID
        self.episodeID = episodeID
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    public var isFinished: Bool {
        duration > 0 && position >= duration - 8
    }
}

/// 播放进度存储：影院、资源、云盘、未来电视共用一个接口。
/// 现有实现都在主线程模型上读写，因此协议固定为 `@MainActor`，避免跨线程改 UI 状态。
@MainActor
public protocol PlaybackProgressStore: AnyObject {
    func progress(sourceID: SourceID, itemID: String, episodeID: String?) -> PlaybackProgress?
    func save(_ progress: PlaybackProgress)
    func remove(sourceID: SourceID, itemID: String, episodeID: String?)
    func removeAll(sourceID: SourceID)
}
