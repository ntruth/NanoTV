import Foundation

/// TMDB 官方 API：v3 API Key（query 参数）或 v4 Read Access Token（Bearer 头）。
struct TMDBClient: CinemaMetadataSource {
    let apiKey: String
    let apiBase: String
    let imageBase: String
    let language: String

    var provider: CinemaProvider { .tmdb }

    enum TMDBError: LocalizedError {
        case missingKey
        case invalidBase
        case http(Int, String)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingKey: return "请先在设置 › 影院里填写 TMDB API Key"
            case .invalidBase: return "TMDB 接口地址无效，请检查设置里的地址"
            case .http(let status, let message): return "TMDB 请求失败（\(status)）：\(message)"
            case .decoding: return "TMDB 返回内容无法解析"
            }
        }
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usesBearer: Bool { trimmedKey.hasPrefix("eyJ") }

    func search(query: String, isTV: Bool, year: Int?) async throws -> [CinemaMatch] {
        let path = isTV ? "/search/tv" : "/search/movie"
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: "1")
        ]
        if let year {
            items.append(URLQueryItem(name: isTV ? "first_air_date_year" : "year", value: String(year)))
        }
        let object = try await request(path: path, items: items)
        guard let results = object["results"] as? [[String: Any]] else {
            throw TMDBError.decoding
        }
        return results.compactMap { parse($0, isTV: isTV) }
    }

    /// 详情：合集、演职员、预告片与分级一次取回。
    func details(id: Int, isTV: Bool) async throws -> CinemaDetails? {
        let path = isTV ? "/tv/\(id)" : "/movie/\(id)"
        let append = isTV
            ? "credits,videos,content_ratings"
            : "credits,videos,release_dates"
        let object = try await request(path: path, items: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: append)
        ])
        guard !object.isEmpty else { return nil }

        var details = CinemaDetails()

        if let collection = object["belongs_to_collection"] as? [String: Any] {
            details.collectionID = (collection["id"] as? NSNumber)?.intValue
            details.collectionName = collection["name"] as? String
        }

        if let credits = object["credits"] as? [String: Any] {
            if let cast = credits["cast"] as? [[String: Any]] {
                details.cast = cast.prefix(16).compactMap { item in
                    guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                    return CinemaCastMember(name: name,
                                            character: item["character"] as? String,
                                            profileURL: imageURL(path: item["profile_path"] as? String,
                                                                 size: "w185"),
                                            tmdbID: (item["id"] as? NSNumber)?.intValue)
                }
            }
            if let crew = credits["crew"] as? [[String: Any]] {
                details.directors = crew.compactMap { item in
                    guard (item["job"] as? String) == "Director",
                          let name = item["name"] as? String else { return nil }
                    return name
                }
            }
        }
        // 剧集没有导演字段，用主创补位。
        if details.directors.isEmpty, let creators = object["created_by"] as? [[String: Any]] {
            details.directors = creators.compactMap { $0["name"] as? String }
        }

        if let videos = object["videos"] as? [String: Any],
           let results = videos["results"] as? [[String: Any]] {
            let trailers = results.filter {
                ($0["site"] as? String)?.lowercased() == "youtube"
            }
            let trailer = trailers.first { ($0["type"] as? String) == "Trailer" }
                ?? trailers.first { ($0["type"] as? String) == "Teaser" }
                ?? trailers.first
            details.trailerKey = trailer?["key"] as? String
        }

        details.certification = parseCertification(object, isTV: isTV)

        let overview = (object["overview"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        details.overview = (overview?.isEmpty ?? true) ? nil : overview
        details.rating = (object["vote_average"] as? NSNumber)?.doubleValue
        if let genres = object["genres"] as? [[String: Any]] {
            details.genres = genres.compactMap { $0["name"] as? String }
        }

        let tagline = (object["tagline"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        details.tagline = (tagline?.isEmpty ?? true) ? nil : tagline
        details.status = object["status"] as? String
        details.originalLanguage = object["original_language"] as? String
        details.voteCount = (object["vote_count"] as? NSNumber)?.intValue
        if let countries = object["production_countries"] as? [[String: Any]] {
            details.countries = countries.compactMap { $0["name"] as? String }
        }
        if let companies = object["production_companies"] as? [[String: Any]] {
            details.companies = Array(companies.compactMap { $0["name"] as? String }.prefix(6))
        }
        if isTV {
            if let runtimes = object["episode_run_time"] as? [NSNumber] {
                details.runtime = runtimes.first?.intValue
            }
            details.seasonCount = (object["number_of_seasons"] as? NSNumber)?.intValue
            details.episodeCount = (object["number_of_episodes"] as? NSNumber)?.intValue
            details.releaseDate = object["first_air_date"] as? String
            if let networks = object["networks"] as? [[String: Any]] {
                details.networks = networks.compactMap { $0["name"] as? String }
            }
        } else {
            details.runtime = (object["runtime"] as? NSNumber)?.intValue
            details.releaseDate = object["release_date"] as? String
            details.budget = (object["budget"] as? NSNumber)?.int64Value
            details.revenue = (object["revenue"] as? NSNumber)?.int64Value
        }
        return details
    }

    /// 电影看 release_dates，剧集看 content_ratings；优先美国，没有就取第一条非空。
    private func parseCertification(_ object: [String: Any], isTV: Bool) -> String? {
        if isTV,
           let ratings = (object["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]] {
            let pick = ratings.first { ($0["iso_3166_1"] as? String) == "US" }
                ?? ratings.first { !(($0["rating"] as? String) ?? "").isEmpty }
            return (pick?["rating"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let groups = (object["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] else {
            return nil
        }
        func certification(in group: [String: Any]) -> String? {
            let dates = group["release_dates"] as? [[String: Any]] ?? []
            for date in dates {
                if let value = date["certification"] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        if let us = groups.first(where: { ($0["iso_3166_1"] as? String) == "US" }),
           let value = certification(in: us) {
            return value
        }
        for group in groups {
            if let value = certification(in: group) { return value }
        }
        return nil
    }

    /// IMDb ID：TheIntroDB 的片头片尾分段只按 IMDb 索引，用本片 TMDB ID 换一次。
    func externalImdbID(id: Int, isTV: Bool) async throws -> String? {
        let path = isTV ? "/tv/\(id)/external_ids" : "/movie/\(id)/external_ids"
        let object = try await request(path: path, items: [])
        let value = (object["imdb_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 某一季的分集信息：标题、简介与剧照，用于剧集详情展示每集概要。
    func seasonDetails(tvID: Int, season: Int) async throws -> [Int: CinemaEpisodeInfo] {
        let object = try await request(path: "/tv/\(tvID)/season/\(season)",
                                       items: [URLQueryItem(name: "language", value: language)])
        guard let episodes = object["episodes"] as? [[String: Any]] else {
            throw TMDBError.decoding
        }
        var result: [Int: CinemaEpisodeInfo] = [:]
        for item in episodes {
            guard let number = (item["episode_number"] as? NSNumber)?.intValue else { continue }
            let title = (item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let overview = (item["overview"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result[number] = CinemaEpisodeInfo(
                title: title,
                overview: (overview?.isEmpty ?? true) ? nil : overview,
                stillURL: imageURL(path: item["still_path"] as? String, size: "w780")
            )
        }
        return result
    }

    /// 人物页：简介、出生信息与全部作品（combined_credits）。
    func person(id: Int) async throws -> CinemaPersonProfile? {
        let object = try await request(path: "/person/\(id)", items: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: "combined_credits")
        ])
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        var profile = CinemaPersonProfile(
            name: name,
            biography: {
                let raw = (object["biography"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (raw?.isEmpty ?? true) ? nil : raw
            }(),
            birthday: object["birthday"] as? String,
            placeOfBirth: object["place_of_birth"] as? String,
            profileURL: imageURL(path: object["profile_path"] as? String, size: "w300"),
            department: object["known_for_department"] as? String
        )

        var credits: [CinemaPersonCredit] = []
        func append(_ item: [String: Any], isTV: Bool, job: String? = nil) {
            guard let id = (item["id"] as? NSNumber)?.intValue else { return }
            let title = (isTV ? item["name"] as? String : item["title"] as? String) ?? ""
            guard !title.isEmpty else { return }
            let date = (isTV ? item["first_air_date"] as? String : item["release_date"] as? String) ?? ""
            credits.append(CinemaPersonCredit(
                tmdbID: id,
                isTV: isTV,
                title: title,
                year: Int(date.prefix(4)),
                posterURL: imageURL(path: item["poster_path"] as? String, size: "w342"),
                character: item["character"] as? String,
                job: job
            ))
        }

        if let combined = object["combined_credits"] as? [String: Any] {
            for item in (combined["cast"] as? [[String: Any]] ?? []) {
                append(item, isTV: (item["media_type"] as? String) == "tv")
            }
            for item in (combined["crew"] as? [[String: Any]] ?? [])
            where (item["job"] as? String) == "Director" {
                append(item, isTV: (item["media_type"] as? String) == "tv", job: "导演")
            }
        }

        // 同一作品既演又导时只保留一条；按年份从新到旧。
        var seen = Set<String>()
        profile.credits = credits
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) > ($1.year ?? 0) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        return profile
    }

    /// 合集详情：简介 + 全部影片（未入库的只用于提示，不生成条目）。
    func collection(id: Int) async throws -> CinemaCollectionInfo? {
        let object = try await request(path: "/collection/\(id)",
                                       items: [URLQueryItem(name: "language", value: language)])
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        let overview = (object["overview"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = (object["parts"] as? [[String: Any]] ?? []).compactMap { item -> CinemaCollectionPart? in
            guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
            let title = (item["title"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            let date = (item["release_date"] as? String) ?? ""
            return CinemaCollectionPart(tmdbID: id, title: title, year: Int(date.prefix(4)))
        }
        return CinemaCollectionInfo(id: id,
                                    name: name,
                                    overview: (overview?.isEmpty ?? true) ? nil : overview,
                                    parts: parts)
    }

    /// 相似推荐：TMDB 的 recommendations，用同一套条目解析，最多取 20 条。
    func recommendations(id: Int, isTV: Bool) async throws -> [CinemaRecommendation] {
        let path = isTV ? "/tv/\(id)/recommendations" : "/movie/\(id)/recommendations"
        let object = try await request(path: path, items: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "page", value: "1")
        ])
        let results = object["results"] as? [[String: Any]] ?? []
        return results.prefix(20).compactMap { item in
            guard let match = parse(item, isTV: isTV), let tmdbID = Int(match.id) else { return nil }
            return CinemaRecommendation(tmdbID: tmdbID,
                                        kind: isTV ? .tv : .movie,
                                        title: match.title,
                                        year: match.year,
                                        posterURL: match.posterURL,
                                        rating: match.rating)
        }
    }

    /// 按姓名找人物 ID：导演只存了名字，用它补出 ID 再拉作品。
    func searchPersonID(name: String) async throws -> Int? {
        let object = try await request(path: "/search/person", items: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "query", value: name),
            URLQueryItem(name: "page", value: "1")
        ])
        let results = object["results"] as? [[String: Any]] ?? []
        return results.first.flatMap { ($0["id"] as? NSNumber)?.intValue }
    }

    /// 同系列：合集里除当前这部以外的其它影片（带海报）。
    func collectionRecommendations(id: Int, excluding tmdbID: Int) async throws -> [CinemaRecommendation] {
        let object = try await request(path: "/collection/\(id)", items: [
            URLQueryItem(name: "language", value: language)
        ])
        let parts = object["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { item -> CinemaRecommendation? in
            guard let partID = (item["id"] as? NSNumber)?.intValue, partID != tmdbID,
                  let title = item["title"] as? String, !title.isEmpty else { return nil }
            let date = (item["release_date"] as? String) ?? ""
            return CinemaRecommendation(tmdbID: partID,
                                        kind: .movie,
                                        title: title,
                                        year: Int(date.prefix(4)),
                                        posterURL: imageURL(path: item["poster_path"] as? String,
                                                            size: "w342"),
                                        rating: (item["vote_average"] as? NSNumber)?.doubleValue)
        }
    }

    /// 海报 / 背景候选：中文优先、其次无语言，再按社区评分排序。
    func artworkCandidates(id: Int, isTV: Bool) async throws
        -> (posters: [CinemaArtworkCandidate], backdrops: [CinemaArtworkCandidate]) {
        let path = isTV ? "/tv/\(id)/images" : "/movie/\(id)/images"
        let object = try await request(path: path, items: [
            URLQueryItem(name: "include_image_language", value: "zh,en,null")
        ])

        func parse(_ key: String, size: String) -> [CinemaArtworkCandidate] {
            let items = object[key] as? [[String: Any]] ?? []
            return items.compactMap { item in
                guard let path = item["file_path"] as? String,
                      let url = imageURL(path: path, size: size) else { return nil }
                return CinemaArtworkCandidate(url: url,
                                              width: (item["width"] as? NSNumber)?.intValue ?? 0,
                                              height: (item["height"] as? NSNumber)?.intValue ?? 0,
                                              language: item["iso_639_1"] as? String,
                                              rating: (item["vote_average"] as? NSNumber)?.doubleValue)
            }
            .sorted { lhs, rhs in
                if lhs.languageRank != rhs.languageRank { return lhs.languageRank < rhs.languageRank }
                return (lhs.rating ?? 0) > (rhs.rating ?? 0)
            }
        }

        return (parse("posters", size: "w500"), parse("backdrops", size: "w1280"))
    }

    /// 统一构造请求并返回 JSON 对象。
    private func request(path: String, items: [URLQueryItem]) async throws -> [String: Any] {
        guard !trimmedKey.isEmpty else { throw TMDBError.missingKey }
        let base = apiBase.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + path) else {
            throw TMDBError.invalidBase
        }
        var queryItems = items
        if !usesBearer {
            queryItems.append(URLQueryItem(name: "api_key", value: trimmedKey))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw TMDBError.invalidBase }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: AppSettings.shared.cinemaRequestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearer {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (object["status_message"] as? String) ?? "HTTP \(status)"
            throw TMDBError.http(status, message)
        }
        return object
    }

    func imageURL(path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let base = imageBase.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return "\(base)/\(size)\(path)"
    }

    private func parse(_ item: [String: Any], isTV: Bool) -> CinemaMatch? {
        guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
        let title = (isTV ? item["name"] as? String : item["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let original = (isTV ? item["original_name"] as? String : item["original_title"] as? String)
        let date = (isTV ? item["first_air_date"] as? String : item["release_date"] as? String) ?? ""
        let year = Int(date.prefix(4))
        let genreIDs = (item["genre_ids"] as? [NSNumber])?.map { $0.intValue } ?? []
        var seenGenres = Set<String>()
        let genres = genreIDs.compactMap { Self.genreNames[$0] }.filter { seenGenres.insert($0).inserted }
        return CinemaMatch(id: String(id),
                           isTV: isTV,
                           title: title,
                           originalTitle: original,
                           year: year,
                           posterURL: imageURL(path: item["poster_path"] as? String, size: "w500"),
                           backdropURL: imageURL(path: item["backdrop_path"] as? String, size: "w780"),
                           overview: item["overview"] as? String,
                           rating: (item["vote_average"] as? NSNumber)?.doubleValue,
                           voteCount: (item["vote_count"] as? NSNumber)?.intValue,
                           genres: genres,
                           provider: .tmdb)
    }

    /// 搜索结果只给 genre_ids，这里换成中文类型名，和豆瓣的 types 对齐。
    private static let genreNames: [Int: String] = [
        12: "冒险", 14: "奇幻", 16: "动画", 18: "剧情", 27: "恐怖", 28: "动作",
        35: "喜剧", 36: "历史", 37: "西部", 53: "惊悚", 80: "犯罪", 99: "纪录",
        878: "科幻", 9648: "悬疑", 10402: "音乐", 10749: "爱情", 10751: "家庭",
        10752: "战争", 10770: "电视电影", 10759: "动作冒险", 10762: "儿童",
        10763: "新闻", 10764: "真人秀", 10765: "科幻奇幻", 10766: "肥皂剧",
        10767: "脱口秀", 10768: "战争政治"
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
