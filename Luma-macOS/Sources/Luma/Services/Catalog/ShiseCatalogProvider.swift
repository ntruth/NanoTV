import Foundation

/// 视色（`shise.me`）适配器。
///
/// 传统服务端渲染站点：列表卡片是 `<div class="item video">`，封面写在
/// `background-image:url('…')`；详情页用 VideoPlayer，`src: '/hls/{id}/master.m3u8'`。
struct ShiseCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://shise.me"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "videos/cat-jav", title: "日本AV", children: [
            CatalogCategory(id: "videos/xs-4", title: "有码"),
            CatalogCategory(id: "videos/xs-5", title: "无码")
        ]),
        CatalogCategory(id: "videos/cat-cn", title: "国产"),
        CatalogCategory(id: "videos/cat-movie", title: "电影", children: [
            CatalogCategory(id: "videos/xs-61", title: "华语"),
            CatalogCategory(id: "videos/xs-118", title: "欧美"),
            CatalogCategory(id: "videos/xs-137", title: "韩国"),
            CatalogCategory(id: "videos/xs-156", title: "日本")
        ]),
        CatalogCategory(id: "videos/cat-ai", title: "AI视频"),
        CatalogCategory(id: "videos/cat-other", title: "其他"),
        CatalogCategory(id: "aiDramas", title: "AI短剧")
    ]

    // MARK: - CatalogProvider

    /// 站点侧栏只有当前父分类会展开子项，所以先取一次列表页拿到父分类，
    /// 再逐个父分类页收集它的二级（电影 → 华语 / 欧美 / 韩国 / 日本 这类）。
    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        guard let html = try? await WebCatalogSupport.fetchHTML("\(root)/videos.html",
                                                                source: source) else {
            return source.categories.isEmpty ? Self.defaultCategories : source.categories
        }
        var parents = Self.parseMenu(html)
        guard !parents.isEmpty else {
            return source.categories.isEmpty ? Self.defaultCategories : source.categories
        }
        for index in parents.indices {
            guard let page = try? await WebCatalogSupport.fetchHTML(
                "\(root)/\(parents[index].id).html", source: source) else { continue }
            let children = Self.parseMenu(page)
                .first(where: { $0.id == parents[index].id })?.children ?? []
            if !children.isEmpty { parents[index].children = children }
        }
        return parents
    }

    func home(source: CatalogSource) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let html = try await WebCatalogSupport.fetchHTML(root + "/", source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: 1, hasMore: false)
    }

    func category(source: CatalogSource, category: CatalogCategory,
                  sort: CatalogSort, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        let target = category.isGroupCategory ? (category.children?.first ?? category) : category
        guard !target.id.isEmpty else { throw CatalogError.parse("分类地址无效") }
        // 新版分类 id 带 `videos/` 前缀；旧源保存的 `cat-*` / `xs-*` 仍然兼容。
        var path = target.id
        if path.hasPrefix("cat-") || path.hasPrefix("xs-") { path = "videos/" + path }
        let address = page <= 1
            ? "\(root)/\(path).html"
            : "\(root)/\(path)/\(page).html"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page)
                               || items.count >= 12)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.queryEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/search.html?keyword=\(encoded)"
        if page > 1 { address += "&page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page))
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/video/\(itemID).html"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let title = CatalogHTML.first(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
            .map(CatalogHTML.stripTags) ?? ""
        let cover = Self.detailCover(html, itemID: itemID)
        let tags = CatalogHTML.fullMatches(#"<div class="tag[^"]*">([\s\S]*?)</div>"#, in: html)
            .map(CatalogHTML.stripTags)
            .filter { !$0.isEmpty && $0.count <= 12 && Int($0) == nil }
        return WebCatalogSupport.singleEpisode(
            id: itemID,
            title: title.isEmpty ? itemID : title,
            cover: CatalogHTML.fixURL(cover, base: root),
            pageURL: address,
            blocks: WebCatalogSupport.tagBlocks(tags)
        )
    }

    func stream(source: CatalogSource, episode: CatalogEpisode) async throws -> CatalogStream {
        let root = try WebCatalogSupport.root(source)
        guard let url = URL(string: episode.pageURL) else {
            throw CatalogError.parse("分集地址无效")
        }
        let html = try await WebCatalogSupport.fetchHTML(url, source: source)
        guard let raw = CatalogHTML.first(#"src:\s*'([^']*master\.m3u8[^']*)'"#, in: html)
        else { throw CatalogError.parse("该条目没有可播放的视频") }
        return try WebCatalogSupport.stream(raw, base: root,
                                            referer: episode.pageURL,
                                            userAgent: source.userAgent)
    }

    func coverData(source: CatalogSource, urlString: String) async throws -> Data {
        try await WebCatalogSupport.coverData(source: source, urlString: urlString)
    }

    // MARK: - 导入

    static func importSource(from address: String) async throws -> CatalogSource {
        let base = try WebCatalogSupport.base(from: address)
        let probe = CatalogSource(name: "视色",
                                  kind: .shise,
                                  baseURL: base,
                                  userAgent: defaultUserAgent,
                                  referer: base + "/",
                                  categories: defaultCategories)
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: probe)
        guard html.contains("item video") || html.contains("shise") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        let parsed = parseMenu(html)
        return CatalogSource(name: "视色",
                             kind: .shise,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: parsed.isEmpty ? defaultCategories : parsed,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 解析

    /// 「影片分类」侧栏：父分类与紧随其后的二级子项（只有当前父分类会展开子项）。
    static func parseMenu(_ html: String) -> [CatalogCategory] {
        let pattern = #"<a href="/((?:videos/)?[^"/]+)\.html"><div class="(parent|sub)[^"]*">([\s\S]*?)</div></a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var result: [CatalogCategory] = []
        var current: CatalogCategory?
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            let kind = ns.substring(with: match.range(at: 2))
            let rawTitle = CatalogHTML.stripTags(ns.substring(with: match.range(at: 3)))
            // 标题后面的「(1171)」是影片数量，不进名称。
            let title = rawTitle.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "",
                                                      options: .regularExpression)
            guard !title.isEmpty else { continue }
            if kind == "parent" {
                if let current { result.append(current) }
                current = CatalogCategory(id: id, title: title)
            } else if var parent = current {
                var children = parent.children ?? []
                children.append(CatalogCategory(id: id, title: title))
                parent.children = children
                current = parent
            }
        }
        if let current { result.append(current) }
        return result
    }

    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<div class="item video""#, in: html) {
            guard let hex = CatalogHTML.first(#"href="/video/id-([0-9a-f]+)\.html""#, in: block)
            else { continue }
            let id = "id-\(hex)"
            guard seen.insert(id).inserted else { continue }
            let title = CatalogHTML.first(#"title="([^"]+)""#, in: block)
                ?? CatalogHTML.first(#"<div class="title">[\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block)
                    .map(CatalogHTML.stripTags)
                ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"background-image:url\('([^']+)'\)"#, in: block) ?? ""
            let duration = CatalogHTML.first(#"far fa-clock"></i>\s*([\d:]+)"#, in: block) ?? ""
            result.append(CatalogItem(id: id, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }

    /// 详情页封面：优先页面里的 cover 图，其次按条目 id 拼图床地址。
    private static func detailCover(_ html: String, itemID: String) -> String {
        if let url = CatalogHTML.first(#"cover/([0-9a-f]+)\.webp"#, in: html) {
            return "https://r2.xchina.download/cover/\(url).webp"
        }
        let hex = itemID.replacingOccurrences(of: "id-", with: "")
        return "https://r2.xchina.download/cover/\(hex).webp"
    }
}
