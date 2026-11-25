import Foundation

/// 统一搜索的来源：图库 / 网盘 / 影院 / 网络影院 / 电视 / 资源。
/// 独立成模块后，页面只声明自己需要哪些来源，组件就只检索、只展示这些来源。
enum SearchSourceKind: String, CaseIterable, Identifiable, Hashable {
    case library
    case cloud
    case cinema
    /// 网络影院：网络影视源（苹果CMS / FoFo / 爱看片片 / 爱壹帆）聚合出的条目。
    case networkCinema
    case television
    case catalog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "图库"
        case .cloud: return "网盘"
        case .cinema: return "影院"
        case .networkCinema: return "网络影院"
        case .television: return "电视"
        case .catalog: return "资源"
        }
    }

    var icon: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .cloud: return "externaldrive.connected.to.line.below"
        case .cinema: return "film.stack"
        case .networkCinema: return "play.tv.fill"
        case .television: return "tv"
        case .catalog: return "safari"
        }
    }
}

/// 命中的内容类型：用于「按类型」筛选，也决定行内图标与徽标。
enum SearchHitKind: String, Hashable {
    case photo
    case video
    case album
    case folder
    case person
    case scene
    case place
    case cloudPhoto
    case cloudVideo
    case cloudFile
    case cloudFolder
    case movie
    case series
    case channel
    /// 节目单里的一档节目：点开按直播 / 回看处理。
    case program
    case catalogItem

    var title: String {
        switch self {
        case .photo: return "图片"
        case .video: return "视频"
        case .album: return "相簿"
        case .folder: return "文件夹"
        case .person: return "人物"
        case .scene: return "场景"
        case .place: return "位置"
        case .cloudPhoto: return "图片"
        case .cloudVideo: return "视频"
        case .cloudFile: return "文件"
        case .cloudFolder: return "文件夹"
        case .movie: return "电影"
        case .series: return "电视剧"
        case .channel: return "直播"
        case .program: return "节目"
        case .catalogItem: return "条目"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .album: return "rectangle.stack"
        case .folder, .cloudFolder: return "folder"
        case .person: return "person"
        case .scene: return "sparkles"
        case .place: return "mappin.and.ellipse"
        case .cloudPhoto: return "photo"
        case .cloudVideo: return "video"
        case .cloudFile: return "doc"
        case .movie: return "film"
        case .series: return "tv"
        case .channel: return "antenna.radiowaves.left.and.right"
        case .program: return "list.bullet.rectangle"
        case .catalogItem: return "safari"
        }
    }
}

/// 行首视觉：只描述「画什么」，具体视图由组件按类型渲染。
enum SearchVisual {
    case photo(PhotoItem)
    case albumCover(PhotoItem?, AlbumPlaceholderStyle)
    case avatar(Data?, isPet: Bool)
    case place
    case scene
    case cloudFile(isVideo: Bool)
    case cloudFolder
    case cinemaPoster(String?, CinemaMediaKind)
    case channelLogo(String?)
    case catalogCover(sourceID: UUID, url: String)
}

/// 点击后的动作数据：不携带闭包，保证可测试、可跨页面复用。
enum SearchPayload {
    case photo(UUID)
    case localAlbum(UUID)
    case localFolder(UUID)
    case systemAlbum(Int64)
    case systemFolder(Int64)
    case localPerson(UUID)
    case systemPerson(SystemPersonInfo)
    case place(PlaceCluster)
    case scene(String)
    case cloudFile(mountID: UUID, folderPath: String?, path: String)
    case cloudFolder(mountID: UUID, path: String)
    case cinema(scopeKey: String, queueTitle: String, entry: CinemaEntry)
    case channel(TVChannel)
    /// 节目单里的节目：正在播直接看直播，已播且支持回看就回看，其它情况落到当天节目单。
    case program(channel: TVChannel, program: TVEPGProgram)
    case catalogItem(sourceID: UUID, item: CatalogItem)
    /// 网络影院条目：点击后进入网络影院并停在这部作品的详情页。
    case networkCinemaItem(sourceID: UUID, item: CatalogItem, isTV: Bool)
}

/// 一条统一命中。
struct SearchHit: Identifiable {
    let id: String
    let source: SearchSourceKind
    let kind: SearchHitKind
    let title: String
    let subtitle: String
    let badge: String?
    let visual: SearchVisual
    let payload: SearchPayload
    /// 命中所属的「源」：网盘名称、影院范围、电视频道所属播放列表、网络资源站点、图库名称。
    var origin: String? = nil
    /// 源下面的分类：电视频道分组、资源分类等。
    var category: String? = nil
    /// 命中来自哪个图库（跨图库搜索）：nil = 当前图库。
    var libraryPath: String? = nil
    /// 是否来自「其它图库」：图库结果区据此决定继续用照片墙还是改成结果行。
    var isOtherLibrary: Bool = false
}

/// 一个来源的检索结果。
struct SearchSection: Identifiable {
    let source: SearchSourceKind
    var hits: [SearchHit]
    var total: Int
    /// 各内容类型的命中总数（不受 hits 截断影响）。
    var kindCounts: [SearchHitKind: Int]

    var id: String { source.rawValue }

    var orderedKinds: [SearchHitKind] {
        let order: [SearchHitKind] = [.photo, .video, .album, .folder, .person, .scene, .place,
                                      .cloudPhoto, .cloudVideo, .cloudFile, .cloudFolder,
                                      .movie, .series, .channel, .program, .catalogItem]
        return order.filter { (kindCounts[$0] ?? 0) > 0 }
    }

    /// 本轮命中涉及的「源」（去重，按命中数排序）；用于结果页的源筛选条。
    var origins: [(title: String, count: Int)] {
        var counts: [String: Int] = [:]
        for hit in hits {
            guard let origin = hit.origin, !origin.isEmpty else { continue }
            counts[origin, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (title: $0.key, count: $0.value) }
    }

    /// 指定源下面的分类（去重，按命中数排序）；未指定源时统计全部。
    func categories(under origin: String?) -> [(title: String, count: Int)] {
        var counts: [String: Int] = [:]
        for hit in hits {
            if let origin, hit.origin != origin { continue }
            guard let category = hit.category, !category.isEmpty else { continue }
            counts[category, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (title: $0.key, count: $0.value) }
    }
}

/// 来源检索器：每个来源一个实现，SearchCenter 并发调度。
@MainActor
protocol SearchProviding: AnyObject {
    var source: SearchSourceKind { get }
    func search(query: String, limit: Int) async -> SearchSection
}

/// 统一搜索的轻量模糊匹配。
///
/// 去掉空白与标点、忽略大小写 / 全半角后，**任一方向包含**即命中：
/// 搜「海上海」也能命中「上海」这个地点或相簿，不必逐字完全相同。
enum SearchFuzzyText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// 词条与关键词是否模糊命中。
    static func matches(_ value: String?, keyword: String) -> Bool {
        guard let value else { return false }
        let text = normalize(value)
        let query = normalize(keyword)
        guard !query.isEmpty, !text.isEmpty else { return false }
        if text.contains(query) { return true }
        // 反方向包含只对至少 2 个字的条名生效，避免单字名称命中所有关键词。
        return text.count >= 2 && query.contains(text)
    }

    static func matchesAny(_ values: [String?], keyword: String) -> Bool {
        values.contains { matches($0, keyword: keyword) }
    }
}
