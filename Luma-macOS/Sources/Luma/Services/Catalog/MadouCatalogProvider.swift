import Foundation

/// 麻豆社（`madou.club`）适配器：国产原创片库（麻豆 / 果冻 / 天美 / 星空 / 精东 / 91制片厂等）。
///
/// - 列表：WordPress 服务端渲染，卡片是 `<article class="excerpt">`，标题在 `<h2>`
///   里，封面是 `data-src`，分页 ` /page/N `。
/// - 分类：导航里的 `/category/<slug>` 就是片商 / 系列，顺序按站点导航。
/// - 搜索：WordPress 原生 `?s=<关键词>`，分页 `/page/N/?s=…`。
/// - 播放：详情页正文内嵌 `dash.madou.club/share/<id>` iframe；
///   该页给出一段带 100 秒 token 的 `index.m3u8`，拼上 token 就能播。
struct MadouCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://madou.club"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 没有网络时用于渲染侧边栏骨架。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "category/麻豆传媒", title: "麻豆传媒"),
        CatalogCategory(id: "category/麻豆番外篇", title: "麻豆番外篇"),
        CatalogCategory(id: "category/果冻传媒", title: "果冻传媒"),
        CatalogCategory(id: "category/天美传媒", title: "天美传媒"),
        CatalogCategory(id: "category/星空无限传媒", title: "星空传媒"),
        CatalogCategory(id: "category/精东影业", title: "精东影业"),
        CatalogCategory(id: "category/蜜桃影像", title: "蜜桃影像")
    ]

    // MARK: - CatalogProvider

    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let live = try? await Self.liveCategories(source: source, root: root), live.count >= 4 {
            return live
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        try await home(source: source, page: 1)
    }

    func home(source: CatalogSource, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let address = page > 1 ? "\(root)/page/\(page)" : root + "/"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        let id = target.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        var address = "\(root)/"
        // 导航解析出来的 id 已经是 percent-encoding；只有手写的默认分类需要编码，
        // 再次编码会把 `%` 变成 `%25`。
        address += id.contains("%")
            ? id
            : (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
        if page > 1 { address += "/page/\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword) else {
            throw CatalogError.parse("搜索关键词无效")
        }
        var address = page > 1 ? "\(root)/page/\(page)/?s=\(encoded)" : "\(root)/?s=\(encoded)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: Self.hasNextPage(html, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/\(itemID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? itemID
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        // 正文标签里混着导航与长句，只留短标签，详情页不会变成一大段。
        let tags = Self.links(html, path: "/tag/")
            .filter { $0.count <= 12 }
            .prefix(12)
            .map { $0 }
        let studios = Self.categoryTags(html)

        var detail = WebCatalogSupport.singleEpisode(id: itemID,
                                                     title: title,
                                                     cover: cover,
                                                     pageURL: address,
                                                     blocks: WebCatalogSupport.tagBlocks(tags))
        if let studio = studios.first {
            detail.facts.append(CatalogDetailFact(label: "系列", value: studio))
        }
        if !tags.isEmpty {
            detail.facts.append(CatalogDetailFact(label: "类型",
                                                  value: tags.prefix(6).joined(separator: "、")))
        }
        return detail
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let root = try WebCatalogSupport.root(source)
        guard !episode.pageURL.isEmpty else { throw CatalogError.parse("分集地址无效") }
        let address = episode.pageURL
        let html = try await WebCatalogSupport.fetchHTML(address, source: Self.pageSource(source, root: root))

        // 详情页正文里的 iframe 才是播放页；广告 iframe 在正文外，不参与匹配。
        guard let share = CatalogHTML.first(#"(https?://dash\.[^\s"'<>]+/share/[0-9a-zA-Z]+)"#, in: html)
                ?? CatalogHTML.first(#"<iframe[^>]+src=["']?([^"' >]+)"#, in: html) else {
            throw CatalogError.parse("该条目没有可播放的视频")
        }
        let playHTML = try await WebCatalogSupport.fetchHTML(share, source: Self.pageSource(source, root: root))
        guard let rawPath = CatalogHTML.first(#"var m3u8 = '([^']+)'"#, in: playHTML) else {
            throw CatalogError.parse("播放地址解析失败")
        }
        var raw = rawPath
        if !raw.hasPrefix("http") {
            let comps = URLComponents(string: share)
            let host = (comps?.scheme ?? "https") + "://" + (comps?.host ?? "dash.madou.club")
            raw = host + (raw.hasPrefix("/") ? raw : "/" + raw)
        }
        if let token = CatalogHTML.first(#"var token = "([^"]*)""#, in: playHTML), !token.isEmpty {
            raw += (raw.contains("?") ? "&" : "?") + "token=\(token)"
        }
        var stream = try WebCatalogSupport.stream(raw, base: root,
                                                  referer: root + "/",
                                                  userAgent: source.userAgent)
        stream.headers["Origin"] = root
        return stream
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        var probe = CatalogSource(name: "麻豆社",
                                  kind: .madou,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("excerpt"), html.contains("madou") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        if let cats = try? await liveCategories(source: probe, root: base), !cats.isEmpty {
            probe.categories = cats
        }
        return CatalogSource(name: "麻豆社",
                             kind: .madou,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: probe.categories,
                             posterAspect: 4.0 / 3.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    private static func pageSource(_ source: CatalogSource, root: String) -> CatalogSource {
        var copy = source
        copy.referer = root + "/"
        return copy
    }

    /// 导航里的 `/category/<slug>` 就是片商 / 系列，保持站点原有顺序。
    private static func liveCategories(source: CatalogSource, root: String) async throws -> [CatalogCategory] {
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: pageSource(source, root: root))
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for anchor in CatalogHTML.fullMatches(#"<a\s+[^>]*href="[^"]*category/[^"]+"[^>]*>[\s\S]*?</a>"#,
                                              in: html) {
            guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor),
                  let comps = URLComponents(string: href) else { continue }
            let title = CatalogHTML.stripTags(anchor)
            guard !title.isEmpty else { continue }
            let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(CatalogCategory(id: path, title: title))
        }
        return result
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<article class="excerpt\b"#, in: html) {
            guard let href = CatalogHTML.first(#"<h2>\s*<a[^>]+href="([^"]+)""#, in: block)
                    ?? CatalogHTML.first(#"class="?thumbnail"?[^>]+href="([^"]+)""#, in: block),
                  let slug = slug(from: href, base: base),
                  seen.insert(slug).inserted else { continue }
            let title = CatalogHTML.first(#"<h2>\s*<a[^>]*>([\s\S]*?)</a>"#, in: block)
                .map(CatalogHTML.stripTags) ?? ""
            guard !title.isEmpty else { continue }
            let rawCover = CatalogHTML.first(#"data-src="([^"]+\.(?:jpg|jpeg|png|webp))""#, in: block) ?? ""
            let views = CatalogHTML.first(#"观看\(([^)]+)\)"#, in: block) ?? ""
            result.append(CatalogItem(id: slug,
                                      title: title,
                                      coverURL: CatalogHTML.fixURL(rawCover, base: base),
                                      remark: views.isEmpty ? "" : "观看 \(views)",
                                      categoryID: nil))
        }
        return result
    }

    /// `https://madou.club/%e5%b7%a8%e4%b9%b3.html` → 保留原来的 percent-encoding，
    /// 不在这里解码，避免拼回详情地址时丢中文。
    private static func slug(from address: String, base: String) -> String? {
        guard let comps = URLComponents(string: address) else { return nil }
        var path = comps.percentEncodedPath
        if path.isEmpty || path == "/" { return nil }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty, !path.hasPrefix("category/"),
              !path.hasPrefix("page/"), !path.hasPrefix("tag/") else { return nil }
        return path
    }

    /// 文章自身所属的系列：站内导航也有大量 `/category/`，只认 `rel="category tag"`。
    private static func categoryTags(_ html: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+rel="category tag"[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty }
    }

    private static func links(_ html: String, path: String) -> [String] {
        CatalogHTML.fullMatches(#"<a[^>]+href=[^ >]*\#(path)[^ >]+[^>]*>([\s\S]*?)</a>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
    }

    private static func hasNextPage(_ html: String, page: Int) -> Bool {
        html.range(of: "/page/\(page + 1)") != nil || html.contains("下一页")
    }
}
