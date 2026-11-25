import Foundation

// MARK: - 影院刮削

/// 相似推荐：只存展示所需的最小信息，点击时再回本库找同 tmdbID 的条目。
struct CinemaRecommendation: Codable, Hashable, Identifiable {
    var tmdbID: Int
    var kind: CinemaMediaKind
    var title: String
    var year: Int?
    var posterURL: String?
    var rating: Double?
    /// 豆瓣条目 ID：豆瓣推荐不能按 tmdbID 回本库，点击时改为打开豆瓣页。
    var doubanID: String? = nil

    var id: String {
        if let doubanID { return "douban-\(doubanID)" }
        return "\(kind.rawValue)-\(tmdbID)"
    }
}

/// 推荐分组：详情页每个 tab 一组，来源决定点击行为。
struct CinemaRecommendationGroup: Codable, Hashable, Identifiable {
    enum Source: String, Codable {
        case tmdb
        case douban
        case collection
        case director
        case cast
    }

    var source: Source
    var title: String
    var items: [CinemaRecommendation]

    var id: String { source.rawValue }
}

/// TMDB 图片候选：海报 / 背景二选一，写回条目后立即生效。
struct CinemaArtworkCandidate: Identifiable, Hashable {
    var url: String
    var width: Int
    var height: Int
    var language: String?
    var rating: Double?

    var id: String { url }

    /// 「zh」/「en」/ 无语言三种来源的排序权重：中文优先，其次无语言（通常是原版）。
    var languageRank: Int {
        switch language {
        case "zh", "cn", "zh-CN": return 0
        case nil, "": return 1
        default: return 2
        }
    }
}

enum CinemaMediaKind: String, Codable, CaseIterable, Identifiable {
    case movie
    case tv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: return "电影"
        case .tv: return "电视剧"
        }
    }
}

/// 刮削数据源。值表示「优先使用哪个」：两个源同时启用，前一个没匹配到再换另一个。
enum CinemaProvider: String, Codable, CaseIterable, Identifiable {
    case douban
    case tmdb
    case tvdb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tmdb: return "TMDB"
        case .douban: return "豆瓣"
        case .tvdb: return "TVDB"
        }
    }

    var tagline: String {
        switch self {
        case .tmdb: return "官方 API · 全球影视 · 海报与背景图"
        case .douban: return "中文影视更全 · 免 Key · 非官方接口"
        case .tvdb: return "剧集资料与分集更细 · 需 API Key"
        }
    }

    var badge: String? {
        switch self {
        case .tmdb: return "推荐"
        case .douban: return "实验性"
        case .tvdb: return nil
        }
    }
}

/// 影院作用域：本地图库，或某一个网盘实例。刮削结果按作用域分别保存。
enum CinemaScope: Hashable {
    case local
    case mount(UUID)
}

/// 影院顶部的分段：全部 / 电影 / 电视剧 / 文件夹。
/// 状态放在 `LibraryStore`，让顶栏控制台与内容页共用同一个选中值。
enum CinemaTab: String, CaseIterable, Identifiable {
    case all
    case movies
    case shows
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .movies: return "电影"
        case .shows: return "电视剧"
        case .folder: return "文件夹"
        }
    }

    var icon: String {
        switch self {
        case .all: return "film.stack"
        case .movies: return "film"
        case .shows: return "tv"
        case .folder: return "folder"
        }
    }
}

/// 影院的内容类型：电影 / 电视剧之外，由刮削到的类型标签映射出的细分入口。
/// 内置四个（动漫 / 综艺 / 演唱会 / 纪录片）默认固定在顶栏，其余类型折叠进「类型」弹层。
/// 判定完全基于 TMDB / 豆瓣返回的类型标签，不额外扫目录。
struct CinemaContentType: Identifiable, Hashable {
    /// 稳定键：内置类型用固定 slug，普通类型直接用类型名。
    var id: String
    var title: String
    var icon: String
    /// 命中任意一个标签都算这个类型：TMDB 与豆瓣的用词不同，这里都收进来。
    var genreKeys: [String]

    static let anime = CinemaContentType(id: "anime", title: "动漫",
                                         icon: "sparkles",
                                         genreKeys: ["动画", "动漫"])
    static let variety = CinemaContentType(id: "variety", title: "综艺",
                                           icon: "theatermasks.fill",
                                           genreKeys: ["真人秀", "脱口秀", "综艺"])
    static let concert = CinemaContentType(id: "concert", title: "演唱会",
                                           icon: "music.mic",
                                           genreKeys: ["音乐", "演唱会", "音乐会"])
    static let documentary = CinemaContentType(id: "documentary", title: "纪录片",
                                               icon: "camera.fill",
                                               genreKeys: ["纪录", "纪录片"])

    static let builtIns: [CinemaContentType] = [anime, variety, concert, documentary]

    static func builtIn(id: String) -> CinemaContentType? {
        builtIns.first { $0.id == id }
    }

    /// 普通类型（动作 / 喜剧 / 科幻……）：标题就是类型名本身。
    static func generic(_ genre: String) -> CinemaContentType {
        CinemaContentType(id: genre, title: genre, icon: "tag", genreKeys: [genre])
    }

    static func descriptor(id: String) -> CinemaContentType {
        builtIn(id: id) ?? generic(id)
    }

    func matches(_ genres: [String]?) -> Bool {
        guard let genres, !genres.isEmpty else { return false }
        return genres.contains { genre in
            genreKeys.contains { genre == $0 || genre.contains($0) }
        }
    }

    /// 一组标签同时命中内置类型与普通类型（同一个标签不会被算两次）。
    static func ids(matching genres: [String]) -> [String] {
        var ids = builtIns.filter { $0.matches(genres) }.map(\.id)
        for genre in genres where !builtIns.contains(where: { $0.matches([genre]) }) {
            if !ids.contains(genre) { ids.append(genre) }
        }
        return ids
    }
}

/// 某个类型在当前影院里的可点条目数：电影按版本去重，剧集按整部计。
struct CinemaTypeBucket: Identifiable, Hashable {
    var type: CinemaContentType
    var count: Int
    var id: String { type.id }
}

/// 影院里的一个文件夹节点：可以一层层点进去。
/// `photos` 是当前目录直属视频；`subtreePhotos` 含所有子目录，用于统计与整目录刮削。
struct CinemaFolder: Identifiable {
    var path: String
    var name: String
    var parentPath: String?
    /// 人类可读的目录链（夸克等网盘的 path 是 ID，展示时用它）。
    var hint: String?
    var mountID: UUID?
    var photos: [PhotoItem]
    var entries: [CinemaEntry]
    var children: [CinemaFolder]
    var subtreePhotos: [PhotoItem]
    var matchedCount: Int
    var title: String?
    var kind: CinemaMediaKind?
    var posterURL: String?
    var backdropURL: String?
    var year: Int?
    var episodeCount: Int

    var id: String { path }
    var displayPath: String { hint ?? name }
    var displayTitle: String { title ?? name }
    var isMatched: Bool { matchedCount > 0 }
    var totalCount: Int { subtreePhotos.count }
    var unmatchedCount: Int { max(0, totalCount - matchedCount) }
    var firstPhoto: PhotoItem? { photos.first ?? subtreePhotos.first }
    var hasChildren: Bool { !children.isEmpty }
    var hasVideos: Bool { !photos.isEmpty }
}

/// 影院的浏览姿态：书架 / 海报墙 / 列表。只改变呈现，不改变数据。
enum CinemaViewMode: String, CaseIterable, Identifiable {
    case shelf
    case wall
    case card
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: return "书架"
        case .wall: return "海报墙"
        case .card: return "卡片"
        case .list: return "列表"
        }
    }

    var icon: String {
        switch self {
        case .shelf: return "rectangle.stack"
        case .wall: return "square.grid.2x2"
        case .card: return "rectangle.on.rectangle"
        case .list: return "list.bullet"
        }
    }
}

/// 海报墙密度：只改每列的最小宽度与卡片大小，不改数据。
enum CinemaWallDensity: String, CaseIterable, Identifiable {
    case compact
    case normal
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .normal: return "标准"
        case .large: return "大图"
        }
    }

    /// 海报墙每列最小宽度：越紧凑，同屏放的卡片越多。
    var minimumColumnWidth: CGFloat {
        switch self {
        case .compact: return 128
        case .normal: return 156
        case .large: return 196
        }
    }

    /// 卡片模式（16:9 宽幅）的最小列宽。
    var minimumCardWidth: CGFloat {
        switch self {
        case .compact: return 300
        case .normal: return 340
        case .large: return 400
        }
    }
}

/// 影院排序：只改变顺序，不改变集合。
enum CinemaSort: String, CaseIterable, Identifiable {
    case recent
    case rating
    case year
    case title
    case duration
    /// 随机：同一次进入影院内顺序稳定，下次进入重新洗牌。
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "最近添加（新 → 旧）"
        case .rating: return "评分（高 → 低）"
        case .year: return "年份（新 → 旧）"
        case .title: return "片名（A → Z）"
        case .duration: return "时长（长 → 短）"
        case .random: return "随机（每次进入重排）"
        }
    }

    var shortTitle: String {
        switch self {
        case .recent: return "最近"
        case .rating: return "评分"
        case .year: return "年份"
        case .title: return "片名"
        case .duration: return "时长"
        case .random: return "随机"
        }
    }
}

/// 观看状态筛选：从本地续播记录派生。
enum CinemaWatchFilter: String, CaseIterable, Identifiable, Hashable {
    case unwatched
    case inProgress
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unwatched: return "未看"
        case .inProgress: return "进行中"
        case .finished: return "已看完"
        }
    }
}

/// 分辨率筛选：从文件的像素宽度派生，不做主观画质判断。
enum CinemaResolutionFilter: String, CaseIterable, Identifiable, Hashable {
    case uhd4k
    case fullHD
    case sd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uhd4k: return "4K"
        case .fullHD: return "1080P / 2K"
        case .sd: return "720P 及以下"
        }
    }

    func matches(_ file: CinemaFile) -> Bool {
        let width = file.pixelWidth
        guard width > 0 else { return false }
        switch self {
        case .uhd4k: return width >= 3000
        case .fullHD: return width >= 1800 && width < 3000
        case .sd: return width < 1800
        }
    }
}

/// 规格筛选：从文件名里的发行标记派生，只做筛选与角标，不参与匹配。
enum CinemaSpecFilter: String, CaseIterable, Identifiable, Hashable {
    case dolbyVision
    case hdr
    case atmos
    case highFrameRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dolbyVision: return "杜比视界"
        case .hdr: return "HDR"
        case .atmos: return "杜比全景声"
        case .highFrameRate: return "高帧率"
        }
    }

    func matches(_ file: CinemaFile) -> Bool {
        switch self {
        case .dolbyVision:
            return file.displayTags.contains("DV")
        case .hdr:
            return file.displayTags.contains { $0 == "DV" || $0.hasPrefix("HDR") }
        case .atmos:
            return file.displayTags.contains("Atmos")
        case .highFrameRate:
            return (file.parsedFrameRate ?? 0) >= 50
        }
    }
}

/// 片长筛选：按分钟分档，剧集用单集时长。
enum CinemaRuntimeFilter: String, CaseIterable, Identifiable, Hashable {
    case short
    case standard
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "短片 <40"
        case .standard: return "标准 40–120"
        case .long: return "长片 >120"
        }
    }

    func matches(_ minutes: Int?) -> Bool {
        guard let minutes, minutes > 0 else { return false }
        switch self {
        case .short: return minutes < 40
        case .standard: return minutes >= 40 && minutes <= 120
        case .long: return minutes > 120
        }
    }
}

/// 评分筛选：按刮削到的评分分档；「暂无评分」单独一档。
enum CinemaRatingFilter: String, CaseIterable, Identifiable, Hashable {
    case excellent
    case great
    case good
    case unrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .excellent: return "9 分+"
        case .great: return "8 分+"
        case .good: return "7 分+"
        case .unrated: return "暂无评分"
        }
    }

    func matches(_ rating: Double?) -> Bool {
        switch self {
        case .excellent: return (rating ?? 0) >= 9
        case .great: return (rating ?? 0) >= 8
        case .good: return (rating ?? 0) >= 7
        case .unrated: return (rating ?? 0) <= 0
        }
    }
}

/// 地区 / 语言筛选里显示的语言名：原始值保留 ISO 代码，界面只负责翻译常见项。
enum CinemaLanguageCatalog {
    static func title(_ code: String) -> String {
        switch code.lowercased() {
        case "zh": return "中文"
        case "cn": return "粤语"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        case "it": return "意大利语"
        case "ru": return "俄语"
        case "hi": return "印地语"
        case "th": return "泰语"
        case "pt": return "葡萄牙语"
        case "ar": return "阿拉伯语"
        default: return code.uppercased()
        }
    }
}

/// 不同数据源归一化后的搜索结果，交给 `CinemaScraper` 统一打分。
struct CinemaMatch: Hashable {
    var id: String
    var isTV: Bool
    var title: String
    var originalTitle: String?
    var year: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String?
    var rating: Double?
    /// 投票数：同名作品里优先选更热门 / 更权威的那一条。
    var voteCount: Int?
    /// 类型标签（剧情 / 科幻 / 悬疑……），用于影院顶栏的筛选。
    var genres: [String] = []
    /// 这条结果来自哪个数据源；详情（合集 / 演职员 / 预告）只有 TMDB 能补。
    var provider: CinemaProvider? = nil

    /// 候选唯一键：不同数据源的数字 ID 可能撞号，比较与去重都带上来源。
    var sourceKey: String { "\(provider?.rawValue ?? "?")-\(id)" }
}

/// 演职员一条：只存展示需要的名字、角色、头像与 TMDB 人物 ID（人物页要按 ID 拉作品）。
struct CinemaCastMember: Codable, Hashable, Identifiable {
    var name: String
    var character: String?
    var profileURL: String?
    var tmdbID: Int? = nil

    var id: String { name + "|" + (character ?? "") }
}

/// 人物页「全部作品」里的一条：来自 TMDB combined_credits，不落库。
struct CinemaPersonCredit: Hashable, Identifiable {
    var tmdbID: Int
    var isTV: Bool
    var title: String
    var year: Int?
    var posterURL: String?
    var character: String?
    var job: String?

    var id: String { "\(isTV ? "tv" : "movie")-\(tmdbID)" }
}

/// 人物页数据：简介、出生信息与全部作品。
struct CinemaPersonProfile: Hashable {
    var name: String
    var biography: String?
    var birthday: String?
    var placeOfBirth: String?
    var profileURL: String?
    var department: String?
    var credits: [CinemaPersonCredit] = []
}

/// 合集详情：TMDB 合集简介 + 全集列表（用于算出「下一部未入库」）。
struct CinemaCollectionPart: Hashable {
    var tmdbID: Int
    var title: String
    var year: Int?
}

struct CinemaCollectionInfo: Hashable {
    var id: Int
    var name: String
    var overview: String?
    var parts: [CinemaCollectionPart] = []
}

/// 交给大模型做季集映射的单个文件（index 从 1 开始，和界面里的序号一致）。
struct CinemaAIMatchFile: Codable, Hashable {
    var index: Int
    var filename: String
    var detectedEpisode: Int?
    var durationSeconds: Double?
    var sizeBytes: Int64?
}

/// 智能季集映射的输入：剧名、季、文件列表和用户补充要求。
struct CinemaAIMatchRequest: Codable, Hashable {
    var title: String
    var year: Int?
    var season: Int
    var files: [CinemaAIMatchFile]
    var note: String?
}

/// 智能季集映射的计划：index → 集号；mode / offset 是模型可选调用的工具结果。
struct CinemaAIMatchPlan: Hashable {
    var assignments: [Int: Int]
    var mode: String?
    var offset: Int?
    var note: String?
}

/// 影院通知：任务结果归档，按今天 / 本周分组，仅保留最近 30 天。
enum CinemaNotificationKind: String, Codable, Hashable {
    case success
    case failure
    case progress
    case info
}

struct CinemaNotification: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: CinemaNotificationKind = .info
    var title: String
    var detail: String = ""
    var date: Date = Date()
    var read = false
    /// 行内动作标题（处理 / 重试 / 重连）；nil 表示只读通知。
    var action: String? = nil
    var scopeKey: String? = nil
}

/// 右上角 Toast：成功 4 秒消失，失败与进度常驻，最多同时 3 条。
enum CinemaToastKind: Hashable {
    case success
    case failure
    case progress
    case info
}

struct CinemaToast: Identifiable {
    let id = UUID()
    var kind: CinemaToastKind
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?
}

/// TMDB 单集信息：剧集详情里每集的标题、简介与剧照（按 tmdbID + 季缓存进图库设置库）。
struct CinemaEpisodeInfo: Codable, Hashable {
    var title: String
    var overview: String?
    var stillURL: String?
}

/// 相簿 / 网格多选右键「手动匹配」的目标：一次可以匹配多个视频（各自按文件名解析季集）。
struct CinemaQuickMatchRequest: Identifiable {
    let id = UUID()
    var photos: [PhotoItem]
}

/// TMDB 详情补全结果：合集、演职员、预告片与分级。
struct CinemaDetails: Hashable {
    var collectionID: Int?
    var collectionName: String?
    var cast: [CinemaCastMember] = []
    var directors: [String] = []
    var certification: String?
    var trailerKey: String?
    // 简介之外的基础资料：详情页「完整信息」用。
    var tagline: String?
    /// 电影片长 / 剧集单集时长（分钟）。
    var runtime: Int?
    /// 剧集播出状态：Returning Series / Ended 等。
    var status: String?
    var releaseDate: String?
    var originalLanguage: String?
    var countries: [String] = []
    var companies: [String] = []
    /// 剧集播出平台（Networks）。
    var networks: [String] = []
    var seasonCount: Int?
    var episodeCount: Int?
    var voteCount: Int?
    var budget: Int64?
    var revenue: Int64?
    /// 悬停档案 / 未入库作品展示用：简介、评分与类型。
    var overview: String?
    var rating: Double?
    var genres: [String] = []
}

/// 家长控制档位：按分级字符串换算，未识别分级的条目默认放行。
enum CinemaParentalLevel: Int, CaseIterable, Identifiable {
    case off = 0
    case child = 1
    case teen = 3
    case adult = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .child: return "儿童（G）"
        case .teen: return "青少年（PG-13）"
        case .adult: return "成人（R）"
        }
    }

    var detail: String {
        switch self {
        case .off: return "不做任何限制。"
        case .child: return "只显示 G / TV-Y / TV-G 级内容。"
        case .teen: return "允许到 PG / PG-13 / TV-14。"
        case .adult: return "允许到 R / NC-17 / TV-MA，即全部分级。"
        }
    }

    /// 分级字符串 → 1（G）… 4（R）；无法识别返回 nil。
    static func level(of certification: String?) -> Int? {
        guard let raw = certification?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "G", "TV-Y", "TV-Y7", "TV-G": return 1
        case "PG", "TV-PG": return 2
        case "PG-13", "TV-14": return 3
        case "R", "NC-17", "TV-MA", "18", "18+": return 4
        default: return nil
        }
    }

    func allows(certification: String?) -> Bool {
        guard self != .off else { return true }
        // 儿童模式：没有分级（未识别 / 刮削缺分级）一律按最严格处理，不冒险展示。
        guard let level = Self.level(of: certification) else { return false }
        return level <= rawValue
    }
}

/// 从文件名 + 所在文件夹解析出的基础信息。
struct CinemaParsedName: Equatable {
    var title: String
    /// 与主标题并列的另一语言名（中文名 / 英文名）。
    var altTitle: String?
    var year: Int?
    var season: Int?
    var episode: Int?
    /// 多集文件的结束集号（S01E01-E03）。
    var episodeEnd: Int?
    var isTV: Bool
    /// 从所在文件夹推断的剧名 / 片名。
    var folderTitle: String?
    /// 分辨率，仅用于展示与排查，不参与匹配。
    var resolution: String?
}

/// 剧集级跳过设置：片头 / 片尾各多少秒（0 表示不跳过）。
/// 按剧（`CinemaSeries.id`）保存，播放时自动应用，对应芝杜的「跳过片头尾」。
struct CinemaIntroMark: Codable, Hashable {
    var introSeconds: Int = 0
    var outroSeconds: Int = 0

    var isEnabled: Bool { introSeconds > 0 || outroSeconds > 0 }
}

/// 参与刮削的一条候选：文件本身 + 所在目录链（用于补全剧名 / 季 / 年份）。
struct CinemaCandidate {
    var photo: PhotoItem
    var folderHint: String?
    /// 所在目录的真实路径（网盘是目录 ID）：文件夹视图靠它还原可钻取的目录树。
    var folderPath: String?
}

/// 供影院库渲染与播放的轻量视频快照（不依赖网盘目录是否已加载）。
struct CinemaFile: Codable, Hashable {
    var photoID: UUID
    var filename: String
    var capturedAt: Date
    var duration: Double?
    var fileSize: Int64
    var cloudMountID: UUID?
    var cloudPath: String?
    var cloudRemoteID: String?
    var cloudThumbnailURL: String?
    /// 网盘端标记为受限内容时保留，影院播放同样需要给出准确提示。
    var cloudRestricted: Bool?
    /// 网盘返回的视频编码（hevc 等），影院播放转封装时同样需要。
    var videoCodec: String?
    var pixelWidth: Int
    var pixelHeight: Int
    /// 蓝光原盘 / ISO 的实际盘根路径；普通视频为空。影院播放也靠它走 `bluray:`。
    var externalPath: String?

    init(photo: PhotoItem) {
        photoID = photo.id
        filename = photo.displayFilename
        capturedAt = photo.capturedAt
        duration = photo.duration
        fileSize = photo.fileSize
        cloudMountID = photo.cloudMountID
        cloudPath = photo.cloudPath
        cloudRemoteID = photo.cloudRemoteID
        cloudThumbnailURL = photo.cloudThumbnailURL
        cloudRestricted = photo.cloudRestricted
        videoCodec = photo.videoCodec
        pixelWidth = photo.pixelWidth
        pixelHeight = photo.pixelHeight
        externalPath = photo.externalPath
    }

    var isCloud: Bool { cloudMountID != nil }

    /// 文件名 / 分辨率里的画质与音质标记。按辨识度排序，用于角标、筛选与详情。
    /// 有就全列出来：4K / DV / HDR10+ / 10bit / Atmos / DTS-HD / 60fps。
    var displayTags: [String] {
        let text = filename.lowercased()
        var tags: [String] = []

        // 画质分辨率
        if pixelWidth >= 3000 {
            tags.append("4K")
        } else if pixelWidth >= 1800 {
            tags.append("2K")
        } else if pixelWidth >= 1200 {
            tags.append("1080P")
        }

        // 动态范围
        if text.range(of: #"(?i)(^|[^a-z0-9])(dv|dovi|dolby[ .]?vision)([^a-z0-9]|$)"#,
                      options: .regularExpression) != nil,
           text.range(of: #"dvd"#, options: .regularExpression) == nil {
            tags.append("DV")
        }
        if text.range(of: #"(?i)hdr10\+|hdr10plus"#, options: .regularExpression) != nil {
            tags.append("HDR10+")
        } else if text.range(of: #"(?i)(^|[^a-z0-9])hdr10([^a-z0-9]|$)"#,
                             options: .regularExpression) != nil {
            tags.append("HDR10")
        } else if text.range(of: #"(?i)(^|[^a-z0-9])(hdr|hlg)([^a-z0-9]|$)"#,
                             options: .regularExpression) != nil {
            tags.append("HDR")
        }
        if text.range(of: #"(?i)(^|[^a-z0-9])10[ .]?bit([^a-z0-9]|$)"#,
                      options: .regularExpression) != nil {
            tags.append("10bit")
        }

        // 音质
        if text.range(of: #"(?i)(^|[^a-z0-9])atmos([^a-z0-9]|$)"#,
                      options: .regularExpression) != nil {
            tags.append("Atmos")
        }
        if text.range(of: #"(?i)dts[ .:-]?x([^a-z0-9]|$)"#, options: .regularExpression) != nil {
            tags.append("DTS:X")
        } else if text.range(of: #"(?i)dts[ .:-]?hd"#, options: .regularExpression) != nil {
            tags.append("DTS-HD")
        } else if text.range(of: #"(?i)(^|[^a-z0-9])dts([^a-z0-9]|$)"#,
                             options: .regularExpression) != nil {
            tags.append("DTS")
        }
        if text.range(of: #"(?i)true[ .]?hd"#, options: .regularExpression) != nil {
            tags.append("TrueHD")
        }

        // 高帧率才值得占一个角标
        if let fps = parsedFrameRate, fps >= 48 {
            tags.append("\(fps)fps")
        }
        return tags
    }

    /// 文件名里的帧率标记（`60fps` / `120 fps`）；没有则为 nil。
    var parsedFrameRate: Int? {
        guard let range = filename.range(of: #"(?i)\d{2,3}\s?fps"#,
                                         options: .regularExpression) else { return nil }
        let digits = filename[range].prefix { $0.isNumber }
        guard let value = Int(digits), value >= 23, value <= 240 else { return nil }
        return value
    }

    /// 还原成播放器认识的 PhotoItem；本地文件按文件名回到图库中查找。
    var photoItem: PhotoItem {
        var item = PhotoItem(id: photoID,
                             filename: filename,
                             editedFilename: nil,
                             originalName: filename,
                             capturedAt: capturedAt,
                             pixelWidth: pixelWidth,
                             pixelHeight: pixelHeight,
                             fileSize: fileSize,
                             kind: .video)
        item.duration = duration
        item.source = isCloud ? .cloud : .local
        item.cloudMountID = cloudMountID
        item.cloudPath = cloudPath
        item.cloudRemoteID = cloudRemoteID
        item.cloudThumbnailURL = cloudThumbnailURL
        item.cloudRestricted = cloudRestricted
        item.videoCodec = videoCodec
        item.externalPath = externalPath
        return item
    }
}

/// 一条刮削结果。未匹配到 TMDB 时也会保留，用于「未识别」列表与再次刮削。
struct CinemaEntry: Codable, Identifiable, Hashable {
    var file: CinemaFile
    var kind: CinemaMediaKind
    var matched: Bool
    var title: String
    var originalTitle: String?
    var year: Int?
    var season: Int?
    var episode: Int?
    var episodeEnd: Int?
    var tmdbID: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String?
    var rating: Double?
    /// 豆瓣评分：主源是 TMDB 时按需补一次，详情页三源评分牌用。
    var doubanRating: Double? = nil
    /// IMDb 评分：条目带 imdb_id 并且拿得到时才有。
    var imdbRating: Double? = nil
    var scrapedAt: Date
    /// 刮削时使用的目录链（剧名 / 季），再次刮削时继续用它。
    var folderHint: String?
    /// 类型标签（剧情 / 科幻 / 悬疑……）。旧版本刮削结果没有这一项，重新刮削即可补齐。
    var genres: [String]? = nil
    /// 详情补全：所属合集、演职员、导演、分级与预告片。
    var collectionID: Int? = nil
    var collectionName: String? = nil
    var cast: [CinemaCastMember]? = nil
    var directors: [String]? = nil
    var certification: String? = nil
    var trailerKey: String? = nil
    /// 详情补全的基础资料：宣传语、片长、状态、上映日期、语言 / 国家 / 公司 / 平台等。
    var tagline: String? = nil
    var runtime: Int? = nil
    var releaseDate: String? = nil
    var originalLanguage: String? = nil
    var countries: [String]? = nil
    var companies: [String]? = nil
    var networks: [String]? = nil
    var seasonCount: Int? = nil
    var episodeTotal: Int? = nil
    var voteCount: Int? = nil
    var budget: Int64? = nil
    var revenue: Int64? = nil
    var status: String? = nil
    /// 相似推荐（TMDB recommendations）：第一次打开详情时补一次，之后直接复用。
    var recommendations: [CinemaRecommendation]? = nil
    /// 推荐分组缓存：TMDB / 豆瓣 / 同系列 / 同导演 / 同演员，详情页按 tab 切换。
    var recommendationGroups: [CinemaRecommendationGroup]? = nil
    /// 推荐分组的抓取时间：旧缓存会按天刷新，避免豆瓣等后加的 tab 永远不出现。
    var recommendationGroupsAt: Date? = nil
    /// 用户手动挑过海报 / 背景后置为 true，重新刮削时不再覆盖。
    var artworkLocked: Bool? = nil
    /// 这条结果来自哪个数据源；只有 TMDB 能补详情。
    var provider: CinemaProvider? = nil

    var id: UUID { file.photoID }

    /// 年代（2020 年代返回 2020），筛选与分组都用它。
    var decade: Int? { year.map { $0 / 10 * 10 } }

    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if kind == .tv, let season, let episode {
            var value = String(format: "S%02dE%02d", season, episode)
            if let end = episodeEnd, end > episode {
                value = String(format: "S%02dE%02d-E%02d", season, episode, end)
            }
            parts.append(value)
        }
        return parts.joined(separator: " · ")
    }

    var artworkURL: String? { posterURL ?? backdropURL }
    /// 网格单元格是横向的，优先用 backdrop，避免竖版海报被裁得只剩一条。
    var gridArtworkURL: String? { backdropURL ?? posterURL }
}

/// 详情页返回记忆：上次查看的季与选中集。
struct CinemaSeriesMemory {
    var season: Int?
    var episodeID: UUID?
}

/// 影院本地续播记录：只保存播放位置与展示快照，不依赖刮削索引是否仍然存在。
struct CinemaProgressRecord: Codable, Hashable, Identifiable {
    var photoID: UUID
    var mountID: UUID?
    var title: String
    var subtitle: String?
    var artworkURL: String?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var id: UUID { photoID }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// 接近结尾就视为看完，不再出现在「继续观看」里，但仍保留在观看记录中。
    var isFinished: Bool { duration > 0 && fraction >= 0.95 }

    var remainingSeconds: Double { max(0, duration - position) }

    /// 记录是否可信：旧版本起流点换算错误会把整条时间轴放大 1000 倍，
    /// 这类记录的时长远超片源真实时长，既不能拿来续播，也不该出现在「继续观看」里。
    func isTrustworthy(realDuration: Double?) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return false }
        if let realDuration, realDuration > 0 {
            return duration <= realDuration * 1.5 + 60
        }
        // 拿不到片源时长时按上限兜底：正常影视不会超过 24 小时。
        return duration <= 24 * 3600
    }
}

/// 影院本地用户状态：收藏 / 想看 / 个人评分。按视频 photoID 存。
struct CinemaUserState: Codable, Hashable {
    var photoID: UUID
    var favorite: Bool = false
    var watchlist: Bool = false
    /// 0–5；nil 表示未评分。
    var rating: Int?
    var updatedAt: Date = Date()
}

/// 自定义清单：手动选片，只存 photoID 引用，不复制元数据。
struct CinemaListRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "list.bullet"
    var itemIDs: [UUID] = []
    var createdAt: Date = Date()

    var count: Int { itemIDs.count }
}

/// 同一部剧的多集聚合成一张卡片：影院里按「剧」浏览，而不是一集一张。
struct CinemaSeries: Identifiable, Hashable {
    var id: String
    var title: String
    var year: Int?
    var overview: String?
    var rating: Double?
    var posterURL: String?
    var backdropURL: String?
    var episodes: [CinemaEntry]

    var episodeCount: Int { episodes.count }

    /// 聚合里的分集是否已经识别；未识别的剧同样聚合成一张卡。
    var isMatched: Bool { episodes.first?.matched ?? false }

    var latestEpisode: CinemaEntry? {
        episodes.max { lhs, rhs in
            (lhs.season ?? 0, lhs.episode ?? 0) < (rhs.season ?? 0, rhs.episode ?? 0)
        }
    }

    var artworkURL: String? { posterURL ?? backdropURL }
    var gridArtworkURL: String? { backdropURL ?? posterURL }

    /// 类型标签取自分集（同一部剧各集一致），旧刮削结果可能为空。
    var genres: [String] {
        episodes.lazy.compactMap { $0.genres }.first(where: { !$0.isEmpty }) ?? []
    }

    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        parts.append("\(episodeCount) 集")
        if let latest = latestEpisode, let season = latest.season, let episode = latest.episode {
            parts.append(String(format: "最新 S%02dE%02d", season, episode))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 配置检测

/// 「测试连接」的一次结果，只在设置面板里展示。
struct CinemaConnectionResult: Equatable {
    var ok: Bool
    var message: String
}

/// 单条刮削结果：`entry` 为空代表网络 / 接口出错，`error` 为空代表正常（含未匹配）。
struct CinemaScrapeOutcome {
    var entry: CinemaEntry?
    var error: String?
    /// 本轮每个数据源各自的错误：批量刮削据此只降级出错的源，不整批停。
    var failedProviders: [CinemaProvider: String] = [:]
}
