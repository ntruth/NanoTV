import Foundation

/// 源的健康状况：总览卡片上的状态徽章。
enum CatalogSourceHealth: String, Codable, Hashable {
    case unknown
    case checking
    case online
    case limited
    case offline

    var title: String {
        switch self {
        case .unknown: return "未检测"
        case .checking: return "检测中"
        case .online: return "在线"
        case .limited: return "需验证"
        case .offline: return "离线"
        }
    }
}

/// 关注的分类（片商 / 题材）：跨源保存在本机，总览页一键跳转。
struct CatalogFollowedCategory: Codable, Identifiable, Hashable {
    var sourceID: UUID
    var categoryID: String
    var title: String
    var sourceName: String
    var addedAt: Date

    var id: String { "\(sourceID.uuidString)|\(categoryID)" }
}

/// 跨源总榜里的一条：带上所属源，便于封面与跳转。
struct CatalogSpotlightItem: Identifiable, Hashable, Codable {
    var sourceID: UUID
    var sourceName: String
    var item: CatalogItem

    var id: String { "\(sourceID.uuidString)|\(item.id)" }
}

/// 跨源搜索的一组结果。
struct CatalogGlobalResult: Identifiable, Hashable, Codable {
    var sourceID: UUID
    var sourceName: String
    var items: [CatalogItem]

    var id: UUID { sourceID }
}

/// 悬停预览的播放目标：地址 + 站点要求的请求头。
struct CatalogPreviewTarget {
    var url: URL
    var headers: [String: String]
}

/// 更新日历的一条：某条内容第一次在本机出现的时间。
struct CatalogCalendarItem: Codable, Hashable, Identifiable {
    var sourceID: UUID
    var itemID: String
    var title: String
    var coverURL: String
    var remark: String
    var firstSeen: Date

    var id: String { "\(sourceID.uuidString)|\(itemID)" }

    var item: CatalogItem {
        CatalogItem(id: itemID, title: title, coverURL: coverURL,
                    remark: remark, categoryID: nil)
    }
}

/// 自定义片单里的一条。
struct CatalogPlaylistEntry: Codable, Hashable, Identifiable {
    var sourceID: UUID
    var itemID: String
    var title: String
    var coverURL: String
    var remark: String
    var addedAt: Date

    var id: String { "\(sourceID.uuidString)|\(itemID)" }

    var item: CatalogItem {
        CatalogItem(id: itemID, title: title, coverURL: coverURL,
                    remark: remark, categoryID: nil)
    }
}

/// 跨源片单。
struct CatalogPlaylist: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var entries: [CatalogPlaylistEntry]
    var createdAt: Date
    /// 手动指定的封面；为空时用第一条的封面。
    var coverURL: String? = nil
}

/// 聚合片单：输入关键字 + 条件，跨源动态聚合，不占用手动条目。
struct CatalogSmartPlaylist: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// 自然语言查询，例如「中文字幕 校园 90 年代」。
    var query: String
    var createdAt: Date
}

/// 网络资源区的顶层分页。
/// 内置资料库不再作为可见入口：它只作为内部数据，供搜索、片源详情匹配与人物档案使用。
enum CatalogHubTab: String, CaseIterable, Identifiable, Hashable {
    case browse
    case ranking
    case calendar
    case history
    case playlists
    case following

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "资源"
        case .following: return "关注"
        case .ranking: return "榜单"
        case .history: return "足迹"
        case .playlists: return "片单"
        case .calendar: return "日历"
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "square.grid.2x2.fill"
        case .following: return "star.circle.fill"
        case .ranking: return "chart.bar.fill"
        case .history: return "clock.arrow.circlepath"
        case .playlists: return "rectangle.stack.fill"
        case .calendar: return "calendar"
        }
    }
}

/// 片单连播交给查看器的一项：源 + 条目 + 第一集。
struct CatalogPlaylistPlaybackItem {
    var source: CatalogSource
    var item: CatalogItem
    var episode: CatalogEpisode
}

/// 关注的女优 / 片商。
struct CatalogFollowedPerson: Codable, Hashable, Identifiable {
    var name: String
    /// 「女优」或「片商」，只用于文案与分组。
    var role: String
    /// 关注时所在的源：后台查新只打这一个源，避免每次刷新都跨源搜索。
    var sourceID: UUID
    /// 已经看过的条目 id。
    var seenIDs: [String]
    /// 上次检查后新增的数量。
    var newCount: Int
    var addedAt: Date

    var id: String { "\(sourceID.uuidString)|\(role)|\(name)" }
}

/// 详情页里点开的人物 / 片商：叠在详情上显示跨源档案。
/// 放在模型里是为了让窗口工具栏的返回按钮能先退回详情页。
struct CatalogDetailPersonTarget: Identifiable, Equatable {
    var name: String
    var role: String
    var id: String { "\(role)|\(name)" }
}

/// 关注页封面墙的一张：记住来源，恢复站点请求头与图片缓存键。
struct CatalogFollowPoster: Codable, Hashable, Identifiable {
    var sourceID: UUID
    var coverURL: String
    var title: String

    var id: String { "\(sourceID.uuidString)|\(coverURL)" }
}

/// 关注人物的聚合快照：先展示历史，再在后台拉新；新条目排最前并高亮。
struct CatalogFollowAggregate: Codable, Hashable {
    var personKey: String
    var name: String
    var role: String
    var groups: [CatalogGlobalResult]
    /// 最近一次刷新相对上一份快照新增的条目（`sourceID|itemID`）。
    var newIDs: [String]
    var updatedAt: Date
}

/// 人物档案：跨源搜同名作品，按年份倒序排出时间线。
struct CatalogPersonProfile: Identifiable, Hashable {
    var name: String
    var role: String
    /// 关注时记下的源（用于后台查新）。
    var sourceID: UUID
    var groups: [CatalogGlobalResult]
    /// 时间线：所有源的条目合并，按可解析的年份倒序。
    var timeline: [CatalogSpotlightItem]
    /// 关注后第一次打开时发现的新条目。
    var newCount: Int
    /// 本次刷新新进库的条目 id（和 `CatalogSpotlightItem.id` 同格式），用来做「新」高亮。
    var newItemIDs: [String] = []
    var fetchedAt: Date

    var id: String { "\(role)|\(name)" }
    var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

/// 站点不支持服务端排序时的「本页排序」：只对已经加载的这一页生效。
enum CatalogLocalSort: String, CaseIterable, Identifiable, Hashable {
    case title
    case year
    case duration
    case firstSeen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: return "标题"
        case .year: return "年份"
        case .duration: return "时长"
        case .firstSeen: return "首次看到"
        }
    }

    var symbol: String {
        switch self {
        case .title: return "textformat.abc"
        case .year: return "calendar"
        case .duration: return "timer"
        case .firstSeen: return "sparkles"
        }
    }
}

/// 跨源总榜的维度：不依赖站点排序，用聚合数据自己排。
enum CatalogSpotlightMode: String, CaseIterable, Identifiable, Hashable {
    case latest
    case hot
    case todayNew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新"
        case .hot: return "今日热榜"
        case .todayNew: return "今天新增"
        }
    }

    var symbol: String {
        switch self {
        case .latest: return "clock.arrow.circlepath"
        case .hot: return "flame.fill"
        case .todayNew: return "sparkles"
        }
    }

    var subtitle: String {
        switch self {
        case .latest: return "各源第一页轮转混排"
        case .hot: return "各源热榜轮转混排"
        case .todayNew: return "本机今天第一次看到的条目"
        }
    }
}

/// 自然语言搜索的解析结果：把「中文字幕 校园 90 年代」拆成检索词 + 筛选条件。
struct CatalogQueryPlan: Hashable {
    var raw: String
    /// 交给站点搜索的词。
    var keywords: [String]
    var chineseOnly: Bool
    var yearFrom: Int?
    var yearTo: Int?

    var keyword: String { keywords.joined(separator: " ") }
    var isEmpty: Bool { keyword.isEmpty }

    var chips: [String] {
        var result = keywords
        if chineseOnly { result.append("中文字幕") }
        if let from = yearFrom, let to = yearTo {
            result.append(from == to ? "\(from)" : "\(from)–\(to)")
        }
        return result
    }

    /// 结果排序分：命中检索词加分，条件不符扣分。
    func score(_ item: CatalogItem) -> Int {
        let text = item.title + " " + item.remark
        var score = 0
        for keyword in keywords where text.localizedCaseInsensitiveContains(keyword) {
            score += 3
        }
        if chineseOnly {
            let marks = ["中文字幕", "中字", "中文", "字幕"]
            score += marks.contains(where: { text.localizedCaseInsensitiveContains($0) }) ? 4 : -2
        }
        if yearFrom != nil || yearTo != nil {
            if let year = Self.year(in: text) {
                if year >= (yearFrom ?? 0), year <= (yearTo ?? 9999) { score += 5 } else { score -= 1 }
            } else {
                score -= 1
            }
        }
        return score
    }

    /// 从标题里取出四位年份。
    static func year(in text: String) -> Int? {
        let pattern = "(19|20)\\d{2}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return Int(text[range])
    }

    static func parse(_ raw: String) -> CatalogQueryPlan {
        var text = raw.lowercased()
        // 「90 年代」「90s」「90's」先合并成可识别的年份区间。
        let decadePattern = "(\\d{2})\\s*(?:年代|'s|s\\b)"
        if let regex = try? NSRegularExpression(pattern: decadePattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: text),
                      let digitRange = Range(match.range(at: 1), in: text),
                      let decade = Int(text[digitRange]) else { continue }
                let start = decade >= 30 ? 1900 + decade : 2000 + decade
                text.replaceSubrange(range, with: "\(start)年代")
            }
        }

        let separators = CharacterSet(charactersIn: "，,、|/;；:：()（）[]【】\"“”")
        let tokens = text.components(separatedBy: separators)
            .flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }) }
            .map(String.init)

        var keywords: [String] = []
        var chineseOnly = false
        var yearFrom: Int?
        var yearTo: Int?

        for token in tokens {
            if token.contains("字幕") || token == "中字" || token == "中文" {
                chineseOnly = true
                continue
            }
            if token.hasSuffix("年代") {
                if let start = Int(token.dropLast(2)) {
                    let base = start < 100 ? (start >= 30 ? 1900 + start : 2000 + start) : start
                    yearFrom = base
                    yearTo = base + 9
                }
                continue
            }
            if token.count == 4, let year = Int(token), year > 1900, year < 2100 {
                yearFrom = year
                yearTo = year
                continue
            }
            keywords.append(token)
        }

        return CatalogQueryPlan(raw: raw, keywords: keywords, chineseOnly: chineseOnly,
                                yearFrom: yearFrom, yearTo: yearTo)
    }
}
