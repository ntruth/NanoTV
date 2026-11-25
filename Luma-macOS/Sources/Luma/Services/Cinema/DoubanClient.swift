import Foundation

/// 豆瓣影视数据（非官方公开接口）。
///
/// - 搜索走 `j/subject_suggest`，评分与类型走 `j/subject_abstract`。
/// - 豆瓣没有背景图，只提供竖版海报；网格里会以海报铺底。
/// - 接口可能限流：可在设置里填写登录 Cookie，或把接口地址换成镜像。
struct DoubanClient: CinemaMetadataSource {
    let apiBase: String
    let cookie: String

    var provider: CinemaProvider { .douban }

    enum DoubanError: LocalizedError {
        case invalidBase
        case http(Int)
        case blocked

        var errorDescription: String? {
            switch self {
            case .invalidBase: return "豆瓣接口地址无效，请检查设置里的地址"
            case .http(let status): return "豆瓣请求失败（\(status)）"
            case .blocked: return "豆瓣接口拒绝了请求，请稍后再试，或在设置里填写 Cookie / 镜像地址"
            }
        }
    }

    func search(query: String, isTV: Bool, year: Int?) async throws -> [CinemaMatch] {
        var matches = Array(try await suggest(query: query).prefix(8))
        guard !matches.isEmpty else { return [] }
        // 只给最可能命中的一条补评分 / 类型 / 导演，控制请求数量。
        if let index = bestIndex(in: matches, isTV: isTV, year: year),
           let detail = try? await abstract(id: matches[index].id) {
            matches[index].rating = detail.rating
            matches[index].overview = detail.overview
            matches[index].genres = detail.genres
            if let detailTV = detail.isTV { matches[index].isTV = detailTV }
            if matches[index].year == nil { matches[index].year = detail.year }
        }
        return matches
    }

    // MARK: 请求

    private var base: String {
        apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func suggest(query: String) async throws -> [CinemaMatch] {
        let data = try await get(path: "/j/subject_suggest", query: [URLQueryItem(name: "q", value: query)])
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DoubanError.blocked
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let episode = (item["episode"] as? String) ?? ""
            let kind = (item["type"] as? String) ?? ""
            let sub = item["sub_title"] as? String
            return CinemaMatch(id: id,
                               isTV: kind == "tv" || !episode.isEmpty,
                               title: title,
                               originalTitle: (sub?.isEmpty == false && sub != title) ? sub : nil,
                               year: Int((item["year"] as? String) ?? ""),
                               posterURL: posterURL(item["img"] as? String),
                               backdropURL: nil,
                               overview: nil,
                               rating: nil,
                               voteCount: nil,
                               provider: .douban)
        }
    }

    private struct Detail {
        var rating: Double?
        var overview: String?
        var genres: [String] = []
        var isTV: Bool?
        var year: Int?
    }

    private func abstract(id: String) async throws -> Detail {
        let data = try await get(path: "/j/subject_abstract",
                                 query: [URLQueryItem(name: "subject_id", value: id)])
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let subject = object["subject"] as? [String: Any] else {
            throw DoubanError.blocked
        }
        let rate = Double((subject["rate"] as? String) ?? "") ?? 0
        let genres = (subject["types"] as? [String]) ?? []
        var parts: [String] = []
        if !genres.isEmpty {
            parts.append(genres.joined(separator: " / "))
        }
        if let region = subject["region"] as? String, !region.isEmpty {
            parts.append(region)
        }
        if let duration = subject["duration"] as? String, !duration.isEmpty {
            parts.append(duration)
        }
        if let directors = subject["directors"] as? [String], !directors.isEmpty {
            parts.append("导演：" + directors.prefix(2).joined(separator: "、"))
        }
        return Detail(rating: rate > 0 ? rate : nil,
                      overview: parts.isEmpty ? nil : parts.joined(separator: " · "),
                      genres: genres,
                      isTV: subject["is_tv"] as? Bool,
                      year: Int((subject["release_year"] as? String) ?? "")
                          ?? (subject["release_year"] as? NSNumber)?.intValue)
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        guard !base.isEmpty,
              var components = URLComponents(string: base + path) else {
            throw DoubanError.invalidBase
        }
        components.queryItems = query
        guard let url = components.url else { throw DoubanError.invalidBase }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: AppSettings.shared.cinemaRequestTimeout)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(base, forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCookie.isEmpty {
            request.setValue(trimmedCookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 418 { throw DoubanError.blocked }
        guard status == 200 else { throw DoubanError.http(status) }
        return data
    }

    // MARK: 推荐

    /// 豆瓣「喜欢这部的人也喜欢」：先用片名命中条目，再取 rexxar 推荐。
    /// 豆瓣条目没有 TMDB ID，返回项的 `doubanID` 用于点击时打开豆瓣页。
    func recommendations(title: String,
                         originalTitle: String?,
                         year: Int?,
                         isTV: Bool) async throws -> [CinemaRecommendation] {
        var queries: [String] = [title]
        if let originalTitle, !originalTitle.isEmpty, originalTitle != title {
            queries.append(originalTitle)
        }
        for query in queries {
            guard let matches = try? await suggest(query: query), !matches.isEmpty,
                  let index = bestIndex(in: matches, isTV: isTV, year: year) else { continue }
            let pick = matches[index]
            if let items = try? await rexxarRecommendations(id: pick.id, isTV: pick.isTV || isTV),
               !items.isEmpty {
                return items
            }
        }
        return []
    }

    private func rexxarRecommendations(id: String, isTV: Bool) async throws -> [CinemaRecommendation] {
        let path = isTV ? "/rexxar/api/v2/tv/\(id)/recommendations"
                        : "/rexxar/api/v2/movie/\(id)/recommendations"
        let data = try await mobileGet(path: path)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { throw DoubanError.blocked }
        return items.prefix(12).compactMap { item -> CinemaRecommendation? in
            let idValue = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue
            guard let idValue, !idValue.isEmpty,
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let kind: CinemaMediaKind = ((item["type"] as? String) ?? "").contains("tv") ? .tv : .movie
            let pic = (item["pic"] as? [String: Any])?["normal"] as? String
                ?? (item["pic"] as? [String: Any])?["large"] as? String
            let rating = ((item["rating"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue
            let year = Int((item["year"] as? String) ?? "") ?? (item["year"] as? NSNumber)?.intValue
            return CinemaRecommendation(tmdbID: 0,
                                        kind: kind,
                                        title: title,
                                        year: year,
                                        posterURL: posterURL(pic),
                                        rating: rating,
                                        doubanID: idValue)
        }
    }

    /// rexxar 接口固定在 m.douban.com，和搜索用的 apiBase 分开。
    private func mobileGet(path: String) async throws -> Data {
        guard let url = URL(string: "https://m.douban.com" + path) else { throw DoubanError.invalidBase }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: AppSettings.shared.cinemaRequestTimeout)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCookie.isEmpty { request.setValue(trimmedCookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 418 { throw DoubanError.blocked }
        guard status == 200 else { throw DoubanError.http(status) }
        return data
    }

    /// 搜索建议里只给 `s_ratio_poster`（小图），换成 `l_ratio_poster` 更清晰。
    private func posterURL(_ raw: String?) -> String? {
        guard var value = raw, !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "/s_ratio_poster/", with: "/l_ratio_poster/")
        if value.hasPrefix("//") {
            value = "https:" + value
        } else if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return value
    }

    /// 按季集与年份选出最像的一条去补详情。
    private func bestIndex(in matches: [CinemaMatch], isTV: Bool, year: Int?) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, match) in matches.enumerated() {
            var score = 0.0
            if match.isTV == isTV { score += 1 }
            if let year, let matchYear = match.year {
                score += max(0, 3 - Double(abs(year - matchYear)))
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
