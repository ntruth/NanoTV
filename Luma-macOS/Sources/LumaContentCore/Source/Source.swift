import Foundation

/// 所有内容来源的统一标识。
/// 字符串化便于持久化与调试；具体构造器负责保证命名空间不冲突。
public struct SourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// 源 ID 末尾的 UUID：`cloud:` / `catalog:` / `cinema:mount:` 共用。
    /// 聚合源（如 `catalog:hub`）没有 UUID，返回 nil。
    public var uuidValue: UUID? {
        guard let separator = rawValue.lastIndex(of: ":") else { return nil }
        return UUID(uuidString: String(rawValue[rawValue.index(after: separator)...]))
    }

    public static func library(_ path: String) -> SourceID {
        SourceID("library:\(path)")
    }

    public static func linkedLibrary(_ path: String) -> SourceID {
        SourceID("library:\(path)")
    }

    public static func cloud(_ id: UUID) -> SourceID {
        SourceID("cloud:\(id.uuidString)")
    }

    public static func cinema(_ id: UUID) -> SourceID {
        SourceID("cinema:\(id.uuidString)")
    }

    /// 本地影院：本地文件刮削结果，不属于某个网盘。
    public static let localCinema = SourceID("cinema:local")

    /// 某个网盘自己的影院。
    public static func mountCinema(_ id: UUID) -> SourceID {
        SourceID("cinema:mount:\(id.uuidString)")
    }

    public static func catalog(_ id: UUID) -> SourceID {
        SourceID("catalog:\(id.uuidString)")
    }

    /// 跨源任务（今日总榜补录、全源健康检测）使用的聚合源。
    public static let catalogHub = SourceID("catalog:hub")

    /// 网络影院：聚合已启用影视源的跨源任务（列表探测、TMDB / 豆瓣资料补全）。
    public static let networkCinema = SourceID("cinemaFeed:network")

    /// 统一搜索：一次检索会跨图库 / 网盘 / 影院 / 电视 / 资源，任务条用它作为来源。
    public static let search = SourceID("search:global")

    public static func television(_ id: UUID) -> SourceID {
        SourceID("tv:\(id.uuidString)")
    }
}

/// 五种内容来源。library 是唯一拥有写入会话的 kind；
/// 链接图库仍然属于 library，只是处于非活动状态。
public enum SourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case library
    case cloudMount
    case cinemaFeed
    case catalogSite
    case iptv

    public var title: String {
        switch self {
        case .library: return "图库"
        case .cloudMount: return "网络云盘"
        case .cinemaFeed: return "网络影院"
        case .catalogSite: return "网络资源"
        case .iptv: return "网络电视"
        }
    }

    /// 侧边栏与空态使用的系统符号名。
    public var symbolName: String {
        switch self {
        case .library: return "photo.stack"
        case .cloudMount: return "externaldrive.connected.to.line.below"
        case .cinemaFeed: return "film.stack"
        case .catalogSite: return "play.rectangle.on.rectangle"
        case .iptv: return "tv"
        }
    }

    /// 只有 library 拥有唯一的写入会话。
    public var ownsWriteSession: Bool { self == .library }

    /// 默认激活语义：链接图库替换当前库；其他源只切换浏览内容。
    public var defaultActivation: SourceActivationPolicy {
        self == .library ? .replaceLibrarySession : .browseReadOnly
    }
}

/// 点击源时的语义，必须在模型层表达，而不是由视图临时判断。
public enum SourceActivationPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    /// 链接图库：替换当前图库会话，撤销栈清空，写入目标改变。
    case replaceLibrarySession
    /// 云盘 / 影院 / 资源 / 电视：只切换右侧浏览内容，当前图库不变。
    case browseReadOnly

    public var isLibrarySwitch: Bool { self == .replaceLibrarySession }
}

/// 内容能力：所有源都有，决定列表 / 详情 / 播放界面能显示什么。
public struct ContentCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// 有可展开的树（文件夹 / 相簿 / 目录 / 分组）。
    public static let browseTree = ContentCapabilities(rawValue: 1 << 0)
    /// 有分类 / 频道 / 货架。
    public static let categories = ContentCapabilities(rawValue: 1 << 1)
    /// 有首页信息流。
    public static let homeFeed = ContentCapabilities(rawValue: 1 << 2)
    /// 支持分页 / 游标。
    public static let pagination = ContentCapabilities(rawValue: 1 << 3)
    /// 支持搜索。
    public static let search = ContentCapabilities(rawValue: 1 << 4)
    /// 支持点播播放。
    public static let vodPlayback = ContentCapabilities(rawValue: 1 << 5)
    /// 支持直播播放。
    public static let livePlayback = ContentCapabilities(rawValue: 1 << 6)
    /// 有 EPG 节目单。
    public static let epg = ContentCapabilities(rawValue: 1 << 7)
    /// 有封面 / 海报 / 台标。
    public static let artwork = ContentCapabilities(rawValue: 1 << 8)
    /// 支持照片类分析（人物 / 场景 / OCR / 相似）。
    public static let photoAnalysis = ContentCapabilities(rawValue: 1 << 9)

    public static let library: ContentCapabilities =
        [.browseTree, .categories, .pagination, .search, .vodPlayback, .artwork, .photoAnalysis]
    public static let cloud: ContentCapabilities =
        [.browseTree, .pagination, .search, .vodPlayback, .artwork, .photoAnalysis]
    public static let catalog: ContentCapabilities =
        [.categories, .homeFeed, .pagination, .search, .vodPlayback, .artwork]
    public static let cinema: ContentCapabilities =
        [.categories, .homeFeed, .pagination, .search, .vodPlayback, .artwork]
    public static let television: ContentCapabilities =
        [.categories, .pagination, .search, .livePlayback, .epg, .artwork]
}

extension ContentCapabilities: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 写入能力：只有 library 可能有值；云盘 WebDAV 未来可单独扩展。
public struct WriteCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let importMedia = WriteCapabilities(rawValue: 1 << 0)
    public static let editOriginal = WriteCapabilities(rawValue: 1 << 1)
    public static let deleteOriginal = WriteCapabilities(rawValue: 1 << 2)
    public static let mutateAlbums = WriteCapabilities(rawValue: 1 << 3)
    public static let mutateFolders = WriteCapabilities(rawValue: 1 << 4)
    public static let overlayMetadata = WriteCapabilities(rawValue: 1 << 5)
    public static let writeKeywords = WriteCapabilities(rawValue: 1 << 6)
    public static let writeTitle = WriteCapabilities(rawValue: 1 << 7)

    public static let readOnly: WriteCapabilities = []

    public static let managedLibrary: WriteCapabilities = [
        .importMedia, .editOriginal, .deleteOriginal, .mutateAlbums,
        .mutateFolders, .overlayMetadata, .writeKeywords, .writeTitle
    ]

    /// 原生库：关键词 / 标题仍写 Luma 本地表；原图编辑与删除取决于 PhotoKit 授权。
    public static let nativeLibrary: WriteCapabilities = [
        .mutateAlbums, .mutateFolders, .overlayMetadata, .writeKeywords, .writeTitle
    ]
}

extension WriteCapabilities: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func supports(_ capability: WriteCapabilities) -> Bool {
        contains(capability)
    }
}

/// 一个内容源的完整描述：持久化、侧边栏、命令可用性都读它。
public struct SourceDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: SourceID
    public var kind: SourceKind
    public var name: String
    public var subtitle: String?
    public var activation: SourceActivationPolicy
    public var content: ContentCapabilities
    public var write: WriteCapabilities
    public var isEnabled: Bool
    public var sortIndex: Int
    public var lastOpenedAt: Date?

    public init(id: SourceID,
                kind: SourceKind,
                name: String,
                subtitle: String? = nil,
                activation: SourceActivationPolicy? = nil,
                content: ContentCapabilities,
                write: WriteCapabilities = .readOnly,
                isEnabled: Bool = true,
                sortIndex: Int = 0,
                lastOpenedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.activation = activation ?? kind.defaultActivation
        self.content = content
        self.write = write
        self.isEnabled = isEnabled
        self.sortIndex = sortIndex
        self.lastOpenedAt = lastOpenedAt
    }

    public var ownsWriteSession: Bool {
        kind.ownsWriteSession && activation.isLibrarySwitch
    }

    public func can(_ capability: ContentCapabilities) -> Bool {
        content.contains(capability)
    }

    public func canWrite(_ capability: WriteCapabilities) -> Bool {
        kind.ownsWriteSession && write.contains(capability)
    }
}

/// 应用级源目录：替代独立的 LibraryRegistry。
/// 链接库、链接网盘、资源、影院、电视都在同一份列表里，靠 kind 区分。
public struct SourceRegistryState: Codable, Hashable, Sendable {
    public var sources: [SourceDescriptor]
    public var activeLibraryID: SourceID?
    public var activeBrowseSourceID: SourceID?

    public init(sources: [SourceDescriptor] = [],
                activeLibraryID: SourceID? = nil,
                activeBrowseSourceID: SourceID? = nil) {
        self.sources = sources
        self.activeLibraryID = activeLibraryID
        self.activeBrowseSourceID = activeBrowseSourceID
    }

    public var activeLibrary: SourceDescriptor? {
        guard let activeLibraryID else { return nil }
        return sources.first { $0.id == activeLibraryID }
    }

    public var linkedLibraries: [SourceDescriptor] {
        sources
            .filter { $0.kind == .library && $0.id != activeLibraryID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    public var linkedSources: [SourceDescriptor] {
        sources
            .filter { $0.kind != .library }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    public func sources(of kind: SourceKind) -> [SourceDescriptor] {
        sources.filter { $0.kind == kind }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func descriptor(for id: SourceID) -> SourceDescriptor? {
        sources.first { $0.id == id }
    }

    public mutating func upsert(_ descriptor: SourceDescriptor) {
        if let index = sources.firstIndex(where: { $0.id == descriptor.id }) {
            sources[index] = descriptor
        } else {
            sources.append(descriptor)
        }
        sources.sort { $0.sortIndex < $1.sortIndex }
    }

    public mutating func remove(_ id: SourceID) {
        sources.removeAll { $0.id == id }
        if activeLibraryID == id { activeLibraryID = nil }
        if activeBrowseSourceID == id { activeBrowseSourceID = nil }
    }

    public mutating func activateLibrary(_ id: SourceID) {
        guard let descriptor = descriptor(for: id), descriptor.kind == .library else { return }
        activeLibraryID = id
        activeBrowseSourceID = id
    }

    public mutating func browse(_ id: SourceID) {
        guard let descriptor = descriptor(for: id) else { return }
        if descriptor.activation.isLibrarySwitch {
            activateLibrary(id)
        } else {
            activeBrowseSourceID = id
        }
    }
}
