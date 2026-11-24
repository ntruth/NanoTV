import Foundation
import NanoCore

/// 跨源播放进度持久化记录（每 5 秒自动落库，支持下次点开精准续播）
public struct PlaybackProgressRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String           // 唯一键："\(sourceID)_\(vfsPath)" 或剧集 ID
    public var sourceID: UUID?
    public var vfsPath: String
    public var title: String
    public var positionSec: Double
    public var durationSec: Double
    public var updatedAt: Date

    public var percentage: Int {
        guard durationSec > 0 else { return 0 }
        return min(100, Int((positionSec / durationSec) * 100.0))
    }

    public init(
        id: String,
        sourceID: UUID? = nil,
        vfsPath: String,
        title: String,
        positionSec: Double,
        durationSec: Double,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.vfsPath = vfsPath
        self.title = title
        self.positionSec = positionSec
        self.durationSec = durationSec
        self.updatedAt = updatedAt
    }
}

/// IPTV 多订阅源持久化配置模型（阶段三「源库」管理）
public struct IPTVSubscriptionSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var m3uURL: String
    public var epgXMLTVURL: String?
    public var customUserAgent: String?
    public var autoRefreshHours: Int
    public var isEnabled: Bool
    public var channelCount: Int
    public var lastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        m3uURL: String,
        epgXMLTVURL: String? = nil,
        customUserAgent: String? = nil,
        autoRefreshHours: Int = 12,
        isEnabled: Bool = true,
        channelCount: Int = 0,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.m3uURL = m3uURL
        self.epgXMLTVURL = epgXMLTVURL
        self.customUserAgent = customUserAgent
        self.autoRefreshHours = autoRefreshHours
        self.isEnabled = isEnabled
        self.channelCount = channelCount
        self.lastSyncedAt = lastSyncedAt
    }
}

/// 字幕与音轨描述模型（供双擎播放器 OSD 面板统一展示与切换）
public struct PlayerMediaTrackOption: Identifiable, Hashable, Sendable {
    public enum TrackType: String, Sendable {
        case audio
        case subtitle
    }

    public let id: String
    public let trackType: TrackType
    public let displayName: String
    public let languageCode: String?
    public let externalFileURL: URL?

    public init(
        id: String,
        trackType: TrackType,
        displayName: String,
        languageCode: String? = nil,
        externalFileURL: URL? = nil
    ) {
        self.id = id
        self.trackType = trackType
        self.displayName = displayName
        self.languageCode = languageCode
        self.externalFileURL = externalFileURL
    }
}
