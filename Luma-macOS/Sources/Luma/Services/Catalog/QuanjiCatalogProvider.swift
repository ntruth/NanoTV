import Foundation

/// 91全集（`91quanji.com`，站点标题「木瓜视频」）适配器。
///
/// 站点是服务端渲染的模板页：
/// - 首页 `/` 把「国产自拍 / 国产精品 / 热门厂商」三段列表拼在一起；
/// - 分类页是 `tag.jsp?t=<token>`，翻页用不透明的 `p=<token>`，
///   只能从当前页的分页条里取到下一页地址；
/// - 厂商墙 `makers.jsp` 列出全部片商，每个片商对应一个 `tag.jsp?t=`；
/// - 详情页 `watch.jsp?v=<id>` 的播放地址写在 `eval(I("…"))` 里，
///   把每个 UTF-16 码元异或 128 就能得到 DPlayer 配置。
struct QuanjiCatalogProvider: CatalogProvider {

    // MARK: - 默认值

    static let defaultBaseURL = "https://91quanji.com"
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// 仅在没有网络时用于渲染分类骨架。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "tag|5y9kg97rdzxe", title: "国产精品"),
        CatalogCategory(id: "tag|649e2zxgw10p", title: "国产自拍"),
        CatalogCategory(id: "group|makers", title: "热门厂商", children: [
            CatalogCategory(id: "makers", title: "全部厂商"),
            CatalogCategory(id: "tag|z8y32yqgdemj", title: "天美传媒"),
            CatalogCategory(id: "tag|0598gp923vod", title: "其他传媒"),
            CatalogCategory(id: "tag|7wxkgwqgm60p", title: "蜜桃影像传媒"),
            CatalogCategory(id: "tag|onmvrndgxzw3", title: "精东影业"),
            CatalogCategory(id: "tag|poy4gx4rqwxv", title: "91制片厂"),
            CatalogCategory(id: "tag|e1mqglprj3v8", title: "麻豆传媒映画"),
            CatalogCategory(id: "tag|k1o721d2zp8l", title: "台湾swag"),
            CatalogCategory(id: "tag|qyl9gmx236dp", title: "星空无限传媒")
        ], isGroup: true)
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        var result: [CatalogCategory] = []
        if let home = try? await WebCatalogSupport.fetchHTML(root + "/", source: source) {
            result = Self.parseNavCategories(home)
        }
        if let makersHTML = try? await WebCatalogSupport.fetchHTML(root + "/makers.jsp",
                                                                   source: source) {
            let makers = Self.parseMakers(makersHTML)
            if !makers.isEmpty {
                result.append(Self.makerGroup(makers))
            }
        }
        if result.isEmpty {
            return source.categories.isEmpty ? Self.defaultCategories : source.categories
        }
        return result
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        return CatalogPage(items: Self.parseSections(html, base: root), page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        if target.id == "makers" {
            guard page <= 1 else { return CatalogPage(items: [], page: page, hasMore: false) }
            let html = try await WebCatalogSupport.fetchHTML(root + "/makers.jsp", source: source)
            return CatalogPage(items: Self.parseSections(html, base: root), page: 1, hasMore: false)
        }
        guard target.id.hasPrefix("tag|") else {
            throw CatalogError.parse("分类地址无效")
        }
        let token = String(target.id.dropFirst("tag|".count))
        return try await tagPage(source: source, root: root, token: token, page: page)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        var address = root + "/search.jsp?keyword=" + encoded
        if page > 1 { address += "&p=\(page)" }
        // 搜索结果的第 2 页起是纯卡片片段，不带完整页面骨架。
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseSections(html, base: root)
        return CatalogPage(items: items, page: page, hasMore: items.count >= 36)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        guard let url = URL(string: root + "/watch.jsp?v=" + itemID) else {
            throw CatalogError.parse("详情地址无效")
        }
        let html = try await WebCatalogSupport.fetchHTML(url, source: source)
        let title = Self.parseTitle(html)
        let item = CatalogItem(id: itemID,
                               title: title.isEmpty ? "视频 \(itemID)" : title,
                               coverURL: "",
                               remark: "",
                               categoryID: nil)
        let episode = CatalogEpisode(index: 1, pageURL: url.absoluteString)
        let facts = await Self.detailFacts(source: source, title: title,
                                           watchHTML: html, pageURL: url)
        return CatalogDetail(item: item, episodes: [episode], facts: facts)
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        guard let url = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        let html = try await WebCatalogSupport.fetchHTML(url, source: source)
        guard let raw = Self.playerAddress(from: html),
              let streamURL = URL(string: raw) else {
            throw CatalogError.parse("该条目没有可直接播放的视频")
        }
        return CatalogStream(url: streamURL,
                             headers: ["User-Agent": source.userAgent,
                                       "Referer": url.absoluteString],
                             isHLS: raw.lowercased().contains(".m3u8"))
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = CatalogSource(name: "91全集",
                                  kind: .quanji,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("watch.jsp?v=") || html.contains("木瓜") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        var categories = parseNavCategories(html)
        if let makersHTML = try? await WebCatalogSupport.fetchHTML(base + "/makers.jsp",
                                                                   source: probe) {
            let makers = parseMakers(makersHTML)
            if !makers.isEmpty { categories.append(makerGroup(makers)) }
        }
        return CatalogSource(name: "91全集",
                             kind: .quanji,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: categories.isEmpty ? defaultCategories : categories,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    private static func makerGroup(_ makers: [CatalogCategory]) -> CatalogCategory {
        CatalogCategory(id: "group|makers", title: "热门厂商",
                        children: [CatalogCategory(id: "makers", title: "全部厂商")] + makers,
                        isGroup: true)
    }

    // MARK: - 分类解析

    /// 顶部导航里的真实分类：国产精品、国产自拍。其余入口是发布页广告。
    static func parseNavCategories(_ html: String) -> [CatalogCategory] {
        var scope = html
        if let start = html.range(of: #"<nav class="main-menu""#)?.lowerBound,
           let end = html.range(of: "</nav>", range: start..<html.endIndex)?.upperBound {
            scope = String(html[start..<end])
        }
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a[^>]+href="[^"]*tag\.jsp\?t=[^"]*"[^>]*>[\s\S]*?</a>"#,
                                              in: scope) {
            guard let token = CatalogHTML.first(#"tag\.jsp\?t=([^"&]+)"#, in: anchor) else { continue }
            let title = CatalogHTML.stripTags(anchor)
            guard !title.isEmpty, title != "首页" else { continue }
            let id = "tag|" + token
            guard seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    /// 厂商墙：每个圆形 logo 对应一个 `tag.jsp?t=`。
    static func parseMakers(_ html: String) -> [CatalogCategory] {
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a[^>]+href="[^"]*tag\.jsp\?t=[^"&]+"[^>]*>[\s\S]*?</a>"#,
                                              in: html) {
            guard let token = CatalogHTML.first(#"tag\.jsp\?t=([^"&]+)"#, in: anchor),
                  let title = CatalogHTML.first(#"<p class="specialTitle">([\s\S]*?)</p>"#,
                                                in: anchor).map(CatalogHTML.stripTags),
                  !title.isEmpty else { continue }
            let id = "tag|" + token
            guard seen.insert(id).inserted else { continue }
            result.append(CatalogCategory(id: id, title: title))
        }
        return result
    }

    // MARK: - 列表解析

    /// 站点列表只有封面和标题，没有集数、评分、时长。
    /// 这里从标题里补出能确定的信息（番号 / 厂牌 / [原创] 这类前缀），
    /// 卡片右下角就不会全是空白。
    static func parseCards(_ html: String, base: String,
                           context: String? = nil) -> [CatalogItem] {
        let blocks = CatalogHTML.fullMatches(
            #"<div class="item thumb[^"]*">[\s\S]*?watch\.jsp\?v=[^"&]+[\s\S]*?</a></div>"#,
            in: html)
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in blocks {
            guard let id = CatalogHTML.first(#"watch\.jsp\?v=([^"&]+)"#, in: block),
                  seen.insert(id).inserted else { continue }
            let title = CatalogHTML.first(#"<h5 class="thumb-spot__title">([\s\S]*?)</h5>"#,
                                          in: block)
                .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"<img[^>]+src="([^"]+)""#, in: block) ?? ""
            result.append(CatalogItem(id: id, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: metadata(title: title, context: context),
                                      categoryID: nil))
        }
        return result
    }

    /// 首页 / 厂商墙把多个区块拼在一页里，每个区块的 `h1` 就是片商名，
    /// 拆开解析才能给卡片补上「天美传媒」这类归属。
    static func parseSections(_ html: String, base: String) -> [CatalogItem] {
        let sections = CatalogHTML.blocks(#"<div id="list_videos_videos_index">"#, in: html)
        guard !sections.isEmpty else { return parseCards(html, base: base) }
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for section in sections {
            let context = CatalogHTML.first(#"<h1 class="title">([\s\S]*?)</h1>"#, in: section)
                .map(CatalogHTML.stripTags)
            for item in parseCards(section, base: base, context: context)
            where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }

    // MARK: - 标题元数据

    /// 常见厂牌：标题里能直接认出来的优先，识别不到再用区块标题兜底。
    private static let makerHints: [String] = [
        "天美传媒", "蜜桃影像传媒", "蜜桃传媒", "精东影业", "麻豆传媒映画",
        "麻豆传媒", "91制片厂", "果冻传媒", "星空无限传媒", "其他传媒",
        "台湾swag", "兔子先生", "千禧传媒", "起点传媒", "蝌蚪传媒",
        "麻麻传媒", "桃泰郎", "奇淫旅社", "世足狂热"
    ].sorted { $0.count > $1.count }

    private static let fc2CodeRegex = try? NSRegularExpression(
        pattern: "(?i)FC2[-_ ]?PPV[-_ ]?\\d{6,8}")
    private static let codeRegex = try? NSRegularExpression(
        pattern: "(?i)(?<![A-Z0-9])([A-Z]{2,6})[-_ ]?(\\d{2,5})(?!\\d)")

    private static func metadata(title: String, context: String?) -> String {
        var parts: [String] = []
        if let code = titleCode(title) { parts.append(code) }
        let maker = makerHints.first { title.contains($0) }
            ?? (isMakerContext(context) ? context : nil)
        if let maker, !parts.contains(maker) { parts.append(maker) }
        if parts.isEmpty, let tag = bracketTag(title) { parts.append(tag) }
        return parts.prefix(2).joined(separator: " · ")
    }

    /// `TMW104` / `FC2-PPV-1234567` 这类番号。
    private static func titleCode(_ title: String) -> String? {
        let range = NSRange(title.startIndex..., in: title)
        if let regex = fc2CodeRegex, let match = regex.firstMatch(in: title, range: range),
           let hit = Range(match.range, in: title) {
            return String(title[hit]).uppercased()
        }
        guard let regex = codeRegex, let match = regex.firstMatch(in: title, range: range),
              let labelRange = Range(match.range(at: 1), in: title),
              let numberRange = Range(match.range(at: 2), in: title) else { return nil }
        return "\(title[labelRange].uppercased())-\(title[numberRange])"
    }

    /// 标题开头的 `[原创]` / `【最新】` 当作标签，至少让卡片不空着。
    private static func bracketTag(_ title: String) -> String? {
        let pattern = #"^[\[【]([^\]】]{1,6})[\]】]"#
        guard let raw = CatalogHTML.first(pattern, in: title) else { return nil }
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }

    private static func isMakerContext(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if ["国产精品", "国产自拍", "热门厂商", "全部厂商", "首页"].contains(text) {
            return false
        }
        return makerHints.contains { text.contains($0) }
            || ["传媒", "影业", "制片厂", "映画", "swag"].contains {
                text.lowercased().contains($0.lowercased())
            }
    }

    // MARK: - 翻页

    private struct Pagination {
        var links: [Int: URL] = [:]
        var next: URL?
    }

    /// 分类页翻页：站点只给出「页码 → 不透明 token」的链接，没有规律可循。
    private func tagPage(source: CatalogSource, root: String, token: String,
                         page: Int) async throws -> CatalogPage {
        guard var url = URL(string: root + "/tag.jsp?t=" + token) else {
            throw CatalogError.parse("分类地址无效")
        }
        var html = try await WebCatalogSupport.fetchHTML(url, source: source)
        var current = 1
        while current < page {
            let pagination = Self.parsePagination(html, currentURL: url)
            guard let next = pagination.links[current + 1] ?? pagination.next else {
                return CatalogPage(items: [], page: page, hasMore: false)
            }
            url = next
            html = try await WebCatalogSupport.fetchHTML(url, source: source)
            current += 1
        }
        let items = Self.parseSections(html, base: root)
        let pagination = Self.parsePagination(html, currentURL: url)
        let hasMore = pagination.links[page + 1] != nil || pagination.next != nil
        return CatalogPage(items: items, page: page, hasMore: hasMore)
    }

    private static func parsePagination(_ html: String, currentURL: URL) -> Pagination {
        var result = Pagination()
        guard let scope = CatalogHTML.first(#"<ul class="pagination">([\s\S]*?)</ul>"#, in: html)
        else { return result }
        for anchor in CatalogHTML.fullMatches(#"<a[^>]*href="([^"]+)"[^>]*>[\s\S]*?</a>"#, in: scope) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                  !href.hasPrefix("javascript") else { continue }
            let label = CatalogHTML.stripTags(anchor)
            guard let resolved = URL(string: href, relativeTo: currentURL)?.absoluteURL else {
                continue
            }
            if let number = Int(label) {
                result.links[number] = resolved
            } else if result.next == nil {
                // 页码之后的箭头（icon-chevron-right）就是下一页。
                result.next = resolved
            }
        }
        return result
    }

    // MARK: - 详情与播放解析

    static func parseTitle(_ html: String) -> String {
        let raw = CatalogHTML.first(#"<h1 class="title">([\s\S]*?)</h1>"#, in: html) ?? ""
        let title = CatalogHTML.stripTags(raw)
        guard title.isEmpty else { return title }
        return CatalogHTML.stripTags(CatalogHTML.first(#"<title>([\s\S]*?)</title>"#, in: html) ?? "")
    }

    /// 从 `eval(I("…"))` 取出异或 128 后的脚本，再抓 DPlayer 的视频地址。
    static func playerAddress(from html: String) -> String? {
        guard let encoded = CatalogHTML.first(#"eval\(I\("([^"]*)"\)\)"#, in: html) else {
            return nil
        }
        let script = decodeObfuscated(encoded)
        return CatalogHTML.first(#"url\s*:\s*'([^']+)'"#, in: script)
            ?? CatalogHTML.first(#"url\s*:\s*"([^"]+)""#, in: script)
    }

    /// 站点详情页本身没有结构化字段，只能从标题补番号 / 片商 / 女优，
    /// 再从播放列表算出时长——这样详情页不会是一张只有封面的空页。
    private static func detailFacts(source: CatalogSource, title: String,
                                    watchHTML: String, pageURL: URL) async -> [CatalogDetailFact] {
        var facts: [CatalogDetailFact] = []
        let parsed = CatalogNameParser.parse(title: title)
        if let code = parsed.code {
            facts.append(CatalogDetailFact(label: "番号", value: code))
        }
        if !parsed.makers.isEmpty {
            facts.append(CatalogDetailFact(label: "片商",
                                           value: parsed.makers.prefix(3).joined(separator: "、")))
        }
        if !parsed.actresses.isEmpty {
            facts.append(CatalogDetailFact(label: "女优",
                                           value: parsed.actresses.prefix(4).joined(separator: "、")))
        }
        if let duration = await hlsDuration(source: source, watchHTML: watchHTML,
                                            pageURL: pageURL) {
            facts.append(CatalogDetailFact(label: "时长", value: duration))
        }
        return facts
    }

    /// m3u8 里每个分片都标了时长，累加就是整片时长；取不到就返回 nil。
    private static func hlsDuration(source: CatalogSource, watchHTML: String,
                                    pageURL: URL) async -> String? {
        guard let raw = playerAddress(from: watchHTML),
              let url = URL(string: raw) else { return nil }
        guard let data = try? await CatalogHTTP.fetchData(
            url: url,
            headers: ["User-Agent": source.userAgent,
                      "Referer": pageURL.absoluteString],
            timeout: 8),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let seconds = CatalogHTML.fullMatches(#"#EXTINF:[0-9.]+"#, in: text)
            .compactMap { Double($0.dropFirst("#EXTINF:".count)) }
            .reduce(0, +)
        return formattedDuration(seconds)
    }

    private static func formattedDuration(_ seconds: Double) -> String? {
        guard seconds >= 20 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, total % 60)
        }
        return "\(minutes):" + String(format: "%02d", total % 60)
    }

    /// 站点脚本等价于 `String.fromCharCode(128 ^ charCodeAt(i))`，按 UTF-16 码元还原。
    static func decodeObfuscated(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for unit in raw.utf16 {
            if let scalar = UnicodeScalar(unit ^ 128) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
