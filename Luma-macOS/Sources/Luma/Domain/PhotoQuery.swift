import Foundation

/// 可下推到 SQLite 的图库查询范围（仅本地图库；系统图库与网盘不走这里）。
enum PhotoQueryScope: String, Sendable {
    case library
    case favorites
    case videos
    case screenshots
    case selfies
    case panoramas
    case livePhotos
    case animated
    case raws
    case recentlyEdited
    case recentlySaved
    case hidden
    case trash
}

/// 大图库的分页查询描述：筛选、排序、范围全部交给 SQLite，Store 只持有窗口数据。
struct PhotoQuery: Equatable, Sendable {
    var scope: PhotoQueryScope = .library
    var filter: PhotoFilter = .all
    var keyword: String?
    var sortKey: SortKey = .capturedAt
    var ascending: Bool = false
    /// 元数据筛选：评分下限（0 表示不限）、旗标、色标。
    var minRating: Int = 0
    var flag: PhotoFlag?
    var colorLabel: PhotoColorLabel?

    /// 影响窗口内容与顺序的指纹（不含图库内容版本号）。
    var key: String {
        [
            scope.rawValue,
            filter.rawValue,
            keyword ?? "",
            sortKey.rawValue,
            String(ascending),
            String(minRating),
            flag?.rawValue ?? "",
            colorLabel?.rawValue ?? ""
        ].joined(separator: "|")
    }
}

/// 年 / 月总览卡片：`photos` 只保留最多 4 张样本，`count` 是该周期的真实总数。
struct PhotoPeriodBucket: Identifiable {
    let id: String
    let title: String
    let count: Int
    let photos: [PhotoItem]
    let capturedAt: Date
}

/// 「月」总览里的一天：样本 + 当天总数。
struct PhotoDayBucket: Identifiable {
    let id: String
    let title: String
    let count: Int
    let photos: [PhotoItem]
    let capturedAt: Date
}

/// 「月」总览里的一个月：按月分段，段内按天展示。
struct PhotoMonthGroup: Identifiable {
    let id: String
    let title: String
    let count: Int
    let days: [PhotoDayBucket]
    /// 直连模式下没有逐天数据，用这个月的样本直接渲染卡片。
    var samples: [PhotoItem] = []
}

extension SidebarItem {
    /// 能完整翻译成 SQL 的本地范围；返回 nil 表示继续走内存路径
    /// （相簿顺序、智能相簿、人物、地点、重复项目等）。
    var photoQueryScope: PhotoQueryScope? {
        switch self {
        case .library:
            return .library
        case .favorites:
            return .favorites
        case .videos:
            return .videos
        case .screenshots:
            return .screenshots
        case .selfies:
            return .selfies
        case .panoramas:
            return .panoramas
        case .livePhotos:
            return .livePhotos
        case .animated:
            return .animated
        case .raws:
            return .raws
        case .recentlyEdited:
            return .recentlyEdited
        case .recentlySaved:
            return .recentlySaved
        case .hidden:
            return .hidden
        case .trash:
            return .trash
        default:
            return nil
        }
    }
}
