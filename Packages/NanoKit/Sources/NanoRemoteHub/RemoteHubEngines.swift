import Foundation
import NanoCore

/// 远程站点统一返回的影视卡片摘要与播放剧集列表
public struct RemoteVodEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var siteID: UUID
    public var siteName: String
    public var vodID: String
    public var title: String
    public var coverURL: String?
    public var remarks: String      // e.g. "更新至24集" / "HD中字"
    public var categoryName: String
    public var actor: String
    public var overview: String
    public var playRoutes: [RemotePlayRoute]

    public init(
        siteID: UUID,
        siteName: String,
        vodID: String,
        title: String,
        coverURL: String? = nil,
        remarks: String = "",
        categoryName: String = "",
        actor: String = "",
        overview: String = "",
        playRoutes: [RemotePlayRoute] = []
    ) {
        self.id = "\(siteID.uuidString)_\(vodID)"
        self.siteID = siteID
        self.siteName = siteName
        self.vodID = vodID
        self.title = title
        self.coverURL = coverURL
        self.remarks = remarks
        self.categoryName = categoryName
        self.actor = actor
        self.overview = overview
        self.playRoutes = playRoutes
    }
}

public struct RemotePlayRoute: Identifiable, Codable, Hashable, Sendable {
    public var id: String { routeName }
    public var routeName: String
    public var episodes: [RemotePlayEpisode]

    public init(routeName: String, episodes: [RemotePlayEpisode]) {
        self.routeName = routeName
        self.episodes = episodes
    }
}

public struct RemotePlayEpisode: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(title)_\(url)" }
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// 引擎 3 专属配置：声明式自定义网页爬虫规则模型（JSON 可序列化导入导出）
public struct CustomWebCrawlerRuleSpec: Codable, Hashable, Sendable {
    public var baseURL: String
    public var userAgent: String?
    public var searchURLTemplate: String        // e.g. "https://example.com/search?q={wd}"
    public var latestListURLTemplate: String    // e.g. "https://example.com/latest?page={pg}"
    public var itemBlockRegex: String           // 匹配单个视频卡片 HTML 片段的正则
    public var titleCaptureRegex: String        // 提取标题 Group 1
    public var hrefCaptureRegex: String         // 提取详情/播放链接 Group 1
    public var coverCaptureRegex: String?       // 提取封面图 Group 1
    public var directStreamSniffRegex: String   // 在播放页 HTML 中提取直链 m3u8/mp4 的正则

    public init(
        baseURL: String,
        userAgent: String? = nil,
        searchURLTemplate: String,
        latestListURLTemplate: String,
        itemBlockRegex: String,
        titleCaptureRegex: String,
        hrefCaptureRegex: String,
        coverCaptureRegex: String? = nil,
        directStreamSniffRegex: String = "(https?:\\\\?/\\\\?/[^\"'\\s<>]+?\\.m3u8[^\"'\\s<>]*)"
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.searchURLTemplate = searchURLTemplate
        self.latestListURLTemplate = latestListURLTemplate
        self.itemBlockRegex = itemBlockRegex
        self.titleCaptureRegex = titleCaptureRegex
        self.hrefCaptureRegex = hrefCaptureRegex
        self.coverCaptureRegex = coverCaptureRegex
        self.directStreamSniffRegex = directStreamSniffRegex
    }
}

/// 统一远程源聚合器：支持 苹果CMS JSON + TVBox/FongMi 订阅解析 + 自定义网页爬虫规则
public struct RemoteResourceEngineHub: Sendable {
    public init() {}

    // MARK: - 1. TVBox / FongMi JSON 订阅包一键解析导入

    public struct ImportedFongMiBundle: Sendable {
        public let sites: [RemoteResourceSite]
        public let liveM3UURLs: [(name: String, url: String, ua: String?)]
    }

    public static func parseFongMiSubscriptionJSON(_ rawJSON: String) throws -> ImportedFongMiBundle {
        // 剥离 TVBox 配置中常见的 `//` 行注释
        let cleanLines = rawJSON.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let sanitized = cleanLines.joined(separator: "\n")
        guard let data = sanitized.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var parsedSites: [RemoteResourceSite] = []
        if let siteArr = root["sites"] as? [[String: Any]] {
            for item in siteArr {
                guard let name = item["name"] as? String,
                      let api = item["api"] as? String else { continue }
                let key = (item["key"] as? String) ?? UUID().uuidString
                let typeInt = (item["type"] as? Int) ?? 1
                let searchable = ((item["searchable"] as? Int) ?? 1) == 1

                // type == 1 && api 为 http 接口即为标准苹果 CMS JSON，其余归为 FongMi 扩展规则源
                let engineType: RemoteSiteEngineType = (typeInt == 1 && api.hasPrefix("http")) ? .macCMSJson : .fongMiTVBox
                var extPayload: String? = nil
                if let extStr = item["ext"] as? String {
                    extPayload = extStr
                } else if let extObj = item["ext"], JSONSerialization.isValidJSONObject(extObj),
                          let extData = try? JSONSerialization.data(withJSONObject: extObj) {
                    extPayload = String(data: extData, encoding: .utf8)
                }

                parsedSites.append(
                    RemoteResourceSite(
                        key: key,
                        name: name,
                        engineType: engineType,
                        apiURL: api,
                        extRulePayload: extPayload,
                        isEnabled: true,
                        isSearchable: searchable,
                        healthStatus: .checking
                    )
                )
            }
        }

        var liveFeeds: [(String, String, String?)] = []
        if let lives = root["lives"] as? [[String: Any]] {
            for live in lives {
                if let url = live["url"] as? String {
                    let name = (live["name"] as? String) ?? "FongMi 直播源"
                    let ua = live["ua"] as? String
                    liveFeeds.append((name, url, ua))
                }
            }
        }

        return ImportedFongMiBundle(sites: parsedSites, liveM3UURLs: liveFeeds)
    }

    // MARK: - 2. 标准苹果 CMS (MacCMS V10 JSON) 分类获取、按分类分页查询与播放串拆解

    public struct RemoteSiteCategory: Identifiable, Hashable, Codable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// 拉取苹果 CMS 站点的顶层与二级分类列表 (`class` 数组)
    public static func fetchMacCMSCategories(site: RemoteResourceSite) async throws -> [RemoteSiteCategory] {
        guard var comps = URLComponents(string: site.apiURL) else { return [] }
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "ac", value: "list"))
        comps.queryItems = q

        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let classArr = json["class"] as? [[String: Any]] else {
            return []
        }

        return classArr.compactMap { item in
            let typeName = (item["type_name"] as? String) ?? ""
            guard !typeName.isEmpty else { return nil }
            let typeID: String
            if let idInt = item["type_id"] as? Int {
                typeID = String(idInt)
            } else {
                typeID = (item["type_id"] as? String) ?? ""
            }
            guard !typeID.isEmpty else { return nil }
            return RemoteSiteCategory(id: typeID, name: typeName)
        }
    }

    public static func fetchMacCMSListOrSearch(
        site: RemoteResourceSite,
        categoryTypeID: String? = nil,
        keyword: String? = nil,
        page: Int = 1
    ) async throws -> [RemoteVodEntry] {
        guard var comps = URLComponents(string: site.apiURL) else { return [] }
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "ac", value: "detail"))
        q.append(URLQueryItem(name: "pg", value: String(page)))
        if let categoryTypeID, !categoryTypeID.isEmpty, categoryTypeID != "all" {
            q.append(URLQueryItem(name: "t", value: categoryTypeID))
        }
        if let keyword, !keyword.isEmpty {
            q.append(URLQueryItem(name: "wd", value: keyword))
        }
        comps.queryItems = q

        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { row in
            let vodName = (row["vod_name"] as? String) ?? ""
            guard !vodName.isEmpty else { return nil }
            let vodID: String
            if let intID = row["vod_id"] as? Int {
                vodID = String(intID)
            } else {
                vodID = (row["vod_id"] as? String) ?? UUID().uuidString
            }

            let playFrom = (row["vod_play_from"] as? String) ?? "默认线路"
            let playURLRaw = (row["vod_play_url"] as? String) ?? ""
            let routes = parseMacCMSPlayRoutes(playFrom: playFrom, playURL: playURLRaw)

            return RemoteVodEntry(
                siteID: site.id,
                siteName: site.name,
                vodID: vodID,
                title: vodName,
                coverURL: row["vod_pic"] as? String,
                remarks: (row["vod_remarks"] as? String) ?? "",
                categoryName: (row["type_name"] as? String) ?? "",
                actor: (row["vod_actor"] as? String) ?? "",
                overview: (row["vod_content"] as? String) ?? "",
                playRoutes: routes
            )
        }
    }

    /// 拆解苹果 CMS 标准 `vod_play_from` (`$$$`) 与 `vod_play_url` (`$$$` 多线路、`#` 多集、`$` 集名与URL)
    public static func parseMacCMSPlayRoutes(playFrom: String, playURL: String) -> [RemotePlayRoute] {
        let fromNames = playFrom.components(separatedBy: "$$$")
        let urlGroups = playURL.components(separatedBy: "$$$")
        var routes: [RemotePlayRoute] = []

        for (idx, groupStr) in urlGroups.enumerated() where !groupStr.isEmpty {
            let routeName = idx < fromNames.count && !fromNames[idx].isEmpty ? fromNames[idx] : "线路 \(idx + 1)"
            let rawEps = groupStr.components(separatedBy: "#")
            var episodes: [RemotePlayEpisode] = []
            for ep in rawEps where !ep.isEmpty {
                let pair = ep.split(separator: "$", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    episodes.append(RemotePlayEpisode(title: pair[0], url: pair[1]))
                } else if pair.count == 1 && pair[0].hasPrefix("http") {
                    episodes.append(RemotePlayEpisode(title: "正片", url: pair[0]))
                }
            }
            if !episodes.isEmpty {
                routes.append(RemotePlayRoute(routeName: routeName, episodes: episodes))
            }
        }
        return routes
    }

    // MARK: - 3. 声明式自定义网页爬虫规则引擎（搜索/列表提取 + 播放页直链嗅探）

    public static func executeWebCrawlerList(site: RemoteResourceSite, keyword: String? = nil, page: Int = 1) async throws -> [RemoteVodEntry] {
        guard let payload = site.extRulePayload,
              let ruleData = payload.data(using: .utf8),
              let rule = try? JSONDecoder().decode(CustomWebCrawlerRuleSpec.self, from: ruleData) else {
            return []
        }

        let targetURLStr: String
        if let keyword, !keyword.isEmpty {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            targetURLStr = rule.searchURLTemplate.replacingOccurrences(of: "{wd}", with: encoded)
        } else {
            targetURLStr = rule.latestListURLTemplate.replacingOccurrences(of: "{pg}", with: String(page))
        }

        guard let targetURL = URL(string: targetURLStr) else { return [] }
        var req = URLRequest(url: targetURL)
        req.setValue(rule.userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""

        let blocks = regexAllFirstCaptures(pattern: rule.itemBlockRegex, in: html)
        return blocks.compactMap { block in
            guard let title = regexFirstCapture(pattern: rule.titleCaptureRegex, in: block),
                  let rawHref = regexFirstCapture(pattern: rule.hrefCaptureRegex, in: block) else {
                return nil
            }
            let fullHref = rawHref.hasPrefix("http") ? rawHref : "\(rule.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(rawHref.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            let cover = rule.coverCaptureRegex.flatMap { regexFirstCapture(pattern: $0, in: block) }

            return RemoteVodEntry(
                siteID: site.id,
                siteName: site.name,
                vodID: fullHref,
                title: title,
                coverURL: cover,
                playRoutes: [
                    RemotePlayRoute(routeName: "网页嗅探", episodes: [RemotePlayEpisode(title: "立即播放", url: fullHref)])
                ]
            )
        }
    }

    public static func sniffStreamFromWebDetailPage(detailURL: URL, rule: CustomWebCrawlerRuleSpec) async throws -> URL {
        var req = URLRequest(url: detailURL)
        req.setValue(rule.userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue(rule.baseURL, forHTTPHeaderField: "Referer")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(data: data, encoding: .utf8) ?? ""

        if let rawStream = regexFirstCapture(pattern: rule.directStreamSniffRegex, in: html) {
            let unescaped = rawStream.replacingOccurrences(of: "\\/", with: "/")
            if let streamURL = URL(string: unescaped) {
                return streamURL
            }
        }
        throw URLError(.cannotFindHost)
    }

    // MARK: - 4. 并发源健康度巡检（对齐参考图6：在线/需验证/离线 + 毫秒延迟统计）

    public static func checkSitesHealthConcurrently(_ sites: [RemoteResourceSite]) async -> [RemoteResourceSite] {
        await withTaskGroup(of: RemoteResourceSite.self) { group in
            for site in sites {
                group.addTask {
                    var updated = site
                    guard site.isEnabled, let probeURL = URL(string: site.apiURL), probeURL.scheme?.hasPrefix("http") == true else {
                        return updated
                    }
                    var req = URLRequest(url: probeURL)
                    req.httpMethod = "GET"
                    req.timeoutInterval = 8.0
                    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

                    let start = ContinuousClock.now
                    do {
                        let (_, resp) = try await URLSession.shared.data(for: req)
                        let elapsed = start.duration(to: ContinuousClock.now)
                        let ms = max(1, Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
                        updated.latencyMs = ms

                        if let http = resp as? HTTPURLResponse {
                            if (200...299).contains(http.statusCode) {
                                updated.healthStatus = .online
                            } else if http.statusCode == 403 || http.statusCode == 503 || http.statusCode == 429 {
                                // 站点开启了人机校验盾，标记为琥珀色「需验证」提醒用户，绝不静默吞错
                                updated.healthStatus = .requireVerify
                            } else {
                                updated.healthStatus = .offline
                            }
                        }
                    } catch {
                        updated.healthStatus = .offline
                        updated.latencyMs = nil
                    }
                    return updated
                }
            }

            var results: [RemoteResourceSite] = []
            for await item in group {
                results.append(item)
            }
            return results
        }
    }

    // MARK: - 跨源聚合并发搜索

    public static func searchAcrossEnabledSites(keyword: String, sites: [RemoteResourceSite]) async -> [RemoteVodEntry] {
        let activeSites = sites.filter { $0.isEnabled && $0.isSearchable }
        return await withTaskGroup(of: [RemoteVodEntry].self) { group in
            for site in activeSites {
                group.addTask {
                    switch site.engineType {
                    case .macCMSJson, .fongMiTVBox:
                        return (try? await fetchMacCMSListOrSearch(site: site, keyword: keyword)) ?? []
                    case .customWebRule:
                        return (try? await executeWebCrawlerList(site: site, keyword: keyword)) ?? []
                    }
                }
            }
            var combined: [RemoteVodEntry] = []
            for await partial in group {
                combined.append(contentsOf: partial)
            }
            return combined
        }
    }

    private static func regexFirstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: nsRange), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexAllFirstCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { m in
            let idx = m.numberOfRanges >= 2 ? 1 : 0
            guard let r = Range(m.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }
    }
}
