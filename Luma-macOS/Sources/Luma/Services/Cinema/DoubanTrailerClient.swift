import Foundation

/// 豆瓣预告片：先用片名找到豆瓣条目，再取 Rexxar 接口里的 mp4 直链。
///
/// TMDB 的 `videos` 只给 YouTube key，App 内没法直接播；豆瓣的 `video_url`
/// 是普通 mp4，可以交给 AVPlayer 在详情页里播放。直链要求带 `Referer`
/// （不带会返回 418），所以每条结果都记着自己的来源页。
enum DoubanTrailerClient {
    struct Trailer: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL
        let coverURL: String?
        let runtime: String?
        /// 播放时随请求一起发送，豆瓣 CDN 用它校验来源。
        let referer: String
        /// 豆瓣标注为「预告片」（而不是花絮 / 片段），排序时优先。
        let isFeature: Bool
    }

    /// 片名 → 豆瓣条目 → 预告片列表；找不到条目或没有预告片时返回空数组。
    /// 长剧在豆瓣可能按季拆成多个条目，所以按匹配度依次试前几个，返回第一个有片源的。
    static func trailers(title: String,
                         originalTitle: String?,
                         year: Int?,
                         isTV: Bool) async -> [Trailer] {
        for subjectID in await subjectIDs(title: title,
                                          originalTitle: originalTitle,
                                          year: year,
                                          isTV: isTV) {
            let list = await trailers(subjectID: subjectID)
            if !list.isEmpty { return list }
        }
        return []
    }

    // MARK: 条目

    private struct SuggestItem {
        let id: String
        let title: String
        let subTitle: String?
        let year: Int?
        let isTV: Bool
    }

    private static func subjectIDs(title: String,
                                   originalTitle: String?,
                                   year: Int?,
                                   isTV: Bool) async -> [String] {
        var pool: [SuggestItem] = []
        var seen = Set<String>()
        for query in queries(title: title, originalTitle: originalTitle) {
            for item in await suggest(query) where seen.insert(item.id).inserted {
                pool.append(item)
            }
        }
        return pool
            .compactMap { item -> (String, Double)? in
                guard let value = score(item, title: title, originalTitle: originalTitle,
                                        year: year, isTV: isTV) else { return nil }
                return (item.id, value)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { $0.0 }
    }

    private static func queries(title: String, originalTitle: String?) -> [String] {
        var result: [String] = []
        for value in [title, originalTitle ?? ""] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// 片名相同优先，其次包含关系；年份越近越好，电影 / 剧集对得上再加分。
    private static func score(_ item: SuggestItem,
                              title: String,
                              originalTitle: String?,
                              year: Int?,
                              isTV: Bool) -> Double? {
        let wanted = [title, originalTitle ?? ""].map(normalize).filter { !$0.isEmpty }
        let offered = [item.title, item.subTitle ?? ""].map(normalize).filter { !$0.isEmpty }
        guard !wanted.isEmpty, !offered.isEmpty else { return nil }

        var score = 0.0
        var matchedName = false
        for name in wanted {
            for candidate in offered {
                if candidate == name {
                    score += 8
                    matchedName = true
                } else if name.count >= 2,
                          candidate.contains(name) || name.contains(candidate) {
                    score += 3
                    matchedName = true
                }
            }
        }
        guard matchedName else { return nil }

        if let year, let itemYear = item.year {
            let gap = abs(year - itemYear)
            score += gap == 0 ? 4 : max(0, 3 - Double(gap) * 0.5)
        }
        score += item.isTV == isTV ? 2 : -2
        return score
    }

    private static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: .current)
        return String(String.UnicodeScalarView(
            folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    // MARK: 请求

    private static func suggest(_ query: String) async -> [SuggestItem] {
        guard var components = URLComponents(string: "https://movie.douban.com/j/subject_suggest") else {
            return []
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let episode = (item["episode"] as? String) ?? ""
            return SuggestItem(id: id,
                               title: title,
                               subTitle: item["sub_title"] as? String,
                               year: Int((item["year"] as? String) ?? ""),
                               isTV: (item["type"] as? String) == "tv" || !episode.isEmpty)
        }
    }

    private static func trailers(subjectID: String) async -> [Trailer] {
        guard let url = URL(string: "https://m.douban.com/rexxar/api/v2/movie/\(subjectID)/trailers") else {
            return []
        }
        // 电影条目和剧集条目共用同一个预告片接口，Referer 用电影路径也能正常返回。
        let referer = "https://m.douban.com/movie/\(subjectID)/"
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let list = object["trailers"] as? [[String: Any]] else {
            return []
        }
        let parsed = list.compactMap { item -> Trailer? in
            guard let raw = item["video_url"] as? String,
                  let videoURL = URL(string: httpsURL(raw)) else { return nil }
            let id = (item["id"] as? String) ?? videoURL.absoluteString
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let runtime = (item["runtime"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Trailer(id: id,
                           title: title?.isEmpty == false ? title! : "预告片",
                           url: videoURL,
                           coverURL: (item["cover_url"] as? String).map(httpsURL),
                           runtime: runtime?.isEmpty == false ? runtime : nil,
                           referer: referer,
                           isFeature: (item["type_name"] as? String) == "预告片")
        }
        // 大片常挂几十条花絮：正式预告排前面，最多留 12 条。
        return Array((parsed.filter(\.isFeature) + parsed.filter { !$0.isFeature }).prefix(12))
    }

    private static func httpsURL(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("http://") { return "https://" + raw.dropFirst("http://".count) }
        return raw
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
