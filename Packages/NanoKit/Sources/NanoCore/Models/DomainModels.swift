import Foundation

// MARK: - 1. 存储源与网盘双轨鉴权模型

/// 存储源类型：涵盖本地 NAS、主流网盘、小雅 OpenList 与媒体服务器
public enum StorageSourceType: String, Codable, CaseIterable, Sendable, Identifiable {
    case smb = "smb"
    case webdav = "webdav"
    case nfs = "nfs"
    case drive115 = "115"
    case quark = "quark"
    case baidu = "baidu"
    case aliyun = "aliyun"
    case xiaoyaOpenList = "alist"
    case emby = "emby"
    case jellyfin = "jellyfin"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smb: return "SMB 共享"
        case .webdav: return "WebDAV 存储"
        case .nfs: return "NFS 共享"
        case .drive115: return "115 网盘"
        case .quark: return "夸克网盘"
        case .baidu: return "百度网盘"
        case .aliyun: return "阿里云盘"
        case .xiaoyaOpenList: return "小雅 / OpenList"
        case .emby: return "Emby 媒体库"
        case .jellyfin: return "Jellyfin 媒体库"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .smb, .nfs: return "externaldrive.connected.to.line.below"
        case .webdav: return "globe.Badge.chevron.backward"
        case .drive115, .quark, .baidu, .aliyun: return "icloud.and.arrow.down"
        case .xiaoyaOpenList: return "shippingbox.and.arrow.backward"
        case .emby, .jellyfin: return "film.stack"
        }
    }

    /// 是否支持方案 A（官方开放平台 OpenAPI）
    public var supportsOpenAPISchemeA: Bool {
        switch self {
        case .drive115, .baidu, .aliyun:
            return true
        case .quark, .smb, .webdav, .nfs, .xiaoyaOpenList, .emby, .jellyfin:
            // 夸克目前无个人官方直链 OpenAPI，自动采用方案 B（扫码 Cookie + 本地流式代理）
            return false
        }
    }

    /// 是否支持方案 B（Web/TV 扫码获取 Cookie/Token + 本地流代理）
    public var supportsCookieSchemeB: Bool {
        switch self {
        case .drive115, .quark, .baidu, .aliyun:
            return true
        default:
            return false
        }
    }
}

/// 网盘鉴权轨模式：方案 A 优先，不支持或失败自动回退方案 B
public enum CloudAuthTrack: String, Codable, Sendable {
    case autoFallback = "auto"      // 默认：优先尝试方案 A (OpenAPI)，不支持或受限时自动启用方案 B (扫码 Cookie)
    case openAPISchemeA = "schemeA" // 强制方案 A：官方开放平台 OAuth2 / OpenAPI
    case cookieSchemeB = "schemeB"  // 强制方案 B：模拟 Web/TV 端扫码获取 Cookie + LocalProxy 直链
    case basicCredential = "basic"  // 基础账号密码/Token（用于 SMB / WebDAV / 小雅 / Emby）
}

/// 网络存储连接源实体
public struct StorageSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var type: StorageSourceType
    public var endpointURL: String
    public var rootPath: String
    public var authTrack: CloudAuthTrack
    public var activeTrackInUse: CloudAuthTrack
    public var keychainCredentialID: String
    public var isPrivate: Bool
    public var quotaUsedBytes: Int64?
    public var quotaTotalBytes: Int64?
    public var latencyMs: Int?
    public var connectedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        type: StorageSourceType,
        endpointURL: String,
        rootPath: String = "/",
        authTrack: CloudAuthTrack = .autoFallback,
        activeTrackInUse: CloudAuthTrack = .basicCredential,
        keychainCredentialID: String = UUID().uuidString,
        isPrivate: Bool = false,
        quotaUsedBytes: Int64? = nil,
        quotaTotalBytes: Int64? = nil,
        latencyMs: Int? = nil,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.endpointURL = endpointURL
        self.rootPath = rootPath
        self.authTrack = authTrack
        self.activeTrackInUse = activeTrackInUse
        self.keychainCredentialID = keychainCredentialID
        self.isPrivate = isPrivate
        self.quotaUsedBytes = quotaUsedBytes
        self.quotaTotalBytes = quotaTotalBytes
        self.latencyMs = latencyMs
        self.connectedAt = connectedAt
    }
}

// MARK: - 2. 影院海报墙与分集刮削模型

public enum MediaKind: String, Codable, Sendable {
    case movie = "movie"
    case tvSeries = "tv"
}

public struct CastMember: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var character: String
    public var avatarURL: String?

    public init(id: String = UUID().uuidString, name: String, character: String, avatarURL: String? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.avatarURL = avatarURL
    }
}

public struct VideoTechnicalSpec: Codable, Hashable, Sendable {
    public var resolution: String   // e.g. "4K", "1080P"
    public var dynamicRange: String // e.g. "Dolby Vision", "HDR", "SDR"
    public var frameRate: String    // e.g. "60 fps", "24 fps"
    public var audioCodec: String   // e.g. "Atmos", "DTS-HD", "AAC"

    public init(resolution: String = "1080P", dynamicRange: String = "HDR", frameRate: String = "60 fps", audioCodec: String = "AAC") {
        self.resolution = resolution
        self.dynamicRange = dynamicRange
        self.frameRate = frameRate
        self.audioCodec = audioCodec
    }
}

public struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var tmdbID: Int?
    public var kind: MediaKind
    public var title: String
    public var originalTitle: String?
    public var releaseDate: String
    public var year: Int?
    public var rating: Double
    public var voteCount: Int
    public var overview: String
    public var posterURL: String?
    public var backdropURL: String?
    public var genres: [String]
    public var language: String
    public var country: String
    public var networkOrStudio: String
    public var seasonCount: Int
    public var totalEpisodes: Int
    public var isCompleted: Bool
    public var cast: [CastMember]
    public var spec: VideoTechnicalSpec
    public var introSkipSec: Int
    public var outroSkipSec: Int
    public var isPrivate: Bool

    public init(
        id: UUID = UUID(),
        tmdbID: Int? = nil,
        kind: MediaKind,
        title: String,
        originalTitle: String? = nil,
        releaseDate: String = "",
        year: Int? = nil,
        rating: Double = 0.0,
        voteCount: Int = 0,
        overview: String = "",
        posterURL: String? = nil,
        backdropURL: String? = nil,
        genres: [String] = [],
        language: String = "汉语",
        country: String = "中国",
        networkOrStudio: String = "",
        seasonCount: Int = 1,
        totalEpisodes: Int = 1,
        isCompleted: Bool = true,
        cast: [CastMember] = [],
        spec: VideoTechnicalSpec = VideoTechnicalSpec(),
        introSkipSec: Int = 0,
        outroSkipSec: Int = 0,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.tmdbID = tmdbID
        self.kind = kind
        self.title = title
        self.originalTitle = originalTitle
        self.releaseDate = releaseDate
        self.year = year
        self.rating = rating
        self.voteCount = voteCount
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.genres = genres
        self.language = language
        self.country = country
        self.networkOrStudio = networkOrStudio
        self.seasonCount = seasonCount
        self.totalEpisodes = totalEpisodes
        self.isCompleted = isCompleted
        self.cast = cast
        self.spec = spec
        self.introSkipSec = introSkipSec
        self.outroSkipSec = outroSkipSec
        self.isPrivate = isPrivate
    }
}

public struct MediaEpisode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    public var sourceID: UUID
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var code: String // e.g. "S01E02"
    public var title: String
    public var overview: String
    public var stillImageURL: String?
    public var vfsPath: String
    public var durationSec: Double
    public var watchedPositionSec: Double

    public var watchedPercentage: Int {
        guard durationSec > 0 else { return 0 }
        return min(100, Int((watchedPositionSec / durationSec) * 100.0))
    }

    public var remainingMinutesText: String {
        let remain = max(0, Int((durationSec - watchedPositionSec) / 60.0))
        return "剩余 \(remain) 分钟"
    }

    public init(
        id: UUID = UUID(),
        mediaID: UUID,
        sourceID: UUID,
        seasonNumber: Int,
        episodeNumber: Int,
        title: String,
        overview: String = "",
        stillImageURL: String? = nil,
        vfsPath: String,
        durationSec: Double = 2700,
        watchedPositionSec: Double = 0
    ) {
        self.id = id
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.code = String(format: "S%02dE%02d", seasonNumber, episodeNumber)
        self.title = title
        self.overview = overview
        self.stillImageURL = stillImageURL
        self.vfsPath = vfsPath
        self.durationSec = durationSec
        self.watchedPositionSec = watchedPositionSec
    }
}

// MARK: - 3. IPTV 网络电视、多线聚合与回看模型

public enum IPTVCatchupMode: String, Codable, Sendable {
    case none = "none"
    case append = "append"
    case shift = "shift"
    case flussonic = "flussonic"
    case defaultTemplate = "default"
}

public struct IPTVStreamLine: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var subscriptionID: UUID
    public var url: String
    public var userAgent: String?
    public var referer: String?
    public var isIPv6: Bool
    public var latencyMs: Int?
    public var resolutionTag: String? // e.g. "4K", "1080P"
    public var catchupMode: IPTVCatchupMode
    public var catchupSourceTemplate: String?

    public init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        url: String,
        userAgent: String? = nil,
        referer: String? = nil,
        isIPv6: Bool = false,
        latencyMs: Int? = nil,
        resolutionTag: String? = nil,
        catchupMode: IPTVCatchupMode = .none,
        catchupSourceTemplate: String? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.url = url
        self.userAgent = userAgent
        self.referer = referer
        self.isIPv6 = isIPv6
        self.latencyMs = latencyMs
        self.resolutionTag = resolutionTag
        self.catchupMode = catchupMode
        self.catchupSourceTemplate = catchupSourceTemplate
    }
}

public struct EPGProgramItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var channelStdName: String
    public var title: String
    public var startTime: Date
    public var endTime: Date

    public init(id: UUID = UUID(), channelStdName: String, title: String, startTime: Date, endTime: Date) {
        self.id = id
        self.channelStdName = channelStdName
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }

    public func isLive(at date: Date = Date()) -> Bool {
        date >= startTime && date < endTime
    }
}

public struct IPTVChannelGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var channelNumber: Int
    public var standardName: String
    public var displayName: String
    public var category: String     // 央视 / 卫视 / 港澳台 / 4K8K / 地方 / 未分类
    public var province: String?    // 按省份维度筛选
    public var logoURL: String?
    public var isFavorite: Bool
    public var lines: [IPTVStreamLine]
    public var currentProgram: EPGProgramItem?
    public var nextProgram: EPGProgramItem?

    public var supportsCatchup: Bool {
        lines.contains { $0.catchupMode != .none }
    }

    public init(
        id: UUID = UUID(),
        channelNumber: Int,
        standardName: String,
        displayName: String,
        category: String,
        province: String? = nil,
        logoURL: String? = nil,
        isFavorite: Bool = false,
        lines: [IPTVStreamLine] = [],
        currentProgram: EPGProgramItem? = nil,
        nextProgram: EPGProgramItem? = nil
    ) {
        self.id = id
        self.channelNumber = channelNumber
        self.standardName = standardName
        self.displayName = displayName
        self.category = category
        self.province = province
        self.logoURL = logoURL
        self.isFavorite = isFavorite
        self.lines = lines
        self.currentProgram = currentProgram
        self.nextProgram = nextProgram
    }
}

// MARK: - 4. 远程网络资源（CMS JSON / FongMi / 网页爬虫规则）模型

public enum RemoteSiteEngineType: String, Codable, CaseIterable, Sendable {
    case macCMSJson = "cms_json"       // 标准苹果 CMS V10 JSON/XML 接口
    case fongMiTVBox = "fongmi_json"   // TVBox / FongMi 订阅源节点
    case customWebRule = "web_rule"    // 声明式自定义网页爬虫规则

    public var badgeTitle: String {
        switch self {
        case .macCMSJson: return "CMS 源"
        case .fongMiTVBox: return "FongMi 源"
        case .customWebRule: return "网页源"
        }
    }
}

public enum RemoteSiteHealthStatus: String, Codable, Sendable {
    case online = "online"
    case requireVerify = "verify"
    case checking = "checking"
    case offline = "offline"
}

public struct RemoteResourceSite: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var name: String
    public var engineType: RemoteSiteEngineType
    public var apiURL: String
    public var extRulePayload: String? // 存储 FongMi ext 参数或自定义网页爬虫规则 JSON
    public var isEnabled: Bool
    public var isSearchable: Bool
    public var isPrivate: Bool
    public var healthStatus: RemoteSiteHealthStatus
    public var latencyMs: Int?
    public var categoryCount: Int
    public var continueWatchCount: Int
    public var cachedPosterBytes: Int64
    public var cachedPosterCount: Int

    public init(
        id: UUID = UUID(),
        key: String = UUID().uuidString,
        name: String,
        engineType: RemoteSiteEngineType,
        apiURL: String,
        extRulePayload: String? = nil,
        isEnabled: Bool = true,
        isSearchable: Bool = true,
        isPrivate: Bool = false,
        healthStatus: RemoteSiteHealthStatus = .online,
        latencyMs: Int? = nil,
        categoryCount: Int = 0,
        continueWatchCount: Int = 0,
        cachedPosterBytes: Int64 = 0,
        cachedPosterCount: Int = 0
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.engineType = engineType
        self.apiURL = apiURL
        self.extRulePayload = extRulePayload
        self.isEnabled = isEnabled
        self.isSearchable = isSearchable
        self.isPrivate = isPrivate
        self.healthStatus = healthStatus
        self.latencyMs = latencyMs
        self.categoryCount = categoryCount
        self.continueWatchCount = continueWatchCount
        self.cachedPosterBytes = cachedPosterBytes
        self.cachedPosterCount = cachedPosterCount
    }
}

// MARK: - 5. 音乐与播放请求通用结构

public struct MusicTrack: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var vfsPath: String
    public var title: String
    public var artist: String
    public var album: String
    public var coverURL: String?
    public var formatTag: String // e.g. "FLAC · 24bit/96kHz"
    public var startOffsetSec: Double // 用于整轨 CUE 虚拟分轨起始秒数
    public var durationSec: Double
    public var lrcContent: String?

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        vfsPath: String,
        title: String,
        artist: String,
        album: String,
        coverURL: String? = nil,
        formatTag: String = "FLAC",
        startOffsetSec: Double = 0,
        durationSec: Double = 240,
        lrcContent: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.vfsPath = vfsPath
        self.title = title
        self.artist = artist
        self.album = album
        self.coverURL = coverURL
        self.formatTag = formatTag
        self.startOffsetSec = startOffsetSec
        self.durationSec = durationSec
        self.lrcContent = lrcContent
    }
}

/// 交付给双擎播放器的统一流描述对象
public struct PlayableStreamTicket: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var subtitle: String?
    public var streamURL: URL
    public var headers: [String: String]
    public var isLiveStream: Bool
    public var startPositionSec: Double
    public var introSkipSec: Int
    public var outroSkipSec: Int
    public var prefersDolbyVisionNative: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        streamURL: URL,
        headers: [String: String] = [:],
        isLiveStream: Bool = false,
        startPositionSec: Double = 0,
        introSkipSec: Int = 0,
        outroSkipSec: Int = 0,
        prefersDolbyVisionNative: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.streamURL = streamURL
        self.headers = headers
        self.isLiveStream = isLiveStream
        self.startPositionSec = startPositionSec
        self.introSkipSec = introSkipSec
        self.outroSkipSec = outroSkipSec
        if let explicitDV = prefersDolbyVisionNative {
            self.prefersDolbyVisionNative = explicitDV
        } else {
            let combined = (title + " " + streamURL.lastPathComponent).uppercased()
            self.prefersDolbyVisionNative = combined.contains("DV") || combined.contains("DOVI") || combined.contains("DOLBY")
        }
    }
}
