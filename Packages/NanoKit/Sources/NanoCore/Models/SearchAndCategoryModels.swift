import Foundation

// MARK: - 1. 统一搜索分域枚举（1:1 对应参考图顶部胶囊：全部 | 网盘 | 影院 | 网络影院 | 电视 | 资源 | 音乐）

public enum UnifiedSearchScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "all"
    case cloudDrive = "cloud"           // 网盘与本地 NAS 文件 (115 / 夸克 / 百度 / SMB / WebDAV)
    case cinema = "cinema"              // 本地已刮削影院海报墙
    case networkCinema = "net_cinema"   // 小雅 OpenList 全局秒搜 / Emby / Jellyfin 网络影院
    case liveTV = "tv"                  // IPTV 电视直播与回看（支持省份地域智能映射，如「上海」-> 东方卫视）
    case remoteResource = "resource"    // 远程扩展源（苹果 CMS JSON / FongMi / 网页爬虫源）
    case music = "music"                // Hi-Fi 无损音乐库

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .cloudDrive: return "网盘"
        case .cinema: return "影院"
        case .networkCinema: return "网络影院"
        case .liveTV: return "电视"
        case .remoteResource: return "资源"
        case .music: return "音乐"
        }
    }

    public var systemIcon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .cloudDrive: return "externaldrive.fill.badge.icloud"
        case .cinema: return "film.stack"
        case .networkCinema: return "play.square.stack.fill"
        case .liveTV: return "tv"
        case .remoteResource: return "safari"
        case .music: return "music.note"
        }
    }

    public var loadingStatusPrompt: String {
        switch self {
        case .all: return "正在汇总检索结果..."
        case .cloudDrive: return "正在检索网盘与存储目录..."
        case .cinema: return "正在检索影院档案..."
        case .networkCinema: return "正在检索网络影院 (小雅 / 媒体服)..."
        case .liveTV: return "正在检索电视直播与节目单..."
        case .remoteResource: return "正在并发检索远程资源站..."
        case .music: return "正在检索无损音乐库..."
        }
    }
}

// MARK: - 2. 统一搜索命中条目模型

public enum UnifiedSearchActionPayload: Hashable, Sendable {
    case openCinemaMedia(UUID)
    case playLiveChannel(channelID: UUID, lineIndex: Int)
    case playVFSNode(sourceID: UUID, path: String, fileID: String, isAudio: Bool)
    case playRemoteStream(title: String, siteName: String, streamURL: String)
}

public struct UnifiedSearchResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let scope: UnifiedSearchScope
    public let title: String
    public let subtitle: String        // 例如："APTV 公开源 · 直播 + 回看 (直连) · 卫视 · 2160p"
    public let badgeText: String?      // 例如："4K" / "S01" / "169 ms"
    public let artworkURL: String?
    public let action: UnifiedSearchActionPayload

    public init(
        id: String = UUID().uuidString,
        scope: UnifiedSearchScope,
        title: String,
        subtitle: String,
        badgeText: String? = nil,
        artworkURL: String? = nil,
        action: UnifiedSearchActionPayload
    ) {
        self.id = id
        self.scope = scope
        self.title = title
        self.subtitle = subtitle
        self.badgeText = badgeText
        self.artworkURL = artworkURL
        self.action = action
    }
}

// MARK: - 3. 多维分类筛选条件模型（用于影院海报墙与远程资源中心多维组合筛选）

public enum MediaSortOrder: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded = "最近添加"
    case highestRating = "评分最高"
    case newestRelease = "首播年份"
    case titleAZ = "名称排序"

    public var id: String { rawValue }
}

public struct MediaCategoryFilterState: Hashable, Sendable {
    public var kindFilter: String = "全部"       // 全部 / 电影 / 剧集
    public var genreFilter: String = "全部"      // 全部 / 剧情 / 喜剧 / 动作 / 科幻 / 悬疑 / 纪录片
    public var regionFilter: String = "全部"     // 全部 / 中国 / 中国香港 / 中国台湾 / 美国 / 日本 / 韩国
    public var yearFilter: String = "全部"       // 全部 / 2026 / 2025 / 2024 / 更早
    public var qualityFilter: String = "全部"    // 全部 / 4K / Dolby Vision / HDR / 60 fps
    public var sortOrder: MediaSortOrder = .recentlyAdded

    public init() {}

    public var isDefault: Bool {
        kindFilter == "全部" && genreFilter == "全部" && regionFilter == "全部" && yearFilter == "全部" && qualityFilter == "全部"
    }

    public mutating func resetAll() {
        self = MediaCategoryFilterState()
    }

    public func matches(_ item: MediaItem) -> Bool {
        if kindFilter == "电影" && item.kind != .movie { return false }
        if kindFilter == "剧集" && item.kind != .tvSeries { return false }

        if genreFilter != "全部" && !item.genres.contains(where: { $0.localizedCaseInsensitiveContains(genreFilter) }) {
            return false
        }

        if regionFilter != "全部" && !item.country.localizedCaseInsensitiveContains(regionFilter) {
            return false
        }

        if yearFilter != "全部" {
            let y = item.year ?? 0
            if yearFilter == "更早" {
                if y >= 2024 || y == 0 { return false }
            } else if let targetYear = Int(yearFilter), y != targetYear {
                return false
            }
        }

        if qualityFilter != "全部" {
            switch qualityFilter {
            case "4K":
                if item.spec.resolution != "4K" { return false }
            case "Dolby Vision":
                if !item.spec.dynamicRange.localizedCaseInsensitiveContains("Dolby") { return false }
            case "HDR":
                if item.spec.dynamicRange == "SDR" { return false }
            case "60 fps":
                if !item.spec.frameRate.contains("60") { return false }
            default:
                break
            }
        }
        return true
    }
}
