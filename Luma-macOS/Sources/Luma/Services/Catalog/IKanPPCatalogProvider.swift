import Foundation

/// 爱看片片（ikanpp）适配器。
///
/// 站点是 Next.js 应用，页面数据全部在 `self.__next_f.push([...])` 的 RSC 负载里：
/// - 列表 / 搜索：从负载里抽取 `entityId` 形如 `ik999141` 的条目对象。
/// - 详情：`/title/<entityId>` 的负载里有完整 entity（简介、导演、演员、类型）。
/// - 播放：`/api/lines?title=<entityId>` 返回各线路的分集，多数线路直接给 m3u8。
///
/// 该接口要求同源请求头（`Sec-Fetch-Site` 等），否则返回 403。
struct IKanPPCatalogProvider: CatalogProvider {
    static let userAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "movie", title: "电影", children: genreChildren("movie")),
        CatalogCategory(id: "tv", title: "电视剧", children: genreChildren("tv")),
        CatalogCategory(id: "anime", title: "动漫", children: genreChildren("anime")),
        CatalogCategory(id: "variety", title: "综艺", children: genreChildren("variety")),
        CatalogCategory(id: "documentary", title: "纪录片", children: genreChildren("documentary")),
        CatalogCategory(id: "short", title: "短剧", children: genreChildren("short"))
    ]

    /// 站内「类型」筛选：所有专区共用同一组 22 个类型。
    static let genres: [String] = [
        "动作", "喜剧", "爱情", "科幻", "悬疑", "犯罪", "警匪", "枪战", "谍战", "惊悚",
        "恐怖", "战争", "灾难", "冒险", "奇幻", "魔幻", "武侠", "历史", "剧情", "传记",
        "动画", "歌舞"
    ]

    /// 二级分类的 id 用 `movie?genre=动作` 记下「专区 + 类型」，取内容时再拆开。
    private static func genreChildren(_ top: String) -> [CatalogCategory] {
        genres.map { title in
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title
            return CatalogCategory(id: "\(top)?genre=\(encoded)", title: title)
        }
    }

    var supportedSorts: [CatalogSort] { [.latest] }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        let items = Self.parseItems(html, source: source)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        if let listed = try? await Self.browse(source: source, categoryID: category.id, page: page) {
            return listed
        }
        // 接口不可用时退回页面解析：只保证第一页，和旧版行为一致。
        guard page <= 1 else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/" + category.path, source: source)
        let items = Self.parseItems(html, source: source)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    /// 站内列表接口：`/api/library/browse` 同时支持专区与类型筛选，并带总数 / 总页数。
    private static func browse(source: CatalogSource,
                               categoryID: String,
                               page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let parts = categoryID.split(separator: "?", maxSplits: 1)
        let type = String(parts[0])
        var query = "type=\(type)&page=\(max(1, page))&limit=24&sort=time_added"
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") where pair.hasPrefix("genre=") {
                query += "&" + pair
            }
        }
        guard let url = URL(string: root + "/api/library/browse?" + query) else {
            throw CatalogError.parse("列表地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": root + "/",
            "Accept": "application/json"
        ])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawList = object["list"] as? [[String: Any]] else {
            throw CatalogError.parse("列表接口返回的不是 JSON")
        }
        let items = rawList.compactMap { raw -> CatalogItem? in
            guard let id = text(raw["id"]), !id.isEmpty,
                  let title = text(raw["title"]), !title.isEmpty else { return nil }
            let types = raw["types"] as? [String] ?? []
            return CatalogItem(id: id,
                               title: title,
                               coverURL: CatalogHTML.fixURL(text(raw["cover"]) ?? "",
                                                            base: source.baseURL),
                               remark: text(raw["remarks"]) ?? "",
                               categoryID: types.first,
                               publishedAt: publishDate(raw))
        }
        let pageCount = int(object["pagecount"]) ?? 1
        return CatalogPage(items: items, page: page, hasMore: page < pageCount)
    }

    /// 列表条目里的上架 / 更新时间：字段名随站点版本变化，按常见键名依次尝试。
    private static func publishDate(_ raw: [String: Any]) -> Date? {
        let keys = ["updated_at", "created_at", "time_added", "add_time", "addTime",
                    "publish_time", "release_date", "update_time", "updatedAt", "createdAt"]
        for key in keys {
            guard let value = raw[key] else { continue }
            if let raw = text(value), let date = parseDate(raw) { return date }
            if let number = value as? NSNumber, number.doubleValue > 1_000_000_000 {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
        }
        return nil
    }

    /// 「2026-11-24」「2026年11月24日」这类写法：取出年月日落到当天中午。
    private static func parseDate(_ raw: String) -> Date? {
        let numbers = raw.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        let year = numbers[0], month = numbers[1], day = numbers[2]
        guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        guard page <= 1 else {
            return CatalogPage(items: [], page: page, hasMore: false)
        }
        guard let query = WebCatalogSupport.queryEncoded(keyword) else {
            throw CatalogError.invalidConfig("搜索词无效")
        }
        let root = try WebCatalogSupport.root(source)
        // 站内搜索页已改为前端渲染，HTML 里不再带条目数据；
        // 改用搜索下拉接口 `/api/suggest`，它直接返回规范条目（ik 开头的 id 与海报）。
        if let result = try? await Self.suggest(source: source, root: root, query: query) {
            return result
        }
        // 接口不可用时退回页面解析：只保证第一页，和旧版行为一致。
        let html = try await WebCatalogSupport.fetchHTML(root + "/search?q=" + query,
                                                         source: source)
        let items = Self.parseItems(html, source: source)
        return CatalogPage(items: items, page: page, hasMore: false)
    }

    /// `/api/suggest?q=`：站内搜索下拉与「搜片名」共用，返回规范条目而不是外部聚合线路。
    private static func suggest(source: CatalogSource,
                                root: String,
                                query: String) async throws -> CatalogPage {
        guard let url = URL(string: root + "/api/suggest?q=" + query + "&limit=24") else {
            throw CatalogError.parse("搜索地址无效")
        }
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": root + "/search",
            "Accept": "application/json"
        ])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["items"] as? [[String: Any]] else {
            throw CatalogError.parse("搜索接口返回的不是 JSON")
        }
        var seen = Set<String>()
        let items = list.compactMap { raw -> CatalogItem? in
            guard let id = text(raw["id"]), !id.isEmpty,
                  let title = text(raw["title"]), !title.isEmpty else { return nil }
            let cover = text(raw["poster"]) ?? ""
            let year = text(raw["year"]) ?? ""
            // 站点会给同一部片留新旧两个条目（同海报、同年份）：合并成一条，避免搜出来重复。
            let key = cover.isEmpty ? "\(title)#\(year)" : "\(cover)#\(year)"
            guard seen.insert(key).inserted else { return nil }
            return CatalogItem(id: id,
                               title: title,
                               coverURL: CatalogHTML.fixURL(cover, base: source.baseURL),
                               remark: text(raw["status"]) ?? "",
                               categoryID: text(raw["type"]))
        }
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let titlePath = root + "/title/" + itemID
        let html = try await WebCatalogSupport.fetchHTML(titlePath, source: source)
        let text = Self.rscText(html)
        // 站点会按标题重排条目 ID：旧 ID 请求 308 跳到新 ID 的页面（例如 ik739610 → ik000088），
        // 页面负载里只有新 ID，仍按旧 ID 找就会误判成「没有找到条目资料」。
        // 以 canonical 里的 ID 为准取 entity；取不到时再退回请求时的 ID。
        let entityID = CatalogHTML.first(
            #"<link[^>]+rel="canonical"[^>]+href="[^"]*/title/(ik\d+)"#,
            in: html
        ) ?? itemID
        let objects = Self.jsonObjects(containing: "\"entityId\":\"\(entityID)\"", in: text)
        let entity = objects.first {
            Self.text($0["cover"]) != nil && Self.text($0["description"]) != nil
        } ?? objects.first ?? [:]

        let title = Self.text(entity["title"]) ?? ""
        guard !title.isEmpty else {
            // 站点被限制访问时会用 200 返回一张引导页（提到回家TV / 最新直连地址），
            // 这种情况不是条目缺失，给出可操作的提示，而不是「没有找到条目资料」。
            if html.contains("回家TV") || html.contains("Unavailable For Legal Reasons") {
                throw CatalogError.unavailable("站点返回了访问限制页，请先打开原站完成验证，或稍后重试。")
            }
            throw CatalogError.parse("没有找到条目资料")
        }
        let cover = CatalogHTML.fixURL(Self.text(entity["cover"]) ?? "",
                                       base: source.baseURL)
        let year = Self.text(entity["year"]) ?? ""
        let type = Self.text(entity["type"]) ?? ""
        let description = Self.text(entity["description"]) ?? ""
        let genres = Self.strings(entity["genres"])
        let directors = Self.strings(entity["directors"])
        let actors = Self.strings(entity["actors"])
        let region = Self.text(entity["region"]) ?? ""
        let status = Self.text(entity["status"]) ?? ""

        var facts: [CatalogDetailFact] = []
        if !genres.isEmpty {
            facts.append(CatalogDetailFact(label: "类型", value: genres.joined(separator: " / ")))
        }
        if !year.isEmpty { facts.append(CatalogDetailFact(label: "年份", value: year)) }
        if !region.isEmpty { facts.append(CatalogDetailFact(label: "地区", value: region)) }
        if !directors.isEmpty {
            facts.append(CatalogDetailFact(label: "导演", value: directors.joined(separator: "、")))
        }
        if !actors.isEmpty {
            facts.append(CatalogDetailFact(label: "主演", value: actors.joined(separator: "、")))
        }
        if !status.isEmpty { facts.append(CatalogDetailFact(label: "状态", value: status)) }

        let blocks = description.isEmpty
            ? []
            : [CatalogContentBlock(kind: .paragraph, text: description)]
        let episodes = await Self.lines(source: source,
                                        itemID: itemID,
                                        referer: titlePath)

        let item = CatalogItem(id: itemID,
                               title: title,
                               coverURL: cover,
                               remark: status,
                               categoryID: type)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let raw = CatalogHTML.fixURL(episode.pageURL, base: source.baseURL)
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("播放地址无效")
        }
        let looksLikePage = raw.contains("/api/play")
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": source.referer,
                                       "Accept": "*/*"],
                             isHLS: raw.lowercased().contains(".m3u8") || looksLikePage)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 列表解析

    static func parseItems(_ html: String, source: CatalogSource) -> [CatalogItem] {
        let payload = rscText(html)
        guard !payload.isEmpty else { return [] }
        var seen = Set<String>()
        var items: [CatalogItem] = []
        for object in jsonObjects(containing: "\"entityId\":\"ik", in: payload) {
            guard let id = text(object["entityId"]),
                  id.hasPrefix("ik"),
                  let title = text(object["title"]), !title.isEmpty,
                  seen.insert(id).inserted else { continue }
            let cover = CatalogHTML.fixURL(text(object["cover"]) ?? "", base: source.baseURL)
            var remark = text(object["updateBadge"]) ?? ""
            if remark.isEmpty { remark = text(object["episodes_info"]) ?? "" }
            if remark.isEmpty { remark = text(object["remarks"]) ?? "" }
            items.append(CatalogItem(id: id,
                                     title: title,
                                     coverURL: cover,
                                     remark: remark,
                                     categoryID: text(object["type"])))
            if items.count >= 240 { break }
        }
        return items
    }

    // MARK: - 分集

    /// `/api/lines` 返回多条线路；优先挑「直链 m3u8 最多」的那条，
    /// 避开需要再跳一次 `/api/play` 的线路。
    private static func lines(source: CatalogSource,
                              itemID: String,
                              referer: String) async -> [CatalogEpisode] {
        guard let root = try? WebCatalogSupport.root(source),
              let encoded = WebCatalogSupport.queryEncoded(itemID),
              let url = URL(string: root + "/api/lines?title=" + encoded)
        else { return [] }
        guard let data = try? await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Referer": referer,
            "Accept": "*/*",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty"
        ]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = object["lines"] as? [[String: Any]] else {
            return []
        }

        var best: [[String: Any]] = []
        var bestScore = -1
        for line in lines {
            guard let episodes = line["episodes"] as? [[String: Any]], !episodes.isEmpty else {
                continue
            }
            let direct = episodes.filter {
                let raw = text($0["url"]) ?? ""
                return raw.lowercased().hasPrefix("http") && !raw.contains("/api/play")
            }.count
            let score = direct * 1000 + episodes.count
            if score > bestScore {
                bestScore = score
                best = episodes
            }
        }

        return best.enumerated().compactMap { index, raw in
            let address = CatalogHTML.fixURL(text(raw["url"]) ?? "", base: source.baseURL)
            guard !address.isEmpty else { return nil }
            return CatalogEpisode(index: index + 1,
                                  pageURL: address,
                                  name: text(raw["name"]) ?? "第 \(index + 1) 集")
        }
    }

    // MARK: - RSC 负载

    /// 把 HTML 里所有 `self.__next_f.push([1,"…"])` 的字符串拼接起来。
    private static func rscText(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)"#
        ) else { return "" }
        let ns = html as NSString
        var output = ""
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 1))
            if let data = ("\"" + body + "\"").data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data,
                                                               options: .fragmentsAllowed) as? String {
                output += decoded
            }
        }
        return output
    }

    /// 找出负载里所有包含指定片段的 JSON 对象（按花括号配对，跳过字符串内部）。
    private static func jsonObjects(containing needle: String,
                                    in text: String) -> [[String: Any]] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var results: [[String: Any]] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let hit = ns.range(of: needle, options: [], range: search)
            if hit.location == NSNotFound { break }
            let prefix = NSRange(location: 0, length: hit.location)
            let brace = ns.range(of: "{", options: .backwards, range: prefix)
            if brace.location != NSNotFound,
               let end = matchingBrace(ns, from: brace.location), end > brace.location {
                let raw = ns.substring(with: NSRange(location: brace.location,
                                                     length: end - brace.location + 1))
                if let data = raw.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    results.append(object)
                }
            }
            let next = hit.location + hit.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return results
    }

    private static func matchingBrace(_ ns: NSString, from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < ns.length {
            let code = ns.character(at: index)
            if inString {
                if escaped {
                    escaped = false
                } else if code == 0x5C {
                    escaped = true
                } else if code == 0x22 {
                    inString = false
                }
            } else if code == 0x22 {
                inString = true
            } else if code == 0x7B {
                depth += 1
            } else if code == 0x7D {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - 小工具

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { text($0) } ?? []
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }
}

// MARK: - 导入

extension IKanPPCatalogProvider {
    static func importSource(from address: String) async throws -> CatalogSource {
        let root = try WebCatalogSupport.base(from: address)
        let host = URL(string: root)?.host ?? root
        let name = host.contains("ikanpp") ? "爱看片片" : host
        let source = CatalogSource(name: name,
                                   kind: .ikanpp,
                                   baseURL: root,
                                   configURL: address,
                                   userAgent: userAgent,
                                   referer: root + "/",
                                   categories: defaultCategories)
        let page = try await IKanPPCatalogProvider().home(source: source)
        guard !page.items.isEmpty else {
            throw CatalogError.invalidConfig("首页没有解析到影视内容")
        }
        return source
    }
}
