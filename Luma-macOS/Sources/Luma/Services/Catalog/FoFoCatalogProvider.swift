import Foundation

/// FoFo 影院（fofo33 等镜像）适配器。
///
/// 站点没有开放 JSON 接口，全部靠服务端渲染的 HTML：
/// - 列表 / 搜索：卡片在 `<li>` 里，链接形如 `/dianying/153021`。
/// - 详情：正文之外还有 `var urlList = decryptDict({...})`，线路名与集名用字符 -1 位移编码。
/// - 播放：把 `sid` POST 到 `/source/`，接口直接返回 m3u8 地址。
struct FoFoCatalogProvider: CatalogProvider {
    static let userAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "dianying", title: "电影", children: genreChildren("dianying")),
        CatalogCategory(id: "dianshiju", title: "电视剧", children: genreChildren("dianshiju")),
        CatalogCategory(id: "zongyi", title: "综艺", children: varietyChildren),
        CatalogCategory(id: "dongman", title: "动漫", children: genreChildren("dongman"))
    ]

    /// 站点分类页的「类型」筛选，序号就是路径里的第一段（如 `/dianying/2-0-0-0`）。
    private static let featureGenres: [(title: String, id: String)] = [
        ("剧情", "1"), ("喜剧", "2"), ("动作", "3"), ("爱情", "4"), ("科幻", "5"),
        ("悬疑", "6"), ("惊悚", "7"), ("恐怖", "8"), ("犯罪", "9"), ("同性", "10"),
        ("音乐", "11"), ("歌舞", "12"), ("传记", "13"), ("历史", "14"), ("战争", "15"),
        ("西部", "16"), ("奇幻", "17"), ("冒险", "18"), ("灾难", "19"), ("武侠", "20"),
        ("伦理", "21")
    ]

    private static let varietyGenres: [(title: String, id: String)] = [
        ("真人秀", "1"), ("脱口秀", "2"), ("纪录片", "3"), ("传记", "4"), ("歌舞", "5")
    ]

    private static var varietyChildren: [CatalogCategory] {
        varietyGenres.map {
            CatalogCategory(id: "zongyi/\($0.id)-0-0-0", title: $0.title)
        }
    }

    private static func genreChildren(_ top: String) -> [CatalogCategory] {
        featureGenres.map {
            CatalogCategory(id: "\(top)/\($0.id)-0-0-0", title: $0.title)
        }
    }

    var supportedSorts: [CatalogSort] { [.latest] }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let html = try await Self.fetchHTML(path: "/", source: source)
        let items = Self.parseList(html, source: source)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        var path = "/" + category.path
        if page > 1 { path += "?page=\(page)" }
        let html = try await Self.fetchHTML(path: path, source: source)
        let items = Self.parseList(html, source: source)
        let hasMore = !items.isEmpty && html.range(of: "page=\(page + 1)") != nil
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        guard let query = WebCatalogSupport.queryEncoded(keyword) else {
            throw CatalogError.invalidConfig("搜索词无效")
        }
        var path = "/search?q=" + query
        if page > 1 { path += "&page=\(page)" }
        let html = try await Self.fetchHTML(path: path, source: source)
        let items = Self.parseList(html, source: source)
        let hasMore = !items.isEmpty && html.range(of: "page=\(page + 1)") != nil
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let canonicalID = itemID.hasPrefix("/") ? String(itemID.dropFirst()) : itemID
        let html = try await Self.fetchHTML(path: "/" + canonicalID, source: source)

        let headingHTML = CatalogHTML.first(
            #"<h[12][^>]*class="product-title"[^>]*>([\s\S]*?)</h[12]>"#, in: html
        ) ?? ""
        let headingText = headingHTML.components(separatedBy: "<").first ?? headingHTML
        let title = Self.clean(headingText)
        guard !title.isEmpty else {
            throw CatalogError.parse("没有找到条目标题")
        }
        let year = NetworkCinemaEnrichment.year(in: headingHTML)
        let cover = CatalogHTML.first(#"<img[^>]+src="([^"]+)"[^>]*class="thumb""#, in: html) ?? ""
        let rating = CatalogHTML.first(#"<span class="rate">\s*([\d.]+)\s*</span>"#, in: html) ?? ""

        let genre = Self.excerpt("类型", in: html)
        let region = Self.excerpt("制片国家/地区", in: html)
        let director = Self.excerpt("导演", in: html)
        let actors = Self.excerpt("主演", in: html)
        let synopsis = Self.excerpt("剧情简介", in: html)

        var facts: [CatalogDetailFact] = []
        if !genre.isEmpty { facts.append(CatalogDetailFact(label: "类型", value: genre)) }
        if let year { facts.append(CatalogDetailFact(label: "年份", value: String(year))) }
        if !region.isEmpty { facts.append(CatalogDetailFact(label: "地区", value: region)) }
        if !director.isEmpty { facts.append(CatalogDetailFact(label: "导演", value: director)) }
        if !actors.isEmpty { facts.append(CatalogDetailFact(label: "主演", value: actors)) }
        if let ratingValue = Double(rating), ratingValue > 0 {
            facts.append(CatalogDetailFact(label: "评分", value: String(format: "%.1f", ratingValue)))
        }

        let blocks = synopsis.isEmpty
            ? []
            : [CatalogContentBlock(kind: .paragraph, text: synopsis)]
        let episodes = Self.parsePlaylist(html)

        let item = CatalogItem(id: canonicalID,
                               title: title,
                               coverURL: CatalogHTML.fixURL(cover, base: source.baseURL),
                               remark: rating.isEmpty ? "" : rating,
                               categoryID: nil)
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        // `fofo://play/<sid>`：sid 只在本适配器内部使用。
        guard let sid = episode.pageURL.split(separator: "/").last.map(String.init),
              !sid.isEmpty else {
            throw CatalogError.parse("播放地址无效")
        }
        let data = try await Self.postForm(path: "/source/",
                                           body: "id=\(sid)",
                                           source: source)
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("http"), let streamURL = URL(string: raw) else {
            throw CatalogError.parse("站点没有返回可用的播放地址")
        }
        return CatalogStream(url: streamURL,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": source.referer],
                             isHLS: raw.lowercased().contains(".m3u8"))
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 带 Cloudflare 验证的请求

    private static func fetchHTML(path: String, source: CatalogSource) async throws -> String {
        let data = try await request(path: path, method: "GET", body: nil, source: source)
        return String(decoding: data, as: UTF8.self)
    }

    private static func postForm(path: String, body: String,
                                 source: CatalogSource) async throws -> Data {
        try await request(path: path, method: "POST", body: Data(body.utf8), source: source)
    }

    /// Cloudflare 的 clearance 会过期：遇到 403 时重新跑一次隐藏 WebView 验证再重试。
    private static func request(path: String, method: String, body: Data?,
                                source: CatalogSource) async throws -> Data {
        let root = try WebCatalogSupport.root(source)
        guard let url = URL(string: root + path) else {
            throw CatalogError.parse("页面地址无效")
        }
        var session = try await FoFoCloudflareGate.shared.session(for: root)
        do {
            return try await send(url: url, method: method, body: body,
                                  session: session, source: source)
        } catch let error as CatalogError {
            guard case .http(403) = error else { throw error }
            await FoFoCloudflareGate.shared.invalidate(host: source.host)
            session = try await FoFoCloudflareGate.shared.session(for: root)
            return try await send(url: url, method: method, body: body,
                                  session: session, source: source)
        }
    }

    private static func send(url: URL, method: String, body: Data?,
                             session: FoFoSession,
                             source: CatalogSource) async throws -> Data {
        var headers: [String: String] = [
            "User-Agent": session.userAgent,
            "Cookie": session.cookies,
            "Referer": source.referer,
            "Accept": "text/html,application/xhtml+xml,application/json,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if method == "POST" {
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            headers["X-Requested-With"] = "XMLHttpRequest"
            return try await CatalogHTTP.postJSON(url: url, headers: headers,
                                                  body: body ?? Data())
        }
        return try await CatalogHTTP.fetchData(url: url, headers: headers)
    }

    // MARK: - 列表解析

    /// 站点把所有卡片都放在 `<li>` 里；导航栏也是 `<li>`，靠链接形态过滤。
    static func parseList(_ html: String, source: CatalogSource) -> [CatalogItem] {
        var seen = Set<String>()
        var items: [CatalogItem] = []
        for block in CatalogHTML.blocks(#"<li(?:\s[^>]*)?>"#, in: html) {
            guard let href = CatalogHTML.first(#"href="/((?:dianying|dianshiju|zongyi|dongman)/\d+)""#,
                                               in: block),
                  seen.insert(href).inserted else { continue }
            let title = CatalogHTML.stripTags(
                CatalogHTML.first(#"<h2><a[^>]*>([\s\S]*?)</a></h2>"#, in: block) ?? ""
            )
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: block) ?? ""
            let note = CatalogHTML.stripTags(
                CatalogHTML.first(#"<div class="note"><span>([\s\S]*?)</span>"#, in: block) ?? ""
            )
            let area = CatalogHTML.stripTags(
                CatalogHTML.first(#"<div class="countrie">([\s\S]*?)</div>"#, in: block) ?? ""
            )
            let rate = CatalogHTML.first(#"<span class="rate">\s*([\d.]+)\s*</span>"#, in: block) ?? ""

            var remark = note
            if remark.isEmpty { remark = Self.collapse(area) }
            if remark.isEmpty, let value = Double(rate), value > 0 {
                remark = String(format: "%.1f 分", value)
            }
            items.append(CatalogItem(id: href,
                                     title: title,
                                     coverURL: CatalogHTML.fixURL(cover, base: source.baseURL),
                                     remark: remark,
                                     categoryID: href.split(separator: "/").first.map(String.init)))
        }
        return items
    }

    // MARK: - 播放线路解析

    /// `urlList` 用「字符 -1 位移」藏起键名与字符串值：
    /// `'tpvsdf'` → `source`、`'vsm`mjtu'` → `url_list`、`'tje'` → `sid`。
    /// 这里把单引号字符串逐个还原，拼成合法 JSON 再解析。
    static func parsePlaylist(_ html: String) -> [CatalogEpisode] {
        guard let literal = CatalogHTML.first(#"decryptDict\((\{[\s\S]*?\})\)"#, in: html),
              let json = shiftedJSON(literal),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let lines = object["url_list"] as? [[[String: Any]]] else {
            return []
        }
        let best = lines.max { $0.count < $1.count } ?? []
        return best.enumerated().compactMap { index, raw in
            guard let sid = text(raw["sid"]), !sid.isEmpty else { return nil }
            let name = text(raw["title"]) ?? "第 \(index + 1) 集"
            return CatalogEpisode(index: index + 1,
                                  pageURL: "fofo://play/\(sid)",
                                  name: name)
        }
    }

    private static func shiftedJSON(_ literal: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"'([^']*)'"#) else { return nil }
        let ns = literal as NSString
        let matches = regex.matches(in: literal, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var output = ""
        var cursor = 0
        for match in matches {
            let gap = match.range.location - cursor
            if gap > 0 {
                output += ns.substring(with: NSRange(location: cursor, length: gap))
            }
            let raw = ns.substring(with: match.range(at: 1))
            output += "\"" + jsonEscape(decodeShifted(raw)) + "\""
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            output += ns.substring(from: cursor)
        }
        return output
    }

    /// 逐字符 -1；如果还原出来是一个 JSON 字符串字面量（`"\u5149\u901f"`），再解一次。
    private static func decodeShifted(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let value = scalar.value > 0 ? scalar.value - 1 : scalar.value
            if let decoded = UnicodeScalar(value) { scalars.append(decoded) }
        }
        let shifted = String(scalars)
        if shifted.hasPrefix("\""), let data = shifted.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data,
                                                         options: .fragmentsAllowed) as? String {
            return value
        }
        return shifted
    }

    private static func jsonEscape(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": output.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": output.append(contentsOf: "\\n".unicodeScalars)
            case "\r": output.append(contentsOf: "\\r".unicodeScalars)
            case "\t": output.append(contentsOf: "\\t".unicodeScalars)
            default:
                if scalar.value < 0x20 {
                    output.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
                } else {
                    output.append(scalar)
                }
            }
        }
        return String(output)
    }

    // MARK: - 小工具

    /// 详情页的 `导演：<span>…</span>` 一类字段。
    private static func excerpt(_ label: String, in html: String) -> String {
        let pattern = #"<div class="product-excerpt">\#(label)：<span>([\s\S]*?)</span>"#
        let raw = CatalogHTML.first(pattern, in: html) ?? ""
        return collapse(CatalogHTML.stripTags(raw))
    }

    private static func clean(_ raw: String) -> String {
        collapse(CatalogHTML.stripTags(raw))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -—·"))
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
}

// MARK: - 导入

extension FoFoCatalogProvider {
    static func importSource(from address: String) async throws -> CatalogSource {
        let root = try WebCatalogSupport.base(from: address)
        let host = URL(string: root)?.host ?? root
        let name = host.contains("fofo") ? "FoFo影院" : host
        let source = CatalogSource(name: name,
                                   kind: .fofo,
                                   baseURL: root,
                                   configURL: address,
                                   userAgent: userAgent,
                                   referer: root + "/",
                                   categories: defaultCategories)
        let page = try await FoFoCatalogProvider().home(source: source)
        guard !page.items.isEmpty else {
            throw CatalogError.invalidConfig("首页没有解析到影视内容")
        }
        return source
    }
}
