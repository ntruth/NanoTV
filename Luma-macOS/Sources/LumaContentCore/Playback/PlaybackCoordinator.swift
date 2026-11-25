import Foundation
import PlaybackCore

/// 解析完成后的播放会话：播放器只消费它，不再自己判断模式与能力。
public struct ResolvedPlayback: Hashable, Sendable {
    public var target: PlaybackTarget
    public var stream: ResolvedStream

    public init(target: PlaybackTarget, stream: ResolvedStream) {
        self.target = target
        self.stream = stream
    }

    /// 模式以 `PlaybackTarget` 为准：适配器返回的流不能改变直播 / 点播语义。
    public var mode: PlaybackMode { target.mode }
    public var capabilities: PlaybackCapabilities { target.capabilities }

    public var isLive: Bool { mode.isLive }
    public var canSeek: Bool { !isLive && capabilities.contains(.seek) }
    public var canResume: Bool { !isLive && capabilities.contains(.resume) }
    public var canAutoAdvance: Bool { !isLive && capabilities.contains(.nextEpisode) }
    public var showsLiveEdge: Bool { capabilities.contains(.liveEdge) }
}

/// 播放协调器：把 `PlaybackTarget` 解析成 `PlaybackSession` 的唯一入口。
/// 不碰 UI、不写进度；进度由 `PlaybackProgressStore` 管理。
public final class PlaybackCoordinator: Sendable {
    private let resolver: any PlaybackResolving

    public init(resolver: any PlaybackResolving) {
        self.resolver = resolver
    }

    public func prepare(_ target: PlaybackTarget) async throws -> ResolvedPlayback {
        let stream = try await resolver.resolve(target)
        return session(for: target, stream: stream)
    }

    /// 已经用现有流程拿到流的场景（图库 / 云盘 / 影院 / 资源），
    /// 用它补上统一的模式与能力语义。
    public func session(for target: PlaybackTarget, stream: ResolvedStream) -> ResolvedPlayback {
        var normalized = stream
        // 直播不携带时长 / 续播语义，统一以 target 为准。
        normalized.mode = target.mode
        return ResolvedPlayback(target: target, stream: normalized)
    }
}

/// 不需要业务查找的解析器：本地文件、已知远端地址直接播放。
/// 电视直播与在线影院先走它；需要源适配器的 `.provider` 由各自模块注册。
public struct DirectPlaybackResolver: PlaybackResolving {
    public init() {}

    public func resolve(_ target: PlaybackTarget) async throws -> ResolvedStream {
        switch target.storage {
        case .localFile(let path):
            return ResolvedStream(url: URL(fileURLWithPath: path), mode: target.mode)

        case .remote(let address, let profile):
            guard let url = URL(string: address) else {
                throw SourceError.parse("播放地址无效：\(address)")
            }
            let ext = url.pathExtension.lowercased()
            return ResolvedStream(url: url,
                                  headers: profile.headerFields,
                                  isHLS: ext == "m3u8",
                                  mode: target.mode,
                                  trustSelfSigned: profile.trustSelfSigned)

        case .provider(let sourceID, let itemID, let episodeID):
            let suffix = episodeID.map { "/\($0)" } ?? ""
            throw SourceError.unsupported("源 \(sourceID.rawValue) 还没有播放解析器（\(itemID)\(suffix)）")
        }
    }
}
