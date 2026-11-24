import Foundation
import NanoCore
import NanoVFS

/// 从复杂文件名中解析出的干净刮削线索与媒体技术规格
public struct ParsedMediaFilename: Sendable {
    public let cleanTitle: String
    public let year: Int?
    public let season: Int?
    public let episode: Int?
    public let spec: VideoTechnicalSpec
}

/// 智能文件名清洗器 + 本地 NFO 解析 + TMDB 刮削服务
public struct MediaScraperEngine: Sendable {
    public let tmdbAPIKey: String
    public let language: String

    public init(tmdbAPIKey: String = "", language: String = "zh-CN") {
        self.tmdbAPIKey = tmdbAPIKey
        self.language = language
    }

    /// 正则提取片名、年份、S01E02 季集以及 4K/DV/HDR/帧率标签
    public static func parseFilename(_ rawName: String) -> ParsedMediaFilename {
        let base = (rawName as NSString).deletingPathExtension
        let upper = base.uppercased()

        // 1. 分辨率识别
        let resolution: String
        if upper.contains("2160P") || upper.contains("4K") || upper.contains("UHD") {
            resolution = "4K"
        } else if upper.contains("1080P") || upper.contains("FHD") {
            resolution = "1080P"
        } else if upper.contains("720P") {
            resolution = "720P"
        } else {
            resolution = "1080P"
        }

        // 2. 动态范围识别
        let dynamicRange: String
        if upper.contains("DV") || upper.contains("DOVI") || upper.contains("DOLBY.VISION") {
            dynamicRange = "Dolby Vision"
        } else if upper.contains("HDR10+") {
            dynamicRange = "HDR10+"
        } else if upper.contains("HDR") {
            dynamicRange = "HDR"
        } else {
            dynamicRange = "SDR"
        }

        // 3. 帧率与音轨标签识别
        let frameRate = (upper.contains("60FPS") || upper.contains("60HZ")) ? "60 fps" : "24 fps"
        let audioCodec = upper.contains("ATMOS") ? "Dolby Atmos" : (upper.contains("DTS") ? "DTS-HD" : "AAC")

        // 4. SxxExx 季集识别（支持 S01E02 / EP02 / 第02集）
        var season: Int? = nil
        var episode: Int? = nil
        if let seMatch = firstMatch(pattern: "[Ss](\\d{1,2})[Ee](\\d{1,3})", in: base),
           seMatch.count >= 3 {
            season = Int(seMatch[1])
            episode = Int(seMatch[2])
        } else if let epMatch = firstMatch(pattern: "(?:EP|第)(\\d{1,3})集?", in: upper),
                  epMatch.count >= 2 {
            season = 1
            episode = Int(epMatch[1])
        }

        // 5. 年份识别 (1950 ~ 2039)
        var year: Int? = nil
        if let yrMatch = firstMatch(pattern: "(?:^|[.\\s\\(\\[])((?:19|20)\\d{2})(?:$|[.\\s\\)\\]])", in: base),
           yrMatch.count >= 2 {
            year = Int(yrMatch[1])
        }

        // 6. 清洗出纯净片名：剔除方括号广告前缀，截断至季集或年份标记前
        var working = base.replacingOccurrences(of: "^\\[[^\\]]+\\]", with: "", options: .regularExpression)
        let cutPattern = "(?:[.\\s_]+)(?:[Ss]\\d{1,2}[Ee]\\d{1,3}|(?:19|20)\\d{2}|2160[pP]|1080[pP]|4[kK]|WEB-DL|BluRay|REMUX).*$"
        working = working.replacingOccurrences(of: cutPattern, with: "", options: .regularExpression)
        working = working.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let cleanTitle = working.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedMediaFilename(
            cleanTitle: cleanTitle.isEmpty ? base : cleanTitle,
            year: year,
            season: season,
            episode: episode,
            spec: VideoTechnicalSpec(
                resolution: resolution,
                dynamicRange: dynamicRange,
                frameRate: frameRate,
                audioCodec: audioCodec
            )
        )
    }

    /// 解析本地 Kodi / TinyMediaManager 标准 `.nfo` XML 内容
    public static func parseLocalNFO(_ xmlContent: String, fallbackSpec: VideoTechnicalSpec = VideoTechnicalSpec()) -> MediaItem? {
        func extractTag(_ tag: String) -> String? {
            guard let m = firstMatch(pattern: "<\(tag)>([\\s\\S]*?)</\(tag)>", in: xmlContent), m.count >= 2 else {
                return nil
            }
            return m[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let title = extractTag("title"), !title.isEmpty else { return nil }
        let originalTitle = extractTag("originaltitle")
        let plot = extractTag("plot") ?? extractTag("outline") ?? ""
        let yearInt = extractTag("year").flatMap(Int.init)
        let premiered = extractTag("premiered") ?? extractTag("releasedate") ?? ""
        let ratingDouble = extractTag("rating").flatMap(Double.init) ?? 0.0
        let tmdbID = extractTag("tmdbid").flatMap(Int.init)
        let studio = extractTag("studio") ?? ""
        let isTV = xmlContent.contains("<tvshow>") || xmlContent.contains("<episodedetails>")

        return MediaItem(
            tmdbID: tmdbID,
            kind: isTV ? .tvSeries : .movie,
            title: title,
            originalTitle: originalTitle,
            releaseDate: premiered,
            year: yearInt,
            rating: ratingDouble,
            overview: plot,
            posterURL: extractTag("thumb"),
            networkOrStudio: studio,
            spec: fallbackSpec
        )
    }

    /// 通过 TMDB API 在线搜索匹配影视档案
    public func searchTMDB(query: String, year: Int? = nil) async throws -> [MediaItem] {
        guard !tmdbAPIKey.isEmpty else { return [] }
        var comps = URLComponents(string: "https://api.themoviedb.org/3/search/multi")!
        var items = [
            URLQueryItem(name: "api_key", value: tmdbAPIKey),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "query", value: query)
        ]
        if let year {
            items.append(URLQueryItem(name: "year", value: String(year)))
        }
        comps.queryItems = items

        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        let imageBase = "https://image.tmdb.org/t/p/w780"
        return results.compactMap { row in
            let mediaType = (row["media_type"] as? String) ?? "movie"
            guard mediaType == "movie" || mediaType == "tv" else { return nil }
            let idNum = row["id"] as? Int
            let title = (row["title"] as? String) ?? (row["name"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            let origTitle = (row["original_title"] as? String) ?? (row["original_name"] as? String)
            let overview = (row["overview"] as? String) ?? ""
            let dateStr = (row["release_date"] as? String) ?? (row["first_air_date"] as? String) ?? ""
            let vote = (row["vote_average"] as? Double) ?? 0.0
            let voteCnt = (row["vote_count"] as? Int) ?? 0
            let posterPath = row["poster_path"] as? String
            let backdropPath = row["backdrop_path"] as? String

            return MediaItem(
                tmdbID: idNum,
                kind: mediaType == "tv" ? .tvSeries : .movie,
                title: title,
                originalTitle: origTitle,
                releaseDate: dateStr,
                year: Int(dateStr.prefix(4)),
                rating: (vote * 10).rounded() / 10,
                voteCount: voteCnt,
                overview: overview,
                posterURL: posterPath.map { "\(imageBase)\($0)" },
                backdropURL: backdropPath.map { "https://image.tmdb.org/t/p/w1280\($0)" }
            )
        }
    }

    /// 拉取 TMDB 完整演职员头像、类型与季集规格详情
    public func fetchTMDBRichDetail(tmdbID: Int, kind: MediaKind, baseSpec: VideoTechnicalSpec = VideoTechnicalSpec()) async throws -> MediaItem? {
        guard !tmdbAPIKey.isEmpty else { return nil }
        let endpointType = (kind == .tvSeries) ? "tv" : "movie"
        var comps = URLComponents(string: "https://api.themoviedb.org/3/\(endpointType)/\(tmdbID)")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: tmdbAPIKey),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: "credits")
        ]

        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let title = (json["title"] as? String) ?? (json["name"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let dateStr = (json["release_date"] as? String) ?? (json["first_air_date"] as? String) ?? ""
        let vote = (json["vote_average"] as? Double) ?? 0.0
        let voteCnt = (json["vote_count"] as? Int) ?? 0
        let overview = (json["overview"] as? String) ?? ""
        let posterPath = json["poster_path"] as? String
        let backdropPath = json["backdrop_path"] as? String
        let genres = (json["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let seasons = (json["number_of_seasons"] as? Int) ?? 1
        let epCount = (json["number_of_episodes"] as? Int) ?? 1
        let statusStr = (json["status"] as? String) ?? "Ended"

        var castList: [CastMember] = []
        if let credits = json["credits"] as? [String: Any],
           let rawCast = credits["cast"] as? [[String: Any]] {
            for person in rawCast.prefix(10) {
                let pName = (person["name"] as? String) ?? ""
                let role = (person["character"] as? String) ?? ""
                let profile = person["profile_path"] as? String
                if !pName.isEmpty {
                    castList.append(
                        CastMember(
                            name: pName,
                            character: role,
                            avatarURL: profile.map { "https://image.tmdb.org/t/p/w300\($0)" }
                        )
                    )
                }
            }
        }

        return MediaItem(
            tmdbID: tmdbID,
            kind: kind,
            title: title,
            releaseDate: dateStr,
            year: Int(dateStr.prefix(4)),
            rating: (vote * 10).rounded() / 10,
            voteCount: voteCnt,
            overview: overview,
            posterURL: posterPath.map { "https://image.tmdb.org/t/p/w780\($0)" },
            backdropURL: backdropPath.map { "https://image.tmdb.org/t/p/w1280\($0)" },
            genres: genres,
            seasonCount: seasons,
            totalEpisodes: epCount,
            isCompleted: (statusStr == "Ended" || statusStr == "Released"),
            cast: castList,
            spec: baseSpec
        )
    }

    /// 批量扫描目录中的视频节点，智能按片名聚类分集并匹配 TMDB 元数据
    public func batchScrapeDirectoryNodes(
        nodes: [VFSNode],
        sourceID: UUID,
        isPrivateSource: Bool = false
    ) async -> [(item: MediaItem, episodes: [MediaEpisode])] {
        let videoNodes = nodes.filter { $0.kind == .video }
        guard !videoNodes.isEmpty else { return [] }

        // 按清洗后的干净片名分组（自动把同一部剧的 S01E01 ~ S01E40 聚合到一张海报下）
        var groupedByTitle: [String: [(node: VFSNode, parsed: ParsedMediaFilename)]] = [:]
        for vNode in videoNodes {
            let parsed = Self.parseFilename(vNode.name)
            groupedByTitle[parsed.cleanTitle, default: []].append((vNode, parsed))
        }

        var output: [(MediaItem, [MediaEpisode])] = []
        for (cleanTitle, entries) in groupedByTitle {
            guard let firstParsed = entries.first?.parsed else { continue }
            let inferredKind: MediaKind = (entries.count > 1 || firstParsed.episode != nil) ? .tvSeries : .movie

            var matchedItem: MediaItem?
            if !tmdbAPIKey.isEmpty,
               let candidates = try? await searchTMDB(query: cleanTitle, year: firstParsed.year),
               let best = candidates.first {
                if let tmdbID = best.tmdbID,
                   let rich = try? await fetchTMDBRichDetail(tmdbID: tmdbID, kind: best.kind, baseSpec: firstParsed.spec) {
                    matchedItem = rich
                } else {
                    matchedItem = best
                }
            }

            var finalItem = matchedItem ?? MediaItem(
                kind: inferredKind,
                title: cleanTitle,
                releaseDate: firstParsed.year.map { "\($0)" } ?? "未知日期",
                year: firstParsed.year,
                rating: 0.0,
                overview: "来自网络存储自动扫描入库（共 \(entries.count) 个媒体文件），点击顶部「刮削」按钮可手动关联网上影视档案。",
                genres: [inferredKind == .tvSeries ? "剧集" : "电影"],
                totalEpisodes: entries.count,
                spec: firstParsed.spec
            )
            finalItem.isPrivate = isPrivateSource

            let sortedEntries = entries.sorted {
                ($0.parsed.episode ?? 0) < ($1.parsed.episode ?? 0)
            }
            let builtEpisodes: [MediaEpisode] = sortedEntries.enumerated().map { idx, pair in
                let sNum = pair.parsed.season ?? 1
                let eNum = pair.parsed.episode ?? (idx + 1)
                return MediaEpisode(
                    mediaID: finalItem.id,
                    sourceID: sourceID,
                    seasonNumber: sNum,
                    episodeNumber: eNum,
                    title: pair.node.name,
                    overview: pair.node.path,
                    vfsPath: pair.node.path
                )
            }
            output.append((finalItem, builtEpisodes))
        }
        return output
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        var groups: [String] = []
        for idx in 0..<match.numberOfRanges {
            let range = match.range(at: idx)
            if let swiftRange = Range(range, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
