import Foundation
import CoreGraphics

enum MediaKind: String, Codable {
    case photo
    case video
    case screenshot
    case panorama
    case selfie
}

enum PhotoSource: String, Codable {
    case local
    case system
    case cloud
}

/// 选片旗标：与评分、色标共同构成轻量元数据工作流。
enum PhotoFlag: String, Codable, CaseIterable, Identifiable {
    case none
    case pick
    case reject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无旗标"
        case .pick: return "留用"
        case .reject: return "排除"
        }
    }

    var icon: String {
        switch self {
        case .none: return "flag"
        case .pick: return "flag.fill"
        case .reject: return "xmark.circle.fill"
        }
    }
}

/// 色标：用于交付状态、主题分组等；与评分相互独立。
enum PhotoColorLabel: String, Codable, CaseIterable, Identifiable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无色标"
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .gray: return "灰色"
        }
    }
}

// MARK: - 整理工作室

/// 整理工作室的浏览维度：评分 / 旗标 / 色标 / 关键词。
enum OrganizeDimension: String, CaseIterable, Identifiable {
    case rating
    case flag
    case colorLabel
    case keyword

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rating: return "评分"
        case .flag: return "旗标"
        case .colorLabel: return "色标"
        case .keyword: return "关键词"
        }
    }

    var icon: String {
        switch self {
        case .rating: return "star.fill"
        case .flag: return "flag.fill"
        case .colorLabel: return "paintpalette.fill"
        case .keyword: return "tag.fill"
        }
    }

    var caption: String {
        switch self {
        case .rating: return "用 0–5 星排出先后，把值得留下的照片顶上来。"
        case .flag: return "留用与排除，让第一轮初筛更快完成。"
        case .colorLabel: return "用颜色给照片贴上用途或情绪，一眼就能找回来。"
        case .keyword: return "把零散的标签集中起来，按关键词整批回看。"
        }
    }
}

/// 整理工作室的分布统计（当前图库范围）。
struct OrganizeStudioStats: Equatable {
    var total = 0
    /// 下标 0…5：未评分与 1–5 星，各自的数量。
    var ratingCounts = [Int](repeating: 0, count: 6)
    var pick = 0
    var reject = 0
    var unflagged = 0
    /// key 为 `PhotoColorLabel.rawValue`。
    var colorCounts: [String: Int] = [:]
    var rated = 0
    var flagged = 0
    var labeled = 0
    /// 至少有一个关键词的照片数量（本地图库）。
    var keyworded = 0
}

struct PhotoItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var filename: String
    var editedFilename: String?
    var originalName: String
    /// 用户自定义标题（与官方「照片」的标题一致，可与文件名不同）。
    var title: String?
    var capturedAt: Date
    var addedAt: Date = Date()
    /// 同一批导入共用的批次 ID，用于「导入项目」按批次分组。
    var importBatchID: UUID?
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var kind: MediaKind = .photo
    var isFavorite: Bool = false
    var isHidden: Bool = false
    var deletedAt: Date?
    var editVersion: Int = 0
    var duration: Double?
    /// 非破坏性旋转：0/90/180/270，顺时针。为兼容旧数据使用可选值。
    var rotation: Int?

    var make: String?
    var model: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutterSpeed: String?
    var iso: String?
    var latitude: Double?
    var longitude: Double?
    var placeCountry: String?
    var placeProvince: String?
    var placeCity: String?
    var placeDistrict: String?
    var placePOI: String?
    var keywords: [String]?
    /// 星级评分 0–5；nil 视为 0，兼容旧库与旧 JSON。
    var rating: Int?
    /// 选片旗标；nil 视为无旗标。
    var flag: PhotoFlag?
    /// 色标；nil 视为无色标。
    var colorLabel: PhotoColorLabel?
    /// 原文件内容哈希（SHA-256），用于导入查重与内容级重复检测。
    var contentHash: String?
    /// 图像感知哈希（64 位 dHash），用于发现重压缩 / 缩放 / 轻微编辑副本。
    var perceptualHash: Int64?

    var source: PhotoSource?
    var systemOriginalPath: String?
    var systemThumbnailPath: String?
    /// 编辑配方（EditState 的 JSON），用于再次进入编辑器与复制/粘贴编辑点。
    var editRecipe: String?
    var isPortraitCapture: Bool = false
    var isDuplicateItem: Bool = false
    var isDeviceImport: Bool = false
    /// 官方图库中的实况照片 / 连拍项目（仅官方库可判定）。
    var isLivePhoto: Bool = false
    var isBurstItem: Bool = false
    /// 连拍组 ID（Photos.sqlite 的 ZAVALANCHEUUID）：同一组内共享，非连拍为 nil。
    var burstGroupID: String?
    /// 连拍组的代表照片（键照片，ZAVALANCHEPICKTYPE & 16；单成员组自身即代表）。
    var isBurstKeyPhoto: Bool = false
    /// 本地实况照片的配对视频文件名（位于 originals/<分片>/）。
    var livePhotoFilename: String?
    /// 系统图库实况照片的配对视频绝对路径。
    var livePhotoVideoPath: String?
    /// 慢动作视频（系统图库按 ZKINDSUBTYPE = 101 判定）。
    var isSlowMotion: Bool = false
    /// 录屏视频（系统图库按 ZISDETECTEDSCREENSHOT 或 ZKINDSUBTYPE = 103 判定）。
    var isScreenRecording: Bool = false
    /// 动图（系统图库按 ZPLAYBACKSTYLE = 2 判定）。
    var isAnimated: Bool = false
    /// 延时摄影（系统图库按 ZKINDSUBTYPE = 102 判定）。
    var isTimelapse: Bool = false
    /// 电影效果（`Photos.sqlite` 没有稳定字段，集合由 PhotoKit 智能相簿提供）。
    var isCinematic: Bool = false
    /// 空间照片 / 空间视频（系统图库按 ZSPATIALTYPE <> 0 判定）。
    var isSpatial: Bool = false
    /// 长曝光（系统图库由 PhotoKit 智能相簿判定）。
    var isLongExposure: Bool = false
    /// 最近查看 / 最近编辑时间（仅系统图库可读，本地库为 nil）。
    var viewedAt: Date?
    var editedAt: Date?

    var cloudMountID: UUID?
    var cloudPath: String?
    var cloudRemoteID: String?
    var cloudThumbnailURL: String?
    /// 库外媒体（蓝光目录 / 光盘镜像）：原文件不复制进 originals，直接引用这个路径。
    /// 有值时 `filename` 为空，播放与缩略图都从这里取源。
    var externalPath: String?
    /// 网盘端已把该文件标记为受限内容（夸克 risk_type ≠ 0），无法取得播放地址。
    var cloudRestricted: Bool?
    /// 网盘返回的视频编码（如 hevc），用于转封装时写正确的 hvc1 标签。
    var videoCodec: String?

    /// 展示 / 刮削用的文件名。蓝光原盘与 ISO 不复制进 originals，filename 为空，
    /// 这里回退到 originalName（目录名或镜像名），影院才能按名字识别成电影。
    var displayFilename: String {
        if let editedFilename, !editedFilename.isEmpty { return editedFilename }
        return filename.isEmpty ? originalName : filename
    }
    /// 展示用标题：优先用户标题，否则用原始文件名。
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return originalName
    }
    var isVideo: Bool { kind == .video }
    var hasEdits: Bool { editedFilename != nil }
    /// 按扩展名判定 RAW（导入与系统图库都适用）。
    var isRAWFile: Bool {
        let ext = (originalName as NSString).pathExtension.lowercased()
        return Self.rawExtensions.contains(ext)
    }
    /// 按扩展名判定动图（系统图库另有 isAnimated）。
    var isAnimatedFile: Bool {
        ["gif", "webp", "apng"].contains((originalName as NSString).pathExtension.lowercased())
    }

    /// 查看器是否按动图播放；已编辑的照片是静态渲染结果，不再播放。
    var playsAnimation: Bool {
        !isVideo && (isAnimated || isAnimatedFile) && !hasEdits
    }

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf",
        "rw2", "pef", "srw", "raw", "3fr", "erf", "mef", "mos", "iiq", "rwl"
    ]

    var isSystem: Bool { source == .system }
    var isCloud: Bool { source == .cloud }
    var isReadOnly: Bool { source == .system || source == .cloud }
    var cacheKey: String { "\(source?.rawValue ?? "local")-\(id.uuidString)-\(editVersion)" }
    var rotationAngle: Int {
        let value = ((rotation ?? 0) % 360 + 360) % 360
        return [0, 90, 180, 270].contains(value) ? value : 0
    }
    var isRotated: Bool { rotationAngle != 0 }
    var displayPixelWidth: Int {
        rotationAngle == 90 || rotationAngle == 270 ? pixelHeight : pixelWidth
    }
    var displayPixelHeight: Int {
        rotationAngle == 90 || rotationAngle == 270 ? pixelWidth : pixelHeight
    }
    var aspectRatio: CGFloat {
        guard displayPixelHeight > 0 else { return 1 }
        return CGFloat(displayPixelWidth) / CGFloat(displayPixelHeight)
    }
    var isDeleted: Bool { deletedAt != nil }
    var hasLocation: Bool { CoordinateValidator.isValid(latitude: latitude, longitude: longitude) }
    var tags: [String] { keywords ?? [] }

    /// 0–5 的稳定评分值；旧数据与越界值都会被收敛。
    var starRating: Int { min(5, max(0, rating ?? 0)) }
    var pickFlag: PhotoFlag { flag ?? .none }
    var labelColor: PhotoColorLabel { colorLabel ?? .none }

    /// 层级关键词使用 `/` 分隔，例如「旅行/日本/京都」。
    static func keywordComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func keywordLeaf(_ path: String) -> String {
        keywordComponents(path).last ?? path
    }

    static func keywordDepth(_ path: String) -> Int {
        max(0, keywordComponents(path).count - 1)
    }
}

/// 媒体类型总览里的分类：标题、图标、匹配规则与对应的侧边栏范围。
enum MediaTypeKey: String, CaseIterable, Identifiable {
    // 顺序与系统「照片」的媒体类型列表一致。
    case videos, selfies, livePhotos, portraits, longExposure, panoramas,
         timelapse, slowMotion, cinematic, spatial, bursts, screenshots,
         screenRecordings, animated, raws

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return "视频"
        case .selfies: return "自拍"
        case .livePhotos: return "实况照片"
        case .portraits: return "人像"
        case .longExposure: return "长曝光"
        case .panoramas: return "全景照片"
        case .timelapse: return "延时摄影"
        case .slowMotion: return "慢动作"
        case .cinematic: return "电影效果"
        case .spatial: return "空间"
        case .bursts: return "连拍快照"
        case .screenshots: return "截屏"
        case .screenRecordings: return "录屏"
        case .animated: return "动图"
        case .raws: return "RAW"
        }
    }

    var icon: String {
        switch self {
        case .videos: return "video"
        case .selfies: return "person.crop.circle"
        case .livePhotos: return "livephoto"
        case .portraits: return "person.crop.rectangle"
        case .longExposure: return "circle.dotted"
        case .panoramas: return "pano"
        case .timelapse: return "camera.metering.center.weighted"
        case .slowMotion: return "slowmo"
        case .cinematic: return "film"
        case .spatial: return "cube.transparent"
        case .bursts: return "square.stack.3d.down.right"
        case .screenshots: return "camera.viewfinder"
        case .screenRecordings: return "record.circle"
        case .animated: return "photo.on.rectangle.angled"
        case .raws: return "camera.aperture"
        }
    }

    /// 只有官方「照片」图库才会提供的分类，本地图库不展示。
    var isSystemOnly: Bool {
        switch self {
        case .portraits, .slowMotion, .screenRecordings,
             .longExposure, .timelapse, .cinematic, .spatial, .bursts:
            return true
        default: return false
        }
    }

    static var localCases: [MediaTypeKey] { allCases.filter { !$0.isSystemOnly } }

    func matches(_ photo: PhotoItem) -> Bool {
        switch self {
        case .videos: return photo.isVideo
        case .selfies: return !photo.isVideo && photo.kind == .selfie
        case .livePhotos: return photo.isLivePhoto
        case .portraits: return !photo.isVideo && photo.isPortraitCapture
        case .longExposure: return photo.isLongExposure
        case .panoramas: return photo.kind == .panorama
        case .timelapse: return photo.isTimelapse
        case .slowMotion: return photo.isSlowMotion
        case .cinematic: return photo.isCinematic
        case .spatial: return photo.isSpatial
        case .bursts: return photo.isBurstItem
        case .screenshots: return photo.kind == .screenshot
        case .screenRecordings: return photo.isScreenRecording
        case .animated: return photo.isAnimated || photo.isAnimatedFile
        case .raws: return photo.isRAWFile
        }
    }

    func item(system: Bool) -> SidebarItem {
        if system {
            switch self {
            case .videos: return .systemVideos
            case .selfies: return .systemSelfies
            case .livePhotos: return .systemLivePhotos
            case .portraits: return .systemPortraits
            case .longExposure: return .systemLongExposure
            case .panoramas: return .systemPanoramas
            case .timelapse: return .systemTimelapse
            case .slowMotion: return .systemSlowMotion
            case .cinematic: return .systemCinematic
            case .spatial: return .systemSpatial
            case .bursts: return .systemBursts
            case .screenshots: return .systemScreenshots
            case .screenRecordings: return .systemScreenRecordings
            case .animated: return .systemAnimated
            case .raws: return .systemRAW
            }
        }
        switch self {
        case .videos: return .videos
        case .selfies: return .selfies
        case .livePhotos: return .livePhotos
        case .panoramas: return .panoramas
        case .screenshots: return .screenshots
        case .animated: return .animated
        case .raws: return .raws
        case .portraits: return .people
        case .slowMotion, .screenRecordings, .timelapse, .cinematic, .spatial: return .videos
        case .longExposure, .bursts: return .library
        }
    }
}

/// 媒体类型总览用的汇总：数量与封面各一次遍历算完。
struct MediaTypeSummary {
    var counts: [MediaTypeKey: Int] = [:]
    var covers: [MediaTypeKey: PhotoItem] = [:]
}

struct KeywordOption: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

/// 相簿 / 文件夹层级面包屑：点任意一级可跳回该层。
struct AlbumBreadcrumb: Identifiable, Hashable {
    let id: String
    let title: String
    let item: SidebarItem
}

struct Album: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var photoIDs: [UUID] = []
    var folderID: UUID?
    /// 用户指定的封面（可为照片或视频）；为空时取相簿内第一张。
    var coverPhotoID: UUID?
}

struct AlbumFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var parentID: UUID?
    var createdAt: Date = Date()
}

struct FolderOption: Identifiable {
    let id: UUID
    let path: String
}

enum SidebarItem: Hashable, Codable {
    case library
    /// 影院：刮削后的电影 / 电视剧库。
    case cinema
    case collections
    case favorites
    case recentlySaved
    case duplicates
    case map
    case places
    case people
    case videos
    case screenshots
    case hidden
    case allAlbums
    /// 媒体类型总览（侧边栏「媒体类型」分区头点击进入）。
    case mediaTypes
    /// 场景总览（侧边栏「场景」分区头点击进入）。
    case scenes
    /// 更多项目总览（侧边栏「更多项目」分区头点击进入）。
    case moreItems
    /// 关键词总览：按关键词聚合的卡片墙。
    case keywords
    case album(UUID)
    case smartAlbum(UUID)
    case folder(UUID)
    case selfies
    case panoramas
    case livePhotos
    case animated
    case raws
    case recentlyEdited
    case imports
    case ocrTexts
    case scene(String)
    /// 图库体检：模糊照片、相似连拍备选、过大视频与「值得重看」范围。
    case health
    /// 整理工作室：评分 / 旗标 / 色标的分布与筛选。
    case ratings
    case flags
    case colorLabels
    case blurry
    case similarDuplicates
    case largeVideos
    case revisit
    case trash
    case systemLibrary
    /// 系统图库自己的精选集（只读汇总卡片）。
    case systemCollections
    /// 系统图库根层相簿（侧边栏「相簿」分区头点击进入）。
    case systemAlbums
    /// 系统图库媒体类型总览。
    case systemMediaTypes
    /// 系统图库更多项目总览。
    case systemMoreItems
    /// 系统图库关键词总览：关键词来自拾光的补充元数据。
    case systemKeywords
    /// 已连接的系统图库列表总览（侧边栏「系统图库」分区头点击进入）。
    case systemLibraries
    /// 网络存储列表总览（侧边栏「网络存储」分区头点击进入）。
    case cloudStorages
    /// 网络资源总览（侧边栏「网络资源」分区头点击进入）。
    case catalogSources
    /// 网络影院：聚合网络影视源（苹果CMS）的电影 / 电视剧，与网络存储的影院相互独立。
    case networkCinema
    case systemAlbum(Int64)
    case systemFolder(Int64)
    case systemFavorites
    case systemVideos
    case systemScreenshots
    case systemHidden
    case systemTrash
    case systemPortraits
    case systemSelfies
    case systemLivePhotos
    case systemPanoramas
    /// 系统图库媒体类型：长曝光 / 延时摄影 / 电影效果 / 连拍快照。
    case systemLongExposure
    case systemTimelapse
    case systemCinematic
    case systemSpatial
    case systemBursts
    case systemSlowMotion
    case systemScreenRecordings
    case systemAnimated
    case systemRAW
    case systemEdited
    case systemRecentlyViewed
    case systemDuplicates
    case systemRecentlySaved
    case systemImports
    /// 单个导入会话（点进「导入项目」里的某一次导入）。
    case systemImportSession(Int64)
    /// 系统图库「值得重看」（纯元数据派生，只读）。
    case systemRevisit
    /// 系统图库场景总览与单个场景（端侧识别结果缓存在 `system_analysis`）。
    case systemScenes
    case systemScene(String)
    /// 系统图库「包含文字」（端侧 OCR 结果缓存在 `system_analysis`）。
    case systemOcrTexts
    /// 系统图库图库体检（只读预览，基于缩略图与缓存特征）。
    case systemHealth
    /// 系统图库整理工作室：评分 / 旗标 / 色标（写入拾光的补充元数据）。
    case systemRatings
    case systemFlags
    case systemColorLabels
    case systemMap
    case systemPlaces
    case systemPeople
    case cloudMount(UUID)
    /// 某一个网盘实例自己的影院（刮削结果与海报都归属这个网盘）。
    case cloudCinema(UUID)
    /// 网络资源（影视源）：与网盘并列，但没有文件树与本地索引。
    case catalogSource(UUID)
    /// 网络电视：直播频道墙，可整体开关。
    case iptv

    /// 是否属于只读的系统「照片」图库范围。
    var isSystemScope: Bool {
        switch self {
        case .systemLibrary, .systemCollections, .systemAlbum, .systemFolder,
             .systemFavorites, .systemVideos,
             .systemScreenshots, .systemHidden, .systemTrash,
             .systemPortraits, .systemSelfies, .systemLivePhotos, .systemPanoramas,
             .systemLongExposure, .systemTimelapse, .systemCinematic, .systemSpatial, .systemBursts,
             .systemSlowMotion, .systemScreenRecordings, .systemAnimated, .systemRAW,
             .systemEdited, .systemRecentlyViewed, .systemDuplicates,
             .systemRecentlySaved, .systemImports, .systemImportSession, .systemRevisit,
             .systemScenes, .systemScene, .systemOcrTexts, .systemHealth, .systemMap,
             .systemPlaces, .systemPeople, .systemAlbums, .systemMediaTypes,
             .systemMoreItems, .systemKeywords,
             .systemRatings, .systemFlags, .systemColorLabels:
            return true
        default:
            return false
        }
    }
}

struct SystemAlbumInfo: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let parentFolder: Int64?
    let assetIDs: [UUID]
    /// 图库内原始顺序（Photos.sqlite 的 Z_PK），用于与官方「照片」保持一致的相簿排序。
    var sortIndex: Int64 = 0
    /// Photos.sqlite 的 ZUUID：用于映射 PhotoKit 的 localIdentifier（写回相簿时必需）。
    var uuid: String? = nil
    /// 官方图库给这个相簿保存的排序方式（`ZGENERICALBUM.ZCUSTOMSORTKEY`）。
    /// 位含义：1 = 按日期、2 = 按标题、4 = 手动拖拽顺序；0 表示跟随默认（拍摄日期降序）。
    var customSortKey: Int? = nil
    /// 官方图库保存的排序方向（`ZGENERICALBUM.ZCUSTOMSORTASCENDING`）。
    var customSortAscending: Bool? = nil
}

struct SystemFolderInfo: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let parent: Int64?
    /// 图库内原始顺序（Photos.sqlite 的 Z_PK）；与相簿共用同一序列，可混排。
    var sortIndex: Int64 = 0
}

/// 官方「照片」的一次导入会话（Photos.sqlite 的 `ZGENERICALBUM.ZKIND = 1506`）。
/// `id` 同时是 `ZASSET.ZIMPORTSESSION` 的外键，官方已缓存该批次数量。
struct SystemImportSession: Identifiable, Hashable {
    let id: Int64
    let createdAt: Date
    let count: Int
    let uuid: String?
}

/// 导入批次的补充概览：批内照片的拍摄跨度与视频数量，用于顶部栏的批次信息。
struct SystemImportSessionSummary {
    let earliest: Date?
    let latest: Date?
    let videoCount: Int
    let totalCount: Int
}

/// 系统图库侧边栏的一个条目：文件夹与相簿按原始顺序混排。
enum SystemSidebarEntry: Identifiable {
    case folder(SystemFolderInfo)
    case album(SystemAlbumInfo)

    var id: String {
        switch self {
        case .folder(let folder): return "folder-\(folder.id)"
        case .album(let album): return "album-\(album.id)"
        }
    }

    var sortIndex: Int64 {
        switch self {
        case .folder(let folder): return folder.sortIndex
        case .album(let album): return album.sortIndex
        }
    }
}

/// 已连接的系统「照片」图库（可同时登记多个，侧边栏逐个展示）。
struct SystemLibraryRef: Identifiable, Codable, Hashable {
    var path: String
    var name: String

    var id: String { path }
}

/// 被固定到侧边栏「固定」分区的项目：系统智能项、相簿、智能相簿、文件夹或系统图库里的相簿 / 文件夹。
enum PinnedSidebarItem: Codable, Hashable, Identifiable {
    case system(String)
    case album(UUID)
    case smartAlbum(UUID)
    case folder(UUID)
    case systemAlbum(Int64)
    case systemFolder(Int64)

    var id: String {
        switch self {
        case .system(let key): return "system-\(key)"
        case .album(let id): return "album-\(id.uuidString)"
        case .smartAlbum(let id): return "smartAlbum-\(id.uuidString)"
        case .folder(let id): return "folder-\(id.uuidString)"
        case .systemAlbum(let id): return "systemAlbum-\(id)"
        case .systemFolder(let id): return "systemFolder-\(id)"
        }
    }
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case edited
    case photos
    case videos
    case screenshots
    case mine
    case notInAlbum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "所有项目"
        case .favorites: return "个人收藏"
        case .edited: return "已编辑"
        case .photos: return "照片"
        case .videos: return "视频"
        case .screenshots: return "截屏"
        case .mine: return "由我拍摄"
        case .notInAlbum: return "不在相簿中"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "heart"
        case .edited: return "slider.horizontal.3"
        case .photos: return "photo"
        case .videos: return "video"
        case .screenshots: return "camera.viewfinder"
        case .mine: return "camera"
        case .notInAlbum: return "rectangle.stack.badge.minus"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case capturedAt
    case addedAt
    case title
    case filename
    case fileSize
    case kind
    case camera
    case place
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capturedAt: return "拍摄日期"
        case .addedAt: return "添加日期"
        case .title: return "标题"
        case .filename: return "文件名"
        case .fileSize: return "文件大小"
        case .kind: return "文件类型"
        case .camera: return "相机"
        case .place: return "地点"
        case .duration: return "时长"
        }
    }

    var icon: String {
        switch self {
        case .capturedAt: return "calendar"
        case .addedAt: return "tray.and.arrow.down"
        case .title: return "textformat"
        case .filename: return "doc.text"
        case .fileSize: return "internaldrive"
        case .kind: return "square.stack.3d.up"
        case .camera: return "camera"
        case .place: return "mappin.and.ellipse"
        case .duration: return "timer"
        }
    }

    /// 名称类默认升序，日期/大小类默认降序。
    var prefersAscending: Bool {
        switch self {
        case .title, .filename, .kind, .camera, .place: return true
        default: return false
        }
    }

    var directionTitle: String {
        switch self {
        case .capturedAt, .addedAt: return "升序为最旧优先，降序为最新优先"
        case .title, .filename, .kind, .camera, .place: return "升序为 A→Z，降序为 Z→A"
        case .fileSize, .duration: return "升序为从小到大，降序为从大到小"
        }
    }
}

enum ThumbnailAspect: String, CaseIterable, Identifiable {
    case square
    case actual
    case masonry
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return "正方形"
        case .actual: return "完整宽高比"
        case .masonry: return "瀑布流"
        case .list: return "列表"
        }
    }

    var icon: String {
        switch self {
        case .square: return "square.grid.2x2"
        case .actual: return "aspectratio"
        case .masonry: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        }
    }
}

/// 相簿总览（「所有相簿」与文件夹层级）的展示形式。
enum AlbumDisplayStyle: String, CaseIterable, Identifiable {
    case grid
    case list
    case collage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        case .collage: return "拼贴墙"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .collage: return "rectangle.grid.2x2"
        }
    }

    var help: String {
        switch self {
        case .grid: return "大卡片展示相簿封面"
        case .list: return "紧凑行展示封面、名称与数量"
        case .collage: return "无边拼贴墙，名称叠加在封面上"
        }
    }
}

/// 「人物」总览的头像形状（圆形 / 圆角方形，参考官方照片 App 的方形大卡片），随当前图库保存。
enum PeopleDisplayStyle: String, CaseIterable, Identifiable {
    case circle
    case roundedSquare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: return "圆形"
        case .roundedSquare: return "圆角方形"
        }
    }

    var icon: String {
        switch self {
        case .circle: return "circle"
        case .roundedSquare: return "roundedrect"
        }
    }

    var help: String {
        switch self {
        case .circle: return "圆形头像卡片"
        case .roundedSquare: return "圆角方形头像卡片"
        }
    }
}

enum GridGrouping: String, CaseIterable, Identifiable {
    case years
    case months
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .years: return "年"
        case .months: return "月"
        case .all: return "所有照片"
        }
    }
}

/// 网格的堆叠浏览形态：把连拍 / 同场景连拍收成一张代表图，展开后再看整组。
enum StackMode: String, CaseIterable, Identifiable {
    case off
    case bursts
    case scenes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭堆叠"
        case .bursts: return "仅连拍"
        case .scenes: return "连拍与同场景"
        }
    }

    /// 菜单 / 悬停提示里的完整说明。
    var detail: String {
        switch self {
        case .off: return "每张照片单独显示"
        case .bursts: return "同一连拍组收成一张代表图"
        case .scenes: return "连拍组、实况与同场景连拍都收成一张代表图"
        }
    }

    var icon: String {
        switch self {
        case .off: return "square.stack.3d.down.right"
        case .bursts, .scenes: return "square.stack.3d.down.right.fill"
        }
    }
}

struct PhotoSection: Identifiable {
    let id: String
    let title: String?
    let photos: [PhotoItem]
}

enum CropAspect: String, Codable, CaseIterable, Identifiable {
    case original
    case square
    case fourThree
    case threeFour
    case sixteenNine
    case nineSixteen
    case cinematic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始"
        case .square: return "正方形"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        case .cinematic: return "2.39:1"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        case .cinematic: return 2.39
        }
    }
}

enum FilterPreset: String, Codable, CaseIterable, Identifiable {
    case none
    case vivid
    case warm
    case cool
    case mono
    case instant
    case noir
    case fade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "原片"
        case .vivid: return "鲜明"
        case .warm: return "暖色"
        case .cool: return "冷色"
        case .mono: return "黑白"
        case .instant: return "复古"
        case .noir: return "银盐"
        case .fade: return "褪色"
        }
    }

    var ciName: String? {
        switch self {
        case .none: return nil
        case .vivid: return "CIPhotoEffectChrome"
        case .warm: return "CIPhotoEffectTransfer"
        case .cool: return "CIPhotoEffectProcess"
        case .mono: return "CIPhotoEffectMono"
        case .instant: return "CIPhotoEffectInstant"
        case .noir: return "CIPhotoEffectNoir"
        case .fade: return "CIPhotoEffectFade"
        }
    }
}

enum DateText {
    static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年"
        return f
    }()

    static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 精确到秒的时分秒：查看器顶栏与信息面板用它区分同一分钟内的连拍。
    static let secondTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 顶栏副标题用的紧凑日期范围：同一天只显示一个日期，同年省略年份、同月省略月份与年份。
    static func span(from start: Date, to end: Date) -> String {
        let calendar = Calendar.current
        let a = calendar.dateComponents([.year, .month, .day], from: start)
        let b = calendar.dateComponents([.year, .month, .day], from: end)
        guard let ay = a.year, let am = a.month, let ad = a.day,
              let by = b.year, let bm = b.month, let bd = b.day else { return "" }
        if ay == by, am == bm, ad == bd { return "\(ay)年\(am)月\(ad)日" }
        if ay == by, am == bm { return "\(ay)年\(am)月\(ad)日 – \(bd)日" }
        if ay == by { return "\(ay)年\(am)月\(ad)日 – \(bm)月\(bd)日" }
        return "\(ay)年\(am)月\(ad)日 – \(by)年\(bm)月\(bd)日"
    }
}

func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
