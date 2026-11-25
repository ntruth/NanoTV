import Foundation

/// 解析后的自然语言搜索：场景词 + 时间范围 + 类型/状态限定 + 人物。
struct SearchQuery: Equatable {
    var tokens: [String] = []
    var startDate: Date?
    var endDate: Date?
    var onlyFavorites = false
    var onlyVideos = false
    var onlyPhotos = false
    var onlyScreenshots = false
    var onlyLivePhotos = false
    var onlyEdited = false
    var personIDs: Set<UUID> = []

    var isEmpty: Bool {
        tokens.isEmpty && startDate == nil && endDate == nil
            && !onlyFavorites && !onlyVideos && !onlyPhotos && !onlyScreenshots
            && !onlyLivePhotos && !onlyEdited && personIDs.isEmpty
    }
}

/// 把「去年 海边 狗」「2024年5月 有文字的截图」这类输入拆成可下推的筛选条件。
enum SearchQueryParser {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        let tokens = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        for token in tokens {
            if applyFlag(token, to: &query) { continue }
            if let interval = dateInterval(for: token, now: now, calendar: calendar) {
                merge(interval, into: &query)
                continue
            }
            query.tokens.append(token)
        }
        return query
    }

    // MARK: - 状态与类型

    private static func applyFlag(_ token: String, to query: inout SearchQuery) -> Bool {
        switch token {
        case "收藏", "喜欢", "最爱", "favorite", "favorites":
            query.onlyFavorites = true
        case "视频", "影片", "video", "videos":
            query.onlyVideos = true
        case "照片", "图片", "photo", "photos":
            query.onlyPhotos = true
        case "截图", "截屏", "screenshot", "screenshots":
            query.onlyScreenshots = true
        case "实况", "livephoto", "live":
            query.onlyLivePhotos = true
        case "已编辑", "编辑过", "edited":
            query.onlyEdited = true
        default:
            return false
        }
        return true
    }

    // MARK: - 时间

    private static func merge(_ interval: DateInterval, into query: inout SearchQuery) {
        query.startDate = max(query.startDate ?? interval.start, interval.start)
        query.endDate = min(query.endDate ?? interval.end, interval.end)
    }

    private static func dateInterval(for token: String, now: Date,
                                     calendar: Calendar) -> DateInterval? {
        switch token {
        case "今天", "今日", "today":
            return dayInterval(containing: now, calendar: calendar)
        case "昨天", "昨日", "yesterday":
            return dayInterval(containing: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
                               calendar: calendar)
        case "前天":
            return dayInterval(containing: calendar.date(byAdding: .day, value: -2, to: now) ?? now,
                               calendar: calendar)
        case "本周", "这周", "这星期":
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case "上周", "上星期":
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start) else {
                return nil
            }
            return DateInterval(start: start, end: thisWeek.start)
        case "本月", "这个月":
            return calendar.dateInterval(of: .month, for: now)
        case "上个月", "上月":
            guard let thisMonth = calendar.dateInterval(of: .month, for: now),
                  let start = calendar.date(byAdding: .month, value: -1, to: thisMonth.start) else {
                return nil
            }
            return DateInterval(start: start, end: thisMonth.start)
        case "今年", "本年", "今年内":
            return calendar.dateInterval(of: .year, for: now)
        case "去年":
            guard let thisYear = calendar.dateInterval(of: .year, for: now),
                  let start = calendar.date(byAdding: .year, value: -1, to: thisYear.start) else {
                return nil
            }
            return DateInterval(start: start, end: thisYear.start)
        case "前年":
            guard let thisYear = calendar.dateInterval(of: .year, for: now),
                  let start = calendar.date(byAdding: .year, value: -2, to: thisYear.start) else {
                return nil
            }
            return DateInterval(start: start, end: calendar.date(byAdding: .year, value: -1, to: thisYear.start) ?? start)
        default:
            break
        }

        // 2024 / 2024年
        if let groups = match(#"^(\d{4})年?$"#, token), groups.count == 1 {
            return yearInterval(groups[0], calendar: calendar)
        }
        // 2024年5月 / 2024-05 / 2024/5
        if let groups = match(#"^(\d{4})[年./-](\d{1,2})月?$"#, token), groups.count == 2 {
            return monthInterval(year: groups[0], month: groups[1], now: now, calendar: calendar)
        }
        // 2024年5月20日 / 2024-05-20
        if let groups = match(#"^(\d{4})[年./-](\d{1,2})[月./-](\d{1,2})日?$"#, token), groups.count == 3 {
            return dayInterval(year: groups[0], month: groups[1], day: groups[2],
                               now: now, calendar: calendar)
        }
        // 5月
        if let groups = match(#"^(\d{1,2})月$"#, token), groups.count == 1 {
            return monthInterval(year: nil, month: groups[0], now: now, calendar: calendar)
        }
        // 5月20日
        if let groups = match(#"^(\d{1,2})月(\d{1,2})日?$"#, token), groups.count == 2 {
            return dayInterval(year: nil, month: groups[0], day: groups[1],
                               now: now, calendar: calendar)
        }
        return nil
    }

    private static func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    private static func yearInterval(_ year: Int, calendar: Calendar) -> DateInterval? {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func monthInterval(year: Int?, month: Int, now: Date,
                                      calendar: Calendar) -> DateInterval? {
        guard (1...12).contains(month) else { return nil }
        var components = DateComponents()
        components.year = year ?? calendar.component(.year, from: now)
        components.month = month
        components.day = 1
        guard var start = calendar.date(from: components) else { return nil }
        // 只写月份时，若该月还没到，则理解为去年那个月。
        if year == nil, start > now {
            components.year = (components.year ?? 0) - 1
            start = calendar.date(from: components) ?? start
        }
        guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func dayInterval(year: Int?, month: Int, day: Int, now: Date,
                                    calendar: Calendar) -> DateInterval? {
        var components = DateComponents()
        components.year = year ?? calendar.component(.year, from: now)
        components.month = month
        components.day = day
        guard var start = calendar.date(from: components) else { return nil }
        if year == nil, start > now {
            components.year = (components.year ?? 0) - 1
            start = calendar.date(from: components) ?? start
        }
        return dayInterval(containing: start, calendar: calendar)
    }

    private static func match(_ pattern: String, _ text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
    }
}
