import Foundation

/// 文件名 / 文件夹名解析 + TMDB、豆瓣匹配。
///
/// 命名规则对齐 Plex / Jellyfin / Emby 的通行约定：
/// - 剧集：`S01E02`、`1x02`、`第 2 集`、`EP02`、纯数字文件名；
/// - 电影：`片名 (年份)`，发行标签（分辨率 / 编码 / 字幕 / 压制组）全部剥离；
/// - 文件夹参与识别：`剧名 (2024)/Season 01/xxx.mkv` 里的目录名用来补全剧名、季与年份。
enum CinemaScraper {
    // MARK: - 解析

    static func parse(filename: String, folderHint: String? = nil) -> CinemaParsedName {
        let base = (filename as NSString).deletingPathExtension
        let text = normalizeWidth(base)
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")

        let folder = parseFolder(folderHint)
        var year = folder.year
        var season: Int?
        var episode: Int?
        var episodeEnd: Int?
        var cutIndex = text.endIndex

        // 剧集：S01E02 / S01E02-E03 / S01E02E03 / S01E02-03
        if let match = firstMatch(#"(?i)S(\d{1,2})[\s\-.]*E(?:P)?(\d{1,4})(?:[\s\-.]*E(?:P)?(\d{1,4})|-(\d{1,4}))?"#,
                                  in: text) {
            season = int(match.groups, 0)
            episode = int(match.groups, 1)
            episodeEnd = int(match.groups, 2) ?? int(match.groups, 3)
            cutIndex = match.range.lowerBound
        } else if let match = firstMatch(#"(?i)(?:^|[\s\-.])(\d{1,2})x(\d{2,4})(?:\b|$)"#, in: text) {
            // 1x02
            season = int(match.groups, 0)
            episode = int(match.groups, 1)
            cutIndex = match.range.lowerBound
        } else if let match = firstMatch(#"(?i)(?:^|[\s\-.])(?:E|EP)(\d{1,4})(?:[\s\-.]*E(?:P)?(\d{1,4})|-(\d{1,4}))?(?:\b|$)"#,
                                          in: text) {
            // EP02 / E02-E03 / E02-03
            episode = int(match.groups, 0)
            episodeEnd = int(match.groups, 1) ?? int(match.groups, 2)
            cutIndex = match.range.lowerBound
        } else if let match = firstMatch(#"第\s*(\d{1,4})\s*[集话話]"#, in: text) {
            episode = int(match.groups, 0)
            cutIndex = match.range.lowerBound
        }

        // 只有季标记：S01 / Season 1 / 第一季
        if season == nil, let match = firstMatch(#"(?i)(?:^|[\s\-.])(?:S|SEASON|SERIES)[\s\-.]*(\d{1,2})(?:\b|$)"#,
                                                  in: text) {
            season = int(match.groups, 0)
            cutIndex = min(cutIndex, match.range.lowerBound)
        }
        if season == nil, let match = firstMatch(#"第\s*(\d{1,2})\s*季"#, in: text) {
            season = int(match.groups, 0)
            cutIndex = min(cutIndex, match.range.lowerBound)
        }
        // 文件名没写季时，用目录里的 `Season 02` / `第二季` 补上。
        if season == nil { season = folder.season }

        // 纯数字文件名：`03.mkv`、`13 4K.mkv`；只有确认在剧集目录里才当作集号。
        if episode == nil {
            let stripped = text
                .replacingOccurrences(of: #"(?i)\b(4k|8k|2160p|1080p|720p|480p|hdr10\+?|hdr|dv|remux|web[- .]?dl|webrip|bluray|x265|x264|h[ .]?265|h[ .]?264|hevc|avc|aac|atmos|高码版?)\b"#,
                                      with: " ",
                                      options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if stripped.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil,
               season != nil || folder.isSeriesFolder {
                episode = Int(stripped)
                cutIndex = text.startIndex
            }
        }

        var titlePart = String(text[text.startIndex..<cutIndex])

        // 年份：标题里最后一个 19xx / 20xx 优先，其次目录名。
        if let match = lastMatch(#"(?:19|20)\d{2}"#, in: titlePart) {
            year = Int(titlePart[match.range])
            titlePart.removeSubrange(match.range)
        } else if year == nil, let match = lastMatch(#"(?:19|20)\d{2}"#, in: text) {
            year = Int(text[match.range])
        }

        let resolution = firstMatch(#"(?i)(2160p|1080p|720p|480p|4k|8k|uhd)"#, in: text)
            .map { String(text[$0.range]).lowercased() }

        var title = cleanTitle(titlePart)
        if isGenericTitle(title), let folderTitle = folder.title {
            title = cleanTitle(folderTitle)
            if year == nil { year = folder.year }
        }
        if title.isEmpty { title = cleanTitle(base) }
        if title.isEmpty { title = base }

        // 中英混排：主名取中文，英文名留作备选检索词。
        let split = alternateTitle(in: title)
        if let split { title = split.primary }

        let isTV = season != nil || episode != nil || folder.isSeriesFolder

        return CinemaParsedName(title: title,
                                altTitle: split?.secondary,
                                year: year,
                                season: season,
                                episode: episode,
                                episodeEnd: episodeEnd,
                                isTV: isTV,
                                folderTitle: folder.title,
                                resolution: resolution)
    }

    // MARK: - 候选过滤

    /// 过滤掉录屏与极短片段；其余视频都参与刮削。
    /// 时长未知（网盘快照常见）时不再直接丢弃，否则会出现「有 67 个视频却一个候选都没有」。
    static func isCandidate(_ photo: PhotoItem) -> Bool {
        guard photo.isVideo else { return false }
        let name = photo.displayFilename.lowercased()
        if name.contains("screen recording") || name.contains("屏幕录制") || name.contains("录屏") {
            return false
        }
        if let duration = photo.duration, duration > 0, duration < 20 {
            return false
        }
        return true
    }

    // MARK: - 匹配

    /// 按优先级依次尝试多个数据源：前一个源没命中（或请求失败）时自动换下一个。
    static func scrape(photo: PhotoItem,
                       folderHint: String? = nil,
                       sources: [any CinemaMetadataSource],
                       cache: CinemaSearchCache? = nil,
                       detailsCache: CinemaDetailsCache? = nil) async -> CinemaScrapeOutcome {
        let parsed = parse(filename: photo.displayFilename, folderHint: folderHint)
        var firstError: Error?
        var sawResults = false
        var failures: [CinemaProvider: String] = [:]

        for source in sources {
            if Task.isCancelled { break }
            let attempt = await attemptMatch(photo: photo,
                                             parsed: parsed,
                                             folderHint: folderHint,
                                             source: source,
                                             cache: cache,
                                             detailsCache: detailsCache)
            sawResults = sawResults || attempt.sawResults
            if let entry = attempt.entry {
                return CinemaScrapeOutcome(entry: entry, error: nil, failedProviders: failures)
            }
            if let error = attempt.error {
                failures[source.provider] = error.localizedDescription
                if firstError == nil { firstError = error }
            }
        }

        // 所有源都没有返回任何候选，才把错误抛给上层（批量刮削据此判断断网 / 凭据失效）。
        if !sawResults, let firstError {
            return CinemaScrapeOutcome(entry: nil,
                                       error: firstError.localizedDescription,
                                       failedProviders: failures)
        }
        return CinemaScrapeOutcome(entry: unmatchedEntry(photo: photo,
                                                         parsed: parsed,
                                                         folderHint: folderHint),
                                   error: nil,
                                   failedProviders: failures)
    }

    /// 在单个数据源上匹配。每个检索词最多尝试「原类型 + 年份 / 原类型无年份 / 反向类型」，
    /// 最多 3 个检索词，同一部剧的多集共用缓存，避免 60 集重复打同一批请求。
    private static func attemptMatch(photo: PhotoItem,
                                     parsed: CinemaParsedName,
                                     folderHint: String?,
                                     source: any CinemaMetadataSource,
                                     cache: CinemaSearchCache?,
                                     detailsCache: CinemaDetailsCache? = nil) async -> (entry: CinemaEntry?,
                                                                         error: Error?,
                                                                         sawResults: Bool) {
        var sawResults = false

        for query in queryVariants(for: parsed).prefix(3) {
            if Task.isCancelled { break }
            var attempts: [(isTV: Bool, year: Int?)] = [(parsed.isTV, parsed.year)]
            if parsed.year != nil { attempts.append((parsed.isTV, nil)) }
            attempts.append((!parsed.isTV, parsed.year))

            for attempt in attempts {
                do {
                    let results = try await search(query: query,
                                                   isTV: attempt.isTV,
                                                   year: attempt.year,
                                                   source: source,
                                                   cache: cache)
                    if results.isEmpty { continue }
                    sawResults = true
                    if let best = choose(from: results, parsed: parsed) {
                        var entry = manualEntry(photo: photo,
                                                parsed: parsed,
                                                folderHint: folderHint,
                                                match: best)
                        if let detailsCache,
                           let details = await detailsCache.details(for: best, source: source) {
                            entry = applying(details, to: entry)
                        }
                        return (entry, nil, true)
                    }
                } catch {
                    // 网络 / 凭据 / 限流属于硬错误：换搜索词也救不回来，直接交给上层换源。
                    return (nil, error, sawResults)
                }
            }
        }
        return (nil, nil, sawResults)
    }

    private static func search(query: String,
                               isTV: Bool,
                               year: Int?,
                               source: any CinemaMetadataSource,
                               cache: CinemaSearchCache?) async throws -> [CinemaMatch] {
        if let cache {
            return try await cache.search(query: query, isTV: isTV, year: year, source: source)
        }
        return try await source.search(query: query, isTV: isTV, year: year)
    }

    /// 把 TMDB 详情并进已匹配条目：合集、演职员、预告与分级。
    static func applying(_ details: CinemaDetails, to entry: CinemaEntry) -> CinemaEntry {
        var copy = entry
        copy.collectionID = details.collectionID
        copy.collectionName = details.collectionName
        if !details.cast.isEmpty { copy.cast = details.cast }
        if !details.directors.isEmpty { copy.directors = details.directors }
        if let value = details.certification { copy.certification = value }
        if let key = details.trailerKey { copy.trailerKey = key }
        return copy
    }

    /// 手动匹配：用用户选中的候选项直接生成一条已匹配条目。
    static func manualEntry(photo: PhotoItem,
                            parsed: CinemaParsedName,
                            folderHint: String?,
                            match: CinemaMatch) -> CinemaEntry {
        CinemaEntry(file: CinemaFile(photo: photo),
                    kind: match.isTV ? .tv : .movie,
                    matched: true,
                    title: match.title,
                    originalTitle: match.originalTitle,
                    year: match.year ?? parsed.year,
                    season: parsed.season,
                    episode: parsed.episode,
                    episodeEnd: parsed.episodeEnd,
                    tmdbID: Int(match.id),
                    posterURL: match.posterURL,
                    backdropURL: match.backdropURL,
                    overview: match.overview,
                    rating: match.rating,
                    scrapedAt: Date(),
                    folderHint: folderHint,
                    genres: match.genres.isEmpty ? nil : match.genres,
                    provider: match.provider)
    }

    /// 手动匹配的候选搜索：按数据源顺序查询，合并去重；全部为空时返回第一个错误。
    static func searchCandidates(query: String,
                                 isTV: Bool,
                                 year: Int?,
                                 sources: [any CinemaMetadataSource],
                                 combineAllSources: Bool = false) async -> (matches: [CinemaMatch], error: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return ([], "请输入至少两个字") }
        var firstError: String?
        var merged: [CinemaMatch] = []
        var seen = Set<String>()

        for source in sources {
            do {
                let found = try await source.search(query: trimmed, isTV: isTV, year: year)
                for match in found {
                    // 各数据源的 ID 体系不同，去重键带上来源，避免撞号吞掉候选。
                    guard seen.insert(match.sourceKey).inserted else { continue }
                    merged.append(match)
                }
                // 刮削是「按顺序补」：第一个有结果就够。手动匹配选「全部」时继续查其余源。
                if !combineAllSources, !merged.isEmpty { break }
            } catch {
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        return (merged, merged.isEmpty ? firstError : nil)
    }

    private static func unmatchedEntry(photo: PhotoItem,
                                       parsed: CinemaParsedName,
                                       folderHint: String?) -> CinemaEntry {
        CinemaEntry(file: CinemaFile(photo: photo),
                    kind: parsed.isTV ? .tv : .movie,
                    matched: false,
                    title: parsed.title,
                    originalTitle: parsed.altTitle,
                    year: parsed.year,
                    season: parsed.season,
                    episode: parsed.episode,
                    episodeEnd: parsed.episodeEnd,
                    tmdbID: nil,
                    posterURL: nil,
                    backdropURL: nil,
                    overview: nil,
                    rating: nil,
                    scrapedAt: Date(),
                    folderHint: folderHint)
    }

    // MARK: - 检索词

    /// 依次尝试：主标题 → 另一语言名 → 文件夹剧名，再补中文段 / 英文段与去分隔符版本。
    static func queryVariants(for parsed: CinemaParsedName) -> [String] {
        var out: [String] = []

        func add(_ raw: String?) {
            guard let raw else { return }
            let value = cleanTitle(raw)
            guard value.count >= 2 else { return }
            let key = normalize(value)
            guard key.count >= 2 else { return }
            if !out.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                out.append(value)
            }
        }

        add(parsed.title)
        // `二-龙-湖·村-暖-花-开` 这类被分隔符打散的中文名，紧跟着补一个去分隔符版本。
        if containsHan(parsed.title) {
            add(parsed.title.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "·", with: ""))
        }
        add(parsed.altTitle)
        add(parsed.folderTitle)

        let bases = out
        for base in bases {
            for run in hanRuns(in: base) { add(run) }
            if !containsHan(base) { add(base) }
        }
        return out
    }

    // MARK: - 打分

    private static func choose(from results: [CinemaMatch], parsed: CinemaParsedName) -> CinemaMatch? {
        guard !results.isEmpty else { return nil }
        let queries = queryVariants(for: parsed).map(normalize).filter { $0.count >= 2 }
        guard !queries.isEmpty else { return nil }

        var best: (match: CinemaMatch, score: Double)?
        for result in results {
            let names = [result.title, result.originalTitle ?? ""]
                .map(normalize)
                .filter { !$0.isEmpty }
            var titleScore = 0.0
            for name in names {
                for query in queries {
                    if name == query {
                        titleScore = max(titleScore, 8)
                    } else if name.count >= 2, query.count >= 2,
                              name.contains(query) || query.contains(name) {
                        titleScore = max(titleScore, 4)
                    } else {
                        titleScore = max(titleScore, similarity(name, query) * 4)
                    }
                }
            }
            // 标题完全不沾边就不接受，避免只靠年份 / 类型凑分。
            guard titleScore >= 2.4 else { continue }

            var score = titleScore
            if let year = parsed.year, let resultYear = result.year {
                score += resultYear == year ? 4 : (abs(resultYear - year) <= 1 ? 2 : -2)
            }
            if result.isTV == parsed.isTV { score += 2 }
            if let rating = result.rating { score += min(1.5, rating / 10) }
            if let votes = result.voteCount { score += min(2, log10(Double(max(votes, 1)))) }
            if best == nil || score > best!.score {
                best = (result, score)
            }
        }
        guard let best, best.score >= 6 else { return nil }
        return best.match
    }

    /// 字符二元组 Dice 系数：对中文与英文片名都稳定。
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let left = bigrams(a)
        let right = bigrams(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var pool = right
        var intersection = 0
        for gram in left {
            if let index = pool.firstIndex(of: gram) {
                pool.remove(at: index)
                intersection += 1
            }
        }
        return 2 * Double(intersection) / Double(left.count + right.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count > 1 else { return [text] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }

    // MARK: - 清洗

    /// 发行标签：分辨率、片源、编码、音轨、HDR 等英文标记。
    private static let latinTagPattern = #"(?i)\b(hd\s*\d{3,4}p|fhd|uhd|2160p|1080p|720p|480p|4k|8k|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|web|hdtv|hdrip|dvdrip|remux|x264|x265|h\.?264|h\.?265|hevc|avc|aac|ac3|eac3|dts|ddp?[\s0-9.]*|atmos|hdr10\+?|hdr|dolby\s*vision|dovi|dv|10bit|8bit|proper|repack|extended|unrated|imax|60fps|hq|hc|tc)\b"#

    /// 字幕 / 语言 / 版本类标记：中文没有词边界，单独匹配。
    private static let cjkTagPattern = #"(中字|简中|繁中|简体|繁体|国语|粤语|双语|中英双字|中英|内封|内嵌|外挂|字幕|完整版|高清|超清|蓝光|原盘|收藏版|导演剪辑版|加长版|未删减|无删减|修复版|重制版|全\s*\d+\s*集)"#

    private static func cleanTitle(_ raw: String) -> String {
        var value = normalizeWidth(raw)
        // 先去掉「(2023)」这种年份括号，再清发行标签。
        value = value.replacingOccurrences(of: #"[\(\[]\s*(?:19|20)\d{2}\s*[\)\]]"#, with: " ",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: latinTagPattern, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: cjkTagPattern, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\"", with: "")
        value = value.replacingOccurrences(of: "“", with: "")
        value = value.replacingOccurrences(of: "”", with: "")
        // 结尾的压制组：只在 ` ... -GROUP` 这种带空格的形式下剥离，保住 Spider-Man / WALL-E。
        value = value.replacingOccurrences(of: #"\s+-\s*[A-Za-z0-9@._]{2,}$"#, with: "",
                                           options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " -_.·[]()【】|/,，:："))
    }

    private static func isGenericTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return true }
        if value.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil { return true }
        let generic = ["video", "vid", "movie", "film", "clip", "untitled", "no title",
                       "未命名", "视频", "新建文件夹", "download", "output", "final", "new",
                       "index", "part", "sample"]
        return generic.contains(value)
    }

    private static func normalizeWidth(_ text: String) -> String {
        let map: [Character: Character] = [
            "（": "(", "）": ")", "【": "[", "】": "]", "：": ":", "｜": "|",
            "，": ",", "／": "/", "　": " ", "～": "~"
        ]
        return String(text.map { map[$0] ?? $0 })
    }

    /// 中英混排拆成两个名字：`边水往事 Escape from the Trilateral Slopes`。
    private static func alternateTitle(in title: String) -> (primary: String, secondary: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for separator in [" | ", "|", " / ", "/", " – ", " - "] {
            guard let range = trimmed.range(of: separator) else { continue }
            let left = String(trimmed[trimmed.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let right = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty, containsHan(left) != containsHan(right) else { continue }
            return containsHan(left) ? (left, right) : (right, left)
        }

        guard let han = hanRuns(in: trimmed).first,
              han.count >= 2, han.count < trimmed.count else { return nil }
        let rest = trimmed.replacingOccurrences(of: han, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-·_.:：,，()（）"))
        // 后半段必须是英文名；`流浪地球2` 去掉中文后剩下的 “2” 不能当备选名。
        guard rest.count >= 2, !containsHan(rest),
              let first = rest.first, first.isASCII, first.isLetter else { return nil }
        return (han, rest)
    }

    // MARK: - 文件夹

    private struct FolderInfo {
        var title: String?
        var year: Int?
        var season: Int?
        var isSeriesFolder = false
    }

    /// 目录链从「最近一级」往上找：跳过季目录、年份目录、根目录与常见通用名。
    private static func parseFolder(_ hint: String?) -> FolderInfo {
        guard let hint, !hint.isEmpty else { return FolderInfo() }

        let generic: Set<String> = [
            "tv", "shows", "show", "movies", "movie", "video", "videos", "media",
            "downloads", "download", "电视剧", "电影", "剧集", "影剧", "影视", "动漫",
            "综艺", "视频", "下载", "未分类", "其他", "夸克网盘", "百度网盘", "阿里云盘",
            "来自:分享", "来自:云收藏", "夸克上传文件", "来自:bt磁力链下载"
        ]

        var info = FolderInfo()
        for part in hint.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed() {
            let name = normalizeWidth(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let lower = name.lowercased()

            if let match = firstMatch(#"(?i)^(?:season|series|s)[\s\-.]*(\d{1,2})$"#, in: name) {
                info.season = int(match.groups, 0)
                info.isSeriesFolder = true
                continue
            }
            if let match = firstMatch(#"^第\s*(\d{1,2})\s*季$"#, in: name) {
                info.season = int(match.groups, 0)
                info.isSeriesFolder = true
                continue
            }
            if name.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil {
                if info.year == nil { info.year = Int(name) }
                continue
            }
            if generic.contains(lower) { continue }
            if name.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil { continue }
            if lower.contains("http") || lower.contains(".com") || lower.contains(".xyz")
                || lower.contains(".cc") || lower.contains(".top") || lower.contains(".cn") {
                continue
            }
            // 「全 24 集」这类标记会被 cleanTitle 当发行标签剥掉，先在这里判定剧集。
            if name.range(of: #"全\s*\d+\s*集"#, options: .regularExpression) != nil {
                info.isSeriesFolder = true
            }

            let cleaned = cleanTitle(name)
            guard !cleaned.isEmpty, !isGenericTitle(cleaned) else { continue }
            info.title = cleaned
            if info.year == nil, let match = lastMatch(#"(?:19|20)\d{2}"#, in: name) {
                info.year = Int(name[match.range])
            }
            if cleaned.contains("季") || cleaned.contains("剧") { info.isSeriesFolder = true }
            break
        }
        return info
    }

    // MARK: - 文本工具

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        return String(lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        })
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    /// 连续 2 个以上的汉字段，按长度降序。
    private static func hanRuns(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\p{Han}{2,}") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .sorted { $0.count > $1.count }
    }

    private static func int(_ groups: [String], _ index: Int) -> Int? {
        guard index < groups.count, !groups[index].isEmpty else { return nil }
        return Int(groups[index])
    }

    // MARK: - 正则

    private struct RegexMatch {
        let range: Range<String.Index>
        let groups: [String]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return build(match, regex: regex, in: text)
    }

    private static func lastMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last else { return nil }
        return build(match, regex: regex, in: text)
    }

    private static func build(_ match: NSTextCheckingResult,
                              regex: NSRegularExpression,
                              in text: String) -> RegexMatch? {
        guard let full = Range(match.range, in: text) else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups.append(String(text[range]))
            } else {
                groups.append("")
            }
        }
        return RegexMatch(range: full, groups: groups)
    }
}

/// 同一次刮削任务里的搜索缓存：同一部剧的几十集只查一次同名结果。
actor CinemaSearchCache {
    private var results: [String: [CinemaMatch]] = [:]

    func search(query: String,
                isTV: Bool,
                year: Int?,
                source: any CinemaMetadataSource) async throws -> [CinemaMatch] {
        // 不同数据源的结果不能互相复用：缓存键带上数据源。
        let key = "\(source.provider.rawValue)|\(query.lowercased())|\(isTV)|\(year ?? 0)"
        if let cached = results[key] { return cached }
        let found = try await source.search(query: query, isTV: isTV, year: year)
        results[key] = found
        return found
    }
}

/// 同一次刮削里的详情缓存：同一部剧的几十集只拉一次 credits / videos / 分级。
actor CinemaDetailsCache {
    private var values: [String: CinemaDetails?] = [:]

    func details(for match: CinemaMatch, source: any CinemaMetadataSource) async -> CinemaDetails? {
        guard source.provider == .tmdb, let id = Int(match.id) else { return nil }
        let key = "\(id)|\(match.isTV)"
        if let cached = values[key] { return cached }
        let details = try? await source.details(id: id, isTV: match.isTV)
        values[key] = details
        return details
    }
}
