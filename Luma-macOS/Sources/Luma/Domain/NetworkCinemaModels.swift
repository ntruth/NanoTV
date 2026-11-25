import Foundation

/// 网络影院的分页：影院管理 / 榜单 / 电影 / 电视剧 / 日历 / 足迹 / 关注。
/// 与「网络存储」里的影院完全独立：这里只聚合网络影视源（苹果CMS 等）的条目。
/// 版式对齐「网络资源」与「网络存储」：管理、发现、浏览、回看各占一页，切换入口在窗口工具栏。
enum NetworkCinemaTab: String, CaseIterable, Identifiable {
    case manage
    case ranking
    case movies
    case shows
    case calendar
    case history
    case following

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manage: return "影院管理"
        case .ranking: return "榜单"
        case .movies: return "电影"
        case .shows: return "电视剧"
        case .calendar: return "日历"
        case .history: return "足迹"
        case .following: return "关注"
        }
    }

    var symbol: String {
        switch self {
        case .manage: return "slider.horizontal.3"
        case .ranking: return "chart.bar.fill"
        case .movies: return "film.fill"
        case .shows: return "tv.fill"
        case .calendar: return "calendar"
        case .history: return "clock.arrow.circlepath"
        case .following: return "star.circle.fill"
        }
    }

    /// 只有电影 / 电视剧会去影视源拉列表；管理、榜单、日历、足迹、关注都读本机聚合数据。
    var browsesContent: Bool {
        self == .movies || self == .shows
    }

    /// 分页记忆：重开应用后仍停在上一页。
    static let storageKey = "networkCinema.tab.v1"

    static var persisted: NetworkCinemaTab {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let tab = NetworkCinemaTab(rawValue: raw) else { return .movies }
        return tab
    }
}

/// 聚合后的一个条目：保留所属源，点击时直接走该源的详情与播放。
/// Codable 用于列表快照：重新进入网络影院时先用上次内容铺满。
struct NetworkCinemaItem: Identifiable, Hashable, Codable {
    var source: CatalogSource
    var item: CatalogItem
    /// 用来决定 TMDB 按电影还是电视剧检索，以及卡片上的类型标记。
    var isTV: Bool

    var id: String { "\(source.id.uuidString)|\(item.id)" }

    var enrichmentKey: String {
        NetworkCinemaEnrichment.key(title: item.title, isTV: isTV)
    }
}

/// TMDB 补全的元数据：海报、评分、简介、年份与类型。
struct NetworkCinemaEnrichment: Codable, Hashable {
    var tmdbID: Int
    var isTV: Bool
    var title: String
    var originalTitle: String?
    var year: Int?
    var posterURL: String?
    var backdropURL: String?
    var overview: String?
    var rating: Double?
    var voteCount: Int?
    var genres: [String] = []

    /// 缓存键：标题归一化 + 电影/剧集，避免同名电影与剧集互相覆盖。
    static func key(title: String, isTV: Bool) -> String {
        normalized(cleanedTitle(title)) + "|" + (isTV ? "tv" : "movie")
    }

    /// 只保留字母与数字：中文标题里的空格、标点、副标题符号都不参与比较。
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 去掉年份、括号说明与常见清晰度 / 语言后缀，提升 TMDB 命中率。
    static func cleanedTitle(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"[\(\[【（][^\)\]】）]*[\)\]】）]"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(19|20)\d{2}"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "国语|粤语|中字|双字|高清|蓝光|完整版|未删减|HD|4K",
                                         with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从标题里认出年份（常见写法「沙丘2 (2024)」），没有就返回 nil。
    static func year(in raw: String) -> Int? {
        guard let range = raw.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return Int(raw[range])
    }
}
