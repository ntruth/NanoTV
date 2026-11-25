import Foundation

/// 系统「照片」图库的索引查询范围：全部可翻译成 `SystemIndex.sqlite` 的 SQL。
/// 只描述“查什么”，不做 IO。
enum SystemQueryScope: Equatable, Sendable {
    case all
    case favorites
    case videos
    case screenshots
    case hidden
    case trash
    case portraits
    case selfies
    case livePhotos
    case longExposures
    case panoramas
    case timelapses
    case slowMotion
    case cinematics
    case spatial
    case bursts
    case screenRecordings
    case animated
    case raws
    case edited
    case recentlyViewed
    case duplicates
    case recentlySaved
    case imports
    /// 单次导入会话（官方「导入项目」里的一个批次）。
    case importSession(Int64)
    case revisit
    case withLocation
    case album(Int64)
    case folder(Int64)
    case person(Int64)

    var rawKey: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .videos: return "videos"
        case .screenshots: return "screenshots"
        case .hidden: return "hidden"
        case .trash: return "trash"
        case .portraits: return "portraits"
        case .selfies: return "selfies"
        case .livePhotos: return "livePhotos"
        case .longExposures: return "longExposures"
        case .panoramas: return "panoramas"
        case .timelapses: return "timelapses"
        case .slowMotion: return "slowMotion"
        case .cinematics: return "cinematics"
        case .spatial: return "spatial"
        case .bursts: return "bursts"
        case .screenRecordings: return "screenRecordings"
        case .animated: return "animated"
        case .raws: return "raws"
        case .edited: return "edited"
        case .recentlyViewed: return "recentlyViewed"
        case .duplicates: return "duplicates"
        case .recentlySaved: return "recentlySaved"
        case .imports: return "imports"
        case .importSession(let id): return "importSession-\(id)"
        case .revisit: return "revisit"
        case .withLocation: return "withLocation"
        case .album(let id): return "album-\(id)"
        case .folder(let id): return "folder-\(id)"
        case .person(let id): return "person-\(id)"
        }
    }
}

/// 大图库的系统图库分页查询描述：筛选、排序、范围全部交给索引库，内存只保留当前窗口。
struct SystemQuery: Equatable, Sendable {
    var scope: SystemQueryScope = .all
    var filter: PhotoFilter = .all
    var sortKey: SortKey = .capturedAt
    var ascending: Bool = false
    /// 相簿使用图库保存的手动顺序（Photos.sqlite 关联表的 `Z_FOK_3ASSETS`）。
    var manualOrder = false
    /// 搜索解析出的时间范围。
    var startDate: Date?
    var endDate: Date?
    var onlyFavorites = false
    var onlyVideos = false
    var onlyPhotos = false
    var onlyScreenshots = false
    var onlyLivePhotos = false
    var onlyEdited = false
    /// 只看带有效定位的照片：人物详情的「地图」在索引里直接裁掉没有 GPS 的行，
    /// 不必把整个人的照片读进内存再过滤。
    var onlyLocated = false
    /// 搜索词（空格分词，全部命中才算匹配）。
    var tokens: [String] = []
    /// 直连模式的地点名命中：`Photos.sqlite` 里的地名只有二进制归档，SQL 无法直接比对，
    /// 这里按 token 传入「地点名匹配到的资产 UUID」，在 SQL 里作为该 token 的 OR 条件。
    var tokenPlaceIDs: [String: [String]]?
    /// 关键词 / AI 标签 / OCR 命中的资产：`Photos.sqlite` 与索引里都没有这些字段，
    /// 按 token 传入内存索引算出的 UUID，在 SQL 里作为该 token 的 OR 条件。
    var tokenKeywordIDs: [String: [String]]?
    /// 关键词筛选命中的照片 ID（来自拾光补充元数据，索引里没有这些数据）。
    var overlayKeywordIDs: [String]?
    /// 地点聚类等派生范围：只在这些 ID 里查（索引无法表达同样的聚类规则）。
    var includeIDs: [String]?
    /// 拾光补充元数据对收藏 / 隐藏的覆盖：索引里是 Photos.sqlite 的原值，这里参与查询。
    var favoriteAdds: [String] = []
    var favoriteRemoves: [String] = []
    var hiddenAdds: [String] = []
    var hiddenRemoves: [String] = []
    /// 「最近保存 / 最近查看」的截止时间。
    var savedCutoff: Date?
    var viewedCutoff: Date?

    /// 影响窗口内容与顺序的指纹。
    var key: String {
        var parts: [String] = []
        parts.append(scope.rawKey)
        parts.append(filter.rawValue)
        parts.append(sortKey.rawValue)
        parts.append(String(ascending))
        parts.append(String(manualOrder))
        parts.append(startDate.map { String($0.timeIntervalSince1970) } ?? "")
        parts.append(endDate.map { String($0.timeIntervalSince1970) } ?? "")
        parts.append(String(onlyFavorites))
        parts.append(String(onlyVideos))
        parts.append(String(onlyPhotos))
        parts.append(String(onlyScreenshots))
        parts.append(String(onlyLivePhotos))
        parts.append(String(onlyEdited))
        parts.append(String(onlyLocated))
        parts.append(tokens.joined(separator: "\u{1F}"))
        parts.append(tokenPlaceIDs?.keys.sorted()
            .map { "\($0):\(tokenPlaceIDs?[$0]?.count ?? 0)" }
            .joined(separator: ",") ?? "")
        parts.append(tokenKeywordIDs?.keys.sorted()
            .map { "\($0):\(tokenKeywordIDs?[$0]?.count ?? 0)" }
            .joined(separator: ",") ?? "")
        parts.append(overlayKeywordIDs?.joined(separator: ",") ?? "")
        parts.append(includeIDs?.joined(separator: ",") ?? "")
        parts.append(favoriteAdds.joined(separator: ","))
        parts.append(favoriteRemoves.joined(separator: ","))
        parts.append(hiddenAdds.joined(separator: ","))
        parts.append(hiddenRemoves.joined(separator: ","))
        parts.append(savedCutoff.map { String($0.timeIntervalSince1970) } ?? "")
        parts.append(viewedCutoff.map { String($0.timeIntervalSince1970) } ?? "")
        return parts.joined(separator: "|")
    }
}

extension SidebarItem {
    /// 能完整翻译成索引 SQL 的系统图库范围；返回 nil 表示该范围不返回照片网格。
    var systemQueryScope: SystemQueryScope? {
        switch self {
        case .systemLibrary:
            return .all
        case .systemPeople:
            // 人物总览是卡片墙；点进某个人物后由 Store 换成 person 范围。
            return nil
        case .systemFavorites: return .favorites
        case .systemVideos: return .videos
        case .systemScreenshots: return .screenshots
        case .systemHidden: return .hidden
        case .systemTrash: return .trash
        case .systemPortraits: return .portraits
        case .systemSelfies: return .selfies
        case .systemLivePhotos: return .livePhotos
        case .systemLongExposure: return .longExposures
        case .systemPanoramas: return .panoramas
        case .systemTimelapse: return .timelapses
        case .systemSlowMotion: return .slowMotion
        case .systemCinematic: return .cinematics
        case .systemSpatial: return .spatial
        case .systemBursts: return .bursts
        case .systemScreenRecordings: return .screenRecordings
        case .systemAnimated: return .animated
        case .systemRAW: return .raws
        case .systemEdited: return .edited
        case .systemRecentlyViewed: return .recentlyViewed
        case .systemDuplicates: return .duplicates
        case .systemRecentlySaved: return .recentlySaved
        case .systemImportSession(let id): return .importSession(id)
        case .systemRevisit: return .revisit
        case .systemMap, .systemPlaces: return .withLocation
        case .systemAlbum(let id): return .album(id)
        case .systemFolder(let id): return .folder(id)
        default: return nil
        }
    }
}
