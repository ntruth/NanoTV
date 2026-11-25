import Foundation

/// 肉视频（`rou.video`）适配器。
///
/// - 列表是服务端渲染的 `/v` 与 `/t/{标签}`，分页统一 `?page=N`。
/// - 详情页把播放地址放在 `ev.d`（base64 + 位移）里，指向 `/api/hls/{id}`。
/// - 该接口返回的是 PNG 外壳的 HLS，播放器不能直读，交给 `RouHLSProxy` 解包转发。
struct RouVideoCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://rou.video"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 视频库首行的筛选 chip（站点 `/v` 页）。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "v", title: "全部"),
        CatalogCategory(id: "t/%E8%87%AA%E6%8B%8D%E6%B5%81%E5%87%BA", title: "自拍流出"),
        CatalogCategory(id: "t/%E5%9C%8B%E7%94%A2AV", title: "國產AV"),
        CatalogCategory(id: "t/%E6%8E%A2%E8%8A%B1", title: "探花"),
        CatalogCategory(id: "t/%E6%97%A5%E6%9C%AC", title: "日本"),
        CatalogCategory(id: "t/%E9%BA%BB%E8%B1%86%E5%82%B3%E5%AA%92", title: "麻豆傳媒"),
        CatalogCategory(id: "t/OnlyFans", title: "OnlyFans")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let html = try? await WebCatalogSupport.fetchHTML(root + "/v", source: source) {
            let live = Self.parseFilters(html)
            if live.count >= 2 { return live }
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await listPage(source: source, path: "v", page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        try await listPage(source: source, path: "v", page: page)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        return try await listPage(source: source, path: target.id, page: page)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/search?q=\(encoded)"
        if page > 1 { address += "&page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: items.count >= 24)
    }

    /// 热门标签：站点「探索分類」把题材与片商分成若干组。
    func tags(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML(root + "/cat", source: source)
        else { return [] }
        return Self.parseTagGroups(html)
    }

    /// 片商 / 子標籤是分类页里的二级频道，不再作为热门标签铺进标签面板。
    func tags(source: CatalogSource, category: CatalogCategory?) async throws -> [CatalogCategory] {
        guard category == nil else { return [] }
        return try await tags(source: source)
    }

    /// 二级频道：`/t/{主分类}` 页把这一类的片商单独列成一排。
    func channels(source: CatalogSource, category: CatalogCategory) async throws -> [CatalogCategory] {
        guard category.id.hasPrefix("t/") else { return [] }
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML("\(root)/\(category.id)",
                                                               source: source) else { return [] }
        var seen = Set<String>()
        return Self.parseContextTags(html)
            .flatMap { $0.children ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/v/\(itemID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? "视频 \(itemID)"
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let info = Self.parseStructuredData(html)

        var blocks: [CatalogContentBlock] = []
        if !info.description.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph, text: info.description))
        }
        if !info.genres.isEmpty {
            blocks.append(CatalogContentBlock(kind: .paragraph,
                                              text: "标签：" + info.genres.joined(separator: " · ")))
        }
        let item = CatalogItem(id: itemID, title: title, coverURL: cover,
                               remark: info.durationText, categoryID: nil)
        return CatalogDetail(item: item,
                             episodes: [CatalogEpisode(index: 1, pageURL: address)],
                             blocks: blocks,
                             facts: info.facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let root = try WebCatalogSupport.root(source)
        guard let pageURL = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        let html = try await WebCatalogSupport.fetchHTML(pageURL, source: source)
        let raw = Self.playbackPath(html)
            ?? "/api/hls/\((episode.pageURL as NSString).lastPathComponent)"
        let fixed = CatalogHTML.fixURL(raw, base: root)
        guard let upstream = URL(string: fixed) else {
            throw CatalogError.parse("视频地址解析失败")
        }
        let local = try RouHLSProxy.shared.url(for: upstream, source: source)
        return CatalogStream(url: local, headers: [:], isHLS: true)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = CatalogSource(name: "肉视频", kind: .rouVideo,
                                  baseURL: base, userAgent: defaultUserAgent,
                                  referer: base + "/", categories: defaultCategories)
        guard let url = URL(string: base + "/v"),
              let html = try? await WebCatalogSupport.fetchHTML(url, source: probe),
              html.contains("rou.video") || html.contains("/v/") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        let live = parseFilters(html)
        return CatalogSource(name: "肉视频",
                             kind: .rouVideo,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: live.count >= 2 ? live : defaultCategories,
                             posterAspect: 1.6,
                             isEnabled: false)
    }

    // MARK: - 列表

    private func listPage(source: CatalogSource, path: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        var address = root + "/" + path
        if page > 1 {
            address += path.contains("?") ? "&page=\(page)" : "?page=\(page)"
        }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: items.count >= 24)
    }

    static func parseFilters(_ html: String) -> [CatalogCategory] {
        guard let bar = CatalogHTML.first(
            #"<div aria-label="篩選"[^>]*>([\s\S]*?)</div>"#, in: html) else { return [] }
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a href="([^"]+)"[^>]*>([^<]+)</a>"#, in: bar) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor) else { continue }
            let id = href.hasPrefix("/") ? String(href.dropFirst()) : href
            let title = CatalogHTML.stripTags(anchor)
            guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    /// 列表卡片：`<a href="/v/{id}" class="group block min-w-0">封面 + 标题 + 时长</a>`。
    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.fullMatches(
            #"<a href="/v/[A-Za-z0-9]+" class="group block[^"]*"[\s\S]*?</a>"#, in: html) {
            guard let id = CatalogHTML.first(#"href="/v/([A-Za-z0-9]+)""#, in: block),
                  seen.insert(id).inserted else { continue }
            let title = CatalogHTML.first(#"alt="([^"]*)""#, in: block)
                ?? CatalogHTML.first(#"<h3[^>]*>([\s\S]*?)</h3>"#, in: block)
                    .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"<img src="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#"(\d+分\d+秒)"#, in: block)
                ?? CatalogHTML.first(#"(\d{1,2}:\d{2}(?::\d{2})?)"#, in: block) ?? ""
            result.append(CatalogItem(id: id, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }

    // MARK: - 标签分组

    static func parseTagGroups(_ html: String) -> [CatalogCategory] {
        var groups: [CatalogCategory] = []
        for section in CatalogHTML.fullMatches(
            #"<section class="my-\[30px\][^"]*">([\s\S]*?)</section>"#, in: html) {
            guard let rawTitle = CatalogHTML.first(#"<h2[^>]*>([\s\S]*?)</h2>"#, in: section)
            else { continue }
            let title = CatalogHTML.stripTags(rawTitle)
            guard !title.isEmpty, title != "主分類", title != "按主分類找片商" else { continue }
            let children = parseTagAnchors(in: section)
            guard children.count >= 2 else { continue }
            groups.append(CatalogCategory(id: "group:rou:\(title)", title: title,
                                          children: Array(children.prefix(40)), isGroup: true))
        }
        // 「按主分類找片商」用 details 折叠，每个主分类一组片商。
        for details in CatalogHTML.fullMatches(#"<details[^>]*>([\s\S]*?)</details>"#, in: html) {
            guard let rawTitle = CatalogHTML.first(
                #"<summary[^>]*>[\s\S]*?<span[^>]*>([^<]+)</span>"#, in: details) else { continue }
            let title = "片商 · " + CatalogHTML.stripTags(rawTitle)
            let children = parseTagAnchors(in: details)
            guard children.count >= 2 else { continue }
            groups.append(CatalogCategory(id: "group:rou:\(title)", title: title,
                                          children: Array(children.prefix(40)), isGroup: true))
        }
        return groups
    }

    /// 标签页的筛选行：`<span class="text-sm text-dim">片商 / 子標籤</span>` + 一串标签。
    static func parseContextTags(_ html: String) -> [CatalogCategory] {
        var groups: [CatalogCategory] = []
        var seen = Set<String>()
        for row in CatalogHTML.fullMatches(
            #"<div class="flex items-center gap-\[9px\] flex-wrap[^"]*">([\s\S]*?)</div>"#,
            in: html) {
            guard let rawTitle = CatalogHTML.first(
                #"<span class="text-sm text-dim">([^<]+)</span>"#, in: row) else { continue }
            let title = CatalogHTML.stripTags(rawTitle)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            let children = parseTagAnchors(in: row)
            guard children.count >= 2 else { continue }
            groups.append(CatalogCategory(id: "group:rou:\(title)", title: title,
                                          children: Array(children.prefix(60)), isGroup: true))
        }
        return groups
    }

    private static func parseTagAnchors(in text: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a href="/t/[^"]+"[^>]*>[\s\S]*?</a>"#, in: text) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor) else { continue }
            // 计数是独立的 span（「91沈先生」+「347」），标题要去掉它。
            let withoutCount = anchor.replacingOccurrences(
                of: #"<span class="text-sm text-dim">[\s\S]*?</span>"#, with: "",
                options: .regularExpression)
            let title = CatalogHTML.stripTags(withoutCount)
            let id = href.hasPrefix("/") ? String(href.dropFirst()) : href
            guard !title.isEmpty, !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    // MARK: - 详情元数据

    private struct StructuredInfo {
        var description = ""
        var durationText = ""
        var genres: [String] = []
        var facts: [CatalogDetailFact] = []
    }

    private static func parseStructuredData(_ html: String) -> StructuredInfo {
        var info = StructuredInfo()
        guard let jsonText = CatalogHTML.first(
            #"<script type="application/ld\+json">([\s\S]*?)</script>"#, in: html),
            let data = jsonText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return info }

        info.description = (object["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        info.genres = (object["genre"] as? [String]) ?? []

        if let duration = object["duration"] as? String {
            info.durationText = durationText(iso: duration)
            if !info.durationText.isEmpty {
                info.facts.append(CatalogDetailFact(label: "时长", value: info.durationText))
            }
        }
        if let upload = object["uploadDate"] as? String, upload.count >= 10 {
            info.facts.append(CatalogDetailFact(label: "上架日期", value: String(upload.prefix(10))))
        }
        if !info.genres.isEmpty {
            info.facts.append(CatalogDetailFact(label: "分类", value: info.genres.joined(separator: " / ")))
        }
        if let stat = object["interactionStatistic"] as? [String: Any],
           let count = stat["userInteractionCount"] as? Int {
            info.facts.append(CatalogDetailFact(label: "观看", value: compactCount(count)))
        }
        // 演员 / 出品方：详情页可点进跨源档案。
        let actors = names(from: object["actor"])
        if !actors.isEmpty {
            info.facts.append(CatalogDetailFact(label: "女优",
                                                value: actors.joined(separator: "、")))
        }
        let makers = names(from: object["productionCompany"]) + names(from: object["publisher"])
        if !makers.isEmpty {
            info.facts.append(CatalogDetailFact(label: "片商",
                                                value: WebCatalogSupport.unique(makers)
                                                    .joined(separator: "、")))
        }
        return info
    }

    /// JSON-LD 里的名字字段可能是字符串、对象或数组。
    private static func names(from value: Any?) -> [String] {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let dict = value as? [String: Any] {
            return names(from: dict["name"])
        }
        if let list = value as? [Any] {
            return list.flatMap { names(from: $0) }
        }
        return []
    }

    /// `PT2603S` → `43:23`。
    private static func durationText(iso: String) -> String {
        guard iso.hasPrefix("PT") else { return "" }
        var seconds = 0
        var number = ""
        for character in iso.dropFirst(2) {
            if character.isNumber {
                number.append(character)
            } else {
                guard let value = Int(number) else { number = ""; continue }
                switch character {
                case "H": seconds += value * 3600
                case "M": seconds += value * 60
                case "S": seconds += value
                default: break
                }
                number = ""
            }
        }
        guard seconds > 0 else { return "" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 10_000 {
            return String(format: "%.1f 万", Double(value) / 10_000)
        }
        return "\(value)"
    }

    // MARK: - 播放地址

    /// 详情页的 `ev:{d:"…",k:23}`：base64 后再逐字符减去 k，得到 `{"videoUrl":…}`。
    static func playbackPath(_ html: String) -> String? {
        let pattern = #"ev:\$R\[\d+\]=\{d:"([^"]+)",k:(\d+)\}"#
        var payload: String?
        var shift = 0
        if let encoded = CatalogHTML.first(pattern, in: html, group: 1),
           let key = CatalogHTML.first(pattern, in: html, group: 2),
           let value = Int(key) {
            payload = encoded
            shift = value
        } else if let encoded = CatalogHTML.first(#"ev:\{d:"([^"]+)",k:(\d+)\}"#, in: html, group: 1),
                  let key = CatalogHTML.first(#"ev:\{d:"([^"]+)",k:(\d+)\}"#, in: html, group: 2),
                  let value = Int(key) {
            payload = encoded
            shift = value
        }
        guard var raw = payload, let data = Data(base64Encoded: raw) else { return nil }
        raw = String(decoding: data.map { byte in
            UInt8(max(0, min(255, Int(byte) - shift)))
        }, as: UTF8.self)
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { return nil }
        return json["videoUrl"] as? String
    }
}
