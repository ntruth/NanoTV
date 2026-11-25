import Foundation

/// XSZAV（`tw.xsz-av.com`）适配器。
///
/// 站点是 Qwik 服务端渲染：列表卡片统一是 `<div class="thumbnail">`，
/// 详情页把播放地址直接写在 `<video src="/media/xxx.m3u8">` 里，图片无需解密。
struct XszCatalogProvider: CatalogProvider {

    static let defaultBaseURL = "https://tw.xsz-av.com"
    static let defaultUserAgent = WebCatalogSupport.userAgent

    /// 骨架与站点实时导航保持同样的 id / 标题：站点用繁体，分组 id 也是由标题拼出来的，
    /// 换成简体就会让「先点骨架、再被实时分类覆盖」这条路径丢失当前一级。
    static let defaultCategories: [CatalogCategory] = [
        CatalogCategory(id: "group:xsz:日本AV", title: "日本AV", children: [
            CatalogCategory(id: "videos/japanese", title: "最近更新"),
            CatalogCategory(id: "videos/uncensored-leak", title: "無碼流出")
        ], isGroup: true),
        CatalogCategory(id: "group:xsz:素人", title: "素人", children: [
            CatalogCategory(id: "tags/siro", title: "SIRO"),
            CatalogCategory(id: "tags/luxu", title: "LUXU"),
            CatalogCategory(id: "tags/gana", title: "GANA"),
            CatalogCategory(id: "tags/prestigepremium", title: "PRESTIGE PREMIUM"),
            CatalogCategory(id: "tags/s-cute", title: "S-CUTE")
        ], isGroup: true),
        CatalogCategory(id: "group:xsz:無碼影片", title: "無碼影片", children: [
            CatalogCategory(id: "videos/uncensored-leak", title: "無碼流出"),
            CatalogCategory(id: "tags/fc2ppv", title: "FC2"),
            CatalogCategory(id: "tags/heyzo", title: "HEYZO"),
            CatalogCategory(id: "tags/1pondo", title: "一本道"),
            CatalogCategory(id: "tags/caribbeancom", title: "Caribbeancom"),
            CatalogCategory(id: "tags/caribbeancompr", title: "Caribbeancompr"),
            CatalogCategory(id: "tags/10musume", title: "10musume"),
            CatalogCategory(id: "tags/pacopacomama", title: "Pacopacomama"),
            CatalogCategory(id: "tags/xxx-av", title: "XXX-AV"),
            CatalogCategory(id: "tags/marriedslash", title: "人妻斬"),
            CatalogCategory(id: "tags/naughty4610", title: "頑皮 4610"),
            CatalogCategory(id: "tags/naughty0930", title: "頑皮 0930")
        ], isGroup: true),
        CatalogCategory(id: "group:xsz:影片", title: "影片", children: [
            CatalogCategory(id: "videos/japanese", title: "日本AV"),
            CatalogCategory(id: "videos/uncensored", title: "無碼影片"),
            CatalogCategory(id: "videos/uncensored-leak", title: "無碼流出"),
            CatalogCategory(id: "videos/amateur", title: "素人"),
            CatalogCategory(id: "videos/chinese", title: "中國"),
            CatalogCategory(id: "videos/korean", title: "韓國"),
            CatalogCategory(id: "videos/western", title: "歐美"),
            CatalogCategory(id: "videos/hanime", title: "動畫")
        ], isGroup: true)
    ]

    // MARK: - CatalogProvider

    /// 顶部导航的每个下拉就是一个分组；分组本身没有页面，点它等于打开第一个子项。
    func categories(source: CatalogSource) async throws -> [CatalogCategory] {
        let root = try WebCatalogSupport.root(source)
        if let html = try? await WebCatalogSupport.fetchHTML(root + "/", source: source) {
            let live = Self.parseNavGroups(html)
            if !live.isEmpty { return live }
        }
        return source.categories.isEmpty ? Self.defaultCategories : source.categories
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
        var address = "\(root)/\(target.id)"
        if page > 1 { address += "?page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page)
                               || items.count >= 12)
    }

    func search(source: CatalogSource, keyword: String, page: Int) async throws -> CatalogPage {
        let root = try WebCatalogSupport.root(source)
        guard let encoded = WebCatalogSupport.pathEncoded(keyword)
        else { throw CatalogError.parse("搜索关键词无效") }
        var address = "\(root)/search/\(encoded)"
        if page > 1 { address += "?page=\(page)" }
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let items = Self.parseCards(html, base: root)
        return CatalogPage(items: items, page: page,
                           hasMore: WebCatalogSupport.hasNextPage(html, page: page)
                               || items.count >= 12)
    }

    func detail(source: CatalogSource, itemID: String) async throws -> CatalogDetail {
        let root = try WebCatalogSupport.root(source)
        let address = "\(root)/video/\(itemID)"
        let html = try await WebCatalogSupport.fetchHTML(address, source: source)
        let title = WebCatalogSupport.meta(html, "og:title")
        let cover = CatalogHTML.fixURL(WebCatalogSupport.meta(html, "og:image"), base: root)
        let tags = WebCatalogSupport.meta(html, "keywords")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return WebCatalogSupport.singleEpisode(
            id: itemID,
            title: title.isEmpty ? "视频 \(itemID)" : title,
            cover: cover,
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
        guard let raw = CatalogHTML.first(#"<video[^>]+src="([^"]+\.m3u8[^"]*)""#, in: html)
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
        let html = try await WebCatalogSupport.fetchHTML(base + "/", source: CatalogSource(
            name: "XSZAV",
            kind: .xszAV,
            baseURL: base,
            userAgent: defaultUserAgent,
            referer: base + "/",
            categories: defaultCategories
        ))
        guard html.contains("xsz"), html.contains("thumbnail") else {
            throw CatalogError.invalidConfig("站点结构无法识别：\(base)")
        }
        let nav = Self.parseNavGroups(html)
        return CatalogSource(name: "XSZAV",
                             kind: .xszAV,
                             baseURL: base,
                             configURL: address,
                             userAgent: defaultUserAgent,
                             referer: base + "/",
                             categories: nav.isEmpty ? defaultCategories : nav,
                             posterAspect: 16.0 / 9.0,
                             isEnabled: false)
    }

    // MARK: - 解析：导航分组

    /// 顶部导航的每个下拉就是一个分组：
    /// `<a href="#" preventdefault:click …>标题</a><div class="px-2 space-y-2 …">子项</div>`。
    static func parseNavGroups(_ html: String) -> [CatalogCategory] {
        let pattern = ##"<a href="#" preventdefault:click[^>]*>([^<]+)[\s\S]{0,1200}?</a><div class="px-2 space-y-2[^"]*"[^>]*>([\s\S]*?)</div>"##
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var result: [CatalogCategory] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var title = CatalogHTML.stripTags(ns.substring(with: match.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // 桌面导航叫「影片」、移动端叫「类别」，统一成一个名字。
            if title == "類別" || title == "类别" { title = "影片" }

            let body = ns.substring(with: match.range(at: 2))
            var children: [CatalogCategory] = []
            var childSeen = Set<String>()
            for anchor in CatalogHTML.fullMatches(
                #"<a href="(/videos/[^"]+|/tags/[^"]+)"[^>]*>([^<]+)</a>"#, in: body) {
                guard let href = CatalogHTML.first(#"href="([^"]+)""#, in: anchor) else { continue }
                // `?o=` 是排序参数，不是分类。
                guard !href.contains("?o=") else { continue }
                let id = href.hasPrefix("/") ? String(href.dropFirst()) : href
                let name = CatalogHTML.stripTags(anchor)
                guard !name.isEmpty, childSeen.insert(id).inserted else { continue }
                children.append(CatalogCategory(id: id, title: name))
            }
            guard children.count >= 2, seen.insert(title).inserted else { continue }
            result.append(CatalogCategory(id: "group:xsz:\(title)", title: title,
                                          children: children, isGroup: true))
        }
        return result
    }

    // MARK: - 解析

    /// 卡片：`<div class="thumbnail">` 里既有 `/video/{id}`，也有懒加载的 `data-src` 封面。
    static func parseCards(_ html: String, base: String) -> [CatalogItem] {
        var result: [CatalogItem] = []
        var seen = Set<String>()
        for block in CatalogHTML.blocks(#"<div class="thumbnail""#, in: html) {
            guard let id = CatalogHTML.first(#"href="/video/(\d+)""#, in: block),
                  seen.insert(id).inserted else { continue }
            let title = CatalogHTML.first(#"<img[^>]+alt="([^"]+)""#, in: block)
                ?? CatalogHTML.first(#"<div class="my-2[^"]*">[\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block)
                    .map(CatalogHTML.stripTags)
                ?? ""
            guard !title.isEmpty else { continue }
            let cover = CatalogHTML.first(#"<img[^>]+data-src="([^"]+)""#, in: block) ?? ""
            let duration = CatalogHTML.first(#"<span[^>]*>\s*(\d+:\d+(?::\d+)?)\s*</span>"#, in: block) ?? ""
            result.append(CatalogItem(id: id, title: title,
                                      coverURL: CatalogHTML.fixURL(cover, base: base),
                                      remark: duration, categoryID: nil))
        }
        return result
    }
}
