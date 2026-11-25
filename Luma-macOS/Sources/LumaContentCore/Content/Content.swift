import Foundation

/// 跨源内容引用：源 + 条目 id，不绑定具体业务模型。
public struct ContentRef: Identifiable, Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var itemID: String

    public var id: String { "\(sourceID.rawValue)#\(itemID)" }

    public init(sourceID: SourceID, itemID: String) {
        self.sourceID = sourceID
        self.itemID = itemID
    }
}

/// 容器：相簿 / 文件夹 / 分类 / 货架 / 频道分组 / 播放列表的统一描述。
public struct ContentContainer: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case root
        case folder
        case album
        case category
        case shelf
        case channelGroup
        case playlist
        case collection
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var subtitle: String?
    public var artworkURL: String?
    public var childCountHint: Int?

    public init(id: String,
                title: String,
                kind: Kind,
                subtitle: String? = nil,
                artworkURL: String? = nil,
                childCountHint: Int? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.childCountHint = childCountHint
    }
}

/// 卡片携带的源侧事实：只用于需要把 `ContentCard` 还原成源条目的场景
/// （网盘文件、本地文件）。普通海报墙 / 频道墙不读它。
public struct ContentAssetFacts: Hashable, Codable, Sendable {
    /// 文件修改时间：网盘按它排序，也是云照片的「最近保存」依据。
    public var updatedAt: Date?
    public var byteCount: Int64?
    /// 视频时长（秒）。
    public var duration: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// 源内稳定 ID（如百度 fs_id），还原后取直链需要它。
    public var remoteID: String?
    /// 视频编码（如 hevc），转封装需要据此写 hvc1 标签。
    public var videoCodec: String?
    /// 源标记的受限内容：可展示，但不能播放 / 下载。
    public var isRestricted: Bool

    public init(updatedAt: Date? = nil,
                byteCount: Int64? = nil,
                duration: Double? = nil,
                pixelWidth: Int? = nil,
                pixelHeight: Int? = nil,
                remoteID: String? = nil,
                videoCodec: String? = nil,
                isRestricted: Bool = false) {
        self.updatedAt = updatedAt
        self.byteCount = byteCount
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.remoteID = remoteID
        self.videoCodec = videoCodec
        self.isRestricted = isRestricted
    }
}

/// 列表卡片：海报墙 / 照片网格 / 频道行 / 文件行都消费这一层。
public struct ContentCard: Identifiable, Hashable, Codable, Sendable {
    public var ref: ContentRef
    public var title: String
    public var subtitle: String?
    public var artworkURL: String?
    public var badges: [String]
    /// 海报宽高比；照片 / 视频可为 nil，由视图决定。
    public var aspectRatio: Double?
    /// 点播进度 0…1；直播为 nil。
    public var progress: Double?
    /// 直播频道 / 正在直播的节目标记。
    public var isLive: Bool
    /// 是否可播放；不可播放的条目（例如仅元数据）仍可展示详情。
    public var isPlayable: Bool
    /// 需要还原源条目时携带的文件事实；纯展示场景留 nil。
    public var asset: ContentAssetFacts?

    public var id: String { ref.id }

    public init(ref: ContentRef,
                title: String,
                subtitle: String? = nil,
                artworkURL: String? = nil,
                badges: [String] = [],
                aspectRatio: Double? = nil,
                progress: Double? = nil,
                isLive: Bool = false,
                isPlayable: Bool = true,
                asset: ContentAssetFacts? = nil) {
        self.ref = ref
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.badges = badges
        self.aspectRatio = aspectRatio
        self.progress = progress
        self.isLive = isLive
        self.isPlayable = isPlayable
        self.asset = asset
    }
}

/// 详情页的事实条目（年份 / 地区 / 时长 / 评分…）。
public struct ContentFact: Identifiable, Hashable, Codable, Sendable {
    public var label: String
    public var value: String

    public var id: String { "\(label)|\(value)" }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// 分集 / 频道节目 / 播放条目。
public struct ContentEpisode: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var index: Int
    public var title: String
    public var subtitle: String?
    public var duration: Double?
    public var target: PlaybackTarget?

    public init(id: String,
                index: Int,
                title: String,
                subtitle: String? = nil,
                duration: Double? = nil,
                target: PlaybackTarget? = nil) {
        self.id = id
        self.index = index
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.target = target
    }
}

/// 一个可选的播放线路：网盘原片、站点线路 1、直播源等。
public struct ContentPlaybackOption: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var target: PlaybackTarget

    public init(id: String, title: String, subtitle: String? = nil, target: PlaybackTarget) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.target = target
    }
}

/// 详情：卡片 + 简介 + 事实 + 子容器 + 分集 + 播放线路。
public struct ContentDetail: Hashable, Codable, Sendable {
    public var card: ContentCard
    public var overview: String?
    public var facts: [ContentFact]
    public var containers: [ContentContainer]
    public var episodes: [ContentEpisode]
    public var playbackOptions: [ContentPlaybackOption]

    public init(card: ContentCard,
                overview: String? = nil,
                facts: [ContentFact] = [],
                containers: [ContentContainer] = [],
                episodes: [ContentEpisode] = [],
                playbackOptions: [ContentPlaybackOption] = []) {
        self.card = card
        self.overview = overview
        self.facts = facts
        self.containers = containers
        self.episodes = episodes
        self.playbackOptions = playbackOptions
    }
}

/// 分页游标：不同源可以把它解释为页码、目录 token、更新时间等。
public struct PageCursor: Hashable, Codable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(page: Int) {
        self.rawValue = String(page)
    }

    public var page: Int? { Int(rawValue) }
}

/// 一页内容：列表项 + 子容器 + 下一页游标。
public struct ContentPage: Hashable, Codable, Sendable {
    public var items: [ContentCard]
    public var containers: [ContentContainer]
    public var next: PageCursor?
    public var totalHint: Int?

    public init(items: [ContentCard] = [],
                containers: [ContentContainer] = [],
                next: PageCursor? = nil,
                totalHint: Int? = nil) {
        self.items = items
        self.containers = containers
        self.next = next
        self.totalHint = totalHint
    }

    public var isEmpty: Bool { items.isEmpty && containers.isEmpty }
}

/// 排序描述：源在能力里声明支持哪些 key，不支持的由 UI 隐藏。
public struct ContentSort: Hashable, Codable, Sendable {
    public enum Key: String, Codable, CaseIterable, Hashable, Sendable {
        case latest
        case oldest
        case title
        case rating
        case duration
        case custom
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }

    public static let latest = ContentSort(key: .latest)
}

/// 过滤描述：保持通用 key/value，源自行解释。
public struct ContentFilter: Identifiable, Hashable, Codable, Sendable {
    public var key: String
    public var value: String

    public var id: String { "\(key)=\(value)" }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// 一次内容查询：容器 + 搜索 + 排序 + 过滤 + 游标。
public struct ContentQuery: Hashable, Codable, Sendable {
    public var containerID: String?
    public var search: String?
    public var sort: ContentSort?
    public var filters: [ContentFilter]
    public var cursor: PageCursor?
    public var limit: Int

    public init(containerID: String? = nil,
                search: String? = nil,
                sort: ContentSort? = nil,
                filters: [ContentFilter] = [],
                cursor: PageCursor? = nil,
                limit: Int = 80) {
        self.containerID = containerID
        self.search = search
        self.sort = sort
        self.filters = filters
        self.cursor = cursor
        self.limit = limit
    }
}

/// 只读内容仓库：云盘 / 资源 / 影院 / 电视实现它；
/// library 的写模型是 LibraryRepository，另有一套能力。
@MainActor
public protocol ContentRepository {
    func containers(_ query: ContentQuery) async throws -> [ContentContainer]
    func page(_ query: ContentQuery) async throws -> ContentPage
    func detail(_ ref: ContentRef) async throws -> ContentDetail
    func search(_ query: ContentQuery) async throws -> ContentPage
    /// 首屏快照：源未变化时可直接铺上次内容；不支持快照的源返回 nil。
    func cachedPage(_ query: ContentQuery) -> ContentPage?
}

public extension ContentRepository {
    func containers(_ query: ContentQuery) async throws -> [ContentContainer] { [] }
    func search(_ query: ContentQuery) async throws -> ContentPage {
        try await page(query)
    }
    func cachedPage(_ query: ContentQuery) -> ContentPage? { nil }
}

/// 占位仓库：源还没有实现只读仓库时使用，调用即返回 `unsupported`，
/// 避免在会话 / 视图里到处判断 optional。
public struct UnavailableContentRepository: ContentRepository {
    public let message: String

    public init(message: String = "这个源还没有可用的内容仓库") {
        self.message = message
    }

    public func page(_ query: ContentQuery) async throws -> ContentPage {
        throw SourceError.unsupported(message)
    }

    public func detail(_ ref: ContentRef) async throws -> ContentDetail {
        throw SourceError.unsupported(message)
    }
}

/// 跨源搜索结果分组：按源展示，失败不影响其他源。
public struct ContentSearchGroup: Identifiable, Hashable, Codable, Sendable {
    public var source: SourceDescriptor
    public var page: ContentPage?
    public var message: String?

    public var id: String { source.id.rawValue }

    public init(source: SourceDescriptor, page: ContentPage? = nil, message: String? = nil) {
        self.source = source
        self.page = page
        self.message = message
    }
}

/// 跨源搜索协调器：源内搜索与全局搜索共用一个入口。
public protocol ContentSearchCoordinating: Sendable {
    func search(_ query: ContentQuery, in sources: [SourceDescriptor]) async -> [ContentSearchGroup]
}
