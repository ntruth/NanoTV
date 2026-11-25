import Foundation

/// 苹果CMS（MacCMS V10）通用适配器。
///
/// 国内大量影视站共用同一套只读 JSON 接口，接口形如
/// `https://example.com/api.php/provide/vod/?ac=detail&pg=1`：
/// - 分类：`ac=list` 返回里的 `class`（`type_id` / `type_name` / `type_pid`）。
/// - 列表 / 搜索 / 详情：`ac=detail` 配 `pg` / `t` / `wd` / `ids`。
/// - 播放：`vod_play_url` 里每集就是播放地址（常见 m3u8 直链），多线路用 `$$$` 分隔。
///
/// 站点地址全部由用户导入，App 不内置任何源、不内置接口地址。
struct MacCMSCatalogProvider: CatalogProvider {
    static let userAgent = WebCatalogSupport.userAgent

    /// 苹果CMS 的 `type_id` 每个站不同，不能写死分类骨架；只有站点返回 `class` 时才知道分类。
    static let defaultCategories: [CatalogCategory] = []

    /// 苹果CMS 只有一个默认顺序：最新更新。
    var supportedSorts: [CatalogSort] { [.latest] }

    // MARK: - 请求

    private func apiURL(_ source: CatalogSource, query: [URLQueryItem]) throws -> URL {
        let raw: String
        if let api = source.apiBase, !api.isEmpty {
            raw = api
        } else {
            raw = source.baseURL + "/api.php/provide/vod/"
        }
        guard var comps = URLComponents(string: raw), comps.host != nil else {
            throw CatalogError.invalidConfig("接口地址无效")
        }
        comps.queryItems = (comps.queryItems ?? []) + query
        guard let url = comps.url else { throw CatalogError.invalidConfig("接口地址无效") }
        return url
    }

    private func fetchJSON(_ source: CatalogSource,
                           query: [URLQueryItem]) async throws -> [String: Any] {
        let url = try apiURL(source, query: query)
        let data = try await CatalogHTTP.fetchData(url: url, headers: [
            "User-Agent": source.userAgent,
            "Accept": "application/json, text/plain, */*",
            "Referer": source.referer
        ])
        return try Self.parseObject(data)
    }

    /// 兼容 JSONP：部分站点的接口被包了一层 `callback({...})`。
    private static func parseObject(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        if let text = String(data: data, encoding: .utf8),
           let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end,
           let object = try? JSONSerialization.jsonObject(
               with: Data(text[start...end].utf8)) as? [String: Any] {
            return object
        }
        throw CatalogError.parse("接口未返回 JSON，站点可能改版或需要验证")
    }

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        if let live = try? await liveCategories(source: source), !live.isEmpty {
            return live
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    private func liveCategories(source: CatalogSource) async throws -> [CatalogCategory] {
        let json = try await fetchJSON(source, query: [URLQueryItem(name: "ac", value: "list")])
        return Self.parseCategories(json)
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let json = try await fetchJSON(source, query: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "pg", value: String(max(1, page)))
        ])
        return Self.page(from: json, page: page, source: source)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let json = try await fetchJSON(source, query: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "t", value: target.id),
            URLQueryItem(name: "pg", value: String(max(1, page)))
        ])
        return Self.page(from: json, page: page, source: source)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let json = try await fetchJSON(source, query: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "wd", value: keyword),
            URLQueryItem(name: "pg", value: String(max(1, page)))
        ])
        return Self.page(from: json, page: page, source: source)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let json = try await fetchJSON(source, query: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "ids", value: itemID)
        ])
        guard let list = json["list"] as? [[String: Any]],
              let raw = list.first,
              let item = Self.parseItem(raw, source: source) else {
            throw CatalogError.parse("没有找到这一条内容")
        }
        let episodes = Self.parseEpisodes(from: raw["vod_play_url"], source: source)
        let synopsis = CatalogHTML.stripTags(Self.text(raw["vod_content"]) ?? "")
        let blocks = synopsis.isEmpty
            ? []
            : [CatalogContentBlock(kind: .paragraph, text: synopsis)]

        var facts: [CatalogDetailFact] = []
        let fields: [(String, String)] = [("类型", "type_name"), ("年份", "vod_year"),
                                          ("地区", "vod_area"), ("语言", "vod_lang"),
                                          ("导演", "vod_director"), ("主演", "vod_actor")]
        for (label, key) in fields {
            if let value = Self.text(raw[key]), !value.isEmpty {
                facts.append(CatalogDetailFact(label: label, value: value))
            }
        }
        if let remarks = Self.text(raw["vod_remarks"]) {
            facts.append(CatalogDetailFact(label: "备注", value: remarks))
        }
        return CatalogDetail(item: item, episodes: episodes, blocks: blocks, facts: facts)
    }

    /// 苹果CMS 的分集地址就是播放地址，不再需要二次解析播放页。
    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let raw = CatalogHTML.fixURL(episode.pageURL, base: source.baseURL)
        guard let url = URL(string: raw) else {
            throw CatalogError.parse("播放地址无效")
        }
        return CatalogStream(url: url,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": source.referer],
                             isHLS: raw.lowercased().contains(".m3u8"))
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 解析

    static func parseCategories(_ json: [String: Any]) -> [CatalogCategory] {
        guard let classes = json["class"] as? [[String: Any]] else { return [] }
        var tops: [CatalogCategory] = []
        var children: [String: [CatalogCategory]] = [:]
        var seen = Set<String>()
        for item in classes {
            guard let id = text(item["type_id"]),
                  let name = text(item["type_name"]),
                  !name.isEmpty,
                  seen.insert(id).inserted else { continue }
            let category = CatalogCategory(id: id, title: name)
            let parent = text(item["type_pid"]) ?? "0"
            if parent == "0" || parent.isEmpty {
                tops.append(category)
            } else {
                children[parent, default: []].append(category)
            }
        }
        if tops.isEmpty {
            // 站点只返回一层分类：全部当一级。
            return children.values.flatMap { $0 }
        }
        let known = Set(tops.map(\.id))
        tops = tops.map { top in
            var copy = top
            if let kids = children[top.id], !kids.isEmpty { copy.children = kids }
            return copy
        }
        // 父分类缺失的孤儿子分类提升为一级，别让它们消失。
        for (parent, kids) in children where !known.contains(parent) {
            tops.append(contentsOf: kids)
        }
        return tops
    }

    private static func page(from json: [String: Any], page: Int,
                             source: CatalogSource) -> CatalogPage {
        let list = json["list"] as? [[String: Any]] ?? []
        let items = list.compactMap { parseItem($0, source: source) }
        let totalPages = int(json["pagecount"]) ?? 0
        // pagecount 缺失时按「本页是否够 20 条」兜底。
        let hasMore = totalPages > 0 ? page < totalPages : items.count >= 20
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    static func parseItem(_ raw: [String: Any], source: CatalogSource) -> CatalogItem? {
        guard let id = text(raw["vod_id"]),
              let name = text(raw["vod_name"]), !name.isEmpty else { return nil }
        let cover = CatalogHTML.fixURL(text(raw["vod_pic"]) ?? "", base: source.baseURL)
        return CatalogItem(id: id,
                           title: name,
                           coverURL: cover,
                           remark: text(raw["vod_remarks"]) ?? "",
                           categoryID: text(raw["type_id"]))
    }

    /// `vod_play_url`：`第1集$url#第2集$url`；多线路用 `$$$` 分隔。
    /// 优先选 m3u8 数量最多的线路，其余线路大概率是网页播放页。
    static func parseEpisodes(from value: Any?, source: CatalogSource) -> [CatalogEpisode] {
        guard let raw = text(value) else { return [] }
        let lines = raw.components(separatedBy: "$$$")
        let chosen = lines.max { lhs, rhs in
            lhs.lowercased().components(separatedBy: ".m3u8").count
                < rhs.lowercased().components(separatedBy: ".m3u8").count
        } ?? ""
        var episodes: [CatalogEpisode] = []
        for chunk in chosen.components(separatedBy: "#") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "$", maxSplits: 1,
                                      omittingEmptySubsequences: false)
            let name = parts.count > 1 ? text(String(parts[0])) : nil
            let address = String(parts.count > 1 ? parts[1] : parts[0])
            let url = CatalogHTML.fixURL(address, base: source.baseURL)
            guard url.hasPrefix("http") else { continue }
            episodes.append(CatalogEpisode(index: episodes.count + 1,
                                           pageURL: url,
                                           name: name))
        }
        return episodes
    }

    // MARK: - 小工具

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
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

// MARK: - 导入

extension MacCMSCatalogProvider {
    /// 用苹果CMS 接口地址（或站点根地址）建一个源：接口必须真的返回数据才算识别成功。
    static func importSource(from address: String,
                             fallbackName: String? = nil) async throws -> CatalogSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.invalidConfig("地址为空") }
        let root = try WebCatalogSupport.base(from: trimmed)
        let api = trimmed.lowercased().contains("api.php")
            ? trimmed
            : root + "/api.php/provide/vod/"
        let name = fallbackName ?? URL(string: root)?.host ?? "影视源"

        var probe = CatalogSource(name: name,
                                  kind: .maccms,
                                  baseURL: root,
                                  configURL: trimmed,
                                  userAgent: userAgent,
                                  referer: root + "/",
                                  categories: [])
        probe.apiBase = api

        let provider = MacCMSCatalogProvider()
        // 只探测一次：`ac=list` 同时能拿到分类与列表，失败就说明这个地址不是苹果CMS。
        let json = try await provider.fetchJSON(probe, query: [URLQueryItem(name: "ac", value: "list")])
        let categories = parseCategories(json)
        let list = json["list"] as? [[String: Any]] ?? []
        guard !categories.isEmpty || !list.isEmpty else {
            throw CatalogError.invalidConfig("接口没有返回影视数据")
        }
        probe.categories = categories
        return probe
    }

    /// FongMi / TVBox 配置：批量导出其中的苹果CMS（`type 1`）站点。
    /// 这里只解析配置自身，不逐条探测；校验交给导入向导逐个做首页探测。
    static func importConfig(from address: String, limit: Int = 24) async throws -> [CatalogSource] {
        var url = URL(string: address)
        if url == nil { url = URL(string: "https://" + address) }
        guard let url else { throw CatalogError.invalidConfig("配置地址无效") }

        let text = try await CatalogHTTP.fetchText(url: url)
        guard let data = text.data(using: .utf8) else {
            throw CatalogError.invalidConfig("配置不是文本格式")
        }
        return try importConfig(from: data, origin: address, limit: limit)
    }

    /// 本地导入：配置内容已经在磁盘上，直接解析。`origin` 只用于记住这份配置从哪来，
    /// 传 nil 表示不保留配置地址（文件导入后仍可按站点单独编辑）。
    static func importConfig(from data: Data, origin: String?, limit: Int = 24) throws -> [CatalogSource] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalidConfig("配置不是 JSON")
        }
        // 兼容 `{"sites":[…]}` 与 `{"urls":[{"url":"…"}]}` 两种结构里的 sites。
        var sites = object["sites"] as? [[String: Any]] ?? []
        if sites.isEmpty, let groups = object["urls"] as? [[String: Any]] {
            for group in groups {
                if let nested = group["sites"] as? [[String: Any]] { sites.append(contentsOf: nested) }
            }
        }
        guard !sites.isEmpty else { throw CatalogError.invalidConfig("配置里没有 sites") }

        var sources: [CatalogSource] = []
        var usedNames = Set<String>()
        var usedHosts = Set<String>()
        for site in sites {
            guard sources.count < limit else { break }
            guard let type = int(site["type"]), type == 1,
                  let api = (site["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !api.isEmpty,
                  let apiURL = URL(string: api),
                  let host = apiURL.host?.lowercased(),
                  usedHosts.insert(host).inserted else { continue }

            let root = (apiURL.scheme ?? "https") + "://" + host
            var name = (site["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty { name = host }
            if !usedNames.insert(name).inserted { name += " · \(host)" }
            usedNames.insert(name)

            var source = CatalogSource(name: name,
                                       kind: .maccms,
                                       baseURL: root,
                                       configURL: origin,
                                       userAgent: userAgent,
                                       referer: root + "/",
                                       categories: [])
            source.apiBase = api
            sources.append(source)
        }
        guard !sources.isEmpty else {
            throw CatalogError.invalidConfig("配置里没有苹果CMS 的影视源")
        }
        return sources
    }
}
